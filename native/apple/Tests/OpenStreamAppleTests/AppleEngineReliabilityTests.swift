import Foundation
import Testing
@testable import OpenStreamApple

@Suite("Engine reliability")
struct AppleEngineReliabilityTests {
    private func failure(_ kind: ApplePlaybackFailure.Kind, status: Int? = nil, message: String = "open failed") -> ApplePlaybackFailure {
        ApplePlaybackFailure(kind: kind, message: message, httpStatus: status)
    }

    private func retries(_ failure: ApplePlaybackFailure, isLive: Bool = false, played: Bool = false,
                         retried: Bool = false, openStream: Bool = true) -> Bool {
        AppleEngineOpenRetryPolicy.shouldRetry(failure: failure, isLive: isLive, reachedFirstFrame: played,
                                               alreadyRetried: retried, engineIsOpenStream: openStream)
    }

    @Test("An open failure before the first frame retries the same candidate once")
    func retriesOnce() {
        #expect(retries(failure(.network)))
        #expect(retries(failure(.player)))
        #expect(retries(failure(.unsupportedMedia)))
        #expect(!retries(failure(.network), retried: true))
        #expect(AppleEngineOpenRetryPolicy.delay == .seconds(1))
    }

    @Test("No retry for live, after a frame, on the stock player, or for answers that will not change")
    func noRetry() {
        #expect(!retries(failure(.network), isLive: true))
        #expect(!retries(failure(.network), played: true))
        #expect(!retries(failure(.network), openStream: false))
        #expect(!retries(failure(.authentication)))
        #expect(!retries(failure(.timedOut)))
        #expect(!retries(failure(.unavailable)))
        #expect(!retries(failure(.network, status: 404)))
        #expect(!retries(failure(.network, message: AppleTruncatedMediaProbe.message)))
        #expect(retries(failure(.network, status: 503)))
    }

    @Test("Engine log lines are scrubbed of URLs and credentials, flattened and bounded")
    func engineLogScrubbing() {
        let line = AppleEngineLogBridge.traceLine(
            "[AetherEngine] open https://fixture.example/play/abc?token=SECRET\nrange 0-1 password=hunter2")
        #expect(line.hasPrefix("[AetherEngine] open "))
        #expect(!line.contains("fixture.example"))
        #expect(!line.contains("SECRET"))
        #expect(!line.contains("hunter2"))
        #expect(!line.contains("\n"))
        let long = AppleEngineLogBridge.traceLine(String(repeating: "x", count: 1_000))
        #expect(long.count <= AppleEngineLogBridge.prefix.count + AppleEngineLogBridge.maximumLineLength + 1)
        #expect(AppleEngineLogBridge.traceLine("player_api.php?username=a&password=b").contains("[REDACTED]"))
    }

