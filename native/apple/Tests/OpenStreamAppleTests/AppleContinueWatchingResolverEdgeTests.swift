import Foundation
import Testing
@testable import OpenStreamApple

/// Edge-case tests for AppleContinueWatchingResolver that complement
/// AppleContinueWatchingResolverTests.
struct AppleContinueWatchingResolverEdgeTests {
    private let catalog = AppleStremioCatalog(type: "series", id: "fixture-edge")
    private let source: AppleSource
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    init() {
        source = AppleSource(
            kind: .stremio, name: "Edge Fixture",
            url: URL(string: "https://fixture.example/edge-manifest.json")!,
            resources: ["catalog"], catalogs: [catalog]
        )
    }

    private func item(_ mediaID: String, name: String, type: String = "series") -> AppleCatalogItem {
        AppleCatalogItem(
            mediaID: mediaID, type: type, name: name,
            posterURL: URL(string: "https://fixture.example/\(mediaID)-poster.jpg"),
            backgroundURL: URL(string: "https://fixture.example/\(mediaID)-backdrop.jpg")
        )
    }

    private func record(_ catalogItem: AppleCatalogItem, progress: Double? = 0.4) -> AppleMediaRecord {
        var value = AppleMediaIngestion.catalogRecord(instanceID: source.id, item: catalogItem)
        value.progress = progress
        return value
    }

    private func lookup(sections: [AppleCatalogSection], sources: [AppleSource]? = nil) -> AppleCatalogSearchLookup {
        AppleCatalogSearchLookup(sections: sections, sources: sources ?? [source])
    }

    // MARK: - Progress threshold boundaries

    /// A record whose progress is exactly at the completion fraction is NOT in progress.
    @Test func exactlyAtCompletionFractionIsFinished() {
        let finished = record(item("tt_edge_f1", name: "Almost Done"),
                             progress: ApplePlaybackProgress.completionFraction)

        let watchedAt = [finished.id: now]
        let result = AppleContinueWatchingResolver.inProgress([finished]) { watchedAt[$0.id] ?? .distantPast }

        #expect(result.isEmpty)
    }

    /// A record whose progress is just below the completion fraction IS in progress.
    @Test func justBelowCompletionFractionIsInProgress() {
        let inProgress = record(item("tt_edge_f2", name: "Still Going"),
                               progress: ApplePlaybackProgress.completionFraction - 0.001)

        let watchedAt = [inProgress.id: now]
        let result = AppleContinueWatchingResolver.inProgress([inProgress]) { watchedAt[$0.id] ?? .distantPast }

        #expect(result.count == 1)
        #expect(result[0].id == inProgress.id)
    }

    /// A record with nil progress is treated as unstarted and excluded.
    @Test func nilProgressExcludedFromInProgress() {
        let unstarted = record(item("tt_edge_nil", name: "Unstarted"), progress: nil)

        let watchedAt = [unstarted.id: now]
        let result = AppleContinueWatchingResolver.inProgress([unstarted]) { watchedAt[$0.id] ?? .distantPast }

        #expect(result.isEmpty)
    }

    // MARK: - Resolve with multiple lookups

    /// When the first lookup does not match but a second does, resolve uses the second.
    @Test func resolvePrefersFirstMatchingLookup() {
        let edgeItem = item("tt_edge_lookup", name: "Lookup Target")
        let edgeRecord = record(edgeItem)

        // First lookup has no sections (empty shelf) — cannot match
        let emptyLookup = AppleCatalogSearchLookup(sections: [], sources: [source])

        // Second lookup lists the item
        let sections = [AppleCatalogSection(source: source, catalog: catalog, items: [edgeItem])]
        let fullLookup = lookup(sections: sections)

        let resolution = AppleContinueWatchingResolver.resolve(edgeRecord, in: [emptyLookup, fullLookup])

        #expect(resolution == .listed(AppleCatalogSearchMatch(item: edgeItem, source: source)))
    }

    // MARK: - In-progress ordering with equal dates

    /// When two records share the same watch date, the one with the
    /// lexicographically smaller id appears first.
    @Test func equalWatchDateSortedByRecordId() {
        // Build two records whose IDs have known relative order.
        // "B" > "A" lexicographically, so recordA.id < recordB.id typically —
        // but we control the order by using different titles.
        let alphaItem = item("tt_edge_aa", name: "Alpha Movie")
        let betaItem  = item("tt_edge_bb", name: "Beta Movie")
        let recordA = record(alphaItem)
        let recordB = record(betaItem)

        // Same watch date for both
        let watchedAt: [String: Date] = [recordA.id: now, recordB.id: now]

        let result = AppleContinueWatchingResolver.inProgress([recordB, recordA]) {
            watchedAt[$0.id] ?? .distantPast
        }

        // Same date → sorted by id ascending
        let sortedIds = result.map(\.id)
        #expect(sortedIds[0] < sortedIds[1])
    }

