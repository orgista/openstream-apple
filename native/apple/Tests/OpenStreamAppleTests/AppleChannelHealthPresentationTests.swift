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

    // MARK: Export wiring

    @MainActor
    @Test func storeReadsHistoryOnceAndExportsOnlyWorkingChannels() async throws {
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
        let text = store.workingM3U()
        #expect(text.hasPrefix("#EXTM3U\n"))
        #expect(text.contains("#EXTINF:-1,Channel a"))
        #expect(!text.contains("Channel b"))
        #expect(!text.contains("Channel c"))

        let map = store.map(for: lineup)
        #expect(AppleChannelHealthIndicator(result: map["b"]) == .offline)
        #expect(AppleChannelHealthIndicator(result: map["c"]) == .notPlayable)
        #expect(AppleChannelHealthIndicator(result: map["a"]) == nil)
        #expect(map["dd"] == nil)
    }

    @Test func shareFileCarriesTheWorkingPlaylist() async throws {
        guard #available(macOS 15.2, iOS 18.2, *) else { return }
        let lineup = [channel("a"), channel("b")]
        let file = AppleWorkingM3UFile(lineup: lineup, health: ["a": result("a", .online), "b": result("b", .timeout)])
        let data = try await file.exported(as: .m3uPlaylist)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text == AppleWorkingM3UExport.text(lineup: lineup, health: file.health))
        #expect(text.contains("Channel a"))
        #expect(!text.contains("Channel b"))
    }

    @Test func portalAddressPairsAndDownloadsInOneVisit() {
        let session = AppleWebManagementSession(
            url: URL(string: "http://192.0.2.10:8090/")!, friendlyURL: URL(string: "http://192.0.2.10:8090/")!,
            expiresAt: now, token: "token", pairingCode: "ABC123")
        #expect(AppleWorkingM3UExportRoute.address(for: session) == "192.0.2.10:8090/working.m3u?pair=ABC123")
    }
}
