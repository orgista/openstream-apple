import Foundation
import Synchronization
import Testing
@testable import OpenStreamApple

/// Owner 2026-09-15: "I search for Jury duty and go odd results[,] I don't want
/// episode results ideally show and movies only."
///
/// The media index holds one record per library *file*, so a show with eight
/// episodes on disk produced eight near-identical rows.
@MainActor
@Suite(.serialized)
struct AppleSearchResultShapeTests {
    @Test func indexedTitleOpensWithMetadataAndAnEnabledSource() throws {
        let source = AppleSource(kind: .mediaServer, name: "Fixture", url: try #require(URL(string: "https://fixture.example")))
        let reference = AppleMediaServerItemReference(sourceID: source.id, itemID: "wick").mediaID
        let item = AppleCatalogItem(mediaID: reference, type: "movie", name: "John Wick",
            posterURL: URL(string: "https://fixture.example/wick.jpg"), releaseInfo: "2014", imdbID: "tt2911666")
        let record = AppleMediaIngestion.catalogRecord(instanceID: source.id, item: item)
        let match = try #require(AppleCatalogSearchMatch.indexed(record, sources: [source]))
        #expect(match.item.mediaID == reference)
        #expect(match.item.imdbID == "tt2911666")
        #expect(match.item.name == item.name)
        #expect(match.item.posterURL == item.posterURL)
        #expect(match.source.id == source.id)
        var disabled = source
        disabled.isEnabled = false
        #expect(AppleCatalogSearchMatch.indexed(record, sources: [disabled]) == nil)
        #expect(AppleCatalogSearchMatch.indexed(record, sources: []) == nil)
    }

    @Test(arguments: [false, true])
    func serverSearchRetainsPlaybackIdentity(hasCanonicalMatch: Bool) async throws {
        let source = AppleSource(kind: .mediaServer, name: "Fixture", url: try #require(URL(string: "https://fixture.example")))
        let reference = AppleMediaServerItemReference(sourceID: source.id, itemID: "movie-one").mediaID
        let latest = Data(#"[{"Id":"movie-one","Name":"Fixture Movie","Type":"Movie"}]"#.utf8)
        let client = AppleMediaServerClient(loader: { request in
            guard let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
                throw URLError(.badURL)
            }
            switch url.lastPathComponent {
            case "Views":
                return (Data(#"{"Items":[{"Id":"movies","Name":"Movies","CollectionType":"movies"}]}"#.utf8), response)
            case "Latest": return (latest, response)
            default: return (Data(#"{"Items":[],"TotalRecordCount":0}"#.utf8), response)
            }
        })
        let domain = "server-search-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = AppleMediaServerLibraryStore(client: client, progressDefaults: defaults)
        let session = AppleMediaServerSession(kind: .jellyfin, baseURL: source.url, accessToken: "fixture", userID: "user")
        await store.reload(sources: [source]) { _ in session }
        let indexed = try #require(store.recentlyAddedRecords().first)
        let record = hasCanonicalMatch
            ? AppleMediaRecord(canonicalID: "tt0000001", kind: indexed.kind, title: indexed.title,
                               availability: indexed.availability)
            : indexed
        #expect(record.availability.first?.itemReference != reference)
        let match = try #require(store.searchMatch(for: record))
        #expect(match.item.mediaID == reference)
        #expect(match.item.name == "Fixture Movie")
        #expect(match.source.id == source.id)
        store.clear(sourceID: source.id)
        #expect(store.searchMatch(for: record) == nil)
    }

    @Test(arguments: [false, true], [AppleMediaServerKind.jellyfin, .emby, .plex])
    func indexedServerTitleResolvesWithoutAShelfOrDetailCache(hasCanonicalMatch: Bool, kind: AppleMediaServerKind) async throws {
        let source = AppleSource(kind: .mediaServer, name: "Fixture", url: try #require(URL(string: "https://fixture.example")))
        let reference = AppleMediaServerItemReference(sourceID: source.id, itemID: "outside-shelf")
        let item = AppleCatalogItem(mediaID: reference.mediaID, type: "movie", name: "Indexed Library Movie")
        let availability = AppleMediaIngestion.catalogRecord(instanceID: source.id, item: item).availability
        let record = AppleMediaRecord(canonicalID: hasCanonicalMatch ? "tt0000001" : nil,
            kind: .movie, title: item.name, availability: availability)
        let root = FileManager.default.temporaryDirectory.appending(path: "server-search-cold-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "index.json")
        let index = AppleMediaIndexRepository(fileURL: file)
        var legacy = AppleMediaRecord(canonicalID: record.canonicalID, kind: record.kind, title: record.title,
            availability: [.init(instanceID: source.id, capability: .resolvable,
                itemReference: "movie|\(reference.mediaID)", lastVerified: .distantPast)])
        legacy.isFavorite = true
        legacy.progress = 0.4
        let unresolved = AppleMediaRecord(kind: .movie, title: "Old unresolvable title",
            availability: [.init(instanceID: source.id, capability: .resolvable,
                itemReference: "movie|\(AppleMediaServerItemReference(sourceID: source.id, itemID: "deleted").mediaID)")],
            isFavorite: true, progress: 0.2)
        try await index.replace(instanceID: source.id, with: [legacy, unresolved])
        #expect(AppleCatalogSearchMatch.indexed(legacy, sources: [source]) == nil)
        let scans = Mutex(0)
        let loader: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse) = { request in
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            let body: String
            if url.path == "/library/sections" {
                body = #"{"MediaContainer":{"Directory":[{"key":"1","type":"movie","title":"Movies"}]}}"#
            } else if url.lastPathComponent == "all" {
                scans.withLock { $0 += 1 }
                body = request.value(forHTTPHeaderField: "X-Plex-Container-Start") == "0"
                    ? #"{"MediaContainer":{"totalSize":2,"Metadata":[{"ratingKey":"other","key":"/library/metadata/other","title":"Other","type":"movie"}]}}"#
                    : #"{"MediaContainer":{"totalSize":2,"Metadata":[{"ratingKey":"outside-shelf","key":"/library/metadata/outside-shelf","title":"Indexed Library Movie","type":"movie"}]}}"#
            } else if url.lastPathComponent == "Items" {
                scans.withLock { $0 += 1 }
                let offset = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                    .first { $0.name == "StartIndex" }?.value
                body = offset == "0"
                    ? #"{"Items":[{"Id":"other","Name":"Other","Type":"Movie"}],"TotalRecordCount":2}"#
                    : #"{"Items":[{"Id":"outside-shelf","Name":"Indexed Library Movie","Type":"Movie"}],"TotalRecordCount":2}"#
            } else {
                body = #"{"Items":[],"MediaContainer":{}}"#
            }
            return (Data(body.utf8), response)
        }
        let domain = "legacy-server-search-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let library = AppleMediaServerLibraryStore(client: .init(loader: loader), plexClient: .init(loader: loader),
            progressDefaults: defaults)
        let session = AppleMediaServerSession(kind: kind, baseURL: source.url, accessToken: "fixture", userID: "user")
        await library.reload(sources: [source]) { _ in session }
        #expect(library.shelves.allSatisfy { $0.items.isEmpty })
        #expect(library.continueWatching.isEmpty)
        let refreshed = AppleMediaIndexStore(repository: .init(fileURL: file))
        try await refreshed.upsert(await library.reindexedLegacyRecords(await index.records()))
        let reloaded = AppleMediaIndexRepository(fileURL: file)
        let indexed = try #require(await reloaded.search(item.name).first)
        let match = try #require(AppleCatalogSearchMatch.indexed(indexed, sources: [source]))
        #expect(match.item.mediaID == reference.mediaID)
        #expect(match.source.id == source.id)
        #expect(indexed.isFavorite)
        #expect(indexed.progress == 0.4)
        let missing = try #require(await reloaded.search(unresolved.title).first)
        #expect(missing.isFavorite)
        #expect(missing.progress == unresolved.progress)
        #expect(missing.availability.first?.isStale == true)
        #expect(AppleCatalogSearchMatch.indexed(missing, sources: [source]) == nil)
        await library.reload(sources: [source]) { _ in session }
        #expect(await library.reindexedLegacyRecords(await reloaded.records()).isEmpty)
        #expect(scans.withLock { $0 } == 2)
    }

    @Test(arguments: [AppleMediaServerKind.jellyfin, .emby, .plex], ["empty", "partial", "failed", "complete"])
    func legacyReindexRetriesAfterAnEmptyPartialOrMissingResult(kind: AppleMediaServerKind, responseKind: String) async throws {
        let source = AppleSource(kind: .mediaServer, name: "Fixture", url: try #require(URL(string: "https://fixture.example")))
        let reference = AppleMediaServerItemReference(sourceID: source.id, itemID: "saved")
        let record = AppleMediaRecord(kind: .movie, title: "Saved title", availability: [
            .init(instanceID: source.id, capability: .resolvable, itemReference: "movie|\(reference.mediaID)")])
        let recovered = Mutex(false)
        let scans = Mutex(0)
        let loader: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse) = { request in
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            let body: String
            if url.path == "/library/sections" {
                body = #"{"MediaContainer":{"Directory":[{"key":"1","type":"movie","title":"Movies"}]}}"#
            } else if url.lastPathComponent == "all" || url.lastPathComponent == "Items" {
                scans.withLock { $0 += 1 }
                let isRecovered = recovered.withLock { $0 }
                let offset = request.value(forHTTPHeaderField: "X-Plex-Container-Start")
                    ?? URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                        .first { $0.name == "StartIndex" }?.value
                if responseKind == "failed", !isRecovered, offset != "0" {
                    throw URLError(.networkConnectionLost)
                }
                let itemID = isRecovered ? "saved" : "other"
                let hasItem = isRecovered || (responseKind != "empty" && offset == "0")
                let total = isRecovered || responseKind == "complete" ? 1 : (responseKind == "empty" ? 0 : 3)
                if kind == .plex {
                    let items = hasItem ? #"[{"ratingKey":"\#(itemID)","key":"/library/metadata/\#(itemID)","title":"Saved title","type":"movie"}]"# : "[]"
                    body = #"{"MediaContainer":{"totalSize":\#(total),"Metadata":\#(items)}}"#
                } else {
                    let items = hasItem ? #"[{"Id":"\#(itemID)","Name":"Saved title","Type":"Movie"}]"# : "[]"
                    body = #"{"Items":\#(items),"TotalRecordCount":\#(total)}"#
                }
            } else {
                body = #"{"Items":[],"MediaContainer":{}}"#
            }
            return (Data(body.utf8), response)
        }
        let domain = "legacy-server-retry-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let library = AppleMediaServerLibraryStore(client: .init(loader: loader), plexClient: .init(loader: loader),
            progressDefaults: defaults)
        let session = AppleMediaServerSession(kind: kind, baseURL: source.url, accessToken: "fixture", userID: "user")
        await library.reload(sources: [source]) { _ in session }
        let now = Date.now
        let first = await library.reindexedLegacyRecords([record], now: now)
        if responseKind == "complete" {
            #expect(first.first?.availability.first?.isStale == true)
        } else {
            #expect(first.isEmpty, "An empty or incomplete scan must leave the saved route untouched")
        }
        recovered.withLock { $0 = true }
        if responseKind == "complete" {
            let initialScans = scans.withLock { $0 }
            await library.reload(sources: [source]) { _ in session }
            #expect(await library.reindexedLegacyRecords(first, now: now.addingTimeInterval(24 * 60 * 60 - 1)).isEmpty)
            #expect(scans.withLock { $0 } == initialScans)
        }
        let retried = try #require(await library.reindexedLegacyRecords(first.isEmpty ? [record] : first,
            now: now.addingTimeInterval(24 * 60 * 60)).first)
        #expect(retried.availability.first?.serverItemID == "saved")
        #expect(retried.availability.first?.isStale != true)
    }

    @Test(arguments: [AppleMediaServerKind.jellyfin, .emby, .plex])
    func legacyEpisodeRouteReindexesWithItsEpisodeIdentity(kind: AppleMediaServerKind) async throws {
        let source = AppleSource(kind: .mediaServer, name: "Fixture", url: try #require(URL(string: "https://fixture.example")))
        let reference = AppleMediaServerItemReference(sourceID: source.id, itemID: "episode")
        var route = AppleMediaAvailability(instanceID: source.id, capability: .resolvable,
            itemReference: "episode|\(reference.mediaID)", lastVerified: .distantPast)
        route.isStale = true
        let record = AppleMediaRecord(kind: .episode, title: "Saved episode", availability: [route])
        let loader: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse) = { request in
            let url = try #require(request.url)
            let body: String
            if url.path == "/library/sections" {
                body = #"{"MediaContainer":{"Directory":[{"key":"1","type":"show","title":"Shows"}]}}"#
            } else if url.lastPathComponent == "all" {
                let type = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "type" }?.value
                body = type == "4"
                    ? #"{"MediaContainer":{"totalSize":1,"Metadata":[{"ratingKey":"episode","key":"/library/metadata/episode","title":"Saved episode","type":"episode"}]}}"#
                    : #"{"MediaContainer":{"totalSize":0,"Metadata":[]}}"#
            } else if url.lastPathComponent == "Items" {
                body = #"{"Items":[{"Id":"episode","Name":"Saved episode","Type":"Episode"}],"TotalRecordCount":1}"#
            } else {
                body = #"{"Items":[],"MediaContainer":{}}"#
            }
            return (Data(body.utf8), try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
        let domain = "legacy-server-episode-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let library = AppleMediaServerLibraryStore(client: .init(loader: loader), plexClient: .init(loader: loader),
            progressDefaults: defaults)
        let session = AppleMediaServerSession(kind: kind, baseURL: source.url, accessToken: "fixture", userID: "user")
        await library.reload(sources: [source]) { _ in session }
        let updated = try #require(await library.reindexedLegacyRecords([record]).first)
        #expect(updated.availability.first?.serverItemID == reference.itemID)
        #expect(updated.availability.first?.itemReference == route.itemReference)
        #expect(updated.availability.first?.isStale != true)
    }

    @Test(arguments: [AppleMediaServerKind.jellyfin, .emby, .plex])
    func legacyReindexBoundsPagesAcrossSectionsAndBacksOffStaleRoutes(kind: AppleMediaServerKind) async throws {
        let source = AppleSource(kind: .mediaServer, name: "Fixture", url: try #require(URL(string: "https://fixture.example")))
        var staleRoute = AppleMediaAvailability(instanceID: source.id, capability: .resolvable,
            itemReference: "missing-stale", lastVerified: .distantPast)
        staleRoute.isStale = true
        let stale = AppleMediaRecord(kind: .movie, title: "Missing stale title", availability: [staleRoute])
        let fresh = AppleMediaRecord(kind: .movie, title: "Unverified title", availability: [
            .init(instanceID: source.id, capability: .resolvable, itemReference: "missing-fresh")])
        let scans = Mutex(0)
        let loader: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse) = { request in
            let url = try #require(request.url)
            let body: String
            if url.path == "/library/sections" {
                body = #"{"MediaContainer":{"Directory":[{"key":"1","type":"show","title":"First"},{"key":"2","type":"show","title":"Second"}]}}"#
            } else if url.lastPathComponent == "all" || url.lastPathComponent == "Items" {
                let count = scans.withLock { $0 += 1; return $0 }
                guard count <= 101 else { throw URLError(.badServerResponse) }
                if kind == .plex {
                    body = #"{"MediaContainer":{"totalSize":60,"Metadata":[{"ratingKey":"other","key":"/library/metadata/other","title":"Other","type":"show"}]}}"#
                } else {
                    body = #"{"Items":[{"Id":"other","Name":"Other","Type":"Series"}],"TotalRecordCount":10000}"#
                }
            } else {
                body = #"{"Items":[],"MediaContainer":{}}"#
            }
            return (Data(body.utf8), try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
        let domain = "legacy-server-page-bound-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let library = AppleMediaServerLibraryStore(client: .init(loader: loader), plexClient: .init(loader: loader),
            progressDefaults: defaults)
        let session = AppleMediaServerSession(kind: kind, baseURL: source.url, accessToken: "fixture", userID: "user")
        await library.reload(sources: [source]) { _ in session }
        let now = Date.now
        let updated = await library.reindexedLegacyRecords([fresh, stale], now: now)
        #expect(scans.withLock { $0 } == 100)
        #expect(updated.count == 1, "A bounded, incomplete scan must not mark a fresh route stale")
        let retried = try #require(updated.first)
        #expect(retried.id == stale.id)
        #expect(retried.availability.first?.isStale == true)
        #expect(retried.availability.first?.lastVerified == now)
        await library.reload(sources: [source]) { _ in session }
        #expect(await library.reindexedLegacyRecords(updated, now: now.addingTimeInterval(60)).isEmpty)
        #expect(scans.withLock { $0 } == 100)
    }

    @Test(arguments: [false, true])
    func legacyReindexRetainsOfflineAndSignedOutRecords(hasSession: Bool) async throws {
        let source = AppleSource(kind: .mediaServer, name: "Fixture", url: try #require(URL(string: "https://fixture.example")))
        let record = AppleMediaRecord(kind: .movie, title: "Saved server title",
            availability: [.init(instanceID: source.id, capability: .resolvable, itemReference: "legacy")],
            isFavorite: true, progress: 0.4)
        let client = AppleMediaServerClient(loader: { request in
            let url = try #require(request.url)
            if url.lastPathComponent == "Items" { throw URLError(.notConnectedToInternet) }
            return (Data(#"{"Items":[]}"#.utf8),
                try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        })
        let domain = "legacy-server-offline-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let library = AppleMediaServerLibraryStore(client: client, progressDefaults: defaults)
        let session = AppleMediaServerSession(kind: .jellyfin, baseURL: source.url, accessToken: "fixture", userID: "user")
        await library.reload(sources: [source]) { _ in hasSession ? session : nil }
        #expect(await library.reindexedLegacyRecords([record]).isEmpty)
    }

    @Test func legacyReindexDoesNotRestoreMyListOrProgressRemovedDuringTheScan() async throws {
        let source = AppleSource(kind: .mediaServer, name: "Fixture", url: try #require(URL(string: "https://fixture.example")))
        let reference = AppleMediaServerItemReference(sourceID: source.id, itemID: "saved")
        let record = AppleMediaRecord(kind: .movie, title: "Saved server title",
            availability: [.init(instanceID: source.id, capability: .resolvable,
                itemReference: "movie|\(reference.mediaID)")], isFavorite: true, progress: 0.4)
        let client = AppleMediaServerClient(loader: { request in
            let url = try #require(request.url)
            let body = url.lastPathComponent == "Items"
                ? #"{"Items":[{"Id":"saved","Name":"Saved server title","Type":"Movie"}],"TotalRecordCount":1}"#
                : #"{"Items":[]}"#
            return (Data(body.utf8),
                try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        })
        let domain = "legacy-server-edits-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let library = AppleMediaServerLibraryStore(client: client, progressDefaults: defaults)
        let session = AppleMediaServerSession(kind: .jellyfin, baseURL: source.url, accessToken: "fixture", userID: "user")
        await library.reload(sources: [source]) { _ in session }
        let reindexed = await library.reindexedLegacyRecords([record])
        let file = FileManager.default.temporaryDirectory.appending(path: "legacy-server-edits-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let repository = AppleMediaIndexRepository(fileURL: file)
        try await repository.upsert(record)
        try await repository.setFavorite(false, recordID: record.id)
        try await repository.updateProgress([:])
        try await repository.upsert(reindexed)
        let saved = try #require(await repository.records().first)
        #expect(saved.availability.first?.serverItemID == reference.itemID)
        #expect(saved.isFavorite == false)
        #expect(saved.progress == nil)
    }

    @Test func tenThousandServerItemsReloadAndResolveWithoutAnotherSearchIndex() async throws {
        let source = AppleSource(kind: .mediaServer, name: "Fixture", url: try #require(URL(string: "https://fixture.example")))
        let latest = try JSONSerialization.data(withJSONObject: (0..<10_000).map {
            ["Id": "movie-\($0)", "Name": "Fixture Movie \($0)", "Type": "Movie"]
        })
        let client = AppleMediaServerClient(loader: { request in
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            switch url.lastPathComponent {
            case "Views":
                return (Data(#"{"Items":[{"Id":"movies","Name":"Movies","CollectionType":"movies"}]}"#.utf8), response)
            case "Latest": return (latest, response)
            default: return (Data(#"{"Items":[],"TotalRecordCount":0}"#.utf8), response)
            }
        })
        let domain = "server-search-large-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = AppleMediaServerLibraryStore(client: client, progressDefaults: defaults)
        let session = AppleMediaServerSession(kind: .jellyfin, baseURL: source.url, accessToken: "fixture", userID: "user")
        let start = ContinuousClock.now
        await store.reload(sources: [source]) { _ in session }
        print("SERVER_RELOAD_10K duration=\(start.duration(to: .now))")
        #expect(store.shelves.first?.items.count == 10_000)
        let last = try #require(store.shelves.first?.items.last)
        let record = AppleMediaIngestion.catalogRecord(instanceID: source.id, item: last)
        #expect(store.searchMatch(for: record)?.item.mediaID == last.mediaID)
    }

    @Test func indexedServerTitleOutsideShelvesResolvesAndRefreshEvictsItsLookup() async throws {
        let source = AppleSource(kind: .mediaServer, name: "Fixture", url: try #require(URL(string: "https://fixture.example")))
        let reference = AppleMediaServerItemReference(sourceID: source.id, itemID: "outside-shelf")
        let client = AppleMediaServerClient(loader: { request in
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            let body = url.lastPathComponent == "outside-shelf"
                ? #"{"Id":"outside-shelf","Name":"Indexed Library Movie","Type":"Movie","ProductionYear":2024}"#
                : #"{"Items":[],"TotalRecordCount":0}"#
            return (Data(body.utf8), response)
        })
        let domain = "server-search-library-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = AppleMediaServerLibraryStore(client: client, progressDefaults: defaults)
        let session = AppleMediaServerSession(kind: .jellyfin, baseURL: source.url, accessToken: "fixture", userID: "user")
        await store.reload(sources: [source]) { _ in session }
        let detail = try await store.detail(for: reference)
        #expect(store.shelves.isEmpty)
        #expect(store.continueWatching.isEmpty)
        let item = store.catalogItem(detail.item, source: source, session: session)
        let root = FileManager.default.temporaryDirectory.appending(path: "server-search-index-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let index = AppleMediaIndexRepository(fileURL: root.appending(path: "index.json"))
        try await index.replace(instanceID: source.id, with: [AppleMediaIngestion.catalogRecord(instanceID: source.id, item: item)])
        let record = try #require(await index.search("Indexed Library Movie").first)
        let match = try #require(store.searchMatch(for: record))
        #expect(match.item.mediaID == reference.mediaID)
        #expect(match.item.name == "Indexed Library Movie")
        await store.reload(sources: [source]) { _ in session }
        #expect(store.searchMatch(for: record) == nil)
    }

    @Test func eachDisplayedMatchIsResolvedOncePerResultSet() async throws {
        let source = AppleSource(kind: .library, name: "Fixture", url: URL(fileURLWithPath: "/fixture"))
        let record = AppleMediaRecord(kind: .movie, title: "John Wick",
            availability: [.init(instanceID: source.id, capability: .direct, itemReference: "wick")])
        let subject = store()
        var resolutions = 0
        await subject.search(query: "wick", resolveMatch: {
            resolutions += 1
            return AppleCatalogSearchMatch.indexed($0, sources: [source])
        }) { _ in [record, record] }
        #expect(resolutions == 1)
        let row = try #require(subject.rows.first)
        #expect(row.record == record)
        #expect(row.match.item.name == "John Wick")
        #expect(subject.rows.count == 1)
        #expect(resolutions == 1)
    }

    @Test func cancelledRevisionUpdatesDoNotRestartSearch() async {
        let subject = store()
        let cancelled = Task { @MainActor in await subject.coalesceRevision("scan-1") }
        cancelled.cancel()
        await cancelled.value
        #expect(subject.contentRevision.isEmpty)
        await subject.coalesceRevision("scan-2")
        #expect(subject.contentRevision == "scan-2")
        #expect(subject.results.isEmpty)
    }

    @Test func sharedLinksIgnoreContentRevisionsButTextQueriesRefresh() async {
        let subject = store()
        let query = subject.taskIdentity(query: "wick")
        let link = "https://www.imdb.com/title/tt2911666/"
        let sharedLink = subject.taskIdentity(query: link)
        await subject.coalesceRevision("scan-complete")
        #expect(subject.taskIdentity(query: "wick") != query)
        #expect(subject.taskIdentity(query: "wick 4") != subject.taskIdentity(query: "wick"))
        #expect(subject.taskIdentity(query: link) == sharedLink)
    }

    @Test(arguments: [AppleMediaKind.video, .movie, .channel])
    func enabledFilesServerTitlesAndChannelsKeepTitlePageRows(kind: AppleMediaKind) async throws {
        let source = AppleSource(kind: kind == .movie ? .mediaServer : .library,
            name: "Fixture", url: URL(fileURLWithPath: "/fixture"))
        let retained = AppleMediaRecord(kind: kind, title: "Fixture Star",
            availability: [.init(instanceID: source.id, capability: .direct, itemReference: "star",
                serverItemID: kind == .movie ? "star" : nil)])
        let subject = store()
        await subject.search(query: "star", resolveMatch: { AppleCatalogSearchMatch.indexed($0, sources: [source]) }) { _ in [retained] }
        #expect(subject.rows.count == 1)
        #expect(subject.rows.first?.match.source.id == source.id)
        await subject.search(query: "star", resolveMatch: { AppleCatalogSearchMatch.indexed($0, sources: []) }) { _ in [retained] }
        #expect(subject.rows.isEmpty)
        var disabled = source
        disabled.isEnabled = false
        await subject.search(query: "star", resolveMatch: { AppleCatalogSearchMatch.indexed($0, sources: [disabled]) }) { _ in [retained] }
        #expect(subject.rows.isEmpty)
    }

    private func store() -> AppleCatalogSearchStore {
        AppleCatalogSearchStore(debounce: .milliseconds(1), maximumResults: 50, revisionDebounce: .zero)
    }

    private func record(
        _ kind: AppleMediaKind,
        _ title: String,
        year: Int? = nil,
        reference: String = UUID().uuidString,
        summary: String? = nil,
        artwork: URL? = nil
    ) -> AppleMediaRecord {
        AppleMediaRecord(
            canonicalID: reference,
            kind: kind,
            title: title,
            year: year,
            summary: summary,
            artworkURL: artwork,
            availability: [.init(instanceID: UUID(), capability: .direct, itemReference: reference)]
        )
    }

    /// Eight files on disk, one show.
    @Test func everyEpisodeFileOfAShowCollapsesToOneRow() async {
        let subject = store()
        let files = (1 ... 8).map { record(.video, "Jury Duty", year: 2023, reference: "s1e\($0)") }
        await subject.search(query: "jury duty") { _ in files }
        #expect(subject.results.count == 1)
        #expect(subject.results.first?.title == "Jury Duty")
    }

    /// A source that returns episodes has them dropped outright.
    @Test func episodeRecordsAreNotResults() async {
        let subject = store()
        let mixed = [
            record(.series, "Jury Duty", year: 2023),
            record(.episode, "Jury Duty", year: 2023, reference: "ep1"),
            record(.episode, "Jury Duty", year: 2023, reference: "ep2"),
        ]
        await subject.search(query: "jury duty") { _ in mixed }
        #expect(subject.results.count == 1)
        #expect(subject.results.allSatisfy { $0.kind != .episode })
    }

    /// The local copy and its catalog entry become one row that carries the
    /// catalog's artwork *and* both sources' availability.
    @Test func aLocalCopyMergesWithItsCatalogEntry() async {
        let subject = store()
        let local = record(.video, "Jury Duty", year: 2023, reference: "local")
        let catalog = record(
            .series, "Jury Duty", year: 2023, reference: "tt15557874",
            summary: "A man thinks he is a juror.",
            artwork: URL(string: "https://example.com/art.jpg")
        )
        await subject.search(query: "jury duty") { _ in [local, catalog] }
        #expect(subject.results.count == 1)
        let merged = subject.results.first
        #expect(merged?.summary != nil)
        #expect(merged?.artworkURL != nil)
        #expect(merged?.availability.count == 2)
    }

    /// Different years are different titles and must not merge.
    @Test func twoFilmsOfTheSameNameStaySeparate() async {
        let subject = store()
        let films = [record(.movie, "Dune", year: 1984), record(.movie, "Dune", year: 2021)]
        await subject.search(query: "dune") { _ in films }
        #expect(subject.results.count == 2)
    }

    /// The field offers "movies, shows, and channels" — live channels stay.
    @Test func channelsAreStillResults() async {
        let subject = store()
        await subject.search(query: "news") { _ in
            [self.record(.channel, "News Channel")]
        }
        #expect(subject.results.count == 1)
        #expect(subject.results.first?.kind == .channel)
    }

    /// Apple TV regression 2026-10-01: the exact title sat under near
    /// matches left over from the half-typed query until the search answered.
    @Test func rowsReRankForTheTypedQueryBeforeTheSearchAnswers() async {
        let subject = store()
        let typed = [record(.movie, "Saturday Night Life", year: 2006),
                     record(.series, "Saturday Night Lights", year: 2026),
                     record(.series, "Saturday Night Live", year: 1975)]
        await subject.search(query: "saturday night li") { _ in typed }
        #expect(subject.results.first?.title == "Saturday Night Life")

        let (gate, release) = AsyncStream<Void>.makeStream()
        let pending = Task { @MainActor in
            await subject.search(query: "saturday night live") { _ in
                for await _ in gate { break }
                return typed
            }
        }
        while !subject.isSearching { await Task.yield() }
        #expect(subject.results.map(\.title) == ["Saturday Night Live"])
        release.yield()
        release.finish()
        await pending.value
        #expect(subject.results.first?.title == "Saturday Night Live")
    }
}
