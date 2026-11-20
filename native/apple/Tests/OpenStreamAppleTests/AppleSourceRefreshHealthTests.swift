import Foundation
import Synchronization
import Testing
@testable import OpenStreamApple

@MainActor
@Suite(.serialized) struct AppleSourceRefreshHealthTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let credentials = SourceRefreshCredentials()

    @Test func savedPlaylistFailuresSurviveRelaunchAndEscalateOnTheThirdRefresh() throws {
        let suite = "source-refresh-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = AppleSource(kind: .liveTV, name: "IPTV", url: URL(string: "https://fixture.example/channels.m3u")!)
        defaults.set(try JSONEncoder().encode([source]), forKey: "fixture-sources")
        var store = AppleSourceStore(defaults: defaults, storageKey: "fixture-sources", keychain: credentials)
        let updated = now.addingTimeInterval(-3600)
        store.recordValidationFailure(id: source.id, summary: "Can’t reach IPTV.", at: now.addingTimeInterval(-60))
        store.recordPlaylistRefreshFailure(id: source.id, error: URLError(.timedOut),
            savedAt: updated, at: now)
        var saved = try #require(store.sources.first)
        #expect(!saved.hasCurrentValidationFailure)
        #expect(saved.lastValidatedAt == nil)
        #expect(saved.savedPlaylistHealth?.storedAt == updated)
        #expect(saved.savedPlaylistHealth?.summary.hasPrefix("Showing saved channels · last updated ") == true)
        store = AppleSourceStore(defaults: defaults, storageKey: "fixture-sources", keychain: credentials)
        store.recordPlaylistRefreshFailure(id: source.id, error: URLError(.timedOut), savedAt: updated,
                                           at: now.addingTimeInterval(60))
        #expect(store.sources.first?.hasCurrentValidationFailure == false)
        store.recordPlaylistRefreshFailure(id: source.id, error: URLError(.timedOut), savedAt: updated,
                                           at: now.addingTimeInterval(120))
        saved = try #require(store.sources.first)
        #expect(saved.hasCurrentValidationFailure)
        store.recordValidationSuccess(id: source.id, summary: "Connected · 3 channels", at: now.addingTimeInterval(180))
        #expect(store.sources.first?.savedPlaylistHealth == nil)
        #expect(store.sources.first?.hasCurrentValidationFailure == false)
    }

    @Test func aDayOfFailuresAndAuthenticationErrorsNeedAttention() throws {
        let suite = "source-refresh-expiry-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = AppleSource(kind: .liveTV, name: "IPTV", url: URL(string: "https://fixture.example/channels.m3u")!)
        defaults.set(try JSONEncoder().encode([source]), forKey: "fixture-sources")
        let store = AppleSourceStore(defaults: defaults, storageKey: "fixture-sources", keychain: credentials)
        store.recordPlaylistRefreshFailure(id: source.id, error: URLError(.timedOut), savedAt: now, at: now)
        store.recordPlaylistRefreshFailure(id: source.id, error: URLError(.timedOut), savedAt: now,
                                           at: now.addingTimeInterval(86400))
        #expect(store.sources.first?.hasCurrentValidationFailure == true)
        store.recordValidationSuccess(id: source.id, summary: "Connected", at: now.addingTimeInterval(86401))
        store.recordPlaylistRefreshFailure(id: source.id, error: AppleIPTVError.requestFailed(401),
                                           savedAt: now, at: now.addingTimeInterval(86402))
        #expect(store.sources.first?.hasCurrentValidationFailure == true)
        store.recordValidationSuccess(id: source.id, summary: "Connected", at: now.addingTimeInterval(86403))
        store.recordPlaylistRefreshFailure(id: source.id, error: URLError(.timedOut), savedAt: now,
                                           at: now.addingTimeInterval(86404))
        #expect(store.sources.first?.hasCurrentValidationFailure == false)
        store.recordValidationFailure(id: source.id, summary: "Explicit connection check failed", at: now.addingTimeInterval(86405))
        #expect(store.sources.first?.hasCurrentValidationFailure == true)
    }

    @Test func cancelledRefreshesDoNotCountAndMissingSavedChannelsFailImmediately() throws {
        let suite = "source-refresh-cancellation-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = AppleSource(kind: .liveTV, name: "IPTV", url: URL(string: "https://fixture.example/channels.m3u")!)
        defaults.set(try JSONEncoder().encode([source]), forKey: "fixture-sources")
        let store = AppleSourceStore(defaults: defaults, storageKey: "fixture-sources", keychain: credentials)
        store.recordPlaylistRefreshFailure(id: source.id, error: CancellationError(), savedAt: now, at: now)
        store.recordPlaylistRefreshFailure(id: source.id, error: URLError(.cancelled), savedAt: now, at: now)
        #expect(store.sources.first?.savedPlaylistHealth == nil)
        #expect(store.sources.first?.lastValidationFailureAt == nil)
        store.recordPlaylistRefreshFailure(id: source.id, error: URLError(.timedOut), savedAt: nil, at: now)
        #expect(store.sources.first?.hasCurrentValidationFailure == true)
    }

    @Test func missingCredentialsRequireAttentionEvenWithSavedChannels() throws {
        let suite = "source-refresh-credentials-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = AppleSource(kind: .liveTV, name: "IPTV", url: URL(string: "https://fixture.example")!,
                                 iptvType: .xtream)
        defaults.set(try JSONEncoder().encode([source]), forKey: "fixture-sources")
        let store = AppleSourceStore(defaults: defaults, storageKey: "fixture-sources", keychain: credentials)
        #expect(try store.iptvCredentials(for: source) == nil)
        store.recordPlaylistRefreshFailure(id: source.id, error: AppleIPTVError.missingCredentials,
                                           savedAt: now, at: now)
        #expect(store.sources.first?.hasCurrentValidationFailure == true)
        #expect(store.sources.first?.savedPlaylistHealth?.failureCount == 1)
    }

    @Test func statusKeepsSuccessAndCurrentFailureSeparate() {
        var source = AppleSource(kind: .liveTV, name: "IPTV", url: URL(string: "https://fixture.example")!)
        #expect(source.validationStatus == "Not yet validated")
        source.validationSummary = "Older summary without a success date"
        #expect(source.validationStatus == "Not yet validated")
        source.validationSummary = nil
        source.lastValidatedAt = now
        #expect(source.validationStatus == nil)
        source.validationSummary = "Connected · 3 channels"
        #expect(source.validationStatus == source.validationSummary)
        source.savedPlaylistHealth = .init(firstFailedAt: now, storedAt: now)
        #expect(source.validationStatus == source.savedPlaylistHealth?.summary)
        source.lastValidationFailureAt = now.addingTimeInterval(60)
        source.validationFailureSummary = "Can’t reach IPTV."
        source.savedPlaylistHealth?.requiresAttention = true
        #expect(source.validationStatus == source.validationFailureSummary)
    }

    @Test func reloadingWithoutAStoreKeepsHubValidationAndOneTitleCountingRule() async throws {
        let suite = "media-server-hub-health-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = AppleSource(kind: .mediaServer, name: "Rill", url: URL(string: "https://fixture.example/jf")!,
                                 serverKind: .jellyfin)
        defaults.set(try JSONEncoder().encode([source]), forKey: "fixture-sources")
        let sources = AppleSourceStore(defaults: defaults, storageKey: "fixture-sources", keychain: credentials)
        let session = AppleMediaServerSession(kind: .jellyfin, baseURL: source.url, accessToken: "fixture", userID: "fixture")
        let status = Mutex(200)
        let titles = #"[{"Id":"one","Name":"One","Type":"Movie","Genres":["Drama"]},{"Id":"one","Name":"One","Type":"Movie","Genres":["Drama"]},{"Id":"two","Name":"Two","Type":"Movie","Genres":["Drama"]},{"Id":"folder","Name":"Folder","Type":"Folder"}]"#
        let client = AppleMediaServerClient(loader: { request in
            let url = try #require(request.url)
            let body: String
            if url.path.hasSuffix("Views") {
                body = #"{"Items":[{"Id":"movies","Name":"Movies","CollectionType":"movies"}]}"#
            } else if url.path.hasSuffix("Latest") {
                body = titles
            } else {
                body = "{\"Items\":\(titles),\"TotalRecordCount\":4}"
            }
            return (Data(body.utf8), try #require(HTTPURLResponse(url: url,
                statusCode: status.withLock { $0 }, httpVersion: nil, headerFields: nil)))
        })
        let library = AppleMediaServerLibraryStore(client: client, progressDefaults: defaults)
        await library.reload(sources: [source], sourceStore: sources) { _ in session }
        #expect(sources.sources.first?.validationSummary == "Connected · 2 titles")
        let firstSuccess = try #require(sources.sources.first?.lastValidatedAt)
        await library.reload(sources: [source]) { _ in session }
        #expect(try #require(sources.sources.first?.lastValidatedAt) > firstSuccess)
        let shelf = try #require(library.shelves.first { $0.title == "Drama" })
        status.withLock { $0 = 401 }
        let lastSuccess = sources.sources.first?.lastValidatedAt
        await library.refresh(shelfID: shelf.id)
        #expect(sources.sources.first?.hasCurrentValidationFailure == true)
        #expect(sources.sources.first?.needsSignIn == true)
        #expect(sources.sources.first?.lastValidatedAt == lastSuccess)
        status.withLock { $0 = 200 }
        await library.refresh(shelfID: shelf.id)
        #expect(sources.sources.first?.hasCurrentValidationFailure == false)
        #expect(sources.sources.first?.needsSignIn == false)
        #expect(library.failures[source.id] == nil)
        #expect(sources.sources.first?.discoveredItemCount == 2)
        #expect(sources.sources.first?.validationSummary == "Connected · 2 titles")
        let recovered = AppleSourceStore(defaults: defaults, storageKey: "fixture-sources", keychain: credentials)
        #expect(recovered.sources.first?.needsSignIn == false)
    }

    @Test(arguments: [200, 401, 503, -1001, -999])
    func mediaServerLibraryLoadsRecordTheirConnectionOutcome(status: Int) async throws {
        let suite = "media-server-health-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = AppleSource(kind: .mediaServer, name: "Rill", url: URL(string: "https://fixture.example/jf")!,
                                 serverKind: .jellyfin)
        defaults.set(try JSONEncoder().encode([source]), forKey: "fixture-sources")
        let sources = AppleSourceStore(defaults: defaults, storageKey: "fixture-sources", keychain: credentials)
        let session = AppleMediaServerSession(kind: .jellyfin, baseURL: source.url, accessToken: "fixture", userID: "fixture")
        let client = AppleMediaServerClient(loader: { request in
            if status < 0 { throw URLError(URLError.Code(rawValue: status)) }
            let body: String
            if request.url?.path.hasSuffix("Views") == true {
                body = #"{"Items":[{"Id":"movies","Name":"Movies","CollectionType":"movies"}]}"#
            } else if request.url?.path.hasSuffix("Latest") == true {
                body = #"[{"Id":"one","Name":"One","Type":"Movie"},{"Id":"one","Name":"One","Type":"Movie"}]"#
            } else { body = #"{"Items":[],"TotalRecordCount":0}"# }
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        })
        let library = AppleMediaServerLibraryStore(client: client, progressDefaults: defaults)
        await library.reload(sources: [source], sourceStore: sources) { _ in session }
        let saved = try #require(sources.sources.first)
        if status == 200 {
            #expect(saved.lastValidatedAt != nil)
            #expect(saved.validationSummary == "Connected · 1 title")
            #expect(saved.discoveredItemCount == 1)
            #expect(!saved.hasCurrentValidationFailure)
        } else if status == -999 {
            #expect(saved.lastValidatedAt == nil)
            #expect(saved.lastValidationFailureAt == nil)
            #expect(library.failures.isEmpty)
        } else {
            #expect(saved.hasCurrentValidationFailure)
            #expect(saved.validationFailureSummary == library.failures[source.id])
            #expect(saved.validationFailureSummary?.contains("unexpected") == false)
        }
    }

    @Test(arguments: ["firstLatest", "lastLatest", "Resume", "NextUp", "hub"], [401, 503, -1001])
    func mediaServerRowFailuresKeepSuccessfulLoadsConnected(row: String, status: Int) async throws {
        let suite = "media-server-partial-health-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = AppleSource(kind: .mediaServer, name: "Rill", url: URL(string: "https://fixture.example/jf")!,
                                 serverKind: .jellyfin)
        defaults.set(try JSONEncoder().encode([source]), forKey: "fixture-sources")
        var sources = AppleSourceStore(defaults: defaults, storageKey: "fixture-sources", keychain: credentials)
        sources.recordValidationFailure(id: source.id, summary: "Can't reach the server.", at: now)
        sources = AppleSourceStore(defaults: defaults, storageKey: "fixture-sources", keychain: credentials)
        #expect(sources.sources.first?.hasCurrentValidationFailure == true)
        let session = AppleMediaServerSession(kind: .jellyfin, baseURL: source.url, accessToken: "fixture", userID: "fixture")
        let failHub = Mutex(false)
        let titles = #"[{"Id":"one","Name":"One","Type":"Movie","Genres":["Drama"]},{"Id":"two","Name":"Two","Type":"Movie","Genres":["Drama"]}]"#
        let client = AppleMediaServerClient(loader: { request in
            let url = try #require(request.url)
            let parent = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "ParentId" }?.value
            let fails = (row.hasSuffix("Latest") && url.path.hasSuffix("Latest") && parent == "bad")
                || url.path.hasSuffix(row)
                || (row == "hub" && failHub.withLock { $0 })
            if fails, status < 0 { throw URLError(.timedOut) }
            let body: String
            if url.path.hasSuffix("Views") {
                let good = #"{"Id":"good","Name":"Movies","CollectionType":"movies"}"#
                let bad = #"{"Id":"bad","Name":"Shows","CollectionType":"tvshows"}"#
                body = "{\"Items\":[\(row == "firstLatest" ? bad + "," + good : good + "," + bad)]}"
            } else if url.path.hasSuffix("Latest") { body = titles }
            else { body = #"{"Items":[],"TotalRecordCount":0}"# }
            return (Data(body.utf8), try #require(HTTPURLResponse(url: url,
                statusCode: fails ? status : 200, httpVersion: nil, headerFields: nil)))
        })
        let library = AppleMediaServerLibraryStore(client: client, progressDefaults: defaults)
        await library.reload(sources: [source], sourceStore: sources) { _ in session }
        if row == "hub" {
            let shelf = try #require(library.shelves.first { $0.title == "Drama" })
            failHub.withLock { $0 = true }
            await library.refresh(shelfID: shelf.id)
        }
        let saved = try #require(sources.sources.first)
        if status == 401 {
            #expect(saved.hasCurrentValidationFailure)
            #expect(saved.needsSignIn)
            #expect(saved.validationStatus == AppleMediaServerFormPolicy.message(for: .invalidCredentials))
        } else {
            #expect(saved.hasCurrentValidationFailure == false)
            #expect(saved.needsSignIn == false)
            #expect(saved.validationStatus == "Connected · 2 titles")
            #expect(library.failures[source.id] == nil)
            #expect(library.shelves.contains { $0.title == "Latest in Movies" && $0.items.count == 2 })
            if row.hasSuffix("Latest") {
                #expect(library.shelves.contains { $0.title == "Latest in Shows" } == false)
            }
        }
    }

    @Test(arguments: [AppleMediaServerKind.jellyfin, .emby, .plex], [503, -1001, 401])
    func structuralFailuresAfterARowAnswersPreserveShelvesAndStatus(kind: AppleMediaServerKind, status: Int) async throws {
        let suite = "media-server-structure-health-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = AppleSource(kind: .mediaServer, name: "Fixture", url: URL(string: "https://fixture.example")!,
                                 serverKind: kind)
        defaults.set(try JSONEncoder().encode([source]), forKey: "fixture-sources")
        let sources = AppleSourceStore(defaults: defaults, storageKey: "fixture-sources", keychain: credentials)
        let failStructure = Mutex(true)
        let loader: AppleMediaServerClient.Loader = { request in
            let url = try #require(request.url)
            let structural = url.path.hasSuffix("Views") || url.path.hasSuffix("/library/sections")
            let fails = structural && failStructure.withLock { $0 }
            if fails, status < 0 { throw URLError(.timedOut) }
            let body: String
            if kind == .plex {
                if structural {
                    body = #"{"MediaContainer":{"Directory":[{"key":"1","type":"movie","title":"Movies"}]}}"#
                } else if url.path.hasPrefix("/hubs/") {
                    body = #"{"MediaContainer":{"Hub":[]}}"#
                } else {
                    body = #"{"MediaContainer":{"Metadata":[{"ratingKey":"one","key":"/library/metadata/one","title":"One","type":"movie"}]}}"#
                }
            } else if structural {
                body = #"{"Items":[{"Id":"movies","Name":"Movies","CollectionType":"movies"}]}"#
            } else if url.path.hasSuffix("Latest") {
                body = #"[{"Id":"one","Name":"One","Type":"Movie"}]"#
            } else {
                body = #"{"Items":[],"TotalRecordCount":0}"#
            }
            return (Data(body.utf8), try #require(HTTPURLResponse(url: url,
                statusCode: fails ? status : 200, httpVersion: nil, headerFields: nil)))
        }
        let library = AppleMediaServerLibraryStore(client: .init(loader: loader), plexClient: .init(loader: loader),
                                                   progressDefaults: defaults)
        let session = AppleMediaServerSession(kind: kind, baseURL: source.url, accessToken: "fixture", userID: "fixture")
        await library.reload(sources: [source], sourceStore: sources) { _ in session }
        #expect(library.shelves.isEmpty)
        #expect(sources.sources.first?.lastValidatedAt == nil)
        #expect(sources.sources.first?.hasCurrentValidationFailure == (status == 401))
        #expect(sources.sources.first?.needsSignIn == (status == 401))
        if status != 401 { #expect(library.failures[source.id] == nil) }

        failStructure.withLock { $0 = false }
        await library.reload(sources: [source], sourceStore: sources) { _ in session }
        let loadedShelves = library.shelves
        try #require(loadedShelves.isEmpty == false)
        let lastSuccess = try #require(sources.sources.first?.lastValidatedAt)
        #expect(sources.sources.first?.validationStatus == "Connected · 1 title")
        #expect(sources.sources.first?.needsSignIn == false)
        failStructure.withLock { $0 = true }
        await library.reload(sources: [source], sourceStore: sources) { _ in session }
        #expect(library.shelves == loadedShelves)
        #expect(sources.sources.first?.lastValidatedAt == lastSuccess)
        #expect(sources.sources.first?.hasCurrentValidationFailure == (status == 401))
        #expect(sources.sources.first?.needsSignIn == (status == 401))
        if status != 401 { #expect(library.failures[source.id] == nil) }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [404, 503, -1001, 200])
    func hubFailureDuringReloadDoesNotChangeSourceStatus(status: Int) async throws {
        let suite = "media-server-hub-during-reload-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = AppleSource(kind: .mediaServer, name: "Rill", url: URL(string: "https://fixture.example")!,
                                 serverKind: .jellyfin)
        defaults.set(try JSONEncoder().encode([source]), forKey: "fixture-sources")
        let sources = AppleSourceStore(defaults: defaults, storageKey: "fixture-sources", keychain: credentials)
        let session = AppleMediaServerSession(kind: .jellyfin, baseURL: source.url, accessToken: "fixture", userID: "fixture")
        let reloading = Mutex(false)
        let (resumeStarted, notifyResumeStarted) = AsyncStream<Void>.makeStream()
        let (resumeRelease, releaseResume) = AsyncStream<Void>.makeStream()
        defer { notifyResumeStarted.finish(); releaseResume.finish() }
        let titles = #"[{"Id":"one","Name":"One","Type":"Movie","Genres":["Drama"]},{"Id":"two","Name":"Two","Type":"Movie","Genres":["Drama"]}]"#
        let client = AppleMediaServerClient(loader: { request in
            let url = try #require(request.url)
            let duringReload = reloading.withLock { $0 }
            let isHub = url.path.hasSuffix("Items")
            if duringReload, url.path.hasSuffix("Resume") {
                notifyResumeStarted.yield(())
                for await _ in resumeRelease { break }
            }
            if duringReload, isHub, status < 0 { throw URLError(.timedOut) }
            let body: String
            if url.path.hasSuffix("Views") {
                body = #"{"Items":[{"Id":"movies","Name":"Movies","CollectionType":"movies"}]}"#
            } else if url.path.hasSuffix("Latest") { body = titles }
            else if duringReload, isHub { body = "invalid JSON" }
            else { body = #"{"Items":[],"TotalRecordCount":0}"# }
            return (Data(body.utf8), try #require(HTTPURLResponse(url: url,
                statusCode: duringReload && isHub ? status : 200, httpVersion: nil, headerFields: nil)))
        })
        let library = AppleMediaServerLibraryStore(client: client, progressDefaults: defaults)
        await library.reload(sources: [source], sourceStore: sources) { _ in session }
        let shelf = try #require(library.shelves.first { $0.title == "Drama" })
        let loadedShelves = library.shelves
        let lastSuccess = try #require(sources.sources.first?.lastValidatedAt)
        reloading.withLock { $0 = true }
        let reload = Task { await library.reload(sources: [source], sourceStore: sources) { _ in session } }
        var starts = resumeStarted.makeAsyncIterator()
        _ = await starts.next()
        await library.refresh(shelfID: shelf.id)
        #expect(library.shelves == loadedShelves)
        #expect(sources.sources.first?.lastValidatedAt == lastSuccess)
        #expect(sources.sources.first?.lastValidationFailureAt == nil)
        #expect(sources.sources.first?.needsSignIn == false)
        #expect(library.failures[source.id] == nil)
        releaseResume.yield(())
        await reload.value
        #expect(sources.sources.first?.hasCurrentValidationFailure == false)
        #expect(library.failures[source.id] == nil)
    }

    @Test(arguments: [-1001, 503, 401])
    func failingAllMediaServerRowsRequiresAttention(status: Int) async throws {
        let suite = "media-server-all-rows-health-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = AppleSource(kind: .mediaServer, name: "Rill", url: URL(string: "https://fixture.example/jf")!,
                                 serverKind: .jellyfin)
        defaults.set(try JSONEncoder().encode([source]), forKey: "fixture-sources")
        let sources = AppleSourceStore(defaults: defaults, storageKey: "fixture-sources", keychain: credentials)
        let failRows = Mutex(false)
        let client = AppleMediaServerClient(loader: { request in
            let url = try #require(request.url)
            if url.path.hasSuffix("Views") {
                return (Data(#"{"Items":[{"Id":"movies","Name":"Movies","CollectionType":"movies"}]}"#.utf8),
                        try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
            }
            let fails = failRows.withLock { $0 }
            if fails, status < 0 { throw URLError(.timedOut) }
            let body = url.path.hasSuffix("Latest")
                ? #"[{"Id":"one","Name":"One","Type":"Movie"}]"# : #"{"Items":[],"TotalRecordCount":0}"#
            return (Data(body.utf8), try #require(HTTPURLResponse(url: url,
                statusCode: fails ? status : 200, httpVersion: nil, headerFields: nil)))
        })
        let session = AppleMediaServerSession(kind: .jellyfin, baseURL: source.url, accessToken: "fixture", userID: "fixture")
        let library = AppleMediaServerLibraryStore(client: client, progressDefaults: defaults)
        await library.reload(sources: [source], sourceStore: sources) { _ in session }
        #expect(sources.sources.first?.validationStatus == "Connected · 1 title")
        let loadedShelves = library.shelves
        failRows.withLock { $0 = true }
        await library.reload(sources: [source], sourceStore: sources) { _ in session }
        let saved = try #require(sources.sources.first)
        #expect(saved.hasCurrentValidationFailure)
        #expect(saved.needsSignIn == (status == 401))
        #expect(library.failures[source.id] == saved.validationFailureSummary)
        #expect(library.shelves == loadedShelves)
        if status == -1001 { #expect(saved.validationStatus == "Can't reach the server.") }
    }

    @Test(arguments: ["onDeck", "recentlyAdded", "hubs"], [401, 503, -1001])
    func plexRowFailuresKeepSuccessfulLoadsConnected(row: String, status: Int) async throws {
        let suite = "plex-partial-health-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = AppleSource(kind: .mediaServer, name: "Plex", url: URL(string: "https://fixture.example")!,
                                 serverKind: .plex)
        defaults.set(try JSONEncoder().encode([source]), forKey: "fixture-sources")
        let sources = AppleSourceStore(defaults: defaults, storageKey: "fixture-sources", keychain: credentials)
        let client = ApplePlexClient(loader: { request in
            let url = try #require(request.url)
            let fails = row == "hubs" ? url.path.hasPrefix("/hubs/") : url.path.hasSuffix(row)
            if fails, status < 0 { throw URLError(.timedOut) }
            let body: String
            if url.path == "/library/sections" {
                body = #"{"MediaContainer":{"Directory":[{"key":"1","type":"movie","title":"Movies"}]}}"#
            } else if url.path.hasPrefix("/hubs/") {
                body = #"{"MediaContainer":{"Hub":[]}}"#
            } else {
                body = #"{"MediaContainer":{"Metadata":[{"ratingKey":"one","key":"/library/metadata/one","title":"One","type":"movie"}]}}"#
            }
            return (Data(body.utf8), try #require(HTTPURLResponse(url: url,
                statusCode: fails ? status : 200, httpVersion: nil, headerFields: nil)))
        })
        let library = AppleMediaServerLibraryStore(plexClient: client, progressDefaults: defaults)
        let session = AppleMediaServerSession(kind: .plex, baseURL: source.url, accessToken: "fixture", userID: "fixture")
        await library.reload(sources: [source], sourceStore: sources) { _ in session }
        let saved = try #require(sources.sources.first)
        #expect(saved.hasCurrentValidationFailure == (status == 401))
        #expect(saved.needsSignIn == (status == 401))
        if status != 401 {
            #expect(saved.validationStatus == "Connected · 1 title")
            #expect(library.failures[source.id] == nil)
            if row == "recentlyAdded" { #expect(library.shelves.isEmpty) }
        }
    }

    @Test func missingMediaServerSessionRequiresSignIn() async throws {
        let suite = "media-server-missing-session-health-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = AppleSource(kind: .mediaServer, name: "Rill", url: URL(string: "https://fixture.example/jf")!,
                                 serverKind: .jellyfin)
        defaults.set(try JSONEncoder().encode([source]), forKey: "fixture-sources")
        let sources = AppleSourceStore(defaults: defaults, storageKey: "fixture-sources", keychain: credentials)
        let library = AppleMediaServerLibraryStore(progressDefaults: defaults)
        await library.reload(sources: [source], sourceStore: sources) { _ in nil }
        #expect(sources.sources.first?.needsSignIn == true)
        #expect(sources.sources.first?.hasCurrentValidationFailure == true)
        #expect(library.failures[source.id] != nil)
    }

    @Test(arguments: [AppleMediaServerKind.jellyfin, .emby, .plex])
    func cancellationDoesNotInvalidateAnyServerKind(kind: AppleMediaServerKind) async throws {
        let suite = "media-server-cancel-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = AppleSource(kind: .mediaServer, name: "Fixture", url: URL(string: "https://fixture.example/server")!,
                                 serverKind: kind)
        defaults.set(try JSONEncoder().encode([source]), forKey: "fixture-sources")
        let sources = AppleSourceStore(defaults: defaults, storageKey: "fixture-sources", keychain: credentials)
        let loader: AppleMediaServerClient.Loader = { _ in throw URLError(.cancelled) }
        let library = AppleMediaServerLibraryStore(client: .init(loader: loader), plexClient: .init(loader: loader),
                                                   progressDefaults: defaults)
        let session = AppleMediaServerSession(kind: kind, baseURL: source.url, accessToken: "fixture", userID: "fixture")
        await library.reload(sources: [source], sourceStore: sources) { _ in session }
        #expect(sources.sources.first?.lastValidationFailureAt == nil)
        #expect(library.failures.isEmpty)
        #expect(!library.isLoading)
    }
}

private final class SourceRefreshCredentials: AppleCredentialStoring {
    private var values: [String: String] = [:]
    func string(for account: String) throws -> String? { values[account] }
    func set(_ value: String, for account: String) throws { values[account] = value }
    func remove(_ account: String) throws { values[account] = nil }
}
