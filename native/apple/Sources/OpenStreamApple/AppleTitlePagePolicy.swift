import Foundation

/// One person on a title page's Cast & Crew rail: who, what they did, and a
/// portrait when the metadata has one.
public struct AppleCreditPerson: Equatable, Hashable, Sendable, Identifiable {
    public let name: String
    /// "Walter White", "Director", "Creator". Nil when the source names the
    /// person and nothing else.
    public let role: String?
    public let portraitURL: URL?

    public var id: String { "\(name)|\(role ?? "")" }

    public init(name: String, role: String? = nil, portraitURL: URL? = nil) {
        self.name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        let cleanRole = role?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.role = cleanRole.isEmpty ? nil : String(cleanRole.prefix(100))
        self.portraitURL = portraitURL.flatMap { $0.scheme?.lowercased() == "https" ? $0 : nil }
    }

    /// TMDB's portrait size for Cast & Crew: 632 px tall, sharp in the Mac's
    /// and Apple TV's large circles at 2x. `w185` upscaled and looked blurry
    /// (owner, 2026-09-25).
    static let tmdbPortraitSize = "h632"

    /// A TMDB image path at a thumbnail size (`/t/p/w185/x.jpg`, w45…w185)
    /// moved to `tmdbPortraitSize`. Larger sizes and face crops are kept.
    static func sharpTMDBPortraitPath(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        // "", "t", "p", size, file…
        guard parts.count >= 5, parts[1] == "t", parts[2] == "p",
              ["w45", "w92", "w154", "w185"].contains(String(parts[3])) else { return path }
        var sharp = parts.map(String.init)
        sharp[3] = tmdbPortraitSize
        return sharp.joined(separator: "/")
    }

    /// "Bryan Cranston" → "BC", for a portrait that has no picture.
    public var initials: String {
        let words = name.split(whereSeparator: { $0.isWhitespace || $0 == "-" })
        let letters = [words.first, words.count > 1 ? words.last : nil].compactMap { $0?.first }
        return String(letters).uppercased()
    }
}

/// The title page's words and sections on the iPhone (N17) and the Mac
/// (N18), after the Apple TV app's (INSPO-TEARDOWN §7, PDF pages 11–16).
/// Everything here is read from the title's own metadata, episode list and
/// saved position; a section with
/// nothing real to say is `nil` or empty and is not drawn.
public enum AppleTitlePagePolicy {
    // MARK: - The one button

    public enum PrimaryAction: Equatable, Sendable {
        /// "Resume S4, E8", or "Resume" for a film.
        case resume(episode: String?)
        case play
        /// "Play S1, E3": a series title page names the episode Play starts.
        case playEpisode(String)
        /// Nothing on the page can play, but a trailer can.
        case playTrailer
        /// A hero whose title has nothing to play and no trailer: the button
        /// opens the title page instead of sitting there greyed out (N17d).
        case details

        public func displayTitle(hasCompletedDownload: Bool) -> String {
            switch self {
            case .play, .playEpisode: hasCompletedDownload ? "Play Offline" : title
            case .resume, .playTrailer, .details: title
            }
        }

        public var systemImage: String {
            self == .details ? "info.circle" : "play.fill"
        }

        public var title: String {
            switch self {
            case .resume(let episode?): "Resume \(episode)"
            case .resume(nil): "Resume"
            case .play: "Play"
            case .playEpisode(let episode): "Play \(episode)"
            case .playTrailer: "Play Trailer"
            case .details: "Details"
            }
        }
    }

    // MARK: - Start from Beginning

    /// "Start from Beginning" sits beside the one button whenever that button
    /// resumes (a film or an episode with a saved position), and nowhere else.
    public static func offersStartFromBeginning(_ action: PrimaryAction?) -> Bool {
        if case .resume? = action { return true }
        return false
    }

    /// Where a press starts: the saved position, or the top for "Start from
    /// Beginning". The saved position is left alone; playing from the top
    /// overwrites it as the title plays.
    public static func startPosition(saved: Double?, fromBeginning: Bool) -> Double? {
        fromBeginning ? nil : saved
    }

