import CoreGraphics
import Testing
@testable import OpenStreamApple

/// N44: the Mac hero's trailer is drawn at its art's own geometry — the same
/// aspect-fill scale about the same centre — so the crossfade from the art
/// to the trailer never reads as a zoom, in a window or full screen.
@Suite("Mac hero: the trailer keeps the art's geometry")
struct AppleMacHeroArtMatchedTrailerTests {
    /// A 1440 pt window, a 1100 pt one, the owner's 3440 × 1440 display
    /// maximised and full screen, a 3000 × 1200 window, and a narrow one.
    private static let heroes: [CGSize] = [
        CGSize(width: 1_440, height: 675), CGSize(width: 1_100, height: 570),
        CGSize(width: 3_440, height: 680), CGSize(width: 3_000, height: 680),
        CGSize(width: 900, height: 600),
    ]
    private static let backdrop = CGSize(width: 1_920, height: 1_080)

    private func isClose(_ a: CGRect, _ b: CGRect, within tolerance: CGFloat = 0.001) -> Bool {
        abs(a.minX - b.minX) < tolerance && abs(a.minY - b.minY) < tolerance
            && abs(a.width - b.width) < tolerance && abs(a.height - b.height) < tolerance
    }

    @Test("Over a 16:9 still the trailer's raster is exactly the still's rect", arguments: heroes)
    func sameRectAsTheArt(hero: CGSize) {
        let art = AppleTrailerPreviewLayout.aspectFillFrame(of: Self.backdrop, in: hero)
        let trailer = AppleTrailerPreviewLayout.artMatchedFrame(in: hero, art: Self.backdrop)
        #expect(isClose(trailer, art))
    }

    @Test("Art and trailer show the same part of themselves: no zoom, no shift", arguments: heroes)
    func sameCrop(hero: CGSize) {
        let viewport = CGRect(origin: .zero, size: hero)
        let art = AppleTrailerPreviewLayout.aspectFillFrame(of: Self.backdrop, in: hero)
        let trailer = AppleTrailerPreviewLayout.artMatchedFrame(in: hero, art: Self.backdrop)
        let artCrop = AppleMacHeroCrop.visibleFraction(of: art, through: viewport)
        let trailerCrop = AppleMacHeroCrop.visibleFraction(of: trailer, through: viewport)
        #expect(isClose(artCrop, trailerCrop))
    }

    /// The probe's 1440 pt window: Project Hail Mary's picture band is 75 %
    /// of its raster. Covering the hero with the band drew it 1.111× the art.
    @Test("A letterboxed trailer is not enlarged to crop its mattes")
    func letterboxedIsNotEnlarged() {
        let hero = CGSize(width: 1_440, height: 675)
        let bandFraction: CGFloat = 0.75
        let art = AppleTrailerPreviewLayout.aspectFillFrame(of: Self.backdrop, in: hero)
        let bandCovering = hero.height / bandFraction
        #expect(bandCovering / art.height > 1.1)
        let trailer = AppleTrailerPreviewLayout.artMatchedFrame(in: hero, art: Self.backdrop)
        #expect(abs(trailer.height / art.height - 1) < 0.0001)
    }

    /// N62 (owner): a 2.37:1 trailer (band 0.125...0.875, as the probe
    /// measured at 1280 × 684) played with black above and below it. The
    /// band must cover the hero at every window size, with no gap.
    @Test("A measured letterboxed band covers the hero, no black bands",
          arguments: heroes + [CGSize(width: 1_286, height: 674), CGSize(width: 1_280, height: 684),
                               CGSize(width: 3_440, height: 1_136), CGSize(width: 900, height: 424)])
    func letterboxedBandCoversTheHero(hero: CGSize) {
        for band: ClosedRange<CGFloat> in [0.125...0.875, 0.1...0.9, 0.2...0.8, 0.12...0.86] {
            let trailer = AppleTrailerPreviewLayout.artMatchedFrame(in: hero, art: Self.backdrop, pictureWindow: band)
            let top = trailer.minY + trailer.height * band.lowerBound
            let bottom = trailer.minY + trailer.height * band.upperBound
            #expect(top <= 0.001 && bottom >= hero.height - 0.001)
            #expect(trailer.minX <= 0.001 && trailer.maxX >= hero.width - 0.001)
            #expect(abs(trailer.width / trailer.height - 16.0 / 9.0) < 0.0001)
            #expect(abs(trailer.midX - hero.width / 2) < 0.001)
            // No larger than it must be: the art's frame, or the band exactly the hero's height.
            let art = AppleTrailerPreviewLayout.artMatchedFrame(in: hero, art: Self.backdrop)
            #expect(trailer.height <= max(art.height, hero.height / (band.upperBound - band.lowerBound)) + 0.001)
        }
    }

    @Test("The owner's window: the band grows to the hero's height, centred on it")
    func ownersWindow() {
        let hero = CGSize(width: 1_280, height: 684)
        let trailer = AppleTrailerPreviewLayout.artMatchedFrame(in: hero, art: Self.backdrop, pictureWindow: 0.125...0.875)
        #expect(abs(trailer.height - 912) < 0.001)
        #expect(abs(trailer.minY - -114) < 0.001)
        #expect(abs(trailer.minX - -170.667) < 0.001)
    }

    @Test("No still decoded yet: a letterboxed band still covers the hero", arguments: heroes)
    func noStillBandCovers(hero: CGSize) {
        let band: ClosedRange<CGFloat> = 0.125...0.875
        let trailer = AppleTrailerPreviewLayout.artMatchedFrame(in: hero, art: nil, pictureWindow: band)
        #expect(trailer.minY + trailer.height * band.lowerBound <= 0.001)
        #expect(trailer.minY + trailer.height * band.upperBound >= hero.height - 0.001)
    }

