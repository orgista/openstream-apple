import Foundation

enum AppleDiscoverRowOrder {
    static let continueWatching = "continueWatching"
    static let services = "services"
    static let top10 = "top10"
    static let featuredMovies = "featuredMovies"
    static let recentlyAdded = "recentlyAdded"
    static let featuredShows = "featuredShows"
    static let becauseWatched = "becauseWatched"
    static let popularMovies = "popularMovies"
    static let popularShows = "popularShows"
    static let serverPrefix = "server:"
    static let top10Title = "Top 10 This Week"
    static let maximumRows = 12
    static let maximumServerRows = 3
    static let maximumItems = 30

    static let builtInIDs = [continueWatching, services, top10, featuredMovies, recentlyAdded,
                             featuredShows, becauseWatched, popularMovies, popularShows]

    struct Row: Sendable {
        let id: String
        var keys: [String]
        var minimumCount = 0
        var isLoading = false
    }

    static func title(forBuiltIn id: String) -> String? {
        switch id {
        case continueWatching: "Continue Watching"
        case services: "Services"
        case top10: top10Title
        case featuredMovies: "Featured Movies"
        case recentlyAdded: "Recently Added"
        case featuredShows: "Featured Shows"
        case becauseWatched: "Because You Watched"
        case popularMovies: "Popular Movies"
        case popularShows: "Popular Shows"
        default: nil
        }
    }

    static func title(for id: String, defaultTitle: String? = nil, customNames: [String: String] = [:]) -> String {
        if let custom = customNames[id]?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty { return custom }
        return defaultTitle ?? title(forBuiltIn: id) ?? ""
    }

    static func ordered(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }.enumerated().sorted {
            let left = builtInIDs.firstIndex(of: $0.element) ?? builtInIDs.count
            let right = builtInIDs.firstIndex(of: $1.element) ?? builtInIDs.count
            return left == right ? $0.offset < $1.offset : left < right
        }.map(\.element)
    }

    static func rows(_ candidates: [Row], hidden: Set<String> = []) -> [Row] {
        let byID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var pending = ordered(candidates.map(\.id)).filter { !hidden.contains($0) }.compactMap { byID[$0] }
        var claimed = Set<String>()
        var result: [Row] = []
        var serverCount = 0
        while let next = pending.first, result.count < maximumRows {
            let index: Int
            if result.last.map({ isFeatured($0.id) }) == true, isFeatured(next.id) {
                // A separator must survive dedupe before the second Featured row claims anything.
                guard let separator = pending.firstIndex(where: { !isFeatured($0.id) }) else { break }
                index = separator
            } else {
                index = 0
            }
            var row = pending.remove(at: index)
            let isServer = row.id.hasPrefix(serverPrefix)
            if isServer && serverCount == maximumServerRows { continue }
            var seen = Set<String>()
            row.keys = Array(row.keys.filter {
                (row.id == top10 || !claimed.contains($0)) && seen.insert($0).inserted
            }.prefix(maximumItems(for: row.id)))
            if row.keys.count < max(minimumItems(for: row.id), row.minimumCount) {
                guard row.isLoading else { continue }
            } else {
                claimed.formUnion(row.keys)
            }
            result.append(row)
            if isServer { serverCount += 1 }
        }
        return result
    }

    private static func isFeatured(_ id: String) -> Bool { id == featuredMovies || id == featuredShows }

    private static func minimumItems(for id: String) -> Int {
        switch id {
        case continueWatching, services: 1
        case top10: 5
        case becauseWatched: AppleRecommendationRowPolicy.minimumItems
        default: 6
        }
    }

    private static func maximumItems(for id: String) -> Int {
        switch id {
        case continueWatching: 20
        case top10: 10
        case services: Int.max
        default: maximumItems
        }
    }
}
