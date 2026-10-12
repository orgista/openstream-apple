import Foundation
import Observation

public struct AppleMediaServerItemReference: Equatable, Hashable, Sendable {
    public let sourceID: UUID
    public let itemID: String

    public static let prefix = "ms:"

    public var mediaID: String {
        "ms:\(sourceID.uuidString.lowercased()):\(itemID)"
    }

    public static func parse(_ mediaID: String) -> AppleMediaServerItemReference? {
        guard mediaID.hasPrefix(AppleMediaServerItemReference.prefix) else { return nil }
        let remainder = mediaID.dropFirst(AppleMediaServerItemReference.prefix.count)
        let parts = remainder.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        guard let sourceID = UUID(uuidString: String(parts[0])), !parts[1].isEmpty else { return nil }
        return AppleMediaServerItemReference(sourceID: sourceID, itemID: String(parts[1]))
    }
}

@MainActor
@Observable
public final class AppleMediaServerLibraryStore {
    public struct Shelf: Identifiable, Equatable, Sendable, Codable {
        public let id: String
        public let title: String
        public let sourceID: UUID
        public let items: [AppleCatalogItem]
        
        public init(id: String, title: String, sourceID: UUID, items: [AppleCatalogItem]) {
            self.id = id
            self.title = title
            self.sourceID = sourceID
            self.items = items
        }
    }

    public private(set) var shelves: [Shelf] = []
    public private(set) var continueWatching: [AppleCatalogItem] = []
    public private(set) var isLoading = false
    public private(set) var failures: [UUID: String] = [:]
    public private(set) var lastLoadedAt: Date?
    
    private var plexIndex: [AppleMediaServerItemReference: ApplePlexItem] = [:]
    private var index: [AppleMediaServerItemReference: AppleMediaServerItem] = [:]
    private var sourceIndex: [UUID: AppleSource] = [:]
    private var sessionIndex: [UUID: AppleMediaServerSession] = [:]
    
    private struct CachedDetail: Sendable {
        let detail: AppleMediaServerDetail
        let fetchedAt: Date
    }
    private var detailCache: [AppleMediaServerItemReference: CachedDetail] = [:]
    
    public struct AppleMediaServerPlaybackTicket: Sendable {
        let session: AppleMediaServerSession
        let mediaSourceID: String
        let playSessionID: String?
    }

    private var activeTickets: [String: AppleMediaServerPlaybackTicket] = [:]
    private var stoppedSessions: Set<String> = []

    private let client: AppleMediaServerClient
    private let plexClient: ApplePlexClient
    private var generation: Int = 0
    
    public init(client: AppleMediaServerClient = AppleMediaServerClient(), plexClient: ApplePlexClient = ApplePlexClient()) {
        self.client = client
        self.plexClient = plexClient
    }
    
    public func plexItem(for reference: AppleMediaServerItemReference) -> ApplePlexItem? {
        plexIndex[reference]
    }
    
    public func item(for reference: AppleMediaServerItemReference) -> AppleMediaServerItem? {
        index[reference]
    }
    
    /// Keep the server's resume fraction on the shelf record as well as its title page.
    public func continueWatchingRecord(for catalogItem: AppleCatalogItem, source: AppleSource) -> AppleMediaRecord {
        var record = AppleMediaIngestion.catalogRecord(instanceID: source.id, item: catalogItem)
        guard let reference = AppleMediaServerItemReference.parse(catalogItem.mediaID),
              let item = index[reference], let data = item.userData, !data.played,
              let duration = item.runtimeSeconds, duration.isFinite, duration > 0,
              data.positionSeconds.isFinite, data.positionSeconds > 0 else { return record }
        record.progress = min(data.positionSeconds / duration, 1)
        return record
    }

    public func source(for reference: AppleMediaServerItemReference) -> AppleSource? {
        sourceIndex[reference.sourceID]
    }
    
    public func clear(sourceID: UUID) {
        shelves.removeAll { $0.sourceID == sourceID }
        continueWatching.removeAll { AppleMediaServerItemReference.parse($0.mediaID)?.sourceID == sourceID }
        let keysToRemove = index.keys.filter { $0.sourceID == sourceID }
        for key in keysToRemove {
            index.removeValue(forKey: key)
        }
        let plexKeysToRemove = plexIndex.keys.filter { $0.sourceID == sourceID }
        for key in plexKeysToRemove {
            plexIndex.removeValue(forKey: key)
        }
        let cacheKeysToRemove = detailCache.keys.filter { $0.sourceID == sourceID }
        for key in cacheKeysToRemove {
            detailCache.removeValue(forKey: key)
        }
        sourceIndex.removeValue(forKey: sourceID)
        sessionIndex.removeValue(forKey: sourceID)
        failures.removeValue(forKey: sourceID)
        persist()
    }
    
