import Foundation
import Testing
import UniformTypeIdentifiers
@testable import OpenStreamApple

@Suite
struct AppleChannelHealthPresentationTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func channel(_ id: String) -> AppleIPTVChannel {
        .init(id: id, sourceID: UUID(), name: "Channel \(id)",
              streamURL: URL(string: "https://fixture.example/\(id.count)/live.m3u8")!)
    }

    private func result(_ id: String, _ bucket: AppleChannelHealthBucket, ago: TimeInterval = 60,
                        status: Int? = 200, stage: AppleSavedSourceDiagnosticStage? = nil) -> AppleChannelHealthResult {
        .init(channelID: id, bucket: bucket, failedStage: stage, httpStatus: status, ttfbMs: 140,
              checkedAt: now.addingTimeInterval(-ago))
    }

    // MARK: Dot mapping

    static let dots: [(AppleChannelHealthBucket, AppleChannelHealthIndicator?)] = [
        (.online, nil), (.reachable, .notPlayable), (.offline, .offline), (.timeout, .offline),
    ]

    @Test(arguments: dots)
    func bucketMapsToDot(bucket: AppleChannelHealthBucket, expected: AppleChannelHealthIndicator?) {
        #expect(AppleChannelHealthIndicator(bucket: bucket) == expected)
    }

    @Test func uncheckedChannelHasNoDot() {
        #expect(AppleChannelHealthIndicator(result: nil) == nil)
    }

    @Test func dotsSpeakPlainLabels() {
        #expect(AppleChannelHealthIndicator.offline.accessibilityLabel == "Offline")
        #expect(AppleChannelHealthIndicator.notPlayable.accessibilityLabel == "Not playable")
    }

    // MARK: Summary line

    static let times: [(TimeInterval, String)] = [
        (30, "just now"), (60, "1m ago"), (3540, "59m ago"),
        (7200, "2h ago"), (86_399, "23h ago"), (259_200, "3d ago"), (-5, "just now"),
    ]

    @Test(arguments: times)
    func relativeTime(seconds: TimeInterval, expected: String) {
        #expect(AppleChannelHealthTime.ago(now.addingTimeInterval(-seconds), now: now) == expected)
    }

    @Test func summaryCountsWorkingChannelsOfTheWholeLineup() {
        let results = [
            "a": result("a", .online, ago: 3 * 3600),
            "b": result("b", .online, ago: 2 * 3600),
            "c": result("c", .reachable, ago: 2 * 3600 + 30),
            "d": result("d", .timeout, ago: 4 * 3600),
            // Not in this lineup: neither counted nor used for "last swept".
            "x": result("x", .online, ago: 10),
        ]
        let line = AppleChannelHealthSummary.line(lineupIDs: ["a", "b", "c", "d", "e"], results: results, now: now)
        #expect(line == "2 of 5 responding, last swept 2h ago")
    }

    @Test func summaryBeforeAnySweep() {
        #expect(AppleChannelHealthSummary.line(lineupIDs: ["a"], results: [:], now: now) == "Not checked yet")
        #expect(AppleChannelHealthSummary.progress(completed: 120, total: 780) == "Checking 120 of 780")
    }

    /// Checklist N7: the action with an empty or unreachable lineup says why.
    @Test func nothingToCheckNamesTheFailedSource() {
        #expect(AppleChannelHealthSummary.nothingToCheck(sourceFailure: nil) == "No channels to check")
        #expect(AppleChannelHealthSummary.nothingToCheck(sourceFailure: " ") == "No channels to check")
        #expect(AppleChannelHealthSummary.nothingToCheck(sourceFailure: "Can’t reach IPTV.")
            == "No channels to check. Can’t reach IPTV.")
    }

    // MARK: Detail

    @Test func detailNamesStatusCodeTimingAndFailedStage() {
        let detail = AppleChannelHealthDetail(result: result("a", .offline, ago: 7200, status: 403, stage: .headers), now: now)
        #expect(detail.rows.map(\.label) == ["Status", "Checked", "Status Code", "First Byte", "Failed At"])
        #expect(detail.rows.map(\.value) == ["Offline", "2h ago", "403", "140 ms", "Connection"])
    }

    @Test func timeoutDetailSaysNoResponse() {
        let detail = AppleChannelHealthDetail(result: .init(channelID: "a", bucket: .timeout, failedStage: .headers,
            checkedAt: now), now: now)
        #expect(detail.rows.first?.value == "Timed out")
        #expect(detail.rows.contains(.init(label: "Status Code", value: "No response")))
        #expect(!detail.rows.contains { $0.label == "First Byte" })
    }

    @Test func workingDetailDescribesTheVideo() {
        let info = AppleChannelHealthVideoInfo(codec: "h264", width: 1920, height: 1080, fps: 29.97, hasVideo: true)
        let detail = AppleChannelHealthDetail(result: .init(channelID: "a", bucket: .online, httpStatus: 200,
            checkedAt: now, videoInfo: info), now: now)
        #expect(detail.rows.first?.value == "Working")
        #expect(!detail.rows.contains { $0.label == "Failed At" })
        #expect(detail.rows.last == .init(label: "Video", value: "1920×1080, H264, 30 fps"))
    }

    static let stages: [(AppleSavedSourceDiagnosticStage, String)] = [
        (.headers, "Connection"), (.manifest, "Playlist"), (.firstRead, "Video data"), (.playbackRequest, "Decoding"),
    ]

    @Test(arguments: stages)
    func stagesInPlainWords(stage: AppleSavedSourceDiagnosticStage, expected: String) {
        #expect(AppleChannelHealthDetail.stage(stage) == expected)
    }

    // MARK: Map

    @Test func mapIsKeyedByAppIDIncludingHashedIDs() {
        let odd = "provider/channel 7"
        let stored = AppleChannelHealthResult(channelID: odd, bucket: .offline, checkedAt: now)
        #expect(stored.channelID != odd)
        let map = AppleChannelHealthMap.build(channels: [channel(odd), channel("plain")],
                                              results: [stored.channelID: stored])
        #expect(map.keys.sorted() == [odd])
        #expect(AppleChannelHealthIndicator(result: map[odd]) == .offline)
        #expect(AppleChannelHealthIndicator(result: map["plain"]) == nil)
    }

    @MainActor
    @Test func storeReadsHistoryOnce() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "health-ui-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = AppleChannelHealthHistory(directory: directory)
        try await history.record(result("a", .online))
        try await history.record(result("b", .offline, status: 403, stage: .headers))
        try await history.record(result("c", .reachable, stage: .manifest))

        let store = AppleChannelHealthStore(history: history)
        let lineup = [channel("a"), channel("b"), channel("c"), channel("dd")]
        store.setLineup(lineup)
        await store.loadIfNeeded()
        let revision = store.revision

        // A result written after the one read is not picked up by a second load.
        try await history.record(result("dd", .online))
        await store.loadIfNeeded()
        #expect(store.revision == revision)

        #expect(store.workingCount == 1)
        #expect(store.summary(now: now) == "1 of 4 responding, last swept 1m ago")

        let map = store.map(for: lineup)
        #expect(AppleChannelHealthIndicator(result: map["b"]) == .offline)
        #expect(AppleChannelHealthIndicator(result: map["c"]) == .notPlayable)
        #expect(AppleChannelHealthIndicator(result: map["a"]) == nil)
        #expect(map["dd"] == nil)
    }
}

