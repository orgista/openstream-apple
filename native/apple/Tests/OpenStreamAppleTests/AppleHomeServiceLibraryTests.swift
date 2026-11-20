import Foundation
import Synchronization
import Testing
@testable import OpenStreamApple

@MainActor
struct AppleHomeServiceLibraryTests {
    @Test func plexLibrariesAndCollectionsSupplyServicesAndKeepPaging() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let domain = "service-plex.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let source = AppleSource(kind: .mediaServer, name: "Fixture", url: try #require(URL(string: "https://fixture.example")))
        let session = AppleMediaServerSession(kind: .plex, baseURL: source.url, accessToken: "fixture", userID: "fixture")
        let client = ApplePlexClient(loader: { request in
            let url = try #require(request.url)
            var container: [String: Any] = ["size": 0, "Metadata": [], "Hub": []]
            if url.path == "/library/sections" {
                container["Directory"] = [["key": "1", "type": "movie", "title": "Netflix Movies"],
                                          ["key": "2", "type": "movie", "title": "Movies"]]
            } else if url.path.hasSuffix("/collections") {
                container = ["size": 1, "totalSize": 1, "Metadata": [
                    ["ratingKey": "hulu", "key": "/library/metadata/hulu/children", "title": "Hulu", "type": "collection"]]]
            } else if url.path == "/library/metadata/hulu/children" {
                let entries = (0..<12).map { ["ratingKey": "hulu-\($0)", "key": "/library/metadata/hulu-\($0)",
                    "title": "Hulu Film \($0)", "type": "movie", "thumb": "/library/metadata/hulu-\($0)/thumb/1"] }
                container = ["size": 12, "totalSize": 12, "Metadata": entries]
            } else if url.path.hasSuffix("/all") {
                let start = Int(request.value(forHTTPHeaderField: "X-Plex-Container-Start") ?? "0") ?? 0
                let entries: [[String: Any]] = (start..<min(start + 40, 92)).map { index in
                    var item: [String: Any] = ["ratingKey": "\(index)", "key": "/library/metadata/\(index)",
                        "title": "Film \(index)", "type": "movie"]
                    if index >= 40 { item["thumb"] = "/library/metadata/\(index)/thumb/1" }
                    return item
                }
                container = ["size": entries.count, "totalSize": 92, "Metadata": entries]
            }
            return (try JSONSerialization.data(withJSONObject: ["MediaContainer": container]),
                try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        })
        let store = AppleMediaServerLibraryStore(plexClient: client, progressDefaults: defaults, cacheFileURL: root.appendingPathComponent("servers.json"))
        await store.reload(sources: [source]) { _ in session }
        let service = try #require(AppleHomeServices.detect(libraries: store.serviceLibraries, sources: [source]).first)
        let library = try #require(service.libraries.first)
        #expect(library.items.count == 80)
        #expect(library.totalItemCount == 92)
        #expect(store.canLoadMore(shelfID: library.id))
        await store.loadMore(shelfID: library.id)
        #expect(store.serviceLibraries.first { $0.id == library.id }?.items.count == 92)
        let loadedIDs = store.serviceLibraries.first { $0.id == library.id }?.items.map(\.id)
        await store.reload(sources: [source]) { _ in session }
        #expect(store.serviceLibraries.first { $0.id == library.id }?.items.map(\.id) == loadedIDs)
        #expect(store.canLoadMore(shelfID: library.id) == false)
        #expect(AppleHomeServices.detect(libraries: store.serviceLibraries, sources: [source]).map(\.service) == [.netflix, .hulu])
    }

