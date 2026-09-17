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
