import SwiftUI

#if os(tvOS)
struct AppleAboutLinkView: View {
    private static let qrSide: CGFloat = 260
    let title: String
    let url: URL

    var body: some View {
        Form {
            AppleTVFocusReadableText(url.absoluteString)
                .focusable()
                .accessibilityIdentifier("settings.about.link.url")
            AppleWebManagementQRCode(url: url, accessibilityText: title)
                .frame(width: Self.qrSide, height: Self.qrSide)
                .accessibilityIdentifier("settings.about.link.qr")
        }
        .appleSettingsPage(title)
    }
}
#endif
