import Testing
import Foundation
@testable import OpenStreamApple

@Suite("AppleMediaServerLibraryStore Tests")
@MainActor
struct AppleMediaServerLibraryStoreTests {

    @Test("Genre shelves use real library metadata and skip singleton genres")
    func genreShelves() {
        let sourceID = UUID()
        let items = [
            AppleCatalogItem(mediaID: "one", type: "movie", name: "One", genres: ["Animation", "Adventure"]),
            AppleCatalogItem(mediaID: "two", type: "movie", name: "Two", genres: ["Animation", "Animation"]),
            AppleCatalogItem(mediaID: "three", type: "movie", name: "Three", genres: ["Drama"])
        ]
        let shelves = AppleMediaServerLibraryStore.genreShelves(items: items, sourceID: sourceID, libraryID: "movies")
        #expect(shelves.map(\.title) == ["Animation"])
        #expect(shelves.first?.items.map(\.mediaID) == ["one", "two"])
        #expect(shelves.first?.sourceID == sourceID)
        #expect(AppleMediaServerLibraryStore.genreShelves(items: [], sourceID: sourceID, libraryID: "movies").isEmpty)
    }

    @Test("Reference parse round trips mediaID and rejects garbage")
    func testReferenceParse() {
        let sourceID = UUID()
        let itemID = "item:with:colons"
        let ref = AppleMediaServerItemReference(sourceID: sourceID, itemID: itemID)
        let mediaID = ref.mediaID
        #expect(mediaID == "ms:\(sourceID.uuidString.lowercased()):item:with:colons")
        
        let parsed = AppleMediaServerItemReference.parse(mediaID)
        #expect(parsed == ref)
        
        #expect(AppleMediaServerItemReference.parse("ms:invalid-uuid:item") == nil)
        #expect(AppleMediaServerItemReference.parse("ms:\(sourceID.uuidString.lowercased()):") == nil) // empty item ID
        #expect(AppleMediaServerItemReference.parse("invalid-prefix:\(sourceID.uuidString.lowercased()):item") == nil)
    }
    
