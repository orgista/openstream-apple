import Foundation
import AVFoundation
import Synchronization
import Testing
@testable import OpenStreamApple

@Suite struct AppleLiveEdgeFollowTests {
    private let window = AppleSeekableRange(start: 100, end: 180)

    @Test func sustainedDriftCatchesUpButSegmentJitterDoesNot() {
        var policy = AppleLiveEdgeFollowPolicy()
        let start = ContinuousClock.now
        #expect(policy.target(position: 165, range: window, isPlaying: true, holdBack: 1, now: start) == nil)
        #expect(policy.target(position: 176, range: window, isPlaying: true, holdBack: 1, now: start + .seconds(4)) == nil)
        #expect(policy.target(position: 160, range: window, isPlaying: true, holdBack: 1, now: start + .seconds(5)) == nil)
        #expect(policy.target(position: 160, range: window, isPlaying: true, holdBack: 1, now: start + .seconds(10)) == 179)
        #expect(policy.target(position: 160, range: window, isPlaying: true, holdBack: 1, now: start + .seconds(11)) == nil)
        #expect(policy.target(position: 160, range: window, isPlaying: true, holdBack: 1, now: start + .seconds(16)) == nil)
        #expect(policy.target(position: 160, range: window, isPlaying: true, holdBack: 1, now: start + .seconds(20)) == nil)
    }

    @Test func userPauseAndRewindStayBehindUntilLiveIsChosen() {
        var policy = AppleLiveEdgeFollowPolicy()
        let start = ContinuousClock.now
        policy.suspend()
        #expect(policy.target(position: 130, range: window, isPlaying: true, holdBack: 1, now: start) == nil)
        #expect(policy.target(position: 130, range: window, isPlaying: true, holdBack: 1, now: start + .seconds(30)) == nil)
        policy.seek(to: 179, range: window, holdBack: 1)
        #expect(policy.target(position: 160, range: window, isPlaying: true, holdBack: 1, now: start + .seconds(31)) == nil)
        #expect(policy.target(position: 160, range: window, isPlaying: true, holdBack: 1, now: start + .seconds(36)) == 179)
        policy.seek(to: 130, range: window, holdBack: 1)
        #expect(policy.target(position: 130, range: window, isPlaying: true, holdBack: 1, now: start + .seconds(60)) == nil)
    }

    @Test func bufferingAndMissingWindowsCannotTriggerASeek() {
        var policy = AppleLiveEdgeFollowPolicy()
        let start = ContinuousClock.now
        #expect(policy.target(position: 130, range: window, isPlaying: false, holdBack: 1, now: start) == nil)
        #expect(policy.target(position: 130, range: nil, isPlaying: true, holdBack: 1, now: start + .seconds(20)) == nil)
        #expect(policy.target(position: .nan, range: window, isPlaying: true, holdBack: 1, now: start + .seconds(30)) == nil)
        #expect(policy.target(position: 130, range: window, isPlaying: true, holdBack: 1, now: start + .seconds(40)) == nil)
    }

    @Test func aLiveClockThatClaimsToPlayButStandsStillNeedsRecovery() {
        #expect(!NativePlaybackEngine.liveClockIsStalled(isLive: true, isPlaying: true, secondsStill: 3, bufferEmpty: true, likelyToKeepUp: false))
        #expect(NativePlaybackEngine.liveClockIsStalled(isLive: true, isPlaying: true, secondsStill: 4, bufferEmpty: true, likelyToKeepUp: false))
        #expect(NativePlaybackEngine.liveClockIsStalled(isLive: true, isPlaying: true, secondsStill: 4, bufferEmpty: false, likelyToKeepUp: false))
        #expect(!NativePlaybackEngine.liveClockIsStalled(isLive: true, isPlaying: true, secondsStill: 30, bufferEmpty: false, likelyToKeepUp: true))
        #expect(!NativePlaybackEngine.liveClockIsStalled(isLive: true, isPlaying: false, secondsStill: 30, bufferEmpty: true, likelyToKeepUp: false))
        #expect(!NativePlaybackEngine.liveClockIsStalled(isLive: false, isPlaying: true, secondsStill: 30, bufferEmpty: true, likelyToKeepUp: false))
    }

    @Test func liveTargetsWorkForShortAndNegativeWindows() {
        #expect(AppleLiveSeekPolicy.liveTarget(in: .init(start: 100, end: 112)) == 111)
        #expect(AppleLiveSeekPolicy.liveTarget(in: .init(start: -60, end: 0)) == -1)
        #expect(AppleLiveSeekPolicy.liveTarget(in: .init(start: 0, end: 0)) == nil)
        #expect(AppleLiveSeekPolicy.liveTarget(in: nil) == nil)
    }

