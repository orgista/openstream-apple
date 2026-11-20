import Foundation
import Testing
@testable import OpenStreamApple

@MainActor
@Suite(.serialized) struct AppleLiveInitialPlaybackTests {
    private func request(isLive: Bool = true, autoplay: Bool = true, mediaID: String = "initial-live") -> ApplePlaybackRequest {
        ApplePlaybackRequest(url: URL(string: "https://fixture.example/live.m3u8")!,
            isLive: isLive, autoplay: autoplay, mediaID: mediaID, sourceKind: .liveTV)
    }

    @Test func aNewChannelJoinsThePublishedEdgeWithoutALivePress() async {
        let engine = FakePlaybackEngine()
        engine.script([.loading])
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        defer { coordinator.stop() }
        await coordinator.begin(request())
        #expect(engine.seeks.isEmpty)
        engine.seekableRange = AppleSeekableRange(start: 120, end: 180)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while engine.seeks.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(engine.seeks == [179])
        #expect(engine.phase == .playing)
        engine.seekableRange = AppleSeekableRange(start: 122, end: 182)
        engine.emit(.position(180))
        #expect(engine.seeks == [179])
    }

    @Test func aUserPauseCancelsThePendingJoin() async throws {
        let engine = FakePlaybackEngine()
        engine.script([.loading])
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        defer { coordinator.stop() }
        await coordinator.begin(request())
        let pending = try #require(coordinator.initialLiveSeekTask)
        coordinator.userPause()
        engine.seekableRange = AppleSeekableRange(start: 120, end: 180)
        await pending.value
        #expect(engine.seeks.isEmpty)
        #expect(engine.phase == .paused)
    }

    @Test(arguments: [false, true]) func pausedAndOnDemandLoadsKeepTheirStart(isLive: Bool) async {
        let engine = FakePlaybackEngine()
        engine.seekableRange = AppleSeekableRange(start: 120, end: 180)
        engine.script([.paused])
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        defer { coordinator.stop() }
        await coordinator.begin(request(isLive: isLive, autoplay: !isLive))
        #expect(engine.seeks.isEmpty)
        #expect(coordinator.phase == .paused)
    }

    @Test func initialTargetWaitsForAUsableWindow() {
        #expect(ApplePlaybackStartPolicy.initialLiveSeekTarget(in: nil) == nil)
        #expect(ApplePlaybackStartPolicy.initialLiveSeekTarget(in: .init(start: 0, end: 0)) == nil)
        #expect(ApplePlaybackStartPolicy.initialLiveSeekTarget(in: .init(start: -1800, end: 0)) == nil)
        #expect(ApplePlaybackStartPolicy.initialLiveSeekTarget(in: .init(start: 50, end: 50.75)) == 50)
        #expect(ApplePlaybackStartPolicy.initialLiveSeekTarget(in: .init(start: 120, end: 180)) == 179)
    }

    @Test(arguments: [ApplePlaybackFailure.Kind.player, .timedOut, .network, .authentication, .unsupportedMedia])
    func onlyUnopenedPlayerDeadlinesBecomeNetworkFailures(kind: ApplePlaybackFailure.Kind) {
        let failure = ApplePlaybackFailure(kind: kind, message: "fixture diagnosis")
        #expect(ApplePlaybackStartPolicy.liveFailureAtDeadline(failure, sourceOpened: true) == failure)
        let unopened = ApplePlaybackStartPolicy.liveFailureAtDeadline(failure, sourceOpened: false)
        if kind == .player || kind == .timedOut {
            #expect(unopened.kind == .network)
            #expect(unopened.networkCode == .timedOut)
        } else {
            #expect(unopened == failure)
        }
    }

    @Test func aSilentOriginFailsAtTheDeadlineEvenWhenItsLoadIgnoresCancellation() async {
        let engine = FakePlaybackEngine()
        var finish: CheckedContinuation<Void, Never>?
        engine.loadHandler = { _ in
            engine.phase = .loading
            await withCheckedContinuation { finish = $0 }
        }
        let clock = ManualClock()
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        coordinator.clock = clock
        let loading = Task { await coordinator.begin(request()) }
        await clock.waitForSleep(until: .seconds(10))
        while finish == nil { await Task.yield() }
        clock.advance(to: .seconds(10))
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while coordinator.phase.isBusy, ContinuousClock.now < deadline { await Task.yield() }
        if case .failed(let failure) = coordinator.phase {
            #expect(failure.kind == .network)
        } else { Issue.record("The silent origin never reached a terminal failure") }
        #expect(engine.loadedRequests.count == 1)
        finish?.resume()
        await loading.value
        #expect(!coordinator.phase.isBusy)
        coordinator.stop()
    }