    @Test("The engine log rate limit admits a window's worth, then reports what it dropped")
    func rateLimit() {
        let limiter = AppleEngineLogBridge.RateLimiter(limit: 2, window: 1)
        let start = Date(timeIntervalSince1970: 1_000)
        #expect(limiter.admit(now: start) == .admit(droppedBefore: 0))
        #expect(limiter.admit(now: start.addingTimeInterval(0.1)) == .admit(droppedBefore: 0))
        #expect(limiter.admit(now: start.addingTimeInterval(0.2)) == .drop)
        #expect(limiter.admit(now: start.addingTimeInterval(0.3)) == .drop)
        #expect(limiter.admit(now: start.addingTimeInterval(1.5)) == .admit(droppedBefore: 2))
    }
}

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1))) struct AppleEngineOpenRetryCoordinatorTests {
    private func request(_ id: String) -> ApplePlaybackRequest {
        ApplePlaybackRequest(url: URL(string: "http://127.0.0.1:8765/media/\(id).mkv")!,
                             mediaID: id, sourceKind: .catalog)
    }

    /// No wall-clock deadline: the parallel gate can hold the coordinator's
    /// tasks up for seconds; the time limit fails an outcome that never comes.
    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        while !condition(), !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test("A failed open retries the same candidate, then plays it, before any fallback")
    func retriesSameCandidate() async {
        let engine = FakePlaybackEngine()
        var opens = 0
        engine.loadHandler = { request in
            if request.mediaID == "first" {
                opens += 1
                if opens == 1 { throw ApplePlaybackFailure(kind: .network, message: "connection reset") }
            }
            engine.phase = .playing
        }
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        coordinator.retriesFailedEngineOpen = true
        coordinator.engineOpenRetryDelay = .milliseconds(10)
        await coordinator.begin(request("first"), fallbackCandidates: [request("second")])
        await waitUntil { coordinator.phase == .playing }
        #expect(engine.loadedRequests.map(\.mediaID) == ["first", "first"])
        coordinator.stop()
    }

    @Test("A second failure of the same candidate falls back to the next")
    func secondFailureFallsBack() async {
        let engine = FakePlaybackEngine()
        engine.loadHandler = { request in
            if request.mediaID == "first" { throw ApplePlaybackFailure(kind: .network, message: "connection reset") }
            engine.phase = .playing
        }
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        coordinator.retriesFailedEngineOpen = true
        coordinator.engineOpenRetryDelay = .milliseconds(10)
        await coordinator.begin(request("first"), fallbackCandidates: [request("second")])
        await waitUntil { coordinator.phase == .playing }
        #expect(engine.loadedRequests.map(\.mediaID) == ["first", "first", "second"])
        coordinator.stop()
    }

    @Test("Live opens retry once without stacking the engine retry")
    func liveRetriesOnlyOnce() async {
        let engine = FakePlaybackEngine()
        engine.failOnLoad = ApplePlaybackFailure(kind: .network, message: "down")
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        #expect(coordinator.retriesFailedEngineOpen == false)
        coordinator.retriesFailedEngineOpen = true
        coordinator.engineOpenRetryDelay = .milliseconds(10)
        var live = request("live")
        live.isLive = true
        live.sourceKind = .iptv
        await coordinator.begin(live)
        await waitUntil { if case .failed = coordinator.phase { true } else { false } }
        #expect(engine.loadedRequests.count == 2)
        coordinator.stop()
    }
}

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1))) struct AppleSilentSourceReopenTests {
    private func request(_ id: String, kind: ApplePlaybackRequest.SourceKind = .mediaServer) -> ApplePlaybackRequest {
        ApplePlaybackRequest(url: URL(string: "https://fixture.example/videos/\(id)/stream")!,
                             mediaID: id, sourceKind: kind)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        while !condition(), !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
    }

    /// A load the engine has taken that never hears from its source, like the
    /// Rill origin's unanswered first request in walk 8.
    private func silentOpen(_ engine: FakePlaybackEngine) async throws {
        engine.awaitsSourceBytes = true
        try await Task.sleep(for: .seconds(30))
    }

    @Test("Only remote on-demand streams are reopened, at most twice per press")
    func policy() {
        #expect(ApplePlaybackStartPolicy.sourceFirstByteDeadline == .seconds(5))
        #expect(ApplePlaybackStartPolicy.reopensSilentSource(request("a"), reopens: 0))
        #expect(ApplePlaybackStartPolicy.reopensSilentSource(request("a", kind: .catalog), reopens: 1))
        #expect(!ApplePlaybackStartPolicy.reopensSilentSource(request("a"), reopens: 2))
        #expect(!ApplePlaybackStartPolicy.reopensSilentSource(request("a", kind: .networkShare), reopens: 0))
        #expect(!ApplePlaybackStartPolicy.reopensSilentSource(request("a", kind: .files), reopens: 0))
        var live = request("a", kind: .iptv)
        live.isLive = true
        #expect(!ApplePlaybackStartPolicy.reopensSilentSource(live, reopens: 0))
        var disc = request("a")
        disc.hints.disc = AppleDiscPlaybackChoice(start: .mainTitle)
        #expect(!ApplePlaybackStartPolicy.reopensSilentSource(disc, reopens: 0))
    }

    @Test("A source that sends nothing by the deadline is reopened and the reopen plays")
    func reopensSilentSource() async {
        let engine = FakePlaybackEngine()
        var opens = 0
        var firstLoadCancelled = false
        engine.loadHandler = { _ in
            opens += 1
            if opens == 1 {
                do { try await self.silentOpen(engine) }
                catch is CancellationError {
                    firstLoadCancelled = true
                    throw CancellationError()
                }
            }
            engine.awaitsSourceBytes = false
            engine.phase = .playing
        }
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        coordinator.sourceFirstByteDeadline = .milliseconds(20)
        await coordinator.begin(request("return"))
        await waitUntil { coordinator.phase == .playing && firstLoadCancelled }
        #expect(engine.stopCount == 2)
        #expect(engine.loadedRequests.map(\.mediaID) == ["return", "return"])
        coordinator.stop()
    }

    @Test("A source that never answers stops after three full waits and offers Retry")
    func reopenLimit() async {
        let engine = FakePlaybackEngine()
        engine.loadHandler = { _ in try await self.silentOpen(engine) }
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        coordinator.sourceFirstByteDeadline = .milliseconds(20)
        await coordinator.begin(request("doctorx"))
        await waitUntil {
            if case .failed = coordinator.phase { return true }
            return false
        }
        #expect(engine.loadedRequests.count == 3)
        if case .failed(let failure) = coordinator.phase {
            #expect(failure.kind == .network)
            #expect(failure.networkCode == .timedOut)
        }
        engine.loadHandler = { _ in
            engine.awaitsSourceBytes = false
            engine.phase = .playing
        }
        await coordinator.retry()
        #expect(coordinator.phase == .playing)
        coordinator.stop()
    }

    @Test("An on-demand stream ending before playback fails instead of closing silently")
    func endsBeforePlaybackOffersRetry() async {
        let engine = FakePlaybackEngine()
        engine.loadHandler = { _ in engine.phase = .ended }
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        await coordinator.begin(request("empty"))
        await waitUntil {
            if case .failed = coordinator.phase { return true }
            return coordinator.phase == .ended
        }
        if case .failed(let failure) = coordinator.phase {
            #expect(failure.kind == .sourceEnded)
        } else { Issue.record("An empty stream was treated as completed playback") }
        coordinator.stop()
    }

    @Test("A source that has sent bytes is not reopened however slow the rest of the start is")
    func openedSourceKeepsItsLoad() async {
        let engine = FakePlaybackEngine()
        engine.loadHandler = { _ in try await Task.sleep(for: .seconds(30)) }
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        coordinator.sourceFirstByteDeadline = .milliseconds(20)
        let start = Task { await coordinator.begin(self.request("nightmare")) }
        try? await Task.sleep(for: .milliseconds(200))
        #expect(engine.loadedRequests.count == 1)
        coordinator.stop()
        await start.value
    }
}
