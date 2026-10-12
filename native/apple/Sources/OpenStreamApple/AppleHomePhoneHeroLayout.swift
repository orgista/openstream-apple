import CoreGraphics

/// Where the iPhone portrait hero draws, off the scroll view it sits in. From
/// the owner's Apple TV app screenshot (iPhone, 874 pt, 2026-09-22 23:00: "the
/// hero needs to be bigger"): the art runs from the top edge of the screen,
/// under the status bar and the large title, down to 73 % of the screen; the
/// button is centred at 64 %, the page dots at 70 %, and the first row's tiles
/// start at 79 %, so about 100 pt of them show above the tab bar.
///
/// Only the art ignores the top safe area. The title, Search and Refresh stay
/// in the navigation bar, and the copy is anchored to the bottom of the art.
public struct AppleHomePhoneHeroLayout: Equatable, Sendable {
    /// The scroll view's height: the whole screen, bars included.
    public var containerHeight: CGFloat
    /// What the status bar and the navigation bar take off the top, and the
    /// tab bar off the bottom (the scroll view's content insets).
    public var topInset: CGFloat
    public var bottomInset: CGFloat

    public init(containerHeight: CGFloat = 0, topInset: CGFloat = 0, bottomInset: CGFloat = 0) {
        self.containerHeight = containerHeight
        self.topInset = topInset
        self.bottomInset = bottomInset
    }

    public static let artFraction: CGFloat = 0.73
    /// The least of the first row's tiles that must show above the tab bar.
    public static let minimumRowPeek: CGFloat = 90
    /// The bottom of the art to the top of the first row's tiles: Discover's
    /// 32 pt row spacing less `trailingOverlap`, then the row's title line.
    public static let firstRowLead: CGFloat = 62
    /// The hero gives back this much of the 32 pt row spacing, so the first
    /// row's title sits just under the art as it does in the Apple TV app.
    /// The art is solid black there, so the overlap does not show.
    public static let trailingOverlap: CGFloat = 20
    /// The bottom of the art to the centre of the page dots (70 % of 874).
    public static let dotsCentreInset: CGFloat = 26
    /// The bottom of the art to the bottom of the buttons (centred at 64 %).
    public static let copyBottomInset: CGFloat = 54
    /// Before the scroll view has been measured, and never less than this.
    public static let minimumArtHeight: CGFloat = 440
    /// Discover's rows are laid out 16 pt below the navigation bar
    /// (`padding(.vertical)`); the hero is pulled up past that too.
    public static let stackTopPadding: CGFloat = 16

    /// The art's height from the top edge of the screen: 73 % of the screen,
    /// held short enough that the first row still peeks above the tab bar.
    public var artHeight: CGFloat {
        guard containerHeight > 0 else { return Self.minimumArtHeight }
        let target = containerHeight * Self.artFraction
        let peekLimit = containerHeight - bottomInset - Self.minimumRowPeek - Self.firstRowLead
        return max(min(target, peekLimit), Self.minimumArtHeight)
    }

    /// The portrait art's aspect: 1.25 × the width (538 pt on a 430 pt
    /// iPhone), so a 2:3 key-art poster loses only its designed margins and a
    /// 16:9 backdrop is not sliced to a sliver (owner items 6 and 19).
    public static let portraitArtAspect: CGFloat = 1.25

    /// The iPhone hero's art height for a screen `width` wide: 1.25 × width,
    /// never taller than `limit` (`artHeight`, which keeps the first row
    /// peeking above the tab bar) and never under `minimumArtHeight`.
    /// An unmeasured width keeps `limit`.
    public static func portraitArtHeight(width: CGFloat, limit: CGFloat) -> CGFloat {
        guard width > 0 else { return limit }
        return max(min((width * portraitArtAspect).rounded(), limit), minimumArtHeight)
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
