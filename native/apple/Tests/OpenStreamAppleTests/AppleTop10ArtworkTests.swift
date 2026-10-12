import Foundation
import Testing
@testable import OpenStreamApple

@MainActor @Test func top10FindsMissingArtworkBeyondLoadedShelves() async throws {
    let source = AppleSource(kind: .stremio, name: "Metadata", url: URL(string: "https://metadata.fixture/manifest.json")!,
        resources: ["catalog"], catalogs: [.init(type: "movie", id: "search", requiresInput: true, supportsSearch: true)])
    let client = AppleStremioCatalogClient { request in
        let data = Data(#"{"metas":[{"id":"tt1234567","type":"movie","name":"A Film","poster":"https://images.fixture/poster.jpg"},{"id":"tt7654321","type":"movie","name":"Another Film"}]}"#.utf8)
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    let match = await AppleTop10ArtworkLookup.find(title: "A Film", type: "movie", seasonTitle: nil, sources: [source], client: client)
    #expect(match?.item.mediaID == "tt1234567")
    #expect(match?.item.posterURL != nil)
    let missing = await AppleTop10ArtworkLookup.find(title: "Unknown Film", type: "movie", seasonTitle: nil, sources: [source], client: client)
    #expect(missing == nil)
}

/// The iPhone review sim's only add-on exposes no search catalog, so the
/// lookup asked nobody and every Top 10 tile stayed a grey title box (N11).
@MainActor @Test func top10FallsBackToCinemetaWhenNoAddOnCanSearch() async throws {
    let source = AppleSource(kind: .stremio, name: "Metadata", url: URL(string: "https://fixture.example/manifest.json")!,
        resources: ["catalog", "meta"], catalogs: [.init(type: "movie", id: "tmdb.top")])
    let requested = AppleTop10RequestLog()
    let client = AppleStremioCatalogClient { request in
        await requested.append(request.url?.path ?? "")
        let data = Data(#"{"metas":[{"id":"tt1234567","type":"movie","name":"Why Did I Get Married Again?","poster":"https://fixture.example/poster.jpg"}]}"#.utf8)
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    let match = try #require(await AppleTop10ArtworkLookup.find(title: "Why Did I Get Married Again?", type: "movie",
                                                                seasonTitle: nil, sources: [source], client: client))
    #expect(match.item.mediaID == "tt1234567")
    #expect(match.source.manifestID == AppleStremioMetadataClient.defaultMetadataSource.manifestID)
    let paths = await requested.paths
    #expect(paths.count == 1)
    #expect(paths.first?.contains("/catalog/movie/top/search=") == true)
}

@MainActor @Test func top10SearchesConfiguredCatalogsBeforeCinemeta() {
    let searchable = AppleSource(kind: .stremio, name: "Metadata", url: URL(string: "https://fixture.example/manifest.json")!,
        resources: ["catalog"], catalogs: [.init(type: "series", id: "search", supportsSearch: true)])
    let sources = AppleTop10ArtworkLookup.searchSources([searchable], type: "series")
    #expect(sources.map(\.name) == ["Metadata", "Cinemeta"])
    #expect(sources.last?.catalogs.map(\.type) == ["series"])

    var cinemeta = AppleStremioMetadataClient.defaultMetadataSource
    cinemeta.catalogs = [.init(type: "series", id: "top", supportsSearch: true)]
    #expect(AppleTop10ArtworkLookup.searchSources([cinemeta], type: "series").count == 1)
}

private actor AppleTop10RequestLog {
    private(set) var paths: [String] = []
    func append(_ path: String) { paths.append(path) }
}
