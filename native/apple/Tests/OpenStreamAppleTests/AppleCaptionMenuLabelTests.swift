import Foundation
import Testing
@testable import OpenStreamApple

/// The captions menu names every choice once, in words (owner 2026-09-24:
/// "captions also have English 1, 2 — it shouldn't have numbers or options").
struct AppleCaptionMenuLabelTests {
    /// What a Matroska release plus two sidecar subtitle files actually hands the
    /// menu: the engine's raw names, three English files, a B-code language.
    private static let messy: [ApplePlaybackTrack] = [
        ApplePlaybackTrack(id: 2, title: "English", language: "eng", codec: "subrip", isDefault: true),
        ApplePlaybackTrack(id: 3, title: "English SDH", language: "eng", codec: "subrip", isHearingImpaired: true),
        ApplePlaybackTrack(id: 4, title: "English Forced", language: "eng", codec: "subrip", isForced: true),
        ApplePlaybackTrack(id: 5, title: "FRE (srt)", language: "fre", codec: "subrip"),
        ApplePlaybackTrack(id: 6, title: "ENG (srt)", language: "eng", codec: "subrip"),
        ApplePlaybackTrack(id: 7, title: "Track 7 (hdmv_pgs_subtitle)", language: "spa", codec: "hdmv_pgs_subtitle"),
        ApplePlaybackTrack(id: 1_000_000, title: "English (OpenSubtitles v3)", language: "en"),
        ApplePlaybackTrack(id: 1_000_001, title: "English (Subsource)", language: "en"),
        ApplePlaybackTrack(id: 1_000_002, title: "Spanish (OpenSubtitles v3)", language: "es"),
    ]

    @Test func eachLanguageAndKindIsOneHumanNamedRow() {
        let choices = AppleSubtitleTrackFilter.menuChoices(Self.messy, preferredLanguages: ["en", "fr", "es"])
        #expect(choices.map(\.title) == ["English", "English (SDH)", "English (Forced)", "French", "Spanish"])
    }

    @Test func noRowCarriesANumberACodecOrASourceName() {
        let odd = Self.messy + [
            ApplePlaybackTrack(id: 20, title: "Subtitle 2", language: "de"),
            ApplePlaybackTrack(id: 21, title: "Track 3 (subrip)", language: "it", codec: "subrip"),
        ]
        let titles = AppleSubtitleCueLayerPolicy.menuEntries(tracks: odd, preferredLanguages: ["en", "fr", "es"],
            languagesAreExplicit: false, activeTrackID: nil).map(\.title)
        #expect(titles.first == "Off")
        for title in titles {
            #expect(title.rangeOfCharacter(from: .decimalDigits) == nil, "\(title)")
            #expect(!title.localizedCaseInsensitiveContains("srt") && !title.localizedCaseInsensitiveContains("subrip"))
            #expect(!title.contains("OpenSubtitles") && !title.contains("Subsource"))
        }
        #expect(Set(titles).count == titles.count, "a name appears twice: \(titles)")
    }

    /// The stream's own text track plays ahead of a sidecar file of the same
    /// language, and text ahead of a bitmap.
    @Test func theBestMemberPlays() {
        let english = AppleSubtitleTrackFilter.menuChoices(Self.messy, preferredLanguages: ["en"]).first
        #expect(english?.track.id == 2)
        #expect(Set(english?.memberIDs ?? []) == [2, 6, 1_000_000, 1_000_001])
        let spanish = AppleSubtitleTrackFilter.menuChoices(Self.messy, preferredLanguages: ["es"])
            .first { $0.title == "Spanish" }
        // PGS 7 against the sidecar text file: text wins even from a sidecar.
        #expect(spanish?.track.id == 1_000_002)
        let sidecarsOnly = [ApplePlaybackTrack(id: 1_000_004, title: "English (B)", language: "en"),
                          ApplePlaybackTrack(id: 1_000_003, title: "English (A)", language: "en")]
        #expect(AppleSubtitleTrackFilter.menuChoices(sidecarsOnly, preferredLanguages: ["en"]).map(\.track.id) == [1_000_003])
    }

    /// Whatever the engine picked by itself stays the ticked row, even when
    /// it is not the member the menu would have chosen.
    @Test func theActiveDuplicateKeepsTheCheckMark() {
        let entries = AppleSubtitleCueLayerPolicy.menuEntries(tracks: Self.messy, preferredLanguages: ["en"],
            languagesAreExplicit: false, activeTrackID: 6)
        let english = entries.first { $0.title == "English" }
        #expect(english?.trackID == 6)
        #expect(english?.isSelected == true)
        #expect(entries.filter(\.isSelected).count == 1)
        let viaSidecar = AppleSubtitleCueLayerPolicy.menuEntries(tracks: Self.messy, preferredLanguages: ["en"],
            languagesAreExplicit: false, activeTrackID: 1_000_001)
        #expect(viaSidecar.first { $0.title == "English" }?.isSelected == true)
    }

    @Test func aVariantAloneIsJustItsLanguage() {
        let sdhOnly = [ApplePlaybackTrack(id: 1, title: "English SDH", language: "en", isHearingImpaired: true)]
        #expect(AppleSubtitleTrackFilter.menuChoices(sdhOnly, preferredLanguages: ["en"]).map(\.title) == ["English"])
        let withCC = [ApplePlaybackTrack(id: 1, title: "English", language: "en", codec: "subrip"),
                      ApplePlaybackTrack(id: 2, title: "CC1", language: "en", codec: "eia_608")]
        #expect(AppleSubtitleTrackFilter.menuChoices(withCC, preferredLanguages: ["en"]).map(\.title) == ["English", "English (CC)"])
    }

