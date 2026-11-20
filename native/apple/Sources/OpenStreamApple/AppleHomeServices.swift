import Foundation

enum AppleHomeServices {
    enum MediaType: String, CaseIterable, Identifiable {
        case movies = "movie"
        case shows = "series"
        var id: Self { self }
        var title: String { self == .movies ? String(localized: "Movies") : String(localized: "Shows") }
    }

    struct Service: Identifiable, Sendable {
        let service: AppleStreamingService
        let libraries: [AppleMediaServerLibraryStore.Shelf]
        var id: String { service.rawValue }
        var itemCount: Int { libraries.reduce(0) { $0 + ($1.totalItemCount ?? $1.items.count) } }
        var mediaTypes: [MediaType] {
            MediaType.allCases.filter { type in
                libraries.contains { library in
                    switch library.collectionType {
                    case .movies: type == .movies
                    case .tvshows: type == .shows
                    case .collections, .other, nil: true
                    }
                }
            }
        }
        func title(customNames: [String: String]) -> String {
            AppleDiscoverRowOrder.title(for: id, defaultTitle: service.displayName, customNames: customNames)
        }
    }

    @MainActor
    final class Cache {
        private var revision: UInt64?
        private var sources: [AppleSource] = []
        private var hidden: Set<String> = []
        private var prepared: [Service] = []

        func services(revision: UInt64, libraries: @autoclosure () -> [AppleMediaServerLibraryStore.Shelf],
                      sources: [AppleSource], hidden: Set<String>) -> [Service] {
            if self.revision != revision || self.sources != sources || self.hidden != hidden {
                prepared = detect(libraries: libraries(), sources: sources, hidden: hidden)
                self.revision = revision
                self.sources = sources
                self.hidden = hidden
            }
            return prepared
        }
    }

    @MainActor
    final class ItemCache {
        private var revisions: [MediaType: UInt64] = [:]
        private var libraryIDs: [MediaType: [String]] = [:]
        private var prepared: [MediaType: [AppleCatalogItem]] = [:]

        func items(revision: UInt64, libraries: [AppleMediaServerLibraryStore.Shelf], type: MediaType) -> [AppleCatalogItem] {
            let ids = libraries.map(\.id)
            if revisions[type] != revision || libraryIDs[type] != ids {
                prepared[type] = AppleHomeServices.items(in: libraries, type: type, previous: prepared[type] ?? [])
                revisions[type] = revision
                libraryIDs[type] = ids
            }
            return prepared[type] ?? []
        }
    }

    static func service(in name: String) -> AppleStreamingService? {
        func words(_ value: String) -> String {
            value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .replacingOccurrences(of: "+", with: " plus ")
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
        }
        let name = words(AppleHomeRowLabel.baseName(name))
        if name == "max" { return .hboMax }
        return AppleStreamingService.allCases.first { service in
            service.libraryAliases.contains { (" " + name + " ").contains(" " + words($0) + " ") }
        }
    }

    static func detect(libraries: [AppleMediaServerLibraryStore.Shelf], sources: [AppleSource],
                       hidden: Set<String> = []) -> [Service] {
        let enabled = Set(sources.filter { $0.kind == .mediaServer && $0.isEnabled }.map(\.id))
        var grouped: [AppleStreamingService: [AppleMediaServerLibraryStore.Shelf]] = [:]
        for library in libraries where enabled.contains(library.sourceID) {
            guard let service = service(in: library.libraryName ?? library.title), !hidden.contains(service.rawValue) else { continue }
            grouped[service, default: []].append(library)
        }
        return grouped.map { Service(service: $0.key, libraries: $0.value) }
        .filter { group in
            group.libraries.contains { library in library.items.contains { isPlayable($0, in: library) } }
        }.sorted {
            if $0.itemCount != $1.itemCount { return $0.itemCount > $1.itemCount }
            return $0.service.displayName.localizedStandardCompare($1.service.displayName) == .orderedAscending
        }
    }

    private static func isPlayable(_ item: AppleCatalogItem, in library: AppleMediaServerLibraryStore.Shelf) -> Bool {
        AppleMediaServerItemReference.parse(item.mediaID)?.sourceID == library.sourceID
            && MediaType(rawValue: item.type) != nil && !item.name.isEmpty
    }

    static func items(in libraries: [AppleMediaServerLibraryStore.Shelf], type: MediaType? = nil,
                      previous: [AppleCatalogItem] = []) -> [AppleCatalogItem] {
        let previousIDs = Set(previous.map(\.id))
        var positions: [String: Int] = [:]
        var merged: [AppleCatalogItem] = []
        for library in libraries {
            for item in library.items where isPlayable(item, in: library) && (type == nil || item.type == type?.rawValue) {
                let identity = AppleRecommendationRowScorer.displayIdentity(item)
                if let position = positions[identity] {
                    if previousIDs.contains(item.id) { merged[position] = item }
                } else {
                    positions[identity] = merged.count
                    merged.append(item)
                }
            }
        }
        return AppleStableRefresh.merge(previous, incoming: merged) { AppleRecommendationRowScorer.displayIdentity($0) }
    }
}
