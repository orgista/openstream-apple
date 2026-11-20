import SwiftUI

/// A window's layout, independent of the device family. The existing title-page
/// tablet breakpoint is 600 pt; checking both axes keeps rotated phones small.
/// The iPhone Duo (Xcode 27.2 device profile) is 466 x 678 pt folded and
/// 669 x 951 pt unfolded (inner panel 2007 x 2853 px at 3x): the breakpoint
/// sits between its two short sides.
enum AppleLayoutClass {
    static let minimumShortSide: CGFloat = 600

    static func isLarge(size: CGSize, isRegularWidth: Bool) -> Bool {
        isRegularWidth && min(size.width, size.height) >= minimumShortSide
    }

    /// The app's large-layout flag. Every iPad window keeps the iPad's layout,
    /// Slide Over, split view and short Stage Manager windows included; a phone
    /// is large only while its window is (an unfolded Duo).
    static func usesLargeLayout(isPad: Bool, size: CGSize, isRegularWidth: Bool) -> Bool {
        isPad || isLarge(size: size, isRegularWidth: isRegularWidth)
    }

    /// iPads split Settings in a regular-width landscape window, as before;
    /// a large phone window splits in either orientation.
    static func settingsUseSplitView(size: CGSize, isRegularWidth: Bool, isPad: Bool) -> Bool {
        if isPad { return isRegularWidth && AppleDetailMetrics.isLandscapeLayout(viewport: size) }
        return isLarge(size: size, isRegularWidth: isRegularWidth)
    }

    /// Discover and Library keep the phone's landing chrome (no bar at rest, round
    /// Search and Refresh over the art) on every phone, an unfolded Duo included;
    /// only a large iPad window shows the stock bar with its title.
    static func usesPadLandingChrome(isLarge: Bool, isPhone: Bool) -> Bool {
        isLarge && !isPhone
    }

    #if os(iOS)
    /// The key window of any connected scene, backgrounded ones included.
    @MainActor static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)
    }
    #endif
}

/// The side safe area a hero's art and the Live video may run under: the
/// iPhone Duo keeps its status bar (folded) or tab bar (unfolded) in an
/// 84 pt column on one side, so its sides differ. A notched iPhone on its side
/// insets both sides equally for the camera; the art stays inside those, so
/// phones are unchanged.
enum AppleHeroSideColumn {
    static func insets(leading: CGFloat, trailing: CGFloat) -> EdgeInsets {
        guard leading != trailing else { return EdgeInsets() }
        return EdgeInsets(top: 0, leading: leading, bottom: 0, trailing: trailing)
    }
}

#if os(iOS)
/// A hero's art runs under the side column (`AppleHeroSideColumn`); copy and
/// controls stay beside it (`appleHeroSideBleed`).
struct AppleHeroSideBleed: ViewModifier {
    let insets: EdgeInsets

    func body(content: Content) -> some View {
        content
            .environment(\.appleHeroSideBleed, insets)
            .padding(.leading, -insets.leading)
            .padding(.trailing, -insets.trailing)
    }

    /// The side column alone, so a bar moving does not redraw the page.
    nonisolated static func sides(of proxy: GeometryProxy) -> EdgeInsets {
        AppleHeroSideColumn.insets(leading: proxy.safeAreaInsets.leading, trailing: proxy.safeAreaInsets.trailing)
    }
}
#endif

extension EnvironmentValues {
    @Entry var appleIsLargeLayout = false
    @Entry var appleExpandsPhoneLayout = false
    /// How far the hero's art runs past the page's sides (`AppleHeroSideBleed`).
    @Entry var appleHeroSideBleed = EdgeInsets()

    var appleUsesPadLandingChrome: Bool {
        // `appleExpandsPhoneLayout` is set only for a large window on a phone.
        AppleLayoutClass.usesPadLandingChrome(isLarge: appleIsLargeLayout, isPhone: appleExpandsPhoneLayout)
    }
}
