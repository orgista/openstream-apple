#if !os(tvOS)
import SwiftUI

/// The frames `AppleFeaturedHero` draws its art and wordmark in, off the
/// viewport it is laid out against. One place, so `AppleHeroPageGate` warms
/// the image caches at exactly the sizes the hero will ask for.
enum AppleFeaturedHeroMetrics {
    /// The hero spans the page's content column: the viewport less the 16 pt
    /// card margin on each side, less the copy block's own 24 pt inset.
    static func copyColumnWidth(viewport: CGSize) -> CGFloat {
        max(viewport.width - 32 - 48, 220)
    }

    static func artHeight(viewport: CGSize) -> CGFloat {
        #if os(visionOS)
        min(max(viewport.height * 0.50, 280), (max(viewport.width, 760) - 32) * 9 / 16)
        #else
        AppleDetailMetrics.featuredHeroHeight(in: viewport)
        #endif
    }

    /// At the accessibility text sizes the copy moves under a shorter still.
    static let accessibilityArtHeight: CGFloat = 220

    /// Scaled off the canvas, not off a constant: at the flat 300 x 90 the
    /// stacked card used, the lockup read as a banner on the iPhone and as a
    /// postage stamp on an iPad in landscape. Capped so it never runs past the
    /// copy column on a wide canvas.
    static func wordmarkSize(viewport: CGSize) -> CGSize {
        CGSize(
            width: min(copyColumnWidth(viewport: viewport) * 0.55, 460),
            height: min(max(artHeight(viewport: viewport) * 0.20, 52), AppleDetailMetrics.titleLogoMaxHeight)
        )
    }
}
#endif
