import Foundation
import Testing
@testable import OpenStreamApple

private struct AliasCredentialStub: AppleCredentialStoring {
    func string(for account: String) throws -> String? { nil }
    func set(_ value: String, for account: String) throws {}
    func remove(_ account: String) throws {}
}

private struct AliasShareClient: AppleNetworkShareClient {
    func listShares(host: String, port: Int, credentials: AppleSMBCredentials) async throws -> [AppleSMBShare] { [] }
    func listDirectory(url: URL, credentials: AppleSMBCredentials, recursive: Bool) async throws -> [AppleSMBDirectoryEntry] { [] }
    func read(url: URL, credentials: AppleSMBCredentials, range: Range<UInt64>) async throws -> Data { throw AppleSMBError.notFound }
    func fileSize(url: URL, credentials: AppleSMBCredentials) async throws -> UInt64? { nil }
}

@MainActor private struct LocalAliasFixture {
    let defaults: UserDefaults
    let root: URL
    let resolver: AppleLibraryMetadataResolver
    let playback: ApplePlaybackStore
    let source: AppleSource
    let sources: AppleSourceStore
    let settings: AppleSettingsStore
    var blobDirectory: URL { root.appendingPathComponent("Playback") }

    static func run(kind: AppleSourceKind = .library, lookup: @escaping AppleLibraryMetadataResolver.Lookup = { _, _, _ in nil },
                    _ body: (Self) async throws -> Void) async throws {
        let suite = "local-alias-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let resolver = AppleLibraryMetadataResolver(directory: root.appendingPathComponent("Titles"),
            matchDirectory: root.appendingPathComponent("Matches"), lookup: lookup)
        let playback = ApplePlaybackStore(defaults: defaults, blobDirectory: root.appendingPathComponent("Playback"))
        let sourceURL = kind == .nas ? try #require(URL(string: "smb://fixture.example/Media")) : root.appendingPathComponent("Media")
        let source = AppleSource(kind: kind, name: "Fixture", url: sourceURL)
        let sources = AppleSourceStore(defaults: defaults, keychain: AliasCredentialStub(), documentsDirectory: root)
        let settings = AppleSettingsStore(defaults: defaults, keychain: AliasCredentialStub())
        try await body(Self(defaults: defaults, root: root, resolver: resolver, playback: playback,
            source: source, sources: sources, settings: settings))
    }

    func file(_ path: String, size: Int64 = 734003200) -> AppleLibraryItem {
        AppleLibraryItem(sourceID: source.id, name: URL(fileURLWithPath: path).lastPathComponent,
            url: source.url.appendingPathComponent(path), relativePath: path, sizeBytes: size)
    }
    func store(_ files: [AppleLibraryItem], offlineIDs: [String: String] = [:]) -> AppleLocalLibraryStore {
        AppleLocalLibraryStore(resolver: resolver, playbackStore: playback,
            groups: AppleLibrarySeries.groups(files), sources: [source], offlineIDs: offlineIDs,
            versionCacheURL: root.appendingPathComponent("MediaVersions-v1.json"), makeShareClient: { AliasShareClient() })
    }
    func table() throws -> AppleIdentityAliasTable {
        let data = AppleIdentityAliasStore(defaults: defaults, blobDirectory: blobDirectory).blobData
        return try data.map { try JSONDecoder().decode(AppleIdentityAliasTable.self, from: $0) } ?? .init()
    }
    func manual(_ file: AppleLibraryItem, kind: String = "series") async throws {
        try await resolver.correctMatch(for: file,
            candidate: AppleCatalogItem(mediaID: "tt0903747", type: kind, name: kind == "series" ? "Show" : "Film", releaseInfo: "2020"), provider: "fixture")
    }
    func resolveAll(_ store: AppleLocalLibraryStore) async {
        for group in store.groups { await store.resolve(group, sourceStore: sources, settings: settings) }
    }
}

@MainActor @Suite struct AppleLocalLibraryAliasTests {
    @Test func shelfMetadataResolutionRecordsIdentityAliasesWithoutAScan() async throws {
        try await LocalAliasFixture.run(lookup: { _, _, _ in
            AppleCatalogItem(mediaID: "tt0903747", type: "series", name: "Show", releaseInfo: "2020")
        }) { f in
            let file = f.file("Shows/Show (2020)/Season 1/Show.2020.S01E01.mkv")
            let store = f.store([file])
            let before = try f.table()
            #expect(before.classes.isEmpty)
            await store.resolveMetadata(store.groups, tmdbKey: "fixture", omdbKey: "")
            let key = try #require(ApplePlaybackIdentity.storageKey(for: store.playbackID(file)))
            #expect(try f.table().classes["li:series:tt0903747:1:1:734003200"] == [key])
        }
    }

    @Test func emptySearchContentIdentityIgnoresContentRevisions() async throws {
        try await LocalAliasFixture.run { f in
            let index = AppleMediaIndexStore(repository: AppleMediaIndexRepository(fileURL: f.root.appendingPathComponent("index.json")))
            let view = AppleSearchView(sourceStore: f.sources, mediaIndex: index, router: AppleAppRouter(),
                settings: f.settings, openSettings: {})
            let revision = index.revision
            #expect(view.searchContentIdentity == nil)
            try await index.upsert(AppleMediaIngestion.libraryRecord(source: f.source, item: f.file("Fixture (2024).mkv")))
            #expect(index.revision != revision)
            #expect(view.searchContentIdentity == nil)
        }
    }

    @Test(arguments: ["", " \n "])
    func emptySearchTaskIdentityIgnoresContentRevisions(query: String) async {
        let search = AppleCatalogSearchStore(revisionDebounce: .zero)
        let identity = search.taskIdentity(query: query)
        await search.coalesceRevision("scan-finished")
        #expect(search.contentRevision == "scan-finished")
        #expect(search.taskIdentity(query: query) == identity)
        #expect(search.taskIdentity(query: query).contentRevision == nil)
    }

    @Test func repeatingASharedLinkChangesTheResolutionTaskRevision() {
        let router = AppleAppRouter()
        let link = AppleAppRoute.sharedLink(.imdb("tt2911666"))
        router.open(link)
        let revision = router.revision
        router.open(link)
        #expect(router.route == link)
        #expect(router.revision != revision)
    }

    @Test(arguments: [AppleSourceKind.library, .nas], ["72.HOURS.2024.mkv", "aabbccddeeff00112233445566778899.mkv"])
    func discoverContinuesTheLibraryTitleWithItsFileProgress(kind: AppleSourceKind, filename: String) async throws {
        try await LocalAliasFixture.run(kind: kind) { f in
            let file = f.file(filename)
            try await f.resolver.correctMatch(for: file,
                candidate: .init(mediaID: "tt0000072", type: "movie", name: "72 Hours",
                    posterURL: URL(string: "https://fixture.example/poster.jpg"), releaseInfo: "2024"), provider: "fixture")
            let library = f.store([file])
            await f.resolveAll(library)
            f.playback.save(mediaID: library.playbackID(file), position: 600, duration: 3600)
            let values = AppleDiscoverView.localContinueWatching(library: library, playbackStore: f.playback)
            let value = try #require(values.first)
            #expect(values.count == library.continueWatching.count)
            #expect(value.record.id == library.playbackID(file))
            #expect(value.record.title == "72 Hours")
            #expect(value.record.kind == .movie)
            #expect(value.item.name == "72 Hours")
            #expect(value.record.progress == 1.0 / 6)
            #expect(AppleDiscoverView.continueWatchingInfo(value, store: f.playback).progress == 1.0 / 6)
            #expect(value.item.posterURL == URL(string: "https://fixture.example/poster.jpg"))
            #expect(value.source.id == f.source.id)
            f.playback.removeFromContinueWatching(mediaID: library.playbackID(file))
            #expect(AppleDiscoverView.localContinueWatching(library: library, playbackStore: f.playback).isEmpty)
        }
    }

