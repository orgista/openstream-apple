import Foundation

/// One page from a server shelf: the shelf items kept, and how many entries
/// the server sent before the shelf's own filtering.
public struct AppleCatalogPage: Equatable, Sendable {
    public let items: [AppleCatalogItem]
    public let receivedCount: Int

    public init(items: [AppleCatalogItem], receivedCount: Int) {
        self.items = items
        self.receivedCount = receivedCount
    }
}

/// Paging a shelf: the next page is asked for when the row reaches its end,
/// and paging stops for good on an empty page, a short page, or a page with
/// nothing new.
enum AppleCatalogPaging {
    /// Home rails stay bounded; full library pages can opt out.
    static let maximumItems = 500
    /// The next page is asked for while one of the last few items is on screen,
    /// so it has usually landed before the viewer gets to the end.
    static let prefetchDistance = 5

    /// `page` added to `existing`, IDs already shown dropped, and whether the
    /// shelf is now done.
    static func merge(
        _ existing: [AppleCatalogItem],
        page: AppleCatalogPage,
        pageSize: Int,
        limit: Int = maximumItems
    ) -> (items: [AppleCatalogItem], isExhausted: Bool) {
        var seen = Set(existing.map(\.id))
        let fresh = page.items.filter { seen.insert($0.id).inserted }
        let merged = Array((existing + fresh).prefix(limit))
        let isExhausted = page.receivedCount == 0
            || page.receivedCount < pageSize
            || fresh.isEmpty
            || merged.count >= limit
        return (merged, isExhausted)
    }

    /// Whether `itemID` showing should ask for the next page.
    static func isNearEnd(itemID: String, in items: [AppleCatalogItem]) -> Bool {
        guard let index = items.lastIndex(where: { $0.id == itemID }) else { return false }
        return index >= items.count - prefetchDistance
    }
}
