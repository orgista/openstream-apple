import Foundation

public struct ApplePlexPIN: Codable, Equatable, Sendable {
    public let id: Int
    public let code: String
    public let expiresAt: Date?
    public let authToken: String?
}

public struct ApplePlexAccount: Codable, Equatable, Sendable {
    public let id: Int
    public let username: String?
    public let email: String?
    public let title: String?
}

public struct ApplePlexConnection: Codable, Equatable, Sendable {
    public let uri: String
    public let `protocol`: String
    public let address: String
    public let port: Int
    public let local: Bool
    public let relay: Bool
}

public struct ApplePlexResource: Codable, Equatable, Sendable {
    public let name: String
    public let clientIdentifier: String
    public let provides: String
    public let accessToken: String?
    public let owned: Bool
    public let connections: [ApplePlexConnection]
    
    public var isServer: Bool {
        provides.split(separator: ",").contains("server")
    }
}

public enum ApplePlexKind: String, Codable, Equatable, Sendable {
    case movie
    case show
    case season
    case episode
    case other
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let rawValue = try? container.decode(String.self) {
            self = ApplePlexKind(rawValue: rawValue) ?? .other
        } else {
            self = .other
        }
    }
}

public struct ApplePlexSection: Codable, Equatable, Sendable {
    public let key: String
    public let title: String
    public let type: ApplePlexKind
}

public struct ApplePlexPage: Codable, Equatable, Sendable {
    public let items: [ApplePlexItem]
    public let totalSize: Int
}

public struct ApplePlexItem: Codable, Equatable, Sendable {
    public let ratingKey: String
    public let key: String
    public let type: ApplePlexKind
    public let title: String
    public let year: Int?
    public let summary: String?
    public let thumbPath: String?
    public let artPath: String?
    public let durationSeconds: Double?
    public let viewOffsetSeconds: Double?
    public let viewCount: Int?
    public let lastViewedAt: Date?
    public let parentRatingKey: String?
    public let grandparentRatingKey: String?
    public let grandparentTitle: String?
    public let index: Int?
    public let parentIndex: Int?
    public let guids: [String]
    public let parts: [Part]

    public struct Part: Codable, Equatable, Sendable {
        public let key: String
        public let container: String?
        public let file: String?
    }

    private enum CodingKeys: String, CodingKey {
        case ratingKey, key, type, title, year, summary
        case thumbPath = "thumb"
        case artPath = "art"
        case durationMs = "duration"
        case viewOffsetMs = "viewOffset"
        case viewCount
        case lastViewedAt
        case parentRatingKey, grandparentRatingKey, grandparentTitle
        case index, parentIndex
        case guids = "Guid"
        case media = "Media"
    }

    private struct GuidWrapper: Codable {
        let id: String
    }
    
    private struct MediaWrapper: Codable {
        let parts: [Part]?
        private enum CodingKeys: String, CodingKey { case parts = "Part" }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ratingKey = try container.decode(String.self, forKey: .ratingKey)
        key = try container.decode(String.self, forKey: .key)
        type = try container.decode(ApplePlexKind.self, forKey: .type)
        title = try container.decode(String.self, forKey: .title)
        year = try container.decodeIfPresent(Int.self, forKey: .year)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        thumbPath = try container.decodeIfPresent(String.self, forKey: .thumbPath)
        artPath = try container.decodeIfPresent(String.self, forKey: .artPath)
        
        if let durMs = try container.decodeIfPresent(Double.self, forKey: .durationMs) {
            durationSeconds = durMs / 1000.0
        } else {
            durationSeconds = nil
        }
        
        if let offsetMs = try container.decodeIfPresent(Double.self, forKey: .viewOffsetMs) {
            viewOffsetSeconds = offsetMs / 1000.0
        } else {
            viewOffsetSeconds = nil
        }
        
        viewCount = try container.decodeIfPresent(Int.self, forKey: .viewCount)
        
