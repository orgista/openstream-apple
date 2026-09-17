import Foundation
import Testing

@Test
func catalogClientAcceptsCinemetaImdbIDPayloads() async throws {
    let source = AppleSource(
        kind: .stremio,
        name: "Cinemeta",
        url: URL(string: "https://v3-cinemeta.strem.io/manifest.json")!,
        resources: ["catalog"],
        catalogs: [AppleStremioCatalog(type: "movie", id: "top")]
    )
    let client = AppleStremioCatalogClient { request in
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        let data = Data(#"{"metas":[{"imdb_id":"tt1234567","type":"movie","name":"Cinemeta Film"}]}"#.utf8)
        return (data, response)
    }

    let items = try await client.load(source: source, catalog: source.catalogs[0])

    #expect(items.map(\.mediaID) == ["tt1234567"])
    #expect(items.first?.name == "Cinemeta Film")
}
@testable import OpenStreamApple

@Test func catalogTitleLookupPreservesCatalogOrderForAmbiguousTitles() throws {
    let source = AppleSource(kind: .stremio, name: "Ordered Catalog",
                             url: URL(string: "https://catalog.example/manifest.json")!)
    let catalog = AppleStremioCatalog(type: "movie", id: "ordered")
    let items = (0..<128).map {
        AppleCatalogItem(mediaID: "tt\(1_000_000 + $0)", type: "movie", name: "Shared Title")
    }
    for order in [items, Array(items.reversed())] {
        #expect(Set(order.map { AppleMediaIngestion.catalogRecord(instanceID: source.id, item: $0).id }).count == 128)
        let lookup = AppleCatalogSearchLookup(
            sections: [.init(source: source, catalog: catalog, items: order)], sources: [source])
        #expect(lookup.match(title: "shared title", type: "MOVIE")?.item == order.first)
    }
}

@Test func catalogCanonicalAvailabilityChoosesFirstEnabledSection() throws {
    let first = AppleSource(kind: .stremio, name: "First", url: URL(string: "https://first.example/manifest.json")!)
    let second = AppleSource(kind: .stremio, name: "Second", url: URL(string: "https://second.example/manifest.json")!)
    var disabled = AppleSource(kind: .stremio, name: "Disabled", url: URL(string: "https://disabled.example/manifest.json")!)
    disabled.isEnabled = false
    let catalog = AppleStremioCatalog(type: "movie", id: "popular")
    let item = AppleCatalogItem(mediaID: "tt100", type: "movie", name: "Shared Title")
    let sections = [disabled, first, second].map { AppleCatalogSection(source: $0, catalog: catalog, items: [item]) }
    let lookup = AppleCatalogSearchLookup(sections: sections, sources: [second, disabled, first])
    let id = AppleMediaIngestion.catalogRecord(instanceID: second.id, item: item).id
    #expect(lookup.match(for: id)?.source.id == first.id)
    #expect(lookup.match(title: item.name, type: item.type)?.source.id == first.id)
}

@Test func catalogSearchLookupBuildsNavigationAndRelatedItemsOncePerSnapshot() throws {
    let source = AppleSource(
        kind: .stremio,
        name: "Fast Catalog",
        url: URL(string: "https://catalog.example/manifest.json")!,
        resources: ["catalog"],
        catalogs: [
            .init(type: "movie", id: "popular", name: "Popular"),
            .init(type: "movie", id: "recent", name: "Recent"),
        ]
    )
    let first = AppleCatalogItem(mediaID: "tt100", type: "movie", name: "First")
    let second = AppleCatalogItem(mediaID: "tt200", type: "movie", name: "Second")
    let sections = [
        AppleCatalogSection(source: source, catalog: source.catalogs[0], items: [first, second]),
        AppleCatalogSection(source: source, catalog: source.catalogs[1], items: [first]),
    ]

    let lookup = AppleCatalogSearchLookup(sections: sections, sources: [source])
    let record = AppleMediaIngestion.catalogRecord(instanceID: source.id, item: second)
    let match = try #require(lookup.match(for: record.id))

    #expect(match.item == second)
    #expect(match.source == source)
    #expect(lookup.relatedItems(for: source.id) == [first, second])
    #expect(lookup.sourceName(for: record) == "Fast Catalog")
}

@Test func stremioCatalogClientBuildsTheEndpointAndParsesMediaCards() async throws {
    let source = AppleSource(
        kind: .stremio,
        name: "Example",
        url: URL(string: "https://addon.example/manifest.json")!,
        manifestID: "example.addon",
        resources: ["catalog"],
        catalogs: [.init(type: "movie", id: "popular", name: "Popular")]
    )
    let client = AppleStremioCatalogClient { request in
        #expect(request.url?.absoluteString == "https://addon.example/catalog/movie/popular.json")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        let data = Data(#"""
        {
          "metas":[
            {"id":"tt001","type":"movie","name":"One","poster":"https://img.example/one.jpg","background":"https://img.example/bg.jpg","description":"First","releaseInfo":"2026","imdbRating":"8.4"},
            {"id":"missing-name","type":"movie"},
            42,
            {"id":"tt001","type":"movie","name":"Duplicate"},
            {"id":"","type":"movie","name":"Invalid"}
          ]
        }
        """#.utf8)
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    let items = try await client.load(source: source, catalog: source.catalogs[0])
    #expect(items.count == 1)
    #expect(items[0].id == "movie:tt001")
    #expect(items[0].name == "One")
    #expect(items[0].rating == 8.4)
}

@Test func discoveryPolicyRequiresCatalogCapabilitySkipsInputAndAppliesBothLimits() async {
    let catalogs = (0 ..< 15).map {
        AppleStremioCatalog(
            type: $0.isMultiple(of: 2) ? "movie" : "series",
            id: "catalog-\($0)",
            requiresInput: $0 == 1,
            supportsSearch: $0 == 1
        )
    }
    let missingCapability = AppleSource(
        kind: .stremio,
        name: "No capability",
        url: URL(string: "https://none.example/manifest.json")!,
        catalogs: catalogs
    )
    #expect(AppleCatalogDiscoveryPolicy.catalogs(for: missingCapability).isEmpty)

    let source = AppleSource(
        kind: .stremio,
        name: "Bounded",
        url: URL(string: "https://bounded.example/manifest.json")!,
        resources: ["CATALOG"],
        catalogs: catalogs
    )
    let discoveryCatalogs = AppleCatalogDiscoveryPolicy.catalogs(for: source)
    #expect(discoveryCatalogs.count == 8)
    #expect(discoveryCatalogs.map(\.requiresInput) == Array(repeating: false, count: 8))
    #expect(AppleCatalogDiscoveryPolicy.catalogs(for: source, maximumCatalogs: 100).count == 12)

    let client = AppleStremioCatalogClient { request in
        Issue.record("No request should be made for an unadvertised catalog: \(request)")
        throw URLError(.badURL)
    }
    await #expect(throws: AppleStremioCatalogError.invalidSource) {
        try await client.load(source: source, catalog: .init(type: "movie", id: "not-advertised"))
    }
    await #expect(throws: AppleStremioCatalogError.invalidSource) {
        try await client.load(source: source, catalog: catalogs[1])
    }
}

@Test func catalogClientPercentEncodesSegmentsCapsItemsAndTrimsFields() async throws {
    let catalog = AppleStremioCatalog(type: "movie", id: "popular/now ?")
    let source = AppleSource(
        kind: .stremio,
        name: "Example",
        url: URL(string: "https://addon.example/manifest.json")!,
        resources: ["catalog"],
        catalogs: [catalog]
    )
    var metas: [Any] = [42, ["id": "missing-name"]]
    metas += (0 ..< 105).map { index -> [String: Any] in
        [
            "id": " item-\(index) ",
            "type": "movie",
            "name": index == 0 ? String(repeating: "N", count: 300) : "Item \(index)",
            "description": index == 0 ? String(repeating: "D", count: 5_000) : "Description",
            "releaseInfo": String(repeating: "2", count: 150),
            "poster": index == 0 ? String(repeating: "x", count: 2_100) : "https://img.example/\(index).jpg",
            "imdbRating": index == 0 ? 99 : 7.5,
        ]
    }
    let payload = try JSONSerialization.data(withJSONObject: ["metas": metas])
    let client = AppleStremioCatalogClient { request in
        #expect(request.url?.absoluteString == "https://addon.example/catalog/movie/popular%2Fnow%20%3F.json")
        return (payload, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    let items = try await client.load(source: source, catalog: catalog)

    #expect(items.count == 100)
    #expect(items.first?.mediaID == "item-0")
    #expect(items.first?.name.count == 200)
    #expect(items.first?.summary?.count == 4_000)
    #expect(items.first?.releaseInfo?.count == 100)
    #expect(items.first?.posterURL == nil)
    #expect(items.first?.rating == nil)
    #expect(items.last?.mediaID == "item-99")
}

@MainActor
@Test func catalogStoreKeepsSuccessfulSectionsWhenAnotherSourceFails() async throws {
    let good = AppleSource(
        kind: .stremio,
        name: "Good",
        url: URL(string: "https://good.example/manifest.json")!,
        manifestID: "good",
        resources: ["catalog"],
        catalogs: [.init(type: "series", id: "featured", name: "Featured")]
    )
    let bad = AppleSource(
        kind: .stremio,
        name: "Bad",
        url: URL(string: "https://bad.example/manifest.json")!,
        manifestID: "bad",
        resources: ["catalog"],
        catalogs: [.init(type: "movie", id: "broken")]
    )
    let client = AppleStremioCatalogClient { request in
        if request.url?.host == "bad.example" { throw URLError(.cannotConnectToHost) }
        let data = Data(#"{"metas":[{"id":"show-1","type":"series","name":"Show"}]}"#.utf8)
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    let cacheURL = FileManager.default.temporaryDirectory
        .appending(path: "openstream-catalog-tests-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: cacheURL) }
    let store = AppleCatalogStore(client: client, cache: AppleCatalogCache(fileURL: cacheURL))

    await store.refresh(sources: [good, bad])

    #expect(store.sections.count == 1)
    #expect(store.sections[0].sourceName == "Good")
    #expect(store.sections[0].items.map(\.name) == ["Show"])
    #expect(store.partialErrors.count == 1)
    #expect(store.sourceRefreshReports.count == 2)
    let goodReport = try #require(store.sourceRefreshReports.first(where: { $0.sourceID == good.id }))
    #expect(goodReport.itemCount == 1)
    #expect(goodReport.successfulCatalogCount == 1)
    #expect(goodReport.failedCatalogCount == 0)
    #expect(goodReport.failureSummary == nil)
    let badReport = try #require(store.sourceRefreshReports.first(where: { $0.sourceID == bad.id }))
    #expect(badReport.itemCount == 0)
    #expect(badReport.successfulCatalogCount == 0)
    #expect(badReport.failedCatalogCount == 1)
    #expect(badReport.failureSummary?.isEmpty == false)

    let reloaded = AppleCatalogStore(client: client, cache: AppleCatalogCache(fileURL: cacheURL))
    await reloaded.loadCachedSections(sources: [good, bad])
    #expect(reloaded.sections == store.sections)
}

@Test func catalogCacheTracksSixHourFreshnessAndFiltersCurrentConfiguration() async throws {
    let now = Date(timeIntervalSince1970: 10_000_000)
    let source = AppleSource(
        kind: .stremio,
        name: "Original",
        url: URL(string: "https://cache.example/manifest.json")!,
        resources: ["catalog"],
        catalogs: [.init(type: "movie", id: "popular")]
    )
    let section = AppleCatalogSection(
        source: source,
        catalog: source.catalogs[0],
        items: [.init(mediaID: "one", type: "movie", name: "One")]
    )
    let cacheURL = FileManager.default.temporaryDirectory
        .appending(path: "openstream-cache-policy-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: cacheURL) }
    let cache = AppleCatalogCache(fileURL: cacheURL)
    try await cache.save([section], now: now)

    let renamed = AppleSource(
        id: source.id,
        kind: source.kind,
        name: "Renamed",
        url: source.url,
        addedAt: source.addedAt,
        resources: source.resources,
        catalogs: source.catalogs
    )
    let fresh = try #require(await cache.load(sources: [renamed], now: now.addingTimeInterval(5 * 60 * 60)))
    #expect(fresh.isFresh)
    #expect(fresh.sections.map(\.sourceName) == ["Renamed"])

    let stale = try #require(await cache.load(sources: [renamed], now: now.addingTimeInterval(7 * 60 * 60)))
    #expect(!stale.isFresh)

    let removed = try #require(await cache.load(sources: [], now: now.addingTimeInterval(60)))
    #expect(removed.sections.isEmpty)
    #expect(!removed.isFresh)

    let disabled = AppleSource(
        id: source.id,
        kind: source.kind,
        name: source.name,
        url: source.url,
        isEnabled: false,
        addedAt: source.addedAt,
        resources: source.resources,
        catalogs: source.catalogs
    )
    let disabledSnapshot = try #require(await cache.load(sources: [disabled], now: now.addingTimeInterval(60)))
    #expect(disabledSnapshot.sections.isEmpty)
}

@Test func catalogCacheRejectsContentFromAReconfiguredSourceIdentity() async throws {
    let sourceID = UUID()
    let catalog = AppleStremioCatalog(type: "movie", id: "popular")
    let oldSource = AppleSource(
        id: sourceID,
        kind: .stremio,
        name: "Provider",
        url: URL(string: "https://old.example/private/manifest.json")!,
        manifestID: "provider",
        version: "1",
        resources: ["catalog"],
        catalogs: [catalog]
    )
    let newSource = AppleSource(
        id: sourceID,
        kind: .stremio,
        name: "Provider",
        url: URL(string: "https://new.example/other/manifest.json")!,
        manifestID: "provider",
        version: "2",
        resources: ["catalog"],
        catalogs: [catalog]
    )
    let cacheURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: cacheURL) }
    let cache = AppleCatalogCache(fileURL: cacheURL)
    try await cache.save([
        AppleCatalogSection(
            source: oldSource,
            catalog: catalog,
            items: [.init(mediaID: "old", type: "movie", name: "Old")]
        ),
    ])

    let snapshot = try #require(await cache.load(sources: [newSource]))

    #expect(snapshot.sections.isEmpty)
    #expect(!snapshot.isFresh)
    #expect(AppleCatalogDiscoveryPolicy.sourceConfigurationID(for: oldSource).count == 64)
    #expect(AppleCatalogDiscoveryPolicy.sourceConfigurationID(for: oldSource)
        != AppleCatalogDiscoveryPolicy.sourceConfigurationID(for: newSource))
}

@Test func cacheReloadUsesTheCallersEffectiveCatalogLimit() async throws {
    let catalogs = (0 ..< 12).map { AppleStremioCatalog(type: "movie", id: "catalog-\($0)") }
    let source = AppleSource(
        kind: .stremio,
        name: "Many",
        url: URL(string: "https://many-cache.example/manifest.json")!,
        resources: ["catalog"],
        catalogs: catalogs
    )
    let sections = catalogs.map {
        AppleCatalogSection(
            source: source,
            catalog: $0,
            items: [.init(mediaID: $0.id, type: "movie", name: $0.id)]
        )
    }
    let cacheURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: cacheURL) }
    let cache = AppleCatalogCache(fileURL: cacheURL)
    try await cache.save(sections)

    #expect(await cache.load(sources: [source])?.sections.count == 8)
    #expect(await cache.load(sources: [source], maximumCatalogs: 12)?.sections.count == 12)
}

@MainActor
@Test func freshCompleteCachePreventsAnAutomaticNetworkRefresh() async throws {
    let now = Date(timeIntervalSince1970: 20_000_000)
    let source = AppleSource(
        kind: .stremio,
        name: "Cached",
        url: URL(string: "https://cached.example/manifest.json")!,
        resources: ["catalog"],
        catalogs: [.init(type: "movie", id: "popular")]
    )
    let section = AppleCatalogSection(
        source: source,
        catalog: source.catalogs[0],
        items: [.init(mediaID: "one", type: "movie", name: "One")]
    )
    let cacheURL = FileManager.default.temporaryDirectory
        .appending(path: "openstream-fresh-cache-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: cacheURL) }
    let cache = AppleCatalogCache(fileURL: cacheURL)
    try await cache.save([section], now: now)
    let client = AppleStremioCatalogClient { request in
        Issue.record("Fresh cache should avoid a request: \(request)")
        throw URLError(.badURL)
    }
    let store = AppleCatalogStore(client: client, cache: cache)

    await store.loadCachedSections(sources: [source], now: now.addingTimeInterval(60))
    await store.refresh(sources: [source])

    #expect(store.sections == [section])
    #expect(store.partialErrors.isEmpty)
}

private actor CatalogRequestProbe {
    private(set) var active = 0
    private(set) var peak = 0
    private(set) var total = 0

    func begin() {
        active += 1
        total += 1
        peak = max(peak, active)
    }

    func end() {
        active -= 1
    }
}

@MainActor
@Test func catalogRefreshBoundsConcurrentFanOutAndTotalQueuedRequests() async {
    let catalogs = (0 ..< 12).map { AppleStremioCatalog(type: "movie", id: "catalog-\($0)") }
    let sources = (0 ..< 10).map { index in
        AppleSource(
            kind: .stremio,
            name: "Many \(index)",
            url: URL(string: "https://many-\(index).example/manifest.json")!,
            resources: ["catalog"],
            catalogs: catalogs
        )
    }
    let probe = CatalogRequestProbe()
    let client = AppleStremioCatalogClient { request in
        await probe.begin()
        try? await Task.sleep(for: .milliseconds(20))
        await probe.end()
        let data = Data(#"{"metas":[{"id":"one","type":"movie","name":"One"}]}"#.utf8)
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    let cacheURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: cacheURL) }
    let store = AppleCatalogStore(client: client, cache: AppleCatalogCache(fileURL: cacheURL))

    await store.refresh(sources: sources, maximumCatalogs: 100, force: true)

    #expect(store.sections.count == AppleCatalogDiscoveryPolicy.maximumTotalRequests)
    #expect(await probe.total == AppleCatalogDiscoveryPolicy.maximumTotalRequests)
    #expect(await probe.peak <= AppleCatalogDiscoveryPolicy.maximumConcurrentRequests)
}

@MainActor
@Test func aSlowerOldRefreshCannotOverwriteANewerConfiguration() async {
    let slow = AppleSource(
        kind: .stremio,
        name: "Slow",
        url: URL(string: "https://slow.example/manifest.json")!,
        resources: ["catalog"],
        catalogs: [.init(type: "movie", id: "slow")]
    )
    let fast = AppleSource(
        kind: .stremio,
        name: "Fast",
        url: URL(string: "https://fast.example/manifest.json")!,
        resources: ["catalog"],
        catalogs: [.init(type: "series", id: "fast")]
    )
    let client = AppleStremioCatalogClient { request in
        if request.url?.host == "slow.example" {
            try? await Task.sleep(for: .milliseconds(100))
        }
        let type = request.url?.host == "slow.example" ? "movie" : "series"
        let data = Data("{\"metas\":[{\"id\":\"\(type)\",\"type\":\"\(type)\",\"name\":\"\(type)\"}]}".utf8)
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    let cacheURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: cacheURL) }
    let store = AppleCatalogStore(client: client, cache: AppleCatalogCache(fileURL: cacheURL))

    let older = Task { @MainActor in await store.refresh(sources: [slow], force: true) }
    try? await Task.sleep(for: .milliseconds(10))
    await store.refresh(sources: [fast], force: true)
    await older.value

    #expect(store.sections.map(\.sourceName) == ["Fast"])
    #expect(store.sections.first?.items.first?.type == "series")
    #expect(!store.isLoading)
}

@MainActor
@Test func catalogStoreHasNoBuiltInContentWhenNoSourcesExist() async {
    let store = AppleCatalogStore(
        client: AppleStremioCatalogClient { _ in
            Issue.record("No request should be made without a configured source")
            throw URLError(.badURL)
        },
        cache: AppleCatalogCache(fileURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
    )
    await store.refresh(sources: [])
    #expect(store.sections.isEmpty)
}
