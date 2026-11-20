import AetherEngine
import Foundation
import Testing
@testable import OpenStreamApple

struct AppleScrubSessionTests {
    private let start = ContinuousClock.now

    @Test func stepsMoveTheDestinationAndCommitAtMostOncePerInterval() {
        var session = AppleScrubSession()
        session.move(by: -10, from: 1000, in: 0...7200)
        #expect(session.destination == 990)
        #expect(session.nextCommit(now: start) == start)
        var committed = session.commit(now: start)
        #expect(committed == 990)
        for _ in 0..<5 { session.move(by: -10, from: 1000, in: 0...7200) }
        #expect(session.destination == 940)
        let next = start.advanced(by: AppleScrubSession.commitInterval)
        #expect(session.nextCommit(now: start.advanced(by: .milliseconds(100))) == next)
        committed = session.commit(now: next)
        #expect(committed == 940)
        committed = session.commit(now: start.advanced(by: .seconds(2)))
        #expect(committed == nil)
        let owed = session.end()
        #expect(owed == nil)
        #expect(!session.isActive)
    }

    @Test func liftCommitsOnlyAnUncommittedDestination() {
        var session = AppleScrubSession()
        session.move(by: 10, from: 7195, in: 0...7200)
        #expect(session.destination == 7200)
        let owed = session.end()
        #expect(owed == 7200)
        #expect(session.destination == nil)
        session.move(by: -10, from: 5, in: 0...7200)
        #expect(session.destination == 0)
    }
}

struct AppleStartupRestartWatchTests {
    /// Apple TV 2026-11-04: resume at 1569.57 s, producer restart to the
    /// segment at 1557.56 s, then playback moving forward from the resume
    /// point. The engine's watch never closed it; this one does.
    @Test func aResumeRestartLandsWhenThePictureMovesInTheRestartedRegion() {
        var watch = AppleStartupRestartWatch()
        watch.observe(id: 1, isNativeScrub: true, began: true, target: 1557.56, hasPresented: false)
        #expect(watch.restartID == 1)
        var landed = watch.observe(position: 1569.57, firstFrameReady: false, isPaused: false)
        #expect(!landed)
        landed = watch.observe(position: 1569.57, firstFrameReady: true, isPaused: false)
        #expect(!landed)
        #expect(!watch.overridesSeeking)
        landed = watch.observe(position: 1569.9, firstFrameReady: true, isPaused: false)
        #expect(landed)
        #expect(watch.overridesSeeking)
        watch.observe(id: 1, isNativeScrub: true, began: false, target: 1557.56, hasPresented: true)
        #expect(watch.restartID == 1)
        #expect(!watch.overridesSeeking)
    }

    @Test func aPausedStartLandsOnItsFirstFrame() {
        var watch = AppleStartupRestartWatch()
        watch.observe(id: 4, isNativeScrub: true, began: true, target: 600, hasPresented: false)
        let landed = watch.observe(position: 612, firstFrameReady: true, isPaused: true)
        #expect(landed)
    }

    @Test func aPictureBelowTheRestartedSegmentHasNotLanded() {
        var watch = AppleStartupRestartWatch()
        watch.observe(id: 1, isNativeScrub: true, began: true, target: 600, hasPresented: false)
        _ = watch.observe(position: 500, firstFrameReady: true, isPaused: false)
        let landed = watch.observe(position: 501, firstFrameReady: true, isPaused: false)
        #expect(!landed)
        #expect(!watch.overridesSeeking)
    }

    @Test func aRestartThatMovesOnBeforeTheFirstFrameIsFollowed() {
        var watch = AppleStartupRestartWatch()
        watch.observe(id: 1, isNativeScrub: true, began: true, target: 600, hasPresented: false)
        watch.observe(id: 2, isNativeScrub: true, began: true, target: 1200, hasPresented: false)
        #expect(watch.restartID == 2)
        var landed = watch.observe(position: 1210, firstFrameReady: true, isPaused: false)
        #expect(!landed)
        landed = watch.observe(position: 1211, firstFrameReady: true, isPaused: false)
        #expect(landed)
    }

