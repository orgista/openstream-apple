import Foundation

/// A Stremio stream URL that is safe to hand to the Apple playback inspection
/// pipeline. HTTP alone does not prove container or codec support, so callers
/// must inspect the asset and route it through `ApplePlaybackPreparer` before
/// creating a player.
public struct AppleStremioHTTPPlaybackCandidate: Equatable, Sendable {
    public let title: String
    public let sourceURL: URL
    public let filename: String?
    public let requestHeaders: [String: String]
    public let requiresGateway: Bool
    public let sourceName: String?
    public let qualityDescription: String?
    public let sizeBytes: Int64?

    public init(
        title: String,
        sourceURL: URL,
        filename: String? = nil,
        requestHeaders: [String: String] = [:],
        requiresGateway: Bool = false,
        sourceName: String? = nil,
        qualityDescription: String? = nil,
        sizeBytes: Int64? = nil
    ) {
        self.qualityDescription = qualityDescription
        self.sizeBytes = sizeBytes
        self.title = title
        self.sourceURL = sourceURL
        self.filename = filename
        self.requestHeaders = requestHeaders
        self.requiresGateway = requiresGateway
        let cleanSourceName = sourceName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.sourceName = cleanSourceName.isEmpty ? nil : cleanSourceName
    }

    public var requiresRuntimeInspection: Bool { true }

    /// These provider status markers point to preparation clips, not the title.
    public var isPendingPreparation: Bool {
        title.range(of: #"\[(?:TB|RD|AD|PM) download\]"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    public func withSourceName(_ sourceName: String) -> Self {
        Self(
            title: title,
            sourceURL: sourceURL,
            filename: filename,
            requestHeaders: requestHeaders,
            requiresGateway: requiresGateway,
            sourceName: sourceName,
            qualityDescription: qualityDescription,
            sizeBytes: sizeBytes
        )
    }
}

/// A locator returned by an add-on that OpenStream cannot truthfully pass to
/// AVFoundation as media. These values are retained so the UI can explain why
/// an add-on result was not offered as a playable URL without silently treating
/// a torrent, web page, or YouTube identifier as direct media.
public enum AppleStremioUnsupportedReason: Equatable, Sendable {
    case torrent(infoHash: String, fileIndex: Int?, sources: [String])
    case externalLink(URL)
    case youtube(videoID: String)
    case invalidHTTPURL
    case invalidLocator
    case missingLocator
}

public struct AppleStremioUnsupportedStream: Equatable, Sendable {
    public let title: String
    public let filename: String?
    public let reason: AppleStremioUnsupportedReason

    public init(title: String, filename: String? = nil, reason: AppleStremioUnsupportedReason) {
        self.title = title
        self.filename = filename
        self.reason = reason
    }
}

public struct AppleStremioStreamSelection: Equatable, Sendable {
    public let httpCandidates: [AppleStremioHTTPPlaybackCandidate]
    public let unsupported: [AppleStremioUnsupportedStream]

    public init(
        httpCandidates: [AppleStremioHTTPPlaybackCandidate],
        unsupported: [AppleStremioUnsupportedStream]
    ) {
        self.httpCandidates = httpCandidates
        self.unsupported = unsupported
    }

    public static let empty = AppleStremioStreamSelection(httpCandidates: [], unsupported: [])
}

public struct AppleStremioSubtitleTrack: Equatable, Sendable {
    public let id: String
    public let url: URL
    public let language: String
    public let mimeType: String

    public init(id: String, url: URL, language: String, mimeType: String) {
        self.id = id
        self.url = url
        self.language = language
        self.mimeType = mimeType
    }
}

public enum AppleStremioPlaybackError: Swift.Error, Equatable, LocalizedError, Sendable {
    case invalidSource
    case invalidMediaIdentity
    case nonHTTPResponse
    case insecureRedirect
    case requestFailed(Int)
    case responseTooLarge
    case invalidPayload

