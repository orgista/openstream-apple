import Foundation

/// One person on a title page's Cast & Crew rail: who, what they did, and a
/// portrait when the metadata has one.
public struct AppleCreditPerson: Equatable, Hashable, Sendable, Identifiable, Codable {
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
            self == .details ? AppleSemanticAction.info.symbol : AppleSemanticAction.play.symbol
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
    /// can play THIS title: a media-server item, local or network-share files
    /// matched to the title (`hasLocalGroup`), or a finished download. An IPTV
    /// playlist, a network share or a media server merely being added is not
    /// one — counting them hid "Watch on <service>" on every catalog title
    /// (iPad v2, 2026-10-01).
    public static func hasPlaybackRoute(item: AppleCatalogItem, hasLocalGroup: Bool = false,
                                        hasCompletedDownload: Bool = false, hasServerMatch: Bool = false) -> Bool {
        AppleMediaServerItemReference.parse(item.mediaID) != nil || hasLocalGroup || hasCompletedDownload || hasServerMatch
    }

    /// Whether the title page's Play is enabled. It needs a playback route
    /// as well as an episode: with no playable source, JEOPARDY!'s title
    /// page offered an enabled Play that could only fail, while its hero —
    /// reading the same route — rightly said Details (N17e, iPhone sim).
    /// `picksEpisodeAtStart`: the episode is chosen when Play is pressed, as
    /// a media-server series does when its list has not arrived yet.
    public static func canStartPlayback(type: String, hasPlaybackRoute: Bool,
                                        isPreparing: Bool, hasSelectedEpisode: Bool,
                                        picksEpisodeAtStart: Bool = false) -> Bool {
        hasPlaybackRoute && !isPreparing && (type != "series" || hasSelectedEpisode || picksEpisodeAtStart)
    }

    /// The server episode Play starts: the one picked on the page, else the
    /// reference itself when it is an episode, else the start pick from the
    /// detail Play fetched (pressed before the page's own list arrived).
    /// A series id never stands in for an episode: nil, and Play reports it.
    static func serverEpisodeToPlay(selectedID: String?, startID: String?, referenceID: String,
                                    referenceIsEpisode: Bool,
                                    episodesBySeason: [String: [AppleMediaServerItem]]) -> AppleMediaServerItem? {
        let episodes = episodesBySeason.values.flatMap { $0 }
        return [selectedID, referenceIsEpisode ? referenceID : nil, startID].lazy.compactMap { id in
            id.flatMap { id in episodes.first { $0.id == id && $0.type == .episode } }
        }.first
    }

    /// An episode its server lists under no series: the page opens it on
    /// its own and Play starts it.
    static func standaloneServerEpisode(in detail: AppleMediaServerLibraryStore.AppleMediaServerDetail) -> AppleMediaServerItem? {
        detail.item.type == .episode && detail.episodesBySeason.isEmpty ? detail.item : nil
    }

    /// Where the title page's Cast & Crew comes from.
    public enum CreditOrigin: Equatable, Sendable { case page, catalog }

    /// The page's own details win when they have credits; until they do, a
    /// media-server title draws the catalog's (TMDB, cached on disk), which
    /// do not wait on the server (owner recording 2026-11-04: Chernobyl's
    /// Cast & Crew "took a while"). Whichever drew first keeps the section,
    /// so the portraits never swap under the viewer.
    public static func creditOrigin(pageHasCredits: Bool, catalogHasCredits: Bool,
                                    shown: CreditOrigin?) -> CreditOrigin? {
        if let shown { return shown }
        if pageHasCredits { return .page }
        return catalogHasCredits ? .catalog : nil
    }

    /// Whether Play waits for the page to finish preparing. A media-server
    /// title's route is its id, and Play asks the server for the item when it
    /// is pressed, so it does not wait on the page's own detail call: against
    /// a failing server that call took 1.2 s or never answered, and Play sat
    /// greyed out (owner recording 2026-11-04, Chernobyl).
    public static func playWaitsForPreparation(isPreparing: Bool, isMediaServerTitle: Bool) -> Bool {
        isPreparing && !isMediaServerTitle
    }

