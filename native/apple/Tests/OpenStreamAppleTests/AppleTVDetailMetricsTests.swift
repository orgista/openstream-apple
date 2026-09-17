import CoreGraphics
import Testing
@testable import OpenStreamApple

@Suite("Apple TV title page and chrome metrics")
struct AppleTVDetailMetricsTests {
    @Test func heroFillsTheWholeScreen() {
        #expect(AppleTVDetailMetrics.screenSize == CGSize(width: 1920, height: 1080))
        #expect(AppleTVDetailMetrics.heroFrame == CGRect(x: 0, y: 0, width: 1920, height: 1080))
    }

    @Test func overlaySitsAtEightyFromTheLeadingEdgeAndSixtyFromTheBottom() {
        #expect(AppleTVDetailMetrics.overlayLeadingInset == 80)
        #expect(AppleTVDetailMetrics.overlayBottomInset == 60)
        #expect(AppleTVDetailMetrics.overlayOrigin == CGPoint(x: 80, y: 1020))
        #expect(AppleTVDetailMetrics.overlayOrigin.y == AppleTVDetailMetrics.screenSize.height - 60)
    }

    @Test func titleBlockUsesTheSectionCTypeScale() {
        #expect(AppleTVDetailMetrics.wordmarkMaxSize == CGSize(width: 560, height: 180))
        #expect(AppleTVDetailMetrics.titleFontSize == 76)
        #expect(AppleTVDetailMetrics.metadataFontSize == 29)
        #expect(AppleTVDetailMetrics.badgeFontSize == 23)
        #expect(AppleTVDetailMetrics.synopsisFontSize == 29)
        #expect(AppleTVDetailMetrics.synopsisColumnWidth == 900)
        #expect(AppleTVDetailMetrics.shelfTitleFontSize == 38)
        #expect(AppleTVDetailMetrics.posterNameFontSize == 25)
    }

    @Test func playPillIsTwoTwentyBySixtySixCallout() {
        #expect(AppleTVDetailMetrics.pillSize == CGSize(width: 220, height: 66))
        #expect(AppleTVDetailMetrics.pillFontSize == 31)
    }

    @Test func glyphActionsAreThirtyEightPointsWithCentersOneTwentyApart() {
        #expect(AppleTVDetailMetrics.iconGlyphSize == 38)
        #expect(AppleTVDetailMetrics.iconLabelFontSize == 23)
        #expect(AppleTVDetailMetrics.iconCellWidth == 120)

        let centers = AppleTVDetailMetrics.iconCenters(count: 2)
        #expect(centers == [60, 180])
        #expect(centers[1] - centers[0] == 120)
        #expect(AppleTVDetailMetrics.iconCenters(count: 0).isEmpty)
        // Wider than the disc, so neighbouring glyphs never touch (HIG: 60 pt minimum).
        #expect(AppleTVDetailMetrics.iconCellWidth >= AppleTVDetailMetrics.iconDiscSize)
    }

    @Test func shelvesMatchTheSpec() {
        #expect(AppleTVDetailMetrics.episodeCardSize == CGSize(width: 400, height: 225))
        #expect(abs(AppleTVDetailMetrics.episodeCardSize.width / AppleTVDetailMetrics.episodeCardSize.height - 16.0 / 9.0) < 0.0001)
        #expect(AppleTVDetailMetrics.episodeCardGap == 40)
        #expect(AppleTVDetailMetrics.posterSize == CGSize(width: 260, height: 390))
        #expect(AppleTVDetailMetrics.posterSize.height == AppleTVDetailMetrics.posterSize.width * 1.5)
        #expect(AppleTVDetailMetrics.posterGap == 40)
        #expect(AppleTVDetailMetrics.cardCornerRadius == 18)
    }

    @Test func fullScreenLayoutIsChosenOnlyOnAppleTV() {
        #expect(AppleTVDetailMetrics.usesTVDetailLayout(on: .tvOS))
        #expect(!AppleTVDetailMetrics.usesTVDetailLayout(on: .iOS))
        #expect(!AppleTVDetailMetrics.usesTVDetailLayout(on: .visionOS))
        #expect(!AppleTVDetailMetrics.usesTVDetailLayout(on: .macOS))
        #if os(tvOS)
        #expect(AppleUIPlatform.current == .tvOS)
        #elseif os(macOS)
        #expect(AppleUIPlatform.current == .macOS)
        #endif
    }

    @Test func tabRootsDrawNoNavigationTitleOnAppleTV() {
        #expect(AppleAlignedTabTitle.style(for: .tvOS) == .hidden)
        #expect(AppleAlignedTabTitle.style(for: .iOS) == .leadingToolbarItem)
        #expect(AppleAlignedTabTitle.style(for: .macOS) == .inlineLargeNavigationTitle)
        #expect(AppleAlignedTabTitle.style(for: .visionOS) == .inlineLargeNavigationTitle)
    }

    @Test func pushedPageHeaderIsTitleThreeAtTheSafeZoneInset() {
        #expect(AppleTVChromeMetrics.pageHeaderFontSize == 48)
        #expect(AppleTVChromeMetrics.pageHeaderLeadingInset == 80)
        #expect(AppleTVChromeMetrics.pageHeaderLeadingInset == AppleTVChromeMetrics.horizontalSafeInset)
    }

    @Test func discoverGlyphPairStaysInsideTheSafeZone() {
        #expect(AppleTVChromeMetrics.glyphPairMaxX == 1840)
        #expect(AppleTVChromeMetrics.glyphPairMaxX <= AppleTVChromeMetrics.screenSize.width - AppleTVChromeMetrics.horizontalSafeInset)
        #expect(AppleTVChromeMetrics.glyphPairTrailingPaddingInsideSafeArea == 0)
        // The pair is a content row as tall as its 56 pt focus discs, so it
        // scrolls with the hero; a HIG-sized glyph (31 pt) fits inside.
        #expect(AppleTVChromeMetrics.glyphPairRowHeight == 56)
        #expect(AppleTVChromeMetrics.glyphPairRowHeight >= AppleTVChromeMetrics.glyphDiscSize)
        #expect(AppleTVChromeMetrics.glyphFontSize == 31)
        #expect(AppleTVChromeMetrics.glyphFontSize < AppleTVChromeMetrics.glyphDiscSize)
    }
}
