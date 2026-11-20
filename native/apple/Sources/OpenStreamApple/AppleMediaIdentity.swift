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

public struct AppleMediaEpisode: Identifiable, Codable, Equatable, Sendable {
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
    public let episode: AppleMediaEpisode

    public init?(seriesMediaID: String, episode: AppleMediaEpisode) {
        if let reference = AppleXtreamReference.parse(seriesMediaID), reference.kind == .series,
           let season = episode.season, season >= 0, let number = episode.episode, number > 0,
           episode.id == reference.mediaID + ":\(season):\(number)" {
            self.episode = episode
            return
        }
        guard let identity = AppleMediaIdentifier.episodeIdentity(
            episode.id,
            expectedSeriesID: seriesMediaID
        ),
        episode.season == identity.season,
        episode.episode == identity.episode else { return nil }
        self.episode = AppleMediaEpisode(
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

public enum AppleMediaEpisodePolicy {
    /// Above this many episodes a series is a daily soap whose first season
    /// is decades old, so it opens on its latest season instead.
    static let latestSeasonFirstEpisodeCount = 1_000

    public static func initialSeason(in episodes: [AppleMediaEpisode]) -> Int? {
        let available = seasons(in: episodes)
        if episodes.count > latestSeasonFirstEpisodeCount, let latest = available.last(where: { $0 > 0 }) {
            return latest
        }
        return available.first(where: { $0 > 0 }) ?? available.first
    }

    /// Numbered seasons in order, then Specials (season 0).
    public static func seasons(in episodes: [AppleMediaEpisode]) -> [Int] {
        Array(Set(episodes.compactMap { isSafe($0) ? $0.season : nil })).sorted { ($0 == 0 ? Int.max : $0) < ($1 == 0 ? Int.max : $1) }
    }

    public static func episodes(
        in season: Int?,
        from episodes: [AppleMediaEpisode]
    ) -> [AppleMediaEpisode] {
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
        from episodes: [AppleMediaEpisode],
        completedIDs: Set<String>
    ) -> AppleMediaEpisode? {
        let ordered = Self.episodes(in: season, from: episodes)
        return ordered.first { !completedIDs.contains($0.id) } ?? ordered.first
    }

    /// The Apple TV app's Up Next: the first unfinished episode after the
    /// last finished one, across seasons. Nothing finished yet is the first
    /// episode; a show finished to the end starts over at its first episode
    /// rather than offering nothing. Specials (season 0) are left out unless
    /// the show has nothing else.
    public static func upNext(
        from allEpisodes: [AppleMediaEpisode],
        completedIDs: Set<String>
    ) -> AppleMediaEpisode? {
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
        return AppleCompletionPolicy.successor(after: candidates[last].id, episodes: candidates,
            completedIDs: completedIDs) ?? start
    }

    /// The episode the title page selects in `season`: Up Next when it is in
    /// that season, otherwise the season's first unfinished episode.
    public static func defaultEpisode(
        in season: Int?,
        from allEpisodes: [AppleMediaEpisode],
        completedIDs: Set<String>
    ) -> AppleMediaEpisode? {
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
        in episodes: [AppleMediaEpisode]
    ) -> AppleMediaEpisode? {
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
        _ episode: AppleMediaEpisode,
        in allEpisodes: [AppleMediaEpisode]
    ) -> AppleMediaEpisode? {
        let ordered = episodes(in: nil, from: allEpisodes)
        guard let index = ordered.firstIndex(where: { $0.id == episode.id }) else { return nil }
        let next = ordered.index(after: index)
        return next < ordered.endIndex ? ordered[next] : nil
    }

    private static func isSafe(_ episode: AppleMediaEpisode) -> Bool {
        guard !episode.id.isEmpty,
              let season = episode.season,
              let number = episode.episode else { return false }
        return season >= 0 && number >= 1
    }
}

public enum AppleMediaIdentifier {
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
    ) -> AppleMediaEpisodeIdentity? {
        let parts = id.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let seriesID = canonicalSeriesID(String(parts[0])),
              let season = positiveNumber(parts[1], allowingZero: true),
              let episode = positiveNumber(parts[2], allowingZero: false),
              expectedSeriesID.map({ seriesRootID($0) == seriesID }) ?? true else {
            return nil
        }
        return AppleMediaEpisodeIdentity(seriesID: seriesID, season: season, episode: episode)
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


