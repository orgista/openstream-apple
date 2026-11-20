import Foundation
import CoreGraphics
import ImageIO
import Synchronization
import SwiftUI

enum AppleArtworkSizePolicy {
    static let serverWidthStep = 32
    static let buckets = [64, 128, 256, 384, 512, 768, 1280, 1920, 2560, 3840, 5120, 8192]
    // Catalog backdrops also serve the billboard, so keep one bounded server URL.
    static let backdropMaximumWidth = 1920

    static func bucket(_ pixels: Int) -> Int {
        buckets.first { $0 >= pixels } ?? 8192
    }

    static func bucket(size: CGSize, scale: CGFloat) -> Int {
        let pixels = max(size.width, size.height) * scale
        guard pixels.isFinite else { return 64 }
        return bucket(Int(min(2560, max(64, pixels)).rounded(.up)))
    }

    static func displayVariant(_ pixels: Int) -> String { "display-\(bucket(pixels))" }
}

enum AppleRemoteImageContentMode: Equatable {
    case fill
    case fit
}

/// A bounded, memory-cached remote image that decodes near its rendered size.
/// Poster catalogs otherwise retain full 1000×1500 source images for every
/// 160-point card, which is especially costly on Apple TV.
struct AppleRemoteImage: View {
    static var defaultLoadingFill: Color { Color.secondary.opacity(0.2) }

    let url: URL?
    var contentMode: AppleRemoteImageContentMode = .fill
    var placeholderSystemImage = "film"
    /// Called on the main actor when the image is available, including cache
    /// hits and reappearing rows, so callers can react to its pixel size.
    var onLoad: ((CGImage) -> Void)? = nil
    /// Called on the main actor when there is nothing to show (no URL, or the
    /// fetch/decode failed), so a caller can draw its own placeholder.
    var onFailure: (() -> Void)? = nil
    var loadingFill: Color = Self.defaultLoadingFill
    /// Keeps the current image on screen while a new URL or size loads, and
    /// swaps only once the replacement has decoded. A full-bleed hero opts in:
    /// its backdrop upgrades mid-view, and clearing first painted the hero
    /// black between the two stills (sim finding f, 2026-09-22).
    var keepsImageWhileReloading = false
    /// Decodes once at this pixel budget, whatever size the view is drawn at,
    /// so resizing a window never reloads the image. The Mac hero opts in: a
    /// live resize otherwise asked for a new decode at every size it passed
    /// through. Nil decodes near the rendered size.
    var fixedPixelDimension: Int? = nil
    /// Where a filled image that overhangs its frame is pinned. Nil keeps the
    /// `GeometryReader`'s top-leading corner, which every other caller is laid
    /// out and measured against (`AppleHeroLuminanceMap.reading`). The Mac
    /// heroes centre it, as the trailer's cover over it is centred: pinned
    /// top-leading, the art jumped by the overhang when the trailer mounted
    /// (67 pt in a 1440 pt window, 627 pt in a 3440 pt one; N44).
    var fillAlignment: Alignment? = nil
    /// Hero and title-page art pass `.foreground` to start ahead of rows.
    var priority: AppleArtworkRequestQueue.Priority = .visible

    @Environment(\.displayScale) private var displayScale
    @State private var imageState = AppleRemoteImageState()
    @State private var placeholderColour: (url: URL, colour: AppleArtworkColour)?
    @State private var placeholderColourURL: URL?

