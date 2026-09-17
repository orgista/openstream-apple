import Foundation

/// Connection information for a Stremio Service / streaming server. Public
/// servers must use HTTPS. Plain HTTP is limited to loopback, private IP
/// literals, and mDNS `.local` hosts so a mistyped public endpoint cannot send
/// torrent metadata over cleartext.
public struct AppleStremioStreamingServerConfiguration: Equatable, Sendable {
    public let baseURL: URL

    public init(baseURL: String) throws {
        self.baseURL = try AppleStremioStreamingServerEndpointPolicy.normalize(baseURL)
    }
}

public enum AppleStremioStreamingServerEndpointPolicy {
    public enum Error: Swift.Error, Equatable, LocalizedError, Sendable {
        case invalidEndpoint

        public var errorDescription: String? {
            "Use HTTPS, or HTTP with localhost, a private IP address, or a .local host."
        }
    }

    public static func normalize(_ value: String) throws -> URL {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard isAllowed(trimmed), let url = URL(string: trimmed) else {
            throw Error.invalidEndpoint
        }
        return url
    }

    public static func isAllowed(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard (1 ... 2_048).contains(trimmed.utf8.count),
              !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            return false
        }

        if scheme == "https" { return true }
        guard scheme == "http" else { return false }
        if AppleGatewayEndpointPolicy.isAllowed(trimmed) { return true }
        return host != ".local" && host.hasSuffix(".local")
    }
}

public struct AppleStremioSeriesInfo: Equatable, Sendable {
    public let season: Int
    public let episode: Int

    public init?(mediaID: String) {
        let parts = mediaID.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 3,
              let season = Int(parts[parts.count - 2]),
              let episode = Int(parts[parts.count - 1]),
              (0 ... 10_000).contains(season),
              (0 ... 100_000).contains(episode) else {
            return nil
        }
        self.season = season
        self.episode = episode
    }
}

public enum AppleStremioStreamingServerError: Swift.Error, Equatable, LocalizedError, Sendable {
    case invalidTorrent
    case invalidResponse
    case responseTooLarge
    case requestFailed(Int)
    case redirectRejected
    case unreachable

    public var errorDescription: String? {
        switch self {
        case .invalidTorrent:
            "The add-on returned invalid stream information."
        case .invalidResponse:
            "The add-on service returned an invalid response."
        case .responseTooLarge:
            "The add-on service response is too large."
        case .requestFailed(let status):
            "The add-on service returned HTTP \(status)."
        case .redirectRejected:
            "The add-on service redirected outside its configured address."
        case .unreachable:
            "The add-on service could not be reached. Check its URL and local-network access."
        }
    }
}

/// Implements Stremio's documented streaming-service conversion flow:
/// create/attach the torrent, expose its selected file, and provide an HLSv2
/// route that AVPlayer can consume when the original container is unsupported.
public struct AppleStremioStreamingServerClient: Sendable {
    public typealias Loader = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public static let maximumResponseBytes = 1_000_000

    private let loader: Loader

    public init(loader: @escaping Loader = AppleStremioStreamingServerClient.liveLoader) {
        self.loader = loader
    }

    public func testConnection(
        configuration: AppleStremioStreamingServerConfiguration
    ) async throws {
        let url = try endpoint(configuration: configuration, path: ["settings"])
        let data = try await request(url: url, method: "GET", configuration: configuration)
        let object = try? JSONSerialization.jsonObject(with: data)
        guard object is [String: Any] else {
            throw AppleStremioStreamingServerError.invalidResponse
        }
    }

