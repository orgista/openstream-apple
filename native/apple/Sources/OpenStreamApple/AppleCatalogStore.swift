import Foundation
import Observation

public enum AppleCatalogDiscoveryPolicy {
    /// Movie and series items: the titles with a full title page and episode
    /// lists.
    public static func isTitleType(_ type: String) -> Bool {
        ["movie", "series"].contains(type.lowercased())
    }
}

public struct AppleCatalogItem: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let mediaID: String
    public let type: String
    public let name: String
    public let posterURL: URL?
    public let backgroundURL: URL?
    /// The title's wordmark art, when the meta response carried one.
    ///
    /// Optional, and decoded with `decodeIfPresent`, so cached payloads written
    /// before the field existed still read back. The Library hero had no way to
    /// show a wordmark at all because this was dropped on the floor: the meta
    /// response that fills a Library card already contains `logo`, and
    /// `AppleLibraryMetadataResolver.liveLookup` simply did not copy it across
    /// (owner 2026-09-20: "wordmarks not loading on (library) ap tv").
    public let logoURL: URL?
    public let summary: String?
    public let releaseInfo: String?
    public let rating: Double?
    public let contentRating: String?
    public let formatBadges: [String]?
    /// Content signals used by "More Like This". Optional so cached catalog
    /// payloads written before these fields existed still decode.
    public let genres: [String]?
    public let cast: [String]?
    public let director: String?
    public let writers: [String]?
    public let year: Int?
    /// The title's IMDb id when the item is keyed by another scheme
    /// (`tmdb:…`) but carries `imdb_id` too, so rows for one title merge
    /// (full test 2026-10-01).
    public let imdbID: String?
    /// Running time and popularity when the source sent them; nil when it
    /// sent none.
    public let runtimeMinutes: Int?
    public let popularity: Double?
    public let voteCount: Int?

    public init(
        mediaID: String,
        type: String,
        name: String,
        posterURL: URL? = nil,
        backgroundURL: URL? = nil,
        summary: String? = nil,
        releaseInfo: String? = nil,
        rating: Double? = nil,
        contentRating: String? = nil,
        formatBadges: [String]? = nil,
        genres: [String]? = nil,
        cast: [String]? = nil,
        director: String? = nil,
        writers: [String]? = nil,
        year: Int? = nil,
        logoURL: URL? = nil,
        imdbID: String? = nil,
        runtimeMinutes: Int? = nil,
        popularity: Double? = nil,
        voteCount: Int? = nil
    ) {
        self.voteCount = voteCount.flatMap { $0 >= 0 ? $0 : nil }
        self.runtimeMinutes = runtimeMinutes.flatMap { (1 ... 3_000).contains($0) ? $0 : nil }
        self.popularity = popularity.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        let normalizedType = String(type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().prefix(40))
        let normalizedMediaID = String(mediaID.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
        id = "\(normalizedType):\(normalizedMediaID)"
        self.mediaID = normalizedMediaID
        self.type = normalizedType
        // Sources hand back text that was escaped for a web page
        // upstream, so a description arrives reading "the 9/11 Memorial
        // &amp; Museum" and the raw entity is what the viewer reads on the
        // hero and the title page.
        self.name = String(AppleHTMLEntities.decoded(name)
            .trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        self.posterURL = posterURL
        self.backgroundURL = backgroundURL
        self.logoURL = logoURL
        self.summary = AppleHTMLEntities.decoded(summary)?.trimmedAndLimited(to: 4_000)
        self.releaseInfo = releaseInfo?.trimmedAndLimited(to: 100)
        self.rating = rating.flatMap { $0.isFinite && (0 ... 10).contains($0) ? $0 : nil }
        let cleanContentRating = contentRating?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.contentRating = cleanContentRating.isEmpty ? nil : String(cleanContentRating.prefix(20))
        self.formatBadges = formatBadges?.compactMap { value in
            let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return clean.isEmpty ? nil : String(clean.prefix(30))
        }
        self.genres = Self.cleanedList(genres, limit: 12, maximumLength: 60)
        self.cast = Self.cleanedList(cast, limit: 20, maximumLength: 80)
        let cleanDirector = director?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.director = cleanDirector.isEmpty ? nil : String(cleanDirector.prefix(80))
        self.writers = Self.cleanedList(writers, limit: 8, maximumLength: 80)
        self.year = year.flatMap { (1_870 ... 2_200).contains($0) ? $0 : nil }
        let cleanIMDbID = imdbID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.imdbID = cleanIMDbID.flatMap { AppleMediaIdentifier.isIMDBIdentifier($0) ? $0 : nil }
    }

    /// Rehydrates a cached item through the memberwise initialiser.
    ///
    /// The synthesised `Decodable` conformance assigns the stored properties
    /// directly, so everything `init(mediaID:…)` does — trimming, clamping and
    /// entity decoding — was skipped for anything already on disk. A viewer
    /// whose cache predates a normalisation fix would keep seeing the old text
    /// forever; routing the decode through the same initialiser means the
    /// cache is normalised on read.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            mediaID: try container.decode(String.self, forKey: .mediaID),
            type: try container.decode(String.self, forKey: .type),
            name: try container.decode(String.self, forKey: .name),
            posterURL: try container.decodeIfPresent(URL.self, forKey: .posterURL),
            backgroundURL: try container.decodeIfPresent(URL.self, forKey: .backgroundURL),
            summary: try container.decodeIfPresent(String.self, forKey: .summary),
            releaseInfo: try container.decodeIfPresent(String.self, forKey: .releaseInfo),
            rating: try container.decodeIfPresent(Double.self, forKey: .rating),
            contentRating: try container.decodeIfPresent(String.self, forKey: .contentRating),
            formatBadges: try container.decodeIfPresent([String].self, forKey: .formatBadges),
            genres: try container.decodeIfPresent([String].self, forKey: .genres),
            cast: try container.decodeIfPresent([String].self, forKey: .cast),
            director: try container.decodeIfPresent(String.self, forKey: .director),
            writers: try container.decodeIfPresent([String].self, forKey: .writers),
            year: try container.decodeIfPresent(Int.self, forKey: .year),
            logoURL: try container.decodeIfPresent(URL.self, forKey: .logoURL),
            imdbID: try container.decodeIfPresent(String.self, forKey: .imdbID),
            runtimeMinutes: try container.decodeIfPresent(Int.self, forKey: .runtimeMinutes),
            popularity: try container.decodeIfPresent(Double.self, forKey: .popularity),
            voteCount: try container.decodeIfPresent(Int.self, forKey: .voteCount)
        )
    }

    /// The same item with no poster, backdrop or wordmark.
    var withoutArtwork: Self {
        Self(mediaID: mediaID, type: type, name: name, summary: summary, releaseInfo: releaseInfo, rating: rating,
             contentRating: contentRating, formatBadges: formatBadges, genres: genres, cast: cast, director: director,
             writers: writers, year: year, imdbID: imdbID, runtimeMinutes: runtimeMinutes, popularity: popularity, voteCount: voteCount)
    }

    /// What VoiceOver reads for the item: its name, or for a poster-only
    /// entry that came without one, its type and id.
    public var accessibilityTitle: String {
        guard name.isEmpty else { return name }
        let kind = switch type {
        case "movie": "Movie"
        case "series": "Show"
        case "tv": "TV"
        default: type.capitalized
        }
        return "\(kind) \(mediaID)"
    }

    private static func cleanedList(_ values: [String]?, limit: Int, maximumLength: Int) -> [String]? {
        guard let values else { return nil }
        let cleaned = values
            .compactMap { value -> String? in
                let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return clean.isEmpty ? nil : String(clean.prefix(maximumLength))
            }
            .prefix(limit)
            .map { $0 }
        return cleaned.isEmpty ? nil : cleaned
    }

    public func withMediaID(_ mediaID: String) -> AppleCatalogItem {
        AppleCatalogItem(
            mediaID: mediaID,
            type: type,
            name: name,
            posterURL: posterURL,
            backgroundURL: backgroundURL,
            summary: summary,
            releaseInfo: releaseInfo,
            rating: rating,
            contentRating: contentRating,
            formatBadges: formatBadges,
            genres: genres,
            cast: cast,
            director: director,
            writers: writers,
            year: year,
            logoURL: logoURL,
            imdbID: imdbID,
            runtimeMinutes: runtimeMinutes,
            popularity: popularity,
            voteCount: voteCount
        )
    }

    /// Returns a copy whose hero art has been upgraded in place.
    ///
    /// Everything else — identity included — stays put, so swapping in a
    /// textless backdrop after first paint cannot change a view's identity and
    /// so cannot move focus on tvOS.
    public func withHeroArtwork(backgroundURL: URL?, logoURL: URL?) -> AppleCatalogItem {
        AppleCatalogItem(
            mediaID: mediaID,
            type: type,
            name: name,
            posterURL: posterURL,
            backgroundURL: backgroundURL ?? self.backgroundURL,
            summary: summary,
            releaseInfo: releaseInfo,
            rating: rating,
            contentRating: contentRating,
            formatBadges: formatBadges,
            genres: genres,
            cast: cast,
            director: director,
            writers: writers,
            year: year,
            logoURL: logoURL ?? self.logoURL,
            imdbID: imdbID,
            runtimeMinutes: runtimeMinutes,
            popularity: popularity,
            voteCount: voteCount
        )
    }

    /// Returns a copy enriched with content signals from a resolved meta
    /// response, keeping any value the catalog payload already carried.
    public func merging(details: AppleTMDBDetails) -> AppleCatalogItem {
        AppleCatalogItem(
            mediaID: mediaID,
            type: type,
            name: name,
            posterURL: posterURL,
            backgroundURL: backgroundURL,
            summary: summary ?? details.overview,
            releaseInfo: releaseInfo ?? details.releaseInfo,
            rating: rating ?? details.imdbRating,
            contentRating: contentRating,
            formatBadges: formatBadges,
            genres: genres ?? (details.genres.isEmpty ? nil : details.genres),
            cast: cast ?? (details.cast.isEmpty ? nil : details.cast),
            director: director ?? details.director,
            writers: writers ?? (details.writers.isEmpty ? nil : details.writers),
            year: year ?? details.year,
            logoURL: logoURL ?? details.logoURL,
            imdbID: imdbID,
            runtimeMinutes: runtimeMinutes,
            popularity: popularity,
            voteCount: voteCount
        )
    }
}

private extension String {
    func trimmedAndLimited(to maximumCharacters: Int) -> String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : String(value.prefix(maximumCharacters))
    }
}


