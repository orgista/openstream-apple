import Foundation
import Synchronization
import Testing
@testable import OpenStreamApple

/// "Watch on <service>" (specs/watch-on-service.md). Everything here is pure
/// or runs against an injected transport: no test touches the network.
@Suite("Watch on service")
struct AppleWatchOnTests {
    private let netflix = AppleWatchProvider(id: 8, name: "Netflix", offer: .subscription)
    private let netflixAds = AppleWatchProvider(id: 1796, name: "Netflix Standard with Ads", offer: .subscription)
    private let appleTV = AppleWatchProvider(id: 350, name: "Apple TV+", offer: .subscription)
    private let tubi = AppleWatchProvider(id: 73, name: "Tubi", offer: .ads)
    private let unknown = AppleWatchProvider(id: 99_999, name: "Somewhere", offer: .subscription)

    // MARK: Provider → service → property

    @Test(arguments: [
        (8, AppleStreamingService.netflix), (1796, .netflix), (337, .disneyPlus), (15, .hulu),
        (9, .primeVideo), (119, .primeVideo), (1899, .hboMax), (384, .hboMax), (350, .appleTV),
        (531, .paramountPlus), (386, .peacock), (283, .crunchyroll), (73, .tubi), (300, .plutoTV),
    ])
    func tmdbProviderMapsToService(id: Int, service: AppleStreamingService) {
        #expect(AppleStreamingService(tmdbProviderID: id) == service)
    }

    @Test func unknownProviderHasNoService() {
        #expect(AppleStreamingService(tmdbProviderID: 99_999) == nil)
    }

    @Test func servicesUseTheSpecProperties() {
        #expect(AppleStreamingService.netflix.wikidataProperties.map(\.rawValue) == ["P1874"])
        #expect(AppleStreamingService.disneyPlus.wikidataProperties.map(\.rawValue) == ["P13902", "P7595", "P7596"])
        #expect(AppleStreamingService.hulu.wikidataProperties.map(\.rawValue) == ["P6467", "P6466"])
        #expect(AppleStreamingService.primeVideo.wikidataProperties.map(\.rawValue) == ["P14462", "P8055", "P14440"])
        #expect(AppleStreamingService.hboMax.wikidataProperties.map(\.rawValue) == ["P8298"])
        #expect(AppleStreamingService.appleTV.wikidataProperties.map(\.rawValue) == ["P9586", "P9751"])
        #expect(AppleStreamingService.tubi.wikidataProperties.map(\.rawValue) == ["P7760", "P7761"])
        // Their links do not open the app (spec §3): search or home only.
        #expect(AppleStreamingService.peacock.wikidataProperties.isEmpty)
        #expect(AppleStreamingService.paramountPlus.wikidataProperties.isEmpty)
    }

    // MARK: URL builders