@MainActor @Test
func channelHealthLoadsMissingLineupBeforeLiveAndReusesItsCache() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let suite = "health-cold-lineup-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let sources = AppleSourceStore(defaults: defaults, keychain: HealthLineupCredentials(),
        documentsDirectory: root.appendingPathComponent("documents"))
    let source = try sources.addIPTV(name: "Fixture TV", type: .m3u,
        endpoint: "https://fixture.example/channels.m3u", username: "", password: "")
    let settings = AppleSettingsStore(defaults: defaults, keychain: HealthLineupCredentials())
    settings.liveChannelScope = .providerLineup
    settings.liveChannelPackage = .everything
    let cache = AppleIPTVChannelCache(directory: root.appendingPathComponent("channels"))
    let client = AppleIPTVClient { request in
        let url = try #require(request.url)
        #expect(url.host == "fixture.example")
        return (Data("#EXTM3U\n#EXTINF:-1,Fixture News\nhttps://fixture.example/live/news.m3u8\n".utf8),
            try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
    }
    let store = AppleChannelHealthStore(history: AppleChannelHealthHistory(directory: root.appendingPathComponent("history")))
    #expect(store.lineup.isEmpty)
    #expect(await cache.snapshot(for: source.id) == nil)
    await store.prepareLineupIfNeeded(settings: settings, sourceStore: sources, allowsNetwork: true, cache: cache, client: client)
    #expect(store.lineup.map(\.name) == ["Fixture News"])
    #expect(!store.isPreparingLineup)
    #expect(!store.isSweeping)
    #expect(await cache.snapshot(for: source.id)?.channels == store.lineup)
    let cachedStore = AppleChannelHealthStore(history: AppleChannelHealthHistory(directory: root.appendingPathComponent("history")))
    let noNetwork = AppleIPTVClient { _ in
        Issue.record("A saved lineup must be usable before Live without refetching it")
        throw URLError(.badServerResponse)
    }
    await cachedStore.prepareLineupIfNeeded(settings: settings, sourceStore: sources, cache: cache, client: noNetwork)
    #expect(cachedStore.lineup == store.lineup)
}

