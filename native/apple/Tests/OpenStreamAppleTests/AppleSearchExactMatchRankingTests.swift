import Foundation
import Testing
@testable import OpenStreamApple

/// Full test 2026-10-01: "stranger things" listed the 2013 film first, twice
/// (two sources not merged), and the 2016 series third.
@MainActor
@Suite("Search exact-match ranking and IMDb merging")
struct AppleSearchExactMatchRankingTests {
    let firstSource = UUID()
    let secondSource = UUID()

    private func catalogRecord(_ source: UUID, id: String, type: String, year: String,
                               imdbID: String? = nil) -> AppleMediaRecord {
        AppleMediaIngestion.catalogRecord(
            instanceID: source,
            item: AppleCatalogItem(mediaID: id, type: type, name: "Stranger Things",
                                   releaseInfo: year, imdbID: imdbID))
    }

    @Test func rowsFromTwoSourcesMergeByIMDbID() {
        let results = AppleCatalogSearchStore.mergedResults(
            [catalogRecord(firstSource, id: "tt3007000", type: "movie", year: "2013"),
             catalogRecord(secondSource, id: "tmdb:250000", type: "movie", year: "2012", imdbID: "tt3007000")],
            matching: "stranger things", limit: 20)
        #expect(results.count == 1)
    }

    @Test func theSeriesMoreSourcesCarryAndNewerRanksFirst() {
        let results = AppleCatalogSearchStore.mergedResults(
            [catalogRecord(firstSource, id: "tt3007000", type: "movie", year: "2013"),
             catalogRecord(secondSource, id: "tmdb:250000", type: "movie", year: "2013", imdbID: "tt3007000"),
             catalogRecord(firstSource, id: "tt4574334", type: "series", year: "2016-"),
             catalogRecord(secondSource, id: "tmdb:66732", type: "series", year: "2016", imdbID: "tt4574334")],
            matching: "stranger things", limit: 20)
        #expect(results.map(\.canonicalID) == ["tt4574334", "tt3007000"])
    }

    @Test func aNonIMDbValueIsNotKept() {
        #expect(AppleCatalogItem(mediaID: "tmdb:1", type: "movie", name: "X", imdbID: "tmdb:1").imdbID == nil)
    }

    @Test func equalExactMatchesFromOneSourceSortNewestFirst() {
        func gh(_ id: String, _ year: String) -> AppleMediaRecord {
            AppleMediaIngestion.catalogRecord(
                instanceID: firstSource,
                item: AppleCatalogItem(mediaID: id, type: "series", name: "General Hospital", releaseInfo: year))
        }
        let answer = [gh("tt0056758", "1963-"), gh("tt0196249", "1972-1980"),
                      gh("tt6283678", "2008-2009"), gh("tt31235905", "1994-1996")]
        #expect(AppleCatalogSearchStore.mergedResults(answer, matching: "general hospital", limit: 20)
            .map(\.canonicalID) == ["tt6283678", "tt31235905", "tt0196249", "tt0056758"])
    }
}
