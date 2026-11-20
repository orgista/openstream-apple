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

    @Test func heroArtworkIsBoundedBeforeTheWidgetReadsIt() async throws {
        let root = try temporaryContainer()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try posterData(width: 2_400, height: 1_350)
        let fetches = Counter()
        let store = AppleWidgetHeroArtworkStore(fetch: { _ in
            await fetches.increment()
            return source
        })
        let backdrop = url("https://fixture.example/backdrop.jpg")
        let first = await store.prepare(itemID: "hero", backdrop: backdrop, wordmark: nil, in: root)
        let data = try #require(AppleWidgetHeroArtworkStore.read(first.backdropFile, in: root))
        let size = try #require(AppleWidgetArtworkThumbnail.pixelSize(ofEncoded: data))
        #expect(size.width == 1_600)
        #expect(size.width > size.height)
        #expect(first.wordmarkFile == nil)
        let second = await store.prepare(itemID: "hero", backdrop: backdrop, wordmark: nil, in: root)
        #expect(first == second)
        #expect(await fetches.value == 1)
        let snapshot = AppleTopShelfSnapshot(version: 1, generatedAt: .now, continueWatching: [],
            recentlyAdded: [], favorites: [], widgetHero: first)
        let decoded = try JSONDecoder().decode(AppleTopShelfSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded.widgetHero == first)
        var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        legacy.removeValue(forKey: "widgetHero")
        let older = try JSONDecoder().decode(AppleTopShelfSnapshot.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(older.widgetHero == nil)
    }

    @Test func failedHeroFetchesAreRememberedUntilTheNextSession() async throws {
        let root = try temporaryContainer()
        defer { try? FileManager.default.removeItem(at: root) }
        let fetches = Counter()
        let store = AppleWidgetHeroArtworkStore(fetch: { _ in
            await fetches.increment()
            throw URLError(.timedOut)
        })
        let backdrop = url("https://fixture.example/missing.jpg")
        for id in ["first", "second"] {
            let hero = await store.prepare(itemID: id, backdrop: backdrop, wordmark: nil, in: root)
            #expect(hero.backdropFile == nil)
        }
        #expect(await fetches.value == 1)
        let nextSession = AppleWidgetHeroArtworkStore(fetch: { _ in
            await fetches.increment()
            throw URLError(.timedOut)
        })
        _ = await nextSession.prepare(itemID: "third", backdrop: backdrop, wordmark: nil, in: root)
        #expect(await fetches.value == 2)
    }

    @Test(arguments: [(0.25, 6_000.0, 75), (1.0 / 3.0, 3_600.0, 40), (0.99, 3_610.0, 1), (1.0, 600.0, 0)])
    func resumeCueUsesRemainingWholeMinutes(progress: Double, duration: Double, expected: Int) {
        let item = AppleTopShelfSnapshot.Item(id: "hero", title: "Hero", kind: "movie", artworkURL: nil,
            displayURL: url("openstream://media/hero"), playURL: nil, progress: progress, durationSeconds: duration)
        #expect(item.remainingMinutes == expected)
    }

    @Test(arguments: [(nil, 600.0), (0.5, nil), (Double.nan, 600.0), (-0.1, 600.0), (1.1, 600.0)] as [(Double?, Double?)])
    func unknownResumeTimeHasNoMinuteCue(progress: Double?, duration: Double?) {
        let item = AppleTopShelfSnapshot.Item(id: "hero", title: "Hero", kind: "movie", artworkURL: nil,
            displayURL: url("openstream://media/hero"), playURL: nil, progress: progress, durationSeconds: duration)
        #expect(item.remainingMinutes == nil)
    }

    @Test func opaqueArtworkIsNeverUsedAsAWordmark() throws {
        let source = try posterData(width: 600, height: 300)
        #expect(AppleWidgetArtworkThumbnail.thumbnail(from: source, pixelSize: 600, isWordmark: true) == nil)
    }

    @Test func heroWordmarksKeepTheirTransparentPixels() async throws {
        let root = try temporaryContainer()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = try #require(CGContext(data: nil, width: 1_200, height: 300, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 100, y: 100, width: 300, height: 100))
        let buffer = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(buffer, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        let source = buffer as Data
        let store = AppleWidgetHeroArtworkStore(fetch: { _ in source })
        let hero = await store.prepare(itemID: "hero", backdrop: nil,
            wordmark: url("https://fixture.example/transparent.png"), in: root)
        let encoded = try #require(AppleWidgetHeroArtworkStore.read(hero.wordmarkFile, in: root))
        let size = try #require(AppleWidgetArtworkThumbnail.pixelSize(ofEncoded: encoded))
        #expect(max(size.width, size.height) <= AppleWidgetHeroArtworkStore.wordmarkPixels)
        let imageSource = try #require(CGImageSourceCreateWithData(encoded as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        #expect([CGImageAlphaInfo.premultipliedLast, .premultipliedFirst, .last, .first].contains(image.alphaInfo))
    }

    @Test func missingAndUnsafeHeroArtFallsBackWithoutFetching() async throws {
        let root = try temporaryContainer()
        defer { try? FileManager.default.removeItem(at: root) }
        let fetches = Counter()
        let store = AppleWidgetHeroArtworkStore(fetch: { _ in
            await fetches.increment()
            throw URLError(.timedOut)
        })
        let hero = await store.prepare(itemID: "hero", backdrop: url("http://fixture.example/art.jpg"),
            wordmark: nil, in: root)
        #expect(hero.backdropFile == nil)
        #expect(hero.wordmarkFile == nil)
        #expect(await fetches.value == 0)
        #expect(AppleWidgetHeroArtworkStore.read("../outside.png", in: root) == nil)
    }

    @Test func replacingHeroArtEvictsThePreviousTitle() async throws {
        let root = try temporaryContainer()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try posterData(width: 100, height: 60)
        let store = AppleWidgetHeroArtworkStore(fetch: { _ in source })
        let previous = await store.prepare(itemID: "old", backdrop: url("https://fixture.example/old.jpg"),
            wordmark: nil, in: root)
        let current = await store.prepare(itemID: "new", backdrop: url("https://fixture.example/new.jpg"),
            wordmark: nil, in: root)
        store.removeUnused(in: root, keeping: current)
        #expect(AppleWidgetHeroArtworkStore.read(previous.backdropFile, in: root) == nil)
        #expect(AppleWidgetHeroArtworkStore.read(current.backdropFile, in: root) != nil)
        AppleWidgetHeroArtworkStore.removeAll(in: root)
        #expect(AppleWidgetHeroArtworkStore.read(current.backdropFile, in: root) == nil)
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
