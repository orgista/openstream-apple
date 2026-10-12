import SwiftUI

/// How a tab root is titled on each platform.
enum AppleTabTitleStyle: Equatable, Sendable {
    /// iPhone and iPad: the stock inline-large navigation title (title shares the
    /// toolbar row, collapses with scrolling).
    case largeNavigationTitle
    /// Apple TV: no page title under the tab bar (the stock TV app has none).
    case hidden
    /// Mac and Vision Pro: the stock inline-large navigation title.
    case inlineLargeNavigationTitle
    /// Live tab on iPhone and iPad: inline, no large title row.
    case inline
}

/// Uses a native navigation title so iOS does not turn plain text into toolbar chrome.
struct AppleAlignedTabTitle: ViewModifier {
    let title: String
    let isLive: Bool

    static func style(for platform: AppleUIPlatform, isLive: Bool = false) -> AppleTabTitleStyle {
        switch platform {
        case .iOS: return isLive ? .inline : .largeNavigationTitle
        case .tvOS: return .hidden
        case .visionOS, .macOS: return .inlineLargeNavigationTitle
        }
    }

    func body(content: Content) -> some View {
        #if os(iOS)
        if isLive {
            legacyNavigationBackground(content)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
        } else {
            // `.inlineLarge` puts the large title in the toolbar row instead of a
            // second row beneath it, so "Discover" and "Live" sit right under the
            // status bar (owner, 2026-09-18: "Live is too low… Discover is too low").
            legacyNavigationBackground(content)
                .navigationTitle(title)
                .toolbarTitleDisplayMode(.inlineLarge)
        }
        #elseif os(tvOS)
        content
        #else
        content
            .navigationTitle(title)
            .toolbarTitleDisplayMode(.inlineLarge)
        #endif
    }

    #if os(iOS)
    @ViewBuilder
    private func legacyNavigationBackground(_ content: Content) -> some View {
        if #available(iOS 26, *) {
            content
        } else {
            content
                .toolbarBackground(Color(uiColor: .systemBackground), for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
        }
    }
    #endif
}

extension View {
    func appleAlignedTabTitle(_ title: String, isLive: Bool = false) -> some View { modifier(AppleAlignedTabTitle(title: title, isLive: isLive)) }
}
