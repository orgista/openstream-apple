import Foundation
import Testing
@testable import OpenStreamApple

/// Owner 2026-09-14: "subtitles have too many tracks since I only selected one
/// language". A remux carries fifteen or twenty tracks; the preference was only
/// handed to the engine for auto-selection and never used to shorten the menu.
@Suite("Subtitle track filter")
struct AppleSubtitleTrackFilterTests {
    private func track(_ id: Int, _ language: String?, _ title: String = "Subtitle") -> ApplePlaybackTrack {
        ApplePlaybackTrack(id: id, title: title, language: language)
    }

    private var remux: [ApplePlaybackTrack] {
        [track(0, "eng", "English"), track(1, "eng", "English SDH"), track(2, "spa"),
         track(3, "fra"), track(4, "deu"), track(5, "jpn"), track(6, nil, "Unknown")]
    }

    @Test func onlyThePreferredLanguageIsListed() {
        let visible = AppleSubtitleTrackFilter.visible(remux, preferredLanguages: ["eng"])
        #expect(visible.map(\.id) == [0, 1])
    }

    @Test func languagesAreListedInTheViewersOrder() {
        let visible = AppleSubtitleTrackFilter.visible(remux, preferredLanguages: ["fra", "eng"])
        #expect(visible.map(\.id) == [3, 0, 1])
    }

    @Test func noPreferenceListsEverything() {
        #expect(AppleSubtitleTrackFilter.visible(remux, preferredLanguages: []).count == remux.count)
    }

    /// A language the app only *guessed* from the device is forgiving: when it
    /// matches nothing, an empty menu is worse than a long one.
    @Test func aGuessedLanguageThatMatchesNothingListsEverything() {
        #expect(AppleSubtitleTrackFilter.visible(remux, preferredLanguages: ["kor"]).count == remux.count)
    }

    /// A language the viewer *picked* is not. "English can be default, only
    /// option as well" (owner 2026-09-15) — so a stream with no Korean offers
    /// nothing rather than quietly listing six other languages.
    @Test func aPickedLanguageThatMatchesNothingListsNothing() {
        let visible = AppleSubtitleTrackFilter.visible(
            remux, preferredLanguages: ["kor"], isExplicitChoice: true)
        #expect(visible.isEmpty)
    }

    /// Picking a language does not change what happens when it *does* match:
    /// still that language, still nothing else.
    @Test func aPickedLanguageListsOnlyItself() {
        let visible = AppleSubtitleTrackFilter.visible(
            remux, preferredLanguages: ["eng"], isExplicitChoice: true)
        #expect(visible.map(\.id) == [0, 1])
    }

    /// An explicit choice of nothing is still no preference — every track.
    @Test func anExplicitEmptyListStillListsEverything() {
        let visible = AppleSubtitleTrackFilter.visible(
            remux, preferredLanguages: [], isExplicitChoice: true)
        #expect(visible.count == remux.count)
    }

    @Test func theCodeFormDoesNotMatter() {
        for preferred in ["eng", "en", "en-US", "en_GB", "English"] {
            let visible = AppleSubtitleTrackFilter.visible(remux, preferredLanguages: [preferred])
            #expect(visible.map(\.id) == [0, 1], "failed for \(preferred)")
        }
        // And the same on the track's side.
        let mixed = [track(0, "en-US"), track(1, "spa")]
        #expect(AppleSubtitleTrackFilter.visible(mixed, preferredLanguages: ["eng"]).map(\.id) == [0])
    }

    @Test func normalisationReducesEveryFormToTheTwoLetterCode() {
        #expect(AppleSubtitleTrackFilter.normalized("eng") == "en")
        #expect(AppleSubtitleTrackFilter.normalized("EN-us") == "en")
        #expect(AppleSubtitleTrackFilter.normalized("English") == "en")
        #expect(AppleSubtitleTrackFilter.normalized("  spa ") == "es")
        #expect(AppleSubtitleTrackFilter.normalized("") == "")
    }
}
