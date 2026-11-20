import Foundation
import Observation
import Testing
@testable import OpenStreamApple

@MainActor @Test(arguments: [
    "Example.Film.2020.mkv", "Shows/Example/Season 1/Example.S01E02.Pilot.mkv",
    "Amélie (2001)/Amélie (2001).mp4", "Movie/disc.iso", "Extras/Behind the Scenes.mkv"
])
func libraryPlaybackLookupKeepsPersistedRecordIdentity(relativePath: String) throws {
    let source = AppleSource(id: UUID(), kind: .nas, name: "Fixture",
        url: try #require(URL(string: "smb://fixture.example/Media")), isEnabled: true)
    let item = AppleLibraryItem(sourceID: source.id, name: URL(fileURLWithPath: relativePath).lastPathComponent,
        url: URL(fileURLWithPath: "/fixture/" + relativePath), relativePath: relativePath, sizeBytes: 1)
    let library = AppleLocalLibraryStore(sources: [source])
    let persistedID = AppleMediaIngestion.libraryRecord(source: source, item: item).id
    #expect(library.playbackID(item) == persistedID)
    let offline = AppleLocalLibraryStore(sources: [source], offlineIDs: [item.id: "fixture-offline-id"])
    #expect(offline.playbackID(item) == "fixture-offline-id")
    #expect(AppleLocalLibraryStore().playbackID(item) == item.id)
}

/// Build 20 B5: a share the first scan could not reach (the Local Network
/// prompt was still up) is scanned again on a widening schedule that ends;
/// a scan that reached every share schedules nothing.
@Test func unreachableShareIsScannedAgainOnAWideningScheduleThatEnds() {
    let delays = (0 ..< 8).compactMap { AppleLibraryShareRetryPolicy.delay(unreachableShares: 1, attempt: $0) }
    #expect(delays == [.seconds(3), .seconds(10), .seconds(30), .seconds(60), .seconds(120)])
    #expect(AppleLibraryShareRetryPolicy.delay(unreachableShares: 2, attempt: 0) == .seconds(3))
    #expect(AppleLibraryShareRetryPolicy.delay(unreachableShares: 0, attempt: 0) == nil)
    #expect(AppleLibraryShareRetryPolicy.delay(unreachableShares: 1, attempt: -1) == nil)
}

/// Build 20 B5 at the store: a share that does not answer reads as
/// unreachable and is scanned again without the loading spinner or a launch
/// scan stamp; a clean scan starts the count over, Refresh and Reset drop a
/// pending retry, and a share that answers with an error is not retried.
@MainActor @Test(.timeLimit(.minutes(1)))
func unreachableShareIsScannedAgainQuietlyUntilAScanReachesIt() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let suite = "library-share-retry-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let sourceStore = AppleSourceStore(defaults: defaults, keychain: SortObservationCredentialStub(),
        documentsDirectory: root.appendingPathComponent("documents"))
    let settings = AppleSettingsStore(defaults: defaults, keychain: SortObservationCredentialStub())
    _ = try sourceStore.addNetworkShare(name: "Home NAS", host: "192.0.2.10", share: "Media")
    let client = FlakyShareClient()
    let library = AppleLocalLibraryStore(
        resolver: AppleLibraryMetadataResolver(directory: root.appendingPathComponent("metadata")) { _, _, _ in nil },
        playbackStore: ApplePlaybackStore(defaults: defaults), versionCacheURL: root.appendingPathComponent("versions.json"),
        makeShareClient: { client }, shareRetryDelays: [.milliseconds(20), .milliseconds(20), .seconds(60)])
    await client.observeLoading { library.isLoading }
    let index = AppleMediaIndexStore(repository: AppleMediaIndexRepository(fileURL: root.appendingPathComponent("index.json")))
    func reload() async { await library.reload(sourceStore: sourceStore, mediaIndex: index, settings: settings) }
    let stampKey = "openstream.library.lastScan.v1"
    func digest() -> String {
        ApplePlaybackIdentity.digest(for: library.sources.map(\.id.uuidString).sorted().joined(separator: ","))
    }
    func stamp() -> TimeInterval? {
        (UserDefaults.standard.dictionary(forKey: stampKey) as? [String: TimeInterval])?[digest()]
    }

    await client.fail(with: .serverUnreachable)
    await reload()
    #expect(library.errorMessage == "Home NAS: Can't reach this share.")
    while await client.loadingAtEachScan.count < 3 { try await Task.sleep(for: .milliseconds(10)) }
    while library.shareRetryAttempt < 3 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(await client.loadingAtEachScan == [true, false, false])
    #expect(library.hasPendingShareRetry)
    #expect(stamp() == nil)

    await client.fail(with: nil)
    await reload()
    #expect(library.errorMessage == nil)
    #expect(!library.hasPendingShareRetry)
    #expect(library.shareRetryAttempt == 0)
    #expect(stamp() != nil)
    let stampedDigest = digest()
    defer {
        var stamps = UserDefaults.standard.dictionary(forKey: stampKey) ?? [:]
        stamps[stampedDigest] = nil
        UserDefaults.standard.set(stamps, forKey: stampKey)
    }

    await client.fail(with: .authenticationFailed)
    await reload()
    #expect(library.errorMessage == "Home NAS: \(AppleSMBError.authenticationFailed.localizedDescription)")
    #expect(!library.hasPendingShareRetry)

    await client.fail(with: .serverUnreachable)
    await library.retryUnreachableShares(sourceStore: sourceStore, mediaIndex: index, settings: settings)
    #expect(await client.loadingAtEachScan.count == 5, "becoming active rescans only after an unreachable share")
    await reload()
    await library.retryUnreachableShares(sourceStore: sourceStore, mediaIndex: index, settings: settings)
    let afterRefresh = await client.loadingAtEachScan.dropFirst(5)
    #expect(afterRefresh.first == true)
    #expect(afterRefresh.count >= 2 && afterRefresh.dropFirst().allSatisfy { !$0 }, "becoming active rescans an unreachable share quietly")
    while library.shareRetryAttempt < 3 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(library.hasPendingShareRetry)
    library.discardAfterReset()
    #expect(!library.hasPendingShareRetry)
    #expect(library.shareRetryAttempt == 0)
}

