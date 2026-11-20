import Foundation
import Observation
import Synchronization
import Testing
@testable import OpenStreamApple

@MainActor
struct AppleStartupCacheTests {
    private let source = AppleSource(kind: .mediaServer, name: "Fixture", url: URL(string: "https://fixture.example")!)

    /// Rill's feed (`AppleOStreamFeed`) is off on these servers: answered before any gate.
    nonisolated private func feedOff(_ request: URLRequest) throws -> (Data, URLResponse)? {
        let url = try #require(request.url)
        guard url.path.hasSuffix("/OStream/Feed") else { return nil }
        return (Data(), try #require(HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)))
    }

    nonisolated private func response(_ request: URLRequest, _ json: String) throws -> (Data, URLResponse) {
        let url = try #require(request.url)
        return (Data(json.utf8), try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
    }

    @Test(arguments: [AppleMediaServerKind.jellyfin, .plex])
    func cachedServerRowsRestoreTheirArtworkWithoutANetworkRequest(kind: AppleMediaServerKind) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = directory.appendingPathComponent("servers.json")
        let client = AppleMediaServerClient(loader: { request in
            if let off = try self.feedOff(request) { return off }
            let path = try #require(request.url?.path)
            let json: String
            if path.hasSuffix("Views") {
                json = #"{"Items":[{"Id":"movies","Name":"Movies","CollectionType":"movies"}]}"#
            } else if path.hasSuffix("Latest") {
                json = "[" + (0..<8).map { #"{"Id":"item\#($0)","Name":"Movie \#($0)","Type":"Movie","ImageTags":{"Primary":"tag"}}"# }.joined(separator: ",") + "]"
            } else { json = #"{"Items":[],"TotalRecordCount":0}"# }
            return try self.response(request, json)
        })
        let plex = ApplePlexClient(loader: { request in
            let path = try #require(request.url?.path)
            let json: String
            if path == "/library/sections" {
                json = #"{"MediaContainer":{"Directory":[{"key":"movies","title":"Movies","type":"movie"}]}}"#
            } else if path == "/library/recentlyAdded" {
                json = #"{"MediaContainer":{"Metadata":["# + (0..<8).map {
                    #"{"ratingKey":"item\#($0)","key":"/library/metadata/item\#($0)","type":"movie","title":"Movie \#($0)","thumb":"/library/metadata/item\#($0)/thumb/tag","duration":1000000,"viewOffset":50000,"lastViewedAt":1700000100}"#
                }.joined(separator: ",") + "]}}"
            } else { json = #"{"MediaContainer":{"Hub":[],"Metadata":[]}}"# }
            return try self.response(request, json)
        })
        let session = AppleMediaServerSession(kind: kind, baseURL: source.url, accessToken: "fixture-secret", userID: "fixture")
        let writer = AppleMediaServerLibraryStore(client: client, plexClient: plex, cacheFileURL: cache)
        await writer.reload(sources: [source]) { _ in session }
        let saved = try String(contentsOf: cache, encoding: .utf8)
        #expect(!saved.contains("fixture-secret"))
        let restored = AppleMediaServerLibraryStore(cacheFileURL: cache)
        let start = ContinuousClock.now
        restored.loadPersisted(sources: [source]) { _ in session }
        #expect(restored.shelves.map(\.id) == writer.shelves.map(\.id))
        #expect(restored.shelves.first?.items.first?.posterURL == writer.shelves.first?.items.first?.posterURL)
        if kind == .plex {
            let reference = AppleMediaServerItemReference(sourceID: source.id, itemID: "item0")
            #expect(restored.plexItem(for: reference) == writer.plexItem(for: reference))
        }
        #expect(AppleDiscoverServerRows.rows(restored.shelves, sources: [source]).count == 1)
        print("PRELOAD_MEASURE server_cache_restore_ms=\(AppleLaunchMarks.milliseconds(start.duration(to: .now)))")
        restored.loadPersisted(sources: []) { _ in session }
        #expect(restored.shelves.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func aFastLibraryPublishesWhileAnotherLibraryIsStillPending() async throws {
        let gate = AsyncStream<Void>.makeStream()
        let publishedBeforeRelease = Mutex(false)
        let client = AppleMediaServerClient(loader: { request in
            if let off = try self.feedOff(request) { return off }
            let path = try #require(request.url?.path)
            let json: String
            if path.hasSuffix("Views") {
                json = #"{"Items":[{"Id":"slow","Name":"Slow","CollectionType":"movies"},{"Id":"fast","Name":"Fast","CollectionType":"movies"}]}"#
            } else if path.hasSuffix("Latest") {
                let parent = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "ParentId" }?.value
                if parent == "slow" { for await _ in gate.stream {} }
                json = #"[{"Id":"\#(parent ?? "missing")","Name":"Fixture","Type":"Movie"}]"#
            } else { json = #"{"Items":[],"TotalRecordCount":0}"# }
            return try self.response(request, json)
        })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppleMediaServerLibraryStore(client: client, cacheFileURL: directory.appendingPathComponent("rows.json"))
        withObservationTracking { _ = store.shelves } onChange: {
            publishedBeforeRelease.withLock { $0 = true }
            gate.continuation.finish()
        }
        defer { gate.continuation.finish() }
        let session = AppleMediaServerSession(kind: .jellyfin, baseURL: source.url, accessToken: "fixture", userID: "fixture")
        await store.reload(sources: [source]) { _ in session }
        #expect(publishedBeforeRelease.withLock { $0 })
        #expect(store.shelves.count == 2)
    }

    @Test func latestRowsTakeTheIncomingOrderWithinTheSameSession() {
        let cache = AppleDiscoverServerRows.Cache()
        func item(_ id: Int, name: String = "Title") -> AppleCatalogItem {
            .init(mediaID: "item\(id)", type: "movie", name: "\(name) \(id)", posterURL: URL(string: "https://fixture.example/\(id).jpg"))
        }
        func shelf(_ values: [AppleCatalogItem]) -> AppleMediaServerLibraryStore.Shelf {
            .init(id: "movies:latest", title: "Latest", sourceID: source.id, items: values, collectionType: .movies, discoverySort: .latest)
        }
        let first = cache.rows(revision: 1, shelves: [shelf((0..<8).map { item($0) })], sources: [source], pendingShelfIDs: [])
        let updated = cache.rows(revision: 2, shelves: [shelf([item(8)] + (0..<8).reversed().map { item($0, name: "Updated") })], sources: [source], pendingShelfIDs: [])
        #expect(first.first?.items.first?.id == item(0).id)
        #expect(updated.first?.items.map(\.id) == [8, 7, 6, 5, 4, 3, 2, 1, 0].map { item($0).id })
    }

    @Test func mergedInputsRetainTheirTitlesUntilDisplayOrderDedupe() {
        let cache = AppleDiscoverServerRows.Cache()
        func shelf(_ id: String, values: Range<Int>, sort: AppleMediaServerLibraryStore.Shelf.DiscoverySort) -> AppleMediaServerLibraryStore.Shelf {
            .init(id: id, title: id, sourceID: source.id, items: values.map {
                .init(mediaID: "item\($0)", type: "movie", name: "Title \($0)", posterURL: URL(string: "https://fixture.example/\($0).jpg"))
            }, collectionType: .movies, discoverySort: sort)
        }
        let top = shelf("top", values: 8..<16, sort: .top)
        let first = cache.rows(revision: 1, shelves: [shelf("latest", values: 0..<8, sort: .latest), top], sources: [source], pendingShelfIDs: [])
        let refreshed = cache.rows(revision: 2, shelves: [shelf("latest", values: 0..<16, sort: .latest), top], sources: [source], pendingShelfIDs: [])
        #expect(refreshed.map(\.id) == first.map(\.id))
        #expect(refreshed.last?.items.map(\.id) == first.last?.items.map(\.id))
        #expect(refreshed.first?.items.count == 16)
        let nextSession = AppleDiscoverServerRows.Cache().rows(revision: 2,
            shelves: [shelf("latest", values: 0..<16, sort: .latest), top], sources: [source], pendingShelfIDs: [])
        #expect(nextSession.count == 2)
        #expect(nextSession.first?.items.count == 16)
    }

    @Test func localRowsArrivingLaterUseHomeOrder() {
        let servers: [AppleDiscoverView.DiscoverRail] = [.mediaServer("movies"), .mediaServer("shows")]
        let first = AppleDiscoverView.RailOrder.rows(servers, previous: [], serverIDs: ["movies", "shows"])
        #expect(first == servers)
        let incoming: [AppleDiscoverView.DiscoverRail] = [.library] + servers
        let result = AppleDiscoverView.RailOrder.rows(incoming, previous: first, serverIDs: ["movies", "shows"])
        #expect(result == [.library] + servers)
        #expect(AppleDiscoverView.RailOrder.rows(incoming, previous: first, serverIDs: ["movies", "shows"]) == result)
    }

    @Test func staleChannelsRestoreAndPersistTheProvidersNewOrder() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceID = UUID()
        func channel(_ id: String, name: String) -> AppleIPTVChannel {
            .init(id: id, sourceID: sourceID, name: name, streamURL: URL(string: "https://fixture.example/\(id).ts")!)
        }
        let original = [channel("a", name: "A"), channel("b", name: "B")]
        await AppleIPTVChannelCache(directory: directory).store(original, for: sourceID, now: .distantPast)
        let restored = AppleIPTVChannelCache(directory: directory)
        let start = ContinuousClock.now
        #expect(await restored.snapshot(for: sourceID)?.channels == original)
        print("PRELOAD_MEASURE channel_cache_restore_ms=\(AppleLaunchMarks.milliseconds(start.duration(to: .now)))")
        let refreshed = await restored.reconcileAndStore([channel("b", name: "Updated B"), channel("a", name: "Updated A"), channel("c", name: "C")], for: sourceID)
        #expect(refreshed.map(\.id) == ["b", "a", "c"])
        #expect(refreshed.first?.name == "Updated B")
        #expect(await AppleIPTVChannelCache(directory: directory).snapshot(for: sourceID)?.channels == refreshed)
        let largeLineup = (0..<10_000).map { channel("channel\($0)", name: "Channel \($0)") }
        await restored.store(largeLineup, for: sourceID)
        let cold = AppleIPTVChannelCache(directory: directory)
        let largeStart = ContinuousClock.now
        #expect(await cold.snapshot(for: sourceID)?.channels.count == largeLineup.count)
        print("PRELOAD_MEASURE channel_cache_count=10000 restore_ms=\(AppleLaunchMarks.milliseconds(largeStart.duration(to: .now)))")
    }

    @Test func aNewGuideStoreRestoresStaleNowAndNextBeforeRefresh() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceID = UUID()
        let channelID = sourceID.uuidString + ":1"
        let now = Date()
        let programmes = [(-60.0, 1800.0), (1800.0, 3600.0)].enumerated().map { index, window in
            AppleIPTVProgramme(id: "programme\(index)", channelID: channelID, title: "Fixture \(index)",
                subtitle: nil, description: nil, start: now.addingTimeInterval(window.0), end: now.addingTimeInterval(window.1), category: nil, isLive: true)
        }
        let url = URL(string: "https://fixture.example")!
        let disk = AppleIPTVGuideDiskCache(directory: directory)
        let evidence = AppleIPTVGuideMappingEvidence(providerID: "1", declaredProviderID: "1", origin: .providerID,
            confidence: 1, defaultOffsetHours: 0, channelShiftHours: 0, correctionHours: 0,
            fetchedAt: now.addingTimeInterval(-3600), coverage: [], isStale: false)
        await disk.store(programmes, key: sourceID.uuidString + "|evidence-v2|xtream|" + url.absoluteString + "|fixture|fixture",
            mappingEvidence: [channelID: evidence], now: now)
        let store = AppleIPTVGuideStore(diskCache: AppleIPTVGuideDiskCache(directory: directory))
        store.configure(xtreamBase: url, username: "fixture", password: "fixture", sourceID: sourceID)
        let start = ContinuousClock.now
        await store.restorePersisted(now: now)
        let restored = store.guide(for: [channelID]).nowAndNext(channelID: channelID, at: now)
        #expect(restored.now?.id == "programme0")
        #expect(restored.next?.id == "programme1")
        print("PRELOAD_MEASURE guide_cache_restore_ms=\(AppleLaunchMarks.milliseconds(start.duration(to: .now)))")
    }

    @Test(.timeLimit(.minutes(1))) func seventyLibrariesPublishProgressivelyWithinTheRequestBudget() async throws {
        let counters = Mutex((active: 0, peak: 0))
        let gate = StartupRequestGate()
        let client = AppleMediaServerClient(loader: { request in
            if let off = try self.feedOff(request) { return off }
            counters.withLock { $0.active += 1; $0.peak = max($0.peak, $0.active) }
            defer { counters.withLock { $0.active -= 1 } }
            await gate.arriveAndWait(releasingAt: AppleMediaServerLibraryStore.maximumConcurrentLibraryRequestsPerSource)
            let path = try #require(request.url?.path)
            let json: String
            if path.hasSuffix("Views") {
                json = #"{"Items":["# + (0..<70).map {
                    #"{"Id":"lib\#($0)","Name":"Library \#($0)","CollectionType":"movies"}"#
                }.joined(separator: ",") + "]}"
            } else if path.hasSuffix("Latest") {
                let parent = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "ParentId" }?.value ?? "missing"
                json = "[" + (0..<8).map {
                    #"{"Id":"\#(parent)-\#($0)","Name":"Title \#(parent) \#($0)","Type":"Movie","ImageTags":{"Primary":"tag"}}"#
                }.joined(separator: ",") + "]"
            } else { json = #"{"Items":[],"TotalRecordCount":0}"# }
            return try self.response(request, json)
        })
        let session = AppleMediaServerSession(kind: .jellyfin, baseURL: source.url, accessToken: "fixture", userID: "fixture")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppleMediaServerLibraryStore(client: client, cacheFileURL: directory.appendingPathComponent("rows.json"))
        let first = Mutex<ContinuousClock.Instant?>(nil)
        withObservationTracking { _ = store.shelves } onChange: { first.withLock { $0 = .now } }
        let after = ContinuousClock.now
        await store.reload(sources: [source]) { _ in session }
        let firstTime = try #require(first.withLock { $0 })
        let firstMS = AppleLaunchMarks.milliseconds(after.duration(to: firstTime))
        #expect(store.shelves.count == 70)
        #expect((AppleDiscoverServerRows.rows(store.shelves, sources: [source]).first?.items.count ?? 0) >= 6)
        #expect(counters.withLock { $0.peak } == AppleMediaServerLibraryStore.maximumConcurrentLibraryRequestsPerSource)
        #expect(store.shelves.map(\.title) == (0..<70).map { "Latest in Library \($0)" })
        print("PRELOAD_MEASURE libraries=70 progressive_first_ms=\(firstMS) progressive_complete_ms=\(AppleLaunchMarks.milliseconds(after.duration(to: .now))) peak_requests=\(counters.withLock { $0.peak })")
        let coldStore = AppleMediaServerLibraryStore(cacheFileURL: directory.appendingPathComponent("rows.json"))
        let restoreStart = ContinuousClock.now
        coldStore.loadPersisted(sources: [source]) { _ in session }
        #expect(coldStore.shelves == store.shelves)
        print("PRELOAD_MEASURE server_cache_shelves=70 server_cache_items=560 restore_ms=\(AppleLaunchMarks.milliseconds(restoreStart.duration(to: .now)))")
    }
    @Test func topRowOrderIsHeldOnlyByTheCurrentDisplaySession() {
        func shelf(_ ids: [Int]) -> AppleMediaServerLibraryStore.Shelf {
            .init(id: "top", title: "Top", sourceID: source.id, items: ids.map {
                .init(mediaID: "item\($0)", type: "movie", name: "Title \($0)", posterURL: URL(string: "https://fixture.example/\($0).jpg"))
            }, collectionType: .movies, discoverySort: .top)
        }
        let cache = AppleDiscoverServerRows.Cache()
        let first = cache.rows(revision: 1, shelves: [shelf(Array(0..<8))], sources: [source], pendingShelfIDs: [])
        let reversed = shelf(Array((0..<8).reversed()))
        let sameSession = cache.rows(revision: 2, shelves: [reversed], sources: [source], pendingShelfIDs: [])
        #expect(sameSession.first?.items == first.first?.items)
        let nextSession = AppleDiscoverServerRows.Cache().rows(revision: 2, shelves: [reversed], sources: [source], pendingShelfIDs: [])
        #expect(nextSession.first?.items == reversed.items)
    }

