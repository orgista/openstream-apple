import Foundation
import Testing
@testable import OpenStreamApple

/// Names are the real Torrentio answer for tt31091039:1:1 on 2026-09-17.
@Suite struct AppleStremioTitleMatchTests {
    let title = "The Secret Lives of Mormon Wives"

    @Test func otherShowsThatShareWordsContradict() {
        #expect(AppleStremioTitleMatch.contradicts("Secret Lives of Gypsy Wives S01E01 1080p HDTV H264-DARKFLiX", title: title))
        #expect(AppleStremioTitleMatch.contradicts("Secret Sex Lives of Tyrants S01E01 1080p WEB h264-EDITH", title: title))
    }

    @Test func theRightShowInAnyReleaseSpellingDoesNot() {
        #expect(!AppleStremioTitleMatch.contradicts("The.Secret.Lives.of.Mormon.Wives.S01.COMPLETE.1080p.WEB.h264-EDITH[TGx]", title: title))
        #expect(!AppleStremioTitleMatch.contradicts("The Secret Lives of Mormon Wives S01E01 1080p WEB h264-EDITH", title: title))
        #expect(!AppleStremioTitleMatch.contradicts("the_secret_lives_of_mormon_wives_s01e01.mkv", title: title))
    }

    @Test func silenceAndSubtitledTitlesAreNotContradictions() {
        #expect(!AppleStremioTitleMatch.contradicts("a1b2c3d4.mkv", title: title))
        #expect(!AppleStremioTitleMatch.contradicts("Andor.S01E01.1080p.WEB.h264-CAKES", title: "Star Wars: Andor"))
        #expect(AppleStremioTitleMatch.contradicts("The.Mandalorian.S01E01.1080p.WEB.h264-CAKES", title: "Star Wars: Andor"))
        #expect(!AppleStremioTitleMatch.contradicts("9-11.One.Day.in.America.S01E01.1080p", title: "9/11: One Day in America"))
    }

    @Test func rankingPutsTheRightShowFirstEvenAtLowerQuality() {
        let gypsy = AppleStremioHTTPPlaybackCandidate(
            title: "Secret Lives of Gypsy Wives S01E01 1080p HDTV H264-DARKFLiX",
            sourceURL: URL(string: "https://fixture.example/gypsy.mkv")!)
        let tyrants = AppleStremioHTTPPlaybackCandidate(
            title: "Secret Sex Lives Of Tyrants S01E01 720p WEB H264-JFF",
            sourceURL: URL(string: "https://fixture.example/tyrants.mkv")!)
        let mormon720 = AppleStremioHTTPPlaybackCandidate(
            title: "The.Secret.Lives.of.Mormon.Wives.S01.COMPLETE.720p.WEBRip.x264-GalaxyTV",
            sourceURL: URL(string: "https://fixture.example/mormon.mkv")!,
            filename: "The.Secret.Lives.of.Mormon.Wives.S01E01.720p.WEBRip.x264-GalaxyTV.mkv")
        let ranked = AppleStremioCandidateRanking.rankForAutomaticPlayback(
            [gypsy, tyrants, mormon720], episode: (season: 1, episode: 1), title: "The Secret Lives of Mormon Wives")
        #expect(ranked.first?.sourceURL == mormon720.sourceURL, "another show's S01E01 still won")
        #expect(ranked.map(\.sourceURL.lastPathComponent) == ["mormon.mkv", "gypsy.mkv", "tyrants.mkv"])
    }

    @Test func withoutATitleTheOldOrderStands() {
        let gypsy = AppleStremioHTTPPlaybackCandidate(title: "Secret Lives of Gypsy Wives S01E01 1080p", sourceURL: URL(string: "https://fixture.example/g.mkv")!)
        let mormon = AppleStremioHTTPPlaybackCandidate(title: "The Secret Lives of Mormon Wives S01E01 720p", sourceURL: URL(string: "https://fixture.example/m.mkv")!)
        #expect(AppleStremioCandidateRanking.rankForAutomaticPlayback([gypsy, mormon], episode: (1, 1)).first?.sourceURL == gypsy.sourceURL)
    }
}

/// Full test 2026-09-30: Saturday Night Live S1 E1 (1975, tt0072562) played
/// "Saturday Night Live UK S01E01". Names are release-style fixtures.
@Suite struct AppleStremioEditionMatchTests {
    let title = "Saturday Night Live"

