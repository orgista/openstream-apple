import Foundation
import AetherEngine
import AVFoundation
import Combine
import Testing
@testable import OpenStreamApple

@MainActor
@Suite(.timeLimit(.minutes(1))) struct AppleSeekRecoveryTests {
    private func request(_ name: String = "first") -> ApplePlaybackRequest {
        ApplePlaybackRequest(url: URL(fileURLWithPath: "/fixtures/\(name).mp4"),
                             mediaID: name, sourceKind: .files)
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        try #require(condition())
    }

    @Test func hundredsOfJogReversalsCoalesceAndPreserveTheLastTarget() async throws {
        let engine = FakePlaybackEngine()
        engine.duration = 7200
        engine.position = 100
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        let model = AppleTransportOverlayModel(coordinator: coordinator, isLive: false)
        var landing: CheckedContinuation<Void, Never>?
        engine.seekHandler = { target in
            if engine.seeks.count == 1 { await withCheckedContinuation { landing = $0 } }
            engine.position = target
        }
        let first = Task { await coordinator.userSeek(to: 900) }
        try await waitFor { landing != nil }
        for index in 0..<800 {
            await model.scrub(by: index % 2 == 0 ? 0.0001 : -0.0001)
        }
        await coordinator.userSeek(to: 101)
        coordinator.seekPositionChanged(100)
        #expect(engine.seeks == [900])
        #expect(coordinator.pendingSeekTarget == 101)
        landing?.resume()
        await first.value
        #expect(engine.seeks == [900, 101])
        #expect(engine.position == 101)
        coordinator.stop()
    }

    @Test(arguments: [false, true])
    func relativeInputsKeepAddingWhenTheSampledPositionLags(_ fractional: Bool) async {
        let engine = FakePlaybackEngine()
        engine.duration = 10_000
        engine.position = 100
        engine.scriptedPresentationTime = 100
        engine.seekHandler = { engine.scriptedPresentationTime = $0 }
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        let model = AppleTransportOverlayModel(coordinator: coordinator, isLive: false)
        for _ in 0..<200 {
            if fractional { await model.scrub(by: 0.001) }
            else { await model.skip(by: 10) }
        }
        #expect(abs((engine.seeks.last ?? 0) - 2100) < 0.001)
        #expect(engine.seeks.count == 200)
        #expect(coordinator.pendingSeekTarget == nil)
        coordinator.stop()
    }

    @Test func resetDuringASeekClearsTheQueueAndTheNextTitlePlays() async throws {
        let engine = FakePlaybackEngine()
        engine.scriptedPhases = [.playing]
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        await coordinator.begin(request())
        var landing: CheckedContinuation<Void, Never>?
        engine.seekHandler = { _ in await withCheckedContinuation { landing = $0 } }
        let first = Task { await coordinator.userSeek(to: 900) }
        try await waitFor { landing != nil }
        await coordinator.userSeek(to: 1200)
        let stops = engine.stopCount
        coordinator.reset()
        #expect(coordinator.pendingSeekTarget == nil)
        #expect(coordinator.route == .none)
        #expect(engine.stopCount > stops)
        engine.seekHandler = nil
        await coordinator.begin(request("second"))
        landing?.resume()
        await first.value
        #expect(engine.seeks == [900])
        #expect(coordinator.phase == .playing)
        #expect(coordinator.currentRequest?.mediaID == "second")
        coordinator.stop()
    }

    @Test func alertResetKeepsRetryAvailableWithoutKeepingAnActiveRequest() async {
        let engine = FakePlaybackEngine()
        engine.scriptedPhases = [.playing]
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        await coordinator.begin(request())
        coordinator.reset()
        #expect(coordinator.currentRequest == nil)
        #expect(coordinator.route == .none)
        engine.scriptedRoute = .none
        await coordinator.userSeek(to: 900)
        #expect(engine.seeks.isEmpty)
        engine.scriptedRoute = .avPlayer
        await coordinator.retry()
        #expect(engine.loadedRequests.count == 2)
        #expect(coordinator.currentRequest?.mediaID == "first")
        #expect(coordinator.phase == .playing)
        coordinator.stop()
        await coordinator.retry()
        #expect(engine.loadedRequests.count == 2)
    }

    @Test(arguments: [false, true])
    func alertResetRetainsTheSMBLeaseForRetryAndReleasesItOnExit(_ differentTitle: Bool) async throws {
        let server = AppleSMBRangeServer.shared
        let originalCount = await server.diagnostics().sessionCount
        let url = try await server.playbackURL(
            sourceURL: #require(URL(string: "smb://fixture.invalid/Media/retry.mp4")),
            credentials: .init(username: "fixture", password: "fixture"), sizeBytes: 1_024)
        let engine = FakePlaybackEngine()
        engine.scriptedPhases = [.playing]
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        defer { coordinator.stop() }
        await coordinator.begin(.init(url: url, mediaID: "share", sourceKind: .networkShare))
        coordinator.reset()
        await coordinator.retry()
        #expect(engine.loadedRequests.last?.url == url)
        #expect(await server.diagnostics().sessionCount == originalCount + 1)
        coordinator.reset()
        if differentTitle { await coordinator.begin(request("second")) }
        else { coordinator.stop() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await server.diagnostics().sessionCount > originalCount, ContinuousClock.now < deadline {
            await Task.yield()
        }
        #expect(await server.diagnostics().sessionCount == originalCount)
    }

    @Test func requestsDuringLoadWaitForTheNewEngineAndKeepOnlyTheLatest() async throws {
        let engine = FakePlaybackEngine()
        engine.duration = 7200
        var loaded: CheckedContinuation<Void, Never>?
        engine.loadHandler = { _ in
            await withCheckedContinuation { loaded = $0 }
            engine.phase = .playing
        }
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        let load = Task { await coordinator.begin(request()) }
        try await waitFor { loaded != nil }
        for index in 0..<600 { await coordinator.userSeek(to: Double(index)) }
        #expect(engine.seeks.isEmpty)
        #expect(coordinator.pendingSeekTarget == 599)
        loaded?.resume()
        await load.value
        #expect(engine.seeks == [599])
        coordinator.stop()
    }

    @Test func aFailedLoadDoesNotDeferEveryLaterSeek() async {
        let engine = FakePlaybackEngine()
        engine.failOnLoad = .init(kind: .unavailable, message: "Unavailable.")
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        await coordinator.begin(request())
        await coordinator.userSeek(to: 42)
        #expect(engine.seeks == [42])
        coordinator.stop()
    }

    @Test func failureDuringLoadCannotKeepTheOldLoadAlive() async throws {
        let engine = FakePlaybackEngine()
        var loading: CheckedContinuation<Void, Never>?
        engine.loadHandler = { _ in await withCheckedContinuation { loading = $0 } }
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        let load = Task { await coordinator.begin(request()) }
        try await waitFor { loading != nil }
        coordinator.fail(ApplePlaybackFailure(kind: .unavailable, message: "Unavailable."))
        await coordinator.userSeek(to: 42)
        #expect(engine.seeks == [42])
        loading?.resume()
        await load.value
        guard case .failed = coordinator.phase else { Issue.record("A failed load resumed playback"); return }
        coordinator.stop()
    }

    @Test func aCancelledLoadDoesNotStrandLaterSeeks() async throws {
        let engine = FakePlaybackEngine()
        var loading: CheckedContinuation<Void, Never>?
        engine.loadHandler = { _ in
            await withCheckedContinuation { loading = $0 }
            try Task.checkCancellation()
        }
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        let load = Task { await coordinator.begin(request()) }
        try await waitFor { loading != nil }
        load.cancel()
        loading?.resume()
        await load.value
        await coordinator.userSeek(to: 42)
        #expect(engine.seeks == [42])
        coordinator.stop()
    }

    @Test func anOldLoadExitCannotClearTheReplacementLoad() async throws {
        let engine = FakePlaybackEngine()
        var first: CheckedContinuation<Void, Never>?
        var second: CheckedContinuation<Void, Never>?
        engine.loadHandler = { request in
            await withCheckedContinuation {
                if request.mediaID == "first" { first = $0 } else { second = $0 }
            }
        }
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        let old = Task { await coordinator.begin(request()) }
        try await waitFor { first != nil }
        let replacement = Task { await coordinator.begin(request("second")) }
        try await waitFor { second != nil }
        first?.resume()
        await old.value
        await coordinator.userSeek(to: 42)
        #expect(engine.seeks.isEmpty)
        second?.resume()
        await replacement.value
        #expect(engine.seeks == [42])
        coordinator.stop()
    }

    @Test func backgroundNativeSeekEventsAreDeliveredOnTheMainActor() async throws {
        let engine = FakePlaybackEngine()
        engine.scriptedPhases = [.paused]
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        await coordinator.begin(request())
        let events = Just(SeekEvent(id: 1, origin: .nativeScrub, outcome: .began, target: 42))
            .subscribe(on: DispatchQueue.global())
            .eraseToAnyPublisher()
        coordinator.observeNativeSeeks(events)
        try await waitFor { coordinator.pendingSeekTarget == 42 }
        coordinator.stop()
    }

    @Test func aSeekCompletingAfterPauseCannotRestartPlayback() async throws {
        let engine = FakePlaybackEngine()
        engine.scriptedPhases = [.playing]
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        await coordinator.begin(request())
        var landing: CheckedContinuation<Void, Never>?
        engine.seekHandler = { _ in
            await withCheckedContinuation { landing = $0 }
            engine.play()
        }
        let first = Task { await coordinator.userSeek(to: 900) }
        try await waitFor { landing != nil }
        coordinator.userPause()
        landing?.resume()
        await first.value
        #expect(engine.phase == .paused)
        coordinator.stop()
    }

    @Test func invalidTargetsAreIgnoredAndVodTargetsClampAtBothEnds() async {
        let engine = FakePlaybackEngine()
        engine.duration = 7200
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        await coordinator.userSeek(to: .nan)
        await coordinator.userSeek(to: .infinity)
        await coordinator.userSeek(to: -20)
        await coordinator.userSeek(to: 8000)
        #expect(engine.seeks == [0, 7200])
        coordinator.stop()
    }

    @Test func cancellingTheFirstInputDoesNotStrandLaterInputs() async throws {
        let engine = FakePlaybackEngine()
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        var landing: CheckedContinuation<Void, Never>?
        engine.seekHandler = { target in
            if engine.seeks.count == 1 { await withCheckedContinuation { landing = $0 } }
            engine.position = target
            engine.pause()
        }
        let first = Task { await coordinator.userSeek(to: 20) }
        try await waitFor { landing != nil }
        await coordinator.userSeek(to: 40)
        first.cancel()
        landing?.resume()
        await first.value
        #expect(engine.seeks == [20, 40])
        #expect(engine.phase == .playing)
        coordinator.stop()
    }

    @Test func failureCancelsTheSeekDeadlineAndQueuedTarget() async throws {
        let engine = FakePlaybackEngine()
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        let clock = ManualClock()
        coordinator.clock = clock
        var landing: CheckedContinuation<Void, Never>?
        engine.seekHandler = { _ in await withCheckedContinuation { landing = $0 } }
        let first = Task { await coordinator.userSeek(to: 20) }
        try await waitFor { landing != nil }
        await coordinator.userSeek(to: 40)
        let failure = ApplePlaybackFailure(kind: .network, message: "Connection lost.")
        coordinator.fail(failure)
        clock.advance(by: .seconds(10))
        landing?.resume()
        await first.value
        #expect(coordinator.pendingSeekTarget == nil)
        #expect(coordinator.phase == .failed(failure))
        #expect(engine.seeks == [20])
        coordinator.stop()
    }

    @Test(arguments: [ApplePlaybackEnginePhase.ended, .paused])
    func seekingToTheEndDoesNotRestartTheTitle(_ finishedPhase: ApplePlaybackEnginePhase) async {
        let engine = FakePlaybackEngine()
        engine.duration = 7200
        engine.seekHandler = { target in engine.position = target; engine.phase = finishedPhase }
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        await coordinator.userSeek(to: 7200)
        #expect(engine.phase == finishedPhase)
        #expect(coordinator.pendingSeekTarget == nil)
        coordinator.stop()
    }

    @Test(arguments: [ApplePlaybackEnginePhase.rebuffering, .stalled(reconnecting: false)])
    func seekingWhileBufferingResumesWhenTheEngineLeavesItPaused(_ phase: ApplePlaybackEnginePhase) async {
        let engine = FakePlaybackEngine()
        engine.phase = phase
        engine.seekHandler = { target in engine.position = target; engine.pause() }
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        coordinator.update(.waiting("Buffering…"))
        await coordinator.userSeek(to: 20)
        #expect(engine.seeks == [20])
        #expect(engine.phase == .playing)
        #expect(coordinator.pendingSeekTarget == nil)
        coordinator.stop()
    }

    @Test(arguments: [0.0, 7200.0])
    func hundredsOfStepsClampAtTheBeginningAndEnd(_ boundary: Double) async throws {
        let engine = FakePlaybackEngine()
        engine.duration = 7200
        engine.position = 3600
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        let model = AppleTransportOverlayModel(coordinator: coordinator, isLive: false)
        var landing: CheckedContinuation<Void, Never>?
        engine.seekHandler = { target in
            if engine.seeks.count == 1 { await withCheckedContinuation { landing = $0 } }
            engine.position = target
        }
        let first = Task { await coordinator.userSeek(to: 3600) }
        try await waitFor { landing != nil }
        for _ in 0..<600 { await model.skip(by: boundary == 0 ? -10 : 10) }
        #expect(engine.seeks == [3600])
        #expect(coordinator.pendingSeekTarget == boundary)
        landing?.resume()
        await first.value
        #expect(engine.seeks == [3600, boundary])
        #expect(engine.position == boundary)
        coordinator.stop()
    }

    @Test func aReturnedSeekRetriesBeforeReopeningAnActuallyStalledEngine() async throws {
        let engine = FakePlaybackEngine()
        engine.scriptedPhases = [.playing]
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        let clock = ManualClock()
        coordinator.clock = clock
        await coordinator.begin(request())
        await coordinator.userSeek(to: 900)
        engine.phase = .stalled(reconnecting: false)
        await clock.waitForSleep(until: ApplePlaybackCoordinator.seekTimeout)
        clock.advance(by: ApplePlaybackCoordinator.seekTimeout)
        try await waitFor { engine.seeks.count == 2 && engine.phase == .playing }
        #expect(engine.loadedRequests.count == 1)
        engine.phase = .stalled(reconnecting: false)
        await clock.waitForSleep(until: ApplePlaybackCoordinator.seekTimeout * 2)
        clock.advance(by: ApplePlaybackCoordinator.seekTimeout)
        try await waitFor { engine.loadedRequests.count == 2 }
        #expect(engine.loadedRequests.last?.resumePosition == 900)
        coordinator.stop()
    }

    @Test func slowBufferingNeverReopensTheTitleOrIssuesASecondSeek() async throws {
        let engine = FakePlaybackEngine()
        engine.scriptedPhases = [.playing]
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        let clock = ManualClock()
        coordinator.clock = clock
        await coordinator.begin(request())
        var landing: CheckedContinuation<Void, Never>?
        engine.seekHandler = { target in
            engine.phase = .rebuffering
            await withCheckedContinuation { landing = $0 }
            engine.position = target
            engine.phase = .playing
        }
        let seek = Task { await coordinator.userSeek(to: 900) }
        try await waitFor { landing != nil }
        for window in 1...4 {
            await clock.waitForSleep(until: ApplePlaybackCoordinator.seekTimeout * window)
            clock.advance(by: ApplePlaybackCoordinator.seekTimeout)
        }
        await clock.waitForSleep(until: ApplePlaybackCoordinator.seekTimeout * 5)
        #expect(engine.loadedRequests.count == 1)
        #expect(engine.seeks == [900])
        await coordinator.userSeek(to: 1200)
        #expect(engine.seeks == [900])
        engine.seekHandler = { engine.position = $0 }
        landing?.resume()
        await seek.value
        #expect(engine.seeks == [900, 1200])
        #expect(coordinator.pendingSeekTarget == nil)
        coordinator.stop()
    }

    @Test func aStalledPhaseWithAnAdvancingPictureDoesNotReopenOrRetry() async {
        let engine = FakePlaybackEngine()
        engine.scriptedPhases = [.playing]
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        let clock = ManualClock()
        coordinator.clock = clock
        await coordinator.begin(request())
        await coordinator.userSeek(to: 900)
        engine.phase = .stalled(reconnecting: false)
        for window in 1...3 {
            await clock.waitForSleep(until: ApplePlaybackCoordinator.seekTimeout * window)
            engine.scriptedPresentationTime = Double(window) * 100
            clock.advance(by: ApplePlaybackCoordinator.seekTimeout)
            await clock.waitForSleep(until: ApplePlaybackCoordinator.seekTimeout * (window + 1))
        }
        #expect(engine.seeks == [900])
        #expect(engine.loadedRequests.count == 1)
        coordinator.stop()
    }

    @Test func requestsDuringARecoveryLoadWaitForTheReplacementEngine() async throws {
        let engine = FakePlaybackEngine()
        engine.scriptedPhases = [.playing]
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        let clock = ManualClock()
        coordinator.clock = clock
        await coordinator.begin(request())
        await coordinator.userSeek(to: 900)
        engine.phase = .stalled(reconnecting: false)
        await clock.waitForSleep(until: ApplePlaybackCoordinator.seekTimeout)
        clock.advance(by: ApplePlaybackCoordinator.seekTimeout)
        try await waitFor { engine.seeks.count == 2 && engine.phase == .playing }
        engine.phase = .stalled(reconnecting: false)
        var loaded: CheckedContinuation<Void, Never>?
        engine.loadHandler = { _ in
            await withCheckedContinuation { loaded = $0 }
            engine.phase = .playing
        }
        await clock.waitForSleep(until: ApplePlaybackCoordinator.seekTimeout * 2)
        clock.advance(by: ApplePlaybackCoordinator.seekTimeout)
        try await waitFor { loaded != nil }
        await coordinator.userSeek(to: 1200)
        #expect(engine.seeks == [900, 900])
        #expect(coordinator.pendingSeekTarget == 1200)
        loaded?.resume()
        try await waitFor { engine.seeks.last == 1200 }
        coordinator.stop()
    }

    @Test func aPlayingEngineWithALaggingClockIsNeverReopened() async throws {
        let engine = FakePlaybackEngine()
        engine.scriptedPhases = [.playing]
        engine.scriptedPresentationTime = 100
        engine.seekHandler = { engine.position = $0 }
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        let clock = ManualClock()
        coordinator.clock = clock
        await coordinator.begin(request())
        await coordinator.userSeek(to: 900)
        engine.emit(.position(900))
        try await waitFor { coordinator.lastKnownPosition == 900 }
        #expect(coordinator.pendingSeekTarget == 900)
        await clock.waitForSleep(until: ApplePlaybackCoordinator.seekTimeout)
        clock.advance(by: ApplePlaybackCoordinator.seekTimeout)
        try await waitFor { coordinator.pendingSeekTarget == nil }
        #expect(engine.loadedRequests.count == 1)
        coordinator.stop()
    }

    @Test func stockScrubsAreWatchedWithoutIssuingDuplicateSeeks() async {
        let engine = FakePlaybackEngine()
        engine.scriptedPhases = [.playing]
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        await coordinator.begin(request())
        coordinator.stockSeekCommitted(to: 100, isPlaying: true)
        coordinator.stockSeekCommitted(to: 200, isPlaying: true)
        #expect(engine.seeks.isEmpty)
        #expect(coordinator.pendingSeekTarget == 200)
        engine.position = 200
        coordinator.seekPositionChanged(200)
        #expect(coordinator.pendingSeekTarget == nil)
        #expect(engine.loadedRequests.count == 1)
        coordinator.stop()
    }

    @Test func aPausedStockScrubStaysPausedWithoutReloading() async {
        let engine = FakePlaybackEngine()
        engine.scriptedPhases = [.paused]
        engine.position = 100
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        let clock = ManualClock()
        coordinator.clock = clock
        await coordinator.begin(request())
        coordinator.stockSeekCommitted(to: 100, isPlaying: false)
        coordinator.seekPositionChanged(100)
        #expect(coordinator.pendingSeekTarget == nil)
        clock.advance(by: ApplePlaybackCoordinator.seekTimeout * 3)
        #expect(engine.loadedRequests.count == 1)
        #expect(engine.phase == .paused)
        #expect(engine.seeks.isEmpty)
        coordinator.stop()
    }

    @Test func pausingThroughAVKitDuringASeekUpdatesPlaybackIntent() async throws {
        let engine = FakePlaybackEngine()
        engine.scriptedPhases = [.playing]
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        let clock = ManualClock()
        coordinator.clock = clock
        await coordinator.begin(request())
        coordinator.stockSeekCommitted(to: 900, isPlaying: true)
        engine.pause()
        engine.emit(.phase(.paused))
        try await waitFor { coordinator.phase == .paused }
        engine.position = 900
        coordinator.seekPositionChanged(900)
        #expect(coordinator.pendingSeekTarget == nil)
        clock.advance(by: ApplePlaybackCoordinator.seekTimeout * 3)
        #expect(engine.loadedRequests.count == 1)
        #expect(engine.phase == .paused)
        coordinator.stop()
    }

    @Test func oldNativeLandingsCannotReleaseANewerScrub() async {
        let engine = FakePlaybackEngine()
        engine.scriptedPhases = [.playing]
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        await coordinator.begin(request())
        coordinator.observeNativeSeek(.init(id: 1, origin: .nativeScrub, outcome: .began, target: 100))
        coordinator.observeNativeSeek(.init(id: 2, origin: .nativeScrub, outcome: .began, target: 200))
        coordinator.observeNativeSeek(.init(id: 1, origin: .nativeScrub, outcome: .landed(renderedTime: 100), target: 100))
        #expect(coordinator.pendingSeekTarget == 200)
        coordinator.observeNativeSeek(.init(id: 2, origin: .nativeScrub, outcome: .landed(renderedTime: 206), target: 200))
        #expect(coordinator.pendingSeekTarget == nil)
        #expect(engine.seeks.isEmpty)
        coordinator.stop()
    }

    @Test func aNativeScrubCannotMistakeTheOldFrameForALanding() async throws {
        let engine = FakePlaybackEngine()
        engine.scriptedPhases = [.paused]
        engine.position = 100
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        let clock = ManualClock()
        coordinator.clock = clock
        await coordinator.begin(request())
        coordinator.observeNativeSeek(.init(id: 1, origin: .nativeScrub, outcome: .began, target: 101))
        coordinator.seekPositionChanged(100)
        #expect(coordinator.pendingSeekTarget == 101)
        await clock.waitForSleep(until: ApplePlaybackCoordinator.seekTimeout)
        clock.advance(by: ApplePlaybackCoordinator.seekTimeout)
        try await waitFor { coordinator.pendingSeekTarget == nil }
        #expect(engine.loadedRequests.count == 1)
        #expect(engine.phase == .paused)
        coordinator.stop()
    }

    @Test func anEndNotificationQueuedBeforeStopCannotEndTheNextSession() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let engine = NativePlaybackEngine()
        try await engine.load(.init(url: file, autoplay: false, mediaID: "retired", sourceKind: .files))
        let item = try #require(engine.avPlayer?.currentItem)
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: item)
        engine.stop()
        await engine.retirementTask?.value
        #expect(engine.phase == .idle)
        #expect(engine.route == .none)
        #expect(engine.avPlayer == nil)
    }

    @Test func lateSeekInputAfterStopCannotRestartTheStoppedEngine() async {
        let engine = FakePlaybackEngine()
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        coordinator.stop()
        engine.scriptedRoute = .none
        await coordinator.userSeek(to: 900)
        #expect(engine.seeks.isEmpty)
        #expect(engine.phase == .idle)
        #expect(coordinator.phase == .idle)
        #expect(coordinator.pendingSeekTarget == nil)
    }
}