    @Test func discoverSearchUsesOneMetadataTitleAndKeepsItsFileRoute() async throws {
        try await LocalAliasFixture.run { f in
            let files = [f.file("JOHN.WICK.2014.1080p.mkv"), f.file("JOHN.WICK.2014.2160p.mkv")]
            let movie = AppleCatalogItem(mediaID: "tt2911666", type: "movie", name: "John Wick",
                posterURL: URL(string: "https://fixture.example/wick.jpg"), releaseInfo: "2014")
            for file in files { try await f.resolver.correctMatch(for: file, candidate: movie, provider: "fixture") }
            let library = f.store(files)
            await f.resolveAll(library)
            let staleTitle = AppleCatalogItem(mediaID: movie.mediaID, type: "movie", name: "JOHN WICK",
                posterURL: movie.posterURL, summary: "An older index entry.", releaseInfo: "2014")
            let indexed = AppleMediaIngestion.libraryRecords(source: f.source, items: files)
                + [AppleMediaIngestion.catalogRecord(instanceID: f.source.id, item: staleTitle)]
            let rows = AppleCatalogSearchStore.mergedResults(await library.searchRecords(indexed: indexed), matching: "wick", limit: 100)
            let row = try #require(rows.first)
            #expect(rows.count == 1)
            #expect(row.title == "John Wick")
            #expect(row.kind == .movie)
            #expect(row.artworkURL == movie.posterURL)
            let match = try #require(library.searchMatch(for: row))
            #expect(match.item == movie)
            #expect(match.source.id == f.source.id)
        }
    }

    @Test func discoverShowsFileProgressForAnUnmatchedLocalEpisode() async throws {
        try await LocalAliasFixture.run { f in
            let file = f.file("Shows/Show/Show.S01E02.mkv")
            let library = f.store([file])
            f.playback.save(mediaID: library.playbackID(file), position: 600, duration: 1800)
            let value = try #require(AppleDiscoverView.localContinueWatching(library: library, playbackStore: f.playback).first)
            let info = AppleDiscoverView.continueWatchingInfo(value, store: f.playback)
            #expect(info.progress == 1.0 / 3)
            #expect(info.subtitle == "S1 E2 · 20 min left")
        }
    }

    @Test func discoverSearchFindsMetadataNamesAndGroupsShowEpisodes() async throws {
        try await LocalAliasFixture.run { f in
            let files = [f.file("RELEASE.S01E01.mkv"), f.file("RELEASE.S01E02.mkv")]
            let show = AppleCatalogItem(mediaID: "tt0903747", type: "series", name: "Breaking Bad", releaseInfo: "2008")
            try await f.resolver.correctMatch(for: files[0], candidate: show, provider: "fixture")
            let library = f.store(files)
            await f.resolveAll(library)
            let rows = AppleCatalogSearchStore.mergedResults(
                await library.searchRecords(indexed: AppleMediaIngestion.libraryRecords(source: f.source, items: files)),
                matching: "breaking", limit: 100)
            #expect(rows.count == 1)
            #expect(rows.first?.kind == .series)
            #expect(rows.first.flatMap { library.searchMatch(for: $0) }?.item == show)
            let match = try #require(rows.first.flatMap { library.searchMatch(for: $0) })
            let group = try #require(library.groups.first { $0.id == match.localGroupID })
            #expect(group.id == library.groups.first?.id)
            #expect(AppleLocalLibraryStore.episodes(group: group, mediaID: match.item.mediaID, enriched: []).count == 2)
        }
    }

