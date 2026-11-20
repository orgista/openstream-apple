import Foundation
import Testing
@testable import OpenStreamApple

struct AppleRecommendationRowScorerTests {
    private let now = Date(timeIntervalSince1970: 1_793_664_000)

    private func title(_ id: String, completed: Bool = false, resumable: Bool = false,
                       genres: [String] = ["Drama"]) -> AppleRecommendationRowScorer.Title {
        .init(rankable: .init(id: id, genres: genres, releaseYear: 2020, metadataCompleteness: 1,
            isResumable: resumable, isCompleted: completed), name: id)
    }

    private func finished(_ count: Int) -> [AppleViewingSignal] {
        (0..<count).map { .init(titleID: "seed-\($0)", genres: ["Drama"], at: now, completed: true) }
    }

    @Test func coldStartAndLikesDoNotGenerateThemedOrPersonalizedRows() async throws {
        let values = (0..<160).map { title("title-\($0)") }
        #expect(try await AppleRecommendationRowScorer.build(values, history: [], ratings: ["title-0": .up], listIDs: ["title-1"], now: now).isEmpty)
    }

    @Test(arguments: [0, 9, 10, 11])
    func onlyTenDistinctFinishedTitlesEnableOneSeedRow(count: Int) async throws {
        let values = (0..<11).map { title("seed-\($0)", completed: true) } + (0..<30).map { title("related-\($0)") }
        let rows = try await AppleRecommendationRowScorer.build(values, history: finished(count), ratings: [:], listIDs: [], now: now)
        #expect(rows.count == (count >= 10 ? 1 : 0))
        if count >= 10 {
            let row = try #require(rows.first)
            #expect(row.heading == "Because You Watched seed-0")
            #expect(row.minimumCount == 8)
            #expect(row.ids.count == 20)
            #expect(row.ids.allSatisfy { $0.hasPrefix("related-") })
        }
    }

    @Test(arguments: [7, 8])
    func seedRowRequiresEightUnwatchedItems(count: Int) async throws {
        let values = [title("seed-0", completed: true)] + (0..<count).map { title("related-\($0)") }
            + [title("completed", completed: true), title("resuming", resumable: true)]
        let rows = try await AppleRecommendationRowScorer.build(values, history: finished(10), ratings: [:], listIDs: [], now: now)
        #expect(rows.count == (count >= 8 ? 1 : 0))
        #expect(rows.flatMap(\.ids).contains("completed") == false)
        #expect(rows.flatMap(\.ids).contains("resuming") == false)
    }

    @Test func tenEpisodesOfOneShowDoNotCountAsTenFinishedTitles() async throws {
        let history = (0..<20).map { AppleViewingSignal(titleID: "episode-\($0)", genres: ["Drama"], at: now, completed: true, showID: "seed-0") }
        let values = [title("seed-0")] + (0..<20).map { title("related-\($0)") }
        #expect(try await AppleRecommendationRowScorer.build(values, history: history, ratings: [:], listIDs: [], now: now).isEmpty)
    }

    @Test func dislikedSeedsAndUnrelatedTitlesDoNotFillTheRow() async throws {
        let values = [title("seed-0")] + (0..<20).map { title("unrelated-\($0)", genres: ["Comedy"]) }
        #expect(try await AppleRecommendationRowScorer.build(values, history: finished(10), ratings: [:], listIDs: [], now: now).isEmpty)
        #expect(try await AppleRecommendationRowScorer.build(values, history: finished(10), ratings: ["seed-0": .down], listIDs: [], now: now).isEmpty)
    }

    @Test func callerCanDisableTheSeedRowAndInputOrderDoesNotChangeIt() async throws {
        let values = [title("seed-0")] + (0..<20).map { title("related-\($0)") }
        #expect(try await AppleRecommendationRowScorer.build(values, history: finished(10), ratings: [:], listIDs: [], now: now, limit: 0).isEmpty)
        let first = try await AppleRecommendationRowScorer.build(values, history: finished(10), ratings: [:], listIDs: [], now: now)
        let reversed = try await AppleRecommendationRowScorer.build(Array(values.reversed()), history: finished(10), ratings: [:], listIDs: [], now: now)
        #expect(first == reversed)
    }

    @Test func completionAndRecentHistoryCarryMoreWeightThanAnOldPartial() {
        let completed = AppleViewingSignal(titleID: "a", genres: ["Drama"], at: now, completed: true)
        let partial = AppleViewingSignal(titleID: "a", genres: ["Drama"], at: now.addingTimeInterval(-60 * 86400), completed: false)
        let strong = AppleRecommendationRowScorer.affinities([title("target")], history: [completed], ratings: [:], listIDs: [], now: now)
        let weak = AppleRecommendationRowScorer.affinities([title("target")], history: [partial], ratings: [:], listIDs: [], now: now)
        #expect((strong["target"] ?? 0) > (weak["target"] ?? 0))
    }

    @Test func repeatedEpisodesAndDislikedSeedsDoNotAmplifyTaste() {
        let history = (0..<100).map { AppleViewingSignal(titleID: "ep-\($0)", genres: ["Drama"], at: now, completed: true, showID: "show") }
        let values = [title("target")]
        let single = AppleRecommendationRowScorer.affinities(values, history: Array(history.prefix(1)), ratings: [:], listIDs: [], now: now)
        #expect(AppleRecommendationRowScorer.affinities(values, history: history, ratings: [:], listIDs: [], now: now) == single)
        #expect(AppleRecommendationRowScorer.affinities(values, history: history, ratings: ["show": .down], listIDs: [], now: now)["target"] == 0)
    }

    @Test func libraryAndChartAliasesShareOneDisplayIdentity() {
        let owned = AppleCatalogItem(mediaID: "tt0000001", type: "movie", name: "Hárbor  Lights", year: 2020)
        let chart = AppleCatalogItem(mediaID: "tmdb:movie:42", type: "movie", name: "harbor lights", year: 2020)
        let remake = AppleCatalogItem(mediaID: "tmdb:movie:43", type: "movie", name: "Harbor Lights", year: 2021)
        #expect(AppleRecommendationRowScorer.displayIdentity(owned) == AppleRecommendationRowScorer.displayIdentity(chart))
        #expect(AppleRecommendationRowScorer.displayIdentity(owned) != AppleRecommendationRowScorer.displayIdentity(remake))
    }

    @Test func cachedDeckExpiresAtTheDailyBoundary() async throws {
        let first = try #require(AppleDiscoverRecommendationCache.key(scope: "fixture", state: .init(), now: now))
        let same = try #require(AppleDiscoverRecommendationCache.key(scope: "fixture", state: .init(), now: now.addingTimeInterval(3600)))
        let next = try #require(AppleDiscoverRecommendationCache.key(scope: "fixture", state: .init(), now: now.addingTimeInterval(86400)))
        #expect(first == same)
        #expect(first != next)
    }
}
