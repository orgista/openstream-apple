import Foundation
import Testing
@testable import OpenStreamApple

extension AppleLiveCaptionWrapTests {
    private var undeclaredMedia: String {
        "#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6.0,\nfirst.ts\n#EXTINF:6.0,\nsecond.ts\n"
    }

    private func fixtureRequest(_ origin: AppleLiveTVUpstreamFixture, playlist: String) async throws -> ApplePlaybackRequest {
        let port = try await origin.start()
        await origin.addRoute("/live.m3u8", body: Data(playlist.utf8))
        let url = try #require(URL(string: "http://127.0.0.1:\(port)/live.m3u8"))
        return AppleIPTVChannel(id: UUID().uuidString, sourceID: UUID(), name: "Caption fixture",
                               streamURL: url, userAgent: "FixtureAgent").playbackRequest()
    }

    @Test func firstPlayOfUndeclaredMediaPlaylistCarriesTheCaptionMaster() async throws {
        let origin = AppleLiveTVUpstreamFixture()
        let request = try await fixtureRequest(origin, playlist: undeclaredMedia)
        let probe = AppleLiveCaptionProbe()
        #expect(probe.wrapsInCaptionMaster(channelID: request.mediaID) == nil)
        let prepared = try await probe.preparedRequest(request)
        #expect(prepared.hints.declaresEmbeddedCaptions)
        #expect(prepared.effectiveHeaders == request.effectiveHeaders)
        // No segment or positive stamp is needed before the first master.
        #expect(await origin.hitCount(for: "/first.ts") == 0)
        let server = AppleProtectedHTTPPlaybackServer()
        let url = try await server.playbackURL(upstreamURL: prepared.url,
            requestHeaders: prepared.effectiveHeaders, declaringCaptions: prepared.hints.declaresEmbeddedCaptions)
        let (data, _) = try await URLSession.shared.data(from: url)
        #expect(String(decoding: data, as: UTF8.self).contains("INSTREAM-ID=\"CC1\""))
        #expect(url.lastPathComponent == "captions.m3u8")
        await server.revoke(playbackURL: url)
    }

    @Test func aMasterPlaylistIsNeverWrappedOnFirstPlay() async throws {
        let origin = AppleLiveTVUpstreamFixture()
        let request = try await fixtureRequest(origin,
            playlist: "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=2000000\nvariant.m3u8\n")
        let prepared = try await AppleLiveCaptionProbe().preparedRequest(request)
        #expect(prepared.hints.declaresEmbeddedCaptions == false)
        #expect(prepared.url == request.url)
        #expect(await origin.hitCount(for: "/variant.m3u8") == 0)
    }

    @Test func closedCaptionsNoneStaysUntouchedOnFirstPlay() async throws {
        let playlist = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=2000000,CLOSED-CAPTIONS=NONE\nvariant.m3u8\n"
        let origin = AppleLiveTVUpstreamFixture()
        let request = try await fixtureRequest(origin, playlist: playlist)
        let prepared = try await AppleLiveCaptionProbe().preparedRequest(request)
        #expect(prepared.hints.declaresEmbeddedCaptions == false)
        #expect(prepared.url == request.url)
        #expect(AppleHLSCaptionDeclaration.declaring(playlist) == playlist)
    }

    @Test(arguments: ["#EXTM3U\n", "#EXTM3U\n#EXTINF:6,\na.ts\n#CLOSED-CAPTIONS=NONE\n"])
    func emptyOrCaptionDeclaredMediaIsNotWrapped(playlist: String) {
        #expect(AppleLiveCaptionWrapPolicy.shouldWrap(playlist: playlist) == false)
    }

    @MainActor
    @Test func aCompletedNegativeObservationSuppressesTheNextRequestWithoutReloading() async throws {
        #expect(AppleLiveCaptionProbe.observationWindow == .seconds(60))
        let origin = AppleLiveTVUpstreamFixture()
        let request = try await fixtureRequest(origin, playlist: undeclaredMedia)
        for path in ["/first.ts", "/second.ts"] { await origin.addRoute(path, body: Data(repeating: 0x47, count: 188)) }
        let probe = AppleLiveCaptionProbe(observationDuration: .zero)
        let engine = NativePlaybackEngine(captionProbe: probe)
        defer { engine.stop() }
        let initialGeneration = engine.loadGeneration
        var pausedRequest = request
        pausedRequest.autoplay = false
        try await engine.load(pausedRequest)
        await engine.captionObservation?.value
        #expect(probe.wrapsInCaptionMaster(channelID: request.mediaID) == false)
        // Each load advances the real engine's generation. A completed negative
        // observation must leave it at the single initial load.
        #expect(engine.loadGeneration == initialGeneration + 1)
        let prepared = try await probe.preparedRequest(request)
        #expect(prepared.hints.declaresEmbeddedCaptions == false)
    }

