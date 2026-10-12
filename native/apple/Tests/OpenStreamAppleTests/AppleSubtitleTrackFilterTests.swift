import Foundation
import Testing
@testable import OpenStreamApple

@Suite("Subtitle track filter")
struct AppleSubtitleTrackFilterTests {
    private func track(_ id: Int, _ language: String?, _ title: String = "Subtitle", codec: String? = nil, isDefault: Bool = false) -> ApplePlaybackTrack {
        ApplePlaybackTrack(id: id, title: title, language: language, codec: codec, isDefault: isDefault)
    }

    @Test func twoEnglishTracksReturnsExactlyTheDefaultOne() {
        let tracks = [
            track(0, "en", "English 1"),
            track(1, "en", "English 2", isDefault: true)
        ]
        let visible = AppleSubtitleTrackFilter.visible(tracks, preferredLanguages: ["en"])
        #expect(visible.map(\.id) == [1])
    }

    @Test func preferredListWithOnlyEnglishPresentReturnsTheEnglishOne() {
        let tracks = [
            track(0, "spa", "Spanish"),
            track(1, "eng", "English")
        ]
        let visible = AppleSubtitleTrackFilter.visible(tracks, preferredLanguages: ["fr", "en"])
        #expect(visible.map(\.id) == [1])
    }

    @Test func explicitChoiceWithNoMatchReturnsEmpty() {
        let tracks = [track(0, "spa", "Spanish")]
        let visible = AppleSubtitleTrackFilter.visible(tracks, preferredLanguages: ["en"], isExplicitChoice: true)
        #expect(visible.isEmpty)
    }

    /// Untagged broadcast captions stand in for the viewer's language when
    /// nothing is tagged in it (US live TV carries English this way).
    @Test(arguments: ["eia_608", "cc"])
    func untaggedCaptionsStandInWhenNothingIsTagged(codec: String) {
        let tracks = [track(99_608, nil, "Closed Captions", codec: codec)]
        let visible = AppleSubtitleTrackFilter.visible(tracks, preferredLanguages: ["es"], isExplicitChoice: true)
        #expect(visible.map(\.id) == [99_608])
    }

    @Test func aLiveStreamWithOnlyUntaggedCC1ListsAndSelectsIt() {
        let tracks = [track(99_608, nil, "CC1", codec: "eia_608")]
        #expect(AppleSubtitleTrackFilter.menu(tracks, preferredLanguages: ["en"]).map(\.id) == [99_608])
        #expect(AppleSubtitleTrackFilter.visible(tracks, preferredLanguages: ["en"]).map(\.id) == [99_608])
        let entries = AppleSubtitleCueLayerPolicy.menuEntries(
            tracks: tracks, preferredLanguages: ["en"], languagesAreExplicit: false, activeTrackID: nil)
        #expect(entries.map(\.trackID) == [nil, 99_608])
    }

    @Test func aTaggedEnglishTrackHidesTheUntaggedCC1() {
        let tracks = [track(99_608, "und", "CC1", codec: "eia_608"), track(2, "eng", "English", codec: "subrip")]
        #expect(AppleSubtitleTrackFilter.menu(tracks, preferredLanguages: ["en"]).map(\.id) == [2])
        #expect(AppleSubtitleTrackFilter.visible(tracks, preferredLanguages: ["en"]).map(\.id) == [2])
    }

    @Test func aTaggedSpanishCC3StaysHiddenBesideAnUntaggedCC1() {
        let tracks = [track(99_608, nil, "CC1", codec: "eia_608"), track(99_609, "es", "CC3", codec: "eia_608")]
        #expect(AppleSubtitleTrackFilter.menu(tracks, preferredLanguages: ["en"]).map(\.id) == [99_608])
        #expect(AppleSubtitleTrackFilter.visible(tracks, preferredLanguages: ["en"]).map(\.id) == [99_608])
        #expect(AppleSubtitleTrackFilter.menu(tracks, preferredLanguages: ["es"]).map(\.id) == [99_609])
    }

    @Test(arguments: [0, 1_000_000])
    func explicitSpanishStillRejectsEnglishOnly(id: Int) {
        let tracks = [track(id, "en", "English")]
        let visible = AppleSubtitleTrackFilter.visible(tracks, preferredLanguages: ["es"], isExplicitChoice: true)
        #expect(visible.isEmpty)
    }

    @Test func untaggedAddOnsAreNotAutoSelected() {
        let tracks = [
            track(1_000_000, nil, "Add-on 1"),
            track(1_000_001, "und", "Add-on 2", isDefault: true)
        ]
        let visible = AppleSubtitleTrackFilter.visible(tracks, preferredLanguages: ["es"], isExplicitChoice: true)
        #expect(visible.isEmpty)
    }

    /// A guessed (device) language is as strict as a picked one.
    @Test func guessedWithNoMatchReturnsNothing() {
        let tracks = [
            track(0, "spa", "Spanish 1"),
            track(1, "spa", "Spanish 2", isDefault: true)
        ]
        let visible = AppleSubtitleTrackFilter.visible(tracks, preferredLanguages: ["en"], isExplicitChoice: false)
        #expect(visible.isEmpty)
    }

