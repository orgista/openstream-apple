import Foundation
import Testing
@testable import OpenStreamApple

struct AppleHomeFixTests {
    @Test func heroPersonalizationUsesHistoryEvenBelowTheRowThreshold() async throws {
        let source = AppleSource(kind: .library, name: "Fixture", url: URL(fileURLWithPath: "/fixture"))
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let values = (0..<9).map { index in
            let item = AppleCatalogItem(mediaID: "tt\(String(format: "%07d", index + 1))", type: "movie", name: "Title \(index)",
                backgroundURL: URL(string: "https://fixture.example/backdrop.jpg"), genres: [index < 5 ? "Horror" : "Drama"])
            return AppleDiscoverView.IndexedCatalogItem(record: AppleMediaIngestion.catalogRecord(instanceID: source.id, item: item),
                item: item, source: source)
        }
        let seed = try #require(values.last)
        let input = AppleDiscoverView.RecommendationSnapshot(relations: [], sources: [source], records: [seed.record],
            progress: [:], activity: [:], completed: [try #require(ApplePlaybackIdentity.storageKey(for: seed.record.id)): now],
            unwatched: [:], removed: [:], ratings: [:], serverContinueWatching: [], serverShelves: [], artwork: [:],
            debugHeroTitle: nil, now: now, localItems: values, libraryItems: values)
        let result = try await AppleDiscoverView.buildRecommendations(input)
        #expect(result.heroes.prefix(2).allSatisfy { $0.item.genres == ["Drama"] && $0.id != seed.id })
        #expect(result.heroes.count == AppleHeroRotation.maximumCandidates)
        #expect(result.seedRows.isEmpty)
    }

    @Test func onlyMatchedLibraryTitlesWithArtworkFeedRecommendations() async throws {
        let source = AppleSource(kind: .nas, name: "Fixture", url: try #require(URL(string: "smb://fixture.example/Media")))
        let files = ["Alpha.2020.mkv", "Beta.2021.mkv", "Gamma.2022.mkv"].map {
            AppleLibraryItem(sourceID: source.id, name: $0, url: URL(fileURLWithPath: "/fixture/\($0)"),
                             relativePath: $0, sizeBytes: 1)
        }
        let groups = AppleLibrarySeries.groups(files).sorted { $0.parsed.title < $1.parsed.title }
        let first = try #require(groups.first)
        let second = try #require(groups.dropFirst().first)
        let match = AppleCatalogItem(mediaID: "tt1234567", type: "movie", name: first.parsed.title,
            posterURL: URL(string: "https://fixture.example/poster.jpg"))
        let artless = AppleCatalogItem(mediaID: "tt7654321", type: "movie", name: second.parsed.title)
        let empty = try await AppleDiscoverView.libraryRecommendationItems(.init(groups: groups, metadata: [:], sources: [source], offlineIDs: [:]))
        #expect(empty.ranked.isEmpty)
        let result = try await AppleDiscoverView.libraryRecommendationItems(.init(groups: groups,
            metadata: [first.id: match, second.id: artless], sources: [source], offlineIDs: [:]))
        #expect(result.ranked.map(\.item.mediaID) == [match.mediaID])
        #expect(result.ranked.flatMap(\.progressKeys).count == first.items.count)
    }

    @Test func identicalRelationsDoNotInvalidateRecommendationsOnEachHeroTurn() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = AppleTMDBRelationCache(cache: AppleMetadataDiskCache(directory: root))
        let config = try AppleTMDBConfiguration(credential: "fixture-key")
        let target = AppleTMDBRelation.Target(id: 42, type: "movie", title: "Fixture", year: 2020, origin: .similar)
        await cache.store(.init(seedID: "tt1234567", type: "movie", targets: [target], storedAt: .now), configuration: config)
        let revision = AppleTMDBRelationCache.revision
        for tick in 1...5 {
            await cache.store(.init(seedID: "tt1234567", type: "movie", targets: [target],
                storedAt: Date.now.addingTimeInterval(Double(tick) * 6)), configuration: config)
        }
        #expect(AppleTMDBRelationCache.revision == revision)
        await cache.store(.init(seedID: "tt1234567", type: "movie", targets: [], storedAt: .now), configuration: config)
        #expect(AppleTMDBRelationCache.revision == revision + 1)
    }

    @Test func heroArtworkRefreshesTheLivePageWithoutChangingSelection() throws {
        let item = AppleCatalogItem(mediaID: "tt1234567", type: "movie", name: "Fixture",
            backgroundURL: URL(string: "https://fixture.example/original.jpg"))
        let backdrop = try #require(URL(string: "https://fixture.example/textless.jpg"))
        let logo = try #require(URL(string: "https://fixture.example/logo.png"))
        let original = AppleDiscoverView.heroItem(item, artwork: [:])
        let upgraded = AppleDiscoverView.heroItem(item, artwork: [item.mediaID: .init(backdropURL: backdrop, logoURL: logo)])
        #expect(upgraded.id == original.id)
        #expect(upgraded.backgroundURL == backdrop)
        #expect(upgraded.logoURL == logo)
        let before = AppleHeroPageArt(id: original.id, backdrop: original.backgroundURL, wordmark: original.logoURL)
        let after = AppleHeroPageArt(id: upgraded.id, backdrop: upgraded.backgroundURL, wordmark: upgraded.logoURL)
        #expect(before.key != after.key)
    }

    @Test func artworkFailuresOnlyTriggerOneMetadataFallback() {
        var lookup = AppleCatalogArtworkPolicy.Lookup()
        #expect(lookup.attempt == 0)
        #expect(lookup.completedAttempt == nil)
        lookup.complete(attempt: 0)
        for _ in 0..<10 { lookup.suppliedArtworkFailed() }
        #expect(lookup.attempt == 1)
        lookup.complete(attempt: 1)
        for _ in 0..<10 { lookup.suppliedArtworkFailed() }
        #expect(lookup.attempt == 1)
        #expect(lookup.completedAttempt == lookup.attempt)
        lookup = .init()
        #expect(lookup.attempt == 0)
        #expect(lookup.completedAttempt == nil)
        lookup = .init(suppliedArtworkFailed: true)
        #expect(lookup.attempt == 1)
        #expect(lookup.completedAttempt == nil)
    }

    @Test func heroKeepsAUsableDetailsActionWhenTheLibraryNeverLoads() {
        let waiting = AppleTitlePagePolicy.HeroButtonSelection(page: "movie", action: nil).button
        #expect(waiting.title == "Details")
        #expect(waiting.systemImage == "info.circle")
        #expect(waiting.isHidden == false)
        #expect(waiting.action == .details)
        #expect(AppleTitlePagePolicy.heroPrimaryAction(type: "movie", progress: nil, selectedEpisode: nil,
            isPlayable: false, trailer: .none, playabilityKnown: false) == nil)
        #expect(AppleTitlePagePolicy.heroPrimaryAction(type: "movie", progress: nil, selectedEpisode: nil,
            isPlayable: true, trailer: .none, playabilityKnown: false) == .play)
        #expect(AppleTitlePagePolicy.heroPrimaryAction(type: "movie", progress: nil, selectedEpisode: nil,
            isPlayable: false, trailer: .none, playabilityKnown: true) == .details)
    }

    @Test func returningFromBackgroundOrContinueDiscardsAnInterruptedFade() {
        var fade = AppleHeroPageSwap.FadeVisit()
        fade.update(isActive: true, isCovered: false, routeRevision: 0)
        let initial = fade.revision
        fade.update(isActive: false, isCovered: false, routeRevision: 0)
        fade.update(isActive: true, isCovered: false, routeRevision: 0)
        #expect(fade.revision == initial + 1)
        fade.update(isActive: true, isCovered: false, routeRevision: 1)
        #expect(fade.revision == initial + 2)
        fade.update(isActive: true, isCovered: false, routeRevision: 1)
        #expect(fade.revision == initial + 2)
        fade.update(isActive: true, isCovered: true, routeRevision: 1)
        fade.update(isActive: true, isCovered: false, routeRevision: 1)
        #expect(fade.revision == initial + 3)
    }

    @Test func shortSyncedHistoryWithoutALocalSourceDoesNotGenerateRows() async throws {
        let source = AppleSource(kind: .nas, name: "Fixture", url: try #require(URL(string: "smb://fixture.example/Media")))
        let stamp = Date.now
        let seed = AppleCatalogItem(mediaID: "tt1234567", type: "movie", name: "Seed", genres: ["Drama"])
        let values = ([seed] + (0..<12).map {
            AppleCatalogItem(mediaID: "tt20000\(String(format: "%02d", $0))", type: "movie", name: "Pick \($0)", genres: ["Drama"])
        }).map { item in
            AppleDiscoverView.IndexedCatalogItem(record: AppleMediaIngestion.catalogRecord(instanceID: source.id, item: item),
                item: item, source: source)
        }
        let history = AppleMediaRecord(canonicalID: seed.mediaID, kind: .movie, title: seed.name,
            availability: [.init(instanceID: UUID(), capability: .resolvable, itemReference: seed.mediaID)], progress: 1)
        let key = try #require(ApplePlaybackIdentity.storageKey(for: history.id))
        let input = AppleDiscoverView.RecommendationSnapshot(relations: [], sources: [source], records: [history],
            progress: [:], activity: [key: .init(position: 1000, duration: 1000, updatedAt: stamp)],
            completed: [:], unwatched: [:], removed: [:], ratings: [:], serverContinueWatching: [],
            serverShelves: [], artwork: [:], debugHeroTitle: nil, now: stamp, libraryItems: values)
        let result = try await AppleDiscoverView.buildRecommendations(input)
        #expect(result.seedRows.isEmpty)
    }

    @MainActor @Test func browsingCoordinatorDoesNotWarmTheDemuxingEngine() {
        let coordinator = ApplePlaybackCoordinator.forBrowsing()
        #expect(coordinator.engine.kind == .native)
        #expect(coordinator.phase == .idle)
        coordinator.beginResolving()
        #expect(coordinator.phase == .resolving)
        coordinator.reset()
        #expect(coordinator.phase == .idle)
    }

    @Test func aSingleSyncedCompletionDoesNotGenerateRowsForARemovedSource() async throws {
        let source = AppleSource(kind: .nas, name: "Fixture", url: try #require(URL(string: "smb://fixture.example/Media")))
        let values = (0..<8).map { index in
            let item = AppleCatalogItem(mediaID: "tt30000\(String(format: "%02d", index))", type: "movie",
                name: "Related \(index)", year: 2024)
            return AppleDiscoverView.IndexedCatalogItem(record: AppleMediaIngestion.catalogRecord(instanceID: source.id, item: item),
                item: item, source: source)
        }
        let history = AppleMediaRecord(canonicalID: "tt1234567", kind: .movie, title: "Watched Seed",
            availability: [.init(instanceID: UUID(), capability: .resolvable, itemReference: "tt1234567")])
        let targets = values.enumerated().map { index, value in
            AppleTMDBRelation.Target(id: index + 1, type: "movie", title: value.item.name, year: 2024, origin: .similar)
        }
        let stamp = Date.now
        let input = AppleDiscoverView.RecommendationSnapshot(
            relations: [.init(seedID: "tt1234567", type: "movie", targets: targets, storedAt: stamp)],
            sources: [source], records: [history], progress: [:], activity: [:],
            completed: [try #require(ApplePlaybackIdentity.storageKey(for: history.id)): stamp],
            unwatched: [:], removed: [:], ratings: [:], serverContinueWatching: [], serverShelves: [],
            artwork: [:], debugHeroTitle: nil, now: stamp, libraryItems: values)
        let result = try await AppleDiscoverView.buildRecommendations(input)
        #expect(result.seedRows.isEmpty)
    }

    @Test func watchedTitlesGetMetadataBeforeUnrelatedNewestFiles() async throws {
        let source = UUID()
        let groups = AppleLibrarySeries.groups(["New.2025.mkv", "Seed.2020.mkv"].map {
            AppleLibraryItem(sourceID: source, name: $0, url: URL(fileURLWithPath: "/fixture/\($0)"), relativePath: $0, sizeBytes: 1)
        })
        let ordered = groups.sorted { $0.parsed.title < $1.parsed.title }
        let history = AppleMediaRecord(canonicalID: "tt1234567", kind: .movie, title: "Seed", availability: [], progress: 1)
        let prepared = await AppleLocalLibraryStore.metadataPreparationGroups(ordered, records: [history])
        #expect(prepared.map(\.parsed.title) == ["Seed", "New"])
    }

    @MainActor @Test(arguments: [true, false])
    func concurrentContinueWatchingKeepsRemovalAndCompletionRules(hasSource: Bool) async throws {
        let name = "homefix-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = ApplePlaybackStore(defaults: defaults)
        let source = AppleSource(kind: .nas, name: "Fixture", url: try #require(URL(string: "smb://fixture.example/Media")))
        let files = (0..<600).map { index in
            let name = "Movie\(index).2020.mkv"
            return AppleLibraryItem(sourceID: source.id, name: name, url: URL(fileURLWithPath: "/fixture/\(name)"),
                relativePath: name, sizeBytes: 1)
        }
        let library = AppleLocalLibraryStore(playbackStore: store, groups: AppleLibrarySeries.groups(files), sources: hasSource ? [source] : [])
        let first = try #require(files.first)
        let id = library.playbackID(first)
        store.save(mediaID: id, position: 100, duration: 1000)
        #expect(await library.continueWatching(state: store.readState()).map(\.id) == library.continueWatching.map(\.id))
        #expect(await library.continueWatching(state: store.readState()).count == 1)
        store.removeFromContinueWatching(mediaID: id)
        #expect(await library.continueWatching(state: store.readState()).isEmpty)
        store.save(mediaID: id, position: 1000, duration: 1000)
        #expect(await library.continueWatching(state: store.readState()).isEmpty)
    }
}
