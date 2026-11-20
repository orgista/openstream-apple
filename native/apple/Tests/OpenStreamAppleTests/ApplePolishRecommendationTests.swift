import Foundation
import Testing
import Synchronization
@testable import OpenStreamApple

@Suite("Accessible recommendation polish")
struct ApplePolishRecommendationTests {
    @Test func anIdenticalRefetchRefreshesRelationFreshnessInMemoryAndOnDisk() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = AppleMetadataDiskCache(directory: directory)
        let cache = AppleTMDBRelationCache(cache: disk)
        let configuration = try AppleTMDBConfiguration(credential: "fixture-refetch")
        let targets = [AppleTMDBRelation.Target(id: 42, type: "movie", title: "Fixture", year: 2020, origin: .similar)]
        let previous = AppleTMDBRelation(seedID: "tt1234567", type: "movie", targets: targets,
            storedAt: Date.now.addingTimeInterval(-AppleMetadataDiskCachePolicy.keepFor + 60))
        await cache.store(previous, configuration: configuration)
        let refreshed = AppleTMDBRelation(seedID: previous.seedID, type: previous.type, targets: targets, storedAt: .now)
        await cache.store(refreshed, configuration: configuration)
        #expect(await cache.snapshot(configuration: configuration) == [refreshed])
        #expect(await AppleTMDBRelationCache(cache: disk).snapshot(configuration: configuration) == [refreshed])
    }

    @Test func relationIDsPiggybackOnTheExistingTwoMetadataRequests() async throws {
        let count = Mutex(0)
        let configuration = try AppleTMDBConfiguration(credential: "fixture-\(UUID().uuidString)")
        let client = AppleTMDBClient { request in
            count.withLock { $0 += 1 }
            let body: String
            if request.url?.path.hasPrefix("/3/find/") == true {
                body = #"{"movie_results":[{"id":42}],"tv_results":[]}"#
            } else {
                let query = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?.queryItems
                #expect(query?.first(where: { $0.name == "append_to_response" })?.value?.contains("recommendations,similar") == true)
                body = #"{"genres":[],"recommendations":{"results":[{"id":7,"title":"Accessible","release_date":"2020-01-01"}]},"similar":{"results":[{"id":9,"title":"Other","release_date":"2021-01-01"}]}}"#
            }
            let url = try #require(request.url)
            return (Data(body.utf8), try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
        _ = try await client.details(imdbID: "tt1234567", kind: .movie, configuration: configuration)
        #expect(count.withLock { $0 } == 2)
        let relation = try #require(await AppleTMDBRelationCache.shared.snapshot(configuration: configuration).first)
        #expect(relation.seedID == "tt1234567")
        #expect(relation.targets.map(\.origin) == [.recommendation, .similar])
        #expect(relation.targets.map(\.id) == [7, 9])
    }

    @Test func cachedRelationsOnlyIntersectAccessibleTitlesOfTheSameKindAndYear() {
        let target = AppleTMDBRelation.Target(id: 42, type: "movie", title: "A Film", year: 2020, origin: .recommendation)
        let accessible = AppleCatalogItem(mediaID: "tt1234567", type: "movie", name: "A Film", year: 2020)
        #expect(target.matches(accessible))
        #expect(!target.matches(AppleCatalogItem(mediaID: "tt1234568", type: "movie", name: "A Film", year: 2021)))
        #expect(!target.matches(AppleCatalogItem(mediaID: "tmdb:42", type: "series", name: "A Film", year: 2020)))
        #expect(!AppleTMDBRelation.Target(id: 42, type: "movie", title: "A Film", year: nil, origin: .similar).matches(accessible))
    }

    @Test func inaccessibleAndAmbiguousRelationIDsNeverCreateCandidates() {
        let target = AppleTMDBRelation.Target(id: 42, type: "movie", title: "Film", year: 2020, origin: .similar)
        let first = AppleCatalogItem(mediaID: "tt1234567", type: "movie", name: "Film", year: 2020)
        let other = AppleCatalogItem(mediaID: "tt7654321", type: "movie", name: "Film", year: 2020)
        #expect(target.accessibleIDs(in: AppleTMDBRelation.accessibleIndex([:])).isEmpty)
        #expect(target.accessibleIDs(in: AppleTMDBRelation.accessibleIndex(["first": first])) == ["first"])
        #expect(target.accessibleIDs(in: AppleTMDBRelation.accessibleIndex(["first": first, "other": other])).isEmpty)
        let direct = AppleCatalogItem(mediaID: "tmdb:42", type: "movie", name: "Film", year: 2020)
        #expect(target.accessibleIDs(in: AppleTMDBRelation.accessibleIndex(["first": first, "direct": direct])) == ["direct"])
    }

    @Test func seedRowRequiresEightItemsAndANonemptyTitle() {
        #expect(AppleRecommendationRowPolicy.heading(seed: "Seed", count: 7) == nil)
        #expect(AppleRecommendationRowPolicy.heading(seed: "Seed", count: 8) == "Because You Watched Seed")
        #expect(AppleRecommendationRowPolicy.heading(seed: " ", count: 10) == nil)
    }

    @Test func topPicksPreferUnseenWhileDefaultResumeRankingIsUnchanged() {
        let now = Date(timeIntervalSince1970: 100)
        let history = [AppleViewingSignal(titleID: "seed", genres: ["Drama"], at: now, completed: true)]
        let values = [AppleRankableTitle(id: "resume", genres: ["Drama"], releaseYear: nil, metadataCompleteness: 1, isResumable: true, isCompleted: false),
                      AppleRankableTitle(id: "unseen", genres: ["Drama"], releaseYear: nil, metadataCompleteness: 1, isResumable: false, isCompleted: false)]
        #expect(AppleRecommendationRanker.rank(values, history: history, ratings: [:], now: now, limit: 2).first?.id == "resume")
        #expect(AppleRecommendationRanker.rank(values, history: history, ratings: [:], now: now, limit: 2, preferUnseen: true).first?.id == "unseen")
    }

    @Test func relationAffinityRequiresAnActualViewingSeedAndIsBounded() {
        let now = Date(timeIntervalSince1970: 100)
        let title = AppleRankableTitle(id: "target", genres: [], releaseYear: nil, metadataCompleteness: 0, isResumable: false, isCompleted: false)
        let history = [AppleViewingSignal(titleID: "seed", genres: [], at: now, completed: true)]
        let ranked = AppleRecommendationRanker.rankWithProvenance([title], history: history, ratings: [:], now: now, limit: 1, relationIDs: ["target": ["seed", "unknown"]])
        #expect(ranked.first?.relationScore == 1)
        #expect(ranked.first?.seeds.count == 1)
        #expect(ranked.first?.seeds.first?.kind == .related)
    }

    @Test func cacheBoundsSeedsAndTargetsAndSurvivesConcurrentWrites() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = AppleMetadataDiskCache(directory: directory)
        let cache = AppleTMDBRelationCache(cache: disk)
        let configuration = try AppleTMDBConfiguration(credential: "fixture-bounds")
        let targets = (1...60).map { AppleTMDBRelation.Target(id: $0, type: "movie", title: "Fixture", year: 2020, origin: .similar) }
        for index in 1...130 {
            await cache.store(AppleTMDBRelation(seedID: "seed-\(index)", type: "movie", targets: targets, storedAt: .now), configuration: configuration)
        }
        #expect(await cache.snapshot(configuration: configuration).count == 128)
        #expect(await cache.snapshot(configuration: configuration).allSatisfy { $0.targets.count == 40 })
        await withTaskGroup(of: Void.self) { group in
            for index in 1...8 {
                group.addTask {
                    await cache.store(AppleTMDBRelation(seedID: "concurrent-\(index)", type: "movie", targets: [], storedAt: .now), configuration: configuration)
                }
            }
        }
        let reloaded = await AppleTMDBRelationCache(cache: disk).snapshot(configuration: configuration)
        #expect(reloaded.filter { $0.seedID.hasPrefix("concurrent-") }.count == 8)
    }

    @Test func cachedRelationsRespectMetadataOffExpiryAndConfigurationIsolation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = AppleTMDBRelationCache(cache: AppleMetadataDiskCache(directory: directory))
        let first = try AppleTMDBConfiguration(credential: "fixture-first")
        let second = try AppleTMDBConfiguration(credential: "fixture-second")
        let relation = AppleTMDBRelation(seedID: "tt1234567", type: "movie", targets: [], storedAt: .now)
        await cache.store(relation, configuration: first)
        let stored = await cache.snapshot(configuration: first)
        #expect(stored == [relation])
        #expect(await cache.snapshot(configuration: nil) == [])
        #expect(await cache.snapshot(configuration: second) == [])
        await cache.store(AppleTMDBRelation(seedID: "tt7654321", type: "movie", targets: [], storedAt: .distantPast), configuration: first)
        #expect(await cache.snapshot(configuration: first) == [relation])
    }
}