    public func playbackCandidates(
        title: String,
        filename: String?,
        infoHash: String,
        fileIndex: Int?,
        sources: [String],
        seriesInfo: AppleStremioSeriesInfo?,
        configuration: AppleStremioStreamingServerConfiguration
    ) async throws -> [AppleStremioHTTPPlaybackCandidate] {
        guard Self.isValidInfoHash(infoHash),
              fileIndex.map({ (0 ... 100_000).contains($0) }) ?? true else {
            throw AppleStremioStreamingServerError.invalidTorrent
        }

        let peerSources = Self.safePeerSources(sources, infoHash: infoHash)
        var resolvedIndex = fileIndex
        // This mirrors Stremio's own createTorrent.js: an explicit file index
        // with no trackers can be addressed directly; every other case asks
        // the service to create the engine and, when needed, choose a file.
        if fileIndex == nil || !peerSources.isEmpty {
            let createURL = try endpoint(
                configuration: configuration,
                path: [infoHash.lowercased(), "create"]
            )
            let body = try Self.createBody(
                infoHash: infoHash,
                fileIndex: fileIndex,
                peerSources: peerSources,
                seriesInfo: seriesInfo
            )
            let response = try await request(
                url: createURL,
                method: "POST",
                body: body,
                configuration: configuration
            )
            if fileIndex == nil {
                let created = try? JSONDecoder().decode(CreateResponse.self, from: response)
                resolvedIndex = created?.guessedFileIdx
            }
        }

        let selectedIndex = resolvedIndex ?? -1
        let directURL = try mediaURL(
            configuration: configuration,
            infoHash: infoHash,
            fileIndex: selectedIndex,
            peerSources: peerSources
        )
        let hlsURL = try hlsURL(configuration: configuration, mediaURL: directURL)
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayTitle = cleanTitle.isEmpty ? "Stream" : cleanTitle

        return [
            AppleStremioHTTPPlaybackCandidate(
                title: "\(displayTitle) · HLS",
                sourceURL: hlsURL,
                filename: filename
            ),
            AppleStremioHTTPPlaybackCandidate(
                title: displayTitle,
                sourceURL: directURL,
                filename: filename
            ),
        ]
    }

    private func request(
        url: URL,
        method: String,
        body: Data? = nil,
        configuration: AppleStremioStreamingServerConfiguration
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("OpenStream/1.0 Apple", forHTTPHeaderField: "User-Agent")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await loader(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AppleStremioStreamingServerError.unreachable
        }
        guard data.count <= Self.maximumResponseBytes,
              response.expectedContentLength <= Int64(Self.maximumResponseBytes) else {
            throw AppleStremioStreamingServerError.responseTooLarge
        }
        guard let http = response as? HTTPURLResponse,
              let responseURL = http.url else {
            throw AppleStremioStreamingServerError.invalidResponse
        }
        guard Self.sameOrigin(responseURL, configuration.baseURL) else {
            throw AppleStremioStreamingServerError.redirectRejected
        }
        guard (200 ... 299).contains(http.statusCode) else {
            if (300 ... 399).contains(http.statusCode) {
                throw AppleStremioStreamingServerError.redirectRejected
            }
            throw AppleStremioStreamingServerError.requestFailed(http.statusCode)
        }
        return data
    }

    private func endpoint(
        configuration: AppleStremioStreamingServerConfiguration,
        path: [String]
    ) throws -> URL {
        guard var components = URLComponents(
            url: configuration.baseURL,
            resolvingAgainstBaseURL: false
        ) else {
            throw AppleStremioStreamingServerError.invalidResponse
        }
        let basePath = components.percentEncodedPath
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let suffix = path.map(Self.percentEncodedPathSegment).joined(separator: "/")
        components.percentEncodedPath = basePath.isEmpty ? "/\(suffix)" : "/\(basePath)/\(suffix)"
        guard let url = components.url else {
            throw AppleStremioStreamingServerError.invalidResponse
        }
        return url
    }