    public var errorDescription: String? {
        switch self {
        case .invalidSource:
            "The add-on address is invalid."
        case .invalidMediaIdentity:
            "The title identifier is invalid."
        case .nonHTTPResponse:
            "The add-on returned an invalid response."
        case .insecureRedirect:
            "The add-on redirected to an insecure address."
        case .requestFailed(let status):
            "The add-on request failed with HTTP \(status)."
        case .responseTooLarge:
            "The add-on response is too large."
        case .invalidPayload:
            "The add-on returned invalid playback data."
        }
    }
}

/// A bounded Stremio playback-resource client. It deliberately resolves only
/// the protocol layer: native media compatibility remains an AVAsset runtime
/// decision made by the playback preparation pipeline.
public struct AppleStremioPlaybackClient: Sendable {
    public typealias Loader = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    public typealias Sleeper = @Sendable (Duration) async throws -> Void

    public static let maximumResponseBytes = 2_000_000
    public static let maximumHTTPStreams = 200
    public static let maximumUnsupportedStreams = 100
    public static let maximumSubtitles = 100

    private let loader: Loader
    private let sleeper: Sleeper

    public init(
        loader: @escaping Loader = AppleStremioPlaybackClient.liveLoader,
        sleeper: @escaping Sleeper = AppleStremioPlaybackClient.liveSleeper
    ) {
        self.loader = loader
        self.sleeper = sleeper
    }

    /// Resolves stream entries only when the enabled source advertises the
    /// `stream` resource. Direct HTTP(S) entries are returned separately from
    /// locators that need another product or resolver.
    public func streams(
        source: AppleSource,
        type: String,
        mediaID: String
    ) async throws -> AppleStremioStreamSelection {
        guard source.kind == .stremio,
              source.isEnabled,
              source.resources.contains(where: { $0.caseInsensitiveCompare("stream") == .orderedSame }) else {
            return .empty
        }

        let endpoint = try Self.endpoint(
            source: source,
            resource: "stream",
            type: type,
            mediaID: mediaID
        )
        let payload = try await request(endpoint)
        return try Self.parseStreams(payload)
    }

    /// Resolves safe HTTP(S) subtitle files for a movie or episode identity.
    /// Unsafe schemes are ignored and malformed array members do not discard
    /// otherwise valid tracks.
    public func subtitles(
        source: AppleSource,
        type: String,
        mediaID: String
    ) async throws -> [AppleStremioSubtitleTrack] {
        guard source.kind == .stremio,
              source.isEnabled,
              source.resources.contains(where: { $0.caseInsensitiveCompare("subtitles") == .orderedSame }) else {
            return []
        }

        let endpoint = try Self.endpoint(
            source: source,
            resource: "subtitles",
            type: type,
            mediaID: mediaID
        )
        let payload = try await request(endpoint)
        return try Self.parseSubtitles(payload)
    }

    public static func parseStreams(_ data: Data) throws -> AppleStremioStreamSelection {
        guard data.count <= maximumResponseBytes,
              let envelope = try? JSONDecoder().decode(StreamEnvelope.self, from: data) else {
            throw data.count > maximumResponseBytes ?
                AppleStremioPlaybackError.responseTooLarge :
                AppleStremioPlaybackError.invalidPayload
        }

        var seenHTTPURLs = Set<String>()
        var httpCandidates: [AppleStremioHTTPPlaybackCandidate] = []
        var unsupported: [AppleStremioUnsupportedStream] = []

        for (index, lossyValue) in envelope.streams.enumerated() {
            guard let value = lossyValue.value else { continue }
            let title = cleanLabel(value.name) ?? cleanLabel(value.title) ?? "Stream \(index + 1)"

            if let rawURL = value.url?.trimmingCharacters(in: .whitespacesAndNewlines),
               !rawURL.isEmpty,
               let url = safeHTTPURL(rawURL) {
                let headers = safeProxyHeaders(value.behaviorHints?.proxyHeaders?.request)
                let notWebReady = value.behaviorHints?.notWebReady == true
                let key = [
                    url.absoluteString,
                    headers.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: "|"),
                    String(notWebReady),
                ].joined(separator: "\u{1f}")
                guard seenHTTPURLs.insert(key).inserted else { continue }
                if httpCandidates.count < maximumHTTPStreams {
                    httpCandidates.append(AppleStremioHTTPPlaybackCandidate(
                        title: title,
                        sourceURL: url,
                        filename: cleanFilename(value.behaviorHints?.filename),
                        requestHeaders: headers,
                        requiresGateway: notWebReady,
                        qualityDescription: [value.name, value.title].compactMap { $0 }.joined(separator: " "),
                        sizeBytes: value.behaviorHints?.videoSize
                    ))
                }
                continue
            }

            guard unsupported.count < maximumUnsupportedStreams else { continue }
            let reason: AppleStremioUnsupportedReason
            if let hash = validInfoHash(value.infoHash) {
                reason = .torrent(
                    infoHash: hash,
                    fileIndex: validFileIndex(value.fileIndex),
                    sources: safeTorrentSources(value.sources)
                )
            } else if let videoID = validYouTubeID(value.youtubeID) {
                reason = .youtube(videoID: videoID)
            } else if let externalURL = safeExternalURL(value.externalURL) {
                reason = .externalLink(externalURL)
            } else if value.url?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                reason = .invalidHTTPURL
            } else if value.infoHash != nil || value.youtubeID != nil || value.externalURL != nil {
                reason = .invalidLocator
            } else {
                reason = .missingLocator
            }
            unsupported.append(AppleStremioUnsupportedStream(
                title: title,
                filename: cleanFilename(value.behaviorHints?.filename),
                reason: reason
            ))
        }

