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
        #expect(!retries(failure(.player, message: AppleStreamPlaceholderPolicy.failureMessage)))
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
@Suite(.serialized) struct AppleEngineOpenRetryCoordinatorTests {
    private func request(_ id: String) -> ApplePlaybackRequest {
        ApplePlaybackRequest(url: URL(string: "http://127.0.0.1:8765/media/\(id).mkv")!,
                             mediaID: id, sourceKind: .stremio)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(8)
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
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
