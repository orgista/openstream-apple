import Foundation
import Network
import Testing
@testable import OpenStreamApple

@Suite(.timeLimit(.minutes(1)))
struct AppleChannelHealthTests {
    private func channel(_ url: URL, id: String = "fixture-channel") -> AppleIPTVChannel {
        .init(id: id, sourceID: UUID(), name: "Fixture", streamURL: url,
              userAgent: "FixtureAgent", referer: "https://fixture.example/", origin: "https://fixture.example")
    }
    private var config: AppleChannelHealthConfiguration {
        .init(requestTimeout: 2, requestsPerSecondPerHost: 1000)
    }
    private let playlist = Data("#EXTM3U\n#EXT-X-TARGETDURATION:1\n#EXTINF:0.2,\nsegment.ts\n#EXT-X-ENDLIST\n".utf8)

    @Test func onlineHLSUsesBundledFFmpegAndOneSegment() async throws {
        let server = HealthHTTPFixture()
        let base = try await server.start()
        await server.route("/live.m3u8", body: playlist)
        await server.route("/segment.ts", body: Self.video)
        let result = try await AppleChannelHealthProbe(configuration: config).probe(channel(base.appendingPathComponent("live.m3u8")))
        await server.stop()
        #expect(result.bucket == .online)
        #expect(result.failedStage == nil)
        #expect(result.videoInfo?.codec == "h264")
        #expect(result.videoInfo?.width == 32)
        #expect(result.videoInfo?.height == 32)
        #expect(result.videoInfo?.fps == 25)
        #expect(result.ttfbMs != nil)
        #expect(await server.hits("/segment.ts") == 1)
        #expect(await server.header("/segment.ts", "user-agent") == "FixtureAgent")
        #expect(await server.header("/segment.ts", "referer") == "https://fixture.example/")
    }

    @Test(arguments: [401, 403, 404])
    func httpFailureStopsAtFirstRung(status: Int) async throws {
        let server = HealthHTTPFixture()
        let base = try await server.start()
        await server.route("/live.m3u8", status: status, body: playlist)
        let result = try await AppleChannelHealthProbe(configuration: config).probe(channel(base.appendingPathComponent("live.m3u8")))
        await server.stop()
        #expect(result.bucket == .offline)
        #expect(result.httpStatus == status)
        #expect(result.failedStage == .headers)
        #expect(result.failureKind == (status == 404 ? .unavailable : .authentication))
        #expect(await server.hits("/segment.ts") == 0)
    }

    @Test func firstRungTimeout() async throws {
        let server = HealthHTTPFixture()
        let base = try await server.start()
        await server.route("/slow", body: playlist, delay: .seconds(5))
        let probe = AppleChannelHealthProbe(configuration: .init(requestTimeout: 0.15))
        let result = try await probe.probe(channel(base.appendingPathComponent("slow")))
        await server.stop()
        #expect(result.bucket == .timeout)
        #expect(result.failedStage == .headers)
    }

    @Test func unresolvableFixtureHostIsOffline() async throws {
        let url = try #require(URL(string: "http://unresolvable-channel.fixture.example/live.m3u8"))
        let result = try await AppleChannelHealthProbe(configuration: config).probe(channel(url))
        #expect(result.bucket == .offline)
        #expect(result.httpStatus == nil)
        #expect(result.failureKind == .network)
    }

    @Test(arguments: ["<html>Denied</html>", "#EXTM3U\n#EXT-X-VERSION:3\n", "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000\n"])
    func invalidOrEmptyManifestIsReachable(body: String) async throws {
        let server = HealthHTTPFixture()
        let base = try await server.start()
        await server.route("/live", body: Data(body.utf8))
        let result = try await AppleChannelHealthProbe(configuration: config).probe(channel(base.appendingPathComponent("live")))
        await server.stop()
        #expect(result.bucket == .reachable)
        #expect(result.failedStage == .manifest)
        #expect(result.httpStatus == 200)
    }

