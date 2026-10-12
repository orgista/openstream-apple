import CoreGraphics

/// Layout numbers for `AppleCatalogCard` that differ by platform.
public enum AppleCatalogCardMetrics {
    /// How far the progress bar on a card's artwork sits in from the art's
    /// sides and bottom. On Apple TV the focus lift dropped a bar drawn on
    /// the very bottom edge from the focused card (N58), and the Apple TV
    /// app insets its bar anyway; other platforms keep the edge bar.
    public static func progressBarInset(isTV: Bool) -> (horizontal: CGFloat, bottom: CGFloat) {
        isTV ? (horizontal: 12, bottom: 10) : (horizontal: 0, bottom: 0)
    }

    public static var progressBarInset: (horizontal: CGFloat, bottom: CGFloat) {
        #if os(tvOS)
        progressBarInset(isTV: true)
        #else
        progressBarInset(isTV: false)
        #endif
    }
}
