import Foundation
import Observation

/// Only channel labels, safe artwork, and app links cross into Apple services.
@MainActor @Observable
final class AppleLiveSystemChannels {
    static let shared: AppleLiveSystemChannels = {
        let snapshot = AppleTopShelfSnapshotReader().read()
        return AppleLiveSystemChannels(favorites: snapshot?.favoriteChannels ?? [], recents: snapshot?.recentChannels ?? [])
    }()
    private(set) var favorites: [AppleTopShelfSnapshot.Item]
    private(set) var recents: [AppleTopShelfSnapshot.Item]
    private(set) var revision = 0
    var requestedChannelID: String?

    init(favorites: [AppleTopShelfSnapshot.Item], recents: [AppleTopShelfSnapshot.Item]) {
        self.favorites = favorites
        self.recents = recents
    }

    func update(channels: [AppleIPTVChannel], favorites ids: Set<String>, favoriteOrder: [String], recentIDs: [String]) {
        let index = AppleIPTVChannelIndex(channels)
        var orderedIDs = favoriteOrder.filter { ids.contains($0) }
        let ordered = Set(orderedIDs)
        orderedIDs += channels.filter { ids.contains($0.id) && !ordered.contains($0.id) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.map(\.id)
        let favorites = Self.items(ids: orderedIDs, index: index, limit: 12)
        let recents = Self.items(ids: recentIDs, index: index, limit: 10)
        guard favorites != self.favorites || recents != self.recents else { return }
        self.favorites = favorites
        self.recents = recents
        revision &+= 1
    }

    private static func items(ids: [String], index: AppleIPTVChannelIndex, limit: Int) -> [AppleTopShelfSnapshot.Item] {
        var seen: Set<String> = []
        return Array(ids.compactMap { id in
            guard seen.insert(id).inserted, let channel = index[id] else { return nil }
            return item(channel)
        }.prefix(limit))
    }

    nonisolated static func supported(_ items: [AppleTopShelfSnapshot.Item], sourceIDs: Set<UUID>) -> [AppleTopShelfSnapshot.Item] {
        items.filter { item in
            guard let first = item.id.split(separator: ":").first,
                  let sourceID = UUID(uuidString: String(first)) else { return false }
            return sourceIDs.contains(sourceID)
        }
    }

    nonisolated static func item(_ channel: AppleIPTVChannel) -> AppleTopShelfSnapshot.Item? {
        guard let url = AppleAppRoute.liveURL(channelID: channel.id) else { return nil }
        return .init(id: channel.id, title: channel.name, kind: "live",
            artworkURL: AppleSystemArtworkPolicy.publicURL(channel.logoURL), displayURL: url, playURL: url)
    }
}
