import SwiftUI

/// Genre, year and runtime with the outlined rating, centred under the
/// iPhone hero's title. Stacks at the accessibility text sizes so neither part
/// is truncated to nothing.
struct AppleHomePhoneHeroMetadata: View {
    let item: AppleCatalogItem
    var values: [String]? = nil
    var contentRating: String? = nil
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let fields = values ?? Self.values(for: item)
        let line = fields.isEmpty ? nil : fields.joined(separator: AppleBillboardCopy.separator)
        let rating = AppleBillboardCopy.ratingBadge(contentRating ?? item.contentRating)
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
    private static func values(for item: AppleCatalogItem) -> [String] {
        var values: [String] = []
        if let genre = item.genres?.first(where: { !$0.isEmpty }) { values.append(genre) }
        if item.type == "series", let release = AppleTitleMetadataPresentation.formattedReleaseInfo(item.releaseInfo) {
            values.append(release)
        } else if let year = item.year {
            values.append(String(year))
        }
        if let minutes = item.runtimeMinutes, (1 ... 24 * 60).contains(minutes) {
            values.append(AppleTitleMetadataPresentation.formattedRuntime(minutes))
        }
        return values
    }

}
