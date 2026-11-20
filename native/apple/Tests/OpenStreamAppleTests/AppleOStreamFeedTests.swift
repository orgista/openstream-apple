import Foundation
import Observation
import Synchronization
import Testing
@testable import OpenStreamApple

/// Rill's feed (schema v1). The fixture is the owner's live feed of
/// 2026-11-09 cut to a few titles per row, plus the cases the schema allows
/// that the live copy lacked: a direct trailer link and a service id the app
/// has no icon for.
@MainActor
@Suite(.serialized)
struct AppleOStreamFeedTests {
    private let source = AppleSource(kind: .mediaServer, name: "Rill", url: URL(string: "https://fixture.example")!)
    private let session = AppleMediaServerSession(kind: .jellyfin, baseURL: URL(string: "https://fixture.example/jellyfin")!,
        accessToken: "fixture", userID: "fixture-user")

    nonisolated private static func fixtureData() throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ostream-feed-v1.json"))
    }

    private func feed() throws -> AppleOStreamFeed {
        try JSONDecoder().decode(AppleOStreamFeed.self, from: Self.fixtureData())
    }

    // MARK: Schema

    @Test func decodesTheLiveSchema() throws {
        let feed = try feed()
        #expect(feed.v == 1)
        #expect(feed.rows.map(\.role) == [.top10, .featured, .featured, .catalog, .service, .service, .service, .service, .catalog, .service])
        let top10 = try #require(feed.rows.first)
        #expect(top10.kind == .mixed && top10.libraryId == nil && top10.next == nil)
        #expect(top10.items.count == 6)
        #expect(top10.items.first?.trailer?.youtube == "AyIZ9tiiN8I")
        let popular = feed.rows[3]
        #expect(popular.next == "/OStream/Feed/Row?v=1&id=0500d4ce-273a-6d6f-7669-657c616461e4&start=20&limit=20")
        #expect(popular.items[1].trailer?.url == URL(string: "https://fixture.example/trailers/one.m3u8"))
        #expect(feed.rows.filter { $0.serviceId == "netflix" }.count == 3)
    }

    @Test func optionalTotalsAndPlayability() async throws {
        var json = try #require(JSONSerialization.jsonObject(with: Self.fixtureData()) as? [String: Any])
        json["titleCount"] = 1791
        var rows = try #require(json["rows"] as? [[String: Any]])
        for i in rows.indices {
            rows[i]["total"] = 200 + i
            var items = try #require(rows[i]["items"] as? [[String: Any]])
            items[0]["playable"] = false
            rows[i]["items"] = items
        }
        json["rows"] = rows
        let body = try JSONSerialization.data(withJSONObject: json)
        let feed = try JSONDecoder().decode(AppleOStreamFeed.self, from: body)
        #expect(feed.titleCount == 1791)
        let shelves = feed.shelves(sourceID: source.id, baseURL: session.baseURL)
        for entry in shelves {
            #expect(entry.shelf.totalItemCount == entry.row.total)
            let excluded = entry.row.items[0].id
            let contains = entry.shelf.items.contains { AppleMediaServerItemReference.parse($0.mediaID)?.itemID == excluded }
            #expect(contains == (entry.row.role != .top10 && entry.row.role != .featured))
        }
        try await withFixture { fixture in
            let store = makeStore(Server().client(feedBody: body), fixture)
            await store.reload(sources: [source]) { _ in self.session }
            #expect(store.titleCount(for: source.id) == 1791)
            let services = AppleHomeServices.detect(libraries: store.shelves, sources: [source])
            #expect(services.first?.service == .netflix)
            #expect(services.first?.itemCount == 615)
            let netflix = try #require(store.shelves.first { $0.title == "Netflix Movies" })
            await store.loadMore(shelfID: netflix.id)
            #expect(store.shelves.first { $0.id == netflix.id }?.totalItemCount == 204)
            #expect(!store.canLoadMore(shelfID: netflix.id))
            #expect(store.titleCount(for: source.id) == 1791)
        }
    }

    @Test func aCountOnlyRefreshUpdatesAnObservedConnectionLabel() async throws {
        var json = try #require(JSONSerialization.jsonObject(with: Self.fixtureData()) as? [String: Any])
        json["titleCount"] = 1791
        let body = Mutex(try JSONSerialization.data(withJSONObject: json))
        let client = AppleMediaServerClient(loader: { request in
            let url = try #require(request.url)
            let data: Data
            if url.path.hasSuffix("/OStream/Feed") { data = body.withLock { $0 } }
            else {
                try #require(url.path.hasSuffix("/Items/Resume") || url.path.hasSuffix("/Shows/NextUp"))
                data = Data(#"{"Items":[],"TotalRecordCount":0}"#.utf8)
            }
            return (data, try #require(HTTPURLResponse(url: url, statusCode: 200,
                httpVersion: nil, headerFields: ["Cache-Control": "private, no-cache"])))
        })
        try await withFixture { fixture in
            let store = makeStore(client, fixture)
            await store.reload(sources: [source]) { _ in self.session }
            #expect(store.titleCount(for: source.id) == 1791)
            let before = store.shelves
            let changed = Mutex(false)
            withObservationTracking { _ = store.titleCount(for: source.id) } onChange: {
                changed.withLock { $0 = true }
            }
            json["titleCount"] = 1792
            let updated = try JSONSerialization.data(withJSONObject: json)
            body.withLock { $0 = updated }
            await store.reload(sources: [source]) { _ in self.session }
            #expect(store.titleCount(for: source.id) == 1792)
            #expect(store.shelves == before)
            #expect(changed.withLock { $0 })
        }
    }

    @Test func aRowPageAndItsEndDecode() throws {
        let page = try JSONDecoder().decode(AppleOStreamFeed.RowPage.self, from: Data(#"""
            {"id":"lib","items":[{"id":"a","type":"Movie","title":"A"}],"next":"/OStream/Feed/Row?v=1&id=lib&start=40&limit=20"}
            """#.utf8))
        #expect(page.items.map(\.title) == ["A"])
        let paged = AppleOStreamFeed.cursor(start: 20, count: 1, next: page.next)
        #expect(paged.offset == 40 && paged.total == 41)
        // The first page can hold fewer than `start` titles (BoxSets are dropped): page on from `next`.
        let short = AppleOStreamFeed.cursor(start: 0, count: 17, next: "/OStream/Feed/Row?v=1&id=lib&start=20&limit=20")
        #expect(short.offset == 20 && short.total == 21)
        let last = AppleOStreamFeed.cursor(start: 40, count: 7, next: nil)
        #expect(last.offset == 47 && last.total == 47)
    }

    // MARK: Rows

    @Test func shelvesCarryRolesServicesAndTaggedArtwork() throws {
        let shelves = try feed().shelves(sourceID: source.id, baseURL: session.baseURL).map(\.shelf)
        let prefix = "ms:\(source.id.uuidString.lowercased()):"
        #expect(shelves.first?.id == prefix + "top10:feed")
        #expect(shelves.first?.discoverySort == .top10)
        #expect(shelves[1].discoverySort == .featured && shelves[1].collectionType == .movies)
        #expect(shelves[2].discoverySort == .featured && shelves[2].collectionType == .tvshows)
        // Known services become their libraries; an unknown id stays a plain row.
        #expect(shelves.filter { $0.libraryName != nil }.map(\.title)
            == ["Netflix Movies", "Netflix Shows", "Netflix Movies", "Apple TV+ Movies"])
        for shelf in shelves where shelf.libraryName != nil {
            #expect(AppleHomeServices.service(in: try #require(shelf.libraryName)) != nil)
        }
        #expect(shelves.last?.title == "Curiosity Stream Shows" && shelves.last?.libraryName == nil)

        let odyssey = try #require(shelves.first?.items.first)
        #expect(odyssey.mediaID == prefix + "01020000-0000-0014-e111-ffffffffae72")
        #expect(odyssey.type == "movie" && odyssey.name == "The Odyssey" && odyssey.year == 2026 && odyssey.rating == 8)
        #expect(odyssey.posterURL?.absoluteString == "https://fixture.example/jellyfin/Items/01020000-0000-0014-e111-ffffffffae72"
            + "/Images/Primary?tag=b7d75a86e60f0e6583cc0c49a65ec7d1&maxWidth=600")
        #expect(odyssey.backgroundURL?.absoluteString.contains("/Images/Backdrop?tag=0b1273bdce156f59c5cb62fbfe75bbb3&maxWidth=") == true)
        #expect(odyssey.logoURL?.absoluteString.hasSuffix("/Images/Logo?tag=b5b0f0cc48537327846de9508a85ca13&maxWidth=600") == true)
        #expect(shelves.flatMap(\.items).allSatisfy { $0.posterURL?.query?.contains("api_key") == false })
    }

    @Test func discoverGetsTop10FeaturedAndCatalogRowsButNoServiceRows() throws {
        let shelves = try feed().shelves(sourceID: source.id, baseURL: session.baseURL).map(\.shelf)
        let rows = AppleDiscoverServerRows.rows(shelves, sources: [source])
        #expect(rows.map(\.id).prefix(4) == [AppleDiscoverRowOrder.top10, AppleDiscoverRowOrder.featuredMovies,
                                              AppleDiscoverRowOrder.featuredShows, AppleDiscoverRowOrder.popularMovies])
        #expect(rows.first?.items.map(\.name).first == "The Odyssey")
        #expect(rows.first?.items.count == 6)
        #expect(rows.contains { $0.title == "Curiosity Stream Movies" })
        #expect(rows.contains { $0.title == "Curiosity Stream Shows" })
        #expect(!rows.contains { $0.title.hasPrefix("Netflix") || $0.title.hasPrefix("Apple TV") })
    }

    @Test(.timeLimit(.minutes(1))) func recordedMixedTop10RetainsEveryRankAfterReloadAndRelaunch() async throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ostream-feed-walk15-top10.json")
        let body = try Data(contentsOf: url)
        let expected = ["The Odyssey", "The Institute", "Model Citizen", "VisionQuest", "Heart of the Beast",
            "Black Doves", "Resident Evil", "Dexter: Resurrection", "Godzilla Minus Zero", "MobLand"]
        try await withFixture { fixture in
            let server = Server()
            let client = server.client(feedBody: body)
            let store = makeStore(client, fixture)
            await store.reload(sources: [source]) { _ in self.session }
            let rows = AppleDiscoverServerRows.rows(store.shelves, sources: [source])
            #expect(rows.first?.id == AppleDiscoverRowOrder.top10)
            #expect(rows.first?.items.map(\.name) == expected)
            let relaunched = makeStore(client, fixture)
            relaunched.loadPersisted(sources: [source]) { _ in self.session }
            await relaunched.reload(sources: [source]) { _ in self.session }
            let restored = AppleDiscoverServerRows.rows(relaunched.shelves, sources: [source])
            #expect(restored.first?.items.map(\.name) == expected)
        }
    }

    @Test(.timeLimit(.minutes(1))) func unchangedFeedItemsRefreshStaleShelfRoles() async throws {
        try await withFixture { fixture in
            let shelves = try feed().shelves(sourceID: source.id, baseURL: session.baseURL).map(\.shelf)
            let chart = try #require(shelves.first)
            let stale = AppleMediaServerLibraryStore.Shelf(id: chart.id, title: chart.title, sourceID: source.id,
                items: chart.items, collectionType: .other, discoverySort: .other)
            let encoded = try JSONEncoder().encode([stale])
            let json: [String: Any] = ["shelves": try JSONSerialization.jsonObject(with: encoded), "continueWatching": []]
            try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: json).write(to: fixture.rows)
            let store = makeStore(Server().client(feedBody: try Self.fixtureData()), fixture)
            store.loadPersisted(sources: [source]) { _ in self.session }
            #expect(store.shelves.first?.discoverySort == .other)
            await store.reload(sources: [source]) { _ in self.session }
            let refreshed = try #require(store.shelves.first { $0.id == chart.id })
            #expect(refreshed.discoverySort == .top10)
            #expect(refreshed.collectionType == nil)
            let rows = AppleDiscoverServerRows.rows(store.shelves, sources: [source])
            #expect(rows.first?.id == AppleDiscoverRowOrder.top10)
            #expect(rows.first?.items.map(\.name) == chart.items.map(\.name))
        }
    }

    @Test func aServiceMergesItsLibrariesAndDropsTheTitleBothAddOnsList() throws {
        let shelves = try feed().shelves(sourceID: source.id, baseURL: session.baseURL).map(\.shelf)
        let netflix = shelves.filter { $0.libraryName.flatMap(AppleHomeServices.service(in:)) == .netflix }
        #expect(netflix.count == 3)
        let movies = AppleHomeServices.items(in: netflix, type: .movies)
        // Two libraries of three titles, one title in both.
        #expect(movies.count == 5)
        #expect(Set(movies.map(\.mediaID)).count == 5)
    }

    @Test(arguments: AppleStreamingService.allCases)
    func serviceIDDrivesDetectionAndPageContents(service: AppleStreamingService) throws {
        let rows: [AppleOStreamFeed.Row] = [AppleOStreamFeed.Row.Kind.movies, .shows].map { kind in
            .init(id: kind.rawValue, title: "Provider picks", kind: kind, role: .service,
                serviceId: service.rawValue, libraryId: kind.rawValue,
                items: [.init(id: kind.rawValue, type: kind == .movies ? "Movie" : "Series", title: kind.rawValue,
                    year: nil, rating: nil, imdb: nil, posterTag: nil, backdropTag: nil, logoTag: nil, trailer: nil)], next: nil)
        }
        let feed = AppleOStreamFeed(v: 1, images: .v1, rows: rows)
        let shelves = feed.shelves(sourceID: source.id, baseURL: session.baseURL).map(\.shelf)
        let detected = try #require(AppleHomeServices.detect(libraries: shelves, sources: [source]).first)
        #expect(detected.service == service)
        let pageLibraries = shelves.filter { AppleHomeServices.service(in: $0.libraryName ?? "") == service }
        #expect(pageLibraries.count == 2)
        #expect(AppleHomeServices.items(in: pageLibraries, type: .movies).map(\.name) == ["movies"])
        #expect(AppleHomeServices.items(in: pageLibraries, type: .shows).map(\.name) == ["shows"])
    }

    // MARK: Store

    final class Server: Sendable {
        enum Feed: Sendable { case on, off, building, broken, webPage }
        private let state = Mutex((feed: Feed.on, log: [String]()))
        static let etag = #"W/"of1-5d41402a""#

        var feed: Feed {
            get { state.withLock { $0.feed } }
            set { state.withLock { $0.feed = newValue } }
        }
        var log: [String] { state.withLock { $0.log } }
        func clearLog() { state.withLock { $0.log = [] } }

        func client(feedBody: Data) -> AppleMediaServerClient {
            AppleMediaServerClient(loader: { request in
                let url = try #require(request.url)
                let query = url.query.map { "?" + $0 } ?? ""
                let conditional = request.value(forHTTPHeaderField: "If-None-Match")
                let mode = self.state.withLock { state in
                    state.log.append(url.path + query + (conditional.map { " If-None-Match: " + $0 } ?? ""))
                    return state.feed
                }
                func reply(_ status: Int, _ body: String, _ headers: [String: String] = [:]) throws -> (Data, URLResponse) {
                    (Data(body.utf8), try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)))
                }
                if url.path.hasSuffix("/OStream/Feed") {
                    switch mode {
                    case .off: return try reply(404, "")
                    case .building: return try reply(503, "", ["Retry-After": "15"])
                    case .broken: throw URLError(.networkConnectionLost)
                    case .webPage: return try reply(200, "<!doctype html><title>App</title>", ["Content-Type": "text/html"])
                    case .on:
                        if conditional == Self.etag { return try reply(304, "", ["ETag": Self.etag]) }
                        return (feedBody, try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                            headerFields: ["ETag": Self.etag, "Cache-Control": "private, no-cache"])))
                    }
                }
                if url.path.hasSuffix("/OStream/Feed/Row") {
                    return try reply(200, #"{"id":"lib","items":[{"id":"page-1","type":"Movie","title":"Paged One","posterTag":"aa"},"#
                        + #"{"id":"page-2","type":"Movie","title":"Paged Two","posterTag":"bb"}]}"#)
                }
                if url.path.hasSuffix("/Views") {
                    return try reply(200, #"{"Items":["# + (0..<40).map {
                        #"{"Id":"lib\#($0)","Name":"Library \#($0)","CollectionType":"movies"}"#
                    }.joined(separator: ",") + "]}")
                }
                if url.path.hasSuffix("/Latest") {
                    return try reply(200, #"[{"Id":"x","Name":"Classic","Type":"Movie","ImageTags":{"Primary":"t"}}]"#)
                }
                return try reply(200, #"{"Items":[],"TotalRecordCount":0}"#)
            })
        }
    }

    private struct Fixture {
        let directory: URL
        let suite: String
        var defaults: UserDefaults { UserDefaults(suiteName: suite)! }
        var rows: URL { directory.appendingPathComponent("rows.json") }
        var feedCache: AppleOStreamFeedCache { AppleOStreamFeedCache(directory: directory.appendingPathComponent("feed")) }
    }

    private func withFixture(_ body: (Fixture) async throws -> Void) async throws {
        let suite = "AppleOStreamFeedTests." + UUID().uuidString
        let fixture = Fixture(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            suite: suite)
        defer {
            try? FileManager.default.removeItem(at: fixture.directory)
            fixture.defaults.removePersistentDomain(forName: suite)
        }
        try await body(fixture)
    }

    private func makeStore(_ client: AppleMediaServerClient, _ fixture: Fixture) -> AppleMediaServerLibraryStore {
        AppleMediaServerLibraryStore(client: client, cacheFileURL: fixture.rows, feedCache: fixture.feedCache, feedDefaults: fixture.defaults)
    }

    private func feedRequests(_ log: [String]) -> [String] { log.filter { $0.contains("/OStream/Feed") } }

    @Test(.timeLimit(.minutes(1))) func aLaunchIsOneConditionalFeedRequestInsteadOfTheRowRequests() async throws {
        try await withFixture { fixture in
            let server = Server()
            let client = server.client(feedBody: try Self.fixtureData())

            // Without the feed: the store's own rows, one request per library and more.
            server.feed = .off
            let classic = makeStore(client, fixture)
            await classic.reload(sources: [source]) { _ in self.session }
            let classicCount = server.log.count
            #expect(classicCount > 40)
            #expect(classic.shelves.contains { $0.id.hasSuffix(":latest") })

            server.feed = .on
            server.clearLog()
            let store = makeStore(client, fixture)
            await store.reload(sources: [source]) { _ in self.session }
            // The feed, and Continue Watching's two calls (resume, Next Up across every library).
            #expect(server.log.count == 3, "\(server.log)")
            #expect(feedRequests(server.log) == ["/jellyfin/OStream/Feed?v=1"])
            #expect(server.log.contains { $0.hasPrefix("/jellyfin/Shows/NextUp") && !$0.contains("ParentId") })
            #expect(!server.log.contains { $0.contains("/Views") || $0.contains("/Latest") })
            #expect(store.shelves.count == 10)
            #expect(store.shelves.allSatisfy { $0.id.hasSuffix(":feed") || $0.id.hasSuffix(":nextup") })
            #expect(AppleOStreamFeedPreference.hasAnswered(source.id, defaults: fixture.defaults))
            #expect(store.feedTrailerKey(for: try #require(store.shelves.first?.items.first?.mediaID)) == "AyIZ9tiiN8I")

            // The next launch draws the kept rows before asking, then sends the ETag back as received:
            // a 304 is the whole launch.
            server.clearLog()
            let relaunched = makeStore(client, fixture)
            relaunched.loadPersisted(sources: [source]) { _ in self.session }
            #expect(relaunched.shelves.map(\.id) == store.shelves.map(\.id))
            #expect(server.log.isEmpty)
            await relaunched.reload(sources: [source], unlessReloadedWithin: AppleMediaServerLibraryStore.rowsFreshness) { _ in self.session }
            #expect(server.log == ["/jellyfin/OStream/Feed?v=1 If-None-Match: \(Server.etag)"])
            #expect(relaunched.shelves.map(\.id) == store.shelves.map(\.id) && relaunched.shelves.map(\.items) == store.shelves.map(\.items))
            #expect(relaunched.feedTrailerKey(for: try #require(store.shelves.first?.items.first?.mediaID)) == "AyIZ9tiiN8I")
            // Back on Discover in the same session: nothing.
            server.clearLog()
            await relaunched.reload(sources: [source], unlessReloadedWithin: AppleMediaServerLibraryStore.rowsFreshness) { _ in self.session }
            #expect(server.log.isEmpty)
            // A forced reload (pull to refresh) is the feed and Continue Watching's two calls.
            await relaunched.reload(sources: [source]) { _ in self.session }
            #expect(server.log.count == 3)
            #expect(relaunched.shelves.map(\.id) == store.shelves.map(\.id) && relaunched.shelves.map(\.items) == store.shelves.map(\.items))
        }
    }

    @Test(.timeLimit(.minutes(1))) func aFreshLaunchStillFollowsTheFeedTurningOffAndOn() async throws {
        try await withFixture { fixture in
            let server = Server()
            let client = server.client(feedBody: try Self.fixtureData())
            @MainActor func launch() async -> AppleMediaServerLibraryStore {
                let store = makeStore(client, fixture)
                store.loadPersisted(sources: [source]) { _ in self.session }
                await store.reload(sources: [source], unlessReloadedWithin: AppleMediaServerLibraryStore.rowsFreshness) { _ in self.session }
                return store
            }
            #expect(await launch().shelves.contains { $0.id.hasSuffix(":feed") })
            // Rill's setting turned off minutes later: the next launch builds its own rows.
            server.feed = .off
            let off = await launch()
            #expect(!off.shelves.contains { $0.id.hasSuffix(":feed") })
            #expect(off.shelves.contains { $0.id.hasSuffix(":latest") })
            // And on again.
            server.feed = .on
            let on = await launch()
            #expect(on.shelves.contains { $0.id.hasSuffix(":feed") })
            #expect(!on.shelves.contains { $0.id.hasSuffix(":latest") })
        }
    }

    @Test(.timeLimit(.minutes(1))) func feedRowsPageFromTheRowEndpoint() async throws {
        try await withFixture { fixture in
            let server = Server()
            let store = makeStore(server.client(feedBody: try Self.fixtureData()), fixture)
            await store.reload(sources: [source]) { _ in self.session }
            let netflix = try #require(store.shelves.first { $0.title == "Netflix Movies" })
            #expect(store.canLoadMore(shelfID: netflix.id))
            server.clearLog()
            await store.loadMore(shelfID: netflix.id)
            #expect(server.log == ["/jellyfin/OStream/Feed/Row?v=1&id=05001b8b-8326-6d6f-7669-657c6164abc3&start=20&limit=20"])
            let paged = try #require(store.shelves.first { $0.id == netflix.id })
            #expect(paged.items.map(\.name).suffix(2) == ["Paged One", "Paged Two"])
            // That page had no `next`: the row is complete.
            #expect(!store.canLoadMore(shelfID: netflix.id))
            // A service page does not refresh a feed row's first page on its own.
            server.clearLog()
            await store.refreshIfNeeded(shelfID: netflix.id, now: .now.addingTimeInterval(3600))
            #expect(server.log.isEmpty)
            // Top 10 and synthesized Featured rows cannot be paged.
            #expect(!store.canLoadMore(shelfID: try #require(store.shelves.first).id))
        }
    }

    @Test(.timeLimit(.minutes(1))) func settingOffOrBuildingFallsBackToTheStoresOwnRows() async throws {
        try await withFixture { fixture in
            let server = Server()
            let store = makeStore(server.client(feedBody: try Self.fixtureData()), fixture)

            // 503 while Rill builds it, with no kept copy: this reload builds its own rows, the next asks again.
            server.feed = .building
            await store.reload(sources: [source]) { _ in self.session }
            #expect(!store.shelves.contains { $0.id.hasSuffix(":feed") })
            #expect(store.shelves.contains { $0.id.hasSuffix(":latest") })
            server.feed = .on
            server.clearLog()
            await store.reload(sources: [source]) { _ in self.session }
            #expect(feedRequests(server.log).count == 1)
            #expect(store.shelves.contains { $0.id.hasSuffix(":feed") })
            #expect(!store.shelves.contains { $0.id.hasSuffix(":latest") })

            // 404: Rill's setting is off. Own rows, and the feed is not asked again this session.
            server.feed = .off
            await store.reload(sources: [source]) { _ in self.session }
            #expect(!store.shelves.contains { $0.id.hasSuffix(":feed") })
            server.feed = .on
            server.clearLog()
            await store.reload(sources: [source]) { _ in self.session }
            #expect(feedRequests(server.log).isEmpty)
            #expect(!store.shelves.contains { $0.id.hasSuffix(":feed") })
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [Server.Feed.building, .broken])
    func aFeedBlipKeepsTheKeptRows(blip: Server.Feed) async throws {
        try await withFixture { fixture in
            let server = Server()
            let store = makeStore(server.client(feedBody: try Self.fixtureData()), fixture)
            await store.reload(sources: [source]) { _ in self.session }
            let fed = store.shelves
            #expect(fed.contains { $0.id.hasSuffix(":feed") })

            // A 503 (a settings save) or a dropped connection on the next reload: the kept feed stands,
            // with only Continue Watching's two calls besides.
            server.feed = blip
            server.clearLog()
            await store.reload(sources: [source]) { _ in self.session }
            #expect(store.shelves.map(\.id) == fed.map(\.id))
            #expect(server.log.count == 3, "\(server.log)")
            #expect(!server.log.contains { $0.contains("/Views") || $0.contains("/Latest") })
        }
    }

    @Test(.timeLimit(.minutes(1))) func anUnreadableKeptCopyIsDroppedAndAskedForAgain() async throws {
        try await withFixture { fixture in
            let server = Server()
            // What an older build kept: a 304 to its ETag would otherwise fall back on every launch.
            fixture.feedCache.save(.init(userID: session.userID, etag: Server.etag, body: Data(#"{"v":1,"rows":"old"}"#.utf8)),
                sourceID: source.id)
            let store = makeStore(server.client(feedBody: try Self.fixtureData()), fixture)
            await store.reload(sources: [source]) { _ in self.session }
            #expect(feedRequests(server.log) == ["/jellyfin/OStream/Feed?v=1 If-None-Match: \(Server.etag)", "/jellyfin/OStream/Feed?v=1"])
            #expect(store.shelves.contains { $0.id.hasSuffix(":feed") })
            #expect(!server.log.contains { $0.contains("/Views") })
            let kept = try #require(fixture.feedCache.entry(sourceID: source.id, userID: session.userID))
            #expect(kept.body == (try Self.fixtureData()))
        }
    }

    @Test(.timeLimit(.minutes(1))) func feedRequestsAreShortAndAskEveryServerAtOnce() async throws {
        try await withFixture { fixture in
            let first = AppleSource(kind: .mediaServer, name: "One", url: URL(string: "https://one.example")!)
            let second = AppleSource(kind: .mediaServer, name: "Two", url: URL(string: "https://two.example")!)
            let sessions = [first.id: AppleMediaServerSession(kind: .jellyfin, baseURL: first.url, accessToken: "a", userID: "u"),
                            second.id: AppleMediaServerSession(kind: .jellyfin, baseURL: second.url, accessToken: "b", userID: "u")]
            let state = Mutex((inFlight: 0, overlapped: false, timeouts: [TimeInterval]()))
            let client = AppleMediaServerClient(loader: { request in
                let url = try #require(request.url)
                func reply(_ status: Int, _ body: String) throws -> (Data, URLResponse) {
                    (Data(body.utf8), try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)))
                }
                guard url.path.hasSuffix("/OStream/Feed") else { return try reply(200, #"{"Items":[],"TotalRecordCount":0}"#) }
                state.withLock { $0.inFlight += 1; $0.timeouts.append(request.timeoutInterval) }
                // Each feed answer waits for the other server's request, up to a second: asked one after
                // another, neither would see the other.
                for _ in 0..<100 where !state.withLock({ $0.overlapped }) {
                    if state.withLock({ $0.inFlight }) == 2 { state.withLock { $0.overlapped = true } }
                    try await Task.sleep(for: .milliseconds(10))
                }
                state.withLock { $0.inFlight -= 1 }
                return try reply(404, "")
            })
            let store = makeStore(client, fixture)
            await store.reload(sources: [first, second]) { sessions[$0.id] }
            #expect(state.withLock { $0.overlapped })
            #expect(state.withLock { $0.timeouts } == [5, 5])
        }
    }

    @Test(.timeLimit(.minutes(1))) func aServerWithoutTheFeedIsNotAskedForADay() async throws {
        try await withFixture { fixture in
            let server = Server()
            server.feed = .off
            let client = server.client(feedBody: try Self.fixtureData())
            await makeStore(client, fixture).reload(sources: [source]) { _ in self.session }
            #expect(feedRequests(server.log).count == 1)
            // The next launches skip it.
            server.clearLog()
            let relaunched = makeStore(client, fixture)
            await relaunched.reload(sources: [source], unlessReloadedWithin: AppleMediaServerLibraryStore.rowsFreshness) { _ in self.session }
            #expect(feedRequests(server.log).isEmpty)
            #expect(server.log.contains { $0.contains("/Views") })
            // Rill's setting turned on: a pull to refresh finds it.
            server.feed = .on
            server.clearLog()
            await makeStore(client, fixture).reload(sources: [source]) { _ in self.session }
            #expect(feedRequests(server.log) == ["/jellyfin/OStream/Feed?v=1"])
            // A day later, or at another address, it is asked again.
            #expect(!AppleOStreamFeedPreference.isMissing(source.id, baseURL: session.baseURL,
                now: .now.addingTimeInterval(AppleOStreamFeedPreference.missingLifetime + 1), defaults: fixture.defaults))
            #expect(!AppleOStreamFeedPreference.isMissing(source.id, baseURL: URL(string: "https://moved.example")!, defaults: fixture.defaults))
        }
    }

    @Test(.timeLimit(.minutes(1))) func aWebPageForEveryPathCountsAsNoFeed() async throws {
        try await withFixture { fixture in
            let server = Server()
            server.feed = .webPage
            let store = makeStore(server.client(feedBody: try Self.fixtureData()), fixture)
            await store.reload(sources: [source]) { _ in self.session }
            #expect(store.shelves.contains { $0.id.hasSuffix(":latest") })
            server.clearLog()
            await store.reload(sources: [source]) { _ in self.session }
            #expect(feedRequests(server.log).isEmpty)
        }
    }

    @Test(.timeLimit(.minutes(1))) func anotherAccountOnTheSourceIsAskedAgain() async throws {
        try await withFixture { fixture in
            let server = Server()
            let store = makeStore(server.client(feedBody: try Self.fixtureData()), fixture)
            await store.reload(sources: [source]) { _ in self.session }
            server.feed = .off
            await store.reload(sources: [source]) { _ in self.session }
            // Another user signs in this session: the 404 was the other account's.
            server.feed = .on
            server.clearLog()
            let other = AppleMediaServerSession(kind: .jellyfin, baseURL: session.baseURL, accessToken: "other", userID: "other-user")
            await store.reload(sources: [source]) { _ in other }
            #expect(feedRequests(server.log) == ["/jellyfin/OStream/Feed?v=1"])
            #expect(store.shelves.contains { $0.id.hasSuffix(":feed") })
        }
    }

    @Test(.timeLimit(.minutes(1))) func connectedCountsTheFeedRowsTitles() async throws {
        try await withFixture { fixture in
            let store = makeStore(Server().client(feedBody: try Self.fixtureData()), fixture)
            await store.reload(sources: [source]) { _ in self.session }
            let feed = try feed()
            let entries = feed.shelves(sourceID: source.id, baseURL: session.baseURL)
            let titles = Set(entries.flatMap(\.shelf.items).map(\.mediaID)).count
            // Each row that pages on adds the rest it is known to have.
            let more = entries.filter { $0.row.libraryId != nil }.map {
                max(0, AppleOStreamFeed.cursor(start: 0, count: $0.row.items.count, next: $0.row.next).total - $0.shelf.items.count)
            }.reduce(0, +)
            #expect(titles > 20 && more > 0)
            #expect(store.titleCount(for: source.id) == titles + more)
        }
    }

    @Test(.timeLimit(.minutes(1))) func signedOutAndRemovedSourcesLoseTheirKeptFeed() async throws {
        try await withFixture { fixture in
            let server = Server()
            let store = makeStore(server.client(feedBody: try Self.fixtureData()), fixture)
            await store.reload(sources: [source]) { _ in self.session }
            #expect(fixture.feedCache.entry(sourceID: source.id, userID: session.userID) != nil)
            var signedOut = source
            signedOut.isEnabled = false
            await store.reload(sources: [signedOut]) { _ in nil }
            for _ in 0..<100 where fixture.feedCache.entry(sourceID: source.id, userID: session.userID) != nil {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(fixture.feedCache.entry(sourceID: source.id, userID: session.userID) == nil)
        }
    }

    @Test(.timeLimit(.minutes(1))) func turningTheSwitchOffReloadsTheOwnRowsAtOnce() async throws {
        try await withFixture { fixture in
            let server = Server()
            let store = makeStore(server.client(feedBody: try Self.fixtureData()), fixture)
            await store.reload(sources: [source]) { _ in self.session }
            #expect(store.shelves.contains { $0.id.hasSuffix(":feed") })

            AppleOStreamFeedPreference.setOn(false, sourceID: source.id, defaults: fixture.defaults)
            server.clearLog()
            // The rows are fresh, but the switch changed: no skip.
            await store.reload(sources: [source], unlessReloadedWithin: AppleMediaServerLibraryStore.rowsFreshness) { _ in self.session }
            #expect(feedRequests(server.log).isEmpty)
            #expect(server.log.contains { $0.hasSuffix("/Views") || $0.contains("/Views?") })
            #expect(!store.shelves.contains { $0.id.hasSuffix(":feed") })

            // Unchanged since: the fresh rows stand in again.
            server.clearLog()
            await store.reload(sources: [source], unlessReloadedWithin: AppleMediaServerLibraryStore.rowsFreshness) { _ in self.session }
            #expect(server.log.isEmpty)
        }
    }

    @Test func aDirectFeedTrailerPlaysWithoutAskingTheServer() async throws {
        let feed = try feed()
        let trailers = feed.trailers(sourceID: source.id)
        let (mediaID, link) = try #require(trailers.first { $0.value.url != nil }.map { ($0.key, $0.value.url!) })
        let asked = Mutex(0)
        let store = AppleServerTrailerStore(client: AppleMediaServerClient(loader: { request in
            asked.withLock { $0 += 1 }
            throw URLError(.notConnectedToInternet)
        }))
        store.update(sessions: [source.id: session])
        store.update(feedTrailers: [mediaID: link])
        let item = AppleCatalogItem(mediaID: mediaID, type: "movie", name: "Fixture")
        let trailer = try #require(try await store.trailer(for: item))
        #expect(trailer.url == link)
        #expect(!trailer.isFile)
        #expect(asked.withLock { $0 } == 0)
    }

    @Test func top10FollowsTheChartNotTheLastOrderShown() throws {
        func top10(_ titles: [String]) -> AppleOStreamFeed {
            AppleOStreamFeed(v: 1, images: .v1, rows: [.init(id: "top10", title: "Top 10", kind: .mixed, role: .top10,
                serviceId: nil, libraryId: nil, items: titles.enumerated().map { position, title in
                    .init(id: title, type: "Movie", title: title, year: nil, rating: nil, imdb: nil, posterTag: "p",
                        backdropTag: nil, logoTag: nil, trailer: nil, rank: position + 1)
                }.reversed(), next: nil)])
        }
        // Items arrive out of rank order: the rank decides.
        let yesterday = top10(["A", "B", "C"]).shelves(sourceID: source.id, baseURL: session.baseURL).map(\.shelf)
        #expect(yesterday.first?.items.map(\.name) == ["A", "B", "C"])
        let shown = AppleDiscoverServerRows.rows(yesterday, sources: [source])
        let today = top10(["C", "D", "A"]).shelves(sourceID: source.id, baseURL: session.baseURL).map(\.shelf)
        let rows = AppleDiscoverServerRows.rows(today, sources: [source], previousRows: shown)
        #expect(rows.first { $0.id == AppleDiscoverRowOrder.top10 }?.items.map(\.name) == ["C", "D", "A"])
    }

    @Test func onlyHTTPSDirectTrailersArePassedOn() {
        let trailers: [String: AppleOStreamFeed.Trailer] = [
            "secure": .init(youtube: nil, url: URL(string: "https://fixture.example/t.m3u8")),
            "plain": .init(youtube: nil, url: URL(string: "http://fixture.example/t.m3u8")),
            "youtube": .init(youtube: "AyIZ9tiiN8I", url: nil)]
        #expect(AppleOStreamFeed.directLinks(trailers) == ["secure": URL(string: "https://fixture.example/t.m3u8")!])
    }

    @Test(.timeLimit(.minutes(1))) func theBillboardSeesAFeedTrailerThatLandsLater() async throws {
        try await withFixture { fixture in
            let store = makeStore(Server().client(feedBody: try Self.fixtureData()), fixture)
            let mediaID = AppleMediaServerItemReference(sourceID: source.id, itemID: "01020000-0000-0014-e111-ffffffffae72").mediaID
            let changed = Mutex(false)
            withObservationTracking { _ = store.feedTrailerKey(for: mediaID) } onChange: { changed.withLock { $0 = true } }
            await store.reload(sources: [source]) { _ in self.session }
            #expect(changed.withLock { $0 })
            #expect(store.feedTrailerKey(for: mediaID) == "AyIZ9tiiN8I")
        }
    }
}
