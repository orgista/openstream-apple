import SwiftUI

/// How a tab root is titled on each platform.
enum AppleTabTitleStyle: Equatable, Sendable {
    /// iPhone and iPad: a leading toolbar item shares the bar row with the icons.
    case leadingToolbarItem
    /// Apple TV: no page title under the tab bar (the stock TV app has none).
    case hidden
    /// Mac and Vision Pro: the stock inline-large navigation title.
    case inlineLargeNavigationTitle
}

/// Owner item 9 (2026-09-03): the tab title shares the bar row with the
/// trailing toolbar icons and sits at the leading edge (the way the Live TV
/// reference does it) instead of on its own line beneath them. On iPhone the
/// system inline title is always centered, so the title is drawn as a leading
/// toolbar item and the navigation title is left empty (pushed screens then
/// show a plain "Back" button). On Apple TV tab roots carry no title at all
/// (rework plan task 3); pushed tvOS pages draw their own `TVPageHeader`.
struct AppleAlignedTabTitle: ViewModifier {
    let title: String

    static func style(for platform: AppleUIPlatform) -> AppleTabTitleStyle {
        switch platform {
        case .iOS: .leadingToolbarItem
        case .tvOS: .hidden
        case .visionOS, .macOS: .inlineLargeNavigationTitle
        }
    }

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Text(title)
                        .font(.title.bold())
                        .foregroundStyle(.primary)
                        .accessibilityAddTraits(.isHeader)
                }
            }
        #elseif os(tvOS)
        content
        #else
        content
            .navigationTitle(title)
            .toolbarTitleDisplayMode(.inlineLarge)
        #endif
    }
}

extension View {
    func appleAlignedTabTitle(_ title: String) -> some View { modifier(AppleAlignedTabTitle(title: title)) }
}
