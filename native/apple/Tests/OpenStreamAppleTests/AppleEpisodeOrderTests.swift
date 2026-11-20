import Foundation
import Testing
@testable import OpenStreamApple

/// N32 #14: a daily show's season must read in number order, never string
/// order ("Episode 1000" before "Episode 816"), with the air date breaking ties.
@Suite("Episode order")
struct AppleEpisodeOrderTests {
    private func episode(_ id: String, _ season: Int?, _ number: Int?, aired: String? = nil) -> AppleMediaEpisode {
        AppleMediaEpisode(id: id, title: "Episode \(number.map(String.init) ?? "?")",
                            season: season, episode: number, releaseInfo: aired)
    }

    @Test func numbersSortNumerically() {
        let episodes = [episode("c", 1, 1000), episode("b", 1, 818), episode("d", 1, 9), episode("a", 1, 816), episode("e", 1, 1)]
        #expect(AppleMediaEpisodePolicy.episodes(in: 1, from: episodes).map(\.episode) == [1, 9, 816, 818, 1000])
    }

    @Test func seasonsSortBeforeEpisodes() {
        let episodes = [episode("x", 10, 1), episode("y", 2, 5), episode("z", 2, 1)]
        #expect(AppleMediaEpisodePolicy.episodes(in: nil, from: episodes).map(\.id) == ["z", "y", "x"])
    }

    @Test func sameNumberFallsBackToAirDateThenUndatedLast() {
        let episodes = [
            episode("undated", 1, 5),
            episode("late", 1, 5, aired: "1984-09-12T00:00:00.000Z"),
            episode("early", 1, 5, aired: "1984-09-10T00:00:00.000Z"),
        ]
        #expect(AppleMediaEpisodePolicy.episodes(in: 1, from: episodes).map(\.id) == ["early", "late", "undated"])
    }

    /// Apple TV regression 2026-10-01: Goede tijden, slechte tijden (7,301
    /// episodes, 37 seasons) stopped at 1,000 episodes and opened in the past.
    @Test func aDailySoapKeepsEverySeasonAndOpensOnTheLatest() {
        let episodes: [AppleMediaEpisode] = (1...37).flatMap { (season: Int) in
            (1...200).map { (number: Int) in episode("tt0096597:\(season):\(number)", season, number) }
        }
        #expect(AppleMediaEpisodePolicy.episodes(in: nil, from: episodes).count == 37 * 200)
        #expect(AppleMediaEpisodePolicy.seasons(in: episodes).last == 37)
        #expect(AppleMediaEpisodePolicy.initialSeason(in: episodes) == 37)
        // An ordinary series still opens on season 1.
        let short = [episode("a", 2, 1), episode("b", 1, 1)]
        #expect(AppleMediaEpisodePolicy.initialSeason(in: short) == 1)
    }

    @Test func dailySoapUpNextStartsInLatestSeasonUnlessWatched() {
        let soap: [AppleMediaEpisode] = (1...37).flatMap { (season: Int) in
            (1...30).map { (number: Int) in episode("s\(season)e\(number)", season, number) }
        }
        #expect(AppleMediaEpisodePolicy.upNext(from: soap, completedIDs: [])?.season == 37)
        // A watched episode still wins: Up Next follows it.
        #expect(AppleMediaEpisodePolicy.upNext(from: soap, completedIDs: ["s1e1"])?.id == "s1e2")
        let short = [episode("a", 1, 1), episode("b", 2, 1)]
        #expect(AppleMediaEpisodePolicy.upNext(from: short, completedIDs: [])?.season == 1)
    }
}
