import Foundation
import Testing
@testable import OpenStreamApple

@Suite("Catalog paging with skip")
struct AppleCatalogPagingTests {
    private func source(_ catalog: AppleStremioCatalog) -> AppleSource {
        AppleSource(kind: .stremio, name: "Fixture Add-on",
                    url: URL(string: "https://fixture.example/addon/manifest.json")!,
                    resources: ["catalog"], catalogs: [catalog])
    }

    private func item(_ n: Int) -> AppleCatalogItem {
        AppleCatalogItem(mediaID: "tt\(n)", type: "movie", name: "Film \(n)")
    }

    @Test("Manifest `extra: [{name: skip}]` and `extraSupported: [skip]` both declare paging")
    func decodesSkipExtra() throws {
        let extra = try JSONDecoder().decode(AppleStremioCatalog.self, from: Data(
            #"{"type":"movie","id":"top","extra":[{"name":"genre"},{"name":"skip"}]}"#.utf8))
        let short = try JSONDecoder().decode(AppleStremioCatalog.self, from: Data(
            #"{"type":"movie","id":"top","extraSupported":["search","skip"]}"#.utf8))
        let none = try JSONDecoder().decode(AppleStremioCatalog.self, from: Data(
            #"{"type":"movie","id":"top","extra":[{"name":"genre"}]}"#.utf8))
        #expect(extra.supportsSkip)
        #expect(short.supportsSkip && short.supportsSearch)
        #expect(!none.supportsSkip)
        // Survives the store's own encode/decode round trip.
        let again = try JSONDecoder().decode(AppleStremioCatalog.self, from: JSONEncoder().encode(extra))
        #expect(again.supportsSkip)
    }

    @Test("Page 2 is …/catalog/movie/top/skip=100.json; search plus skip keeps the SDK order")
    func endpoints() throws {
        let catalog = AppleStremioCatalog(type: "movie", id: "top", supportsSearch: true, supportsSkip: true)
        let source = source(catalog)
        #expect(try AppleStremioCatalogClient.endpoint(source: source, catalog: catalog, skip: 100).absoluteString
                == "https://fixture.example/addon/catalog/movie/top/skip=100.json")
        #expect(try AppleStremioCatalogClient.endpoint(source: source, catalog: catalog, skip: 0)
                == AppleStremioCatalogClient.endpoint(source: source, catalog: catalog))
        #expect(try AppleStremioCatalogClient.searchEndpoint(source: source, catalog: catalog, query: "x", skip: 100)
            .absoluteString == "https://fixture.example/addon/catalog/movie/top/search=x&skip=100.json")
    }

    @Test("A catalog without skip in its extras never gets skip")
    func noSkipWithoutDeclaration() {
        let catalog = AppleStremioCatalog(type: "movie", id: "top")
        #expect(throws: AppleStremioCatalogError.invalidSource) {
            try AppleStremioCatalogClient.endpoint(source: source(catalog), catalog: catalog, skip: 100)
        }
        #expect(AppleCatalogPaging.nextSkip(catalog: catalog, loadedCount: 100, state: nil) == nil)
    }

    @Test("skip is the number of items held; stops on an empty, short or repeated page and dedupes")
    func mergeRules() {
        let catalog = AppleStremioCatalog(type: "movie", id: "top", supportsSkip: true)
        let first = (0..<100).map(item)
        #expect(AppleCatalogPaging.nextSkip(catalog: catalog, loadedCount: first.count, state: nil) == 100)

        let second = AppleCatalogPaging.merge(first, page: .init(items: (95..<200).map(item), receivedCount: 105),
                                              pageSize: 100)
        #expect(second.items.count == 200)
        #expect(Set(second.items.map(\.id)).count == 200)
        #expect(!second.isExhausted)

        #expect(AppleCatalogPaging.merge(first, page: .init(items: [], receivedCount: 0), pageSize: 100).isExhausted)
        let short = AppleCatalogPaging.merge(first, page: .init(items: (100..<140).map(item), receivedCount: 40),
                                             pageSize: 100)
        #expect(short.items.count == 140 && short.isExhausted)
        let repeated = AppleCatalogPaging.merge(first, page: .init(items: first, receivedCount: 100), pageSize: 100)
        #expect(repeated.items.count == 100 && repeated.isExhausted)
        #expect(AppleCatalogPaging.nextSkip(catalog: catalog, loadedCount: 140,
                                            state: .init(pageSize: 100, isExhausted: true)) == nil)
    }

    @Test("The next page is asked for near the end of the row only")
    func nearEnd() {
        let items = (0..<20).map(item)
        #expect(!AppleCatalogPaging.isNearEnd(itemID: items[10].id, in: items))
        #expect(AppleCatalogPaging.isNearEnd(itemID: items[15].id, in: items))
        #expect(AppleCatalogPaging.isNearEnd(itemID: items[19].id, in: items))
        #expect(!AppleCatalogPaging.isNearEnd(itemID: "movie:nope", in: items))
    }

    @MainActor @Test("The store fetches skip=100 then skip=200 and stops after a short page: 250 items")
    func storePagesToTheEnd() async throws {
        let catalog = AppleStremioCatalog(type: "movie", id: "top", supportsSkip: true)
        let source = source(catalog)
        let requested = RequestLog()
        let client = AppleStremioCatalogClient { request in
            let path = request.url!.path
            await requested.append(path)
            let start = path.contains("skip=200") ? 200 : path.contains("skip=100") ? 100 : 0
            let count = start == 200 ? 50 : 100
            let metas = (start..<(start + count)).map { #"{"id":"tt\#($0)","type":"movie","name":"Film \#($0)"}"# }
            let data = Data(#"{"metas":[\#(metas.joined(separator: ","))]}"#.utf8)
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let cacheURL = FileManager.default.temporaryDirectory
            .appending(path: "openstream-paging-tests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        let store = AppleCatalogStore(client: client, cache: AppleCatalogCache(fileURL: cacheURL))
        await store.refresh(sources: [source])
        let id = try #require(store.sections.first?.id)
        #expect(store.sections[0].items.count == 100)
        await store.loadNextPage(sectionID: id, sources: [source])
        #expect(store.sections[0].items.count == 200)
        await store.loadNextPage(sectionID: id, sources: [source])
        #expect(store.sections[0].items.count == 250)
        await store.loadNextPage(sectionID: id, sources: [source])
        #expect(store.sections[0].items.count == 250)
        let paths = await requested.paths
        #expect(paths.filter { $0.contains("skip=") } == [
            "/addon/catalog/movie/top/skip=100.json", "/addon/catalog/movie/top/skip=200.json",
        ])
    }
}

private actor RequestLog {
    private(set) var paths: [String] = []
    func append(_ path: String) { paths.append(path) }
}
