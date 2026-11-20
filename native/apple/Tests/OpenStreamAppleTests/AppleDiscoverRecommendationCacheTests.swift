import Foundation
import Testing
@testable import OpenStreamApple

@Suite("Discover recommendation persistence")
struct AppleDiscoverRecommendationCacheTests {
    @Test func restoresDeckAndRowsWithCurrentSources() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = AppleMetadataDiskCache(directory: directory)
        let source = source()
        let item = AppleCatalogItem(mediaID: "tt1234567", type: "movie", name: "Movie",
            backgroundURL: URL(string: "https://fixture.example/backdrop.jpg"))
        let record = AppleMediaRecord(canonicalID: item.mediaID, kind: .movie, title: item.name,
            availability: [.init(instanceID: source.id, capability: .resolvable, itemReference: "movie|tt1234567")])
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let value = AppleDiscoverView.IndexedCatalogItem(record: record, item: item, source: source,
            continueWatchingUpdatedAt: date)
        let result = AppleDiscoverView.RecommendationResult(continueWatching: [value],
            heroes: [value], seedRows: [.init(heading: "Because You Watched Movie", items: [value])],
            featuredMovies: [value], featuredShows: [])
        let key = try #require(AppleDiscoverRecommendationCache.key(scope: "viewer", state: .init()))
        #expect(await AppleDiscoverRecommendationCache.restore(key, sources: [source], cache: cache) == nil)
        await AppleDiscoverRecommendationCache.store(result, key: key, favoriteIDs: [record.id], cache: cache)
        await AppleDiscoverRecommendationCache.store(.init(), key: key, favoriteIDs: [], cache: cache)
        var current = source
        current.name = "Current Source"
        let restored = try #require(await AppleDiscoverRecommendationCache.restore(key, sources: [current], cache: cache))
        #expect(restored.heroes.map(\.id) == [record.id])
        #expect(restored.featuredMovies.map(\.id) == [record.id])
        #expect(restored.featuredShows.isEmpty)
        #expect(restored.continueWatching.first?.continueWatchingUpdatedAt == date)
        #expect(restored.seedRows.map(\.heading) == ["Because You Watched Movie"])
        #expect(restored.seedRows.map(\.minimumCount) == [8])
        #expect(restored.seedRows.map { $0.items.map(\.id) } == [[record.id]])
        #expect(restored.heroes.first?.source.name == "Current Source")
        #expect(restored.heroes.first?.record.isFavorite == true)
        #expect(restored.continueWatching.first?.record.isFavorite == true)
        current.isEnabled = false
        #expect(await AppleDiscoverRecommendationCache.restore(key, sources: [current], cache: cache) == nil)
        #expect(await AppleDiscoverRecommendationCache.restore(key, sources: [], cache: cache) == nil)
        let changed = try #require(AppleDiscoverRecommendationCache.key(scope: "viewer",
            state: .init(removed: [record.id: date])))
        #expect(await AppleDiscoverRecommendationCache.restore(changed, sources: [source], cache: cache) == nil)
        let entry = try #require(await cache.entry(source: key.scope, type: AppleDiscoverRecommendationCache.entryType,
            mediaID: "recommendations"))
        var emptyDeck = try #require(JSONSerialization.jsonObject(with: entry.payload) as? [String: Any])
        emptyDeck["heroes"] = []
        await cache.store(try JSONSerialization.data(withJSONObject: emptyDeck), source: key.scope,
            type: AppleDiscoverRecommendationCache.entryType, mediaID: "recommendations")
        #expect(await AppleDiscoverRecommendationCache.restore(key, sources: [source], cache: cache) == nil)

    }

    @Test(arguments: ["discover-v5", "discover-v6", "discover-v8"])
    func previousLaneCacheCannotRestoreTheMergedAnswer(legacyType: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = AppleMetadataDiskCache(directory: directory)
        let key = try #require(AppleDiscoverRecommendationCache.key(scope: "viewer", state: .init()))
        let source = source()
        let item = AppleCatalogItem(mediaID: "tt1234567", type: "movie", name: "Movie")
        let value = AppleDiscoverView.IndexedCatalogItem(
            record: AppleMediaIngestion.catalogRecord(instanceID: source.id, item: item), item: item, source: source)
        await AppleDiscoverRecommendationCache.store(.init(heroes: [value]), key: key, favoriteIDs: [], cache: cache)
        let entry = try #require(await cache.entry(source: key.scope, type: AppleDiscoverRecommendationCache.entryType,
            mediaID: "recommendations"))
        let legacyCache = AppleMetadataDiskCache(directory: directory.appending(path: "legacy"))
        await legacyCache.store(entry.payload, source: key.scope, type: legacyType, mediaID: "recommendations")
        #expect(await AppleDiscoverRecommendationCache.restore(key, sources: [source], cache: legacyCache) == nil)
    }

    @Test func watchAndViewerChangesInvalidateSavedResult() async throws {
        let original = try #require(AppleDiscoverRecommendationCache.key(scope: "viewer", state: .init()))
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let progress = ApplePlaybackProgress(position: 100, duration: 1000, updatedAt: date)
        let changes: [AppleDiscoverRecommendationCache.WatchState] = [
            .init(progress: ["title": progress]), .init(activity: ["title": progress]),
            .init(completed: ["title": date]), .init(unwatched: ["title": date]),
            .init(removed: ["title": date]), .init(ratings: ["title": AppleTitleRating.down.rawValue])
        ]
        for state in changes {
            #expect(AppleDiscoverRecommendationCache.key(scope: "viewer", state: state) != original)
        }
        #expect(AppleDiscoverRecommendationCache.key(scope: "other viewer", state: .init()) != original)
    }

    @Test func invalidPayloadIsAMiss() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = AppleMetadataDiskCache(directory: directory)
        let key = try #require(AppleDiscoverRecommendationCache.key(scope: "viewer", state: .init()))
        await cache.store(Data("invalid".utf8), source: key.scope, type: "discover-v1", mediaID: "recommendations")
        #expect(await AppleDiscoverRecommendationCache.restore(key, sources: [source()], cache: cache) == nil)
    }

    @Test(arguments: [false, true])
    func cachedCatalogRemainsVisibleWhileRecommendationsPrepare(isLoading: Bool) {
        #expect(!AppleDiscoverView.showsLoadingContent(hasContent: true, isLoading: isLoading))
    }

    @Test(arguments: [false, true])
    func onlyAnEmptyLoadingPageShowsTheSkeleton(isLoading: Bool) {
        #expect(AppleDiscoverView.showsLoadingContent(hasContent: false, isLoading: isLoading) == isLoading)
    }

    @Test func launchHoldShowsNothingPartialBeforeTheSavedDeck() {
        // Within the hold nothing shows, so the stored Top 10 cannot show alone;
        // the restored deck builds hidden while its art loads.
        #expect(AppleDiscoverLaunchHold.content(.restoring) == .blank)
        #expect(AppleDiscoverLaunchHold.content(.warmingHero) == .hidden)
        #expect(AppleDiscoverLaunchHold.content(.released) == .page)
    }

    @Test func launchNeverReleasesWhileHeroWordmarkOrVisiblePostersAreStillLoading() {
        #expect(AppleDiscoverLaunchReadiness.decision(artwork: [nil, true], wordmark: true, hasWordmark: true, timedOut: false) == .waiting)
        #expect(AppleDiscoverLaunchReadiness.decision(artwork: [true, nil], wordmark: true, hasWordmark: true, timedOut: false) == .waiting)
        #expect(AppleDiscoverLaunchReadiness.decision(artwork: [true, true], wordmark: nil, hasWordmark: true, timedOut: false) == .waiting)
        #expect(AppleDiscoverLaunchReadiness.decision(artwork: [true, true], wordmark: true, hasWordmark: true, timedOut: false) == .ready)
        #expect(AppleDiscoverLaunchReadiness.decision(artwork: [true], wordmark: nil, hasWordmark: false, timedOut: false) == .ready)
        #expect(AppleDiscoverLaunchReadiness.decision(artwork: [true], wordmark: nil, hasWordmark: false, lookupPending: true, timedOut: false) == .waiting)
    }

    @Test func launchFailureWaitsForOtherVisibleAssetsAndEventuallyUsesTheCompleteFallback() {
        #expect(AppleDiscoverLaunchReadiness.decision(artwork: [false, nil], wordmark: false, hasWordmark: true, timedOut: false) == .waiting)
        #expect(AppleDiscoverLaunchReadiness.decision(artwork: [false, true], wordmark: false, hasWordmark: true, timedOut: false) == .failed)
        #expect(AppleDiscoverLaunchReadiness.decision(artwork: [nil, true], wordmark: nil, hasWordmark: true, timedOut: true) == .failed)
    }

    @Test func launchRemembersTheHeroStillItReadsBackNextTime() throws {
        let defaults = try #require(UserDefaults(suiteName: "launch-hero-still-\(UUID())"))
        #expect(AppleLaunchHeroStill.saved(defaults: defaults) == nil)
        let still = AppleArtworkPrefetchPolicy.Request(url: try #require(URL(string: "https://fixture.example/hero.jpg")),
                                                       maximumPixelDimension: 1280)
        AppleLaunchHeroStill.remember(still, defaults: defaults)
        #expect(AppleLaunchHeroStill.saved(defaults: defaults) == still)
    }

    @Test func initialRecommendationsSurviveCatalogRefreshButNotViewerChangesOrAnExistingHero() {
        #expect(AppleDiscoverView.canPublishRecommendations(requestedRevision: "catalog-1", currentRevision: "catalog-2",
            initialContext: "sources-1|watch-1", currentContext: "sources-1|watch-1", hasHeroes: false))
        #expect(!AppleDiscoverView.canPublishRecommendations(requestedRevision: "catalog-1", currentRevision: "catalog-2",
            initialContext: "sources-1|watch-1", currentContext: "sources-2|watch-1", hasHeroes: false))
        #expect(!AppleDiscoverView.canPublishRecommendations(requestedRevision: "catalog-1", currentRevision: "catalog-2",
            initialContext: "sources-1|watch-1", currentContext: "sources-1|watch-2", hasHeroes: false))
        #expect(!AppleDiscoverView.canPublishRecommendations(requestedRevision: "catalog-1", currentRevision: "catalog-2",
            initialContext: "sources-1|watch-1", currentContext: "sources-1|watch-1", hasHeroes: true))
        #expect(!AppleDiscoverView.canPublishRecommendations(requestedRevision: "catalog-1", currentRevision: "catalog-2",
            initialContext: nil, currentContext: "sources-1|watch-1", hasHeroes: false))
        #expect(AppleDiscoverView.canPublishRecommendations(requestedRevision: "catalog-2", currentRevision: "catalog-2",
            initialContext: nil, currentContext: "sources-1|watch-1", hasHeroes: true))
    }

    @Test func firstDeckRetryUsesTheNewViewerContextAndStillSurvivesCatalogArrivals() {
        let abandoned = "sources-1|watch-1"
        let retry = "sources-2|watch-2"
        #expect(!AppleDiscoverView.canPublishRecommendations(requestedRevision: "catalog-1", currentRevision: "catalog-3",
            initialContext: abandoned, currentContext: retry, hasHeroes: false))
        #expect(AppleDiscoverView.canPublishRecommendations(requestedRevision: "catalog-2", currentRevision: "catalog-3",
            initialContext: retry, currentContext: retry, hasHeroes: false))
        #expect(!AppleDiscoverView.canPublishRecommendations(requestedRevision: "catalog-2", currentRevision: "catalog-3",
            initialContext: retry, currentContext: retry, hasHeroes: true))
    }

    @Test func initialDeckCanBeSavedAfterCatalogArrivalsButNeverAfterReplacementOrViewerChanges() {
        #expect(AppleDiscoverView.canPersistRecommendations(requestedRevision: "catalog-1", currentRevision: "catalog-2",
            publishedRevision: "catalog-1", initialContext: "viewer-1", currentContext: "viewer-1"))
        #expect(!AppleDiscoverView.canPersistRecommendations(requestedRevision: "catalog-1", currentRevision: "catalog-2",
            publishedRevision: "catalog-2", initialContext: "viewer-1", currentContext: "viewer-1"))
        #expect(!AppleDiscoverView.canPersistRecommendations(requestedRevision: "catalog-1", currentRevision: "catalog-2",
            publishedRevision: "catalog-1", initialContext: "viewer-1", currentContext: "viewer-2"))
        #expect(!AppleDiscoverView.canPersistRecommendations(requestedRevision: "catalog-1", currentRevision: "catalog-2",
            publishedRevision: "catalog-1", initialContext: nil, currentContext: "viewer-1"))
        #expect(AppleDiscoverView.canPersistRecommendations(requestedRevision: "catalog-2", currentRevision: "catalog-2",
            publishedRevision: "catalog-2", initialContext: nil, currentContext: "viewer-1"))
    }

    private func source() -> AppleSource {
        AppleSource(kind: .liveTV, name: "Fixture", url: URL(string: "https://fixture.example/playlist.m3u")!,
            iptvType: .m3u)
    }
}