    nonisolated public func catalogItem(_ item: ApplePlexItem, source: AppleSource, session: AppleMediaServerSession) -> AppleCatalogItem {
        let mappedType: String
        switch item.type {
        case .movie: mappedType = "movie"
        case .show, .season, .episode: mappedType = "series"
        default: mappedType = "movie"
        }
        
        let mediaID = AppleMediaServerItemReference(sourceID: source.id, itemID: item.ratingKey).mediaID
        
        let plexClient = ApplePlexClient()
        
        let posterURL: URL?
        if let thumb = item.thumbPath {
            posterURL = plexClient.imageURL(session: session, path: thumb, width: 600, height: 900)
        } else {
            posterURL = nil
        }
        
        let backgroundURL: URL?
        if let art = item.artPath {
            backgroundURL = plexClient.imageURL(session: session, path: art, width: 1920, height: 1080)
        } else {
            backgroundURL = nil
        }
        
        let releaseInfo: String?
        if let y = item.year {
            releaseInfo = String(y)
        } else {
            releaseInfo = nil
        }
        
        return AppleCatalogItem(
            mediaID: mediaID,
            type: mappedType,
            name: item.title,
            posterURL: posterURL,
            backgroundURL: backgroundURL,
            summary: item.summary,
            releaseInfo: releaseInfo,
            rating: nil, // Plex API in client didn't expose rating easily, so nil
            genres: nil, // and genres
            year: item.year
        )
    }

    nonisolated public func catalogItem(_ item: AppleMediaServerItem, source: AppleSource, session: AppleMediaServerSession) -> AppleCatalogItem {
        let mappedType: String
        switch item.type {
        case .movie: mappedType = "movie"
        case .series, .episode: mappedType = "series"
        default: mappedType = "movie"
        }
        
        let mediaID = AppleMediaServerItemReference(sourceID: source.id, itemID: item.id).mediaID
        
        let posterURL: URL?
        if let primaryTag = item.primaryImageTag {
            posterURL = try? client.imageURL(session: session, itemID: item.id, type: .primary, tag: primaryTag, maxWidth: 600)
        } else {
            posterURL = nil
        }
        
        let backgroundURL: URL?
        if let backdropTag = item.backdropImageTags.first {
            backgroundURL = try? client.imageURL(session: session, itemID: item.id, type: .backdrop, tag: backdropTag, maxWidth: nil)
        } else {
            backgroundURL = nil
        }
        
        let releaseInfo: String?
        if let y = item.year {
            releaseInfo = String(y)
        } else {
            releaseInfo = nil
        }
        
        return AppleCatalogItem(
            mediaID: mediaID,
            type: mappedType,
            name: item.name,
            posterURL: posterURL,
            backgroundURL: backgroundURL,
            summary: item.overview,
            releaseInfo: releaseInfo,
            rating: item.communityRating,
            genres: item.genres.isEmpty ? nil : item.genres,
            year: item.year
        )
    }
    
    /// Genre rails from the loaded library page: no extra requests and no invented categories.
    nonisolated static func genreShelves(items: [AppleCatalogItem], sourceID: UUID, libraryID: String) -> [Shelf] {
        let genres = Set(items.flatMap { $0.genres ?? [] }.filter { !$0.isEmpty }).sorted()
        return genres.compactMap { genre in
            let matches = items.filter { $0.genres?.contains(genre) == true }
            guard matches.count >= 2 else { return nil }
            return Shelf(id: "ms:\(sourceID.uuidString.lowercased()):\(libraryID):genre:\(genre)",
                         title: genre, sourceID: sourceID, items: matches)
        }
    }

