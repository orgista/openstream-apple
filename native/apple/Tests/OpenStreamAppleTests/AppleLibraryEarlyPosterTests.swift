import Foundation
import Observation
import Synchronization
import Testing
@testable import OpenStreamApple

@Suite("Library early posters", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct AppleLibraryEarlyPosterTests {
    @Test(arguments: [false, true])
    func searchPublishesOnlyPosterWhileDetailsAreSuspended(series: Bool) async throws {
        let fixture = try Fixture(series: series)
        defer { fixture.remove() }
        let original = fixture.library.catalogItem(for: fixture.group)
        let task = Task { await fixture.resolve() }
        await fixture.details.waitUntilStarted()
        let poster = try await fixture.waitForPoster()
        #expect(poster.url == fixture.searchPoster)
        #expect(poster == fixture.library.poster(for: fixture.group))
        #expect(AppleCatalogCard.resolvedPosterURL(item: original, sizing: .catalog, libraryPoster: poster) == fixture.searchPoster)
        #expect(fixture.library.metadata[fixture.group.id] == nil)
        #expect(fixture.library.catalogItem(for: fixture.group) == original)
        #expect(fixture.library.contentRevision == 0)
        #expect(fixture.group.items.first?.id == fixture.file.id)
        fixture.library.posterDidLoad(poster)
        await fixture.details.finish()
        await task.value
        #expect(fixture.library.metadata[fixture.group.id]?.mediaID == "tt1234567")
        #expect(fixture.library.poster(for: fixture.group)?.url == fixture.searchPoster)
    }

    @Test(arguments: [false, true], [false, true])
    func fullPosterReplacesOnlyAnEarlyPosterThatNeverLoaded(loaded: Bool, samePoster: Bool) async throws {
        let fixture = try Fixture(samePoster: samePoster)
        defer { fixture.remove() }
        let task = Task { await fixture.resolve() }
        await fixture.details.waitUntilStarted()
        let poster = try await fixture.waitForPoster()
        if loaded { fixture.library.posterDidLoad(poster) }
        await fixture.details.finish()
        await task.value
        let final = try #require(fixture.library.metadata[fixture.group.id])
        #expect(final.posterURL == fixture.fullPoster)
        #expect(final.summary == "Full details")
        #expect(final.genres == ["Drama"])
        let displayed = fixture.library.poster(for: fixture.group)?.url ?? final.posterURL
        #expect(displayed == (loaded ? fixture.searchPoster : fixture.fullPoster))
    }

    @Test(arguments: [false, true])
    func rematchAndUnmatchClearThePosterAndRejectLateLoads(manual: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let task = Task { await fixture.resolve() }
        await fixture.details.waitUntilStarted()
        let oldPoster = try await fixture.waitForPoster()
        if manual {
            try await fixture.library.correctMatch(fixture.group,
                candidate: .init(mediaID: "tt7654321", type: "movie", name: "Owner pick"),
                provider: "fixture", resolver: fixture.resolver)
        } else {
            try await fixture.library.useAutomaticMatch(fixture.group)
        }
        fixture.library.posterDidLoad(oldPoster)
        #expect(fixture.library.poster(for: fixture.group) == nil)
        #expect(fixture.library.earlyPosterURLs[fixture.group.id] == nil)
        await fixture.details.finish()
        await task.value
        #expect(fixture.library.poster(for: fixture.group) == nil)
        if manual { #expect(fixture.library.metadata[fixture.group.id]?.mediaID == "tt7654321") }
    }

    @Test(arguments: [false, true])
    func revalidationKeepsRichCachedContentVisible(detailsFail: Bool) async throws {
        let fixture = try Fixture(fails: detailsFail)
        defer { fixture.remove() }
        let cached = AppleCatalogItem(mediaID: "tt1234567", type: "movie", name: "Film",
            posterURL: fixture.fullPoster, summary: "Full details", releaseInfo: "2024-01-01",
            genres: ["Drama"], year: 2024)
        try fixture.writeCache(cached, checkedAt: .now)
        await fixture.resolve()
        let revision = fixture.library.contentRevision
        try fixture.writeCache(cached, checkedAt: .distantPast)
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("Matches"))
        let task = Task { await fixture.resolve() }
        await fixture.details.waitUntilStarted()
        #expect(fixture.library.catalogItem(for: fixture.group) == cached)
        #expect(fixture.library.poster(for: fixture.group) == nil)
        #expect(fixture.library.contentRevision == revision)
        await fixture.details.finish()
        await task.value
        #expect(fixture.library.catalogItem(for: fixture.group) == cached)
        #expect(fixture.library.poster(for: fixture.group) == nil)
        #expect(fixture.library.contentRevision == revision)
    }

    @Test func detailsFailureStillFallsBackToOMDb() async throws {
        let fixture = try Fixture(fails: true)
        defer { fixture.remove() }
        let stubs = fixture.root.appendingPathComponent("Providers")
        let omdb = stubs.appendingPathComponent("www.omdbapi.com")
        try FileManager.default.createDirectory(at: omdb, withIntermediateDirectories: true)
        try Data(#"{"Title":"Film","Year":"2024","imdbID":"tt7654321","Type":"movie","Response":"True","Plot":"OMDb details","Poster":"https://fixture.example/omdb.jpg"}"#.utf8)
            .write(to: omdb.appendingPathComponent("index.json"))
        try await AppleNetworkStub.$testRoot.withValue(stubs) {
            let task = Task { await fixture.resolve(omdbKey: "fixture") }
            await fixture.details.waitUntilStarted()
            let poster = try await fixture.waitForPoster()
            fixture.library.posterDidLoad(poster)
            await fixture.details.finish()
            await task.value
        }
        #expect(fixture.library.metadata[fixture.group.id]?.mediaID == "tt7654321")
        #expect(fixture.library.metadata[fixture.group.id]?.summary == "OMDb details")
        #expect(fixture.library.poster(for: fixture.group) == nil)
    }

    @Test(arguments: [false, true], [false, true])
    func nilResultsClearLoadedEarlyPosters(noMatch: Bool, single: Bool) async throws {
        let fixture = try Fixture(fails: true, noMatch: noMatch)
        defer { fixture.remove() }
        let task = Task { await fixture.resolve(single: single) }
        await fixture.details.waitUntilStarted()
        let poster = try await fixture.waitForPoster()
        fixture.library.posterDidLoad(poster)
        await fixture.details.finish()
        await task.value
        #expect(fixture.library.metadata[fixture.group.id] == nil)
        #expect(fixture.library.noMatchIDs.contains(fixture.group.id) == noMatch)
        #expect(fixture.library.poster(for: fixture.group) == nil)
        #expect(fixture.library.earlyPosterURLs.isEmpty)
    }

    @Test(arguments: [false, true])
    func completedRescanPrunesPostersAndRejectsPendingDeliveries(loaded: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let task = Task { await fixture.resolve() }
        await fixture.details.waitUntilStarted()
        let poster = try await fixture.waitForPoster()
        if loaded { fixture.library.posterDidLoad(poster) }
        _ = await fixture.library.publishScanProgress([], sourceID: fixture.file.sourceID, complete: true)
        #expect(fixture.library.groups.isEmpty)
        #expect(fixture.library.earlyPosterURLs.isEmpty)
        fixture.library.posterDidLoad(poster)
        await fixture.details.finish()
        await task.value
        #expect(fixture.library.poster(for: fixture.group) == nil)
        #expect(fixture.library.earlyPosterURLs.isEmpty)
    }

    @Test(arguments: [AppleCatalogCardSizing.featured, .ranked, .continueWatching])
    func landscapeCardsPreferBackdropsAndResumeStills(sizing: AppleCatalogCardSizing) throws {
        let poster = AppleLibraryPoster(groupID: "fixture", url: try #require(URL(string: "https://fixture.example/early.jpg")))
        let backdrop = try #require(URL(string: "https://fixture.example/backdrop.jpg"))
        let still = try #require(URL(string: "https://fixture.example/still.jpg"))
        let item = AppleCatalogItem(mediaID: "tt1234567", type: "movie", name: "Film", backgroundURL: backdrop)
        #expect(AppleCatalogCard.resolvedPosterURL(item: item, sizing: sizing, libraryPoster: poster) == backdrop)
        #expect(AppleCatalogCard.resolvedPosterURL(item: item, sizing: sizing,
            resumeStillURL: still, libraryPoster: poster) == (sizing == .continueWatching ? still : backdrop))
        let fallback = AppleArtworkResolver.Artwork(posterURL: nil, backgroundURL: backdrop)
        let bare = AppleCatalogItem(mediaID: item.mediaID, type: item.type, name: item.name)
        #expect(AppleCatalogCard.resolvedPosterURL(item: bare, sizing: sizing,
            libraryPoster: poster, fallbackArtwork: fallback) == backdrop)
    }

    @Test func posterArrivalDoesNotInvalidateOtherGroupsOrTheGrid() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let other = AppleLibrarySeries(id: "another-group", parsed: fixture.group.parsed, items: [])
        let unrelatedChanges = Mutex(0)
        let tileChanges = Mutex(0)
        withObservationTracking {
            _ = fixture.library.poster(for: other)
            _ = fixture.library.groups
            _ = fixture.library.sorted(.title)
        } onChange: { unrelatedChanges.withLock { $0 += 1 } }
        withObservationTracking {
            _ = fixture.library.poster(for: fixture.group)
        } onChange: { tileChanges.withLock { $0 += 1 } }
        let task = Task { await fixture.resolve() }
        await fixture.details.waitUntilStarted()
        let poster = try await fixture.waitForPoster()
        #expect(unrelatedChanges.withLock { $0 } == 0)
        #expect(tileChanges.withLock { $0 } == 1)
        let finalPosterChanges = Mutex(0)
        withObservationTracking {
            _ = fixture.library.poster(for: fixture.group)
        } onChange: { finalPosterChanges.withLock { $0 += 1 } }
        fixture.library.posterDidLoad(poster)
        await fixture.details.finish()
        await task.value
        #expect(finalPosterChanges.withLock { $0 } == 0)
    }

    @Test func aPosterSubscriberJoiningAPlainLookupReceivesTheAcceptedPoster() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = Task {
            try await fixture.resolver.resolve(fixture.file, tmdbKey: "fixture", omdbKey: "")
        }
        await fixture.details.waitUntilStarted()
        let (posters, sink) = AsyncStream<AppleLibraryMetadataResolver.Poster>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let second = Task {
            try await fixture.resolver.resolve(fixture.file, tmdbKey: "fixture", omdbKey: "", posters: sink)
        }
        let replay = await Task {
            try await appleBoundedMetadataLookup(timeout: .seconds(5)) {
                var iterator = posters.makeAsyncIterator()
                return await iterator.next()
            }
        }.result
        await fixture.details.finish()
        #expect(try await first.value?.mediaID == "tt1234567")
        #expect(try await second.value?.mediaID == "tt1234567")
        #expect(try replay.get()?.url == fixture.searchPoster)
        let (cachedPosters, cachedSink) = AsyncStream<AppleLibraryMetadataResolver.Poster>.makeStream()
        #expect(try await fixture.resolver.resolve(fixture.file, tmdbKey: "fixture", omdbKey: "", posters: cachedSink)?.mediaID == "tt1234567")
        var iterator = cachedPosters.makeAsyncIterator()
        #expect(await iterator.next() == nil)
    }

    @Test func posterDeliveryDoesNotHoldUpTheDetailsRequest() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let (posters, sink) = AsyncStream<AppleLibraryMetadataResolver.Poster>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let task = Task {
            try await fixture.resolver.resolve(fixture.file, tmdbKey: "fixture", omdbKey: "", posters: sink)
        }
        // The main-actor consumer has not started when the details request begins.
        await fixture.details.waitUntilStarted()
        var iterator = posters.makeAsyncIterator()
        #expect(await iterator.next()?.url == fixture.searchPoster)
        await fixture.details.finish()
        #expect(try await task.value?.mediaID == "tt1234567")
        #expect(await iterator.next()?.mediaID == "tt1234567")
        #expect(await iterator.next() == nil)
    }

    @Test func sharedLookupReplaysThePosterAndFinishesACancelledObserversStream() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let (firstPosters, firstSink) = AsyncStream<AppleLibraryMetadataResolver.Poster>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let first = Task {
            try await fixture.resolver.resolve(fixture.file, tmdbKey: "fixture", omdbKey: "", posters: firstSink)
        }
        await fixture.details.waitUntilStarted()
        var firstIterator = firstPosters.makeAsyncIterator()
        #expect(await firstIterator.next()?.url == fixture.searchPoster)
        let (secondPosters, secondSink) = AsyncStream<AppleLibraryMetadataResolver.Poster>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let second = Task {
            try await fixture.resolver.resolve(fixture.file, tmdbKey: "fixture", omdbKey: "", posters: secondSink)
        }
        var secondIterator = secondPosters.makeAsyncIterator()
        #expect(await secondIterator.next()?.url == fixture.searchPoster)
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(await firstIterator.next() == nil)
        await fixture.details.finish()
        #expect(try await second.value?.mediaID == "tt1234567")
        #expect(await secondIterator.next()?.mediaID == "tt1234567")
        #expect(await secondIterator.next() == nil)
    }

    @Test func rejectedSearchResultsDoNotPublishPosters() async throws {
        let client = AppleTMDBClient { request in
            let url = try #require(request.url)
            #expect(url.path.hasPrefix("/3/search/"))
            let body = #"{"results":[{"id":42,"title":"Another Film","release_date":"2024-01-01","poster_path":"/wrong.jpg"}]}"#
            let http = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (Data(body.utf8), http)
        }
        let value = try await client.librarySearch(AppleLibraryTitleParser.parse(name: "Film.2024.mkv"),
            configuration: .init(credential: "fixture"), onPoster: { _ in Issue.record("Rejected poster published") })
        #expect(value == nil)
    }

    @MainActor
    private struct Fixture {
        let root: URL
        let file: AppleLibraryItem
        let group: AppleLibrarySeries
        let details: PosterDetails
        let resolver: AppleLibraryMetadataResolver
        let library: AppleLocalLibraryStore
        let defaults: UserDefaults
        let searchPoster = URL(string: "https://image.tmdb.org/t/p/w500/search.jpg")!
        let fullPoster: URL

        init(series: Bool = false, samePoster: Bool = false, fails: Bool = false, noMatch: Bool = false) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let name = series ? "Film.2024.S01E01.mkv" : "Film.2024.mkv"
            file = AppleLibraryItem(sourceID: UUID(), name: name,
                url: URL(string: "https://fixture.example/Film.mkv")!, relativePath: name, sizeBytes: 1)
            group = try #require(AppleLibrarySeries.groups([file]).first)
            details = PosterDetails(samePoster: samePoster, fails: fails, noMatch: noMatch)
            let probe = details
            resolver = AppleLibraryMetadataResolver(directory: root, tmdbClient: AppleTMDBClient { request in
                try await probe.load(request)
            })
            defaults = try #require(UserDefaults(suiteName: "EarlyPoster-" + root.lastPathComponent))
            library = AppleLocalLibraryStore(resolver: resolver,
                playbackStore: ApplePlaybackStore(defaults: defaults, blobDirectory: root.appendingPathComponent("Playback")), groups: [group],
                versionCacheURL: root.appendingPathComponent("Versions.json"))
            fullPoster = URL(string: "https://image.tmdb.org/t/p/w500/\(samePoster ? "search" : "full").jpg")!
        }

        func resolve(omdbKey: String = "", single: Bool = false) async {
            if single {
                let sources = AppleSourceStore(defaults: defaults, keychain: PosterCredentials(),
                    documentsDirectory: root.appendingPathComponent("Sources"))
                let settings = AppleSettingsStore(defaults: defaults, keychain: PosterCredentials())
                settings.tmdbAPIKey = "fixture"
                settings.omdbAPIKey = omdbKey
                await library.resolve(group, sourceStore: sources, settings: settings)
            } else {
                await library.resolveMetadata([group], tmdbKey: "fixture", omdbKey: omdbKey)
            }
        }

        func waitForPoster() async throws -> AppleLibraryPoster {
            if library.poster(for: group) == nil {
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = library.poster(for: group)
                    } onChange: { continuation.resume() }
                }
            }
            return try #require(library.poster(for: group))
        }

        func writeCache(_ value: AppleCatalogItem, checkedAt: Date) throws {
            struct Entry: Encodable {
                let value: AppleCatalogItem
                let checkedAt: Date
                let addedAt = Date()
                let schema = 3
            }
            let directory = root.appendingPathComponent(file.sourceID.uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(Entry(value: value, checkedAt: checkedAt))
                .write(to: directory.appendingPathComponent(AppleLibraryMetadataResolver.cacheKey(file) + ".json"))
        }

        func remove() {
            defaults.removePersistentDomain(forName: "EarlyPoster-" + root.lastPathComponent)
            try? FileManager.default.removeItem(at: root)
        }
    }
}

