import Foundation

/// Reads the season and episode out of a release name.
///
/// Owner report, TestFlight build 10: "The Secret Lives of Mormon Wives" — the
/// metadata is right, but playing episodes 1–2 gives a **different show**, the
/// same wrong one every time, while picking another source by hand plays the
/// correct one.
///
/// That combination is the signature of a ranking problem rather than a bad
/// add-on: candidates were ordered by resolution, then size, then container,
/// and **nothing checked that a candidate was even the episode being asked
/// for**. A mislabelled release that happens to be 1080p and large wins on
/// quality alone, and wins every time, because the sort is deterministic.
///
/// A name that states no episode at all — a season pack — is *not* a
/// contradiction: those are legitimate and the file index inside the torrent
/// decides which episode plays.
public enum AppleStremioEpisodeFilenameMatch {
    private static let patterns = [
        #"(?i)\bs(\d{1,2})\s*[._-]?\s*e(\d{1,3})\b"#,   // S01E02, s1.e2, S01 E02
        #"(?i)\b(\d{1,2})x(\d{1,3})\b"#,                 // 1x02
        #"(?i)\bseason\s*(\d{1,2})\s*episode\s*(\d{1,3})\b"#,
    ]

    /// Every season/episode pair named in `text`.
    public static func markers(in text: String) -> [(season: Int, episode: Int)] {
        let ns = text as NSString
        var found: [(Int, Int)] = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                guard match.numberOfRanges == 3,
                      let season = Int(ns.substring(with: match.range(at: 1))),
                      let episode = Int(ns.substring(with: match.range(at: 2))) else { continue }
                found.append((season, episode))
            }
        }
        return found
    }

    /// True when the name states at least one episode and **none** of them is
    /// the one being played.
    ///
    /// Deliberately conservative: silence is not a contradiction, so season
    /// packs and bare titles are untouched.
    public static func contradicts(_ text: String, season: Int, episode: Int) -> Bool {
        let found = markers(in: text)
        guard !found.isEmpty else { return false }
        return !found.contains { $0.season == season && $0.episode == episode }
    }
}