    /// Shared by title pages and every Discover hero. A route is a source that
    /// can play THIS title: a Stremio add-on that serves streams, a media-server
    /// item, local or network-share files matched to the title
    /// (`hasLocalGroup`), or a finished download. An IPTV playlist, a network
    /// share or a media server merely being added is not one — counting them
    /// hid "Watch on <service>" on every catalog title (iPad v2, 2026-10-01).
    /// Metadata-only add-ons are not routes either.
    public static func hasPlaybackRoute(
        item: AppleCatalogItem,
        sources: [AppleSource],
        hasLocalGroup: Bool = false,
        hasCompletedDownload: Bool = false,
        episodesUnavailable: Bool = false
    ) -> Bool {
        if AppleMediaServerItemReference.parse(item.mediaID) != nil || hasLocalGroup { return true }
        if hasCompletedDownload { return true }
        if item.type == "series", episodesUnavailable { return false }
        return sources.contains { source in
            source.isEnabled && source.isAddon
                && source.resources.contains { $0.caseInsensitiveCompare("stream") == .orderedSame }
        }
    }

    /// Where the hero's own episode lookup stands, for a series.
    public enum HeroEpisodeLookup: Equatable, Sendable {
        /// Still out, inside `heroTrailerLookupPatience`.
        case pending
        /// Never answered in time, or not looked up: no evidence either way.
        case unknown
        /// Answered with at least one episode.
        case found
        /// Answered with none — the title page will say "Episodes aren't
        /// available" and its Play is not offered.
        case empty
    }

    /// The hero's route: the title page's `hasPlaybackRoute`, fed with what
    /// the hero's episode lookup found. An empty answer is the title page's
    /// "Episodes aren't available", so the hero must not promise Play: it
    /// did, for Monster: The Lizzie Borden Story with Torrentio off, and the
    /// press ended in "Playback Unavailable" (iOS 18.6 regression
    /// 2026-10-01). A lookup that never answered (`unknown`) is no evidence,
    /// so the hero falls back to the source check (N17e).
    public static func heroHasPlaybackRoute(item: AppleCatalogItem, sources: [AppleSource],
                                             hasLocalGroup: Bool = false,
                                             hasCompletedDownload: Bool = false,
                                             episodeLookup: HeroEpisodeLookup = .unknown) -> Bool {
        hasPlaybackRoute(item: item, sources: sources, hasLocalGroup: hasLocalGroup,
                         hasCompletedDownload: hasCompletedDownload,
                         episodesUnavailable: episodeLookup == .empty)
    }

    /// Whether the hero's route is final: false only while its episode
    /// lookup is out and the answer turns on it (a series whose only route
    /// is a streaming add-on), so the button waits instead of saying Play
    /// and then changing its mind.
    public static func heroRouteIsSettled(item: AppleCatalogItem, sources: [AppleSource],
                                           hasLocalGroup: Bool = false,
                                           hasCompletedDownload: Bool = false,
                                           episodeLookup: HeroEpisodeLookup) -> Bool {
        guard episodeLookup == .pending else { return true }
        let withEpisodes = hasPlaybackRoute(item: item, sources: sources, hasLocalGroup: hasLocalGroup,
                                            hasCompletedDownload: hasCompletedDownload, episodesUnavailable: false)
        let withoutEpisodes = hasPlaybackRoute(item: item, sources: sources, hasLocalGroup: hasLocalGroup,
                                               hasCompletedDownload: hasCompletedDownload, episodesUnavailable: true)
        return withEpisodes == withoutEpisodes
    }

    /// Whether the title page's Play is enabled. It needs a playback route
    /// as well as an episode: with only a metadata add-on, JEOPARDY!'s title
    /// page offered an enabled Play that could only fail, while its hero —
    /// reading the same route — rightly said Details (N17e, iPhone sim).
    public static func canStartPlayback(type: String, hasPlaybackRoute: Bool,
                                        isPreparing: Bool, hasSelectedEpisode: Bool) -> Bool {
        hasPlaybackRoute && !isPreparing && (type != "series" || hasSelectedEpisode)
    }

    /// The title page's one button, or nil when the page has none: nothing
    /// can play and there is no trailer, so the row keeps only My List and
    /// Rate rather than a Play that is greyed out at rest (owner, N22c —
    /// JEOPARDY! with only a metadata add-on). The Apple TV has no trailers,
    /// so there nothing to play is always no button.
    public static func titlePagePrimaryAction(
        type: String,
        progress: ApplePlaybackProgress?,
        selectedEpisode: AppleStremioEpisode?,
        isPlayable: Bool,
        hasTrailer: Bool,
        namesEpisode: Bool = false,
        platform: AppleUIPlatform = .current
    ) -> PrimaryAction? {
        guard isPlayable || (hasTrailer && offersTrailers(on: platform)) else { return nil }
        return primaryAction(type: type, progress: progress, selectedEpisode: selectedEpisode,
                             isPlayable: isPlayable, hasTrailer: hasTrailer,
                             namesEpisode: namesEpisode, platform: platform)
    }

