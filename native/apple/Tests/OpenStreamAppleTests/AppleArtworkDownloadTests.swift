import CoreGraphics
import Foundation
import Testing
@testable import OpenStreamApple

@Suite("Artwork source transfer sharing", .timeLimit(.minutes(1)))
struct AppleArtworkDownloadTests {
    @Test func displaySizesShareBytesWithoutSharingCancellation() async throws {
        let probe = TransferProbe()
        let transfer = AppleArtworkDownload()
        let url = try #require(URL(string: "https://fixture.example/poster.png"))
        let request = URLRequest(url: url)
        let first = Task { try await transfer.data(for: request, download: { try await probe.load($0) }) }
        await probe.waitForStarts(1)
        let second = Task { try await transfer.data(for: request, download: { try await probe.load($0) }) }
        while await transfer.consumerCount < 2 { await Task.yield() }
        first.cancel()
        while await transfer.consumerCount != 1 { await Task.yield() }
        try await probe.finish(request)
        await #expect(throws: CancellationError.self) { try await first.value }
        let result = try await second.value
        #expect(result.0 == Data([1, 2, 3]))
        #expect(await probe.loads == 1)
        #expect(await transfer.consumerCount == 0)
    }
    @Test func simultaneousDisplayVariantsDownloadOnceAndLaterSizesUseDisk() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = AppleArtworkDiskCache(directory: directory)
        let context = try #require(CGContext(data: nil, width: 512, height: 768, bitsPerComponent: 8,
            bytesPerRow: 512 * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let probe = TransferProbe(data: try #require(AppleRemoteImageDecoder.displayData(image)))
        let transfer = AppleArtworkDownload()
        let url = try #require(URL(string: "https://fixture.example/source.png"))
        let download: AppleRemoteImageCache.DataLoader = { request in
            try await transfer.data(for: request, download: { try await probe.load($0) })
        }
        let small = Task { try await AppleRemoteImageCache.load(url: url, maximumPixelDimension: 128, disk: disk, download: download) }
        await probe.waitForStarts(1)
        let large = Task { try await AppleRemoteImageCache.load(url: url, maximumPixelDimension: 512, disk: disk, download: download) }
        while await transfer.consumerCount < 2 { await Task.yield() }
        // The loader sets a timeout; use its actual request as the transfer identity.
        try await probe.finish(try #require(await probe.started.first))
        #expect(try await small.value.height == 128)
        #expect(try await large.value.height == 512)
        _ = try await AppleRemoteImageCache.load(url: url, maximumPixelDimension: 256, disk: disk, download: download)
        #expect(await probe.loads == 1)
        for pixels in [128, 256, 512] {
            while await disk.data(for: url, variant: AppleArtworkSizePolicy.displayVariant(pixels)) == nil { await Task.yield() }
        }
    }

    @Test func cancellationRemovesQueuedTransfersAndReleasesTheRunningHost() async throws {
        let probe = TransferProbe()
        let transfer = AppleArtworkDownload(maximumConcurrentLoadsPerHost: 1)
        let requests = try (0..<3).map { URLRequest(url: try #require(URL(string: "https://fixture.example/cancel-\($0)"))) }
        let first = Task { try await transfer.data(for: requests[0], download: { try await probe.load($0) }) }
        await probe.waitForStarts(1)
        let obsolete = Task { try await transfer.data(for: requests[1], download: { try await probe.load($0) }) }
        while await transfer.consumerCount < 2 { await Task.yield() }
        obsolete.cancel()
        await #expect(throws: CancellationError.self) { try await obsolete.value }
        let next = Task { try await transfer.data(for: requests[2], download: { try await probe.load($0) }) }
        while await transfer.consumerCount < 2 { await Task.yield() }
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        await probe.waitForStarts(2)
        #expect(await probe.started == [requests[0], requests[2]])
        try await probe.finish(requests[2])
        _ = try await next.value
    }

    @Test func saturatedHostLeavesOtherHostsResponsive() async throws {
        let probe = TransferProbe()
        let transfer = AppleArtworkDownload(maximumConcurrentLoadsPerHost: 1)
        let requests = try ["https://first.fixture.example/one", "https://first.fixture.example/two",
                            "https://second.fixture.example/one"].map { URLRequest(url: try #require(URL(string: $0))) }
        let first = Task { try await transfer.data(for: requests[0], download: { try await probe.load($0) }) }
        await probe.waitForStarts(1)
        let queued = Task { try await transfer.data(for: requests[1], download: { try await probe.load($0) }) }
        while await transfer.consumerCount < 2 { await Task.yield() }
        let other = Task { try await transfer.data(for: requests[2], download: { try await probe.load($0) }) }
        await probe.waitForStarts(2)
        #expect(await probe.started == [requests[0], requests[2]])
        try await probe.finish(requests[0])
        await probe.waitForStarts(3)
        #expect(await probe.started.last == requests[1])
        try await probe.finish(requests[1])
        try await probe.finish(requests[2])
        for task in [first, queued, other] { _ = try await task.value }
    }

    @Test func foregroundArtSkipsTheHostQueueAndVisibleNeverWaitsForPrefetch() async throws {
        let probe = TransferProbe()
        let transfer = AppleArtworkDownload(maximumConcurrentLoadsPerHost: 1)
        let requests = try ["row-1", "row-2", "tile", "title-backdrop"]
            .map { URLRequest(url: try #require(URL(string: "https://fixture.example/\($0)"))) }
        func fetch(_ index: Int, _ priority: AppleArtworkRequestQueue.Priority) -> Task<(Data, URLResponse), any Error> {
            Task {
                try await AppleArtworkDownload.$priority.withValue(priority) {
                    try await transfer.data(for: requests[index], download: { try await probe.load($0) })
                }
            }
        }
        let tasks = [fetch(0, .prefetch)]
        await probe.waitForStarts(1)
        let queued = [fetch(1, .prefetch), fetch(2, .visible)]
        while await transfer.consumerCount < 3 { await Task.yield() }
        // The tile starts beside the running prefetch; the second prefetch waits.
        await probe.waitForStarts(2)
        #expect(await probe.started == [requests[0], requests[2]])
        let title = fetch(3, .foreground)
        await probe.waitForStarts(3)
        #expect(await probe.started.last == requests[3])
        // Prefetch still counts the visible transfer against the host.
        try await probe.finish(requests[0])
        try await probe.finish(requests[2])
        await probe.waitForStarts(4)
        #expect(await probe.started.last == requests[1])
        for index in [1, 3] { try await probe.finish(requests[index]) }
        for task in tasks + queued + [title] { _ = try await task.value }
    }

    @Test func promotedPrefetchStartsBeforeEarlierVisibleWork() async throws {
        let probe = TransferProbe()
        let transfer = AppleArtworkDownload(maximumConcurrentLoadsPerHost: 1)
        let requests = try ["running", "tile", "hero"]
            .map { URLRequest(url: try #require(URL(string: "https://fixture.example/\($0)"))) }
        func fetch(_ index: Int, _ priority: AppleArtworkRequestQueue.Priority) -> Task<(Data, URLResponse), any Error> {
            Task {
                try await AppleArtworkDownload.$priority.withValue(priority) {
                    try await transfer.data(for: requests[index], download: { try await probe.load($0) })
                }
            }
        }
        let running = fetch(0, .visible)
        await probe.waitForStarts(1)
        let tile = fetch(1, .visible)
        while await transfer.consumerCount < 2 { await Task.yield() }
        let hero = fetch(2, .prefetch)
        while await transfer.consumerCount < 3 { await Task.yield() }
        await transfer.promote(url: try #require(requests[2].url), to: .visible)
        try await probe.finish(requests[0])
        await probe.waitForStarts(2)
        #expect(await probe.started.last == requests[1], "equal priority keeps arrival order")
        await transfer.promote(url: try #require(requests[2].url), to: .foreground)
        await probe.waitForStarts(3)
        #expect(await probe.started.last == requests[2])
        for index in [1, 2] { try await probe.finish(requests[index]) }
        for task in [running, tile, hero] { _ = try await task.value }
    }
}

private actor TransferProbe {
    let data: Data
    init(data: Data = Data([1, 2, 3])) { self.data = data }
    private(set) var started: [URLRequest] = []
    var loads: Int { started.count }
    private var observer: (count: Int, continuation: CheckedContinuation<Void, Never>)?
    private var results: [URLRequest: CheckedContinuation<(Data, URLResponse), any Error>] = [:]

    func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                results[request] = $0
                started.append(request)
                if let observer, started.count >= observer.count {
                    self.observer = nil
                    observer.continuation.resume()
                }
            }
        } onCancel: {
            Task { await self.cancel(request) }
        }
    }

    private func cancel(_ request: URLRequest) {
        results.removeValue(forKey: request)?.resume(throwing: CancellationError())
    }

    func waitForStarts(_ count: Int) async {
        if started.count >= count { return }
        await withCheckedContinuation { observer = (count, $0) }
    }

    func finish(_ request: URLRequest) throws {
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        results.removeValue(forKey: request)?.resume(returning: (data, response))
    }
}
