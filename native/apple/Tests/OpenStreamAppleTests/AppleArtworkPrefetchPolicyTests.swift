import Foundation
import Testing
@testable import OpenStreamApple

@Suite("AppleArtworkPrefetchPolicy")
struct AppleArtworkPrefetchPolicyTests {
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

    @Test("Section cap, ordering, nils skipped, duplicates removed (first position kept)")
    func sectionPrefetching() {
        let item1 = makeItem(id: "1", poster: "https://a.test/poster1.jpg", background: "https://a.test/bg1.jpg")
        let item2 = makeItem(id: "2", poster: "https://a.test/poster2.jpg", background: nil)
        let item3 = makeItem(id: "3", poster: nil, background: "https://a.test/bg3.jpg")
        let item4 = makeItem(id: "4", poster: "https://a.test/poster4.jpg", background: "https://a.test/bg1.jpg") // bg1 is duplicate of item1

        let sections = [
            [item1, item2],
            [item3, item4]
        ]

        let urls = AppleArtworkPrefetchPolicy.urls(sections: sections, perSection: 1)
        // perSection = 1 means only item1 from section 0, and item3 from section 1.
        // item1 -> poster1, bg1
        // item3 -> bg3 (poster is nil)
        #expect(urls == [
            URL(string: "https://a.test/poster1.jpg")!,
            URL(string: "https://a.test/bg1.jpg")!,
            URL(string: "https://a.test/bg3.jpg")!
        ])

        let allUrls = AppleArtworkPrefetchPolicy.urls(sections: sections, perSection: 2)
        // perSection = 2 means item1, item2, item3, item4
        // item1 -> poster1, bg1
        // item2 -> poster2
        // item3 -> bg3
        // item4 -> poster4, bg1 (bg1 is duplicate, so skipped)
        #expect(allUrls == [
            URL(string: "https://a.test/poster1.jpg")!,
            URL(string: "https://a.test/bg1.jpg")!,
            URL(string: "https://a.test/poster2.jpg")!,
            URL(string: "https://a.test/bg3.jpg")!,
            URL(string: "https://a.test/poster4.jpg")!
        ])
    }

    @Test("Detail ordering and episode cap, de-duplication")
    func detailPrefetching() {
        let item = makeItem(id: "1", poster: "https://a.test/poster1.jpg", background: "https://a.test/bg1.jpg")
        let episodes = [
            URL(string: "https://a.test/ep1.jpg")!,
            URL(string: "https://a.test/bg1.jpg")!, // duplicate of background
            URL(string: "https://a.test/ep3.jpg")!,
            URL(string: "https://a.test/ep4.jpg")!
        ]

        let urls = AppleArtworkPrefetchPolicy.urls(forDetail: item, episodeThumbnails: episodes, limit: 2)
        // detail order: background, poster (no logo available on item)
        // then episodes up to limit (2).
        // episodes to consider: ep1, bg1
        // but bg1 is a duplicate, so only ep1 is appended from the first two elements.
        // Wait, the limit is applied BEFORE de-duplication according to the policy implementation.
        // Let's check: episodeThumbnails.prefix(limit) is [ep1, bg1].
        // bg1 is a duplicate, so skipped. Result: bg1, poster1, ep1.
        #expect(urls == [
            URL(string: "https://a.test/bg1.jpg")!,
            URL(string: "https://a.test/poster1.jpg")!,
            URL(string: "https://a.test/ep1.jpg")!
        ])
    }
}
