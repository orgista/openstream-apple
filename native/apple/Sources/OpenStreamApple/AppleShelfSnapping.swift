import SwiftUI

/// Whole-tile snapping for horizontal shelves, as in the Apple TV app on the
/// iPhone and iPad: a flick lands with a tile's leading edge on the row's
/// leading margin, under the row header (N65). The Apple TV is focus-driven
/// and the Mac pages whole tiles with its ‹ › buttons (N54), so only iOS
/// opts in; every other platform keeps its rails as they were.
///
/// `.viewAligned` aligns to the scroll view's content margins, not to padding
/// inside the content, so a snapping shelf sets its leading inset with
/// `contentMargins(_:_:for: .scrollContent)`.
enum AppleShelfSnapping {
    enum Platform: Equatable, Sendable, CaseIterable { case iOS, tvOS, macOS, visionOS }

    static func snapsToTiles(on platform: Platform) -> Bool {
        platform == .iOS
    }

    static var current: Platform {
        #if os(iOS)
        .iOS
        #elseif os(tvOS)
        .tvOS
        #elseif os(visionOS)
        .visionOS
        #else
        .macOS
        #endif
    }
}

extension View {
    /// On a shelf's tile stack: each tile becomes a snap target on iOS.
    @ViewBuilder
    func appleShelfSnapTargets() -> some View {
        #if os(iOS)
        scrollTargetLayout()
        #else
        self
        #endif
    }

    /// On a shelf's horizontal scroll view: a flick settles with a whole
    /// tile on the leading content margin on iOS.
    @ViewBuilder
    func appleShelfTileSnapping() -> some View {
        #if os(iOS)
        scrollTargetBehavior(.viewAligned)
        #else
        self
        #endif
    }
}
