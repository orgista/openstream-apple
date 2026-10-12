import Foundation
import Testing
@testable import OpenStreamApple

/// Full test 2026-10-01: "stranger things" listed the 2013 film first, twice
/// (Cinemeta and the TMDB add-on not merged), and the 2016 series third.
@MainActor
@Suite("Search exact-match ranking and IMDb merging")
struct AppleSearchExactMatchRankingTests {
    let cinemeta = UUID()
    let tmdb = UUID()

    private func catalogRecord(_ source: UUID, id: String, type: String, year: String,
                               imdbID: String? = nil) -> AppleMediaRecord {
        AppleMediaIngestion.catalogRecord(
            instanceID: source,
            item: AppleCatalogItem(mediaID: id, type: type, name: "Stranger Things",
                                   releaseInfo: year, imdbID: imdbID))
    }

    @Test func tmdbRowsMergeWithCinemetaByIMDbID() {
        let results = AppleCatalogSearchStore.mergedResults(
            [catalogRecord(cinemeta, id: "tt3007000", type: "movie", year: "2013"),
             catalogRecord(tmdb, id: "tmdb:250000", type: "movie", year: "2012", imdbID: "tt3007000")],
            matching: "stranger things", limit: 20)
        #expect(results.count == 1)
    }

    @Test func theSeriesMoreSourcesCarryAndNewerRanksFirst() {
        let results = AppleCatalogSearchStore.mergedResults(
            [catalogRecord(cinemeta, id: "tt3007000", type: "movie", year: "2013"),
             catalogRecord(tmdb, id: "tmdb:250000", type: "movie", year: "2013", imdbID: "tt3007000"),
             catalogRecord(cinemeta, id: "tt4574334", type: "series", year: "2016-"),
             catalogRecord(tmdb, id: "tmdb:66732", type: "series", year: "2016", imdbID: "tt4574334")],
            matching: "stranger things", limit: 20)
        #expect(results.map(\.canonicalID) == ["tt4574334", "tt3007000"])
    }

    @Test func aNonIMDbValueIsNotKept() {
        #expect(AppleCatalogItem(mediaID: "tmdb:1", type: "movie", name: "X", imdbID: "tmdb:1").imdbID == nil)
    }

