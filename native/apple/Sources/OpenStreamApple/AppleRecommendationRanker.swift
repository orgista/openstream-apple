import Foundation

public struct AppleRankableTitle: Sendable, Equatable {
    public let id: String
    public let genres: [String]
    public let releaseYear: Int?
    public let metadataCompleteness: Double
    public let isResumable: Bool
    public let isCompleted: Bool

    public init(id: String, genres: [String], releaseYear: Int?, metadataCompleteness: Double, isResumable: Bool, isCompleted: Bool) {
        self.id = id
        self.genres = genres
        self.releaseYear = releaseYear
        self.metadataCompleteness = max(0, min(1, metadataCompleteness))
        self.isResumable = isResumable
        self.isCompleted = isCompleted
    }
}

public struct AppleViewingSignal: Sendable, Equatable {
    public let titleID: String
    public let genres: [String]
    public let at: Date
    public let completed: Bool

    public init(titleID: String, genres: [String], at: Date, completed: Bool) {
        self.titleID = titleID
        self.genres = genres
        self.at = at
        self.completed = completed
    }
}

public enum AppleTitleRating: Int, Sendable, Equatable {
    case down = -1
    case none = 0
    case up = 1
    case doubleUp = 2
}

public enum AppleRecommendationRanker {
    public static func rank(
        _ titles: [AppleRankableTitle],
        history: [AppleViewingSignal],
        ratings: [String: AppleTitleRating],
        now: Date,
        limit: Int
    ) -> [AppleRankableTitle] {
        
        struct HistoryStats {
            var genres: Set<String>
            var mostRecentAt: Date
            var visits: Int
        }
        
        var historySummary: [String: HistoryStats] = [:]
        for signal in history {
            if let existing = historySummary[signal.titleID] {
                historySummary[signal.titleID] = HistoryStats(
                    genres: existing.genres.union(signal.genres),
                    mostRecentAt: max(existing.mostRecentAt, signal.at),
                    visits: existing.visits + 1
                )
            } else {
                historySummary[signal.titleID] = HistoryStats(
                    genres: Set(signal.genres),
                    mostRecentAt: signal.at,
                    visits: 1
                )
            }
        }
        
        let validTitles = titles.filter { title in
            return ratings[title.id] != .down
        }
        
        typealias ScoredTitle = (title: AppleRankableTitle, score: Double)
        
        var scoredTitles: [ScoredTitle] = validTitles.map { title in
            let titleGenres = Set(title.genres)
            var affinityScore: Double = 0

            if let rating = ratings[title.id] {
                affinityScore += rating == .doubleUp ? 200 : 100
            }
            
            if !titleGenres.isEmpty {
                for (_, stats) in historySummary {
                    let overlap = Double(titleGenres.intersection(stats.genres).count)
                    if overlap > 0 {
                        let daysAgo = max(0, now.timeIntervalSince(stats.mostRecentAt) / 86400.0)
                        let recencyWeight = pow(0.5, daysAgo / 14.0)
                        let repeatFactor = log1p(Double(stats.visits))
                        affinityScore += overlap * recencyWeight * repeatFactor
                    }
                }
            }
            
            if let rating = ratings[title.id] {
                if rating == .up {
                    affinityScore *= 1.5
                } else if rating == .doubleUp {
                    affinityScore *= 2.5
                }
            }
            
            return (title: title, score: affinityScore)
        }
        
        scoredTitles.sort { lhs, rhs in
            let l = lhs.title
            let r = rhs.title
            
            if l.isResumable != r.isResumable {
                return l.isResumable
            }
            
            // completed titles after unwatched at equal score; wait, it says:
            // "completed titles after unwatched at equal score"
            // Let's check completed status first? "completed titles after unwatched at equal score"
            // Wait, does it mean completed titles are always after unwatched IF their scores are equal?
            // "resumable first; then affinity score... completed titles after unwatched at equal score"
            // This means score takes precedence over completed.
            
            // Wait, to be safe against floating point equality, let's use a small epsilon or just exact equality.
            if abs(lhs.score - rhs.score) > 1e-8 {
                return lhs.score > rhs.score
            }
            
            if l.isCompleted != r.isCompleted {
                return !l.isCompleted // false (unwatched) comes before true (completed)
            }
            
            let lYear = l.releaseYear ?? Int.min
            let rYear = r.releaseYear ?? Int.min
            if lYear != rYear {
                return lYear > rYear
            }
            
            if abs(l.metadataCompleteness - r.metadataCompleteness) > 1e-8 {
                return l.metadataCompleteness > r.metadataCompleteness
            }
            
            return l.id < r.id
        }
        
        let result = scoredTitles.prefix(limit).map { $0.title }
        return Array(result)
    }
}