    @Test func plainSubtitlesPreferredOverCC() {
        let tracks = [
            track(0, "en", "English CC", codec: "cc"),
            track(1, "en", "English Sub", codec: "subrip")
        ]
        let visible = AppleSubtitleTrackFilter.visible(tracks, preferredLanguages: ["en"])
        #expect(visible.map(\.id) == [1])
    }

    @Test func forcedAndSDHDemoted() {
        let tracks = [
            track(0, "en", "English SDH"),
            track(1, "en", "English Forced"),
            track(2, "en", "English Commentary"),
            track(3, "en", "English")
        ]
        let visible = AppleSubtitleTrackFilter.visible(tracks, preferredLanguages: ["en"])
        #expect(visible.map(\.id) == [3])
    }

    /// V16: "Forced" in a title with no forced flag is a muxer's label, never
    /// an auto-selection; a flagged forced track is picked when it is all
    /// the language has, and loses to a full track otherwise.
    @Test func aTitleOnlyForcedTrackIsNeverAutoSelected() {
        let titled = [track(0, "en", "English Forced")]
        #expect(AppleSubtitleTrackFilter.visible(titled, preferredLanguages: ["en"]).isEmpty)

        let flagged = [ApplePlaybackTrack(id: 1, title: "English", language: "en", codec: nil, isDefault: false, isForced: true)]
        #expect(AppleSubtitleTrackFilter.visible(flagged, preferredLanguages: ["en"]).map(\.id) == [1])

        let both = flagged + [track(2, "en", "English")]
        #expect(AppleSubtitleTrackFilter.visible(both, preferredLanguages: ["en"]).map(\.id) == [2])
    }

    @Test func nothingPickedMeansTheDevicesPrimaryLanguage() {
        #expect(AppleSubtitleTrackFilter.effectiveLanguages([], deviceLanguages: ["en-US", "fr-FR"]) == ["en"])
        #expect(AppleSubtitleTrackFilter.effectiveLanguages([], deviceLanguages: ["es-MX", "en-US"]) == ["es"])
        #expect(AppleSubtitleTrackFilter.effectiveLanguages(["und", ""], deviceLanguages: ["de-DE"]) == ["de"])
        #expect(AppleSubtitleTrackFilter.effectiveLanguages([], deviceLanguages: ["qq"]) == ["en"])
        #expect(AppleSubtitleTrackFilter.effectiveLanguages(["spa", "es-MX", "eng"], deviceLanguages: ["de"]) == ["es", "en"])
    }

    @Test(arguments: ["en", "eng", "en-US", "en_GB", "English", "ENGLISH", "English (US)"])
    func everyFormOfEnglishIsEnglish(language: String) {
        let tracks = [track(0, "spa", "Spanish"), track(1, language, "Subtitle")]
        #expect(AppleSubtitleTrackFilter.menu(tracks, preferredLanguages: ["en"]).map(\.id) == [1])
        #expect(AppleSubtitleTrackFilter.visible(tracks, preferredLanguages: ["eng"]).map(\.id) == [1])
    }

    @Test func aTitleNamingEnglishCountsWhenTheCodeIsMissing() {
        let tracks = [track(0, nil, "English"), track(1, "und", "German"), track(2, "de", "Deutsch")]
        #expect(AppleSubtitleTrackFilter.menu(tracks, preferredLanguages: ["en"]).map(\.id) == [0])
        let german = AppleSubtitleTrackFilter.menuChoices(tracks, preferredLanguages: ["de"])
        #expect(german.map(\.title) == ["German"])
        #expect(Set(german.first?.memberIDs ?? []) == [1, 2])
    }

    @Test func untaggedSubtitleTracksAreNeverListed() {
        let tracks = [track(0, "und", "Subtitle"), track(1, nil, "Track 2"), track(2, "", "Subtitle 3"),
                      track(3, "eng", "English")]
        #expect(AppleSubtitleTrackFilter.menu(tracks, preferredLanguages: ["en"]).map(\.id) == [3])
        #expect(AppleSubtitleTrackFilter.menu(Array(tracks.prefix(3)), preferredLanguages: ["en"]).isEmpty)
    }

    /// Owner 2026-09-28: no fallback to every language. The menu is Off alone.
    @Test func aStreamWithNoEnglishListsOnlyOff() {
        let tracks = [track(0, "spa", "Spanish"), track(1, "fre", "French", isDefault: true)]
        #expect(AppleSubtitleTrackFilter.menu(tracks, preferredLanguages: ["en"]).isEmpty)
        #expect(AppleSubtitleTrackFilter.visible(tracks, preferredLanguages: ["en"]).isEmpty)
        let entries = AppleSubtitleCueLayerPolicy.menuEntries(
            tracks: tracks, preferredLanguages: ["en"], languagesAreExplicit: false, activeTrackID: nil)
        #expect(entries.map(\.title) == ["Off"])
    }