    @Test func serviceLibraryPagesPastTheShelfLimitAndRestoresItsCursor() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let domain = "service-paging.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let source = AppleSource(kind: .mediaServer, name: "Fixture", url: try #require(URL(string: "https://fixture.example")))
        let session = AppleMediaServerSession(kind: .jellyfin, baseURL: source.url, accessToken: "fixture", userID: "fixture")
        let offsets = Mutex<[Int]>([])
        let client = AppleMediaServerClient(loader: { request in
            let url = try #require(request.url)
            var object: Any = ["Items": []]
            if url.path.hasSuffix("Views") {
                object = ["Items": [["Id": "netflix", "Name": "Netflix Movies (Library)", "CollectionType": "movies"]]]
            } else if url.path.hasSuffix("Latest") {
                object = []
            } else if url.path.hasSuffix("Items") {
                let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                let start = Int(query.first { $0.name == "StartIndex" }?.value ?? "0") ?? 0
                #expect(query.first { $0.name == "SortBy" }?.value == "SortName")
                offsets.withLock { $0.append(start) }
                let entries: [[String: Any]] = (start..<min(start + 40, 525)).map {
                    ["Id": "title-\($0)", "Name": "Film \($0)", "Type": "Movie", "ImageTags": ["Primary": "art"]]
                }
                object = ["Items": entries, "TotalRecordCount": 525]
            }
            return (try JSONSerialization.data(withJSONObject: object),
                try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        })
        let cache = root.appendingPathComponent("servers.json")
        let store = AppleMediaServerLibraryStore(client: client, progressDefaults: defaults, cacheFileURL: cache)
        await store.reload(sources: [source]) { _ in session }
        let library = try #require(store.serviceLibraries.first)
        #expect(library.items.count == 40)
        #expect(library.totalItemCount == 525)
        #expect(AppleDiscoverServerRows.rows(store.shelves, sources: [source]).isEmpty)
        await store.loadMore(shelfID: library.id)
        await store.loadMore(shelfID: library.id)
        let pagedIDs = try #require(store.serviceLibraries.first).items.map(\.id)
        #expect(pagedIDs.count == 120)
        await store.reload(sources: [source]) { _ in session }
        #expect(store.serviceLibraries.first?.items.map(\.id) == pagedIDs)
        await store.refreshIfNeeded(shelfID: library.id, now: .distantFuture)
        #expect(store.serviceLibraries.first?.items.map(\.id) == pagedIDs)
        await store.loadMore(shelfID: library.id)
        #expect(offsets.withLock { $0.last } == 120)
        while store.canLoadMore(shelfID: library.id) { await store.loadMore(shelfID: library.id) }
        #expect(store.serviceLibraries.first?.items.count == 525)
        #expect(store.item(for: .init(sourceID: source.id, itemID: "title-524")) != nil)
        #expect(offsets.withLock { $0 } == [0, 40, 80, 0, 0] + Array(stride(from: 120, to: 525, by: 40)))
        let restored = AppleMediaServerLibraryStore(client: client, progressDefaults: defaults, cacheFileURL: cache)
        restored.loadPersisted(sources: [source]) { _ in session }
        #expect(restored.serviceLibraries.first?.items.count == 40)
        #expect(restored.serviceLibraries.first?.libraryName == library.libraryName)
        #expect(restored.serviceLibraries.first?.totalItemCount == 525)
        #expect(restored.canLoadMore(shelfID: library.id))
        await restored.loadMore(shelfID: library.id)
        #expect(offsets.withLock { $0.last } == 40)
        #expect(restored.serviceLibraries.first?.items.count == 80)
    }

