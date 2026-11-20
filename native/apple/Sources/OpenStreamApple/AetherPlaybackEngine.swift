import AVFoundation
import Combine
import Foundation
import AetherEngine

/// OpenStream's primary playback engine: a thin `ApplePlaybackEngine` adapter
/// around `AetherEngine` that mirrors its Combine publishers into the engine
/// protocol's properties and `AsyncStream` events. One instance owns one
/// `AetherEngine`; the subscriptions live for the lifetime of this adapter and
/// are cancelled automatically when it deinits (every sink captures `self`
/// weakly, so there is no retain cycle).
@MainActor
public final class AetherPlaybackEngine: ApplePlaybackEngine {
    public let kind: ApplePlaybackEngineKind = .openStream

    public let discMenu = AppleDiscMenuSession()

    private let aether: AetherEngine
    private var cancellables = Set<AnyCancellable>()
    private let eventStream = ApplePlaybackEventStream()

    /// True once playback has actually rolled for this session; an error after
    /// this point is a mid-playback failure rather than a load failure.
    private var hasReachedPlaying = false
    private(set) var hasFirstFrameReadyForDisplay = false
    private var firstFrameObservation: AnyCancellable?
    private var startupRestart = AppleStartupRestartWatch()
    /// Bumped by every `seek`; a seek that returns after a newer one began
    /// does no post-seek work.
    private var viewerSeekGeneration = 0
    /// The newest values the engine's publishers delivered. Combine sinks
    /// run in `willSet`, so the engine's own properties can still hold the
    /// previous value there.
    private var deliveredPhase: PlaybackPhase?
    private var deliveredTransport: (state: PlaybackState, isBuffering: Bool) = (.idle, false)
    private let viewerSeekSubject = PassthroughSubject<SeekEvent, Never>()
    /// The proxy's caption-declaring master for this load, revoked on the next
    /// load or stop (`ApplePlaybackRequest.Hints.declaresEmbeddedCaptions`).
    private var captionMasterURL: URL?
    private var captionObservation: Task<Void, Never>?
    private var loadGeneration = 0
    private var nativePlayerDuringLoad: AVPlayer?
    private var subtitleSelectionOverridden = false
    private var stockPlayerRendersSubtitles = false
    /// Captions for Picture in Picture and AirPlay (`AppleCaptionHandoff`).
    private(set) var captionHandoff = AppleCaptionHandoff()
    /// Whether this load's item is one the handoff manages: a loopback item
    /// on a platform that keeps renditions off it while the picture is here.
    private var captionHandoffEligible = false
    private var captionHandoffReload: Task<Void, Never>?
    private var lastPositionUpdate = Date.distantPast
    private var lastCueClockTrace = Date.distantPast
    #if os(visionOS)
    private let softwareAudioSwitch = AppleSoftwareAudioSwitch()
    private var softwareAudioSwitchTask: Task<Void, Never>?
    private var softwareAudioSwitchTimeout: Task<Void, Never>?
    private var softwareAudioSwitchPreviousTimebase: CMTimebase?
    private var preparingPausedLoad = false
    private var pausedLoadPosition: Double?
    private var framePreparationVolume: Float?
    #endif
    /// Latest values published by `aether.$duration` / `aether.$isLive`. Used by
    /// `refreshDuration` because `@Published` sinks fire on `willSet`, when the
    /// engine's own stored properties still hold the previous value.
    private var lastPublishedDuration: Double = 0
    /// The disc file this load plays, so the titles the engine finds on it
    /// fill the title page's Titles row (`AppleDiscCatalog`).
    private var discFileURL: URL?
    private var lastPublishedIsLive: Bool = false

    /// Subtitle tracks demuxed from the media, kept apart from the sidecar
    /// tracks so `subtitleTracks` can be rebuilt with the embedded ones first
    /// and the appended sidecar ids stay stable.
    private var embeddedSubtitleTracks: [ApplePlaybackTrack] = []
    private var externalSubtitleTracks: [AppleExternalSubtitleTrack] = []
    private var activeExternalSubtitleID: Int?
    private var externalSubtitleLoad: Task<Void, Never>?
    /// The in-flight sidecar subtitle read and parse, if any. Tests await
    /// it instead of polling `subtitleCues` against the clock.
    var pendingExternalSubtitleLoad: Task<Void, Never>? { externalSubtitleLoad }
    /// Latest `sourceVideoWidth/Height` and `softwareDisplaySize`, captured in
    /// the sinks for the same `willSet` reason as `lastPublishedDuration`.
    private var lastSourceVideoWidth: Int32 = 0
    private var lastSourceVideoHeight: Int32 = 0
    private var lastSoftwareDisplaySize: CGSize?

    /// Track ids at or above this value address `externalSubtitleTracks`; the
    /// engine's own track indices are small integers.
    static let externalSubtitleTrackIDBase = 1_000_000

    /// Reads a chosen sidecar subtitle file. Injectable for tests.
    public var externalSubtitleDataLoader: @Sendable (URL) async throws -> Data
        = AppleExternalSubtitleService.liveDataLoader

    public private(set) var phase: ApplePlaybackEnginePhase = .idle {
        didSet {
            guard phase != oldValue else { return }
            if case .playing = phase { hasReachedPlaying = true }
            emit(.phase(phase))
        }
    }
    public private(set) var route: ApplePlaybackPresentationRoute = .none {
        didSet {
            guard route != oldValue else { return }
            emit(.route(route))
            refreshCaptionHandoff()
        }
    }
    public private(set) var position: Double = 0
    /// `aether.clock.sourceTime`: the source PTS of the frame on screen. The
    /// engine documents it as the clock hosts pace cues from; `position`
    /// follows `currentTime`, which it holds through live rebases.
    public private(set) var presentationTime: Double = 0
    /// The picture's display size, so the cue layer fits bitmap subtitles to
    /// the picture rather than to an assumed 16:9 (a 2.39:1 film letterboxes).
    /// The software route reports what it renders; the AVPlayer routes use the
    /// probed coded size times the pixel aspect. nil until probed.
    public private(set) var videoSize: CGSize?
    public private(set) var duration: Double? = nil {
        didSet {
            guard duration != oldValue else { return }
            emit(.duration(duration))
        }
    }
    public private(set) var audioTracks: [ApplePlaybackTrack] = [] {
        didSet {
            guard audioTracks != oldValue else { return }
            emit(.tracks)
        }
    }
    /// Aether's `activeAudioTrackIndex`: the stream index playing.
    public private(set) var activeAudioTrackID: Int? {
        didSet {
            guard activeAudioTrackID != oldValue else { return }
            emit(.tracks)
        }
    }
    public private(set) var subtitleTracks: [ApplePlaybackTrack] = [] {
        didSet {
            guard subtitleTracks != oldValue else { return }
            emit(.tracks)
            autoSelectSubtitleIfPreferred()
            refreshCaptionHandoff()
        }
    }

    /// Decoded cues for the active subtitle track, mirrored from the engine for
    /// the app to draw on both routes (the engine keeps AVPlayer's legible
    /// group deselected on `.avPlayer`). Not emitted through `events`; readers
    /// re-read it on position ticks.
    public private(set) var subtitleCues: [AppleSubtitleCue] = []
    /// The rendered selection shared by every menu: Aether's published track,
    /// or the app-owned sidecar/native selection while that renderer owns cues.
    public private(set) var activeSubtitleTrackID: Int? {
        didSet {
            guard activeSubtitleTrackID != oldValue else { return }
            emit(.tracks)
            refreshCaptionHandoff()
        }
    }
    /// Chapters published by the engine for the active container or disc title.
    private var acceptsChapterUpdates = false
    public private(set) var chapterMediaVersion: UUID?
    public private(set) var chapters: [AppleChapter] = [] {
        didSet {
            guard chapters != oldValue else { return }
            appleTrace("engine chapters: \(chapters.count) — \(chapters.map(\.title).prefix(6).joined(separator: ", "))")
            emit(.tracks)
        }
    }

    nonisolated static func mapChapter(_ info: ChapterInfo) -> AppleChapter {
        AppleChapter(title: info.name, start: info.startSeconds, end: info.startSeconds + max(info.durationSeconds, 0))
    }

