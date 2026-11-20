import AVFoundation
import AetherEngine
import Combine
import Foundation
import Observation

public enum ApplePlaybackPhase: Equatable, Sendable {
    case idle
    case resolving
    case loading
    case waiting(String?)
    case playing
    case paused
    case ended
    case failed(ApplePlaybackFailure)

    public var isBusy: Bool {
        switch self {
        case .resolving, .loading, .waiting:
            true
        case .idle, .playing, .paused, .ended, .failed:
            false
        }
    }
}

public struct ApplePlaybackFailure: Error, Equatable, LocalizedError, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case authentication
        case network
        case unsupportedMedia
        case unavailable
        case player
        case timedOut
        case sourceEnded
        case engineUnavailable
        /// The device ran out of storage for the player's segment files. Not
        /// the source's fault: no fallback, and Retry can work once tvOS or
        /// the viewer frees space.
        case storageFull
        /// The load was cancelled because a newer request replaced it (a
        /// channel switch). Never shown to the viewer.
        case cancelled
    }

    public let kind: Kind
    public let message: String
    /// The HTTP status the origin answered with, when the failure carries one.
    public let httpStatus: Int?
    /// The URL loading error underneath, when there was one (no route to the
    /// host, DNS failure, timeout).
    public let networkCode: URLError.Code?
    public let isConnectionLimit: Bool

    public init(kind: Kind, message: String, httpStatus: Int? = nil, networkCode: URLError.Code? = nil,
                isConnectionLimit: Bool = false) {
        self.kind = kind
        self.message = message
        self.httpStatus = httpStatus
        self.networkCode = networkCode
        self.isConnectionLimit = isConnectionLimit
    }

    public var errorDescription: String? { message }

    static let storageFullMessage = "This device is out of storage. Free up space, then try again."

    /// Engine diagnostics remain in `message` for recovery policies and traces.
    /// Only this wording belongs in playback alerts.
    public var userMessage: String {
        let diagnostic = message.lowercased()
        let hasEngineDiagnostic = ["videoengine", "demuxer", "ffmpeg", "coremedia", "avplayer"]
            .contains { diagnostic.contains($0) }
        if kind == .player || hasEngineDiagnostic {
            return "This video could not be played. Try another source."
        }
        return message
    }

    /// Channel playback failures do not invalidate a saved playlist or account.
    var liveChannelMessage: String {
        switch kind {
        case .authentication:
            let status = message.contains("403") ? " (HTTP 403)" : message.contains("401") ? " (HTTP 401)" : ""
            return "The provider denied access to this channel\(status). Try again or choose another channel."
        case .player:
            return "This channel could not start playing. Try again or choose another channel."
        case .network, .timedOut:
            return "This channel is not responding. Check your connection, then try again or choose another channel."
        default:
            return userMessage
        }
    }

    public static func classify(_ error: any Error) -> ApplePlaybackFailure {
        // A cancelled load is a channel switch, not a failure the viewer caused.
        if error is CancellationError {
            return ApplePlaybackFailure(kind: .cancelled, message: "Playback was cancelled.")
        }
        if let failure = error as? ApplePlaybackFailure { return failure }

        // Every source for the title was ruled out; asking again rules them
        // out again, so this is not a player fault worth a retry.
        if let library = error as? AppleLibrarySourceError, library == .noMedia {
            return .init(kind: .unavailable, message: library.localizedDescription)
        }

        if let iptv = error as? AppleIPTVError {
            switch iptv {
            case .missingCredentials, .authenticationFailed:
                return .init(
                    kind: .authentication,
                    message: iptv.localizedDescription,
                    isConnectionLimit: AppleIPTVFailureCause.classify(iptv) == .streamLimit
                )
            case .requestFailed(let status) where status == 401 || status == 403,
                 .streamRequestFailed(let status) where status == 401 || status == 403:
                return .init(
                    kind: .authentication,
                    message: "The Live TV provider rejected the account or required request headers (HTTP \(status)).",
                    httpStatus: status
                )
            case .requestFailed(let status), .streamRequestFailed(let status):
                return .init(kind: .network, message: iptv.localizedDescription, httpStatus: status)
            case .invalidSource, .invalidPlaylist:
                return .init(kind: .unavailable, message: iptv.localizedDescription)
            default:
                return .init(kind: .network, message: iptv.localizedDescription)
            }
        }

        if let share = error as? AppleSMBError {
            let kind: Kind = switch share {
            case .authenticationFailed, .accessDenied: .authentication
            case .serverUnreachable, .connectionFailed: .network
            case .invalidHost, .invalidPort, .invalidShare, .unavailableOnPlatform, .notFound: .unavailable
            }
            return .init(kind: kind, message: share.localizedDescription)
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .userAuthenticationRequired, .noPermissionsToReadFile:
                return .init(
                    kind: .authentication,
                    message: "The media server rejected the account or request headers.",
                    networkCode: urlError.code
                )
            case .timedOut:
                return .init(kind: .timedOut, message: "Playback timed out while waiting for the media server.",
                             networkCode: urlError.code)
            case .unsupportedURL, .cannotDecodeContentData, .cannotDecodeRawData:
                return .init(
                    kind: .unsupportedMedia,
                    message: "This media format cannot be played directly. Try another source.",
                    networkCode: urlError.code
                )
            default:
                return .init(
                    kind: .network,
                    message: "oStream could not reach the media server. Check the server and network, then try again.",
                    networkCode: urlError.code
                )
            }
        }

        let nsError = error as NSError
        if nsError.domain == AVFoundationErrorDomain {
            return .init(
                kind: .unsupportedMedia,
                message: "AVPlayer could not decode this media. Try another source."
            )
        }

        if nsError.domain == "CoreMediaErrorDomain" {
            if nsError.code == -12887 {
                return .init(
                    kind: .unavailable,
                    message: "The provider returned an empty playlist. The channel may be offline or the account may be out of connections."
                )
            }
            return .init(
                kind: .player,
                message: "The player could not read this stream (CoreMedia \(nsError.code))."
            )
        }

        let clean = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return .init(
            kind: .player,
            message: clean.isEmpty ? "Playback failed before the player became ready." : clean
        )
    }
}

/// Owns the user-visible lifecycle for every Apple playback attempt. The
/// coordinator loads an `ApplePlaybackRequest` into its engine, mirrors the
/// engine's phase/route events into `phase`, and applies the policy table
/// (timeout, live-retry, progress throttling) so the player view only needs to
/// observe `phase` and `route`.
@MainActor
@Observable
public final class ApplePlaybackCoordinator {
    public private(set) var phase: ApplePlaybackPhase = .idle
    public private(set) var route: ApplePlaybackPresentationRoute = .none
    /// The audio track picked in the transport that the engine has not
    /// confirmed yet; outlives one overlay (`AppleTransportOverlayModel`).
    @ObservationIgnored var pendingAudioPick: Int?
    /// The previous episode's audio and subtitle choices, applied once this
    /// stream's tracks are known (`AppleTrackCarryOver`). Each half clears
    /// itself when applied.
    @ObservationIgnored var trackCarryOver: AppleTrackCarryOver? {
        didSet {
            if let chain = trackCarryOver?.autoPlayChain { autoPlayChain = chain }
        }
    }
    var autoPlayChain = AppleAutoPlayChain()
    /// Set by the transport while the end of this stream will start the next
    /// episode; the player then stays open at `.ended` for the handover.
    @ObservationIgnored var handsOffAtEnd = false
    /// The next episode has been started from this stream; once is enough.
    @ObservationIgnored var hasAdvancedToNextEpisode = false
    /// The viewer's subtitle delay and frame-rate fix for the title playing.
    /// Per play: a retry, a fallback or a quality switch of the same title
    /// keeps it, a different title starts at zero, and nothing is saved.
    public var subtitleTiming = AppleSubtitleTiming() {
        didSet {
            guard subtitleTiming != oldValue else { return }
            appleTrace("subtitle timing delay=\(subtitleTiming.delayLabel) fps=\(subtitleTiming.frameRateFix.rawValue)")
        }
    }
    @ObservationIgnored private var subtitleTimingMediaID: String?
    public private(set) var engine: any ApplePlaybackEngine
    var sharePlayChannel: AppleSharePlayChannel?
    weak var sharedPlayback: AppleSharePlayPlaybackBinding?

    func userPlay() {
        if pendingSeekTarget != nil { seekPlaybackIntent = true }
        #if os(visionOS)
        if phase == .ended, sharedPlayback == nil, var request = lastRequest, !request.isLive {
            request.resumePosition = 0
            request.autoplay = true
            let expectedGeneration = generation
            Task { @MainActor [weak self] in
                guard let self, self.generation == expectedGeneration else { return }
                await self.begin(request)
            }
            return
        }
        #endif
        if let sharedPlayback { sharedPlayback.play() } else { engine.play() }
    }

    func userPause() {
        if pendingSeekTarget != nil { seekPlaybackIntent = false }
        cancelInitialLiveSeek()
        liveEdgeCorrectionTask?.cancel()
        liveEdgeCorrectionTask = nil
        liveEdgeFollow.suspend()
        if let sharedPlayback { sharedPlayback.pause() } else { engine.pause() }
    }

    /// The viewer's newest seek target until playback reaches it
    /// (`AppleSeekTargetPolicy`); nil when the position is current.
    private(set) var pendingSeekTarget: Double?
    @ObservationIgnored private var seekTargets = AppleSeekTargetPolicy()
    @ObservationIgnored private var seekTask: Task<Void, Never>?
    @ObservationIgnored private var seekDeadlineTask: Task<Void, Never>?
    @ObservationIgnored private var seekPlaybackIntent: Bool?
    @ObservationIgnored private var nativeScrubID: UInt64?
    @ObservationIgnored private var observesNativeScrub = false
    @ObservationIgnored private var seekRetryAttempted = false
    @ObservationIgnored private var engineSeekObservation: AnyCancellable?
    static let seekTimeout: Duration = .seconds(12)
    /// How long one seek may keep buffering, across every re-armed deadline,
    /// before the player gives up on it and offers Retry at its target.
    static let seekRecoveryLimit: Duration = seekTimeout * 5
    /// When the newest run of seeks began: the first seek after the
    /// transport had arrived. Superseding commits and AVKit scrub steps
    /// share it, so a scrub that never stops buffering still reaches Retry.
    @ObservationIgnored private var seekBurstStart: ContinuousClock.Instant?

    /// Where a relative move (a skip, a scrubber step) starts: the newest
    /// target while earlier seeks are still landing, else the position.
    var seekBase: Double { seekTargets.base(position: engine.presentationTime) }

