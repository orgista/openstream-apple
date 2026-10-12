import Foundation
import Testing
@testable import OpenStreamApple

@Suite("Subtitle delay and frame-rate fix")
struct AppleSubtitleDelayTests {
    private func cue(_ id: Int, _ start: Double, _ end: Double, _ text: String = "line") -> AppleSubtitleCue {
        AppleSubtitleCue(id: id, startTime: start, endTime: end, body: .text(text))
    }

    @Test("A delay shifts both ends of every cue by exactly that amount")
    func delayShiftsCueEnds() {
        let cues = [cue(1, 10, 13), cue(2, 60, 63)]
        let later = AppleSubtitleTiming(delay: 1.5)
        let earlier = AppleSubtitleTiming(delay: -2.0)
        #expect(cues.map { later.adjusted($0).startTime } == [11.5, 61.5])
        #expect(cues.map { later.adjusted($0).endTime } == [14.5, 64.5])
        #expect(cues.map { earlier.adjusted($0).startTime } == [8, 58])
        #expect(cues.map { earlier.adjusted($0).endTime } == [11, 61])
    }

    @Test("Negative times clamp to zero")
    func negativeClamps() {
        let adjusted = AppleSubtitleTiming(delay: -5).adjusted(cue(1, 1, 3))
        #expect(adjusted.startTime == 0)
        #expect(adjusted.endTime == 0)
    }

    @Test("The cue layer shows the 60 s cue at 62 s with a +2 s delay, and not at 60 s")
    func activeCuesFollowTheDelay() {
        let cues = [cue(1, 60, 63, "T=60s")]
        let timing = AppleSubtitleTiming(delay: 2)
        #expect(AppleSubtitleCueLayerPolicy.activeCues(in: cues, at: 60.5, timing: timing).isEmpty)
        #expect(AppleSubtitleCueLayerPolicy.activeCues(in: cues, at: 62.1, timing: timing).map(\.id) == [1])
        #expect(AppleSubtitleCueLayerPolicy.activeCues(in: cues, at: 64.9, timing: timing).map(\.id) == [1])
        #expect(AppleSubtitleCueLayerPolicy.activeCues(in: cues, at: 65.1, timing: timing).isEmpty)
        // No timing is the old behaviour.
        #expect(AppleSubtitleCueLayerPolicy.activeCues(in: cues, at: 60.5).map(\.id) == [1])
    }

    @Test("Steps of 50 and 100 ms add up exactly; reset returns to zero; the delay is bounded")
    func nudgesAndReset() {
        var timing = AppleSubtitleTiming()
        for _ in 0..<10 { timing.apply(.nudge(0.1)) }
        #expect(timing.delay == 1.0)
        timing.apply(.nudge(-0.05))
        #expect(timing.delay == 0.95)
        #expect(timing.delayLabel == "+950 ms")
        timing.apply(.nudge(0.3))
        #expect(timing.delayLabel == "+1.25 s")
        timing.apply(.resetDelay)
        #expect(timing.delay == 0)
        #expect(timing.delayLabel == "0 ms")
        timing.apply(.nudge(-0.1))
        #expect(timing.delayLabel == "−100 ms")
        timing.apply(.nudge(-1000))
        #expect(timing.delay == -AppleSubtitleTiming.delayLimit)
    }

    @Test("fps resync maps a 25-fps-timed cue for T=300 s (287.712 s) back to 300 s within 40 ms")
    func frameRateResync() {
        let drifted = 300 * 23.976 / 25  // 287.712
        let timing = AppleSubtitleTiming(frameRateFix: .from25To23976)
        let shown = timing.adjusted(cue(1, drifted, drifted + 3))
        #expect(abs(shown.startTime - 300) < 0.04)
        let cues = [cue(1, drifted, drifted + 3, "T=300s")]
        #expect(AppleSubtitleCueLayerPolicy.activeCues(in: cues, at: 300.2, timing: timing).map(\.id) == [1])
        #expect(AppleSubtitleCueLayerPolicy.activeCues(in: cues, at: 288, timing: timing).isEmpty)
        // The other direction undoes it.
        let back = AppleSubtitleTiming(frameRateFix: .from23976To25).adjusted(shown)
        #expect(abs(back.startTime - drifted) < 0.001)
    }

    @Test("Delay and frame-rate fix combine: stretch first, then shift")
    func delayAndRateCombine() {
        let timing = AppleSubtitleTiming(delay: 1, frameRateFix: .from25To23976)
        let shown = timing.adjusted(cue(1, 23.976, 25))
        #expect(abs(shown.startTime - 26) < 0.0001)
        #expect(abs(timing.cueClock(at: 26) - 23.976) < 0.0001)
    }

    @Test("The menu offers the timing rows only while a subtitle is on")
    func menuOfferedOnlyWithASubtitle() {
        #expect(AppleSubtitleTimingMenu.isOffered(subtitleSelected: true))
        #expect(!AppleSubtitleTimingMenu.isOffered(subtitleSelected: false))
        #expect(AppleSubtitleTimingMenu.steps.map(\.seconds) == [0.1, 0.05, -0.05, -0.1])
    }
}

@MainActor
@Suite("Subtitle delay is per play")
struct AppleSubtitleDelayPerPlayTests {
    private func request(_ mediaID: String, _ path: String = "movie.mp4") -> ApplePlaybackRequest {
        ApplePlaybackRequest(url: URL(string: "https://fixture.example/\(path)")!, mediaID: mediaID,
                             sourceKind: .stremio)
    }

    @Test("A retry or another stream of the same title keeps the delay; a new title starts at zero")
    func resetsOnNewTitleOnly() async {
        let engine = FakePlaybackEngine()
        engine.script([.playing])
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        await coordinator.begin(request("tt1"))
        coordinator.subtitleTiming.apply(.nudge(0.1))
        coordinator.subtitleTiming.apply(.frameRate(.from25To23976))
        await coordinator.begin(request("tt1", "other-quality.mp4"))
        #expect(coordinator.subtitleTiming.delay == 0.1)
        #expect(coordinator.subtitleTiming.frameRateFix == .from25To23976)
        await coordinator.begin(request("tt2"))
        #expect(coordinator.subtitleTiming.isIdentity)
        coordinator.stop()
    }

    @Test("The transport overlay's active cues follow the coordinator's delay at once")
    func overlayCuesFollowDelay() {
        let engine = FakePlaybackEngine()
        engine.subtitleCues = [AppleSubtitleCue(id: 7, startTime: 60, endTime: 63, body: .text("T=60s"))]
        engine.position = 60.5
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        let model = AppleTransportOverlayModel(coordinator: coordinator, isLive: false)
        model.apply(.tracks)
        model.apply(.position(60.5))
        #expect(model.activeSubtitleCues.map(\.id) == [7])
        model.changeSubtitleTiming(.nudge(2))
        #expect(model.activeSubtitleCues.isEmpty)
        #expect(model.subtitleTiming.delay == 2)
    }
}
