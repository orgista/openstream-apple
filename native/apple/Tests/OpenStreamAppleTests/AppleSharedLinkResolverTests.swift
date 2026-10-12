import Foundation
import Synchronization
import Testing
@testable import OpenStreamApple

struct AppleSharedLinkResolverTests {
    @Test(arguments: [
        ("https://tv.apple.com/us/movie/mayday/umc.cmc.shin43vzfoz3h4ggx41z8rf", SharedLink.appleTV(.movie, "mayday", "umc.cmc.shin43vzfoz3h4ggx41z8rf")),
        ("https://tv.apple.com/fr/show/the-show/umc.cmc.abc", .appleTV(.show, "the-show", "umc.cmc.abc")),
        ("https://tv.apple.com/de/episode/the-episode/umc.cmc.abc", .appleTV(.episode, "the-episode", "umc.cmc.abc")),
        ("https://www.netflix.com/us/title/973331?s=i&trkid=123", .netflix("973331")),
        ("https://netflix.com/fr-fr/title/973331", .netflix("973331")),
        ("https://netflix.com/title/973331", .netflix("973331")),
        ("https://youtu.be/3iRUwVzRDZQ?is=abc", .youtube("3iRUwVzRDZQ")),
        ("https://youtube.com/watch?v=3iRUwVzRDZQ", .youtube("3iRUwVzRDZQ")),
        ("https://m.youtube.com/shorts/3iRUwVzRDZQ", .youtube("3iRUwVzRDZQ")),
        ("https://www.imdb.com/title/tt1234567/", .imdb("tt1234567")),
        ("https://www.themoviedb.org/movie/123-title", .tmdb(.movie, 123)),
        ("https://themoviedb.org/tv/123", .tmdb(.show, 123)),
        ("https://trakt.tv/movies/mayday-2021", .trakt(.movie, "mayday-2021")),
        ("https://trakt.tv/shows/the-show", .trakt(.show, "the-show")),
        ("https://letterboxd.com/film/mayday/", .letterboxd("mayday"))
    ])
    func supported(value: (String, SharedLink)) throws {
        #expect(AppleSharedLinkResolver.parse(try #require(URL(string: value.0))) == value.1)
    }

    @Test(arguments: ["https://netflix.com.evil.test/title/123", "file:///title/123", "https://user:password@netflix.com/title/123", "https://netflix.com/title/nope", "https://youtube.com/watch?v=short", "https://tv.apple.com/us/movie/mayday/nope", "https://imdb.com/title/ttbad", "https://themoviedb.org/movie/0", "https://trakt.tv/users/me", "https://letterboxd.com/film/", "https://fixture.example/movie/test", "https://netflix.com:8443/title/123", "https://youtu.be/3iRUwVzRDZQ/extra"])
    func rejectsJunk(value: String) throws {
        #expect(AppleSharedLinkResolver.parse(try #require(URL(string: value))) == nil)
    }

    @Test func pageMetadata() throws {
        let html = """
        <meta content='Watch Mayday | Netflix Official Site' property='og:title'>
        <script type="application/ld+json">{"@graph":[{"@type":"Movie","name":"Mayday","datePublished":"2021-10-01"}]}</script>
        """
        let title = try #require(AppleSharedLinkResolver.pageTitle(html))
        #expect(title.name == "Mayday")
        #expect(title.year == 2021)
        #expect(title.kind == .movie)
        #expect(AppleSharedLinkResolver.pageTitle("<meta property=\"og:title\" content=\"Mayday &amp; Me | Apple TV\">")?.name == "Mayday & Me")
        #expect(AppleSharedLinkResolver.pageTitle("<html>no metadata</html>") == nil)
    }

