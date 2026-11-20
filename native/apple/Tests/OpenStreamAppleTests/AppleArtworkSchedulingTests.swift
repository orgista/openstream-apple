import CoreGraphics
import Foundation
import Synchronization
import Testing
@testable import OpenStreamApple

@Suite("Discover artwork scheduling", .timeLimit(.minutes(1)))
struct AppleArtworkSchedulingTests {
    @Test func tmdbVariantsStayWithinCardsAndBoundHeroes() {
        #expect(AppleArtworkResolver.Purpose.poster.size(pixelWidth: 140 * 3) == "w342")
        #expect(AppleArtworkResolver.Purpose.poster.size(pixelWidth: 230) == "w185")
        #expect(AppleArtworkResolver.Purpose.hero.size(pixelWidth: 1920) == "w1280")
        #expect(AppleArtworkResolver.Purpose.hero.size(pixelWidth: 3840) == "w1280")
        #expect(AppleArtworkResolver.Purpose.poster.size(pixelWidth: .infinity) == "w92")
        #expect(AppleArtworkResolver.Purpose.poster.size(pixelWidth: 343) == "w342")
        #expect(AppleArtworkResolver.Purpose.poster.size(pixelWidth: 421) == "w342")
        #expect(AppleArtworkResolver.Purpose.poster.size(pixelWidth: 501) == "w500")
        #expect(AppleArtworkResolver.Purpose.poster.size(pixelWidth: 10_000) == "w780")
        #expect(AppleArtworkResolver.Purpose.resume.size(pixelWidth: 3840) == "w1280")
        #expect(AppleArtworkResolver.Purpose.poster.size(pixelWidth: 500) == "w500")
    }

    @Test func invalidRailPitchDoesNotProduceAnIndex() {
        for pitch in [CGFloat(0), -1, .nan, .infinity] {
            #expect(AppleArtworkPrefetchPolicy.firstIndex(offset: 400, pitch: pitch) == 0)
        }
        #expect(AppleArtworkPrefetchPolicy.firstIndex(offset: .nan, pitch: 254) == 0)
        #expect(AppleArtworkPrefetchPolicy.firstIndex(offset: 508, pitch: 254) == 2)
    }

