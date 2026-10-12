import SwiftUI

/// "TV Show · Thriller · Drama" and the outlined rating, centred under the
/// iPhone hero's title. Stacks at the accessibility text sizes so neither part
/// is truncated to nothing.
struct AppleHomePhoneHeroMetadata: View {
    let item: AppleCatalogItem
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let line = AppleBillboardCopy.phoneMetadataLine(type: item.type, genres: item.genres)
        let rating = AppleBillboardCopy.ratingBadge(item.contentRating)
        if line != nil || rating != nil {
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(spacing: 6))
                : AnyLayout(HStackLayout(spacing: 8))
            layout {
                if let line {
                    Text(line)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                }
                if let rating {
                    Text(rating)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .overlay {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .strokeBorder(.white.opacity(0.4), lineWidth: 1)
                        }
                        .accessibilityLabel("Rated \(rating)")
                }
            }
        }
    }
}
