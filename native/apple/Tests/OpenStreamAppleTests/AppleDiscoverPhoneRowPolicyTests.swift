import Foundation
import Testing
@testable import OpenStreamApple

@Suite struct AppleDiscoverPhoneRowPolicyTests {
    @Test(arguments: [
        (0.0, 3420.0, "57 MIN LEFT"),
        (3000.0, 3480.0, "8 MIN LEFT"),
        (3590.0, 3600.0, "1 MIN LEFT"),
        (0.0, 3900.0, "1 HR 5 MIN LEFT"),
        (0.0, 7200.0, "2 HR LEFT"),
    ])
    func remainingTimeReadsLikeTheAppleTVApp(position: Double, duration: Double, expected: String) {
        #expect(AppleContinueWatchingCaption.remainingLabel(position: position, duration: duration) == expected)
    }

    @Test(arguments: [(10.0, 0.0), (10.0, .nan), (10.0, .infinity), (-1.0, 100.0), (100.0, 100.0)])
    func remainingTimeIsHiddenWhenTheLengthIsUnknown(position: Double, duration: Double) {
        #expect(AppleContinueWatchingCaption.remainingLabel(position: position, duration: duration) == nil)
    }

    @Test func subtitleNamesTheEpisodeOrSaysMovie() {
        #expect(AppleContinueWatchingCaption.subtitle(type: "series", partID: "tt0000001:1:3") == "Continue · S1, E3")
        #expect(AppleContinueWatchingCaption.subtitle(type: "series", partID: "tmdb:42:12:104") == "Continue · S12, E104")
        #expect(AppleContinueWatchingCaption.subtitle(type: "movie", partID: nil) == "Movie")
        #expect(AppleContinueWatchingCaption.subtitle(type: "series", partID: nil) == "Continue")
        #expect(AppleContinueWatchingCaption.subtitle(type: "series", partID: "tt0000001") == "Continue")
    }

    @Test func railsAlternateStillsAndPostersKeepingTheFirstRailFirst() {
        // Continue Watching, Your Library, Top Picks, Top 10 ×2, catalogue posters ×3.
        let shapes: [AppleDiscoverRailRhythm.Shape] = [.still, .poster, .still, .still, .still, .poster, .poster, .poster]
        let order = AppleDiscoverRailRhythm.order(shapes)
        #expect(order == [0, 1, 2, 5, 3, 6, 4, 7])
        #expect(order.map { shapes[$0] } == [.still, .poster, .still, .poster, .still, .poster, .still, .poster])
    }

    @Test func railsOfOneShapeKeepTheirOrder() {
        #expect(AppleDiscoverRailRhythm.order([.poster, .poster, .poster]) == [0, 1, 2])
        #expect(AppleDiscoverRailRhythm.order([.poster, .still, .still, .poster, .poster]) == [0, 1, 3, 2, 4])
        #expect(AppleDiscoverRailRhythm.order([]).isEmpty)
    }

