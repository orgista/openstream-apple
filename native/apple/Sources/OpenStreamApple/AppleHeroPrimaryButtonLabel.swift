import SwiftUI

/// The hero button's glyph and words (`AppleTitlePagePolicy.HeroButton`).
struct AppleHeroPrimaryButtonLabel: View {
    let button: AppleTitlePagePolicy.HeroButton

    var body: some View {
        Label(button.title, systemImage: button.systemImage)
    }
}

extension View {
    /// Keeps a hero button's place while its label is still undecided,
    /// rather than showing it greyed out (N17d).
    func appleHeroPrimaryButtonState(_ button: AppleTitlePagePolicy.HeroButton) -> some View {
        opacity(button.isHidden ? 0 : 1)
            .allowsHitTesting(!button.isHidden)
            .accessibilityHidden(button.isHidden)
    }
}
