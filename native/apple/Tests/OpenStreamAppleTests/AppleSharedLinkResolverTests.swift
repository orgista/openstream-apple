import Foundation
import Testing
@testable import OpenStreamApple

struct AppleSharedLinkResolverTests {
    @Test(arguments: ["the dark knight", "Dune", "Mr. Smith", "Star Trek: Voyager", "M*A*S*H"])
    func ordinarySearchTitlesAreNotLinks(_ title: String) {
        #expect(AppleSharedLinkResolver.link(in: title) == nil)
    }

    @Test(arguments: [
        "tt1234567", "imdb:tt1234567", "imdb:title:tt1234567", "imdb://title/tt1234567",
        "tmdb:123", "tmdb:movie:123", "tmdb://movie/123", "tmdb://tv/123",
        "imdb.com", "www.imdb.com", "themoviedb.org", "www.themoviedb.org",
        "imdb.com?title=tt1234567", "themoviedb.org?movie=123",
    ])
    func bareIDsAndCustomSchemesRemainUnsupported(_ value: String) throws {
        #expect(AppleSharedLinkResolver.parse(try #require(URL(string: value))) == nil)
        #expect(AppleSharedLinkResolver.link(in: value) == nil)
    }

    @Test(arguments: [
        ("imdb.com/title/tt1234567", SharedLink.imdb("tt1234567")),
        ("www.imdb.com/title/tt1234567", .imdb("tt1234567")),
        ("m.imdb.com/title/tt1234567", .imdb("tt1234567")),
        ("themoviedb.org/movie/123-title", .tmdb(.movie, 123)),
        ("www.themoviedb.org/tv/123", .tmdb(.show, 123)),
    ])
    func titleURLsWithoutASchemeStillResolve(value: (String, SharedLink)) {
        #expect(AppleSharedLinkResolver.link(in: value.0) == value.1)
        #expect(AppleSharedLinkResolver.link(in: "Watch this " + value.0) == value.1)
    }

    @Test(arguments: [
        ("https://www.imdb.com/title/tt1234567/", SharedLink.imdb("tt1234567")),
        ("https://m.imdb.com/title/tt1234567", .imdb("tt1234567")),
        ("https://www.themoviedb.org/movie/123-title", .tmdb(.movie, 123)),
        ("https://themoviedb.org/tv/123", .tmdb(.show, 123)),
        ("http://imdb.com/title/tt1234567", .imdb("tt1234567")),
        ("HTTPS://WWW.IMDB.COM/title/tt1234567?ref_=share#details", .imdb("tt1234567")),
        ("http://themoviedb.org/movie/123", .tmdb(.movie, 123)),
        ("https://www.themoviedb.org/tv/123-title?language=en-US#episodes", .tmdb(.show, 123)),
    ])
    func supported(value: (String, SharedLink)) throws {
        #expect(AppleSharedLinkResolver.parse(try #require(URL(string: value.0))) == value.1)
        #expect(AppleSharedLinkResolver.link(in: value.0) == value.1)
        #expect(AppleSharedLinkResolver.link(in: " \n" + value.0 + " \t") == value.1)
        #expect(AppleSharedLinkResolver.link(in: "Watch this " + value.0) == value.1)
    }

    @Test(arguments: ["https://imdb.com.evil.test/title/tt123", "file:///title/tt123", "https://user:password@imdb.com/title/tt123",
                      "https://imdb.com/title/ttbad", "https://themoviedb.org/movie/0", "https://imdb.com:8443/title/tt123",
                      "https://www.netflix.com/title/973331", "https://tv.apple.com/us/movie/mayday/umc.cmc.abc",
                      "https://youtu.be/3iRUwVzRDZQ", "https://trakt.tv/movies/mayday-2021", "https://letterboxd.com/film/mayday/"])
    func rejectsEverythingElse(value: String) throws {
        #expect(AppleSharedLinkResolver.parse(try #require(URL(string: value))) == nil)
    }

