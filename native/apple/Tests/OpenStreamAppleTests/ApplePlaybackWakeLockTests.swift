import Foundation
import Testing
@testable import OpenStreamApple

/// Stands in for the real idle timer / `ProcessInfo` activity: the SPM test
/// process has no `UIApplication`, and a test must never take a real assertion
/// on the machine running it.
@MainActor
private final class RecordingWakeAssertion: ApplePlaybackWakeAssertion {
    private(set) var applied: [Bool] = []
    var isDisabled: Bool { applied.last ?? false }
    func setDisplaySleepDisabled(_ disabled: Bool) { applied.append(disabled) }
}

@MainActor
private func makeLock() -> (ApplePlaybackWakeLock, RecordingWakeAssertion) {
    let assertion = RecordingWakeAssertion()
    return (ApplePlaybackWakeLock(assertion: assertion), assertion)
}

@MainActor
@Suite("Playback wake lock") struct ApplePlaybackWakeLockTests {

    // MARK: - Reference counting

    @Test func oneSessionTakesAndGivesBackTheAssertion() {
        let (lock, assertion) = makeLock()
        lock.acquire("player")
        #expect(lock.holderCount == 1)
        #expect(assertion.isDisabled)
        lock.release("player")
        #expect(lock.holderCount == 0)
        #expect(assertion.isDisabled == false)
        #expect(assertion.applied == [true, false])
    }

    @Test func endingOneOfTwoSessionsKeepsTheDisplayAwake() {
        let (lock, assertion) = makeLock()
        lock.acquire("live")
        lock.acquire("detail")
        #expect(lock.holderCount == 2)
        lock.release("live")
        #expect(lock.holderCount == 1)
        #expect(assertion.isDisabled)
        // The assertion was taken once and never lifted in between.
        #expect(assertion.applied == [true])
        lock.release("detail")
        #expect(assertion.isDisabled == false)
    }

    @Test func repeatedAcquireCountsOnceAndOneReleaseIsEnough() {
        let (lock, assertion) = makeLock()
        lock.acquire("player")
        lock.acquire("player")
        lock.acquire("player")
        #expect(lock.holderCount == 1)
        lock.release("player")
        #expect(lock.holderCount == 0)
        #expect(assertion.isDisabled == false)
    }

    @Test func releasingTwiceCannotUnderflowOrDisturbAnotherHolder() {
        let (lock, assertion) = makeLock()
        lock.acquire("live")
        lock.acquire("detail")
        lock.release("live")
        lock.release("live")
        lock.release("live")
        #expect(lock.holderCount == 1)
        #expect(assertion.isDisabled)
        lock.release("detail")
        #expect(lock.holderCount == 0)
        #expect(assertion.isDisabled == false)
    }

    @Test func releasingAnOwnerThatNeverAcquiredDoesNothing() {
        let (lock, assertion) = makeLock()
        lock.release("never-played")
        #expect(lock.holderCount == 0)
        #expect(assertion.applied.isEmpty)
    }

    @Test func releaseAllDropsEveryClaim() {
        let (lock, assertion) = makeLock()
        lock.acquire("live")
        lock.acquire("detail")
        lock.releaseAll()
        #expect(lock.holderCount == 0)
        #expect(assertion.isDisabled == false)
    }

    // MARK: - Backgrounding (Picture-in-Picture, background audio)

    @Test func backgroundingLiftsTheAssertionAndReturningTakesItAgain() {
        let (lock, assertion) = makeLock()
        lock.acquire("player")
        #expect(assertion.isDisabled)
        lock.setApplicationActive(false)
        #expect(assertion.isDisabled == false)
        // The claim survives: the picture is still playing, it is just not on
        // screen. Picture-in-Picture and background audio hold nothing.
        #expect(lock.holderCount == 1)
        lock.setApplicationActive(true)
        #expect(assertion.isDisabled)
    }

    @Test func acquiringWhileBackgroundedTakesNothing() {
        let (lock, assertion) = makeLock()
        lock.setApplicationActive(false)
        lock.acquire("pip")
        #expect(lock.holderCount == 1)
        #expect(assertion.applied.isEmpty)
        lock.release("pip")
        #expect(assertion.applied.isEmpty)
    }

