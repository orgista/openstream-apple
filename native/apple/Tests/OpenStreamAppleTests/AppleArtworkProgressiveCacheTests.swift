import CoreGraphics
import Foundation
import Testing
@testable import OpenStreamApple

@Suite("Progressive artwork cache")
struct AppleArtworkProgressiveCacheTests {
    @Test func sizeBucketsRoundUpAndClamp() {
        #expect(AppleArtworkSizePolicy.bucket(-1) == 64)
        #expect(AppleArtworkSizePolicy.bucket(384) == 384)
        #expect(AppleArtworkSizePolicy.bucket(385) == 512)
        #expect(AppleArtworkSizePolicy.bucket(3840) == 3840)
        #expect(AppleArtworkSizePolicy.bucket(5120) == 5120)
        #expect(AppleArtworkSizePolicy.bucket(100_000) == 8192)
        #expect(AppleArtworkSizePolicy.bucket(size: CGSize(width: 148, height: 222), scale: 3) == 768)
        #expect(AppleArtworkSizePolicy.displayVariant(385) == AppleArtworkSizePolicy.displayVariant(500))
    }

    @Test func placeholderSelectsLargestSizeAndDoesNotRetainEvictedImages() async throws {
        let url = try #require(URL(string: "https://fixture.example/poster.png"))
        let other = try #require(URL(string: "https://fixture.example/other.png"))
        let cache = AppleRemoteImageCache { _, pixels in try Self.image(width: pixels, height: pixels) }
        #expect(cache.cachedPlaceholderImage(url: url) == nil)
        _ = try await cache.image(url: url, maximumPixelDimension: 500)
        _ = try await cache.image(url: url, maximumPixelDimension: 100)
        #expect(cache.cachedPlaceholderImage(url: url)?.width == 512)
        #expect(cache.cachedImage(url: url, maximumPixelDimension: 385)?.width == 512)
        #expect(cache.cachedImage(url: url, maximumPixelDimension: 700) == nil)
        #expect(cache.cachedPlaceholderImage(url: other) == nil)
        _ = try await cache.image(url: url, maximumPixelDimension: 700)
        #expect(cache.cachedPlaceholderImage(url: url)?.width == 768)
        cache.removeAllCached()
        #expect(cache.cachedPlaceholderImage(url: url) == nil)
    }

