import Foundation

@MainActor enum AppleTop10ArtworkLookup {
    static func find(
        title: String, type: String, seasonTitle: String?, sources: [AppleSource],
        client: AppleStremioCatalogClient = AppleStremioCatalogClient()
    ) async -> AppleCatalogSearchMatch? {
        // Only configured metadata catalogs are queried. Four catalogs and two
        // concurrent requests bound the work for each lazily visible card.
        let eligible = sources.compactMap { source -> AppleSource? in
            guard source.isEnabled, source.kind == .stremio else { return nil }
            var value = source
            value.catalogs = Array(source.catalogs.filter { $0.type == type && $0.supportsSearch }.prefix(1))
            return value.catalogs.isEmpty ? nil : value
        }
        let store = AppleCatalogSearchStore(client: client, debounce: .zero, deadline: .seconds(4), maximumConcurrentRequests: 2)
        await store.search(query: title, sources: Array(eligible.prefix(4)), baseSections: []) { _ in [] }
        guard !Task.isCancelled else { return nil }
        return store.lookup.match(title: title, type: type, seasonTitle: seasonTitle)
    }
}
