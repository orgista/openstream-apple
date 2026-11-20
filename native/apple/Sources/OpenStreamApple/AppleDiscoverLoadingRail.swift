import SwiftUI

struct AppleDiscoverLoadingRail: View {
    let landscape: Bool
    let rowStyle: AppleDiscoverRowStyle?
    var sizing: AppleCatalogCardSizing? = nil

    private var cardSizing: AppleCatalogCardSizing { sizing ?? (landscape ? .continueWatching : .catalog) }

    private var cardWidth: CGFloat {
        AppleCatalogCard.width(sizing: cardSizing, rowStyle: rowStyle,
            scaledCardWidth: 140, viewportWidth: nil, regularWidth: rowStyle?.platform == .pad)
    }

    private var headingHeight: CGFloat {
        #if os(tvOS)
        AppleTVBillboardMetrics.rowTitleFontSize * 1.2
        #else
        29
        #endif
    }

    var body: some View {
        AppleMediaShelf(title: "", header: AnyView(
            RoundedRectangle(cornerRadius: 4)
                .fill(AppleDesignTokens.surface)
                .frame(width: cardWidth, height: headingHeight)
        )) {
            ForEach(0..<8) { _ in
                VStack(alignment: .leading, spacing: 8) {
                    AppleDiscoverLoadingPoster(width: cardWidth,
                        height: AppleCatalogCard.height(sizing: cardSizing, width: cardWidth), cornerRadius: rowStyle == nil ? 18 : 12)
                    #if os(tvOS)
                    if landscape {
                        Rectangle().fill(AppleDesignTokens.surface).frame(width: cardWidth * 0.65, height: 29)
                    }
                    #else
                    Rectangle().fill(AppleDesignTokens.surface).frame(width: cardWidth * 0.65, height: 20)
                    #endif
                }
            }
        }
    }
}

struct AppleDiscoverLoadingPoster: View {
    let width: CGFloat
    var height: CGFloat? = nil
    var cornerRadius: CGFloat = AppleUIPlatform.current == .tvOS ? 18 : AppleDesignTokens.cornerRadiusCard

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(AppleDesignTokens.surface)
            .frame(width: width, height: height ?? width * 1.5)
    }
}
