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

    public init(kind: Kind, message: String) {
        self.kind = kind
        self.message = message
    }

    public var errorDescription: String? { message }

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

        if let stremio = error as? AppleStremioPlaybackError {
            switch stremio {
            case .requestFailed(let status) where status == 401 || status == 403:
                return .init(kind: .authentication, message: "The stream add-on rejected this request (HTTP \(status)).")
            case .requestFailed(let status):
                return .init(kind: .network, message: "The stream add-on returned HTTP \(status).")
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
                    message: "The Live TV account needs a valid username and password."
                )
            case .requestFailed(let status) where status == 401 || status == 403:
                return .init(
                    kind: .authentication,
                    message: "The Live TV provider rejected the account or required request headers (HTTP \(status))."
                )
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
                    message: "The media server rejected the account or request headers."
                )
            case .timedOut:
                return .init(kind: .timedOut, message: "Playback timed out while waiting for the media server.")
            case .unsupportedURL, .cannotDecodeContentData, .cannotDecodeRawData:
                return .init(
                    kind: .unsupportedMedia,
                    message: "This media format cannot be played directly. Try another source."
                )
            default:
                return .init(
                    kind: .network,
                    message: "OpenStream could not reach the media server. Check the server and network, then try again."
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
    private var hasShownFallbackNotice = false
    private var lastRequest: ApplePlaybackRequest?
    private var observationTask: Task<Void, Never>?
    private var loadTask: Task<Void, any Error>?
    private var fallbackTask: Task<Void, Never>?
    private var generation = 0
    private var timeoutTask: Task<Void, Never>?
    private var liveRetryTask: Task<Void, Never>?
    private var liveRetryAttempted = false
    private let timeoutDuration: Duration
    private let retryDelay: Duration
    private let progressInterval: Duration
    private var lastProgressWrite: ContinuousClock.Instant?
    private var progressCoordinator: ApplePlaybackProgressCoordinator?
    /// The media and part the software route writes progress under when no
    /// host `progressWriter` is installed. Nil for live, which has no position.
    private var surfaceProgressIdentity: String?
    private var surfaceProgressPartID: String?

    /// Injected by tests (and the host) to record progress writes on `.surface`
    /// routes. Called at most once per `progressInterval` with `(position, duration)`.
    /// On `.avPlayer` routes the existing `ApplePlaybackProgressCoordinator`
    /// observes `engine.avPlayer` directly.
    public var progressWriter: (@MainActor (Double, Double) -> Void)?

    /// Fetches add-on subtitle files for the request's media identity. Injected
    /// by tests; the default asks every enabled add-on that offers subtitles.
    public var externalSubtitleFetcher: (@Sendable (AppleExternalSubtitleQuery) async -> [AppleExternalSubtitleTrack])?
    private var externalSubtitleTask: Task<Void, Never>?

    // MARK: - Candidate fallback

    private var fallbackCandidates: [ApplePlaybackRequest] = []
    private var fallbackAttempted = 0
    private var fallbackTotal = 0
    private var fallbackTitle: String? = nil

    public init(
        engine: any ApplePlaybackEngine,
        timeout: Duration = .seconds(20),
        retryDelay: Duration = .seconds(3),
        progressInterval: Duration = .seconds(5)
    ) {
        self.engine = engine
        self.timeoutDuration = timeout
        self.retryDelay = retryDelay
        self.progressInterval = progressInterval
    }

    /// Convenience initializer that creates a default engine via the factory so
    /// source views can keep `ApplePlaybackCoordinator()` as a `@State` default.
    public convenience init() {
        let (engine, _) = ApplePlaybackEngineFactory.make(preferred: .openStream)
        self.init(engine: engine)
    }

    isolated deinit {
        externalSubtitleTask?.cancel()
        observationTask?.cancel()
        loadTask?.cancel()
        fallbackTask?.cancel()
        timeoutTask?.cancel()
        liveRetryTask?.cancel()
    }

    public func beginResolving() { phase = .resolving }

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
        hasShownFallbackNotice = false
        let ordered = [request] + fallbackCandidates.prefix(2)
        self.fallbackCandidates = Array(ordered.dropFirst())
        self.fallbackAttempted = 1
        self.fallbackTotal = ordered.count
        self.fallbackTitle = request.title
        await beginAttempt(ordered[0])
    }

    private func beginAttempt(_ request: ApplePlaybackRequest) async {
        generation &+= 1
        let attempt = generation
        loadTask?.cancel()
        lastRequest = request
        liveRetryAttempted = false
        lastProgressWrite = nil
        cancelObservation()
        cancelTimeout()
        cancelLiveRetry()
        engine.stop()
        phase = .loading
        route = engine.route
        appleTrace("play \"\(request.title ?? "untitled")\" attempt \(fallbackAttempted)/\(fallbackTotal) \(request.sourceKind.rawValue)\(request.isLive ? " live" : "") host=\(request.url.host() ?? "?") route=\(route)")
        startExternalSubtitles(for: request, attempt: attempt)
        setupProgress(for: request)
        startTimeout()
        let engine = self.engine
        let task = Task { @MainActor in try await engine.load(request) }
        loadTask = task
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
        let retriedLive = liveRetryAttempted
        await beginAttempt(request)
        liveRetryAttempted = retriedLive
    }

    public func stop() {
        sharedPlayback?.suspendForLocalTransition()
        generation &+= 1
        externalSubtitleTask?.cancel()
        externalSubtitleTask = nil
        loadTask?.cancel()
        loadTask = nil
        fallbackTask?.cancel()
        fallbackTask = nil
        lastRequest = nil
        clearFallback()
        stopMonitoring()
        cancelObservation()
        cancelTimeout()
        cancelLiveRetry()
        progressCoordinator?.stopObserving()
        progressCoordinator = nil
        engine.stop()
        phase = .idle
        route = .none
    }

    public func update(_ phase: ApplePlaybackPhase) { self.phase = phase }

    public func reset() {
        stopMonitoring()
        cancelObservation()
        cancelTimeout()
        cancelLiveRetry()
        phase = .idle
    }

    @discardableResult
    public func fail(_ error: any Error) -> ApplePlaybackFailure {
        stopMonitoring()
        cancelTimeout()
        let failure = ApplePlaybackFailure.classify(error)
        cancelObservation()
        phase = .failed(failure)
        return failure
    }

    // MARK: - Add-on subtitles

    /// Asks the installed add-ons for subtitle files for this title, without
    /// holding up the load: the fetch runs alongside it and the tracks are
    /// appended to the engine whenever they arrive. A newer attempt (a stream
    /// switch) discards the result.
    private func startExternalSubtitles(for request: ApplePlaybackRequest, attempt: Int) {
        externalSubtitleTask?.cancel()
        externalSubtitleTask = nil
        guard let query = AppleExternalSubtitleQuery(request: request) else { return }
        let fetcher = externalSubtitleFetcher
        let engine = self.engine
        externalSubtitleTask = Task { @MainActor [weak self] in
            let tracks: [AppleExternalSubtitleTrack]
            if let fetcher {
                tracks = await fetcher(query)
            } else {
                let sources = AppleSourceStore().sources
                tracks = await AppleExternalSubtitleService.shared.tracks(
                    for: query,
                    sources: sources,
                    preferredLanguages: AppleSubtitleLanguages.storedPreferredLanguages()
                )
            }
            guard let self, !Task.isCancelled, self.generation == attempt, !tracks.isEmpty else { return }
            engine.addExternalSubtitleTracks(tracks)
        }
    }

    // MARK: - Candidate fallback

    /// On an `.unsupportedMedia` or HTTP/network failure, advance to the next
    /// ranked candidate. When the list is exhausted, report a single
    /// `.unsupportedMedia` failure naming how many streams were tried.
    private func handleFailure(_ failure: ApplePlaybackFailure) async {
        appleTraceFailure("playback \(failure.kind): \(failure.message) — \(shouldFallBack(for: failure) ? "falling back" : "final")")
        if shouldFallBack(for: failure), let lastRequest {
            ApplePlaybackFailureHistory.shared.record(lastRequest.url)
            onSourceFailure?(lastRequest)
        }
        if shouldFallBack(for: failure), let next = nextFallbackCandidate() {
            cancelTimeout()
            cancelObservation()
            showFallbackNotice()
            await beginAttempt(next)
        } else if shouldFallBack(for: failure), let nextAutomaticSource {
            cancelTimeout()
            cancelObservation()
            let attempt = generation
            do {
                let next = try await nextAutomaticSource()
                guard !Task.isCancelled, generation == attempt else { return }
                if let next {
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

    /// Returns the next candidate to try and advances the attempt count, or
    /// nil if the list is exhausted.
    private func nextFallbackCandidate() -> ApplePlaybackRequest? {
        guard !fallbackCandidates.isEmpty else { return nil }
        let next = fallbackCandidates.removeFirst()
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
            route = newRoute
            setupProgress(for: request)
        case .position(let position):
            handlePosition(position)
        case .duration, .tracks:
            break
        case .failure(let failure):
            if let failure {
                scheduleFailure(failure)
            }
        }
    }

    private func applyEnginePhase(_ enginePhase: ApplePlaybackEnginePhase, request: ApplePlaybackRequest) {
        switch enginePhase {
        case .idle:
            break
        case .loading:
            phase = .loading
        case .playing:
            // The first frame. Everything before this is the wait the owner
            // sees as a spinner, so it is the one timestamp worth having.
            if case .playing = phase {} else { appleTrace("first frame, route=\(route)") }
            phase = .playing
            cancelTimeout()
            clearFallback()
        case .paused:
            phase = .paused
        case .seeking:
            break
        case .rebuffering:
            appleTrace("rebuffering")
            phase = .waiting("Buffering…")
        case .stalled(let reconnecting):
            appleTrace("stalled reconnecting=\(reconnecting)")
            phase = .waiting(reconnecting ? "Reconnecting…" : "Reconnecting…")
        case .ended:
            handleEnded(request: request)
        case .error(let message):
            cancelTimeout()
            scheduleFailure(engine.failure ?? ApplePlaybackFailure(kind: .player, message: message))
        }
    }

    private func handleEnded(request: ApplePlaybackRequest) {
        guard request.isLive else {
            cancelTimeout()
            phase = .ended
            return
        }
        if !liveRetryAttempted {
            liveRetryAttempted = true
            phase = .waiting("Stream ended. Reconnecting…")
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
            phase = .failed(ApplePlaybackFailure(
                kind: .sourceEnded,
                message: "The channel stopped sending data."
            ))
        }
    }

    // MARK: - Timeout

    /// A live channel that has not produced a frame by now is not coming: the
    /// provider is refusing it or the stream is dead. Dead channels are normal
    /// in a large lineup, and holding them to the on-demand timeout left the
    /// screen black for twenty seconds before saying anything, which is most of
    /// what "live freezes when flipping channels" was (owner 2026-09-14).
    private var liveTimeoutDuration: Duration { .seconds(10) }

    private func startTimeout() {
        timeoutTask?.cancel()
        let isLive = lastRequest?.isLive ?? false
        let duration = isLive ? liveTimeoutDuration : timeoutDuration
        let attempt = generation
        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self, self.generation == attempt else { return }
            switch self.phase {
            case .idle, .resolving, .loading, .waiting:
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
        surfaceProgressIdentity = request.isLive ? nil : request.mediaID
        surfaceProgressPartID = AppleDetailResume.partID(type: request.hints.addonMediaType,
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
            }
        default:
            progressCoordinator?.stopObserving()
            progressCoordinator = nil
        }
    }

    private func handlePosition(_ position: Double) {
        guard route == .surface else { return }
        let now = ContinuousClock().now
        guard lastProgressWrite == nil || now - lastProgressWrite! >= progressInterval else { return }
        lastProgressWrite = now
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
        route = engine.route
        setupProgress(for: request)
        if let failure = engine.failure {
            cancelTimeout()
            phase = .failed(failure)
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
}