    var body: some View {
        GeometryReader { geometry in
            Group {
                if let image = displayedImage(size: geometry.size) {
                    rendered(image, in: geometry.size)
                } else if imageState.failed {
                    placeholder
                } else {
                    // Keep the surrounding layout quiet while remote art is
                    // loading. A spinner inside every poster reads as a
                    // boxed loading state and makes the detail page jump when
                    // the image arrives.
                    if let placeholderColour, placeholderColour.url == url {
                        Color(red: Double(placeholderColour.colour.red) / 255,
                              green: Double(placeholderColour.colour.green) / 255,
                              blue: Double(placeholderColour.colour.blue) / 255)
                    } else {
                        loadingFill
                    }
                }
            }
            .task(id: loadIdentity(url: url, size: geometry.size)) {
                let identity = loadIdentity(url: url, size: geometry.size)
                guard !Task.isCancelled else { return }
                if imageState.restore(url: url, identity: identity,
                    maximumPixelDimension: maximumPixelDimension(for: geometry.size), onLoad: onLoad) {
                    if let image = imageState.image {
                        if let url { AppleArtworkTrace.record("cache=memory image=\(AppleArtworkTrace.identifier(url))") }
                        AppleArtworkTrace.ready(url: url, size: geometry.size, scale: displayScale, image: image)
                    }
                    return
                }
                imageState.identity = nil
                if !keepsImageWhileReloading { imageState.image = nil }
                imageState.failed = false
                guard let url else {
                    imageState.image = nil
                    imageState.failed = true
                    onFailure?()
                    return
                }
                do {
                    let pixelDimension = maximumPixelDimension(for: geometry.size)
                    let inMemory = AppleRemoteImageCache.shared.cachedImage(url: url, maximumPixelDimension: pixelDimension)
                    if let preview = inMemory ?? AppleRemoteImageCache.shared.cachedPlaceholderImage(url: url) {
                        imageState.image = preview
                        imageState.url = url
                    }
                    if imageState.image == nil {
                        // Paired with `ready` to time how long a tile shows its placeholder.
                        AppleArtworkTrace.record("placeholder image=\(AppleArtworkTrace.identifier(url))")
                        placeholderColourURL = url
                    }
                    let loaded = try await AppleRemoteImageCache.shared.image(
                        url: url,
                        maximumPixelDimension: maximumPixelDimension(for: geometry.size),
                        priority: priority
                    )
                    guard !Task.isCancelled else { return }
                    imageState.image = loaded
                    imageState.identity = identity
                    imageState.url = url
                    AppleArtworkTrace.ready(url: url, size: geometry.size, scale: displayScale, image: loaded)
                    #if DEBUG
                    AppleLaunchClock.count(fixedPixelDimension != nil || keepsImageWhileReloading ? "image.hero" : "image.card",
                                           marking: [1, 8, 16, 32])
                    #endif
                    onLoad?(loaded)
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    if imageState.image == nil || imageState.url != url {
                        imageState.image = nil
                        imageState.failed = true
                        onFailure?()
                    }
                }
            }
        }
        // Apart from the load: the colour is read from the disk cache, which
        // queues behind the launch prefetch's reads, and the image itself must
        // not wait for it. the test Apple TV's billboard still sat 70 ms in memory before
        // its view was given it, past the launch hold (walk b20r24).
        .task(id: placeholderColourURL) {
            guard let url = placeholderColourURL, placeholderColour?.url != url else { return }
            let colour = await AppleArtworkDiskCache.shared.colour(for: url)
            guard !Task.isCancelled else { return }
            placeholderColour = colour.map { (url, $0) }
        }
        .accessibilityHidden(true)
        .accessibilityIgnoresInvertColors()
    }

    @ViewBuilder
    private func rendered(_ image: CGImage, in size: CGSize) -> some View {
        let value = Image(decorative: image, scale: displayScale)
            .resizable()
        if contentMode == .fill, let fillAlignment {
            value.scaledToFill()
                .frame(width: size.width, height: size.height, alignment: fillAlignment)
        } else if contentMode == .fill {
            value.scaledToFill()
        } else {
            value.scaledToFit()
        }
    }

    private var placeholder: some View {
        ZStack {
            loadingFill
            Image(systemName: placeholderSystemImage)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
        }
    }

    private func displayedImage(size: CGSize) -> CGImage? {
        imageState.displayedImage(url: url, identity: loadIdentity(url: url, size: size),
            maximumPixelDimension: maximumPixelDimension(for: size), keepsImageWhileReloading: keepsImageWhileReloading)
    }

    private func maximumPixelDimension(for size: CGSize) -> Int {
        if let fixedPixelDimension { return AppleArtworkSizePolicy.bucket(fixedPixelDimension) }
        return AppleArtworkSizePolicy.bucket(size: size, scale: displayScale)
    }

    private func loadIdentity(url: URL?, size: CGSize) -> String {
        "\(url?.absoluteString ?? "")|\(maximumPixelDimension(for: size))"
    }
}

/// One image load's identity, including synchronous delivery when a lazy row returns.
@MainActor
struct AppleRemoteImageState {
    var image: CGImage?
    var identity: String?
    var url: URL?
    var failed = false

    /// Memory hits paint in the first body pass, before the view's task runs.
    func displayedImage(url: URL?, identity: String, maximumPixelDimension: Int,
                        keepsImageWhileReloading: Bool, cache: AppleRemoteImageCache = .shared) -> CGImage? {
        if self.identity == identity { return image }
        return url.flatMap {
            cache.cachedImage(url: $0, maximumPixelDimension: maximumPixelDimension) ?? cache.cachedPlaceholderImage(url: $0)
        } ?? (keepsImageWhileReloading || self.url == url ? image : nil)
    }

    mutating func restore(url: URL?, identity: String, maximumPixelDimension: Int,
                          cache: AppleRemoteImageCache = .shared, onLoad: ((CGImage) -> Void)?) -> Bool {
        let restored: CGImage?
        if !AppleArtworkLoadingPolicy.needsReload(loadedIdentity: self.identity,
            requestedIdentity: identity, hasImage: image != nil) {
            restored = image
        } else {
            restored = url.flatMap { cache.cachedImage(url: $0, maximumPixelDimension: maximumPixelDimension) }
        }
        guard let restored else { return false }
        image = restored
        self.identity = identity
        self.url = url
        failed = false
        onLoad?(restored)
        return true
    }
}

