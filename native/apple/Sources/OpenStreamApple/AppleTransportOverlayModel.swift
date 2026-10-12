import Foundation
import Observation

/// Backing model for `AppleTransportOverlay` on surface and full-screen Live routes. It mirrors
/// the engine's position/duration/tracks through `events` into observable
/// stored properties, applies the transport policy table (scrubbability, time
/// formatting, live/DVR behaviour), and owns the 3-second control auto-hide
/// timer. The view stays declarative; this type owns the state.
///
/// VOD uses this transport on `.surface`; full-screen Live also uses it on
/// `.avPlayer`. Stock and inline players share `AppleSubtitleCueLayer` and
/// use `AppleStockPlayerSubtitles` when they own their controls.
///
/// Policy table (see T5 spec):
/// - VOD with a known duration → scrubber enabled, `m:ss` / `h:mm:ss` times.
/// - live the player reports no usable rewind for → scrubber and skip buttons
///   hidden, "LIVE" badge, empty times.
/// - live with a real seekable range (`liveSeekableRange`, wider than
///   `AppleLiveSeekPolicy.minimumUsefulSpan`) → scrubber over that range; the
///   "LIVE" badge is tappable to seek back to the live edge.
@MainActor
@Observable
public final class AppleTransportOverlayModel {
    /// The coordinator whose engine is driving playback.
    public let coordinator: ApplePlaybackCoordinator

    /// Whether the current request is a live stream. Set once at construction;
    /// the view passes `request.isLive`.
    public let isLive: Bool

    /// What the stream can ACTUALLY be seeked within, mirrored from the engine
    /// on every position tick. Nil until the player reports one, and nil for a
    /// live-edge-only source that can never rewind.
    ///
    /// Every live seek and every live readout is computed from this, not from
    /// `dvrWindowSeconds`: that number is the load hint, identical (1800) for
    /// every live channel, and clamping against it is why skip-back on a live
    /// channel moved nothing a viewer could see (owner, GUI audit 2026-09-19).
    public private(set) var liveSeekableRange: AppleSeekableRange? = nil

    /// Presentation route. Seeded from the coordinator in `init` and updated
    /// when the engine emits a `.route` event; drives whether the overlay and
    /// its waiting indicator are shown at all.
    public var route: ApplePlaybackPresentationRoute = .none

    /// Starts the next episode. Set by whatever presented the player and knows
    /// the season; nil for a movie, a live channel or the last episode.
    public var nextEpisode: (() -> Void)? = nil { didSet { syncEndHandOff() } }
    /// The next episode's `displayTitle`, for the card to name it. Set
    /// alongside `nextEpisode`; one without the other offers nothing.
    public var nextEpisodeTitle: String? = nil { didSet { syncEndHandOff() } }
    /// The viewer's "Auto Play Next Episode" setting. With it off the card
    /// still appears and still works — only the unattended start stops.
    public var autoPlayNextEpisode: Bool = true { didSet { syncEndHandOff() } }
    /// Set when the viewer dismisses the card, which also stops the
    /// auto-advance for the rest of the episode. Cleared on the next load.
    public private(set) var nextEpisodeDismissed = false { didSet { syncEndHandOff() } }
    /// Guards against firing the advance twice: the position observer ticks
    /// four times a second and the end can be reported more than once.
    /// Held by the coordinator, like `pendingAudioPick`: SwiftUI can build
    /// more than one model for the same player, and each one fired the advance
    /// (2-3 starts per episode on the iPhone 27 sim).
    private var hasAdvancedToNextEpisode: Bool {
        get { coordinator.hasAdvancedToNextEpisode }
        set { coordinator.hasAdvancedToNextEpisode = newValue }
    }

    /// The stream's opening sequence, from its own chapter markers. Nil for
    /// content that carries none, which is most of it — see
    /// `AppleChapterMarkers`.
    public var introChapter: AppleChapter? = nil
    /// Sticky for the rest of the item: seeking back into the opening after
    /// skipping must not put the button up again. It ends with the item —
    /// see `clearIntroForNewItem()`, because this model outlives a load
    /// whenever the viewer switches source or channel inside the player.
    public private(set) var hasSkippedIntro = false

