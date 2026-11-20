import CoreGraphics

/// The iPhone landing hero shares the title page's 70% art target, with 40 pt
/// below the art for landing controls and dots. Short screens keep the title
/// page's height; taller screens leave a 90 pt first-row peek. On the 874 pt
/// reference screen, buttons remain
/// centred near 64% and dots near 70% of the screen height.
public struct AppleHomePhoneHeroLayout: Equatable, Sendable {
    public var containerWidth: CGFloat
    /// The scroll view's height: the whole screen, bars included.
    public var containerHeight: CGFloat
    /// What the status bar and the navigation bar take off the top, and the
    /// tab bar off the bottom (the scroll view's content insets).
    public var topInset: CGFloat
    public var bottomInset: CGFloat

    public init(containerHeight: CGFloat = 0, topInset: CGFloat = 0, bottomInset: CGFloat = 0,
                containerWidth: CGFloat = 0) {
        self.containerWidth = containerWidth
        self.containerHeight = containerHeight
        self.topInset = topInset
        self.bottomInset = bottomInset
    }

    public static let artFraction: CGFloat = 0.70
    /// The first-row peek above the tab bar when the title page's art floor fits.
    public static let minimumRowPeek: CGFloat = 90
    /// The bottom of the hero to the top of the first row's tiles: Discover's
    /// 32 pt row spacing less `trailingOverlap`, then the row's title line.
    public static let firstRowLead: CGFloat = 62
    /// The hero gives back this much of the 32 pt row spacing, so the first
    /// row's title sits just under the art as it does in the Apple TV app.
    /// The art is solid black there, so the overlap does not show.
    public static let trailingOverlap: CGFloat = 20
    /// The bottom of the hero to the centre of the page dots.
    public static let dotsCentreInset: CGFloat = 26
    /// The bottom of the hero to the bottom of the buttons.
    public static let copyBottomInset: CGFloat = 54
    static let titlePageCopyBottomInset: CGFloat = 14
    /// The art floor shared with the title page, also used before measurement.
    public static let minimumArtHeight: CGFloat = 440
    /// Discover's rows are laid out 16 pt below the navigation bar
    /// (`padding(.vertical)`); the hero is pulled up past that too.
    public static let stackTopPadding: CGFloat = 16

    public static var footerHeight: CGFloat { copyBottomInset - titlePageCopyBottomInset }
    public var heroHeight: CGFloat { artHeight + Self.footerHeight }

    /// The art's height from the top edge of the screen: 70 % of the screen,
    /// held short for a row peek only when that preserves the shared art floor.
    public var artHeight: CGFloat {
        guard containerHeight > 0 else { return Self.minimumArtHeight }
        let target = AppleTitlePageSlotArt.heroHeight(screenHeight: containerHeight)
        let peekLimit = containerHeight - bottomInset - Self.minimumRowPeek - Self.firstRowLead - Self.footerHeight
        return peekLimit < Self.minimumArtHeight ? target : min(target, peekLimit)
    }

    /// iOS 18's inline-large bar changes height as Discover appears and
    /// scrolls (115 and 97 pt on an iPhone 15 Pro Max), and the scroll view
    /// reports its insets a frame before or after its size (heights of 965,
    /// 949 and 913 pt for a 932 pt screen). Drawn as read, the art moved and
    /// resized with each reading. A reading at the screen height already
    /// drawn keeps the tallest top inset, the bar with its title expanded;
    /// another height at the same width is only drawn after `settleDelay`.
    /// The owner's 15 Pro Max also reports the tab bar as 82.67 then 83 pt
    /// while the bar moves (trace 2026-10-17): less than a point is not a
    /// new layout, or the hero redrew every frame with nothing moved.
    public static func settled(drawn: Self, measured: Self) -> Self {
        if widthChanged(drawn: drawn, measured: measured) { return measured }
        guard measured.topInset > 0 else { return drawn }
        guard drawn.topInset > 0 else { return measured }
        guard abs(measured.containerHeight - drawn.containerHeight) < 1 else { return drawn }
        var next = drawn
        if measured.topInset >= drawn.topInset + 1 { next.topInset = measured.topInset }
        if abs(measured.bottomInset - drawn.bottomInset) >= 1 { next.bottomInset = measured.bottomInset }
        return next
    }

    public static let settleDelay: Duration = .milliseconds(750)

    /// What is drawn after one reading: as read until the first layout has
    /// held (the launch passes land in the same frame), `settled` after.
    public static func next(drawn: Self, measured: Self, held: Bool) -> Self {
        if held || widthChanged(drawn: drawn, measured: measured) {
            return settled(drawn: drawn, measured: measured)
        }
        return measured.topInset > 0 ? measured : drawn
    }

    private static func widthChanged(drawn: Self, measured: Self) -> Bool {
        drawn.containerWidth > 0 && measured.containerWidth > 0
            && abs(measured.containerWidth - drawn.containerWidth) >= 1
    }

    /// How far the hero is pulled up so its art starts at the top edge.
    public var topOverlap: CGFloat { topInset + Self.stackTopPadding }

    /// Over how many points the copy fades as it rises towards the bars.
    public static let copyFadeDistance: CGFloat = 120

    /// The copy's opacity (wordmark, genres, buttons) when its top edge is
    /// `copyTop` points below the top of the screen, and `restingTop` before
    /// any scroll. It reaches zero at `fadeLine` — the bottom of the
    /// navigation bar with its large title (the top content inset), below
    /// where the inline title settles — so no Play button is left showing
    /// through the bar once it has collapsed (N17b, ios-top10-rank-02.png).
    /// The fade never starts below where the copy rests, so a short screen or
    /// a large text size, where the copy already sits close to the bar, still
    /// opens at full strength.
    public static func copyOpacity(copyTop: CGFloat, restingTop: CGFloat, fadeLine: CGFloat) -> CGFloat {
        let fadeStart = min(restingTop, fadeLine + copyFadeDistance)
        guard fadeStart > fadeLine else { return copyTop >= restingTop ? 1 : 0 }
        return min(max((copyTop - fadeLine) / (fadeStart - fadeLine), 0), 1)
    }

    /// The copy's top on the screen's scale, which `restingTop` and `fadeLine`
    /// use, from its place in the scroll view. The `.scrollView` space starts
    /// under the bars, at the top content inset, not at the top of the screen:
    /// measured on the iPhone (N49), the copy at rest read exactly `topInset`
    /// points higher than it sits. Compared as it was, the fade ended that far
    /// below the bar, and at Accessibility XL, where the copy rests close to
    /// the bar, it started out fully faded: no title, no Play.
    public static func screenTop(scrollViewMinY: CGFloat, topInset: CGFloat) -> CGFloat {
        scrollViewMinY + topInset
    }

    /// Whether the copy has faded all the way out (`copyOpacity` is zero):
    /// its buttons then take no taps and leave the accessibility tree, as
    /// they would once scrolled under the bar.
    public static func copyIsHidden(copyTop: CGFloat, restingTop: CGFloat, fadeLine: CGFloat) -> Bool {
        copyOpacity(copyTop: copyTop, restingTop: restingTop, fadeLine: fadeLine) == 0
    }
}
