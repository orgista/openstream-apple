import Foundation

/// Rill's ready-made home rows (`GET /OStream/Feed?v=1`, schema v1 in
/// Rill's `work/2026-11-09/OSTREAM-FEED.md`): services, rows, artwork tags
/// and trailers in one conditional request, instead of the ~90 row requests
/// the store makes to work them out itself. Any answer other than 200 or 304
/// leaves the store on its own rows.
struct AppleOStreamFeed: Codable, Equatable, Sendable {
    static let version = 1
    static let path = "OStream/Feed"
    static let rowPath = "OStream/Feed/Row"
    static let rowPageSize = 20
    /// A server that doesn't answer the feed this fast gets its own rows built.
    static let requestTimeout: TimeInterval = 5

    struct Images: Codable, Equatable, Sendable {
        let poster: String
        let backdrop: String
        let logo: String

        /// Schema v1's templates, for a row page asked for before this launch's feed.
        static let v1 = Images(poster: "/Items/{id}/Images/Primary?tag={tag}",
            backdrop: "/Items/{id}/Images/Backdrop?tag={tag}", logo: "/Items/{id}/Images/Logo?tag={tag}")
    }

    struct Row: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable { case movies, shows, mixed }
        enum Role: String, Codable, Sendable { case top10, featured, service, catalog }
        let id: String
        let title: String
        let kind: Kind
        let role: Role
        let serviceId: String?
        let libraryId: String?
        let items: [Item]
        let next: String?
        var total: Int? = nil
    }

    struct Item: Codable, Equatable, Sendable {
        let id: String
        let type: String
        let title: String
        let year: Int?
        let rating: Double?
        let imdb: String?
        let posterTag: String?
        let backdropTag: String?
        let logoTag: String?
        let trailer: Trailer?
        /// Top 10 position, 1 first.
        var rank: Int? = nil
        var playable: Bool? = nil
    }

    struct Trailer: Codable, Equatable, Sendable {
        let youtube: String?
        let url: URL?
    }

    struct RowPage: Codable, Equatable, Sendable {
        let items: [Item]
        let next: String?
    }

    let v: Int
    let images: Images
    let rows: [Row]
    var titleCount: Int? = nil
}

extension AppleOStreamFeed {
    /// The library shelves the store keeps for one source, in feed order.
    /// Top 10 and Featured rows carry their role in `discoverySort`; a row of
    /// a service the app knows becomes that service's library (Services
    /// strip and service page); any other row is a plain catalog row.
    func shelves(sourceID: UUID, baseURL: URL) -> [(row: Row, shelf: AppleMediaServerLibraryStore.Shelf)] {
        rows.compactMap { row in
            let eligible = row.items.filter { row.role != .top10 && row.role != .featured || $0.playable != false }
            let ordered = row.role == .top10 ? eligible.enumerated().sorted {
                ($0.element.rank ?? .max, $0.offset) < ($1.element.rank ?? .max, $1.offset)
            }.map(\.element) : eligible
            let items = ordered.compactMap { Self.catalogItem($0, images: images, sourceID: sourceID, baseURL: baseURL) }
            guard !items.isEmpty else { return nil }
            let type: AppleMediaServerLibrary.Kind? = switch row.kind {
            case .movies: .movies
            case .shows: .tvshows
            case .mixed: nil
            }
            let sort: AppleMediaServerLibraryStore.Shelf.DiscoverySort = switch row.role {
            case .top10: .top10
            case .featured: .featured
            case .service, .catalog: .other
            }
            let service = row.role == .service ? row.serviceId.flatMap(AppleStreamingService.init(rawValue:)) : nil
            return (row, AppleMediaServerLibraryStore.Shelf(id: Self.shelfID(sourceID: sourceID, row: row), title: row.title,
                sourceID: sourceID, items: items, collectionType: type, discoverySort: sort,
                libraryName: service.map { $0.libraryAliases.first ?? $0.displayName }, totalItemCount: row.total))
        }
    }

    /// Where a row continues (`next`'s `start`; the first page may hold fewer
    /// items than that) and a total that keeps paging while `next` is there.
    static func cursor(start: Int, count: Int, next: String?) -> (offset: Int, total: Int) {
        guard let next else { return (start + count, start + count) }
        let offset = URLComponents(string: next)?.queryItems?.first { $0.name == "start" }?.value.flatMap(Int.init) ?? start + count
        return (max(offset, start + count), max(offset, start + count) + 1)
    }

    static func shelfID(sourceID: UUID, row: Row) -> String {
        "ms:\(sourceID.uuidString.lowercased()):\(row.libraryId ?? row.id):feed"
    }