    @Test func abbottSearchOpensTheLibrarySeasonSixEpisodes() async throws {
        try await LocalAliasFixture.run { f in
            let files = (1...3).map { f.file("TV/Abbott Elementary/Season 6/Abbott Elementary - S06E0\($0).mkv") }
            try await f.resolver.correctMatch(for: files[0],
                candidate: .init(mediaID: "tt14218830", type: "series", name: "Abbott Elementary", releaseInfo: "2021"), provider: "fixture")
            let library = f.store(files)
            await f.resolveAll(library)
            let row = try #require(AppleCatalogSearchStore.mergedResults(await library.searchRecords(indexed: []),
                matching: "abbott", limit: 100).first)
            let match = try #require(library.searchMatch(for: row))
            let group = try #require(library.groups.first { $0.id == match.localGroupID })
            let episodes = AppleLocalLibraryStore.episodes(group: group, mediaID: match.item.mediaID, enriched: [])
            #expect(episodes.count == 3)
            #expect(episodes.first?.season == 6)
            #expect(episodes.first?.episode == 1)
            #expect(AppleTitlePagePolicy.canStartPlayback(type: match.item.type,
                hasPlaybackRoute: AppleTitlePagePolicy.hasPlaybackRoute(item: match.item, hasLocalGroup: true),
                isPreparing: false, hasSelectedEpisode: ApplePlayGatingPolicy.defaultEpisodeID(episodes: episodes) != nil))
        }
    }

    @Test(arguments: [false, true])
    func stagedDiscAndMatchedCopySearchAsOneMetadataTitle(reverse: Bool) async throws {
        try await LocalAliasFixture.run { f in
            let staged = f.file("ISO-STAGE-93-John-Wick-Chapter-4-2023-UHD.iso")
            let clean = f.file("John.Wick.Chapter.4.2023.COMPLETE.UHD.BLURAY.iso")
            let movie = AppleCatalogItem(mediaID: "tt10366206", type: "movie", name: "John Wick: Chapter 4",
                posterURL: URL(string: "https://fixture.example/wick.jpg"), summary: "A matched film.", releaseInfo: "2023")
            try await f.resolver.correctMatch(for: clean, candidate: movie, provider: "fixture")
            let library = f.store(reverse ? [clean, staged] : [staged, clean])
            await f.resolveAll(library)
            let indexed = AppleMediaIngestion.libraryRecords(source: f.source, items: [staged, clean])
            let records = await library.searchRecords(indexed: indexed)
            let rows = AppleCatalogSearchStore.mergedResults(reverse ? records.reversed() : records, matching: "wick", limit: 100)
            let row = try #require(rows.first)
            #expect(rows.count == 1)
            #expect(row.title == movie.name)
            #expect(row.canonicalID == movie.mediaID)
            #expect(row.artworkURL == movie.posterURL)
            let match = try #require(library.searchMatch(for: row))
            #expect(match.item == movie)
            #expect(library.groups.first { $0.id == match.localGroupID }?.items.contains(clean) == true)
        }
    }

    @Test(arguments: [false, true])
    func coldDiscSearchStaysOneRowAfterItsFirstMetadataMatch(reverse: Bool) async throws {
        let movie = AppleCatalogItem(mediaID: "tt10366206", type: "movie", name: "John Wick: Chapter 4",
            posterURL: URL(string: "https://fixture.example/wick.jpg"), summary: "A matched film.", releaseInfo: "2023")
        try await LocalAliasFixture.run(kind: .nas, lookup: { _, _, _ in movie }) { f in
            let staged = f.file("movies/ISO-STAGE-93-John-Wick-Chapter-4-2023-UHD/ISO-STAGE-93-John-Wick-Chapter-4-2023-UHD.iso",
                size: 96_539_312_128)
            let clean = f.file("movies/John Wick - Chapter 4 (2023)/John.Wick.Chapter.4.2023.COMPLETE.UHD.BLURAY-B0MBARDiERS.iso",
                size: 96_539_312_128)
            let files = reverse ? [clean, staged] : [staged, clean]
            let library = f.store(files)
            let group = try #require(library.groups.first { $0.items.contains(staged) })
            let storedName = library.catalogItem(for: group).name
            let localCatalogRecords = library.groups.map {
                AppleMediaIngestion.catalogRecord(instanceID: f.source.id, item: library.catalogItem(for: $0))
            }
            let indexed = AppleMediaIngestion.libraryRecords(source: f.source, items: files) + localCatalogRecords
            let coldRows = AppleCatalogSearchStore.mergedResults(await library.searchRecords(indexed: indexed),
                matching: "wick", limit: 100)
            #expect(coldRows.count == 1)
            #expect(coldRows.first?.title == "John Wick Chapter 4")
            #expect(library.catalogItem(for: group).name == storedName)

            await library.resolve(group, sourceStore: f.sources, settings: f.settings)
            let stale = try #require(localCatalogRecords.first { $0.title == storedName })
            #expect(library.searchMatch(for: stale)?.localGroupID == group.id)
            #expect(library.searchMatch(for: stale)?.item == movie)
            let refreshedIndex = indexed + [AppleMediaIngestion.catalogRecord(instanceID: f.source.id, item: movie)]
            let records = await library.searchRecords(indexed: refreshedIndex)
            #expect(!records.contains { $0.title == storedName })
            let rows = AppleCatalogSearchStore.mergedResults(records, matching: "wick", limit: 100)
            #expect(rows.count == 1)
            #expect(rows.first?.title == movie.name)
            #expect(rows.first?.artworkURL == movie.posterURL)
        }
    }

    @Test(arguments: [("72.HOURS.mkv", "72 Hours"), ("rocky.ii.mkv", "ROCKY II"), ("csi.miami.mkv", "CSI MIAMI")])
    func providerTitleReachesSearchContinueWatchingAndAbout(_ value: (String, String)) async throws {
        try await LocalAliasFixture.run { f in
            let file = f.file(value.0)
            let candidate = AppleCatalogItem(mediaID: "tt0000072", type: "movie", name: value.1)
            try await f.resolver.correctMatch(for: file, candidate: candidate, provider: "fixture")
            let library = f.store([file])
            await f.resolveAll(library)
            let group = try #require(library.groups.first)
            let item = library.catalogItem(for: group)
            #expect(item == candidate)
            #expect(library.mediaRecord(for: group)?.title == value.1)
            #expect(await library.searchRecords(indexed: []).first?.title == value.1)
            f.playback.save(mediaID: library.playbackID(file), position: 600, duration: 3600)
            #expect(AppleDiscoverView.localContinueWatching(library: library, playbackStore: f.playback).first?.item == candidate)
            #expect(AppleMetadataPresentationPolicy.title(metadata: candidate.name, fallback: file.name) == value.1)
        }
    }

    @Test(arguments: ["the.wire.s01e01.mkv", "tHe.WiRe.s01e01.mkv"])
    func metadataTitleCasingDoesNotComeFromTheFilename(filename: String) async throws {
        try await LocalAliasFixture.run { f in
            let file = f.file(filename)
            try await f.resolver.correctMatch(for: file,
                candidate: .init(mediaID: "tt0306414", type: "series", name: "THE WIRE"), provider: "fixture")
            let library = f.store([file])
            await f.resolveAll(library)
            let group = try #require(library.groups.first)
            #expect(library.catalogItem(for: group).name == "THE WIRE")
            #expect(await library.searchRecords(indexed: []).first?.title == "THE WIRE")
        }
    }

    @Test(arguments: [false, true])
    func searchGroupIdentitySurvivesAnArtworkRefresh(tmdbKeyed: Bool) async throws {
        try await LocalAliasFixture.run { f in
            let staged = f.file("ISO-STAGE-93-John-Wick-Chapter-4-2023-UHD.iso")
            let clean = f.file("John.Wick.Chapter.4.2023.COMPLETE.UHD.BLURAY.iso")
            let movie = AppleCatalogItem(mediaID: tmdbKeyed ? "tmdb:movie:603692" : "tt10366206", type: "movie", name: "John Wick: Chapter 4",
                posterURL: URL(string: "https://fixture.example/new-poster.jpg"), releaseInfo: "2023", imdbID: "tt10366206")
            try await f.resolver.correctMatch(for: clean, candidate: movie, provider: "fixture")
            let library = f.store([staged, clean])
            await f.resolveAll(library)
            let record = AppleMediaRecord(canonicalID: movie.imdbID, kind: .movie, title: movie.name,
                artworkURL: URL(string: "https://fixture.example/old-poster.jpg"),
                availability: AppleMediaIngestion.libraryRecord(source: f.source, item: staged).availability)
            let match = try #require(library.searchMatch(for: record))
            #expect(match.item == movie)
            #expect(library.groups.first { $0.id == match.localGroupID }?.items.contains(clean) == true)
        }
    }

    @Test(arguments: [false, true], [false, true])
    func activatedSearchDestinationPinsItsGroupBySourceAndIMDb(tmdbKeyed: Bool, hasStaleGroupID: Bool) async throws {
        try await LocalAliasFixture.run { f in
            let files = (1...2).map { f.file("TV/Abbott Elementary/Season 6/Abbott Elementary - S06E0\($0).mkv") }
            let otherSource = AppleSource(kind: .library, name: "Other", url: f.root.appendingPathComponent("Other"))
            let otherFile = AppleLibraryItem(sourceID: otherSource.id, name: files[0].name,
                url: otherSource.url.appendingPathComponent(files[0].name), relativePath: files[0].name, sizeBytes: 1)
            let show = AppleCatalogItem(mediaID: tmdbKeyed ? "tmdb:series:125935" : "tt14218830", type: "series",
                name: "Abbott Elementary", releaseInfo: "2021", imdbID: "tt14218830")
            for file in [otherFile, files[0]] { try await f.resolver.correctMatch(for: file, candidate: show, provider: "fixture") }
            let library = AppleLocalLibraryStore(resolver: f.resolver, playbackStore: f.playback,
                groups: AppleLibrarySeries.groups([otherFile] + files), sources: [otherSource, f.source],
                versionCacheURL: f.root.appendingPathComponent("MediaVersions-v1.json"))
            await f.resolveAll(library)
            let record = AppleMediaIngestion.libraryRecord(source: f.source, item: files[0])
            let match = AppleCatalogSearchMatch(item: show, source: f.source, localGroupID: hasStaleGroupID ? "retired-group" : nil)
            let destination = try #require(AppleSearchView.RoutedResult(record: record, match: match,
                action: .display, revision: -1, library: library))
            let pinned = try #require(destination.localGroup)
            #expect(pinned.items == files)
            #expect(destination.requiresLocalGroup)
            library.discardAfterReset()
            #expect(library.groups.isEmpty)
            #expect(destination.localGroup == pinned)
            #expect(AppleLocalLibraryStore.episodes(group: pinned, mediaID: show.mediaID, enriched: []).first?.season == 6)
        }
    }

    @Test func aSearchDestinationUsesItsGroupIDBeforeMetadataIDs() async throws {
        try await LocalAliasFixture.run { f in
            let file = f.file("Unmatched.2024.iso")
            let library = f.store([file])
            let group = try #require(library.groups.first)
            let staleItem = AppleCatalogItem(mediaID: "tt0000001", type: "movie", name: "Old Match")
            let match = AppleCatalogSearchMatch(item: staleItem, source: f.source, localGroupID: group.id)
            let destination = try #require(AppleSearchView.RoutedResult(record: AppleMediaIngestion.libraryRecord(source: f.source, item: file),
                match: match, action: .display, revision: -1, library: library))
            #expect(destination.localGroup == group)
            library.discardAfterReset()
            let unavailable = AppleSearchView.RoutedResult(record: destination.record, match: match,
                action: .display, revision: -1, library: library)
            #expect(unavailable == nil)
        }
    }

    @Test(arguments: [AppleSourceKind.liveTV, .mediaServer])
    func externalSearchTitlesKeepTheirCatalogDestination(kind: AppleSourceKind) async throws {
        try await LocalAliasFixture.run { f in
            let file = f.file("John.Wick.2014.iso")
            try await f.resolver.correctMatch(for: file,
                candidate: .init(mediaID: "tt2911666", type: "movie", name: "John Wick"), provider: "fixture")
            let library = f.store([file])
            await f.resolveAll(library)
            let source = AppleSource(kind: kind, name: "Fixture", url: URL(string: "https://fixture.example")!)
            let mediaID = kind == .liveTV
                ? AppleXtreamReference(sourceID: source.id, kind: .movie, providerID: "1").mediaID
                : AppleMediaServerItemReference(sourceID: source.id, itemID: "1").mediaID
            let item = AppleCatalogItem(mediaID: mediaID, type: "movie", name: "John Wick", imdbID: "tt2911666")
            let record = AppleMediaIngestion.catalogRecord(instanceID: source.id, item: item)
            let match = try #require(AppleCatalogSearchMatch.indexed(record, sources: [source]))
            let destination = try #require(AppleSearchView.RoutedResult(record: record, match: match,
                action: .display, revision: -1, library: library))
            #expect(!destination.requiresLocalGroup)
            #expect(destination.localGroup == nil)
            #expect(destination.item.mediaID == mediaID)
            #expect(destination.source == source)
        }
    }

    @Test func unmatchedTitlesKeepTheirStoredIdentityName() throws {
        let file = AppleLibraryItem(sourceID: UUID(), name: "ISO-STAGE-93-John-Wick-Chapter-4-2023-UHD.iso",
            url: URL(fileURLWithPath: "/fixture/disc.iso"), relativePath: "disc.iso", sizeBytes: 1)
        let group = try #require(AppleLibrarySeries.groups([file]).first)
        let library = AppleLocalLibraryStore(groups: [group])
        #expect(library.catalogItem(for: group).name == group.parsed.title)
    }

    @Test(arguments: [AppleSourceKind.library, .nas])
    func extraTransportKeepsItsOwnTitleInAMatchedMovieGroup(kind: AppleSourceKind) async throws {
        try await LocalAliasFixture.run(kind: kind) { f in
            let feature = f.file("John.Wick.Chapter.4.2023.iso")
            let extra = f.file("Behind the Scenes.mkv")
            #expect(AppleLibraryTitleParser.parse(extra).role == .behindTheScenes)
            try await f.resolver.correctMatch(for: feature,
                candidate: .init(mediaID: "tt10366206", type: "movie", name: "John Wick: Chapter 4", releaseInfo: "2023"), provider: "fixture")
            var group = try #require(AppleLibrarySeries.groups([feature]).first)
            group.items.append(extra)
            let library = AppleLocalLibraryStore(resolver: f.resolver, playbackStore: f.playback,
                groups: [group], sources: [f.source], versionCacheURL: f.root.appendingPathComponent("MediaVersions-v1.json"),
                makeShareClient: { AliasShareClient() })
            await f.resolveAll(library)
            let presentation = try await library.presentation(for: extra, sourceStore: f.sources,
                settings: f.settings, engineOverride: .openStream)
            #expect(presentation.request.hints.filename == extra.name)
            #expect(presentation.request.title == "Behind the Scenes.mkv")
            if kind == .nas {
                let original = AppleSMBPlaybackRequestFactory.make(source: f.source, item: extra, playbackURL: presentation.request.url)
                #expect(presentation.request.title == original.title)
                await AppleSMBRangeServer.shared.revoke(playbackURL: presentation.request.url)
            }
        }
    }

    @Test func searchRecordRecomputeForThreeThousandUnmatchedGroups() async throws {
        try await LocalAliasFixture.run { f in
            let files = (1...3_000).map { f.file("Unmatched.Feature.\($0).2024.mkv") }
            let library = f.store(files)
            #expect(library.groups.count == 3_000)
            let started = ContinuousClock.now
            let mainActorTurn = Task { @MainActor in started.duration(to: .now) }
            let records = await library.searchRecords(indexed: [])
            let elapsed = started.duration(to: .now)
            let mainActorDelay = await mainActorTurn.value
            #expect(records.count == 3_000)
            let cachedStarted = ContinuousClock.now
            let cached = await library.searchRecords(indexed: [])
            let cachedElapsed = cachedStarted.duration(to: .now)
            #expect(cached == records)
            print("Search records (3,000 unmatched): recompute=\(elapsed), mainActor=\(mainActorDelay), cached=\(cachedElapsed)")
        }
    }

    @Test(arguments: [AppleSourceKind.library, .nas])
    func episodeTransportKeepsItsOriginalTitle(kind: AppleSourceKind) async throws {
        try await LocalAliasFixture.run(kind: kind) { f in
            let file = f.file("File.Title.S01E01.iso")
            try await f.resolver.correctMatch(for: file,
                candidate: .init(mediaID: "tt0306414", type: "series", name: "The Wire"), provider: "fixture")
            let library = f.store([file])
            await f.resolveAll(library)
            let presentation = try await library.presentation(for: file, sourceStore: f.sources,
                settings: f.settings, engineOverride: .openStream)
            #expect(presentation.request.title == "File Title")
            if kind == .nas {
                let original = AppleSMBPlaybackRequestFactory.make(source: f.source, item: file, playbackURL: presentation.request.url)
                #expect(presentation.request.title == original.title)
            }
            #expect(presentation.request.title != "The Wire")
            let nowPlaying = AppleNowPlayingMetadata(request: presentation.request)
            #expect(nowPlaying.seriesTitle == "The Wire")
            #expect(nowPlaying.title == "S1, E1 · Episode 1")
            if kind == .nas { await AppleSMBRangeServer.shared.revoke(playbackURL: presentation.request.url) }
        }
    }

    @Test(arguments: [
        ("tt1160419", "Dune", "2021", true),
        ("tt0087182", "Dune", "2021", true),
        ("tt1160419", "Dune: Part One", "2021", false),
        ("tt1160419", "Dune", "1984", false),
        ("tmdb:movie:438631", "Dune", "2021", true)
    ])
    func libraryMatchingKeepsNameAndYearRulesForTMDBItemsWithIMDbIDs(_ value: (String, String, String, Bool)) async throws {
        try await LocalAliasFixture.run { f in
            let file = f.file("Dune.2021.iso")
            let movie = AppleCatalogItem(mediaID: "tmdb:movie:438631", type: "movie", name: "Dune",
                releaseInfo: "2021", imdbID: "tt1160419")
            try await f.resolver.correctMatch(for: file, candidate: movie, provider: "fixture")
            let library = f.store([file])
            await f.resolveAll(library)
            let group = try #require(library.groups.first)
            let query = AppleCatalogItem(mediaID: value.0, type: "movie", name: value.1, releaseInfo: value.2)
            #expect(AppleLocalLibraryStore.matches(movie, query) == value.3)
            #expect(library.matchingGroups(query).map(\.id) == (value.3 ? [group.id] : []))
        }
    }

    @Test(arguments: [AppleSourceKind.library, .nas], [nil, AppleDiscPlaybackChoice(start: .menu),
        AppleDiscPlaybackChoice(start: .mainTitle), AppleDiscPlaybackChoice(start: .mainTitle, titleID: 3)])
    func discTransportUsesTheMatchedTitleAndKeepsTheFilenameHint(kind: AppleSourceKind, disc: AppleDiscPlaybackChoice?) async throws {
        try await LocalAliasFixture.run(kind: kind) { f in
            let file = f.file("ISO-STAGE-93-John-Wick-Chapter-4-2023-UHD.iso")
            try await f.resolver.correctMatch(for: file,
                candidate: .init(mediaID: "tt10366206", type: "movie", name: "John Wick: Chapter 4", releaseInfo: "2023"), provider: "fixture")
            let library = f.store([file])
            await f.resolveAll(library)
            let presentation = try await library.presentation(for: file, sourceStore: f.sources,
                settings: f.settings, disc: disc, engineOverride: .openStream)
            #expect(presentation.request.title == "John Wick: Chapter 4")
            #expect(presentation.request.hints.filename == file.name)
            #expect(presentation.request.hints.disc != nil)
            #expect(presentation.request.hints.disc?.titleID == disc?.titleID)
            if kind == .nas { await AppleSMBRangeServer.shared.revoke(playbackURL: presentation.request.url) }
        }
    }

    @Test func offlineDiscTransportUsesTheProviderTitle() async throws {
        try await LocalAliasFixture.run { f in
            let source = AppleSource(id: AppleLocalLibraryStore.downloadsID, kind: .library, name: "Downloads",
                url: f.root.appendingPathComponent("Downloads"))
            let file = AppleLibraryItem(sourceID: source.id, name: "ROCKY.II.1979.iso",
                url: source.url.appendingPathComponent("download.iso"), relativePath: "download.iso", sizeBytes: 1)
            try await f.resolver.correctMatch(for: file,
                candidate: .init(mediaID: "tt0079817", type: "movie", name: "ROCKY II", releaseInfo: "1979"), provider: "fixture")
            let library = AppleLocalLibraryStore(resolver: f.resolver, playbackStore: f.playback,
                groups: AppleLibrarySeries.groups([file]), sources: [source], offlineIDs: [file.id: "offline-film"],
                versionCacheURL: f.root.appendingPathComponent("MediaVersions-v1.json"))
            await f.resolveAll(library)
            let presentation = try await library.presentation(for: file, sourceStore: f.sources,
                settings: f.settings, disc: .init(start: .mainTitle, titleID: 2), engineOverride: .openStream)
            #expect(presentation.request.title == "ROCKY II")
            #expect(presentation.request.url == file.url)
            #expect(presentation.request.hints.filename == file.name)
            #expect(presentation.request.hints.disc?.titleID == 2)
        }
    }

    @Test func unmatchedLibrarySearchStillOpensATitlePage() async throws {
        try await LocalAliasFixture.run { f in
            let library = f.store([f.file("Unmatched.2024.mkv")])
            let row = try #require(await library.searchRecords(indexed: []).first)
            #expect(library.searchMatch(for: row)?.item.name == "Unmatched")
            #expect(library.searchMatch(for: row)?.source.id == f.source.id)
        }
    }

    @Test func airbenderSearchKeepsItsGroupForOnDemandMetadata() async throws {
        let movie = AppleCatalogItem(mediaID: "tt0938283", type: "movie", name: "The Last Airbender",
            posterURL: URL(string: "https://fixture.example/airbender.jpg"), summary: "A matched disc.", releaseInfo: "2010")
        try await LocalAliasFixture.run(lookup: { parsed, _, _ in
            #expect(parsed.title == "The Last Airbender")
            #expect(parsed.year == 2010)
            return movie
        }) { f in
            let file = f.file("movies/The Last Airbender (2010)/The Last Airbender (2010).iso", size: 45_306_740_736)
            let library = f.store([file])
            let row = try #require(await library.searchRecords(indexed: []).first)
            let match = try #require(library.searchMatch(for: row))
            let group = try #require(library.groups.first { $0.id == match.localGroupID })
            #expect(match.item.mediaID.hasPrefix("local-"))
            #expect(library.metadata[group.id] == nil)
            await library.resolve(group, sourceStore: f.sources, settings: f.settings)
            #expect(library.searchMatch(for: row)?.item == movie)
        }
    }

    @Test func searchSnapshotRefreshesWhenLibraryMetadataChanges() async throws {
        try await LocalAliasFixture.run { f in
            let file = f.file("RELEASE.2024.mkv")
            let library = f.store([file])
            #expect(await library.searchRecords(indexed: []).first?.title == "RELEASE")
            try await f.resolver.correctMatch(for: file,
                candidate: .init(mediaID: "tt0000072", type: "movie", name: "72 Hours", releaseInfo: "2024"), provider: "fixture")
            await f.resolveAll(library)
            #expect(await library.searchRecords(indexed: []).first?.title == "72 Hours")
            library.discardAfterReset()
            #expect(await library.searchRecords(indexed: []).isEmpty)
        }
    }

    @Test func defaultDVDPlayOpensTheDiscMenu() async throws {
        try await LocalAliasFixture.run { f in
            let file = f.file("Film.2020.iso")
            let store = f.store([file])
            let presentation = try await store.presentation(for: file, sourceStore: f.sources,
                settings: f.settings, engineOverride: .openStream)
            #expect(presentation.request.hints.disc?.start == .menu)
            #expect(presentation.request.hints.disc?.engineTitleID == nil)
        }
    }

    @Test func strongMatchRecordsOneClassPerFile() async throws {
        try await LocalAliasFixture.run { f in
            let file = f.file("Shows/Show/Season 1/Show.S01E01.mkv")
            try await f.manual(file)
            let store = f.store([file])
            await f.resolveAll(store)
            let key = try #require(ApplePlaybackIdentity.storageKey(for: store.playbackID(file)))
            #expect(try f.table().classes["li:series:tt0903747:1:1:734003200"] == [key])
            #expect(try f.table().classes["li:series:tt0903747:1:1"]?.contains(key) == true)
            let storage = ApplePlaybackBlobStorage.storage(defaults: f.defaults, directory: f.blobDirectory)
            let url = storage.fileURL(forKey: "openstream.identity.aliases.v1")
            let sentinel = Date(timeIntervalSince1970: 1234)
            try FileManager.default.setAttributes([.modificationDate: sentinel], ofItemAtPath: url.path)
            await f.resolveAll(store)
            #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date == sentinel)
        }
    }
    @Test func renamedFileJoinsTheSameClass() async throws {
        try await LocalAliasFixture.run { f in
            let old = f.file("Shows/Show/Season 1/Show.S01E01.mkv")
            let new = f.file("Moved/Shows/Show/Season 1/Show.S01E01.renamed.mkv")
            try await f.manual(old)
            let oldStore = f.store([old])
            await f.resolveAll(oldStore)
            f.playback.save(mediaID: oldStore.playbackID(old), position: 600, duration: 3600)
            let newStore = f.store([new])
            await f.resolveAll(newStore)
            let members = try #require(f.table().classes["li:series:tt0903747:1:1:734003200"])
            #expect(members.count == 2)
            #expect(Set(members) == Set([oldStore.playbackID(old), newStore.playbackID(new)].compactMap { ApplePlaybackIdentity.storageKey(for: $0) }))
            #expect(newStore.continueWatching.map(\.id) == newStore.groups.map(\.id))
            #expect(f.playback.progress(for: newStore.playbackID(new))?.position == 600)
        }
    }
    @Test func weakMatchRecordsNothing() async throws {
        try await LocalAliasFixture.run(lookup: { _, _, _ in
            AppleCatalogItem(mediaID: "tt0903747", type: "movie", name: "Film", releaseInfo: "2019")
        }) { f in
            let file = f.file("Film.2020.mkv")
            let store = f.store([file])
            await f.resolveAll(store)
            #expect(await f.resolver.matchRecord(for: file)?.confidence == 0.6)
            #expect(try f.table().classes.isEmpty)
            // Weak evidence is deduped until an explicit metadata refresh.
            try await f.manual(file, kind: "movie")
            await f.resolveAll(store)
            #expect(try f.table().classes.isEmpty)
            for group in store.groups {
                await store.resolve(group, sourceStore: f.sources, settings: f.settings, refresh: true)
            }
            #expect(try f.table().classes["li:movie:tt0903747"] != nil)
        }
    }
    @Test func noMatchRecordsNothing() async throws {
        try await LocalAliasFixture.run { f in
            let store = f.store([f.file("Film.2020.mkv")])
            await f.resolveAll(store)
            let table = try f.table()
            #expect(table.classes.isEmpty)
            // A newly resolved match must still record after an earlier miss.
            try await f.manual(store.groups[0].items[0], kind: "movie")
            await f.resolveAll(store)
            #expect(try f.table().classes["li:movie:tt0903747"] != nil)
        }
    }
    @Test func twoCopiesShareTitleAndKeepVersionScopes() async throws {
        try await LocalAliasFixture.run { f in
            let first = f.file("Film.2020.1080p.mkv", size: 1000)
            let second = f.file("Film.2020.2160p.mkv", size: 2000)
            try await f.manual(first, kind: "movie")
            let store = f.store([first, second])
            await f.resolveAll(store)
            let table = try f.table()
            #expect(table.classes["li:movie:tt0903747:1000"]?.count == 1)
            #expect(table.classes["li:movie:tt0903747:2000"]?.count == 1)
            #expect(table.classes["li:movie:tt0903747"] != nil)
            f.playback.save(mediaID: store.playbackID(first), position: 600, duration: 3600)
            #expect(f.playback.progress(for: store.playbackID(second))?.position == 600)
            _ = store.mediaVersions(for: first)
            #expect(f.playback.versionProgress(itemID: "li:movie:tt0903747", versionID: store.playbackID(first))?.position == 600)
            #expect(f.playback.versionProgress(itemID: "li:movie:tt0903747", versionID: store.playbackID(second)) == nil)
        }
    }
    @Test func unmatchedSameTitleCopiesAreNeitherMergedNorAliased() async throws {
        try await LocalAliasFixture.run { f in
            let first = f.file("Film.2020.1080p.mkv", size: 1000)
            let second = f.file("Film.2020.2160p.mkv", size: 2000)
            let store = f.store([first, second])
            await f.resolveAll(store)
            let one = store.mediaVersions(for: first)
            let two = store.mediaVersions(for: second)
            #expect(one.count == 1 && two.count == 1)
            #expect(one.first?.itemID == store.playbackID(first))
            #expect(two.first?.itemID == store.playbackID(second))
            let table = try f.table()
            #expect(table.classes.isEmpty)
            f.playback.save(mediaID: store.playbackID(first), position: 600, duration: 3600)
            #expect(f.playback.progress(for: store.playbackID(second)) == nil)
        }
    }

    @Test func anUnmatchedStackSharesOneTimeline() async throws {
        try await LocalAliasFixture.run { f in
            let parts = [f.file("Film.2020.cd1.mkv", size: 1000), f.file("Film.2020.cd2.mkv", size: 1000)]
            let store = f.store(parts)
            await f.resolveAll(store)
            let one = try #require(store.mediaVersions(for: parts[0]).first)
            let two = try #require(store.mediaVersions(for: parts[1]).first)
            #expect(one.parts.map(\.reference) == parts.map(\.id))
            #expect(one.itemID == two.itemID && one.id == two.id)
            #expect(one.itemID != store.playbackID(parts[0]))
        }
    }

    /// A stack whose probe fails plays part by part on each file's own
    /// position, learns each part's length from playback, and then resumes
    /// through the whole cumulative timeline.
    @Test func aStackWithAFailingProbePlaysPartByPartAndLearnsItsTimeline() async throws {
        try await LocalAliasFixture.run { f in
            let folder = f.root.appendingPathComponent("Downloads")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let downloads = AppleSource(id: AppleLocalLibraryStore.downloadsID, kind: .library, name: "Downloads", url: folder)
            let parts = ["Film.2020.cd1.mkv", "Film.2020.cd2.mkv"].map { name in
                AppleLibraryItem(sourceID: downloads.id, name: name, url: folder.appendingPathComponent(name),
                    relativePath: name, sizeBytes: 16)
            }
            // Not media: the probe fails and reports no duration.
            for part in parts { try Data(repeating: 7, count: 16).write(to: part.url) }
            let store = AppleLocalLibraryStore(resolver: f.resolver, playbackStore: f.playback,
                groups: AppleLibrarySeries.groups(parts), sources: [downloads],
                versionCacheURL: f.root.appendingPathComponent("MediaVersions-v1.json"))
            await f.resolveAll(store)

            let first = try await store.presentation(for: parts[0], sourceStore: f.sources, settings: f.settings, engineOverride: .openStream)
            #expect(first.request.url == parts[0].url)
            #expect(first.request.hints.versionID == nil)
            #expect(first.request.mediaID == store.playbackID(parts[0]))
            first.coordinator.progressWriter?(900, 1800)
            #expect(f.playback.fileProgress(for: store.playbackID(parts[0]))?.position == 900)

            let second = try await store.presentation(for: parts[1], sourceStore: f.sources, settings: f.settings,
                continuingPart: true, engineOverride: .openStream)
            #expect(second.request.url == parts[1].url)
            #expect(second.request.hints.versionID == nil)
            second.coordinator.progressWriter?(300, 2400)

            let resumed = try await store.presentation(for: parts[0], sourceStore: f.sources, settings: f.settings, engineOverride: .openStream)
            #expect(resumed.request.hints.versionDuration == 4200)
            #expect(resumed.request.url == parts[1].url)
            #expect(resumed.request.resumePosition == 300)
            #expect(resumed.request.hints.versionOffset == 1800)
        }
    }

    @Test func playAndItsPromptUseTheLastPlayedCopy() async throws {
        try await LocalAliasFixture.run { f in
            let low = f.file("Film.2020.1080p.mkv", size: 1000)
            let high = f.file("Film.2020.2160p.mkv", size: 2000)
            try await f.manual(low, kind: "movie")
            let cacheURL = f.root.appendingPathComponent("MediaVersions-v1.json")
            let probe = f.store([low, high])
            await f.resolveAll(probe)
            var versions = probe.mediaVersions(for: low)
            try #require(versions.count == 2)
            for index in versions.indices {
                versions[index].parts[0].duration = versions[index].parts[0].reference == high.id ? 7200 : 6000
            }
            AppleMediaVersionCache(url: cacheURL).record(versions)
            let store = f.store([low, high])
            await f.resolveAll(store)
            let itemID = versions[0].itemID
            let highID = try #require(versions.first { $0.parts[0].reference == high.id }?.id)
            let lowID = try #require(versions.first { $0.parts[0].reference == low.id }?.id)
            f.playback.saveVersion(itemID: itemID, versionID: highID, position: 600, duration: 7200)
            f.playback.preferVersion(lowID, itemID: itemID)
            // Play on the 4K file still resumes the 1080p copy played last, and
            // the runtime differs, so it asks about exactly that copy.
            await #expect(throws: AppleVersionResumeConfirmation(position: 600, versionID: lowID)) {
                _ = try await store.presentation(for: high, sourceStore: f.sources, settings: f.settings, engineOverride: .openStream)
            }
            #expect(f.playback.preferredVersion(itemID: itemID) == lowID)
        }
    }

    @Test func playNamesTheCopyItActuallyTried() async throws {
        try await LocalAliasFixture.run { f in
            let low = f.file("Film.2020.1080p.mkv", size: 1000)
            let high = f.file("Film.2020.2160p.mkv", size: 2000)
            try await f.manual(low, kind: "movie")
            let store = f.store([low, high])
            await f.resolveAll(store)
            let versions = store.mediaVersions(for: low)
            try #require(versions.count == 2)
            let lowID = try #require(versions.first { $0.parts[0].reference == low.id }?.id)
            f.playback.preferVersion(lowID, itemID: versions[0].itemID)
            // Play on the 4K file selects the 1080p copy played last; a failure
            // blacklists the file `attempting` ends on.
            var attempted = high
            let presentation = try await store.presentation(attempting: &attempted, sourceStore: f.sources,
                settings: f.settings, engineOverride: .openStream)
            #expect(attempted.id == low.id)
            #expect(presentation.request.hints.libraryFileURL == low.url)
        }
    }
    @Test func oneLibraryPublishWritesTheVersionCacheOnce() async throws {
        try await LocalAliasFixture.run { f in
            let files = [f.file("Alpha.2020.mkv"), f.file("Beta.2021.mkv"), f.file("Gamma.2022.mkv")]
            for (index, file) in files.enumerated() {
                try await f.resolver.correctMatch(for: file, candidate: AppleCatalogItem(mediaID: "tt000000\(index + 1)",
                    type: "movie", name: file.name, releaseInfo: "2020"), provider: "fixture")
            }
            let store = f.store(files)
            #expect(store.groups.count == 3)
            await store.recordAllIdentityAliases()
            #expect(store.mediaVersionCache.versions.count == 3)
            #expect(store.mediaVersionCache.diskWrites == 1)
            // The next launch rebuilds the same versions with a newer timestamp: no write.
            let relaunched = f.store(files)
            await relaunched.recordAllIdentityAliases()
            #expect(relaunched.mediaVersionCache.versions.count == 3)
            #expect(relaunched.mediaVersionCache.diskWrites == 0)
        }
    }

    @Test(arguments: [
        ["Shows/Show/Show.2020-01-01.mkv", "Shows/Show/Show.2020-01-02.mkv"],
        ["Shows/Show/Pilot.mkv", "Shows/Show/Arrival.mkv"]
    ]) func dailyAndUnnumberedEpisodesKeepSeparateTimelines(paths: [String]) async throws {
        try await LocalAliasFixture.run { f in
            let files = paths.map { f.file($0, size: 1000) }
            try await f.manual(files[0])
            let library = f.store(files)
            await f.resolveAll(library)
            let first = try #require(library.mediaVersions(for: files[0]).first)
            let second = try #require(library.mediaVersions(for: files[1]).first)
            #expect(first.itemID != second.itemID)
            f.playback.saveVersion(itemID: first.itemID, versionID: first.id, position: 600, duration: 3600)
            #expect(f.playback.progress(for: second.itemID) == nil)
        }
    }

    @Test func aCancelledVersionPressDoesNotPrepareOrMigratePlayback() async throws {
        try await LocalAliasFixture.run { f in
            let file = f.file("Film.2020.2160p.mkv")
            let library = f.store([file])
            let task = Task { @MainActor in
                _ = try await library.presentation(for: file, sourceStore: f.sources, settings: f.settings, explicitVersion: true)
            }
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(f.playback.configurationProgress().isEmpty)
            #expect(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("MediaVersions-v1.json").path) == false)
        }
    }

    @Test func copiesAcrossLocalSourcesProduceOneContinueWatchingCard() async throws {
        try await LocalAliasFixture.run { f in
            let first = f.file("Film.2020.1080p.mkv", size: 1000)
            let other = AppleSource(kind: .library, name: "Other", url: f.root.appendingPathComponent("Other"))
            let second = AppleLibraryItem(sourceID: other.id, name: "Film.2020.2160p.mkv",
                url: other.url.appendingPathComponent("Film.2020.2160p.mkv"), relativePath: "Film.2020.2160p.mkv", sizeBytes: 2000)
            try await f.manual(first, kind: "movie")
            try await f.manual(second, kind: "movie")
            let library = AppleLocalLibraryStore(resolver: f.resolver, playbackStore: f.playback,
                groups: AppleLibrarySeries.groups([first, second]), sources: [f.source, other],
                versionCacheURL: f.root.appendingPathComponent("MediaVersions-v1.json"))
            await f.resolveAll(library)
            let versions = library.mediaVersions(for: first)
            #expect(versions.count == 2)
            let version = try #require(versions.first)
            f.playback.saveVersion(itemID: version.itemID, versionID: version.id, position: 600, duration: 3600)
            #expect(library.continueWatching.count == 1)
        }
    }

    @Test func saveCompletionIndexSyncAndRowResolutionWithTwoVersions() async throws {
        try await LocalAliasFixture.run { f in
            let first = f.file("Film.2020.1080p.mkv", size: 1000)
            let second = f.file("Film.2020.2160p.mkv", size: 2000)
            try await f.manual(first, kind: "movie")
            let library = f.store([first, second])
            await f.resolveAll(library)
            let versions = library.mediaVersions(for: first)
            #expect(versions.count == 2)
            let itemID = try #require(versions.first?.itemID)
            f.playback.saveVersion(itemID: itemID, versionID: library.playbackID(first), position: 600, duration: 3600)
            library.refreshProgress()
            #expect(library.continueWatching.count == 1)
            f.playback.saveVersion(itemID: itemID, versionID: library.playbackID(first), position: 3600, duration: 3600)
            let repository = AppleMediaIndexRepository(fileURL: f.root.appendingPathComponent("index.json"))
            try await repository.replace(instanceID: f.source.id, with: [first, second].map { AppleMediaIngestion.libraryRecord(source: f.source, item: $0) })
            library.refreshProgress()
            #expect(library.continueWatching.isEmpty)
            #expect(f.playback.completedMediaIDs(among: [library.playbackID(first), library.playbackID(second)]).count == 2)
            #expect(library.sorted(.added).count == 1)
        }
    }

    @Test func extrasDownloadsAndZeroSizeRecordNothing() async throws {
        try await LocalAliasFixture.run { f in
            let extra = f.file("Film.2020-trailer.mkv")
            let zero = f.file("Empty.2020.mkv", size: 0)
            let download = f.file("Downloaded.2020.mkv")
            for file in [extra, zero, download] { try await f.manual(file, kind: "movie") }
            let store = f.store([extra, zero, download], offlineIDs: [download.id: "fixture-download"])
            await f.resolveAll(store)
            #expect(AppleLibraryTitleParser.parse(extra).role == .trailer)
            #expect(try f.table().classes.isEmpty)
        }
    }
    @Test func strongMatchIDsReadsOnly() async throws {
        try await LocalAliasFixture.run { f in
            let file = f.file("Shows/Show/Season 1/Show.S01E01.mkv")
            let missing = await f.resolver.strongMatchIDs(for: file)
            #expect(missing.map { _ in true } == nil)
            let folder = f.root.appendingPathComponent("Matches")
            #expect(FileManager.default.fileExists(atPath: folder.path) == false)
            try await f.manual(file)
            let url = try #require(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first)
            let before = try Data(contentsOf: url)
            let sentinel = Date(timeIntervalSince1970: 1234)
            try FileManager.default.setAttributes([.modificationDate: sentinel], ofItemAtPath: url.path)
            for _ in 0..<10 {
                let ids = await f.resolver.strongMatchIDs(for: file)
                #expect(ids?.kind == .series)
                #expect(ids?.imdb == "tt0903747")
                #expect(ids?.tmdb == nil)
            }
            #expect(try Data(contentsOf: url) == before)
            #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date == sentinel)
        }
    }
    @Test func legacyEpisodeLookupIsPureAndExplicitPairKeepsParity() throws {
        try ApplePlaybackAliasFixture.run { f in
            let file = AppleLibraryItem(sourceID: UUID(), name: "Pilot.mkv", url: URL(fileURLWithPath: "/Pilot.mkv"),
                relativePath: "Shows/Show/Season 1/Pilot.mkv", sizeBytes: 1)
            let group = AppleLibrarySeries.groups([file])[0]
            let rows = AppleLocalLibraryStore.episodes(group: group, mediaID: "tt1", enriched: [])
            let current = AppleLocalLibraryStore.fileEpisodeID(file)
            f.store.markWatched(mediaID: "tt1:1:1")
            let before = f.defaults.dictionaryRepresentation().compactMapValues { $0 as? Data }
            let completed = AppleLocalLibraryStore.completedEpisodeIDs(rows, group: group, mediaID: "tt1", store: f.store)
            #expect(f.defaults.dictionaryRepresentation().compactMapValues { $0 as? Data } == before)
            f.store.recordIdentityAlias(classID: AppleLogicalItemKey.legacyEpisodeClass(fileEpisodeID: current),
                mediaIDs: [current, "tt1:1:1"])
            #expect(f.store.completedMediaIDs(among: rows.map(\.id)) == completed)
            let data = try #require(f.defaults.data(forKey: "openstream.identity.aliases.v1"))
            let table = try JSONDecoder().decode(AppleIdentityAliasTable.self, from: data)
            #expect(table.classes[AppleLogicalItemKey.legacyEpisodeClass(fileEpisodeID: current)] == [current, "tt1:1:1"].compactMap { ApplePlaybackIdentity.storageKey(for: $0) }.sorted())
        }
    }
    @Test func resolveRecordsFilenamePairUsingResolvedShowID() async throws {
        try await LocalAliasFixture.run { f in
            let file = f.file("Shows/Show/Season 1/Pilot.mkv")
            try await f.manual(file)
            let store = f.store([file])
            await f.resolveAll(store)
            let current = AppleLocalLibraryStore.fileEpisodeID(file)
            #expect(try f.table().classes["le:" + current] == [current, "tt0903747:1:1"]
                .compactMap { ApplePlaybackIdentity.storageKey(for: $0) }.sorted())
        }
    }

    @Test func filenameLookupDoesNotBorrowAnotherCopiesPositionalHistory() throws {
        try ApplePlaybackAliasFixture.run { f in
            let source = UUID()
            func file(_ name: String, size: Int64) -> AppleLibraryItem {
                AppleLibraryItem(sourceID: source, name: name, url: URL(fileURLWithPath: "/" + name),
                    relativePath: "Shows/Show/Season 1/" + name, sizeBytes: size)
            }
            let old = file("Pilot.mkv", size: 1000)
            let renamed = file("Renamed Pilot.mkv", size: 1000)
            let copy = file("Other Pilot.mkv", size: 2000)
            let oldID = AppleLocalLibraryStore.fileEpisodeID(old)
            let newID = AppleLocalLibraryStore.fileEpisodeID(renamed)
            let copyID = AppleLocalLibraryStore.fileEpisodeID(copy)
            f.store.recordIdentityAlias(classID: "le:" + oldID, mediaIDs: [oldID, "tt1:1:1"])
            f.store.recordIdentityAliases([
                (classID: "li:series:tt1:1000", mediaIDs: [oldID, newID]),
                (classID: "le:" + copyID, mediaIDs: [copyID, "tt1:1:1"])])
            f.store.markWatched(mediaID: "tt1:1:1")
            var group = try #require(AppleLibrarySeries.groups([old]).first)
            group.items = [copy, renamed]
            let rows = AppleLocalLibraryStore.episodes(group: group, mediaID: "tt1", enriched: [])
            #expect(AppleLocalLibraryStore.completedEpisodeIDs(rows, group: group, mediaID: "tt1", store: f.store) == [newID])
        }
    }

}

