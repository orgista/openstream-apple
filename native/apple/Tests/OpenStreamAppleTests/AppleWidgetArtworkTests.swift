import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import OpenStreamApple

/// Owner's home screen, 2026-09-20: the widget drew "The Whisper Man" over a
/// blank grey square. `AsyncImage` cannot work inside a WidgetKit view — the
/// snapshot is captured before the fetch resolves — so the poster is now
/// downsampled in the timeline provider and carried on the entry. These cover
/// the pure half of that: the sizing, the decode, and the app-group cache.
@Suite("Widget poster artwork")
struct AppleWidgetArtworkTests {
    private func url(_ value: String) -> URL { URL(string: value)! }

    /// A synthetic poster, encoded the way a CDN would serve one.
    private func posterData(width: Int, height: Int) throws -> Data {
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 0.2, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let buffer = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            buffer, UTType.jpeg.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return buffer as Data
    }

    @Test func aFullSizePosterIsDownsampledToTheRequestedEdge() throws {
        let source = try posterData(width: 1_000, height: 1_500)
        let thumbnail = try #require(AppleWidgetArtworkThumbnail.thumbnail(from: source, pixelSize: 200))
        let size = try #require(AppleWidgetArtworkThumbnail.pixelSize(ofEncoded: thumbnail))
        #expect(max(size.width, size.height) <= 200)
        // Still a poster, not a postage stamp: the shape is preserved.
        #expect(size.height > size.width)
        #expect(thumbnail.count < source.count)
    }

    @Test func aPosterSmallerThanTheRequestedEdgeIsNotUpscaled() throws {
        let source = try posterData(width: 80, height: 120)
        let thumbnail = try #require(AppleWidgetArtworkThumbnail.thumbnail(from: source, pixelSize: 480))
        let size = try #require(AppleWidgetArtworkThumbnail.pixelSize(ofEncoded: thumbnail))
        #expect(max(size.width, size.height) <= 480)
    }

    @Test func bytesThatAreNotAnImageDecodeToNothing() {
        #expect(AppleWidgetArtworkThumbnail.thumbnail(from: Data("not a poster".utf8), pixelSize: 200) == nil)
        #expect(AppleWidgetArtworkThumbnail.thumbnail(from: Data(), pixelSize: 200) == nil)
    }

    @Test func aNonPositiveEdgeDecodesToNothing() throws {
        let source = try posterData(width: 100, height: 150)
        #expect(AppleWidgetArtworkThumbnail.thumbnail(from: source, pixelSize: 0) == nil)
    }