/// scan-1107: a rescan of a share whose titles are already on screen keeps
/// them as they are until the share is done (a test Apple TV NAS rescan regrouped
/// every ~70 ms for 30 s); a first scan shows titles at most once a second.
@MainActor @Test(.timeLimit(.minutes(1)), arguments: [true, false])
func shareScanRedrawsTitlesAtMostOncePerSecond(alreadyShown: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let suite = "library-scan-progress-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let persists = AppleLocalLibraryStore.persistsScanResults
    AppleLocalLibraryStore.persistsScanResults = false
    defer { AppleLocalLibraryStore.persistsScanResults = persists }
    let sourceStore = AppleSourceStore(defaults: defaults, keychain: SortObservationCredentialStub(),
        documentsDirectory: root.appendingPathComponent("documents"))
    let settings = AppleSettingsStore(defaults: defaults, keychain: SortObservationCredentialStub())
    _ = try sourceStore.addNetworkShare(name: "Home NAS", host: "192.0.2.10", share: "Media")
    let source = try #require(sourceStore.sources.first)
    let titles = ["Arrival.2016.mkv", "Dune.2021.mkv", "Heat.1995.mkv", "Alien.1979.mkv", "Ronin.1998.mkv", "Tenet.2020.mkv"]
    let persisted = AppleLibraryItem(sourceID: source.id, name: titles[0],
        url: try AppleSMBEndpointPolicy.makeURL(host: "192.0.2.10", port: 445, share: "Media", path: "F0/" + titles[0]),
        relativePath: "F0/" + titles[0], sizeBytes: 1)
    let client = FolderPerTitleShareClient(titles: titles)
    let library = AppleLocalLibraryStore(
        resolver: AppleLibraryMetadataResolver(directory: root.appendingPathComponent("metadata")) { _, _, _ in nil },
        playbackStore: ApplePlaybackStore(defaults: defaults),
        groups: alreadyShown ? AppleLibrarySeries.groups([persisted]) : [],
        versionCacheURL: root.appendingPathComponent("versions.json"), makeShareClient: { client })
    await client.observe { Set(library.groups.flatMap(\.items).map(\.name)) }
    let index = AppleMediaIndexStore(repository: AppleMediaIndexRepository(fileURL: root.appendingPathComponent("index.json")))
    await library.reload(sourceStore: sourceStore, mediaIndex: index, settings: settings)

    // Folders load four at a time, so F4 and F5 are listed after F0...F3 reported their files.
    let shownWhileListing = await client.shownAtEachListing
    #expect(shownWhileListing["/Media/F4"] == [titles[0]], "only the first progress (or the persisted index) is on screen")
    #expect(shownWhileListing["/Media/F5"] == [titles[0]])
    #expect(Set(library.groups.flatMap(\.items).map(\.name)) == Set(titles))
}