/// Renders a title wordmark from its decoded alpha bounds rather than its
/// source canvas. Title logos often contain asymmetric transparent padding;
/// cropping that padding keeps the visible mark optically centered.
struct AppleTrimmedTitleLogo: View {
    let url: URL
    /// Where the wordmark sits inside the slot it is given.
    ///
    /// `scaledToFit` leaves slack on one axis, and this view used to centre the
    /// artwork in that slack unconditionally — which overrode the
    /// `alignment: .leading` its callers asked for and left the Discover
    /// billboard's wordmark indented ~190 pt while the metadata line, synopsis
    /// and Play button under it were flush at the safe inset. It is declared
    /// before `onLoadResult` so callers keep trailing-closure syntax.
    var alignment: Alignment = .center
    /// Reports `true` once the wordmark is on screen, `false` when the fetch or
    /// decode failed, so callers can fall back to a text title instead of
    /// showing nothing.
    var onLoadResult: (Bool) -> Void = { _ in }

    @Environment(\.displayScale) private var displayScale
    @State private var image: CGImage?
    /// The result last reported, and for which wordmark. Keyed by URL: the
    /// hero carousel reuses this view for the next page, and a bare flag
    /// swallowed the new page's `true` as a repeat, so its lockup drew the
    /// text title over a wordmark that was on screen (owner, 2026-09-24:
    /// "Dark Matter (2024)" over the DARK MATTER mark on the Mac).
    @State private var reported: (url: URL, loaded: Bool)?
    /// Which wordmark `image` is, so a reused view never shows the last
    /// page's mark while the new one loads.
    @State private var imageURL: URL?

    var body: some View {
        GeometryReader { geometry in
            Group {
                if let image = imageURL == url ? image
                    : AppleRemoteImageCache.shared.cachedTrimmedLogo(url: requestedURL(width: geometry.size.width)) {
                    Image(decorative: image, scale: displayScale)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geometry.size.width, height: geometry.size.height, alignment: alignment)
                        .frame(maxWidth: .infinity, alignment: alignment)
                } else {
                    Color.clear
                }
            }
            .task(id: "\(url.absoluteString)|\(Int(geometry.size.width))x\(Int(geometry.size.height))@\(displayScale)") {
                guard !Task.isCancelled else { return }
                let requestedURL = requestedURL(width: geometry.size.width)
                // A reopened title page draws its wordmark from memory, before any await.
                if let cachedImage = AppleRemoteImageCache.shared.cachedTrimmedLogo(url: requestedURL) {
                    image = cachedImage
                    imageURL = url
                    report(true)
                    return
                }
                if imageURL != url { image = nil }
                do {
                    if let cachedData = await AppleArtworkDiskCache.shared.data(for: requestedURL, variant: "logo-trimmed"),
                       let cachedImage = await Task.detached(priority: .userInitiated, operation: {
                           AppleRemoteImageDecoder.displayImage(data: cachedData)
                       }).value {
                        AppleRemoteImageCache.shared.storeTrimmedLogo(cachedImage, url: requestedURL)
                        guard !Task.isCancelled else { return }
                        image = cachedImage
                        imageURL = url
                        report(true)
                        return
                    }

                    let decoded = try await AppleRemoteImageCache.shared.image(
                        url: requestedURL,
                        maximumPixelDimension: min(2_560, max(256, Int(max(geometry.size.width, geometry.size.height) * displayScale * 4))),
                        priority: .foreground
                    )
                    guard !Task.isCancelled else { return }
                    let trimmed = await Task.detached(priority: .userInitiated) {
                        AppleRemoteImageDecoder.trimmedToAlphaBounds(decoded)
                    }.value
                    if let trimmed { AppleRemoteImageCache.shared.storeTrimmedLogo(trimmed, url: requestedURL) }
                    guard !Task.isCancelled else { return }
                    image = trimmed
                    imageURL = url
                    report(image != nil)

                    if let finalImage = trimmed {
                        Task.detached(priority: .background) {
                            if let encoded = AppleRemoteImageDecoder.displayData(finalImage) {
                                await AppleArtworkDiskCache.shared.store(encoded, for: requestedURL, variant: "logo-trimmed")
                            }
                        }
                    }
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    image = nil
                    report(false)
                }
            }
        }
        .accessibilityHidden(true)
        .accessibilityIgnoresInvertColors()
    }

    /// Puts a wordmark trimmed on an earlier launch into memory, at whichever
    /// width it was drawn, so a restored hero's first frame already has it.
    static func warmTrimmedFromDisk(_ url: URL) async {
        let candidates = Set(AppleArtworkResolver.Purpose.logo.widths.map {
            AppleTMDBClient.resizedArtworkURL(url, size: "w\($0)") ?? url
        })
        await withDiscardingTaskGroup { group in
            for candidate in candidates where AppleRemoteImageCache.shared.cachedTrimmedLogo(url: candidate) == nil {
                group.addTask(priority: .userInitiated) {
                    guard let data = await AppleArtworkDiskCache.shared.data(for: candidate, variant: "logo-trimmed"),
                          let image = AppleRemoteImageDecoder.displayImage(data: data) else { return }
                    AppleRemoteImageCache.shared.storeTrimmedLogo(image, url: candidate)
                }
            }
        }
    }

    private func requestedURL(width: CGFloat) -> URL {
        AppleTMDBClient.resizedArtworkURL(url, size: AppleArtworkResolver.Purpose.logo.size(pixelWidth: width * displayScale)) ?? url
    }

    private func report(_ loaded: Bool) {
        if let reported, reported.url == url, reported.loaded == loaded { return }
        reported = (url, loaded)
        onLoadResult(loaded)
    }
}