    private func candidate(_ name: String, _ file: String) -> AppleStremioHTTPPlaybackCandidate {
        AppleStremioHTTPPlaybackCandidate(title: name, sourceURL: URL(string: "https://fixture.example/\(file)")!)
    }

    @Test func theWordAfterTheTitleIsRead() {
        #expect(AppleStremioTitleMatch.tail(of: "Saturday.Night.Live.UK.S01E01.1080p.WEB.h264-KOGi", title: title) == .qualifier("uk"))
        #expect(AppleStremioTitleMatch.tail(of: "Saturday.Night.Live.S01E01.Rob.Reiner.1975.DVDRip.x264", title: title) == .bare)
        #expect(AppleStremioTitleMatch.tail(of: "Doctor.Who.2005.S01E01.720p.BluRay", title: "Doctor Who") == .year(2005))
        // A daily show's air date is not the show's year.
        #expect(AppleStremioTitleMatch.tail(of: "Saturday.Night.Live.2024.10.05.Nate.Bargatze.1080p", title: title) == .unknown)
        #expect(AppleStremioTitleMatch.tail(of: "a1b2c3d4.mkv", title: title) == .unknown)
        // A tag the title itself carries is not a different edition.
        #expect(AppleStremioTitleMatch.tail(of: "Saturday.Night.Live.UK.S01E01.1080p", title: "Saturday Night Live UK") == .bare)
    }

    @Test func anotherCountrysEditionGoesBehindTheUntaggedOne() {
        let uk = candidate("Saturday.Night.Live.UK.S01E01.1080p.WEB.h264-KOGi", "uk.mkv")
        let original = candidate("Saturday.Night.Live.S01E01.Rob.Reiner.1975.DVDRip.x264", "us.mkv")
        let ranked = AppleStremioCandidateRanking.rankForAutomaticPlayback(
            [uk, original], episode: (season: 1, episode: 1), title: title, year: 1975)
        #expect(ranked.map(\.sourceURL.lastPathComponent) == ["us.mkv", "uk.mkv"])
    }

    @Test func withNothingUntaggedNoEditionIsDemoted() {
        let uk = candidate("The.Office.UK.S01E01.720p.BluRay.x264", "uk.mkv")
        let us = candidate("The.Office.US.S01E01.1080p.WEB-DL.x264", "us.mkv")
        #expect(AppleStremioTitleMatch.mismatches(
            ["The.Office.UK.S01E01.720p", "The.Office.US.S01E01.1080p"], title: "The Office", year: 2001) == [false, false])
        // Quality decides, as before.
        #expect(AppleStremioCandidateRanking.rankForAutomaticPlayback(
            [uk, us], episode: (1, 1), title: "The Office", year: 2001).first?.sourceURL == us.sourceURL)
    }

    @Test func aConflictingYearGoesBehind() {
        let reboot = candidate("Doctor.Who.2005.S01E01.1080p.BluRay.x264", "2005.mkv")
        let classic = candidate("Doctor.Who.1963.S01E01.576p.DVDRip", "1963.mkv")
        let ranked = AppleStremioCandidateRanking.rankForAutomaticPlayback(
            [reboot, classic], episode: (1, 1), title: "Doctor Who", year: 1963)
        #expect(ranked.first?.sourceURL == classic.sourceURL)
        // One year either way is the same title (festival vs release year).
        #expect(AppleStremioTitleMatch.mismatches(["Dune.2021.2160p.WEB"], title: "Dune", year: 2020) == [false])
        // Without a year, a year in the name is no conflict.
        #expect(AppleStremioTitleMatch.mismatches(["Doctor.Who.2005.S01E01"], title: "Doctor Who") == [false])
    }

    @MainActor @Test func theQualityPickerOrderAgrees() {
        let uk = candidate("Saturday.Night.Live.UK.S01E01.1080p.WEB.h264-KOGi", "uk.mkv")
        let original = candidate("Saturday.Night.Live.S01E01.1975.480p.DVDRip.x264", "us.mkv")
        let order = AppleStremioCandidateRanking.playbackOrder(
            [uk, original], choice: .automatic, device: .current, episode: (1, 1), title: title, year: 1975)
        #expect(order.first?.sourceURL == original.sourceURL)
    }
}
