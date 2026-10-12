import Foundation
import Testing
@testable import OpenStreamApple

/// Owner 2026-09-29: on a fresh install Discover's hero drew "JEOPARDY!" as
/// plain text all session while its title page had the logo. The heroes now
/// ask for their own wordmarks, retry an add-on that could not be reached,
/// and draw a mark found late the next time the page comes round.
@Suite("Hero wordmark fetch")
struct AppleHeroWordmarkFetchTests {
    private let mark = URL(string: "https://fixture.example/logo.png")!

    @Test func aWordmarkIsFoundWhateverTheCacheSays() {
        let assets = AppleStremioPreviewAssets(trailerYouTubeKey: nil, logoURL: mark)
        #expect(AppleHeroWordmarkFetch.outcome(assets: assets, answered: true) == .found(mark))
        #expect(AppleHeroWordmarkFetch.outcome(assets: assets, answered: false) == .found(mark))
    }

    /// A cached "none" is an answer; an empty cache after the ask means no
    /// add-on was reached, which is worth asking again.
    @Test func noWordmarkIsAnAnswerOnlyWhenTheCacheHoldsOne() {
        #expect(AppleHeroWordmarkFetch.outcome(assets: nil, answered: true) == .none)
        #expect(AppleHeroWordmarkFetch.outcome(assets: nil, answered: false) == .transient)
        let trailerOnly = AppleStremioPreviewAssets(trailerYouTubeKey: "abcd1234567", logoURL: nil)
        #expect(AppleHeroWordmarkFetch.outcome(assets: trailerOnly, answered: false) == .none)
    }

    @Test func retriesAreBounded() {
        #expect(AppleHeroWordmarkFetch.retryDelay(0) == nil)
        #expect(AppleHeroWordmarkFetch.retryDelay(1) == .seconds(3))
        #expect(AppleHeroWordmarkFetch.retryDelay(2) == .seconds(10))
        #expect(AppleHeroWordmarkFetch.retryDelay(3) == nil)
    }

    @Test func traceLinesNameTheTitleAndTheOutcome() {
        #expect(AppleHeroWordmarkFetch.traceLine(title: "Jeopardy!", outcome: .found(mark), milliseconds: 412)
            == "hero wordmark fetch Jeopardy!: found (412ms)")
        #expect(AppleHeroWordmarkFetch.traceLine(title: "Jeopardy!", outcome: .none, milliseconds: 90)
            == "hero wordmark fetch Jeopardy!: none (90ms)")
        #expect(AppleHeroWordmarkFetch.traceLine(title: "Jeopardy!", outcome: .transient, milliseconds: 15000)
            .hasPrefix("hero wordmark fetch Jeopardy!: none (15000ms"))
    }

    /// The name keeps the slot for the rest of that showing, and lets go
    /// when the hero moves to another page, so the mark draws next time.
    @Test func theNameLatchLastsOneShowingOfOnePage() {
        #expect(AppleHeroTitlePolicy.nameLatch("a", from: "a", to: "a") == "a")
        #expect(AppleHeroTitlePolicy.nameLatch("a", from: "a", to: "b") == nil)
        #expect(AppleHeroTitlePolicy.nameLatch("a", from: "b", to: "a") == nil)
        #expect(AppleHeroTitlePolicy.nameLatch(nil, from: "a", to: "b") == nil)
    }

    /// Back on the page with a mark known and no latch, the mark draws.
    @Test func aPageComingRoundAgainDrawsTheMarkFoundMeanwhile() {
        let latch = AppleHeroTitlePolicy.nameLatch("a", from: "b", to: "a")
        let presentation = AppleHeroTitlePolicy.presentation(
            wordmark: mark, loaded: nil, failed: nil, graceExpired: false,
            lookupPending: false, nameShown: latch == "a"
        )
        #expect(presentation == .wordmark(mark))
    }
}

/// `previewAssets` remembers "no wordmark" for two minutes. A walk where an
/// add-on could not be reached is not that answer and must not be cached.
@Suite("Preview assets negative cache")
struct AppleStremioPreviewAssetsNegativeCacheTests {
    private func source() throws -> AppleSource {
        AppleSource(kind: .stremio, name: "Fixture",
                    url: try #require(URL(string: "https://fixture.example/manifest.json")), resources: ["meta"])
    }

    /// Unique per test run: the cache is process-wide and tests run in parallel.
    private func mediaID() -> String { "fixture-hero-\(UUID().uuidString)" }

    @Test func anUnreachableAddOnIsNotRememberedAsNoWordmark() async throws {
        let id = mediaID()
        let client = AppleStremioMetadataClient(loader: { _ in throw URLError(.timedOut) })
        let assets = await client.previewAssets(sources: [try source()], type: "series", mediaID: id)
        #expect(assets == nil)
        let key = AppleStremioPreviewAssetsCache.key(type: "series", mediaID: id)
        #expect(await AppleStremioPreviewAssetsCache.shared.entry(for: key) == nil)
    }

    @Test func anAddOnThatAnswersWithoutAWordmarkIsRemembered() async throws {
        let id = mediaID()
        let client = AppleStremioMetadataClient(loader: { request in
            let body = Data(#"{"meta":{"id":"x","type":"series","trailers":[]}}"#.utf8)
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (body, response)
        })
        let assets = await client.previewAssets(sources: [try source()], type: "series", mediaID: id)
        #expect(assets == nil)
        let key = AppleStremioPreviewAssetsCache.key(type: "series", mediaID: id)
        let entry = try #require(await AppleStremioPreviewAssetsCache.shared.entry(for: key))
        #expect(entry.assets == nil)
    }
}
