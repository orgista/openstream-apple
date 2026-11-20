import Foundation

public struct AppleRankableTitle: Sendable, Equatable {
    public let id: String
    public let genres: [String]
    public let releaseYear: Int?
    public let metadataCompleteness: Double
    public let isResumable: Bool
    public let isCompleted: Bool
    public let primaryGenre: String?
    public let franchiseID: String?
    public let sourceID: String?
    /// Lead cast and director, normalized (`AppleRecommendationInputs.people`).
    public let people: [String]
    /// When the title reached the viewer's library; nil when unknown.
    public let addedAt: Date?
    /// The title's public score out of 10; nil when unknown.
    public let quality: Double?

    public init(id: String, genres: [String], releaseYear: Int?, metadataCompleteness: Double, isResumable: Bool, isCompleted: Bool, primaryGenre: String? = nil, franchiseID: String? = nil, sourceID: String? = nil,
                people: [String] = [], addedAt: Date? = nil, quality: Double? = nil) {
        self.id = id
        self.genres = AppleRecommendationInputs.normalizedGenres(genres)
        self.releaseYear = releaseYear
        self.metadataCompleteness = metadataCompleteness.isFinite ? max(0, min(1, metadataCompleteness)) : 0
        self.isResumable = isResumable
        self.isCompleted = isCompleted
        self.primaryGenre = primaryGenre ?? genres.first
        self.franchiseID = franchiseID
        self.sourceID = sourceID
        self.people = AppleRecommendationInputs.normalizedPeople(people)
        self.addedAt = addedAt
        self.quality = quality.flatMap { $0.isFinite ? $0 : nil }
    }
}

public struct AppleViewingSignal: Sendable, Equatable {
    public let titleID: String
    public let genres: [String]
    public let at: Date?
    public let showID: String?
    public let completed: Bool
    public let people: [String]

