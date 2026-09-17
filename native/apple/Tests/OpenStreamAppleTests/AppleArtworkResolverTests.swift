import Foundation
import Testing
@testable import OpenStreamApple

@Test func artworkResolverReturnsTMDBPosterWhenItemHasNoPoster() async throws {
    let configuration = try AppleTMDBConfiguration(credential: String(repeating: "a", count: 32))
    let hitCount = HitCounter()
    let client = AppleTMDBClient { request in
        await hitCount.increment()
        let body: Data
        if request.url?.path == "/3/find/tt1234567" {
            body = Data(#"{"movie_results":[{"id":42}],"tv_results":[]}"#.utf8)
        } else {
            body = Data(#"{"poster_path":"/poster.jpg","backdrop_path":"/backdrop.jpg","genres":[]}"#.utf8)
        }
        return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    let resolver = AppleArtworkResolver(tmdbClient: client)

    let artwork = await resolver.resolve(
        mediaID: "tt1234567",
        type: "movie",
        existingPosterURL: nil,
        configuration: configuration
    )

    #expect(artwork?.posterURL == URL(string: "https://image.tmdb.org/t/p/w500/poster.jpg"))
    #expect(artwork?.backgroundURL == URL(string: "https://image.tmdb.org/t/p/w1280/backdrop.jpg"))
}

@Test func artworkResolverReturnsNilWhenTMDBIsDisabled() async throws {
    let hitCount = HitCounter()
    let client = AppleTMDBClient { request in
        await hitCount.increment()
        return (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    let resolver = AppleArtworkResolver(tmdbClient: client)

    let artwork = await resolver.resolve(
        mediaID: "tt1234567",
        type: "movie",
        existingPosterURL: nil,
        configuration: nil
    )

    #expect(artwork == nil)
    #expect(await hitCount.count == 0)
}

@Test func artworkResolverCachesResultsPerMediaID() async throws {
    let configuration = try AppleTMDBConfiguration(credential: String(repeating: "a", count: 32))
    let hitCount = HitCounter()
    let client = AppleTMDBClient { request in
        let body: Data
        if request.url?.path == "/3/find/tt1234567" {
            await hitCount.increment() // one increment per client.details() call
            body = Data(#"{"movie_results":[{"id":42}],"tv_results":[]}"#.utf8)
        } else {
            body = Data(#"{"poster_path":"/poster.jpg","genres":[]}"#.utf8)
        }
        return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    let resolver = AppleArtworkResolver(tmdbClient: client)

    _ = await resolver.resolve(mediaID: "tt1234567", type: "movie", existingPosterURL: nil, configuration: configuration)
    _ = await resolver.resolve(mediaID: "tt1234567", type: "movie", existingPosterURL: nil, configuration: configuration)

    #expect(await hitCount.count == 1)
}

@Test func artworkResolverNeverOverridesAnExistingPoster() async throws {
    let configuration = try AppleTMDBConfiguration(credential: String(repeating: "a", count: 32))
    let hitCount = HitCounter()
    let client = AppleTMDBClient { request in
        await hitCount.increment()
        return (Data(#"{"movie_results":[],"tv_results":[]}"#.utf8),
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    let resolver = AppleArtworkResolver(tmdbClient: client)

    let artwork = await resolver.resolve(
        mediaID: "tt1234567",
        type: "movie",
        existingPosterURL: URL(string: "https://images.fixture/poster.jpg"),
        configuration: configuration
    )

    #expect(artwork == nil)
    #expect(await hitCount.count == 0)
}

private actor HitCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}
