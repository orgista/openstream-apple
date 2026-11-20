import SwiftUI

struct AppleContinueWatchingArtworkTitle: View {
    let title: String
    let hasProgress: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let inset = AppleCatalogCardMetrics.progressBarInset
        Text(title)
            .font(.headline.weight(.semibold))
            .foregroundStyle(.white)
            .shadow(color: .black, radius: 2, y: 1)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, inset.horizontal)
            .padding(.bottom, inset.bottom + (hasProgress ? 14 : 2))
            .frame(maxWidth: .infinity, alignment: .bottomLeading)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