    @Test(arguments: [18.0, 30.0]) func normalHoldBackDoesNotBecomeDrift(holdBack: Double) {
        var policy = AppleLiveEdgeFollowPolicy()
        let start = ContinuousClock.now
        for seconds in stride(from: 0, through: 600, by: 5) {
            #expect(policy.target(position: 180 - holdBack, range: window, isPlaying: true,
                holdBack: holdBack, now: start + .seconds(seconds)) == nil)
        }
        #expect(AppleLiveSeekPolicy.liveTarget(in: window, holdBack: holdBack) == 180 - holdBack)
        #expect(AppleLiveSeekPolicy.isAtLiveEdge(position: 180 - holdBack, in: window,
            tolerance: AppleLiveSeekPolicy.edgeTolerance(holdBack: holdBack)))
    }

    @Test func unknownHoldBackNeverChasesMeasuredLag() {
        var policy = AppleLiveEdgeFollowPolicy()
        let start = ContinuousClock.now
        for seconds in [0, 10, 30, 120] {
            #expect(policy.target(position: 130, range: window, isPlaying: true,
                holdBack: nil, now: start + .seconds(seconds)) == nil)
        }
    }

    @Test func aCorrectionThatBuffersCannotLoop() {
        var policy = AppleLiveEdgeFollowPolicy()
        let start = ContinuousClock.now
        #expect(policy.target(position: 130, range: window, isPlaying: true, holdBack: 18, now: start) == nil)
        #expect(policy.target(position: 130, range: window, isPlaying: true, holdBack: 18, now: start + .seconds(5)) == 162)
        #expect(policy.target(position: 130, range: window, isPlaying: false, holdBack: 18, now: start + .seconds(6)) == nil)
        for seconds in [20, 40, 60, 120] {
            #expect(policy.target(position: 130, range: window, isPlaying: true,
                holdBack: 18, now: start + .seconds(seconds)) == nil)
        }
    }
}

@MainActor
@Suite(.serialized) struct AppleLiveReturnToEdgeTests {
    private func request() -> ApplePlaybackRequest {
        ApplePlaybackRequest(url: URL(string: "https://fixture.example/live.m3u8")!,
            isLive: true, autoplay: false, mediaID: "wiring", sourceKind: .liveTV)
    }

    private func position(_ value: Double, engine: FakePlaybackEngine, coordinator: ApplePlaybackCoordinator) async {
        engine.position = value
        engine.emit(.position(value))
        await waitFor("coordinator position event", limit: .seconds(2)) { coordinator.lastKnownPosition == value }
    }

    @Test func positionEventsCorrectDriftAndNewLoadsRearmAfterUserPause() async throws {
        let engine = FakePlaybackEngine()
        engine.liveEdgeOffset = 18
        engine.seekableRange = .init(start: 100, end: 180)
        engine.script([.playing])
        let clock = ManualClock()
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        coordinator.clock = clock
        defer { coordinator.stop() }
        await coordinator.begin(request())
        await position(130, engine: engine, coordinator: coordinator)
        #expect(engine.seeks.isEmpty)
        clock.advance(by: .seconds(5))
        await position(131, engine: engine, coordinator: coordinator)
        await coordinator.liveEdgeCorrectionTask?.value
        #expect(engine.seeks == [162])

        coordinator.userPause()
        coordinator.userPlay()
        coordinator.update(.playing)
        clock.advance(by: .seconds(20))
        await position(132, engine: engine, coordinator: coordinator)
        clock.advance(by: .seconds(5))
        await position(133, engine: engine, coordinator: coordinator)
        #expect(engine.seeks == [162])

        await coordinator.begin(request())
        await position(134, engine: engine, coordinator: coordinator)
        clock.advance(by: .seconds(5))
        await position(135, engine: engine, coordinator: coordinator)
        await coordinator.liveEdgeCorrectionTask?.value
        #expect(engine.seeks == [162, 162])
        #expect(engine.loadedRequests.count == 2)
    }

    @Test(arguments: [false, true]) func onlyAPauseAfterPlaybackSuspendsFollowing(hasPlayed: Bool) async {
        let engine = FakePlaybackEngine()
        engine.liveEdgeOffset = 18
        engine.seekableRange = .init(start: 100, end: 180)
        let clock = ManualClock()
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        coordinator.clock = clock
        defer { coordinator.stop() }
        await coordinator.begin(request())
        // Emitted after `begin` so they reach the coordinator's event stream.
        for phase: ApplePlaybackEnginePhase in (hasPlayed ? [.playing, .paused, .playing] : [.paused, .playing]) {
            engine.phase = phase
            engine.emit(.phase(phase))
        }
        await position(130, engine: engine, coordinator: coordinator)
        clock.advance(by: .seconds(5))
        await position(131, engine: engine, coordinator: coordinator)
        await coordinator.liveEdgeCorrectionTask?.value
        #expect(engine.seeks == (hasPlayed ? [] : [162]))
    }

