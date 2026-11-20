import Foundation
import Synchronization
import Testing
@testable import OpenStreamApple

private func fixture(_ name: String) throws -> Data {
    try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appending(path: "Fixtures/MediaServer/\(name)"))
}

/// Media server replies decoded the way the app reads them. Each fixture's
/// `_fixture` key says whether it was recorded from a Jellyfin-compatible
/// server (ids, names, hosts and links replaced) or written by hand; entries
/// added by hand to a recorded reply carry "synthetic" in their id or name,
/// and tests that build a reply inline or from parts say so in their names.
@Suite("Media server reply contract", .timeLimit(.minutes(1)))
@MainActor
struct AppleMediaServerContractTests {
    let source = AppleSource(id: UUID(), kind: .mediaServer, name: "Fixture",
                             url: URL(string: "https://fixture.example/")!, isEnabled: true)
    var session: AppleMediaServerSession {
        AppleMediaServerSession(kind: .jellyfin, baseURL: source.url, accessToken: "tk", userID: "u")
    }

    private func store(replies: @escaping @Sendable (URLRequest) -> Data?) -> AppleMediaServerLibraryStore {
        let client = AppleMediaServerClient(loader: { request in
            let body = replies(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: body == nil ? 503 : 200, httpVersion: nil, headerFields: nil)!
            return (body ?? Data(), response)
        }, deviceID: "fixture-device")
        let defaults = UserDefaults(suiteName: "media-server-contract-\(UUID())")!
        return AppleMediaServerLibraryStore(client: client, progressDefaults: defaults)
    }

    @Test("Views skip nameless entries and recognize collection views")
    func views() throws {
        let views = try JSONDecoder().decode(AppleMediaServerItemList<AppleMediaServerLibrary>.self, from: fixture("server-views.json")).items
        #expect(views.map(\.collectionType) == [.movies, .tvshows, .collections])
        #expect(!views.contains { $0.id == "synthetic-view-without-name" })
    }