    /// Whether the title page offers Download Season / Download at all: only
    /// when one can start, which is the same route Play needs — a source
    /// that serves streams (a metadata-only add-on cannot) or a media-server
    /// title — or when the title is already downloaded, so its state stays
    /// visible. Otherwise the button is not drawn (N22c).
    public static func offersDownload(item: AppleCatalogItem, sources: [AppleSource],
                                      hasCompletedDownload: Bool = false,
                                      episodesUnavailable: Bool = false) -> Bool {
        hasPlaybackRoute(item: item, sources: sources, hasCompletedDownload: hasCompletedDownload,
                         episodesUnavailable: episodesUnavailable)
    }

    /// An episode row's download control: where a download can start, or on
    /// an episode that is already downloaded (its checkmark stays).
    public static func showsEpisodeDownload(offersDownload: Bool, isDownloaded: Bool) -> Bool {
        offersDownload || isDownloaded
    }

    /// The hero has no episode picker: resume the saved episode, otherwise
    /// use the title page's default. Media servers own their episode list and
    /// resume routing; retain their opaque saved part id for the same label.
    static func heroEpisode(item: AppleCatalogItem, progress: ApplePlaybackProgress?,
                            episodes: [AppleStremioEpisode], completedIDs: Set<String> = [],
                            localResumeEpisode: AppleStremioEpisode? = nil) -> AppleStremioEpisode? {
        if let saved = AppleStremioEpisodePolicy.savedEpisode(progress: progress, in: episodes) { return saved }
        if AppleMediaServerItemReference.parse(item.mediaID) != nil,
           let progress, progress.resumePosition != nil, let part = progress.partID {
            let identity = AppleStremioMetadataClient.episodeIdentity(part)
            return AppleStremioEpisode(id: part, title: "", season: identity?.season,
                                       episode: identity?.episode, releaseInfo: nil)
        }
        if let localResumeEpisode { return localResumeEpisode }
        return AppleStremioEpisodePolicy.upNext(from: episodes, completedIDs: completedIDs)
    }

    /// The button's verb, derived from state rather than an error after the
    /// press (A8 UX note). `progress` is the title's saved position;
    /// `selectedEpisodeID` the episode Play would start. A series only says
    /// Resume when the saved position belongs to that episode, so choosing
    /// another season never leaves the button promising the old one.
    /// `namesEpisode` makes Play say which episode it starts ("Play S1, E3"),
    /// as the Apple TV app's title page does; the heroes keep "Play".
    /// `platform` is where the button is drawn: the Apple TV never offers a
    /// trailer (`offersTrailers(on:)`), so there it says Play.
    public static func primaryAction(
        type: String,
        progress: ApplePlaybackProgress?,
        selectedEpisode: AppleStremioEpisode?,
        isPlayable: Bool,
        hasTrailer: Bool,
        namesEpisode: Bool = false,
        platform: AppleUIPlatform = .current
    ) -> PrimaryAction {
        guard isPlayable else { return hasTrailer && offersTrailers(on: platform) ? .playTrailer : .play }
        let play: PrimaryAction = if namesEpisode, type == "series", let code = selectedEpisode.flatMap(episodeCode) {
            .playEpisode(code)
        } else {
            .play
        }
        guard let progress, progress.resumePosition != nil else { return play }
        if type == "series" {
            guard let selectedEpisode, progress.partID == selectedEpisode.id else { return play }
            return .resume(episode: episodeCode(selectedEpisode))
        }
        return .resume(episode: nil)
    }

    /// The title page's hero art: the first candidate that has not failed
    /// to load, nil once every one has. Candidates are in preference order;
    /// nil entries (art the metadata did not name) are skipped.
    public static func heroArtworkURL(candidates: [URL?], failed: Set<URL>) -> URL? {
        candidates.lazy.compactMap { $0 }.first { !failed.contains($0) }
    }

