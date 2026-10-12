import Testing
import Foundation
@testable import OpenStreamApple

@Suite("AppleMetadataDiskCache Tests")
struct AppleMetadataDiskCacheTests {
    @Test("Cache filenames distinguish complete provider endpoints without exposing them")
    func fileNameRules() throws {
        let endpoint = try #require(URL(string: "https://fixture.example/config-one/meta/movie/tt12345.json"))
        let otherEndpoint = try #require(URL(string: "https://fixture.example/config-two/meta/movie/tt12345.json"))
        let name = AppleMetadataDiskCachePolicy.fileName(source: endpoint.absoluteString, type: "movie", mediaID: "tt12345")
        #expect(name != AppleMetadataDiskCachePolicy.fileName(source: endpoint.absoluteString, type: "series", mediaID: "tt12345"))
        #expect(name != AppleMetadataDiskCachePolicy.fileName(source: endpoint.absoluteString, type: "movie", mediaID: "tt54321"))
        #expect(name != AppleMetadataDiskCachePolicy.fileName(source: otherEndpoint.absoluteString, type: "movie", mediaID: "tt12345"))
        #expect(name == AppleMetadataDiskCachePolicy.fileName(source: endpoint.absoluteString, type: "movie", mediaID: "tt12345"))
        #expect(name.hasSuffix(".json"))
        #expect(name.dropLast(5).count == 64)
        #expect(name.dropLast(5).allSatisfy { $0.isHexDigit })
        #expect(!name.contains("fixture"))
        #expect(!name.contains("config-one"))
    }

    @Test("Freshness boundaries")
    func freshnessBoundaries() {
        let now = Date()
        #expect(AppleMetadataDiskCachePolicy.freshness(storedAt: now.addingTimeInterval(-3600), now: now) == .fresh)
        #expect(AppleMetadataDiskCachePolicy.freshness(storedAt: now.addingTimeInterval(-48 * 3600), now: now) == .stale)
        #expect(AppleMetadataDiskCachePolicy.freshness(storedAt: now.addingTimeInterval(-15 * 24 * 3600), now: now) == .expired)
    }

    @Test("Round trip store and fetch removes only its expired entry")
    func roundTrip() async throws {
        let temp = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let cache = AppleMetadataDiskCache(directory: temp)
        let endpoint = try #require(URL(string: "https://fixture.example/meta/movie/test1.json"))
        let data = Data("payload".utf8)
        await cache.store(data, source: endpoint.absoluteString, type: "movie", mediaID: "test1")
        let entry = await cache.entry(source: endpoint.absoluteString, type: "movie", mediaID: "test1")
        #expect(entry?.payload == data)
        #expect(entry?.freshness == .fresh)

        let expiredName = AppleMetadataDiskCachePolicy.fileName(source: endpoint.absoluteString, type: "movie", mediaID: "expired")
        let expiredURL = temp.appendingPathComponent(expiredName)
        let expiredEntry = AppleMetadataDiskCache.Entry(
            storedAt: Date().addingTimeInterval(-15 * 24 * 3600), payload: Data("old".utf8)
        )
        try JSONEncoder().encode(expiredEntry).write(to: expiredURL)
        #expect(await cache.entry(source: endpoint.absoluteString, type: "movie", mediaID: "expired") == nil)
        #expect(!FileManager.default.fileExists(atPath: expiredURL.path))
        #expect(await cache.entry(source: endpoint.absoluteString, type: "movie", mediaID: "test1") != nil)
    }

    @Test("Client uses an explicitly injected fresh cache without calling loader")
    func clientUsesCache() async throws {
        let temp = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let cache = AppleMetadataDiskCache(directory: temp)
        let endpoint = try #require(URL(string: "https://fixture.example/meta/movie/tt99999.json"))
        await cache.store(Self.payload(title: "Cached Movie"), source: endpoint.absoluteString, type: "movie", mediaID: "tt99999")
        let loadCount = Counter()
        let client = AppleStremioMetadataClient(loader: { _ in
            await loadCount.increment()
            throw URLError(.notConnectedToInternet)
        }, metadataCache: cache)
        let details = try await client.details(source: source(), type: "movie", mediaID: "tt99999")
        #expect(details.title == "Cached Movie")
        #expect(await loadCount.value == 0)
    }