    @Test func logoDiskEncodingPreservesClearAndPartialAlpha() throws {
        let context = try #require(CGContext(data: nil, width: 3, height: 1, bitsPerComponent: 8,
            bytesPerRow: 12, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.5))
        context.fill(CGRect(x: 1, y: 0, width: 1, height: 1))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 2, y: 0, width: 1, height: 1))
        let image = try #require(context.makeImage())
        let encoded = try #require(AppleRemoteImageDecoder.displayData(image))
        #expect(Array(encoded.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10])
        let decoded = try #require(AppleRemoteImageDecoder.displayImage(data: encoded))
        context.clear(CGRect(x: 0, y: 0, width: 3, height: 1))
        context.draw(decoded, in: CGRect(x: 0, y: 0, width: 3, height: 1))
        let bytes = try #require(context.data?.assumingMemoryBound(to: UInt8.self))
        #expect(bytes[3] == 0)
        #expect((127...128).contains(bytes[7]))
        #expect(bytes[11] == 255)
    }

    @Test func visibleRequestsOvertakePrefetchAndPromoteSharedKeys() {
        var queue = AppleArtworkRequestQueue()
        queue.enqueue("next-screen-1", priority: .prefetch)
        queue.enqueue("next-screen-2", priority: .prefetch)
        queue.enqueue("visible", priority: .visible)
        #expect(queue.next(prefetchAllowed: false) == "visible")
        #expect(queue.next(prefetchAllowed: false) == nil)
        queue.enqueue("next-screen-2", priority: .visible)
        #expect(queue.next(prefetchAllowed: false) == "next-screen-2")
        #expect(queue.next(prefetchAllowed: true) == "next-screen-1")
        #expect(queue.next(prefetchAllowed: true) == nil)
    }

    @Test func foregroundArtStartsFirstEvenWhenTheLoadLimitIsFull() {
        var queue = AppleArtworkRequestQueue()
        queue.enqueue("row", priority: .prefetch)
        queue.enqueue("tile", priority: .visible)
        queue.enqueue("title", priority: .foreground)
        #expect(queue.next(prefetchAllowed: true, visibleAllowed: false) == "title")
        #expect(queue.next(prefetchAllowed: true, visibleAllowed: false) == nil)
        queue.enqueue("row", priority: .foreground)
        #expect(queue.next(prefetchAllowed: false, visibleAllowed: false) == "row")
        #expect(queue.next(prefetchAllowed: false) == "tile")
    }

    @Test func trimmedLogosAreReadFromMemory() throws {
        let cache = AppleRemoteImageCache()
        let url = try #require(URL(string: "https://fixture.example/logo-\(UUID().uuidString).png"))
        let context = try #require(CGContext(data: nil, width: 4, height: 2, bitsPerComponent: 8, bytesPerRow: 16,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        #expect(cache.cachedTrimmedLogo(url: url) == nil)
        cache.storeTrimmedLogo(image, url: url)
        #expect(cache.cachedTrimmedLogo(url: url) === image)
        #expect(cache.cachedPlaceholderImage(url: url) == nil, "a trimmed logo is not a display-size variant")
    }

    @Test func cancelledQueuedWorkNeverStarts() {
        var queue = AppleArtworkRequestQueue()
        queue.enqueue("offscreen", priority: .visible)
        queue.enqueue("next-screen", priority: .prefetch)
        queue.cancel("offscreen")
        queue.cancel("next-screen")
        #expect(queue.next(prefetchAllowed: true) == nil)
        queue.enqueue("offscreen", priority: .visible)
        #expect(queue.next(prefetchAllowed: false) == "offscreen")
    }

    @Test func cacheKeysSeparateVersionsAndShareDecodeBuckets() throws {
        let first = try #require(URL(string: "https://fixture.example/poster.jpg?version=1"))
        let changed = try #require(URL(string: "https://fixture.example/poster.jpg?version=2"))
        #expect(AppleRemoteImageCache.key(url: first, maximumPixelDimension: 385)
            == AppleRemoteImageCache.key(url: first, maximumPixelDimension: 500))
        #expect(AppleRemoteImageCache.key(url: first, maximumPixelDimension: 256)
            != AppleRemoteImageCache.key(url: first, maximumPixelDimension: 500))
        #expect(AppleRemoteImageCache.key(url: first, maximumPixelDimension: 500)
            != AppleRemoteImageCache.key(url: changed, maximumPixelDimension: 500))
        #expect(AppleArtworkDiskCachePolicy.fileName(for: first, variant: "raw")
            != AppleArtworkDiskCachePolicy.fileName(for: changed, variant: "raw"))
    }

    @Test func prefetchWindowUsesOneScreenAndTheTileVariant() {
        #expect(AppleArtworkPrefetchPolicy.screenCount(viewportWidth: 1760, cardWidth: 230, gap: 24) == 7)
        #expect(AppleArtworkPrefetchPolicy.screenCount(viewportWidth: 358, cardWidth: 148, gap: 8) == 3)
        #expect(AppleArtworkPrefetchPolicy.screenCount(viewportWidth: 0, cardWidth: 148, gap: 8) == 0)
        let items = (0..<30).map { index in
            AppleCatalogItem(mediaID: "movie-\(index)", type: "movie", name: "Fixture",
                posterURL: URL(string: "https://image.tmdb.org/t/p/w500/poster-\(index).jpg"))
        }
        let pixels = CGSize(width: 460, height: 690)
        let requests = AppleArtworkPrefetchPolicy.requests(items: items, pixels: pixels, landscape: false,
            after: items[6].id, limit: 7)
        #expect(requests.count == 7)
        let tile = AppleCatalogArtworkPolicy.displayRequest(url: items[7].posterURL, pixels: pixels, purpose: .poster)
        #expect(requests.first?.url == tile.url)
        #expect(requests.first?.maximumPixelDimension == tile.fixedPixelDimension.map(AppleArtworkSizePolicy.bucket))
    }

    @Test(arguments: [
        (AppleCatalogCardSizing.catalog, "poster", "w185", 384),
        (AppleCatalogCardSizing.portraitPromo, "poster", "w342", 768),
        (AppleCatalogCardSizing.featured, "still", "w300", 384),
    ])
    func homeShelfPrefetchMatchesRenderedArtwork(
        sizing: AppleCatalogCardSizing, asset: String, variant: String, decodePixels: Int
    ) throws {
        let items = (0..<6).map { index in
            AppleCatalogItem(mediaID: "fixture-\(index)", type: "movie", name: "Fixture \(index)",
                posterURL: URL(string: "https://image.tmdb.org/t/p/w500/poster-\(index).jpg"),
                backgroundURL: URL(string: "https://image.tmdb.org/t/p/w1280/still-\(index).jpg"))
        }
        let width = AppleCatalogCard.width(sizing: sizing, rowStyle: .phone, scaledCardWidth: 140,
            viewportWidth: 390, regularWidth: false)
        let pixels = CGSize(width: width * 2, height: AppleCatalogCard.height(sizing: sizing, width: width) * 2)
        let landscape = AppleCatalogCard.isLandscape(sizing)
        let requests = AppleArtworkPrefetchPolicy.requests(items: items, pixels: pixels, landscape: landscape, limit: 2)
        let expectedURLs = try (0..<2).map {
            try #require(URL(string: "https://image.tmdb.org/t/p/\(variant)/\(asset)-\($0).jpg"))
        }
        #expect(requests.map(\.url) == expectedURLs)
        #expect(requests.map(\.maximumPixelDimension) == [decodePixels, decodePixels])
        let request = try #require(requests.first)
        let rendered = AppleCatalogArtworkPolicy.displayRequest(
            url: landscape ? items[0].backgroundURL : items[0].posterURL, pixels: pixels,
            purpose: landscape ? .resume : .poster)
        #expect(request.url == rendered.url)
        #expect(request.maximumPixelDimension == rendered.fixedPixelDimension.map(AppleArtworkSizePolicy.bucket))
    }

    @Test func disappearingLastConsumerCancelsTheLoader() async throws {
        let probe = ArtworkLoaderProbe()
        let cache = AppleRemoteImageCache(maximumConcurrentLoads: 1, loader: { _, _ in
            try await probe.load()
        })
        let url = try #require(URL(string: "https://fixture.example/offscreen.jpg"))
        let task = Task { try await cache.image(url: url, maximumPixelDimension: 256) }
        await probe.waitForStart()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        await probe.waitForCancellation()
        #expect(cache.cachedImage(url: url, maximumPixelDimension: 256) == nil)
    }

    @Test func imageLoadsStayWithinTheGlobalConcurrencyLimit() async throws {
        let context = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8,
            bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let probe = BoundedArtworkProbe(image: image)
        let cache = AppleRemoteImageCache(maximumConcurrentLoads: 2, loader: { _, _ in
            await probe.load()
        })
        let urls = try (0..<10).map { try #require(URL(string: "https://fixture.example/poster-\($0).jpg")) }
        let tasks = urls.map { url in Task { try await cache.image(url: url, maximumPixelDimension: 256) } }
        for count in stride(from: 2, through: 10, by: 2) {
            await probe.waitForStarts(count)
            await probe.releaseStarted()
        }
        for task in tasks { _ = try await task.value }
        #expect(await probe.peak == 2)
        #expect(await probe.started == 10)
    }

    @Test func realCacheCapsPrefetchAndStartsVisibleBeforeQueuedPrefetch() async throws {
        let probe = try ControlledArtworkProbe()
        let cache = AppleRemoteImageCache(maximumConcurrentLoads: 3, maximumConcurrentPrefetchLoads: 2,
            loader: { url, _ in try await probe.load(url) })
        let urls = try (0..<5).map { try #require(URL(string: "https://fixture.example/scheduled-\($0).png")) }
        let first = Task { try await cache.image(url: urls[0], maximumPixelDimension: 256, priority: .prefetch) }
        let second = Task { try await cache.image(url: urls[1], maximumPixelDimension: 256, priority: .prefetch) }
        await probe.waitForStarts(2)
        let queued = Task { try await cache.image(url: urls[2], maximumPixelDimension: 256, priority: .prefetch) }
        while await cache.pendingRequestCount < 3 { await Task.yield() }
        #expect(await probe.started.count == 2)
        let visible = Task { try await cache.image(url: urls[3], maximumPixelDimension: 256) }
        await probe.waitForStarts(3)
        #expect(await probe.started[2] == urls[3])
        let nextVisible = Task { try await cache.image(url: urls[4], maximumPixelDimension: 256) }
        while await cache.pendingRequestCount < 5 { await Task.yield() }
        await probe.release(urls[0])
        await probe.waitForStarts(4)
        #expect(await probe.started[3] == urls[4])
        await probe.release(urls[1])
        await probe.waitForStarts(5)
        #expect(await probe.started[4] == urls[2])
        for url in urls.dropFirst(2) { await probe.release(url) }
        for task in [first, second, queued, visible, nextVisible] { _ = try await task.value }
    }

    @Test func cancellingOneOfTwoWaitersKeepsTheSharedLoadAlive() async throws {
        let probe = try ControlledArtworkProbe()
        let cache = AppleRemoteImageCache(loader: { url, _ in try await probe.load(url) })
        let url = try #require(URL(string: "https://fixture.example/shared.png"))
        let first = Task { try await cache.image(url: url, maximumPixelDimension: 256) }
        await probe.waitForStarts(1)
        let second = Task { try await cache.image(url: url, maximumPixelDimension: 256) }
        while await cache.waiterCount < 2 { await Task.yield() }
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(await probe.cancelled.isEmpty)
        await probe.release(url)
        _ = try await second.value
        #expect(await probe.started == [url])
        #expect(cache.cachedImage(url: url, maximumPixelDimension: 256) != nil)
    }

    @Test func cancelledRunningVisibleLoadFreesItsSlot() async throws {
        let probe = try ControlledArtworkProbe()
        let cache = AppleRemoteImageCache(maximumConcurrentLoads: 1,
            loader: { url, _ in try await probe.load(url) })
        let firstURL = try #require(URL(string: "https://fixture.example/leaving.png"))
        let nextURL = try #require(URL(string: "https://fixture.example/entering.png"))
        let first = Task { try await cache.image(url: firstURL, maximumPixelDimension: 256) }
        await probe.waitForStarts(1)
        let next = Task { try await cache.image(url: nextURL, maximumPixelDimension: 256) }
        while await cache.pendingRequestCount < 2 { await Task.yield() }
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        await probe.waitForStarts(2)
        #expect(await probe.cancelled == [firstURL])
        await probe.release(nextURL)
        _ = try await next.value
    }

    @Test func scrollCancellationFinishesStartedPrefetchButRemovesQueuedPrefetch() async throws {
        let probe = try ControlledArtworkProbe()
        let cache = AppleRemoteImageCache(maximumConcurrentLoads: 1,
            loader: { url, _ in try await probe.load(url) })
        let runningURL = try #require(URL(string: "https://fixture.example/next-screen.png"))
        let queuedURL = try #require(URL(string: "https://fixture.example/obsolete.png"))
        let running = Task { try await cache.image(url: runningURL, maximumPixelDimension: 256, priority: .prefetch) }
        await probe.waitForStarts(1)
        let queued = Task { try await cache.image(url: queuedURL, maximumPixelDimension: 256, priority: .prefetch) }
        while await cache.pendingRequestCount < 2 { await Task.yield() }
        queued.cancel()
        running.cancel()
        await #expect(throws: CancellationError.self) { try await queued.value }
        await #expect(throws: CancellationError.self) { try await running.value }
        #expect(await probe.cancelled.isEmpty)
        let visible = Task { try await cache.image(url: runningURL, maximumPixelDimension: 256) }
        while await cache.waiterCount < 1 { await Task.yield() }
        await probe.release(runningURL)
        _ = try await visible.value
        #expect(await probe.started == [runningURL])
        #expect(cache.cachedImage(url: runningURL, maximumPixelDimension: 256) != nil)
    }

}

private actor BoundedArtworkProbe {
    let image: CGImage
    private(set) var started = 0
    private(set) var peak = 0
    private var loads: [CheckedContinuation<CGImage, Never>] = []
    private var observer: (count: Int, continuation: CheckedContinuation<Void, Never>)?

    init(image: CGImage) { self.image = image }

    func load() async -> CGImage {
        await withCheckedContinuation { continuation in
            loads.append(continuation)
            started += 1
            peak = max(peak, loads.count)
            if let observer, started >= observer.count {
                self.observer = nil
                observer.continuation.resume()
            }
        }
    }

    func waitForStarts(_ count: Int) async {
        if started >= count { return }
        await withCheckedContinuation { observer = (count, $0) }
    }

    func releaseStarted() {
        let ready = loads
        loads.removeAll()
        for continuation in ready { continuation.resume(returning: image) }
    }
}

private actor ArtworkLoaderProbe {
    private var started = false
    private var cancelled = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var cancelWaiter: CheckedContinuation<Void, Never>?
    private var loadWaiter: CheckedContinuation<CGImage, any Error>?

    func load() async throws -> CGImage {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                loadWaiter = continuation
                started = true
                startWaiter?.resume()
                startWaiter = nil
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    func waitForStart() async {
        if started { return }
        await withCheckedContinuation { startWaiter = $0 }
    }

    func waitForCancellation() async {
        if cancelled { return }
        await withCheckedContinuation { cancelWaiter = $0 }
    }

    private func cancel() {
        cancelled = true
        loadWaiter?.resume(throwing: CancellationError())
        loadWaiter = nil
        cancelWaiter?.resume()
        cancelWaiter = nil
    }
}


private actor ControlledArtworkProbe {
    let image: CGImage
    private(set) var started: [URL] = []
    private(set) var cancelled: [URL] = []
    private var loads: [URL: CheckedContinuation<CGImage, any Error>] = [:]
    private var observer: (count: Int, continuation: CheckedContinuation<Void, Never>)?

    init() throws {
        let context = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8,
            bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        image = try #require(context.makeImage())
    }

    func load(_ url: URL) async throws -> CGImage {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                loads[url] = continuation
                started.append(url)
                if let observer, started.count >= observer.count {
                    self.observer = nil
                    observer.continuation.resume()
                }
            }
        } onCancel: { Task { await self.cancel(url) } }
    }

    func waitForStarts(_ count: Int) async {
        if started.count >= count { return }
        await withCheckedContinuation { observer = (count, $0) }
    }

    func release(_ url: URL) { loads.removeValue(forKey: url)?.resume(returning: image) }

    private func cancel(_ url: URL) {
        cancelled.append(url)
        loads.removeValue(forKey: url)?.resume(throwing: CancellationError())
    }
}

