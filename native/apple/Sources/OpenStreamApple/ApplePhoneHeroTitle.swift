import SwiftUI

struct ApplePhoneHeroTitle: View {
    let name: String
    let presentation: AppleTitleLogoPresentation
    var logoURL: URL?
    var onLoad: (Bool) -> Void = { _ in }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .largeTitle) private var titleSize: CGFloat = 44

    var textFallback: Text { Text(name) }

    var body: some View {
        Group {
            if presentation == .text {
                textFallback
                    .font(.system(size: min(max(titleSize, 34), dynamicTypeSize.isAccessibilitySize ? 58 : 48), weight: .black))
                    .tracking(1)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .minimumScaleFactor(0.6)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.8), radius: 12, y: 2)
            } else {
                ZStack {
                    if let logoURL {
                        AppleTrimmedTitleLogo(url: logoURL, alignment: .center, onLoadResult: onLoad)
                            .opacity(presentation == .logo ? 1 : 0)
                    }
                }
                .frame(maxWidth: 280)
                .frame(height: dynamicTypeSize.isAccessibilitySize ? 120 : AppleDetailMetrics.titleLogoMaxHeight)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityAddTraits(.isHeader)
        .accessibilityHidden(presentation == .hidden)
    }
}
