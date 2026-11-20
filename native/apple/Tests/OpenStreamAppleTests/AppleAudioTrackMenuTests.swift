import Testing
@testable import OpenStreamApple

/// Full test 2026-10-01: the audio menu read "ENG (ac3) (eng)" and showed no
/// check mark on the track playing.
@Suite("Audio menu labels and selection")
struct AppleAudioTrackMenuTests {
    static let tracks = [
        ApplePlaybackTrack(id: 1, title: "ENG (ac3)", language: "eng", codec: "ac3", isDefault: true, channels: 6),
        ApplePlaybackTrack(id: 2, title: "SPA (aac)", language: "spa", codec: "aac", channels: 2),
        ApplePlaybackTrack(id: 3, title: "Director's Commentary", language: "eng", codec: "aac", channels: 2),
    ]

    @Test func labelsAreHuman() {
        let titles = AppleAudioTrackMenu.entries(Self.tracks, activeTrackID: nil).map(\.title)
        #expect(titles == ["English · AC-3 5.1", "Spanish · AAC Stereo", "Commentary"])
    }

    @Test func theDefaultIsCheckedUntilTheEngineSaysOtherwise() {
        #expect(AppleAudioTrackMenu.entries(Self.tracks, activeTrackID: nil).filter(\.isSelected).map(\.trackID) == [1])
        #expect(AppleAudioTrackMenu.entries(Self.tracks, activeTrackID: 2).filter(\.isSelected).map(\.trackID) == [2])
    }

    @Test func identicalLabelsAreOneRowStandingForThePlayingTrack() {
        let twins = [
            ApplePlaybackTrack(id: 4, title: "ENG (eac3)", language: "eng", codec: "eac3", channels: 6),
            ApplePlaybackTrack(id: 5, title: "ENG (eac3)", language: "eng", codec: "eac3", channels: 6),
        ]
        let entries = AppleAudioTrackMenu.entries(twins, activeTrackID: 5)
        #expect(entries.count == 1)
        #expect(entries.first?.trackID == 5)
        #expect(entries.first?.isSelected == true)
        #expect(entries.first?.title == "English · E-AC-3 5.1")
    }

    /// Codec names only, never a licensed format brand (licence audit 2026-10-22).
    @Test func objectAudioReadsAsItsCodecAndCommentaryIsFlagged() {
        let atmos = ApplePlaybackTrack(id: 1, title: "", language: "en", codec: "truehd", channels: 8, isAtmos: true)
        #expect(AppleAudioTrackMenu.label(for: atmos) == "English · TrueHD 7.1")
        let dts = ApplePlaybackTrack(id: 3, title: "", language: "en", codec: "dts", channels: 6)
        #expect(AppleAudioTrackMenu.label(for: dts) == "English · DTS 5.1")
        let flagged = ApplePlaybackTrack(id: 2, title: "Track 2", language: "en", codec: "aac", isCommentary: true)
        #expect(AppleAudioTrackMenu.label(for: flagged) == "Commentary")
    }
}

/// Full test 2026-10-01: with English as the language, Spanish was unreachable.
@Suite("Subtitle menu More…")
struct AppleSubtitleMoreMenuTests {
    static let tracks = [
        ApplePlaybackTrack(id: 1, title: "English", language: "eng", codec: "subrip"),
        ApplePlaybackTrack(id: 2, title: "Spanish", language: "spa", codec: "subrip"),
        ApplePlaybackTrack(id: 3, title: "French", language: "fre", codec: "subrip"),
        ApplePlaybackTrack(id: 4, title: "English SDH", language: "eng", codec: "subrip", isHearingImpaired: true),
    ]

    @Test func otherLanguagesSitUnderMoreAlphabetically() {
        let main = AppleSubtitleCueLayerPolicy.menuEntries(
            tracks: Self.tracks, preferredLanguages: ["en"], languagesAreExplicit: true, activeTrackID: nil)
        #expect(!main.map(\.title).contains("Spanish"))
        let more = AppleSubtitleCueLayerPolicy.moreMenuEntries(
            tracks: Self.tracks, preferredLanguages: ["en"], activeTrackID: nil)
        #expect(more.map(\.title) == ["French", "Spanish"])
    }

    @Test func aPickFromMoreCarriesTheCheckMark() {
        let more = AppleSubtitleCueLayerPolicy.moreMenuEntries(
            tracks: Self.tracks, preferredLanguages: ["en"], activeTrackID: 2)
        #expect(more.first { $0.isSelected }?.trackID == 2)
    }

    @Test func noOtherLanguagesMeansNoMore() {
        #expect(AppleSubtitleCueLayerPolicy.moreMenuEntries(
            tracks: Array(Self.tracks.prefix(1)), preferredLanguages: ["en"], activeTrackID: nil).isEmpty)
    }
}