    /// Whether the Skip Intro button belongs on screen right now.
    public var showsSkipIntro: Bool {
        AppleChapterMarkers.shouldOfferSkip(
            position: position,
            intro: introChapter,
            hasSkipped: hasSkippedIntro
        )
    }

    /// Seeks to the first frame after the opening, through the same
    /// coordinator path the scrubber uses.
    public func skipIntro() async {
        guard let introChapter else { return }
        hasSkippedIntro = true
        bumpActivity()
        let destination = AppleChapterMarkers.skipDestination(intro: introChapter)
        appleTrace("skip intro → \(Int(destination))s")
        await coordinator.userSeek(to: destination)
    }

    /// Re-derives the opening from the engine's markers and whatever runtime is
    /// known now. Idempotent and write-guarded, so calling it from both
    /// `.tracks` and `.duration` costs no extra Observation invalidation.
    private func refreshIntroChapter() {
        let all = coordinator.engine.chapters
        if chapters != all { chapters = all }
        let found = AppleChapterMarkers.intro(in: all, duration: duration)
        if introChapter != found { introChapter = found }
    }

    /// Every chapter the stream carries, for the scrubber marks and the
    /// Chapters menu. The engine reported them and nothing showed them
    /// (full test 2026-09-30: 16 for Top Gun: Maverick).
    public private(set) var chapters: [AppleChapter] = []

    /// Where the chapter marks sit on the scrubber, as fractions of it.
    public var chapterMarkFractions: [Double] {
        AppleChapterMarkers.scrubberFractions(chapters: chapters, duration: duration)
    }

    /// Seeks to a chapter's start through the scrubber's path.
    public func jump(to chapter: AppleChapter) async {
        bumpActivity()
        appleTrace("chapter → \(chapter.title) at \(Int(chapter.start))s")
        await coordinator.userSeek(to: max(0, chapter.start))
    }

    /// Re-reads the engine's real seekable span. Write-guarded: the position
    /// observer ticks four times a second and an unchanged range must not
    /// invalidate every Observation reader of this model.
    private func refreshSeekableRange() {
        // Live only. A VOD item's seekable range grows as it buffers, and
        // mirroring that at four ticks a second would invalidate every
        // Observation reader of this model — the track menu included — for a
        // value nothing on a VOD screen reads.
        let found = isLive ? coordinator.engine.seekableRange : nil
        if liveSeekableRange != found { liveSeekableRange = found }
    }

    /// Drops the opening and the sticky skip when the engine leaves the item.
    private func clearIntroForNewItem() {
        if introChapter != nil { introChapter = nil }
        if hasSkippedIntro { hasSkippedIntro = false }
    }

    /// The end-of-episode card, or nil when there is nothing to offer yet.
    public var nextEpisodePrompt: AppleNextEpisodePrompt? {
        // A provider's error clip is not the episode ending.
        guard nextEpisode != nil, !coordinator.isPlaceholderPlayback else { return nil }
        return AppleNextEpisodePolicy.prompt(
            position: position,
            duration: duration,
            nextTitle: nextEpisodeTitle,
            isLive: isLive,
            isDismissed: nextEpisodeDismissed
        )
    }

    /// The viewer saying "no". Hides the card and cancels the auto-advance
    /// until another episode loads.
    public func dismissNextEpisode() {
        nextEpisodeDismissed = true
        bumpActivity()
    }

    /// Tells the player whether `.ended` hands over to the next episode
    /// (stay open) or closes it.
    private func syncEndHandOff() {
        coordinator.handsOffAtEnd = AppleNextEpisodePolicy.handsOffAtEnd(
            hasNext: nextEpisode != nil && nextEpisodeTitle != nil, isLive: isLive,
            isDismissed: nextEpisodeDismissed, isEnabled: autoPlayNextEpisode)
    }

    /// Starts the next episode now, from the card.
    public func playNextEpisode() {
        guard let nextEpisode else { return }
        hasAdvancedToNextEpisode = true
        // This one stays on screen until the next is ready; it must not keep
        // talking over the wait.
        coordinator.userPause()
        nextEpisode()
    }

    /// Whether the transport controls are currently visible. Auto-hides 3 s
    /// after the last interaction while playing; any interaction re-shows them.
    public private(set) var controlsVisible: Bool = true