    @Test("A band that already covers the hero keeps the art's frame (no zoom)")
    func coveringBandKeepsTheArtFrame() {
        let hero = CGSize(width: 3_440, height: 1_136)
        let art = AppleTrailerPreviewLayout.artMatchedFrame(in: hero, art: Self.backdrop)
        let trailer = AppleTrailerPreviewLayout.artMatchedFrame(in: hero, art: Self.backdrop, pictureWindow: 0.125...0.875)
        #expect(isClose(trailer, art))
        // Unletterboxed, or no band measured yet: always the art's frame.
        for hero in Self.heroes {
            #expect(isClose(AppleTrailerPreviewLayout.artMatchedFrame(in: hero, art: Self.backdrop, pictureWindow: 0...1),
                            AppleTrailerPreviewLayout.artMatchedFrame(in: hero, art: Self.backdrop)))
        }
    }

    @Test("A tall enough band off the hero's centre moves only as far as it must")
    func offCentreBandShifts() {
        let hero = CGSize(width: 3_440, height: 1_136)
        let art = AppleTrailerPreviewLayout.artMatchedFrame(in: hero, art: Self.backdrop)
        let band: ClosedRange<CGFloat> = 0.24...0.9
        let trailer = AppleTrailerPreviewLayout.artMatchedFrame(in: hero, art: Self.backdrop, pictureWindow: band)
        #expect(abs(trailer.height - art.height) < 0.001 && abs(trailer.minX - art.minX) < 0.001)
        #expect(abs(trailer.minY + trailer.height * band.lowerBound) < 0.001)
    }

    @Test("Over a still that is not 16:9 the trailer covers the still, centred on it",
          arguments: [CGSize(width: 2_000, height: 1_000), CGSize(width: 1_600, height: 1_200),
                      CGSize(width: 1_850, height: 1_000)])
    func coversOtherStills(still: CGSize) {
        for hero in Self.heroes {
            let art = AppleTrailerPreviewLayout.aspectFillFrame(of: still, in: hero)
            let trailer = AppleTrailerPreviewLayout.artMatchedFrame(in: hero, art: still)
            #expect(abs(trailer.width / trailer.height - 16.0 / 9.0) < 0.0001)
            #expect(trailer.minX <= art.minX + 0.001 && trailer.maxX >= art.maxX - 0.001)
            #expect(trailer.minY <= art.minY + 0.001 && trailer.maxY >= art.maxY - 0.001)
            #expect(abs(trailer.midX - art.midX) < 0.001 && abs(trailer.midY - art.midY) < 0.001)
            // Matches the still along one side, so it is no larger than it must be.
            #expect(abs(trailer.width - art.width) < 0.001 || abs(trailer.height - art.height) < 0.001)
        }
    }

    @Test("Before the still has decoded it is drawn as a 16:9 still would be", arguments: heroes)
    func noStillYet(hero: CGSize) {
        let trailer = AppleTrailerPreviewLayout.artMatchedFrame(in: hero, art: nil)
        #expect(isClose(trailer, AppleTrailerPreviewLayout.coverFrame(in: hero)))
        #expect(isClose(trailer, AppleTrailerPreviewLayout.aspectFillFrame(of: Self.backdrop, in: hero)))
    }

    @Test("The visible fraction of a picture through the hero")
    func visibleFraction() {
        let hero = CGRect(x: 0, y: 0, width: 1_440, height: 675)
        #expect(AppleMacHeroCrop.visibleFraction(of: hero, through: hero) == CGRect(x: 0, y: 0, width: 1, height: 1))
        let drawn = CGRect(x: 0, y: -67.5, width: 1_440, height: 810)
        let crop = AppleMacHeroCrop.visibleFraction(of: drawn, through: hero)
        #expect(abs(crop.minY - 67.5 / 810) < 0.0001 && abs(crop.height - 675 / 810) < 0.0001)
        #expect(AppleMacHeroCrop.visibleFraction(of: .zero, through: hero) == .zero)
    }
}

@Suite("Hero art luminance: a centred still")
struct AppleHeroArtLuminanceAnchorTests {
    /// 16:9, dark except its middle third of rows.
    private let map = AppleHeroLuminanceMap(
        columns: 16, rows: 9,
        values: (0 ..< 9).flatMap { row in [Float](repeating: (3 ..< 6).contains(row) ? 0.9 : 0.01, count: 16) },
        aspectRatio: 16.0 / 9.0)

    @Test("Pinned top-leading, a wide hero reads the art's top; centred, its middle")
    func anchorMovesTheReading() throws {
        // A 1600 × 300 hero draws the art 1600 × 900: rows 0–300 pinned at
        // the top, rows 300–600 centred.
        let frame = CGSize(width: 1_600, height: 300)
        let region = CGRect(x: 100, y: 100, width: 400, height: 100)
        let top = try #require(map.reading(region: region, in: frame))
        let centred = try #require(map.reading(region: region, in: frame, anchor: CGPoint(x: 0.5, y: 0.5)))
        #expect(AppleHeroArtTone(reading: top) == .dark)
        #expect(AppleHeroArtTone(reading: centred) == .bright)
    }

    @Test("A still with no overhang reads the same either way")
    func noOverhang() {
        let frame = CGSize(width: 1_600, height: 900)
        let region = CGRect(x: 40, y: 400, width: 480, height: 200)
        #expect(map.reading(region: region, in: frame) == map.reading(region: region, in: frame, anchor: CGPoint(x: 0.5, y: 0.5)))
    }
}