        if let viewedAtUnix = try container.decodeIfPresent(TimeInterval.self, forKey: .lastViewedAt) {
            lastViewedAt = Date(timeIntervalSince1970: viewedAtUnix)
        } else {
            lastViewedAt = nil
        }
        
        parentRatingKey = try container.decodeIfPresent(String.self, forKey: .parentRatingKey)
        grandparentRatingKey = try container.decodeIfPresent(String.self, forKey: .grandparentRatingKey)
        grandparentTitle = try container.decodeIfPresent(String.self, forKey: .grandparentTitle)
        index = try container.decodeIfPresent(Int.self, forKey: .index)
        
        if let parentIdx = try? container.decodeIfPresent(Int.self, forKey: .parentIndex) {
            parentIndex = parentIdx
        } else if let parentIdxStr = try? container.decodeIfPresent(String.self, forKey: .parentIndex) {
            parentIndex = Int(parentIdxStr)
        } else {
            parentIndex = nil
        }
        
        let guidWrappers = try container.decodeIfPresent([GuidWrapper].self, forKey: .guids) ?? []
        guids = guidWrappers.map { $0.id }
        
        let medias = try container.decodeIfPresent([MediaWrapper].self, forKey: .media) ?? []
        parts = medias.compactMap { $0.parts }.flatMap { $0 }
    }
    
    public func encode(to encoder: Encoder) throws {
        // Not used by requirements, dummy implementation to satisfy Codable
    }
    
    public var tmdbID: String? { guids.first { $0.hasPrefix("tmdb://") }?.replacingOccurrences(of: "tmdb://", with: "") }
    public var imdbID: String? { guids.first { $0.hasPrefix("imdb://") }?.replacingOccurrences(of: "imdb://", with: "") }
    public var tvdbID: String? { guids.first { $0.hasPrefix("tvdb://") }?.replacingOccurrences(of: "tvdb://", with: "") }
}

public struct ApplePlexClient: Sendable {
    private let loader: AppleMediaServerClient.Loader
    private let clientIdentifier: String
    
    private var platformName: String {
        #if os(tvOS)
        return "tvOS"
        #elseif os(visionOS)
        return "visionOS"
        #elseif os(macOS)
        return "macOS"
        #else
        return "iOS"
        #endif
    }
    
    public init(
        loader: @escaping AppleMediaServerClient.Loader = URLSession.shared.data(for:),
        clientIdentifier: String? = nil
    ) {
        self.loader = loader
        if let id = clientIdentifier {
            self.clientIdentifier = id
        } else {
            if let existing = UserDefaults.standard.string(forKey: "openstream.plex.clientIdentifier.v1") {
                self.clientIdentifier = existing
            } else {
                let new = UUID().uuidString
                UserDefaults.standard.set(new, forKey: "openstream.plex.clientIdentifier.v1")
                self.clientIdentifier = new
            }
        }
    }
    
    private func defaultHeaders(token: String? = nil) -> [String: String] {
        var headers: [String: String] = [
            "X-Plex-Client-Identifier": clientIdentifier,
            "X-Plex-Product": "oStream",
            "X-Plex-Version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
            "X-Plex-Platform": platformName,
            "X-Plex-Device-Name": "oStream",
            "Accept": "application/json"
        ]
        if let token = token {
            headers["X-Plex-Token"] = token
        }
        return headers
    }
    
    private func performRequest(url: URL, method: String = "GET", token: String? = nil, headers: [String: String] = [:], timeout: TimeInterval = 60.0) async throws -> Data {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = method
        let defaults = defaultHeaders(token: token)
        for (k, v) in defaults {
            req.setValue(v, forHTTPHeaderField: k)
        }
        for (k, v) in headers {
            req.setValue(v, forHTTPHeaderField: k)
        }
        
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await loader(req)
        } catch {
            throw AppleMediaServerError.unreachable
        }
        