    @Test(arguments: [
        (AppleWikidataStreamingProperty.netflix, "70143836", "https://www.netflix.com/title/70143836"),
        (.disneyPlusBrowse, "entity-05eb6a8e-90ed-4947-8c0b-e6536cbddd5f",
         "https://www.disneyplus.com/browse/entity-05eb6a8e-90ed-4947-8c0b-e6536cbddd5f"),
        (.disneyPlusMovie, "4TQTHo9Qto2m", "https://www.disneyplus.com/movies/wd/4TQTHo9Qto2m"),
        (.disneyPlusSeries, "3xsQKWG00GL5", "https://www.disneyplus.com/series/wp/3xsQKWG00GL5"),
        (.huluSeries, "05eb6a8e-90ed-4947-8c0b-e6536cbddd5f",
         "https://www.hulu.com/series/05eb6a8e-90ed-4947-8c0b-e6536cbddd5f"),
        (.huluMovie, "05eb6a8e-90ed-4947-8c0b-e6536cbddd5f",
         "https://www.hulu.com/movie/05eb6a8e-90ed-4947-8c0b-e6536cbddd5f"),
        (.primeVideoASIN, "B008Y6W4I8", "https://www.primevideo.com/detail/B008Y6W4I8"),
        (.primeVideoGTI, "amzn1.dv.gti.0eb2d6ba-0d93-4e86-9c3e-6b4a0e5a8f11",
         "https://www.primevideo.com/detail/amzn1.dv.gti.0eb2d6ba-0d93-4e86-9c3e-6b4a0e5a8f11"),
        (.primeVideoID, "0OU80GSYHEGIM88LA9B3GOPU2B", "https://www.primevideo.com/detail/0OU80GSYHEGIM88LA9B3GOPU2B"),
        (.hboMax, "show/93ba22b1-6b0f-4f6e-9a3e-2a6c0bd8a1c2",
         "https://play.hbomax.com/show/93ba22b1-6b0f-4f6e-9a3e-2a6c0bd8a1c2"),
        (.hboMax, "series/urn:hbo:series:GVU2cggagzYNJjhsJATwo",
         "https://play.hbomax.com/series/urn:hbo:series:GVU2cggagzYNJjhsJATwo"),
        (.appleTVMovie, "umc.cmc.6loas01ow0w4lkatxxloz7a6e", "https://tv.apple.com/movie/umc.cmc.6loas01ow0w4lkatxxloz7a6e"),
        (.appleTVShow, "umc.cmc.1v90fu25sgywa1e14jwnrt9uc", "https://tv.apple.com/show/umc.cmc.1v90fu25sgywa1e14jwnrt9uc"),
        (.crunchyrollSeries, "GR751KNZY", "https://www.crunchyroll.com/series/GR751KNZY"),
        (.tubiMovie, "100003156", "https://tubitv.com/movies/100003156"),
        (.tubiSeries, "300001234", "https://tubitv.com/series/300001234"),
    ])
    func buildsTheVerifiedTitleURL(property: AppleWikidataStreamingProperty, id: String, expected: String) {
        #expect(property.url(for: id)?.absoluteString == expected)
    }

    @Test func malformedIDsBuildNothing() {
        #expect(AppleWikidataStreamingProperty.netflix.url(for: "70143836/../evil") == nil)
        #expect(AppleWikidataStreamingProperty.netflix.url(for: "abc") == nil)
        #expect(AppleWikidataStreamingProperty.disneyPlusBrowse.url(for: "05eb6a8e") == nil)
        #expect(AppleWikidataStreamingProperty.appleTVShow.url(for: "umc.cmc.UPPER") == nil)
        #expect(AppleWikidataStreamingProperty.primeVideoASIN.url(for: "B008Y6W4I8 ") == nil)
    }

    @Test func peacockAndParamountNeverBuildATitleLink() {
        #expect(AppleWikidataStreamingProperty.peacock.url(for: "tv/yellowstone") == nil)
        #expect(AppleWikidataStreamingProperty.paramountPlus.url(for: "gUufhVPlJy5i5HLTbS8li1LruEeMH_3x") == nil)
    }

