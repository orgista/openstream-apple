import Foundation
import Testing
@testable import OpenStreamApple

struct AppleDiscoverOwnedHeroTests {
    private func source(_ kind: AppleSourceKind = .mediaServer) throws -> AppleSource {
        AppleSource(kind: kind, name: "Fixture", url: try #require(URL(string: "https://fixture.example")))
    }

    private func item(_ id: String) -> AppleCatalogItem {
        AppleCatalogItem(mediaID: id, type: "movie", name: "Fixture Movie",
            backgroundURL: URL(string: "https://fixture.example/backdrop.jpg"))
    }

    private func snapshot(sources: [AppleSource], serverShelves: [AppleMediaServerLibraryStore.Shelf] = []) -> AppleDiscoverView.RecommendationSnapshot {
        .init(relations: [], sources: sources, records: [], progress: [:], activity: [:],
            completed: [:], unwatched: [:], removed: [:], ratings: [:], serverContinueWatching: [],
            serverShelves: serverShelves, artwork: [:], debugHeroTitle: nil, now: Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test func serverOnlySetupNeedsNoIndexedHistoryOrMetadataKey() async throws {
        let server = try source()
        let movie = item(AppleMediaServerItemReference(sourceID: server.id, itemID: "movie").mediaID)
        let input = AppleDiscoverView.RecommendationSnapshot(relations: [], sources: [server], records: [],
            progress: [:], activity: [:], completed: [:], unwatched: [:], removed: [:], ratings: [:],
            serverContinueWatching: [], serverShelves: [.init(id: "latest", title: "Latest", sourceID: server.id, items: [movie])],
            artwork: [:], debugHeroTitle: nil, now: .now)
        let result = try await AppleDiscoverView.buildRecommendations(input)
        #expect(result.heroes.map(\.item.mediaID) == [movie.mediaID])
        #expect(result.heroes.first?.source.id == server.id)
    }

    @Test func serverOnlyLibraryNeedsNoShelvesOrIndexHistory() async throws {
        let server = try source()
        let movie = item(AppleMediaServerItemReference(sourceID: server.id, itemID: "movie").mediaID)
        let value = AppleDiscoverView.IndexedCatalogItem(
            record: AppleMediaIngestion.catalogRecord(instanceID: server.id, item: movie), item: movie, source: server)
        var input = snapshot(sources: [server])
        input.localItems = [value]
        let result = try await AppleDiscoverView.buildRecommendations(input)
        #expect(result.heroes.map(\.id) == [value.id])
        #expect(result.heroes.first?.source.id == server.id)
    }

    @Test func libraryArtworkCanFillDiscoverWithoutServerShelves() async throws {
        let share = try source(.nas)
        let movie = item("tt0000001")
        let value = AppleDiscoverView.IndexedCatalogItem(
            record: AppleMediaIngestion.catalogRecord(instanceID: share.id, item: movie), item: movie, source: share)
        var input = snapshot(sources: [share])
        input.localItems = [value]
        let result = try await AppleDiscoverView.buildRecommendations(input)
        #expect(result.heroes.map(\.id) == [value.id])
        input = snapshot(sources: [])
        input.localItems = [value]
        #expect(try await AppleDiscoverView.buildRecommendations(input).heroes.isEmpty)
    }

    @Test func trendingSuppliesMetadataPagesWithoutInventingASource() async throws {
        let movie = item("tt0000002")
        var input = snapshot(sources: [try source()])
        input.trending = [movie]
        let result = try await AppleDiscoverView.buildRecommendations(input)
        let hero = try #require(result.heroes.first)
        #expect(hero.item.mediaID == movie.mediaID)
        #expect(hero.source.id == AppleMediaAvailability.metadataOnlyInstanceID)
    }

    @Test func trendingNeedsAnEnabledOwnedSource() async throws {
        var input = snapshot(sources: [])
        input.trending = [item("tt0000002")]
        #expect(try await AppleDiscoverView.buildRecommendations(input).heroes.isEmpty)
        var disabled = try source()
        disabled.isEnabled = false
        input = snapshot(sources: [disabled])
        input.trending = [item("tt0000002")]
        #expect(try await AppleDiscoverView.buildRecommendations(input).heroes.isEmpty)
    }

    @Test func ownedRouteWinsOverDuplicateTrendingMetadata() async throws {
        let server = try source()
        let movie = AppleCatalogItem(mediaID: AppleMediaServerItemReference(sourceID: server.id, itemID: "movie").mediaID,
            type: "movie", name: "Fixture Movie", backgroundURL: URL(string: "https://fixture.example/backdrop.jpg"),
            imdbID: "tt0000002")
        var input = snapshot(sources: [server])
        input.localItems = [.init(record: AppleMediaIngestion.catalogRecord(instanceID: server.id, item: movie), item: movie, source: server)]
        input.trending = [item("tt0000002")]
        let result = try await AppleDiscoverView.buildRecommendations(input)
        #expect(result.heroes.count == 1)
        #expect(result.heroes.first?.source.id == server.id)
    }

    @Test(arguments: [nil, "tt0000002"] as [String?], ["fixture-trending", "tmdb:movie:42"])
    func ownedTitlesDedupeAcrossCanonicalIDsByNormalizedTitleAndYear(imdbID: String?, trendingID: String) async throws {
        let server = try source()
        let owned = AppleCatalogItem(mediaID: AppleMediaServerItemReference(sourceID: server.id, itemID: "movie").mediaID,
            type: "movie", name: "  FÍXTURE   Movie ", backgroundURL: URL(string: "https://fixture.example/backdrop.jpg"),
            year: 2024, imdbID: imdbID)
        let trending = AppleCatalogItem(mediaID: trendingID, type: "movie", name: "fixture movie",
            backgroundURL: URL(string: "https://fixture.example/backdrop.jpg"), year: 2024)
        var input = snapshot(sources: [server])
        input.localItems = [.init(record: AppleMediaIngestion.catalogRecord(instanceID: server.id, item: owned),
            item: owned, source: server)]
        input.trending = [trending]
        let result = try await AppleDiscoverView.buildRecommendations(input)
        #expect(result.heroes.count == 1)
        #expect(result.heroes.first?.source.id == server.id)
    }

    @Test func serverShelfAndLibraryShareOneHeroAndPlaybackRoute() async throws {
        let server = try source()
        let movie = item(AppleMediaServerItemReference(sourceID: server.id, itemID: "movie").mediaID)
        let value = AppleDiscoverView.IndexedCatalogItem(
            record: AppleMediaIngestion.catalogRecord(instanceID: server.id, item: movie), item: movie, source: server)
        var input = snapshot(sources: [server],
            serverShelves: [.init(id: "latest", title: "Latest", sourceID: server.id, items: [movie])])
        input.localItems = [value]
        let result = try await AppleDiscoverView.buildRecommendations(input)
        #expect(result.heroes.map(\.id) == [value.id])
        #expect(result.heroes.first?.record.availability.count == 1)
    }

    @Test(arguments: [2023, nil])
    func matchingNamesWithDifferentOrMissingYearsRemainSeparate(year: Int?) async throws {
        let server = try source()
        let owned = AppleCatalogItem(mediaID: AppleMediaServerItemReference(sourceID: server.id, itemID: "movie").mediaID,
            type: "movie", name: "Fixture Movie", backgroundURL: URL(string: "https://fixture.example/backdrop.jpg"), year: 2024)
        let trending = AppleCatalogItem(mediaID: "tmdb:movie:42", type: "movie", name: "Fixture Movie",
            backgroundURL: URL(string: "https://fixture.example/backdrop.jpg"), year: year)
        var input = snapshot(sources: [server])
        input.localItems = [.init(record: AppleMediaIngestion.catalogRecord(instanceID: server.id, item: owned),
            item: owned, source: server)]
        input.trending = [trending]
        #expect(try await AppleDiscoverView.buildRecommendations(input).heroes.count == 2)
    }

    @Test func trendingHeroRestoresFromTheRecommendationCache() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = AppleMetadataDiskCache(directory: directory)
        let server = try source()
        var input = snapshot(sources: [server])
        input.trending = [item("tt0000002")]
        let result = try await AppleDiscoverView.buildRecommendations(input)
        let configuration = try AppleTMDBConfiguration(credential: "fixture-key")
        let scope = AppleDiscoverRecommendationCache.scope(sourceIdentity: "fixture", namespace: "viewer",
            metadataConfiguration: configuration, top10ListsEnabled: true, heroTitle: "")
        let key = try #require(AppleDiscoverRecommendationCache.key(scope: scope, state: .init()))
        await AppleDiscoverRecommendationCache.store(result, key: key, favoriteIDs: [], cache: cache)
        let restored = try #require(await AppleDiscoverRecommendationCache.restore(key, sources: [server], cache: cache))
        #expect(restored.heroes.map(\.item.mediaID) == ["tt0000002"])
        #expect(await AppleDiscoverRecommendationCache.restore(key, sources: [], cache: cache) == nil)
        let changes: [(AppleTMDBConfiguration?, Bool)] = [(nil, true), (configuration, false)]
        for (metadata, enabled) in changes {
            let changedScope = AppleDiscoverRecommendationCache.scope(sourceIdentity: "fixture", namespace: "viewer",
                metadataConfiguration: metadata, top10ListsEnabled: enabled, heroTitle: "")
            let changed = try #require(AppleDiscoverRecommendationCache.key(scope: changedScope, state: .init()))
            #expect(await AppleDiscoverRecommendationCache.restore(changed, sources: [server], cache: cache) == nil)
        }
    }
}