    @Test func viewerSeeksAreNotTheStartupRestartAndEndIt() {
        var scrubbed = AppleStartupRestartWatch()
        scrubbed.observe(id: 1, isNativeScrub: true, began: true, target: 600, hasPresented: false)
        _ = scrubbed.observe(position: 610, firstFrameReady: true, isPaused: false)
        _ = scrubbed.observe(position: 611, firstFrameReady: true, isPaused: false)
        #expect(scrubbed.overridesSeeking)
        scrubbed.observe(id: 2, isNativeScrub: true, began: true, target: 300, hasPresented: true)
        #expect(scrubbed.restartID == 1)
        #expect(!scrubbed.overridesSeeking)

        var programmatic = AppleStartupRestartWatch()
        programmatic.observe(id: 1, isNativeScrub: true, began: true, target: 600, hasPresented: false)
        programmatic.observe(id: 2, isNativeScrub: false, began: true, target: 900, hasPresented: false)
        #expect(programmatic.restartID == 1)
        let programmaticLanded = programmatic.observe(position: 900, firstFrameReady: true, isPaused: true)
        #expect(!programmaticLanded)

        var viewer = AppleStartupRestartWatch()
        viewer.observe(id: 1, isNativeScrub: true, began: true, target: 600, hasPresented: false)
        viewer.viewerSeek()
        let viewerLanded = viewer.observe(position: 610, firstFrameReady: true, isPaused: true)
        #expect(!viewerLanded)
    }

    /// Apple TV 2026-11-04: Pause during the overridden restart left the app
    /// reporting playing, because the engine's phase stayed `.seeking`.
    @Test func theOverriddenPhaseFollowsTheTransport() {
        #expect(AetherPlaybackEngine.transportPhase(state: .paused, isBuffering: false) == .paused)
        #expect(AetherPlaybackEngine.transportPhase(state: .paused, isBuffering: true) == .paused)
        #expect(AetherPlaybackEngine.transportPhase(state: .playing, isBuffering: true) == .rebuffering)
        #expect(AetherPlaybackEngine.transportPhase(state: .playing, isBuffering: false) == .playing)
    }
}

