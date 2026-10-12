import Foundation
import Synchronization
import Testing
@testable import OpenStreamApple

@Suite("Guide robustness")
struct AppleIPTVGuideRobustnessTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["OPENSTREAM_GUIDE_CACHE_BENCHMARK"] == "1"),
          .timeLimit(.minutes(1)))
    func largeParsedGuideCacheRoundTripMeasurement() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = AppleIPTVGuideDiskCache(directory: directory)
        let now = Date()
        let programmes = (0..<200_000).map { index in
            let start = now.addingTimeInterval(Double(index % 31 - 15) * 86_400)
            return AppleIPTVProgramme(id: "p\(index)", channelID: "c\(index % 1000)", title: "Programme \(index)",
                subtitle: nil, description: "Synthetic guide programme for measurement", start: start,
                end: start.addingTimeInterval(3600), category: "Fixture", isLive: false)
        }
        let clock = ContinuousClock()
        let writeStart = clock.now
        await cache.store(programmes, key: "benchmark", fetchedAt: now, isRawXMLTV: true)
        print("GUIDE_CACHE_WRITE \(writeStart.duration(to: clock.now))")
        for _ in 0..<3 {
            let readStart = clock.now
            let restored = await cache.snapshot(key: "benchmark", now: now)
            print("GUIDE_CACHE_READ \(readStart.duration(to: clock.now)) records=\(restored.programmes.count)")
            #expect(!restored.programmes.isEmpty && restored.programmes.count <= programmes.count)
            #expect(restored.fetchedAt == now)
        }
    }

    @Test func missingOffsetUsesConfiguredZoneAndExplicitOffsetWins() throws {
        let xml = Data("""
        <tv>
        <programme channel="a" start="20301005090000" stop="20301005100000"><title>Local</title></programme>
        <programme channel="a" start="20301005090000 +0000" stop="20301005100000 +0000"><title>UTC</title></programme>
        <programme channel="a" start="bad" stop="20301005100000"><title>Bad</title></programme>
        <programme channel="a" start="20301005110000" stop="20301005100000"><title>Reversed</title></programme>
        </tv>
        """.utf8)
        let programmes = AppleIPTVGuideXMLTVParser().parse(data: xml, defaultOffsetHours: -5)
        #expect(programmes.count == 2)
        let local = try #require(programmes.first { $0.title == "Local" })
        let utc = try #require(programmes.first { $0.title == "UTC" })
        #expect(local.start.timeIntervalSince(utc.start) == 5 * 3600)
    }

    @MainActor @Test func xmltvFileFreshnessConditionalAndChangedResponses() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = AppleIPTVGuideDiskCache(directory: directory)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FreshGuideProtocol.self]
        FreshGuideProtocol.requests.withLock { $0 = [] }
        let store = AppleIPTVGuideStore(loader: AppleIPTVGuideLoader(session: URLSession(configuration: config)), diskCache: disk)
        let url = URL(string: "https://fixture.example/fresh.xml")!
        let now = try #require(AppleIPTVGuideXMLTVParser.parseDate("20301005090000 +0000", defaultOffsetHours: 0))
        store.configure(xmltvURL: url)
        await store.refreshVisible(channelIDs: ["a"], now: now)
        let file = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .first { !$0.lastPathComponent.contains(".day.") })
        let original = try Data(contentsOf: file)
        let saved = try JSONDecoder().decode(AppleIPTVGuideDiskCache.Snapshot.self, from: original)
        #expect(saved.eTag == "v1")
        #expect(saved.lastModified == "Mon, 05 Oct 2026 12:00:00 GMT")
        #expect(saved.fetchedAt == now)
        await store.refreshVisible(channelIDs: ["b"], now: now.addingTimeInterval(3599 * 6))
        #expect(FreshGuideProtocol.requests.withLock { $0.count } == 1)
        #expect(store.guide(for: ["b"]).allProgrammes.first?.title == "Original")
        await store.refreshVisible(channelIDs: ["a"], now: now.addingTimeInterval(6 * 3600))
        #expect(FreshGuideProtocol.requests.withLock { $0.count } == 2)
        #expect(try Data(contentsOf: file) == original) // 304 never rewrites the snapshot
        #expect(store.guide(for: ["a"]).allProgrammes.first?.title == "Original")
        await store.refreshVisible(channelIDs: ["a"], now: now.addingTimeInterval(7 * 3600))
        #expect(FreshGuideProtocol.requests.withLock { $0.count } == 2)
        await store.refreshVisible(channelIDs: ["a"], force: true, now: now.addingTimeInterval(7 * 3600))
        #expect(store.guide(for: ["a"]).allProgrammes.first?.title == "Changed")
        #expect(try Data(contentsOf: file) != original)
        let requests = FreshGuideProtocol.requests.withLock { $0 }
        #expect(requests[1].value(forHTTPHeaderField: "If-None-Match") == "v1")
        #expect(requests[1].value(forHTTPHeaderField: "If-Modified-Since") == "Mon, 05 Oct 2026 12:00:00 GMT")
        let changed = try Data(contentsOf: file)
        await store.refreshVisible(channelIDs: ["a"], force: true, now: now.addingTimeInterval(8 * 3600))
        #expect(try Data(contentsOf: file) == changed) // identical 200 also avoids parse/write
        // A changed configuration must fetch even while the old file was fresh.
        store.configure(xmltvURL: URL(string: "https://fixture.example/other.xml")!)
        await store.refreshVisible(channelIDs: ["a"], now: now.addingTimeInterval(7 * 3600))
        #expect(FreshGuideProtocol.requests.withLock { $0.count } == 5)
        #expect(FreshGuideProtocol.requests.withLock { $0.last?.value(forHTTPHeaderField: "If-None-Match") } == nil)
    }

    @Test func fixedXMLTVDatesMatchTheFormerFormatters() throws {
        let samples = [
            "20301005090000", "20301005090000 +0000", "20301005090000 +0530",
            "20301005090000 -0330", "20000229000000 +1400", "19691231235959 -1200",
            "20240229000000", "21000301000000", " 20301005090000 +0200 ",
            "19700101000000 +0000", "19000228000000 +0000", "19000229000000 +0000",
            "20301005090000 +1245", "20301231235959 -1200",
            "20300230090000", "20301301090000", "bad"
        ]
        for offset in [-20.0, -5, -5.501, -0.008333333333333333, 0.001, 0.008333333333333333, 5.5, 5.501, 20, .infinity] {
            let withOffset = DateFormatter()
            withOffset.dateFormat = "yyyyMMddHHmmss Z"
            withOffset.locale = Locale(identifier: "en_US_POSIX")
            withOffset.isLenient = false
            let withoutOffset = DateFormatter()
            withoutOffset.dateFormat = "yyyyMMddHHmmss"
            withoutOffset.locale = Locale(identifier: "en_US_POSIX")
            withoutOffset.timeZone = TimeZone(secondsFromGMT: Int((offset.isFinite ? min(14, max(-12, offset)) : 0) * 3600))
            withoutOffset.isLenient = false
            for sample in samples {
                let trimmed = sample.trimmingCharacters(in: .whitespacesAndNewlines)
                let expected = withOffset.date(from: trimmed) ?? withoutOffset.date(from: trimmed)
                #expect(AppleIPTVGuideXMLTVParser.parseDate(sample, defaultOffsetHours: offset) == expected)
            }
        }
        let xml = Data("<tv><programme channel=\"a\" start=\"20301005090000 +0000\" stop=\"20301005100000 +0000\"><title>Stable</title></programme></tv>".utf8)
        let first = try #require(AppleIPTVGuideXMLTVParser().parse(data: xml).first)
        let second = try #require(AppleIPTVGuideXMLTVParser().parse(data: xml).first)
        #expect(first.id == "a|\(Int64(first.start.timeIntervalSince1970))")
        #expect(first.id == second.id)
    }

    @Test func cacheExpiresByProgrammeEndAndKeepsFutureData() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = AppleIPTVGuideDiskCache(directory: directory)
        let now = Date(timeIntervalSince1970: 1000)
        func programme(_ id: String, end: Date) -> AppleIPTVProgramme {
            AppleIPTVProgramme(id: id, channelID: "a", title: id, subtitle: nil, description: nil,
                start: now.addingTimeInterval(-100), end: end, category: nil, isLive: false)
        }
        await cache.store([programme("old", end: now), programme("next", end: now.addingTimeInterval(60))], key: "fixture")
        let restored = await cache.programmes(key: "fixture", now: now)
        #expect(restored.map(\.id) == ["next"])
        #expect(await cache.programmes(key: "other", now: now).isEmpty)
        #expect(await cache.programmes(key: "fixture", now: now.addingTimeInterval(60)).isEmpty)
    }

    @Test func rawGuidePrunesShardsMigratesLegacyAndRejectsIncompleteGeneration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        func programme(_ day: Int) -> AppleIPTVProgramme {
            let start = now.addingTimeInterval(Double(day) * 86_400)
            return AppleIPTVProgramme(id: "p\(day)", channelID: "a", title: "Fixture", subtitle: nil, description: nil,
                start: start, end: start.addingTimeInterval(3600), category: nil, isLive: false)
        }
        let manifest = directory.appendingPathComponent(ApplePlaybackIdentity.digest(for: "legacy") + ".json")
        let legacy = AppleIPTVGuideDiskCache.Snapshot(programmes: [-4, -3, 0, 6, 7, 8].map(programme),
            channelNames: ["a": "Fixture"], fetchedAt: now, eTag: "fixture-etag", isRawXMLTV: true)
        try JSONEncoder().encode(legacy).write(to: manifest)
        let cache = AppleIPTVGuideDiskCache(directory: directory)
        let restored = await cache.snapshot(key: "legacy", now: now)
        #expect(Set(restored.programmes.map(\.id)) == ["p-3", "p0", "p6"])
        #expect(restored.eTag == "fixture-etag" && restored.channelNames == ["a": "Fixture"])
        let saved = try JSONDecoder().decode(AppleIPTVGuideDiskCache.Snapshot.self, from: Data(contentsOf: manifest))
        #expect(saved.programmes.isEmpty && saved.shardDays?.count == 3)
        #expect(saved.shardGeneration != nil && saved.binaryShards == true)
        #expect(await cache.snapshot(key: "legacy", now: now).programmes.count == 3)
        await cache.store([programme(0)], key: "legacy", fetchedAt: now, isRawXMLTV: true)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let shard = try #require(files.first { $0.lastPathComponent.contains(".day.") })
        #expect(files.count == 2) // Old generations are removed after publishing.
        #expect(try Data(contentsOf: shard).starts(with: Data("bplist00".utf8)))
        try FileManager.default.removeItem(at: shard)
        #expect(await cache.snapshot(key: "legacy", now: now).isRawXMLTV == nil)
        #expect(await cache.snapshot(key: "legacy", now: now).programmes.isEmpty)
    }
    @MainActor @Test func xmltvRefreshPopulatesMoreThanFiftyChannelsAndRestoresWithoutNetwork() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = AppleIPTVGuideDiskCache(directory: directory)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RobustGuideProtocol.self]
        let loader = AppleIPTVGuideLoader(session: URLSession(configuration: config))
        let source = UUID()
        let mapping = Dictionary(uniqueKeysWithValues: (0..<80).map { (source.uuidString + ":" + String($0), "p" + String($0)) })
        let url = URL(string: "https://fixture.example/guide.xml")!
        RobustGuideProtocol.requests.withLock { $0 = 0 }
        let first = AppleIPTVGuideStore(loader: loader, diskCache: disk)
        let now = try #require(AppleIPTVGuideXMLTVParser.parseDate("20301005090000 +0000", defaultOffsetHours: 0))
        first.configure(xmltvURL: url, sourceID: source, channelMapping: mapping, timeShiftHours: 2)
        await first.refreshVisible(channelIDs: [source.uuidString + ":0"], now: now)
        #expect(first.guide(for: mapping.keys).allProgrammes.count == 80)
        let original = AppleIPTVGuideXMLTVParser().parse(data: Data("<tv><programme channel=\"p0\" start=\"20301005090000 +0000\" stop=\"20301005100000 +0000\"><title>Programme 0</title></programme></tv>".utf8))
        #expect(first.guide(for: mapping.keys).allProgrammes.first?.start == original.first?.start.addingTimeInterval(7200))
        let relaunched = AppleIPTVGuideStore(loader: loader, diskCache: disk)
        relaunched.configure(xmltvURL: url, sourceID: source, channelMapping: mapping, timeShiftHours: 2)
        await relaunched.refreshVisible(channelIDs: Set(mapping.keys), now: now)
        #expect(relaunched.guide(for: mapping.keys).allProgrammes.count == 80)
        #expect(RobustGuideProtocol.requests.withLock { $0 } == 1)
    }

}


private final class RobustGuideProtocol: URLProtocol {
    static let requests = Mutex(0)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.withLock { $0 += 1 }
        let entries = (0..<80).map { index in
            "<programme channel=\"p\(index)\" start=\"20301005090000 +0000\" stop=\"20301005100000 +0000\"><title>Programme \(index)</title></programme>"
        }.joined()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(("<tv>" + entries + "</tv>").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class FreshGuideProtocol: URLProtocol {
    static let requests = Mutex<[URLRequest]>([])
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let count = Self.requests.withLock { $0.append(request); return $0.count }
        let status = count == 2 ? 304 : 200
        let title = count < 3 ? "Original" : "Changed"
        let entries = ["a", "b"].map {
            "<programme channel=\"\($0)\" start=\"20301005090000 +0000\" stop=\"20301005100000 +0000\"><title>\(title)</title></programme>"
        }.joined()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["ETag": count < 3 ? "v1" : "v2", "Last-Modified": "Mon, 05 Oct 2026 12:00:00 GMT"])!, cacheStoragePolicy: .notAllowed)
        if status != 304 { client?.urlProtocol(self, didLoad: Data(("<tv>" + entries + "</tv>").utf8)) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