    /// Every viewer seek. One runs at a time; targets asked for while it lands
    /// fold into a single follow-up seek to the newest. `supersedingInFlight`
    /// (a scrub session's commit) replaces the seek in flight instead of
    /// queueing behind its landing. `play` sets whether playback runs once
    /// it lands; otherwise it keeps what it was doing.
    func userSeek(to seconds: Double, supersedingInFlight: Bool = false, play: Bool? = nil) async {
        guard seconds.isFinite, !Task.isCancelled,
              lastRequest != nil || engine.route != .none else { return }
        nativeScrubID = nil
        let target: Double
        if lastRequest?.isLive != true, let duration = engine.duration, duration.isFinite, duration > 0 {
            target = min(duration, max(0, seconds))
        } else {
            target = max(0, seconds)
        }
        cancelInitialLiveSeek()
        liveEdgeFollow.seek(to: target, range: engine.seekableRange, holdBack: engine.liveEdgeOffset)
        #if os(visionOS)
        if phase == .ended, sharedPlayback == nil, var request = lastRequest, !request.isLive {
            request.resumePosition = target
            request.autoplay = false
            await begin(request)
            return
        }
        #endif
        if let play {
            seekPlaybackIntent = play
        } else if seekPlaybackIntent == nil {
            seekPlaybackIntent = loadTask != nil ? (lastRequest?.autoplay ?? true)
                : phase != .paused && engine.phase != .paused
        }
        let attempt = generation
        let replaced = supersedingInFlight ? seekTargets.inFlight : nil
        var next = updateSeekTargets {
            $0.request(target, deferred: loadTask != nil, superseding: supersedingInFlight)
        }
        if let replaced, next != nil {
            appleTrace("seek \(Int(replaced.target))s superseded → \(Int(target))s")
            seekTask?.cancel()
        }
        while let seek = next {
            armSeekDeadline(seek, attempt: attempt)
            if let sharedPlayback {
                sharedPlayback.seek(to: seek.target)
            } else {
                let engine = self.engine
                let task = Task { @MainActor in await engine.seek(to: seek.target) }
                seekTask = task
                await task.value
            }
            guard generation == attempt, seekTargets.inFlight == seek else { return }
            seekTask = nil
            next = updateSeekTargets { $0.returned(seek, now: clock.now) }
        }
        guard generation == attempt, seekTargets.inFlight == nil, loadTask == nil else { return }
        let finalTarget = pendingSeekTarget ?? target
        if sharedPlayback == nil, let shouldPlay = seekPlaybackIntent {
            if !shouldPlay { engine.pause() }
            else if !seekReachesEnd(finalTarget), engine.phase != .ended { engine.play() }
        }
        seekPositionChanged(engine.presentationTime)
    }

    private func seekReachesEnd(_ target: Double) -> Bool {
        lastRequest?.isLive != true && engine.duration.map {
            $0.isFinite && $0 > 0 && target >= $0 - AppleNextEpisodePolicy.endTolerance
        } == true
    }

    /// `since`: when this run of seeks started (`seekBurstStart`); re-arms
    /// carry it so buffering cannot extend the wait past `seekRecoveryLimit`.
    private func armSeekDeadline(_ seek: AppleSeekTargetPolicy.Seek, attempt: Int,
                                 since: ContinuousClock.Instant? = nil) {
        seekDeadlineTask?.cancel()
        let started = since ?? seekBurstStart ?? clock.now
        let deadline = clock.now.advanced(by: Self.seekTimeout)
        let previousPosition = engine.presentationTime
        seekDeadlineTask = Task { @MainActor [weak self, clock] in
            do { try await clock.sleep(until: deadline) } catch { return }
            guard let self, !Task.isCancelled, self.generation == attempt,
                  self.seekTargets.inFlight == seek || self.pendingSeekTarget != nil else { return }
            if self.observesNativeScrub, self.engine.phase == .paused {
                self.resetSeeks()
                return
            }
            switch self.engine.phase {
            case .rebuffering, .loading:
                self.extendSeekDeadline(seek, attempt: attempt, since: started)
                return
            default:
                break
            }
            self.seekPositionChanged(self.engine.presentationTime)
            guard self.seekTargets.inFlight != nil || self.pendingSeekTarget != nil else { return }
            if abs(self.engine.presentationTime - previousPosition) > AppleSeekTargetPolicy.arrivalTolerance {
                self.armSeekDeadline(seek, attempt: attempt, since: started)
                return
            }
            self.seekDeadlineTask = nil
            let target = self.pendingSeekTarget ?? seek.target
            if !self.seekRetryAttempted {
                let shouldPlay = self.seekPlaybackIntent
                self.resetSeeks()
                self.seekRetryAttempted = true
                self.seekPlaybackIntent = shouldPlay
                appleTrace("seek deadline → retry latest target")
                await self.userSeek(to: target)
                return
            }
            switch self.engine.phase {
            case .idle, .stalled, .error:
                await self.recoverSeek(to: target)
            case .playing, .paused, .ended:
                self.resetSeeks()
            case .seeking, .loading, .rebuffering:
                self.extendSeekDeadline(seek, attempt: attempt, since: started)
            }
        }
    }

    /// Another deadline for a seek that is still buffering, unless it has
    /// used up `seekRecoveryLimit`: then playback stops and the player offers
    /// Retry at the newest target rather than spinning on.
    private func extendSeekDeadline(_ seek: AppleSeekTargetPolicy.Seek, attempt: Int,
                                    since started: ContinuousClock.Instant) {
        guard started.duration(to: clock.now) >= Self.seekRecoveryLimit else {
            armSeekDeadline(seek, attempt: attempt, since: started)
            return
        }
        let target = pendingSeekTarget ?? seek.target
        let shouldPlay = seekPlaybackIntent ?? true
        appleTrace("seek to \(Int(target))s still buffering after \(Self.seekRecoveryLimit) → offering Retry")
        resetSeeks()
        if var request = lastRequest {
            request.resumePosition = target
            request.autoplay = shouldPlay
            lastRequest = request
        }
        generation &+= 1
        loadTask?.cancel()
        loadTask = nil
        stopMonitoring()
        cancelTimeout()
        cancelObservation()
        engine.stop()
        setPhase(.failed(ApplePlaybackFailure(
            kind: .timedOut, message: "The video stopped loading at this point.")))
    }

    private func recoverSeek(to target: Double) async {
        guard var request = lastRequest else { stop(); return }
        request.resumePosition = target
        request.autoplay = seekPlaybackIntent ?? true
        appleTrace("seek retry stalled → reopen at latest target")
        await beginAttempt(request)
    }

    private func resetSeeks() {
        seekTask?.cancel()
        seekTask = nil
        seekDeadlineTask?.cancel()
        seekDeadlineTask = nil
        seekPlaybackIntent = nil
        nativeScrubID = nil
        observesNativeScrub = false
        seekRetryAttempted = false
        updateSeekTargets { $0.reset() }
    }

    func stockSeekCommitted(to target: Double, isPlaying: Bool) {
        appleTrace("stock scrub committed")
        watchNativeScrub(to: target, shouldPlay: isPlaying)
    }

    func observeNativeSeek(_ event: SeekEvent) {
        guard event.origin == .nativeScrub else { return }
        switch event.outcome {
        case .began:
            watchNativeScrub(to: event.target, shouldPlay: phase != .paused && engine.phase != .paused)
            if pendingSeekTarget != nil { nativeScrubID = event.id }
        case .landed where nativeScrubID == event.id:
            resetSeeks()
        default:
            break
        }
    }

    private func watchNativeScrub(to target: Double, shouldPlay: Bool) {
        guard target.isFinite, lastRequest != nil, loadTask == nil else { return }
        // AVKit owns the seek; only watch its landing, without issuing another.
        let burstStart = seekBurstStart
        resetSeeks()
        seekBurstStart = burstStart
        observesNativeScrub = true
        seekPlaybackIntent = shouldPlay
        if let seek = updateSeekTargets({ $0.request(target) }) {
            updateSeekTargets { $0.returned(seek, now: clock.now) }
            armSeekDeadline(seek, attempt: generation)
        }
    }

    func userReturnToLive() async {
        let failed: Bool
        if case .failed = phase { failed = true } else { failed = false }
        guard phase == .paused || engine.phase == .paused || failed || !AppleLiveSeekPolicy.isAtLiveEdge(
            position: engine.position, in: engine.seekableRange, tolerance: liveEdgeTolerance) else { return }
        guard !failed, let target = AppleLiveSeekPolicy.liveTarget(in: engine.seekableRange, holdBack: engine.liveEdgeOffset) else {
            guard var request = lastRequest, request.isLive else { return }
            request.autoplay = true
            await begin(request)
            return
        }
        liveEdgeFollow = AppleLiveEdgeFollowPolicy()
        let attempt = generation
        await userSeek(to: target)
        guard generation == attempt, !Task.isCancelled else { return }
        liveEdgeFollow.seek(to: target, range: engine.seekableRange, holdBack: engine.liveEdgeOffset)
        userPlay()
    }

    var liveEdgeTolerance: Double { AppleLiveSeekPolicy.edgeTolerance(holdBack: engine.liveEdgeOffset) }

    /// Internal so a model test can tick it without loading a stream.
    func seekPositionChanged(_ position: Double) {
        guard let target = seekTargets.pending, seekTargets.inFlight == nil, nativeScrubID == nil else { return }
        if seekPlaybackIntent == true, engine.phase != .playing, !seekReachesEnd(target) { return }
        updateSeekTargets { $0.observe(position: position, now: clock.now) }
        if seekTargets.pending == nil, seekTargets.inFlight == nil {
            seekDeadlineTask?.cancel()
            seekDeadlineTask = nil
            seekPlaybackIntent = nil
            observesNativeScrub = false
            seekRetryAttempted = false
        }
    }

    /// The policy is not observed; only its pending target is, and only when
    /// it changes, so position ticks do not invalidate the transport.
    @discardableResult
    private func updateSeekTargets<Value>(_ change: (inout AppleSeekTargetPolicy) -> Value) -> Value {
        let result = change(&seekTargets)
        if pendingSeekTarget != seekTargets.pending { pendingSeekTarget = seekTargets.pending }
        if seekTargets.pending == nil, seekTargets.inFlight == nil { seekBurstStart = nil }
        else if seekBurstStart == nil { seekBurstStart = clock.now }
        return result
    }

    private var failureMonitor: Task<Void, Never>?
    private weak var monitoredSession: ApplePlayerSession?

