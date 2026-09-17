import Foundation
import Testing
@testable import OpenStreamApple

/// C8 (landscape) cannot be verified by capture: `simctl` has no orientation
/// option, so the rendered frame is unreachable from a headless harness. The
/// decisions behind the layout *are* pure functions of the viewport, so these
/// pin them at the real extremes — the shortest landscape phone the app
/// supports and the tallest — rather than only the mid-size one the existing
/// tests use.
@Suite("Landscape at the device extremes")
struct AppleLandscapeExtremesTests {
    /// iPhone SE (3rd gen): 375 pt of height in landscape, the least there is.
    private let smallestPhone = CGSize(width: 667, height: 375)
    /// iPhone 16 Pro Max: the most.
    private let largestPhone = CGSize(width: 956, height: 440)

    @Test func bothExtremesAreRecognisedAsLandscape() {
        #expect(AppleDetailMetrics.isLandscapeLayout(viewport: smallestPhone))
        #expect(AppleDetailMetrics.isLandscapeLayout(viewport: largestPhone))
    }

    /// The hero must leave room for a shelf underneath even on the shortest
    /// screen, which is the whole reason for the 55% cap.
    @Test func theHeroNeverEatsTheWholeShortestScreen() {
        for viewport in [smallestPhone, largestPhone] {
            let hero = AppleDetailMetrics.featuredHeroHeight(in: viewport)
            #expect(hero > 0)
            #expect(hero <= viewport.height * 0.55 + 0.0001,
                    "hero takes \(hero) of \(viewport.height)")
            #expect(viewport.height - hero >= 150,
                    "only \(viewport.height - hero) pt left for the shelves")
        }
    }

    /// The 16:9 arm of the cap is the binding one on a wide, short phone —
    /// without it the hero would be letterboxed against its own artwork.
    @Test func theWidthCapBindsOnTheShortestPhone() {
        let byHeight = smallestPhone.height * AppleDetailMetrics.featuredHeroLandscapeHeightFraction
        let byWidth = (smallestPhone.width - 32) * 9 / 16
        #expect(AppleDetailMetrics.featuredHeroHeight(in: smallestPhone) == min(byHeight, byWidth))
    }

    /// Owner's rule: the phone hides the tab bar in landscape so content fills
    /// the screen. Both extremes are compact, so both hide it.
    @Test func bothExtremesHideTheTabBar() {
        for viewport in [smallestPhone, largestPhone] {
            #expect(OpenStreamTabBarVisibility.isHidden(
                viewport: viewport, horizontalSizeClassIsCompact: true))
        }
    }

    /// Rotating back has to bring it straight back.
    @Test func rotatingBackToPortraitRestoresTheTabBar() {
        for viewport in [smallestPhone, largestPhone] {
            let portrait = CGSize(width: viewport.height, height: viewport.width)
            #expect(!OpenStreamTabBarVisibility.isHidden(
                viewport: portrait, horizontalSizeClassIsCompact: true))
            #expect(AppleDetailMetrics.featuredHeroHeight(in: portrait)
                    == AppleDetailMetrics.featuredHeroPortraitHeight)
        }
    }

    /// A square viewport is not landscape: the comparison is strict, so a
    /// transient resize mid-rotation cannot flip the layout.
    @Test func aSquareViewportIsNotLandscape() {
        #expect(!AppleDetailMetrics.isLandscapeLayout(viewport: CGSize(width: 500, height: 500)))
    }
}
