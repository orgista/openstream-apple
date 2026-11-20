import Foundation
import Synchronization
import Testing
@testable import OpenStreamApple

struct AppleArtworkFailureCacheTests {
    @Test(arguments: [404, 410])
    func missingArtworkIsNotRefetchedAtOtherSizesOrAfterRelaunch(status: Int) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try #require(URL(string: "https://fixture.example/missing-logo.png"))
        let calls = Mutex(0)
        let download: AppleRemoteImageCache.DataLoader = { _ in
            calls.withLock { $0 += 1 }
            return (Data(), try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)))
        }
        let disk = AppleArtworkDiskCache(directory: directory)
        for pixels in [64, 128, 256, 64] {
            await #expect(throws: URLError(.cannotDecodeContentData)) {
                _ = try await AppleRemoteImageCache.load(url: url, maximumPixelDimension: pixels, disk: disk, download: download)
            }
        }
        let relaunched = AppleArtworkDiskCache(directory: directory)
        await #expect(throws: URLError(.cannotDecodeContentData)) {
            _ = try await AppleRemoteImageCache.load(url: url, maximumPixelDimension: 128, disk: relaunched, download: download)
        }
        #expect(calls.withLock { $0 } == 1)
        await relaunched.clearFailures()
        await #expect(throws: URLError(.cannotDecodeContentData)) {
            _ = try await AppleRemoteImageCache.load(url: url, maximumPixelDimension: 128, disk: relaunched, download: download)
        }
        #expect(calls.withLock { $0 } == 2)
    }

    @Test func failuresExpireAfterOneDayAndRefreshAllowsAnotherRequest() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = AppleArtworkDiskCache(directory: directory)
        let url = try #require(URL(string: "https://fixture.example/logo.png"))
        let now = Date(timeIntervalSince1970: 1_000_000)
        let generation = await disk.failureGeneration
        await disk.recordFailure(for: url, generation: generation, now: now)
        #expect(await disk.containsFailure(for: url, now: now.addingTimeInterval(86_399)))
        #expect(await disk.containsFailure(for: url, now: now.addingTimeInterval(86_400)) == false)
        await disk.recordFailure(for: url, generation: generation)
        await disk.clearFailures()
        #expect(await disk.containsFailure(for: url) == false)
        await disk.recordFailure(for: url, generation: generation)
        #expect(await disk.containsFailure(for: url) == false)
        await disk.recordFailure(for: url, generation: await disk.failureGeneration)
        #expect(await disk.containsFailure(for: url))
    }

    @Test func transientFailuresDoNotPoisonTheArtworkURL() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = AppleArtworkDiskCache(directory: directory)
        let url = try #require(URL(string: "https://fixture.example/logo.png"))
        let calls = Mutex(0)
        for _ in 0..<2 {
            await #expect(throws: URLError(.cannotDecodeContentData)) {
                _ = try await AppleRemoteImageCache.load(url: url, maximumPixelDimension: 128, disk: disk) { _ in
                    calls.withLock { $0 += 1 }
                    return (Data(), try #require(HTTPURLResponse(url: url, statusCode: 503, httpVersion: nil, headerFields: nil)))
                }
            }
        }
        #expect(calls.withLock { $0 } == 2)
        #expect(await disk.containsFailure(for: url) == false)
    }

    @Test func sourceRefreshPreservesOtherArtworkFailures() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = AppleArtworkDiskCache(directory: directory)
        let refreshed = try #require(URL(string: "https://fixture.example/source-a/logo.png"))
        let unrelated = try #require(URL(string: "https://fixture.example/source-b/logo.png"))
        let generation = await disk.failureGeneration
        await disk.recordFailure(for: refreshed, generation: generation)
        await disk.recordFailure(for: unrelated, generation: generation)
        await disk.clearFailures(for: [refreshed])
        let relaunched = AppleArtworkDiskCache(directory: directory)
        #expect(await relaunched.containsFailure(for: refreshed) == false)
        #expect(await relaunched.containsFailure(for: unrelated))
        await disk.recordFailure(for: refreshed, generation: generation)
        #expect(await disk.containsFailure(for: refreshed) == false)
    }

    @Test func anIndexedMissDoesNotReadANewFailureFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let disk = AppleArtworkDiskCache(directory: directory)
        let url = try #require(URL(string: "https://fixture.example/logo.png"))
        await disk.trimIfNeeded()
        let file = directory.appendingPathComponent(AppleArtworkDiskCachePolicy.fileName(for: url, variant: "failure"))
        try JSONEncoder().encode(Date.now.addingTimeInterval(86_400)).write(to: file)
        #expect(await disk.containsFailure(for: url) == false)
        #expect(await AppleArtworkDiskCache(directory: directory).containsFailure(for: url))
        await disk.recordFailure(for: url, generation: await disk.failureGeneration)
        #expect(await disk.containsFailure(for: url))
    }
}