    /// Preferred caption behaviour applied at load and when tracks arrive. The
    /// host sets this from `AppleSettingsStore.captionsPreference` before load;
    /// `.always` auto-selects the first track, `.english` / `.deviceLanguage`
    /// hand the engine matching languages, `.off` selects nothing.
    public var captionsPreference: AppleCaptionsPreference = .off
    /// Captions are off and no selection has overridden that for this item.
    var holdsCaptionsOff: Bool { captionsPreference == .off && !subtitleSelectionOverridden }

    /// The viewer's chosen subtitle languages. Auto-selection picks the first
    /// track in these rather than the first track in the file: a remux lists
    /// its tracks in whatever order the muxer used, so "first" was routinely a
    /// language the viewer does not read (owner 2026-09-14). Empty means the
    /// device's primary language (`AppleSubtitleTrackFilter.effectiveLanguages`).
    public var preferredSubtitleLanguages: [String] =
        UserDefaults.standard.stringArray(forKey: AppleSubtitleLanguages.defaultsKey) ?? []
    /// True when `preferredSubtitleLanguages` is a language the viewer picked
    /// rather than one inferred from the device. A picked language is the whole
    /// menu; see `AppleSubtitleTrackFilter.visible`.
    public var subtitleLanguagesAreExplicit = false
    /// The audio languages a load starts in, best first. Nil reads Settings ›
    /// Playback › Audio Language at each load (`AppleAudioLanguagePreference`).
    public var preferredAudioLanguages: [String]?
    public private(set) var failure: ApplePlaybackFailure? = nil {
        didSet {
            guard failure != oldValue else { return }
            emit(.failure(failure))
        }
    }

    public var avPlayer: AVPlayer? { aether.currentAVPlayer }

    public var startupCheckpoint: Int { aether.startupProgress?.completed ?? 0 }

    public var awaitsSourceBytes: Bool { aether.startupProgress?.checkpoint == .dispatched }

    /// What the live source can actually rewind, on the session axis
    /// `position` is published on.
    ///
    /// Two sources, folded: the engine's `seekableLiveRange`, and — where an
    /// `AVPlayer` is doing the playing — the item's own `seekableTimeRanges`.
    /// Neither alone is right. `seekableLiveRange` is window arithmetic
    /// (`edge - dvrWindowSeconds`) on the remote-HLS path, where no segment
    /// cache exists to report an honest floor, so it advertises the 1800 s
    /// every live request carries; the item knows the truth but speaks its own
    /// axis. `shift` measures the offset between the two from a single sample
    /// of each (the engine folds a constant `playlistShiftSeconds +
    /// liveItemAxisOffsetSeconds` into the playhead), then the narrower of the
    /// two wins.
    public var seekableRange: AppleSeekableRange? {
        let claimed = aether.seekableLiveRange.flatMap {
            AppleSeekableRange(start: $0.lowerBound, end: $0.upperBound)
        }
        guard let player = aether.currentAVPlayer,
              let item = avPlayerSeekableRange(player) else {
            // Before AVPlayer publishes its window the engine's DVR arithmetic is only a placeholder.
            return route == .surface ? claimed?.expanded(toInclude: position) : nil
        }
        let playerTime = player.currentTime().seconds
        guard playerTime.isFinite, position.isFinite else {
            return claimed?.expanded(toInclude: position)
        }
        let shift = position - playerTime
        guard let onSessionAxis = AppleSeekableRange(start: item.start + shift,
                                                     end: item.end + shift) else {
            return claimed?.expanded(toInclude: position)
        }
        let folded = claimed.flatMap { onSessionAxis.intersected(with: $0) } ?? onSessionAxis
        return folded.expanded(toInclude: position)
    }

    /// Exposed for `ApplePlaybackSurfaceView`, which mounts the engine's own
    /// SwiftUI surface on `.surface` routes.
    internal var aetherEngine: AetherEngine { aether }

    var keepsSoftwareSurfaceForAudioSwitch: Bool {
        #if os(visionOS)
        softwareAudioSwitch.selection != nil
        #else
        false
        #endif
    }

    #if DEBUG
    var debugResumeSeekProbe: ((Double) -> Void)?
    #endif

    /// Reapply before every phase, including the software audio host's load.
    var multiviewMuted = false {
        didSet { aether.volume = multiviewMuted || AppleTestAudioMute.isActive ? 0 : 1 }
    }

    #if os(visionOS)
    private func applyPlaybackVolume() {
        let muted = multiviewMuted || AppleTestAudioMute.isActive
        if (softwareAudioSwitch.selection != nil && softwareAudioSwitch.pauseRequested) || pausedLoadPosition != nil {
            if framePreparationVolume == nil { framePreparationVolume = aether.currentAVPlayer?.volume ?? aether.volume }
            aether.volume = 0
        } else if let volume = framePreparationVolume {
            framePreparationVolume = nil
            aether.volume = muted ? 0 : volume
        } else if muted {
            aether.volume = 0
        }
    }
    #endif

    public var events: AsyncStream<ApplePlaybackEngineEvent> {
        eventStream.stream()
    }

    public init() throws {
        aether = try AetherEngine()
        if AppleTestAudioMute.isActive { aether.volume = 0 }
        // The app owns the system Now Playing card; the engine must not take it
        // from AVKit. The default is already `false`, set it explicitly so the
        // intent survives an engine-side default change.
        #if os(iOS) || os(tvOS)
        aether.ownsVideoNowPlayingSession = false
        #endif
        bind()
    }

    // MARK: - ApplePlaybackEngine

    private var liveBuffer: AppleLiveBufferPreference = .automatic
    private var isLiveBufferSession = false

    private func applyLiveBuffer() {
        guard isLiveBufferSession, liveBuffer != .automatic else { return }
        aether.currentAVPlayer?.currentItem?.preferredForwardBufferDuration =
            liveBuffer.forwardBufferDuration(isLive: true)
    }