    @Test func recencyOrderAndSeriesDeduplicationSurviveReloadAndColdRestore() async throws {
        let refreshed = Mutex(false)
        let client = AppleMediaServerClient(loader: { request in
            if let off = try self.feedOff(request) { return off }
            let path = try #require(request.url?.path)
            let isNew = refreshed.withLock { $0 }
            let json: String
            if path.hasSuffix("Views") {
                json = #"{"Items":[{"Id":"shows","Name":"Shows","CollectionType":"tvshows"}]}"#
            } else if path.hasSuffix("Latest") {
                let ids = isNew ? ["new", "b", "a"] : ["a", "b"]
                json = "[" + ids.map { #"{"Id":"\#($0)","Name":"\#($0)","Type":"Series"}"# }.joined(separator: ",") + "]"
            } else if path.hasSuffix("Resume") {
                let ids = isNew ? ["new-movie", "resuming"] : ["resuming"]
                json = #"{"Items":["# + ids.map {
                    #"{"Id":"\#($0)","Name":"\#($0)","Type":"Episode","SeriesId":"\#($0)","RunTimeTicks":10000000000,"UserData":{"PlaybackPositionTicks":2000000000}}"#
                }.joined(separator: ",") + "]}"
            } else if path.hasSuffix("NextUp") {
                let ids = isNew ? ["next-new", "next-old"] : ["next-old", "next-new"]
                json = #"{"Items":[{"Id":"duplicate","Name":"Duplicate","Type":"Episode","SeriesId":"resuming"},"#
                    + ids.map { #"{"Id":"\#($0)","Name":"\#($0)","Type":"Episode","SeriesId":"\#($0)"}"# }.joined(separator: ",") + "]}"
            } else { json = #"{"Items":[]}"# }
            return try self.response(request, json)
        })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = directory.appendingPathComponent("rows.json")
        let session = AppleMediaServerSession(kind: .jellyfin, baseURL: source.url, accessToken: "fixture", userID: "fixture")
        let store = AppleMediaServerLibraryStore(client: client, cacheFileURL: cache)
        await store.reload(sources: [source]) { _ in session }
        #expect(store.continueWatching.map(\.name) == ["resuming", "next-old", "next-new"])
        refreshed.withLock { $0 = true }
        await store.reload(sources: [source]) { _ in session }
        #expect(store.shelves.first?.items.map(\.name) == ["new", "b", "a"])
        #expect(store.shelves.first { $0.title == "Next up in Shows" }?.items.map(\.name) == ["Duplicate", "next-new", "next-old"])
        #expect(store.continueWatching.map(\.name) == ["new-movie", "resuming", "next-new", "next-old"])
        let restored = AppleMediaServerLibraryStore(cacheFileURL: cache)
        restored.loadPersisted(sources: [source]) { _ in session }
        #expect(restored.shelves == store.shelves)
        #expect(restored.continueWatching == store.continueWatching)
    }

    @Test(.timeLimit(.minutes(1))) func aBlockedServerCannotUseAnotherSourcesRequestSlots() async throws {
        let slow = AppleSource(kind: .mediaServer, name: "Slow", url: URL(string: "https://slow.fixture.example")!)
        let fast = AppleSource(kind: .mediaServer, name: "Fast", url: URL(string: "https://fast.fixture.example")!)
        let gate = StartupRequestGate()
        let publishedWhileBlocked = Mutex(false)
        let client = AppleMediaServerClient(loader: { request in
            if let off = try self.feedOff(request) { return off }
            let url = try #require(request.url)
            let json: String
            if url.path.hasSuffix("Views") {
                if url.host == fast.url.host {
                    await gate.waitForArrivals(AppleMediaServerLibraryStore.maximumConcurrentLibraryRequestsPerSource)
                }
                json = #"{"Items":["# + (0..<6).map {
                    #"{"Id":"lib\#($0)","Name":"Library \#($0)","CollectionType":"movies"}"#
                }.joined(separator: ",") + "]}"
            } else if url.path.hasSuffix("Latest") {
                if url.host == slow.url.host {
                    // A scheduler exceeding the source budget releases itself so a regression fails without a timer.
                    await gate.arriveAndWait(releasingAt: AppleMediaServerLibraryStore.maximumConcurrentLibraryRequestsPerSource + 1)
                }
                let parent = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "ParentId" }?.value ?? "missing"
                json = #"[{"Id":"\#(parent)","Name":"\#(parent)","Type":"Movie"}]"#
            } else { json = #"{"Items":[]}"# }
            return try self.response(request, json)
        })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppleMediaServerLibraryStore(client: client, cacheFileURL: directory.appendingPathComponent("rows.json"))
        withObservationTracking { _ = store.shelves } onChange: {
            Task { @MainActor in
                let blocked = await !gate.isOpen
                publishedWhileBlocked.withLock { $0 = blocked && store.shelves.first?.sourceID == fast.id }
                await gate.release()
            }
        }
        await store.reload(sources: [slow, fast]) { source in
            .init(kind: .jellyfin, baseURL: source.url, accessToken: "fixture", userID: "fixture")
        }
        #expect(publishedWhileBlocked.withLock { $0 })
        #expect(store.shelves.map(\.sourceID) == Array(repeating: slow.id, count: 6) + Array(repeating: fast.id, count: 6))
        #expect(store.shelves.map(\.title) == (0..<6).map { "Latest in Library \($0)" } + (0..<6).map { "Latest in Library \($0)" })
    }

    @Test func genreTitlesAreUniqueAcrossLibrariesAndAgainstLatest() async throws {
        let client = AppleMediaServerClient(loader: { request in
            if let off = try self.feedOff(request) { return off }
            let path = try #require(request.url?.path)
            let json: String
            if path.hasSuffix("Views") {
                json = #"{"Items":[{"Id":"a","Name":"A","CollectionType":"movies"},{"Id":"b","Name":"B","CollectionType":"movies"}]}"#
            } else if path.hasSuffix("Latest") {
                json = #"[{"Id":"one","Name":"One","Type":"Movie","Genres":["Action","Latest in B"]},{"Id":"two","Name":"Two","Type":"Movie","Genres":["Action","Latest in B"]}]"#
            } else { json = #"{"Items":[]}"# }
            return try self.response(request, json)
        })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppleMediaServerLibraryStore(client: client, cacheFileURL: directory.appendingPathComponent("rows.json"))
        await store.reload(sources: [source]) { _ in .init(kind: .jellyfin, baseURL: source.url, accessToken: "fixture", userID: "fixture") }
        #expect(store.shelves.map(\.title) == ["Latest in A", "Action", "Latest in B"])
        #expect(store.shelves.first { $0.title == "Action" }?.id.hasSuffix("a:genre:Action") == true)
    }

    @Test func plexHubTitlesAreUniqueAcrossTheWholeSource() async throws {
        let plex = ApplePlexClient(loader: { request in
            let path = try #require(request.url?.path)
            let json: String
            if path == "/library/sections" {
                json = #"{"MediaContainer":{"Directory":[{"key":"a","title":"Movies","type":"movie"},{"key":"b","title":"Shows","type":"show"}]}}"#
            } else if path.hasPrefix("/hubs/sections/") {
                json = #"{"MediaContainer":{"Hub":[{"hubIdentifier":"genre.action","key":"/hubs/action","title":"Action","type":"movie","Metadata":[{"ratingKey":"one","key":"/library/metadata/one","type":"movie","title":"One"}]}]}}"#
            } else { json = #"{"MediaContainer":{"Metadata":[],"Hub":[]}}"# }
            return try self.response(request, json)
        })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppleMediaServerLibraryStore(plexClient: plex, cacheFileURL: directory.appendingPathComponent("rows.json"))
        await store.reload(sources: [source]) { _ in .init(kind: .plex, baseURL: source.url, accessToken: "fixture", userID: "fixture") }
        #expect(store.shelves.map(\.title) == ["Recently added in Movies", "Action", "Recently added in Shows"])
        #expect(store.shelves.first { $0.title == "Action" }?.id.contains(":a:hub:") == true)
    }

}


private actor StartupRequestGate {
    private var arrivals = 0
    private(set) var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var arrivalWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func arriveAndWait(releasingAt count: Int) async {
        arrivals += 1
        let ready = arrivalWaiters.filter { $0.0 <= arrivals }
        arrivalWaiters.removeAll { $0.0 <= arrivals }
        for (_, waiter) in ready { waiter.resume() }
        if arrivals >= count { release() }
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func waitForArrivals(_ count: Int) async {
        guard arrivals < count else { return }
        await withCheckedContinuation { arrivalWaiters.append((count, $0)) }
    }

    func release() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}
