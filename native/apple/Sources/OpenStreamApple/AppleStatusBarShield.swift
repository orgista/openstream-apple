import SwiftUI

/// Keeps scrolled content from being drawn across the clock.
///
/// The detail page hides the navigation bar on iOS so its hero can bleed to the
/// top of the screen, which is right — but with no bar there is also nothing
/// behind the status bar once the page scrolls, so the synopsis was drawn
/// straight through the time and the battery. Measured on both the iPhone and
/// the iPad at the default text size (2026-09-17), so it is not an accessibility
/// edge case.
///
/// The shield is a flat black fill, not a scrim: the owner's rules allow exactly
/// one gradient in the app and this is not it. It is invisible while the page is
/// at rest — the hero is supposed to run under the status bar there — and
/// appears as soon as the page moves.
struct AppleStatusBarShield: ViewModifier {
    /// The page's own top safe-area inset. Passed in rather than measured here
    /// because an overlay reads a safe area its parent has already consumed.
    let topInset: CGFloat

    @State private var isScrolled = false

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: Bool.self) { geometry in
                // 8 pt of slack so a rubber-band bounce at rest does not flicker
                // the shield on and off.
                geometry.contentOffset.y > 8
            } action: { _, scrolled in
                isScrolled = scrolled
            }
            .overlay(alignment: .top) {
                Color.black
                    .frame(height: topInset)
                    .opacity(isScrolled ? 1 : 0)
                    .animation(.easeOut(duration: 0.15), value: isScrolled)
                    .ignoresSafeArea(edges: .top)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }
}

extension View {
    /// iOS only: every other platform either keeps its navigation bar or has no
    /// status bar to collide with.
    @ViewBuilder
    func appleStatusBarShield(topInset: CGFloat) -> some View {
        #if os(iOS)
        modifier(AppleStatusBarShield(topInset: topInset))
        #else
        self
        #endif
    }
}