    /// Whether a platform plays trailers at all. Everywhere but the Apple TV
    /// (owner 2026-09-23: "remove trailers from Apple TV and add them to
    /// Mac"): no trailer on its heroes or title pages, and no lookups for one.
    public static func offersTrailers(on platform: AppleUIPlatform = .current) -> Bool {
        platform != .tvOS
    }

    // MARK: - The hero's button

    /// Where a hero's trailer lookup stands: a title with nothing to play
    /// waits for it before choosing between Play Trailer and Details.
    public enum TrailerAvailability: Equatable, Sendable {
        case none, pending, available
    }

    /// How long a hero holds its button back for the trailer lookups. Past
    /// it, a title with nothing to play and no trailer found yet says
    /// Details (N30: a hero whose lookups never answered showed only the
    /// My List "+"); a trailer that turns up later still makes it Play Trailer.
    public static let heroTrailerLookupPatience: Duration = .seconds(4)

    /// Where the hero's trailer lookup stands. `lookupsAnswered`: every
    /// lookup that can find a trailer has answered; `patienceElapsed`: the
    /// hero has waited `heroTrailerLookupPatience` for them.
    public static func trailerAvailability(hasTrailer: Bool, lookupsAnswered: Bool,
                                           patienceElapsed: Bool) -> TrailerAvailability {
        if hasTrailer { return .available }
        return lookupsAnswered || patienceElapsed ? .none : .pending
    }

    /// The hero's one button (every Discover hero). Never a disabled Play:
    /// nothing to play and no trailer is Details, and while the trailer
    /// lookup that decides between the two is still out the answer is nil —
    /// the button is held back until its label is final.
    public static func heroPrimaryAction(
        type: String,
        progress: ApplePlaybackProgress?,
        selectedEpisode: AppleStremioEpisode?,
        isPlayable: Bool,
        trailer: TrailerAvailability
    ) -> PrimaryAction? {
        if isPlayable {
            return primaryAction(type: type, progress: progress, selectedEpisode: selectedEpisode,
                                 isPlayable: true, hasTrailer: false)
        }
        switch trailer {
        case .available: return .playTrailer
        case .pending: return nil
        case .none: return .details
        }
    }

    /// What the hero's button shows: its words and glyph. `action == nil`
    /// keeps the button's place without showing it. A pressed Play Trailer
    /// keeps its label: trailers are art-first and have no loading state
    /// (`AppleTrailerArtFirstPolicy`).
    public struct HeroButton: Equatable, Sendable {
        public let action: PrimaryAction?
        public let title: String
        public let systemImage: String

        public var isHidden: Bool { action == nil }

        public init(action: PrimaryAction?, isDownloaded: Bool = false) {
            self.action = action
            title = (action ?? .play).displayTitle(hasCompletedDownload: isDownloaded)
            systemImage = (action ?? .play).systemImage
        }
    }

    /// "S4, E8" — the Apple TV app's spelling. Nil without a season and number.
    public static func episodeCode(_ episode: AppleStremioEpisode) -> String? {
        guard let season = episode.season, let number = episode.episode else { return nil }
        return "S\(season), E\(number)"
    }

    /// "S4, E8 · Follow the Anger" over the next episode's synopsis.
    public static func nextEpisodeHeading(_ episode: AppleStremioEpisode) -> String? {
        let code = episodeCode(episode)
        let title = episode.title.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (code, title.isEmpty) {
        case (let code?, false): return "\(code) · \(title)"
        case (let code?, true): return code
        case (nil, false): return title
        case (nil, true): return nil
        }
    }

    // MARK: - Schedule badge