    @Test func failedFetchFallbacks() async throws {
        let resolver = AppleSharedLinkResolver(loader: { _ in throw URLError(.notConnectedToInternet) })
        let apple = try await resolver.title(for: .appleTV(.movie, "the-last-movie", "umc.cmc.abc"))
        #expect(apple.name == "The Last Movie")
        await #expect(throws: AppleSharedLinkError.netflixUnreadable) {
            try await resolver.title(for: .netflix("123"))
        }
    }

    @Test func fetchUsesCanonicalURL() async throws {
        let resolver = AppleSharedLinkResolver(loader: { request in
            #expect(request.url?.absoluteString == "https://www.netflix.com/title/973331")
            #expect(request.timeoutInterval == 8)
            #expect(request.value(forHTTPHeaderField: "User-Agent")?.contains("Safari") == true)
            return (Data("<meta property='og:title' content='Watch Mayday | Netflix Official Site'>".utf8), HTTPURLResponse(url: try #require(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        #expect(try await resolver.title(for: .netflix("973331")).name == "Mayday")
    }

    @Test func ambiguousMatching() {
        let first = AppleMediaRecord(canonicalID: "tt1234567", kind: .movie, title: "Mayday", year: 2021, availability: [])
        let second = AppleMediaRecord(canonicalID: "tt7654321", kind: .movie, title: "Mayday", year: 2025, availability: [])
        #expect(AppleSharedLinkResolver.bestMatch(.init(name: "Mayday", year: 2021, kind: .movie), records: [first, second])?.id == first.id)
        #expect(AppleSharedLinkResolver.bestMatch(.init(name: "Mayday"), records: [first, second]) == nil)
        #expect(AppleSharedLinkResolver.bestMatch(.init(name: "Different"), records: [first]) == nil)
    }

    @Test func deepLink() throws {
        var components = URLComponents(string: "openstream://open")!
        components.queryItems = [.init(name: "url", value: "https://www.netflix.com/us/title/973331?s=i&trkid=123")]
        #expect(AppleAppRoute(url: try #require(components.url)) == .sharedLink(.netflix("973331")))
        #expect(AppleAppRoute(url: URL(string: "openstream://open?url=https%3A%2F%2Fevil.test")!) == nil)
    }
    @Test func ignoresTrackingAndExtractsSharedText() {
        #expect(AppleSharedLinkResolver.link(in: "Watch this https://youtu.be/3iRUwVzRDZQ?is=123") == .youtube("3iRUwVzRDZQ"))
        #expect(AppleSharedLinkResolver.link(in: "https://youtu.be/3iRUwVzRDZQ https://netflix.com/title/123") == nil)
        #expect(AppleSharedLinkResolver.pageTitle("<meta property='og:title' content='Watch Mayday - Apple\u{00a0}TV'>")?.name == "Mayday")
        #expect(AppleSharedLinkHandoff.deepLink(for: URL(string: "file:///tmp/movie")!) == nil)
    }

    @Test func rejectsBadResponsesAndPreservesCancellation() async {
        let badResponse = AppleSharedLinkResolver(loader: { request in
            (Data("<meta property='og:title' content='Wrong Movie'>".utf8), HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!)
        })
        await #expect(throws: AppleSharedLinkError.netflixUnreadable) { try await badResponse.title(for: .netflix("123")) }
        let cancelled = AppleSharedLinkResolver(loader: { _ in throw CancellationError() })
        await #expect(throws: CancellationError.self) { try await cancelled.title(for: .appleTV(.movie, "mayday", "umc.cmc.abc")) }
    }

    @Test @MainActor func pipelineUsesTitleYearAndKind() async throws {
        let first = AppleMediaRecord(canonicalID: "tt1234567", kind: .movie, title: "Mayday", year: 2021, availability: [])
        let page = AppleSharedLinkResolver(loader: { request in
            let html = "<script type='application/ld+json'>{\"@type\":\"Movie\",\"name\":\"Mayday\",\"releaseYear\":2021}</script>"
            return (Data(html.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let result = try await AppleSharedLinkResolution.resolve(.netflix("123"), records: [], sources: [], configuration: nil, pageResolver: page) { name in
            #expect(name == "Mayday")
            return [first]
        }
        #expect(result.record?.id == first.id)
        #expect(result.item?.mediaID == "tt1234567")
    }

    @Test @MainActor func identifierBypassesTextSearch() async throws {
        let record = AppleMediaRecord(canonicalID: "tt1234567", kind: .series, title: "A Show", availability: [])
        let result = try await AppleSharedLinkResolution.resolve(.imdb("tt1234567"), records: [record], sources: [], configuration: nil) { _ in
            Issue.record("Identifier route must not search text")
            return []
        }
        #expect(result.record?.id == record.id)
        #expect(result.item?.type == "series")
    }

    @Test func youtubeMessageMatchesBuildBoundary() {
        #if OPENSTREAM_ADDONS
        #expect(AppleSharedLinkError.unsupportedYouTube.errorDescription == "YouTube links need the YouTube add-on")
        #else
        #expect(AppleSharedLinkError.unsupportedYouTube.errorDescription == "YouTube links aren't supported.")
        #endif
    }

    #if OPENSTREAM_ADDONS
    @Test func youtubeOnlyUsesInstalledEligibleSources() {
        let source = AppleSource(kind: .stremio, name: "YouTubio", url: URL(string: "https://fixture.example/manifest.json")!, manifestID: "youtubio.elfhosted.com", resources: ["stream"], catalogs: [.init(type: "youtube", id: "yt_id:discover")])
        var disabled = source
        disabled.isEnabled = false
        let unrelated = AppleSource(kind: .stremio, name: "Movies", url: URL(string: "https://fixture.example/manifest.json")!, resources: ["stream"])
        #expect(AppleSharedLinkYouTubePolicy.sources(in: [source, disabled, unrelated]) == [source])
        #expect(AppleSharedLinkYouTubePolicy.item(videoID: "3iRUwVzRDZQ", source: source).mediaID == "yt_id:3iRUwVzRDZQ")
    }
    #endif

    #if OPENSTREAM_ADDONS
    @Test @MainActor func withoutTMDBKeyTheMetadataCatalogMatchesTitleYearAndKind() async throws {
        let page = AppleSharedLinkResolver(loader: { request in
            let html = "<script type='application/ld+json'>{\"@type\":\"Movie\",\"name\":\"Mayday\",\"releaseYear\":2026}</script>"
            return (Data(html.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let asked = Mutex<[String]>([])
        let result = try await AppleSharedLinkResolution.resolve(.appleTV(.movie, "mayday", "umc.cmc.abc"), records: [], sources: [],
            configuration: nil, pageResolver: page, catalogSearch: { type, query in
                asked.withLock { $0.append("\(type) \(query)") }
                return [AppleCatalogItem(mediaID: "tt0000002", type: "movie", name: "Mayday", releaseInfo: "2021"),
                        AppleCatalogItem(mediaID: "tt0000001", type: "movie", name: "Mayday", releaseInfo: "2026"),
                        AppleCatalogItem(mediaID: "tt0000003", type: "series", name: "Mayday", releaseInfo: "2026")]
            }) { _ in [] }
        #expect(asked.withLock { $0 } == ["movie Mayday"])
        #expect(result.record == nil)
        #expect(result.item?.mediaID == "tt0000001")
        #expect(result.item?.type == "movie")
        #expect(result.item?.year == 2026)
    }

    @Test func catalogMatchStaysOutWhenAmbiguousOrMissing() async {
        let twins: AppleSharedLinkResolution.CatalogSearch = { type, _ in
            [AppleCatalogItem(mediaID: "tt1", type: type, name: "Mayday", releaseInfo: "2026"),
             AppleCatalogItem(mediaID: "tt2", type: type, name: "Mayday", releaseInfo: "2026")]
        }
        #expect(await AppleSharedLinkResolution.catalogMatch(.init(name: "Mayday", year: 2026, kind: .movie), search: twins) == nil)
        let wrongYear: AppleSharedLinkResolution.CatalogSearch = { type, _ in
            [AppleCatalogItem(mediaID: "tt1", type: type, name: "Mayday", releaseInfo: "2019")]
        }
        #expect(await AppleSharedLinkResolution.catalogMatch(.init(name: "Mayday", year: 2026, kind: .movie), search: wrongYear) == nil)
        let failing: AppleSharedLinkResolution.CatalogSearch = { _, _ in throw URLError(.notConnectedToInternet) }
        #expect(await AppleSharedLinkResolution.catalogMatch(.init(name: "Mayday", year: 2026), search: failing) == nil)
        let show: AppleSharedLinkResolution.CatalogSearch = { type, _ in
            type == "series" ? [AppleCatalogItem(mediaID: "tt9", type: "series", name: "The Show", year: 2020)] : []
        }
        #expect(await AppleSharedLinkResolution.catalogMatch(.init(name: "The Show", year: 2020, kind: .episode), search: show)?.mediaID == "tt9")
    }
    #else
    @Test @MainActor func withoutTMDBKeyAppStoreBuildFallsBackToSearch() async throws {
        let page = AppleSharedLinkResolver(loader: { request in
            let html = "<script type='application/ld+json'>{\"@type\":\"Movie\",\"name\":\"Mayday\",\"releaseYear\":2026}</script>"
            return (Data(html.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let result = try await AppleSharedLinkResolution.resolve(.appleTV(.movie, "mayday", "umc.cmc.abc"), records: [], sources: [],
            configuration: nil, pageResolver: page) { _ in [] }
        #expect(result.item == nil)
        #expect(result.title?.name == "Mayday")
    }
    #endif

    @Test func episodeOpensItsSeriesAndFilmPagesSeparateYear() throws {
        let html = "<script type='application/ld+json'>{\"@type\":\"TVEpisode\",\"name\":\"Pilot\",\"datePublished\":\"2024-10-01\",\"partOfSeries\":{\"name\":\"The Show\",\"datePublished\":\"2020-01-01\"}}</script>"
        let title = try #require(AppleSharedLinkResolver.pageTitle(html))
        #expect(title == .init(name: "The Show", year: 2020, kind: .show))
        #expect(AppleSharedLinkResolver.pageTitle("<meta property='og:title' content='Mayday (2021) • Letterboxd'>") == .init(name: "Mayday", year: 2021))
    }

    @Test @MainActor func sharedRouteClearsPreviousSearchPrefill() {
        let router = AppleAppRouter()
        router.showSearch("Dune")
        router.open(.sharedLink(.netflix("973331")))
        #expect(router.searchQuery.isEmpty)
        #expect(AppleSearchRoutePolicy.discoverShowsSearch(for: .sharedLink(.netflix("973331")), hasDedicatedSearchTab: false))
    }

    @Test func numericFilmSlugIsNotAnEmptyTitle() async throws {
        let resolver = AppleSharedLinkResolver(loader: { _ in throw URLError(.notConnectedToInternet) })
        #expect(try await resolver.title(for: .letterboxd("1917")) == .init(name: "1917", kind: .movie))
    }

}
