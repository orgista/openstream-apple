import Foundation
import Network
import Testing
@testable import OpenStreamApple

@Suite(.timeLimit(.minutes(1)))
struct AppleChannelHealthTests {
    private func channel(_ url: URL, id: String = "fixture-channel", sourceID: UUID = UUID()) -> AppleIPTVChannel {
        .init(id: id, sourceID: sourceID, name: "Fixture", streamURL: url,
              userAgent: "FixtureAgent", referer: "https://fixture.example/", origin: "https://fixture.example")
    }
    /// Content tests, not timing tests: the request timeout only guards a hang,
    /// and the parallel gate can hold a loopback answer up for seconds.
    private var config: AppleChannelHealthConfiguration {
        .init(requestTimeout: 30, requestsPerSecondPerHost: 1000)
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

    @Test(arguments: [401, 404])
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

    /// A provider past its connection limit answers 403 or 429; that is no outage.
    @Test(arguments: [403, 429])
    func refusalIsBusyNotOffline(status: Int) async throws {
        let server = HealthHTTPFixture()
        let base = try await server.start()
        await server.route("/live.m3u8", status: status, body: playlist)
        let result = try await AppleChannelHealthProbe(configuration: config).probe(channel(base.appendingPathComponent("live.m3u8")))
        await server.stop()
        #expect(result.bucket == .busy)
        #expect(result.failureKind == nil)
        #expect(AppleChannelHealthIndicator(result: result) == nil)
    }

    @Test func firstRungTimeout() async throws {
        let server = HealthHTTPFixture()
        let base = try await server.start()
        await server.route("/slow", body: playlist, delay: .seconds(3_600))
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
        await server.route("/live", status: 403)
        await server.holdResponses()
        let channels = (0..<12).map { channel(base.appendingPathComponent("live"), id: "channel-\($0)") }
        let progress = HealthProgressRecorder()
        let sweep = Task {
            try await AppleChannelHealthSweep(configuration: .init(concurrency: 3, requestsPerSecondPerHost: 1000))
                .run(channels, history: nil) { value in await progress.record(value) }
        }
        // All three slots fill while nothing has been answered.
        await server.waitForActive(3)
        await server.releaseResponses()
        let results = try await sweep.value
        await server.stop()
        #expect(results.count == 12)
        #expect(await server.maximumActive == 3)
        #expect(await progress.completed == Array(1...12))
    }

    @Test func hostRateSpacesChannelStartsNotTheirSegments() async throws {
        let server = HealthHTTPFixture()
        let base = try await server.start()
        await server.route("/live", body: playlist)
        await server.route("/segment.ts", body: Self.video)
        await server.route("/other", status: 403)
        let clock = ManualClock()
        let sweep = Task {
            try await AppleChannelHealthSweep(configuration: .init(concurrency: 1, requestsPerSecondPerHost: 5, clock: clock))
                .run([channel(base.appendingPathComponent("live"), id: "a"),
                      channel(base.appendingPathComponent("other"), id: "b")], history: nil)
        }
        await clock.waitForSleeps(1)
        #expect(clock.requestedDeadlines == [.milliseconds(200)])
        #expect(await server.hits("/live") == 1)
        #expect(await server.hits("/segment.ts") == 1)
        #expect(await server.hits("/other") == 0)
        clock.advance(by: .milliseconds(200))
        let results = try await sweep.value
        await server.stop()
        #expect(results.count == 2)
        #expect(await server.hits("/other") == 1)
    }

    /// Owner recording 2026-10-15: "Checking 12 of 136" for minutes. A slow provider answered one
    /// request at a time, because the next one waited for the last body plus the spacing.
    @Test func slowAnswersDoNotRunOneAtATime() async throws {
        let server = HealthHTTPFixture()
        let base = try await server.start()
        await server.route("/live", status: 403)
        await server.holdResponses()
        let clock = ManualClock()
        let channels = (0..<2).map { channel(base.appendingPathComponent("live"), id: "channel-\($0)") }
        let sweep = Task {
            try await AppleChannelHealthSweep(configuration: .init(concurrency: 2, requestsPerSecondPerHost: 4, clock: clock))
                .run(channels, history: nil)
        }
        await server.waitForActive(1)
        await clock.waitForSleeps(1)
        #expect(clock.requestedDeadlines == [.milliseconds(250)])
        clock.advance(by: .milliseconds(250))
        await server.waitForActive(2)
        #expect(await server.maximumActive == 2)
        await server.releaseResponses()
        let results = try await sweep.value
        await server.stop()
        #expect(results.count == 2)
    }

    @Test(arguments: [(nil, 2), (1, 1), (3, 3), (10, 4)] as [(Int?, Int)])
    func probesPerProviderFollowItsConnectionLimit(limit: Int?, cap: Int) async throws {
        let server = HealthHTTPFixture()
        let base = try await server.start()
        await server.route("/live", status: 403)
        await server.holdResponses()
        let source = UUID()
        let channels = (0..<8).map { channel(base.appendingPathComponent("live"), id: "channel-\($0)", sourceID: source) }
        let sweep = Task {
            try await AppleChannelHealthSweep(configuration: .init(concurrency: 6, requestsPerSecondPerHost: 1000),
                                              connectionLimits: limit.map { [source: $0] } ?? [:])
                .run(channels, history: nil)
        }
        await server.waitForActive(cap)
        await server.releaseResponses()
        let results = try await sweep.value
        await server.stop()
        #expect(results.count == 8)
        #expect(await server.maximumActive == cap)
        #expect(AppleChannelHealthSweep.probeCap(connectionLimit: limit) == cap)
    }

    @Test func cancellationStopsSweepWithoutRecordingOutages() async throws {
        let server = HealthHTTPFixture()
        let base = try await server.start()
        await server.holdResponses()
        await server.route("/live", body: playlist)
        let directory = FileManager.default.temporaryDirectory.appending(path: "health-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = AppleChannelHealthHistory(directory: directory)
        let channels = (0..<30).map { channel(base.appendingPathComponent("live"), id: "channel-\($0)") }
        // Nothing is answered and nothing times out within the time limit, so
        // only the cancellation reaching the requests in flight ends the sweep.
        let task = Task {
            try await AppleChannelHealthSweep(configuration: .init(requestTimeout: 3_600)).run(channels, history: history)
        }
        await server.waitForHit("/live")
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        await server.stop()
        #expect(await history.snapshot().isEmpty)
        #expect(await server.hits("/live") <= 4)
    }

    @Test func sweepPersistsCompletedResults() async throws {
        let server = HealthHTTPFixture()
        let base = try await server.start()
        await server.route("/live", status: 401)
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

    /// The body stalls after the headers and its first byte, so the request
    /// only ends when its resource timeout runs out, counted from the request.
    /// The answer started before that (status 200), so a first byte timed at
    /// the answer is under the timeout however loaded the machine; one timed
    /// at the end of the body is not.
    @Test func ttfbDoesNotIncludeBodyDownload() async throws {
        let server = HealthHTTPFixture()
        let base = try await server.start()
        await server.route("/live", body: playlist, bodyDelay: .seconds(3_600))
        let result = try await AppleChannelHealthProbe(configuration: .init(requestTimeout: 5))
            .probe(channel(base.appendingPathComponent("live")))
        await server.stop()
        #expect(result.httpStatus == 200)
        let ttfb = try #require(result.ttfbMs)
        #expect(ttfb < 5_000)
    }

    @Test func answeredButStalledBodyIsReachable() async throws {
        let server = HealthHTTPFixture()
        let base = try await server.start()
        await server.route("/live", body: playlist, bodyDelay: .seconds(3_600))
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