    /// iOS 18.6 regression 2026-10-01: "General Hospital" put the 1963 soap
    /// below its 2008, 1994 and 1972 namesakes (newest first). Cinemeta
    /// answers with the soap first; its order is the popularity signal.
    @Test func equalExactMatchesKeepTheirAddOnsPopularityOrder() {
        func gh(_ id: String, _ year: String) -> AppleMediaRecord {
            AppleMediaIngestion.catalogRecord(
                instanceID: cinemeta,
                item: AppleCatalogItem(mediaID: id, type: "series", name: "General Hospital", releaseInfo: year))
        }
        let answer = [gh("tt0056758", "1963-"), gh("tt0196249", "1972-1980"),
                      gh("tt6283678", "2008-2009"), gh("tt31235905", "1994-1996")]
        let ranks = Dictionary(uniqueKeysWithValues: answer.enumerated().map { ($1.id, $0) })
        let results = AppleCatalogSearchStore.mergedResults(answer.reversed(), matching: "general hospital",
                                                            limit: 20, sourceRanks: ranks)
        #expect(results.map(\.canonicalID) == ["tt0056758", "tt0196249", "tt6283678", "tt31235905"])
        // Without ranks (a library-only answer), newest first as before.
        #expect(AppleCatalogSearchStore.mergedResults(answer, matching: "general hospital", limit: 20)
            .first?.canonicalID == "tt6283678")
    }

    /// A movie and a series each top their own catalog: the rank ties and
    /// "stranger things" still puts the newer series first.
    @Test func topOfEachCatalogFallsThroughToTheYear() {
        let film = catalogRecord(cinemeta, id: "tt3007000", type: "movie", year: "2013")
        let show = catalogRecord(cinemeta, id: "tt4574334", type: "series", year: "2016-")
        let results = AppleCatalogSearchStore.mergedResults([film, show], matching: "stranger things", limit: 20,
                                                            sourceRanks: [film.id: 0, show.id: 0])
        #expect(results.map(\.canonicalID) == ["tt4574334", "tt3007000"])
    }

    /// Apple TV pass 2026-10-02: "general hosp" (a prefix, not an exact
    /// match) put the 1963 soap third — namesakes in the prefix tier fell
    /// back to the id. They now order like exact matches, and the long
    /// running one leads the other "General Hospital…" titles.
    @Test func prefixNamesakesKeepTheAddOnsOrderAndTheLongRunnerLeads() {
        func gh(_ id: String, _ name: String, _ year: String) -> AppleMediaRecord {
            AppleMediaIngestion.catalogRecord(
                instanceID: cinemeta,
                item: AppleCatalogItem(mediaID: id, type: "series", name: name, releaseInfo: year))
        }
        let answer = [gh("tt0056758", "General Hospital", "1963-"), gh("tt0196249", "General Hospital", "1972-1980"),
                      gh("tt0983983", "General Hospital: Night Shift", "2007-2008"),
                      gh("tt6283678", "General Hospital", "2008-2009")]
        let ranks = Dictionary(uniqueKeysWithValues: answer.enumerated().map { ($1.id, $0) })
        let results = AppleCatalogSearchStore.mergedResults(answer.reversed(), matching: "general hosp",
                                                            limit: 20, sourceRanks: ranks)
        #expect(results.first?.canonicalID == "tt0056758")
    }

    /// Apple TV pass 2026-10-02: "dune" put a 4-minute short called "Dune"
    /// above Dune (2021), which Cinemeta titles "Dune: Part One".
    @Test func aKnownShortSortsBelowTheFeature() {
        let short = AppleCatalogItem(mediaID: "tt9000001", type: "movie", name: "Dune", releaseInfo: "2023",
                                     runtimeMinutes: 4)
        let feature = AppleCatalogItem(mediaID: "tt1160419", type: "movie", name: "Dune: Part One", releaseInfo: "2021",
                                       rating: 8.0, runtimeMinutes: 155, popularity: 1.5)
        let sequel = AppleCatalogItem(mediaID: "tt15239678", type: "movie", name: "Dune: Part Two", releaseInfo: "2024")
        let classic = AppleCatalogItem(mediaID: "tt0087182", type: "movie", name: "Dune", releaseInfo: "1984")
        let section = AppleCatalogSection(
            source: AppleSource(kind: .stremio, name: "Cinemeta", url: URL(string: "https://fixture.example/manifest.json")!),
            catalog: AppleStremioCatalog(type: "movie", id: "top", name: "Popular"),
            items: [short, feature, sequel, classic])
        let records = AppleMediaIngestion.catalogRecords(section: section)
        let results = AppleCatalogSearchStore.mergedResults(
            records, matching: "dune", limit: 20,
            sourceRanks: AppleCatalogSearchStore.sourceRanks([section]),
            prominence: AppleCatalogSearchStore.prominence([section]))
        // The feature first, then the add-on's order; the short goes last.
        #expect(results.map(\.canonicalID) == ["tt1160419", "tt15239678", "tt0087182", "tt9000001"])
    }

    @Test func runtimeAndRunLengthParse() {
        #expect(AppleSearchProminence.runtimeMinutes("155 min") == 155)
        #expect(AppleSearchProminence.runtimeMinutes("2h 35min") == 155)
        #expect(AppleSearchProminence.runtimeMinutes("1 h 5 m") == 65)
        #expect(AppleSearchProminence.runtimeMinutes("95") == 95)
        #expect(AppleSearchProminence.runtimeMinutes("N/A") == nil)
        #expect(AppleSearchProminence.runYears("1963-", currentYear: 2026) == 63)
        #expect(AppleSearchProminence.runYears("1972-1980", currentYear: 2026) == 8)
        #expect(AppleSearchProminence.runYears("2021", currentYear: 2026) == nil)
    }
}