    private func mediaURL(
        configuration: AppleStremioStreamingServerConfiguration,
        infoHash: String,
        fileIndex: Int,
        peerSources: [String]
    ) throws -> URL {
        let base = try endpoint(
            configuration: configuration,
            path: [infoHash.lowercased(), String(fileIndex)]
        )
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw AppleStremioStreamingServerError.invalidResponse
        }
        if !peerSources.isEmpty {
            components.queryItems = peerSources.map { URLQueryItem(name: "tr", value: $0) }
        }
        guard let url = components.url else {
            throw AppleStremioStreamingServerError.invalidResponse
        }
        return url
    }

    private func hlsURL(
        configuration: AppleStremioStreamingServerConfiguration,
        mediaURL: URL
    ) throws -> URL {
        let sessionID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let base = try endpoint(
            configuration: configuration,
            path: ["hlsv2", sessionID, "master.m3u8"]
        )
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw AppleStremioStreamingServerError.invalidResponse
        }
        components.queryItems = [
            URLQueryItem(name: "mediaURL", value: mediaURL.absoluteString),
            URLQueryItem(name: "videoCodecs", value: "h264"),
            URLQueryItem(name: "videoCodecs", value: "h265"),
            URLQueryItem(name: "videoCodecs", value: "hevc"),
            URLQueryItem(name: "audioCodecs", value: "aac"),
            URLQueryItem(name: "audioCodecs", value: "ac3"),
            URLQueryItem(name: "audioCodecs", value: "eac3"),
            URLQueryItem(name: "maxAudioChannels", value: "8"),
        ]
        guard let url = components.url else {
            throw AppleStremioStreamingServerError.invalidResponse
        }
        return url
    }

    private static func createBody(
        infoHash: String,
        fileIndex: Int?,
        peerSources: [String],
        seriesInfo: AppleStremioSeriesInfo?
    ) throws -> Data {
        var object: [String: Any] = [
            "torrent": ["infoHash": infoHash.lowercased()],
        ]
        if peerSources.isEmpty {
            object["guessFileIdx"] = fileIndex == nil ? [:] : false
        } else {
            object["peerSearch"] = [
                "sources": peerSources,
                "min": 40,
                "max": 200,
            ]
            object["guessFileIdx"] = fileIndex == nil ? [:] : false
        }
        if fileIndex == nil, let seriesInfo {
            object["guessFileIdx"] = [
                "season": seriesInfo.season,
                "episode": seriesInfo.episode,
            ]
        }
        return try JSONSerialization.data(withJSONObject: object)
    }

    private static func safePeerSources(_ values: [String], infoHash: String) -> [String] {
        var seen = Set<String>()
        var result = ["dht:\(infoHash.lowercased())"]
        seen.insert(result[0])
        for raw in values.prefix(64) {
            let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (1 ... 2_048).contains(clean.utf8.count),
                  !clean.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                continue
            }
            let normalized = clean.hasPrefix("tracker:") || clean.hasPrefix("dht:")
                ? clean
                : "tracker:\(clean)"
            if seen.insert(normalized).inserted { result.append(normalized) }
        }
        return values.isEmpty ? [] : result
    }

    private static func isValidInfoHash(_ value: String) -> Bool {
        let bytes = value.utf8
        if bytes.count == 40 {
            return bytes.allSatisfy {
                (48 ... 57).contains($0) || (65 ... 70).contains($0) || (97 ... 102).contains($0)
            }
        }
        if bytes.count == 32 {
            return bytes.allSatisfy {
                (65 ... 90).contains($0) || (97 ... 122).contains($0) || (50 ... 55).contains($0)
            }
        }
        return false
    }

    private static func percentEncodedPathSegment(_ value: String) -> String {
        value.utf8.map { byte in
            switch byte {
            case 48 ... 57, 65 ... 90, 97 ... 122, 45, 46, 95, 126:
                String(UnicodeScalar(byte))
            default:
                String(format: "%%%02X", byte)
            }
        }.joined()
    }

    private static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && effectivePort(lhs) == effectivePort(rhs)
    }

    private static func effectivePort(_ url: URL) -> Int? {
        url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
    }

    public static func liveLoader(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await AppleBoundedHTTPDataLoader.load(
                request,
                maximumBytes: maximumResponseBytes,
                redirectPolicy: .reject
            )
        } catch AppleBoundedHTTPError.responseTooLarge {
            throw AppleStremioStreamingServerError.responseTooLarge
        }
    }

    private struct CreateResponse: Decodable {
        let guessedFileIdx: Int?
    }
}