    @Test func failedCollectionsAreOptionalAndCachedWithoutBlockingServicePaging() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let domain = "service-optional-collections.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let source = AppleSource(kind: .mediaServer, name: "Fixture", url: try #require(URL(string: "https://fixture.example")))
        let session = AppleMediaServerSession(kind: .jellyfin, baseURL: source.url, accessToken: "fixture", userID: "fixture")
        let collectionRequests = Mutex(0)
        let client = AppleMediaServerClient(loader: { request in
            let url = try #require(request.url)
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            var object: Any = ["Items": []]
            if query.first(where: { $0.name == "IncludeItemTypes" })?.value == "BoxSet" {
                collectionRequests.withLock { $0 += 1 }
                throw AppleMediaServerError.invalidCredentials
            } else if url.path.hasSuffix("Views") {
                object = ["Items": [["Id": "netflix", "Name": "Netflix", "CollectionType": "movies"],
                                    ["Id": "movies", "Name": "Movies", "CollectionType": "movies"],
                                    ["Id": "shows", "Name": "Netflix Series", "CollectionType": "tvshows"]]]
            } else if url.path.hasSuffix("Latest") {
                object = []
            } else if query.first(where: { $0.name == "ParentId" })?.value == "shows" {
                throw URLError(.timedOut)
            } else if query.first(where: { $0.name == "ParentId" })?.value == "netflix" {
                let start = Int(query.first { $0.name == "StartIndex" }?.value ?? "0") ?? 0
                object = ["Items": (start..<min(start + 40, 92)).map {
                    ["Id": "title-\($0)", "Name": "Film \($0)", "Type": "Movie", "ImageTags": ["Primary": "art"]]
                }, "TotalRecordCount": 92]
            }
            return (try JSONSerialization.data(withJSONObject: object),
                try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        })
        let store = AppleMediaServerLibraryStore(client: client, progressDefaults: defaults, cacheFileURL: root.appendingPathComponent("servers.json"))
        await store.reload(sources: [source]) { _ in session }
        #expect(store.failures.isEmpty)
        #expect(AppleHomeServices.detect(libraries: store.serviceLibraries, sources: [source]).first?.mediaTypes == [.movies, .shows])
        let library = try #require(store.serviceLibraries.first)
        await store.loadMore(shelfID: library.id)
        #expect(store.serviceLibraries.first?.items.count == 80)
        await store.reload(sources: [source]) { _ in session }
        #expect(store.failures.isEmpty)
        #expect(store.serviceLibraries.first?.items.count == 80)
        #expect(collectionRequests.withLock { $0 } == 1)
    }

