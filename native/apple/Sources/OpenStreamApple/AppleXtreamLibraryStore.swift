import Foundation
import Observation

@MainActor @Observable
final class AppleXtreamLibraryStore {
    static let shared = AppleXtreamLibraryStore()
    struct Shelf: Identifiable {
        let id: String
        let source: AppleSource
        let kind: AppleXtreamReference.Kind
        let category: AppleXtreamCategory
        let references: [AppleXtreamReference]
        let preview: [AppleCatalogItem]
        var title: String { "\(source.name) · \(kind == .movie ? "Movies" : "Series") · \(category.name)" }
    }
    private(set) var shelves: [Shelf] = []
    private(set) var failures: [UUID: String] = [:]
    private(set) var isLoading = false
    private(set) var revision = 0
    private(set) var continueWatching: [AppleCatalogItem] = []
    @ObservationIgnored private var titles: [AppleXtreamReference: AppleXtreamTitle] = [:]
    @ObservationIgnored private var sources: [UUID: AppleSource] = [:]
    @ObservationIgnored private var credentials: [UUID: AppleIPTVCredentials] = [:]
    @ObservationIgnored private var configurationID = ""
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var lastLoadedAt = Date.distantPast
    @ObservationIgnored private var searchReferences: [String: AppleXtreamReference] = [:]
    @ObservationIgnored private var progressReferences: [String: AppleXtreamReference] = [:]
    private let playbackStore: ApplePlaybackStore
    private let client: AppleXtreamLibraryClient

    init(client: AppleXtreamLibraryClient = .init(), playbackStore: ApplePlaybackStore = .init()) {
        self.client = client
        self.playbackStore = playbackStore
    }

    func catalog(_ reference: AppleXtreamReference) -> AppleCatalogItem? {
        titles[reference]?.catalog(sourceID: reference.sourceID)
    }
    func source(_ reference: AppleXtreamReference) -> AppleSource? { sources[reference.sourceID] }

    func reload(sourceStore: AppleSourceStore, force: Bool = false) async {
        let active = sourceStore.sources.filter { $0.isEnabled && $0.kind == .liveTV && $0.iptvType == .xtream }
        let identity = active.map { "\($0.id):\($0.url.absoluteString):\($0.configurationRevision)" }.joined(separator: "|")
        if isLoading, identity == configurationID { return }
        if !force, identity == configurationID, !shelves.isEmpty, AppleXtreamLibraryPolicy.isFresh(storedAt: lastLoadedAt, now: Date()) { refreshProgress(); return }
        generation += 1
        let current = generation
        configurationID = identity
        isLoading = true
        defer { if current == generation { isLoading = false; lastLoadedAt = Date(); refreshProgress() } }
        let ids = Set(active.map(\.id))
        let changed = Set(active.filter { sources[$0.id]?.configurationRevision != $0.configurationRevision }.map(\.id))
        shelves.removeAll { !ids.contains($0.source.id) || changed.contains($0.source.id) }
        titles = titles.filter { ids.contains($0.key.sourceID) && !changed.contains($0.key.sourceID) }
        sources = Dictionary(uniqueKeysWithValues: active.map { ($0.id, $0) })
        credentials = credentials.filter { ids.contains($0.key) }
        searchReferences = [:]
        progressReferences = progressReferences.filter { ids.contains($0.value.sourceID) && !changed.contains($0.value.sourceID) }
        failures = [:]
        revision += 1
        for source in active {
            do {
                guard let login = try sourceStore.iptvCredentials(for: source) else { throw AppleXtreamLibraryError.unavailable }
                credentials[source.id] = login
                for kind in [AppleXtreamReference.Kind.movie, .series] {
                    do {
                        let categories = try await client.categories(base: source.url, credentials: login, kind: kind, force: force)
                        guard current == generation, !Task.isCancelled else { return }
                        let categoryIDs = Set(categories.map(\.id))
                        shelves.removeAll { $0.source.id == source.id && $0.kind == kind && !categoryIDs.contains($0.category.id) }
                        let selected = categories.isEmpty ? [AppleXtreamCategory(id: "", name: "All")] : categories
                        for category in selected {
                            try Task.checkCancellation()
                            do {
                                let fetched = try await client.titles(base: source.url, credentials: login, kind: kind,
                                    categoryID: category.id.isEmpty ? nil : category.id, force: force)
                                guard current == generation, !Task.isCancelled else { return }
                                let (refs, progressKeys) = await Self.references(fetched, sourceID: source.id)
                                guard current == generation, !Task.isCancelled else { return }
                                progressReferences.merge(progressKeys) { _, new in new }
                                guard titles.count + fetched.filter({ titles[AppleXtreamReference(sourceID: source.id, kind: kind, providerID: $0.providerID)] == nil }).count <= 200_000 else {
                                    throw AppleXtreamLibraryError.tooLarge
                                }
                                for (ref, title) in zip(refs, fetched) { titles[ref] = title }
                                let id = "\(source.id):\(kind.rawValue):\(category.id)"
                                let shelf = Shelf(id: id, source: source, kind: kind, category: category, references: refs,
                                    preview: fetched.prefix(24).map { $0.catalog(sourceID: source.id) })
                                shelves.removeAll { $0.id == id }
                                shelves.append(shelf)
                                revision += 1
                            } catch is CancellationError { throw CancellationError() }
                            catch { failures[source.id] = AppleXtreamLibraryError.unavailableMessage(providerName: source.name) }
                        }
                    } catch is CancellationError { throw CancellationError() }
                    catch { failures[source.id] = AppleXtreamLibraryError.unavailableMessage(providerName: source.name) }
                }
            } catch is CancellationError { return }
            catch { failures[source.id] = AppleXtreamLibraryError.unavailableMessage(providerName: source.name) }
        }
        let retained = Set(shelves.flatMap(\.references))
        titles = titles.filter { retained.contains($0.key) }
        progressReferences = progressReferences.filter { retained.contains($0.value) }
    }

