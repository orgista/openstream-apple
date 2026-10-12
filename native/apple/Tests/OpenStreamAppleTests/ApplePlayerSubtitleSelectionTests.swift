import Foundation
import Testing
@testable import OpenStreamApple

@Suite struct ApplePlayerSubtitleSelectionTests {
    @MainActor @Test func nativePickerOffClearsAnAppSidecar() async throws {
        let engine = NativePlaybackEngine()
        defer { engine.stop() }
        engine.externalSubtitleDataLoader = { _ in
            Data("1\n00:00:00,000 --> 00:01:00,000\nFixture cue\n".utf8)
        }
        engine.addExternalSubtitleTracks([
            AppleExternalSubtitleTrack(id: "fixture", languageCode: "en", displayName: "English",
                                       url: try #require(URL(string: "https://fixture.example/captions.srt")))
        ])
        engine.selectSubtitleTrack(id: try #require(engine.subtitleTracks.first?.id))
        await (try #require(engine.externalSubtitleLoad)).value
        #expect(engine.subtitleCues.first?.text == "Fixture cue")
        engine.mirrorSubtitleSelection(nil)
        #expect(engine.activeSubtitleTrackID == nil)
        #expect(engine.subtitleCues.isEmpty)
        #expect(engine.externalSubtitleLoad == nil)
    }

    @MainActor @Test func matchesLanguageInsteadOfStreamOrMenuPosition() {
        let tracks = [track(7, "fr"), track(12, "eng")]
        #expect(ApplePlayerSubtitleSelection.trackID(optionIndex: 0,
            optionLanguages: ["en-US", "fr"], tracks: tracks) == 12)
    }

    @MainActor @Test func preservesSameLanguageTrackRank() {
        let tracks = [track(4, "eng"), track(9, "fr"), track(15, "en")]
        #expect(ApplePlayerSubtitleSelection.trackID(optionIndex: 1,
            optionLanguages: ["en", "en", "fr"], tracks: tracks) == 15)
    }

    @MainActor @Test func matchesUntaggedClosedCaptions() {
        #expect(ApplePlayerSubtitleSelection.trackID(optionIndex: 0,
            optionLanguages: [nil], tracks: [track(99608, nil)]) == 99608)
        #expect(ApplePlayerSubtitleSelection.trackID(optionIndex: 0,
            optionLanguages: ["und"], tracks: [track(99608, nil)]) == 99608)
    }

    @MainActor @Test func textRenditionDoesNotSelectAnEarlierBitmapTrack() {
        let tracks = [
            ApplePlaybackTrack(id: 3, title: "Bitmap", language: "en", codec: "pgssub"),
            ApplePlaybackTrack(id: 99608, title: "CC", language: "en", codec: "eia_608"),
            track(7, "en"), track(11, "en")
        ]
        let ordered = ApplePlayerSubtitleSelection.renditionOrder(tracks)
        #expect(ordered.map(\.id) == [7, 11, 99608, 3])
        #expect(ApplePlayerSubtitleSelection.trackID(optionIndex: 0,
            optionLanguages: ["en", "en", "en", "en"], tracks: ordered) == 7)
    }

    @MainActor @Test func unknownLanguageDoesNotSelectAnUnrelatedTrack() {
        #expect(ApplePlayerSubtitleSelection.trackID(optionIndex: 0,
            optionLanguages: ["es"], tracks: [track(3, "en")]) == nil)
    }

    @MainActor @Test func absentDuplicateAndInvalidIndexHaveNoMatch() {
        #expect(ApplePlayerSubtitleSelection.trackID(optionIndex: 1,
            optionLanguages: ["en", "en"], tracks: [track(3, "en")]) == nil)
        #expect(ApplePlayerSubtitleSelection.trackID(optionIndex: 4,
            optionLanguages: [], tracks: [track(3, "en")]) == nil)
    }

    private func track(_ id: Int, _ language: String?) -> ApplePlaybackTrack {
        ApplePlaybackTrack(id: id, title: "Fixture", language: language, codec: "srt")
    }
}
