import Foundation

/// A release year or run as the Apple TV app prints it: "2013–2018" and, for a
/// show still airing, "1984–", both with an en dash. Some metadata sends a
/// hyphen for a running show ("1984-") and TMDB-derived rows an en dash, so the same
/// page read "1984-" in its metadata line and "2011–2019" on the card beside it.
enum AppleReleaseYearText {
    static func display(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = value.wholeMatch(of: /(\d{4})\s*[-–—]\s*(\d{4})?/) else { return value }
        return "\(match.1)–\(match.2 ?? "")"
    }
}