        guard let http = response as? HTTPURLResponse else {
            throw AppleMediaServerError.malformedResponse
        }
        if http.statusCode == 401 {
            throw AppleMediaServerError.invalidCredentials
        }
        guard (200...299).contains(http.statusCode) else {
            throw AppleMediaServerError.server(status: http.statusCode)
        }
        return data
    }
}

extension ApplePlexClient {
    public func requestPIN() async throws -> ApplePlexPIN {
        var comp = URLComponents(string: "https://plex.tv/api/v2/pins")!
        comp.queryItems = [URLQueryItem(name: "strong", value: "false")]
        let data = try await performRequest(url: comp.url!, method: "POST")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ApplePlexPIN.self, from: data)
    }
    
    public func pollPIN(id: Int) async throws -> String? {
        let url = URL(string: "https://plex.tv/api/v2/pins/\(id)")!
        let data = try await performRequest(url: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let pin = try decoder.decode(ApplePlexPIN.self, from: data)
        if let token = pin.authToken, !token.isEmpty {
            return token
        }
        return nil
    }
    
    public func account(token: String) async throws -> ApplePlexAccount {
        let url = URL(string: "https://plex.tv/api/v2/user")!
        let data = try await performRequest(url: url, token: token)
        return try JSONDecoder().decode(ApplePlexAccount.self, from: data)
    }
    
    public func resources(token: String) async throws -> [ApplePlexResource] {
        var comp = URLComponents(string: "https://plex.tv/api/v2/resources")!
        comp.queryItems = [
            URLQueryItem(name: "includeHttps", value: "1"),
            URLQueryItem(name: "includeRelay", value: "1"),
            URLQueryItem(name: "includeIPv6", value: "0")
        ]
        let data = try await performRequest(url: comp.url!, token: token)
        return try JSONDecoder().decode([ApplePlexResource].self, from: data)
    }
    
    public func preferredConnections(for resource: ApplePlexResource) -> [URL] {
        let ordered = resource.connections.sorted { a, b in
            // local https first, then local http, then remote non-relay https, then remote non-relay http, then relay
            func score(_ conn: ApplePlexConnection) -> Int {
                if conn.relay { return 5 }
                if conn.local && conn.protocol == "https" { return 1 }
                if conn.local && conn.protocol == "http" { return 2 }
                if !conn.local && conn.protocol == "https" { return 3 }
                return 4
            }
            return score(a) < score(b)
        }
        var seen = Set<String>()
        var urls = [URL]()
        for conn in ordered {
            if !seen.contains(conn.uri), let url = URL(string: conn.uri) {
                seen.insert(conn.uri)
                urls.append(url)
            }
        }
        return urls
    }
    
    public func firstReachableConnection(for resource: ApplePlexResource, timeout: Duration = .seconds(5)) async -> URL? {
        let urls = preferredConnections(for: resource)
        for url in urls {
            let identityURL = url.appendingPathComponent("identity")
            do {
                _ = try await performRequest(url: identityURL, token: resource.accessToken, timeout: TimeInterval(timeout.components.seconds))
                return url
            } catch {
                continue
            }
        }
        return nil
    }
    
    public func makeSession(resource: ApplePlexResource, connection: URL, account: ApplePlexAccount, accountToken: String) throws -> AppleMediaServerSession {
        guard let token = resource.accessToken else {
            throw AppleMediaServerError.unsupported
        }
        let userName = account.username ?? account.title
        return AppleMediaServerSession(
            kind: .plex,
            baseURL: connection,
            accessToken: token,
            userID: String(account.id),
            serverID: resource.clientIdentifier,
            serverName: resource.name,
            userName: userName,
            accountToken: accountToken
        )
    }
}

extension ApplePlexClient {
    private struct SectionContainer: Decodable {
        let MediaContainer: Container
        struct Container: Decodable {
            let Directory: [ApplePlexSection]?
        }
    }
    
