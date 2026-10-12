import Foundation
import Testing
@testable import OpenStreamApple

/// Fixes from the 2026-09-30 Stremio add-on compatibility sweep. Every URL is
/// a fixture.example address; no add-on is contacted.
private enum SweepFixture {
    static func response(_ request: URLRequest, status: Int = 200, url: URL? = nil) -> HTTPURLResponse {
        HTTPURLResponse(url: url ?? request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    static func source(
        resources: [String] = ["catalog"],
        catalogs: [AppleStremioCatalog]
    ) -> AppleSource {
        AppleSource(
            kind: .stremio,
            name: "Fixture",
            url: URL(string: "https://addon.fixture.example/manifest.json")!,
            resources: resources,
            catalogs: catalogs
        )
    }

    static func catalogClient(_ body: String) -> AppleStremioCatalogClient {
        AppleStremioCatalogClient { request in (Data(body.utf8), response(request)) }
    }
}

@Suite("Sweep: catalog types beyond movie and series")
struct AppleCatalogTypeBeyondTitlesTests {
    @Test func aManifestKeepsTvAnimeChannelAndCustomCatalogs() throws {
        let data = Data(#"""
        {"id":"fixture.types","name":"Types","resources":["catalog"],
         "catalogs":[{"type":"tv","id":"live"},{"type":"anime","id":"season"},
                     {"type":"channel","id":"chan"},{"type":"Arabcity-Alooytv","id":"x"},
                     {"type":"movie","id":"top"}]}
        """#.utf8)
        let manifest = try JSONDecoder().decode(AppleStremioManifest.self, from: data)
        #expect(manifest.catalogs.map(\.type) == ["tv", "anime", "channel", "arabcity-alooytv", "movie"])
    }

    @Test func pastTheCapMovieAndSeriesCatalogsKeepTheirPlaces() throws {
        let cap = AppleStremioManifest.maximumCatalogs
        let others = (0 ..< cap).map { ["type": "tv", "id": "tv\($0)"] }
        let titles = (0 ..< 3).map { ["type": "movie", "id": "movie\($0)"] }
        let data = try JSONSerialization.data(withJSONObject: [
            "id": "fixture.cap", "name": "Cap", "resources": ["catalog"], "catalogs": others + titles,
        ])
        let manifest = try JSONDecoder().decode(AppleStremioManifest.self, from: data)
        #expect(manifest.catalogs.count == cap)
        #expect(manifest.catalogs.filter { $0.type == "movie" }.count == 3)
    }

    @Test func discoveryListsTitleCatalogsFirstThenOtherTypes() {
        let source = SweepFixture.source(catalogs: [
            .init(type: "tv", id: "live"),
            .init(type: "series", id: "shows"),
            .init(type: "anime", id: "season", requiresInput: true),
            .init(type: "movie", id: "films"),
        ])
        let ids = AppleCatalogDiscoveryPolicy.catalogs(for: source).map(\.id)
        #expect(ids == ["shows", "films", "live"])
    }

    @Test func aTvCatalogDecodesItsItemsAndAMovieCatalogStillDropsThem() async throws {
        let body = #"{"metas":[{"id":"ch:1","type":"tv","name":"News 24","poster":"https://img.fixture.example/1.png"},{"id":"ch:2","name":"Sport"}]}"#
        let tv = AppleStremioCatalog(type: "tv", id: "live")
        let movie = AppleStremioCatalog(type: "movie", id: "films")
        let source = SweepFixture.source(catalogs: [tv, movie])
        let client = SweepFixture.catalogClient(body)

        let live = try await client.load(source: source, catalog: tv)
        #expect(live.map(\.type) == ["tv", "tv"])
        #expect(live.map(\.name) == ["News 24", "Sport"])
        #expect(live.first?.posterURL?.host == "img.fixture.example")

        let films = try await client.load(source: source, catalog: movie)
        #expect(films.map(\.mediaID) == ["ch:2"])
    }

    @Test func aLiveItemFromAnAddOnWithoutMetaOpensStraightToPlayback() {
        let channel = AppleCatalogItem(mediaID: "ch:1", type: "channel", name: "News")
        let tv = AppleCatalogItem(mediaID: "ch:2", type: "tv", name: "Sport")
        let anime = AppleCatalogItem(mediaID: "kitsu:1", type: "anime", name: "Show")
        let movie = AppleCatalogItem(mediaID: "tt0000001", type: "movie", name: "Film")
        let streamOnly = SweepFixture.source(resources: ["catalog", "stream"], catalogs: [])
        let withMeta = SweepFixture.source(resources: ["catalog", "meta", "stream"], catalogs: [])

        #expect(AppleCatalogDiscoveryPolicy.opensStraightToPlayback(item: channel, source: streamOnly))
        #expect(AppleCatalogDiscoveryPolicy.opensStraightToPlayback(item: tv, source: streamOnly))
        #expect(!AppleCatalogDiscoveryPolicy.opensStraightToPlayback(item: tv, source: withMeta))
        #expect(!AppleCatalogDiscoveryPolicy.opensStraightToPlayback(item: anime, source: streamOnly))
        #expect(!AppleCatalogDiscoveryPolicy.opensStraightToPlayback(item: movie, source: streamOnly))
    }

    @Test func unnamedLiveCatalogsGetAPlainHeading() {
        #expect(AppleCatalogShelfPolicy.title(for: .init(type: "tv", id: "x")) == "TV")
        #expect(AppleCatalogShelfPolicy.title(for: .init(type: "channel", id: "x")) == "Channels")
        #expect(AppleCatalogShelfPolicy.title(for: .init(type: "anime", id: "x")) == "Anime")
        #expect(AppleCatalogShelfPolicy.title(for: .init(type: "movie", id: "x")) == "Movies")
    }

    @Test func anAnimeTitlePageReadsTheAddOnsOwnMeta() async throws {
        let source = SweepFixture.source(resources: ["catalog", "meta"], catalogs: [])
        let client = AppleStremioMetadataClient(loader: { request in
            #expect(request.url?.path == "/meta/anime/kitsu%3A1.json" || request.url?.path == "/meta/anime/kitsu:1.json")
            let body = #"{"meta":{"id":"kitsu:1","type":"anime","name":"Fixture Anime","description":"Plot"}}"#
            return (Data(body.utf8), SweepFixture.response(request))
        })
        let details = try await client.details(source: source, type: "anime", mediaID: "kitsu:1")
        #expect(details.title == "Fixture Anime")
        #expect(details.overview == "Plot")
    }
}

@Suite("Sweep: large catalogs decode entry by entry")
struct AppleLargeCatalogTests {
    /// One entry with a full episode list inlined, like TMDB's "tmdb.top".
    private static func heavyEntry(_ index: Int) -> String {
        let videos = (1 ... 300).map { #"{"id":"tmdb:\#(index):1:\#($0)","title":"Episode \#($0) [x] {y}","overview":"\#(String(repeating: "word ", count: 20))"}"# }
        return #"{"id":"tmdb:\#(index)","type":"series","name":"Show \#(index)","videos":[\#(videos.joined(separator: ","))]}"#
    }

    @Test func aTwelveMegabyteStyleShelfDecodesAndCapsItsItems() async throws {
        let body = #"{"cacheMaxAge":3600,"metas":["# + (0 ..< 130).map(Self.heavyEntry).joined(separator: ",") + "]}"
        #expect(body.utf8.count > 2_000_000)
        #expect(body.utf8.count < AppleStremioCatalogClient.maximumResponseBytes)
        let catalog = AppleStremioCatalog(type: "series", id: "tmdb.top")
        let source = SweepFixture.source(catalogs: [catalog])

        let items = try await SweepFixture.catalogClient(body).load(source: source, catalog: catalog)
        #expect(items.count == AppleCatalogDiscoveryPolicy.maximumItemsPerCatalog)
        #expect(items.first?.name == "Show 0")
        #expect(items.last?.mediaID == "tmdb:99")
    }

    @Test func aResponseOverTheCapIsRefused() async throws {
        let catalog = AppleStremioCatalog(type: "movie", id: "huge")
        let source = SweepFixture.source(catalogs: [catalog])
        let size = AppleStremioCatalogClient.maximumResponseBytes + 1
        let client = AppleStremioCatalogClient { request in
            (Data(count: size), SweepFixture.response(request))
        }
        await #expect(throws: AppleStremioCatalogError.responseTooLarge) {
            try await client.load(source: source, catalog: catalog)
        }
    }

    @Test func theScannerFindsTheArrayPastOtherKeysAndTrickyStrings() throws {
        let json = #" {"a":{"metas":[9]},"b":"x\"]}","metas":[ {"id":"1","n":"[{"} , [1,2], "s", 4 ,null ]}"#
        let data = Data(json.utf8)
        let ranges = try #require(AppleJSONArrayElementScanner.elements(ofTopLevelKey: "metas", in: data, limit: 10))
        let values = ranges.map { String(decoding: data[$0], as: UTF8.self) }
        #expect(values == [#"{"id":"1","n":"[{"}"#, "[1,2]", #""s""#, "4", "null"])
        #expect(AppleJSONArrayElementScanner.elements(ofTopLevelKey: "metas", in: data, limit: 2)?.count == 2)
    }

    @Test(arguments: [#"{"metas":{}}"#, #"["metas"]"#, #"{"other":[]}"#, "{", #"{"metas":[{"id":1"#, ""])
    func theScannerRejectsDocumentsWithoutAMetasArray(_ json: String) {
        #expect(AppleJSONArrayElementScanner.elements(ofTopLevelKey: "metas", in: Data(json.utf8), limit: 10) == nil)
    }
}

@Suite("Sweep: catalog entries without a name")
struct AppleNamelessCatalogItemTests {
    @Test func aPosterOnlyEntryIsKeptAndOneWithNeitherIsDropped() async throws {
        let body = #"""
        {"metas":[
          {"id":"tmdb:31132","type":"series","poster":"https://img.fixture.example/p.jpg"},
          {"id":"tmdb:2","type":"series"},
          {"id":"tmdb:15260","type":"series","name":"  ","poster":"https://img.fixture.example/q.jpg"},
          {"id":"tmdb:1","type":"series","name":"Named"}
        ]}
        """#
        let catalog = AppleStremioCatalog(type: "series", id: "cartoons")
        let source = SweepFixture.source(catalogs: [catalog])
        let items = try await SweepFixture.catalogClient(body).load(source: source, catalog: catalog)
        #expect(items.map(\.mediaID) == ["tmdb:31132", "tmdb:15260", "tmdb:1"])
        #expect(items.map(\.name) == ["", "", "Named"])
    }

    @Test func aNamelessItemStillHasAnAccessibilityLabel() {
        let nameless = AppleCatalogItem(mediaID: "tmdb:31132", type: "series", name: "",
                                        posterURL: URL(string: "https://img.fixture.example/p.jpg"))
        #expect(nameless.accessibilityTitle == "Show tmdb:31132")
        #expect(AppleCatalogItem(mediaID: "ch:1", type: "channel", name: "").accessibilityTitle == "Channel ch:1")
        #expect(AppleCatalogItem(mediaID: "tt1", type: "movie", name: "Film").accessibilityTitle == "Film")
    }
}

@Suite("Sweep: meta responses under another id or address")
struct AppleMetaStrictnessTests {
    private let source = SweepFixture.source(resources: ["catalog", "meta"], catalogs: [])

    private func client(answering id: String, finalURL: URL? = nil) -> AppleStremioMetadataClient {
        AppleStremioMetadataClient(loader: { request in
            let body = #"{"meta":{"id":"\#(id)","type":"movie","name":"Fixture Film"}}"#
            return (Data(body.utf8), SweepFixture.response(request, url: finalURL))
        })
    }

    @Test(arguments: [("mx:123", "tt0000123"), ("tmdb:969681", "969681")])
    func theListingAddOnsOnlyMetaAnswersUnderItsOwnID(_ requested: String, _ answered: String) async throws {
        let details = try await client(answering: answered)
            .details(source: source, type: "movie", mediaID: requested, isListingSource: true)
        #expect(details.title == "Fixture Film")
        #expect(details.mediaID == requested)

        await #expect(throws: AppleStremioPlaybackError.invalidPayload) {
            try await client(answering: answered).details(source: source, type: "movie", mediaID: requested)
        }
    }

    @Test func aPercentEncodedEchoOfTheRequestedIDMatches() async throws {
        let details = try await client(answering: "tmdb%3A42").details(source: source, type: "movie", mediaID: "tmdb:42")
        #expect(details.mediaID == "tmdb:42")
    }

    @Test func aRedirectedMetaResponseIsAcceptedOnlyOnAPlainHTTPSAddress() async throws {
        let moved = try #require(URL(string: "https://cdn.fixture.example/meta/movie/tt0000001.json"))
        let details = try await client(answering: "tt0000001", finalURL: moved)
            .details(source: source, type: "movie", mediaID: "tt0000001")
        #expect(details.title == "Fixture Film")

        for bad in ["http://cdn.fixture.example/meta/movie/tt0000001.json",
                    "https://user:pass@cdn.fixture.example/meta/movie/tt0000001.json"] {
            let url = try #require(URL(string: bad))
            await #expect(throws: AppleStremioPlaybackError.invalidPayload) {
                try await client(answering: "tt0000001", finalURL: url)
                    .details(source: source, type: "movie", mediaID: "tt0000001")
            }
        }
    }
}

@Suite("Sweep: every catalog can be turned on")
@MainActor
struct AppleCatalogChoiceTests {
    private func manifest(catalogCount: Int) throws -> Data {
        let catalogs = (0 ..< catalogCount).map { ["type": "movie", "id": "c\($0)", "name": "Catalog \($0)"] }
        return try JSONSerialization.data(withJSONObject: [
            "id": "fixture.many", "name": "Many", "resources": ["catalog"], "catalogs": catalogs,
        ])
    }

    @Test func allSixtyTwoCatalogsAreKeptAndDiscoverStillDefaultsToTheFirstFew() throws {
        let manifest = try JSONDecoder().decode(AppleStremioManifest.self, from: try manifest(catalogCount: 62))
        #expect(manifest.catalogs.count == 62)
        let source = SweepFixture.source(catalogs: manifest.catalogs)
        let shown = AppleCatalogDiscoveryPolicy.catalogs(for: source).map(\.id)
        #expect(shown == (0 ..< AppleCatalogDiscoveryPolicy.defaultMaximumCatalogs).map { "c\($0)" })
    }

    @Test func aChoiceShowsALaterCatalogAndHidesADefaultOne() throws {
        let suite = "openstream-catalog-choices-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AppleSourceStore(defaults: defaults, storageKey: "fixture.sources",
                                     documentsDirectory: FileManager.default.temporaryDirectory)
        let manifest = try JSONDecoder().decode(AppleStremioManifest.self, from: try manifest(catalogCount: 20))
        let added = try store.addStremio(manifestURL: URL(string: "https://addon.fixture.example/manifest.json")!,
                                         manifest: manifest)
        let revision = added.configurationRevision

        store.setCatalog(manifest.catalogs[15], shown: true, id: added.id)
        store.setCatalog(manifest.catalogs[0], shown: false, id: added.id)
        let source = try #require(store.sources.first)
        let shown = AppleCatalogDiscoveryPolicy.catalogs(for: source).map(\.id)
        #expect(shown.first == "c1")
        #expect(shown.contains("c15"))
        #expect(!shown.contains("c0"))
        #expect(source.configurationRevision > revision)

        // Turning a catalog back to its default forgets the choice.
        store.setCatalog(manifest.catalogs[0], shown: true, id: added.id)
        store.setCatalog(manifest.catalogs[15], shown: false, id: added.id)
        #expect(store.sources.first?.catalogChoices.isEmpty == true)

        // Choices survive a reload from storage.
        store.setCatalog(manifest.catalogs[19], shown: true, id: added.id)
        let reloaded = AppleSourceStore(defaults: defaults, storageKey: "fixture.sources",
                                        documentsDirectory: FileManager.default.temporaryDirectory)
        #expect(reloaded.sources.first?.catalogChoices == ["movie:c19": true])
    }
}

@Suite("Sweep: add-ons that serve nothing until configured")
struct AppleUnconfiguredManifestTests {
    private func client(_ body: String) -> AppleManifestClient {
        AppleManifestClient(loader: { url in
            (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, sleeper: { _ in })
    }

    @Test func aConfigurableManifestWithNoResourcesPointsAtItsConfigurePage() async throws {
        let body = #"{"id":"fixture.aio","name":"AIO","resources":[],"catalogs":[],"behaviorHints":{"configurable":true}}"#
        let configure = try #require(URL(string: "https://aio.fixture.example/stremio/configure"))
        await #expect(throws: AppleManifestClientError.manifestNeedsSetup(configureURL: configure)) {
            try await client(body).load("https://aio.fixture.example/stremio/manifest.json")
        }
    }

    @Test(arguments: [
        #"{"id":"fixture.none","name":"None"}"#,
        #"{"id":"fixture.empty","name":"Empty","resources":["catalog"],"catalogs":[]}"#,
        #"{"id":"fixture.other","name":"Other","resources":["addon_catalog"]}"#,
    ])
    func aManifestWithNothingUsableIsRefused(_ body: String) async {
        await #expect(throws: AppleManifestClientError.manifestNeedsSetup(configureURL: nil)) {
            try await client(body).load("https://addon.fixture.example/manifest.json")
        }
    }

    @Test(arguments: [
        #"{"id":"a","name":"A","resources":["stream"]}"#,
        #"{"id":"b","name":"B","resources":[{"name":"meta"}]}"#,
        #"{"id":"c","name":"C","resources":["catalog"],"catalogs":[{"type":"tv","id":"live"}]}"#,
    ])
    func aManifestThatServesSomethingIsAccepted(_ body: String) async throws {
        let (_, manifest) = try await client(body).load("https://addon.fixture.example/manifest.json")
        #expect(manifest.servesUsableContent)
    }

    @Test func theConfigurePageSitsBesideTheManifest() throws {
        let manifest = try #require(URL(string: "https://addon.fixture.example/manifest.json"))
        #expect(AppleManifestURLPolicy.configureURL(forManifest: manifest)?.absoluteString
            == "https://addon.fixture.example/configure")
    }
}

// MARK: - Add-on sweep 2026-10-01 gaps

@Suite("Sweep 2026-10-01: other catalog types end to end")
struct AppleOtherCatalogTypeEndToEndTests {
    @Test func anEventsItemBrowsesOpensAndAsksForStreamsUnderItsType() async throws {
        let events = AppleStremioCatalog(type: "events", id: "today")
        let source = SweepFixture.source(resources: ["catalog", "meta", "stream"], catalogs: [events])
        let items = try await SweepFixture.catalogClient(
            #"{"metas":[{"id":"ev:1","name":"Final","poster":"https://img.fixture.example/e.png"}]}"#
        ).load(source: source, catalog: events)
        let item = try #require(items.first)
        #expect(item.type == "events")

        let meta = AppleStremioMetadataClient(loader: { request in
            #expect(request.url?.path.hasPrefix("/meta/events/") == true)
            return (Data(#"{"meta":{"id":"ev:1","type":"events","name":"Final"}}"#.utf8), SweepFixture.response(request))
        })
        let details = try await meta.details(source: source, type: item.type, mediaID: item.mediaID, isListingSource: true)
        #expect(details.title == "Final")

        let playback = AppleStremioPlaybackClient(loader: { request in
            #expect(request.url?.path.hasPrefix("/stream/events/") == true)
            return (Data(#"{"streams":[{"url":"https://media.fixture.example/e.m3u8","title":"Live"}]}"#.utf8),
                    SweepFixture.response(request))
        })
        let streams = try await playback.streams(source: source, type: item.type, mediaID: item.mediaID)
        #expect(streams.httpCandidates.count == 1)
    }

    @Test func catalogsHaveAtLeastTheMetaAnswerCap() {
        #expect(AppleStremioCatalogClient.maximumResponseBytes >= AppleStremioMetadataClient.maximumMetaResponseBytes)
        #expect(AppleStremioCatalogClient.maximumResponseBytes > AppleStremioPlaybackClient.maximumResponseBytes)
    }
}

@Suite("Sweep 2026-10-01: entries with only an id")
struct AppleIDOnlyCatalogItemTests {
    /// TorrentFreaks Top-10: every entry is `{type, id}` and the add-on
    /// serves no meta; IMDb ids are filled from Cinemeta's art and meta.
    @Test func bareIMDbEntriesAreKeptWithoutACaption() async throws {
        let catalog = AppleStremioCatalog(type: "movie", id: "torrentfreak-movies")
        let source = SweepFixture.source(catalogs: [catalog])
        let items = try await SweepFixture.catalogClient(
            #"{"metas":[{"type":"movie","id":"tt0000101"},{"type":"movie","id":"tt0000102"},{"type":"movie","id":"x:1"}]}"#
        ).load(source: source, catalog: catalog)
        #expect(items.map(\.mediaID) == ["tt0000101", "tt0000102"])
        #expect(items.allSatisfy { $0.name.isEmpty && $0.posterURL == nil })
        #expect(items.first?.accessibilityTitle == "Movie tt0000101")
    }

    @Test func anAddOnWithMetaKeepsItsOwnIDOnlyEntries() async throws {
        let catalog = AppleStremioCatalog(type: "series", id: "own")
        let body = #"{"metas":[{"type":"series","id":"own:1"}]}"#
        let withMeta = SweepFixture.source(resources: ["catalog", "meta"], catalogs: [catalog])
        let withoutMeta = SweepFixture.source(catalogs: [catalog])
        #expect(try await SweepFixture.catalogClient(body).load(source: withMeta, catalog: catalog).map(\.mediaID) == ["own:1"])
        #expect(try await SweepFixture.catalogClient(body).load(source: withoutMeta, catalog: catalog).isEmpty)
    }
}

@Suite("Sweep 2026-10-01: lenient meta answers")
struct AppleLenientMetaTests {
    private let source = SweepFixture.source(resources: ["catalog", "meta"], catalogs: [])

    private func client(_ body: String) -> AppleStremioMetadataClient {
        AppleStremioMetadataClient(loader: { request in (Data(body.utf8), SweepFixture.response(request)) })
    }

    @Test func aMetaObjectAtTheRootIsTheMeta() async throws {
        let details = try await client(#"{"id":"tmdb:1","type":"movie","name":"Root Film","description":"Plot"}"#)
            .details(source: source, type: "movie", mediaID: "tmdb:1")
        #expect(details.title == "Root Film")
        #expect(details.overview == "Plot")
    }

    @Test func aMetaWithoutAnIDAnswersForTheRequestedID() async throws {
        let details = try await client(#"{"meta":{"type":"series","name":"No ID"}}"#)
            .details(source: source, type: "series", mediaID: "tt0000201")
        #expect(details.mediaID == "tt0000201")
        #expect(details.title == "No ID")
    }

    @Test func aMetaWithoutANameTakesTheCatalogItemsName() async throws {
        let body = #"{"meta":{"id":"tt0000301","type":"movie","description":"Plot"}}"#
        let details = try await client(body)
            .details(source: source, type: "movie", mediaID: "tt0000301", fallbackName: "From Catalog")
        #expect(details.title == "From Catalog")
        await #expect(throws: AppleStremioPlaybackError.invalidPayload) {
            try await client(body).details(source: source, type: "movie", mediaID: "tt0000301")
        }
    }

    @Test(arguments: [#"{"meta":null}"#, #"{"meta":{}}"#, #"{"metas":[]}"#, #"{"err":"not found"}"#, "[]"])
    func anAnswerWithNoMetaIsStillRefused(_ body: String) async {
        await #expect(throws: AppleStremioPlaybackError.invalidPayload) {
            try await client(body).details(source: source, type: "movie", mediaID: "tt0000401", fallbackName: "Name")
        }
    }

    @Test func anotherAddOnsMetaUnderADifferentIDIsStillRefused() async {
        await #expect(throws: AppleStremioPlaybackError.invalidPayload) {
            try await client(#"{"id":"tt9999999","name":"Wrong"}"#)
                .details(source: source, type: "movie", mediaID: "tt0000501")
        }
    }
}

@Suite("Sweep 2026-10-01: many catalogs on Discover")
struct AppleManyCatalogRowsTests {
    @Test func upToFortyRowsPerAddOn() {
        let catalogs = (0 ..< 60).map { AppleStremioCatalog(type: "tvgarden", id: "c\($0)") }
        var source = SweepFixture.source(catalogs: catalogs)
        #expect(AppleCatalogDiscoveryPolicy.hardMaximumCatalogs == 40)
        #expect(AppleCatalogDiscoveryPolicy.catalogs(for: source).count == AppleCatalogDiscoveryPolicy.defaultMaximumCatalogs)
        #expect(AppleCatalogDiscoveryPolicy.catalogs(for: source, maximumCatalogs: 100).count == 40)
        source.catalogChoices = Dictionary(uniqueKeysWithValues: catalogs.map { (AppleCatalogDiscoveryPolicy.choiceKey($0), true) })
        #expect(AppleCatalogDiscoveryPolicy.catalogs(for: source).map(\.id) == (0 ..< 40).map { "c\($0)" })
        #expect(AppleCatalogDiscoveryPolicy.maximumConcurrentRequests <= 4)
    }
}
