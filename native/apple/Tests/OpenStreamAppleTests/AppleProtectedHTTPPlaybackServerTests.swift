import Foundation
import Network
import Testing
@testable import OpenStreamApple

// No pre-existing test file covered AppleProtectedHTTPPlaybackServer, so these
// exercise it end-to-end against a tiny loopback HTTP fixture (mirroring the
// receive/parse/respond style the server itself uses over NWConnection) since
// the server has no injectable URLSession seam.

@Test func protectedPlaybackServerPreservesEveryResourceInLongOnDemandPlaylist() async throws {
    let origin = AppleLiveTVUpstreamFixture()
    let port = try await origin.start()
    var manifest = "#EXTM3U\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-TARGETDURATION:6\n"
    manifest += "#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\"\n#EXT-X-MAP:URI=\"init.mp4\"\n"
    for sequence in 0..<600 { manifest += "#EXTINF:6.0,\n\(sequence).ts\n" }
    manifest += "#EXT-X-ENDLIST\n"
    await origin.addRoute("/movie.m3u8", headers: ["Content-Type": "application/vnd.apple.mpegurl"],
                          body: Data(manifest.utf8))
    for path in ["0.ts", "300.ts", "599.ts", "key.bin", "init.mp4"] {
        await origin.addRoute("/" + path, body: Data(path.utf8))
    }
    let server = AppleProtectedHTTPPlaybackServer()
    let playback = try await server.playbackURL(upstreamURL: URL(string: "http://127.0.0.1:\(port)/movie.m3u8")!)
    let (rewritten, _) = try await URLSession.shared.data(from: playback)
    let children = childResourceURLs(inPlaylist: rewritten)
    #expect(children.count == 600)
    for index in [0, 300, 599] {
        let (body, response) = try await URLSession.shared.data(from: children[index])
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(body == Data("\(index).ts".utf8))
    }
    let text = String(decoding: rewritten, as: UTF8.self)
    let pattern = try NSRegularExpression(pattern: "URI=\"([^\"]+)\"")
    for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
        let range = try #require(Range(match.range(at: 1), in: text))
        let url = try #require(URL(string: String(text[range])))
        let (body, response) = try await URLSession.shared.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(!body.isEmpty)
    }
    let oversized = "#EXTM3U\n" + (0..<16_385).map { "oversized-\($0).ts" }.joined(separator: "\n")
    await origin.addRoute("/movie.m3u8", headers: ["Content-Type": "application/vnd.apple.mpegurl"],
                          body: Data(oversized.utf8))
    let (_, rejected) = try await URLSession.shared.data(from: playback)
    #expect(((rejected as? HTTPURLResponse)?.statusCode ?? 0) >= 400)
    let (_, retained) = try await URLSession.shared.data(from: children[0])
    #expect((retained as? HTTPURLResponse)?.statusCode == 200)
    #expect(await server.diagnostics().childResourceCount == 602)
    await server.revoke(playbackURL: playback)
}

