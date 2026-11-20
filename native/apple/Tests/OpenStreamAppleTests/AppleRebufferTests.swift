import Foundation
import Testing
@testable import OpenStreamApple

@Suite struct ApplePlaybackRebufferLedgerTests {
    let start = ContinuousClock.now

    @Test func aWaitThatNeverShowedIsShort() {
        var ledger = ApplePlaybackRebufferLedger()
        let began = ledger.begin(at: start)
        #expect(began)
        ledger.end(at: start + .milliseconds(300))
        #expect(ledger.short == 1)
        #expect(ledger.full == 0)
        #expect(ledger.waited == .zero)
    }

    @Test func aShownWaitIsFullAndTimed() {
        var ledger = ApplePlaybackRebufferLedger()
        _ = ledger.begin(at: start)
        ledger.show()
        ledger.end(at: start + .milliseconds(1_500))
        #expect(ledger.full == 1)
        #expect(ledger.waited == .milliseconds(1_500))
        #expect(ledger.summary == "rebuffers: 1 full (1.5 s waiting), 0 short drew nothing")
    }

    @Test func aSecondBeginInsideAWaitIsTheSameWait() {
        var ledger = ApplePlaybackRebufferLedger()
        let first = ledger.begin(at: start)
        let second = ledger.begin(at: start + .milliseconds(100))
        #expect(first)
        #expect(!second)
        ledger.end(at: start + .milliseconds(200))
        #expect(ledger.short == 1)
    }

    @Test func aPlaybackWithoutWaitsHasNoSummary() {
        var ledger = ApplePlaybackRebufferLedger()
        ledger.end(at: start)
        #expect(ledger.summary == nil)
    }
}

/// REA round 4, fix 3: an underrun under half a second shows no waiting state.
@MainActor
@Suite(.serialized) struct AppleShortRebufferTests {
    private func request() -> ApplePlaybackRequest {
        ApplePlaybackRequest(url: URL(string: "http://127.0.0.1:8765/media/movie.mkv")!,
                             mediaID: "rebuffer-fixture", sourceKind: .networkShare)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(8)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test func aRebufferThatClearsQuicklyDrawsNothing() async {
        let engine = FakePlaybackEngine()
        engine.script([.loading, .playing])
        let coordinator = ApplePlaybackCoordinator(engine: engine, timeout: .seconds(60))
        await coordinator.begin(request())
        engine.emit(.phase(.rebuffering))
        engine.emit(.phase(.playing))
        #expect(await waitUntil { coordinator.rebuffers.short == 1 })
        #expect(coordinator.rebuffers.full == 0)
        #expect(coordinator.phase == .playing)
        coordinator.stop()
    }

    @Test func aRebufferPastHalfASecondShowsAndIsCounted() async {
        let engine = FakePlaybackEngine()
        engine.script([.loading, .playing])
        let coordinator = ApplePlaybackCoordinator(engine: engine, timeout: .seconds(60))
        await coordinator.begin(request())
        let began = ContinuousClock.now
        engine.emit(.phase(.rebuffering))
        #expect(await waitUntil { coordinator.phase == .waiting("Buffering…") })
        #expect(began.duration(to: .now) >= ApplePlaybackRebufferLedger.shortLimit)
        engine.emit(.phase(.playing))
        #expect(await waitUntil { coordinator.rebuffers.full == 1 })
        #expect(coordinator.rebuffers.short == 0)
        coordinator.stop()
    }
}

/// Closing the player ends the share file's bridge session, which writes the
/// bridge's read summary to the trace (none landed on a test iPhone before, 2026-10-18).
@MainActor
@Test func stoppingAShareFilePlaybackEndsItsBridgeSession() async throws {
    let url = try await AppleSMBRangeServer.shared.playbackURL(sourceURL: URL(string: "smb://fixture.invalid/Media/disc.iso")!,
        credentials: .init(username: "fixture", password: "fixture"), sizeBytes: 1_024)
    var head = URLRequest(url: url)
    head.httpMethod = "HEAD"
    // nil once the session is gone and the idle listener has stopped.
    func status() async -> Int? {
        try? await (URLSession.shared.data(for: head).1 as? HTTPURLResponse)?.statusCode
    }
    #expect(await status() == 200)
    let engine = FakePlaybackEngine()
    engine.script([.loading, .playing])
    let coordinator = ApplePlaybackCoordinator(engine: engine, timeout: .seconds(60))
    await coordinator.begin(ApplePlaybackRequest(url: url, mediaID: "bridge-fixture", sourceKind: .networkShare))
    coordinator.stop()
    let deadline = ContinuousClock.now + .seconds(2)
    while await status() == 200, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await status() != 200)
}