private actor FolderPerTitleShareClient: AppleNetworkShareClient {
    let titles: [String]
    private var shown: (@MainActor @Sendable () -> Set<String>)?
    private(set) var shownAtEachListing: [String: Set<String>] = [:]

    init(titles: [String]) { self.titles = titles }
    func observe(_ shown: @escaping @MainActor @Sendable () -> Set<String>) { self.shown = shown }

    func listShares(host: String, port: Int, credentials: AppleSMBCredentials) async throws -> [AppleSMBShare] { [] }
    func listDirectory(url: URL, credentials: AppleSMBCredentials, recursive: Bool) async throws -> [AppleSMBDirectoryEntry] {
        if let shown { shownAtEachListing[url.path] = await shown() }
        if url.path == "/Media" {
            return titles.indices.map { AppleSMBDirectoryEntry(name: "F\($0)", path: "F\($0)", isDirectory: true) }
        }
        guard let folder = url.path.split(separator: "/").last, let i = Int(folder.dropFirst()) else { return [] }
        return [AppleSMBDirectoryEntry(name: titles[i], path: "F\(i)/" + titles[i], isDirectory: false, sizeBytes: 1)]
    }
    func read(url: URL, credentials: AppleSMBCredentials, range: Range<UInt64>) async throws -> Data { Data() }
}

private actor FlakyShareClient: AppleNetworkShareClient {
    private var failure: AppleSMBError?
    private var isLoading: (@MainActor @Sendable () -> Bool)?
    private(set) var loadingAtEachScan: [Bool] = []

    func fail(with failure: AppleSMBError?) { self.failure = failure }
    func observeLoading(_ isLoading: @escaping @MainActor @Sendable () -> Bool) { self.isLoading = isLoading }

    func listShares(host: String, port: Int, credentials: AppleSMBCredentials) async throws -> [AppleSMBShare] { [] }
    func listDirectory(url: URL, credentials: AppleSMBCredentials, recursive: Bool) async throws -> [AppleSMBDirectoryEntry] {
        if let isLoading { loadingAtEachScan.append(await isLoading()) }
        if let failure { throw failure }
        return []
    }
    func read(url: URL, credentials: AppleSMBCredentials, range: Range<UInt64>) async throws -> Data { Data() }
}

@MainActor @Test func localTitleMatchingPrefersIMDbAndDistinguishesRemakes() {
    let movie = AppleCatalogItem(mediaID: "tt1160419", type: "movie", name: "Dune", releaseInfo: "2021")
    #expect(AppleLocalLibraryStore.matches(movie, .init(mediaID: "tt1160419", type: "movie", name: "Dune: Part One", releaseInfo: "2021")))
    #expect(!AppleLocalLibraryStore.matches(movie, .init(mediaID: "tt0087182", type: "movie", name: "Dune", releaseInfo: "1984")))
    #expect(AppleLocalLibraryStore.matches(movie, .init(mediaID: "local-file", type: "movie", name: "DÚNE", releaseInfo: "2021–")))
    #expect(!AppleLocalLibraryStore.matches(movie, .init(mediaID: "local-file", type: "movie", name: "Dune", releaseInfo: "1984")))
    #expect(!AppleLocalLibraryStore.matches(movie, .init(mediaID: "local-file", type: "series", name: "Dune", releaseInfo: "2021")))
}

