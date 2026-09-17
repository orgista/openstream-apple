import Foundation
import Testing
@testable import OpenStreamApple

private func stremioSource(
    url: String = "https://addon.example/config/manifest.json",
    enabled: Bool = true,
    resources: [String] = ["stream", "subtitles"]
) -> AppleSource {
    AppleSource(
        kind: .stremio,
        name: "Example",
        url: URL(string: url)!,
        isEnabled: enabled,
        manifestID: "example.addon",
        resources: resources
    )
}

@Test func rankedStreamsPreserveAuthenticationFailureAfterEmptyFallback() async throws {
    let client = AppleStremioPlaybackClient { request in
        let status = request.url?.host == "denied.example" ? 403 : 200
        return (Data(#"{"streams":[]}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
    let resolver = AppleStremioPlaybackResolver(client: client)
    let first = stremioSource(url: "https://denied.example/manifest.json")
    let second = stremioSource(url: "https://empty.example/manifest.json")
    do {
        _ = try await resolver.rankedCandidates(sources: [first, second], preferredSourceID: first.id,
            item: .init(mediaID: "tt123", type: "movie", name: "Fixture"))
        Issue.record("Expected an authentication failure")
    } catch let error as AppleStremioPlaybackResolutionError {
        guard case .providerFailure(let failure) = error else {
            Issue.record("Expected provider authentication failure, got \(error)")
            return
        }
        #expect(failure.kind == .authentication)
    }
}

private actor ResolutionLoadProbe {
    var active = 0
    var starts = 0
    func begin() { active += 1; starts += 1 }
    func end() { active -= 1 }
}

@Test func rankedStreamsCancelSlowProviderAndTryNextWithinOverallBudget() async throws {
    let probe = ResolutionLoadProbe()
    let client = AppleStremioPlaybackClient { request in
        if request.url?.host == "slow.example" {
            await probe.begin()
            do { try await Task.sleep(for: .seconds(10)) }
            catch { await probe.end(); throw error }
            await probe.end()
        }
        return (Data(#"{"streams":[{"url":"https://media.example/ready.mp4"}]}"#.utf8),
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    let first = stremioSource(url: "https://slow.example/manifest.json")
    let resolver = AppleStremioPlaybackResolver(client: client, resolutionTimeout: .seconds(2), sourceTimeout: .milliseconds(100))
    let result = try await resolver.rankedCandidates(sources: [first, stremioSource(url: "https://ready.example/manifest.json")],
        preferredSourceID: first.id, item: .init(mediaID: "tt123", type: "movie", name: "Fixture"))
    #expect(result.first?.sourceURL.absoluteString == "https://media.example/ready.mp4")
    #expect(await probe.starts == 1)
    #expect(await probe.active == 0)
}

@Test func rankedStreamsEnforceOverallDeadlineAndCancelOutstandingRequests() async throws {
    let probe = ResolutionLoadProbe()
    let client = AppleStremioPlaybackClient { request in
        await probe.begin()
        do { try await Task.sleep(for: .seconds(10)) }
        catch { await probe.end(); throw error }
        await probe.end()
        return (Data(#"{"streams":[]}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    let resolver = AppleStremioPlaybackResolver(client: client, resolutionTimeout: .milliseconds(250), sourceTimeout: .milliseconds(150))
    let start = ContinuousClock.now
    do {
        _ = try await resolver.rankedCandidates(sources: (0..<8).map { stremioSource(url: "https://slow\($0).example/manifest.json") },
            item: .init(mediaID: "tt123", type: "movie", name: "Fixture"))
        Issue.record("Expected overall resolution deadline")
    } catch {
        #expect(ApplePlaybackFailure.classify(error).kind == .timedOut)
    }
    #expect(start.duration(to: .now) < .seconds(2))
    #expect(await probe.starts <= 2)
    #expect(await probe.active == 0)
}

@Test func rankedStreamsPropagateCallerCancellation() async throws {
    let probe = ResolutionLoadProbe()
    let client = AppleStremioPlaybackClient { request in
        await probe.begin()
        do { try await Task.sleep(for: .seconds(10)) }
        catch { await probe.end(); throw error }
        await probe.end()
        return (Data(#"{"streams":[]}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    let resolver = AppleStremioPlaybackResolver(client: client)
    let source = stremioSource()
    let operation = Task {
        try await resolver.rankedCandidates(sources: [source], item: .init(mediaID: "tt123", type: "movie", name: "Fixture"))
    }
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while await probe.starts == 0, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    operation.cancel()
    do {
        _ = try await operation.value
        Issue.record("Expected caller cancellation")
    } catch {
        #expect(error is CancellationError)
    }
    #expect(await probe.starts == 1)
    #expect(await probe.active == 0)
}

@Test func stremioPlaybackClientEncodesEachPathSegmentAndParsesHTTPStreams() async throws {
    let client = AppleStremioPlaybackClient { request in
        #expect(request.url?.absoluteString ==
            "https://addon.example/config/stream/series/tt123%3A1%2F%2E%2E%2F%C3%A9.json")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "OpenStream/1.0 Apple")
        let data = Data(#"{"streams":[{"title":"1080p\nHEVC","url":"https://media.example/movie.mp4?token=one","behaviorHints":{"filename":"Film\t2026.mp4"}}]}"#.utf8)
        return (
            data,
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }

    let result = try await client.streams(
        source: stremioSource(),
        type: "series",
        mediaID: "tt123:1/../é"
    )

    #expect(result.httpCandidates.count == 1)
    #expect(result.httpCandidates[0].title == "1080p HEVC")
    #expect(result.httpCandidates[0].filename == "Film 2026.mp4")
    #expect(result.httpCandidates[0].requiresRuntimeInspection)
    #expect(result.unsupported.isEmpty)
}

@Test func stremioStreamParsingSeparatesDirectHTTPFromUnsupportedLocators() throws {
    let data = Data(#"""
    {
      "streams": [
        {"title":"HTTPS","url":"https://media.example/film.mkv"},
        {"title":"Duplicate","url":"https://media.example/film.mkv"},
        {"name":"HTTP","url":"http://192.168.1.20/live.m3u8"},
        {"title":"Torrent","infoHash":"0123456789abcdef0123456789abcdef01234567","fileIdx":2,"sources":["tracker:udp://tracker.example:80","dht:0123456789abcdef0123456789abcdef01234567"]},
        {"title":"Base32","infoHash":"ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"},
        {"title":"YouTube","ytId":"dQw4w9WgXcQ"},
        {"title":"Related","externalUrl":"stremio:///detail/movie/tt123"},
        {"title":"Unsafe","url":"file:///private/movie.mp4"},
        {"title":"Credentials","url":"https://user:pass@media.example/movie.mp4"},
        {"title":"Invalid hash","infoHash":"not-a-hash"},
        {"title":"Missing"},
        42
      ]
    }
    """#.utf8)

    let result = try AppleStremioPlaybackClient.parseStreams(data)

    #expect(result.httpCandidates.map(\.title) == ["HTTPS", "HTTP"])
    #expect(result.httpCandidates.map(\.sourceURL.scheme) == ["https", "http"])
    #expect(result.unsupported.count == 8)
    #expect(result.unsupported[0].reason == .torrent(
        infoHash: "0123456789abcdef0123456789abcdef01234567",
        fileIndex: 2,
        sources: [
            "tracker:udp://tracker.example:80",
            "dht:0123456789abcdef0123456789abcdef01234567",
        ]
    ))
    #expect(result.unsupported[1].reason == .torrent(
        infoHash: "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567",
        fileIndex: nil,
        sources: []
    ))
    #expect(result.unsupported[2].reason == .youtube(videoID: "dQw4w9WgXcQ"))
    #expect(result.unsupported[3].reason == .externalLink(URL(string: "stremio:///detail/movie/tt123")!))
    #expect(result.unsupported[4].reason == .invalidHTTPURL)
    #expect(result.unsupported[5].reason == .invalidHTTPURL)
    #expect(result.unsupported[6].reason == .invalidLocator)
    #expect(result.unsupported[7].reason == .missingLocator)
}

@Test func stremioStreamParsingHonorsWebReadinessAndSafeProxyHeaders() throws {
    let data = Data(#"""
    {
      "streams": [{
        "title": "Provider stream",
        "url": "https://media.example/master.m3u8",
        "behaviorHints": {
          "notWebReady": true,
          "proxyHeaders": {
            "request": {
              "User-Agent": "Provider Player/1.0",
              "Referer": "https://provider.example/watch",
              "Authorization": "Bearer private-token",
              "Host": "attacker.example",
              "X-Custom": "ignored",
              "Cookie": "bad\r\nInjected: yes"
            }
          }
        }
      }]
    }
    """#.utf8)

    let stream = try #require(AppleStremioPlaybackClient.parseStreams(data).httpCandidates.first)
    #expect(stream.requiresGateway)
    #expect(stream.requestHeaders == [
        "User-Agent": "Provider Player/1.0",
        "Referer": "https://provider.example/watch",
        "Authorization": "Bearer private-token",
    ])
}

@Test func stremioPlaybackResolverProtectsHeaderBearingStreamURLs() async throws {
    let upstream = URL(string: "https://media.example/master.m3u8?token=private")!
    let protected = URL(string: "http://127.0.0.1:12345/live/opaque/stream.m3u8")!
    let expectedHeaders = ["Referer": "https://provider.example/watch"]
    let client = AppleStremioPlaybackClient { request in
        let data = Data(#"{"streams":[{"url":"https://media.example/master.m3u8?token=private","behaviorHints":{"proxyHeaders":{"request":{"Referer":"https://provider.example/watch"}}}}]}"#.utf8)
        return (
            data,
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }
    let resolver = AppleStremioPlaybackResolver(
        client: client,
        inspector: { url in
            #expect(url == protected)
            return playableInspection()
        },
        preparer: { url, _, _, gatewayRequest in
            #expect(url == protected)
            #expect(gatewayRequest == nil)
            return ApplePreparedPlayback(route: .direct(url), url: url)
        },
        protectedPlaybackURL: { url, headers in
            #expect(url == upstream)
            #expect(headers == expectedHeaders)
            return protected
        }
    )

    let result = try await resolver.resolve(
        source: stremioSource(),
        item: AppleCatalogItem(mediaID: "tt123", type: "movie", name: "Film")
    )

    #expect(result.preparedPlayback.url == protected)
    #expect(result.preparedPlayback.requestHeaders.isEmpty)
}

@Test func stremioPlaybackResolverRevokesRejectedProtectedCapabilities() async throws {
    let recorder = PlaybackResolutionRecorder()
    let first = URL(string: "http://127.0.0.1:12345/live/first/stream.m3u8")!
    let second = URL(string: "http://127.0.0.1:12345/live/second/stream.m3u8")!
    let client = AppleStremioPlaybackClient { request in
        let data = Data(#"{"streams":[{"url":"https://media.example/first.m3u8","behaviorHints":{"proxyHeaders":{"request":{"Referer":"https://provider.example"}}}},{"url":"https://media.example/second.m3u8","behaviorHints":{"proxyHeaders":{"request":{"Referer":"https://provider.example"}}}}]}"#.utf8)
        return (
            data,
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }
    let resolver = AppleStremioPlaybackResolver(
        client: client,
        inspector: { _ in playableInspection() },
        preparer: { url, _, _, _ in
            if url == first { throw ApplePlaybackPreparationError.unavailable(["Rejected"]) }
            return ApplePreparedPlayback(route: .direct(url), url: url)
        },
        protectedPlaybackURL: { url, _ in
            url.lastPathComponent == "first.m3u8" ? first : second
        },
        revokeProtectedPlaybackURL: { await recorder.recordRevocation($0) }
    )

    let result = try await resolver.resolve(
        source: stremioSource(),
        item: AppleCatalogItem(mediaID: "tt123", type: "movie", name: "Film")
    )

    #expect(result.preparedPlayback.url == second)
    #expect(await recorder.revoked == [first])
}

@Test func malformedStreamMembersDoNotDiscardLaterQualityAlternatives() throws {
    var values: [[String: Any]] = []
    for index in 0 ..< 75 {
        values.append([
            "title": index == 70 ? "2160p DV P8 HEVC" : "1080p H.264 \(index)",
            "url": "https://media.example/\(index).mp4",
        ])
    }
    let payload: [String: Any] = ["streams": ["bad", NSNull()] + values]
    let data = try JSONSerialization.data(withJSONObject: payload)

    let result = try AppleStremioPlaybackClient.parseStreams(data)

    #expect(result.httpCandidates.count == 75)
    #expect(result.httpCandidates.contains { $0.title == "2160p DV P8 HEVC" })
}

@Test func streamLabelsBoundAdversarialCombiningScalars() throws {
    let combiningTitle = "A" + String(repeating: "\u{0301}", count: 10_000)
    let combiningFilename = "F" + String(repeating: "\u{0301}", count: 10_000)
    let payload: [String: Any] = [
        "streams": [[
            "title": combiningTitle,
            "url": "https://media.example/movie.mp4",
            "behaviorHints": ["filename": combiningFilename],
        ]],
    ]

    let result = try AppleStremioPlaybackClient.parseStreams(
        JSONSerialization.data(withJSONObject: payload)
    )

    let stream = try #require(result.httpCandidates.first)
    #expect(stream.title.unicodeScalars.count == 120)
    #expect(stream.title.utf8.count <= 120 * 4)
    #expect(stream.filename?.unicodeScalars.count == 240)
    #expect(stream.filename?.utf8.count ?? 0 <= 240 * 4)
}

@Test func stremioSubtitleClientEncodesEpisodeIdentityAndKeepsSafeTracks() async throws {
    let client = AppleStremioPlaybackClient { request in
        #expect(request.url?.absoluteString ==
            "https://addon.example/config/subtitles/series/tt765%3A2%3A6.json")
        let data = Data(#"""
        {
          "subtitles": [
            {"id":"english-1","url":"https://subs.example/film.srt?token=1","lang":"eng"},
            {"id":"japanese-1","url":"https://subs.example/path with spaces/film.ass#track","lang":"jpn"},
            {"id":"french-1","url":"http://subs.example/film.ttml","lang":"fra"},
            {"id":"webvtt","url":"https://subs.example/film.vtt","lang":""},
            {"id":"duplicate","url":"https://subs.example/film.vtt","lang":"spa"},
            {"id":"unsafe","url":"file:///private/film.srt","lang":"eng"},
            3
          ]
        }
        """#.utf8)
        return (
            data,
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }

    let tracks = try await client.subtitles(
        source: stremioSource(),
        type: "series",
        mediaID: "tt765:2:6"
    )

    #expect(tracks.map(\.id) == ["english-1", "japanese-1", "french-1", "webvtt"])
    #expect(tracks.map(\.language) == ["eng", "jpn", "fra", "und"])
    #expect(tracks.map(\.mimeType) == [
        "application/x-subrip", "text/x-ssa", "application/ttml+xml", "text/vtt",
    ])
    #expect(tracks[1].url.absoluteString.contains("path%20with%20spaces"))
}

@Test func stremioPlaybackClientRetriesTransientStatusesWithBoundedBackoff() async throws {
    let recorder = PlaybackRequestRecorder()
    let client = AppleStremioPlaybackClient(
        loader: { request in
            let attempt = await recorder.recordRequest()
            let status = attempt == 1 ? 503 : (attempt == 2 ? 429 : 200)
            let data = Data(#"{"streams":[]}"#.utf8)
            return (
                data,
                HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            )
        },
        sleeper: { duration in await recorder.recordSleep(duration) }
    )

    let result = try await client.streams(source: stremioSource(), type: "movie", mediaID: "tt1")

    #expect(result == .empty)
    #expect(await recorder.requestCount == 3)
    #expect(await recorder.sleeps == [.milliseconds(250), .milliseconds(500)])
}

@Test func stremioPlaybackClientRetriesTransportErrorsButNotOrdinaryHTTPFailures() async throws {
    let transportRecorder = PlaybackRequestRecorder()
    let transportClient = AppleStremioPlaybackClient(
        loader: { request in
            let attempt = await transportRecorder.recordRequest()
            if attempt < 4 { throw URLError(.timedOut) }
            return (
                Data(#"{"streams":[]}"#.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        },
        sleeper: { duration in await transportRecorder.recordSleep(duration) }
    )
    _ = try await transportClient.streams(source: stremioSource(), type: "movie", mediaID: "tt1")
    #expect(await transportRecorder.requestCount == 4)
    #expect(await transportRecorder.sleeps == [.milliseconds(250), .milliseconds(500), .seconds(1)])

    let ordinaryRecorder = PlaybackRequestRecorder()
    let ordinaryClient = AppleStremioPlaybackClient { request in
        _ = await ordinaryRecorder.recordRequest()
        return (
            Data(),
            HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
        )
    }
    do {
        _ = try await ordinaryClient.streams(source: stremioSource(), type: "movie", mediaID: "tt1")
        Issue.record("Expected a non-retryable HTTP failure")
    } catch let error as AppleStremioPlaybackError {
        #expect(error == .requestFailed(404))
    }
    #expect(await ordinaryRecorder.requestCount == 1)
}

@Test func stremioPlaybackClientRejectsOversizedAndInsecureResponses() async throws {
    let oversized = AppleStremioPlaybackClient { request in
        let headers = ["Content-Length": "\(AppleStremioPlaybackClient.maximumResponseBytes + 1)"]
        return (
            Data(#"{"streams":[]}"#.utf8),
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!
        )
    }
    do {
        _ = try await oversized.streams(source: stremioSource(), type: "movie", mediaID: "tt1")
        Issue.record("Expected an oversized response failure")
    } catch let error as AppleStremioPlaybackError {
        #expect(error == .responseTooLarge)
    }

    let insecure = AppleStremioPlaybackClient { request in
        return (
            Data(#"{"streams":[]}"#.utf8),
            HTTPURLResponse(
                url: request.url!,
                statusCode: 302,
                httpVersion: nil,
                headerFields: ["Location": "http://addon.example/stream/movie/tt1.json"]
            )!
        )
    }
    do {
        _ = try await insecure.streams(source: stremioSource(), type: "movie", mediaID: "tt1")
        Issue.record("Expected an insecure redirect failure")
    } catch let error as AppleStremioPlaybackError {
        #expect(error == .insecureRedirect)
    }
}

@Test func stremioPlaybackClientAcceptsLoopbackHTTPFixtureResponses() async throws {
    let client = AppleStremioPlaybackClient { request in
        (
            Data(#"{"streams":[{"name":"Fixture 1080p","url":"http://127.0.0.1:8766/media/mkv-h264-aac.mkv"}]}"#.utf8),
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }

    let result = try await client.streams(
        source: stremioSource(url: "http://127.0.0.1:8766/addon/manifest.json"),
        type: "movie",
        mediaID: "tt9018736"
    )

    #expect(result.httpCandidates.count == 1)
    #expect(result.httpCandidates.first?.title == "Fixture 1080p")
}

@Test func stremioPlaybackClientSkipsNetworkForUnavailableResources() async throws {
    let client = AppleStremioPlaybackClient { _ in
        Issue.record("No request should be made")
        throw URLError(.unknown)
    }

    let disabled = try await client.streams(
        source: stremioSource(enabled: false),
        type: "movie",
        mediaID: "tt1"
    )
    let noStreams = try await client.streams(
        source: stremioSource(resources: ["subtitles"]),
        type: "movie",
        mediaID: "tt1"
    )
    let noSubtitles = try await client.subtitles(
        source: stremioSource(resources: ["stream"]),
        type: "movie",
        mediaID: "tt1"
    )

    #expect(disabled == .empty)
    #expect(noStreams == .empty)
    #expect(noSubtitles.isEmpty)
}

@Test func stremioPlaybackClientRejectsInvalidSourceIdentityAndPayload() async throws {
    let client = AppleStremioPlaybackClient { request in
        (
            Data("not json".utf8),
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }

    do {
        _ = try await client.streams(source: stremioSource(), type: "movie", mediaID: "   ")
        Issue.record("Expected an invalid media identity")
    } catch let error as AppleStremioPlaybackError {
        #expect(error == .invalidMediaIdentity)
    }

    do {
        _ = try await client.streams(source: stremioSource(), type: "movie", mediaID: "tt1")
        Issue.record("Expected invalid JSON to fail")
    } catch let error as AppleStremioPlaybackError {
        #expect(error == .invalidPayload)
    }

    do {
        _ = try await client.streams(
            source: stremioSource(url: "http://addon.example/manifest.json"),
            type: "movie",
            mediaID: "tt1"
        )
        Issue.record("Expected an invalid source")
    } catch let error as AppleStremioPlaybackError {
        #expect(error == .invalidSource)
    }
}

@Test func stremioPlaybackResolverInspectsCandidatesUntilOnePrepares() async throws {
    let recorder = PlaybackResolutionRecorder()
    let client = AppleStremioPlaybackClient { request in
        let data = Data(#"""
        {"streams":[
          {"title":"First","url":"https://media.example/first.mp4"},
          {"title":"Second","url":"https://media.example/second.mp4"}
        ]}
        """#.utf8)
        return (
            data,
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }
    let inspection = playableInspection()
    let resolver = AppleStremioPlaybackResolver(
        client: client,
        inspector: { url in
            await recorder.recordInspection(url)
            return inspection
        },
        preparer: { url, decision, receivedInspection, gatewayRequest in
            await recorder.recordPreparation(url, decision: decision, inspection: receivedInspection)
            #expect(gatewayRequest == nil)
            if url.lastPathComponent == "first.mp4" {
                throw ApplePlaybackPreparationError.unavailable(["Rejected"])
            }
            return ApplePreparedPlayback(route: .direct(url), url: url)
        }
    )
    let item = AppleCatalogItem(mediaID: "tt123", type: "movie", name: "Film")

    let result = try await resolver.resolve(source: stremioSource(), item: item)

    #expect(result.stream.title == "Second")
    #expect(result.preparedPlayback.url == URL(string: "https://media.example/second.mp4"))
    #expect(Set(await recorder.inspected.map(\.lastPathComponent)) == ["first.mp4", "second.mp4"])
    #expect((await recorder.prepared.map(\.lastPathComponent)).contains("second.mp4"))
    #expect(await recorder.decisions.allSatisfy { $0.support == .supported })
}

@Test func stremioPlaybackResolverBoundsConcurrentCandidateInspection() async throws {
    let concurrency = PlaybackConcurrencyRecorder()
    let client = AppleStremioPlaybackClient { request in
        let data = Data(#"""
        {"streams":[
          {"title":"First","url":"https://media.example/first.mp4"},
          {"title":"Second","url":"https://media.example/second.mp4"}
        ]}
        """#.utf8)
        return (
            data,
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }
    let resolver = AppleStremioPlaybackResolver(
        client: client,
        inspector: { _ in
            await concurrency.beginAndWaitForPeer()
            await concurrency.finish()
            return playableInspection()
        },
        preparer: { url, _, _, _ in
            if url.lastPathComponent == "first.mp4" {
                throw ApplePlaybackPreparationError.unavailable(["Rejected"])
            }
            return ApplePreparedPlayback(route: .direct(url), url: url)
        }
    )

    let result = try await resolver.resolve(
        source: stremioSource(),
        item: AppleCatalogItem(mediaID: "tt123", type: "movie", name: "Film")
    )

    #expect(result.stream.title == "Second")
    #expect(await concurrency.maximumActive == 2)
}

@Test func stremioPlaybackResolverUsesPlaybackAddonForCatalogOnlyTitles() async throws {
    let catalogSource = AppleSource(
        kind: .stremio,
        name: "Catalogs",
        url: URL(string: "https://catalog.example/manifest.json")!,
        resources: ["catalog"]
    )
    let playbackSource = stremioSource(url: "https://streams.example/manifest.json")
    let client = AppleStremioPlaybackClient { request in
        #expect(request.url?.host == "streams.example")
        return (
            Data(#"{"streams":[{"title":"Direct","url":"https://media.example/film.mp4"}]}"#.utf8),
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }
    let resolver = AppleStremioPlaybackResolver(
        client: client,
        inspector: { _ in playableInspection() },
        preparer: { url, _, _, _ in ApplePreparedPlayback(route: .direct(url), url: url) }
    )

    let result = try await resolver.resolve(
        sources: [catalogSource, playbackSource],
        preferredSourceID: catalogSource.id,
        item: AppleCatalogItem(mediaID: "tt123", type: "movie", name: "Film")
    )

    #expect(result.stream.title == "Direct")
    #expect(result.preparedPlayback.url == URL(string: "https://media.example/film.mp4"))
}

@Test func offlineResolutionDownloadsOriginalMediaWithoutPlaybackInspection() async throws {
    let original = URL(string: "https://media.example/film.mkv")!
    let client = AppleStremioPlaybackClient { request in
        (
            Data(#"{"streams":[{"title":"Original MKV","url":"https://media.example/film.mkv","behaviorHints":{"notWebReady":true}}]}"#.utf8),
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }
    let resolver = AppleStremioPlaybackResolver(
        client: client,
        inspector: { _ in
            Issue.record("Offline resolution must not wait for AVFoundation inspection")
            throw URLError(.cannotDecodeContentData)
        },
        preparer: { _, _, _, _ in
            Issue.record("Offline resolution must not require a playable native route")
            throw ApplePlaybackPreparationError.externalDemuxRequired
        }
    )

    let plan = try await resolver.resolveDownloadPlan(
        sources: [stremioSource()],
        item: AppleCatalogItem(mediaID: "tt123", type: "movie", name: "Film")
    )

    #expect(plan.sourceURL == original)
    #expect(plan.requestHeaders.isEmpty)
    #expect(plan.protectedCapabilityToRevoke == nil)
}

@Test func offlineResolutionKeepsOrderedFallbackCandidates() async throws {
    let first = URL(string: "https://media.example/stale.mp4")!
    let second = URL(string: "https://media.example/working.mp4")!
    let client = AppleStremioPlaybackClient { request in
        (
            Data(#"{"streams":[{"title":"Stale","url":"https://media.example/stale.mp4"},{"title":"Working","url":"https://media.example/working.mp4"}]}"#.utf8),
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }
    let resolver = AppleStremioPlaybackResolver(
        client: client,
        inspector: { _ in
            Issue.record("Offline resolution must not inspect download candidates")
            throw URLError(.cannotDecodeContentData)
        },
        preparer: { _, _, _, _ in
            Issue.record("Offline resolution must not prepare download candidates")
            throw ApplePlaybackPreparationError.externalDemuxRequired
        }
    )

    let plans = try await resolver.resolveDownloadPlans(
        sources: [stremioSource()],
        item: AppleCatalogItem(mediaID: "tt123", type: "movie", name: "Film")
    )

    #expect(plans.map(\.sourceURL) == [first, second])
    #expect(plans.allSatisfy { $0.requestHeaders.isEmpty })
}

@Test func offlineResolutionShieldsProviderHeadersBehindTemporaryCapability() async throws {
    let upstream = URL(string: "https://media.example/master.m3u8?token=private")!
    let capability = URL(string: "http://127.0.0.1:12345/offline/opaque/master.m3u8")!
    let expectedHeaders = ["Authorization": "Bearer private"]
    let client = AppleStremioPlaybackClient { request in
        (
            Data(#"{"streams":[{"url":"https://media.example/master.m3u8?token=private","behaviorHints":{"proxyHeaders":{"request":{"Authorization":"Bearer private"}}}}]}"#.utf8),
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }
    let resolver = AppleStremioPlaybackResolver(
        client: client,
        inspector: { _ in playableInspection() },
        preparer: { url, _, _, _ in ApplePreparedPlayback(route: .direct(url), url: url) },
        protectedPlaybackURL: { url, headers in
            #expect(url == upstream)
            #expect(headers == expectedHeaders)
            return capability
        }
    )

    let plan = try await resolver.resolveDownloadPlan(
        sources: [stremioSource()],
        item: AppleCatalogItem(mediaID: "tt123", type: "movie", name: "Film")
    )

    #expect(plan.sourceURL == capability)
    #expect(plan.requestHeaders.isEmpty)
    #expect(plan.protectedCapabilityToRevoke == capability)
}

@Test func stremioPlaybackResolverReportsUnsupportedOnlyResultsWithoutInspecting() async throws {
    let recorder = PlaybackResolutionRecorder()
    let client = AppleStremioPlaybackClient { request in
        let data = Data(#"{"streams":[{"title":"Torrent","infoHash":"0123456789abcdef0123456789abcdef01234567"}]}"#.utf8)
        return (
            data,
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }
    let resolver = AppleStremioPlaybackResolver(
        client: client,
        inspector: { url in
            await recorder.recordInspection(url)
            return playableInspection()
        },
        preparer: { url, _, _, _ in ApplePreparedPlayback(route: .direct(url), url: url) }
    )

    do {
        _ = try await resolver.resolve(
            source: stremioSource(),
            item: AppleCatalogItem(mediaID: "tt123", type: "movie", name: "Film")
        )
        Issue.record("Expected the unsupported locator to remain non-playable")
    } catch let error as AppleStremioPlaybackResolutionError {
        #expect(error == .unsupportedOnly(.torrent(
            infoHash: "0123456789abcdef0123456789abcdef01234567",
            fileIndex: nil,
            sources: []
        )))
        #expect(error.localizedDescription == "Torrent resolver required.")
    }
    #expect(await recorder.inspected.isEmpty)
}

@Test func stremioPlaybackResolverPassesRejectedRemoteStreamToConfiguredGateway() async throws {
    let sourceURL = URL(string: "https://media.example/film.mkv")!
    let config = try AppleTranscodeGatewayConfig(
        baseURL: "https://gateway.example",
        sessionToken: String(repeating: "g", count: 32)
    )
    let client = AppleStremioPlaybackClient { request in
        let data = Data(#"{"streams":[{"title":"MKV","url":"https://media.example/film.mkv"}]}"#.utf8)
        return (
            data,
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }
    let resolver = AppleStremioPlaybackResolver(
        client: client,
        inspector: { _ in throw URLError(.cannotDecodeContentData) },
        preparer: { url, decision, inspection, request in
            #expect(url == sourceURL)
            #expect(decision.support == .unsupported)
            #expect(!inspection.playable)
            #expect(request == AppleGatewayTranscodeRequest(
                config: config,
                source: .remoteURL(sourceURL),
                maximumWidth: 3_840,
                maximumHeight: 2_160
            ))
            let scopedURL = URL(string: "https://gateway.example/api/transcode/media?transcodeId=gggggggggggggggggggggggggggggggg")!
            return ApplePreparedPlayback(route: .gatewayTranscode(url), url: scopedURL)
        }
    )

    let result = try await resolver.resolve(
        source: stremioSource(),
        item: AppleCatalogItem(mediaID: "tt123", type: "movie", name: "Film"),
        gatewayConfig: config
    )

    #expect(result.preparedPlayback.route == .gatewayTranscode(sourceURL))
    #expect(result.preparedPlayback.requestHeaders.isEmpty)
}

@Test func stremioPlaybackDecisionUsesRuntimeEvidenceRatherThanCodecLabels() {
    let playable = AppleStremioPlaybackResolver.decision(for: playableInspection())
    let rejected = AppleStremioPlaybackResolver.decision(for: AppleAssetInspection(
        formats: [OpenStreamFormat(
            dynamicRange: .sdr,
            codec: "avc1",
            width: 1920,
            height: 1080,
            frameRate: 24
        )],
        playable: false,
        readable: true,
        exportable: false,
        protectedContent: false
    ))

    #expect(playable.support == .supported)
    #expect(rejected.support == .unsupported)
}

private func playableInspection() -> AppleAssetInspection {
    AppleAssetInspection(
        formats: [],
        playable: true,
        readable: true,
        exportable: false,
        protectedContent: false
    )
}

private actor PlaybackRequestRecorder {
    private(set) var requestCount = 0
    private(set) var sleeps: [Duration] = []

    func recordRequest() -> Int {
        requestCount += 1
        return requestCount
    }

    func recordSleep(_ duration: Duration) {
        sleeps.append(duration)
    }
}

private actor PlaybackResolutionRecorder {
    private(set) var inspected: [URL] = []
    private(set) var prepared: [URL] = []
    private(set) var decisions: [OpenStreamPlaybackDecision] = []
    private(set) var revoked: [URL] = []

    func recordInspection(_ url: URL) {
        inspected.append(url)
    }

    func recordPreparation(
        _ url: URL,
        decision: OpenStreamPlaybackDecision,
        inspection: AppleAssetInspection
    ) {
        prepared.append(url)
        decisions.append(decision)
        #expect(inspection == playableInspection())
    }

    func recordRevocation(_ url: URL) {
        revoked.append(url)
    }
}

private actor PlaybackConcurrencyRecorder {
    private(set) var active = 0
    private(set) var maximumActive = 0
    private var observedPeer = false

    func beginAndWaitForPeer() async {
        active += 1
        maximumActive = max(maximumActive, active)
        if active >= 2 { observedPeer = true }
        while !observedPeer { await Task.yield() }
    }

    func finish() {
        active -= 1
    }
}

@Test func imdbIdentifierDetectionMatchesMoviesAndSeriesEpisodes() {
    // Movies and series-episode ids are already stream-add-on friendly.
    #expect(AppleStremioMetadataClient.isIMDBIdentifier("tt10986410"))
    #expect(AppleStremioMetadataClient.isIMDBIdentifier("tt0126029:1:2"))
    // Catalog add-ons (RT / Streaming Catalogs) key items by ids Torrentio
    // cannot resolve — these must NOT be treated as IMDB ids so the meta
    // lookup runs instead.
    #expect(!AppleStremioMetadataClient.isIMDBIdentifier("tmdb:12345"))
    #expect(!AppleStremioMetadataClient.isIMDBIdentifier("stremio:rt:ted-lasso"))
    #expect(!AppleStremioMetadataClient.isIMDBIdentifier("kitsu:1"))
    #expect(!AppleStremioMetadataClient.isIMDBIdentifier("tt"))
    #expect(!AppleStremioMetadataClient.isIMDBIdentifier(""))
}

@Test func stremioCandidateRankingPrefersBroadlyCompatibleContainersAndKeepsNotWebReady() {
    let mkv = AppleStremioHTTPPlaybackCandidate(
        title: "MKV",
        sourceURL: URL(string: "https://media.example/film.mkv")!,
        filename: "film.mkv",
        requiresGateway: true
    )
    let mp4 = AppleStremioHTTPPlaybackCandidate(
        title: "MP4",
        sourceURL: URL(string: "https://media.example/film.mp4")!,
        filename: "film.mp4"
    )
    let ts = AppleStremioHTTPPlaybackCandidate(
        title: "TS",
        sourceURL: URL(string: "https://media.example/film.ts")!,
        filename: "film.ts"
    )
    let ranked = AppleStremioCandidateRanking.rank([mkv, mp4, ts])
    #expect(ranked.map(\.title) == ["MP4", "MKV", "TS"])
    // notWebReady candidate is engine-only: kept, never rejected.
    #expect(ranked.contains(mkv))
}

@Test func stremioCandidatePlaybackRequestCopiesProxyHeadersIntoHints() {
    let candidate = AppleStremioHTTPPlaybackCandidate(
        title: "Provider",
        sourceURL: URL(string: "https://media.example/master.m3u8")!,
        filename: "master.m3u8",
        requestHeaders: ["User-Agent": "Provider Player/1.0", "Referer": "https://provider.example/"],
        requiresGateway: true
    )
    let request = candidate.playbackRequest(mediaID: "tt123", title: "Film", resume: 12.5)
    #expect(request.hints.proxyHeaders == [
        "User-Agent": "Provider Player/1.0",
        "Referer": "https://provider.example/",
    ])
    #expect(request.hints.notWebReady == true)
    #expect(request.hints.filename == "master.m3u8")
    #expect(request.sourceKind == .stremio)
    #expect(request.resumePosition == 12.5)
}

@MainActor
@Test func stremioCandidateFallbackTriesNextAfterUnsupportedMediaThenPlays() async {
    let engine = FakePlaybackEngine()
    engine.scriptedRoute = .avPlayer
    let coordinator = ApplePlaybackCoordinator(engine: engine, timeout: .seconds(60))
    let requests = (0..<3).map { index in
        ApplePlaybackRequest(
            url: URL(string: "https://media.example/\(index).mp4")!,
            mediaID: "tt123",
            title: "Film \(index)",
            sourceKind: .stremio
        )
    }
    var failures = 0
    engine.loadHandler = { _ in
        if failures < 2 {
            failures += 1
            throw ApplePlaybackFailure(kind: .unsupportedMedia, message: "unsupported")
        }
        engine.phase = .loading
        engine.emit(.phase(.loading))
        engine.phase = .playing
        engine.emit(.phase(.playing))
    }

    await coordinator.begin(requests[0], fallbackCandidates: Array(requests.dropFirst()))
    #expect(coordinator.phase == .playing)
    #expect(engine.loadedRequests.map(\.url) == requests.map(\.url))
    coordinator.stop()
}

@MainActor
@Test func stremioCandidateFallbackReportsUnsupportedMediaWhenAllCandidatesFail() async {
    let engine = FakePlaybackEngine()
    engine.scriptedRoute = .avPlayer
    let coordinator = ApplePlaybackCoordinator(engine: engine, timeout: .seconds(60))
    let requests = (0..<4).map { index in
        ApplePlaybackRequest(
            url: URL(string: "https://media.example/\(index).mp4")!,
            mediaID: "tt123",
            title: "Film \(index)",
            sourceKind: .stremio
        )
    }
    engine.loadHandler = { _ in
        throw ApplePlaybackFailure(kind: .unsupportedMedia, message: "unsupported")
    }

    await coordinator.begin(requests[0], fallbackCandidates: Array(requests.dropFirst()))
    if case .failed(let failure) = coordinator.phase {
        #expect(failure.kind == .unsupportedMedia)
        #expect(failure.message.contains("None of the"))
    } else {
        Issue.record("expected .failed(.unsupportedMedia), got \(coordinator.phase)")
    }
    // At most three candidates are tried even when four are available.
    #expect(engine.loadedRequests.count == 3)
    coordinator.stop()
}

@Test func automaticRankingComparesQualityAcrossAddons() async throws {
    let client = AppleStremioPlaybackClient { request in
        let high = request.url?.host == "second.example"
        let body = high
            ? #"{"streams":[{"name":"Provider 4K","title":"Film 30 GB","url":"https://media.example/high.mkv","behaviorHints":{"videoSize":30000000000}}]}"#
            : #"{"streams":[{"name":"Provider 1080p","title":"Film 50 GB","url":"https://media.example/low.mp4"}]}"#
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    let first = stremioSource(url: "https://first.example/manifest.json")
    let second = stremioSource(url: "https://second.example/manifest.json")
    let resolver = AppleStremioPlaybackResolver(client: client)
    let candidates = try await resolver.rankedCandidates(sources: [first, second], preferredSourceID: first.id,
        item: .init(mediaID: "tt123", type: "movie", name: "Film"))
    #expect(candidates.map(\.sourceURL.lastPathComponent) == ["high.mkv", "low.mp4"])
    #expect(candidates.first?.sizeBytes == 30_000_000_000)
}

@Test func automaticPlaybackSkipsProviderPreparationClips() async throws {
    let client = AppleStremioPlaybackClient { request in
        let body = #"{"streams":[{"name":"[TB download] Provider 4k","title":"Film 50 GB","url":"https://media.example/pending.mp4"},{"name":"[TB+] Provider 1080p","title":"Film 8 GB","url":"https://media.example/ready.mkv"}]}"#
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    let source = stremioSource(url: "https://provider.example/manifest.json")
    let candidates = try await AppleStremioPlaybackResolver(client: client).rankedCandidates(sources: [source],
        item: .init(mediaID: "tt123", type: "movie", name: "Film"))
    #expect(candidates.map(\.sourceURL.lastPathComponent) == ["ready.mkv"])
}
