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

    /// Items of an `unanswered` playlist stay as they were; any other item missing from `index` drops.
    func update(index: AppleIPTVChannelIndex, unanswered: Set<UUID>, favorites ids: Set<String>,
                favoriteOrder: [String], recentIDs: [String]) {
        let kept = Dictionary((self.favorites + self.recents).filter { item in
            Self.sourceID(of: item.id).map(unanswered.contains) ?? false
        }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var orderedIDs = favoriteOrder.filter { ids.contains($0) }
        var ordered = Set(orderedIDs)
        orderedIDs += index.channels.filter { ids.contains($0.id) && !ordered.contains($0.id) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.map(\.id)
        ordered.formUnion(orderedIDs)
        orderedIDs += self.favorites.map(\.id).filter { ids.contains($0) && !ordered.contains($0) && kept[$0] != nil }
        let favorites = Self.items(ids: orderedIDs, index: index, kept: kept, limit: 12)
        let recents = Self.items(ids: recentIDs, index: index, kept: kept, limit: 10)
        guard favorites != self.favorites || recents != self.recents else { return }
        self.favorites = favorites
        self.recents = recents
        revision &+= 1
    }

    private static func items(ids: [String], index: AppleIPTVChannelIndex, kept: [String: AppleTopShelfSnapshot.Item],
                              limit: Int) -> [AppleTopShelfSnapshot.Item] {
        var seen: Set<String> = []
        return Array(ids.compactMap { id in
            guard seen.insert(id).inserted else { return nil }
            return index[id].flatMap(item) ?? kept[id]
        }.prefix(limit))
    }

    nonisolated static func supported(_ items: [AppleTopShelfSnapshot.Item], sourceIDs: Set<UUID>) -> [AppleTopShelfSnapshot.Item] {
        items.filter { item in sourceID(of: item.id).map(sourceIDs.contains) ?? false }
    }

    nonisolated private static func sourceID(of channelID: String) -> UUID? {
        channelID.split(separator: ":").first.flatMap { UUID(uuidString: String($0)) }
    }

    nonisolated static func item(_ channel: AppleIPTVChannel) -> AppleTopShelfSnapshot.Item? {
        guard let url = AppleAppRoute.liveURL(channelID: channel.id) else { return nil }
        return .init(id: channel.id, title: channel.displayName, kind: "live",
            artworkURL: AppleSystemArtworkPolicy.publicURL(channel.logoURL), displayURL: url, playURL: url)
    }
}