@MainActor @Test func indexedGroupMatchingAnswersLikeMatchingEveryGroup() {
    let source = UUID()
    let files = ["Dune.2021.2160p.mkv", "Dune (1984).mkv", "DÚNE 2021 1080p.mkv", "Show.S01E01.mkv", "Arrival.2016.mkv"].map {
        AppleLibraryItem(sourceID: source, name: $0, url: URL(fileURLWithPath: "/" + $0), relativePath: $0, sizeBytes: 1)
    }
    let store = AppleLocalLibraryStore(groups: AppleLibrarySeries.groups(files), sources: [])
    let queries: [AppleCatalogItem] = [
        .init(mediaID: "tt1160419", type: "movie", name: "Dune", releaseInfo: "2021"),
        .init(mediaID: "local-x", type: "movie", name: "dune", releaseInfo: "1984"),
        .init(mediaID: "tt0087182", type: "series", name: "Dune", releaseInfo: "1984"),
        .init(mediaID: "tt123", type: "series", name: "Show"),
        .init(mediaID: "tt2543164", type: "movie", name: "Arrival", releaseInfo: "2016–"),
        .init(mediaID: "tt0000000", type: "movie", name: "Nothing Here", releaseInfo: "2001"),
    ]
    for query in queries {
        let expected = store.groups.filter { AppleLocalLibraryStore.matches(store.catalogItem(for: $0), query) }
        #expect(store.matchingGroups(query).map(\.id) == expected.map(\.id), "\(query.name) \(query.releaseInfo ?? "")")
    }
    #expect(!store.matchingGroups(queries[0]).isEmpty)
}

@MainActor @Test(arguments: [true, false])
func matchingGroupsKeepsItsSnapshotUntilTheNewRevisionIsPublished(hasIMDb: Bool) throws {
    let file = AppleLibraryItem(sourceID: UUID(), name: "Example.Film.2020.mkv",
        url: URL(fileURLWithPath: "/Example.Film.2020.mkv"), relativePath: "Example.Film.2020.mkv", sizeBytes: 1)
    let groups = AppleLibrarySeries.groups([file])
    let store = AppleLocalLibraryStore(groups: groups)
    let query = AppleCatalogItem(mediaID: hasIMDb ? "tt1234567" : "fixture", type: "movie", name: "Example Film", releaseInfo: "2020")
    let original = store.matchingGroups(query)
    _ = try #require(original.first)
    let observed = SortObservationChangeFlag()
    withObservationTracking {
        _ = store.contentRevision
    } onChange: {
        // Observation invokes this synchronously from the MainActor reset below.
        MainActor.assumeIsolated {
            #expect(store.matchingGroups(query).map(\.id) == original.map(\.id))
            observed.changed = true
        }
    }
    store.discardAfterReset()
    #expect(observed.changed)
    #expect(store.matchingGroups(query).isEmpty)
}

@MainActor @Test func localSeasonRowsKeepUncatalogedEpisodesAndDeduplicateCopies() {
    let source = UUID()
    let files = ["Show.S01E01.1080p.mkv", "Show.S01E01.2160p.mkv", "Show.S02E03.1080p.mkv"].map {
        AppleLibraryItem(sourceID: source, name: $0, url: URL(fileURLWithPath: "/" + $0), relativePath: $0, sizeBytes: 1)
    }
    let group = AppleLibrarySeries.groups(files)[0]
    let enriched = AppleMediaEpisode(id: "tt123:1:1", title: "Pilot", season: 1, episode: 1, overview: "Overview")
    let episodes = AppleLocalLibraryStore.episodes(group: group, mediaID: "tt123", enriched: [enriched])
    #expect(episodes.count == 2)
    #expect(episodes[0] == enriched)
    #expect(episodes[1].season == 2)
    #expect(episodes[1].episode == 3)
    #expect(AppleLocalLibraryStore.format(files[0]) == "1080P · MKV")
    let store = AppleLocalLibraryStore()
    let selected = store.localFiles(for: .init(mediaID: "tt123", type: "series", name: "Show"), group: group, episode: episodes[0])
    #expect(selected.count == 2)
    #expect(selected.first?.name == "Show.S01E01.2160p.mkv")
    #expect(store.localFiles(for: .init(mediaID: "tt123", type: "series", name: "Show"), group: group, episode: episodes[1]).count == 1)
}

