import Foundation

/// What the detail hero shows in place of the title: the wordmark, the text
/// title, or nothing at all while the wordmark is still being checked.
enum AppleTitleLogoPresentation: Equatable, Sendable {
    case hidden
    case text
    case logo
}

/// Decides between the wordmark and the text title so the hero never ends up
/// showing neither. The wordmark wins once it is actually on screen; a failed
/// validation or a failed image load falls back to the text title, and a short
/// grace period keeps the text title from flashing before a wordmark that is
/// about to arrive.
enum AppleTitleLogoPolicy {
    /// How long the hero stays empty while the wordmark is still resolving.
    /// Owner 2026-09-14: "load the wordmark only if failed for more than 3
    /// secs then load plain text" — a second was not long enough for a slow
    /// wordmark, so the title snapped to text and then back to the logo.
    static let loadingGrace: TimeInterval = 3.0

    /// - Parameters:
    ///   - validated: `nil` while validation is in flight, `false` when there is
    ///     no usable wordmark, `true` when the URL passed validation.
    ///   - loadResult: `nil` until the wordmark view reports, then whether it
    ///     drew the image.
    ///   - elapsed: seconds since the wordmark started resolving.
    static func resolvedState(
        validated: Bool?,
        loadResult: Bool?,
        elapsed: TimeInterval
    ) -> AppleTitleLogoPresentation {
        switch (validated, loadResult) {
        case (false, _):
            return .text
        case (true, .some(false)):
            return .text
        case (true, .some(true)):
            return .logo
        default:
            return elapsed >= loadingGrace ? .text : .hidden
        }
    }
}