    @Test func aLateEngineFailureDoesNotRestartTheStartupWait() async {
        let engine = FakePlaybackEngine()
        engine.scriptedRoute = .surface
        engine.script([.loading])
        let clock = ManualClock()
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        coordinator.clock = clock
        defer { coordinator.stop() }
        await coordinator.begin(request())
        await clock.waitForSleep(until: .seconds(10))
        clock.advance(to: .seconds(10))
        await clock.waitForSleep(until: .seconds(25))
        clock.advance(to: .seconds(20))
        engine.emit(.failure(.init(kind: .player, message: "resource unavailable")))
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while coordinator.phase.isBusy, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        if case .failed(let failure) = coordinator.phase {
            #expect(failure.kind == .player)
            #expect(AppleLiveFailureCause.playback(failure, channelName: "Fixture", sourceName: nil)
                == .notBroadcasting(channel: "Fixture"))
        } else { Issue.record("A late engine failure restarted the startup spinner") }
        #expect(engine.loadedRequests.count == 1)
    }

    @Test(arguments: [false, true])
    func switchingAfterAFailureGetsANewDeadlineAndKeepsTheNewLoad(withFallbacks: Bool) async throws {
        let engine = FakePlaybackEngine()
        var loads: [CheckedContinuation<Void, Never>] = []
        var cancelledLoads: [Bool] = []
        engine.loadHandler = { _ in
            engine.phase = .loading
            await withCheckedContinuation { loads.append($0) }
            cancelledLoads.append(Task.isCancelled)
        }
        let clock = ManualClock()
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        coordinator.clock = clock
        defer { coordinator.stop() }
        let first = Task { await coordinator.begin(request(mediaID: "channel-a")) }
        await clock.waitForSleep(until: .seconds(10))
        await waitFor("the first channel's load") { loads.count == 1 }
        clock.advance(to: .seconds(10))
        await waitFor("the first channel's failure") { !coordinator.phase.isBusy }
        guard case .failed = coordinator.phase else {
            loads.first?.resume()
            await first.value
            Issue.record("The first channel did not fail")
            return
        }
        let second = Task {
            if withFallbacks {
                await coordinator.begin(request(mediaID: "channel-b"), fallbackCandidates: [])
            } else {
                await coordinator.begin(request(mediaID: "channel-b"))
            }
        }
        await clock.waitForSleep(until: .seconds(20))
        await waitFor("the second channel's load") { loads.count == 2 }
        try #require(loads.count == 2)
        loads[0].resume()
        await first.value
        clock.advance(to: .seconds(19))
        #expect(coordinator.phase.isBusy)
        clock.advance(to: .seconds(20))
        await waitFor("the second channel's own deadline") { !coordinator.phase.isBusy }
        if case .failed(let failure) = coordinator.phase {
            #expect(failure.kind == .network)
        } else { Issue.record("The old load cleared the newer channel's watchdog") }
        loads[1].resume()
        await second.value
        #expect(cancelledLoads == [true, true])
    }

    @Test func anAVPlayerLoadThatReturnsBeforeOpenStillUsesTheUnreachableDeadline() async {
        let engine = FakePlaybackEngine()
        engine.script([.loading])
        let clock = ManualClock()
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        coordinator.clock = clock
        defer { coordinator.stop() }
        await coordinator.begin(request())
        await clock.waitForSleep(until: .seconds(10))
        clock.advance(to: .seconds(10))
        await waitFor("the unopened AVPlayer deadline") { !coordinator.phase.isBusy }
        if case .failed(let failure) = coordinator.phase {
            #expect(failure.kind == .network)
        } else { Issue.record("Returning from load incorrectly granted an opened-stream extension") }
    }

    @Test func anOpenedChannelThatNeverPlaysIsNotAnUnreachableServer() async {
        let engine = FakePlaybackEngine()
        engine.scriptedRoute = .surface
        engine.script([.loading])
        let clock = ManualClock()
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        coordinator.clock = clock
        defer { coordinator.stop() }
        await coordinator.begin(request())
        await clock.waitForSleep(until: .seconds(10))
        clock.advance(to: .seconds(10))
        await clock.waitForSleep(until: .seconds(25))
        clock.advance(to: .seconds(25))
        await waitFor("the opened channel's deadline") { !coordinator.phase.isBusy }
        if case .failed(let failure) = coordinator.phase {
            #expect(failure.kind == .timedOut)
            #expect(AppleLiveFailureCause.playback(failure, channelName: "Fixture", sourceName: nil)
                == .notBroadcasting(channel: "Fixture"))
        } else { Issue.record("The opened channel never reached a terminal failure") }
    }

    @Test func anEarlyReopenKeepsTheOriginalStartupDeadline() async {
        let engine = FakePlaybackEngine()
        engine.script([.loading])
        let clock = ManualClock()
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        coordinator.clock = clock
        defer { coordinator.stop() }
        await coordinator.begin(request())
        await clock.waitForSleep(until: .seconds(10))
        clock.advance(to: .seconds(8))
        engine.emit(.failure(.init(kind: .network, message: "connection lost")))
        await clock.waitForSleep(until: .seconds(9))
        clock.advance(to: .seconds(9))
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while engine.loadedRequests.count < 2, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(engine.loadedRequests.count == 2)
        #expect(clock.pendingDeadlines.contains(.seconds(10)))
        #expect(!clock.pendingDeadlines.contains(.seconds(19)))
    }
}
