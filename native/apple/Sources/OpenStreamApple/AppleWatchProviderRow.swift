import SwiftUI

/// "Also available on Netflix" under a title.
///
/// Deliberately a line of text with small provider logos, not a row of
/// buttons. The owner's rule is that the app stays the way you watch things —
/// "in general prefer to stay in the app and just a very subtle also
/// available to stream on (platform)" — so this must not read as a second
/// Play: no buttons, no taps. It sits directly under the primary action
/// buttons, in secondary text, and competes with nothing.
///
/// It renders only when the viewer has opted in *and* a service they subscribe
/// to actually carries the title; `AppleWatchProviderPolicy` decides both.
struct AppleWatchProviderRow: View {
    let providers: [AppleWatchProvider]

    var body: some View {
        if !providers.isEmpty {
            // JustWatch's credit lives once, in About (owner 2026-10-08).
            providerLine
        }
    }

    private var providerLine: some View {
        HStack(spacing: logoSpacing) {
            ForEach(AppleWatchProviderPolicy.logos(providers)) { provider in
                if let logoURL = provider.logoURL {
                    AppleRemoteImage(url: logoURL, contentMode: .fit)
                        .frame(width: logoSize, height: logoSize)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
            }
            Text(AppleWatchProviderRow.sentence(for: providers))
                .font(font)
                .foregroundStyle(AppleDesignTokens.textSecondary)
                .lineLimit(1)
        }
        // One combined label — "Also available on Netflix" — never the
        // logos' own alt text or a second element VoiceOver could tap.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AppleWatchProviderRow.sentence(for: providers))
        .accessibilityIdentifier("detail.alsoAvailableOn")
        #if os(tvOS)
        // A quiet line, not a fifth thing the remote can land on beside
        // Play and the icon row.
        .focusable(false)
        #endif
    }

    private var font: Font {
        #if os(tvOS)
        .system(size: AppleTVDetailMetrics.badgeFontSize)
        #else
        .footnote
        #endif
    }

    private var logoSize: CGFloat {
        #if os(tvOS)
        28
        #else
        18
        #endif
    }

    private var logoSpacing: CGFloat {
        #if os(tvOS)
        8
        #else
        6
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
