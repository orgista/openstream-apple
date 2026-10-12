import SwiftUI

/// The iPhone hero's one fade (the approved billboard fade, DESIGN-SPEC
/// 2026-09-22), over art that now starts at the top edge of the screen: clear
/// through the top third, where the status bar and the title sit, darkening
/// under the wordmark and the meta line, and solid black from just above the
/// buttons down, as the Apple TV app's does.
///
/// A light shade (black at 35 %, gone by 140 pt) sits under the status bar and
/// the large title only: over bright art — a sunlit street, a pale sky — the
/// clock and "Discover" were white on near-white (iPhone sim, 2026-09-23).
///
/// Over bright art under the copy the bottom fade climbs higher and deepens
/// (`AppleHeroScrim.phone`, N20).
struct AppleHomePhoneHeroFade: View {
    static let topShadeHeight: CGFloat = 140
    var scrim = AppleHeroScrim.phone(tone: .unknown)

    var body: some View {
        AppleHeroScrimView(scrim: scrim)
        .overlay(alignment: .top) {
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.35), location: 0),
                    .init(color: .black.opacity(0.3), location: 0.55),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: Self.topShadeHeight)
        }
        .accessibilityHidden(true)
    }
}
