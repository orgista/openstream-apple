import Testing
import Foundation
@testable import OpenStreamApple

@Suite("AppleRecommendationRanker Tests")
struct AppleRecommendationRankerTests {
    
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
}
