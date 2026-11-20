import Foundation
import Testing
@testable import OpenStreamApple

struct AppleEpisodeMetadataTests {
    @Test func seasonEndpointProvidesTitlesAndDistinctStillsAndPersistsThem() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let requests = EpisodeRequests()
        let client = AppleTMDBClient { request in
            let url = try #require(request.url)
            await requests.append(url.path)
            let body = url.path == "/3/find/tt1234567"
                ? #"{"movie_results":[],"tv_results":[{"id":42}]}"#
                : #"{"episodes":[{"season_number":6,"episode_number":1,"name":"First &amp; Last","overview":"A first day.","air_date":"2026-10-01","runtime":22,"still_path":"/first.jpg"},{"season_number":6,"episode_number":2,"name":"Second Day","still_path":"/second.jpg"},{"season_number":5,"episode_number":1,"name":"Wrong season"},{"season_number":6,"episode_number":0,"name":"Invalid episode"}]}"#
            return (Data(body.utf8), try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
        let configuration = try AppleTMDBConfiguration(credential: "fixture-key")
        let episodes = try await client.seasonEpisodes(mediaID: "tt1234567", season: 6,
            configuration: configuration, cache: AppleMetadataDiskCache(directory: directory))
        #expect(episodes.map(\.id) == ["tt1234567:6:1", "tt1234567:6:2"])
        #expect(episodes.map(\.title) == ["First & Last", "Second Day"])
        #expect(episodes.map(\.thumbnailURL) == [URL(string: "https://image.tmdb.org/t/p/w780/first.jpg"),
            URL(string: "https://image.tmdb.org/t/p/w780/second.jpg")])
        #expect(episodes[0].runtimeMinutes == 22)
        #expect(episodes[0].overview == "A first day.")
        #expect(episodes[0].releaseInfo == "2026-10-01")
        #expect(await requests.paths == ["/3/find/tt1234567", "/3/tv/42/season/6"])
        let offline = AppleTMDBClient { _ in throw URLError(.notConnectedToInternet) }
        let restored = try await offline.seasonEpisodes(mediaID: "tt1234567", season: 6,
            configuration: configuration, cache: AppleMetadataDiskCache(directory: directory))
        #expect(restored == episodes)
        await #expect(throws: URLError.self) {
            try await offline.seasonEpisodes(mediaID: "tt1234567", season: 5,
                configuration: configuration, cache: AppleMetadataDiskCache(directory: directory))
        }
        await #expect(throws: URLError.self) {
            try await offline.seasonEpisodes(mediaID: "tt1234567", season: 6,
                configuration: AppleTMDBConfiguration(credential: "different-fixture-key"),
                cache: AppleMetadataDiskCache(directory: directory))
        }
    }

    @Test func seasonEndpointAcceptsTMDBMatchesAndMissingEpisodeFields() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = AppleTMDBClient { request in
            let url = try #require(request.url)
            #expect(url.path == "/3/tv/42/season/0")
            let body = #"{"episodes":[{"season_number":0,"episode_number":1,"name":null,"still_path":null},{"season_number":0,"episode_number":2,"name":"  ","still_path":"https://fixture.example/unsafe.jpg"}]}"#
            return (Data(body.utf8), try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
        let configuration = try AppleTMDBConfiguration(credential: "fixture-key")
        let episodes = try await client.seasonEpisodes(mediaID: "tmdb:tv:42", season: 0,
            configuration: configuration, cache: AppleMetadataDiskCache(directory: directory))
        #expect(episodes.count == 2)
        #expect(episodes.allSatisfy { $0.title.isEmpty && $0.thumbnailURL == nil })
        for id in ["local-unmatched", "tmdb:movie:42", "tmdb:tv:-1", "tt1234567:6:1"] {
            await #expect(throws: AppleTMDBError.invalidIdentifier) {
                try await client.seasonEpisodes(mediaID: id, season: 6, configuration: configuration)
            }
        }
        await #expect(throws: AppleTMDBError.invalidIdentifier) {
            try await client.seasonEpisodes(mediaID: "tt1234567", season: -1, configuration: configuration)
        }
    }

    @Test @MainActor func localEpisodesPreferProviderFieldsAndKeepFileFallbacksAndIdentity() throws {
        let parsed = AppleLibraryTitleParser.parse(name: "Abbott.Elementary.S06E01.Parsed.Filename.mp4",
            parentPath: "Abbott Elementary {imdb-tt14218830}/Season 6")
        #expect(parsed.kind == .show)
        #expect(parsed.explicitIDs["imdb"] == "tt14218830")
        let source = UUID()
        let names = ["Example.S06E01.Parsed.Name.mkv", "Example.S06E02.Other.Name.mkv", "Example.S05E01.Older.mkv"]
        let files = names.map { name in
            AppleLibraryItem(sourceID: source, name: name, url: URL(fileURLWithPath: "/" + name),
                relativePath: "Shows/Example/" + name, sizeBytes: 1)
        }
        let group = try #require(AppleLibrarySeries.groups(files).first)
        let still = URL(string: "https://fixture.example/first.jpg")
        let metadata = [AppleMediaEpisode(id: "tt1234567:6:1", title: "Provider Title", season: 6, episode: 1,
            releaseInfo: "2026-10-01", runtimeMinutes: 22, overview: "Provider summary", thumbnailURL: still),
            AppleMediaEpisode(id: "tt1234567:6:2", title: "", season: 6, episode: 2,
                releaseInfo: "2026-10-08", runtimeMinutes: 23, overview: "Second summary", thumbnailURL: still),
            AppleMediaEpisode(id: "tt1234567:6:3", title: "Not owned", season: 6, episode: 3)]
        let rows = AppleLocalLibraryStore.episodes(group: group, mediaID: "tt1234567", enriched: metadata)
        #expect(rows.count == 3)
        let first = try #require(rows.first { $0.season == 6 && $0.episode == 1 })
        #expect(first == metadata[0])
        #expect(first.title == "Provider Title")
        #expect(first.thumbnailURL == still)
        #expect(first.overview == "Provider summary")
        let second = try #require(rows.first { $0.season == 6 && $0.episode == 2 })
        #expect(second.title == "Other Name")
        #expect(second.thumbnailURL == still)
        #expect(second.releaseInfo == metadata[1].releaseInfo)
        #expect(second.runtimeMinutes == metadata[1].runtimeMinutes)
        #expect(second.overview == metadata[1].overview)
        #expect(rows.first { $0.season == 5 }?.title == "Older")
        #expect(AppleLocalLibraryStore.matchesEpisode(files[0], episode: first))
        #expect(!rows.contains { $0.episode == 3 })
    }

    @Test(arguments: [("Show.S01E02.1080p.WEB.h264-GROUP.mkv", "Episode 2"),
                      ("Show.S01E02.AMZN.WEB-DL.DDP5.1.H.264-GRP.mkv", "Episode 2"),
                      ("Show.S01E02.720p.BluRay.x264-GRP.mkv", "Episode 2"),
                      ("Show.S01E02.BluRay.x264-GRP.mkv", "Episode 2"),
                      ("Show.S01E02.WEB.h264-GROUP.mkv", "Episode 2"), ("Show.S01E02.mkv", "Episode 2"),
                      ("Show.S01E02.Web.of.Lies.mkv", "Web of Lies")])
    func episodeTitlesKeepNamesAndRejectReleaseTags(name: String, expected: String) {
        #expect(AppleLibraryTitleParser.episodeTitle(name: name, number: 2) == expected)
    }

    @Test @MainActor func providerMetadataSurvivesAFileListThatArrivesLater() throws {
        let file = AppleLibraryItem(sourceID: UUID(), name: "Show.S06E01.Parsed.Name.mkv",
            url: URL(fileURLWithPath: "/Show.S06E01.Parsed.Name.mkv"),
            relativePath: "Shows/Show/Show.S06E01.Parsed.Name.mkv", sizeBytes: 1)
        let group = try #require(AppleLibrarySeries.groups([file]).first)
        let provider = AppleMediaEpisode(id: "tt1234567:6:1", title: "First &amp; Last", season: 6, episode: 1,
            releaseInfo: "2026-10-01", runtimeMinutes: 22, overview: "Provider summary",
            thumbnailURL: URL(string: "https://fixture.example/first.jpg"))
        var state = AppleTitlePageEpisodeState()
        state.applyProviderEpisodes([provider], season: 6, group: group, mediaID: "tt1234567")
        state.applyEpisodes([], localGroup: group, mediaID: "tt1234567")
        #expect(state.episodes == [provider])
        state.applyEpisodes([AppleMediaEpisode(id: provider.id, title: "Parsed Name", season: 6, episode: 1)],
            localGroup: group, mediaID: "tt1234567")
        #expect(state.episodes == [provider])
    }

    @Test(arguments: [true, false]) @MainActor
    func partialProviderMetadataUsesEachFetchedField(providerFirst: Bool) throws {
        let file = AppleLibraryItem(sourceID: UUID(), name: "Show.S06E01.Parsed.Name.mkv",
            url: URL(fileURLWithPath: "/Show.S06E01.Parsed.Name.mkv"),
            relativePath: "Shows/Show/Show.S06E01.Parsed.Name.mkv", sizeBytes: 1)
        let group = try #require(AppleLibrarySeries.groups([file]).first)
        let fetched = AppleMediaEpisode(id: "tt1234567:6:1", title: "First &amp; Last", season: 6, episode: 1,
            releaseInfo: "2026-10-01", runtimeMinutes: 22, overview: "Fetched &amp; complete",
            thumbnailURL: URL(string: "https://fixture.example/first.jpg"))
        let provider = AppleMediaEpisode(id: fetched.id, title: "  ", season: 6, episode: 1,
            releaseInfo: " ", runtimeMinutes: 23, overview: "Provider &amp; summary")
        var state = AppleTitlePageEpisodeState()
        if providerFirst {
            state.applyProviderEpisodes([provider], season: 6, group: group, mediaID: "tt1234567")
            state.applyEpisodes([fetched], localGroup: group, mediaID: "tt1234567")
        } else {
            state.applyEpisodes([fetched], localGroup: group, mediaID: "tt1234567")
            state.applyProviderEpisodes([provider], season: 6, group: group, mediaID: "tt1234567")
        }
        #expect(state.episodes == [AppleMediaEpisode(id: fetched.id, title: "First & Last", season: 6, episode: 1,
            releaseInfo: fetched.releaseInfo, runtimeMinutes: 23, overview: "Provider & summary",
            thumbnailURL: fetched.thumbnailURL)])
        let titleOnly = AppleMediaEpisode(id: fetched.id, title: "Provider Title", season: 6, episode: 1)
        state.applyProviderEpisodes([titleOnly], season: 6, group: group, mediaID: "tt1234567")
        #expect(state.episodes == [AppleMediaEpisode(id: fetched.id, title: titleOnly.title, season: 6, episode: 1,
            releaseInfo: fetched.releaseInfo, runtimeMinutes: fetched.runtimeMinutes, overview: fetched.overview,
            thumbnailURL: fetched.thumbnailURL)])
    }

    @Test func anEmptySeasonIsRetriedRatherThanCachedAsFresh() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = AppleMetadataDiskCache(directory: directory)
        let configuration = try AppleTMDBConfiguration(credential: "fixture-key")
        let empty = AppleTMDBClient { request in
            let url = try #require(request.url)
            return (Data(#"{"episodes":[]}"#.utf8),
                try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
        #expect(try await empty.seasonEpisodes(mediaID: "tmdb:tv:42", season: 6,
            configuration: configuration, cache: cache).isEmpty)
        let offline = AppleTMDBClient { _ in throw URLError(.notConnectedToInternet) }
        await #expect(throws: URLError.self) {
            try await offline.seasonEpisodes(mediaID: "tmdb:tv:42", season: 6, configuration: configuration, cache: cache)
        }
        let source = AppleLibraryMetadataResolver.configurationDigest(configuration.credential, "")
        await cache.store(Data("[]".utf8), source: source, type: "tmdb-season", mediaID: "tmdb:tv:42:6")
        let populated = AppleTMDBClient { request in
            let url = try #require(request.url)
            return (Data(#"{"episodes":[{"season_number":6,"episode_number":1,"name":"First &amp; Last"}]}"#.utf8),
                try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
        let retried = try await populated.seasonEpisodes(mediaID: "tmdb:tv:42", season: 6,
            configuration: configuration, cache: cache)
        #expect(retried.map(\.title) == ["First & Last"])
    }

    @Test @MainActor func resettingEpisodesPreservesAnInFlightLoadAndClearsProviderData() throws {
        let file = AppleLibraryItem(sourceID: UUID(), name: "Show.S06E01.Parsed.Name.mkv",
            url: URL(fileURLWithPath: "/Show.S06E01.Parsed.Name.mkv"),
            relativePath: "Shows/Show/Show.S06E01.Parsed.Name.mkv", sizeBytes: 1)
        let group = try #require(AppleLibrarySeries.groups([file]).first)
        let provider = AppleMediaEpisode(id: "tt1234567:6:1", title: "Provider Title", season: 6, episode: 1)
        var state = AppleTitlePageEpisodeState()
        state.applyProviderEpisodes([provider], season: 6, group: group, mediaID: "tt1234567")
        state.isLoading = true
        state.loadFinished = true
        state.selectedSeason = 6
        state.selectedEpisodeID = provider.id
        state.reset()
        #expect(state.isLoading)
        #expect(!state.loadFinished)
        #expect(state.episodes.isEmpty)
        #expect(state.selectedSeason == nil)
        #expect(state.selectedEpisodeID == nil)
        state.applyEpisodes([], localGroup: group, mediaID: "tt1234567")
        #expect(state.episodes.first?.title == "Parsed Name")
    }
}

private actor EpisodeRequests {
    private(set) var paths: [String] = []
    func append(_ path: String) { paths.append(path) }
}