    @Test func missingSegmentIsReachable() async throws {
        let server = HealthHTTPFixture()
        let base = try await server.start()
        await server.route("/live", body: playlist)
        let result = try await AppleChannelHealthProbe(configuration: config).probe(channel(base.appendingPathComponent("live")))
        await server.stop()
        #expect(result.bucket == .reachable)
        #expect(result.failedStage == .firstRead)
        #expect(result.httpStatus == 404)
    }

    @Test func audioOnlyIsReachable() async throws {
        let server = HealthHTTPFixture()
        let base = try await server.start()
        await server.route("/live", body: playlist)
        await server.route("/segment.ts", body: Self.audio)
        let result = try await AppleChannelHealthProbe(configuration: config).probe(channel(base.appendingPathComponent("live")))
        await server.stop()
        #expect(result.bucket == .reachable)
        #expect(result.failedStage == .playbackRequest)
        #expect(result.videoInfo?.hasVideo == false)
    }

    @Test func encryptedMediaIsReachableAndKeyIsNeverFetched() async throws {
        let server = HealthHTTPFixture()
        let base = try await server.start()
        let manifest = "#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"key\"\n#EXTINF:1,\nsegment.ts\n"
        await server.route("/live", body: Data(manifest.utf8))
        await server.route("/segment.ts", body: Self.video)
        let result = try await AppleChannelHealthProbe(configuration: config).probe(channel(base.appendingPathComponent("live")))
        await server.stop()
        #expect(result.bucket == .reachable)
        #expect(result.failedStage == .playbackRequest)
        #expect(await server.hits("/key") == 0)
    }

    @Test func masterAndRedirectFollowOnlyFirstVariant() async throws {
        let server = HealthHTTPFixture()
        let base = try await server.start()
        await server.route("/start", status: 302, headers: ["Location": "/master"])
        await server.route("/master", body: Data("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000\nlive\n#EXT-X-STREAM-INF:BANDWIDTH=2000\nother\n".utf8))
        await server.route("/live", body: playlist)
        await server.route("/segment.ts", body: Self.video)
        let result = try await AppleChannelHealthProbe(configuration: config).probe(channel(base.appendingPathComponent("start")))
        await server.stop()
        #expect(result.bucket == .online)
        #expect(await server.hits("/other") == 0)
    }

    @Test func concurrencyIsBoundedAndProgressIsComplete() async throws {
        let server = HealthHTTPFixture()
        let base = try await server.start()
        await server.route("/live", status: 403, delay: .milliseconds(80))
        let channels = (0..<12).map { channel(base.appendingPathComponent("live"), id: "channel-\($0)") }
        let progress = HealthProgressRecorder()
        let results = try await AppleChannelHealthSweep(configuration: .init(concurrency: 3, requestsPerSecondPerHost: 1000))
            .run(channels, history: nil) { value in await progress.record(value) }
        await server.stop()
        #expect(results.count == 12)
        #expect(await server.maximumActive <= 3)
        #expect(await server.maximumActive > 1)
        #expect(await progress.completed == Array(1...12))
    }

