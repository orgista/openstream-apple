import Foundation

public enum AppleArrKind: String, CaseIterable, Sendable {
    case radarr
    case sonarr

    public var displayName: String {
        switch self {
        case .radarr: "Radarr"
        case .sonarr: "Sonarr"
        }
    }
}

public enum AppleArrEndpointPolicy {
    public static func normalize(_ value: String) throws -> URL {
        guard value.utf8.count <= 2_048 else {
            throw AppleArrClientError.invalidEndpoint
        }
        do {
            return try AppleGatewayEndpointPolicy.normalize(value)
        } catch {
            throw AppleArrClientError.invalidEndpoint
        }
    }

    public static func isAllowed(_ value: String) -> Bool {
        (try? normalize(value)) != nil
    }
}

public struct AppleArrStatus: Equatable, Sendable {
    public let appName: String
    public let version: String
    public let instanceName: String

    public init(appName: String, version: String, instanceName: String) {
        self.appName = appName
        self.version = version
        self.instanceName = instanceName
    }
}

public struct AppleArrRootFolder: Identifiable, Equatable, Sendable {
    public let id: Int
    public let path: String
    public let freeSpace: Int64?
}

public struct AppleArrQualityProfile: Identifiable, Equatable, Sendable {
    public let id: Int
    public let name: String
}

public struct AppleArrQueueOptions: Equatable, Sendable {
    public let rootFolders: [AppleArrRootFolder]
    public let qualityProfiles: [AppleArrQualityProfile]
}

public enum AppleArrEnqueueOutcome: Equatable, Sendable {
    case enqueued
    case alreadyPresent
}

public enum AppleArrFallbackPolicy {
    public typealias Attempt<Value: Sendable> = () async throws -> Value

    public static func firstSuccessful<Value: Sendable>(
        _ attempts: [Attempt<Value>]
    ) async throws -> Value {
        var lastError: (any Error)?
        for attempt in attempts {
            do {
                return try await attempt()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError ?? AppleArrClientError.invalidQueueConfiguration
    }
}

public struct AppleArrLibraryRecord: Identifiable, Equatable, Sendable {
    public let id: String
    public let kind: AppleMediaKind
    public let canonicalID: String?
    public let title: String
    public let year: Int?
    public let summary: String?
    public let artworkURL: URL?
    public let hasFile: Bool

    public init(
        id: String,
        kind: AppleMediaKind,
        canonicalID: String?,
        title: String,
        year: Int?,
        summary: String?,
        artworkURL: URL?,
        hasFile: Bool
    ) {
        self.id = ApplePlaybackIdentity.digest(for: id)
        self.kind = kind
        self.canonicalID = canonicalID
        self.title = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        self.year = year
        self.summary = summary.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4_000)) }
        self.artworkURL = artworkURL
        self.hasFile = hasFile
    }
}

public enum AppleArrInstanceIdentity {
    public static func id(kind: AppleArrKind, baseURL: String) -> UUID? {
        guard let normalized = try? AppleArrEndpointPolicy.normalize(baseURL) else { return nil }
        let digest = ApplePlaybackIdentity.digest(for: "arr|\(kind.rawValue)|\(normalized.absoluteString)")
        let raw = String(digest.prefix(32))
        let value = "\(raw.prefix(8))-\(raw.dropFirst(8).prefix(4))-\(raw.dropFirst(12).prefix(4))-\(raw.dropFirst(16).prefix(4))-\(raw.dropFirst(20).prefix(12))"
        return UUID(uuidString: value)
    }
}

public enum AppleArrClientError: Swift.Error, Equatable, LocalizedError, Sendable {
    case invalidEndpoint
    case invalidAPIKey
    case nonHTTPResponse
    case redirected
    case responseTooLarge
    case requestFailed(Int)
    case invalidQueueConfiguration
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            "Use HTTPS, or HTTP with a private local IP address."
        case .invalidAPIKey:
            "Enter a valid API key."
        case .nonHTTPResponse:
            "The server returned an invalid response."
        case .redirected:
            "The server redirected the connection."
        case .responseTooLarge:
            "The server response is too large."
        case .requestFailed(let status):
            "Connection failed with HTTP \(status)."
        case .invalidQueueConfiguration:
            "Set a root folder and quality profile before adding downloads."
        case .invalidResponse:
            "The server returned invalid status data."
        }
    }
}

