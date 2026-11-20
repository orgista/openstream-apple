import Foundation
import Synchronization
import Testing

@MainActor
@Test func overlayTimeFormattingRejectsNonFiniteAndOverflowingValues() {
    #expect(AppleTransportOverlayModel.timeText(.nan) == "0:00")
    #expect(AppleTransportOverlayModel.timeText(.infinity) == "0:00")
    #expect(AppleTransportOverlayModel.timeText(.greatestFiniteMagnitude) == "0:00")
}
@testable import OpenStreamApple

@MainActor
@Suite(.timeLimit(.minutes(1))) struct AppleTransportOverlayModelTests {
    private func makeRequest(
        isLive: Bool = false,
        dvrWindowSeconds: Double? = nil,
        sourceKind: ApplePlaybackRequest.SourceKind = .catalog
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

    @Test func choosingPlaybackSpeedDoesNotResumePausedVideo() async {
        let engine = FakePlaybackEngine()
        let request = makeRequest()
        let coordinator = makeCoordinator(engine: engine, request: request)
        let model = AppleTransportOverlayModel(coordinator: coordinator, isLive: false)
        await coordinator.begin(request)
        engine.emit(.phase(.paused))
        await waitUntil { coordinator.phase == .paused }
        engine.pause()
        model.playbackRate = 1.5
        #expect(engine.phase == .paused)
        model.togglePlayPause()
        #expect(engine.phase == .playing)
        #expect(model.playbackRate == 1.5)
        coordinator.stop()
    }

    @Test func relativeLiveScrubsUseTheRenderedClockAndClampToTheSlidingWindow() async {
        let engine = FakePlaybackEngine()
        engine.duration = 10_000
        engine.position = 10
        engine.scriptedPresentationTime = 3_650
        engine.seekableRange = .init(start: 3_600, end: 3_900)
        engine.seekHandler = { engine.scriptedPresentationTime = $0 }
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        let model = AppleTransportOverlayModel(coordinator: coordinator, isLive: true)
        await model.skip(by: 10)
        await model.scrub(by: 0.1)
        #expect(engine.seeks == [3_660, 3_690])
        engine.seekableRange = .init(start: 3_680, end: 3_980)
        model.apply(.position(engine.position))
        await model.skip(by: -100)
        #expect(engine.seeks.last == 3_680)
        await model.scrub(by: 2)
        #expect(engine.seeks.last == 3_980)
        coordinator.stop()
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

    /// A 45-minute share film: four Right presses while the first seek is
    /// still landing make one follow-up seek to 4 × 5% past the start, and the
    /// scrubber shows that target meanwhile (resume job, 2026-10-31).
    @Test func scrubPressesWhileASeekLandsAddUpIntoOneFollowUpSeek() async {
        let engine = FakePlaybackEngine()
        engine.duration = 2700
        engine.position = 1.6
        let gate = SeekGate()
        engine.seekHandler = { _ in await gate.wait() }
        let coordinator = makeCoordinator(engine: engine, request: makeRequest())
        let model = AppleTransportOverlayModel(coordinator: coordinator, isLive: false)
        let first = Task { await model.scrub(by: 0.05) }
        await waitUntil { gate.waiting == 1 }
        for _ in 0 ..< 3 { await model.scrub(by: 0.05) }
        #expect(engine.seeks.count == 1)
        #expect(abs(engine.seeks[0] - 136.6) < 0.001)
        #expect(abs(model.scrubPosition - 541.6) < 0.001)
        #expect(abs(model.progress - 541.6 / 2700) < 0.000_001)
        gate.open()
        await waitUntil { gate.waiting == 1 }
        #expect(engine.seeks.count == 2)
        #expect(abs(engine.seeks[1] - 541.6) < 0.001)
        gate.open()
        await first.value
        coordinator.seekPositionChanged(541.7)
        model.apply(.position(541.7))
        #expect(model.scrubPosition == 541.7)
        coordinator.stop()
    }

    @Test func aPausedSeekRetriesTheLatestTargetBeforeReopeningAStalledEngine() async {
        let engine = FakePlaybackEngine()
        engine.duration = 2700
        engine.scriptedPhases = [.playing]
        let gate = SeekGate()
        engine.seekHandler = { _ in await gate.wait() }
        let coordinator = makeCoordinator(engine: engine, request: makeRequest())
        let clock = ManualClock()
        coordinator.clock = clock
        await coordinator.begin(makeRequest())
        let model = AppleTransportOverlayModel(coordinator: coordinator, isLive: false)
        let stuck = Task { await model.scrub(by: 0.05) }
        await waitUntil { gate.waiting == 1 }
        await clock.waitForSleep(until: ApplePlaybackCoordinator.seekTimeout)
        for _ in 0..<400 { await model.scrub(by: 0.0001) }
        let latest = coordinator.pendingSeekTarget
        coordinator.userPause()
        engine.phase = .stalled(reconnecting: false)
        clock.advance(by: ApplePlaybackCoordinator.seekTimeout)
        await waitUntil { gate.waiting == 2 }
        #expect(engine.loadedRequests.count == 1)
        #expect(engine.seeks.last == latest)
        await clock.waitForSleep(until: ApplePlaybackCoordinator.seekTimeout * 2)
        clock.advance(by: ApplePlaybackCoordinator.seekTimeout)
        await waitUntil { engine.loadedRequests.count == 2 }
        #expect(engine.loadedRequests.last?.resumePosition == latest)
        #expect(engine.loadedRequests.last?.autoplay == false)
        #expect(coordinator.pendingSeekTarget == nil)
        gate.open()
        await stuck.value
        #expect(engine.seeks.count == 2)
        coordinator.stop()
    }

    /// Stopping (a new item) while a seek lands: the old seek's return does
    /// not end the next item's seek, so a third press still waits for it.
    @Test func aSeekFromTheLastItemCannotEndTheNextItemsSeek() async {
        let engine = FakePlaybackEngine()
        engine.duration = 100
        let gate = SeekGate()
        engine.seekHandler = { _ in await gate.wait() }
        let coordinator = makeCoordinator(engine: engine, request: makeRequest())
        let old = Task { await coordinator.userSeek(to: 50) }
        await waitUntil { gate.waiting == 1 }
        coordinator.stop()
        #expect(coordinator.pendingSeekTarget == nil)
        let new = Task { await coordinator.userSeek(to: 20) }
        await waitUntil { gate.waiting == 2 }
        gate.open()
        await old.value
        #expect(coordinator.pendingSeekTarget == 20)
        await coordinator.userSeek(to: 30)
        #expect(engine.seeks == [50, 20])
        gate.open()
        await waitUntil { gate.waiting == 1 }
        #expect(engine.seeks == [50, 20, 30])
        gate.open()
        await new.value
    }

    @Test func skipsWhileASeekLandsStartFromItsTarget() async {
        let engine = FakePlaybackEngine()
        engine.duration = 100
        engine.position = 5
        let gate = SeekGate()
        engine.seekHandler = { _ in await gate.wait() }
        let coordinator = makeCoordinator(engine: engine, request: makeRequest())
        let model = AppleTransportOverlayModel(coordinator: coordinator, isLive: false)
        let first = Task { await model.skip(by: 10) }
        await waitUntil { gate.waiting == 1 }
        await model.skip(by: 10)
        await model.skip(by: 10)
        gate.open()
        await waitUntil { gate.waiting == 1 }
        gate.open()
        await first.value
        #expect(engine.seeks == [15, 35])
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
        await waitUntil { !model.visibleSubtitleTracks.isEmpty }
        let track = try #require(model.visibleSubtitleTracks.first)
        #expect(track.id == 17)
        model.selectSubtitle(track.id)
        #expect(engine.selectedSubtitle == [17])

        // A channel switch must not retain the first channel's menu indices.
        engine.subtitleTracks = [ApplePlaybackTrack(id: 23, title: "English", language: "en", codec: "cc")]
        engine.emit(.tracks)
        await waitUntil { model.visibleSubtitleTracks.first?.id == 23 }
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
        await waitUntil { model.selectedSubtitleID == nil }
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
        await waitUntil { if case .waiting = coordinator.phase { true } else { false } }
        #expect(!model.showsOverlay)
        // On `.avPlayer` routes no custom waiting view is ever shown, even while waiting.
        #expect(!model.showsWaitingIndicator)
        coordinator.stop()
    }

    @Test(arguments: [ApplePlaybackPresentationRoute.avPlayer, .surface, .audioOnly])
    func customControlsOwnTheWaitingIndicator(route: ApplePlaybackPresentationRoute) {
        let engine = FakePlaybackEngine()
        let coordinator = makeCoordinator(engine: engine, request: makeRequest(), route: route)
        let model = AppleTransportOverlayModel(coordinator: coordinator, isLive: false, usesSystemControls: false)
        model.route = route
        #expect(model.showsOverlay)
        for phase: ApplePlaybackPhase in [.loading, .waiting("Buffering…")] {
            coordinator.update(phase)
            #expect(model.showsWaitingIndicator)
        }
        coordinator.update(.playing)
        #expect(!model.showsWaitingIndicator)
        model.route = .none
        coordinator.update(.loading)
        #expect(!model.showsWaitingIndicator)
        coordinator.stop()
    }

    /// Full test 2026-09-30: the Audio & Subtitles menu closed itself after
    /// 2-3 s because the auto-hide removed the chrome it hangs from.
    @Test func anOpenMenuHoldsTheControlsPastTheAutoHide() async {
        let engine = FakePlaybackEngine()
        let coordinator = makeCoordinator(engine: engine, request: makeRequest(), route: .surface)
        let clock = ManualClock()
        let model = AppleTransportOverlayModel(coordinator: coordinator, isLive: false, hideClock: clock)
        await coordinator.begin(makeRequest())
        engine.emit(.phase(.playing))
        await waitUntil { if case .playing = coordinator.phase { true } else { false } }
        // A menu reports every row; two rows open, both must close.
        model.menuItemAppeared()
        model.menuItemAppeared()
        // Only the open menu's one-minute hold is left; the 3 s hide is gone.
        await waitUntil { clock.pendingDeadlines == [.seconds(60)] }
        clock.advance(by: .milliseconds(3600))
        #expect(model.controlsVisible)
        #expect(model.menuIsOpen)
        model.menuItemDisappeared()
        #expect(model.menuIsOpen)
        model.menuItemDisappeared()
        #expect(!model.menuIsOpen)
        await waitUntil { clock.pendingDeadlines == [.milliseconds(6600)] }
        clock.advance(by: .seconds(3))
        await waitUntil { !model.controlsVisible }
        coordinator.stop()
    }

    @Test func aFocusedSkipIntroHoldsTheControlsPastTheAutoHide() async {
        let engine = FakePlaybackEngine()
        let coordinator = makeCoordinator(engine: engine, request: makeRequest(), route: .surface)
        let clock = ManualClock()
        let model = AppleTransportOverlayModel(coordinator: coordinator, isLive: false, hideClock: clock)
        await coordinator.begin(makeRequest())
        engine.emit(.phase(.playing))
        await waitUntil { if case .playing = coordinator.phase { true } else { false } }
        // As the overlay view does on a phase change. Focusing the prompt
        // cancels the 3 s hide and none is scheduled while it holds focus.
        model.playbackPhaseChanged()
        await waitFor("the 3 s hide") { clock.pendingDeadlines == [.seconds(3)] }
        model.focusedPromptHoldsControls = true
        #expect(clock.pendingSleepers == 0)
        clock.advance(by: .milliseconds(3600))
        #expect(model.controlsVisible)
        model.focusedPromptHoldsControls = false
        await waitUntil { clock.pendingDeadlines == [.milliseconds(6600)] }
        clock.advance(by: .seconds(3))
        await waitUntil { !model.controlsVisible }
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
        await waitUntil { if case .waiting = coordinator.phase { true } else { false } }
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

    @Test func physicalPartHasNoEpisodePromptAndIgnoresEpisodeAutoplaySetting() {
        let engine = FakePlaybackEngine()
        engine.duration = 100
        engine.position = 90
        let coordinator = makeCoordinator(engine: engine, request: makeRequest())
        let model = AppleTransportOverlayModel(coordinator: coordinator, isLive: false)
        var starts = 0
        model.nextEpisode = { starts += 1 }
        model.nextEpisodeTitle = "Part 2"
        model.isPartBoundary = true
        model.autoPlayNextEpisode = false
        #expect(model.nextEpisodePrompt == nil)
        #expect(model.showsNextEpisode == false)
        #expect(coordinator.handsOffAtEnd)
        model.apply(.phase(.ended))
        model.apply(.phase(.ended))
        #expect(starts == 1)
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
        #expect(engine.seeks == [3_689])
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
        await waitUntil { model.cueTime == 104 }
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
        let changes = Mutex(0)
        await coordinator.begin(makeRequest())
        engine.emit(.position(5))
        await waitUntil { model.position == 5 }

        // One registration stays armed until the first real change, so an
        // identical tick must leave it armed and the counter at zero.
        withObservationTracking {
            _ = model.position
        } onChange: {
            changes.withLock { $0 += 1 }
        }

        engine.emit(.position(5)) // same value again
        // Events are applied in order: once the duration lands, the identical
        // tick before it has been applied too.
        engine.emit(.duration(101))
        await waitUntil { model.duration == 101 }
        #expect(changes.withLock { $0 } == 0)

        engine.emit(.position(6)) // genuinely new value
        await waitUntil { model.position == 6 }
        #expect(changes.withLock { $0 } == 1)

        coordinator.stop()
    }
}

@Test func cancelledLoadIsNotReportedAsAPlaybackFailure() async throws {
    // Switching channels cancels the in-flight load; the viewer must never see
    // "Playback Failed … Swift.CancellationError" for that (owner, 2026-09-04).
    let failure = ApplePlaybackFailure.classify(CancellationError())
    #expect(failure.kind == .cancelled)
}

@MainActor @Test(.timeLimit(.minutes(1)))
func transportControlsHideTogetherAfterThreeSecondsAndReturnOnActivity() async throws {
    let engine = FakePlaybackEngine()
    engine.script([.playing])
    engine.scriptedRoute = .surface
    let coordinator = ApplePlaybackCoordinator(engine: engine)
    await coordinator.begin(.init(url: URL(fileURLWithPath: "/movie.mkv"), mediaID: "auto-hide", sourceKind: .files))
    let clock = ManualClock()
    let model = AppleTransportOverlayModel(coordinator: coordinator, isLive: false, hideClock: clock)
    #expect(model.controlsVisible)
    await clock.waitForSleeps(1)
    #expect(clock.pendingDeadlines == [.seconds(3)])
    clock.advance(by: .seconds(3))
    await waitUntil { !model.controlsVisible }
    model.bumpActivity()
    #expect(model.controlsVisible)
    coordinator.update(.paused)
    model.bumpActivity()
    // Paused: nothing is left to hide the controls.
    #expect(clock.pendingSleepers == 0)
    clock.advance(by: .milliseconds(3200))
    #expect(model.controlsVisible)
    coordinator.stop()
}

/// Waits for engine events to reach the model and coordinator through their
/// main-actor tasks. No wall-clock deadline: the parallel gate can hold the
/// main actor for seconds; the time limit fails a change that never lands.
@MainActor
private func waitUntil(_ condition: () -> Bool) async {
    while !condition(), !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(10))
    }
}

/// Holds each fake seek until the test lets it land.
@MainActor
private final class SeekGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    var waiting: Int { continuations.count }
    func wait() async { await withCheckedContinuation { continuations.append($0) } }
    func open() { if !continuations.isEmpty { continuations.removeFirst().resume() } }
}
