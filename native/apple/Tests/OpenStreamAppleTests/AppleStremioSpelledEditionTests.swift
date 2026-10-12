import Foundation
import Testing
@testable import OpenStreamApple

/// iPhone 27 v2 re-run: SNL S1 E1 and E2 (1975) still played "Saturday Night
/// Live U K … 2026" — the tag was spelled out letter by letter and the air
/// date was fifty years off. Release-style fixture names.
@Suite struct AppleStremioSpelledEditionTests {
    let title = "Saturday Night Live"

    private func candidate(_ name: String, _ file: String) -> AppleStremioHTTPPlaybackCandidate {
        AppleStremioHTTPPlaybackCandidate(title: name, sourceURL: URL(string: "https://fixture.example/\(file)")!)
    }

    @Test(arguments: [
        "Saturday Night Live U K S01E01 1080p WEB h264",
        "Saturday.Night.Live.U.K.S01E01.1080p.WEB.h264-KOGi",
        "Saturday Night Live (U.K.) S01E01 720p",
    ])
    func spelledCountryTagsAreCountryTags(name: String) {
        #expect(AppleStremioTitleMatch.tail(of: name, title: title) == .qualifier("uk"))
    }

    @Test func spelledUSIsATagButOrdinaryLettersAreNot() {
        #expect(AppleStremioTitleMatch.tail(of: "The.Office.U.S.S01E01.720p", title: "The Office") == .qualifier("us"))
        #expect(AppleStremioTitleMatch.joiningSpelledTags(["a", "b", "show"]) == ["a", "b", "show"])
        #expect(AppleStremioTitleMatch.joiningSpelledTags(["show", "u", "s", "a", "s01e01"]) == ["show", "usa", "s01e01"])
    }

    @Test func anAirDateSeasonOneCouldNotHaveHadIsAConflict() {
        #expect(AppleStremioTitleMatch.airYearConflicts(
            "Saturday Night Live U K S01E01 Episode 1 March 21 2026", year: 1975, season: 1))
        #expect(!AppleStremioTitleMatch.airYearConflicts(
            "Saturday.Night.Live.S01E01.1975.10.11.George.Carlin", year: 1975, season: 1))
        #expect(!AppleStremioTitleMatch.airYearConflicts("Saturday.Night.Live.S01E01.1976.DVDRip", year: 1975, season: 1))
        // A later season moves the window with it.
        #expect(!AppleStremioTitleMatch.airYearConflicts("Saturday.Night.Live.S10E01.1984.10.06", year: 1975, season: 10))
        // Without a year or a season, or for a daily show numbered by year, nothing.
        #expect(!AppleStremioTitleMatch.airYearConflicts("Show S01E01 2026", year: nil, season: 1))
        #expect(!AppleStremioTitleMatch.airYearConflicts("Show S01E01 2026", year: 1975, season: nil))
        #expect(!AppleStremioTitleMatch.airYearConflicts("Show 2024 10 05", year: 1975, season: 2024))
        // Resolutions and codecs are not years.
        #expect(!AppleStremioTitleMatch.airYearConflicts("Show.S01E01.2160p.x265", year: 1975, season: 1))
    }

    @Test func theSpelledUKEditionGoesBehindThe1975Show() {
        let uk = candidate("Saturday Night Live U K S01E01 Episode 1 March 21 2026 1080p WEB h264", "uk.mkv")
        let original = candidate("Saturday.Night.Live.S01E01.George.Carlin.480p.DVDRip.x264", "us.mkv")
        let ranked = AppleStremioCandidateRanking.rankForAutomaticPlayback(
            [uk, original], episode: (season: 1, episode: 1), title: title, year: 1975)
        #expect(ranked.map(\.sourceURL.lastPathComponent) == ["us.mkv", "uk.mkv"])
    }

    /// An air date alone, with no tag and nothing untagged to compare with,
    /// still demotes.
    @MainActor @Test func theAirYearAloneDemotesInThePickerOrderToo() {
        let late = candidate("Saturday Night Live S01E02 March 28 2026 1080p WEB", "late.mkv")
        let original = candidate("Saturday.Night.Live.S01E02.Paul.Simon.480p", "original.mkv")
        let order = AppleStremioCandidateRanking.playbackOrder(
            [late, original], choice: .automatic, device: .current, episode: (1, 2), title: title, year: 1975)
        #expect(order.map(\.sourceURL.lastPathComponent) == ["original.mkv", "late.mkv"])
    }

    /// Demote, never drop: when every name conflicts, every name is still there.
    @Test func everythingConflictingIsStillOffered() {
        let a = candidate("Saturday Night Live U K S01E01 2026 1080p", "a.mkv")
        let b = candidate("Saturday Night Live U K S01E01 2026 720p", "b.mkv")
        let ranked = AppleStremioCandidateRanking.rankForAutomaticPlayback(
            [b, a], episode: (1, 1), title: title, year: 1975)
        #expect(ranked.count == 2)
        #expect(ranked.first?.sourceURL.lastPathComponent == "a.mkv")
    }
}
