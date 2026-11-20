import Foundation

/// A trailer the user's own Plex, Jellyfin or Emby server has for a title:
/// a Plex extra (its local trailers and the Plex Pass ones it fetches), a
/// Jellyfin/Emby local trailer, or a remote trailer link that is a video
/// file. `url` may carry the server's token, so it stays in memory: never
/// in a log, the trace or a saved file. The Top Shelf gets a downloaded copy
/// instead (`AppleTopShelfTrailerFiles`).
public struct AppleServerTrailer: Equatable, Sendable {
    public let url: URL
    public let title: String
    public let durationSeconds: Double?
    /// The server sends the file as stored, not a conversion: only a file
    /// can be saved for the Top Shelf.
    public let isFile: Bool
}

/// How a server trailer reaches AVPlayer: the file itself when AVPlayer can
/// open it, otherwise the server's own conversion (Jellyfin and Emby through
/// PlaybackInfo, as normal playback does; Plex through its HLS transcoder).
enum AppleServerTrailerStreamPolicy {
    static let fileContainers: Set<String> = ["mp4", "m4v", "mov"]

    static func playsAsFile(container: String?) -> Bool {
        guard let first = container?.split(separator: ",").first else { return false }
        return fileContainers.contains(first.trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// A server-relative path that may carry the session token: a path on
    /// the server itself, no `..`, and no credential of its own.
    static func isServerPath(_ key: String) -> Bool {
        guard key.hasPrefix("/"), !key.hasPrefix("//"),
              let components = URLComponents(string: key), components.scheme == nil, components.host == nil,
              components.fragment == nil, !components.path.split(separator: "/").contains("..") else { return false }
        return !(components.queryItems ?? []).contains {
            ["x-plex-token", "token", "access_token", "api_key"].contains($0.name.lowercased())
        }
    }

    /// A remote trailer link AVPlayer can open itself: an http(s) video file
    /// or HLS playlist. Web pages (YouTube and the like) are not.
    static func remoteTrailer(_ link: AppleMediaServerItem.RemoteTrailer) -> AppleServerTrailer? {
        guard let url = URL(string: link.url), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.isEmpty == false else { return nil }
        let ext = url.pathExtension.lowercased()
        guard fileContainers.contains(ext) || ext == "m3u8" else { return nil }
        return AppleServerTrailer(url: url, title: link.name ?? "Trailer", durationSeconds: nil, isFile: ext != "m3u8")
    }
}

/// Which trailer a hero plays and where: the server's file first, then
/// YouTube where a web view can show it. The Apple TV has no WebKit, so it
/// plays a server trailer or none.
public enum AppleTrailerSourcePolicy {
    public enum Source: Equatable, Sendable {
        case server(AppleServerTrailer)
        case youTube
    }

    public static func offersYouTube(on platform: AppleUIPlatform = .current) -> Bool {
        platform != .tvOS
    }

    public static func looksUpServer(on platform: AppleUIPlatform = .current) -> Bool {
        platform != .macOS
    }

    /// Nil while the server lookup is out (YouTube must not start under a
    /// server trailer about to arrive) and where nothing can play.
    public static func heroSource(server: AppleServerTrailer?, serverLookedUp: Bool,
                                  on platform: AppleUIPlatform = .current) -> Source? {
        guard looksUpServer(on: platform) else { return .youTube }
        if let server { return .server(server) }
        return serverLookedUp && offersYouTube(on: platform) ? .youTube : nil
    }
}

/// What a title is known by, to find it on a server it did not come from.
public struct AppleServerTrailerQuery: Hashable, Sendable {
    public let mediaID: String
    public let title: String
    public let year: Int?
    public let isSeries: Bool
    public let imdbID: String?
    public let tmdbID: String?

    public init(mediaID: String, title: String, year: Int?, isSeries: Bool, imdbID: String? = nil, tmdbID: String? = nil) {
        self.mediaID = mediaID
        self.title = title
        self.year = year
        self.isSeries = isSeries
        self.imdbID = imdbID
        self.tmdbID = tmdbID
    }

    /// A catalog title's ids: IMDb from a `tt…` id (an episode's
    /// series), TMDB from a `tmdb:` id.
    public init(item: AppleCatalogItem) {
        let imdb = AppleMediaIdentifier.canonicalMediaID(item.mediaID)?
            .split(separator: ":").first.map(String.init)
        let parts = item.mediaID.split(separator: ":")
        let tmdb = parts.count >= 2 && parts[0] == "tmdb" && parts[1].allSatisfy(\.isNumber) ? String(parts[1]) : nil
        self.init(mediaID: item.mediaID, title: item.name, year: item.year, isSeries: item.type == "series",
                  imdbID: imdb, tmdbID: tmdb)
    }
}

/// Picks the server's copy of a title among its search results: the same
/// IMDb or TMDB id, else the same title and year with no id that disagrees.
/// A title alone is never enough — two films share a name too often.
enum AppleServerTrailerMatch {
    struct Candidate: Equatable, Sendable {
        let id: String
        let title: String
        let year: Int?
        let imdbID: String?
        let tmdbID: String?
    }

    static func best(_ candidates: [Candidate], for query: AppleServerTrailerQuery) -> Candidate? {
        if let imdb = query.imdbID, let match = candidates.first(where: { $0.imdbID == imdb }) { return match }
        if let tmdb = query.tmdbID, let match = candidates.first(where: { $0.tmdbID == tmdb }) { return match }
        guard let year = query.year else { return nil }
        let title = normalized(query.title)
        return candidates.first {
            normalized($0.title) == title && $0.year == year
                && agrees($0.imdbID, query.imdbID) && agrees($0.tmdbID, query.tmdbID)
        }
    }

    /// A title and year match is another film when both sides name an id and they differ.
    private static func agrees(_ candidate: String?, _ query: String?) -> Bool {
        candidate == nil || query == nil || candidate == query
    }

    static func normalized(_ title: String) -> String {
        title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }
}

// MARK: - Plex

/// One entry of `/library/metadata/<ratingKey>/extras`.
struct ApplePlexExtra: Decodable, Sendable {
    struct Media: Decodable, Sendable {
        let container: String?
        let bitrate: Int?
        let parts: [ApplePlexItem.Part]

        private enum CodingKeys: String, CodingKey { case container, bitrate, parts = "Part" }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            container = try values.decodeIfPresent(String.self, forKey: .container)
            bitrate = try values.decodeIfPresent(Int.self, forKey: .bitrate)
            parts = try values.decodeIfPresent([ApplePlexItem.Part].self, forKey: .parts) ?? []
        }
    }

    let ratingKey: String
    let title: String
    let subtype: String?
    let extraType: Int?
    let durationSeconds: Double?
    let media: [Media]

    /// Plex's extra type 1 is a trailer.
    var isTrailer: Bool { extraType == 1 || subtype == "trailer" }

    /// The best copy Plex lists: the highest bitrate.
    var bestMedia: Media? {
        media.filter { !$0.parts.isEmpty }.max { ($0.bitrate ?? 0) < ($1.bitrate ?? 0) }
    }

    private enum CodingKeys: String, CodingKey { case ratingKey, title, subtype, extraType, duration, media = "Media" }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        ratingKey = try values.decode(String.self, forKey: .ratingKey)
        title = try values.decodeIfPresent(String.self, forKey: .title) ?? ""
        subtype = try values.decodeIfPresent(String.self, forKey: .subtype)
        extraType = try values.decodeIfPresent(Int.self, forKey: .extraType)
        durationSeconds = try values.decodeIfPresent(Double.self, forKey: .duration).map { $0 / 1000 }
        media = try values.decodeIfPresent([Media].self, forKey: .media) ?? []
    }
}