        return AppleStremioStreamSelection(httpCandidates: httpCandidates, unsupported: unsupported)
    }

    public static func parseSubtitles(_ data: Data) throws -> [AppleStremioSubtitleTrack] {
        guard data.count <= maximumResponseBytes,
              let envelope = try? JSONDecoder().decode(SubtitleEnvelope.self, from: data) else {
            throw data.count > maximumResponseBytes ?
                AppleStremioPlaybackError.responseTooLarge :
                AppleStremioPlaybackError.invalidPayload
        }

        var seenURLs = Set<String>()
        var tracks: [AppleStremioSubtitleTrack] = []
        for (index, lossyValue) in envelope.subtitles.enumerated() {
            guard tracks.count < maximumSubtitles,
                  let value = lossyValue.value,
                  let url = value.url.flatMap(safeHTTPURL),
                  seenURLs.insert(url.absoluteString).inserted else { continue }

            tracks.append(AppleStremioSubtitleTrack(
                id: cleanLabel(value.id, maximumLength: 100) ?? "subtitle-\(index + 1)",
                url: url,
                language: cleanLabel(value.language, maximumLength: 24) ?? "und",
                mimeType: subtitleMimeType(url)
            ))
        }
        return tracks
    }

    private func request(_ endpoint: URL) async throws -> Data {
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("OpenStream/1.0 Apple", forHTTPHeaderField: "User-Agent")

        var lastTransportError: (any Swift.Error)?
        for attempt in 0 ..< 4 {
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await loader(request)
            } catch is CancellationError {
                throw CancellationError()
            } catch AppleStremioPlaybackError.responseTooLarge {
                throw AppleStremioPlaybackError.responseTooLarge
            } catch {
                lastTransportError = error
                guard attempt < 3 else { throw error }
                try await sleeper(Self.backoff(for: attempt))
                continue
            }

            guard data.count <= Self.maximumResponseBytes,
                  response.expectedContentLength <= Int64(Self.maximumResponseBytes) else {
                throw AppleStremioPlaybackError.responseTooLarge
            }
            guard let http = response as? HTTPURLResponse else {
                throw AppleStremioPlaybackError.nonHTTPResponse
            }
            guard let responseURL = http.url,
                  Self.isSecureAddonEndpoint(responseURL) else {
                throw AppleStremioPlaybackError.insecureRedirect
            }
            if (300 ... 399).contains(http.statusCode),
               let location = http.value(forHTTPHeaderField: "Location"),
               let responseURL = http.url,
               let redirectURL = URL(string: location, relativeTo: responseURL)?.absoluteURL,
               !Self.isSecureAddonEndpoint(redirectURL) {
                throw AppleStremioPlaybackError.insecureRedirect
            }
            if Self.isRetryable(http.statusCode), attempt < 3 {
                try await sleeper(Self.backoff(for: attempt))
                continue
            }
            guard (200 ... 299).contains(http.statusCode) else {
                throw AppleStremioPlaybackError.requestFailed(http.statusCode)
            }
            return data
        }

        if let lastTransportError { throw lastTransportError }
        throw AppleStremioPlaybackError.invalidPayload
    }

    private static func endpoint(
        source: AppleSource,
        resource: String,
        type: String,
        mediaID: String
    ) throws -> URL {
        let cleanType = type.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanID = mediaID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanType.isEmpty,
              cleanType.utf8.count <= 64,
              !cleanID.isEmpty,
              cleanID.utf8.count <= 512 else {
            throw AppleStremioPlaybackError.invalidMediaIdentity
        }

        let baseURL = source.transportURL
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              components.host?.isEmpty == false,
              components.scheme?.lowercased() == "https"
                || (components.scheme?.lowercased() == "http"
                    && components.host.map(AppleManifestURLPolicy.isLoopbackHost) == true),
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            throw AppleStremioPlaybackError.invalidSource
        }

        let basePath = components.percentEncodedPath
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let suffix = [
            resource,
            percentEncodedPathSegment(cleanType),
            "\(percentEncodedPathSegment(cleanID)).json",
        ].joined(separator: "/")
        components.percentEncodedPath = basePath.isEmpty ? "/\(suffix)" : "/\(basePath)/\(suffix)"
        guard let endpoint = components.url else { throw AppleStremioPlaybackError.invalidSource }
        return endpoint
    }

    private static func percentEncodedPathSegment(_ value: String) -> String {
        value.utf8.map { byte in
            switch byte {
            case 48 ... 57, 65 ... 90, 97 ... 122, 45, 95, 126:
                String(UnicodeScalar(byte))
            default:
                String(format: "%%%02X", byte)
            }
        }.joined()
    }

    private static func cleanLabel(_ value: String?, maximumLength: Int = 120) -> String? {
        guard let value else { return nil }
        var cleaned = String.UnicodeScalarView()
        cleaned.reserveCapacity(maximumLength)
        for scalar in value.unicodeScalars.prefix(maximumLength) {
            cleaned.append(CharacterSet.controlCharacters.contains(scalar) ? " " : scalar)
        }
        let result = String(cleaned)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return nil }
        return result
    }

    private static func cleanFilename(_ value: String?) -> String? {
        cleanLabel(value, maximumLength: 240)
    }

    private static func safeProxyHeaders(_ values: [String: String]?) -> [String: String] {
        guard let values else { return [:] }
        let allowed = Set(["user-agent", "referer", "origin", "cookie", "authorization"])
        return Dictionary(uniqueKeysWithValues: values.prefix(16).compactMap { name, value in
            let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard allowed.contains(cleanName.lowercased()),
                  !cleanValue.isEmpty,
                  cleanValue.utf8.count <= 2_048,
                  !cleanValue.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                return nil
            }
            return (cleanName, cleanValue)
        })
    }

    private static func safeHTTPURL(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= 8_192,
              !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil else { return nil }
        return components.url
    }

    private static func safeExternalURL(_ value: String?) -> URL? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= 2_048,
              !trimmed.unicodeScalars.contains(where: { $0.value <= 31 || $0.value == 127 }),
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              ["https", "http", "stremio"].contains(scheme),
              components.user == nil,
              components.password == nil else { return nil }
        if scheme == "https" || scheme == "http" {
            guard components.host?.isEmpty == false else { return nil }
        }
        return components.url
    }

    private static func validInfoHash(_ value: String?) -> String? {
        guard let candidate = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              candidate.utf8.count == 40 || candidate.utf8.count == 32 else { return nil }
        let bytes = candidate.utf8
        if bytes.count == 40,
           bytes.allSatisfy({ (48 ... 57).contains($0) || (65 ... 70).contains($0) || (97 ... 102).contains($0) }) {
            return candidate.lowercased()
        }
        if bytes.count == 32,
           bytes.allSatisfy({ (65 ... 90).contains($0) || (97 ... 122).contains($0) || (50 ... 55).contains($0) }) {
            return candidate.uppercased()
        }
        return nil
    }

    private static func validYouTubeID(_ value: String?) -> String? {
        guard let candidate = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              (1 ... 128).contains(candidate.utf8.count),
              candidate.utf8.allSatisfy({
                  (48 ... 57).contains($0) || (65 ... 90).contains($0) ||
                      (97 ... 122).contains($0) || $0 == 45 || $0 == 95
              }) else { return nil }
        return candidate
    }

    private static func validFileIndex(_ value: Int?) -> Int? {
        guard let value, (0 ... 100_000).contains(value) else { return nil }
        return value
    }

    private static func safeTorrentSources(_ values: [String]?) -> [String] {
        guard let values else { return [] }
        var seen = Set<String>()
        return values.prefix(64).compactMap { value in
            let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (1 ... 2_048).contains(clean.utf8.count),
                  !clean.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  seen.insert(clean).inserted else {
                return nil
            }
            return clean
        }
    }

    private static func subtitleMimeType(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "vtt": "text/vtt"
        case "ass", "ssa": "text/x-ssa"
        case "ttml": "application/ttml+xml"
        default: "application/x-subrip"
        }
    }

    private static func isRetryable(_ status: Int) -> Bool {
        status == 408 || status == 429 || (500 ... 599).contains(status)
    }

    private static func isSecureAddonEndpoint(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        guard components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil else { return false }
        let scheme = components.scheme?.lowercased()
        return scheme == "https"
            || (scheme == "http" && components.host.map(AppleManifestURLPolicy.isLoopbackHost) == true)
    }

    private static func backoff(for attempt: Int) -> Duration {
        switch attempt {
        case 0: .milliseconds(250)
        case 1: .milliseconds(500)
        default: .seconds(1)
        }
    }

    public static func liveLoader(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await AppleBoundedHTTPDataLoader.load(
                request,
                maximumBytes: maximumResponseBytes,
                redirectPolicy: .secureHTTPOnly
            )
        } catch AppleBoundedHTTPError.responseTooLarge {
            throw AppleStremioPlaybackError.responseTooLarge
        }
    }

    public static func liveSleeper(_ duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

private struct AppleStremioLossy<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

private struct StreamEnvelope: Decodable {
    let streams: [AppleStremioLossy<RawStream>]

    private enum CodingKeys: String, CodingKey { case streams }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        streams = (try? container.decode([AppleStremioLossy<RawStream>].self, forKey: .streams)) ?? []
    }
}

