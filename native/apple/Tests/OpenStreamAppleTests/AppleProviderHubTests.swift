import Foundation
import Testing
@testable import OpenStreamApple

@Suite("Provider home hubs")
@MainActor
struct AppleProviderHubTests {
    @Test("Plex hubs preserve routes, filter unsupported rows and page only their endpoint", arguments: [false, true])
    func plexHubs(emptyRefresh: Bool) async throws {
        let source = AppleSource(id: UUID(), kind: .mediaServer, name: "Fixture", url: URL(string: "https://fixture.example/")!, isEnabled: true)
        let session = AppleMediaServerSession(kind: .plex, baseURL: source.url, accessToken: "fixture", userID: "fixture")
        let client = ApplePlexClient(loader: { request in
            let path = request.url!.path
            let json: String
            if path == "/library/onDeck" { json = #"{"MediaContainer":{"Metadata":[]}}"# }
            else if path == "/library/sections" { json = #"{"MediaContainer":{"Directory":[{"key":"1","type":"movie","title":"Movies"}]}}"# }
            else if path == "/library/sections/1/collections" { json = #"{"MediaContainer":{"Metadata":[],"totalSize":0}}"# }
            else if path == "/library/recentlyAdded" { json = #"{"MediaContainer":{"Metadata":[{"ratingKey":"fallback","key":"/library/metadata/fallback","title":"Fallback","type":"movie"}]}}"# }
            else if path == "/hubs/sections/1" {
                json = #"{"MediaContainer":{"Hub":[{"hubIdentifier":"genre.action","key":"/hubs/action","title":"Action","type":"movie","size":1,"totalSize":2,"Metadata":[{"ratingKey":"a","key":"/library/metadata/a","title":"A","type":"movie"}]},{"hubIdentifier":"duplicate","key":"/hubs/duplicate","title":"Action","type":"movie","Metadata":[{"ratingKey":"b","key":"/library/metadata/b","title":"B","type":"movie"}]},{"hubIdentifier":"empty","key":"/hubs/empty","title":"Empty","type":"movie","Metadata":[]},{"hubIdentifier":"music","key":"/hubs/music","title":"Music","type":"artist","Metadata":[]}]}}"#
            } else if path == "/hubs/action" {
                let offset = request.value(forHTTPHeaderField: "X-Plex-Container-Start")
                #expect(offset == "1" || offset == "0")
                if offset == "1" {
                    json = #"{"MediaContainer":{"totalSize":2,"Metadata":[{"ratingKey":"c","key":"/library/metadata/c","title":"C","type":"movie"}]}}"#
                } else if emptyRefresh {
                    json = #"{"MediaContainer":{"totalSize":0,"Metadata":[]}}"#
                } else {
                    json = #"{"MediaContainer":{"totalSize":1,"Metadata":[{"ratingKey":"new","key":"/library/metadata/new","title":"New","type":"movie"}]}}"#
                }
            } else { Issue.record("Unexpected provider request"); json = #"{"MediaContainer":{}}"# }
            return (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let defaultsName = "provider-hubs-\(UUID())"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let store = AppleMediaServerLibraryStore(plexClient: client, progressDefaults: defaults)
        await store.reload(sources: [source]) { _ in session }
        #expect(store.failures.isEmpty)
        #expect(store.shelves.map(\.title) == ["Recently added in Movies", "Action"])
        let row = try #require(store.shelves.last)
        let firstRecord = AppleMediaIngestion.catalogRecord(instanceID: source.id, item: row.items[0])
        #expect(store.searchMatch(for: firstRecord)?.item.mediaID == row.items[0].mediaID)
        #expect(AppleMediaServerItemReference.parse(row.items[0].mediaID)?.itemID == "a")
        #expect(store.canLoadMore(shelfID: row.id))
        let unaffected = store.shelves[0]
        await store.loadMore(shelfID: row.id)
        #expect(store.shelves.last?.items.map(\.name) == ["A", "C"])
        let pagedItem = try #require(store.shelves.last?.items.last)
        let pagedRecord = AppleMediaIngestion.catalogRecord(instanceID: source.id, item: pagedItem)
        #expect(store.searchMatch(for: pagedRecord)?.item.mediaID == pagedItem.mediaID)
        #expect(!store.canLoadMore(shelfID: row.id))
        #expect(store.shelves[0] == unaffected)
        await store.refresh(shelfID: row.id)
        let refreshed = store.shelves.first { $0.id == row.id }
        #expect(refreshed?.items.map(\.name) == (emptyRefresh ? nil : ["New"]))
        #expect(store.shelves[0] == unaffected)
        #expect(store.searchMatch(for: firstRecord) == nil)
        #expect(store.searchMatch(for: pagedRecord) == nil)
        if !emptyRefresh {
            let replacement = try #require(refreshed?.items.first)
            let replacementRecord = AppleMediaIngestion.catalogRecord(instanceID: source.id, item: replacement)
            #expect(store.searchMatch(for: replacementRecord)?.item.mediaID == replacement.mediaID)
        }
    }

    @Test("Jellyfin and Emby next up uses bounded paging and unavailable hubs fall back silently", arguments: [AppleMediaServerKind.jellyfin, .emby])
    func nextUp(kind: AppleMediaServerKind) async throws {
        let source = AppleSource(id: UUID(), kind: .mediaServer, name: "Fixture", url: URL(string: "https://fixture.example/")!, isEnabled: true)
        let session = AppleMediaServerSession(kind: kind, baseURL: source.url, accessToken: "fixture", userID: "fixture")
        let client = AppleMediaServerClient(loader: { request in
            let path = request.url!.path
            if path.hasSuffix("/OStream/Feed") { return (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!) }
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let json: String
            var status = 200
            if path.hasSuffix("Views") { json = #"{"Items":[{"Id":"tv","Name":"Shows","CollectionType":"tvshows"},{"Id":"movies","Name":"Movies","CollectionType":"movies"}]}"# }
            else if path.hasSuffix("Resume") { json = #"{"Items":[]}"# }
            else if path.hasSuffix("Latest") { json = #"[{"Id":"recent","Name":"Recent","Type":"Movie"}]"# }
            else if query.contains(URLQueryItem(name: "IncludeItemTypes", value: "BoxSet")) { json = #"{"Items":[]}"# }
            else if path.hasSuffix("NextUp") {
                #expect(query.contains(URLQueryItem(name: "ParentId", value: "tv")))
                #expect(query.contains(URLQueryItem(name: "Limit", value: "20")))
                if query.contains(URLQueryItem(name: "StartIndex", value: "0")) {
                    json = #"{"TotalRecordCount":2,"Items":[{"Id":"episode","Name":"Next","Type":"Episode","SeriesId":"series"}]}"#
                } else { status = 404; json = "{}" }
            } else { Issue.record("Unexpected provider request"); json = "{}" }
            return (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        })
        let defaultsName = "provider-hubs-\(UUID())"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let store = AppleMediaServerLibraryStore(client: client, progressDefaults: defaults)
        await store.reload(sources: [source]) { _ in session }
        let row = try #require(store.shelves.first { $0.title == "Next up in Shows" })
        #expect(AppleMediaServerItemReference.parse(row.items[0].mediaID)?.itemID == "episode")
        let original = store.shelves
        await store.loadMore(shelfID: row.id)
        #expect(store.shelves == original)
        #expect(store.failures.isEmpty)
    }

    @Test("Unavailable and empty Plex home hubs retain the existing recent row silently", arguments: [404, 200])
    func optionalHubFallback(status: Int) async throws {
        let requests = HubRequestRecorder()
        let source = AppleSource(id: UUID(), kind: .mediaServer, name: "Fixture", url: URL(string: "https://fixture.example/")!, isEnabled: true)
        let session = AppleMediaServerSession(kind: .plex, baseURL: source.url, accessToken: "fixture", userID: "fixture")
        let client = ApplePlexClient(loader: { request in
            let path = request.url!.path
            let json: String
            if path == "/library/sections" { json = #"{"MediaContainer":{"Directory":[{"key":"1","type":"movie","title":"Movies"}]}}"# }
            else if path == "/library/recentlyAdded" { json = #"{"MediaContainer":{"Metadata":[{"ratingKey":"fallback","key":"/library/metadata/fallback","title":"Fallback","type":"movie"}]}}"# }
            else if path == "/hubs/sections/1" { json = #"{"MediaContainer":{"Hub":[{"hubIdentifier":"empty","key":"/hubs/empty","title":"Empty","type":"movie","Metadata":[]}]}}"# }
            else { json = #"{"MediaContainer":{"Metadata":[]}}"# }
            let failRecent = await requests.failRecent
            let responseStatus = path == "/library/recentlyAdded" && failRecent ? 503 : path == "/hubs/sections/1" ? status : 200
            return (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: responseStatus, httpVersion: nil, headerFields: nil)!)
        })
        let defaultsName = "provider-hubs-\(UUID())"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let store = AppleMediaServerLibraryStore(plexClient: client, progressDefaults: defaults)
        await store.reload(sources: [source]) { _ in session }
        #expect(store.shelves.map(\.title) == ["Recently added in Movies"])
        #expect(store.shelves[0].items[0].name == "Fallback")
        #expect(store.failures.isEmpty)
        let original = store.shelves
        await requests.makeRecentFail()
        await store.reload(sources: [source]) { _ in session }
        #expect(store.shelves == original)
        #expect(store.failures[source.id] == nil)
    }

    @Test("Affected-row refresh restores newly eligible next-up rows without fetching unrelated rows", arguments: [false, true])
    func affectedRefresh(initiallyEmpty: Bool) async throws {
        let source = AppleSource(id: UUID(), kind: .mediaServer, name: "Fixture", url: URL(string: "https://fixture.example/")!, isEnabled: true)
        let session = AppleMediaServerSession(kind: .jellyfin, baseURL: source.url, accessToken: "fixture", userID: "fixture")
        let requests = HubRequestRecorder()
        if initiallyEmpty { await requests.makeNextUpEmpty() }
        let client = AppleMediaServerClient(loader: { request in
            let path = request.url!.path
            if path.hasSuffix("/OStream/Feed") { return (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!) }
            await requests.record(path)
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let json: String
            if path.hasSuffix("Views") { json = #"{"Items":[{"Id":"tv","Name":"Shows","CollectionType":"tvshows"},{"Id":"movies","Name":"Movies","CollectionType":"movies"}]}"# }
            else if path.hasSuffix("Resume") { json = #"{"Items":[{"Id":"old","Name":"Old","Type":"Episode"}]}"# }
            else if path.hasSuffix("Latest") { json = #"[{"Id":"recent","Name":"Recent","Type":"Movie"}]"# }
            else if query.contains(URLQueryItem(name: "IncludeItemTypes", value: "BoxSet")) { json = #"{"Items":[]}"# }
            else if path.hasSuffix("NextUp") {
                json = await requests.emptyNextUp ? #"{"Items":[]}"# : #"{"Items":[{"Id":"next","Name":"Next","Type":"Episode"}]}"#
            }
            else { Issue.record("Unexpected provider request"); json = "{}" }
            return (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let defaultsName = "provider-hubs-\(UUID())"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let store = AppleMediaServerLibraryStore(client: client, progressDefaults: defaults)
        await store.reload(sources: [source]) { _ in session }
        let original = store.shelves
        if initiallyEmpty { #expect(!original.contains { $0.title == "Next up in Shows" }) }
        await requests.makeNextUpAvailable()
        await requests.reset()
        await store.refreshAffectedHubs(reference: .init(sourceID: source.id, itemID: "old"))
        let fetched = await requests.paths
        #expect(fetched == ["/Shows/NextUp"])
        #expect(store.shelves.map(\.title) == ["Latest in Shows", "Next up in Shows", "Latest in Movies"])
        #expect(store.shelves.filter { $0.title != "Next up in Shows" } == original.filter { $0.title != "Next up in Shows" })
        let available = store.shelves
        await requests.makeNextUpEmpty()
        await store.refreshAffectedHubs(reference: .init(sourceID: source.id, itemID: "old"))
        #expect(!store.shelves.contains { $0.title == "Next up in Shows" })
        #expect(store.shelves == original.filter { $0.title != "Next up in Shows" })
        #expect(store.failures.isEmpty)
        await requests.makeNextUpAvailable()
        await requests.reset()
        await store.refreshAffectedHubs(reference: .init(sourceID: source.id, itemID: "old"))
        #expect(store.shelves == available)
        let restoredFetches = await requests.paths
        #expect(restoredFetches == ["/Shows/NextUp"])
    }

    @Test("A page started before source disable or row refresh cannot overwrite the row", arguments: [true, false])
    func stalePage(disable: Bool) async throws {
        let source = AppleSource(id: UUID(), kind: .mediaServer, name: "Fixture", url: URL(string: "https://fixture.example/")!, isEnabled: true)
        let session = AppleMediaServerSession(kind: .jellyfin, baseURL: source.url, accessToken: "fixture", userID: "fixture")
        let gate = HubPageGate()
        let client = AppleMediaServerClient(loader: { request in
            let path = request.url!.path
            if path.hasSuffix("/OStream/Feed") { return (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!) }
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let json: String
            if path.hasSuffix("Views") { json = #"{"Items":[{"Id":"tv","Name":"Shows","CollectionType":"tvshows"}]}"# }
            else if path.hasSuffix("Resume") { json = #"{"Items":[]}"# }
            else if path.hasSuffix("Latest") { json = "[]" }
            else if query.contains(URLQueryItem(name: "IncludeItemTypes", value: "BoxSet")) { json = #"{"Items":[]}"# }
            else if path.hasSuffix("NextUp") {
                if query.contains(URLQueryItem(name: "StartIndex", value: "1")) {
                    await gate.waitForRelease()
                    json = #"{"TotalRecordCount":2,"Items":[{"Id":"stale","Name":"Stale","Type":"Episode"}]}"#
                } else { json = #"{"TotalRecordCount":2,"Items":[{"Id":"next","Name":"Next","Type":"Episode"}]}"# }
            } else { Issue.record("Unexpected provider request"); json = "{}" }
            return (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let defaultsName = "provider-hubs-\(UUID())"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let store = AppleMediaServerLibraryStore(client: client, progressDefaults: defaults)
        await store.reload(sources: [source]) { _ in session }
        let row = try #require(store.shelves.first { $0.title == "Next up in Shows" })
        let original = store.shelves
        let paging = Task { await store.loadMore(shelfID: row.id) }
        await gate.waitForStart()
        if disable {
            var disabled = source
            disabled.isEnabled = false
            await store.reload(sources: [disabled]) { _ in session }
        } else {
            await store.refresh(shelfID: row.id)
        }
        await gate.release()
        await paging.value
        #expect(store.shelves == (disable ? [] : original))
    }

    @Test("Genre rows load on appearance and retain their heading while pending", .timeLimit(.minutes(1)),
          arguments: [AppleMediaServerKind.jellyfin, .emby])
    func genreHubs(kind: AppleMediaServerKind) async throws {
        let source = AppleSource(id: UUID(), kind: .mediaServer, name: "Fixture", url: URL(string: "https://fixture.example/")!, isEnabled: true)
        let session = AppleMediaServerSession(kind: kind, baseURL: source.url, accessToken: "fixture", userID: "fixture")
        let gate = HubPageGate()
        let client = AppleMediaServerClient(loader: { request in
            let path = request.url!.path
            if path.hasSuffix("/OStream/Feed") { return (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!) }
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let json: String
            if path.hasSuffix("Views") { json = #"{"Items":[{"Id":"movies","Name":"Movies","CollectionType":"movies"}]}"# }
            else if path.hasSuffix("Resume") { json = #"{"Items":[]}"# }
            else if path.hasSuffix("Latest") { json = #"[{"Id":"local1","Name":"Local 1","Type":"Movie","Genres":["Action"]},{"Id":"local2","Name":"Local 2","Type":"Movie","Genres":["Action"]}]"# }
            else if query.contains(URLQueryItem(name: "IncludeItemTypes", value: "BoxSet")) { json = #"{"Items":[]}"# }
            else if path.hasSuffix("Items") {
                #expect(query.contains(URLQueryItem(name: "Genres", value: "Action")))
                #expect(query.contains(URLQueryItem(name: "ParentId", value: "movies")))
                #expect(query.contains(URLQueryItem(name: "IncludeItemTypes", value: "Movie")))
                #expect(query.contains(URLQueryItem(name: "Limit", value: "20")))
                if query.contains(URLQueryItem(name: "StartIndex", value: "2")) {
                    json = #"{"TotalRecordCount":3,"Items":[{"Id":"p3","Name":"Provider 3","Type":"Movie"}]}"#
                } else {
                    await gate.waitForRelease()
                    json = #"{"TotalRecordCount":3,"Items":[{"Id":"p1","Name":"Provider 1","Type":"Movie"},{"Id":"p2","Name":"Provider 2","Type":"Movie"}]}"#
                }
            } else { Issue.record("Unexpected provider request"); json = "{}" }
            return (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let defaultsName = "provider-hubs-\(UUID())"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = directory.appendingPathComponent("rows.json")
        let store = AppleMediaServerLibraryStore(client: client, progressDefaults: defaults, cacheFileURL: cache)
        await store.reload(sources: [source]) { _ in session }
        let row = try #require(store.shelves.last)
        #expect(row.id == "ms:\(source.id.uuidString.lowercased()):movies:genre:Action")
        #expect(!store.isLoading)
        #expect(row.items.isEmpty)
        #expect(store.isShelfPending(shelfID: row.id))
        let loading = Task { await store.refreshIfNeeded(shelfID: row.id) }
        await gate.waitForStart()
        #expect(store.isShelfPending(shelfID: row.id))
        #expect(store.shelves.contains { $0.id == row.id })
        await gate.release()
        await loading.value
        let loaded = try #require(store.shelves.first { $0.id == row.id })
        #expect(!store.isShelfPending(shelfID: row.id))
        #expect(loaded.items.map(\.name) == ["Provider 1", "Provider 2"])
        #expect(AppleMediaServerItemReference.parse(loaded.items[0].mediaID)?.itemID == "p1")
        #expect(store.canLoadMore(shelfID: row.id))
        await store.reload(sources: [source]) { _ in session }
        #expect(store.shelves.last == loaded)
        #expect(!store.isShelfPending(shelfID: row.id))
        #expect(store.canLoadMore(shelfID: row.id))
        let restored = AppleMediaServerLibraryStore(client: client, progressDefaults: defaults, cacheFileURL: cache)
        restored.loadPersisted(sources: [source]) { _ in session }
        #expect(restored.shelves.last == loaded)
        #expect(restored.canLoadMore(shelfID: row.id))
        await restored.reload(sources: [source]) { _ in session }
        #expect(restored.shelves.last == loaded)
        #expect(!restored.isShelfPending(shelfID: row.id))
        #expect(restored.canLoadMore(shelfID: row.id))
        let recent = store.shelves[0]
        await store.loadMore(shelfID: row.id)
        #expect(store.shelves.last?.items.map(\.name) == ["Provider 1", "Provider 2", "Provider 3"])
        #expect(store.shelves[0] == recent)
        #expect(!store.canLoadMore(shelfID: row.id))
    }

    @Test("Hub keys cannot send provider credentials outside the server")
    func unsafePlexHubKey() async throws {
        let client = ApplePlexClient(loader: { _ in Issue.record("Unsafe key reached loader"); throw AppleMediaServerError.unsupported })
        let session = AppleMediaServerSession(kind: .plex, baseURL: URL(string: "https://fixture.example/")!, accessToken: "fixture", userID: "fixture")
        for key in ["https://other.example/hub", "//other.example/hub", "/hubs/action?X-Plex-Token=other", "/hubs/../identity"] {
            await #expect(throws: AppleMediaServerError.self) { try await client.hubItems(session: session, key: key, start: 0, size: 20) }
        }
    }
}

private actor HubRequestRecorder {
    var paths: [String] = []
    var emptyNextUp = false
    var failRecent = false
    func makeRecentFail() { failRecent = true }
    func makeNextUpEmpty() { emptyNextUp = true }
    func makeNextUpAvailable() { emptyNextUp = false }
    func record(_ path: String) { paths.append(path) }
    func reset() { paths = [] }
}

private actor HubPageGate {
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func waitForRelease() async {
        started = true
        startWaiter?.resume()
        startWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
    }
    func waitForStart() async {
        if started { return }
        await withCheckedContinuation { startWaiter = $0 }
    }
    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
}