    func detail(_ reference: AppleXtreamReference) async throws -> AppleXtreamDetail {
        guard let source = sources[reference.sourceID], let login = credentials[reference.sourceID], let title = titles[reference] else {
            throw AppleXtreamLibraryError.unavailable
        }
        // Disk expiry remains authoritative; do not retain detail indefinitely in memory.
        let current = generation
        let value = try await client.detail(base: source.url, credentials: login, title: title)
        try Task.checkCancellation()
        guard current == generation else { throw CancellationError() }
        titles[reference] = value.title
        revision += 1
        return value
    }

    func episodes(_ detail: AppleXtreamDetail, sourceID: UUID) -> [AppleStremioEpisode] {
        detail.episodes.map {
            AppleStremioEpisode(id: AppleXtreamReference(sourceID: sourceID, kind: .series, providerID: detail.title.providerID).mediaID + ":\($0.season):\($0.number)",
                title: $0.title, season: $0.season, episode: $0.number)
        }
    }

    func request(reference: AppleXtreamReference, episodeID: String?, mediaID: String, fromBeginning: Bool) async throws -> ApplePlaybackRequest {
        guard let source = sources[reference.sourceID], let login = credentials[reference.sourceID], let title = titles[reference] else {
            throw AppleXtreamLibraryError.unavailable
        }
        let current = generation
        var target = reference
        var container = title.container
        if reference.kind == .movie, container == nil {
            do { container = try await detail(reference).title.container }
            catch is CancellationError { throw CancellationError() }
            catch { /* Provider summary playback can proceed without optional movie info. */ }
        }
        var displayTitle = title.name
        if reference.kind == .series {
            let value = try await detail(reference)
            guard let episodeID, let episode = value.episodes.first(where: { reference.mediaID + ":\($0.season):\($0.number)" == episodeID }) else {
                throw AppleXtreamLibraryError.unavailable
            }
            target = AppleXtreamReference(sourceID: reference.sourceID, kind: .episode, providerID: episode.providerID)
            container = episode.container
            displayTitle = episode.title
        }
        try Task.checkCancellation()
        guard current == generation else { throw CancellationError() }
        let url = try AppleXtreamLibraryPolicy.playbackURL(base: source.url, credentials: login,
            kind: target.kind, providerID: target.providerID, container: container)
        let partID = reference.kind == .series ? episodeID : nil
        var request = ApplePlaybackRequest(url: url,
            resumePosition: AppleTitlePagePolicy.startPosition(saved: AppleDetailResume.position(mediaID: mediaID, partID: partID, store: playbackStore), fromBeginning: fromBeginning),
            mediaID: mediaID, title: displayTitle, sourceName: source.name, sourceKind: .catalog,
            hints: .init(filename: "\(title.name).\(url.pathExtension)"))
        request.hints.progressPartID = partID
        request.subtitle = reference.kind == .series ? title.name : nil
        request.releaseYear = title.year
        request.artworkURL = title.poster
        return request
    }

    @concurrent private static func references(_ titles: [AppleXtreamTitle], sourceID: UUID) async -> ([AppleXtreamReference], [String: AppleXtreamReference]) {
        var refs: [AppleXtreamReference] = []
        var keys: [String: AppleXtreamReference] = [:]
        for title in titles {
            if Task.isCancelled { break }
            let ref = AppleXtreamReference(sourceID: sourceID, kind: title.kind, providerID: title.providerID)
            refs.append(ref)
            let recordID = AppleMediaIngestion.catalogRecord(instanceID: sourceID, item: title.catalog(sourceID: sourceID)).id
            if let key = ApplePlaybackIdentity.storageKey(for: recordID) { keys[key] = ref }
        }
        return (refs, keys)
    }

    func refreshProgress() {
        var values: [(AppleCatalogItem, Date)] = []
        for (key, progress) in playbackStore.savedProgress() {
            guard progress.resumePosition != nil, !playbackStore.isRemovedFromContinueWatching(mediaID: key),
                  let reference = progressReferences[key], let item = catalog(reference) else { continue }
            values.append((item, progress.updatedAt))
        }
        continueWatching = values.sorted { $0.1 > $1.1 }.prefix(24).map(\.0)
    }

    func search(_ query: String) async -> [AppleMediaRecord] {
        let activeTitles = titles
        let result = await Self.search(query, titles: activeTitles)
        for record in result {
            guard let id = record.canonicalID, let reference = AppleXtreamReference.parse(id) else { continue }
            for availability in record.availability { searchReferences[availability.itemReference] = reference }
        }
        return result
    }
    @concurrent private static func search(_ query: String, titles: [AppleXtreamReference: AppleXtreamTitle]) async -> [AppleMediaRecord] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        var results: [AppleMediaRecord] = []
        for (reference, title) in titles {
            if Task.isCancelled { return [] }
            guard title.name.localizedStandardContains(query) else { continue }
            results.append(AppleMediaIngestion.catalogRecord(instanceID: reference.sourceID, item: title.catalog(sourceID: reference.sourceID)))
            if results.count == 100 { break }
        }
        return results
    }
    func match(_ record: AppleMediaRecord) -> AppleCatalogSearchMatch? {
        _ = revision
        let reference = record.canonicalID.flatMap(AppleXtreamReference.parse)
            ?? record.availability.compactMap { searchReferences[$0.itemReference] }.first
        guard let reference, let item = catalog(reference), let source = source(reference) else { return nil }
        return AppleCatalogSearchMatch(item: item, source: source)
    }
}
