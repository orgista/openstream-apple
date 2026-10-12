import CoreGraphics

/// Where the Mac title page draws (N18), after the Apple TV app's title page
/// on the Mac (INSPO-TEARDOWN §7, PDF pages 11–16): the art edge to edge from
/// the top of the window, under the toolbar, as tall as Discover's hero
/// (N37, owner 2026-09-24: "it should be a full hero like the main page even
/// on the content page" — it was two thirds of the window, a second look);
/// the copy bottom-left in a column that grows with the window; the rails and
/// reference blocks below on the Discover rails' inset, so every left edge on
/// the page lines up.
///
/// Pure, so the gate can check it without a window.
struct AppleTitlePageMacLayout: Equatable, Sendable {
    /// The detail column's width and the window's height, toolbar included.
    var contentWidth: CGFloat
    var windowHeight: CGFloat

    static let copyWidthFraction: CGFloat = 0.42
    static let minimumCopyWidth: CGFloat = 360
    static let maximumCopyWidth: CGFloat = 560
    static let heroBottomPadding: CGFloat = AppleMacHeroLayout.bottomPadding
    static let sectionSpacing: CGFloat = 36
    /// The About card reads as prose, not a banner.
    static let aboutMaxWidth: CGFloat = 720
    /// Below this width the Information, Languages and Accessibility blocks
    /// stack in one column; from it they sit side by side.
    static let columnBreakpoint: CGFloat = 900
    static let maximumColumns = 3
    static let columnSpacing: CGFloat = 40
    static let portraitSide: CGFloat = 120

    /// The art's height, from the top of the window: Discover's hero's
    /// (`AppleMacHeroLayout.height`), so opening a title keeps the art where
    /// it was. The copy still grows the hero downwards onto black when a
    /// short window cannot hold it.
    var heroHeight: CGFloat {
        AppleMacHeroLayout(contentWidth: contentWidth, windowHeight: windowHeight).height.rounded()
    }

    /// The page's leading and trailing inset: the Mac Discover hero's and
    /// rails', 24 pt in a narrow window growing to 48 pt.
    var horizontalInset: CGFloat {
        AppleMacHeroLayout(contentWidth: contentWidth).horizontalPadding
    }

    /// The hero copy column: 42 % of the width, 360–560 pt, and never wider
    /// than the window allows.
    var copyWidth: CGFloat {
        let preferred = min(max(contentWidth * Self.copyWidthFraction, Self.minimumCopyWidth), Self.maximumCopyWidth)
        return max(0, min(preferred, contentWidth - 2 * horizontalInset)).rounded()
    }

    /// The black-weight name drawn when there is no wordmark.
    var titleFontSize: CGFloat {
        AppleMacHeroLayout(contentWidth: contentWidth).titleFontSize
    }

    /// How many columns `count` reference blocks take: one below the
    /// breakpoint, otherwise one each up to three.
    func referenceColumns(count: Int) -> Int {
        guard count > 1, contentWidth >= Self.columnBreakpoint else { return 1 }
        return min(count, Self.maximumColumns)
    }
}
