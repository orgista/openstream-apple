import Foundation
import Testing
@testable import OpenStreamApple

/// N49 #7: a Search row with no chevron that did nothing when tapped.
///
/// The media index keeps catalog records after they leave the shelves (a title
/// page writes one when it opens; a shelf refresh retains the most recent
/// ones). Search finds them locally, but the row opened only when a loaded
/// section still listed the record's item — so these rows were dead.
@MainActor
struct AppleSearchUnlistedRecordTests {
    private let catalog = AppleStremioCatalog(type: "series", id: "fixture-search")
    private let source: AppleSource
    private let listed = AppleCatalogItem(mediaID: "tt0000001", type: "series", name: "Starlight Harbor",
                                          releaseInfo: "2019")

    init() {
        source = AppleSource(kind: .stremio, name: "Fixture", url: URL(string: "https://fixture.example/manifest.json")!,
                             resources: ["catalog"], catalogs: [catalog])
    }

    private var lookup: AppleCatalogSearchLookup {
        AppleCatalogSearchLookup(sections: [.init(source: source, catalog: catalog, items: [listed])], sources: [source])
    }

    /// The record the index kept for an item no section lists any more.
    private func retained(mediaID: String, name: String, year: String = "2016", summary: String? = nil) -> AppleMediaRecord {
        AppleMediaIngestion.catalogRecord(
            instanceID: source.id,
            item: AppleCatalogItem(mediaID: mediaID, type: "series", name: name, summary: summary, releaseInfo: year)
        )
    }

    private func searchStore() -> AppleCatalogSearchStore {
        AppleCatalogSearchStore(
            client: AppleStremioCatalogClient(loader: { _ in throw CancellationError() }),
            debounce: .milliseconds(1),
            deadline: .milliseconds(30),
            maximumConcurrentRequests: 1
        )
    }

    /// The shape of the dead row: a series from an add-on with its own
    /// (non-IMDb) id, found only in the media index. Nothing names the title
    /// any more, so it is not listed rather than listed and inert.
    @Test func anUnlistedRecordWithAnAddOnIDIsNotListed() async throws {
        let record = retained(mediaID: "kitsu:fixture-1", name: "Re: Fixture, Starting Over")
        let store = searchStore()
        await store.search(query: "star", sources: [source],
                           baseSections: [.init(source: source, catalog: catalog, items: [listed])]) { _ in [record] }

        _ = try #require(store.results.first { $0.id == record.id })
        #expect(store.lookup.match(for: record.id) == nil)
        #expect(AppleCatalogSearchLookup.match(for: record, in: [store.lookup]) == nil)
        #expect(AppleCatalogSearchLookup.listsUnmatched(record) == false)
    }

    /// With an IMDb id the record names the title outright, so the row opens
    /// a title page for it — the same record id, so My List and progress
    /// stay attached.
    @Test func anUnlistedRecordWithAnIMDbIDOpensItsTitlePage() throws {
        let record = retained(mediaID: "tt0000002", name: "Fixture Stars")
        let match = try #require(AppleCatalogSearchLookup.match(for: record, in: [lookup]))
        #expect(match.item.mediaID == "tt0000002")
        #expect(match.item.type == "series")
        #expect(match.item.name == "Fixture Stars")
        #expect(match.source.id == source.id)
        #expect(AppleMediaIngestion.catalogRecord(instanceID: source.id, item: match.item).id == record.id)
    }

    /// A merged row keeps the id of the richer record; when that one is the
    /// unlisted copy, the listed item its other availability names opens.
    @Test func aMergedRowOpensTheListedItemOfAnyOfItsAvailabilities() throws {
        let unlisted = retained(mediaID: "tt0000003", name: "Starlight Harbor", year: "2019",
                                summary: "A richer copy the shelves dropped.")
        let fresh = AppleMediaIngestion.catalogRecord(instanceID: source.id, item: listed)
        let rows = AppleCatalogSearchStore.mergedResults([unlisted, fresh], matching: "starlight", limit: 10)
        let row = try #require(rows.first)
        #expect(rows.count == 1)
        #expect(row.id == unlisted.id)
        #expect(lookup.match(for: row.id) == nil)
        #expect(AppleCatalogSearchLookup.match(for: row, in: [lookup])?.item == listed)
    }

    /// A listed item in a later lookup wins over a title rebuilt from the first.
    @Test func aListedItemIsPreferredToARebuiltOne() {
        let record = AppleMediaIngestion.catalogRecord(instanceID: source.id, item: listed)
        let empty = AppleCatalogSearchLookup(sections: [], sources: [source])
        #expect(AppleCatalogSearchLookup.match(for: record, in: [empty, lookup])?.item == listed)
    }

    /// A disabled source cannot open a title page, so it rebuilds nothing.
    @Test func aDisabledSourceRebuildsNothing() {
        var disabled = source
        disabled.isEnabled = false
        let record = retained(mediaID: "tt0000004", name: "Fixture Stars")
        let lookup = AppleCatalogSearchLookup(sections: [], sources: [disabled])
        #expect(AppleCatalogSearchLookup.match(for: record, in: [lookup]) == nil)
    }

    /// Files and channels are not catalog titles; they are listed as before.
    @Test(arguments: [AppleMediaPlaybackCapability.direct, .gateway])
    func nonCatalogRowsAreStillListed(capability: AppleMediaPlaybackCapability) {
        let record = AppleMediaRecord(kind: .channel, title: "Fixture Star Channel",
                                      availability: [.init(instanceID: UUID(), capability: capability, itemReference: "1")])
        #expect(AppleCatalogSearchLookup.match(for: record, in: [lookup]) == nil)
        #expect(AppleCatalogSearchLookup.listsUnmatched(record))
    }
}
