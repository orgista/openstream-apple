import CoreGraphics
import Testing
@testable import OpenStreamApple

@Suite struct AppleDiscoverRowSizingTests {
    /// Owner 2026-11-04: every Apple TV poster row uses the Featured size.
    @Test func televisionDrawsEveryPosterAtTheFeaturedSize() {
        for (sizing, expected) in [(AppleCatalogCardSizing.catalog, CGSize(width: 400, height: 600)),
                                   (.portraitPromo, CGSize(width: 400, height: 600)),
                                   (.continueWatching, CGSize(width: 480, height: 270)),
                                   (.ranked, CGSize(width: 480, height: 270))] {
            let width = AppleCatalogCard.width(sizing: sizing, rowStyle: nil, scaledCardWidth: 500,
                viewportWidth: 1920, regularWidth: true, platform: .tvOS)
            #expect(CGSize(width: width, height: AppleCatalogCard.height(sizing: sizing, width: width)) == expected)
        }
    }

    @Test func phoneAndPadSizesStayFixedAtAccessibilityTextSizes() {
        for (style, featured, poster, resume, rank) in [
            (AppleDiscoverRowStyle.phone, 200.0, 148.0, 248.0, 200.0),
            (.pad(contentWidth: 1366), 260.0, 180.0, 320.0, 320.0)
        ] {
            for (sizing, expected) in [(AppleCatalogCardSizing.portraitPromo, featured),
                                       (.catalog, poster), (.continueWatching, resume), (.ranked, rank)] {
                let width = AppleCatalogCard.width(sizing: sizing, rowStyle: style, scaledCardWidth: 500,
                    viewportWidth: 1366, regularWidth: style.platform == .pad, platform: .iOS)
                #expect(width == CGFloat(expected))
            }
        }
    }

    @Test func unspecializedIOSCardsUseTheSameFixedSizes() {
        for (regular, poster, featured, resume) in [(false, 148.0, 200.0, 248.0), (true, 180.0, 260.0, 320.0)] {
            for (sizing, expected) in [(AppleCatalogCardSizing.catalog, poster), (.portraitPromo, featured), (.continueWatching, resume)] {
                #expect(AppleCatalogCard.width(sizing: sizing, rowStyle: nil, scaledCardWidth: 500,
                    viewportWidth: 1366, regularWidth: regular, platform: .iOS) == CGFloat(expected))
            }
        }
    }

    @Test func televisionFitsFourPostersAndASliverInsideTheSafeArea() {
        let width = AppleCatalogCard.width(sizing: .catalog, rowStyle: nil, scaledCardWidth: 140,
            viewportWidth: 1920, regularWidth: true, platform: .tvOS)
        let available = AppleTVBillboardMetrics.screenSize.width - 2 * AppleTVBillboardMetrics.copyLeadingInset
        let visible = (available + AppleTVBillboardMetrics.cardGap) / (width + AppleTVBillboardMetrics.cardGap)
        #expect(visible.rounded(.down) == 4)
        let nextCardLeading = visible.rounded(.down) * (width + AppleTVBillboardMetrics.cardGap)
        #expect(available - nextCardLeading > 0)
    }
}
