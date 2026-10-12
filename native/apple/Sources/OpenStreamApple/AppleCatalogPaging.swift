import Foundation

/// One page from a Stremio catalog: the shelf items kept, and how many
/// entries the add-on sent before the shelf's own filtering.
public struct AppleCatalogPage: Equatable, Sendable {
    public let items: [AppleCatalogItem]
    public let receivedCount: Int

    public init(items: [AppleCatalogItem], receivedCount: Int) {
        self.items = items
        self.receivedCount = receivedCount
    }
}

/// Paging a catalog shelf with the Stremio `skip` extra
/// (stremio-addon-sdk `defineCatalogHandler`): `skip` is the number of items
/// the shelf already holds, the next page is asked for when the row or See
/// All reaches its end, and paging stops for good on an empty page, a short
/// page, or a page with nothing new.
enum AppleCatalogPaging {
    /// A shelf stops growing here, whatever the add-on still has.
    static let maximumItems = 500
    /// The next page is asked for while one of the last few items is on screen,
    /// so it has usually landed before the viewer gets to the end.
    static let prefetchDistance = 5

    struct State: Equatable {
        /// The first page's size: a later page smaller than this is the last.
        var pageSize: Int
        var isExhausted = false
    }

    /// Whether `catalog` pages at all, and where the next page starts.
    static func nextSkip(catalog: AppleStremioCatalog, loadedCount: Int, state: State?) -> Int? {
        guard catalog.supportsSkip, loadedCount > 0, loadedCount < maximumItems,
              state?.isExhausted != true else { return nil }
        return loadedCount
    }

    /// `page` added to `existing`, IDs already shown dropped, and whether the
    /// catalog is now done.
    static func merge(
        _ existing: [AppleCatalogItem],
        page: AppleCatalogPage,
        pageSize: Int
    ) -> (items: [AppleCatalogItem], isExhausted: Bool) {
        var seen = Set(existing.map(\.id))
        let fresh = page.items.filter { seen.insert($0.id).inserted }
        let merged = Array((existing + fresh).prefix(maximumItems))
        let isExhausted = page.receivedCount == 0
            || page.receivedCount < pageSize
            || fresh.isEmpty
            || merged.count >= maximumItems
        return (merged, isExhausted)
    }

    /// The source's current copy of `catalog` (same type and id), whose
    /// flags may be newer than a cached shelf's.
    static func liveCatalog(_ catalog: AppleStremioCatalog, in source: AppleSource) -> AppleStremioCatalog {
        source.catalogs.first { $0.type == catalog.type && $0.id == catalog.id } ?? catalog
    }

    /// Whether `itemID` showing should ask for the next page.
    static func isNearEnd(itemID: String, in items: [AppleCatalogItem]) -> Bool {
        guard let index = items.lastIndex(where: { $0.id == itemID }) else { return false }
        return index >= items.count - prefetchDistance
    }
}

/// Add-ons saved before catalog paging (40e9350) stored their catalogs
/// without the `skip` flag, so their shelves never page. Each add-on's
/// manifest is fetched again in the background at launch, at most once per
/// add-on per day, and the stored catalogs take the manifest's flags.
enum AppleManifestRefreshPolicy {
    static let interval: TimeInterval = 24 * 60 * 60
    /// A launch refreshes at most this many, one at a time.
    static let maximumPerLaunch = 40

    /// The add-ons due a refresh: enabled Stremio add-ons with catalogs,
    /// signed in, last tried a day or more ago (or never).
    static func due(sources: [AppleSource], lastAttempt: [String: Double], now: Date) -> [AppleSource.ID] {
        sources.filter { source in
            guard source.isAddon, source.isEnabled, !source.needsSignIn, !source.catalogs.isEmpty else { return false }
            guard let last = lastAttempt[source.id.uuidString] else { return true }
            return now.timeIntervalSince1970 - last >= interval || last > now.timeIntervalSince1970
        }
        .prefix(maximumPerLaunch)
        .map(\.id)
    }

    /// Attempt times for add-ons that still exist.
    static func pruned(_ lastAttempt: [String: Double], liveIDs: Set<String>) -> [String: Double] {
        lastAttempt.filter { liveIDs.contains($0.key) }
    }

    /// The stored catalogs, same set and order, with each one's flags
    /// (`skip`, `search`, required input) taken from the manifest's catalog of
    /// the same type and id. Catalogs the manifest no longer lists are kept as
    /// they are; new ones are not added here.
    static func refreshedCatalogs(stored: [AppleStremioCatalog], manifest: [AppleStremioCatalog]) -> [AppleStremioCatalog] {
        stored.map { catalog in
            guard let fresh = manifest.first(where: { $0.type == catalog.type && $0.id == catalog.id }) else { return catalog }
            return AppleStremioCatalog(type: catalog.type, id: catalog.id, name: catalog.name,
                                       requiresInput: fresh.requiresInput, supportsSearch: fresh.supportsSearch,
                                       supportsSkip: fresh.supportsSkip)
        }
    }
}
