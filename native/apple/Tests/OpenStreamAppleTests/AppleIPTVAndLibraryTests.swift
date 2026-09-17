import Foundation
import Testing
@testable import OpenStreamApple

@Test func liveVisibilityRemovesWestDuplicatesAndNoEventSlots() {
    let sourceID = UUID()
    func channel(_ name: String) -> AppleIPTVChannel {
        AppleIPTVChannel(id: name, sourceID: sourceID, name: name, streamURL: URL(string: "https://tv.example/\(name.hashValue)")!)
    }
    let result = AppleChannelVisibilityPolicy.deduplicatedEastChannels([
        channel("248 FX (WEST)"), channel("248 FX"), channel("249 Comedy Central"),
        channel("249 Comedy Central (WEST)"), channel("MAX USA 15: NO EVENT")
    ])
    #expect(result.map(\.name) == ["248 FX", "249 Comedy Central"])
    #expect(Set(result.compactMap { Int($0.name.split(separator: " ").first ?? "") }).count == 2)
}

private final class TestAppleCredentialStore: AppleCredentialStoring {
    enum Failure: Error { case requested }
    var values: [String: String] = [:]
    var readFailures = Set<String>()
    var writeFailures = Set<String>()
    var removalFailures = Set<String>()
    var removals: [String] = []

    func string(for account: String) throws -> String? {
        if readFailures.contains(account) { throw Failure.requested }
        return values[account]
    }
    func set(_ value: String, for account: String) throws {
        if writeFailures.contains(account) { throw Failure.requested }
        values[account] = value
    }
    func remove(_ account: String) throws {
        removals.append(account)
        if removalFailures.contains(account) { throw Failure.requested }
        values.removeValue(forKey: account)
    }
}

private actor IPTVRequestRecorder {
    private(set) var urls: [URL] = []

    func record(_ url: URL) { urls.append(url) }
}

@Test func iptvPolicyAndXtreamEndpointKeepCredentialsOutOfTheBaseURL() throws {
    #expect(try AppleIPTVEndpointPolicy.normalize(" HTTP://TV.Example:8080/base ").absoluteString ==
        "http://tv.example:8080/base")
    #expect(throws: AppleIPTVError.invalidEndpoint) {
        try AppleIPTVEndpointPolicy.normalize("ftp://tv.example/playlist.m3u")
    }
    #expect(throws: AppleIPTVError.invalidEndpoint) {
        try AppleIPTVEndpointPolicy.normalize("http://user:pass@tv.example/playlist.m3u")
    }

    let url = try AppleIPTVClient.xtreamPlaylistURL(
        baseURL: URL(string: "https://tv.example/panel")!,
        username: "viewer+one",
        password: "secret value"
    )
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    #expect(components.path == "/panel/get.php")
    let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    #expect(query["username"] == "viewer+one")
    #expect(query["password"] == "secret value")
    #expect(query["type"] == "m3u_plus")
    #expect(query["output"] == "ts")
}

