import Foundation

enum AppleDiscoverServerRows {
    struct Row: Identifiable, Sendable {
        let id: String
        let title: String
        var items: [AppleCatalogItem]
        var shelfIDs: [String]
        var isLoading: Bool
    }

    @MainActor
    final class Cache {
        private var revision: UInt64?
        private var sources: [AppleSource] = []
        private var pendingShelfIDs: Set<String> = []
        private var prepared: [Row] = []

        func rows(revision: UInt64, shelves: [AppleMediaServerLibraryStore.Shelf], sources: [AppleSource],
                  pendingShelfIDs: Set<String>) -> [Row] {
            if self.revision != revision || self.sources != sources || self.pendingShelfIDs != pendingShelfIDs {
                prepared = AppleDiscoverServerRows.rows(shelves, sources: sources,
                    pendingShelfIDs: pendingShelfIDs, previousRows: prepared)
                self.revision = revision
                self.sources = sources
                self.pendingShelfIDs = pendingShelfIDs
            }
            return prepared
        }
    }

    static func rows(_ shelves: [AppleMediaServerLibraryStore.Shelf], sources: [AppleSource],
                     pendingShelfIDs: Set<String> = [], previousRows: [Row] = []) -> [Row] {
        var merged: [Row] = []
        func append(id: String, title: String, items: [AppleCatalogItem], shelf: AppleMediaServerLibraryStore.Shelf) {
            let isLoading = pendingShelfIDs.contains(shelf.id)
            guard !items.isEmpty || isLoading else { return }
            if let index = merged.firstIndex(where: { $0.id == id || $0.title.caseInsensitiveCompare(title) == .orderedSame }) {
                merged[index].items += items
                merged[index].shelfIDs.append(shelf.id)
                merged[index].isLoading = merged[index].isLoading || isLoading
            } else {
                merged.append(Row(id: id, title: title, items: items, shelfIDs: [shelf.id], isLoading: isLoading))
            }
        }
        for source in sources where source.isEnabled && source.kind == .mediaServer {
            for shelf in shelves where shelf.sourceID == source.id && !isExcludedShelf(shelf) {
                let types = mediaTypes(shelf)
                guard !types.isEmpty else { continue }
                let items = shelf.items.filter { types.contains($0.type) && ($0.posterURL != nil || $0.backgroundURL != nil) }
                switch rowKind(shelf) {
                case .latest:
                    append(id: AppleDiscoverRowOrder.recentlyAdded, title: "Recently Added", items: items, shelf: shelf)
                case .top:
                    for (type, id) in [("movie", AppleDiscoverRowOrder.popularMovies), ("series", AppleDiscoverRowOrder.popularShows)]
                        where types.contains(type) {
                        append(id: id, title: AppleDiscoverRowOrder.title(forBuiltIn: id) ?? "",
                            items: items.filter { $0.type == type }, shelf: shelf)
                    }
                case .top10:
                    append(id: AppleDiscoverRowOrder.top10, title: AppleDiscoverRowOrder.top10Title, items: items, shelf: shelf)
                case .featured:
                    for (type, id) in [("movie", AppleDiscoverRowOrder.featuredMovies), ("series", AppleDiscoverRowOrder.featuredShows)]
                        where types.contains(type) {
                        append(id: id, title: AppleDiscoverRowOrder.title(forBuiltIn: id) ?? "",
                            items: items.filter { $0.type == type }, shelf: shelf)
                    }
                case .other, nil:
                    guard streamingService(in: shelf.title) == nil else { continue }
                    let title = AppleHomeRowLabel.clean(name: shelf.title, mediaTypes: types)
                    guard !title.isEmpty else { continue }
                    let builtIn = [AppleDiscoverRowOrder.featuredMovies, AppleDiscoverRowOrder.featuredShows,
                                   AppleDiscoverRowOrder.recentlyAdded, AppleDiscoverRowOrder.popularMovies,
                                   AppleDiscoverRowOrder.popularShows].first {
                        AppleDiscoverRowOrder.title(forBuiltIn: $0)?.caseInsensitiveCompare(title) == .orderedSame
                    }
                    let id = builtIn ?? "\(AppleDiscoverRowOrder.serverPrefix)\(source.id.uuidString.lowercased()):\(libraryID(shelf))"
                    append(id: id, title: title, items: items, shelf: shelf)
                }
            }
        }
        let previous = Dictionary(previousRows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let byID = Dictionary(uniqueKeysWithValues: merged.map { ($0.id, $0) })
        return AppleDiscoverRowOrder.ordered(merged.map(\.id)).compactMap { id in
            guard var row = byID[id] else { return nil }
            var seen = Set<String>()
            row.items = row.items.filter { seen.insert(AppleRecommendationRowScorer.displayIdentity($0)).inserted }
            // Newest first and a chart's ranks follow the server's order, not the last one shown.
            if id != AppleDiscoverRowOrder.recentlyAdded, id != AppleDiscoverRowOrder.top10 {
                row.items = AppleStableRefresh.merge(previous[id]?.items ?? [], incoming: row.items, id: \.mediaID)
            }
            return row
        }
    }

    private static func libraryID(_ shelf: AppleMediaServerLibraryStore.Shelf) -> String {
        let prefix = "ms:\(shelf.sourceID.uuidString.lowercased()):"
        if shelf.id.lowercased().hasPrefix(prefix) {
            return String(shelf.id.dropFirst(prefix.count).split(separator: ":", maxSplits: 1).first ?? "")
        }
        return shelf.id
    }

    private static func mediaTypes(_ shelf: AppleMediaServerLibraryStore.Shelf) -> Set<String> {
        if shelf.discoverySort == .top10 || shelf.discoverySort == .featured {
            return Set(shelf.items.map(\.type)).intersection(["movie", "series"])
        }
        return switch shelf.collectionType {
        case .movies: ["movie"]
        case .tvshows: ["series"]
        case .other, .collections: []
        case nil: Set(shelf.items.map(\.type)).intersection(["movie", "series"])
        }
    }

    private static func isExcludedShelf(_ shelf: AppleMediaServerLibraryStore.Shelf) -> Bool {
        if shelf.libraryName != nil { return true }
        let parts = Set(shelf.id.lowercased().split(separator: ":").map(String.init))
        return !parts.isDisjoint(with: ["genre", "nextup", "ondeck"]) || shelf.title.lowercased().hasPrefix("next up in ")
    }

    private static func rowKind(_ shelf: AppleMediaServerLibraryStore.Shelf) -> AppleMediaServerLibraryStore.Shelf.DiscoverySort? {
        if let sort = shelf.discoverySort { return sort == .other ? nil : sort }
        let id = shelf.id.lowercased()
        let words = Set(AppleHomeRowLabel.baseName(shelf.title).lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
        if id.hasSuffix(":latest") || id.hasSuffix(":recent") || !words.isDisjoint(with: ["latest", "recent", "recently"])
            || shelf.title.lowercased().hasPrefix("new releases") { return .latest }
        if !words.isDisjoint(with: ["top", "popular", "trending"]) { return .top }
        return nil
    }

    static func streamingService(in name: String) -> AppleStreamingService? {
        AppleHomeServices.service(in: name)
    }
}
