import CoreGraphics
import SwiftUI

/// Where the Live stage puts its two columns on iPhone and iPad.
enum AppleLiveStagePolicy {
    /// The guide column never gets narrower than this beside the player.
    static let minimumGuideWidth: CGFloat = 340

    /// Side by side only in a regular-width window wider than it is tall and
    /// wide enough for both columns; stacked everywhere else. Decided by the
    /// window, never the device, so a resized iPad window (or a foldable's
    /// inner screen) follows its own shape.
    static func sideBySide(isRegularWidth: Bool, size: CGSize) -> Bool {
        isRegularWidth && size.width > size.height
            && size.width >= minimumGuideWidth / 0.38
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