    /// A widget extension is killed at a low memory ceiling, so the decode is
    /// capped however large the widget or the display scale is.
    @Test func theDecodeSizeIsClampedAtBothEnds() {
        #expect(AppleWidgetArtworkPolicy.pixelSize(widthInPoints: 2_000, columns: 1, scale: 3)
            == AppleWidgetArtworkPolicy.ceilingPixels)
        #expect(AppleWidgetArtworkPolicy.pixelSize(widthInPoints: 4, columns: 1, scale: 1)
            == AppleWidgetArtworkPolicy.floorPixels)
        #expect(AppleWidgetArtworkPolicy.pixelSize(widthInPoints: 0, columns: 0, scale: 0)
            == AppleWidgetArtworkPolicy.floorPixels)
    }

    @Test func aRowOfPostersDecodesSmallerThanASinglePoster() {
        let small = AppleWidgetArtworkPolicy.pixelSize(widthInPoints: 158, columns: 1, scale: 2)
        let large = AppleWidgetArtworkPolicy.pixelSize(widthInPoints: 338, columns: 6, scale: 2)
        #expect(large < small)
    }

    @Test func theCacheNameIsStableAndSizeSpecific() {
        let poster = url("https://image.tmdb.org/t/p/w600/a.jpg")
        #expect(AppleWidgetArtworkPolicy.fileName(for: poster, pixelSize: 240)
            == AppleWidgetArtworkPolicy.fileName(for: poster, pixelSize: 240))
        #expect(AppleWidgetArtworkPolicy.fileName(for: poster, pixelSize: 240)
            != AppleWidgetArtworkPolicy.fileName(for: poster, pixelSize: 480))
        #expect(AppleWidgetArtworkPolicy.fileName(for: poster, pixelSize: 240)
            != AppleWidgetArtworkPolicy.fileName(for: url("https://image.tmdb.org/t/p/w600/b.jpg"), pixelSize: 240))
    }

    // MARK: - The store

    private func temporaryContainer() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "widget-artwork-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func aPosterIsFetchedOnceAndThenServedFromTheAppGroup() async throws {
        let root = try temporaryContainer()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try posterData(width: 600, height: 900)
        let fetches = Counter()
        let store = AppleWidgetArtworkStore(containerProvider: { root }, fetch: { _ in
            await fetches.increment()
            return source
        })

        let poster = url("https://image.tmdb.org/t/p/w600/a.jpg")
        let first = try #require(await store.thumbnail(for: poster, pixelSize: 240))
        let second = try #require(await store.thumbnail(for: poster, pixelSize: 240))
        #expect(first == second)
        #expect(await fetches.value == 1)

        let size = try #require(AppleWidgetArtworkThumbnail.pixelSize(ofEncoded: first))
        #expect(max(size.width, size.height) <= 240)
    }

    /// The widget is another process outside the app's sandbox, so it goes
    /// through the same gate Top Shelf and Spotlight do — and never fetches a
    /// URL that gate refuses.
    @Test func anArtworkURLTheSystemPolicyRefusesIsNeverFetched() async throws {
        let root = try temporaryContainer()
        defer { try? FileManager.default.removeItem(at: root) }
        let fetches = Counter()
        let store = AppleWidgetArtworkStore(containerProvider: { root }, fetch: { _ in
            await fetches.increment()
            return Data()
        })

        #expect(await store.thumbnail(for: url("http://cdn.example.com/a.jpg"), pixelSize: 240) == nil)
        #expect(await store.thumbnail(for: url("https://nas.local/a.jpg"), pixelSize: 240) == nil)
        #expect(await store.thumbnail(for: url("https://cdn.example.com/a.jpg?token=secret"), pixelSize: 240) == nil)
        #expect(await store.thumbnail(for: nil, pixelSize: 240) == nil)
        #expect(await fetches.value == 0)
    }

    @Test func anUnreachablePosterLeavesTheItemOutRatherThanFailingTheWidget() async throws {
        let root = try temporaryContainer()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try posterData(width: 600, height: 900)
        let store = AppleWidgetArtworkStore(containerProvider: { root }, fetch: { requested in
            guard requested.path.hasSuffix("good.jpg") else { throw URLError(.timedOut) }
            return source
        })

        let items = [
            item(id: "good", artwork: "https://cdn.example.com/good.jpg"),
            item(id: "bad", artwork: "https://cdn.example.com/bad.jpg"),
            item(id: "none", artwork: nil),
        ]
        let artwork = await store.thumbnails(for: items, pixelSize: 240)
        #expect(artwork.keys.sorted() == ["good"])
    }

    /// More items than the concurrency limit, so the throttle in `thumbnails`
    /// is exercised rather than assumed.
    @Test func everyItemInALargeWidgetGetsItsOwnPoster() async throws {
        let root = try temporaryContainer()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try posterData(width: 600, height: 900)
        let store = AppleWidgetArtworkStore(containerProvider: { root }, fetch: { _ in source })

        let items = (0 ..< 6).map { item(id: "item-\($0)", artwork: "https://cdn.example.com/\($0).jpg") }
        let artwork = await store.thumbnails(for: items, pixelSize: 120)
        #expect(artwork.count == 6)
        #expect(artwork.keys.sorted() == items.map(\.id).sorted())
    }

    @Test func aStoreWithNoAppGroupStillDrawsAPoster() async throws {
        let source = try posterData(width: 600, height: 900)
        let store = AppleWidgetArtworkStore(containerProvider: { nil }, fetch: { _ in source })
        #expect(await store.thumbnail(for: url("https://cdn.example.com/a.jpg"), pixelSize: 240) != nil)
    }

    private func item(id: String, artwork: String?) -> AppleTopShelfSnapshot.Item {
        AppleTopShelfSnapshot.Item(
            id: id,
            title: id,
            kind: "movie",
            artworkURL: artwork.flatMap { URL(string: $0) },
            displayURL: url("openstream://media/\(id)?action=display"),
            playURL: nil
        )
    }
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}
