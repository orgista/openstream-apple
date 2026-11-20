import Foundation
import Testing
@testable import OpenStreamApple

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1))) struct ApplePlaybackCoordinatorTests {
    private func makeRequest(
        isLive: Bool = false,
        sourceKind: ApplePlaybackRequest.SourceKind = .catalog
    ) -> ApplePlaybackRequest {
        ApplePlaybackRequest(
            url: URL(string: "http://127.0.0.1:8765/media/movie.mp4")!,
            isLive: isLive,
            mediaID: "test-media-id",
            sourceKind: sourceKind
        )
    }

    // MARK: - Phase mapping (policy table rows)

    @Test func livePlaybackBlocksHealthProbesUntilEveryPlayerStops() async {
        let store = AppleChannelHealthStore()
        store.setLineup([AppleIPTVChannel(id: "fixture", sourceID: UUID(), name: "Fixture",
            streamURL: URL(string: "https://fixture.example/live.m3u8")!)])
        let first = ApplePlaybackCoordinator(engine: FakePlaybackEngine())
        let second = ApplePlaybackCoordinator(engine: FakePlaybackEngine())
        store.beginLivePlayback(first)
        store.beginLivePlayback(second)
        #expect(store.hasLivePlayback)
        store.startSweep()
        #expect(!store.isSweeping)
        store.endLivePlayback(first)
        #expect(store.hasLivePlayback)
        store.endLivePlayback(second)
        #expect(!store.hasLivePlayback)
        await first.begin(makeRequest(isLive: true, sourceKind: .iptv))
        #expect(AppleChannelHealthStore.shared.tracksLivePlayback(first))
        first.stop()
        #expect(AppleChannelHealthStore.shared.tracksLivePlayback(first) == false)
    }

    @Test func supersededLoadFailureCannotReplaceNewPlayback() async throws {
        let engine = FakePlaybackEngine()
        var oldLoad: CheckedContinuation<Void, any Error>?
        engine.loadHandler = { request in
            if request.mediaID == "old" {
                try await withCheckedThrowingContinuation { oldLoad = $0 }
            } else { engine.phase = .playing }
        }
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        let old = ApplePlaybackRequest(url: makeRequest().url, mediaID: "old", sourceKind: .iptv)
        let first = Task { await coordinator.begin(old) }
        while oldLoad == nil { await Task.yield() }
        await coordinator.begin(makeRequest())
        oldLoad?.resume(throwing: URLError(.cannotConnectToHost))
        await first.value
        #expect(coordinator.phase == .playing)
        coordinator.stop()
    }

    @Test func asynchronousCandidateFailureTriesTheNextStream() async {
        let engine = FakePlaybackEngine()
        engine.loadHandler = { request in engine.phase = request.mediaID == "next" ? .playing : .loading }
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        let next = ApplePlaybackRequest(url: makeRequest().url, mediaID: "next", sourceKind: .catalog)
        await coordinator.begin(makeRequest(), fallbackCandidates: [next])
        // Fixed sleeps made this the flakiest test in the suite: 50 ms is not
        // enough for the fallback to load on a machine that is also running a
        // simulator, so the assertions fired mid-transition and saw one
        // request and `.loading`. Wait for the outcome instead of guessing how
        // long it takes.
        await coordinatorWaitUntil { engine.loadedRequests.isEmpty == false }
        engine.emit(.failure(.init(kind: .unsupportedMedia, message: "Unsupported fixture")))
        await coordinatorWaitUntil { engine.loadedRequests.count >= 2 && coordinator.phase == .playing }
        #expect(engine.loadedRequests.map(\.mediaID) == ["test-media-id", "next"])
        #expect(coordinator.phase == .playing)
        coordinator.stop()
    }

    @Test func liveOpenReopensOnceBeforeTryingTheAlternate() async {
        let engine = FakePlaybackEngine()
        let first = ApplePlaybackRequest(url: URL(string: "https://fixture.example/dead.m3u8")!, isLive: true,
            mediaID: "dead", sourceKind: .iptv)
        let backup = ApplePlaybackRequest(url: URL(string: "https://fixture.example/backup.m3u8")!, isLive: true,
            mediaID: "backup", sourceKind: .iptv)
        engine.loadHandler = { request in
            if request.mediaID == "dead" { throw ApplePlaybackFailure(kind: .network, message: "Fixture offline") }
            engine.phase = .playing
        }
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        await coordinator.begin(first, fallbackCandidates: [backup])
        #expect(engine.loadedRequests.map(\.mediaID) == ["dead", "dead", "backup"])
        #expect(coordinator.phase == .playing)
        coordinator.stop()
    }

    @Test func authenticationFailureKeepsItsActionableReasonWithAlternatives() async {
        let engine = FakePlaybackEngine()
        engine.failOnLoad = .init(kind: .authentication, message: "The source rejected authentication (HTTP 403).")
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        await coordinator.begin(makeRequest(), fallbackCandidates: [makeRequest()])
        guard case .failed(let failure) = coordinator.phase else { Issue.record("Expected authentication error"); return }
        #expect(failure.kind == .authentication)
        #expect(failure.message.contains("403"))
        coordinator.stop()
    }

    @Test func stopInvalidatesAnInFlightLoadAndRetry() async {
        let engine = FakePlaybackEngine()
        var finish: CheckedContinuation<Void, Never>?
        engine.loadHandler = { _ in await withCheckedContinuation { finish = $0 } }
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        let task = Task { await coordinator.begin(makeRequest()) }
        while finish == nil { await Task.yield() }
        coordinator.stop()
        finish?.resume()
        await task.value
        #expect(coordinator.phase == .idle)
        #expect(coordinator.route == .none)
        engine.loadHandler = { _ in engine.phase = .playing }
        await coordinator.retry()
        #expect(engine.loadedRequests.count == 1)
    }

    @Test func coordinatorDoesNotRetainItselfWhileObserving() async {
        let engine = FakePlaybackEngine()
        engine.script([.playing])
        var coordinator: ApplePlaybackCoordinator? = ApplePlaybackCoordinator(engine: engine)
        weak let reference = coordinator
        await coordinator?.begin(makeRequest())
        coordinator = nil
        // Its observation task may be mid-event; once that ends nothing holds
        // it. A retain cycle never lets go, and the time limit fails it.
        await coordinatorWaitUntil { reference == nil }
        #expect(reference == nil)
        reference?.stop()
    }

    @Test func loadingPhaseMapsToLoading() async {
        let engine = FakePlaybackEngine()
        engine.script([.loading])
        let coordinator = ApplePlaybackCoordinator(engine: engine, timeout: .seconds(60))
        await coordinator.begin(makeRequest())
        #expect(coordinator.phase == .loading)
        coordinator.stop()
    }

    @Test func playingPhaseMapsToPlaying() async {
        let engine = FakePlaybackEngine()
        engine.script([.loading, .playing])
        let coordinator = ApplePlaybackCoordinator(engine: engine, timeout: .seconds(60))
        await coordinator.begin(makeRequest())
        #expect(coordinator.phase == .playing)
        coordinator.stop()
    }

    @Test func rebufferingMapsToWaitingBuffering() async {
        let engine = FakePlaybackEngine()
        engine.script([.loading, .playing, .rebuffering])
        let coordinator = ApplePlaybackCoordinator(engine: engine, timeout: .seconds(60))
        await coordinator.begin(makeRequest())
        #expect(coordinator.phase == .waiting("Buffering…"))
        coordinator.stop()
    }

    @Test func stalledReconnectingMapsToWaitingReconnecting() async {
        let engine = FakePlaybackEngine()
        engine.script([.loading, .playing, .stalled(reconnecting: true)])
        let coordinator = ApplePlaybackCoordinator(engine: engine, timeout: .seconds(60))
        await coordinator.begin(makeRequest())
        #expect(coordinator.phase == .waiting("Reconnecting…"))
        coordinator.stop()
    }

    @Test func pausedPhaseMapsToPaused() async {
        let engine = FakePlaybackEngine()
        engine.script([.loading, .playing, .paused])
        let coordinator = ApplePlaybackCoordinator(engine: engine, timeout: .seconds(60))
        await coordinator.begin(makeRequest())
        #expect(coordinator.phase == .paused)
        coordinator.stop()
    }

    @Test func endedNonLiveMapsToEnded() async {
        let engine = FakePlaybackEngine()
        engine.script([.loading, .playing])
        let coordinator = ApplePlaybackCoordinator(engine: engine, timeout: .seconds(60))
        await coordinator.begin(makeRequest(isLive: false))
        engine.emit(.phase(.ended))
        await coordinatorWaitUntil { coordinator.phase == .ended }
        #expect(coordinator.phase == .ended)
        coordinator.stop()
    }

    // MARK: - Failure

    @Test func loadFailureSetsFailedPhase() async {
        let engine = FakePlaybackEngine()
        let failure = ApplePlaybackFailure(kind: .network, message: "Network error")
        engine.failOnLoad = failure
        let coordinator = ApplePlaybackCoordinator(engine: engine, timeout: .seconds(60))
        await coordinator.begin(makeRequest())
        if case .failed(let phaseFailure) = coordinator.phase {
            #expect(phaseFailure.kind == .network)
        } else {
            Issue.record("expected .failed, got \(coordinator.phase)")
        }
        coordinator.stop()
    }

    @Test func failureEventSetsFailedPhase() async {
        let engine = FakePlaybackEngine()
        engine.script([.loading, .playing])
        let coordinator = ApplePlaybackCoordinator(engine: engine, timeout: .seconds(60))
        await coordinator.begin(makeRequest())
        #expect(coordinator.phase == .playing)
        let failure = ApplePlaybackFailure(kind: .player, message: "Player error")
        engine.emit(.failure(failure))
        await coordinatorWaitUntil { if case .failed = coordinator.phase { true } else { false } }
        if case .failed(let phaseFailure) = coordinator.phase {
            #expect(phaseFailure.message == "Player error")
        } else {
            Issue.record("expected .failed, got \(coordinator.phase)")
        }
        coordinator.stop()
    }

    // MARK: - Timeout

    @Test func timeoutFiresWhenPlayingNotReached() async {
        let engine = FakePlaybackEngine()
        engine.script([.loading])
        let coordinator = ApplePlaybackCoordinator(engine: engine, timeout: .milliseconds(50))
        let clock = ManualClock()
        coordinator.clock = clock
        await coordinator.begin(makeRequest())
        await clock.waitForSleep(until: .milliseconds(50))
        #expect(coordinator.phase == .loading)
        clock.advance(to: .milliseconds(50))
        await coordinatorWaitUntil { if case .failed = coordinator.phase { true } else { false } }
        if case .failed(let failure) = coordinator.phase {
            #expect(failure.kind == .timedOut)
            #expect(failure.message == "The player did not become ready in time.")
        } else {
            Issue.record("expected .failed(.timedOut), got \(coordinator.phase)")
        }
        coordinator.stop()
    }

    @Test func mediaServerStartupGetsAnotherWindowOnlyWhileCheckpointsAdvance() async {
        let engine = FakePlaybackEngine()
        engine.script([.loading])
        let coordinator = ApplePlaybackCoordinator(engine: engine, timeout: .milliseconds(50))
        let clock = ManualClock()
        coordinator.clock = clock
        await coordinator.begin(makeRequest(sourceKind: .mediaServer))
        await clock.waitForSleep(until: .milliseconds(50))
        engine.startupCheckpoint = 2
        clock.advance(to: .milliseconds(50))
        await clock.waitForSleep(until: .milliseconds(100))
        #expect(coordinator.phase == .loading)
        engine.startupCheckpoint = 6
        clock.advance(to: .milliseconds(100))
        await clock.waitForSleep(until: .milliseconds(150))
        #expect(coordinator.phase == .loading)
        clock.advance(to: .milliseconds(150))
        await coordinatorWaitUntil { if case .failed = coordinator.phase { true } else { false } }
        if case .failed(let failure) = coordinator.phase { #expect(failure.kind == .timedOut) }
        coordinator.stop()
    }

    // MARK: - Route

    @Test func routeAvPlayerIsMirrored() async {
        let engine = FakePlaybackEngine()
        engine.script([.loading, .playing])
        engine.scriptedRoute = .avPlayer
        let coordinator = ApplePlaybackCoordinator(engine: engine, timeout: .seconds(60))
        await coordinator.begin(makeRequest())
        #expect(coordinator.route == .avPlayer)
        coordinator.stop()
    }

    @Test func routeSurfaceIsMirrored() async {
        let engine = FakePlaybackEngine()
        engine.script([.loading, .playing])
        engine.scriptedRoute = .surface
        let coordinator = ApplePlaybackCoordinator(engine: engine, timeout: .seconds(60))
        await coordinator.begin(makeRequest())
        #expect(coordinator.route == .surface)
        coordinator.stop()
    }

    // MARK: - Live retry

    /// A live stream that ends mid-play goes through the bounded reconnect
    /// (`AppleLiveReconnectPolicy`); here one try, so the second end fails.
    @Test func liveEndedRetriesOnceThenFailsOnSecondEnded() async {
        let engine = FakePlaybackEngine()
        engine.script([.loading, .playing])
        engine.scriptedRoute = .avPlayer
        let coordinator = ApplePlaybackCoordinator(
            engine: engine,
            timeout: .seconds(60),
            retryDelay: .milliseconds(50)
        )
        coordinator.liveReconnectPolicy = AppleLiveReconnectPolicy(maxAttempts: 1, delays: [.milliseconds(50)])
        let clock = ManualClock()
        coordinator.clock = clock
        await coordinator.begin(makeRequest(isLive: true))
        #expect(coordinator.phase == .playing)

        engine.emit(.phase(.ended))
        await clock.waitForSleep(until: .milliseconds(50))
        #expect(coordinator.phase == .waiting("Reconnecting…"))

        clock.advance(to: .milliseconds(50))
        await coordinatorWaitUntil { coordinator.phase == .playing }

        engine.emit(.phase(.ended))
        await coordinatorWaitUntil { if case .failed = coordinator.phase { true } else { false } }
        if case .failed(let failure) = coordinator.phase {
            #expect(failure.kind == .sourceEnded)
            #expect(failure.message == "The channel stopped sending data.")
        } else {
            Issue.record("expected .failed(.sourceEnded), got \(coordinator.phase)")
        }
        coordinator.stop()
    }

    // MARK: - Progress throttling

    @Test func progressWritesAreThrottledOnSurfaceRoute() async {
        let engine = FakePlaybackEngine()
        engine.script([.loading, .playing])
        engine.scriptedRoute = .surface
        var writes: [Double] = []
        let coordinator = ApplePlaybackCoordinator(
            engine: engine,
            timeout: .seconds(60),
            progressInterval: .milliseconds(50)
        )
        let clock = ManualClock()
        coordinator.clock = clock
        coordinator.progressWriter = { pos, _ in
            writes.append(pos)
        }
        await coordinator.begin(makeRequest())
        #expect(coordinator.route == .surface)

        // A burst within one interval writes its first position only.
        for position in 1...100 { engine.emit(.position(Double(position))) }
        engine.emit(.phase(.paused))
        await coordinatorWaitUntil { coordinator.phase == .paused }
        #expect(writes == [1])
        // Past the interval the next position is written.
        clock.advance(by: .milliseconds(60))
        engine.emit(.position(200))
        engine.emit(.phase(.playing))
        await coordinatorWaitUntil { coordinator.phase == .playing }
        #expect(writes == [1, 200])
        coordinator.stop()
    }
}

/// Polls for an outcome rather than sleeping a fixed amount. No wall-clock
/// deadline: a loaded machine slows the suite down instead of failing it,
/// and the suite's time limit fails an outcome that never comes.
@MainActor
private func coordinatorWaitUntil(_ condition: @MainActor () -> Bool) async {
    while !condition(), !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(10))
    }
}

