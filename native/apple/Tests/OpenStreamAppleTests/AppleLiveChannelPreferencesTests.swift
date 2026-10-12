import Foundation
import Testing
@testable import OpenStreamApple

@Suite("Live channel preferences")
struct AppleLiveChannelPreferencesTests {
    @Test func hiddenGroupsAreScopedToTheirSourceAndRestoreIsReversible() {
        let first = UUID(), second = UUID()
        let a = AppleIPTVChannel(id: "a", sourceID: first, name: "A", group: "News", streamURL: URL(string: "https://fixture.example/a")!)
        let b = AppleIPTVChannel(id: "b", sourceID: second, name: "B", group: "News", streamURL: URL(string: "https://fixture.example/b")!)
        let group = AppleLiveChannelPreferences.groupKey(a)
        #expect(AppleLiveChannelPreferences.visible([a, b], hiddenIDs: [], hiddenGroups: [group]).map(\.id) == ["b"])
        #expect(AppleLiveChannelPreferences.visible([a, b], hiddenIDs: ["b"], hiddenGroups: []).map(\.id) == ["a"])
        #expect(AppleLiveChannelPreferences.visible([a, b], hiddenIDs: [], hiddenGroups: []).count == 2)
    }

    @Test func favoriteOrderDropsRemovedIDsAndDuplicatesAndKeepsNewFavorites() {
        #expect(AppleLiveChannelPreferences.order(["b", "a", "b", "old"], favoriteIDs: ["a", "b", "c"]) == ["b", "a", "c"])
    }
}