    @Test("Store reload flows")
    func testStoreReload() async throws {
        let source1ID = UUID()
        let source2ID = UUID()
        let source3ID = UUID()
        
        let source1 = AppleSource(id: source1ID, kind: .mediaServer, name: "S1", url: URL(string: "https://fixture.example/emby/")!, isEnabled: true)
        let source2 = AppleSource(id: source2ID, kind: .mediaServer, name: "S2", url: URL(string: "https://fixture.example/emby/")!, isEnabled: true)
        let source3 = AppleSource(id: source3ID, kind: .mediaServer, name: "S3", url: URL(string: "https://fixture.example/emby/")!, isEnabled: false)
        
        let session1 = AppleMediaServerSession(kind: .emby, baseURL: source1.url, accessToken: "t1", userID: "u1")
        let session2 = AppleMediaServerSession(kind: .emby, baseURL: source2.url, accessToken: "t2", userID: "u2")
        
        let client = AppleMediaServerClient(loader: { req in
            let path = req.url!.path
            if req.url!.absoluteString.contains("t2") || path.contains("u2") {
                return (Data(), HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
            }
            
            let json: String
            if path.hasSuffix("Views") {
                json = """
                {
                    "Items": [
                        { "Id": "lib_movies", "Name": "Movies", "CollectionType": "movies" },
                        { "Id": "lib_tv", "Name": "TV Shows", "CollectionType": "tvshows" },
                        { "Id": "lib_music", "Name": "Music", "CollectionType": "other" }
                    ]
                }
                """
            } else if path.hasSuffix("Resume") {
                json = """
                {
                    "Items": [
                        { "Id": "item1", "Name": "Resume 1", "Type": "Movie", "RunTimeTicks": 10000000000, "UserData": { "PlaybackPositionTicks": 2000000000, "Played": false } },
                        { "Id": "item1", "Name": "Resume 1", "Type": "Movie", "RunTimeTicks": 10000000000, "UserData": { "PlaybackPositionTicks": 2000000000, "Played": false } }
                    ],
                    "TotalRecordCount": 2
                }
                """
            } else if path.hasSuffix("Items/Latest") {
                if req.url!.absoluteString.contains("ParentId=lib_movies") {
                    json = """
                    [
                        { "Id": "item2", "Name": "Movie 2", "Type": "Movie", "ImageTags": { "Primary": "tag1" }, "BackdropImageTags": ["bd1"] },
                        { "Id": "item3", "Name": "Movie 3", "Type": "Movie" }
                    ]
                    """
                } else {
                    json = "[]"
                }
            } else {
                json = "{}"
            }
            
            return (json.data(using: .utf8)!, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        
        let store = AppleMediaServerLibraryStore(client: client)
        
        await store.reload(sources: [source1, source2, source3]) { s in
            if s.id == source1.id { return session1 }
            if s.id == source2.id { return session2 }
            return nil
        }
        
        #expect(store.failures[source2ID] != nil)
        #expect(store.failures[source2ID] == "The server answered with an error (500).")
        #expect(store.failures[source1ID] == nil)
        #expect(store.failures[source3ID] == nil)
        
        #expect(store.shelves.count == 2)
        #expect(store.shelves[0].id == "ms:\(source1ID.uuidString.lowercased()):lib_movies:latest")
        #expect(store.shelves[0].title == "Latest in Movies")
        #expect(store.shelves[1].id == "ms:\(source1ID.uuidString.lowercased()):lib_tv:latest")
        #expect(store.shelves[1].title == "Latest in TV Shows")
        
        let items = store.shelves[0].items
        #expect(items.count == 2)
        #expect(items[0].posterURL?.absoluteString.contains("tag1") == true)
        #expect(items[1].posterURL == nil)
        
        #expect(store.continueWatching.count == 1)
        let resumedItem = try #require(store.continueWatching.first)
        let resumedRecord = store.continueWatchingRecord(for: resumedItem, source: source1)
        #expect(resumedRecord.progress == 0.2)
        #expect(resumedRecord.id == AppleMediaIngestion.catalogRecord(instanceID: source1ID, item: resumedItem).id)

        let ref = AppleMediaServerItemReference(sourceID: source1ID, itemID: "item2")
        #expect(store.item(for: ref) != nil)
        #expect(store.source(for: ref)?.id == source1ID)
        
        store.clear(sourceID: source1ID)
        #expect(store.shelves.isEmpty)
        #expect(store.continueWatching.isEmpty)
        #expect(store.item(for: ref) == nil)
        
        await store.reload(sources: [source1]) { _ in return session1 }
        #expect(store.shelves.count == 2)
    }

    @Test("Merged continue watching handles deduplication")
    func testMergedContinueWatching() {
        let local = [
            AppleCatalogItem(mediaID: "ms:123:item1", type: "movie", name: "L1"),
            AppleCatalogItem(mediaID: "ms:123:item2", type: "movie", name: "L2")
        ]
        
        let server = [
            AppleCatalogItem(mediaID: "ms:123:item2", type: "movie", name: "S2"),
            AppleCatalogItem(mediaID: "ms:123:item3", type: "movie", name: "S3")
        ]
        
        let merged = AppleMediaServerLibraryStore.mergedContinueWatching(local: local, server: server)
        
        #expect(merged.count == 3)
        #expect(merged[0].mediaID == "ms:123:item1")
        #expect(merged[1].mediaID == "ms:123:item2")
        #expect(merged[1].name == "L2") // Keeps local
        #expect(merged[2].mediaID == "ms:123:item3")
        #expect(merged[2].name == "S3")
    }

    @Test("Detail fetching and caching logic")
    func testDetailFetching() async throws {
        let sourceID = UUID()
        let source = AppleSource(id: sourceID, kind: .mediaServer, name: "S", url: URL(string: "https://fixture.example/emby/")!, isEnabled: true)
        let session = AppleMediaServerSession(kind: .emby, baseURL: source.url, accessToken: "tk", userID: "u")
        
        final class SharedState: @unchecked Sendable {
            private let lock = NSLock()
            var count = 0
            func inc() { lock.lock(); count += 1; lock.unlock() }
            func get() -> Int { lock.lock(); defer { lock.unlock() }; return count }
        }
        let state = SharedState()
        let client = AppleMediaServerClient(loader: { req in
            state.inc()
            let path = req.url!.path
            let json: String
            
            if path.hasSuffix("m1") {
                json = """
                { "Id": "m1", "Name": "Movie 1", "Type": "Movie", "RunTimeTicks": 72000000000 }
                """
            } else if path.hasSuffix("s1") {
                json = """
                { "Id": "s1", "Name": "Series 1", "Type": "Series" }
                """
            } else if path.hasSuffix("s1/Seasons") {
                json = """
                { "Items": [
                    { "Id": "sea1", "Name": "Season 1", "Type": "Season" },
                    { "Id": "sea2", "Name": "Season 2", "Type": "Season" }
                ]}
                """
            } else if path.hasSuffix("s1/Episodes") {
                if req.url!.absoluteString.contains("SeasonId=sea1") {
                    json = """
                    { "Items": [ { "Id": "ep1", "Name": "Episode 1", "Type": "Episode" } ] }
                    """
                } else {
                    json = """
                    { "Items": [] }
                    """
                }
            } else if path.hasSuffix("PlaybackInfo") {
                json = """
                {
                    "MediaSources": [
                        { "Id": "src1", "Container": "mp4,mov", "SupportsDirectPlay": true, "SupportsDirectStream": false }
                    ]
                }
                """
            } else if path.hasSuffix("Views") || path.hasSuffix("Resume") {
                json = "{ \"Items\": [], \"TotalRecordCount\": 0 }"
            } else {
                json = "{}"
            }
            return (json.data(using: .utf8)!, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        
        let store = AppleMediaServerLibraryStore(client: client)
        await store.reload(sources: [source]) { _ in return session }
        
        let refMovie = AppleMediaServerItemReference(sourceID: sourceID, itemID: "m1")
        let detailMovie = try await store.detail(for: refMovie)
        
        #expect(detailMovie.item.name == "Movie 1")
        #expect(detailMovie.seasons.isEmpty)
        
        let c1 = state.get()
        let _ = try await store.detail(for: refMovie)
        #expect(state.get() == c1) // cached
        
        let refSeries = AppleMediaServerItemReference(sourceID: sourceID, itemID: "s1")
        let detailSeries = try await store.detail(for: refSeries)
        
        #expect(detailSeries.item.name == "Series 1")
        #expect(detailSeries.seasons.count == 1) // sea2 is dropped because empty
        #expect(detailSeries.seasons[0].id == "sea1")
        #expect(detailSeries.episodesBySeason["sea1"]?.count == 1)
        
        // playbackRequest
        let req = try await store.playbackRequest(for: detailMovie.item, in: detailMovie, resume: true)
        #expect(req.url.absoluteString == "https://fixture.example/emby/Videos/m1/stream.mp4?static=true&mediaSourceId=src1&api_key=tk")
        #expect(req.sourceKind == .mediaServer)
        #expect(AppleMediaServerItemReference.parse(req.mediaID) == refMovie)
        
        // resumePosition
        let itemZero = try JSONDecoder().decode(AppleMediaServerItem.self, from: "{ \"Id\": \"1\", \"Name\": \"\", \"RunTimeTicks\": 1000000000, \"UserData\": { \"PlaybackPositionTicks\": 140000000 } }".data(using: .utf8)!)
        #expect(AppleMediaServerLibraryStore.resumePosition(for: itemZero) == nil) // 14s < 15s
        
        let itemValid = try JSONDecoder().decode(AppleMediaServerItem.self, from: "{ \"Id\": \"1\", \"Name\": \"\", \"RunTimeTicks\": 1000000000, \"UserData\": { \"PlaybackPositionTicks\": 500000000 } }".data(using: .utf8)!)
        #expect(AppleMediaServerLibraryStore.resumePosition(for: itemValid) == 50.0)
        
        let itemEnd = try JSONDecoder().decode(AppleMediaServerItem.self, from: "{ \"Id\": \"1\", \"Name\": \"\", \"RunTimeTicks\": 1000000000, \"UserData\": { \"PlaybackPositionTicks\": 960000000 } }".data(using: .utf8)!)
        #expect(AppleMediaServerLibraryStore.resumePosition(for: itemEnd) == nil) // 96s > 95% of 100s
        
        // metadata mapping
        let meta = store.metadata(from: detailMovie)
        #expect(meta.title == "Movie 1")
        #expect(meta.mediaType == "movie")
        #expect(meta.runtimeMinutes == 120)
    }
    @Test("Merged resume prefers further position unless played")
    func testMergedResume() {
        let local = ApplePlaybackProgress(position: 100, duration: 200, updatedAt: Date())
        let serverUnplayed = AppleMediaServerItem.UserData(positionSeconds: 50, played: false, isFavorite: false, playCount: 0)
        let merged1 = AppleMediaServerLibraryStore.mergedResume(local: local, server: serverUnplayed)
        #expect(merged1 == 100) // max(100, 50)
        
        let serverPlayed = AppleMediaServerItem.UserData(positionSeconds: 0, played: true, isFavorite: false, playCount: 1)
        let merged2 = AppleMediaServerLibraryStore.mergedResume(local: local, server: serverPlayed)
        #expect(merged2 == 0) // played = true wins
        
        let localNone: ApplePlaybackProgress? = nil
        let merged3 = AppleMediaServerLibraryStore.mergedResume(local: localNone, server: serverUnplayed)
        #expect(merged3 == 50)
        
        let serverNone: AppleMediaServerItem.UserData? = nil
        let merged4 = AppleMediaServerLibraryStore.mergedResume(local: local, server: serverNone)
        #expect(merged4 == 100)
    }

    @Test("Remote progress sink reports to client and updates item")
    func testRemoteProgressSink() async throws {
        let sourceID = UUID()
        let source = AppleSource(id: sourceID, kind: .mediaServer, name: "S", url: URL(string: "https://fixture.example/emby/")!, isEnabled: true)
        let session = AppleMediaServerSession(kind: .emby, baseURL: source.url, accessToken: "tk", userID: "u")
        
        final class ProgressState: @unchecked Sendable {
            private let lock = NSLock()
            var reportedStarted = false
            var reportedProgress = 0
            var reportedStopped = 0
            var isPausedSent = false
            
            func setStarted() { lock.lock(); reportedStarted = true; lock.unlock() }
            func incProgress() { lock.lock(); reportedProgress += 1; lock.unlock() }
            func incStopped() { lock.lock(); reportedStopped += 1; lock.unlock() }
            func setPausedSent() { lock.lock(); isPausedSent = true; lock.unlock() }
            
            var started: Bool { lock.lock(); defer { lock.unlock() }; return reportedStarted }
            var progress: Int { lock.lock(); defer { lock.unlock() }; return reportedProgress }
            var stopped: Int { lock.lock(); defer { lock.unlock() }; return reportedStopped }
            var pausedSent: Bool { lock.lock(); defer { lock.unlock() }; return isPausedSent }
        }
        let state = ProgressState()
        
        let client = AppleMediaServerClient(loader: { req in
            let path = req.url!.path
            let json = "{}"
            if path.hasSuffix("m1") {
                return ("""
                { "Id": "m1", "Name": "Movie", "Type": "Movie", "RunTimeTicks": 1000000000 }
                """.data(using: .utf8)!, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            } else if path.hasSuffix("PlaybackInfo") {
                return ("""
                { "MediaSources": [ { "Id": "src1", "SupportsDirectStream": true } ], "PlaySessionId": "sess1" }
                """.data(using: .utf8)!, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            } else if path.hasSuffix("Playing") {
                state.setStarted()
            } else if path.hasSuffix("Progress") {
                state.incProgress()
                if let body = req.httpBody, String(data: body, encoding: .utf8)?.contains("\"IsPaused\":true") == true {
                    state.setPausedSent()
                }
            } else if path.hasSuffix("Stopped") {
                state.incStopped()
            } else if path.hasSuffix("Views") || path.hasSuffix("Resume") || path.hasSuffix("Latest") {
                return ("{ \"Items\": [], \"TotalRecordCount\": 0 }".data(using: .utf8)!, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            return (json.data(using: .utf8)!, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        
        let store = AppleMediaServerLibraryStore(client: client)
        await store.reload(sources: [source]) { _ in return session }
        
        let ref = AppleMediaServerItemReference(sourceID: sourceID, itemID: "m1")
        let detail = try await store.detail(for: ref)
        let req = try await store.playbackRequest(for: detail.item, in: detail, resume: false)
        let mediaID = req.mediaID
        
        // Emulate coordinator sink
        store.handleRemoteProgress(mediaID: mediaID, position: 10, duration: 100, event: .started)
        
        // The report runs in an unstructured task: await the request itself, not a fixed delay.
        await waitUntil { state.started }
        #expect(state.started == true)
        
        store.handleRemoteProgress(mediaID: mediaID, position: 20, duration: 100, event: .progress)
        store.handleRemoteProgress(mediaID: mediaID, position: 25, duration: 100, event: .progress)
        store.handleRemoteProgress(mediaID: mediaID, position: 30, duration: 100, event: .paused)
        
        await waitUntil { state.progress == 3 && state.pausedSent }
        #expect(state.progress == 3) // It sends what it gets. Throttling is in Coordinator
        #expect(state.pausedSent == true)
        
        // Stopped at 40% (moved to front of continue watching)
        store.handleRemoteProgress(mediaID: mediaID, position: 40, duration: 100, event: .stopped)
        await waitUntil { state.stopped == 1 }
        #expect(state.stopped == 1)
        #expect(store.continueWatching.first?.mediaID == mediaID)
        #expect(store.item(for: ref)?.userData?.positionSeconds == 40)
        
        // Second stopped is ignored: it returns before spawning a report, so the
        // count cannot move. The `== 2` below (not 3) re-proves it once the next
        // stop has landed.
        store.handleRemoteProgress(mediaID: mediaID, position: 40, duration: 100, event: .stopped)
        #expect(state.stopped == 1) // still 1
        
        // Stopped at 96% (marked played, removed from continue watching)
        // Reset stopped tracking by pretending it's a new session, wait we need a new request
        let req2 = try await store.playbackRequest(for: detail.item, in: detail, resume: false)
        store.handleRemoteProgress(mediaID: req2.mediaID, position: 96, duration: 100, event: .stopped)
        await waitUntil { state.stopped >= 2 }
        #expect(state.stopped == 2)
        #expect(store.continueWatching.first?.mediaID != mediaID)
        #expect(store.item(for: ref)?.userData?.played == true)
        #expect(store.item(for: ref)?.userData?.positionSeconds == 0)
    }

    @Test("Plex shelves, onDeck, poster URL, mixed sources")
    func testPlexIntegration() async throws {
        let embySourceID = UUID()
        let plexSourceID = UUID()
        
        let embySource = AppleSource(id: embySourceID, kind: .mediaServer, name: "Emby", url: URL(string: "https://emby.fixture/")!, isEnabled: true)
        let plexSource = AppleSource(id: plexSourceID, kind: .mediaServer, name: "Plex", url: URL(string: "https://plex.fixture/")!, isEnabled: true)
        
        let embySession = AppleMediaServerSession(kind: .emby, baseURL: embySource.url, accessToken: "e_tok", userID: "e_u")
        let plexSession = AppleMediaServerSession(kind: .plex, baseURL: plexSource.url, accessToken: "p_tok", userID: "p_u")
        
        let client = AppleMediaServerClient(loader: { req in
            let path = req.url!.path
            if path.hasSuffix("Views") {
                return ("""
                { "Items": [] }
                """.data(using: .utf8)!, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            } else if path.hasSuffix("Resume") {
                return ("""
                { "Items": [], "TotalRecordCount": 0 }
                """.data(using: .utf8)!, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            return ("{}".data(using: .utf8)!, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        
        let plexClient = ApplePlexClient(loader: { req in
            let urlStr = req.url!.absoluteString
            if urlStr.contains("library/onDeck") {
                return ("""
                {"MediaContainer": {"size": 1, "Metadata": [{"ratingKey": "p1", "key": "/library/metadata/p1", "title": "Plex OnDeck", "type": "movie", "viewOffset": 50000, "duration": 1000000, "thumb": "/library/metadata/p1/thumb/123"}]}}
                """.data(using: .utf8)!, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            } else if urlStr.contains("recentlyAdded") {
                return ("""
                {"MediaContainer": {"size": 1, "Metadata": [{"ratingKey": "p2", "key": "/library/metadata/p2", "title": "Plex Recent", "type": "movie"}]}}
                """.data(using: .utf8)!, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            } else if urlStr.contains("library/sections") {
                return ("""
                {"MediaContainer": {"size": 1, "Directory": [{"key": "1", "type": "movie", "title": "Movies"}]}}
                """.data(using: .utf8)!, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            } else if urlStr.contains("library/metadata/s1/children") {
                return ("""
                {"MediaContainer": {"size": 1, "Metadata": [{"ratingKey": "sea1", "key": "/library/metadata/sea1", "type": "season", "title": "Season 1"}]}}
                """.data(using: .utf8)!, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            } else if urlStr.contains("library/metadata/sea1/children") {
                return ("""
                {"MediaContainer": {"size": 1, "Metadata": [{"ratingKey": "ep1", "key": "/library/metadata/ep1", "type": "episode", "title": "Episode 1"}]}}
                """.data(using: .utf8)!, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            } else if urlStr.contains("library/metadata/s1") {
                return ("""
                {"MediaContainer": {"size": 1, "Metadata": [{"ratingKey": "s1", "key": "/library/metadata/s1", "type": "show", "title": "Plex Series"}]}}
                """.data(using: .utf8)!, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            } else if urlStr.contains("library/metadata/p1") {
                return ("""
                {"MediaContainer": {"size": 1, "Metadata": [{"ratingKey": "p1", "key": "/library/metadata/p1", "type": "movie", "title": "Plex OnDeck", "viewOffset": 50000, "duration": 1000000, "Media": [{"id": "m1", "Part": [{"id": "part1", "key": "/library/parts/1/123/file.mp4"}]}]}]}}
                """.data(using: .utf8)!, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            return (Data(), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        
        let store = AppleMediaServerLibraryStore(client: client, plexClient: plexClient)
        await store.reload(sources: [embySource, plexSource]) { s in
            if s.id == embySourceID { return embySession }
            if s.id == plexSourceID { return plexSession }
            return nil
        }
        
        #expect(store.failures.isEmpty, "reload failures: \(store.failures)")
        #expect(store.shelves.count == 1)
        #expect(store.shelves.first?.title == "Recently added in Movies")
        #expect(store.shelves.first?.items.count == 1)
        #expect(store.shelves.first?.items.first?.name == "Plex Recent")
        
        #expect(store.continueWatching.count == 1)
        #expect(store.continueWatching.first?.name == "Plex OnDeck")
        #expect(store.continueWatching.first?.posterURL != nil) // has thumb
        #expect(store.continueWatching.first?.posterURL?.absoluteString.contains("width=600&height=900") == true)
        
        // Show detail
        let refSeries = AppleMediaServerItemReference(sourceID: plexSourceID, itemID: "s1")
        let detail = try await store.detail(for: refSeries)
        #expect(detail.item.name == "Plex Series")
        #expect(detail.seasons.count == 1)
        #expect(detail.episodesBySeason["sea1"]?.count == 1)
        
        // Playback & Resume rule (50s / 1000s -> 5%)
        let refP1 = AppleMediaServerItemReference(sourceID: plexSourceID, itemID: "p1")
        let detailP1 = try await store.detail(for: refP1)
        let req = try await store.playbackRequest(for: detailP1.item, in: detailP1, resume: true)
        #expect(req.url.absoluteString.contains("/library/parts/1/123/file.mp4"))
        #expect(req.resumePosition == 50.0)
        #expect(req.headers["X-Plex-Token"] == "p_tok")
    }
}

/// Polls a condition the store satisfies from an unstructured task; a fixed
/// sleep races the scheduler when the whole gate runs in parallel.
@MainActor
private func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !condition(), clock.now < deadline {
        try? await Task.sleep(for: .milliseconds(10))
    }
}