private struct RawStream: Decodable {
    struct BehaviorHints: Decodable {
        let filename: String?
        let videoSize: Int64?
        let notWebReady: Bool?
        let proxyHeaders: ProxyHeaders?

        struct ProxyHeaders: Decodable {
            let request: [String: String]?
        }

        private enum CodingKeys: String, CodingKey { case filename, videoSize, notWebReady, proxyHeaders }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            videoSize = try? container.decode(Int64.self, forKey: .videoSize)
            filename = try? container.decode(String.self, forKey: .filename)
            notWebReady = try? container.decode(Bool.self, forKey: .notWebReady)
            proxyHeaders = try? container.decode(ProxyHeaders.self, forKey: .proxyHeaders)
        }
    }

    let title: String?
    let name: String?
    let url: String?
    let externalURL: String?
    let youtubeID: String?
    let infoHash: String?
    let fileIndex: Int?
    let sources: [String]?
    let behaviorHints: BehaviorHints?

    private enum CodingKeys: String, CodingKey {
        case title, name, url, externalURL = "externalUrl", youtubeID = "ytId", infoHash
        case fileIndex = "fileIdx", sources
        case behaviorHints
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try? container.decode(String.self, forKey: .title)
        name = try? container.decode(String.self, forKey: .name)
        url = try? container.decode(String.self, forKey: .url)
        externalURL = try? container.decode(String.self, forKey: .externalURL)
        youtubeID = try? container.decode(String.self, forKey: .youtubeID)
        infoHash = try? container.decode(String.self, forKey: .infoHash)
        fileIndex = try? container.decode(Int.self, forKey: .fileIndex)
        sources = try? container.decode([String].self, forKey: .sources)
        behaviorHints = try? container.decode(BehaviorHints.self, forKey: .behaviorHints)
    }
}

private struct SubtitleEnvelope: Decodable {
    let subtitles: [AppleStremioLossy<RawSubtitle>]

    private enum CodingKeys: String, CodingKey { case subtitles }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        subtitles = (try? container.decode([AppleStremioLossy<RawSubtitle>].self, forKey: .subtitles)) ?? []
    }
}

private struct RawSubtitle: Decodable {
    let id: String?
    let url: String?
    let language: String?

    private enum CodingKeys: String, CodingKey { case id, url, language = "lang" }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try? container.decode(String.self, forKey: .id)
        url = try? container.decode(String.self, forKey: .url)
        language = try? container.decode(String.self, forKey: .language)
    }
}
