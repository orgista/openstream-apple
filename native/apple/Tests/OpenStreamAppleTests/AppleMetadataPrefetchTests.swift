import Foundation
import Testing
@testable import OpenStreamApple

/// Owner 2026-09-14: "can we preload metadata like wordmark art so that it
/// loads basically instantly when opening a content page". Measured on the
/// owner's Apple TV, a content page spent 1357 ms resolving preview assets
/// and only ~67 ms drawing the art, so the metadata is what gets preloaded.
@Suite("Metadata prefetch")
struct AppleMetadataPrefetchTests {
    private func title(_ id: String, _ type: String = "movie") -> AppleMetadataPrefetcher.Title {
        .init(type: type, mediaID: id)
    }

    @Test func targetsDropBlanksAndRepeats() {
        let picked = AppleMetadataPrefetcher.targets([
            title("tt1"), title("tt1"), title(""), .init(type: "", mediaID: "tt2"), title("tt3"),
        ])
        #expect(picked.map(\.mediaID) == ["tt1", "tt3"])
    }

    @Test func targetsStopAtTheCap() {
        let many = (0 ..< 20).map { title("tt\($0)") }
        #expect(AppleMetadataPrefetcher.targets(many).count == AppleMetadataPrefetcher.maximumTitles)
    }

    /// The same id under two types is two different titles.
    @Test func typeIsPartOfTheIdentity() {
        let picked = AppleMetadataPrefetcher.targets([title("tt1", "movie"), title("tt1", "series")])
        #expect(picked.count == 2)
    }

    @Test func theKeyIsCaseInsensitiveOnType() {
        #expect(AppleStremioPreviewAssetsCache.key(type: "Movie", mediaID: "tt1")
            == AppleStremioPreviewAssetsCache.key(type: "movie", mediaID: "tt1"))
    }
}

@Suite("Preview assets cache")
struct AppleStremioPreviewAssetsCacheTests {
    private let key = AppleStremioPreviewAssetsCache.key(type: "movie", mediaID: "tt1234567")
    private let assets = AppleStremioPreviewAssets(
        trailerYouTubeKey: nil, logoURL: URL(string: "https://example.test/logo.png"))

    @Test func aStoredAnswerIsServedBack() async {
        let cache = AppleStremioPreviewAssetsCache()
        await cache.store(assets, for: key)
        let entry = await cache.entry(for: key)
        #expect(entry?.assets?.logoURL == assets.logoURL)
    }

    @Test func nothingIsServedForATitleNeverAsked() async {
        let cache = AppleStremioPreviewAssetsCache()
        #expect(await cache.entry(for: key) == nil)
    }

    @Test func aSuccessSurvivesHalfAnHour() async {
        let cache = AppleStremioPreviewAssetsCache()
        let stored = Date()
        await cache.store(assets, for: key, now: stored)
        #expect(await cache.entry(for: key, now: stored.addingTimeInterval(29 * 60)) != nil)
        #expect(await cache.entry(for: key, now: stored.addingTimeInterval(31 * 60)) == nil)
    }

    /// A miss is usually a slow add-on, not a title without artwork, so it
    /// must not stop the next visit from asking.
    @Test func aMissExpiresQuickly() async {
        let cache = AppleStremioPreviewAssetsCache()
        let stored = Date()
        await cache.store(nil, for: key, now: stored)
        #expect(await cache.entry(for: key, now: stored.addingTimeInterval(60)) != nil)
        #expect(await cache.entry(for: key, now: stored.addingTimeInterval(3 * 60)) == nil)
    }

    @Test func theCacheStaysBounded() async {
        let cache = AppleStremioPreviewAssetsCache()
        let start = Date()
        for index in 0 ... AppleStremioPreviewAssetsCache.limit + 10 {
            await cache.store(assets,
                for: AppleStremioPreviewAssetsCache.key(type: "movie", mediaID: "tt\(index)"),
                now: start.addingTimeInterval(Double(index)))
        }
        #expect(await cache.count <= AppleStremioPreviewAssetsCache.limit)
    }
}