    @Test(arguments: [AppleMediaServerKind.jellyfin, .plex])
    func detectionStopsAfterFivePagesAndPersistsOnlyTheFirstPage(kind: AppleMediaServerKind) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let domain = "service-detection-cap.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let source = AppleSource(kind: .mediaServer, name: "Fixture", url: try #require(URL(string: "https://fixture.example")))
        let session = AppleMediaServerSession(kind: kind, baseURL: source.url, accessToken: "fixture", userID: "fixture")
        let offsets = Mutex<[Int]>([])
        let loader: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse) = { request in
            let url = try #require(request.url)
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            var object: Any = ["Items": []]
            if kind == .plex {
                var container: [String: Any] = ["size": 0, "Metadata": [], "Hub": []]
                if url.path == "/library/sections" {
                    container["Directory"] = [["key": "1", "type": "movie", "title": "Netflix"]]
                } else if url.path.hasSuffix("/all") {
                    let start = Int(request.value(forHTTPHeaderField: "X-Plex-Container-Start") ?? "0") ?? 0
                    offsets.withLock { $0.append(start) }
                    let entries = (start..<(start + 40)).map {
                        ["ratingKey": "\($0)", "key": "/library/metadata/\($0)", "title": "Film \($0)", "type": "movie"]
                    }
                    container = ["size": entries.count, "totalSize": 20_000, "Metadata": entries]
                }
                object = ["MediaContainer": container]
            } else if url.path.hasSuffix("Views") {
                object = ["Items": [["Id": "netflix", "Name": "Netflix", "CollectionType": "movies"]]]
            } else if url.path.hasSuffix("Latest") {
                object = []
            } else if query.first(where: { $0.name == "ParentId" })?.value == "netflix" {
                let start = Int(query.first { $0.name == "StartIndex" }?.value ?? "0") ?? 0
                offsets.withLock { $0.append(start) }
                object = ["Items": (start..<(start + 40)).map {
                    ["Id": "title-\($0)", "Name": "Film \($0)", "Type": "Movie"]
                }, "TotalRecordCount": 20_000]
            }
            return (try JSONSerialization.data(withJSONObject: object),
                try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
        let cache = root.appendingPathComponent("servers.json")
        let store = AppleMediaServerLibraryStore(client: AppleMediaServerClient(loader: loader),
            plexClient: ApplePlexClient(loader: loader), progressDefaults: defaults, cacheFileURL: cache)
        await store.reload(sources: [source]) { _ in session }
        #expect(offsets.withLock { $0 } == [0, 40, 80, 120, 160])
        #expect(store.serviceLibraries.first?.items.count == 200)
        #expect(AppleHomeServices.detect(libraries: store.serviceLibraries, sources: [source]).map(\.service) == [.netflix])
        let restored = AppleMediaServerLibraryStore(client: AppleMediaServerClient(loader: loader),
            plexClient: ApplePlexClient(loader: loader), progressDefaults: defaults, cacheFileURL: cache)
        restored.loadPersisted(sources: [source]) { _ in session }
        let shelf = try #require(restored.serviceLibraries.first)
        #expect(shelf.items.count == 40)
        #expect(AppleHomeServices.detect(libraries: restored.serviceLibraries, sources: [source]).map(\.service) == [.netflix])
        await restored.loadMore(shelfID: shelf.id)
        #expect(offsets.withLock { $0.last } == 40)
        #expect(restored.serviceLibraries.first?.items.count == 80)
    }

    @Test(arguments: ["boxsets", "movies"])
    func collectionNamesSupplyServicesAndInitialDetectionFindsArtworkBeyondTheFirstPage(collectionType: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let domain = "service-collections.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let source = AppleSource(kind: .mediaServer, name: "Fixture", url: try #require(URL(string: "https://fixture.example")))
        let session = AppleMediaServerSession(kind: .jellyfin, baseURL: source.url, accessToken: "fixture", userID: "fixture")
        let client = AppleMediaServerClient(loader: { request in
            let url = try #require(request.url)
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            var object: Any = ["Items": []]
            if url.path.hasSuffix("Views") {
                object = ["Items": [["Id": "collections", "Name": "Collections", "CollectionType": collectionType]]]
            } else if url.path.hasSuffix("Latest") {
                object = []
            } else if query.first(where: { $0.name == "IncludeItemTypes" })?.value == "BoxSet" {
                object = ["Items": [["Id": "disney", "Name": "Disney Plus Movies", "Type": "BoxSet"],
                                    ["Id": "empty", "Name": "Max", "Type": "BoxSet"]]]
            } else if query.first(where: { $0.name == "ParentId" })?.value == "empty" {
                object = ["Items": [], "TotalRecordCount": 0]
            } else if url.path.hasSuffix("Items") {
                let start = Int(query.first { $0.name == "StartIndex" }?.value ?? "0") ?? 0
                let entries: [[String: Any]] = (start..<min(start + 40, 52)).map { index in
                    var item: [String: Any] = ["Id": "title-\(index)", "Name": "Title \(index)", "Type": index.isMultiple(of: 2) ? "Movie" : "Series"]
                    if index >= 40 { item["ImageTags"] = ["Primary": "art"] }
                    return item
                }
                object = ["Items": entries, "TotalRecordCount": 52]
            }
            return (try JSONSerialization.data(withJSONObject: object),
                try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        })
        let store = AppleMediaServerLibraryStore(client: client, progressDefaults: defaults, cacheFileURL: root.appendingPathComponent("servers.json"))
        await store.reload(sources: [source]) { _ in session }
        let detected = try #require(AppleHomeServices.detect(libraries: store.serviceLibraries, sources: [source]).first)
        #expect(detected.service == .disneyPlus)
        #expect(AppleHomeServices.items(in: detected.libraries).count == 52)
        #expect(detected.mediaTypes == [.movies, .shows])
        #expect(store.serviceLibraries.contains { $0.libraryName == "Max" && $0.items.isEmpty })
        #expect(AppleHomeRowSetting.services(shelves: store.shelves).contains { $0.id == "hboMax" })
        #expect(AppleHomeServices.detect(libraries: store.serviceLibraries, sources: [source]).count == 1)
        #expect(AppleDiscoverServerRows.rows(store.shelves, sources: [source]).isEmpty)
    }
}
