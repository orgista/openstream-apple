import Foundation
import Testing
@testable import OpenStreamApple

@Suite("AppleArtworkDiskCache")
struct AppleArtworkDiskCacheTests {
    @Test("fileName is stable, hex, ends with variant, differs per variant and URL")
    func fileName() {
        let url1 = URL(string: "https://example.com/image1.jpg")!
        let url2 = URL(string: "https://example.com/image2.jpg")!

        let name1Raw = AppleArtworkDiskCachePolicy.fileName(for: url1, variant: "raw")
        let name1Logo = AppleArtworkDiskCachePolicy.fileName(for: url1, variant: "logo-trimmed")
        let name2Raw = AppleArtworkDiskCachePolicy.fileName(for: url2, variant: "raw")

        #expect(name1Raw.hasSuffix("-raw.bin"))
        #expect(name1Logo.hasSuffix("-logo-trimmed.bin"))
        #expect(name1Raw != name1Logo)
        #expect(name1Raw != name2Raw)

        // Check it's hex before the dash
        let hexPart = name1Raw.components(separatedBy: "-").first!
        #expect(hexPart.count == 64)
        #expect(hexPart.allSatisfy { $0.isHexDigit })
    }

    @Test("evictionOrder respects limit and LRU")
    func evictionOrder() {
        let entries: [(name: String, bytes: Int, modified: Date)] = [
            ("file1", 100, Date(timeIntervalSince1970: 1000)), // oldest
            ("file2", 200, Date(timeIntervalSince1970: 3000)), // newest
            ("file3", 150, Date(timeIntervalSince1970: 2000))
        ]

        // Total is 450. Under limit (500) -> none evicted.
        let none = AppleArtworkDiskCachePolicy.evictionOrder(entries, limit: 500)
        #expect(none.isEmpty)

        // Limit 300. Needs to evict 150.
        // Oldest is file1 (100). Remaining 350 > 300.
        // Next oldest is file3 (150). Remaining 200 <= 300. Stops.
        let some = AppleArtworkDiskCachePolicy.evictionOrder(entries, limit: 300)
        #expect(some == ["file1", "file3"])
    }
    @Test("round trip and modification date update")
    func integration() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cache = AppleArtworkDiskCache(directory: tempDir)
        let url = URL(string: "https://example.com/art.jpg")!
        let data = Data([0x01, 0x02, 0x03])

        // Store
        await cache.store(data, for: url, variant: "raw")

        // Read back
        let readData = await cache.data(for: url, variant: "raw")
        #expect(readData == data)

        // Missing variant returns nil
        let missingData = await cache.data(for: url, variant: "logo-trimmed")
        #expect(missingData == nil)

        // Check modification date update
        let name = AppleArtworkDiskCachePolicy.fileName(for: url, variant: "raw")
        let fileURL = tempDir.appendingPathComponent(name)
        let attrs1 = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let modDate1 = attrs1[.modificationDate] as! Date

        try await Task.sleep(nanoseconds: 10_000_000) // 10ms

        _ = await cache.data(for: url, variant: "raw")

        let attrs2 = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let modDate2 = attrs2[.modificationDate] as! Date

        #expect(modDate2 > modDate1)

        try? FileManager.default.removeItem(at: tempDir)
    }
}
