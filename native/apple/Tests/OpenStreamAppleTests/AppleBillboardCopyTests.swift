import Foundation
import Testing
@testable import OpenStreamApple

/// The one metadata line under a hero's title lockup. Both billboards draw it,
/// so the rule is pinned here rather than in either view.
@Suite("Billboard copy")
struct AppleBillboardCopyTests {
    @Test func genresAndYearJoin() {
        #expect(AppleBillboardCopy.metadataLine(genres: ["Drama", "Sci-Fi"], year: 2024, releaseInfo: nil)
            == "Drama · Sci-Fi · 2024")
    }

    /// The Apple TV app's line is short. A title tagged with six genres must
    /// not push the year off the end of a one-line field.
    @Test func atMostTwoGenres() {
        #expect(AppleBillboardCopy.metadataLine(
            genres: ["Drama", "Sci-Fi", "Thriller", "Mystery"], year: 2024, releaseInfo: nil)
            == "Drama · Sci-Fi · 2024")
    }

    @Test func releaseTextStandsInForAMissingYear() {
        #expect(AppleBillboardCopy.metadataLine(genres: ["Comedy"], year: nil, releaseInfo: "2019–2023")
            == "Comedy · 2019–2023")
    }

    @Test func yearWinsOverReleaseText() {
        #expect(AppleBillboardCopy.metadataLine(genres: nil, year: 2024, releaseInfo: "2019–2023") == "2024")
    }

    /// Nothing known means no line at all — never a lonely separator, and
    /// never an empty row holding space in the copy block.
    @Test func nothingKnownDrawsNothing() {
        #expect(AppleBillboardCopy.metadataLine(genres: nil, year: nil, releaseInfo: nil) == nil)
        #expect(AppleBillboardCopy.metadataLine(genres: [], year: nil, releaseInfo: "   ") == nil)
    }

    @Test func blankGenresAreDropped() {
        #expect(AppleBillboardCopy.metadataLine(genres: ["", "  ", "Horror"], year: nil, releaseInfo: nil) == "Horror")
    }
}

/// The hero's frame on each device. The iPad landscape regression the owner
/// reported on 2026-09-20 was a hero that reserved a flat 600 pt of height for
/// its art and then stacked the copy underneath it, so these are the numbers
/// that say the frame still scales with the viewport.
@Suite("Featured hero geometry")
struct AppleFeaturedHeroGeometryTests {
    @Test func portraitKeepsItsFixedHeight() {
        #expect(AppleDetailMetrics.featuredHeroHeight(in: CGSize(width: 834, height: 1210)) == 390)
        #expect(AppleDetailMetrics.featuredHeroHeight(in: CGSize(width: 393, height: 852)) == 390)
    }

    /// 55 % of an iPad in landscape, which leaves Continue Watching peeking in
    /// under the billboard instead of a screenful of hero.
    @Test func iPadLandscapeIsAFractionOfTheViewport() {
        let height = AppleDetailMetrics.featuredHeroHeight(in: CGSize(width: 1210, height: 834))
        #expect(height == 834 * 0.55)
        #expect(height < 834)
    }

    /// On a barely-landscape canvas — a Stage Manager window, a resized Mac
    /// window — 16:9 is the lower of the two caps and it is the one that wins,
    /// so the art is never taller than the shape it is cropped to.
    @Test func aNearlySquareCanvasIsCappedBySixteenByNine() {
        let viewport = CGSize(width: 810, height: 800)
        #expect(AppleDetailMetrics.featuredHeroHeight(in: viewport) == CGFloat(810 - 32) * 9 / 16)
        #expect(AppleDetailMetrics.featuredHeroHeight(in: viewport) < 800 * 0.55)
    }

    /// A wide canvas is governed by the height fraction instead, which is what
    /// leaves room for Continue Watching under the billboard.
    @Test func aWideCanvasIsCappedByTheHeightFraction() {
        let viewport = CGSize(width: 1600, height: 500)
        #expect(AppleDetailMetrics.featuredHeroHeight(in: viewport) == 500 * 0.55)
    }

    /// Landscape is decided by the viewport, not by the idiom: the phone in
    /// landscape gets the same overlay hero the iPad does.
    @Test func landscapeIsDecidedByTheViewport() {
        #expect(AppleDetailMetrics.isLandscapeLayout(viewport: CGSize(width: 852, height: 393)))
        #expect(!AppleDetailMetrics.isLandscapeLayout(viewport: CGSize(width: 393, height: 852)))
        #expect(!AppleDetailMetrics.isLandscapeLayout(viewport: .zero))
    }
}
