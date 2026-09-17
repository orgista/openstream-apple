import Foundation
import Testing

@MainActor
@Test func overlayTimeFormattingRejectsNonFiniteAndOverflowingValues() {
    #expect(AppleTransportOverlayModel.timeText(.nan) == "0:00")
    #expect(AppleTransportOverlayModel.timeText(.infinity) == "0:00")
    #expect(AppleTransportOverlayModel.timeText(.greatestFiniteMagnitude) == "0:00")
}
@testable import OpenStreamApple

@MainActor
@Suite struct AppleTransportOverlayModelTests {
    private func makeRequest(
        isLive: Bool = false,
        dvrWindowSeconds: Double? = nil,
        sourceKind: ApplePlaybackRequest.SourceKind = .stremio
    ) -> ApplePlaybackRequest {
        ApplePlaybackRequest(
            url: URL(string: "http://127.0.0.1:8765/media/movie.mp4")!,
            isLive: isLive,
            dvrWindowSeconds: dvrWindowSeconds,
            mediaID: "test-media-id",
            sourceKind: sourceKind
        )
    }

    private func makeCoordinator(
        engine: FakePlaybackEngine,
        request: ApplePlaybackRequest,
        route: ApplePlaybackPresentationRoute = .surface
    ) -> ApplePlaybackCoordinator {
        engine.scriptedRoute = route
        let coordinator = ApplePlaybackCoordinator(engine: engine, timeout: .seconds(60))
        return coordinator
    }

    // MARK: - timeText formatting

    @Test func timeTextFormatsMinutesSeconds() {
        #expect(AppleTransportOverlayModel.timeText(65) == "1:05")
    }

    @Test func timeTextFormatsHoursMinutesSeconds() {
        #expect(AppleTransportOverlayModel.timeText(3661) == "1:01:01")
    }

    @Test func timeTextClampsNegativeToZero() {
        #expect(AppleTransportOverlayModel.timeText(-5) == "0:00")
    }

    // MARK: - Scrubbability

    @Test func vodWithDurationIsScrubbable() {
        let engine = FakePlaybackEngine()
        engine.duration = 100
        let coordinator = makeCoordinator(engine: engine, request: makeRequest())
        let model = AppleTransportOverlayModel(coordinator: coordinator, isLive: false)
        model.dvrWindowSeconds = nil
        #expect(model.isScrubbable)
        coordinator.stop()
    }

    @Test func liveWithoutDvrIsNotScrubbable() {
        let engine = FakePlaybackEngine()
        let coordinator = makeCoordinator(engine: engine, request: makeRequest(isLive: true))
        let model = AppleTransportOverlayModel(coordinator: coordinator, isLive: true)
        model.dvrWindowSeconds = nil
        #expect(!model.isScrubbable)
        coordinator.stop()
    }

    @Test func liveWithDvrIsScrubbable() {
        let engine = FakePlaybackEngine()
        let coordinator = makeCoordinator(engine: engine, request: makeRequest(isLive: true, dvrWindowSeconds: 30))
        let model = AppleTransportOverlayModel(coordinator: coordinator, isLive: true)
        model.dvrWindowSeconds = 30
        #expect(model.isScrubbable)
        coordinator.stop()
    }

    @Test func liveWithoutDvrHasEmptyPositionText() {
        let engine = FakePlaybackEngine()
        let coordinator = makeCoordinator(engine: engine, request: makeRequest(isLive: true))
        let model = AppleTransportOverlayModel(coordinator: coordinator, isLive: true)
        model.dvrWindowSeconds = nil
        #expect(model.positionText.isEmpty)
        coordinator.stop()
    }

    // MARK: - Scrub forwards to engine.seek

    @Test func scrubForwardsSeekToEngine() async {
        let engine = FakePlaybackEngine()
        engine.duration = 100
        let coordinator = makeCoordinator(engine: engine, request: makeRequest())
        let model = AppleTransportOverlayModel(coordinator: coordinator, isLive: false)
        await model.scrub(to: 0.5)
        #expect(engine.seeks == [50])
        coordinator.stop()
    }