    @Test @MainActor func firstBodyUsesMemoryArtAndRecycledCardsNeverShowThePreviousTitle() async throws {
        let first = try #require(URL(string: "https://fixture.example/first.png"))
        let second = try #require(URL(string: "https://fixture.example/second.png"))
        let cache = AppleRemoteImageCache { _, _ in try Self.image(width: 128, height: 64) }
        _ = try await cache.image(url: first, maximumPixelDimension: 128)
        var state = AppleRemoteImageState()
        #expect(state.displayedImage(url: first, identity: "first", maximumPixelDimension: 128,
            keepsImageWhileReloading: false, cache: cache) != nil)
        #expect(state.displayedImage(url: first, identity: "larger", maximumPixelDimension: 512,
            keepsImageWhileReloading: false, cache: cache) != nil)
        let restored = state.restore(url: first, identity: "first", maximumPixelDimension: 128, cache: cache, onLoad: nil)
        #expect(restored)
        #expect(state.displayedImage(url: second, identity: "second", maximumPixelDimension: 128,
            keepsImageWhileReloading: false, cache: cache) == nil)
        #expect(state.displayedImage(url: second, identity: "second", maximumPixelDimension: 128,
            keepsImageWhileReloading: true, cache: cache) != nil)
    }

    @Test @MainActor func memoryHitsAndRecycledRowsReportTheirImageWithoutSuspending() async throws {
        let first = try #require(URL(string: "https://fixture.example/first-logo.png"))
        let second = try #require(URL(string: "https://fixture.example/second-logo.png"))
        let missing = try #require(URL(string: "https://fixture.example/missing-logo.png"))
        let cache = AppleRemoteImageCache { url, _ in
            try Self.image(width: url == first ? 64 : 128, height: 64)
        }
        _ = try await cache.image(url: first, maximumPixelDimension: 128)
        _ = try await cache.image(url: second, maximumPixelDimension: 128)
        var state = AppleRemoteImageState()
        var delivered: [Int] = []
        for (url, width) in [(first, 64), (first, 64), (second, 128), (first, 64)] {
            let before = delivered.count
            let restored = state.restore(url: url, identity: url.absoluteString, maximumPixelDimension: 128,
                cache: cache, onLoad: { delivered.append($0.width) })
            #expect(restored)
            #expect(delivered.count == before + 1)
            #expect(delivered.last == width)
            #expect(state.image?.width == width)
            #expect(state.url == url)
            #expect(!state.failed)
        }
        let restoredMissing = state.restore(url: missing, identity: missing.absoluteString, maximumPixelDimension: 128,
            cache: cache, onLoad: { delivered.append($0.width) })
        #expect(!restoredMissing)
        #expect(delivered == [64, 64, 128, 64])
        cache.removeAllCached()
        let restoredRetained = state.restore(url: first, identity: first.absoluteString, maximumPixelDimension: 128,
            cache: cache, onLoad: { delivered.append($0.width) })
        #expect(restoredRetained)
        #expect(delivered == [64, 64, 128, 64, 64])
    }

    @Test func averageColourSidecarSurvivesReopeningAndRejectsTruncatedData() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try #require(URL(string: "https://fixture.example/poster.png"))
        let cache = AppleArtworkDiskCache(directory: directory)
        #expect(await cache.colour(for: url) == nil)
        let image = try Self.image(width: 32, height: 48)
        let colour = try #require(AppleRemoteImageDecoder.averageColour(image))
        #expect(colour.red == 255)
        #expect(colour.green == 0)
        #expect(colour.blue == 0)
        await cache.storeColour(colour, for: url)
        let reopened = AppleArtworkDiskCache(directory: directory)
        #expect(await reopened.colour(for: url) == colour)
        await cache.store(Data([1, 2]), for: url, variant: "colour")
        #expect(await AppleArtworkDiskCache(directory: directory).colour(for: url) == nil)
    }

    @Test func displayVariantRoundTripPreservesSizeAndAlpha() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try #require(URL(string: "https://fixture.example/logo.png"))
        let image = try Self.image(width: 64, height: 96, alpha: 0.5)
        let encoded = try #require(AppleRemoteImageDecoder.displayData(image))
        let cache = AppleArtworkDiskCache(directory: directory)
        let variant = AppleArtworkSizePolicy.displayVariant(100)
        await cache.store(encoded, for: url, variant: variant)
        let reopened = AppleArtworkDiskCache(directory: directory)
        let stored = try #require(await reopened.data(for: url, variant: variant))
        let decoded = try #require(AppleRemoteImageDecoder.displayImage(data: stored))
        #expect(decoded.width == 64)
        #expect(decoded.height == 96)
        #expect(AppleTransparentPNGLogoValidator.hasTransparentEdges(in: decoded))
        #expect(await reopened.data(for: url, variant: AppleArtworkSizePolicy.displayVariant(500)) == nil)
    }

    @Test func prefetchSelectsOnlyNextRowAndMatchesTileRequest() throws {
        let items = (0..<30).map { index in
            AppleCatalogItem(mediaID: "movie-\(index)", type: "movie", name: "Fixture",
                posterURL: URL(string: "https://image.tmdb.org/t/p/w500/fixture-\(index).jpg"))
        }
        let pixels = CGSize(width: 444, height: 666)
        let firstPaint = AppleArtworkPrefetchPolicy.requests(items: items, pixels: pixels, landscape: false)
        #expect(firstPaint.count == 20)
        let expected = AppleCatalogArtworkPolicy.displayRequest(url: items[0].posterURL, pixels: pixels, purpose: .poster)
        #expect(firstPaint.first?.url == expected.url)
        let expectedPixels = try #require(expected.fixedPixelDimension)
        #expect(firstPaint.first?.maximumPixelDimension == AppleArtworkSizePolicy.bucket(expectedPixels))
        let ahead = AppleArtworkPrefetchPolicy.requests(items: items, pixels: pixels, landscape: false, after: items[5].id)
        #expect(ahead.count == 20)
        #expect(ahead.first?.url.lastPathComponent == "fixture-6.jpg")
        #expect(AppleArtworkPrefetchPolicy.requests(items: [items[0], items[0]], pixels: pixels, landscape: false).count == 1)
    }

    @Test func prefetchOfUnsizedArtworkMatchesTileBucket() {
        let width = AppleCatalogCard.width(sizing: .catalog, rowStyle: .phone, scaledCardWidth: 140,
                                           viewportWidth: 390, regularWidth: false)
        #expect(width == AppleDiscoverRowStyle.phone.posterWidth)
        #expect(AppleCatalogCard.width(sizing: .portraitPromo, rowStyle: .phone, scaledCardWidth: 140,
                                       viewportWidth: 390, regularWidth: false) == 200)
        let tile = CGSize(width: width, height: AppleCatalogCard.height(sizing: .catalog, width: width))
        let scale: CGFloat = 3
        let pixels = CGSize(width: (tile.width * scale).rounded(.up), height: (tile.height * scale).rounded(.up))
        let items = (0..<3).map { index in
            AppleCatalogItem(mediaID: "movie-\(index)", type: "movie", name: "Fixture",
                posterURL: URL(string: "https://fixture.example/poster-\(index).png"))
        }
        let requests = AppleArtworkPrefetchPolicy.requests(items: items, pixels: pixels, landscape: false)
        #expect(requests.count == 3)
        #expect(requests.first?.url == items[0].posterURL)
        #expect(requests.first?.maximumPixelDimension == AppleArtworkSizePolicy.bucket(size: tile, scale: scale))
    }

    @Test func prefetchWarmsDecodedBucket() async throws {
        let url = try #require(URL(string: "https://fixture.example/poster.png"))
        let cache = AppleRemoteImageCache { _, pixels in try Self.image(width: pixels, height: pixels) }
        let request = AppleArtworkPrefetchPolicy.Request(url: url, maximumPixelDimension: AppleArtworkSizePolicy.bucket(385))
        await cache.prefetch([request, request])
        #expect(cache.cachedImage(url: url, maximumPixelDimension: 500)?.width == 512)
    }

    @Test func evictionAccountsForRawDisplayAndColourEntries() {
        let entries = [
            (name: "raw", bytes: 100, modified: Date(timeIntervalSince1970: 0)),
            (name: "display-512", bytes: 50, modified: Date(timeIntervalSince1970: 1)),
            (name: "colour", bytes: 3, modified: Date(timeIntervalSince1970: 2))
        ]
        #expect(AppleArtworkDiskCachePolicy.evictionOrder(entries, limit: 52) == ["raw", "display-512"])
    }

    @Test func storeAfterTrimDoesNotTrimAgain() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cache = AppleArtworkDiskCache(directory: directory, maximumBytes: 1_000)
        await cache.trimIfNeeded()
        let urls = try (0..<12).map { try #require(URL(string: "https://fixture.example/poster-\($0).png")) }
        for url in urls.prefix(11) {
            await cache.store(Data(count: 100), for: url, variant: "raw")
        }
        await cache.trimIfNeeded()
        // 1,100 bytes is over the limit, so the trim frees down to 875.
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 8)
        await cache.store(Data(count: 100), for: urls[11], variant: "raw")
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 9)
    }

    @Test func jellyfinBackdropHasBoundedWidthAndImmutableTag() throws {
        let baseURL = try #require(URL(string: "https://fixture.example/jellyfin"))
        let session = AppleMediaServerSession(kind: .jellyfin, baseURL: baseURL, accessToken: "fixture", userID: "fixture")
        let client = AppleMediaServerClient()
        let url = try client.imageURL(session: session, itemID: "movie", type: .backdrop,
            tag: "image-version", maxWidth: AppleArtworkSizePolicy.backdropMaximumWidth)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.queryItems?.first { $0.name == "maxWidth" }?.value == "1920")
        #expect(components.queryItems?.first { $0.name == "tag" }?.value == "image-version")
        #expect(url.path.hasSuffix("Items/movie/Images/Backdrop"))
    }

    @Test @MainActor func jellyfinCatalogArtworkKeepsTagsAndBoundsBackdrop() throws {
        let suite = "artwork-tests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let baseURL = try #require(URL(string: "https://fixture.example/jellyfin"))
        let source = AppleSource(id: UUID(), kind: .mediaServer, name: "Fixture", url: baseURL, isEnabled: true)
        let session = AppleMediaServerSession(kind: .jellyfin, baseURL: baseURL, accessToken: "fixture", userID: "fixture")
        let store = AppleMediaServerLibraryStore(progressDefaults: defaults)
        let item = AppleMediaServerItem(id: "movie", name: "Fixture", type: .movie,
            primaryImageTag: "poster-version", backdropImageTags: ["backdrop-version"])
        let artwork = store.catalogItem(item, source: source, session: session)
        let backdropURL = try #require(artwork.backgroundURL)
        let backdrop = try #require(URLComponents(url: backdropURL, resolvingAgainstBaseURL: false))
        #expect(backdrop.queryItems?.first { $0.name == "maxWidth" }?.value == "1920")
        #expect(backdrop.queryItems?.first { $0.name == "tag" }?.value == "backdrop-version")
        let posterURL = try #require(artwork.posterURL)
        let poster = try #require(URLComponents(url: posterURL, resolvingAgainstBaseURL: false))
        #expect(poster.queryItems?.first { $0.name == "maxWidth" }?.value == "600")
        #expect(poster.queryItems?.first { $0.name == "tag" }?.value == "poster-version")
    }

    private static func image(width: Int, height: Int, alpha: CGFloat = 1) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: alpha)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }
}