    public func load(_ request: ApplePlaybackRequest) async throws {
        firstFrameObservation?.cancel()
        hasFirstFrameReadyForDisplay = false
        acceptsChapterUpdates = false
        chapterMediaVersion = UUID()
        chapters = []
        liveBuffer = .stored()
        isLiveBufferSession = request.isLive
        loadGeneration &+= 1
        #if os(visionOS)
        if (softwareAudioSwitch.selection != nil && softwareAudioSwitch.pauseRequested) || pausedLoadPosition != nil {
            aether.pause()
        }
        finishSoftwareAudioSwitch(applyPause: false)
        softwareAudioSwitch.reset()
        preparingPausedLoad = !request.autoplay && !request.isLive
        pausedLoadPosition = preparingPausedLoad ? max(0, request.resumePosition ?? 0) : nil
        applyPlaybackVolume()
        #endif
        let generation = loadGeneration
        nativePlayerDuringLoad = route == .avPlayer ? avPlayer : nil
        if nativePlayerDuringLoad == nil { route = .none }
        var loaded = false
        defer {
            if generation == loadGeneration {
                nativePlayerDuringLoad = nil
                #if os(visionOS)
                preparingPausedLoad = false
                pausedLoadPosition = nil
                applyPlaybackVolume()
                #endif
                if !loaded { route = .none }
            }
        }
        captionObservation?.cancel()
        captionObservation = nil
        hasReachedPlaying = false
        startupRestart = AppleStartupRestartWatch()
        subtitleSelectionOverridden = false
        stockPlayerRendersSubtitles = false
        activeSubtitleTrackID = nil
        clearExternalSubtitles()
        failure = nil
        revokeCaptionMaster()
        let request = try await AppleLiveCaptionProbe.shared.preparedRequest(request)
        guard generation == loadGeneration, !Task.isCancelled else { throw CancellationError() }
        var sourceURL = request.url
        var headers = request.effectiveHeaders
        // Undeclared CEA-608 in a live HLS media playlist: AVPlayer (the
        // remote-HLS route) only finds it through a master, so the proxy serves
        // one in front of the channel and carries the provider headers itself.
        if request.isLive, request.hints.nativeRemoteHLS, request.hints.declaresEmbeddedCaptions {
            let master = try await AppleProtectedHTTPPlaybackServer.shared.playbackURL(
                upstreamURL: request.url, requestHeaders: headers, declaringCaptions: true)
            guard generation == loadGeneration, !Task.isCancelled else {
                await AppleProtectedHTTPPlaybackServer.shared.revoke(playbackURL: master)
                throw CancellationError()
            }
            captionMasterURL = master
            sourceURL = master
            headers = [:]
        }
        let audioLanguages = preferredAudioLanguages
            ?? AppleAudioLanguagePreference.engineLanguages(choice: AppleAudioLanguagePreference.storedChoice())
        var options = Self.loadOptions(
            for: request, headers: headers,
            preferredSubtitleLanguages: preferredSubtitleLanguages,
            captionsPreference: captionsPreference,
            preferredAudioLanguages: audioLanguages,
            liveBuffer: liveBuffer
        )
        appleTrace("audio language preference \(audioLanguages.joined(separator: ","))")
        // An episode that starts while PiP or AirPlay holds the picture
        // declares the renditions itself rather than rebuilding right after.
        captionHandoffReload?.cancel()
        captionHandoffEligible = !Self.declaresNativeSubtitleRenditions && !request.hints.nativeRemoteHLS
        if captionHandoff.loadStarted(eligible: captionHandoffEligible) { options.prepareNativeSubtitles = true }
        // The title page's title, not the file's own tags (`AppleStockPlayerMetadata`).
        if !request.isLive { aether.setExternalMetadata(AppleStockPlayerMetadata.items(title: request.title, subtitle: request.subtitle, year: request.releaseYear)) }
        // A disc image starts from one choice (`AppleDiscPlaybackStart`); the
        // engine opens navigation unless an explicit title bypasses it.
        if let disc = request.hints.disc { appleTrace(disc.traceLine) }
        discFileURL = request.hints.disc != nil ? (request.hints.libraryFileURL ?? request.url) : nil
        let knownDiscTitles = discFileURL.flatMap { AppleDiscCatalog.shared.titles[$0] } ?? []
        let discTitleID = request.hints.disc?.engineTitleID(knownTitles: knownDiscTitles)
        if let discTitleID, request.hints.disc?.titleID == nil { appleTrace("disc main title: title \(discTitleID) by chapters") }
        acceptsChapterUpdates = true
        // Subscribe after preparation so the outgoing item cannot satisfy this load.
        firstFrameObservation = aether.$hasFirstFrameReadyForDisplay.dropFirst()
            .sink { [weak self] ready in self?.hasFirstFrameReadyForDisplay = ready }
        do {
            _ = try await aether.load(
                url: sourceURL,
                startPosition: request.resumePosition,
                options: options,
                discTitleID: discTitleID
            )
        } catch {
            if generation == loadGeneration {
                acceptsChapterUpdates = false
                chapters = []
                performCaptionHandoff(captionHandoff.reloadFinished(succeeded: false))
            }
            throw error
        }
        print("[OpenStream] route title=\(request.title ?? "Untitled") container=\(request.hints.filename.map { URL(fileURLWithPath: $0).pathExtension } ?? request.url.pathExtension) route=\(aether.videoRoute) decoder=\(aether.activeVideoDecoder ?? "unknown") audio=\(audioTracks.map(\.codec))")
        if let decision = request.hints.playbackDecision {
            let software = Self.mapRoute(aether.videoRoute) == .surface
            appleTrace("playback decision video=\(decision.video) audio=\(decision.audio) observed=\(aether.videoRoute) decoder=\(aether.activeVideoDecoder ?? "unknown") range=\(outputInfo.dynamicRange)\(decision.mismatch(observedSoftwareDecode: software) ? " decisionMismatch" : "")")
        }
        guard generation == loadGeneration, !Task.isCancelled else { throw CancellationError() }
        if knownDiscTitles.isEmpty { switchToMainTitle(request) }
        performCaptionHandoff(captionHandoff.reloadFinished(succeeded: true))
        applyLiveBuffer()
        observeLiveCaptions(request, generation: generation)
        await Self.restoreResumePosition(request, route: route,
            softwareTimebase: aether.softwarePresentationTimebase) { seconds in
                await aether.seek(to: seconds)
                #if DEBUG
                debugResumeSeekProbe?(seconds)
                #endif
            }
        #if os(visionOS)
        if preparingPausedLoad {
            if let position = pausedLoadPosition, route == .surface {
                aether.play()
                await aether.seek(to: position)
                if !aether.hasFirstFrameReadyForDisplay {
                    for await ready in aether.$hasFirstFrameReadyForDisplay.values {
                        if ready { break }
                    }
                }
                guard generation == loadGeneration, !Task.isCancelled else { throw CancellationError() }
                if let position = pausedLoadPosition {
                    aether.pause()
                    await aether.seek(to: position)
                }
            } else if pausedLoadPosition == nil {
                aether.play()
            }
        }
        #endif
        loaded = true
    }

    static func restoreResumePosition(_ request: ApplePlaybackRequest, route: ApplePlaybackPresentationRoute,
                                      softwareTimebase: CMTimebase?, seek: (Double) async -> Void) async {
        let hasSoftwareClock = route == .surface && softwareTimebase != nil
        if !request.isLive, let resume = request.resumePosition, resume.isFinite, resume > 0,
           !request.autoplay || hasSoftwareClock {
            // A paused mount needs an explicit clock anchor; software autoplay
            // must also start at the saved position rather than its keyframe.
            await seek(resume)
        }
    }

    /// Whether loopback HLS declares WebVTT renditions for the stream's own
    /// text subtitles. Only where the stock player's captions rows are hidden
    /// (Apple TV, `allowedSubtitleOptionLanguages`), so they serve AirPlay
    /// without reaching a menu.
    ///
    /// On the Mac and iPhone they did reach one — AVKit's CC menu listed them
    /// under the engine's unique rendition names ("English", "English 2",
    /// "English 3" for one film) — and a choice there drew nothing: the
    /// renditions are non-default, lazily filled and pinned deselected for the
    /// host overlay (AetherEngine Sodalite#32/#38), while the app took the
    /// choice as AVKit's to draw and cleared its own cues (N38, measured on
    /// the Mac stage player: no caption layer ever appeared). Without them
    /// the item has no legible options, AVKit shows no CC button, and the
    /// app's captions menu is the one control, drawn by the app's cue layer.
    /// Picture in Picture and AirPlay get them for as long as they hold the
    /// picture (`AppleCaptionHandoff`, N42).
    nonisolated static var declaresNativeSubtitleRenditions: Bool {
        #if os(tvOS)
        true
        #else
        false
        #endif
    }

    // MARK: - Captions for Picture in Picture and AirPlay

    /// The host says where the picture is: in a Picture in Picture window,
    /// on an AirPlay receiver or external screen, or (both false) in the app.
    ///
    /// The engine hears about PiP too (`pictureInPictureActive`): it is what
    /// makes a rebuild keep the running item attached until the new one is
    /// ready (AE#158). Without it the handoff's own reload closed the window
    /// it was rebuilding for, 0.3 s after it opened (N42, Mac probe).
    public func setPictureWhereabouts(pictureInPicture: Bool, external: Bool) {
        if aether.pictureInPictureActive != pictureInPicture { aether.pictureInPictureActive = pictureInPicture }
        let away = pictureInPicture || external
        guard away != captionHandoff.pictureIsAway else { return }
        appleTrace("caption handoff: picture \(away ? "away" : "back") stage=\(captionHandoff.stage)")
        refreshCaptionHandoff(pictureIsAway: away)
        // The stock player's cue layer re-reads `appDrawsCaptions`.
        emit(.tracks)
    }

    private func refreshCaptionHandoff(pictureIsAway: Bool? = nil) {
        let wanted = captionHandoffEligible && route == .avPlayer
            ? AppleCaptionHandoff.wantedTrack(activeTrackID: activeSubtitleTrackID, tracks: subtitleTracks)
            : nil
        performCaptionHandoff(captionHandoff.update(
            pictureIsAway: pictureIsAway ?? captionHandoff.pictureIsAway, wantedTrackID: wanted))
    }

