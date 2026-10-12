import SwiftUI

/// A channel's logo as the Live tab draws it: fitted, no plate behind it, no
/// clip. IPTV logos mix wide transparent marks, square tiles and white-backed
/// PNGs; fitting keeps every one whole. No logo draws `tv` in the tertiary
/// label colour, never a monogram badge.
struct AppleLiveLogoMark: View {
    let url: URL?
    var height: CGFloat = 32
    var maxWidth: CGFloat = 48
    /// Shown instead of `tv` when there is no logo (the channel's name over
    /// the video).
    var fallbackText: String? = nil
    var alignment: Alignment = .center
    @State private var failedURL: URL?

    private var showsImage: Bool { url != nil && failedURL != url }
    private var showsText: Bool { !showsImage && fallbackText != nil }

    var body: some View {
        Group {
            if let url, showsImage {
                AppleRemoteImage(url: url, contentMode: .fit, onFailure: { failedURL = url },
                                 loadingFill: .clear)
            } else if let fallbackText {
                Text(fallbackText)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize()
            } else {
                Image(systemName: "tv")
                    .font(.system(size: 17))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: showsText ? nil : maxWidth, height: height, alignment: showsText ? .leading : alignment)
        .accessibilityHidden(true)
    }
}