    @Test func searchOnlyWhereTheAppClaimsIt() {
        #expect(AppleStreamingService.netflix.searchURL(for: "Breaking Bad")?.absoluteString
            == "https://www.netflix.com/search?q=Breaking%20Bad")
        #expect(AppleStreamingService.primeVideo.searchURL(for: "Dune")?.absoluteString
            == "https://www.primevideo.com/search?phrase=Dune")
        #expect(AppleStreamingService.peacock.searchURL(for: "Wicked")?.absoluteString
            == "https://www.peacocktv.com/watch/search?q=Wicked")
        for service in [AppleStreamingService.hulu, .paramountPlus, .tubi, .crunchyroll, .disneyPlus, .plutoTV] {
            #expect(service.searchURL(for: "Dune") == nil, "\(service)")
        }
    }

    // MARK: Fallback order

    private func ids(_ values: [String: [String]]) -> AppleStreamingIDs { AppleStreamingIDs(values: values) }

    @Test func titleLinkComesFirstThenSearchThenHome() {
        let links = AppleWatchOnLinkPolicy.links(
            for: .netflix,
            ids: ids(["P1874": ["70143836"], "P9751": ["umc.cmc.1v90fu25sgywa1e14jwnrt9uc"]]),
            title: "Breaking Bad"
        )
        #expect(links.map(\.kind) == [.title, .search, .home])
        #expect(links.first?.url.absoluteString == "https://www.netflix.com/title/70143836")
    }

    /// "Watch on Netflix" with no Netflix id opened tv.apple.com (iOS 18
    /// test, 2026-10-01): the fallback stays on the labelled service.
    @Test func noServiceIDStaysOnTheServiceNotTheAppleTVPage() {
        let netflix = AppleWatchOnLinkPolicy.links(
            for: .netflix, ids: ids(["P9751": ["umc.cmc.1v90fu25sgywa1e14jwnrt9uc"]]), title: "Breaking Bad"
        )
        #expect(netflix.map(\.kind) == [.search, .home])
        #expect(netflix.allSatisfy { $0.url.host()?.hasSuffix("netflix.com") == true })
        let hbo = AppleWatchOnLinkPolicy.links(
            for: .hboMax, ids: ids(["P9586": ["umc.cmc.6loas01ow0w4lkatxxloz7a6e"]]), title: "Dune"
        )
        #expect(!hbo.contains { $0.kind == .appleTV || $0.url.host() == "tv.apple.com" })
        #expect(hbo.last?.kind == .home)
        for platform in [AppleUIPlatform.iOS, .tvOS, .visionOS] {
            let attempts = AppleWatchOnPolicy.attempts(for: netflix, platform: platform)
            #expect(!attempts.contains { attempt in
                switch attempt {
                case .app(let link), .system(let link): link.url.host() == "tv.apple.com"
                case .instructions: false
                }
            }, "\(platform)")
        }
    }

    @Test func noIDsAtAllIsSearchThenHomeOrJustHome() {
        #expect(AppleWatchOnLinkPolicy.links(for: .netflix, ids: ids([:]), title: "Napoleon").map(\.kind) == [.search, .home])
        let paramount = AppleWatchOnLinkPolicy.links(for: .paramountPlus, ids: ids([:]), title: "Napoleon")
        #expect(paramount.map(\.kind) == [.home])
        #expect(paramount.first?.url.absoluteString == "https://www.paramountplus.com/")
    }

    @Test func disneyPrefersBrowseIDOverLegacy() {
        let links = AppleWatchOnLinkPolicy.links(
            for: .disneyPlus,
            ids: ids(["P7595": ["4TQTHo9Qto2m"], "P13902": ["entity-05eb6a8e-90ed-4947-8c0b-e6536cbddd5f"]]),
            title: "Frozen"
        )
        #expect(links.first?.url.absoluteString == "https://www.disneyplus.com/browse/entity-05eb6a8e-90ed-4947-8c0b-e6536cbddd5f")
    }

    @Test func disneyFallsBackToLegacyMovieID() {
        let links = AppleWatchOnLinkPolicy.links(for: .disneyPlus, ids: ids(["P7595": ["bad", "4TQTHo9Qto2m"]]), title: "Frozen")
        #expect(links.first?.url.absoluteString == "https://www.disneyplus.com/movies/wd/4TQTHo9Qto2m")
    }

    @Test func huluContentAlsoLinksIntoDisneyPlus() {
        let uuid = "05eb6a8e-90ed-4947-8c0b-e6536cbddd5f"
        let hulu = AppleWatchOnLinkPolicy.links(for: .hulu, ids: ids(["P6467": [uuid]]), title: "The Bear")
        #expect(hulu.prefix(2).map(\.url.absoluteString) == [
            "https://www.hulu.com/series/\(uuid)", "https://www.disneyplus.com/browse/entity-\(uuid)",
        ])
        let disney = AppleWatchOnLinkPolicy.links(for: .disneyPlus, ids: ids(["P6467": [uuid]]), title: "The Bear")
        #expect(disney.first?.url.absoluteString == "https://www.disneyplus.com/browse/entity-\(uuid)")
    }

    @Test func appleTVServiceIsNotListedTwice() {
        let links = AppleWatchOnLinkPolicy.links(
            for: .appleTV, ids: ids(["P9751": ["umc.cmc.1v90fu25sgywa1e14jwnrt9uc"]]), title: "Severance"
        )
        #expect(links.map(\.kind) == [.appleTV, .search, .home])
    }

    @Test func voiceOverHintOnlyWhenTheLinkIsNotTheTitle() {
        let titled = AppleWatchOnLinkPolicy.links(for: .netflix, ids: ids(["P1874": ["70143836"]]), title: "X")
        #expect(AppleWatchOnLinkPolicy.accessibilityHint(service: .netflix, links: titled) == nil)
        let search = AppleWatchOnLinkPolicy.links(for: .netflix, ids: ids([:]), title: "X")
        #expect(AppleWatchOnLinkPolicy.accessibilityHint(service: .netflix, links: search) == "Opens Netflix search")
        let home = AppleWatchOnLinkPolicy.links(for: .tubi, ids: ids([:]), title: "X")
        #expect(AppleWatchOnLinkPolicy.accessibilityHint(service: .tubi, links: home) == "Opens Tubi")
    }

    // MARK: Primary action

    @Test func inAppSourceKeepsPlay() {
        #expect(AppleWatchOnPolicy.action(hasInAppSource: true, visibleProviders: [netflix]) == nil)
    }

    @Test func noProvidersKeepsThePageAsItIs() {
        #expect(AppleWatchOnPolicy.action(hasInAppSource: false, visibleProviders: []) == nil)
        #expect(AppleWatchOnPolicy.action(hasInAppSource: false, visibleProviders: [unknown]) == nil)
    }

    @Test func oneServiceIsOneButton() throws {
        let action = try #require(AppleWatchOnPolicy.action(hasInAppSource: false, visibleProviders: [netflix, unknown]))
        #expect(action == .single(AppleWatchOnChoice(service: .netflix, provider: netflix)))
        #expect(action.title == "Watch on Netflix")
    }

    @Test func severalServicesAreAMenuInRankOrder() throws {
        let visible = AppleWatchProviderPolicy.visible([tubi, appleTV, netflix, netflixAds], enabledProviderIDs: [8, 1796, 350, 73])
        let action = try #require(AppleWatchOnPolicy.action(hasInAppSource: false, visibleProviders: visible))
        #expect(action.title == "Watch on…")
        // Subscriptions before ads; the two Netflix tiers are one entry.
        #expect(action.choices.map(\.service) == [.appleTV, .netflix, .tubi])
    }

    // MARK: Opening, per platform

    private let title = AppleWatchOnLink(url: URL(string: "https://www.netflix.com/title/70143836")!, kind: .title)
    private let atv = AppleWatchOnLink(url: URL(string: "https://tv.apple.com/show/umc.cmc.1v90fu25sgywa1e14jwnrt9uc")!, kind: .appleTV)
    private let home = AppleWatchOnLink(url: URL(string: "https://www.netflix.com/")!, kind: .home)

    @Test func tvOSTriesTheAppThenTheTVAppThenInstructions() {
        let attempts = AppleWatchOnPolicy.attempts(for: [title, atv, home], platform: .tvOS)
        #expect(attempts == [.app(title), .system(atv), .app(home), .instructions(title)])
    }

    @Test func iOSEndsInTheBrowserBeforeInstructions() {
        let attempts = AppleWatchOnPolicy.attempts(for: [title, atv, home], platform: .iOS)
        #expect(attempts == [.app(title), .system(atv), .app(home), .system(title), .instructions(title)])
    }

    @Test func macOpensTheWebPage() {
        #expect(AppleWatchOnPolicy.attempts(for: [title, atv, home], platform: .macOS) == [.system(title), .instructions(title)])
    }

    @Test func tvOSWithNoAppShowsInstructionsWithTheWebLink() async {
        let outcome = await AppleWatchOnPolicy.run(
            AppleWatchOnPolicy.attempts(for: [title, home], platform: .tvOS), open: { _, _ in false }
        )
        #expect(outcome == .instructions(title))
        #expect(outcome.traceDetail == "instructions")
    }

    @Test func tvOSFallsThroughToTheTVApp() async {
        let outcome = await AppleWatchOnPolicy.run(
            AppleWatchOnPolicy.attempts(for: [title, atv, home], platform: .tvOS),
            open: { url, appOnly in !appOnly && url.host() == "tv.apple.com" }
        )
        #expect(outcome == .opened(atv, inBrowser: false))
        #expect(outcome.traceDetail == "tvapp")
    }

    @Test func installedAppOpensTheTitle() async {
        let outcome = await AppleWatchOnPolicy.run(
            AppleWatchOnPolicy.attempts(for: [title, atv, home], platform: .iOS), open: { _, appOnly in appOnly }
        )
        #expect(outcome == .opened(title, inBrowser: false))
        #expect(outcome.traceDetail == "wikidata id")
    }

    @Test func iOSWithoutTheAppOpensTheBrowser() async {
        let outcome = await AppleWatchOnPolicy.run(
            AppleWatchOnPolicy.attempts(for: [title, home], platform: .iOS), open: { _, appOnly in !appOnly }
        )
        #expect(outcome == .opened(title, inBrowser: true))
    }
}

