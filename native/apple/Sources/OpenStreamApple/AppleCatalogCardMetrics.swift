import CoreGraphics

/// Layout numbers for `AppleCatalogCard` that differ by platform.
public enum AppleCatalogCardMetrics {
    /// How far the progress bar on a card's artwork sits in from the art's
    /// sides and bottom. Keeping it inside the focus surface prevents tvOS's
    /// artwork lift from dropping the bar.
    public static func progressBarInset(isTV: Bool) -> (horizontal: CGFloat, bottom: CGFloat) {
        isTV ? (horizontal: 12, bottom: 10) : (horizontal: 10, bottom: 8)
    }

    public static var progressBarInset: (horizontal: CGFloat, bottom: CGFloat) {
        #if os(tvOS)
        progressBarInset(isTV: true)
        #else
        progressBarInset(isTV: false)
        #endif
    }
}