    @Test("A movie page keeps every readable item and pages past the unreadable one")
    func moviePage() throws {
        let page = try JSONDecoder().decode(AppleMediaServerItemPage.self, from: fixture("server-items-movies.json"))
        #expect(page.receivedCount == 5)
        #expect(page.totalRecordCount == 96)
        #expect(page.items.map(\.id) == ["a0000000000000000000000000000062", "a000000000000000000000000000006e",
                                     "synthetic-odd-shapes", "synthetic-collection"])

        let movie = page.items[0]
        #expect(movie.type == .movie)
        #expect(movie.year == 1999)
        #expect(movie.runtimeSeconds == 5_820)
        #expect(movie.primaryImageTag != nil && movie.logoImageTag != nil && movie.backdropImageTags.count == 1)
        #expect(movie.imdbID == "1000")
        #expect(movie.people.map(\.type) == ["Actor", "Director", "Writer"])
        #expect(movie.people.allSatisfy { $0.primaryImageTag == nil })
        #expect(movie.remoteTrailers.map(\.url) == ["https://www.youtube.com/watch?v=abcdefghijk"])
        #expect(movie.officialRating == nil)

        #expect(page.items[3].type == .other)
    }

    @Test("Synthetic entry: fields in an unexpected shape are dropped one by one, not with the item")
    func oddShapes() throws {
        let page = try JSONDecoder().decode(AppleMediaServerItemPage.self, from: fixture("server-items-movies.json"))
        let odd = try #require(page.items.first { $0.id == "synthetic-odd-shapes" })
        #expect(odd.year == 1999)
        #expect(odd.runtimeSeconds == 5_820)
        #expect(odd.genres.isEmpty)
        #expect(odd.communityRating == nil)
        #expect(odd.primaryImageTag == nil)
        #expect(odd.people.map(\.name) == ["Named Person"])
        #expect(odd.remoteTrailers.isEmpty)
        #expect(odd.userData?.playCount == 2)
        #expect(odd.userData?.played == false)
    }

    @Test("Latest is a bare array; next up may be empty")
    func latestAndNextUp() throws {
        let latest = try JSONDecoder().decode(AppleLossyArray<AppleMediaServerItem>.self, from: fixture("server-latest-shows.json")).values
        #expect(latest.map(\.type) == [.series, .series])
        let next = try JSONDecoder().decode(AppleMediaServerItemPage.self, from: fixture("server-nextup-empty.json"))
        #expect(next.items.isEmpty && next.totalRecordCount == 0)
    }

    @Test("A title's people become Cast & Crew and its YouTube links its trailers")
    func castAndTrailers() throws {
        let movie = try JSONDecoder().decode(AppleMediaServerItemPage.self, from: fixture("server-items-movies.json")).items[0]
        let library = store { _ in nil }
        let details = library.metadata(from: .init(item: movie, source: source, session: session, seasons: [], episodesBySeason: [:]))
        #expect(details.castMembers.map(\.role) == [nil, "Director", "Writer"])
        #expect(details.castMembers.allSatisfy { $0.portraitURL == nil })
        #expect(details.cast == [movie.people[0].name])
        #expect(details.director == movie.people[1].name)
        #expect(details.writers == [movie.people[2].name])
        #expect(details.trailerYouTubeKeys == ["abcdefghijk"])
    }

    @Test("A person with an image tag gets the server's portrait")
    func portrait() {
        let item = AppleMediaServerItem(id: "m", name: "M", type: .movie)
        var withPerson = item
        withPerson.people = [.init(id: "p1", name: "Actor One", type: "Actor", role: "Lead", primaryImageTag: "tag1")]
        let credits = store { _ in nil }.credits(for: withPerson, session: session)
        #expect(credits.first?.role == "Lead")
        #expect(credits.first?.portraitURL?.absoluteString == "https://fixture.example/Items/p1/Images/Primary?tag=tag1&maxWidth=400")
    }

    @Test("When the server has no local-trailers route, a remote trailer that is a video file plays through the server-trailer path")
    func remoteTrailerFile() async throws {
        let client = AppleMediaServerClient(loader: { request in
            let path = request.url!.path
            if path.hasSuffix("/LocalTrailers") {
                return (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
            }
            let body = #"""
                {"Id": "m1", "Name": "M", "Type": "Movie", "RemoteTrailers": [
                  {"Url": "https://www.youtube.com/watch?v=abcdefghijk"},
                  {"Url": "https://video.fixture.example/page/trailer"},
                  {"Url": "http://video.fixture.example/trailers/m1.mp4", "Name": "Teaser"}
                ]}
                """#
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, deviceID: "fixture-device")
        let trailer = try #require(try await client.firstTrailer(session: session, itemID: "m1"))
        #expect(trailer.url.absoluteString == "http://video.fixture.example/trailers/m1.mp4")
        #expect(trailer.title == "Teaser" && trailer.isFile)
        #expect(AppleServerTrailerStreamPolicy.remoteTrailer(.init(url: "https://cdn.fixture.example/t/master.m3u8"))?.isFile == false)
    }

    @Test("YouTube links in their usual forms give the video id")
    func youTubeKeys() {
        #expect(AppleMediaServerLibraryStore.youTubeKey("https://www.youtube.com/watch?v=abcdefghijk") == "abcdefghijk")
        #expect(AppleMediaServerLibraryStore.youTubeKey("https://youtu.be/abcdefghijk") == "abcdefghijk")
        #expect(AppleMediaServerLibraryStore.youTubeKey("https://www.youtube.com/embed/abcdefghijk") == "abcdefghijk")
        #expect(AppleMediaServerLibraryStore.youTubeKey("https://video.fixture.example/watch?v=abcdefghijk") == nil)
    }

    /// The Apple TV Top Shelf opens a title cold and plays at once, before
    /// launch has reloaded the servers.
    @Test("A title asked for before the first reload waits for its server's session")
    func detailWaitsForTheFirstReload() async throws {
        let library = store { request in
            let path = request.url!.path
            if path.hasSuffix("/Seasons") { return try? fixture("server-seasons.json") }
            if path.hasSuffix("/Episodes") { return try? fixture("server-episodes.json") }
            if path.hasSuffix("/Items/a0000000000000000000000000000002") { return try? fixture("server-series-detail.json") }
            if path.hasSuffix("/Views") || path.hasSuffix("/Resume") { return Data(#"{"Items":[]}"#.utf8) }
            return nil
        }
        let source = source
        let session = session
        let early = Task { @MainActor in
            try await library.detail(for: .init(sourceID: source.id, itemID: "a0000000000000000000000000000002"))
        }
        await Task.yield()
        await library.reload(sources: [source]) { _ in session }
        #expect(try await early.value.item.type == .series)
    }

    @Test("A cancelled wait for the first reload ends at once")
    func cancelledSessionWaitEnds() async {
        let library = store { _ in nil }
        let waiter = Task { @MainActor in await library.firstSessions(waitLimit: .seconds(60)) }
        await Task.yield()
        let started = ContinuousClock.now
        waiter.cancel()
        await waiter.value
        #expect(started.duration(to: .now) < .seconds(5))
    }

    @Test("Each wait for the first reload runs to its own deadline")
    func laterSessionWaitKeepsItsOwnDeadline() async {
        let library = store { _ in Data(#"{"Items":[]}"#.utf8) }
        let early = Task { @MainActor in await library.firstSessions(waitLimit: .milliseconds(200)) }
        await Task.yield()
        let late = Task { @MainActor in
            await library.firstSessions(waitLimit: .seconds(60))
            return ContinuousClock.now
        }
        await early.value
        let reloadAt = ContinuousClock.now + .milliseconds(400)
        try? await Task.sleep(until: reloadAt)
        let source = source
        let session = session
        await library.reload(sources: [source]) { _ in session }
        #expect(await late.value >= reloadAt, "the first waiter's deadline released the second")
    }

    @Test("A series loads its seasons and episodes in order, with episode art")
    func seriesInOrder() async throws {
        let library = store { request in
            let path = request.url!.path
            if path.hasSuffix("/Seasons") { return try? fixture("server-seasons.json") }
            if path.hasSuffix("/Episodes") { return try? fixture("server-episodes.json") }
            if path.hasSuffix("/Items/a0000000000000000000000000000002") { return try? fixture("server-series-detail.json") }
            if path.hasSuffix("/Views") || path.hasSuffix("/Resume") { return Data(#"{"Items":[]}"#.utf8) }
            return nil
        }
        await library.reload(sources: [source]) { _ in session }
        let detail = try await library.detail(for: .init(sourceID: source.id, itemID: "a0000000000000000000000000000002"))
        #expect(detail.item.type == .series)
        #expect(detail.seasons.map(\.indexNumber) == [1])
        let episodes = library.episodes(from: detail)
        #expect(episodes.map(\.episode) == [1, 2, 3])
        #expect(episodes.allSatisfy { $0.thumbnailURL != nil })

        let episode = try #require(detail.episodesBySeason.values.first?.first)
        #expect(episode.communityRating == nil)
        #expect(episode.seriesPrimaryImageTag != nil && episode.parentBackdropItemID != nil)
    }

    @Test("An episode with no art of its own shows its series' poster and backdrop")
    func episodeArtFallback() {
        var episode = AppleMediaServerItem(id: "e1", name: "E", type: .episode, seriesID: "s1")
        episode.seriesPrimaryImageTag = "poster"
        episode.parentBackdropItemID = "s1"
        episode.parentBackdropImageTags = ["backdrop"]
        let item = store { _ in nil }.catalogItem(episode, source: source, session: session)
        #expect(item.posterURL?.absoluteString.contains("/Items/s1/Images/Primary?tag=poster") == true)
        #expect(item.backgroundURL?.absoluteString.contains("/Items/s1/Images/Backdrop?tag=backdrop") == true)
    }

    @Test("Specials come after the numbered seasons; unnumbered ones last")
    func specialsAfterSeasons() {
        func season(_ id: String, _ number: Int?) -> AppleMediaServerItem {
            AppleMediaServerItem(id: id, name: id, type: .season, indexNumber: number)
        }
        let ordered = AppleMediaServerItem.inIndexOrder([season("x", nil), season("s0", 0), season("s2", 2), season("s1", 1)])
        #expect(ordered.map(\.id) == ["s1", "s2", "s0", "x"])
        let specials = AppleMediaServerItem(id: "e", name: "E", type: .episode, indexNumber: 1, parentIndexNumber: 0)
        let first = AppleMediaServerItem(id: "f", name: "F", type: .episode, indexNumber: 5, parentIndexNumber: 1)
        #expect(AppleMediaServerItem.inIndexOrder([specials, first]).map(\.id) == ["f", "e"])
    }

    @Test("Synthetic replies: an item without a name is called by its number if it is a season or episode, else left out")
    func nameless() async throws {
        let page = try JSONDecoder().decode(AppleMediaServerItemPage.self, from: Data(#"""
            {"Items": [
              {"Id": "e1", "Type": "Episode", "Name": " ", "IndexNumber": 4},
              {"Id": "s0", "Type": "Season", "IndexNumber": 0},
              {"Id": "m1", "Type": "Movie", "Name": ""}
            ], "TotalRecordCount": 3}
            """#.utf8))
        #expect(page.items.map(\.name) == ["Episode 4", "Specials", ""])

        let library = store { request in
            let path = request.url!.path
            if path.hasSuffix("/Items/Latest") { return Data(#"[{"Id": "m1", "Type": "Movie", "Name": ""}, {"Id": "m2", "Type": "Movie", "Name": "Named"}]"#.utf8) }
            if path.hasSuffix("/Items/Resume") { return Data(#"{"Items": [{"Id": "r1", "Type": "Movie"}, {"Id": "r2", "Type": "Movie", "Name": "Resumed"}]}"#.utf8) }
            if path.hasSuffix("/Shows/NextUp") || path.hasSuffix("/Items") {
                return Data(#"{"Items": [{"Id": "n1", "Type": "Episode", "Name": ""}, {"Id": "x1", "Type": "Movie", "Name": " "}], "TotalRecordCount": 2}"#.utf8)
            }
            if path.hasSuffix("/Views") {
                return Data(#"{"Items": [{"Id": "v1", "Name": "Movies", "CollectionType": "movies"}, {"Id": "v2", "Name": "Shows", "CollectionType": "tvshows"}]}"#.utf8)
            }
            return Data(#"{"Items":[]}"#.utf8)
        }
        await library.reload(sources: [source]) { _ in session }
        let latest = try #require(library.shelves.first { $0.title == "Latest in Movies" })
        #expect(latest.items.map(\.name) == ["Named"])
        #expect(library.continueWatching.map(\.name) == ["Resumed"])
        #expect(library.shelves.allSatisfy { shelf in shelf.items.allSatisfy { !$0.name.isEmpty } })
    }

    @Test("Synthetic reply: no sources and NoCompatibleStream give a clear failure")
    func noStream() async throws {
        let info = try JSONDecoder().decode(AppleMediaServerPlaybackInfo.self, from: fixture("server-playbackinfo-no-stream.json"))
        #expect(info.saysNoCompatibleStream)
        #expect(info.mediaSources.isEmpty)

        let movie = try JSONDecoder().decode(AppleMediaServerItemPage.self, from: fixture("server-items-movies.json")).items[0]
        let library = store { request in
            if request.url!.path.hasSuffix("/PlaybackInfo") { return try? fixture("server-playbackinfo-no-stream.json") }
            if request.url!.path.hasSuffix("/Views") || request.url!.path.hasSuffix("/Resume") { return Data(#"{"Items":[]}"#.utf8) }
            return nil
        }
        await library.reload(sources: [source]) { _ in session }
        let detail = AppleMediaServerLibraryStore.AppleMediaServerDetail(item: movie, source: source, session: session, seasons: [], episodesBySeason: [:])
        await #expect(throws: AppleMediaServerLibraryStore.noStreamFailure) {
            _ = try await library.playbackRequest(for: movie, in: detail, resume: false)
        }
    }

    @Test("Synthetic reply: of several versions the unreadable one is left out, server order plays first, the placeholder last")
    func versions() throws {
        let info = try JSONDecoder().decode(AppleMediaServerPlaybackInfo.self, from: fixture("server-playbackinfo-versions.json"))
        #expect(info.mediaSources.map(\.id) == ["source-remote-1080", "source-file-2160", "source-placeholder"])
        #expect(AppleJellyfinPlaybackPolicy.select(info.mediaSources, failed: [])?.id == "source-remote-1080")
        #expect(AppleJellyfinPlaybackPolicy.select(info.mediaSources, failed: ["source-file-2160"])?.id == "source-remote-1080")
        #expect(AppleJellyfinPlaybackPolicy.select(info.mediaSources, failed: ["source-file-2160", "source-remote-1080"])?.id == "source-placeholder")

        let remote = info.mediaSources[0]
        #expect(remote.remoteURL?.absoluteString == "https://media.fixture.example/library/item-1/1080p.mp4")
        #expect(remote.requiredHTTPHeaders == ["Referer": "https://media.fixture.example/", "User-Agent": "FixturePlayer/1.0"])
        #expect(info.mediaSources[1].remoteURL == nil)
        #expect(info.mediaSources[2].isPlaceholder && info.mediaSources[2].remoteURL == nil)
    }

    /// The recorded item page's own MediaSources (a placeholder with a
    /// relative http path) wrapped by hand as a PlaybackInfo reply.
    private func recordedPlaceholderReply(errorCode: String?) throws -> Data {
        let page = try JSONSerialization.jsonObject(with: fixture("server-items-movies.json")) as! [String: Any]
        let item = (page["Items"] as! [[String: Any]])[0]
        var reply: [String: Any] = ["MediaSources": item["MediaSources"]!, "PlaySessionId": "play-session-2"]
        reply["ErrorCode"] = errorCode
        return try JSONSerialization.data(withJSONObject: reply)
    }

    @Test("Recorded sources in a synthetic reply: a placeholder plays through the server's stream with the token; NoCompatibleStream shows only once it failed")
    func placeholderPlays() async throws {
        let movie = try JSONDecoder().decode(AppleMediaServerItemPage.self, from: fixture("server-items-movies.json")).items[0]
        for errorCode in ["NoCompatibleStream", nil] {
            let reply = try recordedPlaceholderReply(errorCode: errorCode)
            let library = store { request in
                if request.url!.path.hasSuffix("/PlaybackInfo") { return reply }
                if request.url!.path.hasSuffix("/Views") || request.url!.path.hasSuffix("/Resume") { return Data(#"{"Items":[]}"#.utf8) }
                return nil
            }
            await library.reload(sources: [source]) { _ in session }
            let detail = AppleMediaServerLibraryStore.AppleMediaServerDetail(item: movie, source: source, session: session, seasons: [], episodesBySeason: [:])
            let sourceID = "a0000000000000000000000000000062"

            let first = try await library.playbackRequest(for: movie, in: detail, resume: false)
            #expect(first.hints.versionID == sourceID)
            #expect(first.url.host == "fixture.example")
            #expect(first.url.path == "/Videos/\(movie.id)/stream.mp4")
            let query = URLComponents(url: first.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            #expect(query.contains(URLQueryItem(name: "mediaSourceId", value: sourceID)))
            #expect(query.contains(URLQueryItem(name: "api_key", value: "tk")))
            #expect(first.headers.isEmpty)
            #expect(try await library.mediaVersions(for: movie, in: detail).map(\.id) == [sourceID])

            // Its retry has no conversion and nothing else is left.
            let retry = { try await library.playbackRequest(for: movie, in: detail, resume: false, versionID: sourceID, afterFailure: true) }
            let afterAll = { try await library.playbackRequest(for: movie, in: detail, resume: false, failedVersions: [sourceID]) }
            if errorCode == nil {
                await #expect(throws: AppleMediaServerError.unsupported) { _ = try await retry() }
                await #expect(throws: AppleMediaServerError.unsupported) { _ = try await afterAll() }
            } else {
                await #expect(throws: AppleMediaServerLibraryStore.noStreamFailure) { _ = try await retry() }
                await #expect(throws: AppleMediaServerLibraryStore.noStreamFailure) { _ = try await afterAll() }
            }
        }
    }

    @Test("A MediaSources value in an unexpected shape costs only the sources")
    func oddMediaSources() throws {
        let info = try JSONDecoder().decode(AppleMediaServerPlaybackInfo.self,
            from: Data(#"{"MediaSources": {"Id": "x"}, "PlaySessionId": "p", "ErrorCode": "NoCompatibleStream"}"#.utf8))
        #expect(info.mediaSources.isEmpty)
        #expect(info.playSessionID == "p")
        #expect(info.saysNoCompatibleStream)
    }

    @Test("Synthetic reply: external subtitles on the server's own path get the token, another host's do not")
    func externalSubtitles() throws {
        let info = try JSONDecoder().decode(AppleMediaServerPlaybackInfo.self, from: fixture("server-playbackinfo-versions.json"))
        let tracks = AppleJellyfinPlaybackPolicy.externalSubtitles(info.mediaSources[0], session: session)
        #expect(tracks.map(\.url.absoluteString) == [
            "https://fixture.example/Videos/item-1/source-remote-1080/Subtitles/2/0/Stream.srt?api_key=tk",
            "https://subs.fixture.example/item-1/fr.vtt",
        ])
        #expect(tracks.map(\.languageCode) == ["eng", "fre"])
        #expect(tracks[1].displayName.contains("Signs Forced"))
        #expect(AppleJellyfinPlaybackPolicy.externalSubtitles(info.mediaSources[1], session: session).isEmpty)
    }

    @Test("Synthetic reply: a version on another host plays from there with its headers; after a failure, through the server")
    func remoteVersionPlays() async throws {
        let movie = AppleMediaServerItem(id: "item-1", name: "Movie One", type: .movie)
        let library = store { request in
            if request.url!.path.hasSuffix("/PlaybackInfo") { return try? fixture("server-playbackinfo-versions.json") }
            if request.url!.path.hasSuffix("/Views") || request.url!.path.hasSuffix("/Resume") { return Data(#"{"Items":[]}"#.utf8) }
            return nil
        }
        await library.reload(sources: [source]) { _ in session }
        let detail = AppleMediaServerLibraryStore.AppleMediaServerDetail(item: movie, source: source, session: session, seasons: [], episodesBySeason: [:])

        let direct = try await library.playbackRequest(for: movie, in: detail, resume: false, versionID: "source-remote-1080")
        #expect(direct.url.absoluteString == "https://media.fixture.example/library/item-1/1080p.mp4")
        #expect(direct.headers == ["Referer": "https://media.fixture.example/", "User-Agent": "FixturePlayer/1.0"])
        #expect(direct.hints.versionID == "source-remote-1080")
        #expect(direct.hints.externalSubtitles.count == 2)

        let retried = try await library.playbackRequest(for: movie, in: detail, resume: false, versionID: "source-remote-1080", afterFailure: true)
        #expect(retried.url.host == "fixture.example")
        #expect(retried.url.path == "/Videos/item-1/stream.mp4")

        let versions = try await library.mediaVersions(for: movie, in: detail)
        #expect(Set(versions.map(\.id)) == ["source-remote-1080", "source-file-2160", "source-placeholder"])
    }

    @Test("One library the server cannot answer for does not hide the others")
    func libraryFailureIsLocal() async {
        let library = store { request in
            let url = request.url!.absoluteString
            if url.contains("/Views") { return try? fixture("server-views.json") }
            // The TV library fails; the movie library answers with one movie.
            if url.contains("/Items/Latest"), url.contains("ParentId=a0000000000000000000000000000005") { return nil }
            if url.contains("/Items/Latest") { return Data(#"[{"Id": "m1", "Name": "Movie", "Type": "Movie"}]"#.utf8) }
            if url.contains("/Resume") || url.contains("NextUp") || url.contains("/Items?") { return Data(#"{"Items":[]}"#.utf8) }
            return nil
        }
        await library.reload(sources: [source]) { _ in session }
        #expect(library.failures[source.id] == nil)
        #expect(library.shelves.contains { $0.title.hasPrefix("Latest in ") && $0.items.map(\.name) == ["Movie"] })
    }

    @Test("Synthetic reply: links and headers never reach the encoded PlaybackInfo")
    func encodedPlaybackInfoHasNoCredentials() throws {
        var info = try JSONDecoder().decode(AppleMediaServerPlaybackInfo.self, from: fixture("server-playbackinfo-versions.json"))
        let extra = try JSONDecoder().decode(AppleMediaServerPlaybackInfo.MediaSource.self, from: Data(#"""
            {"Id": "with-secrets", "Protocol": "Http", "IsRemote": true,
             "Path": "https://media.fixture.example/item?token=secret-path",
             "TranscodingUrl": "/Videos/item-1/master.m3u8?api_key=secret-transcode",
             "DirectStreamUrl": "/Videos/item-1/stream?api_key=secret-direct",
             "RequiredHttpHeaders": {"Authorization": "Bearer secret-header", "Cookie": "session=secret-cookie"}}
            """#.utf8))
        info = AppleMediaServerPlaybackInfo(playSessionID: info.playSessionID, mediaSources: info.mediaSources + [extra])
        let encoded = try #require(String(data: JSONEncoder().encode(info), encoding: .utf8))
        for secret in ["secret-header", "secret-cookie", "secret-path", "secret-transcode", "secret-direct", "api_key",
                       "RequiredHttpHeaders", "DeliveryUrl", "Referer", "FixturePlayer", "fixture.example"] {
            #expect(!encoded.contains(secret), "\(secret) in the encoded form")
        }
        let decoded = try JSONDecoder().decode(AppleMediaServerPlaybackInfo.self, from: Data(encoded.utf8))
        #expect(decoded.mediaSources.map(\.id) == info.mediaSources.map(\.id))
        #expect(decoded.mediaSources[0].descriptors == info.mediaSources[0].descriptors)
    }

    @Test("The token goes only to a link with the session's scheme, host and port")
    func tokenOnlyForSameOrigin() throws {
        func subtitleURL(_ delivery: String, base: String = "https://fixture.example/") throws -> URL {
            let reply = #"{"MediaSources": [{"Id": "s", "MediaStreams": [{"Type": "Subtitle", "Index": 3, "IsExternal": true, "DeliveryUrl": "\#(delivery)"}]}]}"#
            let info = try JSONDecoder().decode(AppleMediaServerPlaybackInfo.self, from: Data(reply.utf8))
            let session = AppleMediaServerSession(kind: .jellyfin, baseURL: URL(string: base)!, accessToken: "tk", userID: "u")
            return try #require(AppleJellyfinPlaybackPolicy.externalSubtitles(info.mediaSources[0], session: session).first?.url)
        }
        #expect(try subtitleURL("/Videos/s/Subtitles/3/Stream.srt").query == "api_key=tk")
        #expect(try subtitleURL("https://fixture.example:443/Videos/s/Subtitles/3/Stream.srt").query == "api_key=tk")
        #expect(try subtitleURL("http://fixture.example/Videos/s/Subtitles/3/Stream.srt").query == nil)
        #expect(try subtitleURL("https://fixture.example:8920/Videos/s/Subtitles/3/Stream.srt").query == nil)
        #expect(try subtitleURL("https://other.fixture.example/s.srt").query == nil)
        #expect(try subtitleURL("http://fixture.example:8096/s.srt", base: "http://fixture.example:8096/").query == "api_key=tk")
    }

    @Test("Synthetic reply: through the player's own fallback, a failed real source moves on to the next and the placeholder plays last")
    func failedSourceFallsBackThroughTheCoordinator() async throws {
        let movie = AppleMediaServerItem(id: "item-1", name: "Movie One", type: .movie)
        let library = store { request in
            if request.url!.path.hasSuffix("/PlaybackInfo") { return try? fixture("server-playbackinfo-versions.json") }
            if request.url!.path.hasSuffix("/Views") || request.url!.path.hasSuffix("/Resume") { return Data(#"{"Items":[]}"#.utf8) }
            return nil
        }
        await library.reload(sources: [source]) { _ in session }
        let detail = AppleMediaServerLibraryStore.AppleMediaServerDetail(item: movie, source: source, session: session, seasons: [], episodesBySeason: [:])
        let candidates = try await library.playbackCandidates(for: movie, in: detail, resume: false)
        #expect(candidates.map(\.hints.versionID) == ["source-remote-1080", "source-file-2160", "source-placeholder"])
        #expect(candidates[0].headers == ["Referer": "https://media.fixture.example/", "User-Agent": "FixturePlayer/1.0"])
        #expect(candidates[2].headers.isEmpty && candidates[2].url.host == "fixture.example")

        // A version already failed is not handed out again; after a failure only that one is retried.
        let rest = try await library.playbackCandidates(for: movie, in: detail, resume: false, failedVersions: ["source-file-2160"])
        #expect(rest.map(\.hints.versionID) == ["source-remote-1080", "source-placeholder"])
        let retry = try await library.playbackCandidates(for: movie, in: detail, resume: false, versionID: "source-remote-1080", afterFailure: true)
        #expect(retry.count == 1)

        let engine = FakePlaybackEngine()
        engine.loadHandler = { request in
            guard request.hints.versionID == "source-placeholder" else {
                throw ApplePlaybackFailure(kind: .network, message: "Fixture source offline")
            }
            engine.phase = .playing
        }
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        await coordinator.begin(candidates[0], fallbackCandidates: Array(candidates.dropFirst()))
        var tried: [String] = []
        for version in engine.loadedRequests.compactMap(\.hints.versionID) where tried.last != version { tried.append(version) }
        #expect(tried == ["source-remote-1080", "source-file-2160", "source-placeholder"])
        #expect(coordinator.phase == .playing)
        coordinator.stop()
    }

    @Test("Automatic playback uses the server default; an explicit version is sent for preparation")
    func defaultAndManualVersions() async throws {
        let movie = AppleMediaServerItem(id: "item-1", name: "Movie One", type: .movie)
        let library = store { request in
            if request.url!.path.hasSuffix("/PlaybackInfo") {
                let body = try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
                let sourceID = body?["MediaSourceId"] as? String
                let queryID = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "MediaSourceId" }?.value
                #expect(sourceID == queryID)
                #expect(sourceID == nil || sourceID == "manual")
                return Data(#"{"DefaultMediaSourceId":"prepared","MediaSources":[{"Id":"manual","Container":"mp4","SupportsDirectPlay":true},{"Id":"prepared","Container":"mp4","SupportsDirectPlay":true}]}"#.utf8)
            }
            if request.url!.path.hasSuffix("/Views") || request.url!.path.hasSuffix("/Resume") { return Data(#"{"Items":[]}"#.utf8) }
            return nil
        }
        await library.reload(sources: [source]) { _ in session }
        let detail = AppleMediaServerLibraryStore.AppleMediaServerDetail(item: movie, source: source, session: session, seasons: [], episodesBySeason: [:])
        let automatic = try await library.playbackRequest(for: movie, in: detail, resume: false)
        #expect(automatic.hints.versionID == "prepared")
        let manual = try await library.playbackRequest(for: movie, in: detail, resume: false, versionID: "manual")
        #expect(manual.hints.versionID == "manual")
    }

    @Test("Opening a version menu prepares one response that the next Play consumes")
    func versionsAndPlaybackShareThePreparedResponse() async throws {
        let count = Mutex(0)
        let movie = AppleMediaServerItem(id: "item-1", name: "Movie One", type: .movie)
        let library = store { request in
            if request.url!.path.hasSuffix("/PlaybackInfo") {
                count.withLock { $0 += 1 }
                return try? fixture("server-playbackinfo-versions.json")
            }
            if request.url!.path.hasSuffix("/Views") || request.url!.path.hasSuffix("/Resume") { return Data(#"{"Items":[]}"#.utf8) }
            return nil
        }
        await library.reload(sources: [source]) { _ in session }
        let detail = AppleMediaServerLibraryStore.AppleMediaServerDetail(item: movie, source: source, session: session, seasons: [], episodesBySeason: [:])
        #expect(try await library.mediaVersions(for: movie, in: detail).count == 3)
        #expect(try await library.playbackRequest(for: movie, in: detail, resume: false).hints.versionID == "source-remote-1080")
        #expect(count.withLock { $0 } == 1)
        _ = try await library.playbackRequest(for: movie, in: detail, resume: false, versionID: "source-file-2160")
        #expect(count.withLock { $0 } == 2)
    }

    @Test("A series has no file versions until an episode is selected")
    func seriesDoesNotPreparePlaybackInfo() async throws {
        let series = AppleMediaServerItem(id: "show", name: "Fixture Series", type: .series)
        let count = Mutex(0)
        let library = store { request in
            if request.url?.path.hasSuffix("/PlaybackInfo") == true { count.withLock { $0 += 1 } }
            return try? fixture("server-playbackinfo-versions.json")
        }
        let detail = AppleMediaServerLibraryStore.AppleMediaServerDetail(item: series, source: source, session: session, seasons: [], episodesBySeason: [:])
        #expect(try await library.mediaVersions(for: series, in: detail).isEmpty)
        #expect(count.withLock { $0 } == 0)
    }

    @Test("Concurrent preparation shares transport and cancelling one waiter preserves the other")
    func concurrentPlaybackInfoSharesOneRequest() async throws {
        let count = Mutex(0)
        let release = AsyncStream<Void>.makeStream()
        defer { release.continuation.finish() }
        let client = AppleMediaServerClient(loader: { request in
            count.withLock { $0 += 1 }
            for await _ in release.stream { }
            return (try fixture("server-playbackinfo-versions.json"),
                try #require(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }, deviceID: "fixture")
        let activeSession = session
        let first = Task { try await client.playbackInfo(session: activeSession, itemID: "movie") }
        let second = Task { try await client.playbackInfo(session: activeSession, itemID: "movie") }
        defer { first.cancel(); second.cancel() }
        while await client.playbackInfoLookups.activeWaiterCount < 2 {
            try Task.checkCancellation()
            await Task.yield()
        }
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        release.continuation.finish()
        #expect(try await second.value.mediaSources.count == 3)
        #expect(count.withLock { $0 } == 1)
    }

    @Test("Someone listed in several roles appears once in Cast & Crew")
    func rolesMerged() {
        var item = AppleMediaServerItem(id: "m", name: "M", type: .movie)
        item.people = [
            .init(id: "p1", name: "Person One", type: "Actor", role: "Lead"),
            .init(id: "p2", name: "Person Two", type: "Director"),
            .init(id: "p1", name: "Person One", type: "Director"),
            .init(id: "p2", name: "Person Two", type: "Writer"),
            .init(name: "Person Three", type: "Actor"),
            .init(name: "Person Three", type: "Actor"),
        ]
        let credits = store { _ in nil }.credits(for: item, session: session)
        #expect(credits.map(\.name) == ["Person One", "Person Three", "Person Two"])
        #expect(credits.map(\.role) == ["Lead, Director", nil, "Director, Writer"])
        #expect(Set(credits.map(\.id)).count == credits.count)
    }
}