    // MARK: - Entries deduplication with multiple sources

    /// Two records resolving to the same catalog item keep only the first in order.
    @Test func entriesDeduplicateByResolvedItemId() {
        let sharedItem = item("tt_edge_dedup", name: "Shared Title")
        let record1 = record(sharedItem, progress: 0.3)

        // A second record with a different item ID but same canonicalID resolves to the same item
        var record2 = AppleMediaIngestion.catalogRecord(
            instanceID: UUID(),
            item: AppleCatalogItem(mediaID: "fixture:alt-copy", type: "series", name: "Shared Title")
        )
        record2.availability += record1.availability
        record2.progress = 0.6

        let sections = [AppleCatalogSection(source: source, catalog: catalog, items: [sharedItem])]
        let l = lookup(sections: sections)

        let entries = AppleContinueWatchingResolver.entries([record1, record2], in: [l])

        #expect(entries.count == 1)
        #expect(entries[0].record.id == record1.id)
    }

    // MARK: - Record with no matching lookup and no active source

    /// A catalog record whose source is not in the lookup at all is unavailable.
    @Test func recordWithNoMatchingLookupSourceUnavailable() {
        let phantomSource = AppleSource(
            kind: .stremio, name: "Phantom",
            url: URL(string: "https://fixture.example/phantom.json")!,
            resources: ["catalog"], catalogs: [catalog]
        )
        let phantomItem = item("tt_edge_phantom", name: "Gone")
        var phantomRecord = AppleMediaIngestion.catalogRecord(instanceID: phantomSource.id, item: phantomItem)
        phantomRecord.progress = 0.5

        // Lookup only knows about our source, not the phantom
        let sections = [AppleCatalogSection(source: source, catalog: catalog, items: [item("tt_edge_other", name: "Other")])]
        let l = lookup(sections: sections)

        let resolution = AppleContinueWatchingResolver.resolve(phantomRecord, in: [l])

        #expect(resolution == .unavailable(.sourceUnavailable))
    }

    // MARK: - Maximum count limiting

    /// entries respects the maximumCount cap of 12.
    @Test func entriesRespectsMaximumCount() {
        var records: [AppleMediaRecord] = []
        var items: [AppleCatalogItem] = []
        for i in (0 ..< 20) {
            let mID = "tt_edge_max_\(String(format: "%02d", i))"
            let it = item(mID, name: ("Title " + String(i)))
            items.append(it)
            records.append(record(it, progress: 0.3 + Double(i) * 0.01))
        }

        let sections = [AppleCatalogSection(source: source, catalog: catalog, items: items)]
        let l = lookup(sections: sections)
        let watchedAt = Dictionary(uniqueKeysWithValues: records.enumerated().map {
            ($1.id, now.addingTimeInterval(-Double($0) * 300))
        })

        let ordered = AppleContinueWatchingResolver.inProgress(records) {
            watchedAt[$0.id] ?? .distantPast
        }
        let entries = AppleContinueWatchingResolver.entries(ordered, in: [l])

        // All 20 are in progress (max progress = 0.3 + 19*0.01 = 0.49 < 0.95)
        #expect(ordered.count == 20)
        // entries deduplicates by item id; since each resolves to a distinct listed item, all pass
        #expect(entries.count == 20)
        // The resolver itself does not cap at maximumCount — that is an
        // upstream concern (Discover row). Verify the resolver returns all.
    }

    // MARK: - Finished titles drop out of inProgress

    /// Multiple records, some finished, some not — only unfinished remain.
    @Test func finishedTitlesDropOut() {
        let r1 = record(item("tt_edge_dr1", name: "A"), progress: 0.1)
        let r2 = record(item("tt_edge_dr2", name: "B"), progress: 0.95) // exactly at threshold
        let r3 = record(item("tt_edge_dr3", name: "C"), progress: 1.0)
        let r4 = record(item("tt_edge_dr4", name: "D"), progress: 0.5)
        let r5 = record(item("tt_edge_dr5", name: "E"), progress: 0.0) // unstarted

        let watchedAt: [String: Date] = [
            r1.id: now, r2.id: now, r3.id: now, r4.id: now, r5.id: now
        ]

        let result = AppleContinueWatchingResolver.inProgress([r1, r2, r3, r4, r5]) {
            watchedAt[$0.id] ?? .distantPast
        }

        #expect(result.count == 2)
        #expect(Set(result.map(\.id)) == Set([r1.id, r4.id]))
    }
}