/// A film on a NAS, resumed from the Apple TV Home screen: it reaches the
/// shelf's Continue Watching, and its link leads back to the file and the
/// file's saved position.
@MainActor @Suite(.serialized) struct AppleShareResumeFromHomeTests {
    @Test func shareFilmInProgressReachesTheShelfAndItsLinkLeadsBackToTheFile() async throws {
        let film = AppleCatalogItem(mediaID: "tt1234567", type: "movie", name: "Verity",
            backgroundURL: URL(string: "https://fixture.example/verity-backdrop.jpg"), releaseInfo: "2023")
        try await LocalAliasFixture.run(kind: .nas) { f in
            let file = f.file("Movies/Verity (2023).mkv")
            try await f.resolver.correctMatch(for: file, candidate: film, provider: "fixture")
            let library = f.store([file])
            await f.resolveAll(library)
            f.playback.save(mediaID: library.playbackID(file), position: 600, duration: 3600)
            let indexed = AppleMediaIngestion.libraryRecords(source: f.source, items: [file])
            let local = AppleDiscoverView.localContinueWatching(library: library, playbackStore: f.playback).map(\.record)

            let writer = AppleTopShelfSnapshotWriter(containerProvider: { f.root },
                snapshotLocation: { AppleTopShelfSnapshotWriter.snapshotURL(in: $0) }, artwork: nil,
                trailerFiles: nil, didChange: {})
            await AppleTopShelfPublisher(writer: writer, platform: .tvOS).publish(records: indexed, sources: [f.source],
                libraryContinueWatching: local, privateTitlesAllowed: true, enabled: true, playbackStore: f.playback)
            let shelf = try #require(AppleTopShelfSnapshotReader(containerProvider: { f.root }).read())
            let item = try #require(shelf.continueWatching.first)
            #expect(shelf.continueWatching.count == 1)
            #expect(item.title == "Verity")
            #expect(item.progress == 1.0 / 6)
            #expect(item.landscapeArtworkURL == film.backgroundURL)
            #expect(shelf.recentlyAdded.isEmpty && shelf.favorites.isEmpty && shelf.topPicks.isEmpty)

            let play = try #require(item.playURL)
            #expect(AppleAppRoute(url: play) == .media(id: item.id, action: .play))
            let record = try #require(indexed.first { $0.id == item.id })
            let match = try #require(library.searchMatch(for: record))
            #expect(match.localGroupID == library.groups.first?.id)
            #expect(match.source.id == f.source.id)
            #expect(f.playback.progress(for: item.id)?.resumePosition == 600)
        }
    }