    @Test func clampCandidatesShortenAtWordBoundaries() {
        #expect(AppleWordClamp.candidates("Why Did I Get Married Again?") == [
            "Why Did I Get Married Again?", "Why Did I Get Married…", "Why Did I Get…",
            "Why Did I…", "Why Did…", "Why…",
        ])
        #expect(AppleWordClamp.candidates("Monster: The Lizzie Borden Story").last == "Monster…")
        #expect(AppleWordClamp.candidates("Mayday") == ["Mayday"])
    }

    @Test func phoneStyleKeepsTheN11Sizes() {
        let style = AppleDiscoverRowStyle.phone
        #expect(style.platform == .phone)
        #expect([style.stillWidth, style.rankedWidth, style.posterWidth] == [248, 200, 148])
        #expect(style.horizontalInset == 16 && style.cardGap == 12)
    }

    @Test func macTilesAreDesktopSizedInA1440PointWindow() {
        let layout = AppleMacHeroLayout(contentWidth: 1440, windowHeight: 900)
        let style = AppleDiscoverRowStyle.mac(contentWidth: 1440, inset: layout.horizontalPadding)
        #expect(style.platform == .mac)
        #expect((300...340).contains(style.stillWidth))
        #expect(style.rankedWidth < style.stillWidth)
        #expect((160...200).contains(style.posterWidth))
        #expect(style.horizontalInset == layout.horizontalPadding)
    }

    @Test(arguments: [1000.0, 1200.0, 1440.0, 1700.0, 2200.0])
    func macRailsAlwaysShowPartOfTheTrailingTile(width: Double) {
        let inset = AppleMacHeroLayout(contentWidth: width).horizontalPadding
        let style = AppleDiscoverRowStyle.mac(contentWidth: width, inset: inset)
        for tile in [style.stillWidth, style.rankedWidth, style.posterWidth] {
            let inView = (width - inset + style.cardGap) / (tile + style.cardGap)
            let peek = inView - inView.rounded(.down)
            #expect(peek > 0.1 && peek < 0.9, "\(tile) pt tiles at \(width) pt leave \(peek) of a tile")
        }
    }

    @Test func macTilesGrowWithTheWindow() {
        func still(_ width: CGFloat) -> CGFloat {
            AppleDiscoverRowStyle.mac(contentWidth: width, inset: AppleMacHeroLayout(contentWidth: width).horizontalPadding).stillWidth
        }
        #expect(still(1000) < still(1440))
        #expect(still(1440) < still(1700))
    }

    @Test func macTileWidthBeforeTheWindowIsMeasuredIsThePreferredOne() {
        #expect(AppleDiscoverMacRowMetrics.peekWidth(available: 0, preferred: 320, gap: 16, range: 260...380) == 320)
        #expect(AppleDiscoverMacRowMetrics.peekWidth(available: -24, preferred: 320, gap: 16, range: 260...380) == 320)
    }

    @Test func railPagingStopsAtEitherEnd() {
        var geometry = AppleRailPaging.Geometry(offset: 0, contentWidth: 3000, visibleWidth: 1000)
        #expect(!AppleRailPaging.canPageBack(geometry))
        #expect(AppleRailPaging.canPageForward(geometry))
        #expect(AppleRailPaging.target(geometry, forward: true) == 800)
        #expect(AppleRailPaging.target(geometry, forward: false) == 0)
        geometry.offset = 1900
        #expect(AppleRailPaging.target(geometry, forward: true) == 2000)
        geometry.offset = 2000
        #expect(AppleRailPaging.canPageBack(geometry))
        #expect(!AppleRailPaging.canPageForward(geometry))
        #expect(AppleRailPaging.target(geometry, forward: false) == 1200)
    }

    @Test func railPageAnchorsCoverTheRailAndRoundToTheNearestOne() {
        #expect(AppleRailPaging.anchorCount(contentWidth: 0) == 0)
        #expect(AppleRailPaging.anchorCount(contentWidth: .nan) == 0)
        #expect(AppleRailPaging.anchorCount(contentWidth: 2398) == 60)
        #expect(AppleRailPaging.anchorIndex(for: 0) == 0)
        #expect(AppleRailPaging.anchorIndex(for: 1024) == 26)
        #expect(AppleRailPaging.anchorIndex(for: 1000) == 25)
        #expect(AppleRailPaging.anchorID(3) != AppleRailPaging.anchorID(4))
    }

    /// N54: a 1440 pt window, 43 pt inset, 176 pt posters 16 pt apart. Each
    /// page moves by the seven posters wholly in view and lands a poster on
    /// the inset; the last page stops at the scroll's end, and paging back
    /// from there returns to tile boundaries.
    @Test func tilePagingLandsWholeTilesOnTheInset() {
        let pitch: CGFloat = 176 + 16
        let content: CGFloat = 43 * 2 + 20 * 176 + 19 * 16
        var geometry = AppleRailPaging.Geometry(offset: 0, contentWidth: content, visibleWidth: 1440)
        let first = AppleRailPaging.tileAnchorIndex(geometry, forward: true, pitch: pitch, inset: 43)
        #expect(first == 7)
        geometry.offset = CGFloat(first) * pitch
        // Tile 7 starts at 43 + 7 × pitch; scrolled by 7 × pitch it sits at the inset.
        #expect(43 + 7 * pitch - geometry.offset == 43)
        #expect(AppleRailPaging.tileAnchorIndex(geometry, forward: true, pitch: pitch, inset: 43) == 13)
        geometry.offset = content - 1440
        #expect(AppleRailPaging.tileAnchorIndex(geometry, forward: true, pitch: pitch, inset: 43) == 13)
        #expect(AppleRailPaging.tileAnchorIndex(geometry, forward: false, pitch: pitch, inset: 43) == 6)
        geometry.offset = pitch * 3
        #expect(AppleRailPaging.tileAnchorIndex(geometry, forward: false, pitch: pitch, inset: 43) == 0)
    }

    @Test func thePitchFollowsFromTheRailsWidthAndTileCount() {
        let content: CGFloat = 43 * 2 + 20 * 176 + 19 * 16
        #expect(AppleRailPaging.tilePitch(contentWidth: content, tileCount: 20, inset: 43, gap: 16) == 192)
        #expect(AppleRailPaging.tilePitch(contentWidth: 0, tileCount: 20, inset: 43, gap: 16) == nil)
        #expect(AppleRailPaging.tilePitch(contentWidth: content, tileCount: 0, inset: 43, gap: 16) == nil)
    }

    @Test func tilePagingAlwaysMovesAtLeastOneTile() {
        let geometry = AppleRailPaging.Geometry(offset: 0, contentWidth: 2000, visibleWidth: 300)
        #expect(AppleRailPaging.tileAnchorIndex(geometry, forward: true, pitch: 396, inset: 43) == 1)
        #expect(AppleRailPaging.tileAnchorIndex(geometry, forward: true, pitch: 0, inset: 43) == 0)
    }

    @Test func tileAnchorsArePlacedOnePitchApart() {
        #expect(AppleRailPaging.anchorCount(contentWidth: 3910, step: 192) == 21)
        #expect(AppleRailPaging.anchorIndex(for: 1344, step: 192) == 7)
        #expect(AppleRailPaging.anchorCount(contentWidth: 3910, step: 0) == 0)
    }

    @Test func aRailNarrowerThanTheWindowHasNothingToPage() {
        let geometry = AppleRailPaging.Geometry(offset: 0, contentWidth: 600, visibleWidth: 1000)
        #expect(!AppleRailPaging.canPageBack(geometry))
        #expect(!AppleRailPaging.canPageForward(geometry))
        #expect(AppleRailPaging.target(geometry, forward: true) == 0)
    }

    #if DEBUG
    @Test func top10FixtureRanksCatalogueTitlesByTypeWithoutRepeats() throws {
        let source = AppleSource(kind: .stremio, name: "Fixture", url: try #require(URL(string: "https://fixture.example/manifest.json")))
        func section(_ type: String, _ names: [String]) -> AppleCatalogSection {
            AppleCatalogSection(source: source, catalog: AppleStremioCatalog(type: type, id: "c.\(type).\(names.count)", name: "C"),
                                items: names.map { AppleCatalogItem(mediaID: "fixture:\($0)", type: type, name: $0) })
        }
        let week = try #require(AppleTop10Fixture.week(sections: [
            section("movie", (1...8).map { "Film \($0)" }),
            section("movie", ["Film 2"] + (9...14).map { "Film \($0)" }),
            section("series", ["Show A", "Show B"]),
        ]))
        #expect(week.films.map(\.rank) == Array(1...10))
        #expect(week.films.map(\.title) == (1...10).map { "Film \($0)" })
        #expect(week.tv.map(\.title) == ["Show A", "Show B"])
        #expect(AppleTop10Fixture.week(sections: []) == nil)
    }

    @Test func fixtureHidesThePillWhenTheLengthIsUnknown() {
        #expect(AppleContinueWatchingFixture.info(index: 0, type: "series").remainingLabel == "57 MIN LEFT")
        #expect(AppleContinueWatchingFixture.info(index: 0, type: "series").subtitle == "Continue · S1, E3")
        #expect(AppleContinueWatchingFixture.info(index: 2, type: "movie").subtitle == "Movie")
        #expect(AppleContinueWatchingFixture.info(index: 3, type: "series").remainingLabel == nil)
    }
    #endif
}