    var nextAutomaticSource: (() async throws -> ApplePlaybackRequest?)?
    var onSourceFailure: ((ApplePlaybackRequest) -> Void)?
    public private(set) var fallbackNoticeGeneration = 0
    /// Streams this press passed over because this coordinator's engine
    /// cannot open them (`engineOpens`): the Native player's MKVs. Traced
    /// when the press ends with nothing played.
    public private(set) var streamsSkippedForEngine = 0
    /// The streams this press has loaded, in order, each once. When every one
    /// fails on the Native player the title page starts the OpenStream engine
    /// on the rest first (`ApplePlaybackEngineFallback.fallbackOrder`).
    public private(set) var triedSourceURLs: [URL] = []
    private var hasShownFallbackNotice = false
    private var lastRequest: ApplePlaybackRequest?
    private var resetRetryRequest: ApplePlaybackRequest?
    /// The request playing (or last tried), for the next episode to prefer
    /// its service.
    var currentRequest: ApplePlaybackRequest? { lastRequest }
    private var observationTask: Task<Void, Never>?
    private var loadTask: Task<Void, any Error>?
    private var fallbackTask: Task<Void, Never>?
    private var generation = 0
    private var timeoutTask: Task<Void, Never>?
    @ObservationIgnored private(set) var initialLiveSeekTask: Task<Void, Never>?
    private var liveRetryTask: Task<Void, Never>?
    private var liveRetryAttempted = false
    /// The live start deadline was already extended once for this attempt.
    private var liveStartExtended = false
    @ObservationIgnored private var initialLiveStart: ContinuousClock.Instant?
    @ObservationIgnored private var liveSourceOpened = false
    /// A disc image's start: when it began and how far it had got at the last
    /// deadline (`ApplePlaybackStartPolicy.discStartExtension`).
    private var discStartBegan: ContinuousClock.Instant?
    private var discStartMark = ApplePlaybackStartPolicy.DiscStartProgress()
    private var mediaServerStartCheckpoint = 0
    /// Injected by tests with millisecond windows.
    @ObservationIgnored var discStartWindow = ApplePlaybackStartPolicy.discProgressWindow
    @ObservationIgnored var discStartCap = ApplePlaybackStartPolicy.discStartCap
    @ObservationIgnored var discCrashGuard = AppleDiscCrashGuard.shared

    // MARK: - Live reconnect (`AppleLiveReconnectPolicy`)

    /// Injected by tests with millisecond delays.
    @ObservationIgnored var liveReconnectPolicy: AppleLiveReconnectPolicy = .standard
    /// Times the start deadline, the live reconnect delays, the stall timer
    /// and the progress throttle; tests drive it by hand.
    @ObservationIgnored var clock: any AppleClock = AppleSystemClock()
    /// The reopen in flight (1-based) while a live channel that was playing
    /// is being reconnected; 0 otherwise. The player reads it to say
    /// "Reconnecting…" instead of "Connecting to …".
    public private(set) var liveReconnectAttempt = 0
    /// This press's live channel has shown a frame. Only a channel that was
    /// playing is reconnected; one that never started is a dead channel.
    private var liveHasPlayed = false
    private var liveEpisodeAttempts = 0
    private var liveEpisodeStart: ContinuousClock.Instant?
    private var livePlayingSince: ContinuousClock.Instant?
    private var liveStallTask: Task<Void, Never>?
    private var liveStallStart: ContinuousClock.Instant?
    private var liveStallKind: String?
    @ObservationIgnored private var liveEdgeFollow = AppleLiveEdgeFollowPolicy()
    @ObservationIgnored private(set) var liveEdgeCorrectionTask: Task<Void, Never>?
    private(set) var rebuffers = ApplePlaybackRebufferLedger()
    /// Holds a rebuffer that starts mid-play off the screen for its first half second.
    private var rebufferShowTask: Task<Void, Never>?
    static let reconnectingText = "Reconnecting…"

    /// The live channel is being reconnected, by this coordinator's bounded
    /// reopen or by the engine's own (`.stalled(reconnecting:)`).
    public var isReconnectingLive: Bool {
        guard phase.isBusy else { return false }
        if liveReconnectAttempt > 0 { return true }
        return (lastRequest?.isLive ?? false) && phase == .waiting(Self.reconnectingText)
    }
    private let timeoutDuration: Duration
    private let retryDelay: Duration
    private let progressInterval: Duration
    private var lastProgressWrite: ContinuousClock.Instant?
    private var progressCoordinator: ApplePlaybackProgressCoordinator?
    private(set) var progressEnded = false
    /// The media and part the software route writes progress under when no
    /// host `progressWriter` is installed. Nil for live, which has no position.
    private var surfaceProgressIdentity: String?
    /// The saved position this attempt opened at, which a failure's zero
    /// must not overwrite (`ApplePlaybackProgressCoordinator.keepsResumePoint`).
    private(set) var resumedFrom: Double?
    private var surfaceProgressPartID: String?

    public enum RemoteProgressEvent: Sendable {
        case started
        case progress
        case paused
        case stopped
    }

    public var remoteProgressSink: (@MainActor (_ mediaID: String, _ position: Double, _ duration: Double, _ event: RemoteProgressEvent) -> Void)?
    private var remoteProgressStarted = false
    private(set) var lastKnownPosition: Double = 0
    private var avPlayerProgressObserver: Any?
    private weak var avPlayerProgressObserverPlayer: AVPlayer?

    /// Injected by tests (and the host) to record progress writes on `.surface`
    /// routes. Called at most once per `progressInterval` with `(position, duration)`.
    /// On `.avPlayer` routes the existing `ApplePlaybackProgressCoordinator`
    /// observes `engine.avPlayer` directly.
    public var progressWriter: (@MainActor (Double, Double) -> Void)?

    private var externalSubtitleTask: Task<Void, Never>?
    private var librarySubtitles = AppleLibrarySubtitleService()

    // MARK: - Candidate fallback

    private var fallbackCandidates: [ApplePlaybackRequest] = []
    private var fallbackAttempted = 0
    private var fallbackTotal = 0
    private var fallbackTitle: String? = nil
    /// Candidates this press already reopened once after an engine open
    /// failure (`AppleEngineOpenRetryPolicy`).
    private var openRetriedURLs: Set<URL> = []
    /// Reopens this press made for a source that sent nothing in time
    /// (`ApplePlaybackStartPolicy.sourceFirstByteDeadline`).
    private var silentSourceReopens = 0
    private var silentSourceTask: Task<Void, Never>?
    @ObservationIgnored var sourceFirstByteDeadline = ApplePlaybackStartPolicy.sourceFirstByteDeadline
    @ObservationIgnored var iptvAccounts = AppleIPTVAccountLimits.shared
    private var connectionLimitRetried = false
    private var iptvConnectionWaited = false
    /// Whether a failed open is retried on the same candidate. On for the
    /// OpenStream engine itself; tests switch it on for a fake engine.
    @ObservationIgnored var retriesFailedEngineOpen = false
    @ObservationIgnored var engineOpenRetryDelay: Duration = AppleEngineOpenRetryPolicy.delay
    /// Live streams whose HTTP status this press already asked for after a
    /// failed open (`AppleLiveRefusalProbe`).
    private var refusalProbedURLs: Set<URL> = []
    @ObservationIgnored var liveStatusProbe: @Sendable (URL, [String: String]) async -> Int? = AppleLiveRefusalProbe.status

    // MARK: - Display sleep

    /// Holds the display awake while this coordinator has a picture on screen.
    /// The coordinator is the only thing every playback path goes through, so
    /// it is the only thing that needs to know about the lock — see
    /// `ApplePlaybackWakeLock` for why the live route needed one at all.
    private let wakeLock: ApplePlaybackWakeLock
    /// This coordinator's name in the lock. Unique per instance so two players
    /// on screen at once each hold their own claim.
    private let wakeOwner = "playback.\(UUID().uuidString)"

    public init(
        engine: any ApplePlaybackEngine,
        timeout: Duration = .seconds(20),
        retryDelay: Duration = .seconds(3),
        progressInterval: Duration = .seconds(5),
        wakeLock: ApplePlaybackWakeLock = .shared
    ) {
        self.engine = engine
        self.timeoutDuration = timeout
        self.retryDelay = retryDelay
        self.progressInterval = progressInterval
        self.wakeLock = wakeLock
        configureEngine()
    }

    private func configureEngine() {
        retriesFailedEngineOpen = engine is AetherPlaybackEngine
        engineSeekObservation = nil
        if let events = (engine as? AetherPlaybackEngine)?.viewerSeekEvents {
            observeNativeSeeks(events)
        }
    }

