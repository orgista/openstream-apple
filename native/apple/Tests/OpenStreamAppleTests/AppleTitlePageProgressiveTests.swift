import Foundation
import CoreGraphics
import Testing
@testable import OpenStreamApple


@Suite("Cached title header artwork")
struct AppleCachedTitleHeaderTests {
    private func image(_ dimension: Int) -> CGImage {
        CGContext(data: nil, width: dimension, height: dimension, bitsPerComponent: 8,
            bytesPerRow: dimension * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
    }

    @Test func shelfBitmapIsAvailableForTheFirstHeaderFrameAtAnotherDecodeSize() async throws {
        let calls = HeaderCacheCalls()
        let cache = AppleRemoteImageCache(loader: { _, dimension in
            await calls.record()
            return image(dimension)
        })
        let url = URL(string: "https://fixture.example/art/poster.jpg")!
        let shelf = try await cache.image(url: url, maximumPixelDimension: 320)
        #expect(cache.cachedImage(url: url, maximumPixelDimension: 1_280) == nil)
        let placeholder = try #require(cache.cachedPlaceholderImage(url: url))
        #expect(placeholder === shelf)
        #expect(await calls.count == 1)
        let header = try await cache.image(url: url, maximumPixelDimension: 1_280)
        #expect(cache.cachedPlaceholderImage(url: url) === header)
        #expect(await calls.count == 2)
        cache.removeAllCached()
        #expect(cache.cachedPlaceholderImage(url: url) == nil)
    }

    @Test func cachedPosterShowsWhileBetterBackdropIsUncachedThenBackdropWins() async throws {
        let calls = HeaderCacheCalls()
        let cache = AppleRemoteImageCache(loader: { _, dimension in
            await calls.record()
            return image(dimension)
        })
        let poster = URL(string: "https://fixture.example/art/poster.jpg")!
        let backdrop = URL(string: "https://fixture.example/art/backdrop.jpg")!
        let decodedPoster = try await cache.image(url: poster, maximumPixelDimension: 320)
        let first = try #require(AppleTitlePageSlotArt.chooseCached(backdrops: [backdrop], posters: [poster],
            cachedImage: { cache.cachedPlaceholderImage(url: $0) }))
        #expect(first.art == .posterCard(poster))
        #expect(first.image === decodedPoster)
        #expect(await calls.count == 1)
        let decodedBackdrop = try await cache.image(url: backdrop, maximumPixelDimension: 640)
        let later = try #require(AppleTitlePageSlotArt.chooseCached(backdrops: [backdrop], posters: [poster],
            cachedImage: { cache.cachedPlaceholderImage(url: $0) }))
        #expect(later.art == .backdrop(backdrop))
        #expect(later.image === decodedBackdrop)
        #expect(await calls.count == 2)
    }
}

private actor HeaderCacheCalls {
    var count = 0
    func record() { count += 1 }
}
