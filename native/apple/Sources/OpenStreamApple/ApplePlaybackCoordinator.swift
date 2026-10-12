import AVFoundation
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
        /// The load was cancelled because a newer request replaced it (a
        /// channel switch). Never shown to the viewer.
        case cancelled
    }

    public let kind: Kind
    public let message: String
    /// The HTTP status the origin answered with, when the failure carries one.
    /// `AppleStreamServiceFailureScope` reads it to tell a service that is down
    /// (5xx) from one missing file (404/410).
    public let httpStatus: Int?
    /// The URL loading error underneath, when there was one (no route to the
    /// host, DNS failure, timeout).
    public let networkCode: URLError.Code?

    public init(kind: Kind, message: String, httpStatus: Int? = nil, networkCode: URLError.Code? = nil) {
        self.kind = kind
        self.message = message
        self.httpStatus = httpStatus
        self.networkCode = networkCode
    }

    public var errorDescription: String? { message }

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

        if let resolution = error as? AppleStremioPlaybackResolutionError {
            switch resolution {
            case .providerFailure(let failure):
                return failure
            case .noStreams:
                return .init(
                    kind: .unavailable,
                    message: "This catalog provides details only. Add an enabled stream source in Settings to play this title."
                )
            case .unsupportedOnly, .externalDemuxRequired, .noCompatibleHTTPStream:
                return .init(
                    kind: .unsupportedMedia,
                    message: "The available source did not return an Apple-compatible stream. Try another stream source."
                )
            case .gatewayUnavailable:
                return .init(
                    kind: .network,
                    message: "This stream could not be prepared for playback."
                )
            }
        }

        // Every source for the title was ruled out; asking again rules them
        // out again, so this is not a player fault worth a retry.
        if let library = error as? AppleLibrarySourceError, library == .noMedia {
            return .init(kind: .unavailable, message: library.localizedDescription)
        }

        if let stremio = error as? AppleStremioPlaybackError {
            switch stremio {
            case .requestFailed(let status) where status == 401 || status == 403:
                return .init(kind: .authentication, message: "The stream add-on rejected this request (HTTP \(status)).",
                             httpStatus: status)
            case .requestFailed(let status):
                return .init(kind: .network, message: "The stream add-on returned HTTP \(status).", httpStatus: status)
            case .invalidPayload, .invalidMediaIdentity, .invalidSource:
                return .init(kind: .unavailable, message: stremio.localizedDescription)
            case .nonHTTPResponse, .insecureRedirect, .responseTooLarge:
                return .init(kind: .network, message: stremio.localizedDescription)
            }
        }

        if let iptv = error as? AppleIPTVError {
            switch iptv {
            case .missingCredentials, .authenticationFailed:
                return .init(
                    kind: .authentication,
                    message: iptv.localizedDescription
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
    @ObservationIgnored var trackCarryOver: AppleTrackCarryOver?
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
    public let engine: any ApplePlaybackEngine
    var sharePlayChannel: AppleSharePlayChannel?
    weak var sharedPlayback: AppleSharePlayPlaybackBinding?

    func userPlay() {
        if let sharedPlayback { sharedPlayback.play() } else { engine.play() }
    }

    func userPause() {
        if let sharedPlayback { sharedPlayback.pause() } else { engine.pause() }
    }

    func userSeek(to seconds: Double) async {
        if let sharedPlayback { sharedPlayback.seek(to: seconds) } else { await engine.seek(to: seconds) }
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
    /// The request playing (or last tried), for the next episode to prefer
    /// its service.
    var currentRequest: ApplePlaybackRequest? { lastRequest }
    private var observationTask: Task<Void, Never>?
    private var loadTask: Task<Void, any Error>?
    private var fallbackTask: Task<Void, Never>?
    private var generation = 0
    private var timeoutTask: Task<Void, Never>?
    private var liveRetryTask: Task<Void, Never>?
    private var liveRetryAttempted = false
    /// The live start deadline was already extended once for this attempt.
    private var liveStartExtended = false

    // MARK: - Live reconnect (`AppleLiveReconnectPolicy`)

    /// Injected by tests with millisecond delays.
    @ObservationIgnored var liveReconnectPolicy: AppleLiveReconnectPolicy = .standard
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
    /// The media and part the software route writes progress under when no
    /// host `progressWriter` is installed. Nil for live, which has no position.
    private var surfaceProgressIdentity: String?
    private var surfaceProgressPartID: String?

    public enum RemoteProgressEvent: Sendable {
        case started
        case progress
        case paused
        case stopped
    }

    public var remoteProgressSink: (@MainActor (_ mediaID: String, _ position: Double, _ duration: Double, _ event: RemoteProgressEvent) -> Void)?
    private var remoteProgressStarted = false
    private var lastKnownPosition: Double = 0
    private var avPlayerProgressObserver: Any?
    private weak var avPlayerProgressObserverPlayer: AVPlayer?

    /// Injected by tests (and the host) to record progress writes on `.surface`
    /// routes. Called at most once per `progressInterval` with `(position, duration)`.
    /// On `.avPlayer` routes the existing `ApplePlaybackProgressCoordinator`
    /// observes `engine.avPlayer` directly.
    public var progressWriter: (@MainActor (Double, Double) -> Void)?

    /// Fetches add-on subtitle files for the request's media identity. Injected
    /// by tests; the default asks every enabled add-on that offers subtitles.
    public var externalSubtitleFetcher: (@Sendable (AppleExternalSubtitleQuery) async -> [AppleExternalSubtitleTrack])?
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
    /// Whether a failed open is retried on the same candidate. On for the
    /// OpenStream engine itself; tests switch it on for a fake engine.
    @ObservationIgnored var retriesFailedEngineOpen: Bool
    @ObservationIgnored var engineOpenRetryDelay: Duration = AppleEngineOpenRetryPolicy.delay
    /// The attempt (`generation`) already turned away as an error clip, so it
    /// is failed once however many events report its length.
    private var placeholderRejectedAttempt: Int?
    /// Which stream services failed as a whole recently. Injected by tests.
    var serviceHealth: AppleStreamServiceHealth = .shared

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
        self.retriesFailedEngineOpen = engine is AetherPlaybackEngine
        self.timeoutDuration = timeout
        self.retryDelay = retryDelay
        self.progressInterval = progressInterval
        self.wakeLock = wakeLock
    }

    /// Convenience initializer that creates a default engine via the factory so
    /// source views can keep `ApplePlaybackCoordinator()` as a `@State` default.
    public convenience init() {
        let (engine, _) = ApplePlaybackEngineFactory.make(preferred: .openStream)
        self.init(engine: engine)
    }

    isolated deinit {
        AppleChannelHealthStore.shared.endLivePlayback(self)
        externalSubtitleTask?.cancel()
        observationTask?.cancel()
        loadTask?.cancel()
        fallbackTask?.cancel()
        timeoutTask?.cancel()
        liveRetryTask?.cancel()
        liveStallTask?.cancel()
        // A player that goes away without stopping first must not leave the
        // television awake for the rest of the day.
        wakeLock.release(wakeOwner)
    }

    /// Every write to `phase` goes through here, so the display assertion can
    /// never drift out of step with what is on screen.
    private var attemptCountedStart = false
    private var attemptCountedFailure = false

    private func setPhase(_ newPhase: ApplePlaybackPhase) {
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
            AppleInteractionTrace.count { $0.recordStarted(isLive: isLive) }
        case .failed(let failure) where !attemptCountedFailure:
            attemptCountedFailure = true
            AppleInteractionTrace.count { $0.recordFailure(failure.kind, isLive: isLive) }
        default:
            break
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
        librarySubtitles = AppleLibrarySubtitleService()
        hasShownFallbackNotice = false
        // The head of the list, with what decides the stock player's order.
        for (index, candidate) in ([request] + fallbackCandidates).prefix(8).enumerated() {
            appleTrace("candidate \(index + 1): file=\(candidate.hints.filename.map { String($0.suffix(40)) } ?? "-") "
                + "ext=\(AppleTVPlaybackPresentationPolicy.containerExtension(url: candidate.url, filename: candidate.hints.filename) ?? "-") "
                + "mp4InPath=\(AppleStremioCandidateRanking.urlNamesMPEG4(candidate.url))")
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
        generation &+= 1
        let attempt = generation
        if let channelID = request.restrictionChannelID {
            let restrictions = AppleRestrictionStore.shared
            guard await restrictions.authorize(channelID: channelID, group: request.restrictionGroup ?? "",
                title: request.title ?? "Channel"), !Task.isCancelled, generation == attempt,
                  !restrictions.needsUnlock(channelID: channelID, group: request.restrictionGroup ?? "") else { return }
            if restrictions.hasPIN && restrictions.policy.isLocked(channelID: channelID, group: request.restrictionGroup ?? "") {
                restrictions.protect(self)
            }
        }
        loadTask?.cancel()
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
        lastProgressWrite = nil
        remoteProgressStarted = false
        lastKnownPosition = 0
        cancelObservation()
        cancelTimeout()
        cancelLiveRetry()
        engine.stop()
        setPhase(.loading)
        setRoute(engine.route)
        let joinProfile = request.hints.nativeRemoteHLS ? "standard" : "fastZap"
        appleTrace("play \"\(request.title ?? "untitled")\" attempt \(fallbackAttempted)/\(fallbackTotal) \(request.sourceKind.rawValue)\(request.isLive ? " live" : "") host=\(request.url.host() ?? "?") file=\(request.hints.filename.map { String($0.suffix(48)) } ?? "-") route=\(route)\(request.isLive ? " join=\(joinProfile)" : "")")
        setupProgress(for: request)
        startTimeout()
        let engine = self.engine
        let task = Task { @MainActor in try await engine.load(request) }
        loadTask = task
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
        guard attempt == generation, !Task.isCancelled else { return }
        loadTask = nil
        if case .failed = phase { return } // timeout fired during load
        if let failure = engine.failure {
            await handleFailure(failure)
            return
        }
        syncFromEngine(request: request)
        startObserving(request: request)
    }

    /// Re-load the last request. Does not reset `liveRetryAttempted` so the
    /// live-retry policy (retry once) is preserved across auto-retry.
    public func retry() async {
        guard let request = lastRequest else { return }
        liveEpisodeAttempts = 0
        liveEpisodeStart = nil
        let retriedLive = liveRetryAttempted
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
        AppleChannelHealthStore.shared.endLivePlayback(self)
        sleepTimer.cancel()
        sharedPlayback?.suspendForLocalTransition()
        generation &+= 1
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
        lastRequest = nil
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
        stopMonitoring()
        cancelObservation()
        cancelTimeout()
        cancelLiveRetry()
        setPhase(.idle)
    }

    @discardableResult
    public func fail(_ error: any Error) -> ApplePlaybackFailure {
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

    /// Discover alongside playback, but attach only after load has reset the
    /// engine's tracks. Siblings arrive first and keep their IDs when add-ons land.
    private func startExternalSubtitles(
        for request: ApplePlaybackRequest, attempt: Int, load: Task<Void, any Error>
    ) {
        externalSubtitleTask?.cancel()
        externalSubtitleTask = nil
        guard !request.isLive else { return }
        let query = AppleExternalSubtitleQuery(request: request)
        let video = request.hints.libraryFileURL ?? (request.url.isFileURL ? request.url : nil)
        guard query != nil || video != nil else { return }
        let fetcher = externalSubtitleFetcher
        let library = librarySubtitles
        let engine = self.engine
        externalSubtitleTask = Task { @MainActor [weak self] in
            let siblings = if let video { await library.tracks(for: video) } else { [AppleExternalSubtitleTrack]() }
            do { try await load.value } catch { return }
            guard let self, !Task.isCancelled, self.generation == attempt else { return }
            engine.addExternalSubtitleTracks(siblings)
            guard let query else { return }
            let tracks: [AppleExternalSubtitleTrack]
            if let fetcher {
                tracks = await fetcher(query)
            } else {
                tracks = await AppleExternalSubtitleService.shared.tracks(
                    for: query, sources: AppleSourceStore().sources,
                    preferredLanguages: AppleSubtitleLanguages.storedPreferredLanguages())
            }
            guard !Task.isCancelled, self.generation == attempt else { return }
            engine.addExternalSubtitleTracks(tracks)
        }
    }

    // MARK: - Error clips

    /// Whether what is playing is a provider's error clip rather than the
    /// title: far shorter than the title's known runtime. The transport
    /// overlay reads this so it never offers or starts the next episode.
    public var isPlaceholderPlayback: Bool {
        guard let request = lastRequest, !request.isLive else { return false }
        return AppleStreamPlaceholderPolicy.isPlaceholder(duration: engine.duration,
                                                          expectedRuntime: request.hints.expectedRuntime)
    }

    /// The runtime is known but the stream's length is not yet.
    private func awaitsPlaceholderCheck(_ request: ApplePlaybackRequest) -> Bool {
        !request.isLive && request.hints.expectedRuntime != nil && engine.duration == nil
    }

    /// Turns an error clip away as a failed source, once per attempt: its
    /// progress is dropped unsaved and the next candidate is tried.
    private func rejectsPlaceholder(_ request: ApplePlaybackRequest) -> Bool {
        guard isPlaceholderPlayback, lastRequest == request else { return false }
        if placeholderRejectedAttempt == generation { return true }
        placeholderRejectedAttempt = generation
        appleTrace("playback: \(Int(engine.duration ?? 0)) s stream for a \(Int((request.hints.expectedRuntime ?? 0) / 60)) min title — error clip, trying the next source")
        progressCoordinator?.stopObserving(saveCurrentProgress: false)
        progressCoordinator = nil
        surfaceProgressIdentity = nil
        engine.pause()
        cancelTimeout()
        scheduleFailure(ApplePlaybackFailure(kind: .player, message: AppleStreamPlaceholderPolicy.failureMessage))
        return true
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
        if let lastRequest { noteServiceFailure(failure, request: lastRequest) }
        // A service that is down fails every one of its streams the same way,
        // so the next attempt goes to another service while one is left.
        if shouldFallBack(for: failure), let next = nextFallbackCandidate(where: isServiceHealthy) {
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

    private func isServiceHealthy(_ request: ApplePlaybackRequest) -> Bool {
        !serviceHealth.isUnhealthy(request.hints.serviceKey)
    }

    /// A failure that says the whole service is down (not one missing file,
    /// not a codec) marks that service, so its other streams wait until every
    /// other service has had a turn, here and on the next play.
    private func noteServiceFailure(_ failure: ApplePlaybackFailure, request: ApplePlaybackRequest) {
        guard let key = request.hints.serviceKey, AppleStreamServiceFailureScope.of(failure) == .service else { return }
        serviceHealth.recordFailure(key)
        let waiting = fallbackCandidates.count(where: { $0.hints.serviceKey == key })
        appleTrace("service \(AppleStreamServiceKey.traceName(key)) looks down (\(failure.kind)); "
            + "\(waiting) more of its streams wait behind other services")
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
            if rejectsPlaceholder(request) { return }
            // The length is known and is the title's: from here a failure is
            // the stream's, not a reason to try another source.
            if phase == .playing { clearFallback() }
        case .failure(let failure):
            if let failure {
                scheduleFailure(failure)
            }
        }
    }

    /// Applies whatever part of `trackCarryOver` this stream's tracks can
    /// satisfy. Subtitles from add-ons arrive in a later `.tracks` pass, so a
    /// language not found yet stays pending.
    private func applyTrackCarryOver() {
        guard var carry = trackCarryOver else { return }
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
        switch enginePhase {
        case .idle:
            break
        case .loading:
            setPhase(.loading)
        case .playing:
            // The first frame. Everything before this is the wait the owner
            // sees as a spinner, so it is the one timestamp worth having.
            if case .playing = phase {} else { appleTrace("first frame, route=\(route)") }
            if rejectsPlaceholder(request) { return }
            if request.isLive { noteLivePlaying() }
            let isResume = (phase == .paused)
            setPhase(.playing)
            cancelTimeout()
            // An error clip shows its length only once it plays; keep the
            // other sources until it does.
            if !awaitsPlaceholderCheck(request) { clearFallback() }
            if isResume, request.sourceKind == .mediaServer, remoteProgressStarted {
                remoteProgressSink?(request.mediaID, lastKnownPosition, engine.duration ?? 0, .progress)
            }
        case .paused:
            cancelLiveStall()
            setPhase(.paused)
            if request.sourceKind == .mediaServer, remoteProgressStarted {
                remoteProgressSink?(request.mediaID, lastKnownPosition, engine.duration ?? 0, .paused)
            }
        case .seeking:
            break
        case .rebuffering:
            appleTrace("rebuffering")
            setPhase(.waiting("Buffering…"))
            if request.isLive { watchLiveStall(kind: "rebuffering") }
        case .stalled(let reconnecting):
            appleTrace("stalled reconnecting=\(reconnecting)")
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

    private func handleEnded(request: ApplePlaybackRequest) {
        // An error clip that ran out is a failed source, never the end of an
        // episode: no next-episode handover from it.
        if rejectsPlaceholder(request) { return }
        guard request.isLive else {
            cancelTimeout()
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

    /// A live channel that has not produced a frame by now is not coming: the
    /// provider is refusing it or the stream is dead. Dead channels are normal
    /// in a large lineup, and holding them to the on-demand timeout left the
    /// screen black for twenty seconds before saying anything, which is most of
    /// what "live freezes when flipping channels" was (owner 2026-09-14).
    private var liveTimeoutDuration: Duration { .seconds(10) }

    private func startTimeout(after duration: Duration? = nil) {
        timeoutTask?.cancel()
        let isLive = lastRequest?.isLive ?? false
        let duration = duration ?? (isLive ? liveTimeoutDuration : timeoutDuration)
        let attempt = generation
        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self, self.generation == attempt else { return }
            switch self.phase {
            case .idle, .resolving, .loading, .waiting:
                // The engine has opened the channel (its load returned: the
                // provider is sending media and the picture is being built),
                // so this is a slow start, not a dead channel.
                if let more = ApplePlaybackStartPolicy.liveStartExtension(
                    isLive: isLive, sourceOpened: self.loadTask == nil, alreadyExtended: self.liveStartExtended
                ) {
                    self.liveStartExtended = true
                    appleTrace("live start slow: the channel is open but has no picture after \(duration); waiting \(more) more")
                    self.startTimeout(after: more)
                    return
                }
                self.loadTask?.cancel()
                self.engine.stop()
                #if DEBUG
                AppleInteractionTrace.record(.failure, "timed out after \(duration) live=\(isLive) phase=\(self.phase)")
                #endif
                self.scheduleFailure(ApplePlaybackFailure(
                    kind: .timedOut,
                    message: isLive
                        ? "This channel is not responding. It may be off the air or missing from your package."
                        : "The player did not become ready in time."
                ))
            case .playing, .paused, .ended, .failed:
                break
            }
        }
    }

    // MARK: - Progress persistence

    private func setupProgress(for request: ApplePlaybackRequest) {
        progressCoordinator?.stopObserving()
        progressCoordinator = nil
        if let token = avPlayerProgressObserver, let oldPlayer = avPlayerProgressObserverPlayer {
            oldPlayer.removeTimeObserver(token)
            avPlayerProgressObserver = nil
            avPlayerProgressObserverPlayer = nil
        }
        surfaceProgressIdentity = request.isLive ? nil : request.mediaID
        surfaceProgressPartID = request.hints.progressPartID ?? AppleDetailResume.partID(type: request.hints.addonMediaType,
            mediaID: request.hints.addonMediaID)
        switch route {
        case .avPlayer:
            if let player = engine.avPlayer {
                let identity = ApplePlaybackIdentity.storageKey(for: request.mediaID) ?? request.mediaID
                let coordinator = ApplePlaybackProgressCoordinator(
                    store: ApplePlaybackStore(),
                    mediaIdentity: identity,
                    partID: surfaceProgressPartID
                )
                coordinator.startObserving(player)
                progressCoordinator = coordinator

                if request.sourceKind == .mediaServer {
                    let intervalSeconds = Double(progressInterval.components.seconds)
                    let interval = CMTime(seconds: intervalSeconds, preferredTimescale: 600)
                    avPlayerProgressObserverPlayer = player
                    avPlayerProgressObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self, weak player] time in
                        MainActor.assumeIsolated {
                            guard let self, let player, let lastRequest = self.lastRequest, lastRequest.sourceKind == .mediaServer else { return }
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
            progressCoordinator?.stopObserving()
            progressCoordinator = nil
        }
    }

    private func handlePosition(_ position: Double) {
        lastKnownPosition = position
        // An error clip's position is not the title's: never saved as watched.
        if isPlaceholderPlayback { return }

        if let req = lastRequest, req.sourceKind == .mediaServer {
            if !remoteProgressStarted {
                remoteProgressStarted = true
                remoteProgressSink?(req.mediaID, position, engine.duration ?? 0, .started)
            }
        }

        guard route == .surface else { return }
        let now = ContinuousClock().now
        guard lastProgressWrite == nil || now - lastProgressWrite! >= progressInterval else { return }
        lastProgressWrite = now
        
        if let req = lastRequest, req.sourceKind == .mediaServer {
            remoteProgressSink?(req.mediaID, position, engine.duration ?? 0, .progress)
        }

        if let progressWriter {
            progressWriter(position, engine.duration ?? 0)
            return
        }
        // No host writer (an add-on stream on the software route): without
        // this the position was only ever saved by the tvOS Menu handler, so
        // nothing resumed on any other platform or exit path.
        guard let surfaceProgressIdentity, let duration = engine.duration, duration > 0 else { return }
        ApplePlaybackStore().save(mediaID: surfaceProgressIdentity, position: position,
            duration: duration, partID: surfaceProgressPartID)
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
        observationTask?.cancel()
        observationTask = nil
    }

    private func cancelTimeout() {
        timeoutTask?.cancel()
        timeoutTask = nil
    }

    private func cancelLiveRetry() {
        liveRetryTask?.cancel()
        liveRetryTask = nil
    }

    // MARK: - Live reconnect

    private func resetLiveReconnect() {
        liveHasPlayed = false
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
        if livePlayingSince == nil { livePlayingSince = ContinuousClock.now }
    }

    /// Reopens the live `request` after `failure` when the policy says so.
    /// Returns false when the failure should take its normal course.
    private func reconnectLive(_ request: ApplePlaybackRequest, after failure: ApplePlaybackFailure) async -> Bool {
        let now = ContinuousClock.now
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
            try? await Task.sleep(for: delay)
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
        let now = ContinuousClock.now
        let start = liveStallStart ?? now
        liveStallStart = start
        liveStallKind = kind
        let timeout = liveReconnectPolicy.stallTimeout
        let remaining = min(timeout, timeout * 3 - (now - start))
        let attempt = generation
        liveStallTask?.cancel()
        liveStallTask = Task { @MainActor [weak self] in
            if remaining > .zero { try? await Task.sleep(for: remaining) }
            guard !Task.isCancelled, let self, self.generation == attempt else { return }
            self.liveStallTask = nil
            guard case .waiting = self.phase else { return }
            appleTrace("live stalled \(ContinuousClock.now - start) (\(kind)) — treating as a drop")
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
