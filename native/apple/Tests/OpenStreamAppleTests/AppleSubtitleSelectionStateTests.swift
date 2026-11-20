import Foundation
import Testing
@testable import OpenStreamApple

private let sparseSubtitleFixture = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures/out/mp4-h264-aac-subtitles.mp4")

@Suite struct AppleSubtitleSelectionStateTests {
    @MainActor @Test(.timeLimit(.minutes(1)),
                    .enabled(if: FileManager.default.fileExists(atPath: sparseSubtitleFixture.path)))
    func switchingEmbeddedLanguageBackfillsAnAlreadyStartedSparseCue() async throws {
        // This private generated fixture contains one cue per language, spanning 0–10 seconds.
        let engine = try AetherPlaybackEngine()
        engine.captionsPreference = .off
        defer { engine.stop() }
        try await engine.load(ApplePlaybackRequest(url: sparseSubtitleFixture, autoplay: false,
                                                  mediaID: "sparse-subtitle-switch", sourceKind: .files))
        for _ in 0..<150 where engine.subtitleTracks.count < 2 {
            try await Task.sleep(for: .milliseconds(100))
        }
        let english = try #require(engine.subtitleTracks.first { $0.language == "en" || $0.language == "eng" })
        let french = try #require(engine.subtitleTracks.first { $0.language == "fr" || $0.language == "fra" })
        await engine.seek(to: 6)
        for track in [english, french] {
            engine.selectSubtitleTrack(id: track.id)
            let expected = track.id == english.id ? "English fixture cue" : "French fixture cue"
            for _ in 0..<150 where !engine.subtitleCues.contains(where: { $0.text == expected }) {
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(engine.activeSubtitleTrackID == track.id)
            #expect(engine.subtitleCues.contains { $0.text == expected && $0.startTime <= 6 && $0.endTime > 6 })
            #expect(!engine.subtitleCues.contains { $0.text != expected })
        }
    }

    @Test func startupAutoSelectionIsTheRenderedTrack() {
        #expect(AppleSubtitleSelectionState.renderedTrackID(
            engineTrackID: 7, appTrackID: nil, appOwnsRendering: false) == 7)
    }

    @Test func offClearsThePreviousTrack() {
        #expect(AppleSubtitleSelectionState.renderedTrackID(
            engineTrackID: nil, appTrackID: 7, appOwnsRendering: false) == nil)
    }

    @Test func engineEchoCannotClearAppRenderer() {
        #expect(AppleSubtitleSelectionState.renderedTrackID(
            engineTrackID: nil, appTrackID: 1_000_000, appOwnsRendering: true) == 1_000_000)
    }

    @Test func late608DiscoveryRetainsTheSelectedID() {
        let selected = AppleSubtitleSelectionState.renderedTrackID(
            engineTrackID: 99608, appTrackID: nil, appOwnsRendering: false)
        #expect(AppleSubtitleCueLayerPolicy.menuEntries(tracks: [], preferredLanguages: [],
            languagesAreExplicit: false, activeTrackID: selected).isEmpty)
        let entries = AppleSubtitleCueLayerPolicy.menuEntries(
            tracks: [ApplePlaybackTrack(id: 99608, title: "English", language: "en", codec: "eia_608")],
            preferredLanguages: ["en"], languagesAreExplicit: true, activeTrackID: selected)
        #expect(entries.filter(\.isSelected).map(\.trackID) == [99608])
        #expect(entries.first?.isSelected == false)
    }

    @Test func autoSelectedDuplicateKeepsItsCheckedMenuIdentity() {
        let entries = AppleSubtitleCueLayerPolicy.menuEntries(tracks: [
            ApplePlaybackTrack(id: 3, title: "English", language: "en", isDefault: true),
            ApplePlaybackTrack(id: 8, title: "English", language: "eng")
        ], preferredLanguages: ["en"], languagesAreExplicit: true, activeTrackID: 8)
        #expect(entries.map(\.trackID) == [nil, 8])
        #expect(entries.filter(\.isSelected).map(\.trackID) == [8])
    }

    @MainActor @Test func adapterPublishesAutoSelectionAndOffWithoutAnAppCommand() throws {
        let engine = try AetherPlaybackEngine()
        engine.captionsPreference = .off
        engine.applyEngineSubtitleSelection(99608)
        engine.applyEmbeddedSubtitleTracks([
            ApplePlaybackTrack(id: 99608, title: "English", language: "en", codec: "eia_608")])
        let stock = AppleStockPlayerSubtitles()
        stock.refresh(from: engine)
        #expect(engine.activeSubtitleTrackID == 99608)
        #expect(stock.menuEntries.filter(\.isSelected).map(\.trackID) == [99608])
        engine.applyEngineSubtitleSelection(nil)
        stock.refresh(from: engine)
        #expect(stock.menuEntries.first?.isSelected == true)
        #expect(stock.cues.isEmpty)
        engine.stop()
    }
}