@Suite("Wikidata streaming ids")
struct AppleWikidataStreamingIDTests {
    /// Shaped like the research run's answer (spec §2): Breaking Bad,
    /// Frozen's two legacy Disney+ ids, Succession's legacy HBO urn, The Last
    /// of Us's new `show/` path. Napoleon was asked for and is absent.
    static let fixture = Data("""
    {"head":{"vars":["imdb","P1874","P7595","P8298","P9751","P6467"]},
     "results":{"bindings":[
      {"imdb":{"type":"literal","value":"tt0903747"},
       "P1874":{"type":"literal","value":"70143836"},
       "P9751":{"type":"literal","value":"umc.cmc.1v90fu25sgywa1e14jwnrt9uc"},
       "P7595":{"type":"literal","value":""}},
      {"imdb":{"type":"literal","value":"tt2294629"},
       "P7595":{"type":"literal","value":"4TQTHo9Qto2m|8sYv5DkSs0Nk"}},
      {"imdb":{"type":"literal","value":"tt7660850"},
       "P8298":{"type":"literal","value":"series/urn:hbo:series:GXdbR_gOXWJuAuwEAACVH"},
       "P6467":{"type":"literal","value":"8d3b5f0c-3f3a-4d0e-9a1e-2c7f4b6a9e10"}},
      {"imdb":{"type":"literal","value":"tt3581920"},
       "P8298":{"type":"literal","value":"show/93ba22b1-6b0f-4f6e-9a3e-2a6c0bd8a1c2"}}
     ]}}
    """.utf8)

