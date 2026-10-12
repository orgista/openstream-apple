import Foundation

/// File-scoped disk cache and a single four-request budget shared by all Library shelves.
actor AppleLibraryMetadataResolver {
    static let shared = AppleLibraryMetadataResolver()
    typealias Lookup = @Sendable (AppleLibraryTitle, [AppleSource], String, String) async throws -> AppleCatalogItem?
    private struct Entry: Codable {
        let value: AppleCatalogItem?
        let checkedAt: Date
        let addedAt: Date
        /// Which shape of `AppleCatalogItem` this entry was written with.
        /// Absent in everything written before `schema` existed, which reads
        /// back as `0` — see `currentSchema`.
        var schema: Int?
    }

    /// Bumped when a new field means a cached entry is *missing* something
    /// rather than merely being old.
    ///
    /// 1 → `AppleCatalogItem.logoURL`. Without this, a viewer who already had
    /// a Library keeps a hero with no wordmark for up to the seven-day
    /// lifetime below, because the cached JSON simply has no logo in it — the
    /// fix would look like it had not shipped. Re-resolving is the same work
    /// the title did on its first ever appearance, four at a time, and
    /// `addedAt` is carried across so "Recently Added" does not reshuffle.
    private static let currentSchema = 1

    private let directory: URL
    private let lookup: Lookup
    private var active = 0

    init(directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("LibraryTitles-v1"), lookup: @escaping Lookup = AppleLibraryMetadataResolver.liveLookup) {
        self.directory = directory
        self.lookup = lookup
    }

    func datedItems(_ items: [AppleLibraryItem], sourceID: UUID) throws -> [AppleLibraryItem] {
        let folder = directory.appendingPathComponent(sourceID.uuidString)
        let file = folder.appendingPathComponent("added.json")
        var dates = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: Date].self, from: $0) } ?? [:]
        let now = Date()
        let result = items.map { item in
            let key = ApplePlaybackIdentity.digest(for: item.relativePath)
            let date = dates[key] ?? (item.addedAt == .distantPast ? now : item.addedAt)
            dates[key] = date
            return AppleLibraryItem(sourceID: item.sourceID, name: item.name, url: item.url,
                relativePath: item.relativePath, sizeBytes: item.sizeBytes, addedAt: date)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(dates).write(to: file, options: .atomic)
        return result
    }

    func cachedMetadata(for groups: [AppleLibrarySeries]) -> [String: AppleCatalogItem] {
        var result: [String: AppleCatalogItem] = [:]
        for group in groups {
            guard let item = group.items.first else { continue }
            let file = directory.appendingPathComponent(item.sourceID.uuidString).appendingPathComponent(Self.cacheKey(item) + ".json")
            // Same schema gate as `resolve`. Without it a stale entry
            // published here would stick: the store only resolves a group
            // whose metadata is still nil, so the old shape would never be
            // asked to refresh.
            if let data = try? Data(contentsOf: file), let entry = try? JSONDecoder().decode(Entry.self, from: data),
               (entry.schema ?? 0) == Self.currentSchema, let value = entry.value { result[group.id] = value }
        }
        return result
    }

    static func cacheKey(_ item: AppleLibraryItem) -> String {
        ApplePlaybackIdentity.digest(for: "\(item.relativePath)|\(item.sizeBytes)")
    }

    func resolve(_ item: AppleLibraryItem, sources: [AppleSource], tmdbKey: String, omdbKey: String) async throws -> AppleCatalogItem? {
        try Task.checkCancellation()
        let file = directory.appendingPathComponent(item.sourceID.uuidString)
            .appendingPathComponent(Self.cacheKey(item) + ".json")
        let cached = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Entry.self, from: $0) }
        if let cached, (cached.schema ?? 0) == Self.currentSchema,
           Date().timeIntervalSince(cached.checkedAt) < (cached.value == nil ? 3600 : 604800) { return cached.value }
        // Waiting belongs to the card's task: disappearing cards cancel immediately.
        while active >= 4 { try await Task.sleep(for: .milliseconds(30)) }
        try Task.checkCancellation()
        active += 1
        defer { active -= 1 }
        let parsed = AppleLibraryTitleParser.parse(item)
        guard parsed.kind != .other else { return nil }
        let value = try await lookup(parsed, sources, tmdbKey, omdbKey)
        try Task.checkCancellation()
        let entry = Entry(value: value, checkedAt: Date(), addedAt: cached?.addedAt ?? Date(),
                          schema: Self.currentSchema)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(entry).write(to: file, options: .atomic)
        return value
    }

    /// The year disambiguates between films sharing a name; it does not decide
    /// whether a match is real.
    ///
    /// This used to require the parsed year to equal the candidate's
    /// `releaseInfo`, and threw away a correct match when they disagreed.
    /// Providers routinely publish the *production* year there: the owner's
    /// `1992 (2024)` is `tt4959750`, whose cast and `released: 2024-08-30`
    /// make it plainly the 2024 film, while Cinemeta's `releaseInfo` says
    /// 2022. The card had no artwork because a two-year gap in someone else's
    /// metadata outvoted an exact title match (owner 2026-09-15: "1992 still
    /// does not have album art").
    ///
    /// So: an exact year wins, and when nothing matches exactly the year only
    /// chooses *between* same-named candidates. A single same-named candidate
    /// is accepted — its poster is a far better answer than a blank tile.
    static func bestMatch(_ items: [AppleCatalogItem], parsed: AppleLibraryTitle) -> AppleCatalogItem? {
        let type = parsed.kind == .show ? "series" : "movie"
        let sameName = items.filter {
            $0.type == type && normalized($0.name) == normalized(parsed.title)
        }
        guard let first = sameName.first else { return nil }
        guard let year = parsed.year else { return first }
        if let exact = sameName.first(where: { releaseYear($0) == year }) { return exact }
        guard sameName.count > 1 else { return first }
        // Several films of the same name and none from the right year: the
        // nearest is the best available guess, and ties keep search order.
        return sameName.min {
            distance(releaseYear($0), from: year) < distance(releaseYear($1), from: year)
        } ?? first
    }

    private static func releaseYear(_ item: AppleCatalogItem) -> Int? {
        Int((item.releaseInfo ?? "").prefix(4))
    }

    /// Candidates with no year at all sort last rather than counting as zero.
    private static func distance(_ candidate: Int?, from year: Int) -> Int {
        guard let candidate else { return .max }
        return abs(candidate - year)
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined()
    }

    static func liveLookup(_ parsed: AppleLibraryTitle, _ sources: [AppleSource], _ tmdbKey: String, _ omdbKey: String) async throws -> AppleCatalogItem? {
        let type = parsed.kind == .show ? "series" : "movie"
#if OPENSTREAM_ADDONS
        var cinemeta = AppleStremioMetadataClient.defaultMetadataSource
        cinemeta.resources = ["catalog", "meta"]
        cinemeta.catalogs = [.init(type: type, id: "top", supportsSearch: true)]
        let candidates = [cinemeta] + sources.filter { $0.isEnabled && $0.isAddon && $0.manifestID != cinemeta.manifestID }
        let client = AppleStremioCatalogClient()
        for source in candidates {
            for catalog in source.catalogs.filter({ $0.type == type && $0.supportsSearch }).prefix(1) {
                try Task.checkCancellation()
                do {
                    let results = try await client.search(source: source, catalog: catalog, query: parsed.title)
                    if let match = bestMatch(results, parsed: parsed) {
                        let detail = try? await AppleStremioMetadataClient().details(source: source, type: type, mediaID: match.mediaID)
                        try Task.checkCancellation()
                        // `detail.logoURL` is the title's wordmark and it came
                        // back in this very response. Dropping it is why the
                        // Library hero could only ever draw a text title.
                        return AppleCatalogItem(mediaID: match.mediaID, type: type, name: detail?.title ?? match.name,
                            posterURL: detail?.posterURL ?? match.posterURL, backgroundURL: detail?.backdropURL ?? match.backgroundURL,
                            summary: detail?.overview ?? match.summary, releaseInfo: detail?.releaseInfo ?? match.releaseInfo,
                            logoURL: detail?.logoURL ?? match.logoURL)
                    }
                } catch { try Task.checkCancellation() }
            }
        }
#endif
        if !tmdbKey.isEmpty, let result = try? await credentialLookup(parsed, key: tmdbKey, tmdb: true) { return result }
        try Task.checkCancellation()
        if !omdbKey.isEmpty { return try await credentialLookup(parsed, key: omdbKey, tmdb: false) }
        return nil
    }

    private static func credentialLookup(_ parsed: AppleLibraryTitle, key: String, tmdb: Bool) async throws -> AppleCatalogItem? {
        let show = parsed.kind == .show
        var components = URLComponents(string: tmdb ? "https://api.themoviedb.org/3/search/\(show ? "tv" : "movie")" : "https://www.omdbapi.com/")!
        components.queryItems = tmdb ? [.init(name: "query", value: parsed.title)] : [.init(name: "t", value: parsed.title), .init(name: "type", value: show ? "series" : "movie")]
        if let year = parsed.year { components.queryItems?.append(.init(name: tmdb ? (show ? "first_air_date_year" : "year") : "y", value: String(year))) }
        let bearer = tmdb && key.hasPrefix("eyJ")
        if !bearer { components.queryItems?.append(.init(name: tmdb ? "api_key" : "apikey", value: key)) }
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 10
        if bearer { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await AppleTMDBClient.liveLoader(request)
        guard data.count < 2_000_000, let http = response as? HTTPURLResponse, http.statusCode == 200,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let values = tmdb ? (object["results"] as? [[String: Any]] ?? []) : [object]
        let items = values.compactMap { value -> AppleCatalogItem? in
            guard let title = value[tmdb ? (show ? "name" : "title") : "Title"] as? String else { return nil }
            let id = tmdb ? (value["id"] as? Int).map { "tmdb:\($0)" } : value["imdbID"] as? String
            guard let id else { return nil }
            func artwork(_ field: String, size: String) -> URL? {
                guard let path = value[field] as? String, path != "N/A" else { return nil }
                return URL(string: tmdb ? "https://image.tmdb.org/t/p/\(size)\(path)" : path)
            }
            return AppleCatalogItem(mediaID: id, type: show ? "series" : "movie", name: title,
                posterURL: artwork(tmdb ? "poster_path" : "Poster", size: "w500"),
                backgroundURL: tmdb ? artwork("backdrop_path", size: "w1280") : nil,
                summary: value[tmdb ? "overview" : "Plot"] as? String,
                releaseInfo: (value[tmdb ? (show ? "first_air_date" : "release_date") : "Year"] as? String).map { String($0.prefix(4)) })
        }
        guard let match = bestMatch(items, parsed: parsed) else { return nil }
        guard tmdb else { return match }
        // Still one follow-up request, not two: the external ids this match
        // needs and the textless backdrop the hero wants both hang off the
        // record, so they are appended to the same call that used to fetch
        // `/external_ids` on its own.
        var record = URLComponents(string: "https://api.themoviedb.org/3/\(show ? "tv" : "movie")/\(match.mediaID.dropFirst(5))")!
        record.queryItems = [
            .init(name: "append_to_response", value: "external_ids,images"),
            .init(name: "include_image_language", value: "null"),
        ]
        if !bearer { record.queryItems?.append(.init(name: "api_key", value: key)) }
        request.url = record.url
        guard let (data, _) = try? await AppleTMDBClient.liveLoader(request), data.count < 2_000_000,
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return match }
        var result = match
        if let path = textlessBackdropPath(in: value) {
            result = result.withHeroArtwork(
                backgroundURL: URL(string: "https://image.tmdb.org/t/p/w1280\(path)"), logoURL: nil
            )
        }
        if let imdb = (value["external_ids"] as? [String: Any])?["imdb_id"] as? String,
           AppleStremioMetadataClient.isIMDBIdentifier(imdb) {
            result = result.withMediaID(imdb)
        }
        return result
    }

    /// The best textless backdrop in an appended `images` block, or nothing —
    /// in which case the search result's own `backdrop_path` stands.
    private static func textlessBackdropPath(in value: [String: Any]) -> String? {
        let backdrops = ((value["images"] as? [String: Any])?["backdrops"] as? [[String: Any]] ?? [])
            .map {
                AppleArtworkImage(
                    filePath: $0["file_path"] as? String,
                    // A JSON null arrives as NSNull and casts to nil, which is
                    // precisely what "textless" means here.
                    languageCode: $0["iso_639_1"] as? String,
                    voteAverage: $0["vote_average"] as? Double
                )
            }
        guard case .textlessBackdrop(let path)? = AppleTextlessBackdropPolicy.choose(
            backdrops: backdrops, backdropPath: nil, posterPath: nil
        ) else { return nil }
        return path
    }
}