public struct AppleArrClient: Sendable {
    public typealias Loader = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public static let maximumResponseBytes = 512 * 1_024
    public static let maximumLibraryResponseBytes = 8 * 1_024 * 1_024
    public static let maximumLibraryItems = 10_000

    private let loader: Loader

    public init(loader: @escaping Loader = AppleArrClient.liveLoader) {
        self.loader = loader
    }

    public static func isValidAPIKey(_ value: String) -> Bool {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return (1 ... 4_096).contains(key.utf8.count) &&
            key.unicodeScalars.allSatisfy { scalar in
                scalar.value >= 0x20 && scalar.value != 0x7F
            }
    }

    public func test(kind: AppleArrKind, baseURL: String, apiKey: String) async throws -> AppleArrStatus {
        let base = try AppleArrEndpointPolicy.normalize(baseURL)
        let key = try normalizedAPIKey(apiKey)
        let endpoint = base.appending(path: "api/v3/system/status")

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(key, forHTTPHeaderField: "X-Api-Key")
        request.setValue("OpenStream/1.0 Apple", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await loader(request)
        guard data.count <= Self.maximumResponseBytes else {
            throw AppleArrClientError.responseTooLarge
        }
        guard let http = response as? HTTPURLResponse else {
            throw AppleArrClientError.nonHTTPResponse
        }
        if (300 ... 399).contains(http.statusCode) || http.url != endpoint {
            throw AppleArrClientError.redirected
        }
        if http.expectedContentLength > Int64(Self.maximumResponseBytes) {
            throw AppleArrClientError.responseTooLarge
        }
        guard (200 ... 299).contains(http.statusCode) else {
            throw AppleArrClientError.requestFailed(http.statusCode)
        }

        struct Payload: Decodable {
            let appName: String?
            let version: String?
            let instanceName: String?
        }

        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            throw AppleArrClientError.invalidResponse
        }
        return AppleArrStatus(
            appName: bounded(payload.appName, limit: 80, fallback: kind.displayName),
            version: bounded(payload.version, limit: 40),
            instanceName: bounded(payload.instanceName, limit: 80)
        )
    }

