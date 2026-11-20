import Foundation
import Testing
@testable import OpenStreamApple

/// The rule the AVPlayer route applies to a stream's own subtitle tracks.
///
/// The route used to publish none and select none, so MP4/M4V/MOV/HLS — which
/// on Apple TV is most well-formed content — played with no captions available
/// at all. These cover the selection rule
/// without needing an asset; the track plumbing itself is exercised on device.
@Suite("Native route subtitle selection")
struct AppleNativeSubtitleSelectionTests {
    private let tracks = [
        ApplePlaybackTrack(id: 0, title: "English", language: "en", codec: "sub"),
        ApplePlaybackTrack(id: 1, title: "Spanish", language: "spa", codec: "sub"),
        ApplePlaybackTrack(id: 2, title: "French", language: "fr-FR", codec: "sub"),
    ]

    /// A language preference shortens the menu to that language, in the same
    /// way the demuxing engine already did.
    @Test func aLanguagePreferenceShortensTheMenu() {
        let visible = AppleSubtitleTrackFilter.visible(tracks, preferredLanguages: ["es"])
        #expect(visible.map(\.id) == [1])
    }

    @Test func englishMenuEntryRetainsItsLegibleOptionIndex() throws {
        // The best English option is not menu index zero or the first English
        // rendition. Selection must retain its original legible-group index.
        let options = [
            (title: "French", language: "fr", codec: "sub"),
            (title: "English 1", language: "en", codec: "cc"),
            (title: "English 2", language: "eng", codec: "sub"),
        ]
        let tracks = options.enumerated().compactMap { index, option in
            NativePlaybackEngine.subtitleTrack(
                optionIndex: index, title: option.title, language: option.language,
                codec: option.codec, isForced: false)
        }
        let visible = AppleSubtitleTrackFilter.visible(
            tracks, preferredLanguages: ["en"], isExplicitChoice: true)
        #expect(visible.count == 1)
        let selected = try #require(visible.first)
        let englishLabel = Locale.current.localizedString(forLanguageCode: "en")?.capitalized ?? "English"
        #expect(AppleSubtitleTrackFilter.menuLabel(for: selected) == englishLabel)
        #expect(selected.id == 2)
        #expect(options[selected.id].title == "English 2")
    }

    @Test func forcedLegibleOptionsAreExcludedWithoutRenumbering() {
        #expect(NativePlaybackEngine.subtitleTrack(
            optionIndex: 0, title: "English Forced", language: "en",
            codec: "sub", isForced: true) == nil)
        let track = NativePlaybackEngine.subtitleTrack(
            optionIndex: 1, title: "English", language: "en",
            codec: "sub", isForced: false)
        #expect(track?.id == 1)
    }

    /// `spa` and `es` are the same language; so are `fr-FR` and `fr`.
    @Test func languageCodeFormsAreTreatedAsOne() {
        #expect(AppleSubtitleTrackFilter.normalized("spa") == "es")
        #expect(AppleSubtitleTrackFilter.normalized("fr-FR") == "fr")
        #expect(AppleSubtitleTrackFilter.visible(tracks, preferredLanguages: ["fr"]).map(\.id) == [2])
    }

    /// A stream carrying only languages the viewer did not ask for offers
    /// none of them (owner 2026-09-28: English by default and the only entry).
    @Test func aStreamWithNoMatchingLanguageOffersNothing() {
        #expect(AppleSubtitleTrackFilter.visible(tracks, preferredLanguages: ["ja"]).isEmpty)
    }

    /// ...but "list them anyway" must not become "turn one on". Only `.always`
    /// selects a track the viewer did not ask for.
    @Test func onlyAlwaysSelectsALanguageTheViewerDidNotAskFor() {
        #expect(AppleCaptionsPreference.always.autoSelectsAnyTrack)
        #expect(!AppleCaptionsPreference.off.autoSelectsAnyTrack)
    }

    @Test func offSelectsNothing() {
        #expect(AppleCaptionsPreference.off.preferredSubtitleLanguages.isEmpty)
    }
}
