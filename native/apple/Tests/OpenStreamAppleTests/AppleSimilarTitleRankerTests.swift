import Testing
import Foundation
@testable import OpenStreamApple

@Suite("More Like This ranking")
struct AppleSimilarTitleRankerTests {
    private func profile(
        id: String,
        type: String = "movie",
        title: String,
        genres: [String] = [],
        overview: String? = nil,
        cast: [String] = [],
        director: String? = nil,
        writers: [String] = [],
        year: Int? = nil,
        rating: Double? = nil
    ) -> AppleSimilarTitleProfile {
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
            imdbRating: rating,
            keywords: AppleSimilarTitleKeywords.extract(from: overview)
        )
    }

    private var september11Documentary: AppleSimilarTitleProfile {
        profile(
            id: "movie:tt0312318",
            title: "9/11",
            genres: ["Documentary", "History"],
            overview: "Firefighters document the terror attack on the towers in Manhattan and the rescue that followed.",
            year: 2002,
            rating: 7.6
        )
    }

    @Test("A 9/11 documentary suggests related titles, not Star Wars")
    func rankingPrefersRelatedTitles() {
        let target = september11Documentary
        let starWars = profile(
            id: "movie:tt0076759",
            title: "Star Wars",
            genres: ["Sci-Fi", "Adventure"],
            overview: "A farm boy joins a rebellion against a galactic empire with a smuggler and a princess.",
            year: 1977,
            rating: 8.6
        )
        let united93 = profile(
            id: "movie:tt0475276",
            title: "United 93",
            genres: ["Drama", "History", "Thriller"],
            overview: "Passengers fight back against the hijackers in the terror attack of September 11 while the towers burn.",
            year: 2006,
            rating: 7.6
        )
        let fahrenheit = profile(
            id: "movie:tt0361596",
            title: "Fahrenheit 9/11",
            genres: ["Documentary", "History", "War"],
            overview: "A documentary on the aftermath of the terror attack on the towers and the war that followed.",
            year: 2004,
            rating: 7.4
        )

        let ranked = AppleRecommendationRanker.rank(
            target: target,
            candidates: [starWars, united93, fahrenheit]
        )

        #expect(ranked.count >= 2)
        let leaders = Set(ranked.prefix(2).map(\.profile.id))
        #expect(leaders == [united93.id, fahrenheit.id])
        if let starWarsRank = ranked.firstIndex(where: { $0.profile.id == starWars.id }) {
            #expect(starWarsRank == ranked.count - 1)
        }
    }

    @Test("Only the same media type is suggested")
    func rankingFiltersByType() {
        let target = september11Documentary
        let series = profile(
            id: "series:tt1234567",
            type: "series",
            title: "Turning Point",
            genres: ["Documentary", "History"],
            overview: "A documentary series on the terror attack on the towers.",
            year: 2021
        )
        let ranked = AppleRecommendationRanker.rank(target: target, candidates: [series])
        #expect(ranked.isEmpty)
    }

    @Test("The target and duplicate IMDb ids are excluded")
    func rankingExcludesSelfAndDuplicates() {
        let target = AppleSimilarTitleProfile(
            id: "movie:tt0312318",
            type: "movie",
            title: "9/11",
            genres: ["Documentary"],
            canonicalID: "tt0312318"
        )
        let duplicateOfTarget = AppleSimilarTitleProfile(
            id: "movie:rt-9-11",
            type: "movie",
            title: "9/11",
            genres: ["Documentary"],
            canonicalID: "tt0312318"
        )
        let first = AppleSimilarTitleProfile(
            id: "movie:a",
            type: "movie",
            title: "A",
            genres: ["Documentary"],
            imdbRating: 8,
            canonicalID: "tt2000001"
        )
        let duplicateOfFirst = AppleSimilarTitleProfile(
            id: "movie:a-copy",
            type: "movie",
            title: "A (copy)",
            genres: ["Documentary"],
            imdbRating: 8,
            canonicalID: "tt2000001"
        )

        let ranked = AppleRecommendationRanker.rank(
            target: target,
            candidates: [duplicateOfTarget, first, duplicateOfFirst]
        )
        #expect(ranked.map(\.profile.id) == ["movie:a"])
    }

    @Test("Genre Jaccard carries 35 points at a full match")
    func genreJaccardWeight() {
        #expect(AppleRecommendationRanker.jaccard(["a", "b"], ["a", "b"]) == 1)
        #expect(AppleRecommendationRanker.jaccard(["a", "b"], ["b", "c"]) == 1.0 / 3.0)
        #expect(AppleRecommendationRanker.jaccard([], ["a"]) == 0)

        let target = AppleSimilarTitleProfile(
            id: "movie:t", type: "movie", title: "Target", genres: ["Documentary", "History"]
        )
        let exact = AppleSimilarTitleProfile(
            id: "movie:x", type: "movie", title: "Exact", genres: ["documentary", "history"]
        )
        let ranked = AppleRecommendationRanker.rank(target: target, candidates: [exact])
        #expect(ranked.first?.genreScore == 35)
        #expect(ranked.first?.score == 35)
    }

    @Test("Keyword extraction drops stop words and short tokens")
    func keywordExtraction() {
        let keywords = AppleSimilarTitleKeywords.extract(
            from: "The firefighters document a terror attack on the towers."
        )
        #expect(keywords.contains("terror"))
        #expect(keywords.contains("attack"))
        #expect(keywords.contains("towers"))
        #expect(!keywords.contains("the"))
        #expect(!keywords.contains("on"))
        #expect(AppleSimilarTitleKeywords.extract(from: nil).isEmpty)
    }

    @Test("A fourth title repeating the leading genre loses ten points")
    func diversityPenalty() {
        let target = AppleSimilarTitleProfile(
            id: "movie:t", type: "movie", title: "Target", genres: ["Documentary"], year: 2000
        )
        let candidates = (1 ... 4).map { index in
            AppleSimilarTitleProfile(
                id: "movie:\(index)",
                type: "movie",
                title: "Title \(index)",
                genres: ["Documentary"],
                year: 2000,
                imdbRating: Double(10 - index)
            )
        }
        let ranked = AppleRecommendationRanker.rank(target: target, candidates: candidates)
        #expect(ranked.count == 4)
        #expect(ranked.prefix(3).allSatisfy { $0.diversityPenalty == 0 })
        #expect(ranked.last?.diversityPenalty == 10)
        #expect(ranked.last?.profile.id == "movie:4")
    }

    @Test("Ties break on rating then title, and the order is stable")
    func stableOrdering() {
        let target = AppleSimilarTitleProfile(
            id: "movie:t", type: "movie", title: "Target", genres: ["Drama"]
        )
        let beta = AppleSimilarTitleProfile(
            id: "movie:b", type: "movie", title: "Beta", genres: ["Drama"], imdbRating: 7
        )
        let alpha = AppleSimilarTitleProfile(
            id: "movie:a", type: "movie", title: "Alpha", genres: ["Drama"], imdbRating: 7
        )
        let best = AppleSimilarTitleProfile(
            id: "movie:c", type: "movie", title: "Zeta", genres: ["Drama"], imdbRating: 9
        )

        let first = AppleRecommendationRanker.rank(target: target, candidates: [beta, alpha, best])
        let second = AppleRecommendationRanker.rank(target: target, candidates: [best, alpha, beta])
        #expect(first.map(\.profile.id) == ["movie:c", "movie:a", "movie:b"])
        #expect(first.map(\.profile.id) == second.map(\.profile.id))
    }

    @Test("Shared director and cast add up to twenty points")
    func castAndCrewOverlap() {
        let target = AppleSimilarTitleProfile(
            id: "movie:t",
            type: "movie",
            title: "Target",
            cast: ["Alice Ash", "Bob Birch"],
            director: "Cara Cedar",
            writers: ["Dan Dogwood"]
        )
        let candidate = AppleSimilarTitleProfile(
            id: "movie:c",
            type: "movie",
            title: "Candidate",
            cast: ["alice ash", "bob birch"],
            director: "cara cedar"
        )
        let ranked = AppleRecommendationRanker.rank(target: target, candidates: [candidate])
        #expect(ranked.first?.peopleScore == 20)
    }

    @Test("A profile reads its signals off a catalog item")
    func profileFromCatalogItem() {
        let item = AppleCatalogItem(
            mediaID: "tt0312318",
            type: "movie",
            name: "9/11",
            summary: "Firefighters document the terror attack on the towers.",
            releaseInfo: "2002",
            rating: 7.6,
            genres: ["Documentary", "History"],
            cast: ["James Hanlon"],
            director: "Jules Naudet",
            writers: ["Tom Forman"]
        )
        let profile = AppleSimilarTitleProfile(item: item)
        #expect(profile.genres == ["Documentary", "History"])
        #expect(profile.director == "Jules Naudet")
        #expect(profile.writers == ["Tom Forman"])
        #expect(profile.year == 2002)
        #expect(profile.imdbRating == 7.6)
        #expect(profile.canonicalID == "tt0312318")
    }

    @Test("The keyword cache reuses extraction and still ranks")
    func keywordCacheRanks() async {
        let cache = AppleSimilarTitleKeywordCache(capacity: 8)
        let target = september11Documentary
        let related = profile(
            id: "movie:tt0475276",
            title: "United 93",
            genres: ["Drama", "History"],
            overview: "Passengers fight the hijackers during the terror attack on the towers.",
            year: 2006
        )
        let unrelated = profile(
            id: "movie:tt0076759",
            title: "Star Wars",
            genres: ["Sci-Fi"],
            overview: "A farm boy joins a rebellion against a galactic empire.",
            year: 1977
        )
        let ranked = await cache.rankSimilar(target: target, candidates: [unrelated, related])
        #expect(ranked.first?.profile.id == "movie:tt0475276")
        let repeated = await cache.rankSimilar(target: target, candidates: [unrelated, related])
        #expect(repeated.map(\.profile.id) == ranked.map(\.profile.id))
    }
}