    func observeNativeSeeks(_ events: AnyPublisher<SeekEvent, Never>) {
        engineSeekObservation = events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in self?.observeNativeSeek(event) }
    }

    /// Swaps the engine before anything has loaded, so the presenter's hooks
    /// on this coordinator stay attached (a Vision Pro VR file moves to the
    /// AVPlayer engine before playback starts).
    func adoptEngine(_ replacement: any ApplePlaybackEngine) {
        guard phase == .idle, route == .none, engine !== replacement else { return }
        cancelObservation()
        engine.stop()
        engine = replacement
        configureEngine()
    }

    /// Convenience initializer that creates a default engine via the factory so
    /// source views can keep `ApplePlaybackCoordinator()` as a `@State` default.
    public convenience init() {
        let (engine, _) = ApplePlaybackEngineFactory.make(preferred: .openStream)
        self.init(engine: engine)
    }

    // Resolution state only. Every successful title-page path replaces this
    // coordinator with a presentation built from the current engine settings.
    static func forBrowsing() -> ApplePlaybackCoordinator {
        ApplePlaybackCoordinator(engine: NativePlaybackEngine())
    }

    isolated deinit {
        if let url = (lastRequest ?? resetRetryRequest)?.url {
            Task { await AppleSMBRangeServer.shared.revoke(playbackURL: url) }
        }
        AppleChannelHealthStore.shared.endLivePlayback(self)
        displayTraceTask?.cancel()
        externalSubtitleTask?.cancel()
        observationTask?.cancel()
        loadTask?.cancel()
        fallbackTask?.cancel()
        timeoutTask?.cancel()
        silentSourceTask?.cancel()
        initialLiveSeekTask?.cancel()
        liveRetryTask?.cancel()
        liveStallTask?.cancel()
        liveEdgeCorrectionTask?.cancel()
        seekTask?.cancel()
        seekDeadlineTask?.cancel()
        // A player that goes away without stopping first must not leave the
        // television awake for the rest of the day.
        wakeLock.release(wakeOwner)
    }

    /// Every write to `phase` goes through here, so the display assertion can
    /// never drift out of step with what is on screen.
    private var displayTraceTask: Task<Void, Never>?
    private var attemptCountedStart = false
    private var attemptCountedFailure = false

    private func setPhase(_ newPhase: ApplePlaybackPhase) {
        switch newPhase {
        case .idle, .ended, .failed:
            AppleIPTVPreviewActivity.shared.ended(self, now: clock.now)
        default:
            break
        }
        let previous = phase
        switch newPhase {
        case .playing, .failed, .idle, .ended:
            if liveReconnectAttempt != 0 { liveReconnectAttempt = 0 }
        default:
            break
        }
        phase = newPhase
        updateWakeLock()
        countTransition(from: previous, to: newPhase)
    }

    /// Feeds the trace's per-launch tallies: at most one start and one
    /// failure per attempt, so a rebuffer or a resume is not a new start.
    private func countTransition(from previous: ApplePlaybackPhase, to next: ApplePlaybackPhase) {
        let isLive = lastRequest?.isLive ?? false
        switch next {
        case .playing where !attemptCountedStart:
            attemptCountedStart = true
            recordPlaybackDisplay()
            AppleInteractionTrace.count { $0.recordStarted(isLive: isLive) }
        case .failed(let failure) where !attemptCountedFailure:
            attemptCountedFailure = true
            AppleInteractionTrace.count { $0.recordFailure(failure.kind, isLive: isLive) }
        default:
            break
        }
    }

    /// One bounded diagnostic per attempt, outside the frame/render callbacks.
    private func recordPlaybackDisplay() {
        guard AppleInteractionTrace.isEnabled else { return }
        displayTraceTask?.cancel()
        let attempt = generation
        displayTraceTask = Task { @MainActor [weak self] in
            // Let the playing publisher commit its willSet values and AVKit settle.
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            guard let self, !Task.isCancelled, self.generation == attempt else { return }
            var snapshot = await ApplePlaybackDisplayTrace.source(for: self.engine)
            guard !Task.isCancelled, self.generation == attempt else { return }
            snapshot.readDisplay()
            for _ in 0..<6 where snapshot.switchInProgress == true {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard !Task.isCancelled, self.generation == attempt else { return }
                snapshot.readDisplay()
            }
            AppleInteractionTrace.record(.playback, snapshot.line)
        }
    }

    /// Every write to `route` goes through here, for the same reason: the route
    /// decides whether there is a picture to keep lit at all.
    private func setRoute(_ newRoute: ApplePlaybackPresentationRoute) {
        route = newRoute
        updateWakeLock()
    }

    private func updateWakeLock() {
        if ApplePlaybackWakePolicy.shouldHoldDisplayAwake(phase: phase, route: route) {
            wakeLock.acquire(wakeOwner)
        } else {
            wakeLock.release(wakeOwner)
        }
    }

    public func beginResolving() { setPhase(.resolving) }

    func configureExternalPlayback(on player: AVPlayer) {
        let playerURL = (player.currentItem?.asset as? AVURLAsset)?.url
        let allowed = lastRequest?.allowsExternalPlayback(playerURL: playerURL) ?? false
        #if !os(visionOS)
        player.allowsExternalPlayback = allowed
        #endif
        #if os(iOS) || os(tvOS)
        player.usesExternalPlaybackWhileExternalScreenIsActive = allowed
        #endif
    }

    /// Load `request` into the engine and observe its events. Never throws —
    /// load failures and engine failures land in `phase` as `.failed`.
    public func begin(_ request: ApplePlaybackRequest) async {
        fallbackTask?.cancel()
        resetLiveReconnect()
        streamsSkippedForEngine = 0
        triedSourceURLs = []
        openRetriedURLs = []
        silentSourceReopens = 0
        refusalProbedURLs = []
        connectionLimitRetried = false
        iptvConnectionWaited = request.iptvConnectionWaited
        librarySubtitles = AppleLibrarySubtitleService()
        fallbackCandidates = []
        fallbackAttempted = 0
        fallbackTotal = 0
        fallbackTitle = nil
        await beginAttempt(request)
    }

    /// Load the first candidate and keep `fallbackCandidates` for automatic
    /// fallback when the engine reports `.unsupportedMedia` or an HTTP failure
    /// for a candidate. Exhausting the list reports a single
    /// `.unsupportedMedia` failure naming how many streams were tried.
    public func begin(
        _ request: ApplePlaybackRequest,
        fallbackCandidates: [ApplePlaybackRequest]
    ) async {
        fallbackTask?.cancel()
        resetLiveReconnect()
        triedSourceURLs = []
        openRetriedURLs = []
        silentSourceReopens = 0
        refusalProbedURLs = []
        connectionLimitRetried = false
        iptvConnectionWaited = request.iptvConnectionWaited
        librarySubtitles = AppleLibrarySubtitleService()
        hasShownFallbackNotice = false
        // The head of the list, with what decides the stock player's order.
        for (index, candidate) in ([request] + fallbackCandidates).prefix(8).enumerated() {
            appleTrace("candidate \(index + 1): file=\(candidate.hints.filename.map { String($0.suffix(40)) } ?? "-") "
                + "ext=\(AppleTVPlaybackPresentationPolicy.containerExtension(url: candidate.url, filename: candidate.hints.filename) ?? "-")")
        }
        var opens = fallbackCandidates.filter(engineOpens)
        // On the stock player a stream that names an MP4/M4V/MOV/HLS goes
        // before one whose container is unknown; order is otherwise kept.
        if engine is NativePlaybackEngine {
            let named = opens.filter { Self.namesStockContainer(url: $0.url, filename: $0.hints.filename) }
            opens = named + opens.filter { !Self.namesStockContainer(url: $0.url, filename: $0.hints.filename) }
        }
        streamsSkippedForEngine = fallbackCandidates.count - opens.count
        if opens.count < fallbackCandidates.count {
            appleTrace("fallback skips \(fallbackCandidates.count - opens.count) streams the stock player cannot open")
        }
        let ordered = [request] + opens.prefix(Self.fallbackLimit(nativeEngine: engine is NativePlaybackEngine) - 1)
        self.fallbackCandidates = Array(ordered.dropFirst())
        appleTrace("fallback list \(ordered.count) of \(fallbackCandidates.count + 1) "
            + "native=\(engine is NativePlaybackEngine)")
        self.fallbackAttempted = 1
        self.fallbackTotal = ordered.count
        self.fallbackTitle = request.title
        await beginAttempt(ordered[0])
    }

    /// How many streams one press tries. The stock (Native) player cannot open
    /// an MKV or TS and only finds out once the file loads ("no video track"),
    /// so three tries could all be spent on those before the explicit MP4 —
    /// SNL S51E7 closed after three while its MP4 was fifth (Apple TV check
    /// 2026-10-01). It gets six; the OpenStream engine plays nearly anything
    /// and keeps three.
    nonisolated static func fallbackLimit(nativeEngine: Bool) -> Int { nativeEngine ? 6 : 3 }

    /// Whether this coordinator's engine can open `request` at all. The
    /// engine is chosen once per player from the FIRST stream (on the Apple
    /// TV an MP4 picks the stock player even with OpenStream selected), and
    /// every fallback then runs on it: Mad Max's MKV fallbacks all failed "no
    /// video track" in the stock player, one after another, and Search's
    /// automatic sources looped through 100 of them (Apple TV re-check
    /// 2026-10-01). The stock player skips a stream whose name says Matroska,
    /// TS, AVI or WebM; an unnamed container is still tried.
    private func engineOpens(_ request: ApplePlaybackRequest) -> Bool {
        guard engine is NativePlaybackEngine else { return true }
        return Self.stockPlayerOpens(url: request.url, filename: request.hints.filename)
    }

    nonisolated static func namesStockContainer(url: URL, filename: String?) -> Bool {
        AppleTVPlaybackPresentationPolicy.containerExtension(url: url, filename: filename)
            .map(AppleTVPlaybackPresentationPolicy.nativeContainers.contains) ?? false
    }

    nonisolated static func stockPlayerOpens(url: URL, filename: String?) -> Bool {
        guard let ext = AppleTVPlaybackPresentationPolicy.containerExtension(url: url, filename: filename),
              ["mkv", "webm", "ts", "m2ts", "mts", "avi", "wmv", "flv", "mpg", "mpeg"].contains(ext) else { return true }
        return false
    }

    private func beginAttempt(_ request: ApplePlaybackRequest) async {
        let needsConnectionWait = request.iptvSourceID != nil && !iptvConnectionWaited
        if needsConnectionWait { iptvConnectionWaited = true }
        if let previous = resetRetryRequest, previous.url != request.url {
            Task { await AppleSMBRangeServer.shared.revoke(playbackURL: previous.url) }
        }
        resetRetryRequest = nil
        progressCoordinator?.stopObserving()
        progressCoordinator = nil
        progressEnded = false
        if let token = avPlayerProgressObserver, let player = avPlayerProgressObserverPlayer {
            player.removeTimeObserver(token)
            avPlayerProgressObserver = nil
            avPlayerProgressObserverPlayer = nil
        }
        liveEdgeCorrectionTask?.cancel()
        liveEdgeCorrectionTask = nil
        displayTraceTask?.cancel()
        displayTraceTask = nil
        closeRebufferLedger()
        generation &+= 1
        resetSeeks()
        let attempt = generation
        loadTask?.cancel()
        loadTask = nil
        defer { if generation == attempt { loadTask = nil } }
        if let channelID = request.restrictionChannelID {
            let restrictions = AppleRestrictionStore.shared
            guard await restrictions.authorize(channelID: channelID, group: request.restrictionGroup ?? "",
                title: request.title ?? "Channel"), !Task.isCancelled, generation == attempt,
                  !restrictions.needsUnlock(channelID: channelID, group: request.restrictionGroup ?? "") else { return }
            if restrictions.hasPIN && restrictions.policy.isLocked(channelID: channelID, group: request.restrictionGroup ?? "") {
                restrictions.protect(self)
            }
        }
        if request.isLive, initialLiveStart == nil || lastRequest?.mediaID != request.mediaID {
            initialLiveStart = clock.now
        }
        lastRequest = request
        if request.isLive { AppleChannelHealthStore.shared.beginLivePlayback(self) }
        else { AppleChannelHealthStore.shared.endLivePlayback(self) }
        if subtitleTimingMediaID != request.mediaID {
            subtitleTimingMediaID = request.mediaID
            if !subtitleTiming.isIdentity { subtitleTiming = AppleSubtitleTiming() }
        }
        if !triedSourceURLs.contains(request.url) { triedSourceURLs.append(request.url) }
        attemptCountedStart = false
        attemptCountedFailure = false
        AppleInteractionTrace.count { $0.recordAttempt(isLive: request.isLive) }
        liveRetryAttempted = false
        liveStartExtended = false
        liveSourceOpened = false
        discStartBegan = request.hints.disc != nil && !request.isLive ? clock.now : nil
        discStartMark = .init()
        mediaServerStartCheckpoint = 0
        lastProgressWrite = nil
        remoteProgressStarted = false
        lastKnownPosition = 0
        cancelObservation()
        cancelTimeout()
        cancelLiveRetry()
        engine.stop()
        AppleIPTVPreviewActivity.shared.ended(self, now: clock.now)
        if let sourceID = request.iptvSourceID {
            AppleIPTVPreviewActivity.shared.began(self, sourceID: sourceID)
        }
        setPhase(.loading)
        setRoute(engine.route)
        do {
            if needsConnectionWait {
                try await iptvAccounts.waitForAvailableConnection(sourceID: request.iptvSourceID, clock: clock)
            }
        } catch {
            guard generation == attempt, !Task.isCancelled else { return }
            fail(error)
            return
        }
        guard generation == attempt, !Task.isCancelled else { return }
        let discKey = discCrashGuard.key(for: request)
        if let discKey, discCrashGuard.refuses(discKey) {
            fail(ApplePlaybackFailure(kind: .unavailable, message: AppleDiscCrashGuard.refusalMessage))
            return
        }
        let joinProfile = request.hints.nativeRemoteHLS ? "standard" : "fastZap"
        appleTrace("play \"\(request.title ?? "untitled")\" attempt \(fallbackAttempted)/\(fallbackTotal) \(request.sourceKind.rawValue)\(request.isLive ? " live" : "") host=\(request.url.host() ?? "?") file=\(request.hints.filename ?? "-") route=\(route)\(request.isLive ? " join=\(joinProfile)" : " resume=\(request.resumePosition.flatMap { Int(exactly: $0.rounded(.down)) } ?? 0)")")
        resumedFrom = request.resumePosition
        setupProgress(for: request)
        startTimeout()
        watchForSilentSource(request, attempt: attempt)
        let engine = self.engine
        let crashGuard = discCrashGuard
        let task = Task { @MainActor in
            if let discKey { crashGuard.opening(discKey) }
            defer { if let discKey { crashGuard.opened(discKey) } }
            try await engine.load(request)
        }
        loadTask = task
        startInitialLiveSeek(request, attempt: attempt)
        startExternalSubtitles(for: request, attempt: attempt, load: task)
        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch is CancellationError {
            // The view switched channels (or went away) while this load was in
            // flight. That is not a playback failure and must never surface as
            // an alert: the newer request owns the coordinator now.
            return
        } catch {
            guard attempt == generation, !Task.isCancelled else { return }
            await handleFailure(ApplePlaybackFailure.classify(error))
            return
        }
        guard attempt == generation, !Task.isCancelled, !task.isCancelled else { return }
        liveSourceOpened = hasOpenedLiveSource || engine.route == .surface || engine.route == .audioOnly
        if case .failed = phase { return } // timeout fired during load
        if let failure = engine.failure {
            await handleFailure(failure)
            return
        }
        syncFromEngine(request: request)
        startObserving(request: request)
        loadTask = nil
        if let target = pendingSeekTarget { await userSeek(to: target) }
    }

    /// Re-load the last request. Does not reset `liveRetryAttempted` so the
    /// live-retry policy (retry once) is preserved across auto-retry.
    public func retry() async {
        guard let request = lastRequest ?? resetRetryRequest else { return }
        initialLiveStart = nil
        liveEpisodeAttempts = 0
        liveEpisodeStart = nil
        let retriedLive = liveRetryAttempted
        silentSourceReopens = 0
        await beginAttempt(request)
        liveRetryAttempted = retriedLive
    }

    public let sleepTimer = ApplePlaybackSleepTimer()
    public var sleepProgrammeEnd: Date?

    public func armSleepTimer(minutes: Int) {
        sleepTimer.arm(minutes: minutes) { [weak self] in self?.engine.pause() }
    }

    public func armSleepTimer(deadline: Date) {
        sleepTimer.arm(deadline: deadline) { [weak self] in self?.engine.pause() }
    }

    public func stop() {
        stop(keepingRetryRequest: false)
    }

    private func stop(keepingRetryRequest: Bool) {
        let stoppedRequest = lastRequest ?? resetRetryRequest
        AppleChannelHealthStore.shared.endLivePlayback(self)
        sleepTimer.cancel()
        sharedPlayback?.suspendForLocalTransition()
        displayTraceTask?.cancel()
        displayTraceTask = nil
        closeRebufferLedger()
        generation &+= 1
        resetSeeks()
        externalSubtitleTask?.cancel()
        externalSubtitleTask = nil
        loadTask?.cancel()
        loadTask = nil
        fallbackTask?.cancel()
        fallbackTask = nil
        if let req = lastRequest, req.sourceKind == .mediaServer, remoteProgressStarted {
            remoteProgressSink?(req.mediaID, lastKnownPosition, engine.duration ?? 0, .stopped)
            remoteProgressStarted = false
        }
        // A share file plays through the bridge; ending its session writes the
        // bridge's read summary to the trace and lets go of the share.
        if !keepingRetryRequest, let url = stoppedRequest?.url {
            Task { await AppleSMBRangeServer.shared.revoke(playbackURL: url) }
        }
        lastRequest = nil
        resetRetryRequest = keepingRetryRequest ? stoppedRequest : nil
        librarySubtitles = AppleLibrarySubtitleService()
        clearFallback()
        resetLiveReconnect()
        stopMonitoring()
        cancelObservation()
        cancelTimeout()
        cancelLiveRetry()
        if let token = avPlayerProgressObserver, let oldPlayer = avPlayerProgressObserverPlayer {
            oldPlayer.removeTimeObserver(token)
            avPlayerProgressObserver = nil
            avPlayerProgressObserverPlayer = nil
        }
        progressCoordinator?.stopObserving()
        progressCoordinator = nil
        engine.stop()
        setPhase(.idle)
        setRoute(.none)
    }

    public func update(_ phase: ApplePlaybackPhase) { setPhase(phase) }

    public func reset() {
        // Retry still needs the share bridge URL after the alert stops playback.
        stop(keepingRetryRequest: true)
    }

    @discardableResult
    public func fail(_ error: any Error) -> ApplePlaybackFailure {
        generation &+= 1
        loadTask?.cancel()
        loadTask = nil
        resetSeeks()
        stopMonitoring()
        cancelTimeout()
        let failure = ApplePlaybackFailure.classify(error)
        // Before the player: no stream was found or none could be prepared.
        appleTraceFailure("playback \(failure.kind) before the player: \(failure.message)")
        cancelObservation()
        setPhase(.failed(failure))
        return failure
    }

    // MARK: - External subtitles

    /// Discover sidecar files alongside playback, but attach only after load
    /// has reset the engine's tracks.
    private func startExternalSubtitles(
        for request: ApplePlaybackRequest, attempt: Int, load: Task<Void, any Error>
    ) {
        externalSubtitleTask?.cancel()
        externalSubtitleTask = nil
        guard !request.isLive else { return }
        let engine = self.engine
        let offered = request.hints.externalSubtitles
        if !offered.isEmpty {
            externalSubtitleTask = Task { @MainActor [weak self] in
                do { try await load.value } catch { return }
                guard let self, !Task.isCancelled, self.generation == attempt else { return }
                engine.addExternalSubtitleTracks(offered)
            }
            return
        }
        guard let video = request.hints.libraryFileURL ?? (request.url.isFileURL ? request.url : nil) else { return }
        let library = librarySubtitles
        externalSubtitleTask = Task { @MainActor [weak self] in
            let siblings = await library.tracks(for: video)
            do { try await load.value } catch { return }
            guard let self, !Task.isCancelled, self.generation == attempt else { return }
            engine.addExternalSubtitleTracks(siblings)
        }
    }

    // MARK: - Candidate fallback

    /// On an `.unsupportedMedia` or HTTP/network failure, advance to the next
    /// ranked candidate. When the list is exhausted, report a single
    /// `.unsupportedMedia` failure naming how many streams were tried.
    private func handleFailure(_ failure: ApplePlaybackFailure) async {
        if let request = lastRequest, let unavailable = AppleIPTVCatchUp.unavailableFailure(for: failure, request: request) {
            engine.stop()
            fail(unavailable)
            return
        }
        var failure = failure
        if let request = lastRequest, request.iptvSourceID != nil, failure.isConnectionLimit {
            if connectionLimitRetried {
                engine.stop()
                fail(failure)
                return
            }
            connectionLimitRetried = true
            iptvConnectionWaited = false
            cancelTimeout()
            cancelObservation()
            engine.stop()
            appleTrace("live connection limit: retry once after the previous stream closes")
            await beginAttempt(request)
            return
        }
        // The share's own answer, not the demuxer's "invalid data" for a body it never got.
        if let request = lastRequest, request.sourceKind == .networkShare,
           await AppleSMBRangeServer.shared.bytesServed(playbackURL: request.url) == 0,
           let share = await AppleSMBRangeServer.shared.openFailure(playbackURL: request.url) {
            failure = ApplePlaybackFailure(kind: .unavailable, message: share.localizedDescription)
        }
        // The demuxer and AVPlayer lose the origin's status; a channel the
        // provider refuses (HTTP 401/403) is that channel, not off the air.
        if let request = lastRequest, request.isLive, !liveHasPlayed, failure.httpStatus == nil,
           [.network, .player, .unavailable].contains(failure.kind),
           refusalProbedURLs.insert(request.url).inserted {
            let attempt = generation
            let status = await liveStatusProbe(request.url, request.hints.proxyHeaders)
            guard !Task.isCancelled, generation == attempt else { return }
            appleTrace("live refusal probe: HTTP \(status.map(String.init) ?? "none") host=\(request.url.host() ?? "?")")
            if let refusal = AppleLiveRefusalProbe.refusal(status: status) { failure = refusal }
        }
        if lastRequest?.isLive == true, !liveHasPlayed,
           [.network, .timedOut, .player].contains(failure.kind),
           failure.kind == .timedOut || initialLiveStart.map({ $0.duration(to: clock.now) >= liveTimeoutDuration }) == true {
            // An engine's late open error must not restart the wait the channel has already spent.
            appleTrace("live startup deadline exhausted after \(failure.kind)")
            finishInitialLiveStart(with: failure)
            return
        }
        // A file cut short opens like an unplayable format or an unreadable
        // file; it is an incomplete download, which Retry (or another source)
        // can fix. Only the container's own sizes say so, never the error
        // text alone (V13).
        if failure.kind == .unsupportedMedia || failure.message == AppleTruncatedMediaProbe.openFailedMessage,
           let request = lastRequest, !request.isLive {
            let attempt = generation
            let endsEarly = await AppleTruncatedMediaProbe.endsEarly(request.url)
            guard !Task.isCancelled, generation == attempt else { return }
            if endsEarly {
                appleTrace("playback: the file ends before its container says it should — incomplete download")
                failure = ApplePlaybackFailure(kind: .network, message: AppleTruncatedMediaProbe.message)
            }
        }
        // A live channel that was playing is reopened a few times before
        // anything is shown (`AppleLiveReconnectPolicy`).
        if let request = lastRequest, request.isLive, await reconnectLive(request, after: failure) {
            return
        }
        // An engine open that failed before the first frame gets one more go
        // on the same candidate before the next one is tried.
        if let request = lastRequest, AppleEngineOpenRetryPolicy.shouldRetry(
            failure: failure, isLive: request.isLive, reachedFirstFrame: attemptCountedStart,
            alreadyRetried: openRetriedURLs.contains(request.url),
            engineIsOpenStream: retriesFailedEngineOpen) {
            openRetriedURLs.insert(request.url)
            appleTrace("engine open retry \(failure.kind) host=\(request.url.host() ?? "?") in \(engineOpenRetryDelay)")
            cancelTimeout()
            cancelObservation()
            let attempt = generation
            try? await Task.sleep(for: engineOpenRetryDelay)
            guard !Task.isCancelled, generation == attempt else { return }
            await beginAttempt(request)
            return
        }
        appleTraceFailure("playback \(failure.kind): \(failure.message) — \(shouldFallBack(for: failure) ? "falling back" : "final")")
        if shouldFallBack(for: failure), let lastRequest {
            ApplePlaybackFailureHistory.shared.record(lastRequest.url)
            onSourceFailure?(lastRequest)
        }
        if shouldFallBack(for: failure), let next = nextFallbackCandidate(where: { _ in true }) {
            cancelTimeout()
            cancelObservation()
            showFallbackNotice()
            await beginAttempt(next)
        } else if shouldFallBack(for: failure), let nextAutomaticSource {
            cancelTimeout()
            cancelObservation()
            let attempt = generation
            do {
                // Sources this engine cannot open are passed over, a bounded
                // number of them (`engineOpens`).
                var next = try await nextAutomaticSource()
                var skipped = 0
                while let candidate = next, !engineOpens(candidate), skipped < 40 {
                    skipped += 1
                    next = try await nextAutomaticSource()
                }
                streamsSkippedForEngine += skipped
                if skipped > 0 { appleTrace("automatic source skipped \(skipped) the stock player cannot open") }
                if let candidate = next, !engineOpens(candidate) { next = nil; streamsSkippedForEngine += 1 }
                guard !Task.isCancelled, generation == attempt else { return }
                if let next {
                    showFallbackNotice()
                    await beginAttempt(next)
                } else if let next = nextFallbackCandidate(where: { !ApplePlaybackFailureHistory.shared.contains($0.url) }) {
                    // Only streams from a service that is down are left.
                    showFallbackNotice()
                    await beginAttempt(next)
                } else {
                    fail(failure)
                }
            } catch is CancellationError {
                return
            } catch {
                fail(error)
            }
        } else if shouldFallBack(for: failure), let next = nextFallbackCandidate(where: { _ in true }) {
            // Only streams from a service that is down are left; still try them.
            cancelTimeout()
            cancelObservation()
            showFallbackNotice()
            await beginAttempt(next)
        } else if fallbackTotal > 1, shouldFallBack(for: failure) {
            cancelTimeout()
            let total = fallbackTotal
            fallbackCandidates = []
            fallbackAttempted = 0
            fallbackTotal = 0
            let message = failure.kind == .unsupportedMedia
                ? "None of the \(total) streams for this title plays on this device."
                : "Tried \(total) streams. \(failure.message)"
            fail(ApplePlaybackFailure(kind: failure.kind, message: message))
        } else {
            fail(failure)
        }
    }

    private func showFallbackNotice() {
        guard !hasShownFallbackNotice else { return }
        hasShownFallbackNotice = true
        fallbackNoticeGeneration &+= 1
    }

    private func shouldFallBack(for failure: ApplePlaybackFailure) -> Bool {
        switch failure.kind {
        case .unsupportedMedia, .network, .timedOut, .authentication, .player:
            true
        default:
            false
        }
    }

    /// Returns the first remaining candidate that passes `include` and
    /// advances the attempt count, or nil if none does. Candidates it passes
    /// over stay in the list for a later call.
    private func nextFallbackCandidate(where include: (ApplePlaybackRequest) -> Bool) -> ApplePlaybackRequest? {
        guard let index = fallbackCandidates.firstIndex(where: include) else { return nil }
        let next = fallbackCandidates.remove(at: index)
        fallbackAttempted += 1
        return next
    }

    private func clearFallback() {
        fallbackCandidates = []
        fallbackAttempted = 0
        fallbackTotal = 0
        fallbackTitle = nil
    }

    private func scheduleFailure(_ failure: ApplePlaybackFailure) {
        // Run fallback outside the observer being replaced. Cancelling an old
        // observation must not also cancel the next candidate's load.
        let attempt = generation
        fallbackTask?.cancel()
        fallbackTask = Task { @MainActor [weak self] in
            guard let self, self.generation == attempt else { return }
            await self.handleFailure(failure)
        }
    }

    // MARK: - Engine observation

    private func startObserving(request: ApplePlaybackRequest) {
        observationTask?.cancel()
        let engine = self.engine
        let attempt = generation
        let events = engine.events
        observationTask = Task { @MainActor [weak self] in
            for await event in events {
                guard !Task.isCancelled, let self, self.generation == attempt else { break }
                self.handle(event, request: request)
            }
        }
    }

    private func handle(_ event: ApplePlaybackEngineEvent, request: ApplePlaybackRequest) {
        switch event {
        case .phase(let enginePhase):
            applyEnginePhase(enginePhase, request: request)
        case .route(let newRoute):
            appleTrace("route \(route) → \(newRoute)")
            setRoute(newRoute)
            setupProgress(for: request)
        case .position(let position):
            handlePosition(position)
        case .tracks:
            applyTrackCarryOver()
        case .duration:
            // The length is known: from here a failure is the stream's, not a
            // reason to try another source.
            if phase == .playing { clearFallback() }
        case .failure(let failure):
            if let failure {
                scheduleFailure(failure)
            }
        }
    }

    /// Applies whatever part of `trackCarryOver` this stream's tracks can
    /// satisfy. Sidecar subtitles arrive in a later `.tracks` pass, so a
    /// language not found yet stays pending.
    private func applyTrackCarryOver() {
        guard var carry = trackCarryOver else { return }
        carry.autoPlayChain = nil
        let audio = engine.audioTracks
        if carry.audioLanguage != nil, !audio.isEmpty {
            if let id = carry.audioTrackID(in: audio), id != engine.activeAudioTrackID {
                appleTrace("carry-over audio → \(id)")
                pendingAudioPick = id
                engine.selectAudioTrack(id: id)
            }
            carry.audioLanguage = nil
        }
        if let selection = carry.subtitleSelection(in: engine.subtitleTracks) {
            if selection != engine.activeSubtitleTrackID {
                appleTrace("carry-over subtitle → \(selection.map(String.init) ?? "off")")
                engine.selectSubtitleTrack(id: selection)
            }
            carry.subtitle = .unchanged
        }
        trackCarryOver = carry.isEmpty ? nil : carry
    }

    private func applyEnginePhase(_ enginePhase: ApplePlaybackEnginePhase, request: ApplePlaybackRequest) {
        if observesNativeScrub {
            switch enginePhase {
            case .playing: seekPlaybackIntent = true
            case .paused: seekPlaybackIntent = false
            default: break
            }
        }
        switch enginePhase {
        case .rebuffering, .stalled: break
        default: endRebuffer()
        }
        switch enginePhase {
        case .idle:
            break
        case .loading:
            setPhase(.loading)
        case .playing:
            resumeProgressIfNeeded(position: engine.position)
            if case .playing = phase {} else { appleTrace("transport playing, route=\(route)") }
            if request.isLive {
                cancelInitialLiveSeek()
                noteLivePlaying()
            }
            let isResume = (phase == .paused)
            // A version that really plays is the title's resume copy from now on.
            if !isResume { ApplePlaybackStore().notePlaybackStarted(request) }
            setPhase(.playing)
            cancelTimeout()
            clearFallback()
            if isResume, request.sourceKind == .mediaServer, remoteProgressStarted {
                remoteProgressSink?(request.mediaID, lastKnownPosition, engine.duration ?? 0, .progress)
            }
        case .paused:
            cancelLiveStall()
            if request.isLive, liveHasPlayed { liveEdgeFollow.suspend() }
            setPhase(.paused)
            if request.sourceKind == .mediaServer, remoteProgressStarted {
                remoteProgressSink?(request.mediaID, lastKnownPosition, engine.duration ?? 0, .paused)
            }
        case .seeking:
            break
        case .rebuffering:
            if request.isLive {
                _ = liveEdgeFollow.target(position: engine.position, range: engine.seekableRange,
                    isPlaying: false, holdBack: engine.liveEdgeOffset, now: clock.now)
            }
            if rebuffers.begin(at: .now) {
                appleTrace("rebuffering")
                if phase == .playing, !request.isLive {
                    showRebufferAfterShortLimit(request: request)
                    return
                }
            }
            guard rebufferShowTask == nil else { return }
            rebuffers.show()
            setPhase(.waiting("Buffering…"))
            if request.isLive { watchLiveStall(kind: "rebuffering") }
        case .stalled(let reconnecting):
            appleTrace("stalled reconnecting=\(reconnecting)")
            rebufferShowTask?.cancel()
            rebufferShowTask = nil
            _ = rebuffers.begin(at: .now)
            rebuffers.show()
            setPhase(.waiting(Self.reconnectingText))
            if request.isLive { watchLiveStall(kind: "stalled") }
        case .ended:
            handleEnded(request: request)
        case .error(let message):
            cancelTimeout()
            scheduleFailure(engine.failure ?? ApplePlaybackFailure(
                kind: .player,
                message: AppleTruncatedMediaProbe.readableEngineMessage(message, midStream: attemptCountedStart)))
        }
    }

    private func showRebufferAfterShortLimit(request: ApplePlaybackRequest) {
        let attempt = generation
        rebufferShowTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: ApplePlaybackRebufferLedger.shortLimit)
            guard !Task.isCancelled, let self, self.generation == attempt, self.rebuffers.isWaiting else { return }
            self.rebufferShowTask = nil
            self.rebuffers.show()
            self.setPhase(.waiting("Buffering…"))
            if request.isLive { self.watchLiveStall(kind: "rebuffering") }
        }
    }

    private func endRebuffer() {
        rebufferShowTask?.cancel()
        rebufferShowTask = nil
        rebuffers.end(at: .now)
    }

    /// One line per playback with its full and short rebuffers.
    private func closeRebufferLedger() {
        endRebuffer()
        if let summary = rebuffers.summary { appleTrace(summary) }
        rebuffers = ApplePlaybackRebufferLedger()
    }

    private func handleEnded(request: ApplePlaybackRequest) {
        guard request.isLive else {
            cancelTimeout()
            guard attemptCountedStart else {
                scheduleFailure(ApplePlaybackFailure(
                    kind: .sourceEnded, message: "The stream ended before playback started."))
                return
            }
            if let duration = engine.duration, duration.isFinite, duration > 0 {
                lastKnownPosition = duration
                progressCoordinator?.finish(duration: duration)
                if route == .surface {
                    lastProgressWrite = nil
                    handlePosition(duration)
                }
            }
            progressEnded = true
            setPhase(.ended)
            if request.sourceKind == .mediaServer, remoteProgressStarted {
                remoteProgressSink?(request.mediaID, lastKnownPosition, engine.duration ?? 0, .stopped)
                remoteProgressStarted = false
            }
            return
        }
        // A channel that was playing goes through the bounded reconnect.
        if liveHasPlayed {
            cancelTimeout()
            appleTrace("live stream ended mid-play")
            scheduleFailure(ApplePlaybackFailure(kind: .sourceEnded, message: "The channel stopped sending data."))
            return
        }
        if !liveRetryAttempted {
            liveRetryAttempted = true
            setPhase(.waiting("Stream ended. Reconnecting…"))
            let delay = retryDelay
            liveRetryTask?.cancel()
            liveRetryTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self else { return }
                guard case .waiting = self.phase else { return }
                self.liveRetryTask = nil
                await self.retry()
            }
        } else {
            cancelTimeout()
            setPhase(.failed(ApplePlaybackFailure(
                kind: .sourceEnded,
                message: "The channel stopped sending data."
            )))
        }
    }

    // MARK: - Timeout

    private func startInitialLiveSeek(_ request: ApplePlaybackRequest, attempt: Int) {
        guard request.isLive, request.autoplay else { return }
        let deadline = ContinuousClock.now.advanced(by: liveTimeoutDuration + ApplePlaybackStartPolicy.liveOpenedExtension)
        initialLiveSeekTask = Task { @MainActor [weak self] in
            defer { if self?.generation == attempt { self?.initialLiveSeekTask = nil } }
            while !Task.isCancelled, ContinuousClock.now < deadline {
                guard self?.generation == attempt else { return }
                if let engine = self?.engine, engine.phase != .idle {
                    // Autoplay may reach its first picture before the live window is published.
                    guard engine.phase != .playing else { return }
                    let player = engine.route == .avPlayer ? engine.avPlayer : nil
                    let range = player == nil ? engine.seekableRange : engine.avPlayerSeekableRange(player)
                    if player?.currentItem?.status == .readyToPlay { self?.liveSourceOpened = true }
                    if let player, player.currentItem?.status != .readyToPlay || self?.loadTask != nil {
                        try? await Task.sleep(for: .milliseconds(100))
                        continue
                    }
                    guard let target = ApplePlaybackStartPolicy.initialLiveSeekTarget(in: range) else {
                        try? await Task.sleep(for: .milliseconds(100))
                        continue
                    }
                    if let player {
                        // Startup precedes the engine clock's first sample; seek on the item's own axis.
                        let time = CMTime(seconds: target, preferredTimescale: 600)
                        guard await player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) else {
                            try? await Task.sleep(for: .milliseconds(100))
                            continue
                        }
                    } else {
                        await engine.seek(to: target)
                    }
                    guard !Task.isCancelled, self?.generation == attempt else { return }
                    engine.play()
                    let position = player?.currentTime().seconds ?? engine.position
                    appleTrace("live initial edge joined engine=\(engine.kind.rawValue) route=\(engine.route) edge=\(range?.end ?? target) target=\(target) position=\(position)")
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func finishInitialLiveStart(with failure: ApplePlaybackFailure) {
        let failure = ApplePlaybackStartPolicy.liveFailureAtDeadline(failure, sourceOpened: hasOpenedLiveSource)
        generation &+= 1
        loadTask?.cancel()
        loadTask = nil
        engine.stop()
        fail(failure)
    }

    private var hasOpenedLiveSource: Bool {
        liveSourceOpened || engine.avPlayer?.currentItem?.status == .readyToPlay
    }

    /// A live channel that has not produced a frame by now is not coming: the
    /// provider is refusing it or the stream is dead. Dead channels are normal
    /// in a large lineup, and holding them to the on-demand timeout left the
    /// screen black for twenty seconds before saying anything, which is most of
    /// what "live freezes when flipping channels" was (owner 2026-09-14).
    private var liveTimeoutDuration: Duration { .seconds(10) }

    private func startTimeout(after duration: Duration? = nil) {
        timeoutTask?.cancel()
        let isLive = lastRequest?.isLive ?? false
        var wait = isLive ? liveTimeoutDuration : timeoutDuration
        if isLive, !liveHasPlayed, let initialLiveStart {
            wait = max(.zero, wait - initialLiveStart.duration(to: clock.now))
        }
        let duration = duration ?? wait
        let attempt = generation
        if isLive { appleTrace("live deadline armed generation=\(attempt) wait=\(duration)") }
        timeoutTask = Task { @MainActor [weak self, clock] in
            try? await clock.sleep(for: duration)
            guard !Task.isCancelled, let self, self.generation == attempt else { return }
            if isLive { appleTrace("live deadline fired generation=\(attempt) phase=\(self.phase)") }
            let discExtension = await self.discStartExtension()
            guard !Task.isCancelled, self.generation == attempt else { return }
            if let discExtension {
                self.startTimeout(after: discExtension)
                return
            }
            switch self.phase {
            case .idle, .resolving, .loading, .waiting:
                if !isLive, self.lastRequest?.sourceKind == .mediaServer,
                   self.lastRequest?.hints.disc == nil,
                   self.engine.startupCheckpoint > self.mediaServerStartCheckpoint {
                    self.mediaServerStartCheckpoint = self.engine.startupCheckpoint
                    appleTrace("media server startup advancing checkpoint=\(self.mediaServerStartCheckpoint); waiting \(self.timeoutDuration) more")
                    self.startTimeout(after: self.timeoutDuration)
                    return
                }
                // AVPlayer can be ready while load still finishes metadata.
                // That open stream gets one bounded extension for its first frame.
                if let more = ApplePlaybackStartPolicy.liveStartExtension(
                    isLive: isLive, sourceOpened: self.hasOpenedLiveSource, alreadyExtended: self.liveStartExtended
                ) {
                    self.liveStartExtended = true
                    appleTrace("live start slow: the channel is open but has no picture after \(duration); waiting \(more) more")
                    self.startTimeout(after: more)
                    return
                }
                #if DEBUG
                AppleInteractionTrace.record(.failure, "timed out after \(duration) live=\(isLive) phase=\(self.phase)")
                #endif
                let failure = ApplePlaybackFailure(
                    kind: .timedOut, message: "The player did not become ready in time.")
                if isLive, !self.liveHasPlayed {
                    self.finishInitialLiveStart(with: failure)
                } else {
                    self.loadTask?.cancel()
                    self.loadTask = nil
                    self.cancelObservation()
                    self.engine.stop()
                    self.scheduleFailure(failure)
                }
            case .playing, .paused, .ended, .failed:
                break
            }
        }
    }

    /// More time for a disc image that is still starting and has moved since
    /// the last deadline, or nil.
    private func discStartExtension() async -> Duration? {
        guard let began = discStartBegan, let request = lastRequest else { return nil }
        switch phase {
        case .idle, .resolving, .loading, .waiting: break
        case .playing, .paused, .ended, .failed: return nil
        }
        let checkpoint = engine.startupCheckpoint
        let bytesRead = await AppleSMBRangeServer.shared.bytesServed(playbackURL: request.url)
        let current = ApplePlaybackStartPolicy.DiscStartProgress(checkpoint: checkpoint, bytesRead: bytesRead)
        let elapsed = began.duration(to: clock.now)
        guard let more = ApplePlaybackStartPolicy.discStartExtension(
            elapsed: elapsed, previous: discStartMark, current: current,
            window: discStartWindow, cap: discStartCap) else {
            appleTrace("disc start: no progress since the last deadline or the cap reached after \(elapsed) (checkpoint \(checkpoint), \(bytesRead) bytes)")
            return nil
        }
        discStartMark = current
        appleTrace("disc start still reading after \(elapsed) (checkpoint \(checkpoint), \(bytesRead) bytes); waiting \(more) more")
        return more
    }

    // MARK: - Progress persistence

    private func resumeProgressIfNeeded(position: Double) {
        guard progressEnded, lastRequest?.isLive == false,
              position.isFinite, position >= 0, let duration = engine.duration,
              duration.isFinite, position < duration else { return }
        progressEnded = false
        lastKnownPosition = position
        lastProgressWrite = nil
        progressCoordinator?.beginPlaySession()
        if let request = lastRequest { setupProgress(for: request) }
    }

    private func setupProgress(for request: ApplePlaybackRequest) {
        surfaceProgressIdentity = request.isLive ? nil : request.mediaID
        surfaceProgressPartID = request.hints.progressPartID ?? AppleDetailResume.partID(type: request.hints.titleMediaType,
            mediaID: request.hints.titleMediaID)
        switch route {
        case .avPlayer:
            if !request.isLive, let player = engine.avPlayer {
                let identity = ApplePlaybackIdentity.storageKey(for: request.mediaID) ?? request.mediaID
                let coordinator = progressCoordinator ?? ApplePlaybackProgressCoordinator(
                    store: ApplePlaybackStore(),
                    mediaIdentity: identity,
                    partID: surfaceProgressPartID
                )
                coordinator.resumedFrom = resumedFrom
                coordinator.writer = { [weak self] position, duration in
                    if let writer = self?.progressWriter { writer(position, duration) }
                    else { ApplePlaybackStore().save(request: request, position: position, duration: duration) }
                }
                coordinator.startObserving(player)
                progressCoordinator = coordinator

                if request.sourceKind == .mediaServer, avPlayerProgressObserverPlayer !== player {
                    if let token = avPlayerProgressObserver, let oldPlayer = avPlayerProgressObserverPlayer {
                        oldPlayer.removeTimeObserver(token)
                    }
                    let intervalSeconds = Double(progressInterval.components.seconds)
                    let interval = CMTime(seconds: intervalSeconds, preferredTimescale: 600)
                    let attempt = generation
                    avPlayerProgressObserverPlayer = player
                    avPlayerProgressObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self, weak player] time in
                        MainActor.assumeIsolated {
                            guard let self, let player, self.generation == attempt,
                                  self.avPlayerProgressObserverPlayer === player,
                                  let lastRequest = self.lastRequest, lastRequest.sourceKind == .mediaServer else { return }
                            if self.phase == .playing { self.resumeProgressIfNeeded(position: time.seconds) }
                            guard !self.progressEnded else { return }
                            self.lastKnownPosition = time.seconds
                            let duration = player.currentItem?.duration.seconds ?? 0
                            if !self.remoteProgressStarted {
                                self.remoteProgressStarted = true
                                self.remoteProgressSink?(lastRequest.mediaID, time.seconds, duration, .started)
                            }
                            self.remoteProgressSink?(lastRequest.mediaID, time.seconds, duration, .progress)
                        }
                    }
                }
            }
        default:
            progressCoordinator?.stopObserving(saveCurrentProgress: false)
            if let token = avPlayerProgressObserver, let player = avPlayerProgressObserverPlayer {
                player.removeTimeObserver(token)
                avPlayerProgressObserver = nil
                avPlayerProgressObserverPlayer = nil
            }
        }
    }

    /// The players on screen (`AppleMediaPlayerView` registers its own).
    private static let onScreen = NSHashTable<ApplePlaybackCoordinator>.weakObjects()

    func setOnScreen(_ visible: Bool) {
        if visible { Self.onScreen.add(self) } else { Self.onScreen.remove(self) }
    }

    /// Saves every on-screen player's position. The app calls this when it
    /// leaves the screen, before the Top Shelf and widgets read positions.
    static var isPlayerOnScreen: Bool { !onScreen.allObjects.isEmpty }

    static func saveProgressOnScreen() {
        for coordinator in onScreen.allObjects { coordinator.saveProgressNow() }
    }

    /// Saves the position now rather than at the next interval.
    func saveProgressNow() {
        if phase == .playing { resumeProgressIfNeeded(position: engine.position) }
        guard lastRequest?.isLive == false, !progressEnded else { return }
        guard route == .surface else {
            progressCoordinator?.saveCurrentProgress()
            return
        }
        let position = engine.position
        guard position.isFinite, position > 0 else { return }
        lastProgressWrite = nil
        handlePosition(position)
    }

    private func handlePosition(_ position: Double) {
        if phase == .playing { resumeProgressIfNeeded(position: position) }
        guard !progressEnded else { return }
        lastKnownPosition = position
        // The scrub clock can publish the target before a frame is rendered.
        seekPositionChanged(engine.presentationTime)
        if lastRequest?.isLive == true, initialLiveSeekTask == nil, liveEdgeCorrectionTask == nil,
           let target = liveEdgeFollow.target(position: position, range: engine.seekableRange,
               isPlaying: phase == .playing, holdBack: engine.liveEdgeOffset, now: clock.now) {
            let attempt = generation
            appleTrace("live drift catch-up lag=\(engine.seekableRange.map { $0.end - position } ?? 0)s")
            liveEdgeCorrectionTask = Task { @MainActor [weak self] in
                guard let self, self.generation == attempt, !Task.isCancelled else { return }
                defer { if self.generation == attempt { self.liveEdgeCorrectionTask = nil } }
                await self.userSeek(to: target)
            }
        }

        if let req = lastRequest, req.sourceKind == .mediaServer {
            if !remoteProgressStarted {
                remoteProgressStarted = true
                remoteProgressSink?(req.mediaID, position, engine.duration ?? 0, .started)
            }
        }

        guard route == .surface,
              !ApplePlaybackProgressCoordinator.keepsResumePoint(position: position, resumedFrom: resumedFrom)
        else { return }
        let now = clock.now
        guard lastProgressWrite == nil || now - lastProgressWrite! >= progressInterval else { return }
        lastProgressWrite = now
        
        if let req = lastRequest, req.sourceKind == .mediaServer {
            remoteProgressSink?(req.mediaID, position, engine.duration ?? 0, .progress)
        }

        if let progressWriter {
            progressWriter(position, engine.duration ?? 0)
            return
        }
        // No host writer (a stream on the software route): without
        // this the position was only ever saved by the tvOS Menu handler, so
        // nothing resumed on any other platform or exit path.
        guard let surfaceProgressIdentity, let duration = engine.duration, duration > 0 else { return }
        if let request = lastRequest {
            ApplePlaybackStore().save(request: request, position: position, duration: duration)
        } else {
            ApplePlaybackStore().save(mediaID: surfaceProgressIdentity, position: position,
                duration: duration, partID: surfaceProgressPartID)
        }
    }

    /// Reports failures raised by an `ApplePlayerSession` (the AVPlayer-only
    /// path kept for the native engine and the offline/local players) through
    /// the coordinator's `phase`.
    func attachFailureReporting(to session: ApplePlayerSession) {
        stopMonitoring()
        monitoredSession = session
        session.onPlaybackFailure = { [weak self] failure in
            _ = self?.fail(failure)
        }
    }

    private func stopMonitoring() {
        failureMonitor?.cancel()
        failureMonitor = nil
        monitoredSession?.onPlaybackFailure = nil
        monitoredSession = nil
    }

    // MARK: - Sync

    private func syncFromEngine(request: ApplePlaybackRequest) {
        setRoute(engine.route)
        setupProgress(for: request)
        if let failure = engine.failure {
            cancelTimeout()
            setPhase(.failed(failure))
            return
        }
        applyEnginePhase(engine.phase, request: request)
    }

    // MARK: - Cancellation

    private func cancelObservation() {
        cancelInitialLiveSeek()
        observationTask?.cancel()
        observationTask = nil
    }

    private func cancelTimeout() {
        if timeoutTask != nil, lastRequest?.isLive == true {
            appleTrace("live deadline cancelled generation=\(generation) phase=\(phase)")
        }
        timeoutTask?.cancel()
        timeoutTask = nil
        silentSourceTask?.cancel()
        silentSourceTask = nil
    }

    /// Every silent attempt gets a full answer window, including the final one.
    private func watchForSilentSource(_ request: ApplePlaybackRequest, attempt: Int) {
        silentSourceTask?.cancel()
        silentSourceTask = nil
        guard ApplePlaybackStartPolicy.reopensSilentSource(request, reopens: 0) else { return }
        let deadline = sourceFirstByteDeadline
        silentSourceTask = Task { @MainActor [weak self, clock] in
            try? await clock.sleep(for: deadline)
            guard !Task.isCancelled, let self, self.generation == attempt, self.engine.awaitsSourceBytes else { return }
            switch self.phase {
            case .idle, .resolving, .loading, .waiting: break
            case .playing, .paused, .ended, .failed: return
            }
            guard ApplePlaybackStartPolicy.reopensSilentSource(request, reopens: self.silentSourceReopens) else {
                self.silentSourceTask = nil
                self.engine.stop()
                self.fail(ApplePlaybackFailure(kind: .network, message: "The server did not respond.", networkCode: .timedOut))
                return
            }
            self.silentSourceReopens += 1
            appleTrace("source sent nothing in \(deadline) host=\(request.url.host() ?? "?"); reopening \(self.silentSourceReopens)/\(ApplePlaybackStartPolicy.sourceFirstByteReopens)")
            // beginAttempt cancels the watch it replaces; this task is that watch.
            self.silentSourceTask = nil
            await self.beginAttempt(request)
        }
    }

    private func cancelInitialLiveSeek() {
        initialLiveSeekTask?.cancel()
        initialLiveSeekTask = nil
    }

    private func cancelLiveRetry() {
        liveRetryTask?.cancel()
        liveRetryTask = nil
    }

    // MARK: - Live reconnect

    private func resetLiveReconnect() {
        liveEdgeCorrectionTask?.cancel()
        liveEdgeCorrectionTask = nil
        liveEdgeFollow = AppleLiveEdgeFollowPolicy()
        liveHasPlayed = false
        initialLiveStart = nil
        liveEpisodeAttempts = 0
        liveEpisodeStart = nil
        livePlayingSince = nil
        liveReconnectAttempt = 0
        cancelLiveStall()
    }

    private func noteLivePlaying() {
        cancelLiveStall()
        if liveEpisodeAttempts > 0, liveReconnectAttempt > 0 {
            appleTrace("live reconnect recovered on attempt \(liveEpisodeAttempts)")
        }
        liveHasPlayed = true
        // A recovery restarts the window, so the next outage gets its own
        // 15 s; the attempt count carries on until the channel has played
        // steadily (`episodeResetAfter`), so a flapping feed is still bounded.
        liveEpisodeStart = nil
        if livePlayingSince == nil { livePlayingSince = clock.now }
    }

    /// Reopens the live `request` after `failure` when the policy says so.
    /// Returns false when the failure should take its normal course.
    private func reconnectLive(_ request: ApplePlaybackRequest, after failure: ApplePlaybackFailure) async -> Bool {
        let now = clock.now
        if liveEpisodeAttempts > 0, let since = livePlayingSince,
           liveReconnectPolicy.startsNewEpisode(playingFor: now - since) {
            appleTrace("live reconnect: played \(now - since) since the last drop — new episode")
            liveEpisodeStart = nil
            liveEpisodeAttempts = 0
        }
        let elapsed = liveEpisodeStart.map { now - $0 } ?? .zero
        let decision = liveReconnectPolicy.decide(kind: failure.kind, attemptsSoFar: liveEpisodeAttempts,
                                                  elapsed: elapsed, hasPlayed: liveHasPlayed)
        switch decision {
        case .giveUp(let reason):
            if liveHasPlayed {
                appleTrace("live reconnect gave up (\(reason)) after \(liveEpisodeAttempts) of "
                    + "\(liveReconnectPolicy.maxAttempts) in \(elapsed) — \(failure.kind)")
            }
            return false
        case .reconnect(let attempt, let delay):
            if liveEpisodeStart == nil { liveEpisodeStart = now }
            liveEpisodeAttempts = attempt
            livePlayingSince = nil
            appleTrace("live reconnect \(attempt)/\(liveReconnectPolicy.maxAttempts) in \(delay) after "
                + "\(failure.kind): \(failure.message) host=\(request.url.host() ?? "?")")
            cancelTimeout()
            cancelObservation()
            cancelLiveStall()
            engine.stop()
            setPhase(.waiting(Self.reconnectingText))
            liveReconnectAttempt = attempt
            let attemptGeneration = generation
            try? await clock.sleep(for: delay)
            guard !Task.isCancelled, generation == attemptGeneration else { return true }
            // `liveReconnectAttempt` survives the loading phase, so the
            // screen keeps saying "Reconnecting…" until a frame or a give-up.
            await beginAttempt(request)
            return true
        }
    }

    /// A playing live channel that waits for data longer than the policy's
    /// stall timeout is treated as dropped, so the reconnect starts instead
    /// of a frozen frame under a spinner. The engine reconnects on its own
    /// first (`.stalled(reconnecting: true)`); when it moves on to buffering,
    /// data is flowing again, so the timer starts over — up to three
    /// timeouts in all, so a stream that keeps stuttering is still caught.
    private func watchLiveStall(kind: String) {
        guard liveHasPlayed else { return }
        if liveStallTask != nil, kind == liveStallKind { return }
        let clock = self.clock
        let now = clock.now
        let start = liveStallStart ?? now
        liveStallStart = start
        liveStallKind = kind
        let timeout = liveReconnectPolicy.stallTimeout
        let remaining = min(timeout, timeout * 3 - (now - start))
        let attempt = generation
        liveStallTask?.cancel()
        liveStallTask = Task { @MainActor [weak self] in
            if remaining > .zero { try? await clock.sleep(for: remaining) }
            guard !Task.isCancelled, let self, self.generation == attempt else { return }
            self.liveStallTask = nil
            guard case .waiting = self.phase else { return }
            appleTrace("live stalled \(clock.now - start) (\(kind)) — treating as a drop")
            self.liveStallStart = nil
            self.liveStallKind = nil
            self.engine.stop()
            self.scheduleFailure(ApplePlaybackFailure(kind: .timedOut, message: "The channel stopped sending data."))
        }
    }

    private func cancelLiveStall() {
        liveStallTask?.cancel()
        liveStallTask = nil
        liveStallStart = nil
        liveStallKind = nil
    }
}
