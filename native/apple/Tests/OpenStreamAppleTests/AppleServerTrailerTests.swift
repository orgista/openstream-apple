import Foundation
import Testing
@testable import OpenStreamApple

private func fixture(_ name: String) throws -> Data {
    try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/\(name)"))
}

private func reply(_ request: URLRequest, _ data: Data, status: Int = 200) -> (Data, URLResponse) {
    (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
}

private func query(_ url: URL?, _ name: String) -> String? {
    url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value }
}

@Suite("Server trailers: Plex extras")
struct ApplePlexTrailerTests {
    let session = AppleMediaServerSession(kind: .plex, baseURL: URL(string: "https://plex.fixture.example:32400")!,
                                          accessToken: "plex-token", userID: "1")

    @Test("Trailers come from the extras, best copy each, file URL with the token; other extras are left out")
    func extras() async throws {
        let data = try fixture("plex-extras-movie.json")
        let client = ApplePlexClient(loader: { request in
            #expect(request.url?.path == "/library/metadata/9000/extras")
            #expect(request.value(forHTTPHeaderField: "X-Plex-Token") == "plex-token")
            return reply(request, data)
        }, clientIdentifier: "test")
        let trailers = try await client.trailers(session: session, ratingKey: "9000")
        #expect(trailers.map(\.title) == ["About Time", "About Time (International Trailer)"])
        #expect(trailers.allSatisfy { $0.isFile })
        #expect(trailers[0].durationSeconds == 153)
        let url = trailers[1].url
        #expect(url.host == "plex.fixture.example" && url.port == 32400)
        #expect(url.path == "/services/iva/assets/100002/video.mp4")
        #expect(query(url, "bitrate") == "5000")
        #expect(query(url, "fmt") == "4")
        #expect(query(url, "X-Plex-Token") == "plex-token")
    }