    private func performCaptionHandoff(_ actions: [AppleCaptionHandoff.Action]) {
        for action in actions {
            appleTrace("caption handoff: \(action) stage=\(captionHandoff.stage)")
            switch action {
            case .nativeRendering(let on):
                // The engine maps its own active track to a rendition, and
                // `activeSubtitleTrackID` changes before `applySubtitleSelection`
                // hands the track to it; wait for the selection to finish so a
                // new track is not answered with the old one's rendition.
                let generation = loadGeneration
                Task { [weak self] in
                    guard let self, generation == self.loadGeneration else { return }
                    self.aether.setNativeSubtitleRendering(on)
                }
            case .reload(let declaring):
                let generation = loadGeneration
                captionHandoffReload = Task { [weak self] in
                    await self?.waitForSettledSession()
                    guard let self, !Task.isCancelled, generation == self.loadGeneration else { return }
                    var succeeded = true
                    do {
                        try await self.aether.reloadAtCurrentPosition { $0.prepareNativeSubtitles = declaring }
                    } catch {
                        succeeded = false
                        appleTrace("caption handoff: reload failed: \(AppleDiagnosticRedactor.describe(error))")
                    }
                    guard generation == self.loadGeneration else { return }
                    self.performCaptionHandoff(self.captionHandoff.reloadFinished(succeeded: succeeded))
                }
            }
        }
    }

