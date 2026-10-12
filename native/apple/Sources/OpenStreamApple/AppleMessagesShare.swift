import Foundation

/// What the Messages extension can offer to share, and what the resulting
/// bubble says.
///
/// The extension is a separate process with no access to the app's container,
/// so — exactly like the widgets and Top Shelf — everything it knows comes
/// from the snapshot the app writes into the shared app group. Keeping the
/// selection and the bubble wording here rather than in the extension target
/// is what makes them testable: `Messages.framework` is unavailable to
/// `swift test` on macOS, so anything that touches `MSMessage` directly cannot
/// be covered. These types touch only Foundation; the extension maps them onto
/// `MSMessageTemplateLayout` and nothing else.
public struct AppleMessagesShareItem: Equatable, Sendable, Identifiable {
    /// Which shelf the title came from. It decides the bubble's subcaption —
    /// "Watching now" is a claim about the sender, so it must not be said
    /// about a title they have merely been recommended.
    public enum Origin: Equatable, Sendable {
        case continueWatching
        case topPick
    }

    public let id: String
    public let title: String
    public let artworkURL: URL?
    public let displayURL: URL
    public let origin: Origin

    public init(id: String, title: String, artworkURL: URL?, displayURL: URL, origin: Origin) {
        self.id = id
        self.title = title
        self.artworkURL = artworkURL
        self.displayURL = displayURL
        self.origin = origin
    }
}

/// The fields of the message bubble, with no `Messages.framework` types in
/// sight. Mirrors the subset of `MSMessageTemplateLayout` the extension sets.
public struct AppleMessagesShareLayout: Equatable, Sendable {
    /// `MSMessageTemplateLayout.caption`.
    public let caption: String
    /// `MSMessageTemplateLayout.subcaption`.
    public let subcaption: String
    /// Fetched by the extension and assigned to `MSMessageTemplateLayout.image`.
    /// Nil whenever the artwork is missing or is not safe to hand to another
    /// process.
    public let imageURL: URL?
    /// `MSMessage.url` — the deep link the extension opens in the app when a
    /// recipient taps the bubble.
    public let url: URL
    /// `MSMessage.summaryText`, which is what a notification and VoiceOver
    /// read out. Never left to default to the caption alone: out of the app's
    /// context "Dune" is not obviously a thing someone sent you from
    /// OpenStream.
    public let summaryText: String
}

public enum AppleMessagesShareCatalog {
    /// Messages gives a compact presentation roughly two rows tall, so the
    /// list is short by design; the cap also bounds how much a malformed
    /// snapshot can make the extension render.
    public static let limit = 12

    /// Continue Watching first, then Top Picks — the same precedence Top Shelf
    /// and the widgets use, so the three surfaces agree about what is
    /// "current".
    ///
    /// Titles that are blank once trimmed are dropped rather than shown as an
    /// empty row, and an id that appears on both shelves is offered once, as
    /// whatever it was first.
    public static func items(from snapshot: AppleTopShelfSnapshot?) -> [AppleMessagesShareItem] {
        guard let snapshot else { return [] }
        var seen = Set<String>()
        var result: [AppleMessagesShareItem] = []
        let shelves: [(Array<AppleTopShelfSnapshot.Item>, AppleMessagesShareItem.Origin)] = [
            (snapshot.continueWatching, .continueWatching),
            (snapshot.topPicks, .topPick),
        ]
        for (values, origin) in shelves {
            for value in values {
                guard result.count < limit else { return result }
                let title = value.title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty, seen.insert(value.id).inserted else { continue }
                result.append(
                    AppleMessagesShareItem(
                        id: value.id,
                        title: title,
                        // Re-checked rather than trusted: the snapshot on disk
                        // may have been written by an older build, and this
                        // process fetches the URL over the network itself.
                        artworkURL: AppleSystemArtworkPolicy.publicURL(value.artworkURL),
                        displayURL: value.displayURL,
                        origin: origin
                    )
                )
            }
        }
        return result
    }

    /// The bubble for one title. Pure, so the wording is covered by tests.
    public static func layout(for item: AppleMessagesShareItem) -> AppleMessagesShareLayout {
        // Matches the Top Shelf provider's clamp. A title long enough to
        // matter is already unreadable in a bubble, and the payload travels
        // over iMessage.
        let caption = String(item.title.prefix(200))
        let subcaption: String
        switch item.origin {
        case .continueWatching: subcaption = "Watching now"
        case .topPick: subcaption = "On oStream"
        }
        return AppleMessagesShareLayout(
            caption: caption,
            subcaption: subcaption,
            imageURL: item.artworkURL,
            url: item.displayURL,
            summaryText: "\(caption) on oStream"
        )
    }
}