    public func library(kind: AppleArrKind, baseURL: String, apiKey: String) async throws -> [AppleArrLibraryRecord] {
        let base = try AppleArrEndpointPolicy.normalize(baseURL)
        let key = try normalizedAPIKey(apiKey)
        let endpoint = base.appending(path: kind == .radarr ? "api/v3/movie" : "api/v3/series")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(key, forHTTPHeaderField: "X-Api-Key")
        request.setValue("OpenStream/1.0 Apple", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await loader(request)
        guard data.count <= Self.maximumLibraryResponseBytes else { throw AppleArrClientError.responseTooLarge }
        guard let http = response as? HTTPURLResponse else { throw AppleArrClientError.nonHTTPResponse }
        if (300 ... 399).contains(http.statusCode) || http.url != endpoint { throw AppleArrClientError.redirected }
        guard (200 ... 299).contains(http.statusCode) else { throw AppleArrClientError.requestFailed(http.statusCode) }

        let values: [LibraryPayload]
        do { values = try JSONDecoder().decode([LibraryPayload].self, from: data) }
        catch { throw AppleArrClientError.invalidResponse }
        return values.prefix(Self.maximumLibraryItems).compactMap { payload in
            guard let sourceID = payload.id, sourceID > 0,
                  let title = payload.title?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty else { return nil }
            let canonical = payload.imdbID?.nonEmptyArrString
                ?? payload.tmdbID.map { "tmdb:\($0)" }
                ?? payload.tvdbID.map { "tvdb:\($0)" }
            let artwork = payload.images?.compactMap(\.remoteURL).compactMap(URL.init(string:)).first {
                $0.scheme?.lowercased() == "https" && $0.user == nil && $0.password == nil
            }
            let hasFile = payload.hasFile
                ?? ((payload.statistics?.episodeFileCount ?? 0) > 0)
            return AppleArrLibraryRecord(
                id: "\(kind.rawValue)|\(normalizedID(base))|\(sourceID)",
                kind: kind == .radarr ? .movie : .series,
                canonicalID: canonical,
                title: title,
                year: payload.year,
                summary: payload.overview,
                artworkURL: artwork,
                hasFile: hasFile
            )
        }
    }

    public func exactMatch(
        kind: AppleArrKind,
        baseURL: String,
        apiKey: String,
        title: String,
        year: Int?
    ) async throws -> AppleArrLibraryRecord? {
        let values = try await library(kind: kind, baseURL: baseURL, apiKey: apiKey)
        return Self.exactMatch(title: title, year: year, in: values)
    }

    public static func exactMatch(
        title: String,
        year: Int?,
        in values: [AppleArrLibraryRecord]
    ) -> AppleArrLibraryRecord? {
        let expectedTitle = normalizedTitle(title)
        guard !expectedTitle.isEmpty else { return nil }
        return values.first { value in
            normalizedTitle(value.title) == expectedTitle && (year == nil || value.year == year)
        }
    }

    public func queueOptions(
        kind: AppleArrKind,
        baseURL: String,
        apiKey: String
    ) async throws -> AppleArrQueueOptions {
        let base = try AppleArrEndpointPolicy.normalize(baseURL)
        let key = try normalizedAPIKey(apiKey)
        let rootData = try await loadJSON(
            endpoint: base.appending(path: "api/v3/rootfolder"),
            apiKey: key
        )
        let profileData = try await loadJSON(
            endpoint: base.appending(path: "api/v3/qualityprofile"),
            apiKey: key
        )

        let rootPayloads: [RootFolderPayload]
        let profilePayloads: [QualityProfilePayload]
        do {
            rootPayloads = try JSONDecoder().decode([RootFolderPayload].self, from: rootData)
            profilePayloads = try JSONDecoder().decode([QualityProfilePayload].self, from: profileData)
        } catch {
            throw AppleArrClientError.invalidResponse
        }

        let roots = rootPayloads.compactMap { payload -> AppleArrRootFolder? in
            guard let id = payload.id, id > 0,
                  let path = payload.path?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !path.isEmpty else { return nil }
            return AppleArrRootFolder(id: id, path: String(path.prefix(2_048)), freeSpace: payload.freeSpace)
        }
        let profiles = profilePayloads.compactMap { payload -> AppleArrQualityProfile? in
            guard let id = payload.id, id > 0,
                  let name = payload.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else { return nil }
            return AppleArrQualityProfile(id: id, name: String(name.prefix(200)))
        }
        return AppleArrQueueOptions(rootFolders: roots, qualityProfiles: profiles)
    }

    public func enqueueIfMissing(
        kind: AppleArrKind,
        baseURL: String,
        apiKey: String,
        title: String,
        year: Int?,
        mediaID: String,
        rootFolderPath: String,
        qualityProfileID: String
    ) async throws -> AppleArrEnqueueOutcome {
        if try await exactMatch(
            kind: kind,
            baseURL: baseURL,
            apiKey: apiKey,
            title: title,
            year: year
        ) != nil {
            return .alreadyPresent
        }
        try await enqueue(
            kind: kind,
            baseURL: baseURL,
            apiKey: apiKey,
            title: title,
            year: year,
            mediaID: mediaID,
            rootFolderPath: rootFolderPath,
            qualityProfileID: qualityProfileID
        )
        return .enqueued
    }

    public func enqueue(
        kind: AppleArrKind,
        baseURL: String,
        apiKey: String,
        title: String,
        year: Int?,
        mediaID: String,
        rootFolderPath: String,
        qualityProfileID: String
    ) async throws {
        let base = try AppleArrEndpointPolicy.normalize(baseURL)
        let key = try normalizedAPIKey(apiKey)
        let root = rootFolderPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty, root.utf8.count <= 2_048,
              root.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }) else {
            throw AppleArrClientError.invalidQueueConfiguration
        }
        guard let profileID = Int(qualityProfileID.trimmingCharacters(in: .whitespacesAndNewlines)), profileID > 0 else {
            throw AppleArrClientError.invalidQueueConfiguration
        }
        let cleanTitle = bounded(title, limit: 200)
        guard !cleanTitle.isEmpty else { throw AppleArrClientError.invalidQueueConfiguration }

        var payload: [String: Any] = [
            "title": cleanTitle,
            "qualityProfileId": profileID,
            "rootFolderPath": root,
            "monitored": true
        ]
        if let year, (1900 ... 2200).contains(year) { payload["year"] = year }