extension ApplePlexClient {
    private struct ExtrasResponse: Decodable {
        struct Container: Decodable { let Metadata: [ApplePlexExtra]? }
        let MediaContainer: Container
    }

    private struct SearchResponse: Decodable {
        struct Container: Decodable { let Hub: [ApplePlexHub]? }
        let MediaContainer: Container
    }

    /// The title's trailers, best first, as AVPlayer can open them.
    func trailers(session: AppleMediaServerSession, ratingKey: String) async throws -> [AppleServerTrailer] {
        let url = session.baseURL.appendingPathComponent("library/metadata/\(ratingKey)/extras")
        let data = try await performRequest(url: url, token: session.accessToken, timeout: 15)
        let extras = try JSONDecoder().decode(ExtrasResponse.self, from: data).MediaContainer.Metadata ?? []
        return extras.filter(\.isTrailer).compactMap { trailer(for: $0, session: session) }
    }

    func trailer(for extra: ApplePlexExtra, session: AppleMediaServerSession) -> AppleServerTrailer? {
        guard let media = extra.bestMedia, let part = media.parts.first,
              AppleServerTrailerStreamPolicy.isServerPath(part.key) else { return nil }
        let isFile = AppleServerTrailerStreamPolicy.playsAsFile(container: part.container ?? media.container)
        let url = isFile ? fileURL(session: session, key: part.key) : transcodeURL(session: session, ratingKey: extra.ratingKey)
        return url.map { AppleServerTrailer(url: $0, title: extra.title, durationSeconds: extra.durationSeconds, isFile: isFile) }
    }