    @Test(arguments: [false, true])
    func slowPlaylistPreflightReturnsPlainWithinBudget(deliverHeadersFirst: Bool) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SlowCaptionPlaylistURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let probe = AppleLiveCaptionProbe(session: session)
        let url = try #require(URL(string: "https://fixture.example/\(deliverHeadersFirst ? "body" : "headers").m3u8"))
        let request = AppleIPTVChannel(id: UUID().uuidString, sourceID: UUID(), name: "Slow caption fixture",
                                      streamURL: url).playbackRequest()
        let clock = ContinuousClock()
        let started = clock.now
        let prepared = try await probe.preparedRequest(request)
        let elapsed = started.duration(to: clock.now)
        #expect(prepared.hints.declaresEmbeddedCaptions == false)
        #expect(prepared.url == request.url)
        #expect(elapsed < .milliseconds(1_600))
        #expect(elapsed >= .milliseconds(1_400))
        #expect(probe.wrapsInCaptionMaster(channelID: request.mediaID) == nil)
        print("Caption preflight slow fixture: \(elapsed)")
    }

    @Test func cancellingPreflightDoesNotTurnCancellationIntoPlayback() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SlowCaptionPlaylistURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let probe = AppleLiveCaptionProbe(session: session)
        let url = try #require(URL(string: "https://fixture.example/headers.m3u8"))
        let request = AppleIPTVChannel(id: UUID().uuidString, sourceID: UUID(), name: "Cancelled fixture",
                                      streamURL: url).playbackRequest()
        let preflight = Task { try await probe.preparedRequest(request) }
        preflight.cancel()
        await #expect(throws: CancellationError.self) { try await preflight.value }
        #expect(probe.wrapsInCaptionMaster(channelID: request.mediaID) == nil)
    }

    @Test func captionsInALaterSegmentKeepTheFirstPlayDeclaration() async throws {
        let origin = AppleLiveTVUpstreamFixture()
        let request = try await fixtureRequest(origin, playlist: undeclaredMedia)
        await origin.addRoute("/first.ts", body: Data(repeating: 0x47, count: 188))
        let captions = Data(Array(repeating: AppleCEA608Detector.atscUserIdentifier, count: 3).flatMap { $0 })
        await origin.addRoute("/second.ts", body: captions)
        let probe = AppleLiveCaptionProbe()
        let result = await probe.probe(channelID: request.mediaID, playlistURL: request.url)
        #expect(result?.wrapsInCaptionMaster == true)
        #expect(probe.wrapsInCaptionMaster(channelID: request.mediaID) == true)
    }

    @Test func cancellingBeforeTheWindowEndsDoesNotCacheANegative() async throws {
        let origin = AppleLiveTVUpstreamFixture()
        let request = try await fixtureRequest(origin, playlist: undeclaredMedia)
        for path in ["/first.ts", "/second.ts"] { await origin.addRoute(path, body: Data(repeating: 0x47, count: 188)) }
        let probe = AppleLiveCaptionProbe()
        let observation = Task { await probe.probe(channelID: request.mediaID, playlistURL: request.url) }
        defer { observation.cancel() }
        for _ in 0..<200 {
            if await origin.hitCount(for: "/second.ts") > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await origin.hitCount(for: "/second.ts") > 0)
        #expect(probe.wrapsInCaptionMaster(channelID: request.mediaID) == nil)
        observation.cancel()
        #expect(await observation.value == nil)
        #expect(await probe.cachedResult(channelID: request.mediaID) == nil)
    }

    @Test func aFailedSegmentReadDoesNotSuppressCaptions() async throws {
        let origin = AppleLiveTVUpstreamFixture()
        let request = try await fixtureRequest(origin, playlist: undeclaredMedia)
        let probe = AppleLiveCaptionProbe(observationDuration: .zero)
        #expect(await probe.probe(channelID: request.mediaID, playlistURL: request.url) == nil)
        #expect(probe.wrapsInCaptionMaster(channelID: request.mediaID) == nil)
    }
}

/// Delays completion for three seconds, optionally sending headers and a body
/// prefix first to exercise the whole-read deadline, not just connection time.
private final class SlowCaptionPlaylistURLProtocol: URLProtocol {
    private var timer: Timer?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if request.url?.lastPathComponent == "body.m3u8" {
            sendHeaders()
            client?.urlProtocol(self, didLoad: Data("#EXTM3U\n".utf8))
        }
        let timer = Timer(timeInterval: 3, target: self, selector: #selector(finish),
                          userInfo: nil, repeats: false)
        self.timer = timer
        RunLoop.current.add(timer, forMode: RunLoop.current.currentMode ?? .default)
    }

    private func sendHeaders() {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": "application/vnd.apple.mpegurl"])
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }

    @objc private func finish() {
        if request.url?.lastPathComponent != "body.m3u8" { sendHeaders() }
        client?.urlProtocol(self, didLoad: Data("#EXTM3U\n#EXTINF:6,\nsegment.ts\n".utf8))
        client?.urlProtocolDidFinishLoading(self)
        timer = nil
    }

    override func stopLoading() {
        timer?.invalidate()
        timer = nil
    }
}
