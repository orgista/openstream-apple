import Foundation
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

/// A title reduced to the content signals "More Like This" scores on.
public struct AppleSimilarTitleProfile: Sendable, Equatable, Identifiable {
    public let id: String
    /// Canonical IMDb id when the media id is one, used to dedupe the same
    /// title arriving from several catalogs.
    public let canonicalID: String?
    public let type: String
    public let title: String
    public let genres: [String]
    public let overview: String?
    public let cast: [String]
    public let director: String?
    public let writers: [String]
    public let year: Int?
    public let imdbRating: Double?
    public let keywords: Set<String>

    public init(
        id: String,
        type: String,
        title: String,
        genres: [String] = [],
        overview: String? = nil,
        cast: [String] = [],
        director: String? = nil,
        writers: [String] = [],
        year: Int? = nil,
        imdbRating: Double? = nil,
        keywords: Set<String> = [],
        canonicalID: String? = nil
    ) {
        self.id = id
        self.type = type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.title = title
        self.genres = genres.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        self.overview = overview
        self.cast = cast
        self.director = director
        self.writers = writers
        self.year = year
        self.imdbRating = imdbRating
        self.keywords = keywords
        self.canonicalID = canonicalID
    }

    public var primaryGenre: String? { genres.first.map { $0.lowercased() } }

    public func withKeywords(_ keywords: Set<String>) -> AppleSimilarTitleProfile {
        AppleSimilarTitleProfile(
            id: id,
            type: type,
            title: title,
            genres: genres,
            overview: overview,
            cast: cast,
            director: director,
            writers: writers,
            year: year,
            imdbRating: imdbRating,
            keywords: keywords,
            canonicalID: canonicalID
        )
    }
}

public extension AppleSimilarTitleProfile {
    init(item: AppleCatalogItem) {
        self.init(
            id: item.id,
            type: item.type,
            title: item.name,
            genres: item.genres ?? [],
            overview: item.summary,
            cast: item.cast ?? [],
            director: item.director,
            writers: item.writers ?? [],
            year: item.year ?? AppleStremioMetadataClient.leadingYear(item.releaseInfo),
            imdbRating: item.rating,
            canonicalID: AppleStremioMetadataClient.canonicalMediaID(item.mediaID)
        )
    }
}

/// One ranked suggestion with the score that put it there. `components` is kept
/// so a failure or an odd ordering can be explained without re-running the ranker.
public struct AppleSimilarTitleCandidate: Sendable, Equatable, Identifiable {
    public let profile: AppleSimilarTitleProfile
    public let score: Double
    public let genreScore: Double
    public let keywordScore: Double
    public let peopleScore: Double
    public let yearScore: Double
    public let ratingScore: Double
    public let diversityPenalty: Double

    public var id: String { profile.id }

    public init(
        profile: AppleSimilarTitleProfile,
        score: Double,
        genreScore: Double = 0,
        keywordScore: Double = 0,
        peopleScore: Double = 0,
        yearScore: Double = 0,
        ratingScore: Double = 0,
        diversityPenalty: Double = 0
    ) {
        self.profile = profile
        self.score = score
        self.genreScore = genreScore
        self.keywordScore = keywordScore
        self.peopleScore = peopleScore
        self.yearScore = yearScore
        self.ratingScore = ratingScore
        self.diversityPenalty = diversityPenalty
    }
}

public extension AppleRecommendationRanker {
    static let similarGenreWeight: Double = 35
    static let similarKeywordWeight: Double = 25
    static let similarDiversityPenalty: Double = 10