    private struct ItemContainer: Decodable {
        let MediaContainer: Container
        struct Container: Decodable {
            let totalSize: Int?
            let size: Int?
            let Metadata: [ApplePlexItem]?
        }
    }
    
    public func sections(session: AppleMediaServerSession) async throws -> [ApplePlexSection] {
        let url = session.baseURL.appendingPathComponent("library/sections")
        let data = try await performRequest(url: url, token: session.accessToken)
        let container = try JSONDecoder().decode(SectionContainer.self, from: data)
        return container.MediaContainer.Directory ?? []
    }
    
    public func items(session: AppleMediaServerSession, sectionKey: String, kind: ApplePlexKind, start: Int, size: Int) async throws -> ApplePlexPage {
        var comp = URLComponents(url: session.baseURL.appendingPathComponent("library/sections/\(sectionKey)/all"), resolvingAgainstBaseURL: false)!
        let typeStr: String
        if kind == .movie { typeStr = "1" }
        else if kind == .show { typeStr = "2" }
        else { typeStr = "1" } // fallback or handle other
        
        comp.queryItems = [
            URLQueryItem(name: "type", value: typeStr),
            URLQueryItem(name: "includeGuids", value: "1")
        ]
        
        let headers = [
            "X-Plex-Container-Start": String(start),
            "X-Plex-Container-Size": String(size)
        ]
        
        let data = try await performRequest(url: comp.url!, token: session.accessToken, headers: headers)
        let container = try JSONDecoder().decode(ItemContainer.self, from: data).MediaContainer
        let items = container.Metadata ?? []
        return ApplePlexPage(items: items, totalSize: container.totalSize ?? container.size ?? items.count)
    }
    
    public func item(session: AppleMediaServerSession, ratingKey: String) async throws -> ApplePlexItem {
        var comp = URLComponents(url: session.baseURL.appendingPathComponent("library/metadata/\(ratingKey)"), resolvingAgainstBaseURL: false)!
        comp.queryItems = [URLQueryItem(name: "includeGuids", value: "1")]
        let data = try await performRequest(url: comp.url!, token: session.accessToken)
        let container = try JSONDecoder().decode(ItemContainer.self, from: data).MediaContainer
        guard let items = container.Metadata, let first = items.first else {
            throw AppleMediaServerError.malformedResponse
        }
        return first
    }
    
    public func children(session: AppleMediaServerSession, ratingKey: String) async throws -> [ApplePlexItem] {
        let url = session.baseURL.appendingPathComponent("library/metadata/\(ratingKey)/children")
        let data = try await performRequest(url: url, token: session.accessToken)
        return try JSONDecoder().decode(ItemContainer.self, from: data).MediaContainer.Metadata ?? []
    }
    
    public func onDeck(session: AppleMediaServerSession) async throws -> [ApplePlexItem] {
        let url = session.baseURL.appendingPathComponent("library/onDeck")
        let data = try await performRequest(url: url, token: session.accessToken)
        return try JSONDecoder().decode(ItemContainer.self, from: data).MediaContainer.Metadata ?? []
    }
    
    public func recentlyAdded(session: AppleMediaServerSession, sectionKey: String?) async throws -> [ApplePlexItem] {
        let url = session.baseURL.appendingPathComponent("library/recentlyAdded")
        var comp = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        if let sec = sectionKey {
            comp.queryItems = [URLQueryItem(name: "sectionID", value: sec)]
        }
        let data = try await performRequest(url: comp.url!, token: session.accessToken)
        let items = try JSONDecoder().decode(ItemContainer.self, from: data).MediaContainer.Metadata ?? []
        return Array(items.prefix(30))
    }
}

extension ApplePlexClient {
    public func directPlayURL(session: AppleMediaServerSession, part: ApplePlexItem.Part) -> URL {
        var comp = URLComponents(url: session.baseURL.appendingPathComponent(part.key.hasPrefix("/") ? String(part.key.dropFirst()) : part.key), resolvingAgainstBaseURL: false)!
        comp.queryItems = [URLQueryItem(name: "X-Plex-Token", value: session.accessToken)]
        return comp.url!
    }
    