    /// "New Episode Every Wednesday" when the show is airing weekly — its last
    /// three episodes of the current season came out seven days apart on the
    /// same weekday, and the newest aired in the last eight days or the next
    /// one is announced within eight. Otherwise the home hero's "New Season" /
    /// "New Episode" rule, and otherwise nothing.
    public static func scheduleBadge(
        type: String,
        episodes: [AppleHeroBadge.Episode],
        now: Date,
        calendar: Calendar = utcCalendar()
    ) -> String? {
        guard type.lowercased() == "series" else { return nil }
        let regular = episodes.filter { $0.season > 0 && $0.episode > 0 }
        let aired = regular.filter { $0.released <= now }
            .sorted { ($0.released, $0.season, $0.episode) < ($1.released, $1.season, $1.episode) }
        let upcoming = regular.filter { $0.released > now }.min { $0.released < $1.released }
        let week: TimeInterval = 7 * 24 * 60 * 60
        let slack: TimeInterval = 12 * 60 * 60
        if let latest = aired.last {
            let season = aired.filter { $0.season == latest.season }.suffix(3)
            let dates = season.map(\.released)
            let intervals = zip(dates.dropFirst(), dates).map { $0.timeIntervalSince($1) }
            let weekdays = Set(dates.map { calendar.component(.weekday, from: $0) })
            let isWeekly = intervals.count >= 2
                && intervals.allSatisfy { abs($0 - week) <= slack }
                && weekdays.count == 1
            let isCurrent = now.timeIntervalSince(latest.released) <= week + 24 * 60 * 60
                || (upcoming.map { $0.released.timeIntervalSince(now) <= week + 24 * 60 * 60 } ?? false)
            if isWeekly, isCurrent, let weekday = weekdays.first {
                return "New Episode Every \(calendar.weekdaySymbols[weekday - 1])"
            }
        }
        return AppleHeroBadge.select(type: type, episodes: episodes, now: now)?.title
    }

    /// "EPISODE 8", or "EPISODE 8 · COMING WEDNESDAY" / "· COMING SEP 30" for
    /// one that has not aired — an appointment, not a greyed-out tile (A10).
    public static func episodeEyebrow(
        _ episode: AppleStremioEpisode,
        now: Date,
        calendar: Calendar = utcCalendar()
    ) -> String {
        var parts: [String] = []
        if let number = episode.episode {
            parts.append(episode.season == 0 ? "SPECIAL \(number)" : "EPISODE \(number)")
        } else {
            parts.append(episode.season == 0 ? "SPECIAL" : "EPISODE")
        }
        if let released = AppleHeroBadge.releaseDate(episode.releaseInfo), released > now {
            let days = released.timeIntervalSince(now) / (24 * 60 * 60)
            if days < 7 {
                parts.append("COMING \(calendar.weekdaySymbols[calendar.component(.weekday, from: released) - 1].uppercased())")
            } else {
                let formatter = DateFormatter()
                formatter.calendar = calendar
                formatter.timeZone = calendar.timeZone
                formatter.locale = calendar.locale ?? .current
                formatter.setLocalizedDateFormatFromTemplate("MMMd")
                parts.append("COMING \(formatter.string(from: released).uppercased())")
            }
        }
        return parts.joined(separator: " · ")
    }