    /// A handoff reload waits out a rebuild the engine started itself: an
    /// AirPlay receiver makes it reload the item on the LAN address
    /// (AetherEngine #86) on the same edge the host reports, and a second
    /// rebuild inside that one would snapshot the subtitle state mid-teardown.
    /// Every load clears the first-frame latch until its item is ready.
    private func waitForSettledSession() async {
        try? await Task.sleep(for: .milliseconds(300))
        for _ in 0..<40 where !aether.hasFirstFrameReadyForDisplay && !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    /// Builds the engine policy without loading media or reading viewer defaults.
    nonisolated static func loadOptions(
        for request: ApplePlaybackRequest,
        headers: [String: String],
        preferredSubtitleLanguages: [String] = [],
        captionsPreference: AppleCaptionsPreference = .off,
        preferredAudioLanguages: [String] = [],
        liveBuffer: AppleLiveBufferPreference = .automatic
    ) -> LoadOptions {
        var options = LoadOptions(
            httpHeaders: headers,
            isLive: request.isLive,
            dvrWindowSeconds: request.effectiveDVRWindowSeconds
        )
        options.forwardBufferSegments = liveBuffer.forwardBufferSegments(isLive: request.isLive)
        options.preferredDecodePath = .automatic
        #if DEBUG
        // UI tests: the software route puts a library title on the app's own
        // transport, which AVKit owns on the native route.
        if UserDefaults.standard.bool(forKey: "OpenStreamPreferSoftwareDecode") { options.preferredDecodePath = .software }
        #endif
        // No Dolby encoding on the device (licence audit 2026-10-22): audio
        // the engine has to re-encode (TrueHD, DTS) goes out as FLAC.
        options.audioBridgeMode = .lossless
        options.prepareNativeSubtitles = declaresNativeSubtitleRenditions
        // Live HLS from an extension-less URL: AVPlayer plays the origin
        // directly; the raw live path would hand it to FFmpeg and fail.
        if request.hints.nativeRemoteHLS { options.nativeRemoteHLS = true }
        // Raw live TS is demuxed here and re-served as HLS. The lean-back default waits for 3 x TARGETDURATION
        // (18 s with 4 s cuts) before the first playlist; a strict-realtime origin can only fill that in wall-clock
        // time, which is what the 10 s live timeout was firing on. fastZap cuts on the source GOP so the holdback
        // tracks it, and serves a bounded first window if the origin is strict realtime (AE#195/#208).
        if request.isLive, !request.hints.nativeRemoteHLS { options.liveJoinProfile = .fastZap }
        options.autoplay = request.autoplay
        options.dvdStartMode = request.hints.disc?.engineStartMode ?? .mainTitle
        // A language the viewer picked wins over one derived from the captions
        // preference: under `.always` the preference contributes no languages
        // at all, so the demuxer used to pick in muxer order at load and get
        // corrected afterwards — a visible flash of the wrong language.
        // Captions off hands the demuxer no languages at all: the chosen list
        // made it pick English at load with captions off (Apple TV
        // verification 2026-10-01, 2 of 3 launches).
        options.preferredSubtitleLanguages = captionsPreference == .off ? []
            : preferredSubtitleLanguages.isEmpty
            ? captionsPreference.preferredSubtitleLanguages
            : preferredSubtitleLanguages
        // The first frame's audio: the engine resolves it from its one probe,
        // so no reload follows (AetherEngine `preferredAudioLanguages`).
        options.preferredAudioLanguages = preferredAudioLanguages
        return options
    }

    private func observeLiveCaptions(_ request: ApplePlaybackRequest, generation: Int) {
        guard request.isLive, request.hints.declaresEmbeddedCaptions else { return }
        captionObservation = Task { [weak self] in
            guard !Task.isCancelled, self?.loadGeneration == generation else { return }
            await AppleLiveCaptionProbe.shared.probe(
                channelID: request.mediaID, playlistURL: request.url, headers: request.effectiveHeaders)
            guard !Task.isCancelled, let self, self.loadGeneration == generation else { return }
            // The probe caches the next-start decision. Leave this item playing,
            // even if its empty captions option remains until the viewer leaves.
            self.captionObservation = nil
        }
    }

    isolated deinit {
        captionObservation?.cancel()
        captionHandoffReload?.cancel()
        #if os(visionOS)
        softwareAudioSwitchTask?.cancel()
        softwareAudioSwitchTimeout?.cancel()
        #endif
    }

    private func revokeCaptionMaster() {
        guard let url = captionMasterURL else { return }
        captionMasterURL = nil
        Task { await AppleProtectedHTTPPlaybackServer.shared.revoke(playbackURL: url) }
    }

    public func play() {
        #if os(visionOS)
        pausedLoadPosition = nil
        softwareAudioSwitch.play()
        applyPlaybackVolume()
        #endif
        aether.play()
    }
    public func pause() {
        #if os(visionOS)
        if preparingPausedLoad {
            pausedLoadPosition = pausedLoadPosition ?? max(0, aether.currentTime)
            applyPlaybackVolume()
            phase = .paused
            return
        }
        let pausesImmediately = softwareAudioSwitch.pause(activeTrackID: aether.activeAudioTrackIndex,
                                                         isLoading: aether.playbackPhase == .loading)
        applyPlaybackVolume()
        if !pausesImmediately {
            phase = .paused
            return
        }
        #endif
        aether.pause()
    }
    public var maximumPlaybackRate: Float { aether.maxSupportedRate }
    public func setPlaybackRate(_ rate: Float) {
        guard rate.isFinite, rate >= 0, rate <= maximumPlaybackRate else { return }
        aether.setRate(rate)
    }

    public func stop() {
        firstFrameObservation?.cancel()
        firstFrameObservation = nil
        hasFirstFrameReadyForDisplay = false
        acceptsChapterUpdates = false
        chapterMediaVersion = nil
        chapters = []
        loadGeneration &+= 1
        #if os(visionOS)
        finishSoftwareAudioSwitch(applyPause: false)
        softwareAudioSwitch.reset()
        preparingPausedLoad = false
        pausedLoadPosition = nil
        #endif
        captionObservation?.cancel()
        captionObservation = nil
        captionHandoffReload?.cancel()
        captionHandoffReload = nil
        captionHandoffEligible = false
        _ = captionHandoff.loadStarted(eligible: false)
        nativePlayerDuringLoad = nil
        aether.stop()
        AetherSegmentScratch.sweepAfterPlayback()
        #if os(visionOS)
        applyPlaybackVolume()
        #endif
        route = .none
        revokeCaptionMaster()
        activeSubtitleTrackID = nil
        stockPlayerRendersSubtitles = false
        clearExternalSubtitles()
        hasReachedPlaying = false
        startupRestart = AppleStartupRestartWatch()
        position = 0
        presentationTime = 0
        lastPositionUpdate = .distantPast
    }

    public func seek(to seconds: Double) async {
        guard seconds.isFinite, !Task.isCancelled else { return }
        let generation = loadGeneration
        viewerSeekGeneration &+= 1
        let seekGeneration = viewerSeekGeneration
        startupRestart.viewerSeek()
        #if os(visionOS)
        if pausedLoadPosition != nil { pausedLoadPosition = seconds }
        softwareAudioSwitchTask?.cancel()
        softwareAudioSwitchTask = nil
        softwareAudioSwitch.userSeek(to: seconds)
        #endif
        await aether.seek(to: seconds)
        // A newer seek owns the result, whether or not this one was cancelled.
        guard generation == loadGeneration, seekGeneration == viewerSeekGeneration, !Task.isCancelled else { return }
        #if os(visionOS)
        restoreSoftwareAudioSwitchIfReady()
        #endif
        if discFileURL != nil {
            lastPositionUpdate = .distantPast
            applyPosition(aether.currentTime)
        }
    }

    public func selectAudioTrack(id: Int) {
        #if os(visionOS)
        let resume = aether.currentTime
        if route == .surface, !isLiveBufferSession, phase == .playing || phase == .paused,
           id != activeAudioTrackID, audioTracks.contains(where: { $0.id == id }),
           resume.isFinite, resume >= 0 {
            finishSoftwareAudioSwitch(applyPause: false)
            softwareAudioSwitchPreviousTimebase = aether.softwarePresentationTimebase
            softwareAudioSwitch.begin(trackID: id, position: resume,
                                      paused: softwareAudioSwitch.pauseRequested || phase == .paused)
            applyPlaybackVolume()
            let generation = loadGeneration
            softwareAudioSwitchTimeout = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: AppleSoftwareAudioSwitch.timeout) } catch { return }
                guard let self, self.loadGeneration == generation else { return }
                self.finishSoftwareAudioSwitch(applyPause: true, timedOut: true)
            }
        }
        #endif
        aether.selectAudioTrack(index: id)
    }

    #if os(visionOS)
    private func finishSoftwareAudioSwitch(applyPause: Bool, timedOut: Bool = false) {
        let wasPending = softwareAudioSwitch.selection != nil
        softwareAudioSwitchTask?.cancel()
        softwareAudioSwitchTask = nil
        softwareAudioSwitchTimeout?.cancel()
        softwareAudioSwitchTimeout = nil
        softwareAudioSwitchPreviousTimebase = nil
        let pause = timedOut ? softwareAudioSwitch.timeOut() : softwareAudioSwitch.finish()
        if wasPending, phase != .ended { route = Self.mapRoute(aether.videoRoute) }
        if applyPause, pause { aether.pause() }
        applyPlaybackVolume()
    }

    private func restoreSoftwareAudioSwitchIfReady() {
        guard phase == .playing || phase == .paused,
              let selection = softwareAudioSwitch.restore(activeTrackID: aether.activeAudioTrackIndex,
                  hasClock: aether.softwarePresentationTimebase != nil
                    && aether.softwarePresentationTimebase !== softwareAudioSwitchPreviousTimebase) else { return }
        let generation = loadGeneration
        softwareAudioSwitchTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled, self.loadGeneration == generation else { return }
            // Prime the replacement decoder before pinning its paused frame to the saved position.
            await self.aether.seek(to: selection.position)
            guard !Task.isCancelled, self.loadGeneration == generation else { return }
            if !self.aether.hasFirstFrameReadyForDisplay {
                for await ready in self.aether.$hasFirstFrameReadyForDisplay.values {
                    if ready { break }
                }
            }
            guard !Task.isCancelled, self.loadGeneration == generation else { return }
            if self.softwareAudioSwitch.pauseRequested {
                self.aether.pause()
                await self.aether.seek(to: selection.position)
                guard !Task.isCancelled, self.loadGeneration == generation else { return }
            }
            self.finishSoftwareAudioSwitch(applyPause: true)
        }
    }
    #endif

    public func selectSubtitleTrack(id: Int?) {
        #if DEBUG
        appleTrace("subtitle select: track=\(id.map(String.init) ?? "off")")
        #endif
        subtitleSelectionOverridden = true
        if stockPlayerRendersSubtitles {
            stockPlayerRendersSubtitles = false
            aether.setNativeSubtitleRendering(false)
        }
        applySubtitleSelection(id: id)
        emit(.tracks)
    }

    /// AVKit has no public iOS subtitle-button hiding API. A selection there
    /// takes ownership of its rendition, releasing Aether's deselection pin.
    /// AVKit draws that rendition; the app continues to draw sidecars/bitmaps
    /// selected from its own menu, so only one cue renderer is active.
    func mirrorSubtitleSelection(_ option: AVMediaSelectionOption?, in group: AVMediaSelectionGroup) -> Bool {
        guard let option else {
            appleTrace("subtitle mirror: track=off native=off")
            selectSubtitleTrack(id: nil)
            return false
        }
        let index = group.options.firstIndex(of: option)
        let trackID = index.flatMap {
            ApplePlayerSubtitleSelection.trackID(
                optionIndex: $0,
                optionLanguages: group.options.map { $0.extendedLanguageTag ?? $0.locale?.identifier },
                tracks: ApplePlayerSubtitleSelection.renditionOrder(embeddedSubtitleTracks))
        }
        // Discovery can publish the AV option before the corresponding engine
        // track. Keep the rendered option intact until the next mapping pass.
        guard let trackID else { return false }
        subtitleSelectionOverridden = true
        stockPlayerRendersSubtitles = true
        applySubtitleSelection(id: trackID)
        subtitleCues = []
        // Remote HLS selects through AVMediaSelection already. Loopback text
        // renditions need the public native API to release the engine's pin.
        let nativeOrdinal = index.flatMap {
            ApplePlayerSubtitleSelection.trackID(
                optionIndex: $0,
                optionLanguages: group.options.map { $0.extendedLanguageTag ?? $0.locale?.identifier },
                tracks: aether.nativeSubtitleTracks.map {
                    ApplePlaybackTrack(id: $0.ordinal, title: $0.displayName, language: $0.language)
                })
        }
        if let nativeOrdinal { aether.setNativeSubtitleSelected(track: nativeOrdinal) }
        appleTrace("subtitle mirror: track=\(trackID) native=\(nativeOrdinal.map(String.init) ?? "none")")
        emit(.tracks)
        return nativeOrdinal != nil
    }

    /// Appends sidecar subtitle files after the embedded tracks. Ids already
    /// present are ignored, so a second batch never renumbers a track the
    /// viewer can already see.
    public func addExternalSubtitleTracks(_ tracks: [AppleExternalSubtitleTrack]) {
        var merged = externalSubtitleTracks
        for track in tracks where !merged.contains(where: { $0.id == track.id }) {
            merged.append(track)
        }
        guard merged.count != externalSubtitleTracks.count else { return }
        externalSubtitleTracks = merged
        rebuildSubtitleTracks()
    }

    // MARK: - External subtitles

    private func applySubtitleSelection(id: Int?) {
        externalSubtitleLoad?.cancel()
        externalSubtitleLoad = nil
        activeSubtitleTrackID = id
        let previousExternal = activeExternalSubtitleID
        activeExternalSubtitleID = nil
        guard let id else {
            aether.clearSubtitle()
            subtitleCues = []
            return
        }
        let index = id - Self.externalSubtitleTrackIDBase
        guard index >= 0, index < externalSubtitleTracks.count else {
            if previousExternal != nil { subtitleCues = [] }
            aether.selectSubtitleTrack(index: id)
            return
        }
        // Establish ownership before clearSubtitle publishes its nil echo.
        activeExternalSubtitleID = id
        activeSubtitleTrackID = nil
        aether.clearSubtitle()
        subtitleCues = []
        let track = externalSubtitleTracks[index]
        let load = externalSubtitleDataLoader
        externalSubtitleLoad = Task { [weak self] in
            let data = try? await load(track.url)
            guard !Task.isCancelled else { return }
            guard let data else {
                if let self, self.activeExternalSubtitleID == id { self.activeExternalSubtitleID = nil }
                return
            }
            // Inflating and parsing a whole subtitle file on the main actor
            // froze the player; do it off the main actor and hop back only
            // to publish the cues.
            let cues = await Task.detached(priority: .userInitiated) {
                AppleSubtitleTextParser.cues(from: data, language: track.languageCode)
            }.value
            guard let self, !Task.isCancelled, self.activeExternalSubtitleID == id else { return }
            self.subtitleCues = cues
            self.activeSubtitleTrackID = cues.isEmpty ? nil : id
            self.emit(.tracks)
        }
    }

    /// Internal so an engine test can stand in for the demuxer's track list.
    func applyEmbeddedSubtitleTracks(_ tracks: [ApplePlaybackTrack]) {
        embeddedSubtitleTracks = tracks
        rebuildSubtitleTracks()
    }

    private func rebuildSubtitleTracks() {
        subtitleTracks = embeddedSubtitleTracks + externalSubtitleTracks.enumerated().map { index, track in
            track.playbackTrack(id: Self.externalSubtitleTrackIDBase + index)
        }
    }

    private func clearExternalSubtitles() {
        externalSubtitleLoad?.cancel()
        externalSubtitleLoad = nil
        activeExternalSubtitleID = nil
        externalSubtitleTracks = []
        rebuildSubtitleTracks()
    }

    /// Reuses the engine's existing probe; tracing never opens the stream again.
    var displayTraceSource: ApplePlaybackDisplayTrace {
        let range: String
        switch aether.sourceVideoFormat {
        case .dolbyVision: range = "DV"
        case .hdr10: range = "HDR10"
        case .hdr10Plus: range = "HDR10+"
        case .hlg: range = "HLG"
        case .sdr: range = "SDR"
        }
        return ApplePlaybackDisplayTrace(source: range,
            profile: aether.sourceDVProfile.map(String.init),
            renderer: outputInfo.dynamicRange?.rawValue ?? "unknown")
    }

    public var outputInfo: ApplePlaybackOutputInfo {
        guard (phase == .playing || phase == .paused), route != .none, route != .audioOnly else { return ApplePlaybackOutputInfo(dynamicRange: nil) }
        let range: ApplePlaybackOutputInfo.DynamicRange
        switch aether.videoFormat {
        case .sdr: range = .sdr
        case .hdr10: range = .hdr10
        case .hdr10Plus: range = .hdr10Plus
        case .dolbyVision: range = .dolbyVision
        case .hlg: range = .hlg
        }
        let track = audioTracks.first { $0.id == activeAudioTrackID }
        return ApplePlaybackOutputInfo(dynamicRange: range, channels: track?.channels ?? 0)
    }

    // MARK: - Combine bridging

    private func bind() {
        #if os(visionOS)
        aether.$hasFirstFrameReadyForDisplay
            .sink { [weak self] ready in
                guard ready, let self, let trackID = self.softwareAudioSwitch.selection?.trackID,
                      self.aether.activeAudioTrackIndex == trackID else { return }
                let generation = self.loadGeneration
                // The publisher delivers before the renderer's ready flag is stored.
                Task { @MainActor [weak self] in
                    guard let self, self.loadGeneration == generation,
                          self.softwareAudioSwitch.selection?.trackID == trackID,
                          self.aether.activeAudioTrackIndex == trackID,
                          self.aether.hasFirstFrameReadyForDisplay,
                          self.aether.softwarePresentationTimebase !== self.softwareAudioSwitchPreviousTimebase else { return }
                    if self.softwareAudioSwitch.pauseRequested { self.aether.pause() }
                    self.restoreSoftwareAudioSwitchIfReady()
                }
            }
            .store(in: &cancellables)
        #endif
        aether.seekEvents
            .sink { [weak self] event in self?.observeSeekEvent(event) }
            .store(in: &cancellables)
        // While the startup restart's `.seeking` is overridden the engine's
        // phase stays put, so a pause or rebuffer is read off the transport.
        aether.$state
            .combineLatest(aether.$isBuffering)
            .sink { [weak self] state, isBuffering in
                guard let self else { return }
                self.deliveredTransport = (state, isBuffering)
                guard self.startupRestart.overridesSeeking, self.deliveredPhase == .seeking else { return }
                self.phase = Self.transportPhase(state: state, isBuffering: isBuffering)
            }
            .store(in: &cancellables)
        aether.$playbackPhase
            .sink { [weak self] phase in
                self?.deliveredPhase = phase
                self?.applyPhase(phase)
            }
            .store(in: &cancellables)
        aether.$dvdMenu
            .sink { [weak self] state in
                guard let self else { return }
                self.discMenu.state = state
                if state?.isInMenu == true { self.route = .surface }
                appleTrace("disc menu state: menu=\(state?.isInMenu == true) title=\(state?.isPlayingTitle == true) buttons=\(state?.buttons.count ?? 0)")
            }
            .store(in: &cancellables)
        aether.$videoRoute
            .sink { [weak self] videoRoute in
                guard let self else { return }
                // Aether reuses its AVPlayer across native item loads.
                if videoRoute == .none, let player = self.nativePlayerDuringLoad,
                   self.route == .avPlayer, self.aether.currentAVPlayer === player { return }
                self.route = self.discMenu.state?.isInMenu == true ? .surface : Self.mapRoute(videoRoute)
            }
            .store(in: &cancellables)
        aether.$errorInfo
            .sink { [weak self] info in self?.applyFailure(info) }
            .store(in: &cancellables)
        aether.$audioTracks
            .sink { [weak self] tracks in self?.audioTracks = tracks.map(Self.mapTrack) }
            .store(in: &cancellables)
        aether.$activeAudioTrackIndex
            .sink { [weak self] index in self?.activeAudioTrackID = index }
            .store(in: &cancellables)
        aether.$mediaChapters
            .combineLatest(aether.$discChapters)
            .sink { [weak self] container, disc in
                guard let self, self.acceptsChapterUpdates, let version = self.chapterMediaVersion else { return }
                let infos = disc.isEmpty ? container : disc
                self.chapters = infos.map { info in
                    let chapter = Self.mapChapter(info)
                    return AppleChapter(title: chapter.title, start: chapter.start, end: chapter.end,
                                        provenance: .init(source: .embeddedContainer, mediaVersion: version))
                }
            }
            .store(in: &cancellables)
        aether.$discTitles
            .sink { [weak self] titles in
                guard let self, let url = self.discFileURL, !titles.isEmpty else { return }
                AppleDiscCatalog.shared.record(titles.map {
                    AppleDiscTitle(id: $0.id, durationSeconds: $0.durationSeconds, chapterCount: $0.chapterCount)
                }, for: url)
            }
            .store(in: &cancellables)
        aether.$subtitleTracks
            .sink { [weak self] tracks in
                guard let self else { return }
                let generation = self.loadGeneration
                // @Published fires before Aether stores the new tracks. A
                // synchronous auto-select cannot find a just-discovered 608 ID.
                Task { @MainActor [weak self] in
                    guard let self, self.loadGeneration == generation else { return }
                    self.applyEmbeddedSubtitleTracks(tracks.map(Self.mapTrack))
                }
            }
            .store(in: &cancellables)
        aether.$activeSubtitleTrackIndex
            .sink { [weak self] id in self?.applyEngineSubtitleSelection(id) }
            .store(in: &cancellables)
        aether.$subtitleCues
            .sink { [weak self] cues in
                guard let self, self.activeSubtitleTrackID != nil, self.activeExternalSubtitleID == nil, !self.stockPlayerRendersSubtitles else { return }
                self.subtitleCues = cues.map(Self.mapCue)
            }
            .store(in: &cancellables)
        aether.$duration
            .sink { [weak self] seconds in
                guard let self else { return }
                // `@Published` emits on `willSet`, so the sink's parameter is
                // the new value while `aether.duration` still holds the old one.
                // Capture the published value and compute from it, not the store.
                self.lastPublishedDuration = seconds
                self.refreshDuration()
            }
            .store(in: &cancellables)
        aether.$isLive
            .sink { [weak self] live in
                guard let self else { return }
                self.lastPublishedIsLive = live
                self.refreshDuration()
            }
            .store(in: &cancellables)
        aether.$sourceVideoWidth
            .sink { [weak self] width in
                self?.lastSourceVideoWidth = width
                self?.refreshVideoSize()
            }
            .store(in: &cancellables)
        aether.$sourceVideoHeight
            .sink { [weak self] height in
                self?.lastSourceVideoHeight = height
                self?.refreshVideoSize()
            }
            .store(in: &cancellables)
        aether.$softwareDisplaySize
            .sink { [weak self] size in
                self?.lastSoftwareDisplaySize = size
                self?.refreshVideoSize()
            }
            .store(in: &cancellables)
        aether.clock.$currentTime
            .sink { [weak self] seconds in
                self?.applyPosition(seconds)
                self?.checkStartupRestart(at: seconds)
            }
            .store(in: &cancellables)
        aether.clock.$sourceTime
            .sink { [weak self] seconds in self?.applyPresentationTime(seconds) }
            .store(in: &cancellables)
    }

    /// A Blu-ray opened before its titles were known started on the engine's
    /// longest playlist; the main feature by chapters
    /// (`AppleDiscMainTitlePolicy`) replaces it from the top. A resumed play
    /// stays put, since its position belongs to the title it opened.
    private func switchToMainTitle(_ request: ApplePlaybackRequest) {
        let titles = aether.discTitles.map {
            AppleDiscTitle(id: $0.id, durationSeconds: $0.durationSeconds, chapterCount: $0.chapterCount)
        }
        guard let pick = request.hints.disc?.replacementMainTitleID(for: titles) else { return }
        guard (request.resumePosition ?? 0) <= 0 else {
            appleTrace("disc main title: title \(pick) by chapters, kept title 0 for the resume point")
            return
        }
        appleTrace("disc main title: switching to title \(pick) by chapters")
        aether.selectTitle(id: pick)
    }

    /// Aether can select at startup or when live 608 is discovered. Its
    /// publisher is the rendered selection, not just an echo of app commands.
    func applyEngineSubtitleSelection(_ id: Int?) {
        activeSubtitleTrackID = AppleSubtitleSelectionState.renderedTrackID(
            engineTrackID: id, appTrackID: activeSubtitleTrackID,
            appOwnsRendering: activeExternalSubtitleID != nil || stockPlayerRendersSubtitles)
        if activeSubtitleTrackID == nil { subtitleCues = [] }
    }

    private func applyPhase(_ phase: PlaybackPhase) {
        // The engine applies a volume set before load to the host when it is
        // created, but the software host only builds its audio output inside
        // `load`, so the 0 from `init` landed on nothing and the `swift test`
        // Matroska fixture played out loud (2026-09-30). Every phase change
        // re-applies it, before any sample is rendered.
        if multiviewMuted || AppleTestAudioMute.isActive { aether.volume = 0 }
        #if os(visionOS)
        if (softwareAudioSwitch.selection != nil && softwareAudioSwitch.pauseRequested) || pausedLoadPosition != nil {
            aether.volume = 0
        }
        #endif
        applyLiveBuffer()
        if var forwarded = Self.forwardedPhase(phase, hasDiscSession: aether.dvdMenu != nil) {
            if forwarded == .seeking, startupRestart.overridesSeeking {
                forwarded = Self.transportPhase(state: deliveredTransport.state,
                                                isBuffering: deliveredTransport.isBuffering)
            }
            #if os(visionOS)
            self.phase = forwarded == .playing && ((softwareAudioSwitch.selection != nil && softwareAudioSwitch.pauseRequested)
                || pausedLoadPosition != nil)
                ? .paused : forwarded
            #else
            self.phase = forwarded
            #endif
        }
        // The pixel aspect is set after the coded size and is not published;
        // the next phase change picks it up.
        refreshVideoSize()
        #if os(visionOS)
        switch self.phase {
        case .error:
            finishSoftwareAudioSwitch(applyPause: true)
            route = .none
        case .ended:
            finishSoftwareAudioSwitch(applyPause: false)
            softwareAudioSwitch.reset()
        default:
            restoreSoftwareAudioSwitchIfReady()
        }
        if self.phase == .playing, softwareAudioSwitch.selection == nil, softwareAudioSwitch.awaitsLatePlayback {
            let generation = loadGeneration
            // A renderer that lands after the timeout still owes the user's Pause.
            Task { @MainActor [weak self] in
                guard let self, self.loadGeneration == generation, self.phase == .playing,
                      self.softwareAudioSwitch.selection == nil,
                      self.softwareAudioSwitch.consumeLatePause() else { return }
                self.aether.pause()
            }
        }
        #endif
    }

    private func refreshVideoSize() {
        let next = Self.displaySize(
            software: lastSoftwareDisplaySize,
            codedWidth: lastSourceVideoWidth,
            codedHeight: lastSourceVideoHeight,
            pixelAspect: aether.sourceVideoPixelAspectRatio
        )
        if next != videoSize { videoSize = next }
    }

    /// What the picture presents at: the software renderer's own size when it
    /// has one, else the coded size widened by the pixel aspect. nil unknown.
    nonisolated static func displaySize(
        software: CGSize?, codedWidth: Int32, codedHeight: Int32, pixelAspect: Double
    ) -> CGSize? {
        if let software, software.width > 0, software.height > 0 { return software }
        guard codedWidth > 0, codedHeight > 0 else { return nil }
        let aspect = pixelAspect.isFinite && pixelAspect > 0 ? pixelAspect : 1
        return CGSize(width: (Double(codedWidth) * aspect).rounded(), height: Double(codedHeight))
    }

    private func applyFailure(_ info: PlaybackErrorInfo?) {
        guard let info else {
            failure = nil
            return
        }
        #if os(visionOS)
        finishSoftwareAudioSwitch(applyPause: true)
        #endif
        nativePlayerDuringLoad = nil
        route = .none
        failure = Self.classify(info, hasReachedPlaying: hasReachedPlaying)
    }

    private func applyPosition(_ seconds: Double) {
        guard seconds.isFinite else { return }
        #if os(visionOS)
        let seconds = pausedLoadPosition
            ?? (softwareAudioSwitch.pauseRequested ? softwareAudioSwitch.selection?.position : nil) ?? seconds
        #endif
        let now = Date()
        guard now.timeIntervalSince(lastPositionUpdate) >= 0.25 else { return }
        lastPositionUpdate = now
        position = max(0, seconds)
        emit(.position(position))
    }

    private func applyPresentationTime(_ seconds: Double) {
        guard seconds.isFinite else { return }
        presentationTime = max(0, seconds)
        guard activeSubtitleTrackID != nil else { return }
        let now = Date()
        // Cue readers re-read on position ticks. While the scrub clock is held
        // those stop, so tick them off the picture instead.
        if now.timeIntervalSince(lastPositionUpdate) >= 0.5 {
            lastPositionUpdate = now
            emit(.position(position))
        }
        if now.timeIntervalSince(lastCueClockTrace) >= 5 {
            lastCueClockTrace = now
            let gap = ((aether.clock.currentTime - presentationTime) * 100).rounded() / 100
            appleTrace("cue clock: scrub minus picture \(gap)s")
        }
    }

    private func refreshDuration() {
        if lastPublishedIsLive {
            duration = nil
        } else if lastPublishedDuration > 0 {
            duration = lastPublishedDuration
        } else {
            duration = nil
        }
    }

    /// Auto-selects when tracks arrive. `.always` takes the best visible track; language preferences require a
    /// match, including sidecar tracks that arrive after the embedded selection.
    /// A manual choice (including "Off") always survives track discovery.
    private func autoSelectSubtitleIfPreferred() {
        guard !subtitleSelectionOverridden, captionsPreference != .off,
              !subtitleTracks.isEmpty,
              aether.activeSubtitleTrackIndex == nil,
              activeExternalSubtitleID == nil,
              let first = AppleSubtitleTrackFilter.visible(
                  subtitleTracks,
                  preferredLanguages: preferredSubtitleLanguages,
                  isExplicitChoice: subtitleLanguagesAreExplicit
              ).first else { return }
        // Only tagged preferred-language tracks qualify for automatic selection.
        applySubtitleSelection(id: first.id)
    }

    private func emit(_ event: ApplePlaybackEngineEvent) {
        eventStream.emit(event)
    }

    // MARK: - Startup restart (`AppleStartupRestartWatch`)

    /// The engine's seek events without a resume's own producer restart,
    /// which is not the viewer scrubbing.
    var viewerSeekEvents: AnyPublisher<SeekEvent, Never> { viewerSeekSubject.eraseToAnyPublisher() }

    private func observeSeekEvent(_ event: SeekEvent) {
        let began: Bool
        if case .began = event.outcome { began = true } else { began = false }
        startupRestart.observe(id: event.id, isNativeScrub: event.origin == .nativeScrub, began: began,
                                   target: event.target,
                                   hasPresented: hasReachedPlaying || aether.hasFirstFrameReadyForDisplay)
        if event.id != startupRestart.restartID { viewerSeekSubject.send(event) }
    }

    /// `position` is `clock.currentTime`, on the display axis like the seek
    /// event's target (AE#270); `clock.sourceTime` is raw source PTS and
    /// differs from it by the container's start time. Apple TV 2026-11-04
    /// (origin 0): currentTime 1589.631, sourceTime 1589.631, target 1577.56.
    private func checkStartupRestart(at position: Double) {
        guard startupRestart.observe(position: position, firstFrameReady: aether.hasFirstFrameReadyForDisplay,
                                     isPaused: deliveredTransport.state == .paused),
              let deliveredPhase else { return }
        appleTrace("startup restart landed at \(Int(position))s; not waiting for the engine's scrub watch")
        applyPhase(deliveredPhase)
    }

    /// The phase without the startup restart's seek, as the engine folds it.
    nonisolated static func transportPhase(state: PlaybackState, isBuffering: Bool) -> ApplePlaybackEnginePhase {
        if state == .paused { return .paused }
        return isBuffering ? .rebuffering : .playing
    }

    // MARK: - Mapping

    /// A title's end/stop belongs to the navigator until it tears down the disc session.
    nonisolated static func forwardedPhase(_ phase: PlaybackPhase, hasDiscSession: Bool) -> ApplePlaybackEnginePhase? {
        if hasDiscSession {
            switch phase {
            case .ended, .idle: return nil
            default: break
            }
        }
        return mapPhase(phase)
    }

    nonisolated private static func mapPhase(_ phase: PlaybackPhase) -> ApplePlaybackEnginePhase {
        switch phase {
        case .idle: return .idle
        case .loading: return .loading
        case .playing: return .playing
        case .paused: return .paused
        case .seeking: return .seeking
        case .rebuffering: return .rebuffering
        case .stalled(let reconnecting): return .stalled(reconnecting: reconnecting)
        case .ended: return .ended
        case .error(let message): return .error(message)
        }
    }

    private static func mapRoute(_ route: VideoRoute) -> ApplePlaybackPresentationRoute {
        switch route {
        case .none: return .none
        case .remoteBypass, .loopback: return .avPlayer
        case .software: return .surface
        case .audio: return .audioOnly
        }
    }

    private static func mapTrack(_ track: TrackInfo) -> ApplePlaybackTrack {
        ApplePlaybackTrack(
            id: track.id,
            title: track.name,
            language: track.language,
            codec: track.codec,
            isDefault: track.isDefault,
            isForced: track.isForced,
            isHearingImpaired: track.isHearingImpaired,
            channels: track.channels,
            isCommentary: track.isCommentary,
            isAtmos: track.isAtmos
        )
    }

    private static func mapCue(_ cue: SubtitleCue) -> AppleSubtitleCue {
        AppleSubtitleCue(
            id: cue.id,
            startTime: cue.startTime,
            endTime: cue.endTime,
            body: mapCueBody(cue.body)
        )
    }

    /// Embedded text tracks carry the same "£"-for-"♪" captions as sidecar
    /// files (A Different World's MKV, iOS 18.6 regression
    /// 2026-10-01), so they get the same repair
    /// (`AppleSubtitleTextParser.musicNotesRestored`).
    static func mapCueBody(_ body: SubtitleCue.Body) -> AppleSubtitleCueBody {
        switch body {
        case .text(let s):
            return .text(AppleSubtitleTextParser.musicNotesRestored(s))
        case .richText(let runs):
            return .richText(runs.map { run in
                AppleSubtitleTextRun(
                    text: AppleSubtitleTextParser.musicNotesRestored(run.text),
                    isBold: run.isBold,
                    isItalic: run.isItalic,
                    isUnderlined: run.isUnderlined,
                    isStruckThrough: run.isStruckThrough
                )
            })
        case .image(let image):
            return .image(AppleSubtitleBitmap(
                image: image.cgImage,
                rect: image.position,
                canvasSize: image.canvasSize,
                isForced: image.isForced
            ))
        }
    }

    static func classify(_ info: PlaybackErrorInfo, hasReachedPlaying: Bool) -> ApplePlaybackFailure {
        let code = info.underlyingCode
        // `sourceRefused` / `sourceRateLimited` carry the origin's HTTP status;
        // a URL loading error names why the host could not be reached. Both
        // tell a service that is down from one file that is not there.
        let httpStatus = info.underlyingDomain == nil ? code.flatMap { (100...599).contains($0) ? $0 : nil } : nil
        let networkCode = info.underlyingDomain == NSURLErrorDomain ? code.map(URLError.Code.init(rawValue:)) : nil
        // An HTTP 401/403 from the origin is authentication regardless of the
        // engine's own kind token (`sourceRefused` carries the status in `underlyingCode`).
        if code == 401 || code == 403 {
            return ApplePlaybackFailure(
                kind: .authentication,
                message: "The provider rejected the account or request headers (HTTP \(code!).",
                httpStatus: code
            )
        }
        // Usually mid-playback: the segment files filled the device. Classified
        // before the mid-playback rule so the source is not blamed for it.
        if info.kind == .insufficientStorage {
            return ApplePlaybackFailure(kind: .storageFull, message: ApplePlaybackFailure.storageFullMessage)
        }
        // After playback has rolled, surface the engine's own message as a
        // mid-playback player failure rather than reclassifying the load.
        if hasReachedPlaying {
            return ApplePlaybackFailure(kind: .player,
                                        message: AppleTruncatedMediaProbe.readableEngineMessage(info.message, midStream: true))
        }
        let unsupportedKinds: Set<PlaybackErrorKind> = [
            .noPlayableTrackWithinBudget,
            .masterPlaylistRejected,
            .softwarePipelineFailed,
            .dolbyVisionRequiresHardware,
            .demuxedAudioLiveUnsupported,
            .hlsPlaylistOnRawLivePath,
        ]
        if unsupportedKinds.contains(info.kind) {
            return ApplePlaybackFailure(
                kind: .unsupportedMedia,
                message: "This stream uses a format oStream cannot play on this device."
            )
        }
        // AVFoundation codec/container rejections land as unsupported too.
        if let domain = info.underlyingDomain, domain == AVFoundationErrorDomain,
           let resolvedCode = code, resolvedCode == -11828 || resolvedCode == -11829 {
            return ApplePlaybackFailure(
                kind: .unsupportedMedia,
                message: "This stream uses a format oStream cannot play on this device."
            )
        }
        let networkKinds: Set<PlaybackErrorKind> = [
            .sourceRefused,
            .sourceRateLimited,
            .vodSourceFailed,
            .liveSourceUnavailable,
            .audioSessionFailed,
        ]
        if networkKinds.contains(info.kind) {
            return ApplePlaybackFailure(kind: .network,
                                        message: AppleTruncatedMediaProbe.readableEngineMessage(info.message, midStream: false),
                                        httpStatus: httpStatus, networkCode: networkCode)
        }
        return ApplePlaybackFailure(kind: .player,
                                    message: AppleTruncatedMediaProbe.readableEngineMessage(info.message, midStream: false),
                                    networkCode: networkCode)
    }
}
