import Foundation
import Testing
@testable import OpenStreamApple

struct AppleXtreamLibraryTests {
    let sourceID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let base = URL(string: "https://fixture.example/panel")!
    let credentials = AppleIPTVCredentials(username: "user /?", password: "pass/#")

    @Test func referenceRoundTripAndSourceIsolation() throws {
        let reference = AppleXtreamReference(sourceID: sourceID, kind: .movie, providerID: "42")
        #expect(AppleXtreamReference.parse(reference.mediaID) == reference)
        #expect(AppleXtreamReference.parse("xc:invalid:movie:42") == nil)
        #expect(AppleXtreamReference.parse("xc:\(sourceID):live:42") == nil)
        #expect(AppleXtreamReference.parse("xc:\(sourceID):movie:../42") == nil)
    }

    @Test(arguments: [AppleXtreamReference.Kind.movie, .episode])
    func playbackPathsAreEscapedAndNotLive(kind: AppleXtreamReference.Kind) throws {
        let url = try AppleXtreamLibraryPolicy.playbackURL(base: base, credentials: credentials,
            kind: kind, providerID: "42", container: "mkv")
        #expect(url.path.hasPrefix("/panel/\(kind == .movie ? "movie" : "series")/"))
        #expect(url.absoluteString.contains("user%20%2F%3F"))
        #expect(url.absoluteString.hasSuffix("/42.mkv"))
        #expect(url.query == nil)
        #expect(throws: AppleIPTVError.invalidEndpoint) {
            try AppleXtreamLibraryPolicy.playbackURL(base: base, credentials: credentials,
                kind: .series, providerID: "42", container: "mp4")
        }
    }

    @Test func invalidPathsAndExtensionsAreRejected() {
        for id in ["", "../2", "2/3", "-1", "abc"] {
            #expect(throws: AppleIPTVError.invalidEndpoint) {
                try AppleXtreamLibraryPolicy.playbackURL(base: base, credentials: credentials,
                    kind: .movie, providerID: id, container: "mp4")
            }
        }
        #expect(throws: AppleIPTVError.invalidEndpoint) {
            try AppleXtreamLibraryPolicy.playbackURL(base: base, credentials: credentials,
                kind: .movie, providerID: "1", container: "../mp4")
        }
    }

    @Test func cacheExpiryAndFingerprint() {
        let now = Date(timeIntervalSince1970: 100_000)
        #expect(AppleXtreamLibraryPolicy.isFresh(storedAt: now, now: now.addingTimeInterval(43_199)))
        #expect(!AppleXtreamLibraryPolicy.isFresh(storedAt: now, now: now.addingTimeInterval(43_200)))
        #expect(!AppleXtreamLibraryPolicy.isFresh(storedAt: now, now: now.addingTimeInterval(-1)))
        #expect(AppleXtreamLibraryPolicy.cacheKey(base: base, credentials: credentials, action: "get_vod_streams", argument: nil)
            != AppleXtreamLibraryPolicy.cacheKey(base: base, credentials: credentials, action: "get_series", argument: nil))
    }

    @Test func mixedProviderScalarsAndMalformedRows() async throws {
        let client = AppleXtreamLibraryClient(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)) { request in
            let data = Data(#"[{"stream_id":42,"name":"Fixture Film","category_id":"7","stream_icon":"https://fixture.example/poster.jpg","rating":"8.2","container_extension":"mkv"},{"stream_id":"43","name":"Other"},{"stream_id":"../bad","name":"Bad"},{"stream_id":44},null,42]"#.utf8)
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let titles = try await client.titles(base: base, credentials: credentials, kind: .movie, categoryID: nil)
        #expect(titles.map(\.providerID) == ["42", "43"])
        #expect(titles.first?.rating == 8.2)
        #expect(titles.first?.container == "mkv")
    }

    @Test func failureIsNeutralAndDoesNotCache() async {
        let client = AppleXtreamLibraryClient(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)) { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!)
        }
        await #expect(throws: AppleXtreamLibraryError.unavailable) {
            try await client.categories(base: base, credentials: credentials, kind: .movie)
        }
    }

    @Test func catalogueIdentitySurvivesMetadataAndIsProviderScoped() {
        let ref = AppleXtreamReference(sourceID: sourceID, kind: .movie, providerID: "101")
        let first = AppleCatalogItem(mediaID: ref.mediaID, type: "movie", name: "Before")
        let enriched = AppleCatalogItem(mediaID: ref.mediaID, type: "movie", name: "After", releaseInfo: "2025")
        let other = AppleCatalogItem(mediaID: AppleXtreamReference(sourceID: UUID(), kind: .movie, providerID: "101").mediaID,
                                     type: "movie", name: "Before")
        let a = AppleMediaIngestion.catalogRecord(instanceID: sourceID, item: first)
        #expect(a.isPrivate)
        #expect(a.id == AppleMediaIngestion.catalogRecord(instanceID: sourceID, item: enriched).id)
        #expect(a.id != AppleMediaIngestion.catalogRecord(instanceID: sourceID, item: other).id)
        #expect(AppleTitleProgressIdentity.candidates(item: first, sourceID: sourceID) == [a.id])
    }

    @MainActor @Test func seriesSelectionResumeWatchedAndNextEpisode() throws {
        let reference = AppleXtreamReference(sourceID: sourceID, kind: .series, providerID: "201")
        let episodes = [AppleStremioEpisode(id: reference.mediaID + ":1:1", title: "Pilot", season: 1, episode: 1),
                        AppleStremioEpisode(id: reference.mediaID + ":2:1", title: "Next", season: 2, episode: 1)]
        #expect(AppleStremioEpisodeSelection(seriesMediaID: reference.mediaID, episode: episodes[0])?.mediaID == episodes[0].id)
        #expect(AppleStremioEpisodeSelection(seriesMediaID: reference.mediaID, episode: episodes[1]) != nil)
        #expect(AppleStremioEpisodeSelection(seriesMediaID: reference.mediaID,
            episode: AppleStremioEpisode(id: reference.mediaID + ":1:1", title: "Bad", season: 2, episode: 1)) == nil)
        #expect(AppleStremioEpisodePolicy.following(episodes[0], in: episodes) == episodes[1])
        let suite = "xtream-progress-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ApplePlaybackStore(defaults: defaults)
        store.save(mediaID: reference.mediaID, position: 30, duration: 300, partID: episodes[0].id)
        #expect(AppleDetailResume.position(mediaID: reference.mediaID, partID: episodes[0].id, store: store) == 30)
        #expect(AppleDetailResume.position(mediaID: reference.mediaID, partID: episodes[1].id, store: store) == nil)
        store.save(mediaID: reference.mediaID, position: 299, duration: 300, partID: episodes[0].id)
        #expect(store.isWatched(mediaID: episodes[0].id))
        #expect(AppleStremioEpisodePolicy.upNext(from: episodes, completedIDs: [episodes[0].id]) == episodes[1])
    }

    @Test func detailSortsEpisodesAndReadsMovieContainerAndTMDB() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = AppleXtreamLibraryClient(directory: directory) { request in
            let action = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "action" }!.value
            let json = action == "get_vod_info"
                ? #"{"info":{"plot":"Plot","tmdb_id":123,"rating":"9"},"movie_data":{"container_extension":"mkv"}}"#
                : #"{"info":{"name":"Show"},"episodes":{"2":[{"id":22,"season":"2","episode_num":"1","title":"Next","container_extension":"mkv"}],"1":[{"id":"11","season":1,"episode_num":1,"title":"Pilot","container_extension":"mp4"},{"id":"bad","episode_num":2}]}}"#
            return (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        func title(_ kind: AppleXtreamReference.Kind) -> AppleXtreamTitle {
            .init(providerID: "1", kind: kind, name: "Title", categoryID: nil, poster: nil, backdrop: nil,
                  plot: nil, year: nil, rating: nil, container: nil, tmdbID: nil)
        }
        let movie = try await client.detail(base: base, credentials: credentials, title: title(.movie))
        #expect(movie.title.container == "mkv")
        #expect(movie.title.tmdbID == "123")
        let series = try await client.detail(base: base, credentials: credentials, title: title(.series))
        #expect(series.episodes.map(\.providerID) == ["11", "22"])
        #expect(series.episodes.map(\.season) == [1, 2])
    }

    @Test func cacheReusesDiskAndForceRefreshes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = AppleXtreamLibraryClient(directory: directory) { request in
            (Data(#"[{"category_id":1,"category_name":"Movies"}]"#.utf8),
             HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let initial = try await client.categories(base: base, credentials: credentials, kind: .movie)
        let offline = AppleXtreamLibraryClient(directory: directory) { _ in throw AppleXtreamLibraryError.unavailable }
        #expect(try await offline.categories(base: base, credentials: credentials, kind: .movie) == initial)
        await #expect(throws: AppleXtreamLibraryError.unavailable) {
            try await offline.categories(base: base, credentials: credentials, kind: .movie, force: true)
        }
        await #expect(throws: AppleXtreamLibraryError.unavailable) {
            try await offline.categories(base: base, credentials: .init(username: "changed", password: "fixture"), kind: .movie)
        }
    }

    @Test func largeCatalogueHasNoTenThousandTitleCutoff() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = try JSONSerialization.data(withJSONObject: (1...25_000).map { ["stream_id": String($0), "name": "Film \($0)"] })
        let client = AppleXtreamLibraryClient(directory: directory) { request in
            (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        #expect(try await client.titles(base: base, credentials: credentials, kind: .movie, categoryID: nil).count == 25_000)
    }

    @Test func cancellationAndWrongResponseShape() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let invalid = AppleXtreamLibraryClient(directory: directory) { request in
            (Data(#"{"error":"fixture"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        await #expect(throws: AppleXtreamLibraryError.invalidResponse) {
            try await invalid.titles(base: base, credentials: credentials, kind: .movie, categoryID: nil)
        }
        let cancelled = AppleXtreamLibraryClient(directory: directory) { _ in throw CancellationError() }
        await #expect(throws: CancellationError.self) {
            try await cancelled.categories(base: base, credentials: credentials, kind: .movie)
        }
    }

    @MainActor @Test func storeBrowsesSearchesPlaysAndDropsDisabledSources() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "xtream-store-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sourceStore = AppleSourceStore(defaults: defaults, keychain: XtreamFixtureCredentials())
        let source = try sourceStore.addIPTV(name: "Fixture Provider", type: .xtream, endpoint: base.absoluteString,
                                           username: "fixture", password: "fixture")
        let client = AppleXtreamLibraryClient(directory: directory) { request in
            let action = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "action" }!.value
            let json: String
            switch action {
            case "get_vod_categories", "get_series_categories": json = #"[{"category_id":1,"category_name":"Drama"}]"#
            case "get_vod_streams": json = #"[{"stream_id":101,"name":"Film","container_extension":"mkv"}]"#
            case "get_series": json = #"[{"series_id":201,"name":"Show"}]"#
            case "get_series_info": json = #"{"info":{},"episodes":{"1":[{"id":301,"season":1,"episode_num":1,"title":"Pilot","container_extension":"mkv"}]}}"#
            default: json = #"{"info":{},"movie_data":{"container_extension":"mkv"}}"#
            }
            return (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let progress = ApplePlaybackStore(defaults: defaults)
        let library = AppleXtreamLibraryStore(client: client, playbackStore: progress)
        await library.reload(sourceStore: sourceStore)
        #expect(library.shelves.count == 2)
        #expect(library.failures.isEmpty)
        let result = try #require(await library.search("Film").first)
        #expect(library.match(result)?.item.name == "Film")
        let ref = AppleXtreamReference(sourceID: source.id, kind: .series, providerID: "201")
        let detail = try await library.detail(ref)
        let episode = try #require(library.episodes(detail, sourceID: source.id).first)
        let item = try #require(library.catalog(ref))
        let identity = AppleMediaIngestion.catalogRecord(instanceID: source.id, item: item).id
        progress.save(mediaID: identity, position: 30, duration: 300, partID: episode.id)
        library.refreshProgress()
        #expect(library.continueWatching.map(\.name) == ["Show"])
        let request = try await library.request(reference: ref, episodeID: episode.id, mediaID: identity, fromBeginning: false)
        #expect(request.url.path.hasSuffix("/301.mkv"))
        #expect(!request.isLive)
        #expect(request.resumePosition == 30)
        #expect(request.hints.progressPartID == episode.id)
        #expect(request.hints.addonMediaID == nil)
        #expect(try await library.request(reference: ref, episodeID: episode.id, mediaID: identity, fromBeginning: true).resumePosition == nil)
        sourceStore.setEnabled(false, id: source.id)
        await library.reload(sourceStore: sourceStore)
        #expect(library.shelves.isEmpty)
        #expect(library.continueWatching.isEmpty)
        #expect(await library.search("Film").isEmpty)
        #expect(library.match(result) == nil)
    }

    @MainActor @Test func failedMoviesDoNotHideSeries() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "xtream-partial-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sources = AppleSourceStore(defaults: defaults, keychain: XtreamFixtureCredentials())
        _ = try sources.addIPTV(name: "Fixture", type: .xtream, endpoint: base.absoluteString, username: "fixture", password: "fixture")
        let client = AppleXtreamLibraryClient(directory: directory) { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            let action = query.first { $0.name == "action" }!.value ?? ""
            if action.hasPrefix("get_vod") { throw AppleXtreamLibraryError.unavailable }
            let json = action == "get_series_categories" ? #"[{"category_id":1,"category_name":"Shows"}]"# : #"[{"series_id":2,"name":"Show"}]"#
            return (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let library = AppleXtreamLibraryStore(client: client, playbackStore: .init(defaults: defaults))
        await library.reload(sourceStore: sources)
        #expect(library.shelves.count == 1)
        #expect(library.shelves.first?.kind == .series)
        #expect(library.failures.count == 1)
        #expect(!library.isLoading)
    }
}

private final class XtreamFixtureCredentials: AppleCredentialStoring {
    var values: [String: String] = [:]
    func string(for account: String) throws -> String? { values[account] }
    func set(_ value: String, for account: String) throws { values[account] = value }
    func remove(_ account: String) throws { values.removeValue(forKey: account) }
}
