import Foundation

public struct AppleMediaEpisodeIdentity: Equatable, Sendable {
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

public struct AppleMediaEpisode: Identifiable, Equatable, Sendable {
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

public struct AppleMediaEpisodeSelection: Equatable, Sendable {
    public let episode: AppleStremioEpisode

    public init?(seriesMediaID: String, episode: AppleStremioEpisode) {
        if let reference = AppleXtreamReference.parse(seriesMediaID), reference.kind == .series,
           let season = episode.season, season >= 0, let number = episode.episode, number > 0,
           episode.id == reference.mediaID + ":\(season):\(number)" {
            self.episode = episode
            return
        }
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

public struct AppleMediaPreviewAssets: Equatable, Sendable {
    public let trailerYouTubeKeys: [String]
    public let logoURL: URL?
    /// Every episode the meta lists with a release date, for the iPhone hero's
    /// "New Season" / "New Episode" badge. Read from the same response as the
    /// trailers and the wordmark, so it costs no request of its own.
    public let episodes: [AppleHeroBadge.Episode]

    public var trailerYouTubeKey: String? { trailerYouTubeKeys.first }

    public init(
        trailerYouTubeKey: String? = nil,
        trailerYouTubeKeys: [String] = [],
        logoURL: URL? = nil,
        episodes: [AppleHeroBadge.Episode] = []
    ) {
        self.trailerYouTubeKeys = ([trailerYouTubeKey].compactMap { $0 } + trailerYouTubeKeys)
            .compactMap(AppleTrailerPreviewPolicy.validYouTubeKey)
            .reduce(into: []) { keys, key in
                if !keys.contains(key) { keys.append(key) }
            }
        self.logoURL = logoURL
        self.episodes = episodes
    }
}

public struct AppleRuntimeMinutesParser {
    /// A week of runtime. An add-on's free-text field above this (or one
    /// whose hours would overflow `Int` when turned into minutes, which
    /// trapped) is not a runtime, so it reads as unknown.
    static let maximumMinutes = 10_080

    public static func parse(_ value: String?) -> Int? {
        guard let minutes = unboundedParse(value), (0 ... maximumMinutes).contains(minutes) else { return nil }
        return minutes
    }

    private static func unboundedParse(_ value: String?) -> Int? {
        guard let value else { return nil }
        let clean = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = Int(clean) { return exact }

        var total = 0
        var hasValue = false

        if let hRange = clean.range(of: "h") {
            let hStr = clean[..<hRange.lowerBound].trimmingCharacters(in: .whitespaces)
            if let h = Int(hStr) {
                guard (0 ... maximumMinutes).contains(h) else { return nil }
                total += h * 60
                hasValue = true
            }

            let remainder = clean[hRange.upperBound...].trimmingCharacters(in: .whitespaces)
            let mStr = remainder.replacingOccurrences(of: "min", with: "")
                                .replacingOccurrences(of: "m", with: "")
                                .trimmingCharacters(in: .whitespaces)
            if let m = Int(mStr) {
                guard (0 ... maximumMinutes).contains(m) else { return nil }
                total += m
                hasValue = true
            }
        } else {
            let mStr = clean.replacingOccurrences(of: "min", with: "")
                            .replacingOccurrences(of: "m", with: "")
                            .trimmingCharacters(in: .whitespaces)
            if let m = Int(mStr) {
                guard (0 ... maximumMinutes).contains(m) else { return nil }
                total += m
                hasValue = true
            }
        }

        return hasValue ? total : nil
    }
}

public enum AppleMediaEpisodePolicy {
    /// Above this many episodes a series is a daily soap whose first season
    /// is decades old, so it opens on its latest season instead.
    static let latestSeasonFirstEpisodeCount = 1_000

    public static func initialSeason(in episodes: [AppleStremioEpisode]) -> Int? {
        let available = seasons(in: episodes)
        if episodes.count > latestSeasonFirstEpisodeCount, let latest = available.last, latest > 0 {
            return latest
        }
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
            // Same number (or none): earlier air date first, undated last.
            let lhsAired = lhs.releaseInfo.map { String($0.prefix(10)) } ?? ""
            let rhsAired = rhs.releaseInfo.map { String($0.prefix(10)) } ?? ""
            if lhsAired != rhsAired {
                if lhsAired.isEmpty || rhsAired.isEmpty { return rhsAired.isEmpty }
                return lhsAired < rhsAired
            }
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

    /// The Apple TV app's Up Next: the first unfinished episode after the
    /// last finished one, across seasons. Nothing finished yet is the first
    /// episode; a show finished to the end starts over at its first episode
    /// rather than offering nothing. Specials (season 0) are left out unless
    /// the show has nothing else.
    public static func upNext(
        from allEpisodes: [AppleStremioEpisode],
        completedIDs: Set<String>
    ) -> AppleStremioEpisode? {
        let ordered = episodes(in: nil, from: allEpisodes)
        let regular = ordered.filter { $0.season != 0 }
        let candidates = regular.isEmpty ? ordered : regular
        // Nothing watched (or all watched): a daily soap starts at its latest
        // season, any other show at its first episode.
        let start = initialSeason(in: allEpisodes)
            .flatMap { season in candidates.first { $0.season == season } }
            ?? candidates.first
        guard let last = candidates.lastIndex(where: { completedIDs.contains($0.id) }) else {
            return start
        }
        return candidates[candidates.index(after: last)...].first { !completedIDs.contains($0.id) }
            ?? start
    }

    /// The episode the title page selects in `season`: Up Next when it is in
    /// that season, otherwise the season's first unfinished episode.
    public static func defaultEpisode(
        in season: Int?,
        from allEpisodes: [AppleStremioEpisode],
        completedIDs: Set<String>
    ) -> AppleStremioEpisode? {
        if let next = upNext(from: allEpisodes, completedIDs: completedIDs), season == nil || next.season == season {
            return next
        }
        return nextUnwatched(in: season, from: allEpisodes, completedIDs: completedIDs)
    }

    /// The episode a show's saved position belongs to, while that position is
    /// still a resume point.
    ///
    /// A series keeps one progress entry under the show, naming its episode in
    /// `partID`; that entry is what Continue Watching lists and what the home
    /// hero's "Resume S1, E3" reads. The title page chose its episode without
    /// it — the next unwatched one — so pressing Resume could start another
    /// episode than the button named (driver review, 2026-09-22). Nil when
    /// the entry names no episode, is not resumable, or its episode is not in
    /// the list: the page then keeps its usual choice.
    public static func savedEpisode(
        progress: ApplePlaybackProgress?,
        in episodes: [AppleStremioEpisode]
    ) -> AppleStremioEpisode? {
        guard let progress, progress.resumePosition != nil, let part = progress.partID else { return nil }
        return episodes.first { $0.id == part && isSafe($0) }
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

#if OPENSTREAM_ADDONS
public struct AppleMediaMetadataClient: Sendable {
    public typealias Loader = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let loader: Loader
    private let metadataCache: AppleMetadataDiskCache?
    /// How long the other add-ons may still add episodes once one has answered.
    let mergeGrace: Duration
    static let defaultMetadataSource = AppleSource(
        id: UUID(uuidString: "86FE8F74-15D8-4A64-8EE7-B2BE55E22C48") ?? UUID(),
        kind: .stremio,
        name: "Cinemeta",
        url: URL(string: "https://v3-cinemeta.strem.io/manifest.json")
            ?? URL(fileURLWithPath: "/invalid-cinemeta-url"),
        manifestID: "com.linvo.cinemeta",
        resources: ["meta"]
    )

    /// Every episode of a daily soap, bounded. Goede tijden, slechte tijden
    /// is 7,301 episodes over 37 seasons; the old 1,000 cap stopped the list
    /// years short (Apple TV regression 2026-10-01). Each episode is kept as a
    /// compact summary (overview clipped) so the list stays a few MB at most.
    static let maximumEpisodes = 20_000
    static let maximumEpisodeOverviewCharacters = 400
    /// A meta answer listing thousands of episodes: Cinemeta's for Goede
    /// tijden is 4.96 MB, over the 2 MB the stream answers are held to.
    static let maximumMetaResponseBytes = 8_000_000

    static func liveMetaLoader(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await AppleBoundedHTTPDataLoader.load(
                request,
                maximumBytes: maximumMetaResponseBytes,
                redirectPolicy: .secureHTTPOnly
            )
        } catch AppleBoundedHTTPError.responseTooLarge {
            throw AppleStremioPlaybackError.responseTooLarge
        }
    }

    public init() {
        self.loader = Self.liveMetaLoader
        self.metadataCache = .shared
        self.mergeGrace = .seconds(1)
    }

    /// Injected transports remain independent of process-wide persisted data.
    public init(loader: @escaping Loader) {
        self.loader = loader
        self.metadataCache = nil
        self.mergeGrace = .seconds(1)
    }

    internal init(
        loader: @escaping Loader,
        metadataCache: AppleMetadataDiskCache?,
        mergeGrace: Duration = .seconds(1)
    ) {
        self.loader = loader
        self.metadataCache = metadataCache
        self.mergeGrace = mergeGrace
    }

    /// `isListingSource`: the add-on asked is the one whose catalog listed
    /// the title, so the id is in its own namespace. Its single meta answers
    /// the request even under another id (Stravo asked `mx:…` answers `tt…`,
    /// Raccoonmendations asked `tmdb:…` answers the bare number); the result
    /// keeps the requested id.
    ///
    /// `fallbackName`: the catalog item's name, for a meta that comes
    /// without one. A meta object at the root (no `meta` key) is read as the
    /// meta, and one without an `id` answers for the requested id.
    public func details(
        source: AppleSource,
        type: String,
        mediaID: String,
        isListingSource: Bool = false,
        fallbackName: String? = nil
    ) async throws -> AppleTMDBDetails {
        let cleanID = mediaID.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanType = type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard source.isAddon,
              source.isEnabled,
              source.resources.contains(where: { $0.caseInsensitiveCompare("meta") == .orderedSame }),
              // tv, anime, channel and custom types read the add-on's own meta.
              AppleCatalogDiscoveryPolicy.isShelfType(cleanType),
              !cleanID.isEmpty else {
            throw AppleStremioPlaybackError.invalidSource
        }
        let endpoint = try Self.endpoint(source: source, type: cleanType, mediaID: cleanID)

        @Sendable func decode(data: Data) throws -> AppleTMDBDetails {
            guard let value = (try? JSONDecoder().decode(DetailsEnvelope.self, from: data))?.meta,
                  value.id != nil || value.name != nil else {
                throw AppleStremioPlaybackError.invalidPayload
            }
            let responseID = value.id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let title = Self.nonEmpty(value.name) ?? Self.nonEmpty(fallbackName) ?? ""
            guard responseID.isEmpty
                    || Self.metaAnswers(requestedID: cleanID, responseID: responseID, isListingSource: isListingSource),
                  !title.isEmpty else {
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
                mediaID: cleanID,
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
                year: value.year,
                overview: Self.nonEmpty(value.description).map { String($0.prefix(4_000)) },
                posterURL: Self.safeArtworkURL(value.poster),
                backdropURL: Self.safeArtworkURL(value.background ?? value.landscapePoster),
                logoURL: Self.safeArtworkURL(value.logo),
                trailerYouTubeKeys: {
                    let ts1 = value.trailers?.compactMap(\.source) ?? []
                    let ts2 = value.trailerStreams?.compactMap(\.ytID) ?? []
                    return (ts1 + ts2).compactMap(AppleTrailerPreviewPolicy.validYouTubeKey)
                        .reduce(into: []) { keys, key in
                            if !keys.contains(key) { keys.append(key) }
                        }
                }(),
                // Cinemeta sends "United States, United Kingdom".
                castMembers: value.credits,
                countries: (value.country ?? "").split(separator: ",").compactMap { AppleTitlePagePolicy.regionName(String($0)) }
            )
        }

        @Sendable func fetch() async throws -> Data {
            var request = URLRequest(url: endpoint)
            request.timeoutInterval = 15
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("OpenStream/1.0 Apple", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await loader(request)
            // A redirect is followed as for episodes, as long as it ends on
            // a plain https address.
            guard data.count <= Self.maximumMetaResponseBytes,
                  let http = response as? HTTPURLResponse,
                  http.url.map(Self.isAcceptableMetaResponseURL) == true,
                  (200 ... 299).contains(http.statusCode) else {
                throw AppleStremioPlaybackError.invalidPayload
            }
            return data
        }

        return try await fetchCachedOrNetwork(
            cacheSource: endpoint.absoluteString,
            type: cleanType,
            mediaID: cleanID,
            decode: decode(data:),
            fetch: fetch
        )
    }

    /// Whether a meta response's id answers the request: the same id, the
    /// same id percent-encoded (`tmdb%3A…`), or any id from the add-on that
    /// listed the title.
    static func metaAnswers(requestedID: String, responseID: String, isListingSource: Bool) -> Bool {
        guard !responseID.isEmpty else { return false }
        if responseID == requestedID || responseID.removingPercentEncoding == requestedID { return true }
        return isListingSource
    }

    /// Where a meta request may end after redirects: https, with a host and
    /// no credentials in the address.
    static func isAcceptableMetaResponseURL(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return parts.scheme?.lowercased() == "https"
            && parts.host?.isEmpty == false
            && parts.user == nil
            && parts.password == nil
    }

    public func episodes(source: AppleSource, mediaID: String) async throws -> [AppleStremioEpisode] {
        guard source.isAddon, source.isEnabled else {
            throw AppleStremioPlaybackError.invalidSource
        }
        let endpoint = try Self.endpoint(source: source, mediaID: mediaID)
        @Sendable func decode(data: Data) throws -> [AppleStremioEpisode] {
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
                    overview: (value.description ?? value.overview)
                        .map { String($0.prefix(Self.maximumEpisodeOverviewCharacters)) },
                    thumbnailURL: value.thumbnail.flatMap(URL.init(string:))
                )
            }.prefix(Self.maximumEpisodes).map { $0 }
        }

        @Sendable func fetch() async throws -> Data {
            var request = URLRequest(url: endpoint)
            request.timeoutInterval = 15
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("OpenStream/1.0 Apple", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await loader(request)
            guard data.count <= Self.maximumMetaResponseBytes else {
                throw AppleStremioPlaybackError.responseTooLarge
            }
            guard let http = response as? HTTPURLResponse else { throw AppleStremioPlaybackError.nonHTTPResponse }
            guard http.url?.scheme?.lowercased() == "https" else {
                throw AppleStremioPlaybackError.insecureRedirect
            }
            guard (200 ... 299).contains(http.statusCode) else {
                throw AppleStremioPlaybackError.requestFailed(http.statusCode)
            }
            return data
        }

        return try await fetchCachedOrNetwork(
            cacheSource: endpoint.absoluteString,
            type: "episodes",
            mediaID: mediaID,
            decode: decode(data:),
            fetch: fetch
        )
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
            source.isAddon
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

        // Every add-on is asked at once. They were asked one after another,
        // each with a 15 s timeout, so a single slow add-on ahead of the one
        // that answers held the episode list back by its whole timeout. Once
        // one add-on has returned episodes the others get `mergeGrace` to add
        // theirs; the answers are still merged in candidate order.
        let grace = mergeGrace
        let results = await withTaskGroup(
            of: (index: Int, result: Result<[AppleStremioEpisode], any Error>)?.self
        ) { group in
            for (index, source) in candidates.enumerated() {
                group.addTask {
                    do {
                        return (index, .success(try await episodes(source: source, mediaID: mediaID)))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }
            var results: [Int: Result<[AppleStremioEpisode], any Error>] = [:]
            var graceStarted = false
            while let next = await group.next() {
                // The grace timer finished before the stragglers did.
                guard let next else { break }
                results[next.index] = next.result
                if results.count == candidates.count { break }
                if !graceStarted, case .success(let values) = next.result, !values.isEmpty {
                    graceStarted = true
                    group.addTask {
                        try? await Task.sleep(for: grace)
                        return nil
                    }
                }
            }
            group.cancelAll()
            return results
        }
        try Task.checkCancellation()

        var lastError: (any Error)?
        var merged: [AppleStremioEpisode] = []
        var seen = Set<String>()
        for index in candidates.indices {
            switch results[index] {
            case .success(let values):
                for value in values where seen.insert(value.id).inserted {
                    merged.append(value)
                }
            case .failure(let error):
                lastError = error
            case nil:
                continue
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
            source.isAddon
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
            source.isAddon
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
        // Whether an add-on could not be reached (timeout, offline, dropped
        // connection) rather than answering. Such a walk is not "this title
        // has no wordmark", so it is not remembered as one: the next ask goes
        // to the network again (owner 2026-09-29, heroes stuck on the name).
        var unreachable = false
        for source in candidates {
            if Task.isCancelled { return nil }
            do {
                let assets = try await previewAssets(source: source, type: type, mediaID: mediaID)
                if assets.trailerYouTubeKey != nil || assets.logoURL != nil {
                    await AppleStremioPreviewAssetsCache.shared.store(assets, for: cacheKey)
                    return assets
                }
            } catch is URLError {
                unreachable = true
            } catch {}
        }
        // A cancelled walk is not an answer and must not be remembered.
        guard !Task.isCancelled, !unreachable else { return nil }
        await AppleStremioPreviewAssetsCache.shared.store(nil, for: cacheKey)
        return nil
    }

    private func fetchCachedOrNetwork<T>(
        cacheSource: String,
        type: String,
        mediaID: String,
        decode: @escaping @Sendable (Data) throws -> T,
        fetch: @escaping @Sendable () async throws -> Data
    ) async throws -> T {
        if let cache = metadataCache, let entry = await cache.entry(source: cacheSource, type: type, mediaID: mediaID) {
            if entry.freshness == .fresh {
                if let result = try? decode(entry.payload) {
                    return result
                }
            } else if entry.freshness == .stale {
                if let result = try? decode(entry.payload) {
                    Task.detached(priority: .background) { [metadataCache] in
                        if let newData = try? await fetch(),
                           (try? decode(newData)) != nil {
                            await metadataCache?.store(newData, source: cacheSource, type: type, mediaID: mediaID)
                        }
                    }
                    return result
                }
            }
        }

        let data = try await fetch()
        let result = try decode(data)
        await metadataCache?.store(data, source: cacheSource, type: type, mediaID: mediaID)
        return result
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
        guard data.count <= Self.maximumMetaResponseBytes,
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
        @Sendable func decode(data: Data) throws -> AppleStremioPreviewAssets {
            guard let envelope = try? JSONDecoder().decode(PreviewEnvelope.self, from: data) else {
                throw AppleStremioPlaybackError.invalidPayload
            }
            let keys = envelope.meta.trailers.compactMap(\.source)
                .compactMap(AppleTrailerPreviewPolicy.validYouTubeKey)
                + envelope.meta.trailerStreams.compactMap(\.ytID)
                    .compactMap(AppleTrailerPreviewPolicy.validYouTubeKey)
            return AppleStremioPreviewAssets(
                trailerYouTubeKeys: keys,
                logoURL: Self.safeArtworkURL(envelope.meta.logo),
                episodes: envelope.meta.videos.compactMap { video in
                    guard let season = video.season, let episode = video.episode,
                          let released = AppleHeroBadge.releaseDate(video.released) else { return nil }
                    return AppleHeroBadge.Episode(season: season, episode: episode, released: released)
                }
            )
        }

        @Sendable func fetch() async throws -> Data {
            var request = URLRequest(url: endpoint)
            request.timeoutInterval = 15
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("OpenStream/1.0 Apple", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await loader(request)
            guard data.count <= Self.maximumMetaResponseBytes,
                  let http = response as? HTTPURLResponse,
                  http.url?.scheme?.lowercased() == "https",
                  (200 ... 299).contains(http.statusCode) else {
                throw AppleStremioPlaybackError.invalidPayload
            }
            return data
        }

        return try await fetchCachedOrNetwork(
            cacheSource: endpoint.absoluteString,
            type: "preview-assets",
            mediaID: mediaID,
            decode: decode(data:),
            fetch: fetch
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

    /// `{"meta":{…}}`, or the meta object itself at the root (Cartoon
    /// Network, Nickelodeon, Viva Max: add-on sweep 2026-10-01). A `meta`
    /// key that is null or not an object leaves `meta` nil.
    private struct DetailsEnvelope: Decodable {
        let meta: DetailsMeta?

        private struct Key: CodingKey {
            let stringValue: String
            var intValue: Int? { nil }
            init(_ value: String) { stringValue = value }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            if container.contains(Key("meta")) {
                meta = try? container.decode(DetailsMeta.self, forKey: Key("meta"))
            } else if container.contains(Key("id")) || container.contains(Key("name")) {
                meta = try? DetailsMeta(from: decoder)
            } else {
                meta = nil
            }
        }
    }

    private struct DetailsMeta: Decodable {
        let id: String?
        let type: String?
        let name: String?
        let description: String?
        let releaseInfo: String?
        let released: String?
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
        let landscapePoster: String?
        let logo: String?
        let trailers: [Trailer]?
        let trailerStreams: [TrailerStream]?
        let country: String?
        /// The same people with their pictures, when the add-on sends them.
        let credits: [AppleCreditPerson]

        private enum CodingKeys: String, CodingKey {
            case id, type, name, description, releaseInfo, released, runtime, genre, genres, poster, background, landscapePoster, logo, contentRating, certification, badges, formats
            case cast, director, writer, imdbRating, year, trailers, trailerStreams, country
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try? container.decode(String.self, forKey: .id)
            type = try? container.decode(String.self, forKey: .type)
            name = try? container.decode(String.self, forKey: .name)
            description = try? container.decode(String.self, forKey: .description)
            releaseInfo = try? container.decode(String.self, forKey: .releaseInfo)
            released = try? container.decode(String.self, forKey: .released)
            if let rVal = try? container.decode(FlexibleMetadataInt.self, forKey: .runtime) {
                runtime = rVal
            } else if let rStr = try? container.decode(String.self, forKey: .runtime), let mins = AppleRuntimeMinutesParser.parse(rStr) {
                runtime = .value(mins)
            } else {
                runtime = nil
            }
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
            } else if let value = try? container.decode(String.self, forKey: .year), let num = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                year = num
            } else if let release = (try? container.decode(String.self, forKey: .releaseInfo)) ?? (try? container.decode(String.self, forKey: .released)) {
                year = AppleStremioMetadataClient.leadingYear(release)
            } else {
                year = nil
            }
            poster = try? container.decode(String.self, forKey: .poster)
            background = try? container.decode(String.self, forKey: .background)
            landscapePoster = try? container.decode(String.self, forKey: .landscapePoster)
            logo = try? container.decode(String.self, forKey: .logo)
            trailers = try? container.decode([Trailer].self, forKey: .trailers)
            trailerStreams = try? container.decode([TrailerStream].self, forKey: .trailerStreams)
            country = try? container.decode(String.self, forKey: .country)
            credits = (try? AppleStremioCredits(from: decoder))?.people ?? []
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
        let videos: [PreviewVideo]

        private enum CodingKeys: String, CodingKey {
            case logo, trailers, trailerStreams, videos
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            logo = try? container.decode(String.self, forKey: .logo)
            trailers = (try? container.decode([Trailer].self, forKey: .trailers)) ?? []
            trailerStreams = (try? container.decode([TrailerStream].self, forKey: .trailerStreams)) ?? []
            videos = (try? container.decode([PreviewVideo].self, forKey: .videos)) ?? []
        }
    }

    /// Only what the hero badge needs. Never throws, so one odd entry cannot
    /// drop the whole list.
    private struct PreviewVideo: Decodable {
        let season: Int?
        let episode: Int?
        let released: String?

        private enum CodingKeys: String, CodingKey { case season, episode, released }

        init(from decoder: Decoder) throws {
            let container = try? decoder.container(keyedBy: CodingKeys.self)
            season = Self.number(container, .season)
            episode = Self.number(container, .episode)
            released = try? container?.decode(String.self, forKey: .released)
        }

        private static func number(_ container: KeyedDecodingContainer<CodingKeys>?, _ key: CodingKeys) -> Int? {
            if let value = try? container?.decode(Int.self, forKey: key) { return value }
            return (try? container?.decode(String.self, forKey: key)).flatMap { Int($0) }
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
        let overview: String?
        let thumbnail: String?
        let seasonWasPresent: Bool
        let episodeWasPresent: Bool

        private enum CodingKeys: String, CodingKey { case id, title, name, season, episode, releaseInfo, released, runtime, description, overview, thumbnail }

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
            if let rVal = try? container.decode(FlexibleMetadataInt.self, forKey: .runtime) {
                runtime = rVal
            } else if let rStr = try? container.decode(String.self, forKey: .runtime), let mins = AppleRuntimeMinutesParser.parse(rStr) {
                runtime = .value(mins)
            } else {
                runtime = nil
            }
            description = try? container.decode(String.self, forKey: .description)
            overview = try? container.decode(String.self, forKey: .overview)
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
#else
public struct AppleMediaMetadataClient: Sendable {
    public init() {}
    public func episodes(sources: [AppleSource], preferredSourceID: AppleSource.ID? = nil, mediaID: String) async throws -> [AppleStremioEpisode] { [] }
    public func previewAssets(sources: [AppleSource], preferredSourceID: AppleSource.ID? = nil, type: String, mediaID: String) async -> AppleStremioPreviewAssets? { nil }
    public func imdbIdentifier(sources: [AppleSource], preferredSourceID: AppleSource.ID? = nil, type: String, id: String) async -> String? { Self.canonicalMediaID(id) }
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

    static func leadingYear(_ value: String?) -> Int? { value.flatMap { Int($0.prefix(4)) } }
}

#endif

public typealias AppleStremioEpisodeIdentity = AppleMediaEpisodeIdentity

public typealias AppleStremioEpisode = AppleMediaEpisode

public typealias AppleStremioEpisodeSelection = AppleMediaEpisodeSelection

public typealias AppleStremioPreviewAssets = AppleMediaPreviewAssets

public typealias AppleStremioEpisodePolicy = AppleMediaEpisodePolicy

public typealias AppleStremioMetadataClient = AppleMediaMetadataClient
