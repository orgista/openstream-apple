import Foundation

/// One entry from a TMDB `/images` list — a backdrop, a poster or a logo.
public struct AppleArtworkImage: Equatable, Sendable {
    public let filePath: String?
    /// TMDB's `iso_639_1`. A **null** language is the language-neutral image:
    /// the frame with no title burned into it. An `"en"` backdrop is the same
    /// frame with the film's title art painted on.
    public let languageCode: String?
    public let voteAverage: Double?

    public init(filePath: String?, languageCode: String? = nil, voteAverage: Double? = nil) {
        self.filePath = filePath
        self.languageCode = languageCode
        self.voteAverage = voteAverage
    }

    /// Textless means "no words in the picture", which TMDB records as a null
    /// (or, from some mirrors, empty) `iso_639_1`.
    public var isTextless: Bool {
        (languageCode?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
    }
}

/// Which picture a hero should draw, and what kind of picture it is.
///
/// The kind matters as much as the path: a poster already carries the film's
/// own title treatment, so a hero showing one must not draw a second copy of
/// the name over it (`AppleTVBillboardTitleTreatment`).
public enum AppleHeroArtworkChoice: Equatable, Sendable {
    /// A backdrop with no title burned in — what the app wants, because it
    /// renders the wordmark itself.
    case textlessBackdrop(String)
    /// The record's primary `backdrop_path`, whatever TMDB ranked first.
    case backdrop(String)
    /// No backdrop of any kind exists; only the poster is left.
    case poster(String)

    public var path: String {
        switch self {
        case .textlessBackdrop(let path), .backdrop(let path), .poster(let path): path
        }
    }

    /// True when the art is a backdrop, and so has room for a wordmark over it.
    public var isBackdrop: Bool {
        switch self {
        case .textlessBackdrop, .backdrop: true
        case .poster: false
        }
    }
}

/// Picks the hero picture, preferring artwork the app can put its own wordmark
/// over.
///
/// Owner, 2026-09-20: *"when fetching meta data for movie art can we look for
/// movie art without the wordmark since we render the work mark separately"* —
/// the tvOS Library hero for "A Bad Moms Christmas" drew the plain text title
/// over a backdrop that already had the title art baked into it.
///
/// Pure, so the choice is asserted without a network: given the entries, this
/// is the answer.
public enum AppleTextlessBackdropPolicy {
    /// The longest `file_path` TMDB has ever issued is far under this; the cap
    /// only stops a hostile payload from becoming a URL.
    private static let maximumPathLength = 300

    /// - Parameters:
    ///   - backdrops: `images.backdrops` from the title's TMDB record.
    ///   - backdropPath: the record's own `backdrop_path`.
    ///   - posterPath: the record's own `poster_path`.
    /// - Returns: the textless backdrop with the highest `vote_average`, else
    ///   the primary backdrop, else the poster, else nothing.
    public static func choose(
        backdrops: [AppleArtworkImage],
        backdropPath: String?,
        posterPath: String?
    ) -> AppleHeroArtworkChoice? {
        if let textless = bestTextless(backdrops) { return .textlessBackdrop(textless) }
        if let backdrop = usablePath(backdropPath) { return .backdrop(backdrop) }
        if let poster = usablePath(posterPath) { return .poster(poster) }
        return nil
    }

    /// The textless (`iso_639_1 == null`) poster with the highest
    /// `vote_average`, for the iPhone's portrait hero; nil when there is none.
    public static func textlessPoster(_ posters: [AppleArtworkImage]) -> String? {
        bestTextless(posters)
    }

    /// Highest `vote_average` wins. A tie keeps TMDB's own order, which is
    /// already ranked, so the answer never depends on sort stability.
    private static func bestTextless(_ backdrops: [AppleArtworkImage]) -> String? {
        var best: (path: String, score: Double)?
        for image in backdrops where image.isTextless {
            guard let path = usablePath(image.filePath) else { continue }
            let score = (image.voteAverage?.isFinite ?? false) ? image.voteAverage! : 0
            if best == nil || score > best!.score { best = (path, score) }
        }
        return best?.path
    }

    private static func usablePath(_ value: String?) -> String? {
        guard let value else { return nil }
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.hasPrefix("/"), clean.count > 1, clean.count <= maximumPathLength else { return nil }
        return clean
    }
}