    public func imageURL(session: AppleMediaServerSession, path: String, width: Int, height: Int) -> URL {
        var comp = URLComponents(url: session.baseURL.appendingPathComponent("photo/:/transcode"), resolvingAgainstBaseURL: false)!
        comp.queryItems = [
            URLQueryItem(name: "width", value: String(width)),
            URLQueryItem(name: "height", value: String(height)),
            URLQueryItem(name: "minSize", value: "1"),
            URLQueryItem(name: "upscale", value: "1"),
            URLQueryItem(name: "url", value: path),
            URLQueryItem(name: "X-Plex-Token", value: session.accessToken)
        ]
        return comp.url!
    }
    
    public enum PlaybackState: String {
        case playing
        case paused
        case stopped
    }
    
    public func reportTimeline(session: AppleMediaServerSession, item: ApplePlexItem, state: PlaybackState, positionSeconds: Double) async throws {
        var comp = URLComponents(url: session.baseURL.appendingPathComponent(":/timeline"), resolvingAgainstBaseURL: false)!
        var queryItems = [
            URLQueryItem(name: "ratingKey", value: item.ratingKey),
            URLQueryItem(name: "key", value: item.key),
            URLQueryItem(name: "state", value: state.rawValue),
            URLQueryItem(name: "time", value: String(Int(positionSeconds * 1000))),
            URLQueryItem(name: "identifier", value: "com.plexapp.plugins.library")
        ]
        if let dur = item.durationSeconds {
            queryItems.append(URLQueryItem(name: "duration", value: String(Int(dur * 1000))))
        }
        comp.queryItems = queryItems
        _ = try await performRequest(url: comp.url!, token: session.accessToken)
    }
    
    public func markPlayed(session: AppleMediaServerSession, ratingKey: String) async throws {
        var comp = URLComponents(url: session.baseURL.appendingPathComponent(":/scrobble"), resolvingAgainstBaseURL: false)!
        comp.queryItems = [
            URLQueryItem(name: "key", value: ratingKey),
            URLQueryItem(name: "identifier", value: "com.plexapp.plugins.library")
        ]
        _ = try await performRequest(url: comp.url!, token: session.accessToken)
    }
}


extension ApplePlexClient {
    public func downloadsAllowed(session: AppleMediaServerSession) async throws -> Bool {
        let data = try await performRequest(url: session.baseURL, token: session.accessToken)
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let container = root?["MediaContainer"] as? [String: Any]
        // The server reports the authenticated user's capability. Missing is denied.
        let sync = container?["allowSync"]
        return (sync as? Bool == true) || (sync as? Int == 1) || (sync as? String == "1")
    }

    public func downloadRequest(session: AppleMediaServerSession, part: ApplePlexItem.Part, allowed: Bool) throws -> URLRequest {
        guard allowed else { throw AppleMediaServerError.downloadNotAllowed }
        guard part.key.hasPrefix("/library/parts/"), !part.key.contains(".."),
              let base = URLComponents(url: session.baseURL, resolvingAgainstBaseURL: false),
              var components = URLComponents(url: session.baseURL.appendingPathComponent(String(part.key.dropFirst())), resolvingAgainstBaseURL: false),
              components.host == base.host else { throw AppleMediaServerError.unsupported }
        // download=1 lets PMS enforce download permissions, rather than saving a playback URL.
        components.queryItems = [URLQueryItem(name: "download", value: "1")]
        guard let url = components.url else { throw AppleMediaServerError.unreachable }
        var request = URLRequest(url: url)
        for (key, value) in defaultHeaders(token: session.accessToken) { request.setValue(value, forHTTPHeaderField: key) }
        return request
    }
}