@Suite("Live channel failure wording")
struct AppleLiveFailureWordingTests {
    @Test func playerDiagnosticsBecomeAnActionableChannelMessage() {
        let failure = ApplePlaybackFailure(kind: .player, message: "Failed to load: custom source probe failed")
        #expect(failure.liveChannelMessage == "This channel could not start playing. Try again or choose another channel.")
    }

    @Test func channelDenialDoesNotBlameSavedCredentials() {
        let failure = ApplePlaybackFailure(kind: .authentication, message: "Provider rejected account (HTTP 403)")
        #expect(failure.liveChannelMessage.contains("403"))
        #expect(!failure.liveChannelMessage.contains("account"))
        #expect(failure.liveChannelMessage.contains("another channel"))
    }

    @Test func unsupportedFormatDetailsRemainAvailable() {
        let failure = ApplePlaybackFailure(kind: .unsupportedMedia, message: "This video format is not supported.")
        #expect(failure.liveChannelMessage == failure.message)
    }
}

@Suite("Playback diagnostic presentation")
struct ApplePlaybackDiagnosticPresentationTests {
    @Test func engineDiagnosticsStayOutOfUserMessages() {
        for kind in [ApplePlaybackFailure.Kind.player, .unsupportedMedia, .unavailable] {
            let raw = "HLSVideoEngine: open failed (Demuxer could not open input)"
            let failure = ApplePlaybackFailure(kind: kind, message: raw)
            #expect(!failure.userMessage.contains("Demuxer"))
            #expect(!failure.userMessage.contains("HLSVideoEngine"))
            #expect(failure.message == raw)
            #expect(ApplePlaybackEngineFallback.afterEveryStreamFailed(failure,
                engine: .openStream, alreadyFellBack: false) == .alert(failure.userMessage))
        }
    }

    @Test func sourceGuidanceIsPreserved() {
        let failure = ApplePlaybackFailure(kind: .unavailable,
            message: "Add an enabled stream source in Settings to play this title.")
        #expect(failure.userMessage == failure.message)
    }
}