    func trailers(sourceID: UUID) -> [String: Trailer] {
        var trailers: [String: Trailer] = [:]
        for row in rows {
            for item in row.items {
                guard let trailer = item.trailer else { continue }
                trailers[AppleMediaServerItemReference(sourceID: sourceID, itemID: item.id).mediaID] = trailer
            }
        }
        return trailers
    }

    /// The direct trailer links that play as they are: https only.
    static func directLinks(_ trailers: [String: Trailer]) -> [String: URL] {
        trailers.compactMapValues { $0.url?.scheme?.lowercased() == "https" ? $0.url : nil }
    }

    static func catalogItem(_ item: Item, images: Images, sourceID: UUID, baseURL: URL) -> AppleCatalogItem? {
        let type: String
        switch item.type {
        case "Movie": type = "movie"
        case "Series": type = "series"
        default: return nil
        }
        guard !item.id.isEmpty, !item.title.isEmpty else { return nil }
        func image(_ template: String, _ tag: String?, width: Int) -> URL? {
            guard let tag else { return nil }
            let path = template.replacingOccurrences(of: "{id}", with: item.id).replacingOccurrences(of: "{tag}", with: tag)
            var base = baseURL.absoluteString
            while base.hasSuffix("/") { base.removeLast() }
            guard var components = URLComponents(string: base + (path.hasPrefix("/") ? path : "/" + path)) else { return nil }
            components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "maxWidth", value: String(width))]
            return components.url
        }
        return AppleCatalogItem(
            mediaID: AppleMediaServerItemReference(sourceID: sourceID, itemID: item.id).mediaID, type: type, name: item.title,
            posterURL: image(images.poster, item.posterTag, width: 600),
            backgroundURL: image(images.backdrop, item.backdropTag, width: AppleArtworkSizePolicy.backdropMaximumWidth),
            releaseInfo: item.year.map(String.init), rating: item.rating, year: item.year,
            logoURL: image(images.logo, item.logoTag, width: 600), imdbID: item.imdb)
    }
}

extension AppleMediaServerClient {
    enum OStreamFeedAnswer: Sendable {
        case feed(AppleOStreamFeed, body: Data, etag: String?)
        case notModified
        /// 404 (or a 200 that isn't JSON): the setting is off or the version unknown.
        /// Not asked again this session.
        case off
        /// 503 (being built) or any failure: the store uses its kept copy, or builds its own rows this time.
        case unavailable
    }

    /// The feed, conditional on `etag` (sent back exactly as received, weak or not).
    func oStreamFeed(session: AppleMediaServerSession, etag: String?) async throws -> OStreamFeedAnswer {
        let url = try normalizedURL(base: session.baseURL, path: AppleOStreamFeed.path,
            queryItems: [URLQueryItem(name: "v", value: String(AppleOStreamFeed.version))])
        var feedRequest = request(url: url, token: session.accessToken)
        feedRequest.timeoutInterval = AppleOStreamFeed.requestTimeout
        feedRequest.cachePolicy = .reloadIgnoringLocalCacheData
        if let etag { feedRequest.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        do {
            let (data, response) = try await performResponse(feedRequest)
            // A proxy that serves a web page for every path has no feed, as a 404 says.
            if (try? JSONSerialization.jsonObject(with: data)) == nil { return .off }
            guard let feed = try? JSONDecoder().decode(AppleOStreamFeed.self, from: data),
                  feed.v == AppleOStreamFeed.version else { return .unavailable }
            return .feed(feed, body: data, etag: response.value(forHTTPHeaderField: "ETag"))
        } catch AppleMediaServerError.server(let status) {
            switch status {
            case 304: return etag == nil ? .unavailable : .notModified
            case 404: return .off
            default: return .unavailable
            }
        }
    }

    func oStreamFeedRow(session: AppleMediaServerSession, libraryID: String, start: Int) async throws -> AppleOStreamFeed.RowPage {
        let url = try normalizedURL(base: session.baseURL, path: AppleOStreamFeed.rowPath, queryItems: [
            URLQueryItem(name: "v", value: String(AppleOStreamFeed.version)), URLQueryItem(name: "id", value: libraryID),
            URLQueryItem(name: "start", value: String(start)), URLQueryItem(name: "limit", value: String(AppleOStreamFeed.rowPageSize))])
        let data = try await perform(request(url: url, token: session.accessToken))
        return try JSONDecoder().decode(AppleOStreamFeed.RowPage.self, from: data)
    }
}

/// The last feed each source's signed-in user got, with its ETag, so a launch
/// revalidates with `If-None-Match` and a 304 reuses it. Holds no token and no
/// URL: tags, ids and titles only.
struct AppleOStreamFeedCache: Sendable {
    struct Entry: Codable, Sendable {
        let userID: String
        let etag: String
        let body: Data
    }

