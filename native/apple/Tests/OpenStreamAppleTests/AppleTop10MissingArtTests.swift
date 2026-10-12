import Foundation
import Testing
@testable import OpenStreamApple

/// N32 extra: "Monster: The Lizzie Borden Story" and "Jo Koy: Blue in the
/// Face" stayed grey title tiles in Top 10 Shows. Both searches answered;
/// neither result carried the Netflix name under the Netflix type.
@Suite("Top 10 tiles Netflix names differently")
@MainActor
struct AppleTop10MissingArtTests {
    private func client(series: String, movie: String, log: Top10PathLog? = nil) -> AppleStremioCatalogClient {
        AppleStremioCatalogClient { request in
            let path = request.url?.path ?? ""
            await log?.append(path)
            let body = path.contains("/series/") ? series : movie
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    @Test func anthologySeasonMatchesItsSeries() async throws {
        let client = client(
            series: #"{"metas":[{"id":"tt0000011","type":"series","name":"Monster","poster":"https://fixture.example/m.jpg"},{"id":"tt0000012","type":"series","name":"The Story Monster"}]}"#,
            movie: #"{"metas":[]}"#)
        let match = try #require(await AppleTop10ArtworkLookup.find(
            title: "Monster: The Lizzie Borden Story", type: "series", seasonTitle: nil, sources: [], client: client))
        #expect(match.item.mediaID == "tt0000011")
    }

    @Test func specialListedAsTVFindsTheFilm() async throws {
        let log = Top10PathLog()
        let client = client(
            series: #"{"metas":[{"id":"tt0000021","type":"series","name":"In the Face of Crime"}]}"#,
            movie: #"{"metas":[{"id":"tt0000022","type":"movie","name":"Jo Koy: Blue in the Face","poster":"https://fixture.example/j.jpg"}]}"#,
            log: log)
        let match = try #require(await AppleTop10ArtworkLookup.find(
            title: "Jo Koy: Blue in the Face", type: "series", seasonTitle: nil, sources: [], client: client))
        #expect(match.item.mediaID == "tt0000022")
        #expect(match.item.type == "movie")
        let paths = await log.paths
        #expect(paths.contains { $0.contains("/catalog/series/") } && paths.contains { $0.contains("/catalog/movie/") })
    }

    @Test func aMovieNeverFallsBackToASeries() async {
        let log = Top10PathLog()
        let client = client(series: #"{"metas":[{"id":"tt0000031","type":"series","name":"Example"}]}"#,
                            movie: #"{"metas":[]}"#, log: log)
        #expect(await AppleTop10ArtworkLookup.find(title: "Example: Part Two", type: "movie", seasonTitle: nil,
                                                   sources: [], client: client) == nil)
        #expect(await log.paths.allSatisfy { !$0.contains("/catalog/series/") })
    }

    @Test("Only a series title with a subtitle has an anthology name", arguments: [
        ("Monster: The Lizzie Borden Story", "series", "Monster"),
        ("Love Is Blind: Ohio", "series", "Love Is Blind"),
        ("Monster", "series", nil),
        (": Untitled", "series", nil),
        ("Mission: Impossible", "movie", nil),
    ] as [(String, String, String?)])
    func anthologyName(title: String, type: String, expected: String?) {
        #expect(AppleTop10ArtworkLookup.anthologySeries(of: title, type: type) == expected)
    }
}

private actor Top10PathLog {
    private(set) var paths: [String] = []
    func append(_ path: String) { paths.append(path) }
}
