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

@Test func artworkResolverFillsMissingBackdropWithoutReplacingSourcePoster() async throws {
    let config = try AppleTMDBConfiguration(credential: "fixture")
    let client = AppleTMDBClient { request in
        let json = request.url!.path.contains("/find/")
            ? #"{"movie_results":[{"id":42}],"tv_results":[]}"#
            : #"{"backdrop_path":"/backdrop.jpg","genres":[]}"#
        return (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    let source = URL(string: "https://fixture.example/poster.jpg")!
    let art = await AppleArtworkResolver(tmdbClient: client).resolve(mediaID: "tt1234567:1:2", type: "movie",
        existingPosterURL: source, purpose: .resume, pixelWidth: 700, configuration: config)
    #expect(art?.posterURL == source)
    #expect(art?.backgroundURL == URL(string: "https://image.tmdb.org/t/p/w300/backdrop.jpg"))
}

@Test func artworkResolverCoalescesCanonicalInFlightLookupsAndHonorsMetadataOff() async throws {
    let config = try AppleTMDBConfiguration(credential: "fixture")
    let hits = HitCounter()
    let client = AppleTMDBClient { request in
        await hits.increment()
        await Task.yield()
        let json = request.url!.path.contains("/find/")
            ? #"{"movie_results":[{"id":42}],"tv_results":[]}"#
            : #"{"poster_path":"/poster.jpg","genres":[]}"#
        return (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    let resolver = AppleArtworkResolver(tmdbClient: client)
    await withTaskGroup(of: AppleArtworkResolver.Artwork?.self) { group in
        for index in 0..<12 {
            group.addTask {
                await resolver.resolve(mediaID: index.isMultiple(of: 2) ? "tt1234567" : "tt1234567:1:2",
                    type: "movie", existingPosterURL: nil, purpose: .poster, pixelWidth: 300, configuration: config)
            }
        }
        for await art in group { #expect(art?.posterURL != nil) }
    }
    #expect(await hits.count == 2)
    let off = await resolver.resolve(mediaID: "tt1234567", type: "movie", existingPosterURL: nil,
        purpose: .poster, pixelWidth: 300, configuration: nil)
    #expect(off == nil)
}

@Test func artworkSizesAreScaleAwareAndProviderURLsStayExact() {
    #expect(AppleArtworkResolver.Purpose.poster.size(pixelWidth: 140 * 3) == "w342")
    #expect(AppleArtworkResolver.Purpose.hero.size(pixelWidth: 1920) == "w1280")
    #expect(AppleArtworkResolver.Purpose.logo.size(pixelWidth: 280) == "w185")
    let signed = URL(string: "https://fixture.example/w500/poster.jpg?signature=fixture")!
    #expect(AppleTMDBClient.resizedArtworkURL(signed, size: "w780") == signed)
}

@Test func artworkCacheSeparatesKindPurposeSizeAndConfigurationAndCapsMisses() async throws {
    let hits = HitCounter()
    let client = AppleTMDBClient { request in
        if request.url!.path.contains("/find/") { await hits.increment() }
        let json = request.url!.path.contains("/find/")
            ? #"{"movie_results":[{"id":42}],"tv_results":[{"id":43}]}"#
            : #"{"poster_path":"/poster.jpg","backdrop_path":"/backdrop.jpg","genres":[]}"#
        return (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    let config = try AppleTMDBConfiguration(credential: "fixture")
    let resolver = AppleArtworkResolver(tmdbClient: client, maximumLookups: 5, maximumConcurrentLookups: 1)
    for (kind, purpose, pixels, credential) in [
        ("movie", AppleArtworkResolver.Purpose.poster, 300.0, "fixture"),
        ("series", .poster, 300, "fixture"),
        ("movie", .resume, 300, "fixture"),
        ("movie", .poster, 700, "fixture"),
        ("movie", .poster, 300, "other")
    ] {
        _ = await resolver.resolve(mediaID: "tt1234567", type: kind, existingPosterURL: nil,
            purpose: purpose, pixelWidth: pixels, configuration: try AppleTMDBConfiguration(credential: credential))
    }
    #expect(await hits.count == 5)
    _ = await resolver.resolve(mediaID: "tt7654321", type: "movie", existingPosterURL: nil, configuration: config)
    #expect(await hits.count == 5)
}

@Test func artworkErrorsAreCachedAndBackdropOnlySourceCanResolvePoster() async throws {
    let hits = HitCounter()
    let config = try AppleTMDBConfiguration(credential: "fixture")
    let client = AppleTMDBClient { request in
        await hits.increment()
        throw URLError(.timedOut)
    }
    let resolver = AppleArtworkResolver(tmdbClient: client)
    for _ in 0..<3 {
        let value = await resolver.resolve(mediaID: "tt1234567", type: "movie", existingPosterURL: nil,
            existingBackgroundURL: URL(string: "https://fixture.example/backdrop.jpg"), configuration: config)
        #expect(value == nil)
    }
    #expect(await hits.count == 1)
}

@Test func artworkResolverGetsPosterWithExistingBackdropAndKeepsSourceSpecificResultsOutOfCache() async throws {
    let config = try AppleTMDBConfiguration(credential: "fixture")
    let client = AppleTMDBClient { request in
        let json = request.url!.path.contains("/find/")
            ? #"{"movie_results":[{"id":42}],"tv_results":[]}"#
            : #"{"poster_path":"/poster.jpg","backdrop_path":"/backdrop.jpg","genres":[]}"#
        return (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    let resolver = AppleArtworkResolver(tmdbClient: client)
    let source = URL(string: "https://fixture.example/backdrop.jpg")!
    let first = await resolver.resolve(mediaID: "tt1234567", type: "movie", existingPosterURL: nil,
        existingBackgroundURL: source, configuration: config)
    let second = await resolver.resolve(mediaID: "tt1234567", type: "movie", existingPosterURL: nil, configuration: config)
    #expect(first?.posterURL != nil)
    #expect(first?.backgroundURL == source)
    #expect(second?.backgroundURL != source)
}

@Test func heroAndLogoPurposesResolveEvenWithExistingPoster() async throws {
    let config = try AppleTMDBConfiguration(credential: "fixture")
    let client = AppleTMDBClient { request in
        let json = request.url!.path.contains("/find/")
            ? #"{"movie_results":[{"id":42}],"tv_results":[]}"#
            : #"{"backdrop_path":"/backdrop.jpg","genres":[],"images":{"logos":[{"file_path":"/logo.png","iso_639_1":"en"}]}}"#
        return (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    let resolver = AppleArtworkResolver(tmdbClient: client)
    let source = URL(string: "https://fixture.example/poster.jpg")!
    let hero = await resolver.resolve(mediaID: "tt1234567", type: "movie", existingPosterURL: source,
        purpose: .hero, pixelWidth: 1100, configuration: config)
    let logo = await resolver.resolve(mediaID: "tt1234567", type: "movie", existingPosterURL: source,
        purpose: .logo, pixelWidth: 280, configuration: config)
    #expect(hero?.backgroundURL == URL(string: "https://image.tmdb.org/t/p/w780/backdrop.jpg"))
    #expect(logo?.logoURL == URL(string: "https://image.tmdb.org/t/p/w185/logo.png"))
}

@Test func artworkConcurrencyCapQueuesDistinctLookupsWithoutDroppingCards() async throws {
    let config = try AppleTMDBConfiguration(credential: "fixture")
    let hits = HitCounter()
    let client = AppleTMDBClient { request in
        await hits.start()
        await Task.yield()
        let json = request.url!.path.contains("/find/")
            ? #"{"movie_results":[{"id":42}],"tv_results":[]}"#
            : #"{"poster_path":"/poster.jpg","genres":[]}"#
        await hits.finish()
        return (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    let resolver = AppleArtworkResolver(tmdbClient: client, maximumConcurrentLookups: 1)
    await withTaskGroup(of: AppleArtworkResolver.Artwork?.self) { group in
        for index in 0..<10 {
            group.addTask {
                await resolver.resolve(mediaID: "tt123456\(index)", type: "movie", existingPosterURL: nil, configuration: config)
            }
        }
        for await art in group { #expect(art?.posterURL != nil) }
    }
    #expect(await hits.count == 20)
    #expect(await hits.peak == 1)
}

private actor HitCounter {
    private(set) var count = 0
    private var active = 0
    private(set) var peak = 0
    func increment() { count += 1 }
    func start() { count += 1; active += 1; peak = max(peak, active) }
    func finish() { active -= 1 }
}