    let directory: URL

    init(directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appending(path: "OpenStream", directoryHint: .isDirectory).appending(path: "OStreamFeed", directoryHint: .isDirectory)) {
        self.directory = directory
    }

    private func url(sourceID: UUID) -> URL {
        directory.appending(path: sourceID.uuidString.lowercased() + ".json")
    }

    func entry(sourceID: UUID, userID: String) -> Entry? {
        guard let data = try? Data(contentsOf: url(sourceID: sourceID)),
              let entry = try? JSONDecoder().decode(Entry.self, from: data), entry.userID == userID else { return nil }
        return entry
    }

    func save(_ entry: Entry, sourceID: UUID) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var url = url(sourceID: sourceID)
            try JSONEncoder().encode(entry).write(to: url, options: .atomic)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try url.setResourceValues(values)
        } catch {
            appleTrace("server feed cache write failed: \(appleErrorLabel(error))")
        }
    }

    func remove(sourceID: UUID) {
        try? FileManager.default.removeItem(at: url(sourceID: sourceID))
    }

    /// Deletes the kept feeds of every source not in `sourceIDs` (removed,
    /// signed out or turned off): they hold that user's library listing.
    func retain(sourceIDs: Set<UUID>) {
        let kept = Set(sourceIDs.map { $0.uuidString.lowercased() + ".json" })
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where !kept.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

/// Settings › Sources › server › "Use Rill's rows". On unless the user turned
/// it off; the switch shows once the server has answered the feed.
enum AppleOStreamFeedPreference {
    /// Comma-separated source ids the user turned off (an `@AppStorage` string).
    static let offKey = "openstream.mediaServer.feedOff.v1"
    static let answeredKey = "openstream.mediaServer.feedAnswered.v1"
    /// When a server that never sent the feed last answered 404, per source and
    /// address: a plain Jellyfin server isn't asked again for a day, except by
    /// a pull to refresh.
    static let missingKey = "openstream.mediaServer.feedMissing.v1"
    static let missingLifetime: TimeInterval = 24 * 60 * 60

    static func isOn(_ sourceID: UUID, defaults: UserDefaults = .standard) -> Bool {
        !ids(defaults.string(forKey: offKey)).contains(sourceID.uuidString.lowercased())
    }

    static func setOn(_ on: Bool, sourceID: UUID, defaults: UserDefaults = .standard) {
        var off = ids(defaults.string(forKey: offKey))
        if on { off.remove(sourceID.uuidString.lowercased()) } else { off.insert(sourceID.uuidString.lowercased()) }
        defaults.set(off.sorted().joined(separator: ","), forKey: offKey)
    }

    static func hasAnswered(_ sourceID: UUID, defaults: UserDefaults = .standard) -> Bool {
        defaults.stringArray(forKey: answeredKey)?.contains(sourceID.uuidString.lowercased()) == true
    }

    static func recordAnswered(_ sourceID: UUID, defaults: UserDefaults = .standard) {
        let id = sourceID.uuidString.lowercased()
        var answered = defaults.stringArray(forKey: answeredKey) ?? []
        guard !answered.contains(id) else { return }
        answered.append(id)
        defaults.set(answered, forKey: answeredKey)
    }

    static func isMissing(_ sourceID: UUID, baseURL: URL, now: Date = .now, defaults: UserDefaults = .standard) -> Bool {
        guard let at = (defaults.dictionary(forKey: missingKey) as? [String: Double])?[missingID(sourceID, baseURL)] else { return false }
        let age = now.timeIntervalSince1970 - at
        return age >= 0 && age < missingLifetime
    }

    static func recordMissing(_ sourceID: UUID, baseURL: URL, now: Date = .now, defaults: UserDefaults = .standard) {
        var missing = (defaults.dictionary(forKey: missingKey) as? [String: Double] ?? [:]).filter {
            now.timeIntervalSince1970 - $0.value < missingLifetime
        }
        missing[missingID(sourceID, baseURL)] = now.timeIntervalSince1970
        defaults.set(missing, forKey: missingKey)
    }

    private static func missingID(_ sourceID: UUID, _ baseURL: URL) -> String {
        sourceID.uuidString.lowercased() + " " + baseURL.absoluteString
    }

    private static func ids(_ value: String?) -> Set<String> {
        Set((value ?? "").split(separator: ",").map(String.init))
    }
}
