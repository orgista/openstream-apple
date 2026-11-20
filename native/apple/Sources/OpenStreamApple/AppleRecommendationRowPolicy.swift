import Foundation

enum AppleRecommendationRowPolicy {
    static let minimumFinishedTitles = 10
    static let minimumItems = 8

    /// Seeds for those rows: titles the viewer liked, then ones they
    /// finished, then ones they started, each group in the given (most
    /// recent first) order. A disliked title seeds nothing.
    static func seedOrder(_ history: [AppleViewingSignal], ratings: [String: AppleTitleRating]) -> [AppleViewingSignal] {
        func rating(_ seed: AppleViewingSignal) -> AppleTitleRating? {
            ratings[seed.showID ?? seed.titleID] ?? ratings[seed.titleID]
        }
        func rank(_ seed: AppleViewingSignal) -> Int {
            switch rating(seed) {
            case .up, .doubleUp: 0
            default: seed.completed ? 1 : 2
            }
        }
        return history.enumerated()
            .filter { rating($0.element) != .down }
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
    }

    static func heading(seed: String, count: Int) -> String? {
        let title = seed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, count >= minimumItems else { return nil }
        return "Because You Watched \(title)"
    }
}
