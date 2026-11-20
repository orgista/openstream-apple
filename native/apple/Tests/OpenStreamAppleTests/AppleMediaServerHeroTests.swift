import Foundation
import Testing
@testable import OpenStreamApple

@MainActor
struct AppleMediaServerHeroTests {
    private let source: AppleSource

    init() throws {
        source = AppleSource(kind: .mediaServer, name: "Fixture",
            url: try #require(URL(string: "https://fixture.example")))
    }

    private func store(items: [String: String]) async throws -> AppleMediaServerLibraryStore {
        let client = AppleMediaServerClient { request in
            let url = try #require(request.url)
            if url.path.contains("Seasons") || url.path.contains("Episodes") {
                Issue.record("Hero lookup fetched an episode listing")
            }
            let body = items[url.lastPathComponent] ?? #"{"Items":[],"TotalRecordCount":0}"#
            return (Data(body.utf8), try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
        let store = AppleMediaServerLibraryStore(client: client)
        store.automaticallyDeliversRemoteProgress = false
        let session = AppleMediaServerSession(kind: .jellyfin, baseURL: source.url,
            accessToken: "fixture-token", userID: "fixture-user")
        await store.reload(sources: [source]) { _ in session }
        return store
    }

    private func reference(_ id: String) -> AppleMediaServerItemReference {
        .init(sourceID: source.id, itemID: id)
    }

    private func metadataClient() -> AppleTMDBClient {
        AppleTMDBClient { request in
            let url = try #require(request.url)
            let body: String
            switch url.path {
            case "/3/find/tt1234567":
                body = #"{"movie_results":[{"id":42}],"tv_results":[{"id":42}]}"#
            case "/3/movie/42", "/3/tv/42":
                body = #"{"id":42,"title":"Catalog Title","name":"Catalog Title","images":{"logos":[{"file_path":"/wordmark.png","iso_639_1":"en"}]},"videos":{"results":[{"site":"YouTube","key":"catalog1234","type":"Trailer","official":true}]}}"#
            default:
                Issue.record("Unexpected hero metadata request: \(url.path)")
                body = "{}"
            }
            return (Data(body.utf8), try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
    }

    @Test func serverCatalogKeepsItsWordmarkAndIMDbIdentity() throws {
        let session = AppleMediaServerSession(kind: .jellyfin, baseURL: source.url,
            accessToken: "fixture-token", userID: "fixture-user")
        let item = AppleMediaServerItem(id: "movie", name: "Server Title", type: .movie,
            logoImageTag: "logo-tag", providerIDs: ["Imdb": "tt1234567"])
        let catalog = AppleMediaServerLibraryStore().catalogItem(item, source: source, session: session)
        #expect(catalog.mediaID == reference("movie").mediaID)
        #expect(catalog.imdbID == "tt1234567")
        #expect(catalog.logoURL?.path == "/Items/movie/Images/Logo")
    }

    @Test(arguments: [#""Imdb":"tt1234567""#, #""Tmdb":"42""#])
    func missingServerLogoAndTrailerUseProviderIdentity(provider: String) async throws {
        let store = try await store(items: ["movie": """
            {"Id":"movie","Name":"Server Title","Type":"Movie","ProviderIds":{\(provider)},
             "BackdropImageTags":["server-art"]}
            """])
        let metadata = try await store.heroMetadata(for: reference("movie"),
            configuration: AppleTMDBConfiguration(credential: "hero-fixture"), tmdbClient: metadataClient())
        #expect(metadata.title == "Server Title")
        #expect(metadata.mediaID == reference("movie").mediaID)
        #expect(metadata.backdropURL?.path == "/Items/movie/Images/Backdrop")
        #expect(metadata.logoURL?.lastPathComponent == "wordmark.png")
        #expect(metadata.trailerYouTubeKeys == ["catalog1234"])
    }

    @Test func serverAssetsComeFirstAndWorkWithoutCatalogConfiguration() async throws {
        let store = try await store(items: ["movie": #"{"Id":"movie","Name":"Server Title","Type":"Movie","ImageTags":{"Logo":"server-logo"},"RemoteTrailers":[{"Url":"https://www.youtube.com/watch?v=server12345"}]}"#])
        let metadata = try await store.heroMetadata(for: reference("movie"), configuration: nil)
        #expect(metadata.logoURL?.path == "/Items/movie/Images/Logo")
        #expect(metadata.trailerYouTubeKeys == ["server12345"])
        let configured = try await store.heroMetadata(for: reference("movie"),
            configuration: AppleTMDBConfiguration(credential: "hero-fixture"), tmdbClient: metadataClient())
        #expect(configured.logoURL == metadata.logoURL)
        #expect(configured.trailerYouTubeKeys == metadata.trailerYouTubeKeys)
    }

    /// Rill can list a logo or backdrop its image proxy then answers with a
    /// 502 (Doctor X, walk b20r19): the catalog's stay behind the server's.
    @Test func serverArtKeepsTheCatalogsArtBehindIt() async throws {
        let store = try await store(items: ["movie": #"{"Id":"movie","Name":"Server Title","Type":"Movie","ProviderIds":{"Imdb":"tt1234567"},"ImageTags":{"Logo":"server-logo"},"BackdropImageTags":["server-art"]}"#])
        let metadata = try await store.heroMetadata(for: reference("movie"),
            configuration: AppleTMDBConfiguration(credential: "hero-fixture"), tmdbClient: metadataClient())
        #expect(metadata.logoURL?.path == "/Items/movie/Images/Logo")
        #expect(metadata.catalogLogoURL?.lastPathComponent == "wordmark.png")
        #expect(metadata.backdropURL?.path == "/Items/movie/Images/Backdrop")
        let unconfigured = try await store.heroMetadata(for: reference("movie"), configuration: nil)
        #expect(unconfigured.catalogLogoURL == nil)
        #expect(unconfigured.catalogBackdropURL == nil)
    }

    @Test func episodeHeroUsesOnlyItsSeriesMetadataWithoutFetchingSeasons() async throws {
        let store = try await store(items: [
            "episode": #"{"Id":"episode","Name":"Episode 1","Type":"Episode","SeriesId":"series","SeriesName":"Series Title","ProviderIds":{"Imdb":"tt7654321"},"BackdropImageTags":["episode-art"]}"#,
            "series": #"{"Id":"series","Name":"Series Title","Type":"Series","Overview":"Series synopsis","ProviderIds":{"Imdb":"tt1234567"},"ImageTags":{"Logo":"series-logo"},"BackdropImageTags":["series-art"]}"#
        ])
        let metadata = try await store.heroMetadata(for: reference("episode"),
            configuration: AppleTMDBConfiguration(credential: "hero-fixture"), tmdbClient: metadataClient())
        #expect(metadata.mediaID == reference("series").mediaID)
        #expect(metadata.title == "Series Title")
        #expect(metadata.overview == "Series synopsis")
        #expect(metadata.logoURL?.path == "/Items/series/Images/Logo")
        #expect(metadata.backdropURL?.path == "/Items/series/Images/Backdrop")
        let episode = AppleCatalogItem(mediaID: reference("episode").mediaID, type: "series", name: "Episode 1")
        let destination = store.titlePageDestination(for: episode)
        #expect(destination.item.name == "Series Title")
        #expect(destination.item.mediaID == reference("series").mediaID)
        #expect(destination.episodeID == "episode")
    }

    @Test func catalogFailureKeepsServerAssets() async throws {
        let store = try await store(items: ["movie": #"{"Id":"movie","Name":"Server Title","Type":"Movie","ProviderIds":{"Imdb":"tt1234567"},"ImageTags":{"Logo":"server-logo"}}"#])
        let client = AppleTMDBClient { _ in throw AppleTMDBError.titleNotFound }
        let metadata = try await store.heroMetadata(for: reference("movie"),
            configuration: AppleTMDBConfiguration(credential: "hero-failure-fixture"), tmdbClient: client)
        #expect(metadata.title == "Server Title")
        #expect(metadata.logoURL?.path == "/Items/movie/Images/Logo")
    }

    @Test func anEpisodeWithoutAParentNeverUsesItsOwnIMDbIDAsASeries() async throws {
        let store = try await store(items: ["episode": #"{"Id":"episode","Name":"Episode 1","Type":"Episode","ProviderIds":{"Imdb":"tt7654321"}}"#])
        await #expect(throws: AppleMediaServerError.unsupported) {
            try await store.heroMetadata(for: reference("episode"),
                configuration: AppleTMDBConfiguration(credential: "hero-fixture"), tmdbClient: metadataClient())
        }
    }

    @Test func aRetainedStillCanNeverBelongToAnotherTitle() {
        let matrix = AppleHeroStillPage(id: "matrix", url: URL(string: "https://fixture.example/matrix.jpg"))
        let series = AppleHeroStillPage(id: "series", url: URL(string: "https://fixture.example/series.jpg"))
        #expect(AppleHeroStillPage.displayed(current: series, retained: matrix) == series)
        let upgraded = AppleHeroStillPage(id: "series", url: URL(string: "https://fixture.example/series-new.jpg"))
        #expect(AppleHeroStillPage.displayed(current: upgraded, retained: series) == series)
        #expect(AppleHeroStillPage.displayed(current: series, retained: nil) == series)
    }
}