private struct PosterCredentials: AppleCredentialStoring {
    func string(for account: String) throws -> String? { nil }
    func set(_ value: String, for account: String) throws {}
    func remove(_ account: String) throws {}
}

private actor PosterDetails {
    let samePoster: Bool
    let fails: Bool
    let noMatch: Bool
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var response: CheckedContinuation<Void, Never>?

    init(samePoster: Bool, fails: Bool, noMatch: Bool) {
        self.samePoster = samePoster
        self.fails = fails
        self.noMatch = noMatch
    }

    func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let url = try #require(request.url)
        let body: String
        if url.path.hasPrefix("/3/search/") {
            body = #"{"results":[{"id":42,"title":"Film","name":"Film","release_date":"2024-01-01","first_air_date":"2024-01-01","poster_path":"/search.jpg","overview":"Sparse search"}]}"#
        } else {
            await withCheckedContinuation { continuation in
                response = continuation
                started = true
                for waiter in startWaiters { waiter.resume() }
                startWaiters = []
            }
            if noMatch { throw AppleTMDBError.titleNotFound }
            if fails { throw URLError(.timedOut) }
            body = #"{"id":42,"title":"Film","name":"Film","release_date":"2024-01-01","first_air_date":"2024-01-01","poster_path":"/\#(samePoster ? "search" : "full").jpg","overview":"Full details","genres":[{"id":1,"name":"Drama"}],"external_ids":{"imdb_id":"tt1234567"}}"#
        }
        let http = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        return (Data(body.utf8), http)
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func finish() {
        response?.resume()
        response = nil
    }
}