    @Test("The same title from a second provider retains its richer metadata")
    func sameTitleDifferentProviders() async throws {
        let temp = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let cache = AppleMetadataDiskCache(directory: temp)
        let loadCount = Counter()
        let client = AppleStremioMetadataClient(loader: { request in
            await loadCount.increment()
            let url = try #require(request.url)
            let rich = url.path.contains("secondary")
            let payload = rich
                ? Data(#"{"meta":{"id":"tt99999","type":"movie","name":"Secondary","runtime":"121","genres":["Drama"],"background":"https://fixture.example/backdrop.jpg"}}"#.utf8)
                : Self.payload(title: "Preferred")
            return (payload, try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }, metadataCache: cache)
        let preferred = try await client.details(source: source(path: "preferred"), type: "movie", mediaID: "tt99999")
        let secondary = try await client.details(source: source(path: "secondary"), type: "movie", mediaID: "tt99999")
        #expect(preferred.title == "Preferred")
        #expect(preferred.runtimeMinutes == nil)
        #expect(secondary.title == "Secondary")
        #expect(secondary.runtimeMinutes == 121)
        #expect(secondary.genres == ["Drama"])
        #expect(secondary.backdropURL == URL(string: "https://fixture.example/backdrop.jpg"))
        #expect(await loadCount.value == 2)
    }

    @Test("A new client and cache instance reuse the same persisted endpoint")
    func repeatedClientsUseDisk() async throws {
        let temp = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let loadCount = Counter()
        let first = AppleStremioMetadataClient(loader: { request in
            await loadCount.increment()
            let url = try #require(request.url)
            return (Self.payload(title: "Persisted Movie"), try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }, metadataCache: AppleMetadataDiskCache(directory: temp))
        _ = try await first.details(source: source(), type: "movie", mediaID: "tt99999")
        let second = AppleStremioMetadataClient(loader: { _ in
            await loadCount.increment()
            throw URLError(.notConnectedToInternet)
        }, metadataCache: AppleMetadataDiskCache(directory: temp))
        let cached = try await second.details(source: source(), type: "movie", mediaID: "tt99999")
        #expect(cached.title == "Persisted Movie")
        #expect(await loadCount.value == 1)
    }

    @Test("Injected loaders do not implicitly reuse persistence")
    func injectedLoaderStaysIsolated() async throws {
        let loadCount = Counter()
        let client = AppleStremioMetadataClient(loader: { request in
            await loadCount.increment()
            let url = try #require(request.url)
            return (Self.payload(title: "Fixture Movie"), try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        })
        _ = try await client.details(source: source(), type: "movie", mediaID: "tt99999")
        _ = try await client.details(source: source(), type: "movie", mediaID: "tt99999")
        #expect(await loadCount.value == 2)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("OpenStreamMetadataTests-\(UUID().uuidString)")
    }

    private func source(path: String = "") throws -> AppleSource {
        let prefix = path.isEmpty ? "" : "\(path)/"
        return AppleSource(kind: .stremio, name: "Fixture",
            url: try #require(URL(string: "https://fixture.example/\(prefix)manifest.json")), resources: ["meta"])
    }

    private static func payload(title: String) -> Data {
        Data("{\"meta\":{\"id\":\"tt99999\",\"type\":\"movie\",\"name\":\"\(title)\"}}".utf8)
    }

    private actor Counter {
        var value = 0
        func increment() { value += 1 }
    }

    private func waitUntil(_ condition: () async -> Bool, timeout: Duration) async throws {
        let start = ContinuousClock().now
        while ContinuousClock().now < start + timeout {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    @Test("Episodes are returned from cache without network call if fresh")
    func episodesUsesFreshCache() async throws {
        let temp = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let cache = AppleMetadataDiskCache(directory: temp)
        let endpoint = try #require(URL(string: "https://fixture.example/meta/series/tt1234568.json"))
        let payload = Data(#"{"meta":{"id":"tt1234568","type":"series","videos":[{"id":"tt1234568:1:1","title":"Fresh Episode","season":1,"episode":1}]}}"#.utf8)
        await cache.store(payload, source: endpoint.absoluteString, type: "episodes", mediaID: "tt1234568")
        let loadCount = Counter()
        let client = AppleStremioMetadataClient(loader: { _ in
            await loadCount.increment()
            throw URLError(.notConnectedToInternet)
        }, metadataCache: cache)
        
        let result = try await client.episodes(source: try source(), mediaID: "tt1234568")
        #expect(result.count == 1)
        #expect(result.first?.title == "Fresh Episode")
        #expect(await loadCount.value == 0)
    }

    @Test("Episodes are returned from cache but network is called if stale")
    func episodesRefreshesStaleCache() async throws {
        let temp = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let cache = AppleMetadataDiskCache(directory: temp)
        let endpoint = try #require(URL(string: "https://fixture.example/meta/series/tt1234569.json"))
        
        let stalePayload = Data(#"{"meta":{"id":"tt1234569","type":"series","videos":[{"id":"tt1234569:1:1","title":"Stale Episode","season":1,"episode":1}]}}"#.utf8)
        let name = AppleMetadataDiskCachePolicy.fileName(source: endpoint.absoluteString, type: "episodes", mediaID: "tt1234569")
        let url = temp.appendingPathComponent(name)
        let entry = AppleMetadataDiskCache.Entry(storedAt: Date().addingTimeInterval(-48 * 3600), payload: stalePayload)
        try JSONEncoder().encode(entry).write(to: url)
        
        let loadCount = Counter()
        let client = AppleStremioMetadataClient(loader: { request in
            await loadCount.increment()
            let newPayload = Data(#"{"meta":{"id":"tt1234569","type":"series","videos":[{"id":"tt1234569:1:1","title":"New Episode","season":1,"episode":1}]}}"#.utf8)
            return (newPayload, try #require(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }, metadataCache: cache)
        
        let result = try await client.episodes(source: try source(), mediaID: "tt1234569")
        #expect(result.count == 1)
        #expect(result.first?.title == "Stale Episode")
        
        try await waitUntil({ await loadCount.value >= 1 }, timeout: .seconds(3))
        #expect(await loadCount.value == 1)
    }

    @Test("Preview Assets are returned from cache without network call if fresh")
    func previewAssetsUsesFreshCache() async throws {
        let temp = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let cache = AppleMetadataDiskCache(directory: temp)
        let endpoint = try #require(URL(string: "https://fixture.example/meta/movie/tt123_pa_fresh.json"))
        let payload = Data(#"{"meta":{"id":"tt123_pa_fresh","type":"movie","logo":"https://fixture.example/logo.jpg","trailers":[{"source":"abcd1234567"}]}}"#.utf8)
        await cache.store(payload, source: endpoint.absoluteString, type: "preview-assets", mediaID: "tt123_pa_fresh")
        let loadCount = Counter()
        let client = AppleStremioMetadataClient(loader: { _ in
            await loadCount.increment()
            throw URLError(.notConnectedToInternet)
        }, metadataCache: cache)
        
        let result = await client.previewAssets(sources: [try source()], type: "movie", mediaID: "tt123_pa_fresh")
        #expect(result?.trailerYouTubeKeys == ["abcd1234567"])
        #expect(result?.logoURL?.absoluteString == "https://fixture.example/logo.jpg")
        #expect(await loadCount.value == 0)
    }

    @Test("Preview Assets are returned from cache but network is called if stale")
    func previewAssetsRefreshesStaleCache() async throws {
        let temp = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let cache = AppleMetadataDiskCache(directory: temp)
        let endpoint = try #require(URL(string: "https://fixture.example/meta/movie/tt123_pa_stale.json"))
        
        let stalePayload = Data(#"{"meta":{"id":"tt123_pa_stale","type":"movie","logo":"https://fixture.example/old.jpg","trailers":[]}}"#.utf8)
        let name = AppleMetadataDiskCachePolicy.fileName(source: endpoint.absoluteString, type: "preview-assets", mediaID: "tt123_pa_stale")
        let url = temp.appendingPathComponent(name)
        let entry = AppleMetadataDiskCache.Entry(storedAt: Date().addingTimeInterval(-48 * 3600), payload: stalePayload)
        try JSONEncoder().encode(entry).write(to: url)
        
        let loadCount = Counter()
        let client = AppleStremioMetadataClient(loader: { request in
            await loadCount.increment()
            let newPayload = Data(#"{"meta":{"id":"tt123_pa_stale","type":"movie","logo":"https://fixture.example/new.jpg","trailers":[{"source":"new1234567"}]}}"#.utf8)
            return (newPayload, try #require(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }, metadataCache: cache)
        
        let result = await client.previewAssets(sources: [try source()], type: "movie", mediaID: "tt123_pa_stale")
        #expect(result?.logoURL?.absoluteString == "https://fixture.example/old.jpg")
        #expect(result?.trailerYouTubeKeys == [])
        
        try await waitUntil({ await loadCount.value >= 1 }, timeout: .seconds(3))
        #expect(await loadCount.value == 1)
    }
}
