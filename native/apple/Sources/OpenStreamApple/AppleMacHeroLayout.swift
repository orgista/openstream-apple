import CoreGraphics

/// Where the Mac's Discover hero draws, after the Apple TV app on the Mac and
/// the Figma "MacOS-OpenStream" frame (owner 2026-09-23: "make sure the bigger
/// apple tv style hero is on the macOS version as well"): art edge to edge
/// across the content, from the top of the window under the toolbar, as tall
/// as the window less a peek of the first row (owner 2026-09-25, with the
/// Apple TV app on the Mac beside it: "apple tv handles resizing of hero
/// better" — ours stopped at 680 pt, 47 % of a 3440 × 1440 window); the copy
/// bottom-left in a 480 pt column, its wordmark and bottom inset growing
/// gently with the hero; the page dots bottom-centre; a round mute button
/// top-right.
///
/// The iPad's Discover hero is the same hero (N20, after the Apple TV app on
/// the iPad): edge to edge from the top of the screen, under the status bar,
/// the navigation bar and the floating tab bar, taller than the Mac's —
/// `min(900, 90 % of the width, 66 % of the screen)` — so it fills the top of
/// the screen either way up and the first row still shows under it.
///
/// Pure, so the gate can check it without a window.
public struct AppleMacHeroLayout: Equatable, Sendable {
    public enum Platform: Equatable, Sendable {
        case mac
        case pad
    }

    /// The Discover content's width and the window's height.
    public var contentWidth: CGFloat
    public var windowHeight: CGFloat
    /// What the toolbar takes off the top (the scroll view's top content
    /// inset): on the iPad, the status bar, navigation bar and tab bar.
    public var topInset: CGFloat
    public var platform: Platform

    public init(contentWidth: CGFloat = 0, windowHeight: CGFloat = 0, topInset: CGFloat = 0,
                platform: Platform = .mac) {
        self.contentWidth = contentWidth
        self.windowHeight = windowHeight
        self.topInset = topInset
        self.platform = platform
    }

    /// What shows of the first row under the Mac hero: its header and the
    /// top of its cards. The Apple TV app on the Mac, 1928 × 1107 pt window:
    /// the hero is 930 pt, leaving 177 pt — the header and ~120 pt of cards.
    public static let firstRowPeek: CGFloat = 176
    /// A tall, narrow window still gets a landscape hero: never taller than
    /// 75 % of the width, so the aspect-fill crop stays wider than tall.
    public static let widthFraction: CGFloat = 0.75
    /// Before the window has been measured, and never less than this.
    public static let minimumHeight: CGFloat = 360
    /// The hero height the copy is drawn at 1× (a 1440 × 900 window's); the
    /// copy grows at half the hero's rate from it, between these bounds. The
    /// upper one keeps the 400 pt wordmark inside the 480 pt column.
    public static let copyReferenceHeight: CGFloat = 724
    public static let minimumCopyScale: CGFloat = 0.85
    public static let maximumCopyScale: CGFloat = 1.2
    /// The copy's bottom inset, as a fraction of the Mac hero's height:
    /// 40 pt at the reference height, between 32 and 72 pt.
    public static let bottomPaddingFraction: CGFloat = 0.055
    public static let minimumBottomPadding: CGFloat = 32
    public static let maximumBottomPadding: CGFloat = 72

    public static let padMaximumHeight: CGFloat = 900
    public static let padWidthFraction: CGFloat = 0.9
    public static let padScreenFraction: CGFloat = 0.66
    public static let padMinimumHeight: CGFloat = 420
    /// The bottom of the iPad's art to the centre of its page dots, under
    /// the copy's 40 pt bottom inset.
    public static let padDotsCentreInset: CGFloat = 20

    /// The copy column's inset from the leading edge: 24 pt in a narrow
    /// window, growing with the width to 48 pt by 1600 pt.
    public static let minimumHorizontalPadding: CGFloat = 24
    public static let maximumHorizontalPadding: CGFloat = 48
    public static let bottomPadding: CGFloat = 40
    public static let copyMaxWidth: CGFloat = 480
    public static let descriptionMaxWidth: CGFloat = 340
    /// Below this hero height the synopsis is left out rather than crowding
    /// the title and buttons.
    public static let descriptionMinimumHeight: CGFloat = 480

    public static let dotsBottomInset: CGFloat = 16
    public static let muteSide: CGFloat = 36
    public static let muteTopInset: CGFloat = 16
    public static let muteTrailingInset: CGFloat = 24
    public static let listButtonSide: CGFloat = 40
    /// The ‹ › page chevrons shown at the hero's edges under the pointer.
    public static let chevronGlyphSize: CGFloat = 30
    public static let chevronHitWidth: CGFloat = 56
    public static let chevronHitHeight: CGFloat = 120
    /// One decode of the still at this size serves every window size, so a
    /// live resize never reloads it.
    public static let stillPixelDimension = 2_560
    /// The wordmark's slot. Fixed rather than scaled with the window for the
    /// same reason: the trimmed logo decodes at its slot's size. The hero
    /// scales the drawn mark instead (`wordmarkDrawnSize`).
    public static let wordmarkSize = CGSize(width: 400, height: 130)
    /// Discover's rows start 16 pt below the toolbar (`padding(.vertical)`);
    /// the hero is pulled up past that too.
    public static let stackTopPadding: CGFloat = 16

