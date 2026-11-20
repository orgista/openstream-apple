import CoreGraphics
import Foundation
import Synchronization
import Testing
@testable import OpenStreamApple

@Suite("Artwork cache recovery")
struct AppleArtworkCacheRecoveryTests {
    @Test(.timeLimit(.minutes(1)), arguments: ["raw", "display-128"])
    func corruptEntryIsEvictedAndRefetchedOnce(variant: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try #require(URL(string: "https://fixture.example/poster.png"))
        let disk = AppleArtworkDiskCache(directory: directory)
        await disk.store(Data("not an image".utf8), for: url, variant: variant)
        let payload = try imageData()
        let calls = Mutex(0)
        let image = try await AppleRemoteImageCache.load(url: url, maximumPixelDimension: 128, disk: disk) { request in
            let count = calls.withLock { $0 += 1; return $0 }
            #expect(count == 1)
            #expect(await disk.data(for: url, variant: variant) == nil)
            #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
            guard count == 1 else { throw URLError(.unknown) }
            return (payload, try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
        #expect(image.width == 16)
        #expect(image.height == 24)
        #expect(calls.withLock { $0 } == 1)
        #expect(await disk.data(for: url, variant: "raw") == payload)
        // Join the existing asynchronous display/colour persistence before removing the fixture directory.
        await waitFor("display cache write") { await disk.contains(url: url, variant: "display-128") }
        let cached = try await AppleRemoteImageCache.load(url: url, maximumPixelDimension: 128, disk: disk) { _ in
            Issue.record("A repaired entry must be reused")
            throw URLError(.unknown)
        }
        #expect(cached.width == image.width)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func invalidHTTPPayloadIsNotCachedOrRetried(hasCorruptCache: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try #require(URL(string: "https://fixture.example/poster.png"))
        let disk = AppleArtworkDiskCache(directory: directory)
        if hasCorruptCache { await disk.store(Data("bad cache".utf8), for: url, variant: "raw") }
        let calls = Mutex(0)
        await #expect(throws: URLError(.cannotDecodeContentData)) {
            _ = try await AppleRemoteImageCache.load(url: url, maximumPixelDimension: 128, disk: disk) { _ in
                let count = calls.withLock { $0 += 1; return $0 }
                #expect(count == 1)
                guard count == 1 else { throw URLError(.unknown) }
                return (Data("<html>unavailable</html>".utf8),
                    try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
            }
        }
        #expect(calls.withLock { $0 } == 1)
        #expect(await disk.data(for: url, variant: "raw") == nil)
        #expect(await disk.data(for: url, variant: "display-128") == nil)
    }

    @Test(.timeLimit(.minutes(1))) func cancelledAfterDownloadStillCachesValidatedImage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try #require(URL(string: "https://fixture.example/poster.png"))
        let disk = AppleArtworkDiskCache(directory: directory)
        let payload = try imageData()
        let task = Task {
            try await AppleRemoteImageCache.load(url: url, maximumPixelDimension: 128, disk: disk) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return (payload, try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await disk.data(for: url, variant: "raw") == payload)
        await waitFor("display and colour writes after cancellation") {
            let hasDisplay = await disk.contains(url: url, variant: "display-128")
            let colour = await disk.colour(for: url)
            return hasDisplay && colour != nil
        }
        let cached = try await AppleRemoteImageCache.load(url: url, maximumPixelDimension: 128, disk: disk) { _ in
            Issue.record("A cancelled tile's validated download must be reused")
            throw URLError(.unknown)
        }
        #expect(cached.width == 16)
        #expect(cached.height == 24)
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["raw", "display-128"])
    func failedEvictionStillRefetchesOnce(variant: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = try #require(URL(string: "https://fixture.example/poster.png"))
        let disk = AppleArtworkDiskCache(directory: directory)
        await disk.store(Data("corrupt".utf8), for: url, variant: variant)
        let file = directory.appendingPathComponent(AppleArtworkDiskCachePolicy.fileName(for: url, variant: variant))
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file.path)
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: file.path)
        let payload = try imageData()
        let calls = Mutex(0)
        let image = try await AppleRemoteImageCache.load(url: url, maximumPixelDimension: 128, disk: disk) { request in
            let count = calls.withLock { $0 += 1; return $0 }
            #expect(count == 1)
            #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
            guard count == 1 else { throw URLError(.unknown) }
            #expect(FileManager.default.fileExists(atPath: file.path))
            try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file.path)
            return (payload, try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
        #expect(image.width == 16)
        #expect(calls.withLock { $0 } == 1)
        await waitFor("repaired display cache write") {
            let stored = await disk.data(for: url, variant: "display-128")
            return stored.flatMap(AppleRemoteImageDecoder.displayImage) != nil
        }
    }

    private func imageData() throws -> Data {
        let context = try #require(CGContext(data: nil, width: 16, height: 24, bitsPerComponent: 8,
            bytesPerRow: 16 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 24))
        let image = try #require(context.makeImage())
        return try #require(AppleRemoteImageDecoder.displayData(image))
    }
}