@Test func iptvParserKeepsMetadataHeadersAndSafeRelativeStreams() throws {
    let sourceID = UUID()
    let data = Data(#"""
    #EXTM3U url-tvg="https://guide.example/guide.xml"
    #EXTINF:-1 tvg-id="news.one" tvg-logo="https://img.example/news.png" group-title="News",News One
    #EXTVLCOPT:http-user-agent=Provider Player
    #EXTVLCOPT:http-referrer=https://tv.example/
    live/news.m3u8
    #EXTINF:-1 group-title="Movies",Cinema
    https://cdn.example/cinema.m3u8
    #EXTINF:-1,Duplicate
    https://cdn.example/cinema.m3u8
    #EXTINF:-1,Unsafe
    file:///private/movie.mp4
    """#.utf8)

    let channels = try AppleIPTVClient.parseM3U(
        data,
        sourceID: sourceID,
        baseURL: URL(string: "https://tv.example/playlist/main.m3u")!
    )

    #expect(channels.count == 2)
    #expect(channels[0].name == "News One")
    #expect(channels[0].group == "News")
    #expect(channels[0].streamURL == URL(string: "https://tv.example/playlist/live/news.m3u8"))
    #expect(channels[0].logoURL == URL(string: "https://img.example/news.png"))
    #expect(channels[0].userAgent == "Provider Player")
    #expect(channels[0].referer == "https://tv.example/")
    #expect(channels[1].name == "Cinema")
}

@Test func xtreamOutputFormatPrefersM3U8WhenAllowedOtherwiseTS() {
    #expect(AppleXtreamOutputFormat.preferred(allowedOutputFormats: ["m3u8", "ts"]) == .ts) // TS always: see AppleXtreamOutputFormat
    #expect(AppleXtreamOutputFormat.preferred(allowedOutputFormats: ["hls"]) == .ts)
    #expect(AppleXtreamOutputFormat.preferred(allowedOutputFormats: ["ts"]) == .ts)
    #expect(AppleXtreamOutputFormat.preferred(allowedOutputFormats: []) == .ts)
}

@Test func iptvParserMapsExtvlcOptOriginOntoRequestHeaders() throws {
    let sourceID = UUID()
    let data = Data(#"""
    #EXTM3U
    #EXTINF:-1 tvg-id="news" group-title="News",News One
    #EXTVLCOPT:http-user-agent=Provider Player
    #EXTVLCOPT:http-referrer=https://tv.example/
    #EXTVLCOPT:http-origin=https://origin.example
    https://cdn.example/news.m3u8
    """#.utf8)

    let channels = try AppleIPTVClient.parseM3U(
        data,
        sourceID: sourceID,
        baseURL: URL(string: "https://tv.example/playlist.m3u")!
    )
    let channel = try #require(channels.first)
    #expect(channel.userAgent == "Provider Player")
    #expect(channel.referer == "https://tv.example/")
    #expect(channel.origin == "https://origin.example")
    #expect(channel.playbackHeaders == [
        "User-Agent": "Provider Player",
        "Referer": "https://tv.example/",
        "Origin": "https://origin.example",
    ])
}

@Test func m3UChannelPlaybackRequestIsLiveAndBypassesTheLoopbackBridge() throws {
    let sourceID = UUID()
    let data = Data(#"""
    #EXTM3U
    #EXTINF:-1,News One
    https://cdn.example/news.m3u8
    """#.utf8)

    let channels = try AppleIPTVClient.parseM3U(
        data,
        sourceID: sourceID,
        baseURL: URL(string: "https://tv.example/playlist.m3u")!
    )
    let channel = try #require(channels.first)
    let request = channel.playbackRequest()
    #expect(request.isLive == true)
    #expect(request.sourceKind == .liveTV)
    #expect(request.url == channel.streamURL)
    #expect(request.headers == channel.playbackHeaders)
    // The loopback bridge is no longer on the playback path: the request URL
    // is the channel's own URL, never a loopback address.
    #expect(request.url.host == "cdn.example")
    #expect(request.url.host != "127.0.0.1")
}

@Test func liveChannelWithVlcOptUserAgentCarriesHeadersInPlaybackRequestWithUpstreamHost() throws {
    let sourceID = UUID()
    let data = Data(#"""
    #EXTM3U
    #EXTINF:-1 tvg-id="news" group-title="News",News One
    #EXTVLCOPT:http-user-agent=Provider Player
    #EXTVLCOPT:http-referrer=https://tv.example/
    https://cdn.example/news.m3u8
    """#.utf8)

    let channels = try AppleIPTVClient.parseM3U(
        data,
        sourceID: sourceID,
        baseURL: URL(string: "https://tv.example/playlist.m3u")!
    )
    let channel = try #require(channels.first)
    let request = channel.playbackRequest()
    // Provider headers from #EXTVLCOPT are attached to the request directly.
    #expect(request.headers["User-Agent"] == "Provider Player")
    #expect(request.headers["Referer"] == "https://tv.example/")
    #expect(request.isLive == true)
    #expect(request.sourceKind == .liveTV)
    // The request uses the upstream host, not the loopback bridge.
    #expect(request.url.host == "cdn.example")
}

@Test func xtreamChannelUsesRawTSEvenWhenAccountAllowsM3U8() async throws {
    let source = AppleSource(
        kind: .liveTV,
        name: "Xtream Account",
        url: URL(string: "http://tv.example:8080")!,
        iptvType: .xtream
    )
    let credentials = AppleIPTVCredentials(username: "viewer", password: "secret")
    let accountJSON = #"{"user_info":{"auth":1,"status":"Active","allowed_output_formats":["m3u8","ts"]}}"#
    let client = AppleIPTVClient(
        loader: { request in
            let components = try #require(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))
            let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            let body: Data
            switch query["action"] {
            case nil:
                body = Data(accountJSON.utf8)
            case "get_live_categories":
                body = Data(#"[{"category_id":"7","category_name":"News"}]"#.utf8)
            case "get_live_streams":
                body = Data(#"[{"stream_id":42,"name":"News One","stream_icon":"https://img.example/news.png","category_id":"7","container_extension":"ts"}]"#.utf8)
            default:
                throw URLError(.unsupportedURL)
            }
            return (
                body,
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        },
        protectedPlaybackURL: { upstream, _ in upstream }
    )

    let channels = try await client.channels(source: source, credentials: credentials)
    let channel = try #require(channels.first)
    // Live Xtream channels always use raw .ts, even when the account allows
    // m3u8: the engine demuxes TS in one hop (see AppleXtreamOutputFormat).
    #expect(channel.streamURL.pathExtension == "ts")
    let request = channel.playbackRequest()
    #expect(request.url.pathExtension == "ts")
    #expect(request.isLive == true)
    #expect(request.sourceKind == .liveTV)
}

@Test func xtreamValidationAndSavePathShareNonDefaultPortAccountRequest() async throws {
    let source = AppleSource(
        kind: .liveTV,
        name: "Port 826 Xtream",
        url: URL(string: "http://host:826")!,
        iptvType: .xtream
    )
    let credentials = AppleIPTVCredentials(username: "viewer", password: "secret")
    let recorder = IPTVRequestRecorder()
    let client = AppleIPTVClient(
        loader: { request in
            let url = try #require(request.url)
            await recorder.record(url)
            let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            let body: Data
            switch query["action"] {
            case nil:
                body = Data(#"{"user_info":{"auth":"1","status":"Active"}}"#.utf8)
            case "get_live_categories":
                body = Data(#"[{"category_id":"1","category_name":"News"}]"#.utf8)
            case "get_live_streams":
                body = Data(#"[{"stream_id":7,"name":"News One","category_id":"1","container_extension":"ts"}]"#.utf8)
            default:
                throw URLError(.unsupportedURL)
            }
            return (body, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        },
        protectedPlaybackURL: { upstream, _ in upstream }
    )

    let testChannels = try await client.validate(source: source, credentials: credentials)
    let savedChannels = try await client.channels(source: source, credentials: credentials)

    #expect(testChannels == savedChannels)
    #expect(testChannels.count == 1)
    let urls = await recorder.urls
    #expect(urls.count == 6)
    #expect(urls.allSatisfy { $0.host == "host" && $0.port == 826 && $0.path == "/player_api.php" })
}

@Test func iptvParserAcceptsBOMCommasAndMakesVariantIDsUnique() throws {
    let sourceID = UUID()
    let data = Data("""
    \u{feff}#EXTM3U
    #EXTINF:-1 tvg-id=\"news\" group-title=\"Local\",BBC One, London
    https://tv.example/news-hd.m3u8
    #EXTINF:-1 tvg-id=\"news\" group-title=\"Local\",BBC One, London
    https://tv.example/news-sd.m3u8
    """.utf8)

    let channels = try AppleIPTVClient.parseM3U(
        data,
        sourceID: sourceID,
        baseURL: URL(string: "https://tv.example/playlist.m3u")!
    )
    #expect(channels.map(\.name) == ["BBC One, London", "BBC One, London"])
    #expect(Set(channels.map(\.id)).count == 2)
}

@Test func xtreamClientUsesNativeAPIWhenPlaylistExportsAreUnavailable() async throws {
    let source = AppleSource(
        kind: .liveTV,
        name: "Native Xtream",
        url: URL(string: "http://tv.example:8080")!,
        iptvType: .xtream
    )
    let credentials = AppleIPTVCredentials(username: "viewer@one", password: "secret!value")
    let client = AppleIPTVClient(
        loader: { request in
            let components = try #require(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))
            #expect(components.path == "/player_api.php")
            let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            #expect(query["username"] == "viewer@one")
            #expect(query["password"] == "secret!value")

            let body: Data
            switch query["action"] {
            case nil:
                body = Data(#"{"user_info":{"auth":1,"status":"Active"}}"#.utf8)
            case "get_live_categories":
                body = Data(#"[{"category_id":"7","category_name":"News"}]"#.utf8)
            case "get_live_streams":
                body = Data(#"[{"stream_id":42,"name":"News One","stream_icon":"https://img.example/news.png","category_id":"7","container_extension":"ts"}]"#.utf8)
            default:
                throw URLError(.unsupportedURL)
            }
            return (
                body,
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        },
        protectedPlaybackURL: { upstream, headers in
            #expect(upstream.absoluteString == "http://tv.example:8080/live/viewer%40one/secret%21value/42.ts")
            #expect(headers["User-Agent"] == "OpenStream/1.0 Apple")
            return URL(string: "http://127.0.0.1:12345/live/opaque/stream.ts")!
        }
    )

    let channels = try await client.channels(source: source, credentials: credentials)

    #expect(channels.count == 1)
    #expect(channels[0].name == "News One")
    #expect(channels[0].group == "News")
    #expect(channels[0].streamURL.absoluteString == "http://tv.example:8080/live/viewer%40one/secret%21value/42.ts")
    let protected = try await client.playbackURL(for: channels[0])
    #expect(protected.absoluteString == "http://127.0.0.1:12345/live/opaque/stream.ts")
    #expect(!protected.absoluteString.contains("viewer"))
    #expect(!protected.absoluteString.contains("secret"))
}

@Test func iptvStreamProbeRequiresMediaBytesAndPreservesPlaybackHeaders() async throws {
    let sourceID = UUID()
    let channel = AppleIPTVChannel(
        id: "one",
        sourceID: sourceID,
        name: "News",
        streamURL: URL(string: "http://127.0.0.1:12345/live/opaque/stream.ts")!,
        userAgent: "Provider Player",
        referer: "https://tv.example/"
    )
    let probe = AppleIPTVStreamProbe { request in
        #expect(request.value(forHTTPHeaderField: "Range") == "bytes=0-32767")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "Provider Player")
        #expect(request.value(forHTTPHeaderField: "Referer") == "https://tv.example/")
        return (
            Data(repeating: 0x47, count: 188),
            HTTPURLResponse(url: request.url!, statusCode: 206, httpVersion: nil, headerFields: nil)!
        )
    }

    let result = try await probe.validate(channels: [channel])

    #expect(result == .init(
        statusCode: 206,
        bytesReceived: 188,
        mediaKind: .rawMPEGTransportStream
    ))
}

@Test func iptvStreamProbeRecognizesHLSPlaylistBytes() async throws {
    let channel = AppleIPTVChannel(
        id: "one",
        sourceID: UUID(),
        name: "News",
        streamURL: URL(string: "https://tv.example/live")!
    )
    let probe = AppleIPTVStreamProbe { request in
        (
            Data("#EXTM3U\n#EXT-X-VERSION:7\n".utf8),
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }

    let result = try await probe.validate(channel: channel)
    #expect(result.mediaKind == .hlsPlaylist)
}

@Test func iptvStreamProbeRejectsEmptyOrUnauthorizedStreams() async throws {
    let channel = AppleIPTVChannel(
        id: "one",
        sourceID: UUID(),
        name: "News",
        streamURL: URL(string: "https://tv.example/live.ts")!
    )
    let empty = AppleIPTVStreamProbe { request in
        (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    await #expect(throws: AppleIPTVError.streamUnavailable) {
        try await empty.validate(channels: [channel])
    }

    let unauthorized = AppleIPTVStreamProbe { request in
        (Data("denied".utf8), HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!)
    }
    await #expect(throws: AppleIPTVError.authenticationFailed(status: nil)) {
        try await unauthorized.validate(channels: [channel])
    }
}

@Test func channelVisibilityKeepsProviderLineupAndHonorsMyChannelsAndPPV() {
    let sourceID = UUID()
    let news = AppleIPTVChannel(
        id: "news",
        sourceID: sourceID,
        name: "News",
        group: "Local",
        streamURL: URL(string: "https://tv.example/news.m3u8")!
    )
    let event = AppleIPTVChannel(
        id: "event",
        sourceID: sourceID,
        name: "PPV 1",
        group: "Pay Per View",
        streamURL: URL(string: "https://tv.example/event.m3u8")!
    )

    #expect(AppleChannelVisibilityPolicy.visibleChannels(
        from: [news, event],
        scope: .providerLineup,
        showPayPerView: false,
        favoriteIDs: []
    ).map(\.id) == ["news"])
    #expect(AppleChannelVisibilityPolicy.visibleChannels(
        from: [news, event],
        scope: .favorites,
        showPayPerView: true,
        favoriteIDs: ["event"]
    ).map(\.id) == ["event"])
    #expect(AppleChannelVisibilityPolicy.visibleChannels(
        from: [
            news,
            AppleIPTVChannel(
                id: "regional-a",
                sourceID: sourceID,
                name: "Regional News",
                group: "Regional",
                streamURL: URL(string: "https://tv.example/regional-news.m3u8")!
            ),
            AppleIPTVChannel(
                id: "affiliate-a",
                sourceID: sourceID,
                name: "World Feed",
                group: "Affiliate Movies",
                streamURL: URL(string: "https://tv.example/affiliate.m3u8")!
            ),
            AppleIPTVChannel(
                id: "region-x",
                sourceID: sourceID,
                name: "North Region",
                group: "Regions",
                streamURL: URL(string: "https://tv.example/regionals.m3u8")!
            ),
            AppleIPTVChannel(
                id: "sports",
                sourceID: sourceID,
                name: "Sports One",
                group: "Sports",
                streamURL: URL(string: "https://tv.example/sports.m3u8")!
            ),
        ],
        scope: .regional,
        showPayPerView: true,
        favoriteIDs: []
    ).map(\.id).sorted() == ["affiliate-a", "region-x", "regional-a"])
    #expect(AppleIPTVEndpointPolicy.isProtectedPlaybackBridge(
        URL(string: "http://127.0.0.1:12345/live/opaque/stream.ts")!
    ))
}

@Test func channelVisibilityHides24x7ByDefaultIncludingSearchInput() {
    let sourceID = UUID()
    let channels = [
        AppleIPTVChannel(id: "filler", sourceID: sourceID, name: "24/7 ALADDIN", group: "Movies", streamURL: URL(string: "https://tv.example/a")!),
        AppleIPTVChannel(id: "filler-group", sourceID: sourceID, name: "Aladdin", group: "247 Classics", streamURL: URL(string: "https://tv.example/b")!),
        AppleIPTVChannel(id: "real", sourceID: sourceID, name: "Comedy Central", group: "Entertainment", streamURL: URL(string: "https://tv.example/c")!),
    ]
    #expect(AppleChannelVisibilityPolicy.visibleChannels(from: channels, scope: .providerLineup, showPayPerView: true, favoriteIDs: []).map(\.id) == ["real"])
    #expect(AppleChannelVisibilityPolicy.visibleChannels(from: channels, scope: .providerLineup, showPayPerView: true, favoriteIDs: [], show24x7: true).count == 3)
    #expect(AppleChannelVisibilityPolicy.is24x7(channels[0]))
    #expect(AppleChannelProjection.matchingChannels(from: [channels[2]], query: "Comedy").map(\.id) == ["real"])
}

@Test func premierGuideGroupsSortsNumbersAndTrailsOther() {
    let sourceID = UUID()
    let entries = [
        AppleChannelLineupEntry(number: 42, name: "Comedy Central", aliases: [], category: "Entertainment"),
        AppleChannelLineupEntry(number: 2, name: "CBS", aliases: [], category: "Broadcast"),
    ]
    let channels = [
        AppleIPTVChannel(id: "other", sourceID: sourceID, name: "Unknown", streamURL: URL(string: "https://tv.example/o")!),
        AppleIPTVChannel(id: "comedy", sourceID: sourceID, name: "Comedy Central", streamURL: URL(string: "https://tv.example/c")!),
        AppleIPTVChannel(id: "cbs", sourceID: sourceID, name: "CBS", streamURL: URL(string: "https://tv.example/cbs")!),
    ]
    let groups = AppleChannelProjection.premierGuideGroups(from: channels, entries: entries)
    #expect(groups.map(\.name) == ["Premier Guide", "Other"])
    #expect(groups[0].channels.map(\.id) == ["cbs", "comedy"])
    #expect(groups[1].channels.map(\.id) == ["other"])
}

@Test func channelProjectionFiltersAndGroupsLargeLineupsOutsideTheViewBody() async {
    let sourceID = UUID()
    let channels = [
        AppleIPTVChannel(
            id: "news-b",
            sourceID: sourceID,
            name: "News B",
            group: "Local",
            streamURL: URL(string: "https://tv.example/news-b.m3u8")!
        ),
        AppleIPTVChannel(
            id: "sports",
            sourceID: sourceID,
            name: "Sports One",
            group: "Sports",
            streamURL: URL(string: "https://tv.example/sports.m3u8")!
        ),
        AppleIPTVChannel(
            id: "news-a",
            sourceID: sourceID,
            name: "News A",
            group: "Local",
            streamURL: URL(string: "https://tv.example/news-a.m3u8")!
        ),
    ]

    let groups = await AppleChannelProjection.buildGroupsOffMain(
        from: channels,
        scope: .providerLineup,
        showPayPerView: true,
        favoriteIDs: [],
        query: "news"
    )
    #expect(groups.map(\.name) == ["Local"])
    #expect(groups.first?.channels.map(\.id) == ["news-a", "news-b"])

    let matches = await AppleChannelProjection.buildMatchesOffMain(
        from: channels,
        query: "Sports"
    )
    #expect(matches.map(\.id) == ["sports"])
}

@Test func stremioMetadataClientLoadsTrailerAndOfficialWordmarkAssets() async throws {
    let source = AppleSource(
        kind: .stremio,
        name: "Metadata",
        url: URL(string: "https://meta.example/manifest.json")!,
        resources: ["meta"]
    )
    let client = AppleStremioMetadataClient { request in
        let data = Data(#"{"meta":{"logo":"https://img.example/logo.png","trailers":[{"source":"trailer_123","type":"Trailer"},{"source":"trailer_456","type":"Trailer"}]}}"#.utf8)
        return (
            data,
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }

    let assets = await client.previewAssets(
        sources: [source],
        preferredSourceID: source.id,
        type: "movie",
        mediaID: "tt1234567"
    )

    #expect(assets?.trailerYouTubeKey == "trailer_123")
    #expect(assets?.trailerYouTubeKeys == ["trailer_123", "trailer_456"])
    #expect(assets?.logoURL == URL(string: "https://img.example/logo.png"))
}

@Test func xtreamClientClassifiesRejectedAccounts() async throws {
    let source = AppleSource(
        kind: .liveTV,
        name: "Native Xtream",
        url: URL(string: "http://tv.example:8080")!,
        iptvType: .xtream
    )
    let client = AppleIPTVClient { request in
        (
            Data(#"{"user_info":{"auth":0,"status":"Disabled"}}"#.utf8),
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }

    await #expect(throws: AppleIPTVError.authenticationFailed(status: "Disabled")) {
        try await client.channels(
            source: source,
            credentials: .init(username: "viewer", password: "wrong")
        )
    }
}

@Test func xtreamClientReportsRejectionStatusInMessage() async throws {
    let source = AppleSource(
        kind: .liveTV,
        name: "Native Xtream",
        url: URL(string: "http://tv.example:8080")!,
        iptvType: .xtream
    )
    let client = AppleIPTVClient { request in
        (
            Data(#"{"user_info":{"auth":0,"status":"Expired"}}"#.utf8),
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }

    do {
        _ = try await client.channels(
            source: source,
            credentials: .init(username: "viewer", password: "wrong")
        )
        Issue.record("Expected authenticationFailed to be thrown")
    } catch let error as AppleIPTVError {
        #expect(error == .authenticationFailed(status: "Expired"))
        #expect(error.errorDescription?.contains("status: Expired") == true)
    }
}

@Test func xtreamClientClassifiesHTMLBlockPageAsUnexpectedResponse() async throws {
    let source = AppleSource(
        kind: .liveTV,
        name: "Native Xtream",
        url: URL(string: "http://tv.example:8080")!,
        iptvType: .xtream
    )
    let client = AppleIPTVClient { request in
        (
            Data("<html><body>Blocked</body></html>".utf8),
            HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html"]
            )!
        )
    }

    await #expect(throws: AppleIPTVError.unexpectedResponse(contentType: "text/html")) {
        try await client.channels(
            source: source,
            credentials: .init(username: "viewer", password: "wrong")
        )
    }
}

@Test func xtreamClientClassifiesNonSuccessStatusAsHTTPStatus() async throws {
    let source = AppleSource(
        kind: .liveTV,
        name: "Native Xtream",
        url: URL(string: "http://tv.example:8080")!,
        iptvType: .xtream
    )
    let client = AppleIPTVClient { request in
        (
            Data("Forbidden".utf8),
            HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!
        )
    }

    await #expect(throws: AppleIPTVError.httpStatus(403)) {
        try await client.channels(
            source: source,
            credentials: .init(username: "viewer", password: "wrong")
        )
    }
}

@Test func xtreamAPIURLTrimsPaddedUsernameAndPassword() throws {
    let url = try AppleIPTVClient.xtreamAPIURL(
        baseURL: URL(string: "http://tv.example:8080")!,
        credentials: .init(username: "user \n", password: "\tpass "),
        action: nil
    )
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    #expect(query["username"] == "user")
    #expect(query["password"] == "pass")
}

@MainActor
@Test func iptvAndLibrarySourcesPersistWithoutLeakingCredentialsIntoURLs() throws {
    let suiteName = "openstream-live-library-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let keychain = TestAppleCredentialStore()
    let store = AppleSourceStore(defaults: defaults, keychain: keychain)
    let validatedAt = Date(timeIntervalSince1970: 1_788_000_000)

    let live = try store.addIPTV(
        name: "Home TV",
        type: .xtream,
        endpoint: "http://192.168.1.50:8080",
        username: "viewer",
        password: "secret",
        lastValidatedAt: validatedAt,
        validationSummary: "Connected · 42 channels",
        discoveredItemCount: 42,
        capabilities: ["Live channels", "Playback"]
    )
    let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "OpenStream Media")
    let library = try store.addLibraryFolder(name: "Media", url: folder, bookmarkData: Data([1, 2, 3]))

    #expect(live.url.absoluteString == "http://192.168.1.50:8080")
    #expect(!live.url.absoluteString.contains("viewer"))
    #expect(live.credentialReference == live.id.uuidString.lowercased())
    #expect(live.lastValidatedAt == validatedAt)
    #expect(live.validationSummary == "Connected · 42 channels")
    #expect(live.discoveredItemCount == 42)
    #expect(live.capabilities == ["Live channels", "Playback"])
    #expect(try store.iptvCredentials(for: live) == .init(username: "viewer", password: "secret"))
    #expect(library.bookmarkData == Data([1, 2, 3]))
    #expect(library.capabilities == ["Files", "Playback"])

    let failureAt = validatedAt.addingTimeInterval(60)
    store.recordValidationFailure(
        id: live.id,
        summary: "Provider rejected the request.\nRetry later.",
        at: failureAt
    )
    let failed = try #require(store.sources.first { $0.id == live.id })
    #expect(failed.lastValidationFailureAt == failureAt)
    #expect(failed.validationFailureSummary == "Provider rejected the request. Retry later.")

    let recoveredAt = failureAt.addingTimeInterval(60)
    store.recordValidationSuccess(
        id: live.id,
        summary: "Connected · 43 channels",
        discoveredItemCount: 43,
        capabilities: ["Live channels", "Playback", "playback"],
        at: recoveredAt
    )
    let recovered = try #require(store.sources.first { $0.id == live.id })
    #expect(recovered.lastValidatedAt == recoveredAt)
    #expect(recovered.discoveredItemCount == 43)
    #expect(recovered.capabilities == ["Live channels", "Playback"])
    #expect(recovered.lastValidationFailureAt == failureAt)
    let persisted = try #require(defaults.data(forKey: "openstream.sources.v1"))
    let persistedText = try #require(String(data: persisted, encoding: .utf8))
    #expect(!persistedText.contains("viewer"))
    #expect(!persistedText.contains("secret"))
    #expect(AppleSourceStore(defaults: defaults, keychain: keychain).sources == store.sources)
}

@MainActor
@Test func sourceStoreLossilyRetainsKnownSourcesWhenAFutureKindExists() throws {
    let suiteName = "openstream-source-lossy-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let source = AppleSource(
        kind: .stremio,
        name: "Known",
        url: URL(string: "https://known.example/manifest.json")!
    )
    let encoded = try JSONEncoder().encode(source)
    let known = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    let future: [String: Any] = [
        "id": UUID().uuidString,
        "kind": "future-provider",
        "name": "Future",
        "url": "https://future.example/",
    ]
    defaults.set(try JSONSerialization.data(withJSONObject: [known, future]), forKey: "openstream.sources.v1")

    let store = AppleSourceStore(defaults: defaults, keychain: TestAppleCredentialStore())
    #expect(store.sources.map(\.id) == [source.id])
    store.setEnabled(false, id: source.id)
    let preserved = try #require(defaults.data(forKey: "openstream.sources.v1"))
    let members = try #require(JSONSerialization.jsonObject(with: preserved) as? [[String: Any]])
    #expect(members.count == 2)
    #expect(members.contains { $0["kind"] as? String == "future-provider" })
}

@MainActor
@Test func credentialBearingTransportURLsPersistOnlyInKeychain() throws {
    let suiteName = "openstream-source-transport-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let keychain = TestAppleCredentialStore()
    let store = AppleSourceStore(defaults: defaults, keychain: keychain)

    let source = try store.addIPTV(
        name: "Private playlist",
        type: .m3u,
        endpoint: "https://tv.example/lineup.m3u?token=private-bearer"
    )
    let reference = try #require(source.transportReference)
    #expect(keychain.values[reference] == source.url.absoluteString)

    let persisted = try #require(defaults.data(forKey: "openstream.sources.v1"))
    let text = String(decoding: persisted, as: UTF8.self)
    #expect(!text.contains("private-bearer"))
    #expect(!text.contains("lineup.m3u"))

    let restored = AppleSourceStore(defaults: defaults, keychain: keychain)
    #expect(restored.sources.first?.url == source.url)
}

@MainActor
@Test func failedSourceSecretCleanupKeepsARetryTombstone() throws {
    let suiteName = "openstream-source-cleanup-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let keychain = TestAppleCredentialStore()
    let store = AppleSourceStore(defaults: defaults, keychain: keychain)
    let source = try store.addIPTV(
        name: "Private playlist",
        type: .m3u,
        endpoint: "https://tv.example/lineup.m3u?token=private-bearer"
    )
    let reference = try #require(source.transportReference)
    keychain.removalFailures = [reference]

    #expect(store.remove(id: source.id))
    #expect(store.sources.isEmpty)
    #expect(keychain.values[reference] != nil)
    #expect(defaults.stringArray(forKey: "openstream.sources.v1.pending-keychain-removals") == [reference])

    keychain.removalFailures = []
    _ = AppleSourceStore(defaults: defaults, keychain: keychain)
    #expect(keychain.values[reference] == nil)
    #expect(defaults.stringArray(forKey: "openstream.sources.v1.pending-keychain-removals") == nil)
}

@MainActor
@Test func failedTransportMigrationNeverOverwritesTheOnlyFullLocator() throws {
    let suiteName = "openstream-source-transport-migration-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let source = AppleSource(
        kind: .liveTV,
        name: "Legacy playlist",
        url: URL(string: "https://tv.example/lineup.m3u?token=only-copy")!,
        iptvType: .m3u
    )
    let original = try JSONEncoder().encode([source])
    defaults.set(original, forKey: "openstream.sources.v1")
    let keychain = TestAppleCredentialStore()
    keychain.writeFailures = ["transport.\(source.id.uuidString.lowercased())"]

    let store = AppleSourceStore(defaults: defaults, keychain: keychain)
    #expect(store.credentialError != nil)
    store.recordValidationSuccess(id: source.id, summary: "Unrelated update")
    #expect(defaults.data(forKey: "openstream.sources.v1") == original)
}

@MainActor
@Test func cleanupTombstoneNeverDeletesAnActiveSourcesSecrets() throws {
    let suiteName = "openstream-source-cleanup-crash-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let keychain = TestAppleCredentialStore()
    let firstStore = AppleSourceStore(defaults: defaults, keychain: keychain)
    let source = try firstStore.addIPTV(
        name: "Private playlist",
        type: .m3u,
        endpoint: "https://tv.example/lineup.m3u?token=still-active"
    )
    let reference = try #require(source.transportReference)
    defaults.set([reference], forKey: "openstream.sources.v1.pending-keychain-removals")

    let restored = AppleSourceStore(defaults: defaults, keychain: keychain)
    #expect(restored.sources.first?.url == source.url)
    #expect(keychain.values[reference] == source.url.absoluteString)
    #expect(defaults.stringArray(forKey: "openstream.sources.v1.pending-keychain-removals") == [reference])
}

@MainActor
@Test func failedLegacyCredentialMigrationPreservesTheOriginalBlob() throws {
    let suiteName = "openstream-source-migration-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let first = AppleSource(kind: .liveTV, name: "One", url: URL(string: "https://one.example")!, iptvType: .xtream)
    let second = AppleSource(kind: .liveTV, name: "Two", url: URL(string: "https://two.example")!, iptvType: .xtream)
    func legacyObject(_ source: AppleSource, username: String, password: String) throws -> [String: Any] {
        let encoded = try JSONEncoder().encode(source)
        var value = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        value["username"] = username
        value["password"] = password
        return value
    }
    let original = try JSONSerialization.data(withJSONObject: [
        legacyObject(first, username: "first-user", password: "first-pass"),
        legacyObject(second, username: "second-user", password: "second-pass"),
    ])
    defaults.set(original, forKey: "openstream.sources.v1")
    let keychain = TestAppleCredentialStore()
    keychain.writeFailures = [second.id.uuidString.lowercased()]

    let store = AppleSourceStore(defaults: defaults, keychain: keychain)
    #expect(store.credentialError != nil)
    store.setEnabled(false, id: first.id)
    #expect(defaults.data(forKey: "openstream.sources.v1") == original)
}

@MainActor
@Test func settingsStoreDoesNotDeleteASecretThatFailedToLoad() throws {
    let suiteName = "openstream-settings-keychain-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let keychain = TestAppleCredentialStore()
    keychain.values["metadata.tmdb.apiKey"] = "still-saved"
    keychain.readFailures = ["metadata.tmdb.apiKey"]

    let store = AppleSettingsStore(defaults: defaults, keychain: keychain)
    #expect(store.persistenceError != nil)
    store.tmdbAPIKey = ""
    #expect(keychain.values["metadata.tmdb.apiKey"] == "still-saved")
    #expect(!keychain.removals.contains("metadata.tmdb.apiKey"))

    store.tmdbAPIKey = "replacement"
    #expect(keychain.values["metadata.tmdb.apiKey"] == "replacement")
    #expect(store.persistenceError == nil)
}

@MainActor
@Test func channelManagerPreferencesPersistLocally() throws {
    let suiteName = "openstream-channel-manager-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let credentials = AppleKeychainStore(service: suiteName)
    var store: AppleSettingsStore? = AppleSettingsStore(defaults: defaults, keychain: credentials)
    store?.liveChannelScope = .favorites
    store?.showPayPerViewChannels = false
    store?.favoriteChannelIDs = ["news", "sports"]
    store = nil

    let restored = AppleSettingsStore(defaults: defaults, keychain: credentials)
    #expect(restored.liveChannelScope == .favorites)
    #expect(!restored.showPayPerViewChannels)
    #expect(restored.favoriteChannelIDs == ["news", "sports"])
}

@Test func smbEndpointPolicyBuildsCredentialFreeServerShareURLs() throws {
    let url = try AppleSMBEndpointPolicy.makeURL(
        host: " media-server.local ",
        port: 1445,
        share: " Movies ",
        path: "/4K/New/"
    )
    #expect(url.absoluteString == "smb://media-server.local:1445/Movies/4K/New")
    #expect(url.user == nil)
    #expect(url.password == nil)

    let parts = try AppleSMBEndpointPolicy.parts(from: url)
    #expect(parts.host == "media-server.local")
    #expect(parts.port == 1445)
    #expect(parts.share == "Movies")
    #expect(parts.path == "4K/New")
    #expect(throws: AppleSMBError.invalidHost) {
        try AppleSMBEndpointPolicy.makeURL(host: "user@server", port: 445, share: "Movies")
    }
    #expect(throws: AppleSMBError.invalidShare) {
        try AppleSMBEndpointPolicy.makeURL(host: "server.local", port: 445, share: "")
    }
}

@Test func smbEndpointInputAcceptsURLsAndHonorsSeparateShareAndPathFields() throws {
    let parsed = try AppleSMBEndpointPolicy.parseInput(
        host: " smb://media-server.local:1445/Files/Unpaid/User-Movies ",
        port: 445,
        share: "",
        path: ""
    )
    #expect(parsed == .init(
        host: "media-server.local",
        port: 1445,
        share: "Files",
        path: "Unpaid/User-Movies"
    ))

    let overridden = try AppleSMBEndpointPolicy.parseInput(
        host: "smb://media-server.local/Files/Unpaid/User-Movies",
        port: 445,
        share: "Movies",
        path: "Family/Films"
    )
    #expect(overridden == .init(
        host: "media-server.local",
        port: 445,
        share: "Movies",
        path: "Family/Films"
    ))
}

@Test func smbEndpointInputRejectsInvalidValuesAndPreservesBonjourServiceInstances() throws {
    #expect(throws: AppleSMBError.invalidHost) {
        try AppleSMBEndpointPolicy.parseInput(host: "", port: 445, share: "Files", path: "")
    }
    #expect(throws: AppleSMBError.invalidHost) {
        try AppleSMBEndpointPolicy.parseInput(host: "https://media-server.local/Files", port: 445, share: "", path: "")
    }
    #expect(throws: AppleSMBError.invalidShare) {
        try AppleSMBEndpointPolicy.parseInput(host: "smb://media-server.local", port: 445, share: "", path: "")
    }

    let input = try AppleSMBEndpointPolicy.parseInput(
        host: "smb://TestNAS._smb._tcp.local/Movies",
        port: 445,
        share: "",
        path: ""
    )
    let service = try #require(AppleSMBEndpointPolicy.bonjourService(from: input.host))
    #expect(service == .init(name: "TestNAS"))
    #expect(input.host.lowercased() == "testnas._smb._tcp.local")
    let url = try AppleSMBEndpointPolicy.makeURL(
        host: input.host,
        port: input.port,
        share: input.share,
        path: input.path
    )
    #expect(url.host?.lowercased() == "testnas._smb._tcp.local")
}

@Test func smbShareDiscoveryAcceptsServerBeforeTheUserChoosesAShare() throws {
    for host in ["media-server.local", "192.168.1.20", "TestNAS._smb._tcp.local",
                 "smb://media-server.local", "smb://media-server.local:1445/"] {
        let input = try AppleSMBEndpointPolicy.parseInput(
            host: host, port: 445, share: "", path: "", requiresShare: false
        )
        #expect(!input.host.isEmpty)
        #expect(input.share.isEmpty)
        #expect(input.port == (host.contains("1445") ? 1445 : 445))
        #expect(throws: AppleSMBError.invalidShare) {
            try AppleSMBEndpointPolicy.makeURL(host: input.host, port: input.port, share: input.share)
        }
        let selected = try AppleSMBEndpointPolicy.makeURL(
            host: input.host, port: input.port, share: "Family Videos", path: "Movies"
        )
        #expect(try AppleSMBEndpointPolicy.parts(from: selected).share == "Family Videos")
    }
    for host in ["", "https://media-server.local", "smb://user:secret@media-server.local",
                 "smb://media-server.local?token=secret"] {
        #expect(throws: AppleSMBError.invalidHost) {
            try AppleSMBEndpointPolicy.parseInput(
                host: host, port: 445, share: "", path: "", requiresShare: false
            )
        }
    }
    #expect(throws: AppleSMBError.invalidPort) {
        try AppleSMBEndpointPolicy.parseInput(
            host: "media-server.local", port: 0, share: "", path: "", requiresShare: false
        )
    }
}

@MainActor
@Test func xtreamAccountHandlesSuspendedNetworkFailureWithoutCrashing() async throws {
    let source = AppleSource(kind: .liveTV, name: "Test", url: URL(string: "https://tv.example")!, iptvType: .xtream)
    let client = AppleIPTVClient { _ in
        try await Task.sleep(for: .milliseconds(5))
        throw URLError(.cannotConnectToHost)
    }
    do {
        _ = try await client.channels(source: source, credentials: .init(username: "test", password: "test"))
        Issue.record("Expected the unavailable provider to fail")
    } catch let error as AppleIPTVError {
        guard case .unreachable = error else {
            Issue.record("Expected a connection error")
            return
        }
    }
}

@MainActor
@Test func xtreamAccountHandlesSuspendedAuthenticationResponseWithoutCrashing() async throws {
    let source = AppleSource(kind: .liveTV, name: "Test", url: URL(string: "https://tv.example")!, iptvType: .xtream)
    let client = AppleIPTVClient { request in
        try await Task.sleep(for: .milliseconds(5))
        return (Data(#"{"user_info":{"auth":0,"status":"Disabled"}}"#.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    await #expect(throws: AppleIPTVError.authenticationFailed(status: "Disabled")) {
        _ = try await client.channels(source: source, credentials: .init(username: "test", password: "test"))
    }
}

@MainActor
@Test func xtreamDefaultClientHandlesARealHTTPResponseWithoutCrashing() async throws {
    let suiteName = "openstream-xtream-http-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let server = AppleWebManagementServer(configuration: .init(
        preferredPort: 0, sessionDuration: 30, advertisesBonjour: false, advertisedHost: "127.0.0.1"
    ))
    let session = try await server.start(sourceStore: AppleSourceStore(defaults: defaults, keychain: TestAppleCredentialStore()))
    defer { server.stop() }
    let source = AppleSource(kind: .liveTV, name: "HTTP response fixture", url: session.friendlyURL, iptvType: .xtream)
    do {
        _ = try await AppleIPTVClient().channels(source: source, credentials: .init(username: "fixture", password: "fixture"))
        Issue.record("The fixture does not provide an IPTV account")
    } catch let error as AppleIPTVError {
        guard case .httpStatus(404) = error else {
            Issue.record("Expected the HTTP fixture's missing account endpoint response")
            return
        }
    }
}

@MainActor
@Test func networkShareSourcePersistsCredentialsOnlyInTheCredentialStore() throws {
    let suiteName = "openstream-smb-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let keychain = TestAppleCredentialStore()
    let store = AppleSourceStore(defaults: defaults, keychain: keychain)
    let validatedAt = Date(timeIntervalSince1970: 1_788_000_100)

    let source = try store.addNetworkShare(
        name: "Family NAS",
        host: "nas.local",
        share: "Media",
        path: "Movies",
        username: "viewer",
        password: "secret",
        domain: "HOME",
        lastValidatedAt: validatedAt,
        validationSummary: "Connected · 7 items",
        discoveredItemCount: 7,
        capabilities: ["Browse", "Playback", "Seeking"]
    )

    #expect(source.kind == .nas)
    #expect(source.url.absoluteString == "smb://nas.local/Media/Movies")
    #expect(source.credentialReference == source.id.uuidString.lowercased())
    #expect(source.lastValidatedAt == validatedAt)
    #expect(source.validationSummary == "Connected · 7 items")
    #expect(source.discoveredItemCount == 7)
    #expect(source.capabilities == ["Browse", "Playback", "Seeking"])
    #expect(try store.networkCredentials(for: source) == .init(
        username: "viewer",
        password: "secret",
        domain: "HOME"
    ))
    let persisted = try #require(defaults.data(forKey: "openstream.sources.v1"))
    let text = try #require(String(data: persisted, encoding: .utf8))
    #expect(!text.contains("viewer"))
    #expect(!text.contains("secret"))
    #expect(AppleSourceStore(defaults: defaults, keychain: keychain).sources == store.sources)

    store.remove(id: source.id)
    #expect(keychain.values.isEmpty)
}

@Test func smbRangeServerParsesBoundedSingleRanges() {
    #expect(AppleSMBRangeServer.parseRange("Range: bytes=0-99", size: 1_000) == 0 ..< 100)
    #expect(AppleSMBRangeServer.parseRange("range: bytes=900-", size: 1_000) == 900 ..< 1_000)
    #expect(AppleSMBRangeServer.parseRange("Range: bytes=-50", size: 1_000) == 950 ..< 1_000)
    #expect(AppleSMBRangeServer.parseRange("Range: bytes=0-9999", size: 1_000) == 0 ..< 1_000)
    #expect(AppleSMBRangeServer.parseRange("Range: bytes=1000-", size: 1_000) == nil)
    #expect(AppleSMBRangeServer.parseRange("Range: bytes=0-1,4-5", size: 1_000) == nil)
}

@Test func libraryScannerFindsOnlySupportedVideoFiles() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "openstream-library-test-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data([0]).write(to: root.appending(path: "Movie.mp4"))
    try Data([0]).write(to: root.appending(path: "Clip.mkv"))
    try Data([0]).write(to: root.appending(path: "Notes.txt"))

    let source = AppleSource(kind: .library, name: "Test", url: root)
    let items = try await AppleLibraryScanner().scan(source: source)

    #expect(items.map(\.name) == ["Clip.mkv", "Movie.mp4"])
    #expect(items.allSatisfy { $0.sourceID == source.id })
}

@Test func stremioMetadataClientLoadsEpisodeIdentitiesForSeriesPlayback() async throws {
    let source = AppleSource(
        kind: .stremio,
        name: "Catalog",
        url: URL(string: "https://catalog.example/config/manifest.json")!,
        resources: ["catalog", "meta"]
    )
    let client = AppleStremioMetadataClient { request in
        #expect(request.url?.absoluteString == "https://catalog.example/config/meta/series/tt1234567.json")
        let data = Data(#"""
        {"meta":{"videos":[
          {"id":"tt1234567:1:1","title":"Pilot","season":1,"episode":1},
          {"id":"tt1234567:1:2","name":"Second","season":"1","episode":"2"},
          {"id":"","title":"Bad"}
        ]}}
        """#.utf8)
        return (
            data,
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }

    let episodes = try await client.episodes(source: source, mediaID: "tt1234567")

    #expect(episodes.map(\.id) == ["tt1234567:1:1", "tt1234567:1:2"])
    #expect(episodes.map(\.displayTitle) == ["S1 E1 · Pilot", "S1 E2 · Second"])
}

@Test func stremioEpisodePolicyGroupsAndOrdersSeasonsWithoutLosingSpecials() {
    let episodes = [
        AppleStremioEpisode(id: "s2e2", title: "Second", season: 2, episode: 2),
        AppleStremioEpisode(id: "special", title: "Holiday", season: 0, episode: 1),
        AppleStremioEpisode(id: "s1e2", title: "Later", season: 1, episode: 2),
        AppleStremioEpisode(id: "s1e1", title: "Pilot", season: 1, episode: 1),
    ]

    #expect(AppleStremioEpisodePolicy.seasons(in: episodes) == [0, 1, 2])
    #expect(AppleStremioEpisodePolicy.episodes(in: 1, from: episodes).map(\.id) == ["s1e1", "s1e2"])
    #expect(AppleStremioEpisodePolicy.episodes(in: 0, from: episodes).map(\.displayTitle) == ["S0 E1 · Holiday"])
}

@Test func stremioMetadataClientFallsBackToDedicatedMetadataAddon() async throws {
    let catalog = AppleSource(
        kind: .stremio,
        name: "Catalog only",
        url: URL(string: "https://catalog.example/manifest.json")!,
        resources: ["catalog"]
    )
    let metadata = AppleSource(
        kind: .stremio,
        name: "Metadata",
        url: URL(string: "https://meta.example/manifest.json")!,
        manifestID: "com.linvo.cinemeta",
        resources: ["meta"]
    )
    let client = AppleStremioMetadataClient { request in
        #expect(request.url?.host == "meta.example")
        let data = Data(#"{"meta":{"videos":[{"id":"tt1234567:1:1","title":"Pilot","season":1,"episode":1}]}}"#.utf8)
        return (
            data,
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }

    let episodes = try await client.episodes(
        sources: [catalog, metadata],
        preferredSourceID: catalog.id,
        mediaID: "tt1234567"
    )

    #expect(episodes.map(\.id) == ["tt1234567:1:1"])
}

@MainActor
@Test func addingAnotherLiveSourceNeverReplacesAnExistingPlaylistOrAccount() throws {
    let suite = "multiple-live-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = AppleSourceStore(defaults: defaults, keychain: TestAppleCredentialStore())
    let one = try store.addIPTV(name: "First", type: .m3u, endpoint: "https://tv.example/first.m3u")
    let two = try store.addIPTV(name: "Second", type: .m3u, endpoint: "https://tv.example/second.m3u")
    #expect(one.id != two.id)
    #expect(store.sources.count == 2)
    let updated = try store.addIPTV(name: "Renamed", type: .m3u, endpoint: "https://tv.example/first.m3u")
    #expect(updated.id == one.id)
    #expect(store.sources.first { $0.id == two.id }?.name == "Second")
    let account = try store.addIPTV(name: "Account", type: .xtream, endpoint: "https://tv.example", username: "first", password: "fixture")
    let secondAccount = try store.addIPTV(name: "Account Two", type: .xtream, endpoint: "https://tv.example", username: "second", password: "fixture")
    #expect(account.id != secondAccount.id)
    #expect(store.sources.count == 4)
}