    // MARK: - Policy

    @Test(arguments: [
        ApplePlaybackPresentationRoute.avPlayer,
        .surface,
    ])
    func aPlayingVideoRouteHoldsTheDisplay(route: ApplePlaybackPresentationRoute) {
        #expect(ApplePlaybackWakePolicy.shouldHoldDisplayAwake(phase: .playing, route: route))
    }

    @Test(arguments: [
        ApplePlaybackPresentationRoute.audioOnly,
        ApplePlaybackPresentationRoute.none,
    ])
    func aPlayingRouteWithNoPictureDoesNotHoldTheDisplay(route: ApplePlaybackPresentationRoute) {
        #expect(ApplePlaybackWakePolicy.shouldHoldDisplayAwake(phase: .playing, route: route) == false)
    }

    @Test(arguments: [
        ApplePlaybackPhase.idle,
        .resolving,
        .loading,
        .waiting("Buffering…"),
        .paused,
        .ended,
        .failed(ApplePlaybackFailure(kind: .network, message: "gone")),
    ])
    func everythingThatIsNotPlayingLetsTheDisplaySleep(phase: ApplePlaybackPhase) {
        #expect(ApplePlaybackWakePolicy.shouldHoldDisplayAwake(phase: phase, route: .surface) == false)
    }
}

@MainActor
@Suite("Playback wake lock, driven by the coordinator", .serialized, .timeLimit(.minutes(1)))
struct ApplePlaybackCoordinatorWakeLockTests {
    private func makeRequest(isLive: Bool = true) -> ApplePlaybackRequest {
        ApplePlaybackRequest(
            url: URL(string: "https://fixture.example/live/1.ts")!,
            isLive: isLive,
            mediaID: "wake-test",
            sourceKind: .iptv
        )
    }

    /// The reported bug: live TV is demuxed by the engine and drawn on the
    /// `.surface` route, where there is no AVPlayer to keep the television lit.
    @Test func liveOnTheSurfaceRouteHoldsTheDisplayAwake() async {
        let (lock, assertion) = makeLock()
        let engine = FakePlaybackEngine()
        engine.scriptedRoute = .surface
        engine.script([.loading, .playing])
        let coordinator = ApplePlaybackCoordinator(engine: engine, timeout: .seconds(60), wakeLock: lock)
        await coordinator.begin(makeRequest())
        #expect(coordinator.phase == .playing)
        #expect(lock.holderCount == 1)
        #expect(assertion.isDisabled)
        coordinator.stop()
        #expect(lock.holderCount == 0)
        #expect(assertion.isDisabled == false)
    }

    @Test func pausingReleasesTheDisplayAndResumingTakesItBack() async {
        let (lock, _) = makeLock()
        let engine = FakePlaybackEngine()
        engine.scriptedRoute = .surface
        engine.script([.loading, .playing])
        let coordinator = ApplePlaybackCoordinator(engine: engine, timeout: .seconds(60), wakeLock: lock)
        await coordinator.begin(makeRequest())
        #expect(lock.holderCount == 1)

        engine.emit(.phase(.paused))
        await wakeWaitUntil { coordinator.phase == .paused }
        #expect(lock.holderCount == 0)

        engine.emit(.phase(.playing))
        await wakeWaitUntil { coordinator.phase == .playing }
        #expect(lock.holderCount == 1)
        coordinator.stop()
    }

    @Test func aMidPlaybackFailureReleasesTheDisplay() async {
        let (lock, assertion) = makeLock()
        let engine = FakePlaybackEngine()
        engine.scriptedRoute = .surface
        engine.script([.loading, .playing])
        let coordinator = ApplePlaybackCoordinator(engine: engine, timeout: .seconds(60), wakeLock: lock)
        await coordinator.begin(makeRequest())
        #expect(lock.holderCount == 1)

        engine.emit(.failure(.init(kind: .player, message: "The decoder stopped.")))
        await wakeWaitUntil { lock.holderCount == 0 }
        #expect(lock.holderCount == 0)
        #expect(assertion.isDisabled == false)
        coordinator.stop()
    }

