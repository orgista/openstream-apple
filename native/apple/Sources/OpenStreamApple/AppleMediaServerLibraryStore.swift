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
        public let collectionType: AppleMediaServerLibrary.Kind?
        public let discoverySort: DiscoverySort?
        public let libraryName: String?
        public let totalItemCount: Int?

        public enum DiscoverySort: String, Codable, Sendable {
            case latest, top, other
            /// Rill's feed rows (`AppleOStreamFeed`).
            case top10, featured
        }

        public init(id: String, title: String, sourceID: UUID, items: [AppleCatalogItem],
                    collectionType: AppleMediaServerLibrary.Kind? = nil, discoverySort: DiscoverySort? = nil,
                    libraryName: String? = nil, totalItemCount: Int? = nil) {
            self.id = id
            self.title = title
            self.sourceID = sourceID
            self.items = items
            self.collectionType = collectionType
            self.discoverySort = discoverySort
            self.libraryName = libraryName
            self.totalItemCount = totalItemCount
        }
    }

    public private(set) var contentRevision: UInt64 = 0
    /// The rows on screen. During a `reload` they follow the working copy
    /// (`rows`) at most once per `publishInterval`, and only when something
    /// changed: one publish per answer redrew Discover and Library ~80 times
    /// per reload on the owner's Rill server (rows-1107).
    public private(set) var shelves: [Shelf] = [] { didSet { contentRevision &+= 1 } }
    /// The `shelves` whose first page is still on its way, published with them.
    private(set) var pendingShelfIDs: Set<String> = []
    @ObservationIgnored private var rows: [Shelf] = [] { didSet { rowsDidChange() } }
    @ObservationIgnored private var lastPublish: ContinuousClock.Instant?
    @ObservationIgnored private var scheduledPublish: Task<Void, Never>?
    nonisolated static let publishInterval: Duration = .seconds(1)
    public var serviceLibraries: [Shelf] { shelves.filter { $0.libraryName != nil } }
    public private(set) var continueWatching: [AppleCatalogItem] = [] { didSet { contentRevision &+= 1 } }
    public private(set) var isLoading = false
    public private(set) var failures: [UUID: String] = [:]
    public private(set) var lastLoadedAt: Date?
    /// When a `reload` last finished every source without a row error.
    @ObservationIgnored private var reloadedAt: Date?
    
    private var plexIndex: [AppleMediaServerItemReference: ApplePlexItem] = [:]
    private var index: [AppleMediaServerItemReference: AppleMediaServerItem] = [:]
    private var completedSeriesActivity: [String: Date] = [:]
    private var sourceIndex: [UUID: AppleSource] = [:]
    private var sourceOrder: [UUID] = []
    private var sessionIndex: [UUID: AppleMediaServerSession] = [:]
    /// Whether a `reload` has set the sessions up since launch. A title page
    /// opened by a cold deep link (the Apple TV Top Shelf) asks for its
    /// detail before that, and waits for it (`firstSessions`).
    @ObservationIgnored private var sessionsReady = false
    @ObservationIgnored private var sessionWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    @ObservationIgnored private weak var validationSourceStore: AppleSourceStore?
    
    private enum HubRequest: Sendable, Equatable, Codable {
        case plex(key: String, nextUp: Bool)
        case nextUp(parentID: String)
        case genre(parentID: String, name: String, type: AppleMediaServerItemType)
        case library(parentID: String)
        case plexLibrary(sectionKey: String, kind: ApplePlexKind)
        case feedRow(libraryID: String)
    }
    private struct HubState: Sendable, Equatable, Codable {
        let request: HubRequest
        var offset: Int
        var total: Int
        var exhausted = false
        var hasLoaded = true
        var refreshedAt = Date()
        var firstPageCount: Int? = nil
        var firstPageOffset: Int? = nil

        var isLibrary: Bool {
            switch request {
            case .library, .plexLibrary, .feedRow: true
            default: false
            }
        }
    }
    @ObservationIgnored private var hubStates: [String: HubState] = [:] { didSet { rowsDidChange() } }
    private var hubDefinitions: [String: Shelf] = [:]
    private var shelfOrder: [String] = []
    @ObservationIgnored private var loadingHubs: Set<String> = [] { didSet { rowsDidChange() } }
    private var hubRevisions: [String: UInt64] = [:]

    func isShelfPending(shelfID: String) -> Bool {
        loadingHubs.contains(shelfID) || hubStates[shelfID]?.hasLoaded == false
    }

    private func rowsDidChange() {
        guard isLoading, let last = lastPublish, ContinuousClock.now < last + Self.publishInterval else {
            publishRows()
            return
        }
        guard scheduledPublish == nil else { return }
        scheduledPublish = Task { [weak self] in
            try? await Task.sleep(until: last + Self.publishInterval, clock: .continuous)
            guard !Task.isCancelled else { return }
            self?.publishRows()
        }
    }

    private func publishRows() {
        scheduledPublish?.cancel()
        scheduledPublish = nil
        let pending = Set(rows.map(\.id).filter { isShelfPending(shelfID: $0) })
        guard shelves != rows || pendingShelfIDs != pending else { return }
        lastPublish = .now
        if shelves != rows { shelves = rows }
        if pendingShelfIDs != pending { pendingShelfIDs = pending }
    }

    nonisolated static func discoverySort(hubIdentifier: String) -> Shelf.DiscoverySort? {
        let parts = Set(hubIdentifier.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
        if !parts.isDisjoint(with: ["genre", "ondeck", "nextup", "collection"]) { return .other }
        if !parts.isDisjoint(with: ["recent", "recentlyadded", "latest", "newest"]) { return .latest }
        if !parts.isDisjoint(with: ["top", "toprated", "popular", "trending"]) { return .top }
        return nil
    }

    public func canLoadMore(shelfID: String) -> Bool {
        guard let state = hubStates[shelfID], let shelf = rows.first(where: { $0.id == shelfID }) else { return false }
        return !state.exhausted && state.offset < state.total && (state.isLibrary || shelf.items.count < AppleCatalogPaging.maximumItems)
    }

    public func loadMore(shelfID: String) async {
        guard canLoadMore(shelfID: shelfID) else { return }
        await updateHub(shelfID: shelfID, replacing: false)
    }

    public func refresh(shelfID: String) async {
        // Refresh wins over an older page request; the request revision prevents that page committing later.
        hubRevisions[shelfID, default: 0] &+= 1
        loadingHubs.remove(shelfID)
        await updateHub(shelfID: shelfID, replacing: true)
    }

    public func refreshIfNeeded(shelfID: String, now: Date = .now) async {
        guard let state = hubStates[shelfID], !state.hasLoaded || now.timeIntervalSince(state.refreshedAt) >= 60 else { return }
        // A feed row's first page is revalidated with the feed itself.
        if case .feedRow = state.request { return }
        await refresh(shelfID: shelfID)
    }

    /// A delivered terminal event can change its own rows and the server's next-episode hub.
    internal func refreshAffectedHubs(reference: AppleMediaServerItemReference) async {
        let episodic = index[reference]?.type == .episode || plexIndex[reference]?.type == .episode
        let affected = shelfOrder.compactMap { hubDefinitions[$0] }.filter { shelf in
            guard shelf.sourceID == reference.sourceID, let state = hubStates[shelf.id] else { return false }
            let isNextUp: Bool
            switch state.request {
            case .nextUp: isNextUp = episodic
            case .plex(_, let nextUp): isNextUp = episodic && nextUp
            case .genre, .library, .plexLibrary, .feedRow: isNextUp = false
            }
            return isNextUp || rows.first(where: { $0.id == shelf.id })?.items.contains { $0.mediaID == reference.mediaID } == true
        }.map(\.id)
        for id in affected { await refresh(shelfID: id) }
    }

    private func updateHub(shelfID: String, replacing: Bool) async {
        await AppleForegroundOpening.waitUntilQuiet()
        guard !loadingHubs.contains(shelfID), let state = hubStates[shelfID],
              let shelf = hubDefinitions[shelfID],
              let source = sourceIndex[shelf.sourceID], source.isEnabled,
              let session = sessionIndex[shelf.sourceID] else { return }
        let requestGeneration = generation
        let revision = hubRevisions[shelfID, default: 0]
        loadingHubs.insert(shelfID)
        defer { if generation == requestGeneration, hubRevisions[shelfID, default: 0] == revision { loadingHubs.remove(shelfID) } }
        let start = replacing ? 0 : state.offset
        appleTrace("server hub request \(replacing ? "refresh" : "page") start=\(start)")
        do {
            let items: [AppleCatalogItem]
            let rawCount: Int
            let total: Int
            let updatesContinueWatching: Bool
            var rawItems: [AppleMediaServerItem] = []
            var plexItems: [ApplePlexItem] = []
            switch state.request {
            case .plex(let key, let nextUp):
                updatesContinueWatching = nextUp
                let page = try await plexClient.hubItems(session: session, key: key, start: start, size: 20)
                plexItems = page.items
                rawCount = page.items.count
                total = page.totalSize
                items = page.items.filter { Self.isEligible($0) }.map { catalogItem($0, source: source, session: session) }
            case .nextUp(let parentID):
                updatesContinueWatching = true
                let page = try await client.nextUp(session: session, parentID: parentID, startIndex: start)
                rawItems = page.items
                rawCount = page.receivedCount
                total = page.totalRecordCount
                items = page.items.filter { Self.isEligible($0) }.map { catalogItem($0, source: source, session: session) }
            case .genre(let parentID, let name, let type):
                updatesContinueWatching = false
                let page = try await client.items(session: session, parentID: parentID, includeTypes: [type], startIndex: start, limit: 20, genres: [name])
                rawItems = page.items
                rawCount = page.receivedCount
                total = page.totalRecordCount
                items = page.items.filter { Self.isEligible($0) }.map { catalogItem($0, source: source, session: session) }
            case .library(let parentID):
                updatesContinueWatching = false
                let page = try await client.items(session: session, parentID: parentID,
                    includeTypes: [.movie, .series], startIndex: start, limit: Self.servicePageSize)
                rawItems = page.items
                rawCount = page.receivedCount
                total = page.totalRecordCount
                items = page.items.filter { Self.isEligible($0) }.map { catalogItem($0, source: source, session: session) }
            case .plexLibrary(let sectionKey, let kind):
                updatesContinueWatching = false
                let page = try await plexServicePage(session: session, key: sectionKey, kind: kind, start: start)
                plexItems = page.items
                rawCount = page.items.count
                total = page.totalSize
                items = page.items.filter { Self.isEligible($0) }.map { catalogItem($0, source: source, session: session) }
            case .feedRow(let libraryID):
                updatesContinueWatching = false
                let page = try await client.oStreamFeedRow(session: session, libraryID: libraryID, start: start)
                let cursor = AppleOStreamFeed.cursor(start: start, count: page.items.count, next: page.next)
                rawCount = cursor.offset - start
                total = cursor.total
                items = page.items.compactMap { feedItem($0, sourceID: source.id, baseURL: session.baseURL) }
            }
            guard !Task.isCancelled, generation == requestGeneration,
                  hubRevisions[shelfID, default: 0] == revision, hubStates[shelfID] != nil,
                  sessionIndex[shelf.sourceID] == session else { return }
            let position = rows.firstIndex(where: { $0.id == shelfID })
            let existing = position.map { rows[$0].items } ?? []
            hubStates[shelfID]?.hasLoaded = true
            // A successful empty refresh revokes the old row's eligibility. Other rows remain the fallback.
            if items.isEmpty && !state.isLibrary {
                if replacing {
                    if let position { rows.remove(at: position) }
                    hubStates[shelfID]?.offset = 0
                    hubStates[shelfID]?.total = total
                    hubStates[shelfID]?.exhausted = true
                    hubStates[shelfID]?.refreshedAt = Date()
                    if updatesContinueWatching { updateContinueWatchingFromNextUp(previous: existing, incoming: []) }
                    removeUnretainedItems(existing)
                    persist()
                } else {
                    hubStates[shelfID]?.exhausted = true
                    hubStates[shelfID]?.refreshedAt = Date()
                }
            } else {
                let keepsLibraryPages = replacing && state.isLibrary
                let merged = AppleCatalogPaging.merge(replacing ? [] : existing,
                    page: AppleCatalogPage(items: items, receivedCount: rawCount), pageSize: 1,
                    limit: state.isLibrary ? .max : AppleCatalogPaging.maximumItems)
                let ordered = keepsLibraryPages ? AppleStableRefresh.merge(existing, incoming: items + existing, id: \.id) : merged.items
                let reportedTotal: Int?
                if case .feedRow = state.request { reportedTotal = shelf.totalItemCount ?? total }
                else { reportedTotal = state.isLibrary ? total : shelf.totalItemCount }
                let updated = Shelf(id: shelf.id, title: shelf.title, sourceID: shelf.sourceID, items: ordered,
                    collectionType: shelf.collectionType, discoverySort: shelf.discoverySort,
                    libraryName: shelf.libraryName, totalItemCount: reportedTotal)
                if let position { rows[position] = updated }
                else {
                    let order = shelfOrder.firstIndex(of: shelfID) ?? shelfOrder.count
                    let insertion = rows.firstIndex { candidate in
                        (shelfOrder.firstIndex(of: candidate.id) ?? shelfOrder.count) > order
                    } ?? rows.endIndex
                    rows.insert(updated, at: insertion)
                }
                var nextState = state
                nextState.offset = keepsLibraryPages ? max(state.offset, rawCount) : start + rawCount
                nextState.total = total
                nextState.exhausted = (state.isLibrary ? (!keepsLibraryPages && rawCount == 0) : merged.isExhausted) || nextState.offset >= total
                nextState.hasLoaded = true
                nextState.refreshedAt = Date()
                if replacing && state.isLibrary {
                    nextState.firstPageCount = items.count
                    nextState.firstPageOffset = rawCount
                    hubDefinitions[shelfID] = Shelf(id: shelf.id, title: shelf.title, sourceID: shelf.sourceID, items: items,
                        collectionType: shelf.collectionType, discoverySort: shelf.discoverySort,
                        libraryName: shelf.libraryName, totalItemCount: total)
                }
                hubStates[shelfID] = nextState
                for item in rawItems { index[.init(sourceID: shelf.sourceID, itemID: item.id)] = item }
                for item in plexItems { plexIndex[.init(sourceID: shelf.sourceID, itemID: item.ratingKey)] = item }
                if updatesContinueWatching {
                    updateContinueWatchingFromNextUp(previous: replacing ? existing : [], incoming: items)
                }
                if replacing { removeUnretainedItems(existing) }
                persist()
            }
        } catch {
            if !Self.isCancellation(error), generation == requestGeneration, hubRevisions[shelfID, default: 0] == revision {
                appleTraceFailure("media server hub \(shelfID): row load failed (\(appleErrorLabel(error)))")
                if (error as? AppleMediaServerError) == .invalidCredentials {
                    recordConnectionFailure(source: source, error: error)
                }
                hubStates[shelfID]?.refreshedAt = Date()
                hubStates[shelfID]?.hasLoaded = true
            }
            return
        }
        recordConnectionSuccess(source: source)
        await persistNow()
    }

    /// `replacing` rebuilds the row from `incoming` alone.
    private func updateContinueWatchingFromNextUp(previous: [AppleCatalogItem], incoming: [AppleCatalogItem], replacing: Bool = false) {
        let store = ApplePlaybackStore()
        let previousIDs = Set(previous.map(\.mediaID))
        var retained = (replacing ? [] : continueWatching).filter {
            shouldIncludeInContinueWatching(mediaID: $0.mediaID, store: store)
                && (!previousIDs.contains($0.mediaID) || (Self.mergedResume(local: store.progress(for: $0.mediaID),
                    server: playbackState(for: $0.mediaID)?.data) ?? 0) > 0)
        }
        func parentID(_ item: AppleCatalogItem) -> String? {
            guard let reference = AppleMediaServerItemReference.parse(item.mediaID),
                  let parent = index[reference]?.seriesID ?? plexIndex[reference]?.grandparentRatingKey else { return nil }
            return AppleMediaServerItemReference(sourceID: reference.sourceID, itemID: parent).mediaID
        }
        var occupied = Set(retained.compactMap(parentID))
        var seen = Set(retained.map(\.mediaID))
        for item in incoming {
            guard shouldIncludeInContinueWatching(mediaID: item.mediaID, store: store),
                  seen.insert(item.mediaID).inserted else { continue }
            if let parent = parentID(item), !occupied.insert(parent).inserted { continue }
            retained.append(item)
        }
        if continueWatching != retained { continueWatching = retained }
    }

    nonisolated private static func isEligible(_ item: ApplePlexItem) -> Bool {
        [.movie, .show, .episode].contains(item.type) && !item.ratingKey.isEmpty && !item.title.isEmpty
    }
    nonisolated private static func isEligible(_ item: AppleMediaServerItem) -> Bool {
        [.movie, .series, .episode].contains(item.type) && !item.id.isEmpty && !item.name.isEmpty
    }

    private struct CachedDetail: Sendable {
        let detail: AppleMediaServerDetail
        let fetchedAt: Date
    }
    private var detailCache: [AppleMediaServerItemReference: CachedDetail] = [:]

    private struct CachedTitleMatches {
        let matches: [AppleMediaServerTitleMatch]
        let fetchedAt: Date
    }
    @ObservationIgnored private var titleMatchCache: [AppleMediaServerTitleQuery: CachedTitleMatches] = [:]
    
    public struct AppleMediaServerPlaybackTicket: Sendable {
        let session: AppleMediaServerSession
        let mediaSourceID: String
        let playSessionID: String?
        let playbackID = UUID()
    }

    private var activeTickets: [String: AppleMediaServerPlaybackTicket] = [:]
    /// Plays that already sent their stop. Bounded: only a recent player can repeat one.
    private var stoppedPlaybackIDs: [UUID] = []
    @ObservationIgnored private var verifiedVersionItems: Set<String> = []
    @ObservationIgnored private var preparedPlaybackInfo: (reference: AppleMediaServerItemReference,
        session: AppleMediaServerSession, info: AppleMediaServerPlaybackInfo, fetchedAt: ContinuousClock.Instant)?
    private static let preparedPlaybackInfoLifetime: Duration = .seconds(30)

    private let client: AppleMediaServerClient
    private let plexClient: ApplePlexClient
    private let feedCache: AppleOStreamFeedCache
    private let feedDefaults: UserDefaults
    /// Sources whose server answered 404 to the feed: not asked again this session.
    @ObservationIgnored private var feedOff: Set<UUID> = []
    /// Sources whose feed this session has asked for already.
    @ObservationIgnored private var feedChecked: Set<UUID> = []
    /// The server and user `feedOff` and `feedChecked` hold for; another one starts over.
    @ObservationIgnored private var feedAccounts: [UUID: String] = [:]
    /// "Use Rill's rows" as the last reload found it; a change reloads at once.
    @ObservationIgnored private var feedPreferenceAtReload: [UUID: Bool] = [:]
    @ObservationIgnored private var feedImages: [UUID: AppleOStreamFeed.Images] = [:]
    private var feedTitleCounts: [UUID: Int] = [:]
    /// Observed: the billboard picks up a trailer from a feed that lands after it is drawn.
    private var feedTrailers: [String: AppleOStreamFeed.Trailer] = [:]
    internal var automaticallyDeliversRemoteProgress = true
    private let outbox: AppleRemoteProgressOutbox
    private var deliveryTask: Task<Void, Never>?
    private var generation: Int = 0
    private let cacheFileURL: URL?
    @ObservationIgnored private var pendingPersist: Task<Void, Never>?
    @ObservationIgnored private var cacheWrite: Task<Void, Never>?
    
    public convenience init(client: AppleMediaServerClient = AppleMediaServerClient(), plexClient: ApplePlexClient = ApplePlexClient(), progressDefaults: UserDefaults = .standard,
                            cacheFileURL: URL? = nil) {
        self.init(client: client, plexClient: plexClient, progressDefaults: progressDefaults, cacheFileURL: cacheFileURL,
                  feedCache: AppleOStreamFeedCache())
    }

    init(client: AppleMediaServerClient, plexClient: ApplePlexClient = ApplePlexClient(), progressDefaults: UserDefaults = .standard,
         cacheFileURL: URL? = nil, feedCache: AppleOStreamFeedCache, feedDefaults: UserDefaults = .standard) {
        self.client = client
        self.plexClient = plexClient
        self.feedCache = feedCache
        self.feedDefaults = feedDefaults
        self.outbox = AppleRemoteProgressOutbox(defaults: progressDefaults)
        self.cacheFileURL = cacheFileURL
    }
    
    /// The servers' recently added movies and shows (Jellyfin and Emby
    /// "Latest", Plex "Recently added"), newest first per shelf, as index
    /// records: the Top Shelf's Recently Added row opens their pages.
    public func recentlyAddedRecords(verifiedAt: Date = .now) -> [AppleMediaRecord] {
        rows.filter { $0.id.hasSuffix(":latest") || $0.id.hasSuffix(":recent") }.flatMap { shelf in
            shelf.items.enumerated().map { offset, item in
                AppleMediaIngestion.catalogRecord(instanceID: shelf.sourceID, item: item,
                                                  verifiedAt: verifiedAt.addingTimeInterval(-Double(offset)))
            }
        }
    }

    func addedAt(for mediaID: String) -> Date? {
        guard let reference = AppleMediaServerItemReference.parse(mediaID) else { return nil }
        return index[reference]?.addedAt ?? plexIndex[reference]?.addedAt
    }

    private func removeUnretainedItems(_ items: [AppleCatalogItem]) {
        let retained = Set(rows.flatMap(\.items).map(\.mediaID) + continueWatching.map(\.mediaID))
        let store = ApplePlaybackStore()
        for item in items where !retained.contains(item.mediaID) {
            guard let reference = AppleMediaServerItemReference.parse(item.mediaID) else { continue }
            rememberCompletedSeriesActivity(reference, store: store)
            index.removeValue(forKey: reference)
            plexIndex.removeValue(forKey: reference)
            detailCache.removeValue(forKey: reference)
        }
    }

    func searchMatch(for record: AppleMediaRecord) -> AppleCatalogSearchMatch? {
        for route in record.availability {
            guard let itemID = route.serverItemID,
                  let source = sourceIndex[route.instanceID], source.isEnabled,
                  let session = sessionIndex[route.instanceID] else { continue }
            let reference = AppleMediaServerItemReference(sourceID: source.id, itemID: itemID)
            if let item = index[reference], Self.isEligible(item) {
                return .init(item: catalogItem(item, source: source, session: session), source: source)
            }
            if let item = plexIndex[reference], Self.isEligible(item) {
                return .init(item: catalogItem(item, source: source, session: session), source: source)
            }
        }
        return nil
    }

    private static let legacyReindexRetryInterval: TimeInterval = 24 * 60 * 60
    nonisolated private static let legacyReindexMaximumPages = 100

    func reindexedLegacyRecords(_ records: [AppleMediaRecord], now: Date = .now) async -> [AppleMediaRecord] {
        let routes = records.flatMap(\.availability).filter {
            $0.serverItemID == nil && sourceIndex[$0.instanceID] != nil
                && ($0.isStale != true || now.timeIntervalSince($0.lastVerified) >= Self.legacyReindexRetryInterval)
        }
        let sourceIDs = Set(routes.map(\.instanceID))
        guard !sourceIDs.isEmpty else { return [] }
        let requestGeneration = generation
        let client = self.client
        let plexClient = self.plexClient
        let updated = await withTaskGroup(of: [AppleMediaRecord].self) { group in
            for sourceID in sourceIDs {
                guard let source = sourceIndex[sourceID], source.isEnabled, failures[sourceID] == nil,
                      let session = sessionIndex[sourceID] else { continue }
                group.addTask {
                    let needed = Set(routes.filter { $0.instanceID == sourceID }.map(\.itemReference))
                    var replacements: [String: String] = [:]
                    var scannedItemCount = 0
                    var scannedPageCount = 0
                    var scanCompleted = true
                    func remember(_ itemID: String, type: String) {
                        let reference = AppleMediaServerItemReference(sourceID: sourceID, itemID: itemID)
                        let key = ApplePlaybackIdentity.digest(for: "\(type)|\(reference.mediaID)")
                        if needed.contains(key) { replacements[key] = itemID }
                    }
                    do {
                        if session.kind == .plex {
                            sections: for section in try await plexClient.sections(session: session)
                                where section.type == .movie || section.type == .show {
                                let kinds: [ApplePlexKind] = section.type == .show ? [.show, .episode] : [.movie]
                                for kind in kinds {
                                    var offset = 0
                                    while replacements.count < needed.count {
                                        try Task.checkCancellation()
                                        guard scannedPageCount < Self.legacyReindexMaximumPages else {
                                            scanCompleted = false
                                            break sections
                                        }
                                        let page = try await plexClient.items(session: session, sectionKey: section.key,
                                            kind: kind, start: offset, size: 100)
                                        scannedPageCount += 1
                                        for item in page.items where Self.isEligible(item) {
                                            remember(item.ratingKey, type: item.type == .movie ? "movie"
                                                : item.type == .episode ? "episode" : "series")
                                            // Older ingestion represented server episodes as series.
                                            if item.type == .episode { remember(item.ratingKey, type: "series") }
                                        }
                                        offset += page.items.count
                                        scannedItemCount += page.items.count
                                        if offset >= page.totalSize { break }
                                        if page.items.isEmpty { scanCompleted = false; break }
                                    }
                                }
                            }
                        } else {
                            var offset = 0
                            while replacements.count < needed.count {
                                try Task.checkCancellation()
                                guard scannedPageCount < Self.legacyReindexMaximumPages else {
                                    scanCompleted = false
                                    break
                                }
                                let page = try await client.items(session: session, parentID: nil,
                                    includeTypes: [.movie, .series, .episode], startIndex: offset)
                                scannedPageCount += 1
                                for item in page.items where Self.isEligible(item) {
                                    remember(item.id, type: item.type == .movie ? "movie"
                                        : item.type == .episode ? "episode" : "series")
                                    if item.type == .episode { remember(item.id, type: "series") }
                                }
                                offset += page.receivedCount
                                scannedItemCount += page.items.count
                                if offset >= page.totalRecordCount { break }
                                if page.receivedCount == 0 { scanCompleted = false; break }
                            }
                        }
                    } catch {
                        scanCompleted = false
                        appleTrace("legacy server index refresh failed: \(type(of: error))")
                    }
                    return records.compactMap { record in
                        var updated = record
                        for index in updated.availability.indices {
                            let route = updated.availability[index]
                            guard route.instanceID == sourceID, route.serverItemID == nil,
                                  needed.contains(route.itemReference) else { continue }
                            let itemID = replacements[route.itemReference]
                            guard itemID != nil || route.isStale == true || (scanCompleted && scannedItemCount > 0) else { continue }
                            updated.availability[index] = .init(reindexing: route, serverItemID: itemID, lastVerified: now)
                        }
                        guard updated != record else { return nil }
                        // The repository keeps watch state edited while the server scan was in flight.
                        updated.isFavorite = false
                        updated.progress = nil
                        return updated
                    }
                }
            }
            var collected: [AppleMediaRecord] = []
            for await records in group { collected += records }
            return collected
        }
        guard !Task.isCancelled, generation == requestGeneration else { return [] }
        return updated
    }

    public func plexItem(for reference: AppleMediaServerItemReference) -> ApplePlexItem? {
        plexIndex[reference]
    }
    
    public func item(for reference: AppleMediaServerItemReference) -> AppleMediaServerItem? {
        index[reference]
    }

    func titlePageDestination(for item: AppleCatalogItem) -> (item: AppleCatalogItem, episodeID: String?) {
        guard let reference = AppleMediaServerItemReference.parse(item.mediaID),
              let source = sourceIndex[reference.sourceID],
              let session = sessionIndex[reference.sourceID] else { return (item, nil) }
        if session.kind == .plex {
            guard let episode = plexIndex[reference], episode.type == .episode,
                  let seriesID = episode.grandparentRatingKey else { return (item, nil) }
            let parent = AppleMediaServerItemReference(sourceID: source.id, itemID: seriesID)
            let title = plexIndex[parent].map { catalogItem($0, source: source, session: session) }
                ?? AppleCatalogItem(mediaID: parent.mediaID, type: "series",
                    name: episode.grandparentTitle ?? item.name,
                    backgroundURL: catalogItem(episode, source: source, session: session).backgroundURL)
            return (title, episode.ratingKey)
        }
        guard let episode = index[reference], episode.type == .episode,
              let seriesID = episode.seriesID else { return (item, nil) }
        let parent = AppleMediaServerItemReference(sourceID: source.id, itemID: seriesID)
        var series = index[parent] ?? AppleMediaServerItem(id: seriesID, name: episode.seriesName ?? item.name,
            type: .series, primaryImageTag: episode.seriesPrimaryImageTag)
        if index[parent] == nil {
            series.parentBackdropItemID = episode.parentBackdropItemID
            series.parentBackdropImageTags = episode.parentBackdropImageTags
        }
        return (catalogItem(series, source: source, session: session), episode.id)
    }
    
    /// Keep the freshest local or server resume fraction on the shelf record.
    public func continueWatchingRecord(for catalogItem: AppleCatalogItem, source: AppleSource,
                                      store localStore: ApplePlaybackStore = ApplePlaybackStore()) -> AppleMediaRecord {
        var record = AppleMediaIngestion.catalogRecord(instanceID: source.id, item: catalogItem)
        let server = playbackState(for: catalogItem.mediaID)
        if !Self.prefersServer(server?.data, localUpdatedAt: localStore.localPlaybackUpdatedAt(mediaID: catalogItem.mediaID)) {
            record.progress = localStore.progress(for: catalogItem.mediaID).map { $0.duration > 0 ? min($0.position / $0.duration, 1) : 0 } ?? 0
            return record
        }
        guard let server, let data = server.data, !data.played,
              let duration = server.duration, duration.isFinite, duration > 0,
              data.positionSeconds.isFinite, data.positionSeconds > 0 else {
            record.progress = 0
            return record
        }
        record.progress = min(data.positionSeconds / duration, 1)
        return record
    }

    /// Match the same local/server freshness decision as the displayed resume fraction.
    func continueWatchingUpdatedAt(for mediaID: String, store: ApplePlaybackStore) -> Date? {
        let data = playbackState(for: mediaID)?.data
        let local = store.lastActivity(for: mediaID)?.updatedAt
        let date = Self.prefersServer(data, localUpdatedAt: store.localPlaybackUpdatedAt(mediaID: mediaID))
            ? data?.lastPlayedDate : local
        guard let reference = AppleMediaServerItemReference.parse(mediaID),
              let seriesID = index[reference]?.seriesID ?? plexIndex[reference]?.grandparentRatingKey else { return date }
        let parent = AppleMediaServerItemReference(sourceID: reference.sourceID, itemID: seriesID).mediaID
        var dates = [date, store.lastActivity(for: parent)?.updatedAt, completedSeriesActivity[parent]]
        if isNextUpEpisode(mediaID: mediaID, store: store) {
            // An unplayed successor inherits the activity that made its series eligible.
            dates.append(playbackState(for: parent)?.data?.lastPlayedDate)
            dates += index.compactMap { key, item in
                guard key.sourceID == reference.sourceID, item.seriesID == seriesID else { return nil }
                return completedActivityDate(for: key.mediaID, store: store)
            }
            dates += plexIndex.compactMap { key, item in
                guard key.sourceID == reference.sourceID, item.grandparentRatingKey == seriesID else { return nil }
                return completedActivityDate(for: key.mediaID, store: store)
            }
            return dates.compactMap { $0 }.max() ?? sourceIndex[reference.sourceID]?.lastValidatedAt ?? lastLoadedAt
        }
        return dates.compactMap { $0 }.max()
    }

    private func completedActivityDate(for mediaID: String, store: ApplePlaybackStore) -> Date? {
        let local = store.lastActivity(for: mediaID)
        let server = playbackState(for: mediaID)
        let finished = server?.data?.played == true || (server?.duration.map {
            AppleCompletionPolicy.isComplete(position: server?.data?.positionSeconds ?? 0, duration: $0)
        } ?? false)
        return [local?.isComplete == true ? local?.updatedAt : nil,
                finished ? server?.data?.lastPlayedDate : nil].compactMap { $0 }.max()
    }

    /// Pruning a finished episode must not erase its successor's recency.
    private func rememberCompletedSeriesActivity(_ reference: AppleMediaServerItemReference, store: ApplePlaybackStore) {
        guard let seriesID = index[reference]?.seriesID ?? plexIndex[reference]?.grandparentRatingKey,
              let date = completedActivityDate(for: reference.mediaID, store: store) else { return }
        let parent = AppleMediaServerItemReference(sourceID: reference.sourceID, itemID: seriesID).mediaID
        completedSeriesActivity[parent] = max(completedSeriesActivity[parent] ?? .distantPast, date)
    }

    private func isNextUpEpisode(mediaID: String, store: ApplePlaybackStore) -> Bool {
        guard let reference = AppleMediaServerItemReference.parse(mediaID),
              index[reference]?.type == .episode || plexIndex[reference]?.type == .episode else { return false }
        let server = playbackState(for: mediaID)?.data
        if !Self.prefersServer(server, localUpdatedAt: store.localPlaybackUpdatedAt(mediaID: mediaID)) {
            return false
        }
        if let server { return !server.played && server.positionSeconds == 0 }
        return rows.contains { shelf in
            guard shelf.items.contains(where: { $0.mediaID == mediaID }), let state = hubStates[shelf.id] else { return false }
            switch state.request {
            case .nextUp: return true
            case .plex(_, let nextUp): return nextUp
            case .genre, .library, .plexLibrary, .feedRow: return false
            }
        }
    }

    func continueWatchingInfo(for catalogItem: AppleCatalogItem, store: ApplePlaybackStore) -> AppleContinueWatchingTileInfo {
        let local = store.progress(for: catalogItem.mediaID)
        let server = playbackState(for: catalogItem.mediaID)
        let saved: ApplePlaybackProgress?
        if Self.prefersServer(server?.data, localUpdatedAt: store.localPlaybackUpdatedAt(mediaID: catalogItem.mediaID)),
           let data = server?.data, !data.played {
            saved = ApplePlaybackProgress(position: data.positionSeconds, duration: server?.duration ?? local?.duration ?? 0,
                                          updatedAt: data.lastPlayedDate ?? .distantPast)
        } else { saved = local }
        var episode: AppleMediaEpisode?
        var title: String?
        if let reference = AppleMediaServerItemReference.parse(catalogItem.mediaID),
           let session = sessionIndex[reference.sourceID] {
            if let item = index[reference], item.type == .episode {
                let still = item.primaryImageTag.flatMap {
                    try? client.imageURL(session: session, itemID: item.id, type: .primary,
                                         tag: $0, maxWidth: AppleArtworkSizePolicy.backdropMaximumWidth)
                }
                episode = AppleMediaEpisode(id: catalogItem.mediaID, title: item.name,
                    season: item.parentIndexNumber, episode: item.indexNumber, thumbnailURL: still)
                title = item.seriesName
            } else if let item = plexIndex[reference], item.type == .episode {
                let still = item.thumbPath.flatMap {
                    plexClient.imageURL(session: session, path: $0, width: 1280, height: 720)
                }
                episode = AppleMediaEpisode(id: catalogItem.mediaID, title: item.title,
                    season: item.parentIndex, episode: item.index, thumbnailURL: still)
                title = item.grandparentTitle
            }
        }
        var info = AppleContinueWatchingTileInfo.make(type: catalogItem.type, saved: saved,
            recordProgress: nil, episode: episode, isNext: isNextUpEpisode(mediaID: catalogItem.mediaID, store: store))
        info.title = title
        return info
    }

    private func playbackState(for mediaID: String) -> (data: AppleMediaServerItem.UserData?, duration: Double?)? {
        guard let reference = AppleMediaServerItemReference.parse(mediaID) else { return nil }
        if let plex = plexIndex[reference] {
            return (Self.playbackData(for: plex), plex.durationSeconds)
        }
        guard let item = index[reference] else { return nil }
        return (item.userData, item.runtimeSeconds)
    }

    private static func playbackData(for plex: ApplePlexItem) -> AppleMediaServerItem.UserData {
        .init(positionSeconds: plex.viewOffsetSeconds ?? 0, played: (plex.viewCount ?? 0) > 0,
              playCount: plex.viewCount ?? 0, lastPlayedDate: plex.lastViewedAt)
    }

    /// A newer server completion hides a stale local row without rewriting its saved state.
    public func shouldIncludeInContinueWatching(mediaID: String, store: ApplePlaybackStore) -> Bool {
        let server = playbackState(for: mediaID)
        if Self.prefersServer(server?.data, localUpdatedAt: store.localPlaybackUpdatedAt(mediaID: mediaID)) {
            guard let data = server?.data else { return true }
            if data.played { return false }
            if let duration = server?.duration,
               AppleCompletionPolicy.isComplete(position: data.positionSeconds, duration: duration) { return false }
            return true
        }
        return !store.isRemovedFromContinueWatching(mediaID: mediaID)
            && (!store.hasLocalPlaybackState(mediaID: mediaID) || store.progress(for: mediaID)?.resumePosition != nil)
    }

    public func source(for reference: AppleMediaServerItemReference) -> AppleSource? {
        sourceIndex[reference.sourceID]
    }
    
    public func clear(sourceID: UUID) {
        for shelf in hubDefinitions.values.filter({ $0.sourceID == sourceID }) {
            hubStates.removeValue(forKey: shelf.id)
            hubDefinitions.removeValue(forKey: shelf.id)
            shelfOrder.removeAll { $0 == shelf.id }
            hubRevisions[shelf.id, default: 0] &+= 1
            loadingHubs.remove(shelf.id)
        }
        rows.removeAll { $0.sourceID == sourceID }
        continueWatching.removeAll { AppleMediaServerItemReference.parse($0.mediaID)?.sourceID == sourceID }
        completedSeriesActivity = completedSeriesActivity.filter {
            AppleMediaServerItemReference.parse($0.key)?.sourceID != sourceID
        }
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
        sourceOrder.removeAll { $0 == sourceID }
        titleMatchCache.removeAll()
        sessionIndex.removeValue(forKey: sourceID)
        AppleServerTrailerStore.shared.update(sessions: sessionIndex)
        failures.removeValue(forKey: sourceID)
        if sessionIndex.isEmpty {
            deliveryTask?.cancel()
            deliveryTask = nil
        }
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
            year: item.year,
            imdbID: item.imdbID
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
        } else if let seriesID = item.seriesID, let seriesTag = item.seriesPrimaryImageTag {
            posterURL = try? client.imageURL(session: session, itemID: seriesID, type: .primary, tag: seriesTag, maxWidth: 600)
        } else {
            posterURL = nil
        }
        
        let backgroundURL: URL?
        if let backdropTag = item.backdropImageTags.first {
            backgroundURL = try? client.imageURL(session: session, itemID: item.id, type: .backdrop, tag: backdropTag, maxWidth: AppleArtworkSizePolicy.backdropMaximumWidth)
        } else if let parentID = item.parentBackdropItemID, let parentTag = item.parentBackdropImageTags.first {
            backgroundURL = try? client.imageURL(session: session, itemID: parentID, type: .backdrop, tag: parentTag, maxWidth: AppleArtworkSizePolicy.backdropMaximumWidth)
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
            year: item.year,
            logoURL: item.logoImageTag.flatMap {
                try? client.imageURL(session: session, itemID: item.id, type: .logo, tag: $0, maxWidth: 600)
            },
            imdbID: item.imdbID
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

    /// Returns once the first `reload` has set up the sessions, after
    /// `sessionWaitLimit` from this call, or when the caller is cancelled:
    /// a cold deep link can arrive before source startup, and with no server
    /// source no reload may ever come.
    func firstSessions(waitLimit: Duration = sessionWaitLimit) async {
        guard !sessionsReady else { return }
        let id = UUID()
        let deadline = Task { [weak self] in
            try? await Task.sleep(for: waitLimit)
            self?.sessionWaiters.removeValue(forKey: id)?.resume()
        }
        defer { deadline.cancel() }
        await withTaskCancellationHandler {
            await withCheckedContinuation { waiter in
                if sessionsReady || Task.isCancelled { waiter.resume() } else { sessionWaiters[id] = waiter }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.sessionWaiters.removeValue(forKey: id)?.resume() }
        }
    }

    static let sessionWaitLimit: Duration = .seconds(20)

    private func releaseSessionWaiters() {
        let waiters = sessionWaiters.values
        sessionWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    nonisolated static let maximumConcurrentLibraryRequestsPerSource = 2
    nonisolated static let maximumConcurrentLibraryRequests = 4
    nonisolated static let servicePageSize = 40
    nonisolated static let serviceDetectionPageLimit = 5
    nonisolated static let serviceArtworkPrefetchTarget = 12
    nonisolated private static let collectionsCacheLifetime: TimeInterval = 15 * 60

    private struct LibraryRequest: Sendable {
        enum Kind: Sendable {
            case libraries, resume, latest(AppleMediaServerLibrary), nextUp(AppleMediaServerLibrary)
            case plexSections, plexOnDeck, plexRecent(ApplePlexSection), plexHubs(ApplePlexSection)
            case library(AppleMediaServerLibrary), collections(AppleMediaServerLibrary?), plexLibrary(ApplePlexSection)
            case plexCollections(ApplePlexSection), plexCollection(ApplePlexItem)
        }
        let source: AppleSource
        let session: AppleMediaServerSession
        let sourceOrdinal: Int
        var libraryOrdinal = 0
        var collectionOrdinal = 0
        let kind: Kind

        var collectionsCacheKey: String? {
            let parent: String
            switch kind {
            case .collections(let library): parent = "collections:" + (library?.id ?? "all")
            case .plexCollections(let section): parent = "plexCollections:" + section.key
            default: return nil
            }
            return source.id.uuidString + ":" + parent
        }

        var label: String {
            switch kind {
            case .libraries, .plexSections: "libraries"
            case .resume, .plexOnDeck: "resume"
            case .latest, .plexRecent: "latest"
            case .nextUp: "next"
            case .plexHubs: "hubs"
            case .library, .plexLibrary, .plexCollection: "library"
            case .collections, .plexCollections: "collections"
            }
        }
    }

    private struct LibraryAnswer: Sendable {
        var libraries: [AppleMediaServerLibrary]? = nil
        var sections: [ApplePlexSection]? = nil
        var collections: [AppleMediaServerLibrary] = []
        var plexCollections: [ApplePlexItem] = []
        var shelves: [Shelf] = []
        var hubs: [String: HubState] = [:]
        var items: [AppleMediaServerItem] = []
        var plexItems: [ApplePlexItem] = []
        var continueWatching: [AppleCatalogItem]? = nil
    }

    private struct CachedCollections: Sendable {
        let answer: LibraryAnswer
        let fetchedAt: Date
    }
    private var collectionsCache: [String: CachedCollections] = [:]

    private func declareServiceLibrary(_ request: LibraryRequest) -> String? {
        let key: String
        let name: String
        let type: AppleMediaServerLibrary.Kind?
        let hub: HubRequest
        switch request.kind {
        case .library(let library):
            key = library.id
            name = library.name
            type = library.collectionType == .collections ? nil : library.collectionType
            hub = .library(parentID: library.id)
        case .plexLibrary(let section):
            key = section.key
            name = section.title
            type = section.type == .movie ? .movies : .tvshows
            hub = .plexLibrary(sectionKey: section.key, kind: section.type)
        case .plexCollection(let collection):
            key = "collection:" + collection.ratingKey
            name = collection.title
            type = nil
            hub = .plexLibrary(sectionKey: collection.ratingKey, kind: .collection)
        default: return nil
        }
        let id = "ms:\(request.source.id.uuidString.lowercased()):\(key):library"
        guard hubStates[id] == nil else { return id }
        let shelf = Shelf(id: id, title: AppleHomeRowLabel.baseName(name), sourceID: request.source.id, items: [],
            collectionType: type, discoverySort: .other, libraryName: name)
        hubDefinitions[id] = shelf
        hubStates[id] = HubState(request: hub, offset: 0, total: 0, hasLoaded: false)
        if !rows.contains(where: { $0.id == id }) { rows.append(shelf) }
        return id
    }

    private func firstPage(of shelf: Shelf, state: HubState) -> Shelf {
        Shelf(id: shelf.id, title: shelf.title, sourceID: shelf.sourceID,
            items: Array(shelf.items.prefix(state.firstPageCount ?? Self.servicePageSize)),
            collectionType: shelf.collectionType, discoverySort: shelf.discoverySort,
            libraryName: shelf.libraryName, totalItemCount: state.total)
    }

    nonisolated private func fetchLibrary(_ request: LibraryRequest) async throws -> LibraryAnswer {
        let source = request.source
        let session = request.session
        let prefix = "ms:\(source.id.uuidString.lowercased()):"
        var answer = LibraryAnswer()
        switch request.kind {
        case .libraries:
            answer.libraries = try await client.libraries(session: session).filter {
                $0.collectionType == .movies || $0.collectionType == .tvshows || $0.collectionType == .collections
            }
        case .plexSections:
            answer.sections = try await plexClient.sections(session: session).filter { $0.type == .movie || $0.type == .show }
        case .resume:
            answer.items = try await client.resume(session: session, limit: 20).items
            answer.continueWatching = answer.items.filter { item in
                Self.isEligible(item) && item.userData?.played != true
                    && !(item.runtimeSeconds.map { AppleCompletionPolicy.isComplete(
                        position: item.userData?.positionSeconds ?? 0, duration: $0) } ?? false)
            }.map { catalogItem($0, source: source, session: session) }
        case .plexOnDeck:
            answer.plexItems = try await plexClient.onDeck(session: session)
            answer.continueWatching = answer.plexItems.map { catalogItem($0, source: source, session: session) }
        case .latest(let library):
            answer.items = try await client.latest(session: session, parentID: library.id, limit: 20).filter { Self.isEligible($0) }
            let items = answer.items.map { catalogItem($0, source: source, session: session) }
            answer.shelves = [Shelf(id: prefix + library.id + ":latest", title: "Latest in \(library.name)",
                sourceID: source.id, items: items, collectionType: library.collectionType, discoverySort: .latest)]
            for genre in Self.genreShelves(items: items, sourceID: source.id, libraryID: library.id) {
                answer.shelves.append(Shelf(id: genre.id, title: genre.title, sourceID: source.id, items: [],
                    collectionType: library.collectionType, discoverySort: .other))
                answer.hubs[genre.id] = HubState(request: .genre(parentID: library.id, name: genre.title,
                    type: library.collectionType == .movies ? .movie : .series), offset: 0, total: 0, hasLoaded: false)
            }
        case .nextUp(let library):
            let page = try await client.nextUp(session: session, parentID: library.id)
            answer.items = page.items
            let id = prefix + library.id + ":nextup"
            answer.shelves = [Shelf(id: id, title: "Next up in \(library.name)", sourceID: source.id,
                items: page.items.filter { Self.isEligible($0) }.map { catalogItem($0, source: source, session: session) },
                collectionType: library.collectionType, discoverySort: .other)]
            answer.hubs[id] = HubState(request: .nextUp(parentID: library.id), offset: page.receivedCount, total: page.totalRecordCount)
            answer.continueWatching = page.items.filter { Self.isEligible($0) && $0.type == .episode && $0.userData?.played != true }
                .map { catalogItem($0, source: source, session: session) }
        case .plexRecent(let section):
            answer.plexItems = try await plexClient.recentlyAdded(session: session, sectionKey: section.key)
            answer.shelves = [Shelf(id: prefix + section.key + ":recent", title: "Recently added in \(section.title)",
                sourceID: source.id, items: answer.plexItems.map { catalogItem($0, source: source, session: session) },
                collectionType: section.type == .movie ? .movies : .tvshows, discoverySort: .latest)]
        case .collections(let library):
            answer.collections = try await client.collections(session: session, parentID: library?.id)
        case .library(let library):
            var offset = 0
            var total = 0
            var artworkIdentities = Set<String>()
            var pages = 0
            var firstPageCount = 0
            var firstPageOffset = 0
            repeat {
                try Task.checkCancellation()
                let page = try await client.items(session: session, parentID: library.id, includeTypes: [.movie, .series],
                    startIndex: offset, limit: Self.servicePageSize)
                let eligible = page.items.filter { Self.isEligible($0) }
                if pages == 0 { firstPageCount = eligible.count; firstPageOffset = page.receivedCount }
                pages += 1
                answer.items += eligible
                let artwork = eligible.map { catalogItem($0, source: source, session: session) }
                    .filter { $0.posterURL != nil || $0.backgroundURL != nil }
                artworkIdentities.formUnion(artwork.map { AppleRecommendationRowScorer.displayIdentity($0) })
                offset += page.receivedCount
                total = page.totalRecordCount
                if page.receivedCount == 0 { break }
            } while artworkIdentities.count < Self.serviceArtworkPrefetchTarget && offset < total && pages < Self.serviceDetectionPageLimit
            let id = prefix + library.id + ":library"
            answer.shelves = [Shelf(id: id, title: AppleHomeRowLabel.baseName(library.name), sourceID: source.id,
                items: answer.items.map { catalogItem($0, source: source, session: session) },
                collectionType: library.collectionType == .collections ? nil : library.collectionType, discoverySort: .other,
                libraryName: library.name, totalItemCount: total)]
            answer.hubs[id] = HubState(request: .library(parentID: library.id), offset: offset, total: total,
                firstPageCount: firstPageCount, firstPageOffset: firstPageOffset)
        case .plexLibrary(let section):
            return try await fetchPlexService(source: source, session: session, key: section.key, name: section.title, kind: section.type)
        case .plexCollection(let collection):
            return try await fetchPlexService(source: source, session: session, key: collection.ratingKey, name: collection.title, kind: .collection)
        case .plexCollections(let section):
            var offset = 0
            repeat {
                let page = try await plexClient.hubItems(session: session, key: "/library/sections/\(section.key)/collections",
                    start: offset, size: Self.servicePageSize)
                answer.plexCollections += page.items.filter { $0.type == .collection }
                offset += page.items.count
                if page.items.isEmpty || offset >= page.totalSize { break }
                try Task.checkCancellation()
            } while true
        case .plexHubs(let section):
            let hubs = try await plexClient.homeHubs(session: session, sectionKey: section.key)
            for hub in hubs where ["movie", "show", "episode"].contains(hub.type) && !hub.hubIdentifier.isEmpty {
                guard !hub.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !answer.shelves.contains(where: { $0.title.lowercased() == hub.title.lowercased() }) else { continue }
                let eligible = hub.items.filter { Self.isEligible($0) }
                answer.plexItems += eligible
                let id = prefix + section.key + ":hub:" + hub.hubIdentifier
                guard !answer.shelves.contains(where: { $0.id == id }) else { continue }
                answer.shelves.append(Shelf(id: id, title: hub.title, sourceID: source.id,
                    items: eligible.map { catalogItem($0, source: source, session: session) },
                    collectionType: section.type == .movie ? .movies : .tvshows,
                    discoverySort: Self.discoverySort(hubIdentifier: hub.hubIdentifier)))
                answer.hubs[id] = HubState(request: .plex(key: hub.key,
                    nextUp: hub.hubIdentifier.lowercased().contains("ondeck") || hub.hubIdentifier.lowercased().contains("nextup")),
                    offset: hub.items.count, total: hub.totalSize)
            }
        }
        return answer
    }

    nonisolated private func plexServicePage(session: AppleMediaServerSession, key: String, kind: ApplePlexKind, start: Int) async throws -> ApplePlexPage {
        if kind == .collection {
            return try await plexClient.hubItems(session: session, key: "/library/metadata/\(key)/children", start: start, size: Self.servicePageSize)
        }
        return try await plexClient.items(session: session, sectionKey: key, kind: kind, start: start, size: Self.servicePageSize)
    }

    nonisolated private func fetchPlexService(source: AppleSource, session: AppleMediaServerSession,
                                             key: String, name: String, kind: ApplePlexKind) async throws -> LibraryAnswer {
        var answer = LibraryAnswer()
        var offset = 0
        var total = 0
        var artworkIdentities = Set<String>()
        var pages = 0
        var firstPageCount = 0
        var firstPageOffset = 0
        repeat {
            try Task.checkCancellation()
            let page = try await plexServicePage(session: session, key: key, kind: kind, start: offset)
            let eligible = page.items.filter { Self.isEligible($0) }
            if pages == 0 { firstPageCount = eligible.count; firstPageOffset = page.items.count }
            pages += 1
            answer.plexItems += eligible
            let artwork = eligible.map { catalogItem($0, source: source, session: session) }
                .filter { $0.posterURL != nil || $0.backgroundURL != nil }
            artworkIdentities.formUnion(artwork.map { AppleRecommendationRowScorer.displayIdentity($0) })
            offset += page.items.count
            total = page.totalSize
            if page.items.isEmpty { break }
        } while artworkIdentities.count < Self.serviceArtworkPrefetchTarget && offset < total && pages < Self.serviceDetectionPageLimit
        let prefix = "ms:\(source.id.uuidString.lowercased()):"
        let id = prefix + (kind == .collection ? "collection:" : "") + key + ":library"
        let type: AppleMediaServerLibrary.Kind? = kind == .collection ? nil : (kind == .movie ? .movies : .tvshows)
        answer.shelves = [Shelf(id: id, title: AppleHomeRowLabel.baseName(name), sourceID: source.id,
            items: answer.plexItems.map { catalogItem($0, source: source, session: session) },
            collectionType: type, discoverySort: .other, libraryName: name, totalItemCount: total)]
        answer.hubs[id] = HubState(request: .plexLibrary(sectionKey: key, kind: kind), offset: offset, total: total,
            firstPageCount: firstPageCount, firstPageOffset: firstPageOffset)
        return answer
    }

    /// Next Up across every library: the feed replaces the library list the
    /// per-library calls hang from (Rill answers them all with this one).
    nonisolated static let allShows = AppleMediaServerLibrary(id: "", name: "Shows", collectionType: .tvshows)

    private func feedItem(_ item: AppleOStreamFeed.Item, sourceID: UUID, baseURL: URL) -> AppleCatalogItem? {
        AppleOStreamFeed.catalogItem(item, images: feedImages[sourceID] ?? .v1, sourceID: sourceID, baseURL: baseURL)
    }

    /// The feed's YouTube trailer for a title from its rows.
    func feedTrailerKey(for mediaID: String) -> String? {
        feedTrailers[mediaID]?.youtube
    }

    private struct PreparedFeed: Sendable {
        let feed: AppleOStreamFeed
        let entries: [(row: AppleOStreamFeed.Row, shelf: Shelf)]
        let trailers: [String: AppleOStreamFeed.Trailer]
        let notModified: Bool

        init(_ feed: AppleOStreamFeed, sourceID: UUID, baseURL: URL, notModified: Bool) {
            self.feed = feed
            self.notModified = notModified
            entries = feed.shelves(sourceID: sourceID, baseURL: baseURL)
            trailers = feed.trailers(sourceID: sourceID)
        }
    }

    /// The feed as the server has it now: a 200, or the kept copy on a 304,
    /// made into shelves off the main actor. A 503, a failure or a timeout
    /// also keeps the kept copy, so a blip doesn't swap the rows. Nil on 404
    /// (not asked again this session) or with no kept copy: the store then
    /// builds the rows itself, as without the feed.
    private func loadFeed(source: AppleSource, session: AppleMediaServerSession) async -> PreparedFeed? {
        let cache = feedCache
        let sourceID = source.id
        let userID = session.userID
        let baseURL = session.baseURL
        let started = ContinuousClock.now
        var kept = await Task.detached(priority: .userInitiated) { cache.entry(sourceID: sourceID, userID: userID) }.value
        func keptFeed() async -> PreparedFeed? {
            guard let body = kept?.body else { return nil }
            return await Task.detached(priority: .userInitiated) {
                (try? JSONDecoder().decode(AppleOStreamFeed.self, from: body)).map {
                    PreparedFeed($0, sourceID: sourceID, baseURL: baseURL, notModified: true)
                }
            }.value
        }
        while true {
            let answer: AppleMediaServerClient.OStreamFeedAnswer
            do { answer = try await client.oStreamFeed(session: session, etag: kept?.etag) }
            catch {
                appleTrace("server feed failed (\(appleErrorLabel(error))), kept copy=\(kept != nil)")
                return await keptFeed()
            }
            let elapsed = AppleLaunchMarks.milliseconds(started.duration(to: .now))
            switch answer {
            case .feed(let feed, let body, let etag):
                appleTrace("server feed 200 rows=\(feed.rows.count) bytes=\(body.count) ms=\(elapsed)")
                AppleOStreamFeedPreference.recordAnswered(sourceID, defaults: feedDefaults)
                return await Task.detached(priority: .userInitiated) {
                    if let etag { cache.save(.init(userID: userID, etag: etag, body: body), sourceID: sourceID) }
                    else { cache.remove(sourceID: sourceID) }
                    return PreparedFeed(feed, sourceID: sourceID, baseURL: baseURL, notModified: false)
                }.value
            case .notModified:
                guard let prepared = await keptFeed() else {
                    // A copy this build can't read (an older schema): drop it and ask once without the ETag.
                    appleTrace("server feed 304 but the kept copy is unreadable; asking again")
                    await Task.detached(priority: .userInitiated) { cache.remove(sourceID: sourceID) }.value
                    kept = nil
                    continue
                }
                appleTrace("server feed 304 rows=\(prepared.feed.rows.count) ms=\(elapsed)")
                AppleOStreamFeedPreference.recordAnswered(sourceID, defaults: feedDefaults)
                return prepared
            case .off:
                appleTrace("server feed off (404) ms=\(elapsed)")
                feedOff.insert(sourceID)
                if !AppleOStreamFeedPreference.hasAnswered(sourceID, defaults: feedDefaults) {
                    AppleOStreamFeedPreference.recordMissing(sourceID, baseURL: baseURL, defaults: feedDefaults)
                }
                removeFeedShelves(sourceID: sourceID)
                return nil
            case .unavailable:
                appleTrace("server feed unavailable ms=\(elapsed), kept copy=\(kept != nil)")
                return await keptFeed()
            }
        }
    }

    /// Puts the feed's rows in place of the source's own and returns their ids in feed order.
    private func applyFeed(_ prepared: PreparedFeed, source: AppleSource) -> [String] {
        let entries = prepared.entries
        let ids = Set(entries.map(\.shelf.id))
        let kept = { (shelf: Shelf) in shelf.sourceID != source.id || ids.contains(shelf.id) || shelf.id.hasSuffix(":nextup") }
        let stale = rows.filter { !kept($0) }
        rows.removeAll { !kept($0) }
        for id in hubDefinitions.values.filter({ !kept($0) }).map(\.id) + stale.map(\.id) {
            hubStates[id] = nil
            hubDefinitions[id] = nil
        }
        feedImages[source.id] = prepared.feed.images
        feedTitleCounts[source.id] = prepared.feed.titleCount
        for (row, shelf) in entries {
            // A row already showing this first page keeps the pages loaded after it.
            if let position = rows.firstIndex(where: { $0.id == shelf.id }),
               hubStates[shelf.id] != nil || row.libraryId == nil,
               rows[position].items.starts(with: shelf.items) {
                if rows[position].title != shelf.title || rows[position].collectionType != shelf.collectionType
                    || rows[position].discoverySort != shelf.discoverySort || rows[position].libraryName != shelf.libraryName
                    || rows[position].totalItemCount != shelf.totalItemCount {
                    rows[position] = Shelf(id: shelf.id, title: shelf.title, sourceID: shelf.sourceID,
                        items: rows[position].items, collectionType: shelf.collectionType,
                        discoverySort: shelf.discoverySort, libraryName: shelf.libraryName, totalItemCount: shelf.totalItemCount)
                    if row.libraryId != nil { hubDefinitions[shelf.id] = shelf }
                }
                continue
            }
            if let libraryID = row.libraryId {
                let cursor = AppleOStreamFeed.cursor(start: 0, count: row.items.count, next: row.next)
                hubStates[shelf.id] = HubState(request: .feedRow(libraryID: libraryID), offset: cursor.offset, total: cursor.total,
                    exhausted: row.next == nil, firstPageCount: shelf.items.count, firstPageOffset: cursor.offset)
                hubDefinitions[shelf.id] = shelf
            }
            if let position = rows.firstIndex(where: { $0.id == shelf.id }) { rows[position] = shelf } else { rows.append(shelf) }
        }
        setFeedTrailers(prepared.trailers, sourceID: source.id)
        return entries.map(\.shelf.id)
    }

    private func setFeedTrailers(_ trailers: [String: AppleOStreamFeed.Trailer], sourceID: UUID) {
        let merged = feedTrailers.filter { AppleMediaServerItemReference.parse($0.key)?.sourceID != sourceID }
            .merging(trailers) { _, new in new }
        guard merged != feedTrailers else { return }
        feedTrailers = merged
        AppleServerTrailerStore.shared.update(feedTrailers: AppleOStreamFeed.directLinks(merged))
    }

    private func removeFeedShelves(sourceID: UUID) {
        feedTitleCounts[sourceID] = nil
        let isFeed = { (shelf: Shelf) in shelf.sourceID == sourceID && shelf.id.hasSuffix(":feed") }
        guard rows.contains(where: isFeed) || hubDefinitions.values.contains(where: isFeed) else { return }
        rows.removeAll(where: isFeed)
        for id in hubDefinitions.values.filter(isFeed).map(\.id) {
            hubStates[id] = nil
            hubDefinitions[id] = nil
        }
        setFeedTrailers([:], sourceID: sourceID)
        persist()
    }

    func refreshSourcesIfReady(sources: [AppleSource], sourceStore: AppleSourceStore) async {
        guard sessionsReady, !isLoading else { return }
        await reload(sources: sources, sourceStore: sourceStore, unlessReloadedWithin: Self.rowsFreshness) {
            try sourceStore.mediaServerSession(for: $0)
        }
    }

    /// How long a complete reload stands in for the next launch's or
    /// Discover's (owner's Rill, rows-1107: ~80 requests per reload, one
    /// per return to Discover). A shown row with a cursor still refreshes
    /// itself after 60 s (`refreshIfNeeded`); the 600 s matches the NAS rescan.
    nonisolated static let rowsFreshness: TimeInterval = 600

    /// `unlessReloadedWithin` keeps the rows (cached or loaded) when the same
    /// sources finished a complete reload that recently; the sessions are
    /// still set up.
    public func reload(sources: [AppleSource], sourceStore: AppleSourceStore? = nil, unlessReloadedWithin freshness: TimeInterval? = nil,
                       session: @MainActor @Sendable (AppleSource) throws -> AppleMediaServerSession?) async {
        generation += 1
        loadingHubs.removeAll()
        let currentGeneration = generation
        isLoading = true
        if let sourceStore { validationSourceStore = sourceStore }
        defer {
            if generation == currentGeneration {
                isLoading = false
                publishRows()
            }
        }
        var validSources: [(source: AppleSource, session: AppleMediaServerSession)] = []
        for source in sources where source.kind == .mediaServer && source.isEnabled {
            do {
                guard let value = try session(source) else { throw AppleMediaServerError.invalidCredentials }
                validSources.append((source, value))
            } catch {
                if !Self.isCancellation(error) { recordConnectionFailure(source: source, error: error) }
            }
        }
        let newSessions = Dictionary(uniqueKeysWithValues: validSources.map { ($0.source.id, $0.session) })
        let newOrder = validSources.map { $0.source.id }
        let unchangedSources = Set(validSources.filter {
            sessionIndex[$0.source.id] == $0.session
                && sourceIndex[$0.source.id]?.configurationRevision == $0.source.configurationRevision
        }.map { $0.source.id })
        collectionsCache = collectionsCache.filter { entry in
            unchangedSources.contains { entry.key.hasPrefix($0.uuidString + ":") }
        }
        if newSessions != sessionIndex || newOrder != sourceOrder || validSources.contains(where: {
            sourceIndex[$0.source.id]?.configurationRevision != $0.source.configurationRevision
        }) { titleMatchCache.removeAll() }
        sourceIndex = Dictionary(uniqueKeysWithValues: validSources.map { ($0.source.id, $0.source) })
        feedTitleCounts = feedTitleCounts.filter { unchangedSources.contains($0.key) }
        sessionIndex = newSessions
        sourceOrder = newOrder
        sessionsReady = true
        releaseSessionWaiters()
        AppleServerTrailerStore.shared.update(sessions: sessionIndex)
        outbox.retainSources(Set(sources.map(\.id)))
        if sessionIndex.isEmpty { deliveryTask?.cancel(); deliveryTask = nil }
        else { scheduleRemoteDelivery() }
        let enabled = Set(sources.filter { $0.kind == .mediaServer && $0.isEnabled }.map(\.id))
        Task.detached(priority: .utility) { [feedCache] in feedCache.retain(sourceIDs: enabled) }
        let retained = rows.filter {
            enabled.contains($0.sourceID) && ($0.libraryName == nil || unchangedSources.contains($0.sourceID))
        }
        if retained != rows { rows = retained }
        let changedLibraryIDs = hubStates.keys.filter { hubStates[$0]?.isLibrary == true
            && hubDefinitions[$0].map { !unchangedSources.contains($0.sourceID) } == true }
        for id in changedLibraryIDs { hubStates[id] = nil; hubDefinitions[id] = nil }
        let enabledWatching = continueWatching.filter { AppleMediaServerItemReference.parse($0.mediaID).map { enabled.contains($0.sourceID) } == true }
        if enabledWatching != continueWatching { continueWatching = enabledWatching }
        let feedPreferenceUnchanged = validSources.allSatisfy { pair in
            feedPreferenceAtReload[pair.source.id].map { $0 == AppleOStreamFeedPreference.isOn(pair.source.id, defaults: feedDefaults) } ?? true
        }
        var freshAge: Int?
        if let freshness, let reloadedAt, !validSources.isEmpty, unchangedSources.count == validSources.count,
           feedPreferenceUnchanged, validSources.allSatisfy({ failures[$0.source.id] == nil }) {
            let age = Date().timeIntervalSince(reloadedAt)
            if age >= 0, age < freshness { freshAge = Int(age) }
        }
        // Fresh rows from a server that has sent the feed still revalidate it
        // once per session: a 304 keeps them; a changed or withdrawn feed reloads.
        var feeds: [UUID: PreparedFeed] = [:]
        var feedChanged = false
        var asked: [(source: AppleSource, session: AppleMediaServerSession, hasFeedRows: Bool)] = []
        for pair in validSources {
            let id = pair.source.id
            let account = pair.session.baseURL.absoluteString + " " + pair.session.userID
            if feedAccounts[id] != account {
                feedAccounts[id] = account
                feedOff.remove(id)
                feedChecked.remove(id)
            }
            let wanted = AppleOStreamFeedPreference.isOn(id, defaults: feedDefaults)
            let answered = AppleOStreamFeedPreference.hasAnswered(id, defaults: feedDefaults)
            feedPreferenceAtReload[id] = wanted
            if !wanted { removeFeedShelves(sourceID: id) }
            guard wanted, pair.session.kind == .jellyfin, !feedOff.contains(id),
                  // A pull to refresh asks a server remembered without the feed anyway: its setting may be on now.
                  freshness == nil || answered
                    || !AppleOStreamFeedPreference.isMissing(id, baseURL: pair.session.baseURL, defaults: feedDefaults),
                  freshAge == nil || (answered && !feedChecked.contains(id))
            else { continue }
            asked.append((pair.source, pair.session, rows.contains { $0.sourceID == id && $0.id.hasSuffix(":feed") }))
        }
        if !asked.isEmpty {
            await AppleForegroundOpening.waitUntilQuiet()
            // Every source's feed at once: one slow server doesn't hold up another's.
            let answers = await withTaskGroup(of: (UUID, PreparedFeed?).self) { group in
                for pair in asked {
                    group.addTask { (pair.source.id, await self.loadFeed(source: pair.source, session: pair.session)) }
                }
                var answers: [UUID: PreparedFeed] = [:]
                for await (id, prepared) in group { answers[id] = prepared }
                return answers
            }
            guard currentGeneration == generation, !Task.isCancelled else { return }
            for pair in asked {
                let prepared = answers[pair.source.id]
                feedChecked.insert(pair.source.id)
                feeds[pair.source.id] = prepared
                if prepared.map({ !$0.notModified || !pair.hasFeedRows }) ?? pair.hasFeedRows { feedChanged = true }
            }
        }
        if let freshAge, !feedChanged {
            for pair in validSources {
                if let prepared = feeds[pair.source.id] { _ = applyFeed(prepared, source: pair.source) }
            }
            appleTrace("server rows reload skipped: rows are \(freshAge) s old")
            return
        }
        // With the feed, the server's own calls are only Continue Watching's.
        var requests = validSources.enumerated().map { ordinal, pair in
            feeds[pair.source.id].map {
                LibraryRequest(source: pair.source, session: pair.session, sourceOrdinal: ordinal,
                    libraryOrdinal: $0.entries.count, kind: .nextUp(Self.allShows))
            } ?? LibraryRequest(source: pair.source, session: pair.session, sourceOrdinal: ordinal,
                kind: pair.session.kind == .plex ? .plexSections : .libraries)
        }
        requests += validSources.enumerated().map { ordinal, pair in
            LibraryRequest(source: pair.source, session: pair.session, sourceOrdinal: ordinal,
                kind: pair.session.kind == .plex ? .plexOnDeck : .resume)
        }
        var answered = Set<UUID>()
        var rejected = Set<UUID>()
        var rowErrors: [UUID: any Error] = [:]
        var structuralFailures = Set<UUID>()
        var discovered = Set<UUID>()
        var receivedReferences = Set<AppleMediaServerItemReference>()
        var refreshedShelfIDs: [UUID: Set<String>] = [:]
        var watching: [UUID: [Int: [AppleCatalogItem]]] = [:]
        var shelfRanks: [String: (source: Int, library: Int, collection: Int, phase: Int, row: Int)] = [:]
        let previousOrder = shelfOrder
        func orderShelves() {
            let freshOrder = shelfRanks.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value < $1.value }.map(\.key)
            let definitions = Dictionary((rows + Array(hubDefinitions.values)).map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first })
            let ordered = sources.flatMap { source in
                freshOrder.filter { definitions[$0]?.sourceID == source.id }
                    + previousOrder.filter { shelfRanks[$0] == nil && definitions[$0]?.sourceID == source.id }
            }
            var titles: [UUID: Set<String>] = [:]
            for shelf in definitions.values {
                if let hub = hubStates[shelf.id] {
                    switch hub.request {
                    case .genre, .plex, .library, .plexLibrary, .feedRow: continue
                    case .nextUp: break
                    }
                }
                titles[shelf.sourceID, default: []].insert(shelf.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            }
            let accepted = ordered.filter { id in
                guard let shelf = definitions[id], let hub = hubStates[id] else { return true }
                switch hub.request {
                case .nextUp, .library, .plexLibrary, .feedRow: return true
                case .genre, .plex:
                    return titles[shelf.sourceID, default: []].insert(
                        shelf.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()).inserted
                }
            }
            let duplicates = Set(ordered).subtracting(accepted)
            rows.removeAll { duplicates.contains($0.id) }
            shelfOrder = accepted
            let positions = Dictionary(uniqueKeysWithValues: shelfOrder.enumerated().map { ($0.element, $0.offset) })
            rows.sort { positions[$0.id, default: .max] < positions[$1.id, default: .max] }
        }
        let previousWatching = continueWatching
        let previousShelfItems = rows.flatMap(\.items)
        for (ordinal, pair) in validSources.enumerated() {
            guard let feed = feeds[pair.source.id] else { continue }
            discovered.insert(pair.source.id)
            for (position, id) in applyFeed(feed, source: pair.source).enumerated() {
                refreshedShelfIDs[pair.source.id, default: []].insert(id)
                shelfRanks[id] = (ordinal, position, 0, 0, 0)
            }
        }
        if !feeds.isEmpty {
            orderShelves()
            lastLoadedAt = Date()
            persist()
        }
        await withTaskGroup(of: (LibraryRequest, Result<LibraryAnswer, any Error>).self) { group in
            var active: [UUID: Int] = [:]
            while !requests.isEmpty || active.values.contains(where: { $0 > 0 }) {
                if AppleForegroundOpening.isOpening, !requests.isEmpty {
                    let paused = ContinuousClock.now
                    await AppleForegroundOpening.waitUntilQuiet()
                    appleTrace("server rows paused for an opening ms=\(AppleLaunchMarks.milliseconds(paused.duration(to: .now)))")
                }
                while !Task.isCancelled, active.values.reduce(0, +) < Self.maximumConcurrentLibraryRequests,
                      let position = requests.firstIndex(where: {
                    !rejected.contains($0.source.id) && active[$0.source.id, default: 0] < Self.maximumConcurrentLibraryRequestsPerSource
                }) {
                    let request = requests.remove(at: position)
                    let cached = request.collectionsCacheKey.flatMap { collectionsCache[$0] }
                    active[request.source.id, default: 0] += 1
                    group.addTask {
                        let started = ContinuousClock.now
                        let tag = "source=\(request.sourceOrdinal) library=\(request.libraryOrdinal) kind=\(request.label)"
                        appleTrace("server rows request start \(tag)")
                        let result: Result<LibraryAnswer, any Error>
                        do {
                            if let cached, Date().timeIntervalSince(cached.fetchedAt) < Self.collectionsCacheLifetime {
                                result = .success(cached.answer)
                            } else {
                                result = .success(try await self.fetchLibrary(request))
                            }
                        }
                        catch { result = .failure(error) }
                        let success = (try? result.get()) != nil
                        appleTrace("server rows request finish \(tag) ok=\(success) ms=\(AppleLaunchMarks.milliseconds(started.duration(to: .now)))")
                        return (request, result)
                    }
                }
                guard let (request, fetched) = await group.next() else { break }
                active[request.source.id, default: 0] -= 1
                guard currentGeneration == generation, !Task.isCancelled else { group.cancelAll(); return }
                let source = request.source
                guard !rejected.contains(source.id) else { continue }
                var result = fetched
                if let key = request.collectionsCacheKey {
                    switch result {
                    case .success(let answer):
                        if collectionsCache[key].map({ Date().timeIntervalSince($0.fetchedAt) >= Self.collectionsCacheLifetime }) ?? true {
                            collectionsCache[key] = CachedCollections(answer: answer, fetchedAt: Date())
                        }
                    case .failure(let error):
                        guard !Self.isCancellation(error) else { continue }
                        appleTraceFailure("media server collections: optional discovery failed (\(appleErrorLabel(error)))")
                        let answer = collectionsCache[key]?.answer ?? LibraryAnswer()
                        collectionsCache[key] = CachedCollections(answer: answer, fetchedAt: Date())
                        result = .success(answer)
                    }
                }
                switch result {
                case .failure(let error):
                    guard !Self.isCancellation(error) else { continue }
                    rowErrors[source.id] = error
                    switch request.kind {
                    case .libraries, .plexSections: structuralFailures.insert(source.id)
                    default: break
                    }
                    if (error as? AppleMediaServerError) == .invalidCredentials {
                        rejected.insert(source.id)
                        recordConnectionFailure(source: source, error: error)
                    }
                case .success(let answer):
                    if answer.libraries == nil, answer.sections == nil, request.collectionsCacheKey == nil { answered.insert(source.id) }
                    var following: [LibraryRequest] = []
                    if let libraries = answer.libraries {
                        discovered.insert(source.id)
                        for (ordinal, library) in libraries.enumerated() {
                            if library.collectionType != .collections {
                                following.append(LibraryRequest(source: source, session: request.session,
                                    sourceOrdinal: request.sourceOrdinal, libraryOrdinal: ordinal, kind: .latest(library)))
                            }
                            if AppleHomeServices.service(in: library.name) != nil {
                                following.append(LibraryRequest(source: source, session: request.session,
                                    sourceOrdinal: request.sourceOrdinal, libraryOrdinal: ordinal, kind: .library(library)))
                            } else if library.collectionType == .collections {
                                following.append(LibraryRequest(source: source, session: request.session,
                                    sourceOrdinal: request.sourceOrdinal, libraryOrdinal: ordinal, kind: .collections(library)))
                            }
                        }
                        if !libraries.contains(where: { $0.collectionType == .collections }),
                           libraries.contains(where: { AppleHomeServices.service(in: $0.name) == nil }) {
                            following.append(LibraryRequest(source: source, session: request.session,
                                sourceOrdinal: request.sourceOrdinal, libraryOrdinal: libraries.count, kind: .collections(nil)))
                        }
                        for (ordinal, library) in libraries.enumerated() where library.collectionType == .tvshows {
                            following.append(LibraryRequest(source: source, session: request.session,
                                sourceOrdinal: request.sourceOrdinal, libraryOrdinal: ordinal, kind: .nextUp(library)))
                        }
                    }
                    for (ordinal, collection) in answer.collections.enumerated()
                        where AppleHomeServices.service(in: collection.name) != nil {
                        following.append(LibraryRequest(source: source, session: request.session,
                            sourceOrdinal: request.sourceOrdinal, libraryOrdinal: request.libraryOrdinal, collectionOrdinal: ordinal + 1,
                            kind: .library(collection)))
                    }
                    for (ordinal, collection) in answer.plexCollections.enumerated()
                        where AppleHomeServices.service(in: collection.title) != nil {
                        following.append(LibraryRequest(source: source, session: request.session,
                            sourceOrdinal: request.sourceOrdinal, libraryOrdinal: request.libraryOrdinal, collectionOrdinal: ordinal + 1,
                            kind: .plexCollection(collection)))
                    }
                    if let sections = answer.sections {
                        discovered.insert(source.id)
                        for (ordinal, section) in sections.enumerated() {
                            following.append(LibraryRequest(source: source, session: request.session,
                                sourceOrdinal: request.sourceOrdinal, libraryOrdinal: ordinal, kind: .plexRecent(section)))
                        }
                        for (ordinal, section) in sections.enumerated() {
                            following.append(LibraryRequest(source: source, session: request.session,
                                sourceOrdinal: request.sourceOrdinal, libraryOrdinal: ordinal, kind: .plexHubs(section)))
                            if AppleHomeServices.service(in: section.title) != nil {
                                following.append(LibraryRequest(source: source, session: request.session,
                                    sourceOrdinal: request.sourceOrdinal, libraryOrdinal: ordinal, kind: .plexLibrary(section)))
                            } else {
                                following.append(LibraryRequest(source: source, session: request.session,
                                    sourceOrdinal: request.sourceOrdinal, libraryOrdinal: ordinal, kind: .plexCollections(section)))
                            }
                        }
                    }
                    for followingRequest in following {
                        if let id = declareServiceLibrary(followingRequest) { refreshedShelfIDs[source.id, default: []].insert(id) }
                    }
                    requests.append(contentsOf: following)
                    for item in answer.items {
                        let reference = AppleMediaServerItemReference(sourceID: source.id, itemID: item.id)
                        receivedReferences.insert(reference)
                        index[reference] = item
                    }
                    for item in answer.plexItems {
                        let reference = AppleMediaServerItemReference(sourceID: source.id, itemID: item.ratingKey)
                        receivedReferences.insert(reference)
                        plexIndex[reference] = item
                    }
                    for (ordinal, shelf) in answer.shelves.enumerated() {
                        refreshedShelfIDs[source.id, default: []].insert(shelf.id)
                        let phase: Int
                        switch request.kind {
                        case .latest: phase = ordinal == 0 ? 0 : 2
                        case .plexRecent: phase = 0
                        case .library, .plexLibrary, .plexCollection: phase = 3
                        default: phase = 1
                        }
                        shelfRanks[shelf.id] = (request.sourceOrdinal, request.libraryOrdinal, request.collectionOrdinal, phase, ordinal)
                        if let hub = answer.hubs[shelf.id] {
                            if hub.isLibrary, let existing = hubStates[shelf.id], existing.hasLoaded,
                               existing.request == hub.request, unchangedSources.contains(source.id),
                               let position = rows.firstIndex(where: { $0.id == shelf.id }) {
                                let items = AppleStableRefresh.merge(rows[position].items,
                                    incoming: shelf.items + rows[position].items, id: \.id)
                                rows[position] = Shelf(id: shelf.id, title: shelf.title, sourceID: shelf.sourceID, items: items,
                                    collectionType: shelf.collectionType, discoverySort: shelf.discoverySort,
                                    libraryName: shelf.libraryName, totalItemCount: shelf.totalItemCount)
                                var updated = hub
                                updated.offset = max(existing.offset, hub.offset)
                                updated.exhausted = updated.offset >= updated.total
                                hubStates[shelf.id] = updated
                                hubDefinitions[shelf.id] = firstPage(of: shelf, state: hub)
                                continue
                            }
                            hubDefinitions[shelf.id] = hub.isLibrary ? firstPage(of: shelf, state: hub) : shelf
                            // A genre declaration does not replace an already fetched page or its cursor.
                            if !hub.hasLoaded {
                                if hubStates[shelf.id]?.hasLoaded == true { continue }
                                if let existing = rows.first(where: { $0.id == shelf.id }), !existing.items.isEmpty {
                                    var restored = hub
                                    restored.hasLoaded = true
                                    restored.refreshedAt = .distantPast
                                    hubStates[shelf.id] = restored
                                    continue
                                }
                            }
                            hubStates[shelf.id] = hub
                            if hub.hasLoaded, shelf.items.isEmpty, !hub.isLibrary {
                                rows.removeAll { $0.id == shelf.id }
                                continue
                            }
                        }
                        if let position = rows.firstIndex(where: { $0.id == shelf.id }) {
                            rows[position] = shelf
                        } else {
                            rows.append(shelf)
                        }
                    }
                    if !answer.shelves.isEmpty { orderShelves() }
                    if let incoming = answer.continueWatching {
                        let order: Int
                        switch request.kind {
                        case .resume, .plexOnDeck: order = -1
                        default: order = request.libraryOrdinal
                        }
                        watching[source.id, default: [:]][order] = incoming
                        let incoming = validSources.flatMap { pair in
                            let batches = watching[pair.source.id] ?? [:]
                            return batches.keys.sorted().flatMap { batches[$0] ?? [] }
                                + (batches.isEmpty ? previousWatching.filter {
                                    AppleMediaServerItemReference.parse($0.mediaID)?.sourceID == pair.source.id
                                } : [])
                        }
                        updateContinueWatchingFromNextUp(previous: [], incoming: incoming, replacing: true)
                    }
                    if !answer.shelves.isEmpty || answer.continueWatching != nil {
                        lastLoadedAt = Date()
                        persist()
                    }
                }
            }
        }
        guard currentGeneration == generation, !Task.isCancelled else { return }
        let removed = rows.filter { shelf in
            discovered.contains(shelf.sourceID) && rowErrors[shelf.sourceID] == nil
                && !(refreshedShelfIDs[shelf.sourceID] ?? []).contains(shelf.id)
        }
        if !removed.isEmpty {
            let ids = Set(removed.map(\.id))
            rows.removeAll { ids.contains($0.id) }
            for id in ids { hubStates[id] = nil; hubDefinitions[id] = nil }
            removeUnretainedItems(removed.flatMap(\.items))
        }
        let retiredHubs = hubDefinitions.values.filter {
            discovered.contains($0.sourceID) && rowErrors[$0.sourceID] == nil
                && !(refreshedShelfIDs[$0.sourceID] ?? []).contains($0.id)
        }.map(\.id)
        for id in retiredHubs { hubDefinitions[id] = nil; hubStates[id] = nil }
        hubDefinitions = hubDefinitions.filter { enabled.contains($0.value.sourceID) }
        hubStates = hubStates.filter { hubDefinitions[$0.key] != nil }
        shelfOrder = shelfOrder.filter { id in hubDefinitions[id] != nil || rows.contains { $0.id == id } }
        let orderedIDs = Set(shelfOrder)
        hubDefinitions = hubDefinitions.filter { orderedIDs.contains($0.key) }
        hubStates = hubStates.filter { orderedIDs.contains($0.key) }
        let playback = ApplePlaybackStore()
        let freshWatching = validSources.flatMap { pair in
            let previous = previousWatching.filter { AppleMediaServerItemReference.parse($0.mediaID)?.sourceID == pair.source.id }
            if rejected.contains(pair.source.id) {
                return previous
            }
            let batches = watching[pair.source.id] ?? [:]
            let incoming = batches.keys.sorted().flatMap { batches[$0] ?? [] }
            return incoming + (rowErrors[pair.source.id] == nil ? [] : previous)
        }
        updateContinueWatchingFromNextUp(previous: [], incoming:
            freshWatching.filter { shouldIncludeInContinueWatching(mediaID: $0.mediaID, store: playback) }, replacing: true)
        removeUnretainedItems(previousShelfItems)
        let retainedMediaIDs = Set(rows.flatMap(\.items).map(\.mediaID) + continueWatching.map(\.mediaID))
        let replacedSources = discovered.subtracting(rejected)
        for reference in Set(index.keys).union(plexIndex.keys) where replacedSources.contains(reference.sourceID)
            && !receivedReferences.contains(reference) && !retainedMediaIDs.contains(reference.mediaID) {
            rememberCompletedSeriesActivity(reference, store: playback)
            index[reference] = nil
            plexIndex[reference] = nil
        }
        for pair in validSources where !rejected.contains(pair.source.id) {
            let error = rowErrors[pair.source.id]
            if answered.contains(pair.source.id) {
                guard !structuralFailures.contains(pair.source.id) else { continue }
                // Rows that failed and left nothing to count are not "Connected · 0 titles".
                if let error, titleCount(for: pair.source.id) == 0 { recordConnectionFailure(source: pair.source, error: error) }
                else { recordConnectionSuccess(source: pair.source) }
            }
            else if let error { recordConnectionFailure(source: pair.source, error: error) }
        }
        lastLoadedAt = Date()
        reloadedAt = rowErrors.isEmpty && rejected.isEmpty && validSources.count == sources.filter({
            $0.kind == .mediaServer && $0.isEnabled }).count ? lastLoadedAt : nil
        await persistNow()
    }

    nonisolated private static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled
    }

    private func validatesCurrentSource(_ source: AppleSource) -> Bool {
        validationSourceStore?.sources.contains {
            $0.id == source.id && $0.isEnabled && $0.configurationRevision == source.configurationRevision
        } == true
    }

    /// The source's titles as far as this device knows them: every title its
    /// rows have loaded, plus the rest of each library whose size the server
    /// reported. Rows alone undercount: they hold one page of each library,
    /// and none at all before the first page arrives (owner 2026-11-04:
    /// Rill read "Connected · 0 titles" while its rows were full).
    func titleCount(for sourceID: UUID) -> Int {
        if let total = feedTitleCounts[sourceID] { return total }
        // Feed rows' titles aren't indexed: count them from the rows.
        let feedIDs = rows.filter { $0.sourceID == sourceID && $0.id.hasSuffix(":feed") }.flatMap(\.items)
            .compactMap { AppleMediaServerItemReference.parse($0.mediaID)?.itemID }
        let itemIDs = index.filter { $0.key.sourceID == sourceID && Self.isEligible($0.value) }.map { $0.key.itemID } + feedIDs
        let plexIDs = plexIndex.filter { $0.key.sourceID == sourceID && Self.isEligible($0.value) }.map { $0.key.itemID }
        let libraries = hubStates.compactMap { id, hub -> (total: Int, loaded: Int)? in
            guard hub.isLibrary, let shelf = rows.first(where: { $0.id == id }) ?? hubDefinitions[id],
                  shelf.sourceID == sourceID else { return nil }
            return (shelf.totalItemCount ?? hub.total, shelf.items.count)
        }
        return AppleMediaServerTitleCount.titles(indexed: Set(itemIDs + plexIDs).count, libraries: libraries)
    }

    private func recordConnectionSuccess(source: AppleSource) {
        failures.removeValue(forKey: source.id)
        guard validatesCurrentSource(source) else { return }
        let count = titleCount(for: source.id)
        appleTrace("media server checked: \(count) titles")
        validationSourceStore?.recordValidationSuccess(id: source.id,
            summary: "Connected · \(count) \(count == 1 ? "title" : "titles")",
            discoveredItemCount: count, capabilities: ["Library", "Playback"])
    }

    private func recordConnectionFailure(source: AppleSource, error: any Error, generation requestGeneration: Int? = nil) {
        guard !Task.isCancelled, requestGeneration == nil || requestGeneration == generation else { return }
        let needsSignIn = (error as? AppleMediaServerError) == .invalidCredentials
        let summary = Self.connectionFailureMessage(error)
        failures[source.id] = summary
        guard validatesCurrentSource(source) else { return }
        validationSourceStore?.recordValidationFailure(id: source.id, summary: summary,
            needsSignIn: needsSignIn)
    }

    nonisolated private static func connectionFailureMessage(_ error: any Error) -> String {
        if let error = error as? AppleMediaServerError { return AppleMediaServerFormPolicy.message(for: error) }
        return AppleDiagnosticRedactor.redact(error.localizedDescription)
    }
    
    private struct PersistedState: Codable, Sendable {
        let shelves: [Shelf]
        let continueWatching: [AppleCatalogItem]
        let lastLoadedAt: Date?
        var reloadedAt: Date? = nil
        var sources: [PersistedSource]? = nil
        var hubs: [String: HubState]? = nil
        var hubDefinitions: [String: Shelf]? = nil
        var shelfOrder: [String]? = nil
    }

    private struct PersistedSource: Codable, Sendable {
        let id: UUID
        let configurationRevision: Int
        let items: [AppleMediaServerItem]
        let plexItems: [ApplePlexItem]
    }
    
    private func cacheURL() -> URL {
        if let cacheFileURL { return cacheFileURL }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("OpenStream").appendingPathComponent("MediaServers-v1.json")
    }

    private func persist() {
        pendingPersist?.cancel()
        pendingPersist = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(400)) }
            catch { return }
            await self?.persistNow()
        }
    }

    private func persistNow() async {
        pendingPersist?.cancel()
        pendingPersist = nil
        // Plex hub keys may carry credentials; library cursors contain only section IDs.
        let savedHubs = hubStates.filter {
            if case .plex = $0.value.request { return false }
            return true
        }.mapValues { state in
            var saved = state
            if state.isLibrary {
                saved.offset = state.firstPageOffset ?? min(state.offset, Self.servicePageSize)
                saved.exhausted = saved.offset >= state.total
            }
            return saved
        }
        let savedShelves = rows.map { shelf in
            guard let state = hubStates[shelf.id], state.isLibrary else { return shelf }
            return firstPage(of: hubDefinitions[shelf.id] ?? shelf, state: state)
        }
        let state = PersistedState(shelves: savedShelves, continueWatching: continueWatching, lastLoadedAt: lastLoadedAt, reloadedAt: reloadedAt,
            hubs: savedHubs, hubDefinitions: hubDefinitions.filter { savedHubs[$0.key] != nil }, shelfOrder: shelfOrder)
        let sources = sourceOrder.compactMap { sourceIndex[$0] }
        let items = index
        let plexItems = plexIndex
        let url = cacheURL()
        let previous = cacheWrite
        let write = Task.detached(priority: .utility) {
            await previous?.value
            var state = state
            let retained = Set(state.shelves.flatMap(\.items).map(\.mediaID) + state.continueWatching.map(\.mediaID))
            state.sources = sources.map { source in
                PersistedSource(id: source.id, configurationRevision: source.configurationRevision,
                    items: items.filter { $0.key.sourceID == source.id && retained.contains($0.key.mediaID) }.map(\.value),
                    plexItems: plexItems.filter { $0.key.sourceID == source.id && retained.contains($0.key.mediaID) }.map(\.value))
            }
            do {
                let data = try AppleCachedCredentialPolicy.metadata(JSONEncoder().encode(state))
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                var destination = url
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try destination.setResourceValues(values)
            } catch {
                appleTrace("server rows cache write failed: \(type(of: error))")
            }
        }
        cacheWrite = write
        await write.value
    }

    public func loadPersisted(sources: [AppleSource]? = nil,
                              session: ((AppleSource) throws -> AppleMediaServerSession?)? = nil) {
        // A later root task must never overwrite rows already published by reload.
        guard generation == 0 else { return }
        let started = ContinuousClock.now
        guard let data = try? Data(contentsOf: cacheURL()),
              let clean = try? AppleCachedCredentialPolicy.forReading(data),
              let state = try? JSONDecoder().decode(PersistedState.self, from: clean) else {
            return
        }
        let enabled = sources.map { Set($0.filter { $0.isEnabled && $0.kind == .mediaServer }.map(\.id)) }
        var restored: [String: AppleCatalogItem] = [:]
        for source in sources ?? [] where enabled?.contains(source.id) == true {
            guard let saved = state.sources?.first(where: { $0.id == source.id && $0.configurationRevision == source.configurationRevision }),
                  let connection = try? session?(source) else { continue }
            sourceIndex[source.id] = source
            sessionIndex[source.id] = connection
            if !sourceOrder.contains(source.id) { sourceOrder.append(source.id) }
            for item in saved.items {
                index[.init(sourceID: source.id, itemID: item.id)] = item
                let mapped = catalogItem(item, source: source, session: connection)
                restored[mapped.mediaID] = mapped
            }
            for item in saved.plexItems {
                plexIndex[.init(sourceID: source.id, itemID: item.ratingKey)] = item
                let mapped = catalogItem(item, source: source, session: connection)
                restored[mapped.mediaID] = mapped
            }
        }
        self.rows = state.shelves.filter { enabled?.contains($0.sourceID) ?? true }.map { shelf in
            Shelf(id: shelf.id, title: shelf.title, sourceID: shelf.sourceID,
                items: shelf.items.map { restored[$0.mediaID] ?? $0 },
                collectionType: shelf.collectionType, discoverySort: shelf.discoverySort,
                libraryName: shelf.libraryName, totalItemCount: shelf.totalItemCount)
        }
        hubDefinitions = (state.hubDefinitions ?? [:]).filter { enabled?.contains($0.value.sourceID) ?? true }
        hubStates = (state.hubs ?? [:]).filter { hubDefinitions[$0.key] != nil }
        shelfOrder = state.shelfOrder ?? rows.map(\.id)
        self.continueWatching = state.continueWatching.filter {
            guard let enabled else { return true }
            return AppleMediaServerItemReference.parse($0.mediaID).map { enabled.contains($0.sourceID) } == true
        }.map { restored[$0.mediaID] ?? $0 }
        self.lastLoadedAt = state.lastLoadedAt
        reloadedAt = state.reloadedAt
        if clean != data { persist() } // Strip tokens from older saved copies as soon as they are read.
        appleTrace("server rows cache restored shelves=\(rows.count) ms=\(AppleLaunchMarks.milliseconds(started.duration(to: .now)))")
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

    private static func prefersServer(_ server: AppleMediaServerItem.UserData?, localUpdatedAt: Date?) -> Bool {
        guard server != nil else { return localUpdatedAt == nil }
        guard let localUpdatedAt else { return true }
        return server?.lastPlayedDate.map { $0 > localUpdatedAt } ?? false
    }

    public static func mergedResume(local: ApplePlaybackProgress?, server: AppleMediaServerItem.UserData?) -> Double? {
        if !prefersServer(server, localUpdatedAt: local?.updatedAt) { return local?.position }
        return server?.played == true ? nil : server?.positionSeconds
    }

    public static func resumePosition(for item: AppleMediaServerItem, local: ApplePlaybackProgress? = nil,
                                      localUpdatedAt: Date? = nil) -> Double? {
        if !prefersServer(item.userData, localUpdatedAt: localUpdatedAt ?? local?.updatedAt) { return local?.resumePosition }
        guard let position = item.userData?.positionSeconds,
              let duration = item.runtimeSeconds, duration > 0,
              position >= 15, item.userData?.played != true,
              !AppleCompletionPolicy.isComplete(position: position, duration: duration) else { return nil }
        return position
    }

    public func attach(to coordinator: ApplePlaybackCoordinator) {
        let tickets = activeTickets
        coordinator.remoteProgressSink = { [weak self] mediaID, position, duration, event in
            guard let self, let ticket = tickets[mediaID] else { return }
            self.handleRemoteProgress(mediaID: mediaID, position: position, duration: duration, event: event, ticket: ticket)
        }
    }

    internal func handleRemoteProgress(mediaID: String, position: Double, duration: Double, event: ApplePlaybackCoordinator.RemoteProgressEvent) {
        guard let ticket = activeTickets[mediaID] else { return }
        handleRemoteProgress(mediaID: mediaID, position: position, duration: duration, event: event, ticket: ticket)
    }

    private func handleRemoteProgress(mediaID: String, position: Double, duration: Double,
                                      event: ApplePlaybackCoordinator.RemoteProgressEvent,
                                      ticket: AppleMediaServerPlaybackTicket) {
        guard let ref = AppleMediaServerItemReference.parse(mediaID), !stoppedPlaybackIDs.contains(ticket.playbackID) else { return }
        
        let completed = event == .stopped && AppleCompletionPolicy.isComplete(position: position, duration: duration)
        let baseline = ticket.session.kind == .plex ? (plexIndex[ref]?.viewCount ?? 0) : (index[ref]?.userData?.playCount ?? 0)
        let pendingTarget = outbox.entries.filter { $0.sourceID == ref.sourceID && $0.itemID == ref.itemID }
            .compactMap(\.targetPlayCount).max() ?? baseline
        let completionTarget = completed ? max(baseline, pendingTarget, outbox.highestCompletionTarget(for: ref)) + 1 : nil
        if event == .stopped {
            // One stop per play: a second .stopped for the same request is ignored
            // until `playbackRequest` hands out a new ticket for this media id.
            if stoppedPlaybackIDs.contains(ticket.playbackID) { return }
            stoppedPlaybackIDs = Array((stoppedPlaybackIDs + [ticket.playbackID]).suffix(32))
            applyStop(reference: ref, mediaID: mediaID, position: position, duration: duration)
        }
        
        let remoteEvent: AppleRemoteProgressOutbox.Event
        switch event {
        case .started: remoteEvent = .started
        case .progress: remoteEvent = .progress
        case .paused: remoteEvent = .paused
        case .stopped: remoteEvent = .stopped
        }
        var batch: [AppleRemoteProgressOutbox.Entry] = [.init(sourceID: ref.sourceID, itemID: ref.itemID,
            playbackID: ticket.playbackID, kind: ticket.session.kind,
            mediaSourceID: ticket.session.kind == .plex ? "" : ticket.mediaSourceID, playSessionID: ticket.playSessionID,
            event: remoteEvent, position: max(0, position), duration: max(0, duration), targetPlayCount: nil)]
        if event == .stopped, ticket.session.kind == .plex,
           AppleCompletionPolicy.isComplete(position: position, duration: duration) {
            batch.append(.init(sourceID: ref.sourceID, itemID: ref.itemID,
                playbackID: ticket.playbackID, kind: .plex, mediaSourceID: "",
                playSessionID: ticket.playSessionID, event: .scrobble, position: position,
                duration: duration, targetPlayCount: completionTarget))
        }
        outbox.enqueue(batch)
        scheduleRemoteDelivery()
    }

    private func scheduleRemoteDelivery() {
        guard automaticallyDeliversRemoteProgress, !outbox.isDelivering, !outbox.entries.isEmpty else { return }
        deliveryTask?.cancel()
        deliveryTask = Task { [weak self] in
            guard !Task.isCancelled, let self else { return }
            await self.flushRemoteProgress()
            self.deliveryTask = nil
            if let next = self.outbox.nextAttemptAt(availableSources: Set(self.sessionIndex.keys)) {
                let delay = max(0.05, next.timeIntervalSinceNow)
                self.deliveryTask = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                    guard let self else { return }
                    self.deliveryTask = nil
                    self.scheduleRemoteDelivery()
                }
            }
        }
    }

    internal func flushRemoteProgress(now: Date = .now) async {
        var affected: Set<AppleMediaServerItemReference> = []
        await outbox.drain(now: now, availableSources: Set(sessionIndex.keys)) { [self] entry in
            guard let session = sessionIndex[entry.sourceID] else { throw AppleMediaServerError.unreachable }
            var delivered = false
            defer {
                if delivered, entry.event == .stopped || entry.event == .scrobble {
                    affected.insert(.init(sourceID: entry.sourceID, itemID: entry.itemID))
                }
            }
            if entry.kind == .plex {
                let item = try await plexClient.item(session: session, ratingKey: entry.itemID)
                if entry.event == .scrobble {
                    // A timeout may mean PMS applied the increment but its response
                    // was lost. Inspect the count before every retry or relaunch.
                    if (item.viewCount ?? 0) < (entry.targetPlayCount ?? 1) {
                        try await plexClient.markPlayed(session: session, ratingKey: entry.itemID)
                    }
                } else {
                    if entry.event == .stopped {
                        let count = item.viewCount ?? 0
                        if let observed = entry.observedPlayCount {
                            if count > observed { delivered = true; return }
                        } else {
                            outbox.checkpointPlayCount(entryID: entry.id, count: count)
                        }
                    }
                    let state: ApplePlexClient.PlaybackState = entry.event == .stopped ? .stopped : entry.event == .paused ? .paused : .playing
                    try await plexClient.reportTimeline(session: session, item: item, state: state, positionSeconds: entry.position)
                }
            } else {
                switch entry.event {
                case .started:
                    try await client.reportPlaybackStart(session: session, itemID: entry.itemID, mediaSourceID: entry.mediaSourceID, playSessionID: entry.playSessionID, positionSeconds: entry.position)
                case .progress, .paused:
                    try await client.reportPlaybackProgress(session: session, itemID: entry.itemID, mediaSourceID: entry.mediaSourceID, playSessionID: entry.playSessionID, positionSeconds: entry.position, isPaused: entry.event == .paused)
                case .stopped:
                    let fresh = try await client.item(session: session, id: entry.itemID)
                    let count = fresh.userData?.playCount ?? 0
                    if let observed = entry.observedPlayCount {
                        if count > observed { delivered = true; return }
                    } else {
                        // Checkpoint the authoritative pre-stop count before the
                        // request. Partial stops can increment too on some servers.
                        outbox.checkpointPlayCount(entryID: entry.id, count: count)
                    }
                    try await client.reportPlaybackStopped(session: session, itemID: entry.itemID, mediaSourceID: entry.mediaSourceID, playSessionID: entry.playSessionID, positionSeconds: entry.position)
                case .scrobble: break
                }
            }
            delivered = true
        }
        for reference in affected { await refreshAffectedHubs(reference: reference) }
    }

    /// Mirrors a finished play into the in-memory item and the resume row at
    /// once, so Continue Watching is right before the server answers.
    private func applyStop(reference ref: AppleMediaServerItemReference, mediaID: String, position: Double, duration: Double) {
        guard let item = index[ref] else { return }
        let played = AppleCompletionPolicy.isComplete(position: position, duration: duration)
        let old = item.userData
        let newUserData = AppleMediaServerItem.UserData(
            positionSeconds: played ? 0 : position,
            played: played || (old?.played ?? false),
            isFavorite: old?.isFavorite ?? false,
            playCount: (old?.playCount ?? 0) + (played ? 1 : 0),
            lastPlayedDate: old?.lastPlayedDate
        )
        let newItem = item.withUserData(newUserData)
        index[ref] = newItem
        detailCache.removeValue(forKey: ref)
        continueWatching.removeAll(where: { $0.mediaID == mediaID })
        if !played, let source = sourceIndex[ref.sourceID], let sess = sessionIndex[ref.sourceID] {
            continueWatching.insert(catalogItem(newItem, source: source, session: sess), at: 0)
        }
        persist()
    }

    func titleMatches(query: AppleMediaServerTitleQuery, serverTimeout: Duration = .seconds(6),
                      now: Date = .now) async -> [AppleMediaServerTitleMatch] {
        await firstSessions()
        guard !Task.isCancelled else { return [] }
        titleMatchCache = titleMatchCache.filter { now.timeIntervalSince($0.value.fetchedAt) < 600 }
        if let cached = titleMatchCache[query] { return cached.matches }
        let lookupGeneration = generation
        let connections = sourceOrder.compactMap { id -> (AppleSource, AppleMediaServerSession)? in
            guard let source = sourceIndex[id], source.isEnabled,
                  let session = sessionIndex[id], session.kind != .plex else { return nil }
            return (source, session)
        }
        let matches = await withTaskGroup(of: AppleMediaServerTitleMatch?.self) { group in
            for (source, session) in connections {
                group.addTask {
                    await self.titleMatch(query: query, source: source, session: session, timeout: serverTimeout)
                }
            }
            var found: [AppleMediaServerTitleMatch] = []
            for await match in group {
                if let match { found.append(match) }
            }
            return found
        }
        guard !Task.isCancelled else { return [] }
        let order = Dictionary(uniqueKeysWithValues: sourceOrder.enumerated().map { ($0.element, $0.offset) })
        let current = matches.filter { titleConnectionIsCurrent(source: $0.detail.source, session: $0.detail.session) }
            .sorted { order[$0.detail.source.id, default: .max] < order[$1.detail.source.id, default: .max] }
        if generation == lookupGeneration,
           connections.allSatisfy({ titleConnectionIsCurrent(source: $0.0, session: $0.1) }) {
            titleMatchCache[query] = CachedTitleMatches(matches: current, fetchedAt: now)
        }
        return current
    }

    private func titleConnectionIsCurrent(source: AppleSource, session: AppleMediaServerSession) -> Bool {
        sessionIndex[source.id] == session
            && sourceIndex[source.id]?.configurationRevision == source.configurationRevision
            && sourceIndex[source.id]?.isEnabled == true
    }

    private func titleMatch(query: AppleMediaServerTitleQuery, source: AppleSource,
                            session: AppleMediaServerSession, timeout: Duration) async -> AppleMediaServerTitleMatch? {
        await withTaskGroup(of: AppleMediaServerTitleMatch?.self) { group in
            group.addTask { await self.probeTitleMatch(query: query, source: source, session: session) }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let match = await group.next() ?? nil
            group.cancelAll()
            return match
        }
    }

    private func probeTitleMatch(query: AppleMediaServerTitleQuery, source: AppleSource,
                                 session: AppleMediaServerSession) async -> AppleMediaServerTitleMatch? {
        do {
            guard titleConnectionIsCurrent(source: source, session: session) else { return nil }
            let candidates = try await client.titleMatches(session: session, query: query)
            candidateLoop: for candidate in candidates {
                try Task.checkCancellation()
                guard titleConnectionIsCurrent(source: source, session: session) else { continue candidateLoop }
                let reference = AppleMediaServerItemReference(sourceID: source.id, itemID: candidate.id)
                let detail = try await detail(for: reference)
                guard titleConnectionIsCurrent(source: source, session: session), detail.session == session,
                      detail.source.configurationRevision == source.configurationRevision else { continue candidateLoop }
                let targets = candidate.type == .series
                    ? Array(AppleMediaServerItem.inIndexOrder(detail.episodesBySeason.values.flatMap { $0 }).prefix(2)) : [detail.item]
                for target in targets {
                    guard titleConnectionIsCurrent(source: source, session: session) else { continue candidateLoop }
                    let info = try await client.playbackInfo(session: session, itemID: target.id)
                    try Task.checkCancellation()
                    guard titleConnectionIsCurrent(source: source, session: session) else { continue candidateLoop }
                    if !info.saysNoCompatibleStream, info.mediaSources.contains(where: {
                        !$0.isPlaceholder && ($0.supportsDirectPlay || $0.supportsDirectStream || $0.transcodingURLPath != nil)
                    }) {
                        preparedPlaybackInfo = (.init(sourceID: source.id, itemID: target.id), session, info, .now)
                        return .init(detail: detail, playableItem: target)
                    }
                }
            }
        } catch {
            if !Self.isCancellation(error) { appleTrace("title lookup failed (\(session.kind.rawValue))") }
        }
        return nil
    }

    /// The IMDb id the server gave for an item it listed in a row, so a title
    /// page can draw catalog credits before the server's detail answers.
    func imdbID(for reference: AppleMediaServerItemReference) -> String? {
        index[reference]?.imdbID.flatMap { AppleMediaIdentifier.isIMDBIdentifier($0) ? $0 : nil }
    }

    public func detail(for reference: AppleMediaServerItemReference) async throws -> AppleMediaServerDetail {
        if let cached = detailCache[reference], Date().timeIntervalSince(cached.fetchedAt) < 600,
           titleConnectionIsCurrent(source: cached.detail.source, session: cached.detail.session) {
            return cached.detail
        }
        if sessionIndex[reference.sourceID] == nil { await firstSessions() }
        try Task.checkCancellation()

        guard let source = sourceIndex[reference.sourceID],
              let session = sessionIndex[reference.sourceID] else {
            throw AppleMediaServerError.unsupported
        }
        
        if session.kind == .plex {
            let freshPlexItem = try await plexClient.item(session: session, ratingKey: reference.itemID)
            let series: ApplePlexItem?
            var parentFetchFailed = false
            if freshPlexItem.type == .episode {
                let parent = try await Self.parentSeries(of: reference.itemID,
                    seriesID: freshPlexItem.grandparentRatingKey, failed: &parentFetchFailed) {
                    try await plexClient.item(session: session, ratingKey: $0)
                }
                series = parent?.type == .show ? parent : nil
            } else {
                series = freshPlexItem.type == .show ? freshPlexItem : nil
            }

            func toMediaServerItem(_ plex: ApplePlexItem) -> AppleMediaServerItem {
                let type: AppleMediaServerItemType
                switch plex.type {
                case .movie: type = .movie
                case .show: type = .series
                case .season: type = .season
                case .episode: type = .episode
                case .other, .collection: type = .other
                }

                var userData: AppleMediaServerItem.UserData?
                if plex.viewCount != nil || plex.viewOffsetSeconds != nil {
                    userData = Self.playbackData(for: plex)
                }

                return AppleMediaServerItem(
                    id: plex.ratingKey, name: plex.title, type: type, year: plex.year,
                    overview: plex.summary, runtimeSeconds: plex.durationSeconds,
                    seriesID: plex.grandparentRatingKey ?? (type == .episode || type == .season ? series?.ratingKey : nil),
                    seriesName: plex.grandparentTitle, seasonID: plex.parentRatingKey,
                    indexNumber: plex.index, parentIndexNumber: plex.parentIndex, userData: userData
                )
            }

            var seasons: [AppleMediaServerItem] = []
            var episodesBySeason: [String: [AppleMediaServerItem]] = [:]
            if let series {
                let plexSeasons = try await plexClient.children(session: session, ratingKey: series.ratingKey)
                for season in plexSeasons {
                    let listed = try await plexClient.children(session: session, ratingKey: season.ratingKey)
                    seasons.append(toMediaServerItem(season))
                    episodesBySeason[season.ratingKey] = listed.map { episode in
                        let episodeReference = AppleMediaServerItemReference(sourceID: source.id, itemID: episode.ratingKey)
                        // A children listing can omit Media and carry older progress than an item fetch.
                        if episodeReference == reference { return toMediaServerItem(freshPlexItem) }
                        let resolved = plexIndex[episodeReference] ?? episode
                        if plexIndex[episodeReference] == nil {
                            plexIndex[episodeReference] = resolved
                        }
                        let mapped = index[episodeReference] ?? toMediaServerItem(resolved)
                        if index[episodeReference] == nil { index[episodeReference] = mapped }
                        return mapped
                    }
                }
                let seriesReference = AppleMediaServerItemReference(sourceID: source.id, itemID: series.ratingKey)
                let seriesItem = toMediaServerItem(series)
                plexIndex[seriesReference] = series
                index[seriesReference] = seriesItem
                let seriesDetail = AppleMediaServerDetail(item: seriesItem, source: source, session: session,
                    seasons: seasons, episodesBySeason: episodesBySeason)
                detailCache[seriesReference] = CachedDetail(detail: seriesDetail, fetchedAt: Date())
            }
            let freshItem = toMediaServerItem(freshPlexItem)
            plexIndex[reference] = freshPlexItem
            index[reference] = freshItem
            let resolvedDetail = AppleMediaServerDetail(item: freshItem, source: source, session: session,
                seasons: seasons, episodesBySeason: episodesBySeason)
            if !parentFetchFailed { detailCache[reference] = CachedDetail(detail: resolvedDetail, fetchedAt: Date()) }
            return resolvedDetail
        }

        let freshItem = try await client.item(session: session, id: reference.itemID)
        index[reference] = freshItem
        let series: AppleMediaServerItem?
        var parentFetchFailed = false
        if freshItem.type == .episode {
            let parent = try await Self.parentSeries(of: reference.itemID, seriesID: freshItem.seriesID,
                failed: &parentFetchFailed) { try await client.item(session: session, id: $0) }
            series = parent?.type == .series ? parent : nil
            if let series { index[.init(sourceID: source.id, itemID: series.id)] = series }
        } else {
            series = freshItem.type == .series ? freshItem : nil
        }

        var seasons: [AppleMediaServerItem] = []
        var episodesBySeason: [String: [AppleMediaServerItem]] = [:]
        if let series {
            let allSeasons = try await AppleMediaServerItem.inIndexOrder(client.seasons(session: session, seriesID: series.id))
            let episodes = await withTaskGroup(of: (String, [AppleMediaServerItem]).self) { group in
                for season in allSeasons {
                    group.addTask {
                        let eps = (try? await self.client.episodes(session: session, seriesID: series.id, seasonID: season.id)) ?? []
                        return (season.id, AppleMediaServerItem.inIndexOrder(eps))
                    }
                }
                var collected: [String: [AppleMediaServerItem]] = [:]
                for await res in group {
                    if !res.1.isEmpty { collected[res.0] = res.1 }
                }
                return collected
            }
            for season in allSeasons {
                if let eps = episodes[season.id], !eps.isEmpty {
                    seasons.append(season)
                    episodesBySeason[season.id] = eps.map { $0.id == freshItem.id ? freshItem : $0 }
                }
            }
            let seriesReference = AppleMediaServerItemReference(sourceID: source.id, itemID: series.id)
            let seriesDetail = AppleMediaServerDetail(item: series, source: source, session: session,
                seasons: seasons, episodesBySeason: episodesBySeason)
            detailCache[seriesReference] = CachedDetail(detail: seriesDetail, fetchedAt: Date())
        }
        let resolvedDetail = AppleMediaServerDetail(item: freshItem, source: source, session: session,
            seasons: seasons, episodesBySeason: episodesBySeason)
        if !parentFetchFailed { detailCache[reference] = CachedDetail(detail: resolvedDetail, fetchedAt: Date()) }
        return resolvedDetail
    }

    /// An episode's parent series, or nil when it has none (no series id, a
    /// self-reference, or a parent the server no longer returns): the
    /// episode then opens on its own. A failed parent fetch sets `failed`
    /// so that page is not cached as the episode's detail.
    private static func parentSeries<Item>(of episodeID: String, seriesID: String?, failed: inout Bool,
                                           fetch: (String) async throws -> Item) async throws -> Item? {
        guard let seriesID, !seriesID.isEmpty, seriesID != episodeID else { return nil }
        do {
            return try await fetch(seriesID)
        } catch {
            if isCancellation(error) { throw error }
            appleTrace("title parent series unavailable: episode opens alone")
            failed = true
            return nil
        }
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

    public func mediaVersions(for item: AppleMediaServerItem, in detail: AppleMediaServerDetail) async throws -> [AppleMediaVersion] {
        guard item.type != .series, detail.session.kind != .plex else { return [] }
        let itemID = AppleMediaServerItemReference(sourceID: detail.source.id, itemID: item.id).mediaID
        // The menu reads the shared cache; PlaybackInfo is asked again only when it is old.
        let cached = AppleMediaVersionCache.shared.versions(itemID: itemID)
        if !cached.isEmpty, verifiedVersionItems.contains(itemID)
            || cached.allSatisfy({ Date.now.timeIntervalSince($0.lastVerified) < Self.versionCacheLifetime }) {
            return cached.sorted { $0.quality == $1.quality ? $0.id < $1.id : $0.quality > $1.quality }
        }
        let reference = AppleMediaServerItemReference(sourceID: detail.source.id, itemID: item.id)
        let info: AppleMediaServerPlaybackInfo
        if let prepared = preparedPlaybackInfo, prepared.reference == reference, prepared.session == detail.session,
           prepared.fetchedAt.duration(to: .now) < Self.preparedPlaybackInfoLifetime {
            info = prepared.info
        } else {
            info = try await client.playbackInfo(session: detail.session, itemID: item.id)
        }
        try Task.checkCancellation()
        preparedPlaybackInfo = (.init(sourceID: detail.source.id, itemID: item.id), detail.session, info, .now)
        let versions = info.mediaSources.map { source in
            var version = AppleMediaVersion(id: source.id, itemID: itemID, sourceID: detail.source.id,
                label: source.versionLabel,
                parts: [.init(id: "mp:" + ApplePlaybackIdentity.digest(for: itemID + source.id), ordinal: 1,
                    duration: source.descriptors.duration, reference: ApplePlaybackIdentity.digest(for: itemID + source.id))],
                providerVersionID: source.id)
            version.descriptors = source.descriptors
            version.formatBadges = source.formatBadges
            return version
        }
        AppleMediaVersionCache.shared.record(versions)
        verifiedVersionItems.insert(itemID)
        return versions
    }

    static let versionCacheLifetime: TimeInterval = 6 * 60 * 60

    /// Asks PlaybackInfo for the item a title page would play while the
    /// viewer is on the page, so Play reuses the answer. `mediaVersions`
    /// already does this when it asks the server; a page whose versions came
    /// from the cache asked nothing, and its Play waited a full PlaybackInfo
    /// round trip (test Apple TV, The Return of the King: 1.0 s of a 3.045 s start, walk b20r24).
    public func preparePlayback(for item: AppleMediaServerItem, in detail: AppleMediaServerDetail) async {
        guard item.type == .movie || item.type == .episode, detail.session.kind != .plex else { return }
        let reference = AppleMediaServerItemReference(sourceID: detail.source.id, itemID: item.id)
        if let prepared = preparedPlaybackInfo, prepared.reference == reference, prepared.session == detail.session,
           prepared.fetchedAt.duration(to: .now) < Self.preparedPlaybackInfoLifetime { return }
        guard let info = try? await client.playbackInfo(session: detail.session, itemID: item.id),
              !Task.isCancelled else { return }
        preparedPlaybackInfo = (reference, detail.session, info, .now)
    }

    /// The server said NoCompatibleStream and every source it listed failed.
    static let noStreamFailure = ApplePlaybackFailure(kind: .unavailable,
        message: "The server has nothing to play for this title right now.")

    public func playbackRequest(for item: AppleMediaServerItem, in detail: AppleMediaServerDetail, resume: Bool, versionID: String? = nil, afterFailure: Bool = false,
                                failedVersions: Set<String> = [], confirmedVersionID: String? = nil) async throws -> ApplePlaybackRequest {
        try await playbackCandidates(for: item, in: detail, resume: resume, versionID: versionID, afterFailure: afterFailure,
                                     failedVersions: failedVersions, confirmedVersionID: confirmedVersionID)[0]
    }

    /// The request for the chosen source, then the title's other sources in
    /// the order to try them (a placeholder last), for the player to walk
    /// when one fails (`ApplePlaybackCoordinator.begin(_:fallbackCandidates:)`).
    /// Never empty.
    public func playbackCandidates(for item: AppleMediaServerItem, in detail: AppleMediaServerDetail, resume: Bool, versionID: String? = nil, afterFailure: Bool = false,
                                   failedVersions: Set<String> = [], confirmedVersionID: String? = nil) async throws -> [ApplePlaybackRequest] {
        try Task.checkCancellation()
        if detail.session.kind == .plex {
            guard let plexItem = plexIndex[AppleMediaServerItemReference(sourceID: detail.source.id, itemID: item.id)] else {
                throw AppleMediaServerError.unsupported
            }
            guard let part = plexItem.parts.first else {
                throw AppleMediaServerError.unsupported
            }
            let url = plexClient.directPlayURL(session: detail.session, part: part)
            
            let mediaID = AppleMediaServerItemReference(sourceID: detail.source.id, itemID: item.id).mediaID
                activeTickets[mediaID] = AppleMediaServerPlaybackTicket(
                session: detail.session,
                mediaSourceID: part.key,
                playSessionID: nil
            )
            
            let position: Double?
            let localStore = ApplePlaybackStore()
            position = resume ? Self.resumePosition(for: item.withUserData(Self.playbackData(for: plexItem)),
                local: localStore.progress(for: mediaID),
                localUpdatedAt: localStore.localPlaybackUpdatedAt(mediaID: mediaID)) : nil

            let title: String
            if item.type == .episode {
                let sIdx = item.parentIndexNumber.map { String($0) } ?? "?"
                let eIdx = item.indexNumber.map { String($0) } ?? "?"
                let series = item.seriesName ?? detail.item.name
                title = "\(series) S\(sIdx)E\(eIdx)"
            } else {
                title = item.name
            }
            
            let request = ApplePlaybackRequest(
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
            return [withNowPlayingMetadata(request, item: item, detail: detail)]
        }
        
        let preferred = confirmedVersionID ?? versionID
        let reference = AppleMediaServerItemReference(sourceID: detail.source.id, itemID: item.id)
        let prepared = preparedPlaybackInfo
        preparedPlaybackInfo = nil
        let info: AppleMediaServerPlaybackInfo
        if !afterFailure, preferred == nil, let prepared,
           prepared.reference == reference, prepared.session == detail.session,
           prepared.fetchedAt.duration(to: .now) < Self.preparedPlaybackInfoLifetime {
            info = prepared.info
            appleTrace("media server playback info reused from preparation")
        } else {
            info = try await client.playbackInfo(session: detail.session, itemID: item.id,
                forceConversion: afterFailure, mediaSourceID: preferred)
        }
        try Task.checkCancellation()

        let noneLeft: any Error = info.saysNoCompatibleStream ? Self.noStreamFailure : AppleMediaServerError.unsupported
        let capabilities = AppleDeviceCapabilities.current
        guard let mediaSource = AppleJellyfinPlaybackPolicy.select(info.mediaSources, failed: failedVersions,
            preferred: preferred, defaultMediaSourceID: info.defaultMediaSourceID, capabilities: capabilities) else {
            throw noneLeft
        }
        
        // The retry after a failure converts only when the server offers a
        // conversion; replaying the same original would fail the same way.
        // A source on another host that failed retries through the server's
        // own stream of it.
        if afterFailure, mediaSource.transcodingURLPath == nil, mediaSource.remoteURL == nil {
            let othersLeft = info.mediaSources.contains { $0.id != mediaSource.id && !failedVersions.contains($0.id) }
            throw othersLeft ? AppleMediaServerError.unsupported : noneLeft
        }
        let url: URL
        var headers = ["X-Emby-Token": detail.session.accessToken]
        let usesConversion = AppleJellyfinPlaybackPolicy.route(for: mediaSource, afterFailure: afterFailure, capabilities: capabilities) == .conversion
        let descriptors = mediaSource.descriptors
        if usesConversion,
           let path = mediaSource.transcodingURLPath {
            url = try AppleJellyfinPlaybackPolicy.conversionURL(path, session: detail.session,
                audioStreamIndex: mediaSource.mediaStreams.first { $0.type?.lowercased() == "audio" }?.index,
                audioOnly: AppleJellyfinPlaybackPolicy.isAudioOnlyMismatch(mediaSource), videoCodec: mediaSource.descriptors.videoCodec)
        } else if afterFailure {
            url = try serverStreamURL(mediaSource, item: item, session: detail.session)
        } else {
            (url, headers) = try originalStream(mediaSource, item: item, session: detail.session)
        }
        let urlSourceID = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name.lowercased() == "mediasourceid" }?.value
        let sourceBinding = urlSourceID.map { $0 == mediaSource.id ? "selected" : "different" } ?? "unspecified"
        if let first = info.mediaSources.first, first.id != mediaSource.id {
            let video = first.descriptors
            appleTrace("media server skipped first native=\(AppleJellyfinPlaybackPolicy.canDirectPlay(first, capabilities: capabilities)) video=\(video.videoCodec ?? "unknown") size=\(video.width ?? 0)x\(video.height ?? 0) labelHeight=\(AppleReleaseName.resolution(first.name ?? "")) bytes=\(first.size ?? 0)")
        }
        appleTrace("media server selected index=\(info.mediaSources.firstIndex { $0.id == mediaSource.id } ?? -1) defaultIndex=\(info.mediaSources.firstIndex { $0.id == info.defaultMediaSourceID } ?? -1) manual=\(preferred != nil) video=\(descriptors.videoCodec ?? "unknown") size=\(descriptors.width ?? 0)x\(descriptors.height ?? 0) labelHeight=\(AppleReleaseName.resolution(mediaSource.name ?? "")) bytes=\(mediaSource.size ?? 0) binding=\(sourceBinding) conversion=\(usesConversion)")
        
        let mediaID = AppleMediaServerItemReference(sourceID: detail.source.id, itemID: item.id).mediaID
        activeTickets[mediaID] = AppleMediaServerPlaybackTicket(
            session: detail.session,
            mediaSourceID: mediaSource.id,
            playSessionID: info.playSessionID
        )

        let localStore = ApplePlaybackStore()
        let localProgress = localStore.progress(for: mediaID)
        let resolution = AppleVersionResumePolicy.resolve(own: localStore.versionProgress(itemID: mediaID, versionID: mediaSource.id),
            item: localProgress, duration: mediaSource.descriptors.duration)
        let serverOwns = Self.prefersServer(item.userData, localUpdatedAt: localStore.localPlaybackUpdatedAt(mediaID: mediaID))
        if resume, !serverOwns, confirmedVersionID != mediaSource.id, resolution.needsConfirmation, let position = resolution.position {
            throw AppleVersionResumeConfirmation(position: position, versionID: mediaSource.id)
        }
        let position = resume ? (serverOwns ? Self.resumePosition(for: item, local: localProgress,
            localUpdatedAt: localStore.localPlaybackUpdatedAt(mediaID: mediaID)) : resolution.position) : nil
        
        let title: String
        if item.type == .episode {
            let sIdx = item.parentIndexNumber.map { String($0) } ?? "?"
            let eIdx = item.indexNumber.map { String($0) } ?? "?"
            let sName = item.seriesName ?? detail.item.name
            title = "\(sName) · S\(sIdx)E\(eIdx) \(item.name)"
        } else {
            title = item.name
        }
        
        let request = withNowPlayingMetadata(ApplePlaybackRequest(
            url: url,
            headers: headers,
            isLive: false,
            resumePosition: position,
            autoplay: true,
            mediaID: mediaID,
            title: title,
            sourceName: detail.source.name,
            sourceKind: .mediaServer,
            hints: {
                var hints = ApplePlaybackRequest.Hints()
                hints.versionID = mediaSource.id
                hints.externalSubtitles = AppleJellyfinPlaybackPolicy.externalSubtitles(mediaSource, session: detail.session)
                hints.playbackDecision = usesConversion
                    ? AppleJellyfinPlaybackPolicy.conversionDecision(for: mediaSource)
                    : ApplePlaybackDecision.decide(mediaSource.descriptors, remote: true)
                return hints
            }()
        ), item: item, detail: detail)
        guard !afterFailure else { return [request] }
        let others = try AppleJellyfinPlaybackPolicy.ranked(info.mediaSources, failed: failedVersions.union([mediaSource.id]),
            capabilities: capabilities).map { source in
            var fallback = request
            let converts = AppleJellyfinPlaybackPolicy.route(for: source, afterFailure: false, capabilities: capabilities) == .conversion
            if converts, let path = source.transcodingURLPath {
                fallback.url = try AppleJellyfinPlaybackPolicy.conversionURL(path, session: detail.session,
                    audioStreamIndex: source.mediaStreams.first { $0.type?.lowercased() == "audio" }?.index,
                    audioOnly: AppleJellyfinPlaybackPolicy.isAudioOnlyMismatch(source), videoCodec: source.descriptors.videoCodec)
                fallback.headers = ["X-Emby-Token": detail.session.accessToken]
            } else {
                (fallback.url, fallback.headers) = try originalStream(source, item: item, session: detail.session)
            }
            fallback.hints.versionID = source.id
            fallback.hints.externalSubtitles = AppleJellyfinPlaybackPolicy.externalSubtitles(source, session: detail.session)
            fallback.hints.playbackDecision = converts ? AppleJellyfinPlaybackPolicy.conversionDecision(for: source)
                : ApplePlaybackDecision.decide(source.descriptors, remote: true)
            return fallback
        }
        return [request] + others
    }

    private func withNowPlayingMetadata(_ request: ApplePlaybackRequest, item: AppleMediaServerItem,
                                       detail: AppleMediaServerDetail) -> ApplePlaybackRequest {
        var request = request
        if item.type == .episode { request.subtitle = item.seriesName ?? detail.item.name }
        if detail.session.kind == .plex {
            let episode = plexIndex[AppleMediaServerItemReference(sourceID: detail.source.id, itemID: item.id)]
            let series = plexIndex[AppleMediaServerItemReference(sourceID: detail.source.id, itemID: detail.item.id)]
            request.artworkURL = episode.flatMap { catalogItem($0, source: detail.source, session: detail.session).posterURL }
                ?? series.flatMap { catalogItem($0, source: detail.source, session: detail.session).posterURL }
        } else {
            request.artworkURL = catalogItem(item, source: detail.source, session: detail.session).posterURL
                ?? catalogItem(detail.item, source: detail.source, session: detail.session).posterURL
        }
        return request
    }

    /// A source's original: from its own host with the headers it needs, or
    /// the server's stream of it.
    private func originalStream(_ source: AppleMediaServerPlaybackInfo.MediaSource, item: AppleMediaServerItem,
                                session: AppleMediaServerSession) throws -> (URL, [String: String]) {
        if let remote = source.remoteURL { return (remote, source.requiredHTTPHeaders) }
        return (try serverStreamURL(source, item: item, session: session), [:])
    }

    private func serverStreamURL(_ source: AppleMediaServerPlaybackInfo.MediaSource, item: AppleMediaServerItem,
                                 session: AppleMediaServerSession) throws -> URL {
        try client.directStreamURL(session: session, itemID: item.id, mediaSourceID: source.id,
                                   container: source.container?.components(separatedBy: ",").first ?? source.container)
    }

    /// A billboard needs one title, not the season and episode lists loaded by `detail(for:)`.
    func heroMetadata(for reference: AppleMediaServerItemReference, configuration: AppleTMDBConfiguration?,
                      tmdbClient: AppleTMDBClient = AppleTMDBClient()) async throws -> AppleTMDBDetails {
        if sessionIndex[reference.sourceID] == nil { await firstSessions() }
        try Task.checkCancellation()
        guard let source = sourceIndex[reference.sourceID], let session = sessionIndex[reference.sourceID] else {
            throw AppleMediaServerError.unsupported
        }
        let server: AppleTMDBDetails
        let imdbID: String?
        let tmdbID: String?
        if session.kind == .plex {
            let listed = try await plexClient.item(session: session, ratingKey: reference.itemID)
            let title: ApplePlexItem
            if listed.type == .episode {
                guard let parent = listed.grandparentRatingKey, parent != listed.ratingKey else {
                    throw AppleMediaServerError.unsupported
                }
                title = try await plexClient.item(session: session, ratingKey: parent)
                guard title.type == .show else { throw AppleMediaServerError.unsupported }
            } else {
                title = listed
            }
            try Task.checkCancellation()
            guard titleConnectionIsCurrent(source: source, session: session) else { throw CancellationError() }
            plexIndex[reference] = listed
            plexIndex[.init(sourceID: source.id, itemID: title.ratingKey)] = title
            let item = catalogItem(title, source: source, session: session)
            server = AppleTMDBDetails(mediaID: item.mediaID, mediaType: item.type, title: item.name,
                releaseInfo: item.releaseInfo, runtimeMinutes: title.durationSeconds.map { Int($0 / 60) },
                year: item.year, overview: item.summary, posterURL: item.posterURL, backdropURL: item.backgroundURL)
            imdbID = title.imdbID
            tmdbID = title.tmdbID
        } else {
            let listed = try await client.item(session: session, id: reference.itemID)
            let title: AppleMediaServerItem
            if listed.type == .episode {
                guard let parent = listed.seriesID, parent != listed.id else {
                    throw AppleMediaServerError.unsupported
                }
                title = try await client.item(session: session, id: parent)
                guard title.type == .series else { throw AppleMediaServerError.unsupported }
            } else {
                title = listed
            }
            try Task.checkCancellation()
            guard titleConnectionIsCurrent(source: source, session: session) else { throw CancellationError() }
            index[reference] = listed
            index[.init(sourceID: source.id, itemID: title.id)] = title
            server = metadata(from: AppleMediaServerDetail(item: title, source: source, session: session,
                seasons: [], episodesBySeason: [:]))
            imdbID = title.imdbID
            tmdbID = title.tmdbID
        }
        guard let configuration else { return server }
        let kind: AppleMediaKind = server.mediaType == "series" ? .series : .movie
        let catalog: AppleTMDBDetails?
        if let imdbID, AppleMediaIdentifier.isIMDBIdentifier(imdbID), !imdbID.contains(":") {
            catalog = try? await tmdbClient.cachedDetails(imdbID: imdbID, kind: kind, configuration: configuration)
        } else if let tmdbID, let number = Int(tmdbID), number > 0 {
            catalog = try? await tmdbClient.details(tmdbID: number, kind: kind, configuration: configuration)
        } else {
            catalog = nil
        }
        try Task.checkCancellation()
        guard titleConnectionIsCurrent(source: source, session: session) else { throw CancellationError() }
        guard let catalog else { return server }
        return AppleTMDBDetails(mediaID: server.mediaID, mediaType: server.mediaType, title: server.title,
            releaseInfo: server.releaseInfo ?? catalog.releaseInfo, runtimeMinutes: server.runtimeMinutes ?? catalog.runtimeMinutes,
            contentRating: server.contentRating ?? catalog.contentRating,
            genres: server.genres.isEmpty ? catalog.genres : server.genres,
            imdbRating: server.imdbRating ?? catalog.imdbRating, year: server.year ?? catalog.year,
            overview: server.overview ?? catalog.overview, posterURL: server.posterURL ?? catalog.posterURL,
            backdropURL: server.backdropURL ?? catalog.backdropURL, logoURL: server.logoURL ?? catalog.logoURL,
            trailerYouTubeKeys: server.trailerYouTubeKeys + catalog.trailerYouTubeKeys,
            textlessBackdropURL: catalog.textlessBackdropURL, textlessPosterURL: catalog.textlessPosterURL,
            catalogBackdropURL: catalog.backdropURL, catalogLogoURL: catalog.logoURL)
    }

    public func metadata(from detail: AppleMediaServerDetail) -> AppleTMDBDetails {
        let parent = detail.item.seriesID.flatMap {
            index[AppleMediaServerItemReference(sourceID: detail.source.id, itemID: $0)]
        }
        let item = detail.item.type == .episode ? parent ?? detail.item : detail.item
        
        let episodeArtwork: AppleCatalogItem? = detail.item.type == .episode ? parent.map { parent in
            if detail.session.kind == .plex,
               let plex = plexIndex[.init(sourceID: detail.source.id, itemID: parent.id)] {
                return catalogItem(plex, source: detail.source, session: detail.session)
            }
            return catalogItem(parent, source: detail.source, session: detail.session)
        } : nil

        let posterURL: URL? = {
            if let episodeArtwork { return episodeArtwork.posterURL }
            if let tag = item.primaryImageTag {
                return try? client.imageURL(session: detail.session, itemID: item.id, type: .primary, tag: tag, maxWidth: 600)
            }
            return nil
        }()
        let backdropURL: URL? = {
            if let episodeArtwork { return episodeArtwork.backgroundURL }
            if let tag = item.backdropImageTags.first {
                return try? client.imageURL(session: detail.session, itemID: item.id, type: .backdrop, tag: tag, maxWidth: AppleArtworkSizePolicy.backdropMaximumWidth)
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
        let credits = credits(for: item, session: detail.session)
        
        return AppleTMDBDetails(
            mediaID: AppleMediaServerItemReference(sourceID: detail.source.id, itemID: item.id).mediaID,
            mediaType: mappedType,
            title: item.name,
            releaseInfo: item.year.map { String($0) },
            runtimeMinutes: runtimeMinutes,
            contentRating: item.officialRating,
            genres: item.genres,
            cast: item.people.filter { $0.type == "Actor" }.prefix(10).map(\.name),
            director: item.people.first { $0.type == "Director" }?.name,
            writers: item.people.filter { $0.type == "Writer" }.prefix(4).map(\.name),
            imdbRating: item.communityRating,
            year: item.year,
            tagline: item.tagline,
            overview: item.overview,
            posterURL: posterURL,
            backdropURL: backdropURL,
            logoURL: logoURL,
            trailerYouTubeKeys: item.remoteTrailers.compactMap { Self.youTubeKey($0.url) },
            castMembers: credits
        )
    }

    /// The server's people as Cast & Crew: actors with their characters,
    /// then directors and writers, each with the server's portrait. Someone
    /// listed more than once appears once, with every role ("Director, Writer").
    nonisolated func credits(for item: AppleMediaServerItem, session: AppleMediaServerSession) -> [AppleCreditPerson] {
        let actors = item.people.filter { $0.type == "Actor" || $0.type == "GuestStar" }.prefix(15).map { ($0, $0.role) }
        let directors = item.people.filter { $0.type == "Director" }.prefix(2).map { ($0, "Director" as String?) }
        let writers = item.people.filter { $0.type == "Writer" }.prefix(2).map { ($0, "Writer" as String?) }
        var order: [String] = []
        var roles: [String: (person: AppleMediaServerItem.Person, roles: [String])] = [:]
        for (person, role) in actors + directors + writers {
            let key = person.id ?? person.name.lowercased()
            if roles[key] == nil { order.append(key); roles[key] = (person, []) }
            if let role, roles[key]?.roles.contains(role) == false { roles[key]?.roles.append(role) }
        }
        return order.compactMap { roles[$0] }.map { person, roles in
            let portrait = person.id.flatMap { id in
                person.primaryImageTag.flatMap {
                    try? client.imageURL(session: session, itemID: id, type: .primary, tag: $0, maxWidth: 400)
                }
            }
            return AppleCreditPerson(name: person.name, role: roles.isEmpty ? nil : roles.joined(separator: ", "), portraitURL: portrait)
        }
    }

    /// The video id of a YouTube trailer link (`watch?v=`, `youtu.be/`, `embed/`).
    nonisolated static func youTubeKey(_ link: String) -> String? {
        guard let components = URLComponents(string: link), let host = components.host?.lowercased() else { return nil }
        if host == "youtu.be" { return components.path.split(separator: "/").first.map(String.init) }
        guard host == "youtube.com" || host.hasSuffix(".youtube.com") || host == "youtube-nocookie.com"
            || host.hasSuffix(".youtube-nocookie.com") else { return nil }
        if let key = components.queryItems?.first(where: { $0.name == "v" })?.value { return key }
        let parts = components.path.split(separator: "/")
        guard parts.count == 2, ["embed", "shorts", "v"].contains(parts[0]) else { return nil }
        return String(parts[1])
    }

    public func episodes(from detail: AppleMediaServerDetail) -> [AppleMediaEpisode] {
        var results: [AppleMediaEpisode] = []
        for season in detail.seasons {
            if let eps = detail.episodesBySeason[season.id] {
                for ep in eps where Self.isEligible(ep) {
                    let thumbURL: URL? = {
                        if let tag = ep.primaryImageTag {
                            return try? client.imageURL(session: detail.session, itemID: ep.id, type: .primary, tag: tag, maxWidth: 600)
                        }
                        return nil
                    }()
                    
                    results.append(AppleMediaEpisode(
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

enum AppleMediaServerTitleCount {
    /// Titles indexed from rows, plus each library's titles the server
    /// reported (`TotalRecordCount`) that no row has loaded yet.
    static func titles(indexed: Int, libraries: [(total: Int, loaded: Int)]) -> Int {
        indexed + libraries.reduce(0) { $0 + max(0, $1.total - $1.loaded) }
    }
}