    /// Content-based "More Like This" ranking. Deterministic and on-device: no
    /// network, no personalisation, same input always gives the same order.
    ///
    /// 100 points total — genre Jaccard x35, synopsis keyword Jaccard x25,
    /// cast/crew overlap up to 20 (director +10, each shared cast or writer +5,
    /// capped at 10), year proximity 10 - min(|delta|, 10), and the IMDb rating
    /// prior x10. Candidates whose primary genre repeats the primary genre of
    /// the three strongest matches lose 10 points so one genre cannot fill the
    /// whole shelf. Missing fields score 0 rather than excluding a candidate.
    static func rank(
        target: AppleSimilarTitleProfile,
        candidates: [AppleSimilarTitleProfile],
        limit: Int = 12
    ) -> [AppleSimilarTitleCandidate] {
        guard limit > 0 else { return [] }
        let targetGenres = Set(target.genres.map { $0.lowercased() })
        let targetPeople = Set((target.cast + target.writers).map { normalizedName($0) })
        let targetDirector = target.director.map { normalizedName($0) }

        var seen = Set<String>()
        seen.insert(target.canonicalID ?? target.id)
        var scored: [AppleSimilarTitleCandidate] = []
        for candidate in candidates {
            guard candidate.type == target.type, candidate.id != target.id else { continue }
            let identity = candidate.canonicalID ?? candidate.id
            guard seen.insert(identity).inserted else { continue }

            let genreScore = jaccard(targetGenres, Set(candidate.genres.map { $0.lowercased() })) * similarGenreWeight
            let keywordScore = jaccard(target.keywords, candidate.keywords) * similarKeywordWeight

            var peopleScore: Double = 0
            if let targetDirector, !targetDirector.isEmpty,
               let candidateDirector = candidate.director.map({ normalizedName($0) }),
               candidateDirector == targetDirector {
                peopleScore += 10
            }
            let sharedPeople = Set((candidate.cast + candidate.writers).map { normalizedName($0) })
                .intersection(targetPeople)
                .count
            peopleScore += min(Double(sharedPeople) * 5, 10)

            var yearScore: Double = 0
            if let targetYear = target.year, let candidateYear = candidate.year {
                yearScore = 10 - Double(min(abs(targetYear - candidateYear), 10))
            }

            var ratingScore: Double = 0
            if let rating = candidate.imdbRating, rating.isFinite, rating > 0 {
                ratingScore = (min(rating, 10) / 10) * 10
            }

            let total = genreScore + keywordScore + peopleScore + yearScore + ratingScore
            scored.append(AppleSimilarTitleCandidate(
                profile: candidate,
                score: total,
                genreScore: genreScore,
                keywordScore: keywordScore,
                peopleScore: peopleScore,
                yearScore: yearScore,
                ratingScore: ratingScore
            ))
        }

        scored.sort(by: isOrderedBefore)

        let leadGenres = Set(scored.prefix(3).compactMap { $0.profile.primaryGenre })
        var adjusted = scored.enumerated().map { index, candidate -> AppleSimilarTitleCandidate in
            guard index >= 3,
                  let primary = candidate.profile.primaryGenre,
                  leadGenres.contains(primary) else { return candidate }
            return AppleSimilarTitleCandidate(
                profile: candidate.profile,
                score: candidate.score - similarDiversityPenalty,
                genreScore: candidate.genreScore,
                keywordScore: candidate.keywordScore,
                peopleScore: candidate.peopleScore,
                yearScore: candidate.yearScore,
                ratingScore: candidate.ratingScore,
                diversityPenalty: similarDiversityPenalty
            )
        }
        adjusted.sort(by: isOrderedBefore)
        return adjusted.filter { $0.score > 0 }.prefix(limit).map { $0 }
    }

    static func jaccard(_ lhs: Set<String>, _ rhs: Set<String>) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        let union = lhs.union(rhs).count
        guard union > 0 else { return 0 }
        return Double(lhs.intersection(rhs).count) / Double(union)
    }

    private static func isOrderedBefore(
        _ lhs: AppleSimilarTitleCandidate,
        _ rhs: AppleSimilarTitleCandidate
    ) -> Bool {
        if abs(lhs.score - rhs.score) > 1e-9 { return lhs.score > rhs.score }
        let lhsRating = lhs.profile.imdbRating ?? -1
        let rhsRating = rhs.profile.imdbRating ?? -1
        if abs(lhsRating - rhsRating) > 1e-9 { return lhsRating > rhsRating }
        if lhs.profile.title != rhs.profile.title { return lhs.profile.title < rhs.profile.title }
        return lhs.profile.id < rhs.profile.id
    }

    private static func normalizedName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// Synopsis keyword extraction. Uses `NLTagger` lexical classes where it is
