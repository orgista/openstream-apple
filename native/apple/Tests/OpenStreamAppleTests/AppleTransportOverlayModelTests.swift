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
        #expect(model.isScrubbable)
        coordinator.stop()
    }

    @Test func liveWithoutDvrIsNotScrubbable() {
        let engine = FakePlaybackEngine()
        let coordinator = makeCoordinator(engine: engine, request: makeRequest(isLive: true))
        let model = AppleTransportOverlayModel(coordinator: coordinator, isLive: true)
        #expect(!model.isScrubbable)
        #expect(!model.canSkip)
        coordinator.stop()
    }

    @Test func liveWithDvrIsScrubbable() {
        let engine = FakePlaybackEngine()
        engine.seekableRange = AppleSeekableRange(start: 0, end: 30)
        let coordinator = makeCoordinator(engine: engine, request: makeRequest(isLive: true, dvrWindowSeconds: 30))
        let model = AppleTransportOverlayModel(coordinator: coordinator, isLive: true)
        #expect(model.isScrubbable)
        #expect(model.canSkip)
        coordinator.stop()
    }

    /// The request's 1800 s hint is not a window. A channel whose player
    /// reports eight seconds of rewind gets no scrubber and no skip buttons.
    @Test func liveWhosePlayerReportsANarrowWindowIsNotScrubbable() {
        let engine = FakePlaybackEngine()
        engine.seekableRange = AppleSeekableRange(start: 3_600, end: 3_608)
        let coordinator = makeCoordinator(engine: engine, request: makeRequest(isLive: true, dvrWindowSeconds: 1_800))
        let model = AppleTransportOverlayModel(coordinator: coordinator, isLive: true)
        #expect(!model.isScrubbable)
        #expect(!model.canSkip)
        coordinator.stop()
    }

    // MARK: - The live edge

    @Test func liveWithoutDvrIsAlwaysAtTheLiveEdge() {
        let engine = FakePlaybackEngine()
        engine.position = 0
        let coordinator = makeCoordinator(engine: engine, request: makeRequest(isLive: true))
        let model = AppleTransportOverlayModel(coordinator: coordinator, isLive: true)
        #expect(model.isAtLiveEdge)
        coordinator.stop()
    }

    @Test func liveWithDvrIsAtTheEdgeAtTheEndOfItsWindow() {
        let engine = FakePlaybackEngine()
        engine.position = 600
        engine.seekableRange = AppleSeekableRange(start: 0, end: 600)
        let coordinator = makeCoordinator(engine: engine, request: makeRequest(isLive: true, dvrWindowSeconds: 600))
        let model = AppleTransportOverlayModel(coordinator: coordinator, isLive: true)
        #expect(model.isAtLiveEdge)
        coordinator.stop()
    }

    /// A seek lands a moment off the edge and the edge itself moves, so the
    /// badge holds within the tolerance and drops outside it.
    @Test func liveWithDvrLeavesTheEdgeOnceTheViewerScrubsBack() {
        let engine = FakePlaybackEngine()
        engine.position = 600 - AppleTransportOverlayModel.liveEdgeTolerance + 1
        engine.seekableRange = AppleSeekableRange(start: 0, end: 600)
        let coordinator = makeCoordinator(engine: engine, request: makeRequest(isLive: true, dvrWindowSeconds: 600))
        let model = AppleTransportOverlayModel(coordinator: coordinator, isLive: true)
        #expect(model.isAtLiveEdge)
        coordinator.stop()

        let behind = FakePlaybackEngine()
        behind.position = 590
        behind.seekableRange = AppleSeekableRange(start: 0, end: 600)
        let secondCoordinator = makeCoordinator(engine: behind, request: makeRequest(isLive: true, dvrWindowSeconds: 600))
        let scrubbedBack = AppleTransportOverlayModel(coordinator: secondCoordinator, isLive: true)
        #expect(!scrubbedBack.isAtLiveEdge)
        secondCoordinator.stop()
    }

    @Test func vodIsNeverAtALiveEdge() {
        let engine = FakePlaybackEngine()
        engine.duration = 100
        engine.position = 100
        let coordinator = makeCoordinator(engine: engine, request: makeRequest())
        let model = AppleTransportOverlayModel(coordinator: coordinator, isLive: false)
        #expect(!model.isAtLiveEdge)
        coordinator.stop()
    }

    @Test func liveWithoutDvrHasEmptyPositionText() {
        let engine = FakePlaybackEngine()
        let coordinator = makeCoordinator(engine: engine, request: makeRequest(isLive: true))
        let model = AppleTransportOverlayModel(coordinator: coordinator, isLive: true)
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

    @Test func liveCaptionsArrivingAfterPresentationSelectTheCurrentTrack() async throws {
        let engine = FakePlaybackEngine()
        let request = makeRequest(isLive: true)
        let coordinator = makeCoordinator(engine: engine, request: request, route: .avPlayer)
        let model = AppleTransportOverlayModel(coordinator: coordinator, isLive: true)
        model.preferredSubtitleLanguages = ["en"]
        model.subtitleLanguagesAreExplicit = true
        defer { coordinator.stop() }
        #expect(model.visibleSubtitleTracks.isEmpty)

        // The broadcast legible group can arrive after the full-screen host exists.
        await Task.yield()
        engine.subtitleTracks = [ApplePlaybackTrack(id: 17, title: "English", language: "en", codec: "cc")]
        engine.emit(.tracks)
        for _ in 0..<20 where model.visibleSubtitleTracks.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        let track = try #require(model.visibleSubtitleTracks.first)
        #expect(track.id == 17)
        model.selectSubtitle(track.id)
        #expect(engine.selectedSubtitle == [17])

        // A channel switch must not retain the first channel's menu indices.
        engine.subtitleTracks = [ApplePlaybackTrack(id: 23, title: "English", language: "en", codec: "cc")]
        engine.emit(.tracks)
        for _ in 0..<20 where model.visibleSubtitleTracks.first?.id != 23 {
            try await Task.sleep(for: .milliseconds(10))
        }
        let replacement = try #require(model.visibleSubtitleTracks.first)
        #expect(replacement.id == 23)
        model.selectSubtitle(replacement.id)
        model.selectSubtitle(nil)
        #expect(engine.selectedSubtitle == [17, 23, nil])
    }

    @Test func engineOffAfterAutoSelectionClearsTheOverlayCheck() async throws {
        let engine = FakePlaybackEngine()
        engine.activeSubtitleTrackID = 99608
        let coordinator = makeCoordinator(engine: engine, request: makeRequest(isLive: true))
        let model = AppleTransportOverlayModel(coordinator: coordinator, isLive: true)
        defer { coordinator.stop() }
        #expect(model.selectedSubtitleID == 99608)
        await Task.yield()
        engine.activeSubtitleTrackID = nil
        engine.emit(.tracks)
        for _ in 0..<20 where model.selectedSubtitleID != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.selectedSubtitleID == nil)
        #expect(!model.isCCActive)
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

    /// Full test 2026-09-30: the Audio & Subtitles menu closed itself after
    /// 2-3 s because the auto-hide removed the chrome it hangs from.
    @Test func anOpenMenuHoldsTheControlsPastTheAutoHide() async {
        let engine = FakePlaybackEngine()
        let coordinator = makeCoordinator(engine: engine, request: makeRequest(), route: .surface)
        let model = AppleTransportOverlayModel(coordinator: coordinator, isLive: false)
        await coordinator.begin(makeRequest())
        engine.emit(.phase(.playing))
        #expect(await waitUntil { if case .playing = coordinator.phase { true } else { false } })
        // A menu reports every row; two rows open, both must close.
        model.menuItemAppeared()
        model.menuItemAppeared()
        try? await Task.sleep(for: .milliseconds(3600))
        #expect(model.controlsVisible)
        #expect(model.menuIsOpen)
        model.menuItemDisappeared()
        #expect(model.menuIsOpen)
        model.menuItemDisappeared()
        #expect(!model.menuIsOpen)
        #expect(await waitUntil { !model.controlsVisible })
        coordinator.stop()
    }

    @Test func aFocusedSkipIntroHoldsTheControlsPastTheAutoHide() async {
        let engine = FakePlaybackEngine()
        let coordinator = makeCoordinator(engine: engine, request: makeRequest(), route: .surface)
        let model = AppleTransportOverlayModel(coordinator: coordinator, isLive: false)
        await coordinator.begin(makeRequest())
        engine.emit(.phase(.playing))
        #expect(await waitUntil { if case .playing = coordinator.phase { true } else { false } })
        model.focusedPromptHoldsControls = true
        try? await Task.sleep(for: .milliseconds(3600))
        #expect(model.controlsVisible)
        model.focusedPromptHoldsControls = false
        #expect(await waitUntil { !model.controlsVisible })
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
        await model.skip(by: 10)
        #expect(engine.seeks.isEmpty)
        coordinator.stop()
    }

    /// The regression this whole change exists for: a live channel whose
    /// player reports a real 90 s window, sitting at the edge. Skipping back
    /// used to clamp `position - 10` against a fictional 1800 s window and
    /// hand AVPlayer a time it silently swallowed. It must now land inside the
    /// reported range, and the badge must stop saying LIVE.
    @Test func skipBackOnLiveWithARealWindowSeeksInsideIt() async {
        let engine = FakePlaybackEngine()
        engine.position = 3_690
        engine.seekableRange = AppleSeekableRange(start: 3_600, end: 3_690)
        let coordinator = makeCoordinator(engine: engine, request: makeRequest(isLive: true, dvrWindowSeconds: 1_800))
        let model = AppleTransportOverlayModel(coordinator: coordinator, isLive: true)
        #expect(model.isAtLiveEdge)
        await model.skip(by: -10)
        #expect(engine.seeks == [3_680])
        coordinator.stop()
    }

    /// Skipping back at the floor of the window has nowhere to go and must not
    /// issue a seek that only stalls the picture.
    @Test func skipBackAtTheFloorOfTheWindowIssuesNoSeek() async {
        let engine = FakePlaybackEngine()
        engine.position = 3_600
        engine.seekableRange = AppleSeekableRange(start: 3_600, end: 3_690)
        let coordinator = makeCoordinator(engine: engine, request: makeRequest(isLive: true, dvrWindowSeconds: 1_800))
        let model = AppleTransportOverlayModel(coordinator: coordinator, isLive: true)
        await model.skip(by: -10)
        #expect(engine.seeks.isEmpty)
        coordinator.stop()
    }

    /// The LIVE badge seeks to the real edge, not to `dvrWindowSeconds`.
    @Test func liveBadgeSeeksToTheEndOfTheRealWindow() async {
        let engine = FakePlaybackEngine()
        engine.position = 3_620
        engine.seekableRange = AppleSeekableRange(start: 3_600, end: 3_690)
        let coordinator = makeCoordinator(engine: engine, request: makeRequest(isLive: true, dvrWindowSeconds: 1_800))
        let model = AppleTransportOverlayModel(coordinator: coordinator, isLive: true)
        #expect(!model.isAtLiveEdge)
        await model.seekToLiveEdge()
        #expect(engine.seeks == [3_690])
        coordinator.stop()
    }

    /// The scrubber spans the real window, so the thumb sits where the
    /// playhead actually is inside it instead of pinned at 1.0.
    @Test func liveProgressAndDurationReadTheRealWindow() {
        let engine = FakePlaybackEngine()
        engine.position = 3_645
        engine.seekableRange = AppleSeekableRange(start: 3_600, end: 3_690)
        let coordinator = makeCoordinator(engine: engine, request: makeRequest(isLive: true, dvrWindowSeconds: 1_800))
        let model = AppleTransportOverlayModel(coordinator: coordinator, isLive: true)
        #expect(abs(model.progress - 0.5) < 0.001)
        #expect(model.durationText == "1:30")
        coordinator.stop()
    }

    /// A live scrub is a fraction of the real window, on the window's own axis.
    @Test func liveScrubTargetsTheRealWindow() async {
        let engine = FakePlaybackEngine()
        engine.position = 3_690
        engine.seekableRange = AppleSeekableRange(start: 3_600, end: 3_690)
        let coordinator = makeCoordinator(engine: engine, request: makeRequest(isLive: true, dvrWindowSeconds: 1_800))
        let model = AppleTransportOverlayModel(coordinator: coordinator, isLive: true)
        await model.scrub(to: 0.25)
        #expect(engine.seeks == [3_622.5])
        coordinator.stop()
    }

    // MARK: - Cue clock

    @Test func overlayCuesFollowPresentationTimeWhileScrubClockIsHeld() async throws {
        let engine = FakePlaybackEngine()
        engine.position = 100
        engine.subtitleCues = [
            AppleSubtitleCue(id: 1, startTime: 99, endTime: 101, body: .text("HELD SCRUB CLOCK")),
            AppleSubtitleCue(id: 2, startTime: 103, endTime: 105, body: .text("ON SCREEN NOW")),
        ]
        let coordinator = makeCoordinator(engine: engine, request: makeRequest(isLive: true))
        let model = AppleTransportOverlayModel(coordinator: coordinator, isLive: true)
        await coordinator.begin(makeRequest(isLive: true))
        engine.scriptedPresentationTime = 104
        engine.emit(.position(100))
        for _ in 0..<50 where model.cueTime != 104 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.position == 100)
        #expect(model.activeSubtitleCues.map(\.id) == [2])
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