@MainActor @Test func localUnnumberedEpisodePlaysTheFileShownByItsRow() {
    let file = AppleLibraryItem(sourceID: UUID(), name: "Pilot.mkv", url: URL(fileURLWithPath: "/Pilot.mkv"),
        relativePath: "Shows/Example/Season 1/Pilot.mkv", sizeBytes: 1)
    let group = AppleLibrarySeries.groups([file])[0]
    let episodes = AppleLocalLibraryStore.episodes(group: group, mediaID: "local-example", enriched: [])
    let files = AppleLocalLibraryStore().localFiles(for: .init(mediaID: "local-example", type: "series", name: "Example"),
        group: group, episode: episodes[0])
    #expect(files == [file])
}

@MainActor @Test func localSeriesResumesLatestUnfinishedEpisodeAcrossSeasons() {
    let source = UUID()
    let files = ["Example.S01E01.mkv", "Example.S02E03.mkv", "Example.S02E04.mkv"].map {
        AppleLibraryItem(sourceID: source, name: $0, url: URL(fileURLWithPath: "/" + $0), relativePath: $0, sizeBytes: 1)
    }
    let groups = AppleLibrarySeries.groups(files)
    let episodes = AppleLocalLibraryStore.episodes(group: groups[0], mediaID: "tt-example", enriched: [])
    let resumed = AppleLocalLibraryStore.resumeEpisode(in: groups, episodes: episodes) { file in
        let number = files.firstIndex(of: file)!
        return ApplePlaybackProgress(position: number == 2 ? 1000 : 120, duration: 1000,
            updatedAt: Date(timeIntervalSince1970: Double(number + 1)))
    }
    #expect(resumed?.season == 2)
    #expect(resumed?.episode == 3)
}

/// Library shelves read nothing but `sorted(...)` in their body. Once the
/// sort is memoised, the cached answer must still register `groups` and
/// `metadata`, or a title's metadata landing never redraws the shelf.
@MainActor @Test(.timeLimit(.minutes(1))) func memoisedLibrarySortStillObservesTheLibrary() async throws {
    let file = AppleLibraryItem(sourceID: UUID(), name: "Example.Film.2020.mkv",
        url: URL(fileURLWithPath: "/Example.Film.2020.mkv"), relativePath: "Example.Film.2020.mkv", sizeBytes: 1)
    let group = AppleLibrarySeries.groups([file])[0]
    // `resolve` goes through the shared resolver, whose disk cache answers
    // before any lookup; seed it so the metadata update needs no network.
    let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("LibraryTitles-v1").appendingPathComponent(file.sourceID.uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let item = AppleCatalogItem(mediaID: "tt0000001", type: "movie", name: "Example Film", releaseInfo: "2020")
    try JSONEncoder().encode(SeededMetadataEntry(value: item, checkedAt: Date(), addedAt: Date(), schema: 3))
        .write(to: folder.appendingPathComponent(AppleLibraryMetadataResolver.cacheKey(file) + ".json"))
    let suite = "memoised-sort-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let sourceStore = AppleSourceStore(defaults: defaults, keychain: SortObservationCredentialStub(),
        documentsDirectory: FileManager.default.temporaryDirectory.appending(path: suite))
    let settings = AppleSettingsStore(defaults: defaults, keychain: SortObservationCredentialStub())

    let store = AppleLocalLibraryStore()
    _ = store.sorted(.title)
    let flag = SortObservationChangeFlag()
    withObservationTracking {
        _ = store.sorted(.title)
    } onChange: {
        Task { @MainActor in flag.changed = true }
    }
    await store.resolve(group, sourceStore: sourceStore, settings: settings)
    #expect(store.metadata[group.id] == item)
    while !flag.changed { try await Task.sleep(for: .milliseconds(10)) }
    #expect(flag.changed)
}

private struct SeededMetadataEntry: Encodable {
    let value: AppleCatalogItem?
    let checkedAt: Date
    let addedAt: Date
    let schema: Int
}

private struct SortObservationCredentialStub: AppleCredentialStoring {
    func string(for account: String) throws -> String? { nil }
    func set(_ value: String, for account: String) throws {}
    func remove(_ account: String) throws {}
}