    // MARK: Query

    @Test func queryValidatesAndIncludesEveryProperty() throws {
        let query = try #require(AppleWikidataStreamingQuery.sparql(imdbIDs: ["tt0903747", "x\" } DROP", "tt0903747", "nm123"]))
        #expect(query.contains("VALUES ?imdb { \"tt0903747\" }"))
        #expect(!query.contains("DROP"))
        for property in AppleWikidataStreamingProperty.allCases {
            #expect(query.contains("wdt:\(property.rawValue) "), "\(property)")
        }
        #expect(query.contains("wdt:P345 ?imdb"))
    }

    @Test func noValidIDsNoQuery() {
        #expect(AppleWikidataStreamingQuery.sparql(imdbIDs: ["", "tt", "tt12345678901"]) == nil)
    }

    @Test func batchesAtMostFifty() throws {
        let ids = (1 ... 80).map { "tt\(1_000_000 + $0)" }
        let query = try #require(AppleWikidataStreamingQuery.sparql(imdbIDs: ids))
        #expect(query.components(separatedBy: "\"tt").count - 1 == 50)
    }

    /// Only IMDb ids leave the device: two titles' requests differ in the id
    /// alone, and carry nothing but Accept and a User-Agent.
    @Test func requestCarriesOnlyTheIMDbID() throws {
        let a = try #require(AppleWikidataStreamingQuery.request(imdbIDs: ["tt0903747"], version: "9"))
        let b = try #require(AppleWikidataStreamingQuery.request(imdbIDs: ["tt0000001"], version: "9"))
        #expect(a.url?.host() == "query.wikidata.org")
        #expect(a.url?.absoluteString.replacingOccurrences(of: "tt0903747", with: "tt0000001") == b.url?.absoluteString)
        #expect(Set(a.allHTTPHeaderFields?.keys.map { $0 } ?? []) == ["Accept", "User-Agent"])
        #expect(a.value(forHTTPHeaderField: "User-Agent")?.contains("https://") == true)
        #expect(a.timeoutInterval == 20)
        #expect(a.httpBody == nil)
    }

