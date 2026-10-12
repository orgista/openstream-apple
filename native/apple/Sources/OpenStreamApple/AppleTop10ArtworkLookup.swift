import Foundation

@MainActor enum AppleTop10ArtworkLookup {
#if OPENSTREAM_ADDONS
    static func find(
        title: String, type: String, seasonTitle: String?, sources: [AppleSource],
        client: AppleStremioCatalogClient = AppleStremioCatalogClient(),
        deadline: Duration = .seconds(4), retryDeadline: Duration = .seconds(12)
    ) async -> AppleCatalogSearchMatch? {
        if let match = await search(title: title, type: type, seasonTitle: seasonTitle, sources: sources,
                                    client: client, budgets: [deadline, retryDeadline]) {
            return match
        }
        // Netflix files stand-up and one-off specials under TV ("Jo Koy: Blue
        // in the Face"); the metadata catalogs list them as films. One film
        // search before the tile settles for its title (N32 extra).
        guard type.caseInsensitiveCompare("series") == .orderedSame, !Task.isCancelled else { return nil }
        return await search(title: title, type: "movie", seasonTitle: nil, sources: sources,
                            client: client, budgets: [deadline, retryDeadline])
    }

    private static func search(
        title: String, type: String, seasonTitle: String?, sources: [AppleSource],
        client: AppleStremioCatalogClient, budgets: [Duration]
    ) async -> AppleCatalogSearchMatch? {
        // Configured metadata catalogs are asked first. Four catalogs and two
        // concurrent requests bound the work for each lazily visible card.
        let eligible = sources.compactMap { source -> AppleSource? in
            guard source.isEnabled, source.isAddon else { return nil }
            var value = source
            value.catalogs = Array(source.catalogs.filter { $0.type == type && $0.supportsSearch }.prefix(1))
            return value.catalogs.isEmpty ? nil : value
        }
        let searchable = searchSources(eligible, type: type)
        for (attempt, budget) in budgets.enumerated() {
            let store = AppleCatalogSearchStore(client: client, debounce: .zero, deadline: budget, maximumConcurrentRequests: 2)
            await store.search(query: title, sources: searchable, baseSections: []) { _ in [] }
            guard !Task.isCancelled else { return nil }
            let match = store.lookup.match(title: title, type: type, seasonTitle: seasonTitle, ignoringLeadingArticle: true)
                ?? anthologySeries(of: title, type: type).flatMap {
                    store.lookup.match(title: $0, type: type, ignoringLeadingArticle: true)
                }
            let candidates = searchable.flatMap { store.lookup.relatedItems(for: $0.id) }
            #if DEBUG
            AppleInteractionTrace.record(.network,
                "Top10 lookup title=\(title) type=\(type) attempt=\(attempt + 1) matched=\(match != nil) candidates=\(candidates.prefix(20).map(\.name).joined(separator: " | "))")
            #endif
            if let match { return match }
            // A cold metadata search can outlive the interactive search budget.
            // Retry once with more time; an answered, unmatched search is final.
            guard candidates.isEmpty, let metrics = store.metrics,
                  metrics.fetchDuration >= budget else { return nil }
        }
        return nil
    }

#else
    static func find(title: String, type: String, seasonTitle: String?, sources: [AppleSource]) async -> AppleCatalogSearchMatch? { nil }

#endif
    /// "Monster: The Lizzie Borden Story" → "Monster": Netflix names an
    /// anthology's season after its subtitle, the catalogs list the series.
    /// Series only — a film's subtitle is part of its own name.
    static func anthologySeries(of title: String, type: String) -> String? {
        guard type.caseInsensitiveCompare("series") == .orderedSame,
              let colon = title.firstIndex(of: ":") else { return nil }
        let name = title[..<colon].trimmingCharacters(in: .whitespaces)
        return name.isEmpty || name.count == title.count ? nil : name
    }

    /// The configured search catalogs, then Cinemeta's — the same fallback the
    /// library's title lookup uses. Without it a setup whose add-ons expose no
    /// search catalog (the iPhone review sim's only add-on lists `tmdb.top`,
    /// `tmdb.trending`… and none of them searchable) asked nobody, and every
    /// Top 10 tile stayed a grey box with its title in it (N11, 2026-09-23).
#if OPENSTREAM_ADDONS
    static func searchSources(_ eligible: [AppleSource], type: String) -> [AppleSource] {
        var values = Array(eligible.prefix(4))
        var cinemeta = AppleStremioMetadataClient.defaultMetadataSource
        guard !values.contains(where: { $0.manifestID == cinemeta.manifestID }) else { return values }
        cinemeta.resources = ["catalog", "meta"]
        cinemeta.catalogs = [.init(type: type, id: "top", supportsSearch: true)]
        values.append(cinemeta)
        return values
    }
#endif
}