@MainActor @Test
func channelHealthSettingsUsesOnlyCachedChannelsAndPreservesValidation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let suite = "health-cache-only-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let sources = AppleSourceStore(defaults: defaults, keychain: HealthLineupCredentials(),
        documentsDirectory: root.appendingPathComponent("documents"))
    let source = try sources.addIPTV(name: "Fixture TV", type: .m3u,
        endpoint: "https://fixture.example/channels.m3u", username: "", password: "")
    sources.recordValidationFailure(id: source.id, summary: "Can’t reach Fixture TV.")
    let savedSources = sources.sources
    let settings = AppleSettingsStore(defaults: defaults, keychain: HealthLineupCredentials())
    settings.liveChannelScope = .providerLineup
    settings.liveChannelPackage = .everything
    let cache = AppleIPTVChannelCache(directory: root.appendingPathComponent("channels"))
    let store = AppleChannelHealthStore(history: AppleChannelHealthHistory(directory: root.appendingPathComponent("history")))
    let noNetwork = AppleIPTVClient { _ in
        Issue.record("Opening Settings must not fetch a Live playlist")
        throw URLError(.badServerResponse)
    }

    await store.prepareLineupIfNeeded(settings: settings, sourceStore: sources, cache: cache, client: noNetwork)
    #expect(store.lineup.isEmpty)
    #expect(await cache.snapshot(for: source.id) == nil)
    #expect(sources.sources == savedSources)
    #expect(!store.isPreparingLineup)

    let channels = await cache.reconcileAndStore([
        AppleIPTVChannel(id: "fixture-news", sourceID: source.id, name: "Fixture News",
            streamURL: try #require(URL(string: "https://fixture.example/live/news.m3u8")))
    ], for: source.id)
    await store.prepareLineupIfNeeded(settings: settings, sourceStore: sources, cache: cache, client: noNetwork)
    #expect(store.lineup == channels)
    #expect(sources.sources == savedSources)
}

private struct HealthLineupCredentials: AppleCredentialStoring {
    func string(for account: String) throws -> String? { nil }
    func set(_ value: String, for account: String) throws {}
    func remove(_ account: String) throws {}
}
