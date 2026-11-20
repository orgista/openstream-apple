import Foundation
import Testing
@testable import OpenStreamApple

/// Edge-case tests for AppleContinueWatchingResolver that complement
/// AppleContinueWatchingResolverTests.
struct AppleContinueWatchingResolverEdgeTests {
    private let instanceID = UUID()
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func item(_ mediaID: String, name: String, type: String = "series") -> AppleCatalogItem {
        AppleCatalogItem(
            mediaID: mediaID, type: type, name: name,
            posterURL: URL(string: "https://fixture.example/\(mediaID)-poster.jpg"),
            backgroundURL: URL(string: "https://fixture.example/\(mediaID)-backdrop.jpg")
        )
    }

    private func record(_ catalogItem: AppleCatalogItem, progress: Double? = 0.4) -> AppleMediaRecord {
        var value = AppleMediaIngestion.catalogRecord(instanceID: instanceID, item: catalogItem)
        value.progress = progress
        return value
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
