import CoreGraphics
import Foundation

/// The iPhone title page's header art: a 16:9 slot the trailer crossfades
/// over (Mythos §5). Chosen once the page's metadata has answered (or a
/// short deadline has passed) and then held, so the first art drawn is the
/// final art: no poster that turns into a backdrop, no wordmark that
/// replaces a text title (previous agent's note on Taskmaster/Spider-Man).
public enum AppleTitlePageSlotArt: Equatable, Sendable {
    /// Fills the 16:9 slot exactly.
    case backdrop(URL)
    /// No backdrop anywhere: the poster as a card on a blurred copy of itself.
    case posterCard(URL)

    /// How long the page waits for its metadata before choosing from what it has.
    public static let deadline: Duration = .milliseconds(1_500)

    /// Backdrops first (textless first), then posters; failed images skipped.
    public static func choose(backdrops: [URL?], posters: [URL?], failed: Set<URL> = []) -> AppleTitlePageSlotArt? {
        if let url = backdrops.lazy.compactMap({ $0 }).first(where: { !failed.contains($0) }) { return .backdrop(url) }
        if let url = posters.lazy.compactMap({ $0 }).first(where: { !failed.contains($0) }) { return .posterCard(url) }
        return nil
    }

    /// Whether the page knows enough to choose: its details have answered,
    /// or the deadline has passed.
    public static func isReady(detailsAnswered: Bool, deadlinePassed: Bool) -> Bool {
        detailsAnswered || deadlinePassed
    }

    public var url: URL {
        switch self {
        case .backdrop(let url), .posterCard(let url): url
        }
    }

    public var isPosterCard: Bool {
        if case .posterCard = self { return true }
        return false
    }

    /// The slot's height: 16:9 of the width.
    public static func slotHeight(width: CGFloat) -> CGFloat {
        max(0, (width * 9 / 16).rounded())
    }
}