    /// The hero's full height, from the top of the window. On the Mac the
    /// window less `firstRowPeek`, so it grows and shrinks with the window as
    /// the Apple TV app's does; on the iPad `min(900, 90 % of the width,
    /// 66 % of the screen)`.
    public var height: CGFloat {
        switch platform {
        case .mac:
            guard contentWidth > 0 else { return Self.minimumHeight }
            var target = contentWidth * Self.widthFraction
            if windowHeight > 0 { target = min(target, windowHeight - Self.firstRowPeek) }
            return max(target, Self.minimumHeight)
        case .pad:
            guard contentWidth > 0 else { return Self.padMinimumHeight }
            var target = min(Self.padMaximumHeight, contentWidth * Self.padWidthFraction)
            if windowHeight > 0 { target = min(target, windowHeight * Self.padScreenFraction) }
            return max(target, Self.padMinimumHeight)
        }
    }

    /// How much the Mac copy's wordmark and fallback name are scaled with the
    /// hero: gently, and within bounds. 1 on the iPad.
    public var copyScale: CGFloat {
        guard platform == .mac else { return 1 }
        let scale = 1 + (height / Self.copyReferenceHeight - 1) / 2
        return min(max(scale, Self.minimumCopyScale), Self.maximumCopyScale)
    }

    /// The copy's bottom inset: in proportion to the Mac hero, 40 pt on the iPad.
    public var copyBottomPadding: CGFloat {
        guard platform == .mac else { return Self.bottomPadding }
        let padding = (height * Self.bottomPaddingFraction).rounded()
        return min(max(padding, Self.minimumBottomPadding), Self.maximumBottomPadding)
    }

    /// The wordmark's drawn size: its fixed decode slot, scaled.
    public var wordmarkDrawnSize: CGSize {
        CGSize(width: Self.wordmarkSize.width * copyScale, height: Self.wordmarkSize.height * copyScale)
    }

    public var horizontalPadding: CGFloat {
        let t = min(max((contentWidth - 900) / 700, 0), 1)
        return Self.minimumHorizontalPadding + (Self.maximumHorizontalPadding - Self.minimumHorizontalPadding) * t
    }

    /// The black-weight name drawn when there is no wordmark: 6 % of the
    /// width, between 36 and 72 pt.
    public var titleFontSize: CGFloat {
        min(max(contentWidth * 0.06, 36), 72)
    }

    /// The hero's fallback name: `titleFontSize` scaled with the copy.
    public var heroTitleFontSize: CGFloat {
        (titleFontSize * copyScale).rounded()
    }

    public var showsDescription: Bool { height >= Self.descriptionMinimumHeight }

    /// How far the hero is pulled up so its art starts under the toolbar.
    public var topOverlap: CGFloat { topInset + Self.stackTopPadding }
}

/// The Mac hero's two fades, after the Apple TV app on the Mac: a gentle
/// leading fade only as dark as the copy needs — black 58 % at the edge,
/// clear by 48 % of the width — and a bottom fade into the page's black,
/// with a soft shadow under the copy doing the rest (owner 2026-09-24: the
/// left side "is still very dark"; it was 85 % to 30 % of the width).
/// The art and the trailer draw the same pair, so nothing darkens or
/// lightens when the video crossfades in. Over bright art the scrim
/// deepens (`AppleHeroScrim.wide`).
public enum AppleMacHeroFade {
    public typealias Stop = AppleHeroScrim.Stop

    /// Leading edge to trailing edge.
    public static let leading: [Stop] = [
        Stop(location: 0, opacity: 0.58),
        Stop(location: 0.2, opacity: 0.38),
        Stop(location: 0.48, opacity: 0),
    ]

    /// Bottom edge upwards: the page's black at the edge, clear by a third.
    public static let bottom: [Stop] = [
        Stop(location: 0, opacity: 1),
        Stop(location: 0.1, opacity: 0.7),
        Stop(location: 0.34, opacity: 0),
    ]
}

/// The Mac hero's page dots, as the Figma draws them: 7 pt dots 8 pt apart,
/// the active page a 22 pt capsule that fills with the cycle's timer.
public enum AppleMacHeroPageDots {
    public static let activeWidth: CGFloat = 22
    public static let dotSize: CGFloat = 7
    public static let spacing: CGFloat = 8
    /// Each dot's click target, taller and wider than the dot.
    public static let hitSize: CGFloat = 20
    public static let inactiveOpacity: Double = 0.35

    public static func size(position: Int, index: Int, count: Int) -> CGSize {
        guard count > 0, (0 ..< count).contains(position) else { return .zero }
        return CGSize(width: position == index ? activeWidth : dotSize, height: dotSize)
    }
}

/// Turns a trackpad's horizontal two-finger swipe over the Mac hero into one
/// page change per gesture. Vertical scrolling is left to the page, and the
/// momentum that follows a swipe never turns a second page.
public struct AppleMacHeroSwipe: Equatable, Sendable {
    /// Horizontal travel, in points, that turns the page.
    public static let threshold: CGFloat = 60

    private var travel: CGFloat = 0
    private var fired = false

    public init() {}

    /// A new gesture started (the scroll phase began).
    public mutating func begin() {
        travel = 0
        fired = false
    }

    /// One scroll event's deltas. Returns +1 for the next page (content moving
    /// left, as a swipe to the left does), -1 for the previous, or nil.
    public mutating func scroll(deltaX: CGFloat, deltaY: CGFloat) -> Int? {
        guard !fired, abs(deltaX) > abs(deltaY) else { return nil }
        travel += deltaX
        guard abs(travel) >= Self.threshold else { return nil }
        fired = true
        return travel < 0 ? 1 : -1
    }
}
