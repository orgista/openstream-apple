import Foundation
import Testing
@testable import OpenStreamApple

struct AppleContinueWatchingMergeTests {
    struct Entry: Equatable { let id: String; let stamp: Int; let value: String }
    @Test func newestActivityMovesFirstAndRemovedEntriesDropOff() {
        let old = [Entry(id: "a", stamp: 2, value: "old"), Entry(id: "b", stamp: 1, value: "b")]
        let fresh = [Entry(id: "b", stamp: 3, value: "new"), Entry(id: "c", stamp: 4, value: "c"),
                     Entry(id: "a", stamp: 1, value: "stale")]
        let merged = AppleContinueWatchingResolver.merge(old, incoming: fresh, id: { $0.id }, timestamp: { $0.stamp })
        #expect(merged.map(\.id) == ["c", "b", "a"])
        #expect(merged[2].value == "old")
        #expect(merged[1].value == "new")
        #expect(AppleContinueWatchingResolver.merge(merged, incoming: [fresh[0]], id: { $0.id }, timestamp: { $0.stamp }).map(\.id) == ["b"])
        #expect(AppleContinueWatchingResolver.merge(old, incoming: [old[0], old[0]], id: { $0.id }, timestamp: { $0.stamp }) == [old[0]])
    }

    @Test func equalWatchDatesHaveADeterministicOrderAndRefreshMetadata() {
        let old = [Entry(id: "b", stamp: 2, value: "b"), Entry(id: "a", stamp: 2, value: "old")]
        let incoming = [Entry(id: "a", stamp: 2, value: "new"), old[0]]
        let merged = AppleContinueWatchingResolver.merge(old, incoming: incoming, id: { $0.id }, timestamp: { $0.stamp })
        #expect(merged.map(\.id) == ["a", "b"])
        #expect(merged.first?.value == "new")
    }
}