@Test func protectedPlaybackServerBoundsRollingHistoryWithoutEvictingCurrentSegments() async throws {
    let origin = AppleLiveTVUpstreamFixture()
    let port = try await origin.start()
    let server = AppleProtectedHTTPPlaybackServer()
    let playback = try await server.playbackURL(upstreamURL: URL(string: "http://127.0.0.1:\(port)/live.m3u8")!)
    var first: URL?
    var previous: URL?
    var current: URL?
    for start in [0, 512, 1_024] {
        let body = "#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:\(start)\n"
            + (start..<(start + 512)).map { "#EXTINF:6.0,\n\($0).ts" }.joined(separator: "\n")
        await origin.addRoute("/live.m3u8", headers: ["Content-Type": "application/vnd.apple.mpegurl"], body: Data(body.utf8))
        await origin.addRoute("/\(start).ts", body: Data([1, 2, 3]))
        let (rewritten, _) = try await URLSession.shared.data(from: playback)
        let children = childResourceURLs(inPlaylist: rewritten)
        #expect(children.count == 512)
        if first == nil { first = children.first }
        previous = current
        current = children.first
        #expect(await server.diagnostics().childResourceCount <= 1_024)
    }
    for url in [try #require(previous), try #require(current)] {
        let (_, response) = try await URLSession.shared.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
    }
    let (_, expired) = try await URLSession.shared.data(from: #require(first))
    #expect((expired as? HTTPURLResponse)?.statusCode == 404)
    await server.revoke(playbackURL: playback)
}

@Test func protectedPlaybackServerRetainsResourcesAcrossMasterPlaylistVariants() async throws {
    let origin = AppleLiveTVUpstreamFixture()
    let port = try await origin.start()
    await origin.addRoute("/master.m3u8", headers: ["Content-Type": "application/vnd.apple.mpegurl"],
        body: Data("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000\na.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=2000\nb.m3u8\n".utf8))
    for variant in ["a", "b"] {
        let body = "#EXTM3U\n" + (0..<600).map { "#EXTINF:6.0,\n\(variant)/\($0).ts" }.joined(separator: "\n") + "\n#EXT-X-ENDLIST\n"
        await origin.addRoute("/\(variant).m3u8", headers: ["Content-Type": "application/vnd.apple.mpegurl"], body: Data(body.utf8))
        await origin.addRoute("/\(variant)/0.ts", body: Data(variant.utf8))
    }
    let server = AppleProtectedHTTPPlaybackServer()
    let playback = try await server.playbackURL(upstreamURL: URL(string: "http://127.0.0.1:\(port)/master.m3u8")!)
    let (master, _) = try await URLSession.shared.data(from: playback)
    let variants = childResourceURLs(inPlaylist: master)
    var firstSegments: [URL] = []
    for variant in variants {
        let (body, response) = try await URLSession.shared.data(from: variant)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        firstSegments.append(try #require(childResourceURLs(inPlaylist: body).first))
    }
    #expect(firstSegments.count == 2)
    for (index, segment) in firstSegments.enumerated() {
        let (body, response) = try await URLSession.shared.data(from: segment)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(body == Data((index == 0 ? "a" : "b").utf8))
    }
    #expect(await server.diagnostics().childResourceCount == 1_202)
    await server.revoke(playbackURL: playback)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["PLAYBACK_ENGINE_TESTS"] == "1"))
func protectedBridgeTokenCapacityExpiresBeforeRenewal() async throws {
    let origin = AppleLiveTVUpstreamFixture()
    let port = try await origin.start()
    await origin.addRoute("/sample.ts", body: Data([1, 2, 3]))
    let upstream = URL(string: "http://127.0.0.1:\(port)/sample.ts")!
    let server = AppleProtectedHTTPPlaybackServer()
    var urls: [URL] = []
    for _ in 0..<512 { urls.append(try await server.playbackURL(upstreamURL: upstream, lifetime: 60)) }
    #expect(Set(urls).count == 512)
    do {
        _ = try await server.playbackURL(upstreamURL: upstream)
        Issue.record("The session table accepted more than 512 live capabilities")
    } catch AppleProtectedHTTPPlaybackError.listenerUnavailable { }
    let (_, initial) = try await URLSession.shared.data(from: urls[0])
    #expect((initial as? HTTPURLResponse)?.statusCode == 200)
    // Exercise the public 60-second minimum lifetime without changing the
    // production clock or adding a shorter-lived token mode.
    try await Task.sleep(for: .seconds(60))
    try await Task.sleep(for: .seconds(1))
    let renewed = try await server.playbackURL(upstreamURL: upstream, lifetime: 60)
    #expect(await server.diagnostics().sessionCount == 1)
    let (_, expired) = try await URLSession.shared.data(from: urls[0])
    #expect((expired as? HTTPURLResponse)?.statusCode == 404)
    let (body, response) = try await URLSession.shared.data(from: renewed)
    #expect((response as? HTTPURLResponse)?.statusCode == 200)
    #expect(body == Data([1, 2, 3]))
    await server.revoke(playbackURL: renewed)
    #expect(await server.diagnostics().listenerActive == false)
}

@Test func protectedPlaybackServerFollowsCrossOriginRedirectDroppingSensitiveHeaders() async throws {
    let origin = AppleLiveTVUpstreamFixture()
    let edge = AppleLiveTVUpstreamFixture()
    let originPort = try await origin.start()
    let edgePort = try await edge.start()

    await origin.addRoute(
        "/master.m3u8",
        status: 302,
        statusText: "Found",
        headers: ["Location": "http://127.0.0.1:\(edgePort)/edge.m3u8"]
    )
    await edge.addRoute(
        "/edge.m3u8",
        headers: ["Content-Type": "application/vnd.apple.mpegurl"],
        body: Data("#EXTM3U\n#EXT-X-ENDLIST\n".utf8)
    )

    let server = AppleProtectedHTTPPlaybackServer()
    let playback = try await server.playbackURL(
        upstreamURL: URL(string: "http://127.0.0.1:\(originPort)/master.m3u8")!,
        requestHeaders: ["User-Agent": "OpenStreamTest/1.0", "Referer": "http://panel.example/page"]
    )

    let (data, response) = try await URLSession.shared.data(from: playback)
    let http = try #require(response as? HTTPURLResponse)
    #expect(http.statusCode == 200)
    #expect(String(decoding: data, as: UTF8.self).contains("#EXTM3U"))

    let received = await edge.headers(receivedFor: "/edge.m3u8")
    #expect(received?.value(for: "User-Agent") == "OpenStreamTest/1.0")
    #expect(received?.value(for: "Referer") == nil)
}

@Test func protectedPlaybackServerFollowsSameOriginRedirectKeepingReferer() async throws {
    let origin = AppleLiveTVUpstreamFixture()
    let originPort = try await origin.start()

    await origin.addRoute(
        "/master.m3u8",
        status: 302,
        statusText: "Found",
        headers: ["Location": "http://127.0.0.1:\(originPort)/redirected.m3u8"]
    )
    await origin.addRoute(
        "/redirected.m3u8",
        headers: ["Content-Type": "application/vnd.apple.mpegurl"],
        body: Data("#EXTM3U\n#EXT-X-ENDLIST\n".utf8)
    )

    let server = AppleProtectedHTTPPlaybackServer()
    let playback = try await server.playbackURL(
        upstreamURL: URL(string: "http://127.0.0.1:\(originPort)/master.m3u8")!,
        requestHeaders: ["User-Agent": "OpenStreamTest/1.0", "Referer": "http://panel.example/page"]
    )

    let (data, response) = try await URLSession.shared.data(from: playback)
    let http = try #require(response as? HTTPURLResponse)
    #expect(http.statusCode == 200)
    #expect(String(decoding: data, as: UTF8.self).contains("#EXTM3U"))

    let received = await origin.headers(receivedFor: "/redirected.m3u8")
    #expect(received?.value(for: "Referer") == "http://panel.example/page")
}

@Test func protectedPlaybackServerReturnsBadGatewayForEmptyUpstreamPlaylist() async throws {
    let origin = AppleLiveTVUpstreamFixture()
    let originPort = try await origin.start()

    await origin.addRoute(
        "/empty.m3u8",
        headers: ["Content-Type": "application/vnd.apple.mpegurl"],
        body: Data()
    )

    let server = AppleProtectedHTTPPlaybackServer()
    let playback = try await server.playbackURL(
        upstreamURL: URL(string: "http://127.0.0.1:\(originPort)/empty.m3u8")!
    )

    let (data, response) = try await URLSession.shared.data(from: playback)
    let http = try #require(response as? HTTPURLResponse)
    #expect(http.statusCode == 502)
    #expect(http.value(forHTTPHeaderField: "Content-Type") == "text/plain")
    #expect(String(decoding: data, as: UTF8.self) == "upstream returned an empty playlist")
}

@Test func protectedPlaybackServerKeepsChildURLsStableAcrossIdenticalRefreshes() async throws {
    let origin = AppleLiveTVUpstreamFixture()
    let originPort = try await origin.start()
    let playlist = Data("""
    #EXTM3U
    #EXT-X-MEDIA-SEQUENCE:313
    #EXTINF:6.0,
    313.ts
    #EXTINF:6.0,
    314.ts
    """.utf8)
    await origin.addRoute(
        "/live.m3u8",
        headers: ["Content-Type": "application/vnd.apple.mpegurl"],
        body: playlist
    )

    let server = AppleProtectedHTTPPlaybackServer()
    let playback = try await server.playbackURL(
        upstreamURL: URL(string: "http://127.0.0.1:\(originPort)/live.m3u8")!
    )

    let (first, _) = try await URLSession.shared.data(from: playback)
    let (second, _) = try await URLSession.shared.data(from: playback)
    #expect(!first.isEmpty)
    #expect(first == second)
}

@Test func protectedPlaybackServerKeepsChildURLsStableWhenLivePlaylistSlidesByOne() async throws {
    let origin = AppleLiveTVUpstreamFixture()
    let originPort = try await origin.start()

    func playlist(firstSequence: Int, lastSequence: Int) -> Data {
        var text = "#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:\(firstSequence)\n"
        for sequence in firstSequence ... lastSequence {
            text += "#EXTINF:6.0,\n\(sequence).ts\n"
        }
        return Data(text.utf8)
    }

    await origin.addRoute(
        "/live.m3u8",
        headers: ["Content-Type": "application/vnd.apple.mpegurl"],
        body: playlist(firstSequence: 313, lastSequence: 317)
    )

    let server = AppleProtectedHTTPPlaybackServer()
    let playback = try await server.playbackURL(
        upstreamURL: URL(string: "http://127.0.0.1:\(originPort)/live.m3u8")!
    )

    let (firstBody, _) = try await URLSession.shared.data(from: playback)
    let firstURLs = childResourceURLs(inPlaylist: firstBody)
    #expect(firstURLs.count == 5)

    await origin.addRoute(
        "/live.m3u8",
        headers: ["Content-Type": "application/vnd.apple.mpegurl"],
        body: playlist(firstSequence: 314, lastSequence: 318)
    )
    let (secondBody, _) = try await URLSession.shared.data(from: playback)
    let secondURLs = childResourceURLs(inPlaylist: secondBody)
    #expect(secondURLs.count == 5)

    // Sequences 314...317 (indices 1...4 of the first playlist, 0...3 of the
    // second) must keep byte-identical local URLs across the slide.
    for offset in 0 ..< 4 {
        #expect(firstURLs[offset + 1] == secondURLs[offset])
    }
    // Sequence 318 is brand new: its local URL must not have appeared before.
    #expect(!firstURLs.contains(secondURLs[4]))
    // Exactly one new local URL was minted for the slide.
    let newURLs = Set(secondURLs).subtracting(Set(firstURLs))
    #expect(newURLs.count == 1)
}

@Test func protectedPlaybackServerScopesChildURLsToTheirOwnSession() async throws {
    let origin = AppleLiveTVUpstreamFixture()
    let originPort = try await origin.start()
    let playlist = Data("""
    #EXTM3U
    #EXT-X-MEDIA-SEQUENCE:313
    #EXTINF:6.0,
    313.ts
    """.utf8)
    await origin.addRoute(
        "/live.m3u8",
        headers: ["Content-Type": "application/vnd.apple.mpegurl"],
        body: playlist
    )

    let server = AppleProtectedHTTPPlaybackServer()
    let upstream = URL(string: "http://127.0.0.1:\(originPort)/live.m3u8")!
    let firstPlayback = try await server.playbackURL(upstreamURL: upstream)
    let secondPlayback = try await server.playbackURL(upstreamURL: upstream)
    #expect(firstPlayback != secondPlayback)

    let (firstBody, _) = try await URLSession.shared.data(from: firstPlayback)
    let (secondBody, _) = try await URLSession.shared.data(from: secondPlayback)
    let firstURLs = childResourceURLs(inPlaylist: firstBody)
    let secondURLs = childResourceURLs(inPlaylist: secondBody)
    #expect(firstURLs.count == 1 && secondURLs.count == 1)
    #expect(firstURLs[0] != secondURLs[0])
}

@Test func protectedPlaybackServerServesConcurrentRequestsForTheSameChildURL() async throws {
    let origin = AppleLiveTVUpstreamFixture()
    let originPort = try await origin.start()
    let playlist = Data("""
    #EXTM3U
    #EXT-X-MEDIA-SEQUENCE:313
    #EXTINF:6.0,
    313.ts
    """.utf8)
    await origin.addRoute(
        "/live.m3u8",
        headers: ["Content-Type": "application/vnd.apple.mpegurl"],
        body: playlist
    )
    await origin.addRoute("/313.ts", body: Data(repeating: 0x42, count: 4_096))

    let server = AppleProtectedHTTPPlaybackServer()
    let playback = try await server.playbackURL(
        upstreamURL: URL(string: "http://127.0.0.1:\(originPort)/live.m3u8")!
    )
    let (body, _) = try await URLSession.shared.data(from: playback)
    let childURL = try #require(childResourceURLs(inPlaylist: body).first)

    async let first = URLSession.shared.data(from: childURL)
    async let second = URLSession.shared.data(from: childURL)
    let (firstResult, secondResult) = try await (first, second)
    let firstHTTP = try #require(firstResult.1 as? HTTPURLResponse)
    let secondHTTP = try #require(secondResult.1 as? HTTPURLResponse)
    #expect(firstHTTP.statusCode == 200)
    #expect(secondHTTP.statusCode == 200)
    #expect(firstResult.0.count == 4_096)
    #expect(secondResult.0.count == 4_096)
}

@Test func protectedPlaybackServerStickyPlaylistOriginSurvivesLoadBalancedRedirects() async throws {
    let origin = AppleLiveTVUpstreamFixture()
    let edge = AppleLiveTVUpstreamFixture()
    let originPort = try await origin.start()
    let edgePort = try await edge.start()

    // A load-balanced panel: every fresh hit on the panel path hands out a
    // different edge host.
    await origin.addAlternatingRedirect(
        "/live.m3u8",
        to: [
            "http://127.0.0.1:\(edgePort)/edgeA/index.m3u8",
            "http://127.0.0.1:\(edgePort)/edgeB/index.m3u8",
        ]
    )
    let playlist = Data("""
    #EXTM3U
    #EXT-X-MEDIA-SEQUENCE:313
    #EXTINF:6.0,
    313.ts
    #EXTINF:6.0,
    314.ts
    """.utf8)
    await edge.addRoute("/edgeA/index.m3u8", headers: ["Content-Type": "application/vnd.apple.mpegurl"], body: playlist)
    await edge.addRoute("/edgeB/index.m3u8", headers: ["Content-Type": "application/vnd.apple.mpegurl"], body: playlist)

    let server = AppleProtectedHTTPPlaybackServer()
    let playback = try await server.playbackURL(
        upstreamURL: URL(string: "http://127.0.0.1:\(originPort)/live.m3u8")!
    )

    let (firstBody, _) = try await URLSession.shared.data(from: playback)
    let firstURLs = childResourceURLs(inPlaylist: firstBody)
    #expect(firstURLs.count == 2)

    let (secondBody, _) = try await URLSession.shared.data(from: playback)
    let secondURLs = childResourceURLs(inPlaylist: secondBody)
    #expect(secondURLs == firstURLs)

    // The second bridge fetch must have gone straight to the edge it stuck
    // to the first time, never re-hitting the redirecting panel path (which
    // would have hand out edgeB and produced different segment IDs).
    #expect(await origin.hitCount(for: "/live.m3u8") == 1)
    #expect(await edge.hitCount(for: "/edgeB/index.m3u8") == 0)
}

@Test func protectedPlaybackServerFallsBackToOriginalPanelURLWhenStickyURLFails() async throws {
    let origin = AppleLiveTVUpstreamFixture()
    let edge = AppleLiveTVUpstreamFixture()
    let originPort = try await origin.start()
    let edgePort = try await edge.start()

    await origin.addAlternatingRedirect(
        "/live.m3u8",
        to: [
            "http://127.0.0.1:\(edgePort)/edgeA/index.m3u8",
            "http://127.0.0.1:\(edgePort)/edgeB/index.m3u8",
        ]
    )
    await edge.addRoute(
        "/edgeA/index.m3u8",
        headers: ["Content-Type": "application/vnd.apple.mpegurl"],
        body: Data("#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:313\n#EXTINF:6.0,\n313.ts\n".utf8)
    )
    await edge.addRoute(
        "/edgeB/index.m3u8",
        headers: ["Content-Type": "application/vnd.apple.mpegurl"],
        body: Data("#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:400\n#EXTINF:6.0,\n400.ts\n".utf8)
    )

    let server = AppleProtectedHTTPPlaybackServer()
    let playback = try await server.playbackURL(
        upstreamURL: URL(string: "http://127.0.0.1:\(originPort)/live.m3u8")!
    )

    // Prime the sticky URL against edgeA.
    _ = try await URLSession.shared.data(from: playback)

    // edgeA now fails; the bridge must fall back to the panel URL, which
    // hands out edgeB on this (second) hit.
    await edge.addRoute("/edgeA/index.m3u8", status: 503, statusText: "Service Unavailable")

    let (data, response) = try await URLSession.shared.data(from: playback)
    let http = try #require(response as? HTTPURLResponse)
    #expect(http.statusCode == 200)
    #expect(String(decoding: data, as: UTF8.self).contains("#EXT-X-MEDIA-SEQUENCE:400"))
    #expect(await origin.hitCount(for: "/live.m3u8") == 2)
}

@Test func protectedPlaybackServerResolvesRelativeChildURIsAgainstTheFinalRedirectedURL() async throws {
    let origin = AppleLiveTVUpstreamFixture()
    let edge = AppleLiveTVUpstreamFixture()
    let originPort = try await origin.start()
    let edgePort = try await edge.start()

    await origin.addRoute(
        "/live.m3u8",
        status: 302,
        statusText: "Found",
        headers: ["Location": "http://127.0.0.1:\(edgePort)/hls/index.m3u8"]
    )
    await edge.addRoute(
        "/hls/index.m3u8",
        headers: ["Content-Type": "application/vnd.apple.mpegurl"],
        body: Data("#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:313\n#EXTINF:6.0,\n313.ts\n".utf8)
    )
    await edge.addRoute("/hls/313.ts", body: Data(repeating: 0x7A, count: 16))

    let server = AppleProtectedHTTPPlaybackServer()
    let playback = try await server.playbackURL(
        upstreamURL: URL(string: "http://127.0.0.1:\(originPort)/live.m3u8")!
    )

    let (body, _) = try await URLSession.shared.data(from: playback)
    let childURL = try #require(childResourceURLs(inPlaylist: body).first)

    let (segmentData, segmentResponse) = try await URLSession.shared.data(from: childURL)
    let segmentHTTP = try #require(segmentResponse as? HTTPURLResponse)
    #expect(segmentHTTP.statusCode == 200)
    #expect(segmentData.count == 16)
    // The relative "313.ts" URI must resolve against the edge (where the
    // playlist bytes actually came from), never against the original panel
    // path it was redirected away from.
    #expect(await edge.headers(receivedFor: "/hls/313.ts") != nil)
    #expect(await origin.headers(receivedFor: "/hls/313.ts") == nil)
}

@Test func protectedPlaybackServerStreamsLargeBodyWithBackpressureAndTearsDownWhenRevoked() async throws {
    let origin = AppleLiveTVUpstreamFixture()
    let originPort = try await origin.start()
    let payload = Data(repeating: 0x5A, count: 8 * 1_024 * 1_024)
    await origin.addRoute("/movie.ts", body: payload)
    let server = AppleProtectedHTTPPlaybackServer()
    let playback = try await server.playbackURL(
        upstreamURL: URL(string: "http://127.0.0.1:\(originPort)/movie.ts")!
    )

    let clock = ContinuousClock()
    let started = clock.now
    let (data, response) = try await URLSession.shared.data(from: playback)
    let elapsed = started.duration(to: clock.now)
    print("OpenStream protected proxy 8 MiB fixture: \(elapsed)")
    #expect((response as? HTTPURLResponse)?.statusCode == 200)
    #expect(data == payload)
    #expect(elapsed < .seconds(5))

    await server.revoke(playbackURL: playback)
    let stopped = await server.diagnostics()
    #expect(stopped.sessionCount == 0)
    #expect(!stopped.listenerActive)

    let replay = try await server.playbackURL(
        upstreamURL: URL(string: "http://127.0.0.1:\(originPort)/movie.ts")!
    )
    let (replayed, _) = try await URLSession.shared.data(from: replay)
    #expect(replayed == payload)
    await server.revoke(playbackURL: replay)
}

@Test func playbackFailureClassifiesCoreMediaEmptyPlaylistError() {
    let error = NSError(domain: "CoreMediaErrorDomain", code: -12887)
    let failure = ApplePlaybackFailure.classify(error)
    #expect(failure.message ==
        "The provider returned an empty playlist. The channel may be offline or the account may be out of connections.")
}