    public func reload(sources: [AppleSource], session: @MainActor @Sendable (AppleSource) throws -> AppleMediaServerSession?) async {
        generation += 1
        let currentGeneration = generation
        isLoading = true
        
        var validSources: [(source: AppleSource, session: AppleMediaServerSession)] = []
        for source in sources where source.kind == .mediaServer && source.isEnabled {
            if let sess = try? session(source) {
                validSources.append((source, sess))
            }
        }
        
        struct RawShelf: Sendable {
            let id: String
            let title: String
            let sourceID: UUID
            let items: [AppleCatalogItem]
            let rawItems: [AppleMediaServerItem]
        }
        
        struct SourceResult: Sendable {
            let sourceID: UUID
            let shelves: [RawShelf]
            let continueWatching: [AppleCatalogItem]
            let allRawItems: [AppleMediaServerItem]
            let allPlexItems: [ApplePlexItem]
            let source: AppleSource
            let error: String?
        }
        
        let client = self.client
        let plexClient = self.plexClient
        let catalogMapper: @Sendable (AppleMediaServerItem, AppleSource, AppleMediaServerSession) -> AppleCatalogItem = self.catalogItem
        let plexCatalogMapper: @Sendable (ApplePlexItem, AppleSource, AppleMediaServerSession) -> AppleCatalogItem = self.catalogItem
        
        let results = await withTaskGroup(of: SourceResult.self) { group in
            for (source, sess) in validSources {
                group.addTask {
                    do {
                        var allRawItems: [AppleMediaServerItem] = []
                        var allPlexItems: [ApplePlexItem] = []
                        
                        if sess.kind == .plex {
                            let onDeckItems = try await plexClient.onDeck(session: sess)
                            let cwItems = onDeckItems.map { plexCatalogMapper($0, source, sess) }
                            allPlexItems.append(contentsOf: onDeckItems)
                            
                            let sections = try await plexClient.sections(session: sess)
                            var rawShelves: [RawShelf] = []
                            for section in sections {
                                guard section.type == .movie || section.type == .show else { continue }
                                let recent = try await plexClient.recentlyAdded(session: sess, sectionKey: section.key)
                                allPlexItems.append(contentsOf: recent)
                                
                                let shelfItems = recent.map { plexCatalogMapper($0, source, sess) }
                                rawShelves.append(RawShelf(
                                    id: "ms:\(source.id.uuidString.lowercased()):\(section.key):recent",
                                    title: "Recently added in \(section.title)",
                                    sourceID: source.id,
                                    items: shelfItems,
                                    rawItems: []
                                ))
                            }
                            
                            return SourceResult(
                                sourceID: source.id,
                                shelves: rawShelves,
                                continueWatching: cwItems,
                                allRawItems: [],
                                allPlexItems: allPlexItems,
                                source: source,
                                error: nil
                            )
                        }
                        
                        let resumePage = try await client.resume(session: sess, limit: 20)
                        let cwItems = resumePage.items.map { catalogMapper($0, source, sess) }
                        allRawItems.append(contentsOf: resumePage.items)
                        
                        let libraries = try await client.libraries(session: sess)
                        var rawShelves: [RawShelf] = []
                        
                        for library in libraries {
                            guard library.collectionType == .movies || library.collectionType == .tvshows else { continue }
                            
                            let latestItems = try await client.latest(session: sess, parentID: library.id, limit: 20)
                            allRawItems.append(contentsOf: latestItems)
                            
                            let shelfItems = latestItems.map { catalogMapper($0, source, sess) }
                            rawShelves.append(RawShelf(
                                id: "ms:\(source.id.uuidString.lowercased()):\(library.id):latest",
                                title: "Latest in \(library.name)",
                                sourceID: source.id,
                                items: shelfItems,
                                rawItems: latestItems
                            ))
                            rawShelves += Self.genreShelves(items: shelfItems, sourceID: source.id, libraryID: library.id)
                                .map { RawShelf(id: $0.id, title: $0.title, sourceID: $0.sourceID,
                                               items: $0.items, rawItems: []) }
                        }
                        
                        return SourceResult(
                            sourceID: source.id,
                            shelves: rawShelves,
                            continueWatching: cwItems,
                            allRawItems: allRawItems,
                            allPlexItems: [],
                            source: source,
                            error: nil
                        )
                        
                    } catch {
                        let errorMsg: String
                        if let e = error as? AppleMediaServerError {
                            errorMsg = AppleMediaServerFormPolicy.message(for: e)
                        } else {
                            errorMsg = "An unexpected error occurred."
                        }
                        
                        return SourceResult(
                            sourceID: source.id,
                            shelves: [],
                            continueWatching: [],
                            allRawItems: [],
                            allPlexItems: [],
                            source: source,
                            error: errorMsg
                        )
                    }
                }
            }
            
            var collected: [SourceResult] = []
            for await res in group {
                collected.append(res)
            }
            return collected
        }
        
        guard currentGeneration == self.generation else { return }
        
        var nextShelves: [Shelf] = []
        var nextCW: [AppleCatalogItem] = []
        var cwSeen: Set<String> = []
        
        let sortedResults = results.sorted { a, b in
            let aIdx = validSources.firstIndex { $0.source.id == a.sourceID } ?? Int.max
            let bIdx = validSources.firstIndex { $0.source.id == b.sourceID } ?? Int.max
            return aIdx < bIdx
        }
        
        for res in sortedResults {
            if let error = res.error {
                self.failures[res.sourceID] = error
                nextShelves.append(contentsOf: self.shelves.filter { $0.sourceID == res.sourceID })
                nextCW.append(contentsOf: self.continueWatching.filter { AppleMediaServerItemReference.parse($0.mediaID)?.sourceID == res.sourceID })
            } else {
                self.failures.removeValue(forKey: res.sourceID)
                nextShelves.append(contentsOf: res.shelves.map { Shelf(id: $0.id, title: $0.title, sourceID: $0.sourceID, items: $0.items) })
                nextCW.append(contentsOf: res.continueWatching)
                
                self.sourceIndex[res.sourceID] = res.source
                if let sess = validSources.first(where: { $0.source.id == res.sourceID })?.session {
                    self.sessionIndex[res.sourceID] = sess
                }
                for item in res.allRawItems {
                    let ref = AppleMediaServerItemReference(sourceID: res.sourceID, itemID: item.id)
                    self.index[ref] = item
                }
                for item in res.allPlexItems {
                    let ref = AppleMediaServerItemReference(sourceID: res.sourceID, itemID: item.ratingKey)
                    self.plexIndex[ref] = item
                }
            }
        }
        
        var finalShelves: [Shelf] = []
        var finalCW: [AppleCatalogItem] = []
        
        for source in sources {
            if let res = sortedResults.first(where: { $0.sourceID == source.id }) {
                if res.error != nil {
                    finalShelves.append(contentsOf: self.shelves.filter { $0.sourceID == source.id })
                    finalCW.append(contentsOf: self.continueWatching.filter { AppleMediaServerItemReference.parse($0.mediaID)?.sourceID == source.id })
                } else {
                    finalShelves.append(contentsOf: res.shelves.map { Shelf(id: $0.id, title: $0.title, sourceID: $0.sourceID, items: $0.items) })
                    finalCW.append(contentsOf: res.continueWatching)
                }
            } else {
                finalShelves.append(contentsOf: self.shelves.filter { $0.sourceID == source.id })
                finalCW.append(contentsOf: self.continueWatching.filter { AppleMediaServerItemReference.parse($0.mediaID)?.sourceID == source.id })
            }
        }
        
        var dedupedCW: [AppleCatalogItem] = []
        for cw in finalCW {
            if !cwSeen.contains(cw.mediaID) {
                cwSeen.insert(cw.mediaID)
                dedupedCW.append(cw)
            }
        }
        
        self.shelves = finalShelves
        self.continueWatching = dedupedCW
        self.lastLoadedAt = Date()
        self.isLoading = false
        
        persist()
    }
    