    @Test func aHungRetirementTimesOutAndDoesNotBlockTheNextLoad() async throws {
        let engine = NativePlaybackEngine()
        let (blocked, release) = AsyncStream<Void>.makeStream()
        engine.retire { for await _ in blocked {} }
        let retirement = try #require(engine.retirementTask)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        try Data().write(to: file)
        defer { release.finish(); engine.stop(); try? FileManager.default.removeItem(at: file) }
        let started = ContinuousClock.now
        try await engine.load(ApplePlaybackRequest(url: file, autoplay: false, mediaID: "timeout", sourceKind: .files))
        await retirement.value
        #expect(started.duration(to: .now) < .seconds(3))
        #expect(engine.retirementTask == nil)
        #expect(engine.avPlayer != nil)
    }

    @Test(arguments: [nil, AppleSeekableRange(start: 100, end: 100.25), AppleSeekableRange(start: 100, end: 112)])
    func playingAtTheEdgeDoesNotSeekOrReload(range: AppleSeekableRange?) async {
        let engine = FakePlaybackEngine()
        engine.script([.playing])
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        defer { coordinator.stop() }
        await coordinator.begin(ApplePlaybackRequest(url: URL(string: "https://fixture.example/live.m3u8")!,
            isLive: true, mediaID: "edge", sourceKind: .liveTV))
        coordinator.userPause()
        engine.seekableRange = range
        engine.position = range?.end ?? 0
        coordinator.userPlay()
        coordinator.update(.playing)
        await coordinator.userReturnToLive()
        #expect(engine.loadedRequests.count == 1)
        #expect(engine.seeks.isEmpty)
        #expect(engine.phase == .playing)
    }

    @Test func liveWithoutASeekableWindowReopensAndResumes() async {
        let engine = FakePlaybackEngine()
        engine.script([.loading, .playing])
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        let request = ApplePlaybackRequest(url: URL(string: "https://fixture.example/live.m3u8")!,
            isLive: true, mediaID: "no-window", sourceKind: .liveTV)
        await coordinator.begin(request)
        coordinator.userPause()
        await coordinator.userReturnToLive()
        #expect(engine.loadedRequests.count == 2)
        #expect(engine.loadedRequests.last?.autoplay == true)
        #expect(engine.phase == .playing)
        coordinator.stop()
    }

    @Test func stoppingUnbindsBeforeRetiringTheOldPlayer() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let engine = NativePlaybackEngine()
        try await engine.load(ApplePlaybackRequest(url: file, autoplay: false, mediaID: "retirement", sourceKind: .files))
        let player = try #require(engine.avPlayer)
        let replacementOnMain = Mutex<Bool?>(nil)
        let observation = player.observe(\.currentItem) { _, _ in
            replacementOnMain.withLock { $0 = Thread.isMainThread }
        }
        defer { observation.invalidate() }
        engine.stop()
        #expect(engine.avPlayer == nil)
        #expect(engine.phase == .idle)
        #expect(engine.route == .none)
        let retirement = try #require(engine.retirementTask)
        await retirement.value
        #expect(engine.retirementTask == nil)
        #expect(player.currentItem == nil)
        #expect(replacementOnMain.withLock { $0 } == true)
    }

    @Test func oneLivePressSeeksAndResumesAPausedShortWindow() async {
        let engine = FakePlaybackEngine()
        engine.seekableRange = AppleSeekableRange(start: 100, end: 112)
        engine.position = 101
        engine.phase = .paused
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        let model = AppleTransportOverlayModel(coordinator: coordinator, isLive: true)
        #expect(!model.isScrubbable)
        #expect(!model.isAtLiveEdge)
        engine.position = 111
        coordinator.update(.paused)
        #expect(!model.isAtLiveEdge)
        await model.seekToLiveEdge()
        #expect(engine.seeks == [111])
        #expect(engine.phase == .playing)
        coordinator.stop()
    }

    @Test func leavingWhileALiveSeekLandsDoesNotRestartPlayback() async {
        let engine = FakePlaybackEngine()
        engine.seekableRange = AppleSeekableRange(start: 100, end: 180)
        engine.phase = .paused
        var landing: CheckedContinuation<Void, Never>?
        engine.seekHandler = { _ in await withCheckedContinuation { landing = $0 } }
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        let returning = Task { await coordinator.userReturnToLive() }
        let deadline = ContinuousClock.now + .seconds(2)
        while landing == nil, ContinuousClock.now < deadline { await Task.yield() }
        #expect(landing != nil)
        coordinator.stop()
        landing?.resume()
        await returning.value
        #expect(engine.phase == .idle)
    }
}
