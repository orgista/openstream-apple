import Foundation
import Testing
@testable import OpenStreamApple

@Test func shelfDeduplicationKeepsTheFirstEntryForARepeatedIdentifier() {
    struct Entry: Identifiable, Equatable { let id: String; let name: String }
    let merged = [Entry(id: "a", name: "local"), Entry(id: "b", name: "server"),
                  Entry(id: "a", name: "server copy"), Entry(id: "c", name: "local")]
    // Two cards under one identifier is undefined for `ForEach` and ambiguous
    // for a UI test: Continue Watching merges on `mediaID` and draws on
    // `record.id`, so the two can disagree.
    #expect(AppleCatalogShelfPolicy.uniqueByID(merged) == [merged[0], merged[1], merged[3]])
    #expect(AppleCatalogShelfPolicy.uniqueByID([Entry]()).isEmpty)
}

@Test func rankedCardMetadataUsesAvailableYearAndGenre() {
    let complete = AppleCatalogItem(mediaID: "fixture", type: "movie", name: "Fixture",
        releaseInfo: "2025–2026", genres: ["Action", "Drama"], year: 2026)
    #expect(AppleCatalogShelfPolicy.rankedSubtitle(for: complete) == "2026 · Action")
    let releaseOnly = AppleCatalogItem(mediaID: "fixture", type: "series", name: "Fixture", releaseInfo: "2024–")
    #expect(AppleCatalogShelfPolicy.rankedSubtitle(for: releaseOnly) == "2024–")
    let genreOnly = AppleCatalogItem(mediaID: "fixture", type: "movie", name: "Fixture", genres: ["Drama"])
    #expect(AppleCatalogShelfPolicy.rankedSubtitle(for: genreOnly) == "Drama")
    #expect(AppleCatalogShelfPolicy.rankedSubtitle(for: .init(mediaID: "fixture", type: "movie", name: "Fixture")).isEmpty)
}
