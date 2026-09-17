import Darwin
import Foundation

public enum AppleGatewayEndpointPolicy {
    public enum Error: Swift.Error, LocalizedError, Sendable {
        case invalidEndpoint

        public var errorDescription: String? {
            "Use HTTPS, or HTTP with a private local IP address."
        }
    }

    public static func normalize(_ value: String) throws -> URL {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard isAllowed(trimmed), let url = URL(string: trimmed) else { throw Error.invalidEndpoint }
        return url
    }

    public static func isAllowed(_ value: String) -> Bool {
        guard let components = URLComponents(
            string: value.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        ), let scheme = components.scheme?.lowercased(), let host = components.host, !host.isEmpty,
        components.user == nil, components.password == nil,
        components.query == nil, components.fragment == nil else { return false }

        if scheme == "https" { return true }
        guard scheme == "http" else { return false }
        return isPrivateLiteral(host)
    }

    private static func isPrivateLiteral(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        if normalized == "localhost" || normalized == "::1" { return true }
        let octets = normalized.split(separator: ".").compactMap { UInt8($0) }
        if octets.count == 4, normalized.split(separator: ".", omittingEmptySubsequences: false).count == 4 {
            return switch (octets[0], octets[1]) {
            case (10, _), (127, _), (192, 168), (169, 254), (0, _): true
            case (172, 16 ... 31): true
            default: false
            }
        }

        var address = in6_addr()
        let parsed = normalized.withCString { inet_pton(AF_INET6, $0, &address) }
        guard parsed == 1 else { return false }
        return withUnsafeBytes(of: &address) { bytes in
            let loopback = bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
            let linkLocal = bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80
            let uniqueLocal = (bytes[0] & 0xfe) == 0xfc
            return loopback || linkLocal || uniqueLocal
        }
    }
}

public struct AppleTranscodeGatewayConfig: Equatable, Sendable {
    public let baseURL: URL
    public let sessionToken: String
    public let isEnabled: Bool

    public init(baseURL: String, sessionToken: String, isEnabled: Bool = true) throws {
        let token = sessionToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (32 ... 512).contains(token.utf8.count),
              token.utf8.allSatisfy({ byte in
                  (48 ... 57).contains(byte) || (65 ... 90).contains(byte) ||
                      (97 ... 122).contains(byte) || byte == 45 || byte == 95
              }) else { throw AppleTranscodeGatewayError.invalidToken }
        self.baseURL = try AppleGatewayEndpointPolicy.normalize(baseURL)
        self.sessionToken = token
        self.isEnabled = isEnabled
    }
}

public struct AppleTranscodeGatewayCapabilities: Codable, Equatable, Sendable {
    public let available: Bool
    public let version: String?
    public let hardwareAccelerated: Bool

    public init(available: Bool, version: String?, hardwareAccelerated: Bool) {
        self.available = available
        self.version = version
        self.hardwareAccelerated = hardwareAccelerated
    }

    private enum CodingKeys: String, CodingKey {
        case available
        case version
        case hardwareAccelerated
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        available = try container.decodeIfPresent(Bool.self, forKey: .available) ?? false
        version = try container.decodeIfPresent(String.self, forKey: .version)
        hardwareAccelerated = try container.decodeIfPresent(Bool.self, forKey: .hardwareAccelerated) ?? false
    }
}

public struct AppleGatewayPlaybackSession: Equatable, Sendable {
    public let url: URL
    public let headers: [String: String]

    public init(url: URL, headers: [String: String]) {
        self.url = url
        self.headers = headers
    }
}

/// Identifies the gateway input without conflating an SSRF-authorized remote
/// URL with an SMB URI that must resolve through an explicit local mapping.
public enum AppleGatewayTranscodeSource: Equatable, Sendable {
    case remoteURL(URL)
    case smbURI(String)
}

public enum AppleTranscodeGatewayError: Swift.Error, LocalizedError, Equatable, Sendable {
    case invalidToken
    case invalidResponse
    case responseTooLarge
    case requestFailed(Int, String?)
    case missingTranscodeURL

    public var errorDescription: String? {
        switch self {
        case .invalidToken: "Gateway token must be 32 to 512 base64url characters."
        case .invalidResponse: "The gateway returned an invalid response."
        case .responseTooLarge: "The gateway response is too large."
        case .requestFailed(let status, let message): message ?? "Gateway request failed with HTTP \(status)."
        case .missingTranscodeURL: "The gateway did not return a playback URL."
        }
    }
}

public struct AppleTranscodeGatewayClient: Sendable {
    public typealias Loader = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let loader: Loader

    public init(loader: @escaping Loader = AppleTranscodeGatewayClient.liveLoader) {
        self.loader = loader
    }

    public func capabilities(config: AppleTranscodeGatewayConfig) async throws -> AppleTranscodeGatewayCapabilities {
        let data = try await request(config: config, method: "GET", path: "api/transcode/capabilities")
        guard let value = try? JSONDecoder().decode(AppleTranscodeGatewayCapabilities.self, from: data) else {
            throw AppleTranscodeGatewayError.invalidResponse
        }
        return value
    }

    public func startSMBSession(
        config: AppleTranscodeGatewayConfig,
        smbURI: String,
        maximumWidth: Int,
        maximumHeight: Int
    ) async throws -> AppleGatewayPlaybackSession {
        try await startSession(
            config: config,
            source: .smbURI(smbURI),
            maximumWidth: maximumWidth,
            maximumHeight: maximumHeight
        )
    }