    private struct PersistedState: Codable {
        let shelves: [Shelf]
        let continueWatching: [AppleCatalogItem]
        let lastLoadedAt: Date?
    }
    
    private func cacheURL() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = caches.appendingPathComponent("OpenStream")
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent("MediaServers-v1.json")
    }
    
    private func persist() {
        let state = PersistedState(shelves: shelves, continueWatching: continueWatching, lastLoadedAt: lastLoadedAt)
        if let data = try? AppleCachedCredentialPolicy.metadata(JSONEncoder().encode(state)) {
            // Poster and stream URLs here carry X-Plex-Token / api_key.
            var url = cacheURL()
            try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        }
    }
    
    public func loadPersisted() {
        guard let data = try? Data(contentsOf: cacheURL()),
              let clean = try? AppleCachedCredentialPolicy.metadata(data),
              let state = try? JSONDecoder().decode(PersistedState.self, from: clean) else {
            return
        }
        self.shelves = state.shelves
        self.continueWatching = state.continueWatching
        self.lastLoadedAt = state.lastLoadedAt
        persist() // Strip tokens from older saved copies as soon as they are read.
    }
    
    public struct AppleMediaServerDetail: Equatable, Sendable {
        public let item: AppleMediaServerItem
        public let source: AppleSource
        public let session: AppleMediaServerSession
        public let seasons: [AppleMediaServerItem]
        public let episodesBySeason: [String: [AppleMediaServerItem]]
        
        public init(item: AppleMediaServerItem, source: AppleSource, session: AppleMediaServerSession, seasons: [AppleMediaServerItem], episodesBySeason: [String: [AppleMediaServerItem]]) {
            self.item = item
            self.source = source
            self.session = session
            self.seasons = seasons
            self.episodesBySeason = episodesBySeason
        }
    }

    public static func mergedResume(local: ApplePlaybackProgress?, server: AppleMediaServerItem.UserData?) -> Double? {
        if let s = server, s.played {
            return s.positionSeconds
        }
        let l = local?.position ?? 0
        let s = server?.positionSeconds ?? 0
        if l == 0 && s == 0 {
            return local?.position ?? server?.positionSeconds
        }
        return max(l, s)
    }

    public static func resumePosition(for item: AppleMediaServerItem, local: ApplePlaybackProgress? = nil) -> Double? {
        guard let position = mergedResume(local: local, server: item.userData),
              let duration = item.runtimeSeconds,
              duration > 0 else { return nil }
        
        if position >= 15.0 && position < duration * 0.95 {
            return position
        }
        return nil
    }

    public func attach(to coordinator: ApplePlaybackCoordinator) {
        coordinator.remoteProgressSink = { [weak self] mediaID, position, duration, event in
            guard let self = self else { return }
            self.handleRemoteProgress(mediaID: mediaID, position: position, duration: duration, event: event)
        }
    }

    internal func handleRemoteProgress(mediaID: String, position: Double, duration: Double, event: ApplePlaybackCoordinator.RemoteProgressEvent) {
        guard let ref = AppleMediaServerItemReference.parse(mediaID),
              let ticket = activeTickets[mediaID] else { return }
        
        if event == .stopped {
            // One stop per play: a second .stopped for the same request is ignored
            // until `playbackRequest` hands out a new ticket for this media id.
            if stoppedSessions.contains(mediaID) { return }
            stoppedSessions.insert(mediaID)
            applyStop(reference: ref, mediaID: mediaID, position: position, duration: duration)
        }
        
        Task {
            do {
                if ticket.session.kind == .plex {
                    guard let pItem = plexIndex[ref] else { return }
                    let state: ApplePlexClient.PlaybackState
                    switch event {
                    case .started, .progress: state = .playing
                    case .paused: state = .paused
                    case .stopped: state = .stopped
                    }
                    try await self.plexClient.reportTimeline(session: ticket.session, item: pItem, state: state, positionSeconds: position)
                    if event == .stopped && duration > 0 && position >= duration * 0.95 {
                        try await self.plexClient.markPlayed(session: ticket.session, ratingKey: ref.itemID)
                    }
                } else {
                    switch event {
                    case .started:
                        try await self.client.reportPlaybackStart(session: ticket.session, itemID: ref.itemID, mediaSourceID: ticket.mediaSourceID, playSessionID: ticket.playSessionID, positionSeconds: position)
                    case .progress:
                        try await self.client.reportPlaybackProgress(session: ticket.session, itemID: ref.itemID, mediaSourceID: ticket.mediaSourceID, playSessionID: ticket.playSessionID, positionSeconds: position, isPaused: false)
                    case .paused:
                        try await self.client.reportPlaybackProgress(session: ticket.session, itemID: ref.itemID, mediaSourceID: ticket.mediaSourceID, playSessionID: ticket.playSessionID, positionSeconds: position, isPaused: true)
                    case .stopped:
                        try await self.client.reportPlaybackStopped(session: ticket.session, itemID: ref.itemID, mediaSourceID: ticket.mediaSourceID, playSessionID: ticket.playSessionID, positionSeconds: position)
                    }
                }
            } catch {
                appleTrace("Remote progress failed: \(AppleDiagnosticRedactor.describe(error))")
            }
        }
    }

    /// Mirrors a finished play into the in-memory item and the resume row at
    /// once, so Continue Watching is right before the server answers.
    private func applyStop(reference ref: AppleMediaServerItemReference, mediaID: String, position: Double, duration: Double) {
        guard let item = index[ref] else { return }
        let played = duration > 0 && position >= duration * 0.95
        let old = item.userData
        let newUserData = AppleMediaServerItem.UserData(
            positionSeconds: played ? 0 : position,
            played: played || (old?.played ?? false),
            isFavorite: old?.isFavorite ?? false,
            playCount: (old?.playCount ?? 0) + (played ? 1 : 0)
        )
        let newItem = item.withUserData(newUserData)
        index[ref] = newItem
        continueWatching.removeAll(where: { $0.mediaID == mediaID })
        if !played, let source = sourceIndex[ref.sourceID], let sess = sessionIndex[ref.sourceID] {
            continueWatching.insert(catalogItem(newItem, source: source, session: sess), at: 0)
        }
    }

    public func detail(for reference: AppleMediaServerItemReference) async throws -> AppleMediaServerDetail {
        if let cached = detailCache[reference], Date().timeIntervalSince(cached.fetchedAt) < 600 {
            return cached.detail
        }
        
        guard let source = sourceIndex[reference.sourceID],
              let session = sessionIndex[reference.sourceID] else {
            throw AppleMediaServerError.unsupported
        }
        
        if session.kind == .plex {
            let freshPlexItem = try await plexClient.item(session: session, ratingKey: reference.itemID)
            plexIndex[reference] = freshPlexItem
            
            var plexSeasons: [ApplePlexItem] = []
            var plexEpisodesBySeason: [String: [ApplePlexItem]] = [:]
            
            if freshPlexItem.type == .show {
                plexSeasons = try await plexClient.children(session: session, ratingKey: freshPlexItem.ratingKey)
                for season in plexSeasons {
                    let episodes = try await plexClient.children(session: session, ratingKey: season.ratingKey)
                    plexEpisodesBySeason[season.ratingKey] = episodes
                }
            }
            
            func toMediaServerItem(_ plex: ApplePlexItem) -> AppleMediaServerItem {
                let type: AppleMediaServerItemType
                switch plex.type {
                case .movie: type = .movie
                case .show: type = .series
                case .season: type = .season
                case .episode: type = .episode
                case .other: type = .other
                }
                
                var userData: AppleMediaServerItem.UserData?
                if let viewOffset = plex.viewOffsetSeconds, let dur = plex.durationSeconds {
                    userData = AppleMediaServerItem.UserData(
                        positionSeconds: viewOffset,
                        played: (plex.viewCount ?? 0) > 0 || viewOffset >= dur * 0.95,
                        isFavorite: false,
                        playCount: plex.viewCount ?? 0
                    )
                }
                
                return AppleMediaServerItem(
                    id: plex.ratingKey,
                    name: plex.title,
                    type: type,
                    year: plex.year,
                    overview: plex.summary,
                    runtimeSeconds: plex.durationSeconds,
                    seriesID: freshPlexItem.ratingKey,
                    seasonID: plex.parentRatingKey,
                    indexNumber: plex.index,
                    parentIndexNumber: plex.parentIndex,
                    userData: userData
                )
            }
            
            let freshItem = toMediaServerItem(freshPlexItem)
            index[reference] = freshItem
            
            var seasons: [AppleMediaServerItem] = []
            var episodesBySeason: [String: [AppleMediaServerItem]] = [:]
            
            for pSeason in plexSeasons {
                seasons.append(toMediaServerItem(pSeason))
                if let pEps = plexEpisodesBySeason[pSeason.ratingKey] {
                    episodesBySeason[pSeason.ratingKey] = pEps.map { toMediaServerItem($0) }
                }
            }
            
            let detail = AppleMediaServerDetail(item: freshItem, source: source, session: session, seasons: seasons, episodesBySeason: episodesBySeason)
            detailCache[reference] = CachedDetail(detail: detail, fetchedAt: Date())
            return detail
        }
        
        let freshItem = try await client.item(session: session, id: reference.itemID)
        index[reference] = freshItem
        
        var seasons: [AppleMediaServerItem] = []
        var episodesBySeason: [String: [AppleMediaServerItem]] = [:]
        
        if freshItem.type == .series || freshItem.type == .episode {
            let allSeasons = try await client.seasons(session: session, seriesID: reference.itemID)
            
            let episodes = await withTaskGroup(of: (String, [AppleMediaServerItem]).self) { group in
                for season in allSeasons {
                    group.addTask {
                        let eps = (try? await self.client.episodes(session: session, seriesID: reference.itemID, seasonID: season.id)) ?? []
                        return (season.id, eps)
                    }
                }
                var collected: [String: [AppleMediaServerItem]] = [:]
                for await res in group {
                    if !res.1.isEmpty {
                        collected[res.0] = res.1
                    }
                }
                return collected
            }
            
            for season in allSeasons {
                if let eps = episodes[season.id], !eps.isEmpty {
                    seasons.append(season)
                    episodesBySeason[season.id] = eps
                }
            }
        }
        
        let detail = AppleMediaServerDetail(item: freshItem, source: source, session: session, seasons: seasons, episodesBySeason: episodesBySeason)
        detailCache[reference] = CachedDetail(detail: detail, fetchedAt: Date())
        return detail
    }

    nonisolated static func offlinePlaybackRequest(record: AppleOfflineRecord, title: String, resumePosition: Double?) throws -> ApplePlaybackRequest {
        guard record.localURL.isFileURL else { throw AppleOfflineStoreError.uncontainedSourceFileURL }
        return ApplePlaybackRequest(url: record.localURL, headers: [:], isLive: false,
            resumePosition: resumePosition, autoplay: true, mediaID: record.mediaID,
            title: title, sourceName: "Downloads", sourceKind: .mediaServer,
            hints: .init(libraryFileURL: record.localURL))
    }

    public func downloadsAllowed(in detail: AppleMediaServerDetail) async throws -> Bool {
        if detail.session.kind == .plex { return try await plexClient.downloadsAllowed(session: detail.session) }
        return try await client.downloadsAllowed(session: detail.session)
    }

    func downloadPlan(reference: AppleMediaServerItemReference) async throws -> AppleOfflineDownloadPlan {
        let detail = try await detail(for: reference)
        let allowed = try await downloadsAllowed(in: detail)
        guard allowed else { throw AppleMediaServerError.downloadNotAllowed }
        let request: URLRequest
        if detail.session.kind == .plex {
            let fresh = try await plexClient.item(session: detail.session, ratingKey: reference.itemID)
            guard [.movie, .episode].contains(fresh.type), let part = fresh.parts.first else {
                throw AppleMediaServerError.unsupported
            }
            request = try plexClient.downloadRequest(session: detail.session, part: part, allowed: allowed)
        } else {
            guard [.movie, .episode].contains(detail.item.type) else { throw AppleMediaServerError.unsupported }
            request = try client.downloadRequest(session: detail.session, itemID: reference.itemID, allowed: allowed)
        }
        guard let url = request.url else { throw AppleMediaServerError.unreachable }
        return .init(sourceURL: url, requestHeaders: request.allHTTPHeaderFields ?? [:],
                     protectedCapabilityToRevoke: nil, usesBackgroundSession: true)
    }

    public func playbackRequest(for item: AppleMediaServerItem, in detail: AppleMediaServerDetail, resume: Bool) async throws -> ApplePlaybackRequest {
        if detail.session.kind == .plex {
            guard let plexItem = plexIndex[AppleMediaServerItemReference(sourceID: detail.source.id, itemID: item.id)] else {
                throw AppleMediaServerError.unsupported
            }
            guard let part = plexItem.parts.first else {
                throw AppleMediaServerError.unsupported
            }
            let url = plexClient.directPlayURL(session: detail.session, part: part)
            
            let mediaID = AppleMediaServerItemReference(sourceID: detail.source.id, itemID: item.id).mediaID
            stoppedSessions.remove(mediaID)
            activeTickets[mediaID] = AppleMediaServerPlaybackTicket(
                session: detail.session,
                mediaSourceID: part.key,
                playSessionID: nil
            )
            
            let position: Double?
            if resume, let offset = plexItem.viewOffsetSeconds, let dur = plexItem.durationSeconds {
                position = (offset >= dur * 0.95) ? nil : offset
            } else {
                position = nil
            }
            
            let title: String
            if item.type == .episode {
                let sIdx = item.parentIndexNumber.map { String($0) } ?? "?"
                let eIdx = item.indexNumber.map { String($0) } ?? "?"
                let series = item.seriesName ?? detail.item.name
                title = "\(series) S\(sIdx)E\(eIdx)"
            } else {
                title = item.name
            }
            
            return ApplePlaybackRequest(
                url: url,
                headers: ["X-Plex-Token": detail.session.accessToken],
                isLive: false,
                resumePosition: position,
                autoplay: true,
                mediaID: mediaID,
                title: title,
                sourceName: detail.source.name,
                sourceKind: .mediaServer,
                hints: ApplePlaybackRequest.Hints()
            )
        }
        
        let info = try await client.playbackInfo(session: detail.session, itemID: item.id)
        
        guard let mediaSource = info.mediaSources.first(where: { $0.supportsDirectPlay || $0.supportsDirectStream }) else {
            throw AppleMediaServerError.unsupported
        }
        
        let container = mediaSource.container?.components(separatedBy: ",").first ?? mediaSource.container
        let url = try client.directStreamURL(
            session: detail.session,
            itemID: item.id,
            mediaSourceID: mediaSource.id,
            container: container
        )
        
        let mediaID = AppleMediaServerItemReference(sourceID: detail.source.id, itemID: item.id).mediaID
        stoppedSessions.remove(mediaID)
        activeTickets[mediaID] = AppleMediaServerPlaybackTicket(
            session: detail.session,
            mediaSourceID: mediaSource.id,
            playSessionID: info.playSessionID
        )

        let local = ApplePlaybackStore().progress(for: mediaID)
        let position = resume ? Self.resumePosition(for: item, local: local) : nil
        
        let title: String
        if item.type == .episode {
            let sIdx = item.parentIndexNumber.map { String($0) } ?? "?"
            let eIdx = item.indexNumber.map { String($0) } ?? "?"
            let sName = item.seriesName ?? detail.item.name
            title = "\(sName) · S\(sIdx)E\(eIdx) \(item.name)"
        } else {
            title = item.name
        }
        
        return ApplePlaybackRequest(
            url: url,
            headers: [:],
            isLive: false,
            resumePosition: position,
            autoplay: true,
            mediaID: mediaID,
            title: title,
            sourceName: detail.source.name,
            sourceKind: .mediaServer,
            hints: ApplePlaybackRequest.Hints()
        )
    }

    public func metadata(from detail: AppleMediaServerDetail) -> AppleTMDBDetails {
        let item = detail.item
        
        let posterURL: URL? = {
            if let tag = item.primaryImageTag {
                return try? client.imageURL(session: detail.session, itemID: item.id, type: .primary, tag: tag, maxWidth: 600)
            }
            return nil
        }()
        
        let backdropURL: URL? = {
            if let tag = item.backdropImageTags.first {
                return try? client.imageURL(session: detail.session, itemID: item.id, type: .backdrop, tag: tag, maxWidth: nil)
            }
            return nil
        }()
        
        let logoURL: URL? = {
            if let tag = item.logoImageTag {
                return try? client.imageURL(session: detail.session, itemID: item.id, type: .logo, tag: tag, maxWidth: 600)
            }
            return nil
        }()
        
        let runtimeMinutes = item.runtimeSeconds.map { Int($0 / 60) }
        let mappedType = (item.type == .series || item.type == .episode) ? "series" : "movie"
        
        return AppleTMDBDetails(
            mediaID: AppleMediaServerItemReference(sourceID: detail.source.id, itemID: item.id).mediaID,
            mediaType: mappedType,
            title: item.name,
            releaseInfo: item.year.map { String($0) },
            runtimeMinutes: runtimeMinutes,
            genres: item.genres,
            imdbRating: item.communityRating,
            year: item.year,
            overview: item.overview,
            posterURL: posterURL,
            backdropURL: backdropURL,
            logoURL: logoURL
        )
    }

    public func episodes(from detail: AppleMediaServerDetail) -> [AppleStremioEpisode] {
        var results: [AppleStremioEpisode] = []
        for season in detail.seasons {
            if let eps = detail.episodesBySeason[season.id] {
                for ep in eps {
                    let thumbURL: URL? = {
                        if let tag = ep.primaryImageTag {
                            return try? client.imageURL(session: detail.session, itemID: ep.id, type: .primary, tag: tag, maxWidth: 600)
                        }
                        return nil
                    }()
                    
                    results.append(AppleStremioEpisode(
                        id: ep.id, // the raw item id for playbackRequest
                        title: ep.name,
                        season: ep.parentIndexNumber,
                        episode: ep.indexNumber,
                        releaseInfo: ep.year.map { String($0) },
                        runtimeMinutes: ep.runtimeSeconds.map { Int($0 / 60) },
                        overview: ep.overview,
                        thumbnailURL: thumbURL
                    ))
                }
            }
        }
        return results
    }
}
