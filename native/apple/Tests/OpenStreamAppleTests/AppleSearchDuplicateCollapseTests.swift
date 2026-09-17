import Foundation
import Testing
@testable import OpenStreamApple

/// Owner, on searching "Jury duty": "I go odd results". Episodes were filtered
/// out earlier; this is the other half — the **same** 2007 series came back
/// twice, once from Cinemeta carrying its year and once from the TMDB add-on
/// with none, because the collapse key is title|year and "2007" and "" are
/// different keys. Verified on screen on iPhone, 2026-09-16.
@MainActor
@Suite("Search duplicate collapsing")
struct AppleSearchDuplicateCollapseTests {
    private func availability() -> [AppleMediaAvailability] {
        [AppleMediaAvailability(instanceID: UUID(), capability: .direct,
                                itemReference: "ref", lastVerified: .now)]
    }

    private func record(
        title: String, year: Int? = nil, canonical: String? = nil,
        kind: AppleMediaKind = .series
    ) -> AppleMediaRecord {
        AppleMediaRecord(canonicalID: canonical, kind: kind, title: title,
                         year: year, availability: availability())
    }

    /// The exact shape of the bug.
    @Test func oneTitleFromTwoSourcesCollapsesWhenOnlyOneCarriesAYear() {
        let results = AppleCatalogSearchStore.mergedResults(
            [record(title: "Jury Duty", year: 2007, canonical: "tt0460637"),
             record(title: "Jury Duty", canonical: "tt0460637")],
            matching: "jury duty", limit: 20)
        #expect(results.count == 1, "the same series still appears \(results.count) times")
    }

    /// Different titles that merely share a name must stay apart — the 1995
    /// film and the 2007 series are both "Jury Duty" and are not the same thing.
    @Test func differentCanonicalIdentitiesStaySeparate() {
        let results = AppleCatalogSearchStore.mergedResults(
            [record(title: "Jury Duty", year: 1995, canonical: "tt0113377", kind: .movie),
             record(title: "Jury Duty", year: 2007, canonical: "tt0460637")],
            matching: "jury duty", limit: 20)
        #expect(results.count == 2)
    }

    /// The merge this collapsing must not break: a local file has no canonical
    /// id, and folding it into its catalogue entry is what puts the artwork and
    /// the local availability on one row.
    @Test func aLocalFileStillMergesWithItsCatalogueEntry() {
        let results = AppleCatalogSearchStore.mergedResults(
            [record(title: "Jury Duty", year: 2007, canonical: nil, kind: .video),
             record(title: "Jury Duty", year: 2007, canonical: "tt0460637")],
            matching: "jury duty", limit: 20)
        #expect(results.count == 1)
    }

    /// Three copies of one title from three add-ons collapse to one row.
    @Test func severalSourcesOfOneTitleCollapseToOneRow() {
        let results = AppleCatalogSearchStore.mergedResults(
            [record(title: "Jury Duty", year: 2007, canonical: "tt0460637"),
             record(title: "Jury Duty", canonical: "tt0460637"),
             record(title: "Jury  Duty", year: 2007, canonical: "tt0460637")],
            matching: "jury duty", limit: 20)
        #expect(results.count == 1)
    }

    /// Episodes are still excluded outright — the first half of the complaint.
    @Test func episodesAreStillNeverListed() {
        let results = AppleCatalogSearchStore.mergedResults(
            [record(title: "Jury Duty", year: 2007, canonical: "tt0460637"),
             record(title: "Jury Duty", year: 2007, canonical: "tt9999999", kind: .episode)],
            matching: "jury duty", limit: 20)
        #expect(results.count == 1)
        #expect(results.allSatisfy { $0.kind != .episode })
    }
}