    public func startRemoteURLSession(
        config: AppleTranscodeGatewayConfig,
        remoteURL: URL,
        maximumWidth: Int,
        maximumHeight: Int
    ) async throws -> AppleGatewayPlaybackSession {
        try await startSession(
            config: config,
            source: .remoteURL(remoteURL),
            maximumWidth: maximumWidth,
            maximumHeight: maximumHeight
        )
    }

    public func startSession(
        config: AppleTranscodeGatewayConfig,
        source: AppleGatewayTranscodeSource,
        maximumWidth: Int,
        maximumHeight: Int
    ) async throws -> AppleGatewayPlaybackSession {
        struct Profile: Encodable { let maxWidth: Int; let maxHeight: Int; let videoCodec: String }
        struct SMBPayload: Encodable { let smbUri: String; let profile: Profile }
        struct RemotePayload: Encodable { let remoteUrl: String; let profile: Profile }
        struct Response: Decodable { let transcodeUrl: String }

        let profile = Profile(maxWidth: maximumWidth, maxHeight: maximumHeight, videoCodec: "h264")
        let path: String
        let body: Data
        switch source {
        case .smbURI(let smbURI):
            path = "api/transcode/smb-sessions"
            body = try JSONEncoder().encode(SMBPayload(smbUri: smbURI, profile: profile))
        case .remoteURL(let remoteURL):
            path = "api/transcode/sessions"
            body = try JSONEncoder().encode(RemotePayload(
                remoteUrl: remoteURL.absoluteString,
                profile: profile
            ))
        }
        let data = try await request(
            config: config,
            method: "POST",
            path: path,
            body: body
        )
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw AppleTranscodeGatewayError.invalidResponse
        }
        let route = response.transcodeUrl.replacingOccurrences(of: "/gateway/", with: "/api/")
        let candidate = resolvedPlaybackURL(route: route, baseURL: config.baseURL)
        let basePath = config.baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let apiRoot = basePath.isEmpty ? "/api" : "/\(basePath)/api"
        guard let url = candidate,
              sameOrigin(url, config.baseURL),
              isScopedTranscodeURL(url, apiRoot: apiRoot) else {
            throw AppleTranscodeGatewayError.missingTranscodeURL
        }
        return AppleGatewayPlaybackSession(
            url: url,
            headers: [:]
        )
    }

    private func request(
        config: AppleTranscodeGatewayConfig,
        method: String,
        path: String,
        body: Data? = nil
    ) async throws -> Data {
        let url = config.baseURL.appending(path: path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(config.sessionToken, forHTTPHeaderField: "X-OpenStream-Session")
        request.setValue("apple", forHTTPHeaderField: "X-OpenStream-Client")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await loader(request)
        guard data.count <= 1_000_000 else { throw AppleTranscodeGatewayError.responseTooLarge }
        guard let http = response as? HTTPURLResponse else { throw AppleTranscodeGatewayError.invalidResponse }
        guard (200 ... 299).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw AppleTranscodeGatewayError.requestFailed(http.statusCode, message)
        }
        return data
    }

    public static func liveLoader(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await AppleBoundedHTTPDataLoader.load(
                request,
                maximumBytes: 1_000_000,
                redirectPolicy: .reject
            )
        } catch AppleBoundedHTTPError.responseTooLarge {
            throw AppleTranscodeGatewayError.responseTooLarge
        }
    }

    private func sameOrigin(_ candidate: URL, _ baseURL: URL) -> Bool {
        guard let candidateScheme = candidate.scheme?.lowercased(),
              let baseScheme = baseURL.scheme?.lowercased(),
              let candidateHost = candidate.host?.lowercased(),
              let baseHost = baseURL.host?.lowercased() else { return false }
        let candidatePort = candidate.port ?? (candidateScheme == "https" ? 443 : 80)
        let basePort = baseURL.port ?? (baseScheme == "https" ? 443 : 80)
        return candidateScheme == baseScheme && candidateHost == baseHost && candidatePort == basePort
    }

    private func resolvedPlaybackURL(route: String, baseURL: URL) -> URL? {
        if let absolute = URL(string: route), absolute.scheme != nil { return absolute }
        guard let relative = URLComponents(string: route),
              relative.scheme == nil,
              relative.host == nil,
              relative.user == nil,
              relative.password == nil,
              var base = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }

        let basePath = base.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let routePath = relative.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if basePath.isEmpty || routePath == basePath || routePath.hasPrefix(basePath + "/") {
            base.path = "/" + routePath
        } else {
            base.path = "/" + basePath + "/" + routePath
        }
        base.percentEncodedQuery = relative.percentEncodedQuery
        base.fragment = nil
        return base.url
    }

    private func isScopedTranscodeURL(_ url: URL, apiRoot: String) -> Bool {
        guard url.path == apiRoot + "/transcode/media",
              let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              queryItems.count == 1,
              queryItems[0].name == "transcodeId",
              let token = queryItems[0].value,
              (32 ... 128).contains(token.utf8.count) else { return false }
        return token.utf8.allSatisfy { byte in
            (48 ... 57).contains(byte) || (65 ... 90).contains(byte) ||
                (97 ... 122).contains(byte) || byte == 45 || byte == 95
        }
    }
}
extension AppleTranscodeGatewayConfig {
    /// One-line Settings description for the transcode gateway: an optional
    /// remote accelerator, not a requirement for normal HTTP/HLS or compatible
    /// local-file playback.
    public static let settingsDescription = "Optional remote accelerator. Playback works without it."
}
