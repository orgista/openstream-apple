import Foundation
import Testing
@testable import OpenStreamApple

@MainActor
@Suite(.serialized) struct ApplePlaybackCoordinatorTests {
    private func makeRequest(
        isLive: Bool = false,
        sourceKind: ApplePlaybackRequest.SourceKind = .stremio
    ) -> ApplePlaybackRequest {
        ApplePlaybackRequest(
            url: URL(string: "http://127.0.0.1:8765/media/movie.mp4")!,
            isLive: isLive,
            mediaID: "test-media-id",
            sourceKind: sourceKind
        )
    }

    // MARK: - Phase mapping (policy table rows)

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
        let next = ApplePlaybackRequest(url: makeRequest().url, mediaID: "next", sourceKind: .stremio)
        await coordinator.begin(makeRequest(), fallbackCandidates: [next])
        // Fixed sleeps made this the flakiest test in the suite: 50 ms is not
        // enough for the fallback to load on a machine that is also running a
        // simulator, so the assertions fired mid-transition and saw one
        // request and `.loading`. Wait for the outcome instead of guessing how
        // long it takes.
        _ = await coordinatorWaitUntil { engine.loadedRequests.isEmpty == false }
        engine.emit(.failure(.init(kind: .unsupportedMedia, message: "Unsupported fixture")))
        _ = await coordinatorWaitUntil { engine.loadedRequests.count >= 2 && coordinator.phase == .playing }
        #expect(engine.loadedRequests.map(\.mediaID) == ["test-media-id", "next"])
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
        weak var reference = coordinator
        await coordinator?.begin(makeRequest())
        try? await Task.sleep(for: .milliseconds(20))
        coordinator = nil
        await Task.yield()
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
        engine.script([.loading, .playing, .ended])
        let coordinator = ApplePlaybackCoordinator(engine: engine, timeout: .seconds(60))
        await coordinator.begin(makeRequest(isLive: false))
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
        // Wait for the observed state, since concurrent builds can delay the
        // failure-handling task beyond a fixed 20 ms scheduling window.
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if case .failed = coordinator.phase { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
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
        await coordinator.begin(makeRequest())
        // Poll rather than a single fixed sleep: a fixed short wait flakes when
        // the machine is loaded (several agents building at once).
        for _ in 0..<50 {
            if case .failed = coordinator.phase { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        if case .failed(let failure) = coordinator.phase {
            #expect(failure.kind == .timedOut)
            #expect(failure.message == "The player did not become ready in time.")
        } else {
            Issue.record("expected .failed(.timedOut), got \(coordinator.phase)")
        }
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

    @Test func liveEndedRetriesOnceThenFailsOnSecondEnded() async {
        let engine = FakePlaybackEngine()
        engine.script([.loading, .playing])
        engine.scriptedRoute = .avPlayer
        let coordinator = ApplePlaybackCoordinator(
            engine: engine,
            timeout: .seconds(60),
            retryDelay: .milliseconds(50)
        )
        await coordinator.begin(makeRequest(isLive: true))
        #expect(coordinator.phase == .playing)

        try? await Task.sleep(for: .milliseconds(10))
        engine.emit(.phase(.ended))
        try? await Task.sleep(for: .milliseconds(20))
        #expect(coordinator.phase == .waiting("Stream ended. Reconnecting…"))

        try? await Task.sleep(for: .milliseconds(120))
        #expect(coordinator.phase == .playing)

        engine.emit(.phase(.ended))
        try? await Task.sleep(for: .milliseconds(20))
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
        var writes: [(Double, Double, ContinuousClock.Instant)] = []
        let coordinator = ApplePlaybackCoordinator(
            engine: engine,
            timeout: .seconds(60),
            progressInterval: .milliseconds(50)
        )
        coordinator.progressWriter = { pos, dur in
            writes.append((pos, dur, .now))
        }
        await coordinator.begin(makeRequest())
        #expect(coordinator.route == .surface)

        // A burst verifies throttling without assuming the scheduler resumes
        // a 10 ms sleep before a 50 ms interval has elapsed on a busy machine.
        for position in 1...100 { engine.emit(.position(Double(position))) }
        engine.emit(.phase(.paused))
        let batchDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while coordinator.phase != .paused, ContinuousClock.now < batchDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(coordinator.phase == .paused)
        #expect(writes.count < 100)
        #expect(writes.first?.0 == 1)
        for (earlier, later) in zip(writes, writes.dropFirst()) {
            #expect(earlier.2.duration(to: later.2) >= .milliseconds(49))
        }
        try? await Task.sleep(for: .milliseconds(60))
        engine.emit(.position(200))
        engine.emit(.phase(.playing))
        let finalDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while coordinator.phase != .playing, ContinuousClock.now < finalDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(coordinator.phase == .playing)
        #expect(writes.count >= 2)
        #expect(writes.last?.0 == 200)
        coordinator.stop()
    }
}

/// Polls for an outcome rather than sleeping a fixed amount, so a loaded
/// machine slows the suite down instead of failing it.
private func coordinatorWaitUntil(
    timeout: Duration = .seconds(8),
    _ condition: @MainActor () -> Bool
) async -> Bool {
    let deadline = ContinuousClock().now + timeout
    while ContinuousClock().now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}