extension Dictionary where Key == String, Value == String {
    fileprivate func value(for name: String) -> String? {
        first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

/// Pulls every non-comment line (the rewritten child resource URLs) out of a
/// rewritten playlist body, in playlist order.
private func childResourceURLs(inPlaylist data: Data) -> [URL] {
    String(decoding: data, as: UTF8.self)
        .components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        .compactMap(URL.init(string:))
}

/// Minimal loopback HTTP fixture standing in for an IPTV panel/CDN host in
/// tests. Structured like AppleProtectedHTTPPlaybackServer's own NWListener
/// plumbing: accept a connection, read one request, write one canned
/// response, close. Two distinct ports on 127.0.0.1 count as different
/// origins for the server's own isSameOrigin check, which is what lets this
/// fixture simulate a cross-origin redirect without touching the network.
private actor AppleLiveTVUpstreamFixture {
    struct Route: Sendable {
        let status: Int
        let statusText: String
        let headers: [String: String]
        let body: Data
    }

    private var listener: NWListener?
    private var routes: [String: Route] = [:]
    private var captured: [String: [String: String]] = [:]
    private var hitCounts: [String: Int] = [:]
    private var alternatingRedirects: [String: (targets: [String], nextIndex: Int)] = [:]
    private var readyPort: UInt16?

    deinit { listener?.cancel() }

    func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: .any)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                Task { await self?.markReady() }
            }
        }
        listener.start(queue: DispatchQueue(label: "openstream-tests.live-tv-fixture"))
        for _ in 0 ..< 200 {
            if let port = readyPort { return port }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw URLError(.cannotConnectToHost)
    }

    private func markReady() { readyPort = listener?.port?.rawValue }

    func addRoute(
        _ path: String,
        status: Int = 200,
        statusText: String = "OK",
        headers: [String: String] = [:],
        body: Data = Data()
    ) {
        routes[path] = Route(status: status, statusText: statusText, headers: headers, body: body)
    }

    func headers(receivedFor path: String) -> [String: String]? { captured[path] }

    func hitCount(for path: String) -> Int { hitCounts[path] ?? 0 }

    /// Registers a path that 302-redirects to a different absolute location
    /// on each successive request, cycling through `targets` in order —
    /// simulating a load-balanced panel that hands out a different edge host
    /// per request instead of a stable one.
    func addAlternatingRedirect(_ path: String, to targets: [String]) {
        alternatingRedirects[path] = (targets, 0)
    }

    private func accept(_ connection: NWConnection) async {
        connection.start(queue: DispatchQueue(label: "openstream-tests.live-tv-fixture.connection"))
        guard let (path, headers) = try? await readRequest(connection) else {
            connection.cancel()
            return
        }
        captured[path] = headers
        hitCounts[path, default: 0] += 1
        let route: Route
        if var redirect = alternatingRedirects[path], !redirect.targets.isEmpty {
            let target = redirect.targets[redirect.nextIndex % redirect.targets.count]
            redirect.nextIndex += 1
            alternatingRedirects[path] = redirect
            route = Route(status: 302, statusText: "Found", headers: ["Location": target], body: Data())
        } else {
            route = routes[path] ?? Route(status: 404, statusText: "Not Found", headers: [:], body: Data())
        }
        var text = "HTTP/1.1 \(route.status) \(route.statusText)\r\n"
        for (name, value) in route.headers { text += "\(name): \(value)\r\n" }
        text += "Content-Length: \(route.body.count)\r\nConnection: close\r\n\r\n"
        var responseData = Data(text.utf8)
        responseData.append(route.body)
        try? await send(responseData, connection: connection)
        connection.cancel()
    }

    private func readRequest(_ connection: NWConnection) async throws -> (String, [String: String]) {
        var data = Data()
        while data.range(of: Data("\r\n\r\n".utf8)) == nil {
            let chunk = try await receive(connection)
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw URLError(.cannotParseResponse)
        }
        let lines = text.components(separatedBy: "\r\n")
        let requestParts = lines.first?.split(separator: " ") ?? []
        guard requestParts.count >= 2 else { throw URLError(.cannotParseResponse) }
        let path = String(requestParts[1])
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[line.startIndex ..< colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            headers[name] = value
        }
        return (path, headers)
    }

    private func receive(_ connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: data ?? Data()) }
            }
        }
    }

    private func send(_ data: Data, connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, contentContext: .defaultMessage, isComplete: true, completion: .contentProcessed {
                if let error = $0 { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }
}
