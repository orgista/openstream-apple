import Foundation

enum AppleDiscoverContinueWatchingPublication {
    struct Snapshot: Equatable, Sendable {
        let values: [AppleDiscoverView.IndexedCatalogItem]
        let sourceContext: String
        let requests: [AppleArtworkPrefetchPolicy.Request]
        let viewportReady: Bool
    }

    static func visible(_ published: Snapshot?, current: [AppleDiscoverView.IndexedCatalogItem],
        sourceContext: String) -> [AppleDiscoverView.IndexedCatalogItem] {
        guard let published, published.sourceContext == sourceContext else { return [] }
        let currentIDs = Set(current.map(\.id))
        return published.values.filter { currentIDs.contains($0.id) }
    }
}