        let identifierParts = mediaID.split(separator: ":", maxSplits: 1).map(String.init)
        if identifierParts.count == 2, let identifier = Int(identifierParts[1]), identifier > 0 {
            switch (kind, identifierParts[0].lowercased()) {
            case (_, "tmdb"):
                payload["tmdbId"] = identifier
            case (.sonarr, "tvdb"):
                payload["tvdbId"] = identifier
            default:
                break
            }
        } else if kind == .radarr,
                  identifierParts.count == 2,
                  identifierParts[0].lowercased() == "imdb" {
            let imdbID = identifierParts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard (1 ... 32).contains(imdbID.utf8.count),
                  imdbID.hasPrefix("tt"),
                  imdbID.dropFirst(2).allSatisfy(\.isNumber) else {
                throw AppleArrClientError.invalidQueueConfiguration
            }
            payload["imdbId"] = imdbID
        }
        payload["addOptions"] = kind == .radarr
            ? ["searchForMovie": true]
            : ["searchForMissingEpisodes": true, "monitor": "all"]

        guard JSONSerialization.isValidJSONObject(payload) else {
            throw AppleArrClientError.invalidQueueConfiguration
        }
        let endpoint = base.appending(path: kind == .radarr ? "api/v3/movie" : "api/v3/series")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "X-Api-Key")
        request.setValue("OpenStream/1.0 Apple", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await loader(request)
        guard data.count <= Self.maximumResponseBytes else { throw AppleArrClientError.responseTooLarge }
        guard let http = response as? HTTPURLResponse else { throw AppleArrClientError.nonHTTPResponse }
        if (300 ... 399).contains(http.statusCode) || http.url != endpoint { throw AppleArrClientError.redirected }
        if http.expectedContentLength > Int64(Self.maximumResponseBytes) { throw AppleArrClientError.responseTooLarge }
        guard (200 ... 299).contains(http.statusCode) else { throw AppleArrClientError.requestFailed(http.statusCode) }
    }

    public static func liveLoader(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let isLibraryRequest = request.url?.path.hasSuffix("/api/v3/movie") == true
            || request.url?.path.hasSuffix("/api/v3/series") == true
        let responseLimit = isLibraryRequest ? maximumLibraryResponseBytes : maximumResponseBytes
        do {
            return try await AppleBoundedHTTPDataLoader.load(
                request,
                maximumBytes: responseLimit,
                redirectPolicy: .reject
            )
        } catch AppleBoundedHTTPError.responseTooLarge {
            throw AppleArrClientError.responseTooLarge
        }
    }

    private func normalizedAPIKey(_ value: String) throws -> String {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidAPIKey(key) else {
            throw AppleArrClientError.invalidAPIKey
        }
        return key
    }

    private func loadJSON(endpoint: URL, apiKey: String) async throws -> Data {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        request.setValue("OpenStream/1.0 Apple", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await loader(request)
        guard data.count <= Self.maximumResponseBytes else { throw AppleArrClientError.responseTooLarge }
        guard let http = response as? HTTPURLResponse else { throw AppleArrClientError.nonHTTPResponse }
        if (300 ... 399).contains(http.statusCode) || http.url != endpoint {
            throw AppleArrClientError.redirected
        }
        if http.expectedContentLength > Int64(Self.maximumResponseBytes) {
            throw AppleArrClientError.responseTooLarge
        }
        guard (200 ... 299).contains(http.statusCode) else {
            throw AppleArrClientError.requestFailed(http.statusCode)
        }
        return data
    }

    private func bounded(_ value: String?, limit: Int, fallback: String = "") -> String {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !normalized.isEmpty else { return fallback }
        return String(normalized.prefix(limit))
    }

    private func normalizedID(_ url: URL) -> String {
        ApplePlaybackIdentity.digest(for: url.absoluteString)
    }

    private static func normalizedTitle(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private struct RootFolderPayload: Decodable {
        let id: Int?
        let path: String?
        let freeSpace: Int64?
    }

    private struct QualityProfilePayload: Decodable {
        let id: Int?
        let name: String?
    }

    private struct LibraryPayload: Decodable {
        struct Image: Decodable {
            let remoteURL: String?
            private enum CodingKeys: String, CodingKey { case remoteURL = "remoteUrl" }
        }
        struct Statistics: Decodable { let episodeFileCount: Int? }
        let id: Int?
        let title: String?
        let year: Int?
        let overview: String?
        let imdbID: String?
        let tmdbID: Int?
        let tvdbID: Int?
        let hasFile: Bool?
        let images: [Image]?
        let statistics: Statistics?

        private enum CodingKeys: String, CodingKey {
            case id, title, year, overview, images, statistics
            case imdbID = "imdbId"
            case tmdbID = "tmdbId"
            case tvdbID = "tvdbId"
            case hasFile
        }
    }
}

private extension String {
    var nonEmptyArrString: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : String(value.prefix(200))
    }
}
