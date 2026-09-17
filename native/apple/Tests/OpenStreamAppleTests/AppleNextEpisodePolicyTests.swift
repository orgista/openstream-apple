import Foundation
import Testing
@testable import OpenStreamApple

@MainActor
@Suite("Next episode")
struct AppleNextEpisodePolicyTests {
    private func episode(_ season: Int?, _ number: Int?, _ title: String = "Ep") -> AppleStremioEpisode {
        AppleStremioEpisode(
            id: "s\(season.map(String.init) ?? "-")e\(number.map(String.init) ?? "-")",
            title: title, season: season, episode: number,
            releaseInfo: nil, runtimeMinutes: nil, overview: nil, thumbnailURL: nil
        )
    }

    private var season1: [AppleStremioEpisode] {
        [episode(1, 1), episode(1, 2), episode(1, 3)]
    }

    private var twoSeasons: [AppleStremioEpisode] {
        season1 + [episode(2, 1), episode(2, 2)]
    }

    // MARK: Which episode comes next

    @Test func theNextEpisodeIsTheOneAfterIt() {
        let next = AppleStremioEpisodePolicy.following(episode(1, 1), in: season1)
        #expect(next?.episode == 2)
    }

    /// The whole point: what follows the last episode of a season is the first
    /// of the next, not nothing.
    @Test func theLastEpisodeOfASeasonLeadsIntoTheNextSeason() {
        let next = AppleStremioEpisodePolicy.following(episode(1, 3), in: twoSeasons)
        #expect(next?.season == 2)
        #expect(next?.episode == 1)
    }

    @Test func theLastEpisodeOfTheShowHasNoNext() {
        #expect(AppleStremioEpisodePolicy.following(episode(2, 2), in: twoSeasons) == nil)
    }

    /// Order comes from `episodes(in:from:)`, so a muxed-up list still resolves
    /// the real successor.
    @Test func theSourceOrderDoesNotMatter() {
        let shuffled = [episode(1, 3), episode(2, 1), episode(1, 1), episode(1, 2)]
        #expect(AppleStremioEpisodePolicy.following(episode(1, 1), in: shuffled)?.episode == 2)
        #expect(AppleStremioEpisodePolicy.following(episode(1, 3), in: shuffled)?.season == 2)
    }

    @Test func anEpisodeThatIsNotInTheListHasNoNext() {
        #expect(AppleStremioEpisodePolicy.following(episode(9, 9), in: season1) == nil)
    }

    // MARK: When the card appears

    @Test func nothingIsOfferedUntilTheClosingSeconds() {
        #expect(AppleNextEpisodePolicy.prompt(position: 100, duration: 1800, nextTitle: "S1 E2") == nil)
    }

    @Test func theCardAppearsWithTheLeadTimeLeft() {
        let prompt = AppleNextEpisodePolicy.prompt(position: 1800 - 20, duration: 1800, nextTitle: "S1 E2")
        #expect(prompt?.title == "S1 E2")
        #expect(prompt?.secondsRemaining == 20)
    }

    @Test func theCountdownCountsDown() {
        let prompt = AppleNextEpisodePolicy.prompt(position: 1788, duration: 1800, nextTitle: "S1 E2")
        #expect(prompt?.secondsRemaining == 12)
        #expect(prompt?.countdownLabel == "Next Episode in 12s")
    }

    /// The label never reads "in 0s" — at the end it is just the action.
    @Test func theFinalTickDropsTheCountdown() {
        let prompt = AppleNextEpisodePolicy.prompt(position: 1800, duration: 1800, nextTitle: "S1 E2")
        #expect(prompt?.secondsRemaining == 0)
        #expect(prompt?.countdownLabel == "Next Episode")
    }

    @Test func aMovieNeverOffersOne() {
        #expect(AppleNextEpisodePolicy.prompt(position: 1795, duration: 1800, nextTitle: nil) == nil)
    }

    @Test func aLiveStreamNeverOffersOne() {
        #expect(AppleNextEpisodePolicy.prompt(
            position: 1795, duration: 1800, nextTitle: "S1 E2", isLive: true) == nil)
    }

    /// A stream whose duration has not arrived cannot say how long is left, and
    /// a card that cannot count down is worse than no card.
    @Test func anUnknownDurationOffersNothing() {
        #expect(AppleNextEpisodePolicy.prompt(position: 1795, duration: nil, nextTitle: "S1 E2") == nil)
        #expect(AppleNextEpisodePolicy.prompt(position: 1795, duration: .infinity, nextTitle: "S1 E2") == nil)
    }

    // MARK: Dismissal and auto-advance

    /// Dismissing is a real answer: it stops the card *and* the auto-advance
    /// for the rest of the episode, rather than postponing either.
    @Test func dismissingStopsTheCardAndTheAutoAdvance() {
        #expect(AppleNextEpisodePolicy.prompt(
            position: 1795, duration: 1800, nextTitle: "S1 E2", isDismissed: true) == nil)
        #expect(!AppleNextEpisodePolicy.shouldAutoAdvance(
            position: 1800, duration: 1800, nextTitle: "S1 E2", isDismissed: true))
    }

    @Test func theNextEpisodeStartsWhenThisOneRunsOut() {
        #expect(AppleNextEpisodePolicy.shouldAutoAdvance(
            position: 1800, duration: 1800, nextTitle: "S1 E2"))
    }

    @Test func itDoesNotStartEarly() {
        #expect(!AppleNextEpisodePolicy.shouldAutoAdvance(
            position: 1799, duration: 1800, nextTitle: "S1 E2"))
    }

    /// With the setting off the card still appears and still works — only the
    /// unattended start is suppressed.
    @Test func turningAutoPlayOffKeepsTheCardButNotTheAutoStart() {
        #expect(AppleNextEpisodePolicy.prompt(position: 1795, duration: 1800, nextTitle: "S1 E2") != nil)
        #expect(!AppleNextEpisodePolicy.shouldAutoAdvance(
            position: 1800, duration: 1800, nextTitle: "S1 E2", isEnabled: false))
    }

    @Test func aMovieNeverAutoAdvances() {
        #expect(!AppleNextEpisodePolicy.shouldAutoAdvance(
            position: 1800, duration: 1800, nextTitle: nil))
    }
}