    /// The part's own path and query (a Plex Pass trailer's names its
    /// bitrate), with the token.
    private func fileURL(session: AppleMediaServerSession, key: String) -> URL? {
        guard let keyComponents = URLComponents(string: key),
              var components = URLComponents(url: session.baseURL.appendingPathComponent(String(keyComponents.path.dropFirst())),
                                             resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = (keyComponents.queryItems ?? []) + [URLQueryItem(name: "X-Plex-Token", value: session.accessToken)]
        return components.url
    }

    /// Plex's HLS conversion of an extra AVPlayer cannot open as stored.
    private func transcodeURL(session: AppleMediaServerSession, ratingKey: String) -> URL? {
        var components = URLComponents(url: session.baseURL.appendingPathComponent("video/:/transcode/universal/start.m3u8"),
                                       resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "path", value: "/library/metadata/\(ratingKey)"),
            URLQueryItem(name: "mediaIndex", value: "0"),
            URLQueryItem(name: "partIndex", value: "0"),
            URLQueryItem(name: "protocol", value: "hls"),
            URLQueryItem(name: "directPlay", value: "0"),
            URLQueryItem(name: "directStream", value: "1"),
            URLQueryItem(name: "fastSeek", value: "1"),
            URLQueryItem(name: "subtitles", value: "none"),
            URLQueryItem(name: "session", value: UUID().uuidString),
            URLQueryItem(name: "X-Plex-Client-Identifier", value: clientIdentifier),
            URLQueryItem(name: "X-Plex-Product", value: "oStream"),
            URLQueryItem(name: "X-Plex-Platform", value: platformName),
            URLQueryItem(name: "X-Plex-Token", value: session.accessToken),
        ]
        return components?.url
    }

    /// Movies and shows the server finds for `query`'s title.
    func searchCandidates(session: AppleMediaServerSession, query: AppleServerTrailerQuery) async throws -> [AppleServerTrailerMatch.Candidate] {
        var components = URLComponents(url: session.baseURL.appendingPathComponent("hubs/search"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "query", value: query.title), URLQueryItem(name: "limit", value: "10"),
                                 URLQueryItem(name: "includeGuids", value: "1")]
        let data = try await performRequest(url: components.url!, token: session.accessToken, timeout: 15)
        let wanted: ApplePlexKind = query.isSeries ? .show : .movie
        return (try JSONDecoder().decode(SearchResponse.self, from: data).MediaContainer.Hub ?? [])
            .flatMap(\.items)
            .filter { $0.type == wanted }
            .map { .init(id: $0.ratingKey, title: $0.title, year: $0.year, imdbID: $0.imdbID, tmdbID: $0.tmdbID) }
    }
}

// MARK: - Jellyfin and Emby

/// One entry of a Jellyfin or Emby `LocalTrailers` reply.
struct AppleMediaServerTrailerItem: Decodable, Sendable {
    struct MediaSource: Decodable, Sendable {
        let id: String
        let container: String?
        private enum CodingKeys: String, CodingKey { case id = "Id", container = "Container" }
    }

    let id: String
    let name: String
    let container: String?
    let runtimeSeconds: Double?
    let mediaSources: [MediaSource]

