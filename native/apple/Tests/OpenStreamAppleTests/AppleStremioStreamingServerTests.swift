import Foundation
import Testing
@testable import OpenStreamApple

@Test func stremioStreamingServerEndpointPolicyRequiresProtectedOrLocalTransport() throws {
    #expect(AppleStremioStreamingServerEndpointPolicy.isAllowed("https://service.example"))
    #expect(AppleStremioStreamingServerEndpointPolicy.isAllowed("http://127.0.0.1:11470"))
    #expect(AppleStremioStreamingServerEndpointPolicy.isAllowed("http://192.168.1.20:11470"))
    #expect(AppleStremioStreamingServerEndpointPolicy.isAllowed("http://media-mac.local:11470"))
    #expect(!AppleStremioStreamingServerEndpointPolicy.isAllowed("http://service.example:11470"))
    #expect(!AppleStremioStreamingServerEndpointPolicy.isAllowed("https://user:pass@service.example"))
    #expect(!AppleStremioStreamingServerEndpointPolicy.isAllowed("https://service.example?token=secret"))
    #expect(try AppleStremioStreamingServerEndpointPolicy.normalize(" https://service.example/ ").absoluteString ==
        "https://service.example")
}

@Test func stremioStreamingServerCreatesTorrentAndBuildsAppleHLSRoute() async throws {
    let recorder = StremioServiceRequestRecorder()
    let client = AppleStremioStreamingServerClient { request in
        await recorder.record(request)
        return (
            Data(#"{"guessedFileIdx":7}"#.utf8),
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }
    let configuration = try AppleStremioStreamingServerConfiguration(
        baseURL: "http://192.168.1.20:11470"
    )
    let candidates = try await client.playbackCandidates(
        title: "4K HDR",
        filename: "Episode.mkv",
        infoHash: "0123456789abcdef0123456789abcdef01234567",
        fileIndex: nil,
        sources: ["udp://tracker.example:80", "tracker:udp://tracker.example:80"],
        seriesInfo: AppleStremioSeriesInfo(mediaID: "tt123:2:4"),
        configuration: configuration
    )

    let requests = await recorder.snapshot()
    let request = try #require(requests.first)
    #expect(request.method == "POST")
    #expect(request.url.absoluteString ==
        "http://192.168.1.20:11470/0123456789abcdef0123456789abcdef01234567/create")
    let body = try #require(request.body)
    let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let torrent = try #require(object["torrent"] as? [String: String])
    #expect(torrent["infoHash"] == "0123456789abcdef0123456789abcdef01234567")
    let guess = try #require(object["guessFileIdx"] as? [String: Int])
    #expect(guess == ["season": 2, "episode": 4])
    let peerSearch = try #require(object["peerSearch"] as? [String: Any])
    let peerSources = try #require(peerSearch["sources"] as? [String])
    #expect(peerSources == [
        "dht:0123456789abcdef0123456789abcdef01234567",
        "tracker:udp://tracker.example:80",
    ])

    #expect(candidates.count == 2)
    let hls = try #require(candidates.first)
    #expect(hls.sourceURL.path.hasPrefix("/hlsv2/"))
    #expect(hls.sourceURL.lastPathComponent == "master.m3u8")
    let hlsComponents = try #require(URLComponents(url: hls.sourceURL, resolvingAgainstBaseURL: false))
    let mediaURL = hlsComponents.queryItems?.first(where: { $0.name == "mediaURL" })?.value
    #expect(mediaURL?.contains("/0123456789abcdef0123456789abcdef01234567/7") == true)
    #expect(hls.filename == "Episode.mkv")
    #expect(candidates[1].sourceURL.path.hasSuffix("/0123456789abcdef0123456789abcdef01234567/7"))
}

@Test func stremioPlaybackResolverUsesConfiguredServiceForTorrentOnlyResult() async throws {
    let addonClient = AppleStremioPlaybackClient { request in
        (
            Data(#"{"streams":[{"title":"Torrent","infoHash":"0123456789abcdef0123456789abcdef01234567","fileIdx":2}]}"#.utf8),
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }
    let serviceClient = AppleStremioStreamingServerClient { request in
        Issue.record("An explicit file index without extra sources should not need a create request: \(request)")
        throw URLError(.badServerResponse)
    }
    let resolver = AppleStremioPlaybackResolver(
        client: addonClient,
        inspector: { url in
            #expect(url.path.hasPrefix("/hlsv2/"))
            return AppleAssetInspection(
                formats: [],
                playable: true,
                readable: true,
                exportable: false,
                protectedContent: false
            )
        },
        preparer: { url, _, _, request in
            #expect(request == nil)
            return ApplePreparedPlayback(route: .direct(url), url: url)
        },
        streamingServerClient: serviceClient
    )
    let configuration = try AppleStremioStreamingServerConfiguration(
        baseURL: "http://127.0.0.1:11470"
    )
    let source = AppleSource(
        kind: .stremio,
        name: "Streams",
        url: URL(string: "https://addon.example/manifest.json")!,
        resources: ["stream"]
    )
    let result = try await resolver.resolve(
        source: source,
        item: AppleCatalogItem(mediaID: "tt123", type: "movie", name: "Film"),
        streamingServerConfiguration: configuration
    )

    #expect(result.stream.sourceURL.path.hasPrefix("/hlsv2/"))
    #expect(result.preparedPlayback.url == result.stream.sourceURL)
}

@Test func stremioStreamingServerConnectionTestUsesSettingsEndpoint() async throws {
    let client = AppleStremioStreamingServerClient { request in
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://service.example/base/settings")
        return (
            Data(#"{"values":{},"options":[]}"#.utf8),
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }
    try await client.testConnection(configuration: .init(baseURL: "https://service.example/base"))
}

private actor StremioServiceRequestRecorder {
    struct Snapshot: Sendable {
        let url: URL
        let method: String?
        let body: Data?
    }

    private var values: [Snapshot] = []

    func record(_ request: URLRequest) {
        values.append(Snapshot(url: request.url!, method: request.httpMethod, body: request.httpBody))
    }

    func snapshot() -> [Snapshot] { values }
}