    // MARK: - Mirrored engine state

    public private(set) var position: Double = 0
    public private(set) var duration: Double? = nil
    public private(set) var audioTracks: [ApplePlaybackTrack] = []
    /// The audio track playing: the engine's report, else the last pick.
    public private(set) var selectedAudioID: Int?
    /// The audio track the viewer picked that the engine has not reported
    /// yet. An audio switch rebuilds the pipeline, and until it lands the
    /// engine still reports the old track; adopting that put the check back
    /// on English after Spanish was chosen (Apple TV verification 2026-10-01).
    /// Held by the coordinator: the overlay can be rebuilt mid-switch.
    private var pendingAudioID: Int? {
        get { coordinator.pendingAudioPick }
        set { coordinator.pendingAudioPick = newValue }
    }
    /// Every embedded track, unfiltered. `menuSubtitleTracks` is what the
    /// captions menu lists.
    public private(set) var subtitleTracks: [ApplePlaybackTrack] = []

    /// The viewer's chosen subtitle languages; the menu lists only these.
    /// Empty means the device's primary language
    /// (`AppleSubtitleTrackFilter.effectiveLanguages`).
    public var preferredSubtitleLanguages: [String] = []
    /// See `AetherPlaybackEngine.subtitleLanguagesAreExplicit`.
    public var subtitleLanguagesAreExplicit = false

    /// The tracks in the viewer's languages, best first.
    public var visibleSubtitleTracks: [ApplePlaybackTrack] {
        AppleSubtitleTrackFilter.visible(
            subtitleTracks,
            preferredLanguages: preferredSubtitleLanguages,
            isExplicitChoice: subtitleLanguagesAreExplicit)
    }

    /// The manual choices in the viewer's languages, SDH and forced variants included.
    public var menuSubtitleTracks: [ApplePlaybackTrack] {
        AppleSubtitleTrackFilter.menu(subtitleTracks, preferredLanguages: preferredSubtitleLanguages,
                                      activeTrackID: selectedSubtitleID)
    }

    /// Decoded cues for the active subtitle track, mirrored from the engine for
    /// the overlay to render on either video route.
    public private(set) var subtitleCues: [AppleSubtitleCue] = []

    /// The engine's `presentationTime`: the frame on screen, which cues follow.
    /// Kept apart from `position`, the scrub clock, which the engine can hold.
    public private(set) var cueTime: Double = 0

    /// The subtitle track the user selected through the overlay, tracked locally
    /// so the CC button reflects the selection immediately (before the engine
    /// confirms it) and so the model test can assert it without a live engine.
    public private(set) var selectedSubtitleID: Int? = nil

    // MARK: - Private

    private var observationTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    /// Three seconds of stillness hides the chrome. A UI test cannot read a
    /// button's frame and its neighbour's inside that window — the second query
    /// lands after the timer — so the crawler and the live photo tests launch
    /// with `-OpenStreamHoldPlayerChrome YES` and the timer stands down.
    /// iPhone and iPad Live hold it four seconds, as the system player does.
    private var hideDelay: Duration {
        if Self.chromeIsHeldOpen { return .seconds(600) }
        #if os(iOS)
        if isLive { return .seconds(AppleLiveSystemChromePolicy.autoHideSeconds) }
        #endif
        return .seconds(3)
    }

