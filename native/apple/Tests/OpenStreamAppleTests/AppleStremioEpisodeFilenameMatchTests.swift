import Foundation
import Testing
@testable import OpenStreamApple

/// Owner, TestFlight build 10: "The Secret Lives of Mormon Wives" plays a
/// **different show** for episodes 1–2 — the same wrong one every time — while
/// picking another source by hand plays the right one. Ranking sorted purely by
/// resolution, size and container, so a mislabelled release that happened to be
/// large and 1080p won deterministically.
@Suite("Episode markers in release names")
struct AppleStremioEpisodeFilenameMatchTests {
    @Test func theCommonNotationsAreAllRead() {
        for name in ["Show.S01E02.1080p.WEB.mkv", "show s1.e2 720p", "Show 1x02 HDTV",
                     "Show Season 1 Episode 2"] {
            let markers = AppleStremioEpisodeFilenameMatch.markers(in: name)
            #expect(markers.contains { $0.season == 1 && $0.episode == 2 }, "missed \(name)")
        }
    }

    @Test func aNameStatingAnotherEpisodeContradicts() {
        #expect(AppleStremioEpisodeFilenameMatch.contradicts(
            "Some.Other.Show.S01E05.1080p.mkv", season: 1, episode: 1))
        #expect(AppleStremioEpisodeFilenameMatch.contradicts(
            "Show.S02E01.mkv", season: 1, episode: 1))
    }

    @Test func theRightEpisodeDoesNotContradict() {
        #expect(!AppleStremioEpisodeFilenameMatch.contradicts(
            "The.Secret.Lives.of.Mormon.Wives.S01E01.1080p.WEB.mkv", season: 1, episode: 1))
    }

    /// A season pack names no episode, and the file index inside the torrent is
    /// what chooses. Treating that as a contradiction would reject the packs
    /// that legitimately carry the episode.
    @Test func aSeasonPackIsNotAContradiction() {
        for name in ["The.Secret.Lives.of.Mormon.Wives.S01.COMPLETE.1080p.WEB",
                     "Show Season 1 Pack", "Show.1080p.WEB-DL"] {
            #expect(!AppleStremioEpisodeFilenameMatch.contradicts(name, season: 1, episode: 1),
                    "\(name) should not be treated as contradicting")
        }
    }

    /// A name listing a range covering the episode must not be rejected.
    @Test func aNameNamingSeveralEpisodesIncludingOursIsKept() {
        #expect(!AppleStremioEpisodeFilenameMatch.contradicts(
            "Show.S01E01.S01E02.dual.mkv", season: 1, episode: 2))
    }

    @Test func doubleDigitSeasonsAndEpisodesParse() {
        #expect(AppleStremioEpisodeFilenameMatch.contradicts(
            "Show.S10E11.mkv", season: 10, episode: 12))
        #expect(!AppleStremioEpisodeFilenameMatch.contradicts(
            "Show.S10E11.mkv", season: 10, episode: 11))
    }

    /// The whole point: the wrong-episode release must sort below a correct one
    /// even when it is the higher resolution.
    @Test func aContradictingReleaseLosesToACorrectOneDespiteBetterQuality() {
        let wrong = AppleStremioHTTPPlaybackCandidate(
            title: "Some Other Show S01E05 2160p",
            sourceURL: URL(string: "https://example.com/wrong.mkv")!,
            filename: "Some.Other.Show.S01E05.2160p.mkv")
        let right = AppleStremioHTTPPlaybackCandidate(
            title: "Mormon Wives S01E01 720p",
            sourceURL: URL(string: "https://example.com/right.mkv")!,
            filename: "The.Secret.Lives.of.Mormon.Wives.S01E01.720p.mkv")

        let ranked = AppleStremioCandidateRanking.rankForAutomaticPlayback(
            [wrong, right], episode: (season: 1, episode: 1))
        #expect(ranked.first?.filename == right.filename,
                "the wrong-episode release still won")
    }

    /// Without an episode the old behaviour is unchanged — quality decides.
    @Test func withoutAnEpisodeQualityStillDecides() {
        let low = AppleStremioHTTPPlaybackCandidate(
            title: "A 720p", sourceURL: URL(string: "https://example.com/a.mkv")!,
            filename: "A.720p.mkv")
        let high = AppleStremioHTTPPlaybackCandidate(
            title: "B 2160p", sourceURL: URL(string: "https://example.com/b.mkv")!,
            filename: "B.2160p.mkv")
        #expect(AppleStremioCandidateRanking.rankForAutomaticPlayback([low, high]).first?.filename
                == high.filename)
    }
}