    @Test func aPickedSpanishListsOnlySpanish() {
        let tracks = [track(0, "eng", "English", isDefault: true), track(1, "spa", "Spanish"),
                      track(2, "es-419", "Spanish SDH"), track(3, "fre", "French")]
        let choices = AppleSubtitleTrackFilter.menuChoices(tracks, preferredLanguages: ["spa"])
        #expect(choices.map(\.title) == ["Spanish", "Spanish (SDH)"])
        #expect(AppleSubtitleTrackFilter.visible(tracks, preferredLanguages: ["spa"], isExplicitChoice: true).map(\.id) == [1])
    }

    @Test func menuListsOnlyPreferredLanguagesInPreferenceOrder() {
        let tracks = [
            track(9, "de", "German"),
            track(8, "en", "English SDH"),
            track(7, "fr", "French", isDefault: true),
            track(6, "eng", "English", isDefault: true),
            track(5, "spa", "Spanish"),
            track(4, "it", "Italian"),
        ]
        let menu = AppleSubtitleTrackFilter.menu(tracks, preferredLanguages: ["English", "es-MX"])
        // English SDH sits under English, the language it belongs to.
        #expect(menu.map(\.id) == [6, 8, 5])
        #expect(AppleSubtitleTrackFilter.menu(tracks, preferredLanguages: ["it", "fr"]).map(\.id) == [4, 7])
        #expect(AppleSubtitleTrackFilter.visible(tracks, preferredLanguages: ["en"], isExplicitChoice: true).map(\.id) == [6])
        #expect(AppleSubtitleTrackFilter.visible(tracks, preferredLanguages: ["ja"], isExplicitChoice: true).isEmpty)
    }

    /// A forced track is its own row only beside a full one of its language;
    /// alone, a variant is simply that language.
    @Test func forcedIsItsOwnRowOnlyBesideAFullTrack() {
        let forced = ApplePlaybackTrack(id: 0, title: "English", language: "en", isDefault: true, isForced: true)
        let tracks = [forced, track(1, "es", "Spanish"), track(2, "en", "English SDH")]
        let choices = AppleSubtitleTrackFilter.menuChoices(tracks, preferredLanguages: ["en"])
        #expect(choices.map(\.track.id) == [2, 0])
        #expect(choices.map(\.title) == ["English", "English (Forced)"])
        #expect(AppleSubtitleTrackFilter.menuChoices([forced], preferredLanguages: ["en"]).map(\.title) == ["English"])
        #expect(AppleSubtitleTrackFilter.menu([], preferredLanguages: ["en"]).isEmpty)
    }

    @Test func menuDeduplicatesLanguageAndTitleWhileKeepingVariants() {
        let tracks = [
            track(0, "eng", "English"),
            track(4, "EN-us", " english ", isDefault: true),
            track(2, "en", "English SDH"),
            track(3, "es", "English"),
            track(5, "English", "English SDH"),
            track(6, nil, "Unlabelled"),
            track(7, nil, "Unlabelled"),
        ]
        // Track 3 is Spanish whatever its title says; 6 and 7 are untagged.
        #expect(AppleSubtitleTrackFilter.menu(tracks, preferredLanguages: ["en"]).map(\.id) == [4, 2])
        #expect(AppleSubtitleTrackFilter.menu(tracks.reversed(), preferredLanguages: ["en"]).map(\.id) == [4, 2])
    }

    @Test func menuLabelLanguageFormatting() {
        // menuLabel for language "eng" -> "English"
        #expect(AppleSubtitleTrackFilter.menuLabel(for: track(0, "eng")) == "English")
        
        // menuLabel for "en-US" -> "English"
        #expect(AppleSubtitleTrackFilter.menuLabel(for: track(0, "en-US")) == "English")
        
        // menuLabel for a track with no language and title "Subtitle 2" -> "Subtitle"
        #expect(AppleSubtitleTrackFilter.menuLabel(for: track(0, nil, "Subtitle 2")) == "Subtitle")
        
        // menuLabel title "English 1 (eng)" no language -> "English"
        #expect(AppleSubtitleTrackFilter.menuLabel(for: track(0, nil, "English 1 (eng)")) == "English")
    }

    @Test func normalisationReducesEveryFormToTheTwoLetterCode() {
        #expect(AppleSubtitleTrackFilter.normalized("eng") == "en")
        #expect(AppleSubtitleTrackFilter.normalized("EN-us") == "en")
        #expect(AppleSubtitleTrackFilter.normalized("English") == "en")
        #expect(AppleSubtitleTrackFilter.normalized("  spa ") == "es")
        #expect(AppleSubtitleTrackFilter.normalized("") == "")
        #expect(AppleSubtitleTrackFilter.normalized("en_GB") == "en")
        #expect(AppleSubtitleTrackFilter.normalized("fra") == "fr")
        #expect(AppleSubtitleTrackFilter.normalized("fre") == "fr")
        #expect(AppleSubtitleTrackFilter.normalized("Français") == "fr")
        #expect(AppleSubtitleTrackFilter.normalized("Español") == "es")
        #expect(AppleSubtitleTrackFilter.normalized("iw") == "he")
        #expect(AppleSubtitleTrackFilter.normalized("und") == "und")
    }
}
