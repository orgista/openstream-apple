import Testing
@testable import OpenStreamApple

@MainActor
@Suite struct AppleTrackSelectionPolicyTests {
    @Test func unconfirmedPickBeatsTheEnginesStaleTrack() {
        #expect(AppleTrackSelectionPolicy.audio(engineActive: 1, pending: 2, current: 2) == 2)
    }

    @Test func engineReportWinsOnceNothingIsPending() {
        #expect(AppleTrackSelectionPolicy.audio(engineActive: 3, pending: nil, current: 2) == 3)
        #expect(AppleTrackSelectionPolicy.audio(engineActive: nil, pending: nil, current: 2) == 2)
    }

    /// Apple TV verification 2026-10-01: Spanish chosen, the menu reopened
    /// with English checked while the switch was still rebuilding.
    @Test func menuKeepsTheNewAudioTrackThroughTheSwitchAndARebuiltOverlay() async throws {
        let engine = FakePlaybackEngine()
        engine.duration = 100
        engine.audioTracks = [
            ApplePlaybackTrack(id: 1, title: "English", language: "en", isDefault: true),
            ApplePlaybackTrack(id: 2, title: "Spanish", language: "es"),
        ]
        engine.activeAudioTrackID = 1
        let coordinator = ApplePlaybackCoordinator(engine: engine, timeout: .seconds(60))
        defer { coordinator.stop() }
        let model = AppleTransportOverlayModel(coordinator: coordinator, isLive: false)
        #expect(model.selectedAudioID == 1)

        model.selectAudio(2)
        // The engine has not switched yet and says so on a tracks pass.
        engine.emit(.tracks)
        await Task.yield()
        #expect(model.selectedAudioID == 2)

        // The overlay is rebuilt while the pipeline is still rebuilding.
        let rebuilt = AppleTransportOverlayModel(coordinator: coordinator, isLive: false)
        #expect(rebuilt.selectedAudioID == 2)
        let checked = AppleAudioTrackMenu.entries(engine.audioTracks, activeTrackID: rebuilt.selectedAudioID)
            .filter(\.isSelected).map(\.trackID)
        #expect(checked == [2])

        // The switch lands: the engine's report is the truth again.
        engine.activeAudioTrackID = 2
        engine.emit(.tracks)
        for _ in 0..<20 where coordinator.pendingAudioPick != nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(coordinator.pendingAudioPick == nil)
        engine.activeAudioTrackID = 1
        engine.emit(.tracks)
        for _ in 0..<20 where rebuilt.selectedAudioID != 1 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(rebuilt.selectedAudioID == 1)
    }

    /// A pick from "More…" is checked when the menu reopens.
    @Test func subtitlePickedFromMoreIsTheCheckedEntry() {
        let engine = FakePlaybackEngine()
        engine.duration = 100
        engine.subtitleTracks = [
            ApplePlaybackTrack(id: 1, title: "English", language: "en"),
            ApplePlaybackTrack(id: 2, title: "Spanish", language: "es"),
        ]
        let coordinator = ApplePlaybackCoordinator(engine: engine, timeout: .seconds(60))
        defer { coordinator.stop() }
        let model = AppleTransportOverlayModel(coordinator: coordinator, isLive: false)
        model.preferredSubtitleLanguages = ["en"]
        model.selectSubtitle(1)
        model.selectSubtitle(2)
        let main = AppleSubtitleCueLayerPolicy.menuEntries(
            tracks: model.subtitleTracks, preferredLanguages: ["en"],
            languagesAreExplicit: false, activeTrackID: model.selectedSubtitleID)
        let more = AppleSubtitleCueLayerPolicy.moreMenuEntries(
            tracks: model.subtitleTracks, preferredLanguages: ["en"], activeTrackID: model.selectedSubtitleID)
        #expect(more.map(\.trackID) == [2])
        #expect((main + more).filter(\.isSelected).map(\.trackID) == [2])
    }
}