    /// Released dates arrive as midnight UTC, so their weekday is read in UTC.
    public static func utcCalendar(locale: Locale = .current) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        calendar.locale = locale
        return calendar
    }

    // MARK: - Capability chips and what they mean

    /// "4K · HDR · CC · SDH · AD" from the title's own format badges, best
    /// first, unknown values dropped. The content rating is not a capability;
    /// it rides on the meta line.
    public static func capabilityChips(formatBadges: [String]) -> [String] {
        AppleTitleMetadataPresentation.orderedBadges(contentRating: nil, formatBadges: formatBadges, limit: 8)
            .filter { !AppleTitleMetadataPresentation.isContentRating($0) }
    }

    /// The accessibility chips shown in the hero, each spelled out (A13): the
    /// compressed badge and its meaning on the same page.
    public static func accessibilityGlossary(chips: [String]) -> [(badge: String, meaning: String)] {
        let meanings: [(String, String)] = [
            ("CC", "Closed captions (CC) are subtitles in the available language that also describe relevant sounds that aren’t dialogue."),
            ("SDH", "Subtitles for the deaf and hard of hearing (SDH) are subtitles in the original language that also describe relevant sounds that aren’t dialogue."),
            ("AD", "Audio descriptions (AD) are a narration track that describes what is happening on screen, for people who are blind or have low vision."),
        ]
        let present = Set(chips.map { $0.uppercased() })
        return meanings.filter { present.contains($0.0) }.map { (badge: $0.0, meaning: $0.1) }
    }

    /// The 16:9 still YouTube keeps for a video (no letterbox bars).
    public static func trailerThumbnailURL(for key: String?) -> URL? {
        guard let key = AppleTrailerPreviewPolicy.validYouTubeKey(key) else { return nil }
        return URL(string: "https://i.ytimg.com/vi/\(key)/mqdefault.jpg")
    }

    // MARK: - Reference blocks

    public struct Fact: Equatable, Sendable, Identifiable {
        public let label: String
        public let value: String
        public var id: String { label }

        public init(label: String, value: String) {
            self.label = label
            self.value = value
        }
    }

    /// Released · Rated · Region of Origin, each only when known.
    public static func information(
        year: Int?,
        releaseInfo: String?,
        contentRating: String?,
        countries: [String]
    ) -> [Fact] {
        var facts: [Fact] = []
        let release = year.map(String.init)
            ?? AppleTitleMetadataPresentation.formattedReleaseInfo(releaseInfo)
        if let release { facts.append(Fact(label: "Released", value: release)) }
        if let rating = AppleBillboardCopy.ratingBadge(contentRating) {
            facts.append(Fact(label: "Rated", value: rating))
        }
        let regions = cleanList(countries)
        if !regions.isEmpty {
            facts.append(Fact(label: regions.count == 1 ? "Region of Origin" : "Regions of Origin",
                              value: regions.joined(separator: ", ")))
        }
        return facts
    }

    /// Original Audio, then the other spoken languages. Subtitle languages
    /// are only known once a stream is open, so there is no row for them.
    public static func languages(originalLanguage: String?, spokenLanguages: [String]) -> [Fact] {
        var facts: [Fact] = []
        let original = originalLanguage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !original.isEmpty { facts.append(Fact(label: "Original Audio", value: original)) }
        let spoken = cleanList(spokenLanguages)
        if !spoken.isEmpty, spoken != [original] {
            facts.append(Fact(label: "Audio", value: spoken.joined(separator: ", ")))
        }
        return facts
    }

    /// The Cast & Crew rail: the detailed credits when the metadata has them
    /// (portraits, characters), otherwise the bare names — cast as "Actor",
    /// then the director and writers. One entry per person, at most 20.
    public static func credits(
        detailed: [AppleCreditPerson],
        cast: [String],
        director: String?,
        writers: [String]
    ) -> [AppleCreditPerson] {
        let people = !detailed.isEmpty
            ? detailed
            : cleanList(cast).map { AppleCreditPerson(name: $0, role: "Actor") }
                + cleanList([director].compactMap { $0 }).map { AppleCreditPerson(name: $0, role: "Director") }
                + cleanList(writers).map { AppleCreditPerson(name: $0, role: "Writer") }
        var seen = Set<String>()
        return people.filter { !$0.name.isEmpty && seen.insert($0.name.lowercased()).inserted }
            .prefix(20).map { $0 }
    }

    /// `people` with a portrait for anyone who has none, taken from the same
    /// name in `others`: the add-on that wins the merge can name a person
    /// without a picture that another source (TMDB, a second add-on) has.
    public static func fillingPortraits(_ people: [AppleCreditPerson], from others: [AppleCreditPerson]) -> [AppleCreditPerson] {
        guard people.contains(where: { $0.portraitURL == nil }) else { return people }
        var portraits: [String: URL] = [:]
        for person in others {
            if let url = person.portraitURL, portraits[person.name.lowercased()] == nil {
                portraits[person.name.lowercased()] = url
            }
        }
        guard !portraits.isEmpty else { return people }
        return people.map { person in
            guard person.portraitURL == nil, let url = portraits[person.name.lowercased()] else { return person }
            return AppleCreditPerson(name: person.name, role: person.role, portraitURL: url)
        }
    }

    /// A display name for a language code ("en" → "English"), or the value
    /// itself when it is already a name.
    public static func languageName(_ value: String?, locale: Locale = .current) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if value.count <= 3, value.allSatisfy(\.isLetter),
           let name = locale.localizedString(forLanguageCode: value.lowercased()) {
            return name
        }
        return value
    }

    /// A display name for a region code ("GB" → "United Kingdom"), or the
    /// value itself when it is already a name. Cinemeta writes the two most
    /// common countries as "usa" and "uk".
    public static func regionName(_ value: String?, locale: Locale = .current) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        let aliases = ["USA": "US", "UK": "GB"]
        let code = aliases[value.uppercased()] ?? value.uppercased()
        if code.count == 2, code.allSatisfy(\.isLetter),
           let name = locale.localizedString(forRegionCode: code) {
            return name
        }
        return value.count <= 3 && value.allSatisfy(\.isLetter) ? value.uppercased() : value
    }

    private static func cleanList(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }
}