    /// The title page's one button, or nil when the page has none: nothing
    /// can play and there is no trailer, so the row keeps only My List and
    /// Rate rather than a Play that is greyed out at rest (owner, N22c —
    /// JEOPARDY! with no playable source). The Apple TV has no trailers,
    /// so there nothing to play is always no button.
    public static func titlePagePrimaryAction(
        type: String,
        progress: ApplePlaybackProgress?,
        selectedEpisode: AppleMediaEpisode?,
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
    /// when one can start, which is the same route Play needs — a media-server
    /// title — or when the title is already downloaded, so its state stays
    /// visible. Otherwise the button is not drawn (N22c).
    public static func offersDownload(item: AppleCatalogItem, hasCompletedDownload: Bool = false) -> Bool {
        hasPlaybackRoute(item: item, hasCompletedDownload: hasCompletedDownload)
    }

    /// An episode row's download control: where a download can start, or on
    /// an episode that is already downloaded (its checkmark stays).
    public static func showsEpisodeDownload(offersDownload: Bool, isDownloaded: Bool) -> Bool {
        offersDownload || isDownloaded
    }

    static func localDestinationGroup(source: AppleSource, matchingGroups: [AppleLibrarySeries]) -> AppleLibrarySeries? {
        guard source.kind == .nas else { return nil }
        return matchingGroups.first { $0.items.first?.sourceID == source.id }
    }

    /// Which page a pushed title shows, decided once. A NAS card tapped
    /// before the library publishes its group (cold launch) waits for it
    /// instead of opening the catalog page and swapping to the local page
    /// when the scan lands, which threw the page's state away.
    struct TitleDestinationChoice: Equatable {
        enum Page: Equatable {
            case local(AppleLibrarySeries)
            case catalog
        }

        static let groupWait: Duration = .seconds(3)
        private(set) var page: Page?

        /// `groupCanStillArrive`: a NAS title whose library has not loaded
        /// and whose wait has not expired.
        mutating func update(group: AppleLibrarySeries?, groupCanStillArrive: Bool) {
            guard page == nil else { return }
            if let group {
                page = .local(group)
            } else if !groupCanStillArrive {
                page = .catalog
            }
        }
    }

    struct ServerDestination {
        private(set) var item: AppleCatalogItem
        private(set) var initialEpisodeID: String?
        private(set) var isResolved = false
        private var consumedInitialEpisode = false
        private var launchedEpisodeID: String?

        init(item: AppleCatalogItem) { self.item = item }

        func displayItem(navigationItem: AppleCatalogItem) -> AppleCatalogItem {
            isResolved ? item : navigationItem
        }

        mutating func resolve(_ destination: (item: AppleCatalogItem, episodeID: String?)) {
            item = destination.item
            if !consumedInitialEpisode { initialEpisodeID = destination.episodeID }
            isResolved = true
        }

        func startEpisodeID(in episodes: [AppleMediaEpisode], fallbackID: String?) -> String? {
            if let initialEpisodeID, episodes.contains(where: { $0.id == initialEpisodeID }) {
                return initialEpisodeID
            }
            return fallbackID
        }

        func offlineItemID(selectedEpisodeID: String?, referenceID: String) -> String {
            selectedEpisodeID ?? initialEpisodeID ?? referenceID
        }

        mutating func selectionChanged(from previous: String?, to selected: String?) {
            guard previous != selected, selected != initialEpisodeID else { return }
            consumeInitialEpisode()
        }

        mutating func playbackStarted(episodeID: String, wasWatched: Bool) {
            launchedEpisodeID = wasWatched ? nil : episodeID
        }

        mutating func playbackCompleted(selectedEpisodeID: String?, watchedEpisodeIDs: Set<String>) -> Bool {
            guard let launchedEpisodeID, watchedEpisodeIDs.contains(launchedEpisodeID) else { return false }
            self.launchedEpisodeID = nil
            guard selectedEpisodeID == launchedEpisodeID else { return false }
            consumeInitialEpisode()
            return true
        }

        private mutating func consumeInitialEpisode() {
            initialEpisodeID = nil
            consumedInitialEpisode = true
        }
    }

    /// The hero has no episode picker: resume the saved episode, otherwise
    /// use the title page's default. Media servers own their episode list and
    /// resume routing; retain their opaque saved part id for the same label.
    static func heroEpisode(item: AppleCatalogItem, progress: ApplePlaybackProgress?,
                            episodes: [AppleMediaEpisode], completedIDs: Set<String> = [],
                            localResumeEpisode: AppleMediaEpisode? = nil) -> AppleMediaEpisode? {
        if let saved = AppleMediaEpisodePolicy.savedEpisode(progress: progress, in: episodes) { return saved }
        if AppleMediaServerItemReference.parse(item.mediaID) != nil,
           let progress, progress.resumePosition != nil, let part = progress.partID {
            let identity = AppleMediaIdentifier.episodeIdentity(part)
            return AppleMediaEpisode(id: part, title: "", season: identity?.season,
                                       episode: identity?.episode, releaseInfo: nil)
        }
        if let localResumeEpisode { return localResumeEpisode }
        return AppleMediaEpisodePolicy.upNext(from: episodes, completedIDs: completedIDs)
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
        selectedEpisode: AppleMediaEpisode?,
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

    /// YouTube trailers need WebKit. Apple TV instead plays direct server
    /// trailers (`AppleTrailerSourcePolicy`, owner 2026-10-15).
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
        selectedEpisode: AppleMediaEpisode?,
        isPlayable: Bool,
        trailer: TrailerAvailability,
        playabilityKnown: Bool = true
    ) -> PrimaryAction? {
        if isPlayable {
            return primaryAction(type: type, progress: progress, selectedEpisode: selectedEpisode,
                                 isPlayable: true, hasTrailer: false)
        }
        guard playabilityKnown else { return nil }
        switch trailer {
        case .available: return .playTrailer
        case .pending: return nil
        case .none: return .details
        }
    }

    /// What the hero's button shows: its words and glyph. `action == nil`
    /// keeps its place without showing it. A pressed Play Trailer
    /// keeps its label: trailers are art-first and have no loading state
    /// (`AppleTrailerArtFirstPolicy`).
    public struct HeroButton: Equatable, Sendable {
        public let action: PrimaryAction?
        public let title: String
        public let systemImage: String

        public var isHidden: Bool { action == nil }

        /// A Details primary already opens the title page; another info
        /// button would offer the same action twice.
        public var showsDetailsButton: Bool { action != .details }

        public init(action: PrimaryAction?, isDownloaded: Bool = false) {
            self.action = action
            title = (action ?? .play).displayTitle(hasCompletedDownload: isDownloaded)
            systemImage = (action ?? .play).systemImage
        }
    }

    struct HeroButtonSelection: Equatable {
        let page: String
        let button: HeroButton

        init(page: String, action: PrimaryAction?, isDownloaded: Bool = false, retaining previous: Self? = nil) {
            self.page = page
            if let previous, previous.page == page {
                button = previous.button
            } else {
                // Details stays usable even when a library scan never finishes.
                button = HeroButton(action: action ?? .details, isDownloaded: isDownloaded)
            }
        }
    }

    /// "S4, E8" — the Apple TV app's spelling. Nil without a season and number.
    public static func episodeCode(_ episode: AppleMediaEpisode) -> String? {
        guard let season = episode.season, let number = episode.episode else { return nil }
        return "S\(season), E\(number)"
    }

    /// "S4, E8 · Follow the Anger" over the next episode's synopsis.
    public static func nextEpisodeHeading(_ episode: AppleMediaEpisode) -> String? {
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
        _ episode: AppleMediaEpisode,
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

    // MARK: - Capability chips

    /// "4K · HDR · CC · SDH · AD" from the title's own format badges, best
    /// first, unknown values dropped. The content rating is not a capability;
    /// it rides on the meta line.
    public static func capabilityChips(formatBadges: [String]) -> [String] {
        AppleTitleMetadataPresentation.orderedBadges(contentRating: nil, formatBadges: formatBadges, limit: 8)
            .filter { !AppleTitleMetadataPresentation.isContentRating($0) }
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
    /// name in `others`: the source that wins the merge can name a person
    /// without a picture that another source (TMDB) has.
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
    /// value itself when it is already a name. Some metadata writes the two
    /// most common countries as "usa" and "uk".
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

/// The title page sections the viewer keeps (Settings › Title Page, owner
/// 2026-10-28). Every layout reads its sections through these, so one switch
/// hides its section on the iPhone, iPad, Mac, Apple TV and Vision Pro alike.
struct AppleTitlePageSectionVisibility: Equatable, Sendable {
    var trailers = true
    var castAndCrew = true
    var information = true
    var about = true

    func trailerKeys(_ keys: [String]) -> [String] { trailers ? keys : [] }

    func credits(_ people: [AppleCreditPerson]) -> [AppleCreditPerson] { castAndCrew ? people : [] }

    /// Information and Languages: both are the facts block under About.
    func facts(_ facts: [AppleTitlePagePolicy.Fact]) -> [AppleTitlePagePolicy.Fact] { information ? facts : [] }

    func aboutSummary(_ summary: String?) -> String? { about ? summary : nil }

    /// Where the synopsis under the buttons is the page's only one (Apple TV,
    /// iPad, Vision Pro), About off cuts it to the hero's three lines.
    var synopsisLineLimit: Int? { about ? nil : 3 }
}