@MainActor
private final class SortObservationChangeFlag {
    var changed = false
}

@MainActor @Test func unnumberedLocalEpisodesReadLegacyWatchedWithoutRewritingHistory() throws {
    let suite = "local-legacy-watched-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = ApplePlaybackStore(defaults: defaults)
    let source = UUID()
    let files = ["Pilot.mkv", "Finale.mkv"].map {
        AppleLibraryItem(sourceID: source, name: $0, url: URL(fileURLWithPath: "/" + $0),
            relativePath: "Shows/Example/Season 1/" + $0, sizeBytes: 1)
    }
    var group = try #require(AppleLibrarySeries.groups([files[0]]).first)
    group.items = files
    let episodes = AppleLocalLibraryStore.episodes(group: group, mediaID: "tt-example", enriched: [])
    let watchedAt = Date(timeIntervalSince1970: 100)
    store.markWatched(mediaID: "tt-example:1:1", at: watchedAt)
    let originalHistory = store.configurationWatchedHistory()
    let completed = AppleLocalLibraryStore.completedEpisodeIDs(episodes, group: group, mediaID: "tt-example", store: store)
    #expect(completed == [episodes[0].id])
    #expect(episodes[0].id == AppleLocalLibraryStore.fileEpisodeID(files[0]))
    #expect(AppleLocalLibraryStore.nextFilenameEpisode(in: episodes, completedIDs: completed)?.id == episodes[1].id)
    #expect(store.configurationWatchedHistory() == originalHistory)
    #expect(store.configurationWatchedHistory()[episodes[0].id] == nil)
    store.markUnwatched(mediaID: episodes[0].id, at: watchedAt.addingTimeInterval(1))
    #expect(AppleLocalLibraryStore.completedEpisodeIDs(episodes, group: group, mediaID: "tt-example", store: store).isEmpty)
    let legacyKey = try #require(ApplePlaybackIdentity.storageKey(for: "tt-example:1:1"))
    #expect(store.configurationWatchedHistory()[legacyKey] == watchedAt)
    store.markWatched(mediaID: episodes[0].id, at: watchedAt.addingTimeInterval(2))
    #expect(AppleLocalLibraryStore.completedEpisodeIDs(episodes, group: group, mediaID: "tt-example", store: store) == [episodes[0].id])
}

@MainActor @Test func legacyUnwatchedLocalEpisodeDoesNotRegainItsTick() throws {
    let suite = "local-legacy-reset-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = ApplePlaybackStore(defaults: defaults)
    let file = AppleLibraryItem(sourceID: UUID(), name: "Pilot.mkv", url: URL(fileURLWithPath: "/Pilot.mkv"),
        relativePath: "Shows/Example/Season 1/Pilot.mkv", sizeBytes: 1)
    let group = try #require(AppleLibrarySeries.groups([file]).first)
    let episodes = AppleLocalLibraryStore.episodes(group: group, mediaID: "tt-example", enriched: [])
    store.markWatched(mediaID: "tt-example:1:1", at: Date(timeIntervalSince1970: 100))
    store.markUnwatched(mediaID: "tt-example:1:1", at: Date(timeIntervalSince1970: 101))
    #expect(AppleLocalLibraryStore.completedEpisodeIDs(episodes, group: group, mediaID: "tt-example", store: store).isEmpty)
}

@MainActor @Test func filenameAliasDoesNotBorrowDeduplicatedNumberedEpisodeHistory() throws {
    let suite = "local-legacy-dedup-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = ApplePlaybackStore(defaults: defaults)
    let source = UUID()
    let numbered = AppleLibraryItem(sourceID: source, name: "Example.S01E02.mkv", url: URL(fileURLWithPath: "/Example.S01E02.mkv"),
        relativePath: "Shows/Example/Season 1/Example.S01E02.mkv", sizeBytes: 1)
    let filename = AppleLibraryItem(sourceID: source, name: "Pilot.mkv", url: URL(fileURLWithPath: "/Pilot.mkv"),
        relativePath: "Shows/Example/Season 1/Pilot.mkv", sizeBytes: 1)
    var group = try #require(AppleLibrarySeries.groups([numbered]).first)
    group.items = [numbered, filename]
    let episodes = AppleLocalLibraryStore.episodes(group: group, mediaID: "tt-example", enriched: [])
    store.markWatched(mediaID: "tt-example:1:2", at: Date(timeIntervalSince1970: 100))
    let completed = AppleLocalLibraryStore.completedEpisodeIDs(episodes, group: group, mediaID: "tt-example", store: store)
    #expect(completed == ["tt-example:1:2"])
    #expect(completed.contains(AppleLocalLibraryStore.fileEpisodeID(filename)) == false)
}

