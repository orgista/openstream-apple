import CoreGraphics
import SwiftUI

/// Where the Live stage puts its two columns on iPhone and iPad.
enum AppleLiveStagePolicy {
    /// The guide column never gets narrower than this beside the player.
    static let minimumGuideWidth: CGFloat = 340
    static let phoneLogoSize = CGSize(width: 50, height: 50)
    static let phoneChannelRowHeight: CGFloat = 88
    static let phoneProgrammeLineHeight: CGFloat = 3
    /// Paramount+ on a test iPhone (2026-10-21): one flat #121212 panel from the stage's bottom edge
    /// carries the category strip and the rows; the strip is 81 pt from the stage to the first row,
    /// its underline 1 pt, as wide as the label, 6 pt under it; labels about 40 pt apart.
    static let phoneCategoryHeight: CGFloat = 81
    /// The strip's 44 pt row of chips and glyphs starts here, putting the labels' centre 38 pt
    /// below the stage: Paramount+ sets its labels' cap middle at 37.5 pt, baseline 43 pt, the
    /// underline at 55 pt (iPhone capture, 2026-10-20, measured 2026-10-22).
    static let phoneCategoryRowTop: CGFloat = 16
    static let phoneCategorySpacing: CGFloat = 40
    static let phoneCategoryUnderlineHeight: CGFloat = 1
    static let phoneCategoryUnderlineGap: CGFloat = 6
    static let phonePanel = Color(white: 18 / 255)
    static let phoneGuideRowHeight: CGFloat = 64

    /// Every iPad window stacks like Paramount+ (owner 2026-10-21: "live on
    /// ipad needs to full screen"). A large phone window (an unfolded Duo; the
    /// root already checked its size class and size) splits on its side and
    /// stacks upright. A visionOS window splits when wide enough.
    static func sideBySide(isRegularWidth: Bool, size: CGSize, expandsPhoneLayout: Bool = false,
                           isPad: Bool = false) -> Bool {
        guard size.width > size.height, !isPad else { return false }
        if expandsPhoneLayout { return true }
        return isRegularWidth && size.width >= minimumGuideWidth / 0.38
    }

    /// Channel rows a stacked large window keeps under the strip.
    static let minimumStackedRows = 3

    /// The stacked stage on a large window: as wide as the window at 16:9,
    /// shorter only when that would leave fewer than `minimumStackedRows`
    /// rows under the category strip (an iPad on its side).
    static func stackedStageHeight(size: CGSize) -> CGFloat {
        let fullWidth = size.width * 9 / 16
        let room = size.height - phoneCategoryHeight - CGFloat(minimumStackedRows) * phoneChannelRowHeight
        return max(0, min(fullWidth, room)).rounded(.down)
    }

    /// Beside the list on a large phone window the stage's column continues
    /// with the playing channel's schedule (`AppleLiveStageSchedule`).
    static func showsSchedule(sideBySide: Bool, expandsPhoneLayout: Bool) -> Bool {
        sideBySide && expandsPhoneLayout
    }

    /// The player column's width beside the guide: 62 %, leaving the guide
    /// at least `minimumGuideWidth`.
    static func playerWidth(total: CGFloat) -> CGFloat {
        max(0, min((total * 0.62).rounded(.down), total - minimumGuideWidth))
    }
}

#if os(iOS)
/// The system tab bar keeps its standard opaque background over the Live
/// list on iOS 18, so the rows do not show through it (owner decision
/// 2026-10-09). iOS 26 keeps its own Liquid Glass bar untouched.
struct AppleLiveTabBarBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content
        } else {
            content.toolbarBackground(.visible, for: .tabBar)
        }
    }
}
#endif
