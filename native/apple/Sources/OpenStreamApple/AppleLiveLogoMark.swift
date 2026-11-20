import SwiftUI

/// A channel's fitted logo, without a plate or clipping. IPTV logos mix wide
/// transparent marks, square tiles and white-backed PNGs; fitting keeps them
/// whole. Rows fall back to monograms; badges over video use plain white text.
struct AppleLiveLogoMark: View {
    let url: URL?
    var height: CGFloat = 32
    var maxWidth: CGFloat = 48
    var channelName: String = ""
    /// The channel's name over video, where a monogram plate is never drawn.
    var fallbackText: String? = nil
    var alignment: Alignment = .center
    @State private var loadedURL: URL?
    @State private var failedURL: URL?

    private var state: AppleChannelPresentation.LogoState {
        AppleChannelPresentation.logoState(url: url, loadedURL: loadedURL, failedURL: failedURL)
    }

    private var showsText: Bool { state == .fallback && fallbackText != nil }

    var body: some View {
        ZStack(alignment: alignment) {
            if state == .fallback, let fallbackText {
                Text(fallbackText)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize()
            } else if state == .fallback {
                RoundedRectangle(cornerRadius: AppleDesignTokens.cornerRadiusCard)
                    .fill(.white.opacity(0.08))
                    .overlay {
                        Text(AppleChannelPresentation.monogram(channelName))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .padding(4)
                    }
            }
            if let url, state != .fallback {
                AppleRemoteImage(url: url, contentMode: .fit,
                    onLoad: { image in
                        let usable = image.width >= AppleChannelPresentation.minimumLogoPixelSize
                            && image.height >= AppleChannelPresentation.minimumLogoPixelSize
                        loadedURL = usable ? url : nil
                        failedURL = usable ? nil : url
                        if usable { AppleLaunchMarks.record(.liveLogoShown) }
                    }, onFailure: { loadedURL = nil; failedURL = url }, loadingFill: .clear)
                    .opacity(state == .image ? 1 : 0)
            }
        }
        .frame(width: showsText ? nil : maxWidth, height: height, alignment: alignment)
        .accessibilityHidden(true)
    }
}