@MainActor @Test(.timeLimit(.minutes(1)))
func cancelledLibraryReloadAllowsWaitingReloadWithNewestSources() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let firstFolder = root.appendingPathComponent("first")
    let newestFolder = root.appendingPathComponent("newest")
    for folder in [firstFolder, newestFolder] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: folder.appendingPathComponent(folder.lastPathComponent + ".2020.mkv"))
    }
    let suite = "library-reload-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let sourceStore = AppleSourceStore(defaults: defaults, keychain: SortObservationCredentialStub(),
        documentsDirectory: root.appendingPathComponent("documents"))
    let settings = AppleSettingsStore(defaults: defaults, keychain: SortObservationCredentialStub())
    let firstSource = try sourceStore.addLibraryFolder(name: "First", url: firstFolder, bookmarkData: nil)
    let probe = LibraryReloadMatchProbe()
    let resolver = AppleLibraryMetadataResolver(directory: root.appendingPathComponent("metadata")) { title, _, _ in
        await probe.lookup(title.title)
    }
    let library = AppleLocalLibraryStore(resolver: resolver, playbackStore: ApplePlaybackStore(defaults: defaults),
        versionCacheURL: root.appendingPathComponent("versions.json"))
    let index = AppleMediaIndexStore(repository: AppleMediaIndexRepository(fileURL: root.appendingPathComponent("index.json")))
    let first = Task { await library.reload(sourceStore: sourceStore, mediaIndex: index, settings: settings) }
    await probe.waitUntilStarted()
    #expect(library.isLoading)
    let newestSource = try sourceStore.addLibraryFolder(name: "Newest", url: newestFolder, bookmarkData: nil)
    let started = AsyncStream<Void>.makeStream()
    var secondFinished = false
    let second = Task {
        started.continuation.yield(())
        await library.reload(sourceStore: sourceStore, mediaIndex: index, settings: settings)
        secondFinished = true
    }
    var iterator = started.stream.makeAsyncIterator()
    _ = await iterator.next()
    #expect(!secondFinished)
    first.cancel()
    await first.value
    await probe.finish()
    await second.value
    #expect(!library.isLoading)
    #expect(Set(library.groups.flatMap(\.items).map(\.sourceID).filter { $0 != AppleLocalLibraryStore.downloadsID }) == [firstSource.id, newestSource.id])
    #expect(Set(library.sources.map(\.id).filter { $0 != AppleLocalLibraryStore.downloadsID }) == [firstSource.id, newestSource.id])
    #expect(index.records.contains { $0.title.localizedCaseInsensitiveContains("newest") })
}

private actor LibraryReloadMatchProbe {
    private var calls = 0
    private var started: CheckedContinuation<Void, Never>?
    private var response: CheckedContinuation<Void, Never>?

    func lookup(_ title: String) async -> AppleCatalogItem? {
        calls += 1
        if calls == 1 {
            await withCheckedContinuation { continuation in
                response = continuation
                started?.resume()
                started = nil
            }
        }
        return AppleCatalogItem(mediaID: "local-" + title, type: "movie", name: title)
    }

    func waitUntilStarted() async {
        if calls > 0 { return }
        await withCheckedContinuation { started = $0 }
    }

    func finish() {
        response?.resume()
        response = nil
    }
}