    @Test func hostRateIncludesManifestAndSegment() async throws {
        let server = HealthHTTPFixture()
        let base = try await server.start()
        await server.route("/live", body: playlist)
        await server.route("/segment.ts", body: Self.video)
        _ = try await AppleChannelHealthSweep(configuration: .init(requestsPerSecondPerHost: 5))
            .run([channel(base.appendingPathComponent("live"))], history: nil)
        await server.stop()
        let times = await server.arrivals
        #expect(times.count == 2)
        if times.count == 2 { #expect(times[0].duration(to: times[1]) >= .milliseconds(180)) }
    }

    @Test func cancellationStopsSweepWithoutRecordingOutages() async throws {
        let server = HealthHTTPFixture()
        let base = try await server.start()
        await server.route("/live", body: playlist, delay: .seconds(5))
        let directory = FileManager.default.temporaryDirectory.appending(path: "health-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = AppleChannelHealthHistory(directory: directory)
        let channels = (0..<30).map { channel(base.appendingPathComponent("live"), id: "channel-\($0)") }
        let task = Task { try await AppleChannelHealthSweep().run(channels, history: history) }
        for _ in 0..<100 {
            if await server.hits("/live") > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let start = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(start.duration(to: .now) < .seconds(1))
        await server.stop()
        #expect(await history.snapshot().isEmpty)
        #expect(await server.hits("/live") <= 4)
    }

    @Test func sweepPersistsCompletedResults() async throws {
        let server = HealthHTTPFixture()
        let base = try await server.start()
        await server.route("/live", status: 403)
        let directory = FileManager.default.temporaryDirectory.appending(path: "health-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = AppleChannelHealthHistory(directory: directory)
        let results = try await AppleChannelHealthSweep(configuration: config)
            .run([channel(base.appendingPathComponent("live"))], history: history)
        await server.stop()
        let result = try #require(results.first)
        let entry = try #require(await history.entry(channelID: result.channelID))
        #expect(entry.lastResult == result)
        #expect(entry.lastResult.failureKind == .authentication)
    }

    @Test func historyRetainsFiveAndNeverPersistsURLsOrHeaders() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "health-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = AppleChannelHealthHistory(directory: directory)
        for index in 0..<7 {
            try await history.record(.init(channelID: "channel", bucket: index == 6 ? .online : .offline,
                                           checkedAt: Date(timeIntervalSince1970: Double(index))))
        }
        let hostileID = "https://fixture.example/live?token=fixture-secret"
        try await history.record(.init(channelID: hostileID, bucket: .offline))
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(files.count == 2)
        let text = try files.map { String(decoding: try Data(contentsOf: $0), as: UTF8.self) }.joined()
        #expect(text.contains("https") == false)
        #expect(text.contains("fixture.example") == false)
        #expect(text.contains("fixture-secret") == false)
        let restored = AppleChannelHealthHistory(directory: directory)
        let entry = try #require(await restored.entry(channelID: "channel"))
        #expect(entry.outcomes.count == 5)
        #expect(entry.lastResult.bucket == .online)
        #expect(entry.outcomes.first?.checkedAt == Date(timeIntervalSince1970: 2))
    }

    @Test func exportOnlyOnlinePreservesOriginalEXTINFAndHeaders() throws {
        let original = "#EXTINF:-1 tvg-id=\"fixture\" custom=\"keep exactly\",Fixture  Name"
        let input = "#EXTM3U\n\(original)\n#EXTVLCOPT:http-user-agent=FixtureAgent\nhttps://fixture.example/online\n#EXTINF:-1,Other\nhttps://fixture.example/offline\n"
        let lineup = try AppleIPTVClient.parseM3U(Data(input.utf8), sourceID: UUID(), baseURL: URL(string: "https://fixture.example/")!)
        let first = try #require(lineup.first)
        let last = try #require(lineup.last)
        let health = [first.id: AppleChannelHealthResult(channelID: first.id, bucket: .online),
                      last.id: AppleChannelHealthResult(channelID: last.id, bucket: .reachable)]
        let exported = AppleWorkingM3UExport.text(lineup: lineup, health: health, includesCredentials: true)
        #expect(exported.contains(original + "\n"))
        #expect(exported.contains("#EXTVLCOPT:http-user-agent=FixtureAgent"))
        #expect(exported.contains("https://fixture.example/online"))
        #expect(exported.contains("https://fixture.example/offline") == false)
        #expect(first.withGuideURL(nil).originalEXTINF == original)
    }

    @Test func exportRequiresExplicitCredentialChoice() {
        let channel = AppleIPTVChannel(id: "fixture", sourceID: UUID(), name: "Fixture",
            streamURL: URL(string: "https://fixture.example/live/fixture-user/fixture-password/1.ts?token=fixture-token")!,
            referer: "https://fixture.example/private?token=fixture-secret",
            originalEXTINF: "#EXTINF:-1 opaque=\"fixture-metadata-secret\",Fixture")
        let health = ["fixture": AppleChannelHealthResult(channelID: "fixture", bucket: .online)]
        let safe = AppleWorkingM3UExport.text(lineup: [channel], health: health)
        for secret in ["fixture-user", "fixture-password", "fixture-token", "fixture-secret", "fixture-metadata-secret"] {
            #expect(safe.contains(secret) == false)
        }
        let full = AppleWorkingM3UExport.text(lineup: [channel], health: health, includesCredentials: true)
        #expect(full.contains(channel.streamURL.absoluteString))
        #expect(full.contains("https://fixture.example/private?token=fixture-secret"))
    }

    @Test func redactedExportRemovesOpaqueURLSuffixesAndHeaders() {
        let channel = AppleIPTVChannel(id: "opaque", sourceID: UUID(), name: "Fixture",
            streamURL: URL(string: "https://fixture.example/public'opaque-private-secret")!,
            referer: "https://fixture.example/public'header-private-secret")
        let output = AppleWorkingM3UExport.text(lineup: [channel],
            health: ["opaque": .init(channelID: "opaque", bucket: .online)])
        #expect(output.contains("opaque-private-secret") == false)
        #expect(output.contains("header-private-secret") == false)
        #expect(output.contains("#EXTINF:-1,Fixture"))
    }

    @Test func ttfbDoesNotIncludeBodyDownload() async throws {
        let server = HealthHTTPFixture()
        let base = try await server.start()
        await server.route("/live", body: playlist, bodyDelay: .milliseconds(350))
        await server.route("/segment.ts", body: Self.video)
        let start = ContinuousClock.now
        let result = try await AppleChannelHealthProbe(configuration: config).probe(channel(base.appendingPathComponent("live")))
        await server.stop()
        #expect(result.bucket == .online)
        let ttfb = try #require(result.ttfbMs)
        #expect(start.duration(to: .now) >= .milliseconds(350))
        #expect(ttfb < 250)
    }

    @Test func answeredButStalledBodyIsReachable() async throws {
        let server = HealthHTTPFixture()
        let base = try await server.start()
        await server.route("/live", body: playlist, bodyDelay: .seconds(5))
        let result = try await AppleChannelHealthProbe(configuration: .init(requestTimeout: 1))
            .probe(channel(base.appendingPathComponent("live")))
        await server.stop()
        #expect(result.bucket == .reachable)
        #expect(result.failedStage == .manifest)
        #expect(result.httpStatus == 200)
        #expect(result.ttfbMs != nil)
    }

    @Test(arguments: [Data(), Data("<html>Segment unavailable</html>".utf8)])
    func segmentMustContainMediaBytes(bytes: Data) async throws {
        let server = HealthHTTPFixture()
        let base = try await server.start()
        await server.route("/live", body: playlist)
        await server.route("/segment.ts", body: bytes)
        let result = try await AppleChannelHealthProbe(configuration: config).probe(channel(base.appendingPathComponent("live")))
        await server.stop()
        #expect(result.bucket == .reachable)
        #expect(result.failedStage == .firstRead)
    }

    @Test func corruptMediaFailsBundledProbe() async throws {
        let server = HealthHTTPFixture()
        let base = try await server.start()
        var bytes = Data(repeating: 0, count: 188 * 3)
        bytes[0] = 0x47
        bytes[188] = 0x47
        await server.route("/live", body: playlist)
        await server.route("/segment.ts", body: bytes)
        let result = try await AppleChannelHealthProbe(configuration: config).probe(channel(base.appendingPathComponent("live")))
        await server.stop()
        #expect(result.bucket == .reachable)
        #expect(result.failedStage == .playbackRequest)
    }

    // Synthetic black 32x32 H.264 and silent AAC in MPEG-TS. No external tools at test runtime.
    private static let video = Data(base64Encoded: "R0AREABC8CUAAcEAAP8B/wAB/IAUSBIBBkZGbXBlZwlTZXJ2aWNlMDF3fEPK//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////9HQAAQAACwDQABwQAAAAHwACqxBLL//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////0dQABAAArASAAHBAADhAPAAG+EA8AAVvU1W////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////R0EAMAdQAAB7DH4AAAAB4AAAgIAFIQAH2GEAAAABCfAAAAABZ0LACtolsBEAAAMAAQAAAwAyDxImoAAAAAFozg/IAAABBgX//1DcRem95tlIt5Ys2CDZI+7veDI2NCAtIGNvcmUgMTY1IHIzMjIyIGIzNTYwNWEgLSBILjI2NC9NUEVHLTQgQVZDIGNvZGVjIC0gQ29weWxlZnQgMjAwMy0yMDI1IC0gaHR0cDovL3d3dy52aWRlb2xhbi5HAQARb3JnL3gyNjQuaHRtbCAtIG9wdGlvbnM6IGNhYmFjPTAgcmVmPTEgZGVibG9jaz0wOjA6MCBhbmFseXNlPTA6MCBtZT1kaWEgc3VibWU9MCBwc3k9MSBwc3lfcmQ9MS4wMDowLjAwIG1peGVkX3JlZj0wIG1lX3JhbmdlPTE2IGNocm9tYV9tZT0xIHRyZWxsaXM9MCA4eDhkY3Q9MCBjcW09MCBkZWFkem9uZT0yMSwxMSBmYXN0X0cBABJwc2tpcD0xIGNocm9tYV9xcF9vZmZzZXQ9MCB0aHJlYWRzPTEgbG9va2FoZWFkX3RocmVhZHM9MSBzbGljZWRfdGhyZWFkcz0wIG5yPTAgZGVjaW1hdGU9MSBpbnRlcmxhY2VkPTAgYmx1cmF5X2NvbXBhdD0wIGNvbnN0cmFpbmVkX2ludHJhPTAgYmZyYW1lcz0wIHdlaWdodHA9MCBrZXlpbnQ9MjUwIGtleWludF9taW49MjUgRwEAMzsA/////////////////////////////////////////////////////////////////////////////3NjZW5lY3V0PTAgaW50cmFfcmVmcmVzaD0wIHJjPWNyZiBtYnRyZWU9MCBjcmY9MjMuMCBxY29tcD0wLjYwIHFwbWluPTAgcXBtYXg9NjkgcXBzdGVwPTQgaXBfcmF0aW89MS40MCBhcT0wAIAAAAFliIQ6JigACQLJ115HQQA0mgD///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////8AAAHgAACAgAUhAAf0gQAAAAEJ8AAAAAFBmiAmi0dBADWaEAAAiRx+AP///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////wAAAeAAAICABSEACRChAAAAAQnwAAAAAUGaQCqLR0AAEQAAsA0AAcEAAAAB8AAqsQSy//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////9HUAARAAKwEgABwQAA4QDwABvhAPAAFb1NVv///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////0dBADaaAP///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////wAAAeAAAICABSEACSzBAAAAAQnwAAAAAUGaYCqLR0EAN5oQAACXLH4A////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////AAAB4AAAgIAFIQAJSOEAAAABCfAAAAABQZqAKos=")!
    private static let audio = Data(base64Encoded: "R0AREABC8CUAAcEAAP8B/wAB/IAUSBIBBkZGbXBlZwlTZXJ2aWNlMDF3fEPK//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////9HQAAQAACwDQABwQAAAAHwACqxBLL//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////0dQABAAArASAAHBAADhAPAAD+EA8AC2m8DZ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////R0EAMCFQAAB7DH4A//////////////////////////////////8AAAHAAJCAgAUhAAfYYf/xTEADX/zcAExhdmM2My4xLjEwMQACMEAO//FMQAF//AEYIAf/8UxAAX/8ARggB//xTEABf/wBGCAH//FMQAF//AEYIAf/8UxAAX/8ARggB//xTEABf/wBGCAH//FMQAF//AEYIAf/8UxAAX/8ARggB//xTEABf/wBGCAH//FMQAF//AEYIAc=")!
}
