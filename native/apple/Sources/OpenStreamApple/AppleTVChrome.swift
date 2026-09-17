import SwiftUI

/// Apple TV chrome geometry from the rework plan (FEEDBACK section D, task 3):
/// pushed pages carry a Title 3 (48 pt) header at x = 80 inside the content
/// instead of a navigation title, and Discover's search/refresh glyphs are the
/// first content row, trailing in the safe zone (right edge 1840), so they
/// scroll away with the hero instead of floating over it (owner X5).
enum AppleTVChromeMetrics {
    static let screenSize = CGSize(width: 1920, height: 1080)
    static let horizontalSafeInset: CGFloat = 80
    static let verticalSafeInset: CGFloat = 60

    // Page header
    static let pageHeaderFontSize: CGFloat = 48
    static let pageHeaderLeadingInset: CGFloat = 80
    static let pageHeaderTopInset: CGFloat = 24
    static let pageHeaderBottomSpacing: CGFloat = 24

    // Discover glyph pair
    static let glyphPairTrailingInset: CGFloat = 80
    static var glyphPairMaxX: CGFloat { screenSize.width - glyphPairTrailingInset }
    static let glyphDiscSize: CGFloat = 56
    static var glyphPairRowHeight: CGFloat { glyphDiscSize }
    static let glyphFontSize: CGFloat = 31
    static let glyphSpacing: CGFloat = 24

    /// The tvOS safe area already insets content by `horizontalSafeInset`, so
    /// the pair needs only the remainder as trailing padding.
    static var glyphPairTrailingPaddingInsideSafeArea: CGFloat {
        max(0, glyphPairTrailingInset - horizontalSafeInset)
    }
}

/// Title 3 header drawn inside a pushed tvOS page, above its rows, so a title
/// can never sit on top of the first row (owner bug U1: "Cinemeta",
/// "Subtitle Languages", "Add Network Share").
struct TVPageHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: AppleTVChromeMetrics.pageHeaderFontSize, weight: .bold))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, AppleTVChromeMetrics.pageHeaderTopInset)
            .padding(.bottom, AppleTVChromeMetrics.pageHeaderBottomSpacing)
            .accessibilityAddTraits(.isHeader)
    }
}
