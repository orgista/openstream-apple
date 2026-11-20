import Foundation
import Testing
@testable import OpenStreamApple

@Suite("Discover hero mix")
struct AppleHeroMixPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func candidate(_ id: String, resume: Double? = nil, relevant: Bool = false,
                           age: Double? = nil, watched: Bool = false, completed: Bool = false,
                           disliked: Bool = false, accessible: Bool = true, art: Bool = true) -> AppleHeroMixPolicy.Candidate {
        .init(id: id, resumeAt: resume.map { now.addingTimeInterval($0) }, relevant: relevant,
              releaseDate: age.map { now.addingTimeInterval(-$0 * 86_400) },
              state: .init(meaningfulProgress: watched, completed: completed, disliked: disliked),
              accessible: accessible, hasBackdrop: art)
    }
    private func ids(_ values: [AppleHeroMixPolicy.Candidate]) -> [String] {
        AppleHeroMixPolicy.select(values, now: now)
    }

    @Test(arguments: [0, 1, 5]) func resumePrecedenceAndQuotas(count: Int) {
        let resumes = (0..<count).map { candidate("resume\($0)", resume: Double(-$0)) }
        let values = resumes + [candidate("pick1", relevant: true), candidate("pick2", relevant: true),
                                candidate("pick3", relevant: true), candidate("release", age: 2)]
        let deck = ids(values)
        if count > 0 { #expect(deck.first == "resume0") }
        #expect(deck.contains("pick1"))
        #expect(deck.contains("pick2"))
        #expect(deck.contains("release"))
        if count == 5 { #expect(deck == ["resume0", "pick1", "pick2", "release", "resume1"]) }
    }

    @Test func sparseAndNoConfidenceUseExistingOrder() {
        let values = [candidate("r1", resume: 0), candidate("r2", resume: -1), candidate("yearOnly")]
        #expect(ids(values) == values.map(\.id))
        #expect(ids([]).isEmpty)
    }

    @Test(arguments: [0.0, 90.0, 90.0001, -0.001]) func releaseWindow(age: Double) {
        let values = (0..<5).map { candidate("r\($0)", resume: Double(-$0)) } + [candidate("new", age: age)]
        #expect(ids(values).contains("new") == (age >= 0 && age <= 90))
    }

    @Test func yearAloneIsNotAReleaseDate() {
        #expect(AppleHeroMixPolicy.releaseDate("2026") == nil)
        #expect(AppleHeroMixPolicy.releaseDate("2026–2027") == nil)
        #expect(AppleHeroMixPolicy.releaseDate("2026-02-30") == nil)
        #expect(AppleHeroMixPolicy.releaseDate("2026-10-13") != nil)
        #expect(AppleHeroMixPolicy.releaseDate("2026-10-13T00:00:00.000Z") != nil)
    }

    @Test func watchedAndCompletedCannotTakeUnseenSlots() {
        let resumes = (0..<5).map { candidate("r\($0)", resume: Double(-$0)) }
        #expect(ids(resumes + [candidate("watched", relevant: true, age: 1, watched: true),
                               candidate("finished", relevant: true, age: 1, completed: true)]) == resumes.map(\.id))
    }

    @Test func dislikesAndInaccessibleAreExcludedEvenFromFallback() {
        #expect(ids([candidate("down", resume: 1, disliked: true), candidate("offline", accessible: false),
                     candidate("ok")]) == ["ok"])
    }

    @Test func latestResumeAndDeterministicTies() {
        let a = candidate("a", resume: 2), b = candidate("b", resume: 2), old = candidate("old", resume: 0)
        #expect(ids([old, b, a]).first == "a")
        #expect(ids([b, a, old]).first == "a")
        let r = (0..<5).map { candidate("r\($0)", resume: Double(-$0)) }
        #expect(ids(r + [candidate("z", age: 1), candidate("a", age: 1)])[1] == "a")
    }

    @Test func quotasDoNotDoubleCountSameTitle() {
        let r = (0..<5).map { candidate("r\($0)", resume: Double(-$0)) }
        #expect(ids(r + [candidate("both", relevant: true, age: 1), candidate("both", relevant: true),
                         candidate("pick", relevant: true), candidate("release", age: 2)])
                == ["r0", "both", "pick", "release", "r1"])
    }

    @Test func artworkGateAndArtlessFallback() {
        #expect(ids([candidate("noArt", resume: 0, art: false), candidate("art")]) == ["art"])
        #expect(ids([candidate("noArt", art: false)]) == ["noArt"])
        #expect(AppleHeroRotation.interval == 6)
    }

    @Test func sectionsAreGatheredRoundRobin() {
        #expect(AppleHeroMixPolicy.fairlyGather([[1, 2, 3], [], [4, 5], [6]]) == [1, 4, 6, 2, 5, 3])
    }

    @Test func canonicalIdentityKeepsKindAndStableRepresentative() {
        let movie = AppleCatalogItem(mediaID: "tt0000001", type: "movie", name: "Title")
        let duplicate = AppleCatalogItem(mediaID: "other", type: "movie", name: "Title", imdbID: "tt0000001")
        let series = AppleCatalogItem(mediaID: "tt0000001", type: "series", name: "Title")
        #expect(AppleRecommendationInputs.identity(movie) == AppleRecommendationInputs.identity(duplicate))
        #expect(AppleRecommendationInputs.identity(movie) != AppleRecommendationInputs.identity(series))
        #expect(AppleRecommendationInputs.prefers(duplicate, sourceID: "b", accessible: true,
            over: movie, sourceID: "a", accessible: true))
        #expect(AppleRecommendationInputs.prefers(movie, sourceID: "a", accessible: true,
            over: movie, sourceID: "b", accessible: true))
    }

    @Test func duplicateWatchStateIsConservative() {
        var state = AppleHeroMixPolicy.State()
        state.merge(.init(meaningfulProgress: true))
        state.merge(.init(completed: true, disliked: true))
        state.merge(.init())
        #expect(state.meaningfulProgress)
        #expect(state.completed)
        #expect(state.disliked)
    }

    @Test func releaseYearAndCompletenessDoNotCreateAffinity() {
        let title = AppleRankableTitle(id: "yearOnly", genres: [], releaseYear: 2026,
            metadataCompleteness: 1, isResumable: false, isCompleted: false)
        let ranked = AppleRecommendationRanker.rankWithProvenance([title], history: [], ratings: [:],
            now: now, limit: 1, requiresAffinity: true)
        #expect(ranked.isEmpty)
    }

    @Test func relevantAndReleaseFromLaterSectionsParticipate() {
        let r = (0..<5).map { candidate("r\($0)", resume: Double(-$0)) }
        let gathered = AppleHeroMixPolicy.fairlyGather([
            [candidate("ordinary")], [candidate("relevant", relevant: true)], [candidate("release", age: 1)]])
        #expect(ids(r + gathered) == ["r0", "relevant", "release", "r1", "r2"])
    }

    @Test func meaningfulProgressBoundaries() {
        func state(_ position: Double, _ duration: Double) -> AppleHeroMixPolicy.State {
            AppleHeroMixPolicy.watchState(progress: [.init(position: position, duration: duration)],
                                         completed: false, recordProgress: nil, disliked: false)
        }
        #expect(state(1, 1000).meaningfulProgress == false)
        #expect(state(50, 1000).meaningfulProgress)
        #expect(state(60, 10000).meaningfulProgress)
        #expect(state(.nan, 1000).meaningfulProgress == false)
        #expect(state(1000, 1000).completed)
    }

    @MainActor private func resume(_ id: String, source: AppleSource, at: Date?, type: String = "movie") -> AppleDiscoverView.IndexedCatalogItem {
        let item = AppleCatalogItem(mediaID: id, type: type, name: id,
            backgroundURL: URL(string: "https://fixture.example/backdrop.jpg"))
        return .init(record: AppleMediaIngestion.catalogRecord(instanceID: source.id, item: item),
                     item: item, source: source, continueWatchingUpdatedAt: at)
    }

    @MainActor private func recommendations(_ resumes: [AppleDiscoverView.IndexedCatalogItem], sources: [AppleSource]) async throws -> AppleDiscoverView.RecommendationResult {
        try await AppleDiscoverView.buildRecommendations(.init(relations: [], sources: sources,
            records: [], progress: [:], activity: [:],
            completed: [:], unwatched: [:], removed: [:], ratings: [:], serverContinueWatching: resumes,
            serverShelves: [], artwork: [:], debugHeroTitle: nil, now: now))
    }

    @MainActor @Test func undatedServerResumeDoesNotBeatRealWatchDate() async throws {
        let source = AppleSource(kind: .mediaServer, name: "Fixture", url: URL(string: "https://fixture.example")!)
        let undated = resume(AppleMediaServerItemReference(sourceID: source.id, itemID: "a").mediaID, source: source, at: nil)
        let dated = resume(AppleMediaServerItemReference(sourceID: source.id, itemID: "z").mediaID, source: source, at: Date(timeIntervalSince1970: 1_700_000_000))
        let result = try await recommendations([undated, dated], sources: [source])
        #expect(result.heroes.first?.id == dated.id)
    }

    @MainActor @Test(arguments: [AppleXtreamReference.Kind.movie, .series])
    func xtreamResumesRemainHeroEligible(kind: AppleXtreamReference.Kind) async throws {
        let source = AppleSource(kind: .liveTV, name: "Fixture", url: URL(string: "https://fixture.example")!)
        let value = resume(AppleXtreamReference(sourceID: source.id, kind: kind, providerID: "1").mediaID, source: source, at: now, type: kind == .series ? "series" : "movie")
        let result = try await recommendations([value], sources: [source])
        #expect(result.heroes.map(\.id) == [value.id])
        var disabled = source
        disabled.isEnabled = false
        #expect(try await recommendations([value], sources: [disabled]).heroes.isEmpty)
    }

    @MainActor @Test(arguments: [AppleXtreamReference.Kind.movie, .series])
    func mergedXtreamResumeUsesTitlePageRecordWatchDate(kind: AppleXtreamReference.Kind) async throws {
        let suiteName = "ship19.xtream.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ApplePlaybackStore(defaults: defaults)
        let source = AppleSource(kind: .liveTV, name: "Fixture", url: URL(string: "https://fixture.example")!)
        let reference = AppleXtreamReference(sourceID: source.id, kind: kind, providerID: "1")
        let value = resume(reference.mediaID, source: source, at: nil, type: kind == .series ? "series" : "movie")
        // The title page writes both movies and series under progressRecordID, with an episode part for series.
        store.save(mediaID: value.record.id, position: 600, duration: 1200,
            partID: kind == .series ? reference.mediaID + ":1:1" : nil)
        let activity = try #require(store.lastActivity(for: value.record.id))
        #expect(store.lastActivity(for: value.item.mediaID) == nil)

        let merged = AppleDiscoverView.mergedContinueWatching(local: [],
            mediaServerLibrary: AppleMediaServerLibraryStore(progressDefaults: defaults),
            xtreamItems: [value.item], xtreamSource: { $0 == reference ? source : nil },
            sources: [source], playbackStore: store)
        let resumed = try #require(merged.first)
        #expect(merged.count == 1)
        #expect(resumed.record.progress == 0.5)
        #expect(resumed.continueWatchingUpdatedAt == activity.updatedAt)

        let olderSource = AppleSource(kind: .mediaServer, name: "Older fixture", url: URL(string: "https://fixture.example")!)
        let older = resume(AppleMediaServerItemReference(sourceID: olderSource.id, itemID: "older").mediaID,
            source: olderSource, at: activity.updatedAt.addingTimeInterval(-86_400))
        let result = try await recommendations([older] + merged, sources: [olderSource, source])
        #expect(result.heroes.first?.id == value.id)
    }

    @MainActor @Test func displacedHeroResumesRemainInContinueWatching() async throws {
        let source = AppleSource(kind: .mediaServer, name: "Fixture", url: URL(string: "https://fixture.example")!)
        let values = (0..<8).map { index in
            resume(AppleMediaServerItemReference(sourceID: source.id, itemID: "item\(index)").mediaID,
                   source: source, at: now.addingTimeInterval(Double(-index)))
        }
        let result = try await recommendations(values, sources: [source])
        #expect(result.heroes.count == AppleHeroRotation.maximumCandidates)
        #expect(result.continueWatching.map(\.id) == values.map(\.id))
        #expect(Set(result.continueWatching.map(\.id)).subtracting(result.heroes.map(\.id)).count == 3)
    }

    @Test func releaseDayFormatterIsReused() {
        #expect(AppleHeroMixPolicy.releaseDayFormatter === AppleHeroMixPolicy.releaseDayFormatter)
    }
}