    @Test func deepLink() throws {
        var components = try #require(URLComponents(string: "openstream://open"))
        components.queryItems = [.init(name: "url", value: "https://www.imdb.com/title/tt1234567/?ref_=share")]
        #expect(AppleAppRoute(url: try #require(components.url)) == .sharedLink(.imdb("tt1234567")))
        #expect(AppleAppRoute(url: try #require(URL(string: "openstream://open?url=https%3A%2F%2Fevil.test"))) == nil)
    }

    @Test func extractsOneLinkFromSharedText() throws {
        #expect(AppleSharedLinkResolver.link(in: "Watch this https://www.imdb.com/title/tt1234567/") == .imdb("tt1234567"))
        #expect(AppleSharedLinkResolver.link(in: "https://imdb.com/title/tt1 https://themoviedb.org/tv/2") == nil)
    }

    @Test func handoffAcceptsOnlyTitleSites() throws {
        #expect(AppleSharedLinkHandoff.deepLink(for: try #require(URL(string: "https://www.imdb.com/title/tt1234567/"))) != nil)
        #expect(AppleSharedLinkHandoff.deepLink(for: try #require(URL(string: "https://www.netflix.com/title/973331"))) == nil)
        #expect(AppleSharedLinkHandoff.deepLink(for: try #require(URL(string: "file:///tmp/movie"))) == nil)
    }

    /// The Share extension saves a link only for one IMDb or TMDB title;
    /// anything else leaves it showing its one-line "IMDb and TMDB" answer.
    @Test func theShareSheetTakesOneTitleLinkFromURLOrText() {
        #expect(AppleSharedLinkHandoff.deepLink(inShared: " https://www.themoviedb.org/movie/603 ") != nil)
        #expect(AppleSharedLinkHandoff.deepLink(inShared: "Watch this https://m.imdb.com/title/tt1234567/") != nil)
        #expect(AppleSharedLinkHandoff.deepLink(inShared: "https://imdb.com/title/tt1 and https://themoviedb.org/tv/2") == nil)
        #expect(AppleSharedLinkHandoff.deepLink(inShared: "https://fixture.example/title/1") == nil)
        #expect(AppleSharedLinkHandoff.deepLink(inShared: "no link here") == nil)
    }

    @Test @MainActor func imdbIdentifierOpensTheViewersOwnTitle() async throws {
        let record = AppleMediaRecord(canonicalID: "tt1234567", kind: .series, title: "A Show", availability: [])
        let result = try await AppleSharedLinkResolution.resolve(.imdb("tt1234567"), records: [record], configuration: nil)
        #expect(result.record?.id == record.id)
        #expect(result.item?.type == "series")
    }

    /// With no TMDB key a link to a title the viewer does not have says what
    /// is missing instead of "Couldn't read that link".
    @Test @MainActor func aLinkThatNeedsTMDBWithoutAKeySaysSo() async {
        await #expect(throws: AppleSharedLinkError.metadataUnavailable) {
            try await AppleSharedLinkResolution.resolve(.tmdb(.movie, 123), records: [], configuration: nil)
        }
        await #expect(throws: AppleSharedLinkError.metadataUnavailable) {
            try await AppleSharedLinkResolution.resolve(.imdb("tt7654321"), records: [], configuration: nil)
        }
        #expect(AppleSharedLinkError.metadataUnavailable.errorDescription != AppleSharedLinkError.unreadable.errorDescription)
    }

    @Test @MainActor func sharedRouteClearsPreviousSearchPrefill() {
        let router = AppleAppRouter()
        router.showSearch("Dune")
        router.open(.sharedLink(.imdb("tt1234567")))
        #expect(router.searchQuery.isEmpty)
        #expect(AppleSearchRoutePolicy.discoverShowsSearch(for: .sharedLink(.imdb("tt1234567")), hasDedicatedSearchTab: false))
    }
}