    @Test("An extra AVPlayer cannot open as stored goes through Plex's HLS transcoder")
    func conversion() throws {
        let json = #"""
        {"ratingKey": "77", "title": "Teaser", "subtype": "trailer", "extraType": 1, "duration": 60000,
         "Media": [{"container": "mkv", "bitrate": 8000, "Part": [{"key": "/library/parts/77/1/file.mkv", "container": "mkv"}]}]}
        """#
        let extra = try JSONDecoder().decode(ApplePlexExtra.self, from: Data(json.utf8))
        let trailer = try #require(ApplePlexClient(clientIdentifier: "test").trailer(for: extra, session: session))
        #expect(!trailer.isFile)
        #expect(trailer.url.path == "/video/:/transcode/universal/start.m3u8")
        #expect(query(trailer.url, "path") == "/library/metadata/77")
        #expect(query(trailer.url, "protocol") == "hls")
        #expect(query(trailer.url, "X-Plex-Token") == "plex-token")
    }

    @Test("A part path that leaves the server or carries a credential is never given the token")
    func unsafeParts() throws {
        for key in ["https://elsewhere.example/a.mp4", "//elsewhere.example/a.mp4", "/library/../a.mp4",
                    "/library/parts/1/file.mp4?X-Plex-Token=other"] {
            let json = #"{"ratingKey": "1", "title": "T", "extraType": 1, "Media": [{"container": "mp4", "Part": [{"key": "\#(key)"}]}]}"#
            let extra = try JSONDecoder().decode(ApplePlexExtra.self, from: Data(json.utf8))
            #expect(ApplePlexClient(clientIdentifier: "test").trailer(for: extra, session: session) == nil, "\(key)")
        }
    }

    @Test("Search finds the server's copy by its IMDb guid")
    func search() async throws {
        let data = try fixture("plex-hubs-search.json")
        let client = ApplePlexClient(loader: { request in
            #expect(request.url?.path == "/hubs/search")
            #expect(query(request.url, "query") == "About Time")
            #expect(query(request.url, "includeGuids") == "1")
            return reply(request, data)
        }, clientIdentifier: "test")
        let wanted = AppleServerTrailerQuery(mediaID: "tt2194499", title: "About Time", year: 2013, isSeries: false,
                                             imdbID: "tt2194499")
        let candidates = try await client.searchCandidates(session: session, query: wanted)
        #expect(AppleServerTrailerMatch.best(candidates, for: wanted)?.id == "9000")
        let show = AppleServerTrailerQuery(mediaID: "tt2194499", title: "About Time", year: 2013, isSeries: true,
                                           imdbID: "tt2194499")
        #expect(try await client.searchCandidates(session: session, query: show).isEmpty)
    }
}

@Suite("Server trailers: Jellyfin and Emby")
struct AppleMediaServerTrailerTests {
    func session(_ kind: AppleMediaServerKind) -> AppleMediaServerSession {
        AppleMediaServerSession(kind: kind, baseURL: URL(string: "https://jf.fixture.example/jf/")!,
                                accessToken: "jf-token", userID: "u1")
    }

    @Test("Jellyfin: Items/<id>/LocalTrailers; an MP4 plays as the file with the user's key")
    func jellyfinFile() async throws {
        let data = try fixture("jellyfin-local-trailers.json")
        let client = AppleMediaServerClient(loader: { request in
            #expect(request.url?.path == "/jf/Items/movie1/LocalTrailers")
            #expect(query(request.url, "userId") == "u1")
            #expect(request.value(forHTTPHeaderField: "X-Emby-Token") == "jf-token")
            return reply(request, data)
        }, deviceID: "device")
        let trailer = try #require(try await client.firstTrailer(session: session(.jellyfin), itemID: "movie1"))
        #expect(trailer.isFile)
        #expect(trailer.title == "Sintel Trailer")
        #expect(trailer.durationSeconds == 40)
        #expect(trailer.url.path == "/jf/Videos/a1000000000000000000000000000001/stream.mov")
        #expect(query(trailer.url, "static") == "true")
        #expect(query(trailer.url, "api_key") == "jf-token")
    }

    @Test("Emby keeps the route under the user")
    func embyRoute() throws {
        let url = try AppleMediaServerClient(deviceID: "device").localTrailersURL(session: session(.emby), itemID: "movie1")
        #expect(url.pathComponents == ["/", "jf", "Users", "u1", "Items", "movie1", "LocalTrailers"])
    }

    @Test("A Matroska trailer plays as the server's conversion, asked for through PlaybackInfo")
    func conversion() async throws {
        let trailers = try JSONDecoder().decode([AppleMediaServerTrailerItem].self, from: try fixture("jellyfin-local-trailers.json"))
        let info = #"""
        {"PlaySessionId": "p1", "MediaSources": [{"Id": "a1000000000000000000000000000002", "Container": "mkv",
          "SupportsDirectPlay": false, "SupportsDirectStream": false,
          "TranscodingUrl": "/jf/videos/a1000000000000000000000000000002/master.m3u8?MediaSourceId=a1000000000000000000000000000002&api_key=jf-token"}]}
        """#
        let client = AppleMediaServerClient(loader: { request in
            #expect(request.url?.path == "/jf/Items/a1000000000000000000000000000002/PlaybackInfo")
            #expect(request.httpMethod == "POST")
            let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
            #expect(body?["EnableDirectPlay"] as? Bool == false)
            return reply(request, Data(info.utf8))
        }, deviceID: "device")
        let trailer = try await client.trailer(for: trailers[1], session: session(.jellyfin))
        #expect(!trailer.isFile)
        #expect(trailer.url.host == "jf.fixture.example")
        #expect(trailer.url.path == "/jf/videos/a1000000000000000000000000000002/master.m3u8")
    }

    @Test("A path that tries to leave the item is refused before any request")
    func unsafeItemID() async {
        let client = AppleMediaServerClient(loader: { request in
            Issue.record("no request expected")
            return reply(request, Data())
        }, deviceID: "device")
        await #expect(throws: AppleMediaServerError.unsupported) {
            _ = try await client.firstTrailer(session: session(.jellyfin), itemID: "../Users")
        }
    }
}

@Suite("Server trailers: which one plays where")
struct AppleTrailerSourcePolicyTests {
    let trailer = AppleServerTrailer(url: URL(string: "https://jf.fixture.example/t.mp4")!, title: "T",
                                     durationSeconds: nil, isFile: true)

    @Test("The server's trailer comes first; YouTube only after the lookup says no, and only where a web view can show it")
    func heroSource() {
        #expect(AppleTrailerSourcePolicy.heroSource(server: trailer, serverLookedUp: true, on: .visionOS) == .server(trailer))
        #expect(AppleTrailerSourcePolicy.heroSource(server: nil, serverLookedUp: false, on: .visionOS) == nil)
        #expect(AppleTrailerSourcePolicy.heroSource(server: nil, serverLookedUp: true, on: .visionOS) == .youTube)
        #expect(AppleTrailerSourcePolicy.heroSource(server: trailer, serverLookedUp: true, on: .iOS) == .server(trailer))
        #expect(AppleTrailerSourcePolicy.heroSource(server: trailer, serverLookedUp: true, on: .macOS) == .youTube)
        #expect(AppleTrailerSourcePolicy.heroSource(server: nil, serverLookedUp: false, on: .iOS) == nil)
        #expect(AppleTrailerSourcePolicy.heroSource(server: nil, serverLookedUp: false, on: .macOS) == .youTube)
        #expect(AppleTrailerSourcePolicy.heroSource(server: nil, serverLookedUp: true, on: .iOS) == .youTube)
        #expect(AppleTrailerSourcePolicy.heroSource(server: nil, serverLookedUp: true, on: .macOS) == .youTube)
    }

    @Test("The Apple TV never picks YouTube")
    func appleTV() {
        #expect(AppleTrailerSourcePolicy.heroSource(server: trailer, serverLookedUp: true, on: .tvOS) == .server(trailer))
        #expect(AppleTrailerSourcePolicy.heroSource(server: nil, serverLookedUp: true, on: .tvOS) == nil)
        #expect(AppleTrailerSourcePolicy.heroSource(server: nil, serverLookedUp: false, on: .tvOS) == nil)
        #expect(!AppleTrailerSourcePolicy.offersYouTube(on: .tvOS))
    }

    @Test("A file plays as stored only in a container AVPlayer opens")
    func containers() {
        #expect(AppleServerTrailerStreamPolicy.playsAsFile(container: "mp4"))
        #expect(AppleServerTrailerStreamPolicy.playsAsFile(container: "mov,mp4,m4a,3gp,3g2,mj2"))
        #expect(!AppleServerTrailerStreamPolicy.playsAsFile(container: "mkv,webm"))
        #expect(!AppleServerTrailerStreamPolicy.playsAsFile(container: nil))
    }

    @Test("A title is matched by IMDb, then TMDB, then title and year; never by title alone")
    func matching() {
        let candidates: [AppleServerTrailerMatch.Candidate] = [
            .init(id: "1", title: "Dune", year: 1984, imdbID: "tt0087182", tmdbID: "841"),
            .init(id: "2", title: "Dune", year: 2021, imdbID: nil, tmdbID: "438631"),
            .init(id: "3", title: "Amélie", year: 2001, imdbID: nil, tmdbID: nil),
            .init(id: "4", title: "Pinocchio", year: 2022, imdbID: "tt4593060", tmdbID: nil),
        ]
        func best(_ title: String, _ year: Int?, imdb: String? = nil, tmdb: String? = nil) -> String? {
            AppleServerTrailerMatch.best(candidates, for: .init(mediaID: "x", title: title, year: year, isSeries: false,
                                                                imdbID: imdb, tmdbID: tmdb))?.id
        }
        #expect(best("Dune", nil, imdb: "tt0087182") == "1")
        #expect(best("Dune", nil, tmdb: "438631") == "2")
        #expect(best("amelie", 2001) == "3")
        #expect(best("Dune", nil) == nil)
        #expect(best("Dune", 2000) == nil)
        #expect(best("Pinocchio", 2022, imdb: "tt1488589") == nil)
        #expect(best("Pinocchio", 2022, tmdb: "555604") == "4")
    }

    @Test("A catalog title is looked up by the ids its own id names")
    func catalogQuery() {
        func item(_ id: String, type: String = "movie") -> AppleCatalogItem {
            AppleCatalogItem(mediaID: id, type: type, name: "N", posterURL: nil, backgroundURL: nil, summary: nil,
                             releaseInfo: nil, rating: nil, genres: nil, year: 2020)
        }
        #expect(AppleServerTrailerQuery(item: item("tt1234567")).imdbID == "tt1234567")
        #expect(AppleServerTrailerQuery(item: item("tt1234567:1:2", type: "series")).imdbID == "tt1234567")
        #expect(AppleServerTrailerQuery(item: item("tt1234567:1:2", type: "series")).isSeries)
        #expect(AppleServerTrailerQuery(item: item("tmdb:438631")).tmdbID == "438631")
        #expect(AppleServerTrailerQuery(item: item("tmdb:438631")).imdbID == nil)
    }
}

@MainActor
@Suite("Server trailers: lookup and cache")
struct AppleServerTrailerStoreTests {
    final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_000_000)
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    @Test("A server title asks its own server, and the answer is kept for its lifetime only")
    func cache() async throws {
        let data = try fixture("jellyfin-local-trailers.json")
        let calls = Counter()
        let clock = Clock()
        let store = AppleServerTrailerStore(client: AppleMediaServerClient(loader: { request in
            _ = calls.next()
            return reply(request, data)
        }, deviceID: "device"), now: { clock.now })
        let source = UUID()
        store.update(sessions: [source: AppleMediaServerSession(kind: .jellyfin, baseURL: URL(string: "https://jf.fixture.example")!,
                                                                accessToken: "t", userID: "u")])
        let mediaID = AppleMediaServerItemReference(sourceID: source, itemID: "movie1").mediaID
        let wanted = AppleServerTrailerQuery(mediaID: mediaID, title: "Sintel", year: 2010, isSeries: false)
        #expect(try await store.trailer(for: wanted)?.title == "Sintel Trailer")
        #expect(try await store.trailer(for: wanted) != nil)
        #expect(calls.count == 1)
        clock.now += AppleServerTrailerStore.lifetime + 1
        #expect(store.knownTrailer(for: mediaID) == nil)
        _ = try await store.trailer(for: wanted)
        #expect(calls.count == 2)
    }

    @Test("A server that does not answer is asked again; its silence is not kept as \"no trailer\"")
    func unanswered() async throws {
        let calls = Counter()
        let store = AppleServerTrailerStore(client: AppleMediaServerClient(loader: { _ in
            _ = calls.next()
            throw URLError(.timedOut)
        }, deviceID: "device"))
        let source = UUID()
        store.update(sessions: [source: AppleMediaServerSession(kind: .jellyfin, baseURL: URL(string: "https://jf.fixture.example")!,
                                                                accessToken: "t", userID: "u")])
        let mediaID = AppleMediaServerItemReference(sourceID: source, itemID: "movie1").mediaID
        let wanted = AppleServerTrailerQuery(mediaID: mediaID, title: "Sintel", year: 2010, isSeries: false)
        #expect(try await store.trailer(for: wanted) == nil)
        #expect(store.knownTrailer(for: mediaID) == nil)
        _ = try await store.trailer(for: wanted)
        #expect(calls.count == 2)
    }

    @Test("No signed-in server, no request; new sessions forget old answers and tell the views")
    func sessions() async throws {
        let calls = Counter()
        let store = AppleServerTrailerStore(client: AppleMediaServerClient(loader: { request in
            _ = calls.next()
            return reply(request, Data("[]".utf8))
        }, deviceID: "device"))
        let wanted = AppleServerTrailerQuery(mediaID: "tt0000001", title: "Stub", year: 2020, isSeries: false, imdbID: "tt0000001")
        #expect(try await store.trailer(for: wanted) == nil)
        #expect(calls.count == 0)
        let revision = store.revision
        store.update(sessions: [UUID(): AppleMediaServerSession(kind: .emby, baseURL: URL(string: "https://emby.fixture.example")!,
                                                                accessToken: "t", userID: "u")])
        #expect(store.revision != revision)
        #expect(try await store.trailer(for: wanted) == nil)
        #expect(calls.count == 1)
    }
}

@Suite("Server trailers: the Top Shelf's saved copies")
struct AppleTopShelfTrailerFilesTests {
    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Bool
        init(_ value: Bool) { stored = value }
        var value: Bool {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    final class Downloads: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL] = []
        func add(_ url: URL) { lock.lock(); urls.append(url); lock.unlock() }
        var all: [URL] { lock.lock(); defer { lock.unlock() }; return urls }
    }

    private func item(_ id: String) -> AppleTopShelfSnapshot.Item {
        .init(id: id, title: id, kind: "movie", artworkURL: nil, displayURL: URL(string: "openstream://media/\(id)")!,
              playURL: nil, landscapeArtworkURL: URL(string: "https://image.tmdb.org/t/p/original/\(id).jpg"))
    }

    private func hero(_ id: String) -> AppleTopShelfHero {
        AppleTopShelfHero(item: item(id), backdropURL: nil, wordmarkURL: nil,
                          trailerQuery: .init(mediaID: id, title: id, year: 2020, isSeries: false, imdbID: id))
    }

    @Test("A saved name is a bare video file name, one per title, made from nothing secret")
    func names() throws {
        #expect(AppleTopShelfTrailerPolicy.shelfVideo("abc.mp4") == "abc.mp4")
        #expect(AppleTopShelfTrailerPolicy.shelfVideo("../abc.mp4") == nil)
        #expect(AppleTopShelfTrailerPolicy.shelfVideo(".mp4") == nil)
        #expect(AppleTopShelfTrailerPolicy.shelfVideo("abc.m3u8") == nil)
        let trailer = AppleServerTrailer(url: URL(string: "https://plex.fixture.example/v.mov?X-Plex-Token=secret")!,
                                         title: "T", durationSeconds: 90, isFile: true)
        let name = AppleTopShelfTrailerPolicy.fileName(mediaID: "tt1", trailer: trailer)
        #expect(!name.contains("secret") && name.hasSuffix(".mov"))
        #expect(name != AppleTopShelfTrailerPolicy.fileName(mediaID: "tt2", trailer: trailer))
        let directory = FileManager.default.temporaryDirectory.appending(path: "openstream-trailer-names-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(AppleTopShelfTrailerPolicy.savedFile(mediaID: "tt1", in: directory) == nil)
        try Data("x".utf8).write(to: directory.appending(path: name))
        #expect(AppleTopShelfTrailerPolicy.savedFile(mediaID: "tt1", in: directory) == name)
    }

    @Test("The snapshot goes out at once; each hero's trailer is added once saved; conversions and oversize files are skipped; a lookup that fails later keeps the file")
    func writer() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "openstream-topshelf-trailers-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let downloads = Downloads()
        let serverUp = Flag(true)
        let files = AppleTopShelfTrailerFiles(resolve: { query in
            guard serverUp.value else { return nil }
            return switch query.mediaID {
            case "file": AppleServerTrailer(url: URL(string: "https://jf.fixture.example/file.mp4?api_key=k")!,
                                            title: "file", durationSeconds: 60, isFile: true)
            case "big": AppleServerTrailer(url: URL(string: "https://jf.fixture.example/big.mp4?api_key=k")!,
                                           title: "big", durationSeconds: 60, isFile: true)
            case "hls": AppleServerTrailer(url: URL(string: "https://jf.fixture.example/master.m3u8?api_key=k")!,
                                           title: "hls", durationSeconds: 60, isFile: false)
            default: nil
            }
        }, measure: { url in
            url.lastPathComponent == "big.mp4" ? AppleTopShelfTrailerFiles.maximumFileBytes + 1 : 4
        }, download: { source, destination in
            downloads.add(source)
            try Data("mp4!".utf8).write(to: destination)
            return 4
        })
        let runner = AppleTopShelfTrailerDownloads()
        let writer = AppleTopShelfSnapshotWriter(containerProvider: { root },
                                                 snapshotLocation: { AppleTopShelfSnapshotWriter.snapshotURL(in: $0) },
                                                 artwork: nil, trailerFiles: files, trailerDownloads: runner)
        let reader = AppleTopShelfSnapshotReader(containerProvider: { root })
        let heroes = ["file", "big", "hls", "none"].map(hero)
        try await writer.write(records: [], heroes: heroes, enabled: true)
        #expect(try #require(reader.read()).heroes.allSatisfy { $0.shelfVideo == nil })
        await runner.finish()

        let saved = AppleTopShelfTrailerPolicy.fileName(mediaID: "file", trailer: AppleServerTrailer(
            url: URL(string: "https://jf.fixture.example/file.mp4")!, title: "file", durationSeconds: 60, isFile: true))
        #expect(try #require(reader.read()).heroes.map(\.shelfVideo) == [saved, nil, nil, nil])
        let directory = AppleTopShelfTrailerPolicy.directory(in: root)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [saved])
        #expect(downloads.all.map(\.lastPathComponent) == ["file.mp4"])
        let raw = try Data(contentsOf: AppleTopShelfSnapshotWriter.snapshotURL(in: root))
        #expect(!String(decoding: raw, as: UTF8.self).contains("api_key"))

        serverUp.value = false
        try await writer.write(records: [], heroes: heroes, enabled: true)
        await runner.finish()
        #expect(try #require(reader.read()).heroes.first?.shelfVideo == saved)
        #expect(downloads.all.count == 1)

        try await writer.write(records: [], heroes: [], enabled: true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        try await writer.write(records: [], enabled: false)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test("Turning Top Shelf off stops the running download; nothing lands after the opt-out")
    func optOutCancels() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "openstream-topshelf-optout-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let downloads = Downloads()
        let files = AppleTopShelfTrailerFiles(resolve: { query in
            AppleServerTrailer(url: URL(string: "https://jf.fixture.example/\(query.mediaID).mp4")!,
                               title: query.title, durationSeconds: 60, isFile: true)
        }, measure: { _ in 4 }, download: { source, destination in
            downloads.add(source)
            try await Task.sleep(for: .seconds(1))
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data("mp4!".utf8).write(to: destination)
            return 4
        })
        let runner = AppleTopShelfTrailerDownloads()
        let writer = AppleTopShelfSnapshotWriter(containerProvider: { root },
                                                 snapshotLocation: { AppleTopShelfSnapshotWriter.snapshotURL(in: $0) },
                                                 artwork: nil, trailerFiles: files, trailerDownloads: runner)
        try await writer.write(records: [], heroes: ["a", "b"].map(hero), enabled: true)
        while downloads.all.isEmpty { try await Task.sleep(for: .milliseconds(10)) }

        try await writer.write(records: [], enabled: false)
        await runner.finish()
        #expect(downloads.all.count == 1)
        #expect(!FileManager.default.fileExists(atPath: AppleTopShelfTrailerPolicy.directory(in: root).path))
    }

    @Test("Snapshots written before saved trailers still decode")
    func olderSnapshot() throws {
        let json = #"""
        {"id": "a", "title": "A", "kind": "movie", "displayURL": "openstream://media/a"}
        """#
        let decoded = try JSONDecoder().decode(AppleTopShelfSnapshot.Item.self, from: Data(json.utf8))
        #expect(decoded.shelfVideo == nil && decoded.previewVideoURL == nil)
    }
}
