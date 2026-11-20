import Foundation

/// Playlist labels for display; provider names remain intact for guide matching and export.
enum AppleChannelPresentation {
    /// Smaller images are spacers or tracking pixels, rather than channel marks.
    static let minimumLogoPixelSize = 8
    private static let playlistPrefixes: Set<String> = ["CA", "CAN", "CAR", "ES", "IRE", "PH", "PR", "US", "USA", "UK"]
    private static let prefix = try? NSRegularExpression(pattern: #"^\s*(?:\[\s*([A-Za-z]{2,3})\s*\]|\(\s*([A-Za-z]{2,3})\s*\)|([A-Za-z]{2,3})\s*[:|])\s*"#)

    static func displayName(_ name: String) -> String {
        var value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "Channel" }
        while let match = prefix?.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let range = Range(match.range, in: value) {
            let country = (1..<match.numberOfRanges).compactMap { index in
                Range(match.range(at: index), in: value).map { String(value[$0]).uppercased() }
            }.first
            guard let country, playlistPrefixes.contains(country) else { break }
            value = String(value[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value.isEmpty ? name.trimmingCharacters(in: .whitespacesAndNewlines) : value
    }

    static func monogram(_ displayName: String) -> String {
        let words = displayName.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard let first = words.first else { return "TV" }
        if words.count == 1 { return String(first.prefix(3)).uppercased() }
        return String(words.prefix(3).compactMap(\.first)).uppercased()
    }

    /// Loading stays clear; only absent or unusable art gets a fallback.
    enum LogoState: Equatable, Sendable { case loading, image, fallback }

    static func logoState(url: URL?, loadedURL: URL?, failedURL: URL?) -> LogoState {
        guard let url else { return .fallback }
        if loadedURL == url { return .image }
        return failedURL == url ? .fallback : .loading
    }
}