actor AppleRemoteImageCache {
    static let shared = AppleRemoteImageCache(logoFailures: .shared)

    typealias Loader = @Sendable (URL, Int) async throws -> CGImage
    typealias DataLoader = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private final class Entry {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    nonisolated(unsafe) private let cache = NSCache<NSString, Entry>()
    private struct Request {
        let id = UUID()
        let url: URL
        let pixels: Int
        var priority: AppleArtworkRequestQueue.Priority
        var retainsForPrefetch: Bool
        var task: Task<Void, Never>?
        var waiters: [UUID: CheckedContinuation<CGImage, any Error>]
    }

    private var inFlight: [String: Request] = [:]
    private var queue = AppleArtworkRequestQueue()
    var pendingRequestCount: Int { inFlight.count }
    var waiterCount: Int { inFlight.values.reduce(0) { $0 + $1.waiters.count } }

    private var activeLoads = 0
    private var activePrefetches = 0
    private let maximumConcurrentLoads: Int
    private let maximumConcurrentPrefetchLoads: Int
    private let loader: Loader
    /// Logo warms still running, so a second warm of the same logo joins it
    /// instead of starting another transfer.
    private var logoWarms: [String: Task<Bool, Never>] = [:]
    private var activeLogoWarms = 0
    private var logoSlotWaiters: [CheckedContinuation<Void, Never>] = []
    private let logoFailures: AppleArtworkDiskCache?

    #if os(tvOS)
    private static let defaultConcurrentLoads = 10
    #else
    private static let defaultConcurrentLoads = 6
    #endif

    init(maximumConcurrentLoads: Int = AppleRemoteImageCache.defaultConcurrentLoads, maximumConcurrentPrefetchLoads: Int = 2,
         loader: @escaping Loader = AppleRemoteImageCache.load, logoFailures: AppleArtworkDiskCache? = nil) {
        self.loader = loader
        self.logoFailures = logoFailures
        self.maximumConcurrentLoads = max(1, maximumConcurrentLoads)
        self.maximumConcurrentPrefetchLoads = min(max(1, maximumConcurrentLoads), max(1, maximumConcurrentPrefetchLoads))
        cache.countLimit = 300
        cache.totalCostLimit = 160 * 1_024 * 1_024
    }

    /// Reset OpenStream empties the decoded artwork too. `NSCache` is
    /// thread-safe.
    nonisolated func removeAllCached() {
        cache.removeAllObjects()
    }

    /// The decoded image if it is already in memory, without waiting on the
    /// actor. `NSCache` is thread-safe.
    nonisolated func cachedImage(url: URL, maximumPixelDimension: Int) -> CGImage? {
        cache.object(forKey: Self.key(url: url, maximumPixelDimension: maximumPixelDimension) as NSString)?.image
    }

    nonisolated static func key(url: URL, maximumPixelDimension: Int) -> String {
        "\(url.absoluteString)|\(AppleArtworkSizePolicy.bucket(maximumPixelDimension))"
    }

    nonisolated func cachedTrimmedLogo(url: URL) -> CGImage? {
        cache.object(forKey: Self.trimmedLogoKey(url) as NSString)?.image
    }

    nonisolated func storeTrimmedLogo(_ image: CGImage, url: URL) {
        cache.setObject(Entry(image), forKey: Self.trimmedLogoKey(url) as NSString, cost: image.bytesPerRow * image.height)
    }

    private nonisolated static func trimmedLogoKey(_ url: URL) -> String { "\(url.absoluteString)|logo-trimmed" }

    /// Lookups do not retain extra bitmaps after NSCache evicts a variant.
    nonisolated func cachedPlaceholderImage(url: URL) -> CGImage? {
        for pixels in AppleArtworkSizePolicy.buckets.reversed() {
            if let image = cachedImage(url: url, maximumPixelDimension: pixels) { return image }
        }
        return nil
    }

    func image(url: URL, maximumPixelDimension: Int,
               priority: AppleArtworkRequestQueue.Priority = .visible) async throws -> CGImage {
        try Task.checkCancellation()
        guard let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              url.user == nil,
              url.password == nil else {
            throw URLError(.unsupportedURL)
        }
        let key = Self.key(url: url, maximumPixelDimension: maximumPixelDimension)
        if let cached = cache.object(forKey: key as NSString) {
            AppleArtworkTrace.record("cache=memory image=\(AppleArtworkTrace.identifier(url))")
            return cached.image
        }
        let waiter = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if var request = inFlight[key] {
                    AppleArtworkTrace.record("cache=shared image=\(AppleArtworkTrace.identifier(url))")
                    request.waiters[waiter] = continuation
                    if priority == .prefetch { request.retainsForPrefetch = true }
                    if priority > request.priority {
                        request.priority = priority
                        // A running load may be queued for its host behind prefetch.
                        if let task = request.task {
                            Task { await AppleArtworkDownload.shared.promote(url: url, to: priority) }
                            // Awaiting it from a higher priority raises the running prefetch task's
                            // own (utility), which otherwise held a downloaded poster's decode ~400 ms.
                            Task(priority: .userInitiated) { await task.value }
                        }
                    }
                    inFlight[key] = request
                    if request.task == nil { queue.enqueue(key, priority: request.priority) }
                } else {
                    inFlight[key] = Request(url: url, pixels: AppleArtworkSizePolicy.bucket(maximumPixelDimension),
                        priority: priority, retainsForPrefetch: priority == .prefetch, waiters: [waiter: continuation])
                    queue.enqueue(key, priority: priority)
                }
                startNext()
            }
        } onCancel: {
            Task { await self.cancel(key: key, waiter: waiter) }
        }
    }

    private func cancel(key: String, waiter: UUID) {
        guard var request = inFlight[key], let continuation = request.waiters.removeValue(forKey: waiter) else { return }
        continuation.resume(throwing: CancellationError())
        if request.waiters.isEmpty, request.task == nil || !request.retainsForPrefetch {
            request.task?.cancel()
            inFlight[key] = nil
            queue.cancel(key)
            AppleArtworkTrace.record("cancel image=\(AppleArtworkTrace.identifier(request.url))")
        } else {
            inFlight[key] = request
        }
        startNext()
    }

    private func startNext() {
        while let key = queue.next(prefetchAllowed: activePrefetches < maximumConcurrentPrefetchLoads,
                                   visibleAllowed: activeLoads < maximumConcurrentLoads) {
            guard var request = inFlight[key] else { continue }
            let id = request.id
            let url = request.url
            let pixels = request.pixels
            let priority = request.priority
            let prefetch = priority == .prefetch
            activeLoads += 1
            if prefetch { activePrefetches += 1 }
            AppleArtworkTrace.record("start image=\(AppleArtworkTrace.identifier(url)) priority=\(priority) active=\(activeLoads)")
            request.task = Task(priority: prefetch ? .utility : .userInitiated) { [loader] in
                let result: Result<CGImage, any Error>
                do {
                    try Task.checkCancellation()
                    let decoded = try await AppleArtworkDownload.$priority.withValue(priority) { try await loader(url, pixels) }
                    try Task.checkCancellation()
                    result = .success(decoded)
                } catch {
                    result = .failure(error)
                }
                complete(key: key, id: id, prefetch: prefetch, result: result)
            }
            inFlight[key] = request
        }
    }

    private func complete(key: String, id: UUID, prefetch: Bool, result: Result<CGImage, any Error>) {
        activeLoads -= 1
        if prefetch { activePrefetches -= 1 }
        if let request = inFlight[key], request.id == id {
            inFlight[key] = nil
            if case .success(let decoded) = result {
                cache.setObject(Entry(decoded), forKey: key as NSString, cost: decoded.bytesPerRow * decoded.height)
            }
            for continuation in request.waiters.values { continuation.resume(with: result) }
        }
        startNext()
    }

    func prefetch(_ requests: [AppleArtworkPrefetchPolicy.Request]) async {
        var seen = Set<AppleArtworkPrefetchPolicy.Request>()
        let uniqueRequests = requests.filter { seen.insert($0).inserted }
        await withTaskGroup(of: Void.self) { group in
            var active = 0
            for request in uniqueRequests {
                if Task.isCancelled { break }
                if active >= 2 {
                    await group.next()
                    active -= 1
                }
                if Task.isCancelled { break }
                active += 1
                group.addTask(priority: .utility) {
                    // Speculative artwork failures are retried by the visible tile.
                    _ = try? await self.image(url: request.url, maximumPixelDimension: request.maximumPixelDimension, priority: .prefetch)
                }
            }
        }
    }

    /// Warms small images outside the shared prefetch lane, `width` at a
    /// time, and waits at most `deadline` for them. For Live's channel logos:
    /// they come from many playlist hosts, and in the two-slot prefetch lane a
    /// host that never answered held a slot for the full 15 s request timeout
    /// (test Apple TV fresh install, walk 8: 20 logos in 59 s). The deadline only ends
    /// the wait: a slow logo keeps loading and is cached when it lands (a 2 s
    /// cancel left 11 of 16 uncached on every launch, walk 10), and a host
    /// that cannot be reached is remembered like a 404. Returns how many of
    /// `requests` were cached by the deadline.
    func warm(_ requests: [AppleArtworkPrefetchPolicy.Request], width: Int, deadline: Duration) async -> Int {
        var seen = Set<AppleArtworkPrefetchPolicy.Request>()
        var ready = 0
        var loads: [Task<Bool, Never>] = []
        for request in requests where seen.insert(request).inserted {
            if cachedImage(url: request.url, maximumPixelDimension: request.maximumPixelDimension) != nil {
                ready += 1
            } else {
                loads.append(logoWarm(request, width: width))
            }
        }
        guard !loads.isEmpty else { return ready }
        let (finished, continuation) = AsyncStream.makeStream(of: Bool.self)
        for load in loads { Task { continuation.yield(await load.value) } }
        let timer = Task {
            try? await Task.sleep(for: deadline)
            continuation.finish()
        }
        defer {
            timer.cancel()
            continuation.finish()
        }
        var pending = loads.count
        for await loaded in finished {
            if loaded { ready += 1 }
            pending -= 1
            if pending == 0 { break }
        }
        return ready
    }

    /// An unreachable logo host is skipped for an hour, not the 404 day: a
    /// timeout can also be a slow network at wake.
    private static let unreachableLogoLifetime: TimeInterval = 60 * 60

    private func logoWarm(_ request: AppleArtworkPrefetchPolicy.Request, width: Int) -> Task<Bool, Never> {
        let key = Self.key(url: request.url, maximumPixelDimension: request.maximumPixelDimension)
        if let running = logoWarms[key] { return running }
        let loader = self.loader
        let failures = logoFailures
        let pixels = AppleArtworkSizePolicy.bucket(request.maximumPixelDimension)
        let load = Task(priority: .utility) {
            await self.takeLogoSlot(width: width)
            let generation = await failures?.failureGeneration
            var image: CGImage?
            do {
                image = try await AppleArtworkDownload.$priority.withValue(.prefetch) { try await loader(request.url, pixels) }
            } catch let error as URLError where Self.hostUnreachable(error) {
                if let failures, let generation {
                    await failures.recordFailure(for: request.url, generation: generation, lifetime: Self.unreachableLogoLifetime)
                }
            } catch {
                // A 404 is cached by the load itself; the rows retry anything else.
            }
            self.finishLogoWarm(key: key, image: image)
            return image != nil
        }
        logoWarms[key] = load
        return load
    }

    private func takeLogoSlot(width: Int) async {
        if activeLogoWarms < width {
            activeLogoWarms += 1
            return
        }
        await withCheckedContinuation { logoSlotWaiters.append($0) }
    }

    /// Hands the slot straight to the next waiting logo, if any.
    private func finishLogoWarm(key: String, image: CGImage?) {
        if let image {
            cache.setObject(Entry(image), forKey: key as NSString, cost: image.bytesPerRow * image.height)
        }
        logoWarms[key] = nil
        if logoSlotWaiters.isEmpty {
            activeLogoWarms -= 1
        } else {
            logoSlotWaiters.removeFirst().resume()
        }
    }

    private static func hostUnreachable(_ error: URLError) -> Bool {
        [.timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed].contains(error.code)
    }

    private static func load(url: URL, maximumPixelDimension: Int) async throws -> CGImage {
        #if DEBUG
        if let fixture = AppleContinueWatchingDebugView.artwork(for: url) { return fixture }
        #endif
        return try await load(url: url, maximumPixelDimension: maximumPixelDimension, disk: .shared)
    }

    static func load(url: URL, maximumPixelDimension: Int, disk: AppleArtworkDiskCache,
                     download: DataLoader = { request in
                         try await AppleArtworkDownload.shared.data(for: request) { request in
                             try await AppleBoundedHTTPDataLoader.load(request, maximumBytes: 12 * 1_024 * 1_024)
                         }
                     }) async throws -> CGImage {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let variant = AppleArtworkSizePolicy.displayVariant(maximumPixelDimension)
        if let displayData = await disk.data(for: url, variant: variant) {
            let image = await Task.detached(priority: Task.currentPriority, operation: {
                let started = ContinuousClock.now
                let interval = AppleArtworkTrace.begin("Artwork decode", url: url)
                defer {
                    AppleArtworkTrace.end("Artwork decode", id: interval)
                    AppleArtworkTrace.record("decode main=\(Thread.isMainThread) ms=\(AppleLaunchMarks.milliseconds(started.duration(to: .now)))")
                }
                return AppleRemoteImageDecoder.displayImage(data: displayData)
            }).value
            try Task.checkCancellation()
            if let image {
                AppleArtworkTrace.record("cache=disk-display image=\(AppleArtworkTrace.identifier(url)) bytes=\(displayData.count)")
                return image
            }
            try? await disk.remove(for: url, variant: variant)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            AppleArtworkTrace.record("cache=invalid-display")
        }
        if let cachedData = await disk.data(for: url, variant: "raw") {
            AppleArtworkTrace.record("cache=disk-raw image=\(AppleArtworkTrace.identifier(url)) bytes=\(cachedData.count)")
            do {
                return try await decodeAndStore(cachedData, url: url, maximumPixelDimension: maximumPixelDimension, disk: disk)
            } catch let error as URLError where error.code == .cannotDecodeContentData {
                try Task.checkCancellation()
                try? await disk.remove(for: url, variant: "raw")
                request.cachePolicy = .reloadIgnoringLocalCacheData
                AppleArtworkTrace.record("cache=invalid-raw")
            }
        }

        try Task.checkCancellation()
        let failureGeneration = await disk.failureGeneration
        if await disk.containsFailure(for: url) {
            AppleArtworkTrace.record("cache=negative image=\(AppleArtworkTrace.identifier(url))")
            throw URLError(.cannotDecodeContentData)
        }
        let data: Data
        let response: URLResponse
        (data, response) = try await download(request)
        AppleArtworkTrace.record("download image=\(AppleArtworkTrace.identifier(url)) bytes=\(data.count) HTTP=\((response as? HTTPURLResponse)?.statusCode ?? 0)")
        if let http = response as? HTTPURLResponse, http.statusCode == 404 || http.statusCode == 410 {
            await disk.recordFailure(for: url, generation: failureGeneration)
        }
        guard let http = response as? HTTPURLResponse,
              (200 ... 299).contains(http.statusCode) else {
            throw URLError(.cannotDecodeContentData)
        }
        return try await decodeAndStore(data, url: url, maximumPixelDimension: maximumPixelDimension, disk: disk, storesRawData: true)
    }

    private static func decodeAndStore(_ data: Data, url: URL, maximumPixelDimension: Int,
                                       disk: AppleArtworkDiskCache, storesRawData: Bool = false) async throws -> CGImage {
        let image = try await Task.detached(priority: Task.currentPriority) {
            let started = ContinuousClock.now
            let interval = AppleArtworkTrace.begin("Artwork decode", url: url)
            defer {
                AppleArtworkTrace.end("Artwork decode", id: interval)
                AppleArtworkTrace.record("decode main=\(Thread.isMainThread) ms=\(AppleLaunchMarks.milliseconds(started.duration(to: .now)))")
            }
            return try AppleRemoteImageDecoder.downsample(data: data, maximumPixelDimension: maximumPixelDimension)
        }.value
        if storesRawData { await disk.store(data, for: url, variant: "raw") }
        // The colour and the display-size copy serve the next launch; the
        // tile waiting for this image does not wait for them.
        Task.detached(priority: .background) {
            if let colour = AppleRemoteImageDecoder.averageColour(image) {
                await disk.storeColour(colour, for: url)
            }
            if let encoded = AppleRemoteImageDecoder.displayData(image) {
                await disk.store(encoded, for: url, variant: AppleArtworkSizePolicy.displayVariant(maximumPixelDimension))
            }
        }
        try Task.checkCancellation()
        return image
    }
}