    // MARK: - Track selection forwards

    @Test func selectAudioForwardsToEngine() {
        let engine = FakePlaybackEngine()
        engine.duration = 100
        let coordinator = makeCoordinator(engine: engine, request: makeRequest())
        let model = AppleTransportOverlayModel(coordinator: coordinator, isLive: false)
        model.selectAudio(2)
        #expect(engine.selectedAudio == [2])
        coordinator.stop()
    }

    @Test func selectSubtitleNilForwardsToEngine() {
        let engine = FakePlaybackEngine()
        engine.duration = 100
        let coordinator = makeCoordinator(engine: engine, request: makeRequest())
        let model = AppleTransportOverlayModel(coordinator: coordinator, isLive: false)
        model.selectSubtitle(nil)
        #expect(engine.selectedSubtitle == [nil])
        coordinator.stop()
    }

    @Test func selectSubtitleForwardsIdToEngine() {
        let engine = FakePlaybackEngine()
        engine.duration = 100
        engine.subtitleTracks = [ApplePlaybackTrack(id: 1, title: "English", language: "eng")]
        let coordinator = makeCoordinator(engine: engine, request: makeRequest())
        let model = AppleTransportOverlayModel(coordinator: coordinator, isLive: false)
        model.selectSubtitle(1)
        #expect(engine.selectedSubtitle == [1])
        coordinator.stop()
    }

    @Test func ccStateFlagReflectsSubtitleSelection() {
        let engine = FakePlaybackEngine()
        engine.duration = 100
        engine.subtitleTracks = [ApplePlaybackTrack(id: 1, title: "English", language: "eng")]
        let coordinator = makeCoordinator(engine: engine, request: makeRequest())
        let model = AppleTransportOverlayModel(coordinator: coordinator, isLive: false)
        #expect(!model.isCCActive)
        model.selectSubtitle(1)
        #expect(model.isCCActive)
        model.selectSubtitle(nil)
        #expect(!model.isCCActive)
        coordinator.stop()
    }

    // MARK: - Route / AirPlay / PiP flags

    @Test func avPlayerRouteShowsAirPlayAndPiP() {
        let engine = FakePlaybackEngine()
        let coordinator = makeCoordinator(engine: engine, request: makeRequest(), route: .avPlayer)
        let model = AppleTransportOverlayModel(coordinator: coordinator, isLive: false)
        model.route = .avPlayer
        #expect(model.showsAirPlay)
        #if os(iOS)
        #expect(model.showsPictureInPicture)
        #else
        #expect(!model.showsPictureInPicture)
        #endif
        coordinator.stop()
    }

    @Test func surfaceRouteHidesAirPlayAndPiP() {
        let engine = FakePlaybackEngine()
        let coordinator = makeCoordinator(engine: engine, request: makeRequest(), route: .surface)
        let model = AppleTransportOverlayModel(coordinator: coordinator, isLive: false)
        model.route = .surface
        #expect(!model.showsAirPlay)
        #expect(!model.showsPictureInPicture)
        coordinator.stop()
    }

    // MARK: - Overlay visibility / waiting indicator

    @Test func avPlayerRouteHidesOverlayAndWaitingIndicator() async {
        let engine = FakePlaybackEngine()
        let coordinator = makeCoordinator(engine: engine, request: makeRequest(), route: .avPlayer)
        let model = AppleTransportOverlayModel(coordinator: coordinator, isLive: false)
        model.route = .avPlayer
        await coordinator.begin(makeRequest())
        engine.emit(.phase(.rebuffering))
        try? await Task.sleep(for: .milliseconds(150))
        #expect(!model.showsOverlay)
        // On `.avPlayer` routes no custom waiting view is ever shown, even while waiting.
        #expect(!model.showsWaitingIndicator)
        coordinator.stop()
    }

