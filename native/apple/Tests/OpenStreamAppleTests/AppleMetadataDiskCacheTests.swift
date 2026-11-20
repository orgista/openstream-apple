import Testing
import Foundation
@testable import OpenStreamApple

@Suite("AppleMetadataDiskCache Tests", .timeLimit(.minutes(1)))
struct AppleMetadataDiskCacheTests {
    @Test("Cache filenames distinguish complete provider endpoints without exposing them")
    func fileNameRules() throws {
        let endpoint = try #require(URL(string: "https://fixture.example/config-one/movie/tt12345.json"))
        let otherEndpoint = try #require(URL(string: "https://fixture.example/config-two/movie/tt12345.json"))
        let name = AppleMetadataDiskCachePolicy.fileName(source: endpoint.absoluteString, type: "movie", mediaID: "tt12345")
        #expect(name != AppleMetadataDiskCachePolicy.fileName(source: endpoint.absoluteString, type: "series", mediaID: "tt12345"))
        #expect(name != AppleMetadataDiskCachePolicy.fileName(source: endpoint.absoluteString, type: "movie", mediaID: "tt54321"))
        #expect(name != AppleMetadataDiskCachePolicy.fileName(source: otherEndpoint.absoluteString, type: "movie", mediaID: "tt12345"))
        #expect(name == AppleMetadataDiskCachePolicy.fileName(source: endpoint.absoluteString, type: "movie", mediaID: "tt12345"))
        #expect(name.hasSuffix(".json"))
        #expect(name.dropLast(5).count == 64)
        #expect(name.dropLast(5).allSatisfy { $0.isHexDigit })
        #expect(!name.contains("fixture"))
        #expect(!name.contains("config-one"))
    }

    @Test("Freshness boundaries")
    func freshnessBoundaries() {
        let now = Date()
        #expect(AppleMetadataDiskCachePolicy.freshness(storedAt: now.addingTimeInterval(-3600), now: now) == .fresh)
        #expect(AppleMetadataDiskCachePolicy.freshness(storedAt: now.addingTimeInterval(-48 * 3600), now: now) == .stale)
        #expect(AppleMetadataDiskCachePolicy.freshness(storedAt: now.addingTimeInterval(-15 * 24 * 3600), now: now) == .expired)
    }

    @Test("Round trip store and fetch removes only its expired entry")
    func roundTrip() async throws {
        let temp = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let cache = AppleMetadataDiskCache(directory: temp)
        let endpoint = try #require(URL(string: "https://fixture.example/movie/test1.json"))
        let data = Data("payload".utf8)
        await cache.store(data, source: endpoint.absoluteString, type: "movie", mediaID: "test1")
        let entry = await cache.entry(source: endpoint.absoluteString, type: "movie", mediaID: "test1")
        #expect(entry?.payload == data)
        #expect(entry?.freshness == .fresh)

        let expiredName = AppleMetadataDiskCachePolicy.fileName(source: endpoint.absoluteString, type: "movie", mediaID: "expired")
        let expiredURL = temp.appendingPathComponent(expiredName)
        let expiredEntry = AppleMetadataDiskCache.Entry(
            storedAt: Date().addingTimeInterval(-15 * 24 * 3600), payload: Data("old".utf8)
        )
        try JSONEncoder().encode(expiredEntry).write(to: expiredURL)
        #expect(await cache.entry(source: endpoint.absoluteString, type: "movie", mediaID: "expired") == nil)
        #expect(!FileManager.default.fileExists(atPath: expiredURL.path))
        #expect(await cache.entry(source: endpoint.absoluteString, type: "movie", mediaID: "test1") != nil)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("OpenStreamMetadataTests-\(UUID().uuidString)")
    }
}