    @Test func aLoadFailureNeverTakesTheDisplay() async {
        let (lock, assertion) = makeLock()
        let engine = FakePlaybackEngine()
        engine.scriptedRoute = .surface
        engine.failOnLoad = .init(kind: .network, message: "The channel is off the air.")
        let coordinator = ApplePlaybackCoordinator(engine: engine, timeout: .seconds(60), wakeLock: lock)
        await coordinator.begin(makeRequest())
        #expect(lock.holderCount == 0)
        #expect(assertion.applied.isEmpty)
        coordinator.stop()
    }

    @Test func anAudioOnlyRouteNeverTakesTheDisplay() async {
        let (lock, assertion) = makeLock()
        let engine = FakePlaybackEngine()
        engine.scriptedRoute = .audioOnly
        engine.script([.loading, .playing])
        let coordinator = ApplePlaybackCoordinator(engine: engine, timeout: .seconds(60), wakeLock: lock)
        await coordinator.begin(makeRequest(isLive: false))
        #expect(coordinator.phase == .playing)
        #expect(lock.holderCount == 0)
        #expect(assertion.applied.isEmpty)
        coordinator.stop()
    }

    @Test func twoPlayersAtOnceKeepTheDisplayUntilBothStop() async {
        let (lock, assertion) = makeLock()
        let liveEngine = FakePlaybackEngine()
        liveEngine.scriptedRoute = .surface
        liveEngine.script([.loading, .playing])
        let detailEngine = FakePlaybackEngine()
        detailEngine.scriptedRoute = .avPlayer
        detailEngine.script([.loading, .playing])
        let live = ApplePlaybackCoordinator(engine: liveEngine, timeout: .seconds(60), wakeLock: lock)
        let detail = ApplePlaybackCoordinator(engine: detailEngine, timeout: .seconds(60), wakeLock: lock)
        await live.begin(makeRequest())
        await detail.begin(makeRequest(isLive: false))
        #expect(lock.holderCount == 2)

        live.stop()
        #expect(lock.holderCount == 1)
        #expect(assertion.isDisabled)

        detail.stop()
        #expect(lock.holderCount == 0)
        #expect(assertion.isDisabled == false)
    }

    /// A player that goes away without stopping first must not leave the
    /// television awake for the rest of the day.
    @Test func aDiscardedCoordinatorReleasesTheDisplay() async {
        let (lock, assertion) = makeLock()
        let engine = FakePlaybackEngine()
        engine.scriptedRoute = .surface
        engine.script([.loading, .playing])
        var coordinator: ApplePlaybackCoordinator? =
            ApplePlaybackCoordinator(engine: engine, timeout: .seconds(60), wakeLock: lock)
        await coordinator?.begin(makeRequest())
        #expect(lock.holderCount == 1)
        coordinator = nil
        await wakeWaitUntil { lock.holderCount == 0 }
        #expect(lock.holderCount == 0)
        #expect(assertion.isDisabled == false)
    }

    /// Guide previews and detail trailers drive the engine directly and never
    /// build a coordinator, so they cannot hold the display — they are muted
    /// background pictures and are meant to let the screen saver come up.
    @Test func drivingTheEngineWithoutACoordinatorHoldsNothing() async throws {
        let (lock, assertion) = makeLock()
        let engine = FakePlaybackEngine()
        engine.scriptedRoute = .surface
        engine.script([.loading, .playing])
        try await engine.load(makeRequest())
        engine.play()
        #expect(lock.holderCount == 0)
        #expect(assertion.applied.isEmpty)
        engine.stop()
    }
}

/// No wall-clock deadline: the parallel gate can hold the coordinator's tasks
/// up for seconds; the suite's time limit fails an outcome that never comes.
@MainActor
private func wakeWaitUntil(_ condition: @MainActor () -> Bool) async {
    while !condition(), !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(10))
    }
}
