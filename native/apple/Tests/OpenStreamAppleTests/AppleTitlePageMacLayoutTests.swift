import CoreGraphics
import Testing
@testable import OpenStreamApple

@Suite("Mac title page layout")
struct AppleTitlePageMacLayoutTests {
    @Test("The art is Discover's hero, from the same window", arguments: [
        CGSize(width: 1440, height: 900),
        CGSize(width: 1000, height: 800),
        CGSize(width: 1700, height: 1000),
        CGSize(width: 700, height: 1400),
        CGSize(width: 800, height: 400),
        CGSize.zero,
    ])
    func heroIsTheDiscoverHero(window: CGSize) {
        let layout = AppleTitlePageMacLayout(contentWidth: window.width, windowHeight: window.height)
        let discover = AppleMacHeroLayout(contentWidth: window.width, windowHeight: window.height)
        #expect(layout.heroHeight == discover.height.rounded())
    }

    @Test func heroSizesAtCommonWindows() {
        // The window less the first row's peek, at most 75 % of the width,
        // never under 360.
        #expect(AppleTitlePageMacLayout(contentWidth: 1440, windowHeight: 900).heroHeight == 724)
        #expect(AppleTitlePageMacLayout(contentWidth: 1700, windowHeight: 1000).heroHeight == 824)
        #expect(AppleTitlePageMacLayout(contentWidth: 700, windowHeight: 1400).heroHeight == 525)
        #expect(AppleTitlePageMacLayout(contentWidth: 800, windowHeight: 400).heroHeight == 360)
        #expect(AppleTitlePageMacLayout.heroBottomPadding == AppleMacHeroLayout.bottomPadding)
    }

    @Test func theCopyColumnGrowsWithTheWindowWithinItsBounds() {
        #expect(AppleTitlePageMacLayout(contentWidth: 1000, windowHeight: 800).copyWidth == 420)
        #expect(AppleTitlePageMacLayout(contentWidth: 700, windowHeight: 800).copyWidth == 360)
        #expect(AppleTitlePageMacLayout(contentWidth: 1700, windowHeight: 1000).copyWidth == 560)
        // Never wider than the window leaves between its insets.
        let narrow = AppleTitlePageMacLayout(contentWidth: 380, windowHeight: 800)
        #expect(narrow.copyWidth == 380 - 2 * narrow.horizontalInset)
    }

    @Test func theInsetIsTheDiscoverRailsInset() {
        for width in [800.0, 1200, 1440, 1900] {
            let layout = AppleTitlePageMacLayout(contentWidth: width, windowHeight: 900)
            #expect(layout.horizontalInset == AppleMacHeroLayout(contentWidth: width).horizontalPadding)
        }
    }

    @Test func referenceBlocksStackBelowTheBreakpointAndSitSideBySideAboveIt() {
        let narrow = AppleTitlePageMacLayout(contentWidth: 899, windowHeight: 800)
        #expect(narrow.referenceColumns(count: 3) == 1)
        let wide = AppleTitlePageMacLayout(contentWidth: 900, windowHeight: 800)
        #expect(wide.referenceColumns(count: 3) == 3)
        #expect(wide.referenceColumns(count: 2) == 2)
        #expect(wide.referenceColumns(count: 1) == 1)
        #expect(wide.referenceColumns(count: 0) == 1)
        #expect(wide.referenceColumns(count: 5) == 3)
    }
}
