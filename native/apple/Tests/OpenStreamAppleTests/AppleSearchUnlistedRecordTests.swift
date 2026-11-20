import Foundation
import Testing
@testable import OpenStreamApple

/// N49 #7: a Search row with no chevron that did nothing when tapped.
///
/// The media index keeps catalog records after they leave the shelves. Search
/// finds them locally; a record that only resolves through a title page that
/// nothing names any more must not be listed as an inert row.
@MainActor
struct AppleSearchUnlistedRecordTests {
    private let instanceID = UUID()
    private let listed = AppleCatalogItem(mediaID: "tt0000001", type: "series", name: "Starlight Harbor",
                                          releaseInfo: "2019")

    /// The record the index kept for an item no section lists any more.
    private func retained(mediaID: String, name: String, year: String = "2016", summary: String? = nil) -> AppleMediaRecord {
        AppleMediaIngestion.catalogRecord(
            instanceID: instanceID,
            item: AppleCatalogItem(mediaID: mediaID, type: "series", name: name, summary: summary, releaseInfo: year)
        )
    }

    /// Search still returns the record, but nothing names the title any more,
    /// so it is not listed rather than listed and inert.
    @Test func anUnlistedResolvableRecordIsNotListed() async throws {
        let record = retained(mediaID: "fixture:1", name: "Re: Fixture, Starting Over")
        let store = AppleCatalogSearchStore(debounce: .milliseconds(1))
        await store.search(query: "star") { _ in [record] }

        _ = try #require(store.results.first { $0.id == record.id })
        #expect(AppleCatalogSearchStore.listsUnmatched(record) == false)
    }

    /// A merged row keeps the id of the richer record, so the unlisted copy's
    /// My List and progress stay attached.
    @Test func aMergedRowKeepsTheRicherRecordsID() throws {
        let unlisted = retained(mediaID: "tt0000003", name: "Starlight Harbor", year: "2019",
                                summary: "A richer copy the shelves dropped.")
        let fresh = AppleMediaIngestion.catalogRecord(instanceID: instanceID, item: listed)
        let rows = AppleCatalogSearchStore.mergedResults([unlisted, fresh], matching: "starlight", limit: 10)
        let row = try #require(rows.first)
        #expect(rows.count == 1)
        #expect(row.id == unlisted.id)
    }

    /// Files and channels are not catalog titles; they are listed as before.
    @Test func nonCatalogRowsAreStillListed() {
        let record = AppleMediaRecord(kind: .channel, title: "Fixture Star Channel",
                                      availability: [.init(instanceID: UUID(), capability: .direct, itemReference: "1")])
        #expect(AppleCatalogSearchStore.listsUnmatched(record))
    }
}
