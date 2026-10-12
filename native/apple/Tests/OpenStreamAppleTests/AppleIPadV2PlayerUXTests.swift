import Foundation
import Testing
@testable import OpenStreamApple

/// iPad v2 re-run (2026-10-01): a caption drawn three times under the Next
/// Episode card, a stalled live channel under a Play glyph, and duplicate
/// service tiers in Add Service.
@MainActor
@Suite(.serialized) struct AppleIPadV2PlayerUXTests {
    private func cue(_ id: Int, _ text: String, start: Double = 10, end: Double = 14) -> AppleSubtitleCue {
        AppleSubtitleCue(id: id, startTime: start, endTime: end, body: .text(text))
    }

    // MARK: - Cues

    @Test func aRepeatedRollUpLineIsDrawnOnce() {
        let cues = [cue(1, "GOOD EVENING"), cue(2, "GOOD EVENING."), cue(3, "GOOD EVENING.")]
        let active = AppleSubtitleCueLayerPolicy.activeCues(in: cues, at: 12)
        #expect(active.map(\.id) == [3])
    }

    @Test func aGrowingLineKeepsItsLongestForm() {
        let cues = [cue(1, "I MET MY OLD LOVER"), cue(2, "I MET MY OLD LOVER ON THE STREET LAST NIGHT")]
        #expect(AppleSubtitleCueLayerPolicy.activeCues(in: cues, at: 12).map(\.id) == [2])
    }

    @Test func differentLinesOnScreenTogetherAreBothKept() {
        let cues = [cue(1, "- Who is it?"), cue(2, "- Open the door.")]
        #expect(AppleSubtitleCueLayerPolicy.activeCues(in: cues, at: 12).map(\.id) == [1, 2])
        #expect(AppleSubtitleCueLayerPolicy.activeCues(in: [cue(1, "No."), cue(2, "No, wait")], at: 12).count == 2)
    }

    @Test func captionsClearTheNextEpisodeCard() {
        let plain = AppleSubtitleCueLift.lift(controlsVisible: false, bottomBarHeight: 60)
        let withCard = AppleSubtitleCueLift.lift(controlsVisible: false, bottomBarHeight: 60, promptTop: 230)
        #expect(plain == AppleSubtitleCueLift.hidden)
        #expect(withCard >= 230)
        #expect(AppleSubtitleCueLift.lift(controlsVisible: true, bottomBarHeight: 60, promptTop: 230) >= 230)
    }

    @Test func captionsClearTheScrubberMeasuredOnScreen() {
        // Apple TV, 1080 pt screen, bar top at 900: the cue layer's bottom
        // sits at the screen edge whatever the picture's letterboxing.
        let rise = AppleSubtitleCueLift.clearance(layerBottom: 1056, controlsTop: 900, promptTop: nil)
        #expect(1056 - rise <= 900 - AppleSubtitleCueLift.gapAboveControls)
        // The higher of bar and card wins; nothing on screen means no rise.
        #expect(AppleSubtitleCueLift.clearance(layerBottom: 1056, controlsTop: 900, promptTop: 700)
            == 1056 - 700 + AppleSubtitleCueLift.gapAbovePrompt)
        #expect(AppleSubtitleCueLift.clearance(layerBottom: 1056, controlsTop: nil, promptTop: nil) == 0)
        // A layer already above the bar does not move.
        #expect(AppleSubtitleCueLift.clearance(layerBottom: 600, controlsTop: 900, promptTop: nil) == 0)
    }

    @Test func theStockEnginePausedOnTheLastFrameHasEnded() {
        // A 1:05:37 episode paused at its end reads as `.ended`, so the stock
        // route hands over to the next episode (Apple TV regression).
        #expect(NativePlaybackEngine.isAtEnd(position: 3937, duration: 3937.2))
        #expect(!NativePlaybackEngine.isAtEnd(position: 3900, duration: 3937.2))
        #expect(!NativePlaybackEngine.isAtEnd(position: 120, duration: .nan))
        #expect(!NativePlaybackEngine.isAtEnd(position: 0, duration: 0))
    }

    // MARK: - Live stall

    @Test func aStalledLiveChannelSaysReconnectingOnTheStockRoute() async {
        let engine = FakePlaybackEngine()
        engine.scriptedRoute = .avPlayer
        let request = ApplePlaybackRequest(url: URL(string: "http://127.0.0.1:8765/live/ch.m3u8")!, isLive: true,
                                           mediaID: "live-fixture", sourceKind: .iptv)
        let coordinator = ApplePlaybackCoordinator(engine: engine, timeout: .seconds(60))
        let model = AppleTransportOverlayModel(coordinator: coordinator, isLive: true)
        model.route = .avPlayer
        await coordinator.begin(request)
        engine.emit(.phase(.stalled(reconnecting: true)))
        for _ in 0..<50 {
            if case .waiting = coordinator.phase { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(model.showsWaitingIndicator)
        #expect(model.showsReconnecting)
        coordinator.stop()
    }

    // MARK: - Add Service

    @Test func serviceTiersShareOneFamily() {
        #expect(AppleWatchProviderPolicy.serviceFamily("Paramount+ Premium") == AppleWatchProviderPolicy.serviceFamily("Paramount Plus Essential"))
        #expect(AppleWatchProviderPolicy.serviceFamily("Peacock Premium Plus") == "peacock")
        #expect(AppleWatchProviderPolicy.serviceFamily("Netflix Standard with Ads") == "netflix")
        #expect(AppleWatchProviderPolicy.serviceFamily("Hulu") != AppleWatchProviderPolicy.serviceFamily("Max"))
    }

    @Test func addServiceListsEachServiceOnce() {
        let directory = [
            AppleWatchProvider(id: 1, name: "Paramount+ Premium", offer: .subscription),
            AppleWatchProvider(id: 2, name: "Peacock Premium", offer: .subscription),
            AppleWatchProvider(id: 3, name: "Paramount Plus Essential", offer: .subscription),
            AppleWatchProvider(id: 4, name: "Peacock Premium Plus", offer: .subscription),
            AppleWatchProvider(id: 5, name: "Hulu", offer: .subscription),
        ]
        #expect(AppleWatchProviderPolicy.addable(directory, enabledProviderIDs: []).map(\.id) == [1, 2, 5])
        #expect(AppleWatchProviderPolicy.addable(directory, enabledProviderIDs: [3]).map(\.id) == [2, 5])
    }
}
