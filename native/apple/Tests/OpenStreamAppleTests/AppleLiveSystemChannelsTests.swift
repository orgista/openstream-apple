import Foundation
import Testing
@testable import OpenStreamApple

struct AppleLiveSystemChannelsTests {
    @Test func liveLinksRoundTripAndRejectMalformedIDs() throws {
        let id = "AABBCCDD-1234-5678-9012-AABBCCDDEEFF:101"
        let url = try #require(AppleAppRoute.liveURL(channelID: id))
        #expect(AppleAppRoute(url: url) == .live(channelID: id))
        #expect(AppleAppRoute(url: URL(string: "openstream://live/a/b")!) == nil)
        #expect(AppleAppRoute(url: URL(string: "openstream://live/")!) == nil)
        #expect(AppleAppRoute.liveURL(channelID: "a/b") == nil)
        #expect(AppleAppRoute.liveURL(channelID: "") == nil)
    }

    @Test func sharedItemsNeverContainTheStreamURLAndDropCredentialArtwork() throws {
        let channel = AppleIPTVChannel(id: "fixture:101", sourceID: UUID(), name: "News",
            logoURL: URL(string: "https://fixture.example/logo.png?token=synthetic"),
            streamURL: URL(string: "https://fixture.example/live/synthetic.ts")!)
        let item = try #require(AppleLiveSystemChannels.item(channel))
        #expect(item.artworkURL == nil)
        #expect(item.playURL == AppleAppRoute.liveURL(channelID: channel.id))
        let encoded = String(decoding: try JSONEncoder().encode(item), as: UTF8.self)
        #expect(encoded.contains("synthetic") == false)
    }

    @Test @MainActor func favoritesAndRecentsAreBoundedAndDeduplicated() {
        let store = AppleLiveSystemChannels(favorites: [], recents: [])
        let channels = (0..<30).map { AppleIPTVChannel(id: "c:\($0)", sourceID: UUID(), name: "Channel \($0)",
            streamURL: URL(string: "https://fixture.example/live.m3u8")!) }
        store.update(channels: channels, favorites: Set(channels.map(\.id)),
            favoriteOrder: ["c:2", "c:1"], recentIDs: ["missing", "c:3", "c:3", "c:2"])
        #expect(store.favorites.count == 12)
        #expect(store.favorites.prefix(2).map(\.id) == ["c:2", "c:1"])
        #expect(store.recents.map(\.id) == ["c:3", "c:2"])
        let revision = store.revision
        store.update(channels: [], favorites: [], favoriteOrder: [], recentIDs: [])
        #expect(store.favorites.isEmpty)
        #expect(store.recents.isEmpty)
        #expect(store.revision > revision)
    }

    @Test func removedSourcesCannotKeepChannelsOnSystemSurfaces() throws {
        let sourceID = UUID()
        let channel = AppleIPTVChannel(id: "\(sourceID):101", sourceID: sourceID, name: "News",
            streamURL: URL(string: "https://fixture.example/live.m3u8")!)
        let item = try #require(AppleLiveSystemChannels.item(channel))
        #expect(AppleLiveSystemChannels.supported([item], sourceIDs: [sourceID]) == [item])
        #expect(AppleLiveSystemChannels.supported([item], sourceIDs: []).isEmpty)
    }

    @Test func legacySnapshotsAndTheFavoriteChannelsRow() throws {
        let legacy = Data(#"{"version":1,"generatedAt":0,"continueWatching":[],"recentlyAdded":[],"favorites":[]}"#.utf8)
        let decoded = try JSONDecoder().decode(AppleTopShelfSnapshot.self, from: legacy)
        #expect(decoded.favoriteChannels.isEmpty)
        #expect(decoded.recentChannels.isEmpty)
        let item = AppleTopShelfSnapshot.Item(id: "c:1", title: "News", kind: "live", artworkURL: nil,
            displayURL: URL(string: "openstream://live/c:1")!, playURL: URL(string: "openstream://live/c:1"))
        let snapshot = AppleTopShelfSnapshot(version: 1, generatedAt: .now, continueWatching: [],
            recentlyAdded: [], favorites: [], favoriteChannels: [item], recentChannels: [item])
        #expect(AppleTopShelfContentBuilder.sections(for: snapshot).map(\.title) == ["Favorite channels"])
        let roundTrip = try JSONDecoder().decode(AppleTopShelfSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(roundTrip.favoriteChannels == [item])
        #expect(roundTrip.recentChannels == [item])
    }
}