    @Test func surfaceRouteShowsOverlay() {
        let engine = FakePlaybackEngine()
        let coordinator = makeCoordinator(engine: engine, request: makeRequest(), route: .surface)
        let model = AppleTransportOverlayModel(coordinator: coordinator, isLive: false)
        model.route = .surface
        #expect(model.showsOverlay)
        coordinator.stop()
    }

    @Test func surfaceWaitingShowsIndicatorWithAccessibilityLabel() async {
        let engine = FakePlaybackEngine()
        let coordinator = makeCoordinator(engine: engine, request: makeRequest(), route: .surface)
        let model = AppleTransportOverlayModel(coordinator: coordinator, isLive: false)
        model.route = .surface
        await coordinator.begin(makeRequest())
        engine.emit(.phase(.rebuffering))
        // Poll for the observed phase: a fixed sleep flakes under machine load.
        for _ in 0..<50 {
            if case .waiting = coordinator.phase { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        if case .waiting = coordinator.phase {} else {
            Issue.record("expected .waiting phase, got \(coordinator.phase)")
        }
        #expect(model.showsWaitingIndicator)
        // The waiting text is used only as the spinner's accessibility label.
        #expect(model.waitingText == "Buffering…")
        coordinator.stop()
    }

    // MARK: - Next episode

    @Test func nextEpisodeNilHidesAction() {
        let engine = FakePlaybackEngine()
        engine.duration = 100
        let coordinator = makeCoordinator(engine: engine, request: makeRequest())
        let model = AppleTransportOverlayModel(coordinator: coordinator, isLive: false)
        #expect(!model.showsNextEpisode)
        model.nextEpisode = { }
        #expect(model.showsNextEpisode)
        coordinator.stop()
    }

    // MARK: - Skip

    @Test func skipForwardsSeeksClamped() async {
        let engine = FakePlaybackEngine()
        engine.duration = 100
        engine.position = 5
        let coordinator = makeCoordinator(engine: engine, request: makeRequest())
        let model = AppleTransportOverlayModel(coordinator: coordinator, isLive: false)
        await model.skip(by: 10)
        #expect(engine.seeks == [15])
        coordinator.stop()
    }

    @Test func skipClampsToEnd() async {
        let engine = FakePlaybackEngine()
        engine.duration = 100
        engine.position = 95
        let coordinator = makeCoordinator(engine: engine, request: makeRequest())
        let model = AppleTransportOverlayModel(coordinator: coordinator, isLive: false)
        await model.skip(by: 10)
        #expect(engine.seeks == [100])
        coordinator.stop()
    }

    @Test func skipLiveWithoutDvrIsNoOp() async {
        let engine = FakePlaybackEngine()
        let coordinator = makeCoordinator(engine: engine, request: makeRequest(isLive: true))
        let model = AppleTransportOverlayModel(coordinator: coordinator, isLive: true)
        model.dvrWindowSeconds = nil
        await model.skip(by: 10)
        #expect(engine.seeks.isEmpty)
        coordinator.stop()
    }

    // MARK: - Observation guard (repeated position ticks must not thrash the
    // track-selection menu — an open `Menu` observing unrelated state gets
    // torn down and rebuilt on every write, dropping taps).

    @Test func repeatedIdenticalPositionEventsDoNotTriggerObservationChange() async throws {
        let engine = FakePlaybackEngine()
        engine.duration = 100
        engine.position = 5
        let coordinator = makeCoordinator(engine: engine, request: makeRequest())
        let model = AppleTransportOverlayModel(coordinator: coordinator, isLive: false)
        let counter = ObservationChangeCounter()
        await coordinator.begin(makeRequest())
        engine.emit(.position(5))
        for _ in 0..<50 where model.position != 5 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.position == 5)

        // One registration stays armed until the first real change, so an
        // identical tick must leave it armed and the counter at zero.
        withObservationTracking {
            _ = model.position
        } onChange: {
            Task { @MainActor in counter.count += 1 }
        }

        engine.emit(.position(5)) // same value again
        try await Task.sleep(for: .milliseconds(200))
        #expect(counter.count == 0)

        engine.emit(.position(6)) // genuinely new value
        for _ in 0..<50 where counter.count == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(counter.count == 1)
        coordinator.stop()

        coordinator.stop()
    }
}

@MainActor
private final class ObservationChangeCounter {
    var count = 0
}

@Test func cancelledLoadIsNotReportedAsAPlaybackFailure() async throws {
    // Switching channels cancels the in-flight load; the viewer must never see
    // "Playback Failed … Swift.CancellationError" for that (owner, 2026-09-04).
    let failure = ApplePlaybackFailure.classify(CancellationError())
    #expect(failure.kind == .cancelled)
}

@MainActor @Test func transportControlsHideTogetherAfterThreeSecondsAndReturnOnActivity() async throws {
    let engine = FakePlaybackEngine()
    engine.script([.playing])
    engine.scriptedRoute = .surface
    let coordinator = ApplePlaybackCoordinator(engine: engine)
    await coordinator.begin(.init(url: URL(fileURLWithPath: "/movie.mkv"), mediaID: "auto-hide", sourceKind: .files))
    let model = AppleTransportOverlayModel(coordinator: coordinator, isLive: false)
    #expect(model.controlsVisible)
    // Polled, not slept: a fixed 3200 ms against a 3000 ms hide left 200 ms of
    // slack and failed on a loaded machine (twice in six gate runs,
    // 2026-09-15). This still proves the hide happens, without racing it.
    #expect(await waitUntil { !model.controlsVisible })
    model.bumpActivity()
    #expect(model.controlsVisible)
    coordinator.update(.paused)
    model.bumpActivity()
    try await Task.sleep(for: .milliseconds(3200))
    #expect(model.controlsVisible)
    coordinator.stop()
}

/// Owner 2026-09-14: "loading videos has double circles". The player screen
/// and the transport overlay each drew a spinner, a few points apart, because
/// the overlay keeps its own copy of the route and it lags the coordinator's
/// during a retry. Latching on the first route makes them exclusive.
@Suite("Connecting spinner")
struct ApplePlaybackSpinnerPolicyTests {
    @Test func theScreenOwnsTheSpinnerUntilARouteIsKnown() {
        #expect(ApplePlaybackSpinnerPolicy.showsScreenSpinner(route: .none, isBusy: true, hasRouted: false))
        #expect(!ApplePlaybackSpinnerPolicy.showsScreenSpinner(route: .none, isBusy: false, hasRouted: false))
    }

    @Test func theRoutePlayerOwnsItAfterwards() {
        #expect(!ApplePlaybackSpinnerPolicy.showsScreenSpinner(route: .surface, isBusy: true, hasRouted: true))
        #expect(!ApplePlaybackSpinnerPolicy.showsScreenSpinner(route: .avPlayer, isBusy: true, hasRouted: true))
    }

    /// The overlap itself: a retry puts the coordinator back to `.none` while
    /// the overlay still believes it is on the surface route and keeps drawing.
    @Test func aRetryDoesNotBringTheSecondSpinnerBack() {
        #expect(!ApplePlaybackSpinnerPolicy.showsScreenSpinner(route: .none, isBusy: true, hasRouted: true))
    }
}

/// Waits for a condition instead of sleeping past a deadline, so a timing test
/// proves the behaviour without racing the scheduler on a loaded machine.
@MainActor
private func waitUntil(
    timeout: Duration = .seconds(8),
    _ condition: () -> Bool
) async -> Bool {
    let deadline = ContinuousClock().now + timeout
    while ContinuousClock().now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return condition()
}