struct AppleSeekTargetSupersedeTests {
    @Test func aSupersedingRequestReplacesTheSeekInFlight() throws {
        var policy = AppleSeekTargetPolicy()
        let started = policy.request(900)
        let first = try #require(started)
        let queued = policy.request(800)
        #expect(queued == nil)
        let replacing = policy.request(700, superseding: true)
        let second = try #require(replacing)
        #expect(second.target == 700)
        #expect(second != first)
        var followUp = policy.returned(first, now: .now)
        #expect(followUp == nil)
        #expect(policy.inFlight == second)
        let repeated = policy.request(700, superseding: true)
        #expect(repeated == nil)
        followUp = policy.returned(second, now: .now)
        #expect(followUp == nil)
        #expect(policy.inFlight == nil)
        #expect(policy.pending == 700)
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct AppleScrubCommitTests {
    private func request() -> ApplePlaybackRequest {
        ApplePlaybackRequest(url: URL(fileURLWithPath: "/fixtures/scrub.mp4"), mediaID: "scrub", sourceKind: .files)
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        try #require(condition())
    }

    /// Twenty ring steps while the first seek is still landing: one seek on
    /// the first step, one superseding commit to the newest destination at
    /// the cadence, nothing on lift, and a paused transport stays paused.
    @Test func aFastRingSpinCommitsTheNewestDestinationAndKeepsPause() async throws {
        let engine = FakePlaybackEngine()
        engine.scriptedPhases = [.playing]
        engine.duration = 7200
        engine.position = 1000
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        let clock = ManualClock()
        coordinator.clock = clock
        await coordinator.begin(request())
        let model = AppleTransportOverlayModel(coordinator: coordinator, isLive: false)
        coordinator.userPause()
        var landing: CheckedContinuation<Void, Never>?
        engine.seekHandler = { target in
            // The first seek is superseded and never lands.
            if engine.seeks.count == 1 { await withCheckedContinuation { landing = $0 }; return }
            engine.position = target
        }
        model.scrubStep(by: -10)
        try await waitFor { landing != nil }
        #expect(engine.seeks == [990])
        for index in 1..<20 { model.scrubStep(by: index % 5 < 3 ? -10 : 10) }
        #expect(model.scrubPosition == 990 - 30)
        #expect(engine.seeks == [990])
        clock.advance(by: AppleScrubSession.commitInterval)
        try await waitFor { engine.seeks.count == 2 }
        #expect(engine.seeks == [990, 960])
        model.endScrub()
        landing?.resume()
        try await waitFor {
            coordinator.seekPositionChanged(engine.position)
            return coordinator.pendingSeekTarget == nil
        }
        #expect(engine.position == 960)
        #expect(engine.seeks == [990, 960])
        #expect(engine.phase == .paused)
        coordinator.stop()
    }

    /// A seek that keeps buffering re-arms its deadline, but only until
    /// `seekRecoveryLimit`; then the player offers Retry at the target.
    @Test func aSeekThatNeverStopsBufferingEndsInRetryAtItsTarget() async throws {
        let engine = FakePlaybackEngine()
        engine.scriptedPhases = [.playing]
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        let clock = ManualClock()
        coordinator.clock = clock
        await coordinator.begin(request())
        var landing: CheckedContinuation<Void, Never>?
        engine.seekHandler = { _ in
            engine.phase = .rebuffering
            await withCheckedContinuation { landing = $0 }
        }
        let seek = Task { await coordinator.userSeek(to: 900) }
        try await waitFor { landing != nil }
        let windows = Int(ApplePlaybackCoordinator.seekRecoveryLimit / ApplePlaybackCoordinator.seekTimeout)
        for window in 1...windows {
            await clock.waitForSleep(until: ApplePlaybackCoordinator.seekTimeout * window)
            clock.advance(by: ApplePlaybackCoordinator.seekTimeout)
        }
        try await waitFor {
            if case .failed(let failure) = coordinator.phase { return failure.kind == .timedOut }
            return false
        }
        #expect(engine.stopCount >= 1)
        #expect(engine.seeks == [900])
        #expect(coordinator.currentRequest?.resumePosition == 900)
        landing?.resume()
        await seek.value
        engine.seekHandler = nil
        await coordinator.retry()
        #expect(engine.loadedRequests.last?.resumePosition == 900)
        coordinator.stop()
    }

    /// Clickpad presses about 270 ms apart (test Apple TV) are one scrub: the first
    /// press seeks, the rest move the destination, and the burst ends
    /// `pressBurstIdle` after the last press with one seek to where it ended.
    @Test func aRunOfClickpadPressesIsOneScrubThatEndsWhenThePressesStop() async throws {
        let engine = FakePlaybackEngine()
        engine.scriptedPhases = [.playing]
        engine.duration = 7200
        engine.position = 1000
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        let clock = ManualClock()
        coordinator.clock = clock
        await coordinator.begin(request())
        let model = AppleTransportOverlayModel(coordinator: coordinator, isLive: false)
        coordinator.userPause()
        engine.seekHandler = { target in engine.position = target }
        model.scrubPress(by: -10)
        try await waitFor { engine.seeks == [990] }
        for _ in 0..<4 { model.scrubPress(by: -10) }
        #expect(model.scrubPosition == 950)
        await clock.waitForSleep(until: AppleScrubSession.pressBurstIdle)
        clock.advance(by: AppleScrubSession.pressBurstIdle)
        try await waitFor { engine.seeks == [990, 950] }
        clock.advance(by: .seconds(1))
        try await waitFor {
            coordinator.seekPositionChanged(engine.position)
            return coordinator.pendingSeekTarget == nil
        }
        #expect(engine.seeks == [990, 950])
        // The session is over: the next press starts from the position.
        engine.position = 2000
        model.scrubPress(by: 10)
        #expect(model.scrubPosition == 2010)
        coordinator.stop()
    }

    /// Play pressed straight after the presses (the Apple TV test's pattern)
    /// seeks to where they ended and then plays.
    @Test func playRightAfterPressesSeeksThereAndPlays() async throws {
        let engine = FakePlaybackEngine()
        engine.scriptedPhases = [.playing]
        engine.duration = 7200
        engine.position = 1000
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        coordinator.clock = ManualClock()
        await coordinator.begin(request())
        let model = AppleTransportOverlayModel(coordinator: coordinator, isLive: false)
        coordinator.userPause()
        engine.emit(.phase(.paused))
        try await waitFor { coordinator.phase == .paused }
        engine.seekHandler = { target in engine.position = target }
        model.scrubPress(by: -10)
        try await waitFor { engine.seeks == [990] }
        for _ in 0..<3 { model.scrubPress(by: -10) }
        model.togglePlayPause()
        try await waitFor { engine.seeks == [990, 960] && engine.phase == .playing }
        coordinator.stop()
    }

    /// A new item (the engine's `.idle`) drops a scrub without seeking.
    @Test func aStopDropsTheScrubWithoutSeeking() async throws {
        let engine = FakePlaybackEngine()
        engine.scriptedPhases = [.playing]
        engine.duration = 7200
        engine.position = 1000
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        let clock = ManualClock()
        coordinator.clock = clock
        await coordinator.begin(request())
        let model = AppleTransportOverlayModel(coordinator: coordinator, isLive: false)
        var landing: CheckedContinuation<Void, Never>?
        engine.seekHandler = { _ in await withCheckedContinuation { landing = $0 } }
        model.scrubStep(by: -10)
        try await waitFor { landing != nil }
        model.scrubStep(by: -10)
        model.apply(.phase(.idle))
        model.endScrub()
        clock.advance(by: .seconds(1))
        landing?.resume()
        for _ in 0..<50 { await Task.yield() }
        #expect(engine.seeks == [990])
        coordinator.stop()
    }

    /// A superseded seek whose engine call ignores cancellation and returns
    /// after the newer one began does none of the post-seek work: no play,
    /// no follow-up seek, and the newer target stays pending.
    @Test func aSupersededSeekThatReturnsLateChangesNothing() async throws {
        let engine = FakePlaybackEngine()
        engine.scriptedPhases = [.playing]
        engine.duration = 7200
        engine.position = 1000
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        coordinator.clock = ManualClock()
        await coordinator.begin(request())
        var landings: [CheckedContinuation<Void, Never>] = []
        engine.seekHandler = { _ in
            engine.phase = .rebuffering
            await withCheckedContinuation { landings.append($0) }
        }
        let first = Task { await coordinator.userSeek(to: 900) }
        try await waitFor { landings.count == 1 }
        let second = Task { await coordinator.userSeek(to: 700, supersedingInFlight: true) }
        try await waitFor { landings.count == 2 }
        landings[0].resume()
        await first.value
        #expect(engine.phase == .rebuffering)
        #expect(engine.seeks == [900, 700])
        #expect(coordinator.pendingSeekTarget == 700)
        engine.position = 700
        landings[1].resume()
        await second.value
        #expect(engine.phase == .playing)
        #expect(engine.seeks == [900, 700])
        coordinator.stop()
    }

    /// A scrub that keeps committing while the stream buffers counts the
    /// recovery limit from its first seek, not from each newer commit.
    @Test func theRecoveryLimitCountsFromTheFirstSeekOfAScrub() async throws {
        let engine = FakePlaybackEngine()
        engine.scriptedPhases = [.playing]
        engine.duration = 7200
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        let clock = ManualClock()
        coordinator.clock = clock
        await coordinator.begin(request())
        var landings: [CheckedContinuation<Void, Never>] = []
        engine.seekHandler = { _ in
            engine.phase = .rebuffering
            await withCheckedContinuation { landings.append($0) }
        }
        let first = Task { await coordinator.userSeek(to: 900) }
        try await waitFor { landings.count == 1 }
        let timeout = ApplePlaybackCoordinator.seekTimeout
        for window in 1...4 {
            await clock.waitForSleep(until: timeout * window)
            clock.advance(by: timeout)
        }
        clock.advance(by: .seconds(2))
        let second = Task { await coordinator.userSeek(to: 700, supersedingInFlight: true) }
        try await waitFor { landings.count == 2 }
        // 50 s in: one more deadline passes the 60 s limit.
        await clock.waitForSleep(until: .seconds(50) + timeout)
        clock.advance(by: timeout)
        try await waitFor {
            if case .failed(let failure) = coordinator.phase { return failure.kind == .timedOut }
            return false
        }
        #expect(coordinator.currentRequest?.resumePosition == 700)
        landings.forEach { $0.resume() }
        await first.value
        await second.value
        engine.seekHandler = nil
        coordinator.stop()
    }
}

/// Apple TV 2026-11-04: AVFoundation -11819 on a resume at 1649 s, the engine
/// rebuilt at 0 and the progress writer saved `pos=0` over the resume point.
@MainActor
struct AppleResumePointProtectionTests {
    @Test func aZeroAfterAResumeDoesNotReplaceTheSavedPosition() {
        #expect(ApplePlaybackProgressCoordinator.keepsResumePoint(position: 0, resumedFrom: 1649))
        #expect(ApplePlaybackProgressCoordinator.keepsResumePoint(position: 0.4, resumedFrom: 1649))
        #expect(!ApplePlaybackProgressCoordinator.keepsResumePoint(position: 12, resumedFrom: 1649))
        #expect(!ApplePlaybackProgressCoordinator.keepsResumePoint(position: 0, resumedFrom: nil))
        #expect(!ApplePlaybackProgressCoordinator.keepsResumePoint(position: 0, resumedFrom: 0))
    }

    @Test func theProgressWriterSkipsAFailuresZero() {
        let coordinator = ApplePlaybackProgressCoordinator(
            store: ApplePlaybackStore(defaults: UserDefaults(suiteName: "resume-point-\(UUID())")!),
            mediaIdentity: "resume-point")
        var writes: [Double] = []
        coordinator.writer = { position, _ in writes.append(position) }
        coordinator.resumedFrom = 1649
        coordinator.record(position: 1650, duration: 7784, isPlaying: true)
        coordinator.record(position: 0, duration: 7784, isPlaying: true)
        coordinator.record(position: 1660, duration: 7784, isPlaying: true)
        #expect(writes == [1650, 1660])

        coordinator.resumedFrom = nil
        coordinator.record(position: 0, duration: 7784, isPlaying: true)
        #expect(writes == [1650, 1660, 0])
    }

    /// The software route's periodic writer holds the resume point too.
    @Test func theSurfaceWriterSkipsAFailuresZero() async throws {
        let engine = FakePlaybackEngine()
        engine.scriptedRoute = .surface
        engine.scriptedPhases = [.playing]
        engine.duration = 7784
        engine.position = 1649
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        let clock = ManualClock()
        coordinator.clock = clock
        var writes: [Double] = []
        coordinator.progressWriter = { position, _ in writes.append(position) }
        var request = ApplePlaybackRequest(url: URL(fileURLWithPath: "/fixtures/resume.mkv"),
                                           mediaID: "resume", sourceKind: .files)
        request.resumePosition = 1649
        await coordinator.begin(request)
        #expect(coordinator.resumedFrom == 1649)
        engine.position = 0
        // Past the write interval, so only the guard can hold the zero back.
        clock.advance(by: .seconds(60))
        engine.emit(.position(0))
        for _ in 0..<20 { await Task.yield() }
        #expect(!writes.contains(0))
        engine.position = 1652
        coordinator.saveProgressNow()
        #expect(writes.last == 1652)
        coordinator.stop()
    }
}