    public init(titleID: String, genres: [String], at: Date?, completed: Bool, showID: String? = nil, people: [String] = []) {
        self.titleID = titleID
        self.genres = AppleRecommendationInputs.normalizedGenres(genres)
        self.people = AppleRecommendationInputs.normalizedPeople(people)
        self.at = at
        self.showID = showID
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
    struct Seed: Sendable, Equatable {
        enum Kind: String, Sendable { case viewing, liked, related, people }
        let digest: String
        let kind: Kind
        let contribution: Double
    }

    struct Candidate: Sendable, Equatable {
        let title: AppleRankableTitle
        let viewingScore: Double
        let likedScore: Double
        let ratingScore: Double
        var relationScore: Double = 0
        var peopleScore: Double = 0
        var freshnessScore: Double = 0
        var qualityScore: Double = 0
        var diversityPenalty: Double = 0
        let seeds: [Seed]
        /// Taste evidence: a candidate with none is not "for you".
        var affinity: Double { viewingScore + likedScore + relationScore + peopleScore }
        var score: Double { affinity + ratingScore + freshnessScore + qualityScore - diversityPenalty }
        var debugTrace: String {
            "recommendation candidate=\(ApplePlaybackIdentity.digest(for: title.id)) viewing=\(viewingScore) liked=\(likedScore) rating=\(ratingScore) related=\(relationScore) people=\(peopleScore) fresh=\(freshnessScore) quality=\(qualityScore) diversity=\(diversityPenalty) seeds="
                + seeds.map { "\($0.kind.rawValue):\($0.digest):\($0.contribution)" }.joined(separator: ",")
        }
    }

    private static func ratingWeight(_ rating: AppleTitleRating?) -> Double {
        switch rating { case .some(.up): 1; case .some(.doubleUp): 2; case .some(.none), nil, .some(.down): 0 }
    }

    /// Up to 0.3 for an unseen title that arrived lately, halving every 14 days.
    static func freshness(addedAt: Date?, now: Date) -> Double {
        guard let addedAt else { return 0 }
        return 0.3 * pow(0.5, max(0, now.timeIntervalSince(addedAt) / 86400) / 14)
    }

    /// Up to 0.3 for a well-rated title: nothing at 6/10 or below, full at 10.
    static func quality(_ score: Double?) -> Double {
        guard let score else { return 0 }
        return 0.3 * max(0, min(1, (score - 6) / 4))
    }

    /// 0.5 per shared lead actor or director, at most 1, times the seed's weight.
    static func peopleOverlap(_ people: Set<String>, _ seedPeople: Set<String>) -> Double {
        min(1, Double(people.intersection(seedPeople).count) * 0.5)
    }

    public static func rank(
        _ titles: [AppleRankableTitle],
        history: [AppleViewingSignal],
        ratings: [String: AppleTitleRating],
        now: Date,
        limit: Int,
        preferUnseen: Bool = false,
        relationIDs: [String: Set<String>] = [:]
    ) -> [AppleRankableTitle] {
        let result = rankWithProvenance(titles, history: history, ratings: ratings, now: now, limit: limit, preferUnseen: preferUnseen, relationIDs: relationIDs)
        #if DEBUG
        for candidate in result { AppleInteractionTrace.record(.screen, candidate.debugTrace) }
        #endif
        return result.map(\.title)
    }

    static func rankWithProvenance(_ titles: [AppleRankableTitle], history: [AppleViewingSignal],
                                   ratings: [String: AppleTitleRating], now: Date, limit: Int, preferUnseen: Bool = false,
                                   relationIDs: [String: Set<String>] = [:], requiresAffinity: Bool = false) -> [Candidate] {
        guard limit > 0 else { return [] }
        // One strongest observation per title/show. Saves are snapshots, not
        // visits, and a hundred episodes must not outweigh a hundred films.
        struct HistoryStats {
            var genres: Set<String>
            var people: Set<String>
            var weight: Double
        }
        var historySummary: [String: HistoryStats] = [:]
        for signal in history {
            let weight = AppleRecommendationInputs.viewingWeight(signal, now: now)
            let key = signal.showID ?? signal.titleID
            if let existing = historySummary[key] {
                historySummary[key] = HistoryStats(genres: existing.genres.union(signal.genres),
                                                  people: existing.people.union(signal.people),
                                                  weight: max(existing.weight, weight))
            } else {
                historySummary[key] = HistoryStats(genres: Set(signal.genres), people: Set(signal.people), weight: weight)
            }
        }
        let viewingSeeds = historySummary.keys.sorted().compactMap { key -> (String, HistoryStats)? in
            guard let stats = historySummary[key] else { return nil }
            return (ApplePlaybackIdentity.digest(for: key), stats)
        }
        // Bounded liked seeds also include history titles no longer in a shelf.
        var likedGenres: [String: Set<String>] = [:]
        var likedPeople: [String: Set<String>] = [:]
        for title in titles {
            likedGenres[title.id, default: []].formUnion(title.genres)
            likedPeople[title.id, default: []].formUnion(title.people)
        }
        for signal in history {
            likedGenres[signal.titleID, default: []].formUnion(signal.genres)
            likedPeople[signal.titleID, default: []].formUnion(signal.people)
        }
        let likedSeeds = ratings.keys.sorted().compactMap { id -> (String, String, Set<String>, Double)? in
            let weight = ratingWeight(ratings[id])
            guard weight > 0, let genres = likedGenres[id], !genres.isEmpty else { return nil }
            return (id, ApplePlaybackIdentity.digest(for: id), genres, weight)
        }
        let likedPeopleSeeds = ratings.keys.sorted().compactMap { id -> (String, String, Set<String>, Double)? in
            let weight = ratingWeight(ratings[id])
            guard weight > 0, let people = likedPeople[id], !people.isEmpty else { return nil }
            return (id, ApplePlaybackIdentity.digest(for: id), people, weight)
        }
        let viewedPeopleSeeds = viewingSeeds.filter { !$0.1.people.isEmpty }.map { ($0.0, $0.1.people, $0.1.weight) }
        typealias ScoredTitle = Candidate
        var seen = Set<String>()
        let validTitles = titles.filter { ratings[$0.id] != .down && seen.insert($0.id).inserted }
        var scoredTitles: [ScoredTitle] = validTitles.map { title in
            let genres = Set(title.genres)
            let ownDigest = ApplePlaybackIdentity.digest(for: title.id)
            var seeds: [Seed] = []
            var viewingAffinity: Double = 0
            if !genres.isEmpty {
                for (digest, stats) in viewingSeeds where digest != ownDigest {
                    let overlap = Double(genres.intersection(stats.genres).count) / Double(genres.count)
                    let contribution = overlap * stats.weight
                    viewingAffinity += contribution
                    if contribution > 0 {
                        seeds.append(Seed(digest: digest, kind: .viewing,
                                          contribution: contribution))
                    }
                }
            }
            var likedAffinity: Double = 0
            for (id, digest, seedGenres, weight) in likedSeeds where id != title.id && !genres.isEmpty {
                let overlap = Double(genres.intersection(seedGenres).count) / Double(genres.count)
                let contribution = overlap * weight * 0.5
                likedAffinity += contribution
                if contribution > 0 {
                    seeds.append(Seed(digest: digest, kind: .liked,
                                      contribution: contribution))
                }
            }
            let related = (relationIDs[title.id] ?? []).sorted().compactMap { seed -> Seed? in
                guard let stats = historySummary[seed], stats.weight > 0 else { return nil }
                return Seed(digest: ApplePlaybackIdentity.digest(for: seed), kind: .related,
                            contribution: min(1, stats.weight))
            }
            seeds += related
            var peopleAffinity: Double = 0
            let people = Set(title.people)
            if !people.isEmpty {
                let liked = likedPeopleSeeds.filter { $0.0 != title.id }.map { ($0.1, $0.2, $0.3 * 0.5) }
                for (digest, seedPeople, weight) in viewedPeopleSeeds + liked where digest != ownDigest {
                    let contribution = peopleOverlap(people, seedPeople) * weight
                    peopleAffinity += contribution
                    if contribution > 0 { seeds.append(Seed(digest: digest, kind: .people, contribution: contribution)) }
                }
            }
            let unseen = !title.isResumable && !title.isCompleted
            // Each component uses the same small scale; explicit ratings no
            // longer add 100/200 then multiply every other signal.
            return Candidate(title: title, viewingScore: min(4, viewingAffinity), likedScore: min(1, likedAffinity),
                             ratingScore: ratingWeight(ratings[title.id]), relationScore: min(1, related.reduce(0) { $0 + $1.contribution }),
                             peopleScore: min(1, peopleAffinity),
                             freshnessScore: unseen ? freshness(addedAt: title.addedAt, now: now) : 0,
                             qualityScore: quality(title.quality), seeds: seeds)
        }

        if requiresAffinity {
            scoredTitles.removeAll { $0.affinity <= 0 }
        }

        func ordered(_ lhs: ScoredTitle, _ rhs: ScoredTitle) -> Bool {
            let l = lhs.title
            let r = rhs.title
            
            if preferUnseen {
                let lSeen = l.isResumable || l.isCompleted
                let rSeen = r.isResumable || r.isCompleted
                if lSeen != rSeen { return !lSeen }
            }
            if !preferUnseen, l.isResumable != r.isResumable {
                return l.isResumable
            }
            
            if lhs.score != rhs.score {
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
            
            if l.metadataCompleteness != r.metadataCompleteness {
                return l.metadataCompleteness > r.metadataCompleteness
            }
            
            return l.id < r.id
        }
        
        var selected: [AppleCatalogShelfPolicy.DiversitySignals] = []
        var result: [Candidate] = []
        while !scoredTitles.isEmpty, result.count < limit {
            let adjusted = scoredTitles.map { value -> ScoredTitle in
                let signals = AppleCatalogShelfPolicy.DiversitySignals(primaryGenre: value.title.primaryGenre,
                    franchise: value.title.franchiseID, source: value.title.sourceID)
                var adjusted = value
                adjusted.diversityPenalty = AppleCatalogShelfPolicy.diversityPenalty(signals, selected: selected, unit: 0.35)
                return adjusted
            }
            guard let best = adjusted.min(by: ordered) else { break }
            result.append(best)
            selected.append(AppleCatalogShelfPolicy.DiversitySignals(primaryGenre: best.title.primaryGenre,
                franchise: best.title.franchiseID, source: best.title.sourceID))
            scoredTitles.removeAll { $0.title.id == best.title.id }
        }
        return result
    }
}

/// Pure inputs from metadata and saved playback snapshots. Never fetches.
enum AppleRecommendationInputs {
    /// Scoped to one snapshot: artwork/genre enrichment can reuse an ID,
    /// while kind, year, canonical IDs and source-local identities cannot.
    struct IdentityMemo {
        private struct Key: Hashable {
            let mediaID: String
            let type: String
            let name: String
            let year: Int?
            let releaseInfo: String?
            let imdbID: String?
            let sourceID: String
        }
        private var identities: [Key: String] = [:]
        private var genreValues: [[String]: [String]] = [:]
        private var progressKeys: [Key: [String]] = [:]
        var count: Int { identities.count }

        mutating func identity(_ item: AppleCatalogItem, sourceID: String) -> String {
            let key = key(for: item, sourceID: sourceID)
            if let id = identities[key] { return id }
            let id = AppleRecommendationInputs.identity(item, sourceID: sourceID)
            identities[key] = id
            return id
        }

        mutating func genres(_ item: AppleCatalogItem) -> [String] {
            let raw = item.genres ?? []
            if let genres = genreValues[raw] { return genres }
            let genres = AppleRecommendationInputs.normalizedGenres(raw)
            genreValues[raw] = genres
            return genres
        }

        mutating func progressCandidates(_ item: AppleCatalogItem, sourceID: AppleSource.ID) -> [String] {
            let key = key(for: item, sourceID: sourceID.uuidString)
            if let keys = progressKeys[key] { return keys }
            let keys = AppleTitleProgressIdentity.candidates(item: item, sourceID: sourceID)
            progressKeys[key] = keys
            return keys
        }

        private func key(for item: AppleCatalogItem, sourceID: String) -> Key {
            Key(mediaID: item.mediaID, type: item.type, name: item.name, year: item.year,
                releaseInfo: item.releaseInfo, imdbID: item.imdbID, sourceID: sourceID)
        }

    }

    static func normalizedGenres(_ values: [String]) -> [String] {
        Array(Set(values.flatMap { value -> [String] in
            let genre = value.trimmingCharacters(in: .whitespacesAndNewlines)
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .lowercased()
            switch genre {
            case "science fiction", "sci fi": return ["sci-fi"]
            case "sci-fi & fantasy": return ["sci-fi", "fantasy"]
            case "action & adventure": return ["action", "adventure"]
            case "war & politics": return ["war", "politics"]
            default: return genre.isEmpty ? [] : [genre]
            }
        })).sorted()
    }

    static func genres(_ item: AppleCatalogItem) -> [String] { normalizedGenres(item.genres ?? []) }

    /// The director and the first five billed actors: the people a viewer
    /// follows from one title to the next.
    static func people(_ item: AppleCatalogItem) -> [String] {
        normalizedPeople([item.director].compactMap { $0 } + (item.cast ?? []).prefix(5))
    }

    static func normalizedPeople(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            let name = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return !name.isEmpty && seen.insert(name).inserted ? name : nil
        }
    }

    static func releaseYear(_ item: AppleCatalogItem) -> Int? {
        if let year = item.year { return year }
        guard let raw = item.releaseInfo?.trimmingCharacters(in: .whitespacesAndNewlines),
              raw.count >= 4, raw.prefix(4).allSatisfy({ $0.isASCII && $0.isNumber }),
              raw.dropFirst(4).first?.isNumber != true,
              let year = Int(raw.prefix(4)), (1870...2200).contains(year) else { return nil }
        return year
    }

    static func identity(_ item: AppleCatalogItem, sourceID: String = "") -> String {
        let mediaID = item.mediaID.lowercased()
        let parts = mediaID.split(separator: ":")
        let episode = AppleMediaSeriesInfo(mediaID: mediaID)
        let suffix = episode.map { "|s\($0.season)e\($0.episode)" } ?? ""
        let root = episode == nil ? mediaID : parts.dropLast(2).joined(separator: ":")
        let strongID = item.imdbID ?? (AppleMediaIdentifier.isIMDBIdentifier(root) ? root : nil)
            ?? (root.hasPrefix("tmdb:") ? root : nil)
        let identity: String
        if let strongID {
            identity = "\(item.type)|id|\(strongID)\(suffix)"
        } else if let year = releaseYear(item), !item.name.isEmpty {
            let name = item.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            identity = "\(item.type)|title|\(name)|\(year)\(suffix)"
        } else {
            // Unknown year and opaque IDs cannot safely merge by name alone.
            identity = "\(item.type)|source|\(sourceID)|\(mediaID)"
        }
        return ApplePlaybackIdentity.digest(for: identity)
    }

    static func metadataCompleteness(_ item: AppleCatalogItem) -> Double {
        Double([item.summary != nil, item.posterURL != nil, item.backgroundURL != nil,
                releaseYear(item) != nil, item.rating != nil, !genres(item).isEmpty,
                item.logoURL != nil, item.imdbID != nil].filter { $0 }.count) / 8
    }

    static func prefers(_ item: AppleCatalogItem, sourceID: String, accessible: Bool,
                        over other: AppleCatalogItem, sourceID otherSourceID: String, accessible otherAccessible: Bool) -> Bool {
        if accessible != otherAccessible { return accessible }
        let quality = metadataCompleteness(item), otherQuality = metadataCompleteness(other)
        if quality != otherQuality { return quality > otherQuality }
        return sourceID + "|" + item.id < otherSourceID + "|" + other.id
    }

    static func playbackRoutes(_ records: [AppleMediaRecord]) -> [AppleMediaAvailability] {
        var routes: [String: AppleMediaAvailability] = [:]
        for route in records.flatMap(\.availability) {
            let key = route.instanceID.uuidString + "|" + route.itemReference
            if let old = routes[key], old.lastVerified >= route.lastVerified { continue }
            routes[key] = route
        }
        return routes.keys.sorted().compactMap { routes[$0] }
    }

    static func signal(titleID: String, genres: [String], people: [String] = [], progress: [ApplePlaybackProgress],
                       completedDates: [Date], recordProgress: Double?, showID: String? = nil, now: Date = .now) -> AppleViewingSignal? {
        let meaningful = progress.filter {
            $0.position.isFinite && $0.duration.isFinite && $0.duration > 0
                && ($0.isComplete || $0.position >= 60 || $0.position / $0.duration >= 0.05)
        }
        let observations = meaningful.map {
            AppleViewingSignal(titleID: titleID, genres: genres, at: $0.updatedAt,
                               completed: $0.isComplete, showID: showID, people: people)
        } + completedDates.map {
            AppleViewingSignal(titleID: titleID, genres: genres, at: $0, completed: true, showID: showID, people: people)
        }
        if !observations.isEmpty { return boundedHistory(observations, now: now, limit: 1).first }
        guard let fraction = recordProgress, fraction.isFinite, fraction >= 0.05 else { return nil }
        return AppleViewingSignal(titleID: titleID, genres: genres, at: nil,
            completed: fraction >= ApplePlaybackProgress.completionFraction, showID: showID, people: people)
    }

    static func viewingWeight(_ signal: AppleViewingSignal, now: Date) -> Double {
        let recency = signal.at.map { pow(0.5, max(0, now.timeIntervalSince($0) / 86400) / 14) } ?? 0.25
        return recency * (signal.completed ? 1 : 0.5)
    }

    static func boundedHistory(_ values: [AppleViewingSignal], now: Date = .now, limit: Int = 500) -> [AppleViewingSignal] {
        var byTitle: [String: AppleViewingSignal] = [:]
        for value in values {
            let key = value.showID ?? value.titleID
            if let old = byTitle[key] {
                // Keep the strongest actual observation. Combining an old
                // completion with a recent partial date would invent evidence.
                let weight = viewingWeight(value, now: now), oldWeight = viewingWeight(old, now: now)
                let chosen = weight > oldWeight || (weight == oldWeight && value.titleID < old.titleID) ? value : old
                byTitle[key] = AppleViewingSignal(titleID: chosen.titleID, genres: old.genres + value.genres,
                    at: chosen.at, completed: chosen.completed, showID: chosen.showID, people: old.people + value.people)
            } else { byTitle[key] = value }
        }
        return Array(byTitle.values.sorted {
            if $0.at != $1.at { return ($0.at ?? .distantPast) > ($1.at ?? .distantPast) }
            return $0.titleID < $1.titleID
        }.prefix(max(0, limit)))
    }
}