    static let chromeIsHeldOpen: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-OpenStreamHoldPlayerChrome")
            || UserDefaults.standard.bool(forKey: "OpenStreamHoldPlayerChrome")
        #else
        return false
        #endif
    }()

    public init(coordinator: ApplePlaybackCoordinator, isLive: Bool) {
        self.coordinator = coordinator
        self.isLive = isLive
        // Seed from the engine's current synchronous state so the first render
        // is correct before any event has been emitted.
        self.position = coordinator.engine.position
        self.cueTime = coordinator.engine.presentationTime
        self.duration = coordinator.engine.duration
        self.audioTracks = coordinator.engine.audioTracks
        // A switch can outlive this overlay: the route leaves `.surface`
        // while the pipeline rebuilds and a new overlay is built after it.
        self.selectedAudioID = AppleTrackSelectionPolicy.audio(
            engineActive: coordinator.engine.activeAudioTrackID,
            pending: coordinator.pendingAudioPick, current: nil)
        self.subtitleTracks = coordinator.engine.subtitleTracks
        self.chapters = coordinator.engine.chapters
        self.introChapter = AppleChapterMarkers.intro(
            in: coordinator.engine.chapters,
            duration: coordinator.engine.duration
        )
        // The same persisted list the coordinator reads when no host hands it
        // one, so the menu and the auto-selection agree on the languages. The
        // key existing *is* the explicit choice — `AppleSettingsStore` derives
        // `hasChosenSubtitleLanguages` from exactly this — so a viewer who
        // picked English gets a menu of English and nothing else.
        let chosen = UserDefaults.standard.stringArray(forKey: AppleSubtitleLanguages.defaultsKey)
        self.preferredSubtitleLanguages = chosen ?? []
        self.subtitleLanguagesAreExplicit = chosen != nil
        self.route = coordinator.route
        self.liveSeekableRange = isLive ? coordinator.engine.seekableRange : nil
        // The engine may already have auto-selected a track from the viewer's
        // captions preference before the overlay existed. Without this the CC
        // key would open reading "off" over a picture with captions on it.
        self.selectedSubtitleID = coordinator.engine.activeSubtitleTrackID
        startObserving()
        scheduleAutoHide()
    }

    // MARK: - Overlay visibility

    /// Whether VOD needs the custom transport. Live hosts can also mount it
    /// on `.avPlayer` in place of AVKit's controls.
    public var showsOverlay: Bool { route == .surface }

    /// `true` when the centered spinning waiting indicator should be shown.
    /// Only on `.surface` routes, and only before the player is ready
    /// (`.resolving` / `.loading`) or while it is buffering / reconnecting
    /// (`.waiting`). On `.avPlayer` routes the system player shows its own
    /// spinner, so this is always `false`.
    ///
    /// A live channel shows it on either route: a stalled channel otherwise
    /// sat on its last frame under a Play glyph (iPad v2 re-run).
    public var showsWaitingIndicator: Bool {
        guard route == .surface || isLive else { return false }
        switch coordinator.phase {
        case .resolving, .loading, .waiting:
            return true
        default:
            return false
        }
    }

    /// A live channel that stalled and is being reconnected: the overlay
    /// says so under the spinner instead of offering Play.
    public var showsReconnecting: Bool {
        guard isLive, case .waiting = coordinator.phase else { return false }
        return true
    }

    /// Text for the waiting indicator's accessibility label. The spinner has
    /// no visible text; this string (the coordinator's waiting message, or a
    /// default while resolving/loading) is exposed to VoiceOver only.
    public var waitingText: String {
        switch coordinator.phase {
        case .waiting(let message): return message ?? "Preparing playback"
        case .resolving: return "Resolving stream"
        case .loading: return "Loading stream"
        default: return "Preparing playback"
        }
    }

    // MARK: - Policy-derived views

    /// `true` when the scrubber should be shown and accept input.
    public var isScrubbable: Bool {
        if isLive {
            // The window the player proves it holds, not the one the request
            // asked for. A sliding-window IPTV playlist with three segments in
            // it gets no scrubber, because there is nothing to scrub.
            return AppleLiveSeekPolicy.offersDVR(liveSeekableRange)
        }
        // VOD: scrubbable once a positive duration is known.
        return (duration ?? 0) > 0
    }

    /// How far behind the live edge the viewer still counts as being at it.
    /// A seek lands a fraction of a second off, and a stream's own edge moves
    /// while the seek is in flight.
    public static let liveEdgeTolerance: Double = 5

    /// `true` while a live stream is playing at its edge — always true for a
    /// live stream with no DVR window, because there is nowhere else to be.
    ///
    /// The LIVE badge is drawn from this. Without it, skipping back ten
    /// seconds on a channel with a DVR window changed nothing a viewer could
    /// see: the badge stayed red, the thumb moved a tenth of a percent, and
    /// live carries no time readout (button crawl, 2026-09-19).
    public var isAtLiveEdge: Bool {
        guard isLive else { return false }
        return AppleLiveSeekPolicy.isAtLiveEdge(
            position: position,
            in: liveSeekableRange,
            tolerance: Self.liveEdgeTolerance
        )
    }

    /// `true` when the ±10 s skip buttons belong on screen: they move the
    /// picture. A live channel with no rewind gets none rather than two that
    /// look enabled and swallow the tap.
    public var canSkip: Bool {
        if isLive { return AppleLiveSeekPolicy.offersDVR(liveSeekableRange) }
        return (duration ?? 0) > 0
    }

    /// `m:ss` or `h:mm:ss` for VOD; empty for live (the LIVE badge carries the
    /// status, DVR or not).
    public var positionText: String {
        isLive ? "" : Self.timeText(position)
    }

    /// Duration label. For VOD this is the media duration; for a DVR live
    /// stream it is the window length; empty for plain live.
    public var durationText: String {
        if isLive {
            guard let range = liveSeekableRange, AppleLiveSeekPolicy.offersDVR(range) else { return "" }
            return Self.timeText(range.span)
        }
        guard let duration, duration > 0 else { return "" }
        return Self.timeText(duration)
    }

    /// `0...1` position within the scrubbed window (media duration for VOD,
    /// DVR window for live-with-DVR). `0` when not scrubbable.
    public var progress: Double {
        guard isScrubbable, position >= 0 else { return 0 }
        if isLive {
            return AppleLiveSeekPolicy.progress(position: position, in: liveSeekableRange)
        }
        guard let duration, duration > 0 else { return 0 }
        return min(1, max(0, position / duration))
    }

    // MARK: - Actions

    public func togglePlayPause() {
        bumpActivity()
        if case .playing = coordinator.phase {
            coordinator.userPause()
        } else {
            coordinator.userPlay()
        }
    }

    /// Seek to `fraction` of the scrubbed window (`0...1`).
    public func scrub(to fraction: Double) async {
        bumpActivity()
        let target: Double
        if isLive {
            guard let live = AppleLiveSeekPolicy.scrubTarget(fraction: fraction, in: liveSeekableRange) else { return }
            target = live
        } else {
            guard let duration, duration > 0 else { return }
            target = min(1, max(0, fraction)) * duration
        }
        await coordinator.userSeek(to: target)
    }

    /// Seek back to the live edge of the DVR window. Bound to the "LIVE" badge.
    public func seekToLiveEdge() async {
        guard isLive, let range = liveSeekableRange, AppleLiveSeekPolicy.offersDVR(range) else { return }
        bumpActivity()
        await coordinator.userSeek(to: range.end)
    }

    public func selectAudio(_ id: Int) {
        bumpActivity()
        pendingAudioID = id
        coordinator.engine.selectAudioTrack(id: id)
        selectedAudioID = id
    }

    public func selectSubtitle(_ id: Int?) {
        bumpActivity()
        coordinator.engine.selectSubtitleTrack(id: id)
        selectedSubtitleID = coordinator.engine.activeSubtitleTrackID
    }

    /// True when a subtitle track is selected; "Off" clears it. Seeded from
    /// the engine's own selection and then driven by the overlay, so it is
    /// the immediate, testable signal that captions are on screen (the
    /// Audio & Subtitles bubble fills while it is set).
    public var isCCActive: Bool { AppleCaptionsToggle.isOn(selected: selectedSubtitleID) }

    /// The cues active at the frame on screen on either video route. Empty
    /// when no track is selected or no cue overlaps the position. Stock and
    /// inline players use the same policy through `AppleStockPlayerSubtitles`.
    public var activeSubtitleCues: [AppleSubtitleCue] {
        AppleSubtitleCueLayerPolicy.activeCues(in: subtitleCues, at: cueTime,
                                               timing: coordinator.subtitleTiming)
    }

    /// The per-play subtitle delay and frame-rate fix (held by the coordinator).
    public var subtitleTiming: AppleSubtitleTiming { coordinator.subtitleTiming }

    /// A subtitle-menu timing action: the cue on screen moves at once, paused or not.
    public func changeSubtitleTiming(_ change: AppleSubtitleTiming.Change) {
        bumpActivity()
        coordinator.subtitleTiming.apply(change)
    }

    // MARK: - Route-derived secondary actions

    /// AirPlay button is shown on `.avPlayer` routes (a real route picker);
    /// on `.surface` it shows the unavailable hint instead. The T7e overlay no
    /// longer renders either button, but the model still reports the route.
    public var showsAirPlay: Bool { route == .avPlayer }

    /// Picture-in-picture button is shown on `.avPlayer` routes on iOS
    /// (toggles PiP through the AVKit controller). tvOS offers PiP from the
    /// stock player only (`AppleTVPictureInPicturePolicy`), never from this
    /// overlay; `.surface` hides it. The T7e overlay no longer renders it.
    public var showsPictureInPicture: Bool {
        #if os(iOS)
        return route == .avPlayer
        #else
        return false
        #endif
    }

    /// `true` when a "Next Episode" action is wired.
    public var showsNextEpisode: Bool { nextEpisode != nil }

    /// Starts the next episode once this one has run out, unless the viewer
    /// turned auto-play off or dismissed the card.
    private func advanceToNextEpisodeIfDue(hasEnded: Bool = false) {
        guard !hasAdvancedToNextEpisode, let nextEpisode, !coordinator.isPlaceholderPlayback else { return }
        guard AppleNextEpisodePolicy.shouldAutoAdvance(
            position: position,
            duration: duration ?? coordinator.engine.duration,
            nextTitle: nextEpisodeTitle,
            isLive: isLive,
            isDismissed: nextEpisodeDismissed,
            isEnabled: autoPlayNextEpisode,
            hasEnded: hasEnded
        ) else { return }
        hasAdvancedToNextEpisode = true
        appleTrace("next episode auto-advance → \(nextEpisodeTitle ?? "?")")
        nextEpisode()
    }

    // MARK: - Skip

    /// Skip by `seconds` (typically ±10). Clamped to `[0, duration]` for VOD
    /// and to the stream's real seekable range for live; a no-op for a live
    /// source with no rewind, and for a move the range leaves nowhere to go.
    public func skip(by seconds: Double) async {
        bumpActivity()
        let target: Double
        if isLive {
            guard let live = AppleLiveSeekPolicy.skipTarget(
                from: position, by: seconds, in: liveSeekableRange
            ) else {
                appleTrace("live skip \(Int(seconds))s ignored — seekable \(liveSeekableRange.map { "\(Int($0.start))–\(Int($0.end))s" } ?? "none") at \(Int(position))s")
                return
            }
            target = live
        } else {
            guard let duration, duration > 0 else { return }
            target = min(duration, max(0, position + seconds))
        }
        appleTrace("skip \(Int(seconds))s: \(Int(position))s → \(Int(target))s")
        await coordinator.userSeek(to: target)
    }

    /// Called by the view on any user interaction (tap, focus move, remote
    /// press). Re-shows the controls and restarts the auto-hide timer.
    public func bumpActivity() {
        controlsVisible = true
        scheduleAutoHide()
    }

    public func hideControls() {
        controlsVisible = false
        hideTask?.cancel()
    }

    /// True while a menu from the transport (Audio & Subtitles, More) is open.
    /// Removing the chrome closed the open menu after three seconds (full
    /// test 2026-09-30), so the auto-hide stands down until it closes.
    public var menuIsOpen: Bool { openMenuItems > 0 }

    /// Menu rows on screen. A menu reports each of its rows appearing and
    /// disappearing, so the count is balanced however many rows it has.
    private var openMenuItems = 0

    /// How long an open menu holds the chrome before the timer resumes, in
    /// case the menu's close is never reported.
    private let openMenuHideDelay: Duration = .seconds(60)

    public func menuItemAppeared() {
        openMenuItems += 1
        guard openMenuItems == 1 else { return }
        controlsVisible = true
        scheduleAutoHide()
    }

    public func menuItemDisappeared() {
        guard openMenuItems > 0 else { return }
        openMenuItems -= 1
        if openMenuItems == 0 { scheduleAutoHide() }
    }

    /// Apple TV: true while Skip Intro holds focus. The auto-hide stands down
    /// until focus leaves it: hiding the chrome took the focus back to the
    /// picture a moment after it landed (Apple TV verification 2026-10-01).
    public var focusedPromptHoldsControls = false {
        didSet {
            guard focusedPromptHoldsControls != oldValue else { return }
            scheduleAutoHide()
        }
    }

    // MARK: - Formatting

    /// `m:ss` for streams under an hour, `h:mm:ss` once ≥ 1 h. Pure static so
    /// tests can assert it without a model instance.
    public static func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0, seconds < Double(Int.max) else { return "0:00" }
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    // MARK: - Engine observation

    private func startObserving() {
        observationTask?.cancel()
        let engine = coordinator.engine
        let events = engine.events
        observationTask = Task { @MainActor [weak self] in
            for await event in events {
                guard !Task.isCancelled, let self else { break }
                self.apply(event)
            }
        }
    }

    /// Internal so a model test can feed it events without an engine stream.
    func apply(_ event: ApplePlaybackEngineEvent) {
        switch event {
        case .phase(let phase):
            // A new load runs through the engine's `stop()`, which reports
            // `.idle`; from here that is the only load boundary in sight (the
            // coordinator's attempt counter is private). The opening belongs to
            // the item, so both the marker and the skip end with it.
            if phase == .idle {
                clearIntroForNewItem()
                // A new item has its own tracks; an unconfirmed pick is moot.
                pendingAudioID = nil
            }
            // A load boundary replaces the item and with it the window.
            refreshSeekableRange()
            if phase == .ended { advanceToNextEpisodeIfDue(hasEnded: true) }
            // Phase is otherwise read directly from the coordinator;
            // re-evaluate auto-hide.
            scheduleAutoHide()
        case .route(let route):
            self.route = route
        case .position(let seconds):
            let clamped = max(0, seconds)
            if position != clamped { position = clamped }
            // The window slides with the stream: re-read it on every tick so
            // the badge, the scrubber and the skip bounds all follow the edge.
            refreshSeekableRange()
            advanceToNextEpisodeIfDue()
            // Cues carry source PTS and the active cue rolls with the position;
            // re-read on each tick so the overlay renders the current cue, but
            // only write when the array actually changed so unrelated
            // Observation readers (e.g. the track-selection menu) don't get
            // invalidated on every position tick.
            let cues = coordinator.engine.subtitleCues
            if subtitleCues != cues { subtitleCues = cues }
            let presented = coordinator.engine.presentationTime
            if cueTime != presented { cueTime = presented }
        case .duration(let seconds):
            guard duration != seconds else { break }
            duration = seconds
            // The runtime and the chapter list come from independent engine
            // publishers, so a runtime that lands *after* the chapters has to
            // re-run the marker test: `AppleChapterMarkers.intro` can only skip
            // a mislabelled single-chapter file once it knows the runtime to
            // measure the chapter against.
            refreshIntroChapter()
        case .tracks:
            // Chapters land in the same pass as the tracks, after `load`
            // returns, so this is where a stream's opening sequence becomes
            // known.
            refreshIntroChapter()
            let audio = coordinator.engine.audioTracks
            if audioTracks != audio { audioTracks = audio }
            let active = coordinator.engine.activeAudioTrackID
            if active != nil, active == pendingAudioID {
                pendingAudioID = nil
            }
            let audioID = AppleTrackSelectionPolicy.audio(
                engineActive: active, pending: pendingAudioID, current: selectedAudioID)
            if audioID != selectedAudioID { selectedAudioID = audioID }
            let subtitles = coordinator.engine.subtitleTracks
            if subtitleTracks != subtitles { subtitleTracks = subtitles }
            let cues = coordinator.engine.subtitleCues
            if subtitleCues != cues { subtitleCues = cues }
            // Nil is an authoritative Off too, including a native-menu action.
            selectedSubtitleID = coordinator.engine.activeSubtitleTrackID
        case .failure:
            break
        }
    }

    // MARK: - Auto-hide

    func playbackPhaseChanged() { scheduleAutoHide() }

    private func scheduleAutoHide() {
        hideTask?.cancel()
        guard case .playing = coordinator.phase, !focusedPromptHoldsControls else {
            // Keep controls visible while paused / buffering / failed, and
            // while a focused prompt holds them.
            controlsVisible = true
            return
        }
        let delay = menuIsOpen ? max(hideDelay, openMenuHideDelay) : hideDelay
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            guard case .playing = self.coordinator.phase else { return }
            self.controlsVisible = false
        }
    }

    isolated deinit {
        observationTask?.cancel()
        hideTask?.cancel()
    }
}