@Suite("Live logo warm", .timeLimit(.minutes(1)))
struct AppleLiveLogoWarmTests {
    private static func image() throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8,
            bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try #require(context.makeImage())
    }

    private static func requests(_ names: [String]) throws -> [AppleArtworkPrefetchPolicy.Request] {
        try names.map { AppleArtworkPrefetchPolicy.Request(
            url: try #require(URL(string: "https://fixture.example/\($0).png")), maximumPixelDimension: 128) }
    }

    /// Walk 8's stall: every logo host down. The warm stops waiting at its
    /// deadline instead of holding on for each request timeout.
    @Test func deadHostsNeverHoldTheWarmPastItsDeadline() async throws {
        let image = try Self.image()
        let cache = AppleRemoteImageCache(loader: { url, _ in
            if url.lastPathComponent.hasPrefix("dead") {
                try await Task.sleep(for: .seconds(30))
                throw URLError(.timedOut)
            }
            return image
        })
        let requests = try Self.requests((0..<20).map { $0 % 4 == 0 ? "logo-\($0)" : "dead-\($0)" })
        let started = ContinuousClock.now
        #expect(await cache.warm(requests, width: 6, deadline: .milliseconds(200)) <= 5)
        #expect(started.duration(to: .now) < .seconds(2))
    }

    /// A logo slower than the deadline is not cancelled: it lands in the
    /// cache afterwards, so the rows draw it (walk 10: 11 of 16 never did).
    @Test func aSlowLogoFinishesAfterTheWarmStopsWaiting() async throws {
        let image = try Self.image()
        let cache = AppleRemoteImageCache(loader: { url, _ in
            if url.lastPathComponent.hasPrefix("slow") { try await Task.sleep(for: .milliseconds(400)) }
            return image
        })
        let requests = try Self.requests(["fast-1", "slow-1", "fast-2", "slow-2"])
        #expect(await cache.warm(requests, width: 6, deadline: .milliseconds(100)) == 2)
        #expect(cache.cachedImage(url: requests[1].url, maximumPixelDimension: 128) == nil)
        #expect(await cache.warm(requests, width: 6, deadline: .seconds(5)) == 4)
        #expect(cache.cachedImage(url: requests[3].url, maximumPixelDimension: 128) != nil)
    }

    /// Six transfers at most, even across warms that stopped waiting; a
    /// second warm of a running logo joins it.
    @Test func atMostWidthLoadsRunAndARepeatJoinsTheRunningLoad() async throws {
        let image = try Self.image()
        let counts = Mutex((running: 0, peak: 0, calls: 0))
        let cache = AppleRemoteImageCache(loader: { _, _ in
            counts.withLock { $0.running += 1; $0.calls += 1; $0.peak = max($0.peak, $0.running) }
            try await Task.sleep(for: .milliseconds(150))
            counts.withLock { $0.running -= 1 }
            return image
        })
        let requests = try Self.requests((0..<14).map { "logo-\($0)" })
        _ = await cache.warm(requests, width: 6, deadline: .milliseconds(10))
        #expect(await cache.warm(requests, width: 6, deadline: .seconds(5)) == 14)
        let final = counts.withLock { $0 }
        #expect(final.peak == 6)
        #expect(final.calls == 14)
    }

    /// A host that cannot be reached is remembered like a 404 (for an hour),
    /// so the rows and the next launch do not wait on it again.
    @Test func anUnreachableHostIsRememberedAndOtherFailuresAreNot() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = AppleArtworkDiskCache(directory: directory)
        let cache = AppleRemoteImageCache(loader: { url, _ in
            throw URLError(url.lastPathComponent.hasPrefix("dead") ? .cannotConnectToHost : .notConnectedToInternet)
        }, logoFailures: disk)
        let requests = try Self.requests(["dead-1", "offline-1"])
        #expect(await cache.warm(requests, width: 6, deadline: .seconds(5)) == 0)
        #expect(await disk.containsFailure(for: requests[0].url))
        #expect(await disk.containsFailure(for: requests[0].url, now: .now.addingTimeInterval(2 * 60 * 60)) == false)
        #expect(await disk.containsFailure(for: requests[1].url) == false)
    }
}