    private enum CodingKeys: String, CodingKey {
        case id = "Id", name = "Name", container = "Container", runTimeTicks = "RunTimeTicks", mediaSources = "MediaSources"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? ""
        container = try values.decodeIfPresent(String.self, forKey: .container)
        runtimeSeconds = try values.decodeIfPresent(Int64.self, forKey: .runTimeTicks).map(AppleMediaServerTicks.seconds(fromTicks:))
        mediaSources = try values.decodeIfPresent([MediaSource].self, forKey: .mediaSources) ?? []
    }
}

extension AppleMediaServerClient {
    /// Jellyfin 10.9 moved the route under `Items`; Emby keeps it under the user.
    func localTrailersURL(session: AppleMediaServerSession, itemID: String) throws -> URL {
        switch session.kind {
        case .jellyfin:
            return try normalizedURL(base: session.baseURL, path: "Items/\(itemID)/LocalTrailers",
                                     queryItems: [URLQueryItem(name: "userId", value: session.userID)])
        case .emby, .plex:
            return try normalizedURL(base: session.baseURL, path: "Users/\(session.userID)/Items/\(itemID)/LocalTrailers")
        }
    }

    /// The item's first local trailer AVPlayer can open, else its first
    /// remote trailer that is a video file (YouTube links play in the web
    /// view from the metadata instead).
    func firstTrailer(session: AppleMediaServerSession, itemID: String) async throws -> AppleServerTrailer? {
        guard !itemID.isEmpty, !itemID.contains("/"), !itemID.contains("..") else { throw AppleMediaServerError.unsupported }
        var req = request(url: try localTrailersURL(session: session, itemID: itemID), token: session.accessToken)
        req.timeoutInterval = 15
        do {
            for item in try JSONDecoder().decode([AppleMediaServerTrailerItem].self, from: try await perform(req)) {
                if let trailer = try? await trailer(for: item, session: session) { return trailer }
            }
        } catch AppleMediaServerError.server, AppleMediaServerError.malformedResponse {
            // A server without the local-trailers route can still list remote ones.
        }
        guard let item = try? await self.item(session: session, id: itemID) else { return nil }
        return item.remoteTrailers.lazy.compactMap(AppleServerTrailerStreamPolicy.remoteTrailer).first
    }

    func trailer(for item: AppleMediaServerTrailerItem, session: AppleMediaServerSession) async throws -> AppleServerTrailer {
        let source = item.mediaSources.first
        let container = source?.container ?? item.container
        if AppleServerTrailerStreamPolicy.playsAsFile(container: container) {
            let url = try directStreamURL(session: session, itemID: item.id, mediaSourceID: source?.id ?? item.id,
                                          container: container?.split(separator: ",").first.map(String.init))
            return AppleServerTrailer(url: url, title: item.name, durationSeconds: item.runtimeSeconds, isFile: true)
        }
        let info = try await playbackInfo(session: session, itemID: item.id, forceConversion: true)
        guard let path = AppleJellyfinPlaybackPolicy.select(info.mediaSources, failed: [])?.transcodingURLPath else {
            throw AppleMediaServerError.unsupported
        }
        let url = try AppleJellyfinPlaybackPolicy.conversionURL(path, session: session)
        return AppleServerTrailer(url: url, title: item.name, durationSeconds: item.runtimeSeconds, isFile: false)
    }

    /// Movies and series the server finds for `query`'s title.
    func searchCandidates(session: AppleMediaServerSession, query: AppleServerTrailerQuery) async throws -> [AppleServerTrailerMatch.Candidate] {
        let url = try normalizedURL(base: session.baseURL, path: "Users/\(session.userID)/Items", queryItems: [
            URLQueryItem(name: "SearchTerm", value: query.title),
            URLQueryItem(name: "IncludeItemTypes", value: query.isSeries ? "Series" : "Movie"),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "Fields", value: "ProviderIds,ProductionYear"),
            URLQueryItem(name: "Limit", value: "10"),
        ])
        var req = request(url: url, token: session.accessToken)
        req.timeoutInterval = 15
        let page = try JSONDecoder().decode(AppleMediaServerItemPage.self, from: try await perform(req))
        return page.items.map { .init(id: $0.id, title: $0.name, year: $0.year, imdbID: $0.imdbID, tmdbID: $0.tmdbID) }
    }
}