@MainActor @Test func refusedShareFailsBeforeProbingOrConstructingThePlayer() async throws {
    let suite = "share-playback-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let source = AppleSource(kind: .nas, name: "Fixture", url: try #require(URL(string: "smb://fixture.example/Media")))
    let file = AppleLibraryItem(sourceID: source.id, name: "Movie.2020.mkv",
        url: source.url.appendingPathComponent("Movie.2020.mkv"), relativePath: "Movie.2020.mkv", sizeBytes: 1024)
    let library = AppleLocalLibraryStore(groups: AppleLibrarySeries.groups([file]), sources: [source],
        makeShareClient: { RefusedPlaybackShareClient() })
    let sources = AppleSourceStore(defaults: defaults, keychain: SortObservationCredentialStub())
    let settings = AppleSettingsStore(defaults: defaults, keychain: SortObservationCredentialStub())
    await #expect(throws: AppleSMBError.accessDenied) {
        try await library.presentation(for: file, sourceStore: sources, settings: settings)
    }
}

private struct RefusedPlaybackShareClient: AppleNetworkShareClient {
    func listShares(host: String, port: Int, credentials: AppleSMBCredentials) async throws -> [AppleSMBShare] { [] }
    func listDirectory(url: URL, credentials: AppleSMBCredentials, recursive: Bool) async throws -> [AppleSMBDirectoryEntry] { [] }
    func read(url: URL, credentials: AppleSMBCredentials, range: Range<UInt64>) async throws -> Data { throw AppleSMBError.accessDenied }
    func fileSize(url: URL, credentials: AppleSMBCredentials) async throws -> UInt64? { throw AppleSMBError.accessDenied }
}

@MainActor @Test
func libraryProgressRefreshReadsCurrentPlaybackStateOnEveryReturn() throws {
    let suite = "library-progress-refresh-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = AppleSource(id: UUID(), kind: .library, name: "Fixture", url: URL(fileURLWithPath: "/fixture"), isEnabled: true)
    let file = AppleLibraryItem(sourceID: source.id, name: "Fixture.2020.mkv",
        url: URL(fileURLWithPath: "/fixture/Fixture.2020.mkv"), relativePath: "Fixture.2020.mkv", sizeBytes: 1)
    let group = AppleLibrarySeries(id: "fixture-group", parsed: AppleLibraryTitleParser.parse(file), items: [file])
    let store = ApplePlaybackStore(defaults: defaults, blobDirectory: root)
    let library = AppleLocalLibraryStore(playbackStore: store, groups: [group], sources: [source])
    let mediaID = library.playbackID(file)
    store.save(mediaID: mediaID, position: 90, duration: 600)
    library.refreshProgress()
    #expect(library.progress[group.id]?.position == 90)
    store.save(mediaID: mediaID, position: 180, duration: 600)
    library.refreshProgress()
    #expect(library.progress[group.id]?.position == 180)
    store.markWatched(mediaID: mediaID)
    library.refreshProgress()
    #expect(library.progress[group.id] == nil)
}

@MainActor @Test
func libraryProgressRefreshUsesOfflineIdentitiesAndSkipsNonresumableFiles() throws {
    let suite = "library-progress-offline-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = AppleSource(id: UUID(), kind: .library, name: "Fixture", url: URL(fileURLWithPath: "/fixture"), isEnabled: true)
    func file(_ name: String) -> AppleLibraryItem {
        AppleLibraryItem(sourceID: source.id, name: name, url: URL(fileURLWithPath: "/fixture/" + name),
            relativePath: name, sizeBytes: 1)
    }
    let first = file("Fixture.2020.mkv"), second = file("Fixture.2020.4K.mkv")
    let group = AppleLibrarySeries(id: "fixture-group", parsed: AppleLibraryTitleParser.parse(first), items: [first, second])
    let store = ApplePlaybackStore(defaults: defaults, blobDirectory: root)
    let library = AppleLocalLibraryStore(playbackStore: store, groups: [group], sources: [source],
        offlineIDs: [first.id: "fixture-offline-first", second.id: "fixture-offline-second"])
    store.save(mediaID: "fixture-offline-first", position: 90, duration: 600)
    store.save(mediaID: "fixture-offline-second", position: 5, duration: 600)
    library.refreshProgress()
    #expect(library.progress[group.id]?.position == 90)
    store.save(mediaID: "fixture-offline-second", position: 240, duration: 600)
    library.refreshProgress()
    #expect(library.progress[group.id]?.position == 240)
}