enum AppleRemoteImageDecoder {
    static func displayImage(data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    static func displayData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        let opaque = [CGImageAlphaInfo.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        // Photograph variants stay small; logos retain their transparency.
        let format = opaque ? "public.jpeg" : "public.png"
        guard let destination = CGImageDestinationCreateWithData(data, format as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    static func averageColour(_ image: CGImage) -> AppleArtworkColour? {
        let side = 16
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
            bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
              let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        var red = 0, green = 0, blue = 0, alpha = 0
        for offset in stride(from: 0, to: side * side * 4, by: 4) {
            red += Int(pixels[offset])
            green += Int(pixels[offset + 1])
            blue += Int(pixels[offset + 2])
            alpha += Int(pixels[offset + 3])
        }
        guard alpha > 0 else { return nil }
        return AppleArtworkColour(red: UInt8(min(255, red * 255 / alpha)),
                                  green: UInt8(min(255, green * 255 / alpha)),
                                  blue: UInt8(min(255, blue * 255 / alpha)))
    }

    static func downsample(data: Data, maximumPixelDimension: Int) throws -> CGImage {
        guard maximumPixelDimension > 0,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maximumPixelDimension,
                  kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else {
            throw URLError(.cannotDecodeContentData)
        }
        return image
    }

    static func trimmedToAlphaBounds(_ image: CGImage, minimumAlpha: UInt8 = 8) -> CGImage? {
        guard image.width > 1, image.height > 1 else { return image }

        let width = image.width
        let height = image.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let buffer = context.data?.assumingMemoryBound(to: UInt8.self) else {
            return image
        }

        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1
        for y in 0..<height {
            for x in 0..<width where buffer[(y * width + x) * 4 + 3] >= minimumAlpha {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }

        guard maxX >= minX, maxY >= minY else { return image }
        return image.cropping(to: CGRect(
            x: minX,
            y: minY,
            width: maxX - minX + 1,
            height: maxY - minY + 1
        )) ?? image
    }
}

enum AppleTransparentPNGLogoValidator {
    private static let pngSignature: [UInt8] = [
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
    ]

    /// The size the wordmark views ask the cache for. Validating at the same
    /// size means the validator and the view share one download instead of
    /// fetching the same PNG twice in a row, which was most of the 1.6 s a
    /// content page took to show its wordmark (measured 2026-09-15).
    static let validationPixelDimension = 2_560

    static func firstValid(in candidates: [URL]) async -> URL? {
        var seen = Set<URL>()
        for url in candidates where seen.insert(url).inserted {
            guard !Task.isCancelled else { return nil }
            if await isValid(url: url), !Task.isCancelled { return url }
        }
        return nil
    }

    /// Verdicts for logos that decoded, so a reopened title page skips the
    /// full-size edge scan. Network failures are not remembered.
    private static let verdicts = Mutex<[URL: Bool]>([:])
    /// The same verdicts on disk: at launch the saved hero's wordmark waited
    /// on a fresh 2,560 px decode and scan of a logo checked last session.
    private static let verdictCacheSource = "logo-transparency"

    static func isValid(url: URL) async -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              url.user == nil,
              url.password == nil else { return false }
        if let verdict = verdicts.withLock({ $0[url] }) { return verdict }
        if let stored = await AppleMetadataDiskCache.shared.entry(source: verdictCacheSource, type: "v1",
                                                                  mediaID: url.absoluteString),
           let byte = stored.payload.first {
            verdicts.withLock { $0[url] = byte == 1 }
            return byte == 1
        }

        do {
            // Through the shared cache: this is the fetch `AppleTrimmedTitleLogo`
            // is about to make, so it is warm by the time the view asks.
            let image = try await AppleRemoteImageCache.shared.image(
                url: url,
                maximumPixelDimension: validationPixelDimension,
                priority: .foreground
            )
            let verdict = await Task.detached(priority: .userInitiated) {
                hasTransparentEdges(in: image)
            }.value
            verdicts.withLock { $0[url] = verdict }
            Task.detached(priority: .utility) {
                await AppleMetadataDiskCache.shared.store(Data([verdict ? 1 : 0]), source: verdictCacheSource,
                                                          type: "v1", mediaID: url.absoluteString)
            }
            return verdict
        } catch is CancellationError {
            return false
        } catch {
            return false
        }
    }

    /// Edge transparency straight off a decoded image. A JPEG decodes fully
    /// opaque, so it fails these samples without needing the PNG signature
    /// check the data-based version does.
    static func hasTransparentEdges(in image: CGImage) -> Bool {
        guard image.width >= 2, image.height >= 2 else { return false }
        guard let buffer = premultipliedRGBA(image) else { return false }
        return samplesAreTransparent(buffer.pixels, width: image.width, height: image.height)
    }

    /// A logo is only safe to place over the hero when it is a PNG and its
    /// decoded corners and edge midpoints contain real transparency. Sampling
    /// the decoded pixels rejects JPEGs and PNGs with an opaque plate.
    static func hasTransparentEdges(in data: Data) -> Bool {
        guard data.starts(with: pngSignature),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return false }
        return hasTransparentEdges(in: image)
    }

    /// Draws `image` into a premultiplied RGBA buffer, keeping the context
    /// alive for as long as the pixels are read.
    private static func premultipliedRGBA(_ image: CGImage) -> (context: CGContext, pixels: UnsafeMutablePointer<UInt8>)? {
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return (context, pixels)
    }

    /// Points read along each edge of the logo.
    private static let samplesPerEdge = 16

    /// A plate or a photo behind the mark is opaque all the way round its
    /// border; a wordmark leaves most of its border clear. TMDB crops its
    /// logos tight, so letters touch the edges: the old rule, every corner
    /// and edge midpoint clear, refused marks whose top-centre letter
    /// reached the edge, and the iPhone hero drew the name instead
    /// (owner recording 2026-11-04). A quarter of the border clear is a mark;
    /// a rounded plate clears only its corners, about an eighth.
    private static func samplesAreTransparent(_ pixels: UnsafeMutablePointer<UInt8>, width: Int, height: Int) -> Bool {
        let steps = (0..<samplesPerEdge).map { Double($0) / Double(samplesPerEdge - 1) }
        let xs = steps.map { Int($0 * Double(width - 1)) }
        let ys = steps.map { Int($0 * Double(height - 1)) }
        let border = xs.flatMap { [($0, 0), ($0, height - 1)] } + ys.flatMap { [(0, $0), (width - 1, $0)] }
        let clear = border.count { x, y in pixels[(y * width + x) * 4 + 3] < 250 }
        return clear * 4 >= border.count
    }
}