/// available and falls back to plain word splitting elsewhere.
public enum AppleSimilarTitleKeywords {
    public static let stopWords: Set<String> = [
        "the", "and", "for", "with", "that", "this", "from", "his", "her", "its", "their",
        "but", "not", "are", "was", "were", "has", "have", "had", "who", "whom", "what", "when",
        "where", "will", "would", "can", "could", "should", "into", "onto", "out", "off", "over",
        "under", "after", "before", "while", "than", "then", "them", "they", "she", "him", "you",
        "your", "our", "ours", "one", "two", "new", "old", "own", "get", "gets", "got", "make",
        "makes", "made", "take", "takes", "took", "come", "comes", "came", "goes", "going", "went",
        "find", "finds", "found", "must", "may", "might", "just", "also", "all", "any", "more",
        "most", "some", "such", "only", "same", "too", "very", "film", "movie", "series",
        "season", "episode", "story", "stories", "based", "true", "life", "lives", "man", "men",
        "woman", "women", "world", "year", "years", "day", "days", "time", "times", "set", "way",
    ]

    public static func extract(from text: String?, limit: Int = 60) -> Set<String> {
        guard let text, !text.isEmpty else { return [] }
        let source = String(text.prefix(4_000))
        var keywords: Set<String> = []

        #if canImport(NaturalLanguage)
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = source
        let options: NLTagger.Options = [.omitPunctuation, .omitWhitespace, .omitOther, .joinNames]
        tagger.enumerateTags(
            in: source.startIndex ..< source.endIndex,
            unit: .word,
            scheme: .lexicalClass,
            options: options
        ) { tag, range in
            guard let tag, [.noun, .verb, .adjective].contains(tag) else { return true }
            if let keyword = normalize(String(source[range])) { keywords.insert(keyword) }
            return keywords.count < limit
        }
        #endif

        if keywords.isEmpty {
            for word in source.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
                guard keywords.count < limit else { break }
                if let keyword = normalize(String(word)) { keywords.insert(keyword) }
            }
        }
        return keywords
    }

    private static func normalize(_ value: String) -> String? {
        let lowered = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet.letters.union(.decimalDigits).inverted)
        guard lowered.count >= 3, !stopWords.contains(lowered) else { return nil }
        return lowered
    }
}

/// Caches extracted keywords per title id so reopening a detail page does not
/// re-tokenize every synopsis on screen.
public actor AppleSimilarTitleKeywordCache {
    public static let shared = AppleSimilarTitleKeywordCache()

    private var cache: [String: Set<String>] = [:]
    private var order: [String] = []
    private let capacity: Int

    public init(capacity: Int = 512) {
        self.capacity = max(1, capacity)
    }

    public func keywords(id: String, text: String?) -> Set<String> {
        if let cached = cache[id] { return cached }
        let keywords = AppleSimilarTitleKeywords.extract(from: text)
        cache[id] = keywords
        order.append(id)
        if order.count > capacity, let oldest = order.first {
            order.removeFirst()
            cache.removeValue(forKey: oldest)
        }
        return keywords
    }

    /// Hydrates keywords for the target and every candidate, then ranks.
    public func rankSimilar(
        target: AppleSimilarTitleProfile,
        candidates: [AppleSimilarTitleProfile],
        limit: Int = 12
    ) -> [AppleSimilarTitleCandidate] {
        let hydratedTarget = target.withKeywords(keywords(id: target.id, text: target.overview))
        let hydratedCandidates = candidates.map { candidate in
            candidate.withKeywords(keywords(id: candidate.id, text: candidate.overview))
        }
        return AppleRecommendationRanker.rank(
            target: hydratedTarget,
            candidates: hydratedCandidates,
            limit: limit
        )
    }
}
