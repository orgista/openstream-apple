import SwiftUI

/// "Also available on Netflix" under a title.
///
/// Deliberately a line of text, not a row of buttons. The owner's rule is that
/// the app stays the way you watch things — "in general prefer to stay in the
/// app and just a very subtle also available to stream on (platform)" — so this
/// must not read as a second Play. It sits with the synopsis, in secondary
/// text, and competes with nothing.
///
/// It renders only when the viewer has opted in *and* a service they subscribe
/// to actually carries the title; `AppleWatchProviderPolicy` decides both.
struct AppleWatchProviderRow: View {
    let providers: [AppleWatchProvider]

    var body: some View {
        if !providers.isEmpty {
            Text(AppleWatchProviderRow.sentence(for: providers))
                .font(font)
                .foregroundStyle(AppleDesignTokens.textSecondary)
                .lineLimit(2)
                .accessibilityIdentifier("detail.alsoAvailableOn")
        }
    }

    private var font: Font {
        #if os(tvOS)
        .system(size: AppleTVDetailMetrics.badgeFontSize)
        #else
        .footnote
        #endif
    }

    /// "Also available on Netflix", "…on Netflix and Tubi · Free with ads",
    /// "…on Netflix, Max and 2 more".
    ///
    /// Capped rather than listed in full: a title on nine services would
    /// otherwise turn a quiet line into a paragraph, which is the opposite of
    /// what this is for.
    static func sentence(for providers: [AppleWatchProvider], limit: Int = 3) -> String {
        let names = providers.map(\.displayName)
        guard !names.isEmpty else { return "" }
        let shown = Array(names.prefix(limit))
        let remainder = names.count - shown.count
        let list: String
        if remainder > 0 {
            list = shown.joined(separator: ", ") + " and \(remainder) more"
        } else if shown.count == 1 {
            list = shown[0]
        } else {
            list = shown.dropLast().joined(separator: ", ") + " and " + shown[shown.count - 1]
        }
        return "Also available on \(list)"
    }
}