    @Test func untaggedTitlesAreNumberedSubtitleChoices() {
        let tracks = [ApplePlaybackTrack(id: 0, title: "English", codec: "subrip"),
                      ApplePlaybackTrack(id: 1, title: "German", codec: "subrip"),
                      ApplePlaybackTrack(id: 2, title: "Subtitle 3", codec: "subrip")]
        // A track name is not language metadata (owner 2026-10-14).
        #expect(AppleSubtitleTrackFilter.menuChoices(tracks, preferredLanguages: ["en", "de"]).map(\.title)
            == ["Subtitles 1", "Subtitles 2", "Subtitles 3"])
    }

    /// Owner 2026-10-22: a Live channel's captions menu read "(unknown)".
    @Test func liveCaptionTracksAreNamedByLanguageOrService() {
        let taggedCaptions = [ApplePlaybackTrack(id: 99_608, title: "CC1", language: "en", codec: "eia_608")]
        #expect(AppleSubtitleTrackFilter.menuChoices(taggedCaptions, preferredLanguages: ["en"]).map(\.title)
            == ["English (CC)"])

        let untagged = [ApplePlaybackTrack(id: 99_609, title: "CC3", codec: "eia_608"),
                        ApplePlaybackTrack(id: 99_608, title: "Closed Captions", codec: "eia_608"),
                        ApplePlaybackTrack(id: 5, title: "(unknown)", codec: "dvb_subtitle"),
                        ApplePlaybackTrack(id: 6, title: "Track 6 (webvtt)", language: "und", codec: "webvtt")]
        #expect(AppleSubtitleTrackFilter.menuChoices(untagged, preferredLanguages: ["en"]).map(\.title)
            == ["Subtitles 1", "Subtitles 2", "CC1", "CC3"])

        let coded = [ApplePlaybackTrack(id: 1, title: "dvbsub", language: "deu", codec: "dvb_subtitle"),
                     ApplePlaybackTrack(id: 2, title: "Subtitle 2", language: "fr", codec: "webvtt")]
        #expect(AppleSubtitleTrackFilter.menuChoices(coded, preferredLanguages: ["de", "fr"]).map(\.title)
            == ["German", "French"])

        let twoCC1 = [ApplePlaybackTrack(id: 99_608, title: "CC1", codec: "eia_608"),
                      ApplePlaybackTrack(id: 99_609, title: "CC1", codec: "eia_608")]
        #expect(AppleSubtitleTrackFilter.menuChoices(twoCC1, preferredLanguages: ["en"]).map(\.title) == ["CC1", "CC1 (2)"])

        // A playlist that tags its rendition "unknown" or "undefined" gave a language row named after the tag.
        let wordTags = [ApplePlaybackTrack(id: 1, title: "(unknown)", language: "unknown", codec: "webvtt"),
                        ApplePlaybackTrack(id: 2, title: "Subtitle 2", language: "Undefined", codec: "webvtt")]
        #expect(AppleSubtitleTrackFilter.menuChoices(wordTags, preferredLanguages: ["en"]).map(\.title)
            == ["Subtitles 1", "Subtitles 2"])
        #expect(AppleSubtitleTrackFilter.otherLanguageChoices(wordTags, preferredLanguages: ["en"]).isEmpty)
        // A three-letter code with no two-letter form is still a language.
        let hawaiian = [ApplePlaybackTrack(id: 3, title: "haw", language: "haw", codec: "webvtt")]
        #expect(AppleSubtitleTrackFilter.menuChoices(hawaiian, preferredLanguages: ["haw"]).map(\.title) == ["Hawaiian"])

        let titles = AppleSubtitleCueLayerPolicy.menuEntries(tracks: taggedCaptions + untagged + coded + wordTags,
            preferredLanguages: ["en"], languagesAreExplicit: false, activeTrackID: nil).map(\.title)
            + AppleSubtitleCueLayerPolicy.moreMenuEntries(tracks: taggedCaptions + untagged + coded + wordTags,
                preferredLanguages: ["en"], activeTrackID: nil).map(\.title)
        #expect(!titles.contains { $0.localizedCaseInsensitiveContains("unknown") }, "\(titles)")
    }

    /// The app draws the Mac's captions now; a 12 pt cue under a 700 pt
    /// picture was unreadable (N38 frame), so cues scale with the picture.
    @Test func macCuesGrowWithThePicture() {
        #expect(AppleSubtitleCueLayerPolicy.macTextSize(base: 12, pictureHeight: 720) == 32)
        #expect(AppleSubtitleCueLayerPolicy.macTextSize(base: 12, pictureHeight: 200) == 12)
    }

    @Test func bibliographicCodesReadAsTheirLanguage() {
        #expect(AppleSubtitleTrackFilter.normalized("fre") == "fr")
        #expect(AppleSubtitleTrackFilter.normalized("ger") == "de")
        #expect(AppleSubtitleTrackFilter.normalized("dut") == "nl")
        #expect(AppleSubtitleTrackFilter.menuLabel(for: ApplePlaybackTrack(id: 0, title: "FRE (srt)", language: "fre"))
            == "French")
    }
}
