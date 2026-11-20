import Testing
import Foundation
@testable import OpenStreamApple

@Suite("AppleRecommendationRanker Tests")
struct AppleRecommendationRankerTests {
    
    @Test func provenanceRetainsCappedComponentsAndSafeSeeds() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let title = AppleRankableTitle(id: "candidate", genres: ["Drama"], releaseYear: nil,
            metadataCompleteness: 1, isResumable: false, isCompleted: false)
        let history = (0..<20).map { AppleViewingSignal(titleID: "https://fixture.example/\($0)?token=private",
            genres: ["Drama"], at: now, completed: true) }
        let ratings = Dictionary(uniqueKeysWithValues: history.map { ($0.titleID, AppleTitleRating.doubleUp) })
        let value = try #require(AppleRecommendationRanker.rankWithProvenance([title], history: history,
            ratings: ratings, now: now, limit: 1).first)
        #expect(value.viewingScore == 4)
        #expect(value.likedScore == 1)
        #expect(value.ratingScore == 0)
        #expect(value.score == 5)
        #expect(value.seeds.filter { $0.kind == .viewing }.count == 20)
        #expect(value.seeds.filter { $0.kind == .liked }.count == 20)
        #expect(value.debugTrace.contains("private") == false)
        #expect(value.debugTrace.contains("https") == false)
        #expect(value.debugTrace.contains("token") == false)
        let reversed = AppleRecommendationRanker.rankWithProvenance([title], history: history.reversed(),
            ratings: ratings, now: now, limit: 1)
        #expect(reversed.first == value)
    }

    @Test func topPicksDiversifySelectedGenresFranchisesAndSourcesWithStableTies() {
        let a = AppleRankableTitle(id: "a", genres: ["Drama"], releaseYear: 2020, metadataCompleteness: 1,
            isResumable: false, isCompleted: false, franchiseID: "same", sourceID: "one")
        let b = AppleRankableTitle(id: "b", genres: ["Drama"], releaseYear: 2020, metadataCompleteness: 1,
            isResumable: false, isCompleted: false, franchiseID: "same", sourceID: "one")
        let c = AppleRankableTitle(id: "c", genres: ["Comedy"], releaseYear: 2020, metadataCompleteness: 1,
            isResumable: false, isCompleted: false, franchiseID: "other", sourceID: "two")
        let first = AppleRecommendationRanker.rank([b, c, a], history: [], ratings: [:], now: .distantPast, limit: 3)
        let second = AppleRecommendationRanker.rank([c, a, b], history: [], ratings: [:], now: .distantPast, limit: 3)
        #expect(first.map(\.id) == ["a", "c", "b"])
        #expect(first == second)
    }

    @Test("Resumable wins")
    func testResumableWins() {
        let t1 = AppleRankableTitle(id: "1", genres: ["Action"], releaseYear: 2020, metadataCompleteness: 1.0, isResumable: false, isCompleted: false)
        let t2 = AppleRankableTitle(id: "2", genres: ["Comedy"], releaseYear: 2020, metadataCompleteness: 1.0, isResumable: true, isCompleted: false)
        
        // t2 is resumable, should win over t1 even if t1 has higher score (we give no history, so score is 0 for both)
        let ranked = AppleRecommendationRanker.rank([t1, t2], history: [], ratings: [:], now: Date(), limit: 10)
        #expect(ranked.first?.id == "2")
    }
    
    @Test("Down-rated excluded")
    func testDownRatedExcluded() {
        let t1 = AppleRankableTitle(id: "1", genres: ["Action"], releaseYear: 2020, metadataCompleteness: 1.0, isResumable: false, isCompleted: false)
        let t2 = AppleRankableTitle(id: "2", genres: ["Comedy"], releaseYear: 2020, metadataCompleteness: 1.0, isResumable: false, isCompleted: false)
        
        let ranked = AppleRecommendationRanker.rank([t1, t2], history: [], ratings: ["1": .down], now: Date(), limit: 10)
        #expect(ranked.count == 1)
        #expect(ranked.first?.id == "2")
    }
    
    @Test("DoubleUp beats up")
    func testDoubleUpBeatsUp() {
        let t1 = AppleRankableTitle(id: "1", genres: ["Action"], releaseYear: 2020, metadataCompleteness: 1.0, isResumable: false, isCompleted: false)
        let t2 = AppleRankableTitle(id: "2", genres: ["Action"], releaseYear: 2020, metadataCompleteness: 1.0, isResumable: false, isCompleted: false)
        
        let now = Date()
        let history = [AppleViewingSignal(titleID: "3", genres: ["Action"], at: now, completed: true)]
        
        // t1 gets doubleUp, t2 gets up. Same base score due to genre match.
        let ranked = AppleRecommendationRanker.rank([t1, t2], history: history, ratings: ["1": .doubleUp, "2": .up], now: now, limit: 10)
        #expect(ranked.first?.id == "1")
        #expect(ranked.last?.id == "2")
    }
    
    @Test("Genre overlap and recency")
    func testGenreOverlap() {
        let t1 = AppleRankableTitle(id: "1", genres: ["Action", "Sci-Fi"], releaseYear: 2020, metadataCompleteness: 1.0, isResumable: false, isCompleted: false)
        let t2 = AppleRankableTitle(id: "2", genres: ["Comedy"], releaseYear: 2020, metadataCompleteness: 1.0, isResumable: false, isCompleted: false)
        
        let now = Date()
        let history = [AppleViewingSignal(titleID: "3", genres: ["Sci-Fi"], at: now, completed: true)]
        
        // t1 shares genre with history, t2 does not. t1 should outrank t2.
        let ranked = AppleRecommendationRanker.rank([t1, t2], history: history, ratings: [:], now: now, limit: 10)
        #expect(ranked.first?.id == "1")
    }
    
    @Test("Completed sinks")
    func testCompletedSinks() {
        let t1 = AppleRankableTitle(id: "1", genres: ["Action"], releaseYear: 2020, metadataCompleteness: 1.0, isResumable: false, isCompleted: true)
        let t2 = AppleRankableTitle(id: "2", genres: ["Action"], releaseYear: 2020, metadataCompleteness: 1.0, isResumable: false, isCompleted: false)
        
        // At equal score (0 for both), unwatched (t2) beats completed (t1).
        let ranked = AppleRecommendationRanker.rank([t1, t2], history: [], ratings: [:], now: Date(), limit: 10)
        #expect(ranked.first?.id == "2")
        #expect(ranked.last?.id == "1")
    }
    
    @Test("Deterministic across two calls")
    func testDeterministic() {
        let titles = (1...10).map { i in
            AppleRankableTitle(id: "\(i)", genres: ["Genre\(i % 3)"], releaseYear: 2000 + i, metadataCompleteness: 0.5, isResumable: i == 5, isCompleted: i % 2 == 0)
        }
        
        let now = Date()
        let history = [
            AppleViewingSignal(titleID: "h1", genres: ["Genre0", "Genre1"], at: now.addingTimeInterval(-86400 * 5), completed: true),
            AppleViewingSignal(titleID: "h2", genres: ["Genre2"], at: now, completed: false)
        ]
        
        let ratings: [String: AppleTitleRating] = ["1": .up, "3": .down, "8": .doubleUp]
        
        let rank1 = AppleRecommendationRanker.rank(titles, history: history, ratings: ratings, now: now, limit: 10)
        let rank2 = AppleRecommendationRanker.rank(titles, history: history, ratings: ratings, now: now, limit: 10)
        
        #expect(rank1 == rank2)
    }
    private func title(_ id: String, genres: [String] = [], year: Int = 2020) -> AppleRankableTitle {
        AppleRankableTitle(id: id, genres: genres, releaseYear: year, metadataCompleteness: 1,
                           isResumable: false, isCompleted: false)
    }

    @Test func unratedIsExactlyNeutral() {
        let titles = [title("a"), title("z", year: 2025)]
        let baseline = AppleRecommendationRanker.rank(titles, history: [], ratings: [:], now: .distantPast, limit: 10)
        #expect(AppleRecommendationRanker.rank(titles, history: [], ratings: ["a": .none], now: .distantPast, limit: 10) == baseline)
    }

    @Test func likesTransferGenresWithoutSpreadingDislikes() {
        let titles = [title("seed", genres: ["Drama"]), title("related", genres: [" drama "]), title("other", year: 2025)]
        let liked = AppleRecommendationRanker.rank(titles, history: [], ratings: ["seed": .up], now: .distantPast, limit: 10)
        #expect(liked.map(\.id) == ["seed", "related", "other"])
        let disliked = AppleRecommendationRanker.rank(titles, history: [], ratings: ["seed": .down], now: .distantPast, limit: 10)
        #expect(disliked.map(\.id) == ["other", "related"])
    }

    @Test func ratingWeightsRemainComparableToViewingEvidence() {
        let now = Date(timeIntervalSince1970: 100000)
        let titles = [title("liked"), title("relevant", genres: ["Drama"])]
        let history = (0..<4).map { AppleViewingSignal(titleID: "show-\($0)", genres: ["Drama"], at: now, completed: true) }
        let ranked = AppleRecommendationRanker.rank(titles, history: history, ratings: ["liked": .doubleUp], now: now, limit: 10)
        #expect(ranked.first?.id == "relevant")
    }

    @Test func episodeAndAutosaveInfluenceIsCappedPerShow() {
        let now = Date(timeIntervalSince1970: 100000)
        let titles = [title("drama", genres: ["Drama"]), title("comedy", genres: ["Comedy"])]
        let single = [AppleViewingSignal(titleID: "show", genres: ["Drama"], at: now, completed: true)]
        let repeated = (0..<100).map { AppleViewingSignal(titleID: "episode-\($0)", genres: ["Drama"], at: now, completed: true, showID: "show") }
        let other = (0..<2).map { AppleViewingSignal(titleID: "film-\($0)", genres: ["Comedy"], at: now, completed: true) }
        #expect(AppleRecommendationRanker.rank(titles, history: single + other, ratings: [:], now: now, limit: 10)
            == AppleRecommendationRanker.rank(titles, history: repeated + other, ratings: [:], now: now, limit: 10))
        #expect(AppleRecommendationRanker.rank(titles, history: repeated + other, ratings: [:], now: now, limit: 10).first?.id == "comedy")
    }

    @Test func unknownDatesRemainUnknownAndHaveBoundedInfluence() throws {
        let signal = try #require(AppleRecommendationInputs.signal(titleID: "h", genres: ["Drama"],
            progress: [], completedDates: [], recordProgress: 0.5))
        #expect(signal.at == nil)
        let now = Date(timeIntervalSince1970: 100000)
        let titles = [title("drama", genres: ["Drama"]), title("comedy", genres: ["Comedy"])]
        let recent = AppleViewingSignal(titleID: "recent", genres: ["Comedy"], at: now, completed: false)
        #expect(AppleRecommendationRanker.rank(titles, history: [signal, recent], ratings: [:], now: now, limit: 10).first?.id == "comedy")
    }

    @Test func historyUsesViewingDatesAndIncludesFinishedTitles() throws {
        let played = Date(timeIntervalSince1970: 1000)
        let completed = Date(timeIntervalSince1970: 2000)
        let saved = ApplePlaybackProgress(position: 300, duration: 1000, updatedAt: played)
        let partial = try #require(AppleRecommendationInputs.signal(titleID: "partial", genres: [" Drama "],
            progress: [saved], completedDates: [], recordProgress: nil))
        #expect(partial.at == played)
        #expect(partial.genres == ["drama"])
        #expect(partial.completed == false)
        let finished = try #require(AppleRecommendationInputs.signal(titleID: "finished", genres: [],
            progress: [], completedDates: [completed], recordProgress: nil))
        #expect(finished.at == completed)
        #expect(finished.completed)
        #expect(AppleRecommendationInputs.signal(titleID: "incidental", genres: [],
            progress: [.init(position: 5, duration: 1000, updatedAt: played)], completedDates: [], recordProgress: nil) == nil)
    }

    @Test func genresAndLeadingYearsAreNormalizedWithoutInventingMetadata() {
        let item = AppleCatalogItem(mediaID: "a", type: "movie", name: "A", releaseInfo: "2013–2018", genres: [" Drama ", "DRAMA", "Sci-Fi"])
        #expect(AppleRecommendationInputs.genres(item) == ["drama", "sci-fi"])
        #expect(AppleRecommendationInputs.releaseYear(item) == 2013)
        #expect(AppleRecommendationInputs.releaseYear(.init(mediaID: "b", type: "movie", name: "B", releaseInfo: "2000-", year: 2024)) == 2024)
        #expect(AppleRecommendationInputs.releaseYear(.init(mediaID: "b", type: "movie", name: "B", releaseInfo: "unknown")) == nil)
        #expect(AppleRecommendationInputs.genres(.init(mediaID: "b", type: "movie", name: "B")) == [])
        #expect(AppleRecommendationInputs.releaseYear(.init(mediaID: "b", type: "movie", name: "B", releaseInfo: "20245")) == nil)
    }

    @Test func canonicalIdentityKeepsRemakesKindsAndConflictingIDsSeparate() {
        func identity(_ id: String, kind: String = "movie", year: Int? = 2000, imdb: String? = nil) -> String {
            AppleRecommendationInputs.identity(.init(mediaID: id, type: kind, name: "Same Name", year: year, imdbID: imdb))
        }
        #expect(identity("tt1234567") == identity("tmdb:1", imdb: "tt1234567"))
        #expect(identity("tt1234567") != identity("tt7654321"))
        #expect(identity("provider-a", year: 2000) != identity("provider-b", year: 2020))
        #expect(identity("provider-a", kind: "movie") != identity("provider-b", kind: "series"))
        #expect(identity("provider-a", year: nil) != identity("provider-b", year: nil))
        #expect(identity("tt1234567:1:1", kind: "episode") != identity("tt1234567:1:2", kind: "episode"))
    }

    @Test func historyBudgetCapsShowsBeforeLimitingAndKeepsRealDates() throws {
        let now = Date(timeIntervalSince1970: 100000)
        let episodes = (0..<100).map { AppleViewingSignal(titleID: "episode-\($0)", genres: ["Drama"], at: now, completed: true, showID: "show") }
        let unknown = AppleViewingSignal(titleID: "film", genres: ["Comedy"], at: nil, completed: true)
        let bounded = AppleRecommendationInputs.boundedHistory(episodes + [unknown], now: now, limit: 2)
        #expect(bounded.count == 2)
        #expect(bounded.contains { $0.titleID == "film" && $0.at == nil })
        let old = AppleViewingSignal(titleID: "same", genres: ["Drama"], at: now.addingTimeInterval(-86400 * 60), completed: true)
        let recent = AppleViewingSignal(titleID: "same", genres: ["Drama"], at: now, completed: false)
        let merged = try #require(AppleRecommendationInputs.boundedHistory([old, recent], now: now).first)
        #expect(merged.at == now)
        #expect(merged.completed == false)
    }

    @Test func recencyUsesFourteenDayDecayAndMissingGenresStayNeutral() {
        let now = Date(timeIntervalSince1970: 10000000)
        let titles = [title("a", genres: ["Drama"]), title("b", genres: ["Comedy"])]
        let history = [AppleViewingSignal(titleID: "old", genres: ["Drama"], at: now.addingTimeInterval(-86400 * 28), completed: true),
                       AppleViewingSignal(titleID: "recent", genres: ["Comedy"], at: now, completed: false)]
        #expect(AppleRecommendationRanker.rank(titles, history: history, ratings: [:], now: now, limit: 10).first?.id == "b")
        let neutral = [title("a"), title("b", year: 2025)]
        #expect(AppleRecommendationRanker.rank(neutral, history: history, ratings: [:], now: now, limit: 10)
            == AppleRecommendationRanker.rank(neutral, history: [], ratings: [:], now: now, limit: 10))
    }

    @Test func duplicateRankerIDsNeverOccupyMultipleSlots() {
        let a = title("a", genres: ["Drama"])
        #expect(AppleRecommendationRanker.rank([a, a, title("b")], history: [], ratings: [:], now: .distantPast, limit: 10).count == 2)
    }

    @Test func canonicalDedupRetainsAlternatePlaybackRoutes() {
        let a = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let b = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let item = AppleCatalogItem(mediaID: "tt1234567", type: "movie", name: "Film")
        let first = AppleMediaIngestion.catalogRecord(instanceID: a, item: item)
        let second = AppleMediaIngestion.catalogRecord(instanceID: b, item: item)
        let routes = AppleRecommendationInputs.playbackRoutes([first, second, first])
        #expect(routes.count == 2)
        #expect(Set(routes.map(\.instanceID)) == [a, b])
        #expect(AppleRecommendationInputs.playbackRoutes([second, first]) == routes)
    }

    @Test func oldCompletionDoesNotBorrowRecentPartialWatchDate() throws {
        let now = Date(timeIntervalSince1970: 10000000)
        let old = now.addingTimeInterval(-86400 * 60)
        let partial = ApplePlaybackProgress(position: 120, duration: 1000, updatedAt: now)
        let signal = try #require(AppleRecommendationInputs.signal(titleID: "film", genres: ["Drama"],
            progress: [partial], completedDates: [old], recordProgress: nil, now: now))
        #expect(signal.at == now)
        #expect(signal.completed == false)
        let recentCompletion = try #require(AppleRecommendationInputs.signal(titleID: "film", genres: [],
            progress: [partial], completedDates: [now.addingTimeInterval(-60)], recordProgress: nil, now: now))
        #expect(recentCompletion.at == now.addingTimeInterval(-60))
        #expect(recentCompletion.completed)
    }

    @Test func recommendationIdentityMemoReusesIDsButTracksIdentityMetadata() {
        let item = AppleCatalogItem(mediaID: "provider-film", type: "movie", name: "Film", year: 2020)
        var memo = AppleRecommendationInputs.IdentityMemo()
        let id = memo.identity(item, sourceID: "a")
        #expect(id == AppleRecommendationInputs.identity(item, sourceID: "a"))
        #expect(memo.identity(item.withHeroArtwork(backgroundURL: URL(string: "https://fixture.example/art"), logoURL: nil), sourceID: "a") == id)
        #expect(memo.count == 1)
        let remake = AppleCatalogItem(mediaID: "provider-film", type: "movie", name: "Film", year: 2024)
        #expect(memo.identity(remake, sourceID: "a") != id)
        #expect(memo.count == 2)
        let unknown = AppleCatalogItem(mediaID: "opaque", type: "movie", name: "Unknown")
        #expect(memo.identity(unknown, sourceID: "a") != memo.identity(unknown, sourceID: "b"))
    }

    @Test func recommendationMemoKeepsEnrichedGenresSeparateFromIdentity() {
        var memo = AppleRecommendationInputs.IdentityMemo()
        let original = AppleCatalogItem(mediaID: "fixture", type: "movie", name: "Film", genres: [" Drama ", "DRAMA"])
        let enriched = AppleCatalogItem(mediaID: "fixture", type: "movie", name: "Film", genres: ["Drama", "Comédie"])
        #expect(memo.genres(original) == ["drama"])
        #expect(memo.genres(enriched) == ["comedie", "drama"])
        #expect(memo.genres(original) == ["drama"])
    }

    @Test func recommendationMemoPreservesProgressAliasesAcrossMetadataChanges() {
        var memo = AppleRecommendationInputs.IdentityMemo()
        let source = UUID()
        for item in [
            AppleCatalogItem(mediaID: "fixture", type: "movie", name: "Film", releaseInfo: "2020"),
            AppleCatalogItem(mediaID: "fixture", type: "movie", name: "Film", releaseInfo: "2024"),
            AppleCatalogItem(mediaID: "tt2250912", type: "movie", name: "Film", releaseInfo: "2017"),
        ] {
            let expected = AppleTitleProgressIdentity.candidates(item: item, sourceID: source)
            #expect(memo.progressCandidates(item, sourceID: source) == expected)
            #expect(memo.progressCandidates(item.withHeroArtwork(backgroundURL: URL(string: "https://fixture.example/art"),
                logoURL: nil), sourceID: source) == expected)
        }
    }

    @Test func ratingRevisionChangesForSetRemovalAndRestore() throws {
        let suite = "recommendation-rating-revision-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AppleTitleRatingStore(defaults: defaults)
        var revision = AppleTitleRatingStore.revision
        store.set(.up, for: "tt1234567")
        #expect(AppleTitleRatingStore.revision > revision)
        revision = AppleTitleRatingStore.revision
        store.set(nil, for: "tt1234567")
        #expect(AppleTitleRatingStore.revision > revision)
        revision = AppleTitleRatingStore.revision
        store.restoreConfigurationRatings([ApplePlaybackIdentity.digest(for: "tt1234567"): AppleTitleRating.doubleUp.rawValue])
        #expect(AppleTitleRatingStore.revision > revision)
        #expect(store.rating(for: "tt1234567") == .doubleUp)
    }

}
