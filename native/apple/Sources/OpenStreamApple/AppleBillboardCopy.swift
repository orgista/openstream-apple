import Foundation

/// The one-line "Drama · Sci-Fi · 2024" under a billboard's title lockup.
///
/// Both heroes draw it — the Apple TV billboard and the iPhone/iPad one — so
/// the rule for which parts appear, and what happens when a title has none of
/// them, lives here rather than being written twice.
public enum AppleBillboardCopy {
    public static let separator = " · "

    /// At most the first two genres, then the year (or the release text when
    /// there is no year). `nil` when nothing is known, so the copy block never
    /// shows a lonely separator or an empty line holding space.
    public static func metadataLine(genres: [String]?, year: Int?, releaseInfo: String?) -> String? {
        var parts: [String] = []
        if let genres {
            parts += genres
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .prefix(2)
        }
        if let year {
            parts.append(String(year))
        } else if let release = releaseInfo?.trimmingCharacters(in: .whitespacesAndNewlines), !release.isEmpty {
            parts.append(release)
        }
        return parts.isEmpty ? nil : parts.joined(separator: separator)
    }

    /// The iPhone hero's "TV Show · Thriller · Drama": what kind of title it
    /// is, then at most two genres. No year — the Apple TV app's hero has none.
    public static func phoneMetadataLine(type: String, genres: [String]?) -> String? {
        var parts: [String] = []
        switch type.lowercased() {
        case "series": parts.append("TV Show")
        case "movie": parts.append("Movie")
        default: break
        }
        if let genres {
            parts += genres
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .prefix(2)
        }
        return parts.isEmpty ? nil : parts.joined(separator: separator)
    }

    /// The outlined rating badge ("TV-MA"), or nil when the add-on sent none.
    public static func ratingBadge(_ contentRating: String?) -> String? {
        guard let rating = contentRating?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rating.isEmpty, rating.count <= 10 else { return nil }
        return rating
    }

    /// The hero's play button: "Resume S1, E3" when a series is part-way into
    /// an episode, "Resume" for a part-watched film, "Play" otherwise. Read
    /// from the saved position, so it never promises a resume that is not there:
    /// a series entry saved before episodes were recorded (no `partID`) cannot
    /// be resumed by the title page, so it says Play. Pressing it opens the
    /// title page, which starts the episode the entry names at its position
    /// (`AppleStremioEpisodePolicy.savedEpisode`).
    public static func playTitle(progress: ApplePlaybackProgress?, type: String? = nil) -> String {
        guard let progress, progress.resumePosition != nil else { return "Play" }
        if type == "series", progress.partID == nil { return "Play" }
        if let part = progress.partID, let episode = AppleStremioMetadataClient.episodeIdentity(part) {
            return "Resume S\(episode.season), E\(episode.episode)"
        }
        return "Resume"
    }
}
