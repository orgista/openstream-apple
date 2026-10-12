import Foundation
import Testing
@testable import OpenStreamApple

/// Edge cases for `AppleArtworkPrefetchPolicy` that
/// `AppleArtworkPrefetchPolicyTests` does not already cover: empty input,
/// zero/default `perSection`/`limit`, an item whose poster and background
/// are the very same URL, and a case where `urls(forDetail:)` truncates
/// `episodeThumbnails` to `limit` before de-duplicating, so a genuinely
/// unique thumbnail right after a duplicate never makes it in.
@Suite("AppleArtworkPrefetchPolicyEdgeTests")
struct AppleArtworkPrefetchPolicyEdgeTests {
    private func makeItem(
        id: String,
        poster: String? = nil,
        background: String? = nil
    ) -> AppleCatalogItem {
        AppleCatalogItem(
            mediaID: id,
            type: "movie",
            name: "Title \(id)",
            posterURL: poster.flatMap(URL.init(string:)),
            backgroundURL: background.flatMap(URL.init(string:))
        )
    }

    @Test("No sections at all returns no URLs")
    func emptySectionsReturnNoURLs() {
        #expect(AppleArtworkPrefetchPolicy.urls(sections: []) == [])
    }

    @Test("An empty section and an item with no art are both skipped without crashing")
    func sectionsWithEmptyArraysAndItemsWithNoArtAreSkipped() {
        let noArt = makeItem(id: "1")
        let urls = AppleArtworkPrefetchPolicy.urls(sections: [[], [noArt]])
        #expect(urls == [])
    }

    @Test("An item whose poster and background are the same URL is only prefetched once")
    func duplicatePosterAndBackgroundOnTheSameItemCountsOnce() {
        let item = makeItem(id: "1", poster: "https://fixture.example/same.jpg", background: "https://fixture.example/same.jpg")
        let urls = AppleArtworkPrefetchPolicy.urls(sections: [[item]])
        #expect(urls == [URL(string: "https://fixture.example/same.jpg")!])
    }

    @Test("perSection: 0 inspects nothing, even in a non-empty section")
    func perSectionZeroInspectsNothing() {
        let item = makeItem(id: "1", poster: "https://fixture.example/poster1.jpg")
        let urls = AppleArtworkPrefetchPolicy.urls(sections: [[item]], perSection: 0)
        #expect(urls == [])
    }

    @Test("The default perSection caps a section at 12 items when the caller does not pass one")
    func defaultPerSectionCapsAtTwelveItems() {
        let items = (1 ... 13).map { makeItem(id: "\($0)", poster: "https://fixture.example/poster\($0).jpg") }
        let urls = AppleArtworkPrefetchPolicy.urls(sections: [items])
        #expect(urls.count == 12)
        #expect(urls == (1 ... 12).map { URL(string: "https://fixture.example/poster\($0).jpg")! })
    }

    @Test("A detail item with no art de-duplicates its own repeated episode thumbnails")
    func detailWithNoArtAndDuplicateEpisodesDedupesAndSkipsNils() {
        let item = makeItem(id: "1")
        let episodes = [
            URL(string: "https://fixture.example/ep1.jpg")!,
            URL(string: "https://fixture.example/ep1.jpg")!,
            URL(string: "https://fixture.example/ep2.jpg")!
        ]
        let urls = AppleArtworkPrefetchPolicy.urls(forDetail: item, episodeThumbnails: episodes)
        #expect(urls == [
            URL(string: "https://fixture.example/ep1.jpg")!,
            URL(string: "https://fixture.example/ep2.jpg")!
        ])
    }

    @Test("limit: 0 excludes every episode thumbnail but keeps the item's own art")
    func detailLimitZeroExcludesAllEpisodesButKeepsArt() {
        let item = makeItem(id: "1", poster: "https://fixture.example/poster1.jpg", background: "https://fixture.example/bg1.jpg")
        let episodes = [URL(string: "https://fixture.example/ep1.jpg")!]
        let urls = AppleArtworkPrefetchPolicy.urls(forDetail: item, episodeThumbnails: episodes, limit: 0)
        #expect(urls == [
            URL(string: "https://fixture.example/bg1.jpg")!,
            URL(string: "https://fixture.example/poster1.jpg")!
        ])
    }

    /// The limit counts the first episodes on screen, not unique images: an
    /// episode whose thumbnail is already the item's art is simply loaded,
    /// and an episode past the limit is not on screen yet, so it waits.
    @Test("The limit counts episodes shown, so a duplicate thumbnail does not pull in a later episode")
    func detailLimitCountsEpisodesShown() {
        let item = makeItem(id: "1", poster: "https://fixture.example/poster1.jpg")
        let episodes = [
            URL(string: "https://fixture.example/poster1.jpg")!, // episode 1 reuses the item's poster
            URL(string: "https://fixture.example/ep2.jpg")!,
        ]
        let urls = AppleArtworkPrefetchPolicy.urls(forDetail: item, episodeThumbnails: episodes, limit: 1)
        #expect(urls == [URL(string: "https://fixture.example/poster1.jpg")!])
    }
}
