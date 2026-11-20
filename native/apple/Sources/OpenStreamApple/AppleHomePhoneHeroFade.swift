import SwiftUI

/// The iPhone hero's approved billboard fade, clear through the top third,
/// darkening under the wordmark and solid black above the buttons. Bright
/// artwork keeps this same fade; the copy uses its existing shadow.
struct AppleHomePhoneHeroFade: View {
    var scrim = AppleHeroScrim.phone(tone: .unknown)

    var body: some View {
        AppleHeroScrimView(scrim: scrim)
            .accessibilityHidden(true)
    }
}
