import Foundation

public struct AppleStremioEpisodeIdentity: Equatable, Sendable {
    public let seriesID: String
    public let season: Int
    public let episode: Int

    public init(seriesID: String, season: Int, episode: Int) {
        self.seriesID = seriesID
        self.season = season
        self.episode = episode
    }

    public var id: String { "\(seriesID):\(season):\(episode)" }
}

public struct AppleStremioEpisode: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let season: Int?
    public let episode: Int?
    public let releaseInfo: String?
    public let runtimeMinutes: Int?
    public let overview: String?
    public let thumbnailURL: URL?

    public var formattedReleaseInfo: String? {
        guard let releaseInfo, !releaseInfo.isEmpty else { return nil }
        let day = String(releaseInfo.prefix(10))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        guard let date = formatter.date(from: day), formatter.string(from: date) == day else { return releaseInfo }
        formatter.locale = .current
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    public init(id: String, title: String, season: Int? = nil, episode: Int? = nil, releaseInfo: String? = nil, runtimeMinutes: Int? = nil, overview: String? = nil, thumbnailURL: URL? = nil) {
        self.id = String(id.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
        self.title = String(AppleHTMLEntities.decoded(title)
            .trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        self.season = season
        self.episode = episode
        let cleanRelease = releaseInfo?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.releaseInfo = cleanRelease.isEmpty ? nil : cleanRelease
        self.runtimeMinutes = runtimeMinutes.flatMap { (1 ... 24 * 60).contains($0) ? $0 : nil }
        let cleanOverview = AppleHTMLEntities.decoded(overview)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.overview = cleanOverview.isEmpty ? nil : cleanOverview
        self.thumbnailURL = thumbnailURL.flatMap { url in
            ["https", "http"].contains(url.scheme?.lowercased() ?? "") && url.host != nil
                && url.user == nil && url.password == nil ? url : nil
        }
    }

    public var displayTitle: String {
        let number: String? = if let season, let episode {
            "S\(season) E\(episode)"
        } else if let episode {
            "Episode \(episode)"
        } else {
            nil
        }
        if let number, !title.isEmpty { return "\(number) · \(title)" }
        return number ?? (title.isEmpty ? "Episode" : title)
    }
}

public struct AppleStremioEpisodeSelection: Equatable, Sendable {
    public let episode: AppleStremioEpisode

    public init?(seriesMediaID: String, episode: AppleStremioEpisode) {
        guard let identity = AppleStremioMetadataClient.episodeIdentity(
            episode.id,
            expectedSeriesID: seriesMediaID
        ),
        episode.season == identity.season,
        episode.episode == identity.episode else { return nil }
        self.episode = AppleStremioEpisode(
            id: identity.id,
            title: episode.title,
            season: identity.season,
            episode: identity.episode,
            releaseInfo: episode.releaseInfo,
            runtimeMinutes: episode.runtimeMinutes,
            overview: episode.overview,
            thumbnailURL: episode.thumbnailURL
        )
    }

    public var mediaID: String { episode.id }
    public var displayTitle: String { episode.displayTitle }
}

public struct AppleStremioPreviewAssets: Equatable, Sendable {
    public let trailerYouTubeKeys: [String]
    public let logoURL: URL?

    public var trailerYouTubeKey: String? { trailerYouTubeKeys.first }

    public init(
        trailerYouTubeKey: String? = nil,
        trailerYouTubeKeys: [String] = [],
        logoURL: URL? = nil
    ) {
        self.trailerYouTubeKeys = ([trailerYouTubeKey].compactMap { $0 } + trailerYouTubeKeys)
            .compactMap(AppleTrailerPreviewPolicy.validYouTubeKey)
            .reduce(into: []) { keys, key in
                if !keys.contains(key) { keys.append(key) }
            }
        self.logoURL = logoURL
    }
}

public enum AppleStremioEpisodePolicy {
    public static func initialSeason(in episodes: [AppleStremioEpisode]) -> Int? {
        let available = seasons(in: episodes)
        return available.first(where: { $0 > 0 }) ?? available.first
    }

    public static func seasons(in episodes: [AppleStremioEpisode]) -> [Int] {
        Array(Set(episodes.compactMap { isSafe($0) ? $0.season : nil })).sorted()
    }

    public static func episodes(
        in season: Int?,
        from episodes: [AppleStremioEpisode]
    ) -> [AppleStremioEpisode] {
        let values = season.map { selected in
            episodes.filter { isSafe($0) && $0.season == selected }
        } ?? episodes
        return values.filter(isSafe).sorted { lhs, rhs in
            if lhs.season != rhs.season { return (lhs.season ?? Int.max) < (rhs.season ?? Int.max) }
            if lhs.episode != rhs.episode { return (lhs.episode ?? Int.max) < (rhs.episode ?? Int.max) }
            let titleOrder = lhs.title.localizedStandardCompare(rhs.title)
            if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
            return lhs.id < rhs.id
        }
    }

    /// Returns the first episode that has not been completed, preserving the
    /// display order used by the detail page. Partially watched episodes stay
    /// the natural resume target.
    public static func nextUnwatched(
        in season: Int?,
        from episodes: [AppleStremioEpisode],
        completedIDs: Set<String>
    ) -> AppleStremioEpisode? {
        let ordered = Self.episodes(in: season, from: episodes)
        return ordered.first { !completedIDs.contains($0.id) } ?? ordered.first
    }

    /// The episode after `episode` in the order the detail page lists them,
    /// crossing into the next season when the current one runs out.
    ///
    /// Season-crossing is the point: the episode a viewer wants after the last
    /// one of a season is the first of the next, not nothing. Specials
    /// (season 0) are ordered ahead of season 1 by `episodes(in:from:)` and
    /// are reached only by playing into them deliberately.
    public static func following(
        _ episode: AppleStremioEpisode,
        in allEpisodes: [AppleStremioEpisode]
    ) -> AppleStremioEpisode? {
        let ordered = episodes(in: nil, from: allEpisodes)
        guard let index = ordered.firstIndex(where: { $0.id == episode.id }) else { return nil }
        let next = ordered.index(after: index)
        return next < ordered.endIndex ? ordered[next] : nil
    }

    private static func isSafe(_ episode: AppleStremioEpisode) -> Bool {
        guard !episode.id.isEmpty,
              let season = episode.season,
              let number = episode.episode else { return false }
        return season >= 0 && number >= 1
    }
}

public struct AppleStremioMetadataClient: Sendable {
    public typealias Loader = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let loader: Loader
    static let defaultMetadataSource = AppleSource(
        id: UUID(uuidString: "86FE8F74-15D8-4A64-8EE7-B2BE55E22C48") ?? UUID(),
        kind: .stremio,
        name: "Cinemeta",
        url: URL(string: "https://v3-cinemeta.strem.io/manifest.json")
            ?? URL(fileURLWithPath: "/invalid-cinemeta-url"),
        manifestID: "com.linvo.cinemeta",
        resources: ["meta"]
    )

    public init(loader: @escaping Loader = AppleStremioPlaybackClient.liveLoader) {
        self.loader = loader
    }

    public func details(
        source: AppleSource,
        type: String,
        mediaID: String
    ) async throws -> AppleTMDBDetails {
        let cleanID = mediaID.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanType = type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard source.kind == .stremio,
              source.isEnabled,
              source.resources.contains(where: { $0.caseInsensitiveCompare("meta") == .orderedSame }),
              ["movie", "series", "episode"].contains(cleanType),
              !cleanID.isEmpty else {
            throw AppleStremioPlaybackError.invalidSource
        }
        let endpoint = try Self.endpoint(source: source, type: cleanType, mediaID: cleanID)
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("OpenStream/1.0 Apple", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await loader(request)
        guard data.count <= AppleStremioPlaybackClient.maximumResponseBytes,
              let http = response as? HTTPURLResponse,
              http.url == endpoint,
              (200 ... 299).contains(http.statusCode),
              let envelope = try? JSONDecoder().decode(DetailsEnvelope.self, from: data) else {
            throw AppleStremioPlaybackError.invalidPayload
        }
        let value = envelope.meta
        let responseID = value.id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = value.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard responseID == cleanID, !title.isEmpty else {
            throw AppleStremioPlaybackError.invalidPayload
        }
        let genres = (value.genres ?? value.genre ?? [])
            .compactMap {
                let clean = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                return clean.isEmpty ? nil : clean
            }
            .prefix(12)
            .map { String($0.prefix(60)) }
        return AppleTMDBDetails(
            mediaID: responseID,
            mediaType: Self.nonEmpty(value.type) ?? cleanType,
            title: String(title.prefix(200)),
            releaseInfo: Self.nonEmpty(value.releaseInfo).map { String($0.prefix(100)) },
            runtimeMinutes: value.runtime?.boundedRuntime,
            contentRating: Self.nonEmpty(value.contentRating ?? value.certification),
            formatBadges: value.formatBadges ?? [],
            genres: genres,
            cast: Self.names(value.cast, limit: 20),
            director: Self.names(value.director, limit: 4).first,
            writers: Self.names(value.writer, limit: 8),
            imdbRating: value.imdbRating,
            year: value.year ?? Self.leadingYear(value.releaseInfo),
            overview: Self.nonEmpty(value.description).map { String($0.prefix(4_000)) },
            posterURL: Self.safeArtworkURL(value.poster),
            backdropURL: Self.safeArtworkURL(value.background),
            logoURL: Self.safeArtworkURL(value.logo)
        )
    }

    public func episodes(source: AppleSource, mediaID: String) async throws -> [AppleStremioEpisode] {
        guard source.kind == .stremio, source.isEnabled else {
            throw AppleStremioPlaybackError.invalidSource
        }
        let endpoint = try Self.endpoint(source: source, mediaID: mediaID)
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("OpenStream/1.0 Apple", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await loader(request)
        guard data.count <= AppleStremioPlaybackClient.maximumResponseBytes else {
            throw AppleStremioPlaybackError.responseTooLarge
        }
        guard let http = response as? HTTPURLResponse else { throw AppleStremioPlaybackError.nonHTTPResponse }
        guard http.url?.scheme?.lowercased() == "https" else {
            throw AppleStremioPlaybackError.insecureRedirect
        }
        guard (200 ... 299).contains(http.statusCode) else {
            throw AppleStremioPlaybackError.requestFailed(http.statusCode)
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            throw AppleStremioPlaybackError.invalidPayload
        }

        guard let seriesID = Self.seriesRootID(mediaID) else {
            throw AppleStremioPlaybackError.invalidMediaIdentity
        }
        var seen = Set<String>()
        return envelope.meta.videos.compactMap { value in
            guard let identity = Self.episodeIdentity(value.id, expectedSeriesID: seriesID),
                  value.season?.boundedEpisodeNumber.map({ $0 == identity.season }) ?? true,
                  value.episode?.boundedEpisodeNumber.map({ $0 == identity.episode }) ?? true,
                  !value.seasonWasPresent || value.season != nil,
                  !value.episodeWasPresent || value.episode != nil,
                  seen.insert(identity.id).inserted else { return nil }
            return AppleStremioEpisode(
                id: identity.id,
                title: value.title ?? value.name ?? "",
                season: identity.season,
                episode: identity.episode,
                releaseInfo: value.releaseInfo ?? value.released,
                runtimeMinutes: value.runtime?.boundedRuntime,
                overview: value.description,
                thumbnailURL: value.thumbnail.flatMap(URL.init(string:))
            )
        }
        .prefix(1_000)
        .map { $0 }
    }

    /// Catalog results and metadata are often supplied by different add-ons.
    /// Prefer the catalog source when it advertises `meta`, then fall back to
    /// every other enabled metadata provider until one returns episodes.
    public func episodes(
        sources: [AppleSource],
        preferredSourceID: AppleSource.ID? = nil,
        mediaID: String
    ) async throws -> [AppleStremioEpisode] {
        let eligible = sources.filter { source in
            source.kind == .stremio
                && source.isEnabled
                && source.resources.contains { $0.caseInsensitiveCompare("meta") == .orderedSame }
        }
        var candidates = eligible.filter { $0.id == preferredSourceID }
            + eligible.filter { $0.id != preferredSourceID }
        let hasDefaultSource = Self.defaultMetadataSource.manifestID.map { manifestID in
            candidates.contains { $0.manifestID == manifestID }
        } ?? false
        if Self.isIMDBIdentifier(mediaID), !hasDefaultSource {
            candidates.append(Self.defaultMetadataSource)
        }

        var lastError: (any Error)?
        var merged: [AppleStremioEpisode] = []
        var seen = Set<String>()
        for source in candidates {
            try Task.checkCancellation()
            do {
                let values = try await episodes(source: source, mediaID: mediaID)
                for value in values where seen.insert(value.id).inserted {
                    merged.append(value)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        if !merged.isEmpty {
            return AppleStremioEpisodePolicy.episodes(in: nil, from: merged)
        }
        if let lastError { throw lastError }
        return []
    }

    /// Resolves a catalog item's canonical IMDB id (`tt…`) via a meta-capable
    /// add-on. Catalog add-ons like Rotten Tomatoes and Streaming Catalogs
    /// return items keyed by non-IMDB ids (tmdb/slug/prefixed), but stream
    /// add-ons like Torrentio only resolve IMDB ids — so the raw catalog id
    /// yields "no streams". This mirrors the Android client, which stores each
    /// item's id AS its resolved IMDB id. Returns nil when nothing maps.
    public func imdbIdentifier(
        sources: [AppleSource],
        preferredSourceID: AppleSource.ID? = nil,
        type: String,
        id: String
    ) async -> String? {
        // Already an IMDB id (movie `tt123`, or series episode `tt123:1:2`).
        if let canonical = Self.canonicalMediaID(id) { return canonical }
        let eligible = sources.filter { source in
            source.kind == .stremio
                && source.isEnabled
                && source.resources.contains { $0.caseInsensitiveCompare("meta") == .orderedSame }
        }
        let candidates = eligible.filter { $0.id == preferredSourceID }
            + eligible.filter { $0.id != preferredSourceID }
        for source in candidates {
            if Task.isCancelled { return nil }
            if let resolved = try? await metaIMDBID(source: source, type: type, id: id) {
                return resolved
            }
        }
        return nil
    }

    public func previewAssets(
        sources: [AppleSource],
        preferredSourceID: AppleSource.ID? = nil,
        type: String,
        mediaID: String
    ) async -> AppleStremioPreviewAssets? {
        // Served from the cache when the home screen has already asked for it
        // (`AppleMetadataPrefetcher`). This is the 1357 ms a content page used
        // to spend before it could show a wordmark.
        let cacheKey = AppleStremioPreviewAssetsCache.key(type: type, mediaID: mediaID)
        if let entry = await AppleStremioPreviewAssetsCache.shared.entry(for: cacheKey) {
            #if DEBUG
            AppleLaunchClock.mark("meta.hit.\(mediaID)")
            #endif
            return entry.assets
        }
        #if DEBUG
        AppleLaunchClock.mark("meta.miss.\(mediaID)")
        #endif
        let eligible = sources.filter { source in
            source.kind == .stremio
                && source.isEnabled
                && source.resources.contains { $0.caseInsensitiveCompare("meta") == .orderedSame }
        }
        var candidates = eligible.filter { $0.id == preferredSourceID }
            + eligible.filter { $0.id != preferredSourceID }
        let hasDefaultSource = Self.defaultMetadataSource.manifestID.map { manifestID in
            candidates.contains { $0.manifestID == manifestID }
        } ?? false
        if Self.isIMDBIdentifier(mediaID), !hasDefaultSource {
            candidates.append(Self.defaultMetadataSource)
        }
        for source in candidates {
            if Task.isCancelled { return nil }
            if let assets = try? await previewAssets(source: source, type: type, mediaID: mediaID),
               assets.trailerYouTubeKey != nil || assets.logoURL != nil {
                await AppleStremioPreviewAssetsCache.shared.store(assets, for: cacheKey)
                return assets
            }
        }
        // A cancelled walk is not an answer and must not be remembered.
        guard !Task.isCancelled else { return nil }
        await AppleStremioPreviewAssetsCache.shared.store(nil, for: cacheKey)
        return nil
    }

    public static func canonicalMediaID(_ id: String) -> String? {
        let parts = id.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 3,
              let seriesID = canonicalSeriesID(String(parts[0])) else { return nil }
        guard parts.count == 3,
              let season = positiveNumber(parts[1], allowingZero: true),
              let episode = positiveNumber(parts[2], allowingZero: false) else {
            return parts.count == 1 ? seriesID : nil
        }
        return "\(seriesID):\(season):\(episode)"
    }

    public static func episodeIdentity(
        _ id: String,
        expectedSeriesID: String? = nil
    ) -> AppleStremioEpisodeIdentity? {
        let parts = id.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let seriesID = canonicalSeriesID(String(parts[0])),
              let season = positiveNumber(parts[1], allowingZero: true),
              let episode = positiveNumber(parts[2], allowingZero: false),
              expectedSeriesID.map({ seriesRootID($0) == seriesID }) ?? true else {
            return nil
        }
        return AppleStremioEpisodeIdentity(seriesID: seriesID, season: season, episode: episode)
    }

    /// True for a canonical movie/series id `tt1234567` or episode id `tt1234567:1:2`.
    public static func isIMDBIdentifier(_ id: String) -> Bool {
        canonicalMediaID(id) != nil
    }

    private static func seriesRootID(_ id: String) -> String? {
        let root = id.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? ""
        return canonicalSeriesID(root)
    }

    private static func canonicalSeriesID(_ id: String) -> String? {
        guard id.hasPrefix("tt"), id.count >= 7,
              id.dropFirst(2).allSatisfy(\.isNumber) else { return nil }
        return id
    }

    private static func positiveNumber(_ value: Substring, allowingZero: Bool) -> Int? {
        guard !value.isEmpty, value.allSatisfy(\.isNumber), let number = Int(value),
              number <= 100_000, allowingZero ? number >= 0 : number >= 1 else { return nil }
        return number
    }

    private func metaIMDBID(source: AppleSource, type: String, id: String) async throws -> String? {
        let endpoint = try Self.endpoint(source: source, type: type, mediaID: id)
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("OpenStream/1.0 Apple", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await loader(request)
        guard data.count <= AppleStremioPlaybackClient.maximumResponseBytes,
              let http = response as? HTTPURLResponse,
              http.url?.scheme?.lowercased() == "https",
              (200 ... 299).contains(http.statusCode),
              let envelope = try? JSONDecoder().decode(IMDBEnvelope.self, from: data) else {
            return nil
        }
        if let imdb = envelope.meta.imdbID,
           let canonical = Self.canonicalMediaID(imdb) {
            return canonical
        }
        let metaID = envelope.meta.id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Self.isIMDBIdentifier(metaID) ? metaID : nil
    }

    private func previewAssets(
        source: AppleSource,
        type: String,
        mediaID: String
    ) async throws -> AppleStremioPreviewAssets {
        let endpoint = try Self.endpoint(source: source, type: type, mediaID: mediaID)
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("OpenStream/1.0 Apple", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await loader(request)
        guard data.count <= AppleStremioPlaybackClient.maximumResponseBytes,
              let http = response as? HTTPURLResponse,
              http.url?.scheme?.lowercased() == "https",
              (200 ... 299).contains(http.statusCode),
              let envelope = try? JSONDecoder().decode(PreviewEnvelope.self, from: data) else {
            throw AppleStremioPlaybackError.invalidPayload
        }
        let keys = envelope.meta.trailers.compactMap(\.source)
            .compactMap(AppleTrailerPreviewPolicy.validYouTubeKey)
            + envelope.meta.trailerStreams.compactMap(\.ytID)
                .compactMap(AppleTrailerPreviewPolicy.validYouTubeKey)
        return AppleStremioPreviewAssets(
            trailerYouTubeKeys: keys,
            logoURL: Self.safeArtworkURL(envelope.meta.logo)
        )
    }

    private static func endpoint(source: AppleSource, type: String = "series", mediaID: String) throws -> URL {
        let cleanID = mediaID.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanType = type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleanID.isEmpty, cleanID.utf8.count <= 512,
              !cleanType.isEmpty, cleanType.utf8.count <= 64,
              var components = URLComponents(url: source.transportURL, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            throw AppleStremioPlaybackError.invalidMediaIdentity
        }
        let basePath = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let suffix = "meta/\(encodedSegment(cleanType))/\(encodedSegment(cleanID)).json"
        components.percentEncodedPath = basePath.isEmpty ? "/\(suffix)" : "/\(basePath)/\(suffix)"
        guard let url = components.url else { throw AppleStremioPlaybackError.invalidSource }
        return url
    }

    private static func encodedSegment(_ value: String) -> String {
        value.utf8.map { byte in
            switch byte {
            case 48 ... 57, 65 ... 90, 97 ... 122, 45, 95, 126:
                String(UnicodeScalar(byte))
            default:
                String(format: "%%%02X", byte)
            }
        }.joined()
    }

    private static func safeArtworkURL(_ value: String?) -> URL? {
        guard let value, let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              url.host?.isEmpty == false,
              url.user == nil, url.password == nil else { return nil }
        return url
    }

    static func names(_ values: [String]?, limit: Int) -> [String] {
        (values ?? [])
            .compactMap {
                let clean = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                return clean.isEmpty ? nil : String(clean.prefix(80))
            }
            .prefix(limit)
            .map { $0 }
    }

    /// `releaseInfo` is `2001`, `2001-` or `2001–2005`; take the first year.
    static func leadingYear(_ value: String?) -> Int? {
        guard let value else { return nil }
        let digits = value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4)
        guard digits.count == 4, let year = Int(digits), (1_870 ... 2_200).contains(year) else { return nil }
        return year
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }

    private struct Envelope: Decodable {
        let meta: Metadata
    }

    private struct DetailsEnvelope: Decodable {
        let meta: DetailsMeta
    }

    private struct DetailsMeta: Decodable {
        let id: String?
        let type: String?
        let name: String?
        let description: String?
        let releaseInfo: String?
        let runtime: FlexibleMetadataInt?
        let contentRating: String?
        let certification: String?
        let formatBadges: [String]?
        let genre: [String]?
        let genres: [String]?
        let cast: [String]?
        let director: [String]?
        let writer: [String]?
        let imdbRating: Double?
        let year: Int?
        let poster: String?
        let background: String?
        let logo: String?

        private enum CodingKeys: String, CodingKey {
            case id, type, name, description, releaseInfo, runtime, genre, genres, poster, background, logo, contentRating, certification, badges, formats
            case cast, director, writer, imdbRating, year
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try? container.decode(String.self, forKey: .id)
            type = try? container.decode(String.self, forKey: .type)
            name = try? container.decode(String.self, forKey: .name)
            description = try? container.decode(String.self, forKey: .description)
            releaseInfo = try? container.decode(String.self, forKey: .releaseInfo)
            runtime = try? container.decode(FlexibleMetadataInt.self, forKey: .runtime)
            contentRating = try? container.decode(String.self, forKey: .contentRating)
            certification = try? container.decode(String.self, forKey: .certification)
            formatBadges = (try? container.decode([String].self, forKey: .badges))
                ?? (try? container.decode([String].self, forKey: .formats))
            genre = try? container.decode([String].self, forKey: .genre)
            genres = try? container.decode([String].self, forKey: .genres)
            cast = Self.people(in: container, forKey: .cast)
            director = Self.people(in: container, forKey: .director)
            writer = Self.people(in: container, forKey: .writer)
            if let value = try? container.decode(Double.self, forKey: .imdbRating) {
                imdbRating = value.isFinite ? value : nil
            } else if let value = try? container.decode(String.self, forKey: .imdbRating) {
                imdbRating = Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
            } else {
                imdbRating = nil
            }
            if let value = try? container.decode(Int.self, forKey: .year) {
                year = value
            } else if let value = try? container.decode(String.self, forKey: .year) {
                year = AppleStremioMetadataClient.leadingYear(value)
            } else {
                year = nil
            }
            poster = try? container.decode(String.self, forKey: .poster)
            background = try? container.decode(String.self, forKey: .background)
            logo = try? container.decode(String.self, forKey: .logo)
        }

        /// Cinemeta returns `cast`/`director`/`writer` as an array of names, but
        /// some add-ons send a single name as a plain string.
        private static func people(
            in container: KeyedDecodingContainer<CodingKeys>,
            forKey key: CodingKeys
        ) -> [String]? {
            if let values = try? container.decode([String].self, forKey: key) { return values }
            if let value = try? container.decode(String.self, forKey: key) { return [value] }
            return nil
        }
    }

    private enum FlexibleMetadataInt: Decodable {
        case value(Int)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(Int.self) {
                self = .value(value)
            } else if let value = try? container.decode(String.self), let number = Int(value) {
                self = .value(number)
            } else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected an integer")
            }
        }

        var boundedRuntime: Int? {
            switch self {
            case .value(let value): (1 ... 24 * 60).contains(value) ? value : nil
            }
        }
    }

    private struct IMDBEnvelope: Decodable {
        let meta: IMDBMeta
    }

    private struct PreviewEnvelope: Decodable {
        let meta: PreviewMeta
    }

    private struct PreviewMeta: Decodable {
        let logo: String?
        let trailers: [Trailer]
        let trailerStreams: [TrailerStream]

        private enum CodingKeys: String, CodingKey {
            case logo, trailers, trailerStreams
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            logo = try? container.decode(String.self, forKey: .logo)
            trailers = (try? container.decode([Trailer].self, forKey: .trailers)) ?? []
            trailerStreams = (try? container.decode([TrailerStream].self, forKey: .trailerStreams)) ?? []
        }
    }

    private struct Trailer: Decodable { let source: String? }
    private struct TrailerStream: Decodable {
        let ytID: String?
        private enum CodingKeys: String, CodingKey { case ytID = "ytId" }
    }

    private struct IMDBMeta: Decodable {
        let id: String?
        let imdbID: String?
        private enum CodingKeys: String, CodingKey { case id, imdbID = "imdb_id" }
    }

    private struct Metadata: Decodable {
        let videos: [Video]

        private enum CodingKeys: String, CodingKey { case videos }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            var values: [Video] = []
            var array = try container.nestedUnkeyedContainer(forKey: .videos)
            while !array.isAtEnd {
                if let value = try? array.decode(Video.self) {
                    values.append(value)
                } else {
                    _ = try? array.superDecoder()
                }
            }
            videos = values
        }
    }

    private struct Video: Decodable {
        let id: String
        let title: String?
        let name: String?
        let season: FlexibleInt?
        let episode: FlexibleInt?
        let releaseInfo: String?
        let released: String?
        let runtime: FlexibleMetadataInt?
        let description: String?
        let thumbnail: String?
        let seasonWasPresent: Bool
        let episodeWasPresent: Bool

        private enum CodingKeys: String, CodingKey { case id, title, name, season, episode, releaseInfo, released, runtime, description, thumbnail }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            title = try? container.decode(String.self, forKey: .title)
            name = try? container.decode(String.self, forKey: .name)
            season = try? container.decode(FlexibleInt.self, forKey: .season)
            episode = try? container.decode(FlexibleInt.self, forKey: .episode)
            seasonWasPresent = container.contains(.season)
            episodeWasPresent = container.contains(.episode)
            releaseInfo = try? container.decode(String.self, forKey: .releaseInfo)
            released = try? container.decode(String.self, forKey: .released)
            runtime = try? container.decode(FlexibleMetadataInt.self, forKey: .runtime)
            description = try? container.decode(String.self, forKey: .description)
            thumbnail = try? container.decode(String.self, forKey: .thumbnail)
        }
    }

    private enum FlexibleInt: Decodable {
        case value(Int)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(Int.self) {
                self = .value(value)
            } else if let value = try? container.decode(String.self), let number = Int(value) {
                self = .value(number)
            } else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected an integer")
            }
        }

        var boundedEpisodeNumber: Int? {
            switch self {
            case .value(let value): (0 ... 100_000).contains(value) ? value : nil
            }
        }
    }
}