    // MARK: Parsing

    @Test func parsesTheFixture() throws {
        let parsed = try AppleWikidataStreamingQuery.parse(Self.fixture)
        #expect(parsed.count == 4)
        #expect(parsed["tt0903747"]?.first(.netflix) == "70143836")
        #expect(parsed["tt0903747"]?.values["P7595"] == nil)
        #expect(parsed["tt2294629"]?.values["P7595"] == ["4TQTHo9Qto2m", "8sYv5DkSs0Nk"])
        #expect(parsed["tt7660850"]?.first(.hboMax) == "series/urn:hbo:series:GXdbR_gOXWJuAuwEAACVH")
        #expect(parsed["tt3581920"]?.first(.hboMax) == "show/93ba22b1-6b0f-4f6e-9a3e-2a6c0bd8a1c2")
        #expect(parsed["tt13287846"] == nil)
    }

    @Test func parsedIDsBuildLinks() throws {
        let parsed = try AppleWikidataStreamingQuery.parse(Self.fixture)
        let succession = try #require(parsed["tt7660850"])
        #expect(AppleWatchOnLinkPolicy.links(for: .hboMax, ids: succession, title: "Succession").first?.url.absoluteString
            == "https://play.hbomax.com/series/urn:hbo:series:GXdbR_gOXWJuAuwEAACVH")
    }

    @Test func retryAfterReadsSecondsAndDates() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(AppleWikidataStreamingIDClient.retryAfter("120", now: now) == 120)
        #expect(AppleWikidataStreamingIDClient.retryAfter(nil, now: now) == nil)
        let date = AppleWikidataStreamingIDClient.retryAfter("Mon, 12 Jan 1970 13:47:40 GMT", now: now)
        #expect(date == 60)
    }

    // MARK: Client, cache and rate limits (injected transport and clock)

    final class Harness: Sendable {
        let clock = Mutex(Date(timeIntervalSince1970: 2_000_000_000))
        let calls = Mutex(0)
        let inFlight = Mutex(0)
        let maxInFlight = Mutex(0)
        let status = Mutex(200)
        let retryAfter = Mutex<String?>(nil)
        let fileURL: URL

        init() {
            fileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("watch-on-\(UUID().uuidString).json")
        }

        func advance(_ seconds: TimeInterval) { clock.withLock { $0 = $0.addingTimeInterval(seconds) } }

        func client() -> AppleWikidataStreamingIDClient {
            AppleWikidataStreamingIDClient(
                cacheFileURL: fileURL,
                now: { [self] in clock.withLock { $0 } },
                transport: { [self] request in
                    calls.withLock { $0 += 1 }
                    let current = inFlight.withLock { $0 += 1; return $0 }
                    maxInFlight.withLock { $0 = max($0, current) }
                    try await Task.sleep(for: .milliseconds(20))
                    inFlight.withLock { $0 -= 1 }
                    let code = status.withLock { $0 }
                    var headers: [String: String] = [:]
                    if let retry = retryAfter.withLock({ $0 }) { headers["Retry-After"] = retry }
                    let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: headers)!
                    return (code == 200 ? AppleWikidataStreamingIDTests.fixture : Data(), response)
                }
            )
        }
    }

    @Test func hitsAreCachedForSevenDays() async {
        let harness = Harness()
        let client = harness.client()
        #expect(await client.ids(for: "tt0903747").first(.netflix) == "70143836")
        harness.advance(6 * 24 * 60 * 60)
        #expect(await client.ids(for: "tt0903747").first(.netflix) == "70143836")
        #expect(harness.calls.withLock { $0 } == 1)
        harness.advance(2 * 24 * 60 * 60)
        _ = await client.ids(for: "tt0903747")
        #expect(harness.calls.withLock { $0 } == 2)
    }

    @Test func missesAreCachedForOneDay() async {
        let harness = Harness()
        let client = harness.client()
        #expect(await client.ids(for: "tt13287846").isEmpty)
        harness.advance(23 * 60 * 60)
        _ = await client.ids(for: "tt13287846")
        #expect(harness.calls.withLock { $0 } == 1)
        harness.advance(2 * 60 * 60)
        _ = await client.ids(for: "tt13287846")
        #expect(harness.calls.withLock { $0 } == 2)
    }

    @Test func cacheSurvivesANewClientAndIgnoresACorruptFile() async throws {
        let harness = Harness()
        _ = await harness.client().ids(for: "tt0903747")
        #expect(await harness.client().ids(for: "tt0903747").first(.netflix) == "70143836")
        #expect(harness.calls.withLock { $0 } == 1)
        try Data("not json".utf8).write(to: harness.fileURL)
        #expect(await harness.client().ids(for: "tt0903747").first(.netflix) == "70143836")
        #expect(harness.calls.withLock { $0 } == 2)
    }

    @Test func oneRequestInFlightAndSameIDsCoalesce() async {
        let harness = Harness()
        let client = harness.client()
        async let a = client.ids(for: "tt0903747")
        async let b = client.ids(for: "tt0903747")
        async let c = client.ids(for: "tt2294629")
        let results = await [a, b, c]
        #expect(results[0] == results[1])
        #expect(harness.maxInFlight.withLock { $0 } == 1)
        #expect(harness.calls.withLock { $0 } == 2)
    }

    @Test func rateLimitHonoursRetryAfterAndReturnsEmpty() async {
        let harness = Harness()
        harness.status.withLock { $0 = 429 }
        harness.retryAfter.withLock { $0 = "120" }
        let client = harness.client()
        #expect(await client.ids(for: "tt0903747").isEmpty)
        #expect(await client.isBackingOff)
        harness.status.withLock { $0 = 200 }
        // Still inside Retry-After: no request goes out, and the failure was
        // not cached as a miss.
        harness.advance(60)
        #expect(await client.ids(for: "tt0903747").isEmpty)
        #expect(harness.calls.withLock { $0 } == 1)
        harness.advance(61)
        #expect(await client.ids(for: "tt0903747").first(.netflix) == "70143836")
        #expect(harness.calls.withLock { $0 } == 2)
    }

    @Test func repeatedRateLimitsBackOffExponentially() async {
        let harness = Harness()
        harness.status.withLock { $0 = 503 }
        let client = harness.client()
        _ = await client.ids(for: "tt0903747")
        harness.advance(61)
        _ = await client.ids(for: "tt0903747")
        // Second 503 without Retry-After: 120 s, so 61 s later still waiting.
        harness.advance(61)
        _ = await client.ids(for: "tt0903747")
        #expect(harness.calls.withLock { $0 } == 2)
        #expect(await client.isBackingOff)
    }
}
