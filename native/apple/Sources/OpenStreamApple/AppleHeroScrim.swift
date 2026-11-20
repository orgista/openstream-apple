import CoreGraphics
import SwiftUI

/// The approved fades over each hero's art. Bright art changes only the
/// existing copy shadow; it never adds or strengthens a gradient.
/// Pure, so the gate can check it without a window.
public struct AppleHeroScrim: Equatable, Sendable {
    public struct Stop: Equatable, Sendable {
        public let location: CGFloat
        public let opacity: Double

        public init(location: CGFloat, opacity: Double) {
            self.location = location
            self.opacity = opacity
        }
    }

    public struct Shadow: Equatable, Sendable {
        public let opacity: Double
        public let radius: CGFloat
    }

    /// Black from the leading edge towards the trailing one; empty for none.
    public var leading: [Stop]
    /// Black from the bottom edge upwards.
    public var bottom: [Stop]
    /// Under the wordmark, the name and the text lines; nil for none.
    public var copyShadow: Shadow?

    public init(leading: [Stop] = [], bottom: [Stop], copyShadow: Shadow? = nil) {
        self.leading = leading
        self.bottom = bottom
        self.copyShadow = copyShadow
    }

    /// The existing soft shadow under hero copy over bright art.
    public static let brightCopyShadow = Shadow(opacity: 0.55, radius: 12)
    /// The lighter shadow under the Mac and iPad hero's copy over any other
    /// art or the trailer: with the gentle fade, it is what keeps the text
    /// readable where the picture is not dark.
    public static let wideCopyShadow = Shadow(opacity: 0.35, radius: 8)

    /// A fade's opacity at `location`, as `LinearGradient` draws it: held
    /// flat before the first stop and after the last.
    public static func opacity(of stops: [Stop], at location: CGFloat) -> Double {
        guard let first = stops.first, let last = stops.last else { return 0 }
        if location <= first.location { return first.opacity }
        if location >= last.location { return last.opacity }
        for (lower, upper) in zip(stops, stops.dropFirst()) where location <= upper.location {
            let span = upper.location - lower.location
            guard span > 0 else { return upper.opacity }
            let t = Double((location - lower.location) / span)
            return lower.opacity + (upper.opacity - lower.opacity) * t
        }
        return last.opacity
    }

    // MARK: Mac and iPad (`AppleHomeMacHero`)

    /// `copyTrailing`: the copy column's trailing edge as a fraction of the
    /// hero's width.
    public static func wide(tone: AppleHeroArtTone, videoIsShowing: Bool, copyTrailing: CGFloat) -> Self {
        Self(leading: AppleMacHeroFade.leading, bottom: AppleMacHeroFade.bottom,
             copyShadow: tone.isBright && !videoIsShowing ? brightCopyShadow : wideCopyShadow)
    }

    // MARK: iPhone portrait (`AppleHomePhoneHero`)

    /// The approved billboard fade, bottom up: solid black under the buttons,
    /// 55 % under the wordmark, clear through the top third.
    public static let phoneBottom: [Stop] = [
        Stop(location: 0, opacity: 1),
        Stop(location: 0.14, opacity: 1),
        Stop(location: 0.38, opacity: 0.55),
        Stop(location: 0.68, opacity: 0),
    ]

    public static func phone(tone: AppleHeroArtTone) -> Self {
        Self(bottom: phoneBottom, copyShadow: tone.isBright ? brightCopyShadow : nil)
    }

    // MARK: Apple TV (`AppleTVBillboard`)

    /// Clear at 35 % of the art from the top, black at its bottom edge.
    public static let tvBottom: [Stop] = [
        Stop(location: 0, opacity: 1),
        Stop(location: 1 - AppleTVBillboardMetrics.fadeStartFraction, opacity: 0),
    ]

    public static func tv(tone: AppleHeroArtTone, copyTrailing: CGFloat) -> Self {
        Self(bottom: tvBottom, copyShadow: tone.isBright ? brightCopyShadow : nil)
    }

    // MARK: The featured hero (`AppleFeaturedHero`: iPad accessibility sizes,
    // a phone on its side, Vision Pro, Library on iPhone and iPad)

