import Foundation

enum AppleRecommendationRowScorer {
    static let maximumRows = 1
    static let maximumItems = 20

    struct Title: Sendable {
        let rankable: AppleRankableTitle
        let name: String
    }

    struct Row: Sendable, Equatable {
        let id: String
        let heading: String
        let ids: [String]
        var minimumCount: Int = AppleRecommendationRowPolicy.minimumItems
    }

    static func day(_ now: Date) -> Int { Int(floor(now.timeIntervalSince1970 / 86400)) }

    static func displayIdentity(_ item: AppleCatalogItem, source: AppleSource? = nil) -> String {
        // Charts may lack the IMDb ID carried by an owned copy. This only hides duplicate cards;
        // it never merges playback routes or changes the title's saved identity.
        if AppleRecommendationInputs.releaseYear(item) != nil, !item.name.isEmpty,
           let titleKey = AppleTMDBRelation.Target.keys(item).last { return titleKey }
        return AppleCatalogShelfPolicy.identity(item, source: source)
    }

    @concurrent nonisolated static func build(_ input: [Title], history: [AppleViewingSignal],
        ratings: [String: AppleTitleRating], listIDs: Set<String>, relationIDs: [String: Set<String>] = [:],
        now: Date, limit: Int = maximumRows) async throws -> [Row] {
        try Task.checkCancellation()
        guard limit > 0 else { return [] }
        let finished = history.filter(\.completed)
        let finishedIDs = Set(finished.map { $0.showID ?? $0.titleID })
        guard finishedIDs.count >= AppleRecommendationRowPolicy.minimumFinishedTitles else { return [] }
        let titles = Dictionary(input.map { ($0.rankable.id, $0) }, uniquingKeysWith: { first, _ in first })
        let affinity = affinities(input, history: history, ratings: ratings, listIDs: listIDs, now: now)
        let seeds = AppleRecommendationRowPolicy.seedOrder(finished, ratings: ratings)
        let eligible = titles.values.filter {
            !$0.rankable.isCompleted && !$0.rankable.isResumable && !finishedIDs.contains($0.rankable.id)
                && ratings[$0.rankable.id] != .down
        }.sorted {
            let lhs = (affinity[$0.rankable.id] ?? 0) + AppleRecommendationRanker.quality($0.rankable.quality)
                + AppleRecommendationRanker.freshness(addedAt: $0.rankable.addedAt, now: now)
            let rhs = (affinity[$1.rankable.id] ?? 0) + AppleRecommendationRanker.quality($1.rankable.quality)
                + AppleRecommendationRanker.freshness(addedAt: $1.rankable.addedAt, now: now)
            return lhs == rhs ? $0.rankable.id < $1.rankable.id : lhs > rhs
        }
        for signal in seeds {
            try Task.checkCancellation()
            let seedID = signal.showID ?? signal.titleID
            guard let seed = titles[seedID] else { continue }
            let genres = Set(seed.rankable.genres), people = Set(seed.rankable.people)
            let related = eligible.filter {
                let title = $0.rankable
                return !genres.isDisjoint(with: title.genres) || !people.isDisjoint(with: title.people)
                    || relationIDs[title.id]?.contains(seedID) == true
            }.map(\.rankable.id)
            guard let heading = AppleRecommendationRowPolicy.heading(seed: seed.name, count: related.count) else { continue }
            let ids = Array(related.prefix(maximumItems))
            return [Row(id: "seed:\(seedID)", heading: heading, ids: ids,
                minimumCount: AppleRecommendationRowPolicy.minimumItems)]
        }
        return []
    }

    static func affinities(_ titles: [Title], history: [AppleViewingSignal], ratings: [String: AppleTitleRating],
                           listIDs: Set<String>, now: Date) -> [String: Double] {
        var genres: [String: Double] = [:], people: [String: Double] = [:]
        func add(_ seedGenres: [String], _ seedPeople: [String], weight: Double) {
            for genre in seedGenres { genres[genre, default: 0] += weight }
            for person in seedPeople { people[person, default: 0] += weight * 0.5 }
        }
        let bounded = AppleRecommendationInputs.boundedHistory(history, now: now)
        for signal in bounded where ratings[signal.showID ?? signal.titleID] != .down && ratings[signal.titleID] != .down {
            add(signal.genres, signal.people, weight: AppleRecommendationInputs.viewingWeight(signal, now: now))
        }
        var represented = Set<String>()
        for value in titles where represented.insert(value.rankable.id).inserted {
            let title = value.rankable
            guard ratings[title.id] != .down else { continue }
            let weight = Double(max(0, ratings[title.id]?.rawValue ?? 0)) * 0.75 + (listIDs.contains(title.id) ? 0.35 : 0)
            if weight > 0 { add(title.genres, title.people, weight: weight) }
        }
        for signal in bounded where !represented.contains(signal.titleID) && ratings[signal.titleID] != .down {
            let weight = Double(max(0, ratings[signal.titleID]?.rawValue ?? 0)) * 0.75 + (listIDs.contains(signal.titleID) ? 0.35 : 0)
            if weight > 0 { add(signal.genres, signal.people, weight: weight) }
        }
        return Dictionary(titles.map { value in
            let title = value.rankable
            let genre = title.genres.reduce(0) { $0 + (genres[$1] ?? 0) } / Double(max(1, title.genres.count))
            let person = title.people.reduce(0) { $0 + (people[$1] ?? 0) }
            return (title.id, min(4, genre) + min(1, person))
        }, uniquingKeysWith: { first, _ in first })
    }

}