    /// The snapshot also feeds the iPhone and iPad widgets, which show on the
    /// Home and Lock Screen: a private title stays out of them.
    @Test func shareFilmStaysOutOfTheWidgets() async throws {
        try await LocalAliasFixture.run(kind: .nas) { f in
            let file = f.file("Movies/Verity (2023).mkv")
            let library = f.store([file])
            f.playback.save(mediaID: library.playbackID(file), position: 600, duration: 3600)
            let local = AppleDiscoverView.localContinueWatching(library: library, playbackStore: f.playback).map(\.record)
            #expect(local.map(\.isPrivate) == [true])
            let writer = AppleTopShelfSnapshotWriter(containerProvider: { f.root },
                snapshotLocation: { AppleTopShelfSnapshotWriter.snapshotURL(in: $0) }, artwork: nil,
                trailerFiles: nil, didChange: {})
            await AppleTopShelfPublisher(writer: writer, platform: .tvOS).publish(records: [], sources: [f.source],
                libraryContinueWatching: local, privateTitlesAllowed: false, enabled: true, playbackStore: f.playback)
            let shelf = try #require(AppleTopShelfSnapshotReader(containerProvider: { f.root }).read())
            #expect(shelf.continueWatching.isEmpty)
        }
    }

    /// The Top Shelf's off-main-actor read picks the same file and progress
    /// as Discover's row.
    @Test func shelfReadMatchesDiscoversRow() async throws {
        try await LocalAliasFixture.run(kind: .nas) { f in
            let first = f.file("Movies/Verity (2023).mkv")
            let second = f.file("Movies/Verity (2023) 2160p.mkv")
            let other = f.file("Movies/Harbor (2021).mkv")
            let library = f.store([first, second, other])
            f.playback.save(mediaID: library.playbackID(first), position: 300, duration: 3600)
            f.playback.save(mediaID: library.playbackID(second), position: 900, duration: 3600)
            f.playback.save(mediaID: library.playbackID(other), position: 60, duration: 1200)
            let row = AppleDiscoverView.localContinueWatching(library: library, playbackStore: f.playback).map(\.record)
            let shelf = await AppleDiscoverView.localContinueWatching(library: library, state: f.playback.readState())
            #expect(row.count >= 2)
            // Same files (the id is the file's), same progress; the records
            // carry the time they were made, so they are not equal as a whole.
            #expect(shelf.map(\.id) == row.map(\.id))
            #expect(shelf.map(\.progress) == row.map(\.progress))
        }
    }

    @Test func shareFilmPlaysFromItsSavedPosition() async throws {
        try await LocalAliasFixture.run(kind: .nas) { f in
            let file = f.file("Movies/Verity (2023).mkv")
            let library = f.store([file])
            f.playback.save(mediaID: library.playbackID(file), position: 600, duration: 3600)
            let presentation = try await library.presentation(for: file, sourceStore: f.sources,
                settings: f.settings, engineOverride: .openStream)
            defer { Task { await AppleSMBRangeServer.shared.revoke(playbackURL: presentation.request.url) } }
            #expect(presentation.request.resumePosition == 600)
            #expect(presentation.request.mediaID == library.playbackID(file))
            #expect(presentation.request.url.host == "127.0.0.1")
            #expect(presentation.request.hints.libraryFileURL == file.url)
        }
    }
}