    /// Clear at 35 % from the top to black at 85 % at the bottom edge.
    public static let featuredBottom: [Stop] = [
        Stop(location: 0, opacity: 0.85),
        Stop(location: 1 - AppleTVBillboardMetrics.fadeStartFraction, opacity: 0),
    ]

    public static func featured(tone: AppleHeroArtTone, copyTrailing: CGFloat) -> Self {
        Self(bottom: featuredBottom, copyShadow: tone.isBright ? brightCopyShadow : nil)
    }
}

/// Where each hero's wordmark, name and text lines sit over its art, in points
/// from the top-left of the art frame: the patch `AppleHeroLuminanceMap` reads.
/// The buttons are opaque and are left out.
public enum AppleHeroCopyRegion {
    /// The Mac's and the iPad's column, bottom-left: the text block above the
    /// buttons (a 130 pt wordmark, the kind line and up to three lines of
    /// synopsis — about 220 pt — over ~64 pt of buttons). The wordmark and
    /// the bottom inset grow with a tall Mac hero, and the patch with them.
    public static func wide(_ layout: AppleMacHeroLayout) -> CGRect {
        let width = max(min(AppleMacHeroLayout.copyMaxWidth, layout.contentWidth - 2 * layout.horizontalPadding), 1)
        let bottom = layout.height - layout.copyBottomPadding - 64
        let height = 220 + layout.wordmarkDrawnSize.height - AppleMacHeroLayout.wordmarkSize.height
        return CGRect(x: layout.horizontalPadding, y: bottom - height, width: width, height: height)
    }

    /// The iPhone's centred wordmark and kind line, above the buttons.
    public static func phone(width: CGFloat, artHeight: CGFloat) -> CGRect {
        let columnWidth = min(300, max(width - 40, 1))
        let bottom = artHeight - AppleHomePhoneHeroLayout.copyBottomInset - 66
        return CGRect(x: (width - columnWidth) / 2, y: bottom - 130, width: columnWidth, height: 130)
    }

    /// The Apple TV's column: the wordmark (62 % of the column), the kind line
    /// and the synopsis, above the pills.
    public static var tv: CGRect {
        typealias M = AppleTVBillboardMetrics
        let bottom = M.artHeight - M.copyBottomInset - M.pillSize.height - 36
        return CGRect(x: M.copyLeadingInset, y: bottom - 270, width: M.copyColumnWidth * 0.78, height: 270)
    }

    /// The featured hero's column, bottom-left inside its 24 pt padding: the
    /// wordmark, the meta line and two lines of synopsis above the buttons
    /// and the page dots.
    public static func featured(frame: CGSize, copyWidth: CGFloat) -> CGRect {
        let width = max(min(copyWidth, 560), 1)
        let bottom = frame.height - 24 - 76
        return CGRect(x: 24, y: bottom - 150, width: width, height: 150)
    }

    /// The region's trailing edge as a fraction of the frame's width.
    public static func trailingFraction(_ region: CGRect, in frame: CGSize) -> CGFloat {
        guard frame.width > 0 else { return 0 }
        return min(max(region.maxX / frame.width, 0), 1)
    }
}

/// Draws an `AppleHeroScrim` over a hero's art.
struct AppleHeroScrimView: View {
    let scrim: AppleHeroScrim

    var body: some View {
        ZStack {
            if !scrim.leading.isEmpty {
                LinearGradient(stops: Self.stops(scrim.leading), startPoint: .leading, endPoint: .trailing)
            }
            LinearGradient(stops: Self.stops(scrim.bottom), startPoint: .bottom, endPoint: .top)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private static func stops(_ stops: [AppleHeroScrim.Stop]) -> [Gradient.Stop] {
        stops.map { Gradient.Stop(color: .black.opacity($0.opacity), location: $0.location) }
    }
}

extension View {
    /// The scrim's soft shadow under a hero's copy, when it has one. Always
    /// applied (clear when there is none), so a change of tone never swaps
    /// the copy's identity and reloads its wordmark.
    func appleHeroCopyShadow(_ shadow: AppleHeroScrim.Shadow?) -> some View {
        self.shadow(color: .black.opacity(shadow?.opacity ?? 0), radius: shadow?.radius ?? 0, y: shadow == nil ? 0 : 1)
    }
}
