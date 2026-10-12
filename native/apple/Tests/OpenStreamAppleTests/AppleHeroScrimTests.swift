import CoreGraphics
import Foundation
import Testing
@testable import OpenStreamApple

/// A solid or split test image: `left` fills the left half, `right` the right
/// half, as sRGB grey levels 0…255.
private func testImage(width: Int = 320, height: Int = 180, left: UInt8, right: UInt8) throws -> CGImage {
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                         bytesPerRow: width * 4, space: space,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(srgbRed: CGFloat(left) / 255, green: CGFloat(left) / 255, blue: CGFloat(left) / 255, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
    context.setFillColor(CGColor(srgbRed: CGFloat(right) / 255, green: CGFloat(right) / 255, blue: CGFloat(right) / 255, alpha: 1))
    context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
    return try #require(context.makeImage())
}

@Suite("Hero art luminance")
struct AppleHeroArtLuminanceTests {
    @Test("Near-white art under the copy is bright, near-black is dark, unmeasured is unknown")
    func toneFromReading() throws {
        let white = try #require(AppleHeroLuminanceMap(image: testImage(left: 245, right: 245)))
        let black = try #require(AppleHeroLuminanceMap(image: testImage(left: 12, right: 12)))
        let frame = CGSize(width: 1600, height: 900)
        let region = CGRect(x: 40, y: 500, width: 480, height: 220)
        #expect(AppleHeroArtTone(reading: white.reading(region: region, in: frame)) == .bright)
        #expect(AppleHeroArtTone(reading: black.reading(region: region, in: frame)) == .dark)
        #expect(AppleHeroArtTone(reading: nil) == .unknown)
    }

    @Test("The thresholds: a mid-grey patch is dark; a light one, or a bright tenth, is bright")
    func thresholds() {
        #expect(AppleHeroArtTone(reading: .init(mean: 0.2, upper: 0.3)) == .dark)
        #expect(AppleHeroArtTone(reading: .init(mean: 0.3, upper: 0.35)) == .bright)
        #expect(AppleHeroArtTone(reading: .init(mean: 0.12, upper: 0.6)) == .bright)
        #expect(!AppleHeroArtTone.unknown.isBright)
    }

    @Test("Relative luminance is WCAG's: black 0, white 1, sRGB mid-grey about 0.21")
    func relativeLuminance() {
        #expect(AppleHeroLuminanceMap.relativeLuminance(red: 0, green: 0, blue: 0) == 0)
        #expect(abs(AppleHeroLuminanceMap.relativeLuminance(red: 255, green: 255, blue: 255) - 1) < 0.001)
        #expect(abs(AppleHeroLuminanceMap.relativeLuminance(red: 128, green: 128, blue: 128) - 0.216) < 0.01)
    }

    @Test("Only the patch under the copy counts: dark left half, white right half")
    func regionIsWhereTheCopyIs() throws {
        let map = try #require(AppleHeroLuminanceMap(image: testImage(left: 10, right: 250)))
        let frame = CGSize(width: 1600, height: 900)
        let left = try #require(map.reading(region: CGRect(x: 40, y: 400, width: 600, height: 400), in: frame))
        let right = try #require(map.reading(region: CGRect(x: 960, y: 400, width: 600, height: 400), in: frame))
        #expect(AppleHeroArtTone(reading: left) == .dark)
        #expect(AppleHeroArtTone(reading: right) == .bright)
    }

    @Test("The art is drawn filled from the top-leading corner: a tall frame shows only its left part")
    func aspectFillCropsTheTrailingSide() throws {
        // 16:9 art in a portrait frame shows its left 32 %, all of it the
        // dark half, so even the frame's right edge reads dark.
        let map = try #require(AppleHeroLuminanceMap(image: testImage(left: 10, right: 250)))
        let frame = CGSize(width: 402, height: 700)
        let reading = try #require(map.reading(region: CGRect(x: 300, y: 300, width: 102, height: 200), in: frame))
        #expect(AppleHeroArtTone(reading: reading) == .dark)
    }

    @Test("An empty frame or a region outside it reads nothing")
    func emptyRegions() throws {
        let map = try #require(AppleHeroLuminanceMap(image: testImage(left: 250, right: 250)))
        #expect(map.reading(region: CGRect(x: 0, y: 0, width: 10, height: 10), in: .zero) == nil)
        #expect(map.reading(region: CGRect(x: 2000, y: 0, width: 10, height: 10), in: CGSize(width: 100, height: 100)) == nil)
    }

    @Test("The grid keeps the art's proportions")
    func gridShape() throws {
        let map = try #require(AppleHeroLuminanceMap(image: testImage(width: 1920, height: 1080, left: 0, right: 0)))
        #expect(map.columns == AppleHeroLuminanceMap.gridColumns)
        #expect(map.rows == 27)
        #expect(map.values.count == map.columns * map.rows)
        #expect(abs(map.aspectRatio - 16.0 / 9.0) < 0.001)
    }
}

@Suite("Hero luminance cache")
struct AppleHeroLuminanceCacheTests {
    @Test("Each URL is measured once: a second image for the same URL gets the first map")
    func measuredOncePerURL() async throws {
        let cache = AppleHeroLuminanceCache()
        let url = try #require(URL(string: "https://fixture.example/backdrop-a.jpg"))
        #expect(cache.cached(for: url) == nil)
        let first = try #require(await cache.map(for: url, image: testImage(left: 250, right: 250)))
        let second = try #require(await cache.map(for: url, image: testImage(left: 5, right: 5)))
        #expect(first == second)
        #expect(cache.cached(for: url) == first)
    }

    @Test("Different URLs are measured separately")
    func perURL() async throws {
        let cache = AppleHeroLuminanceCache()
        let bright = try #require(URL(string: "https://fixture.example/bright.jpg"))
        let dark = try #require(URL(string: "https://fixture.example/dark.jpg"))
        let brightMap = try #require(await cache.map(for: bright, image: testImage(left: 250, right: 250)))
        let darkMap = try #require(await cache.map(for: dark, image: testImage(left: 5, right: 5)))
        #expect(brightMap != darkMap)
        #expect(cache.cached(for: bright) == brightMap)
        #expect(cache.cached(for: dark) == darkMap)
        #expect(cache.cached(for: nil) == nil)
    }

    @Test("The oldest URL leaves once the cache is full")
    func bounded() async throws {
        let cache = AppleHeroLuminanceCache(capacity: 2)
        let urls = try (0 ..< 3).map { try #require(URL(string: "https://fixture.example/\($0).jpg")) }
        for url in urls { _ = await cache.map(for: url, image: try testImage(left: 100, right: 100)) }
        #expect(cache.cached(for: urls[0]) == nil)
        #expect(cache.cached(for: urls[1]) != nil)
        #expect(cache.cached(for: urls[2]) != nil)
    }

    @Test("A measurement answers only for its own URL")
    func measurementIsPerURL() throws {
        let map = try #require(AppleHeroLuminanceMap(image: testImage(left: 250, right: 250)))
        let own = try #require(URL(string: "https://fixture.example/own.jpg"))
        let next = try #require(URL(string: "https://fixture.example/never-measured.jpg"))
        let measurement = AppleHeroArtMeasurement(url: own, map: map)
        #expect(AppleHeroArtMeasurement.map(measurement, for: own) == map)
        #expect(AppleHeroArtMeasurement.map(measurement, for: next) == nil)
        #expect(AppleHeroArtMeasurement.map(measurement, for: nil) == nil)
    }
}

@Suite("Hero scrim policy")
struct AppleHeroScrimTests {
    private let samples = stride(from: CGFloat(0), through: 1, by: 0.05).map { $0 }

    /// The bright scrim is at least as dark as the standard one everywhere.
    private func covers(_ bright: [AppleHeroScrim.Stop], _ standard: [AppleHeroScrim.Stop]) -> Bool {
        samples.allSatisfy {
            AppleHeroScrim.opacity(of: bright, at: $0) + 0.0001 >= AppleHeroScrim.opacity(of: standard, at: $0)
        }
    }

    @Test("Dark and unmeasured art keep the standard fades; the wide hero's copy has its light shadow",
          arguments: [AppleHeroArtTone.dark, .unknown])
    func darkIsUnchanged(tone: AppleHeroArtTone) {
        let wide = AppleHeroScrim.wide(tone: tone, videoIsShowing: false, copyTrailing: 0.4)
        #expect(wide.leading == AppleMacHeroFade.leading)
        #expect(wide.bottom == AppleMacHeroFade.bottom)
        #expect(wide.copyShadow == AppleHeroScrim.wideCopyShadow)
        #expect(AppleHeroScrim.phone(tone: tone) == AppleHeroScrim(bottom: AppleHeroScrim.phoneBottom))
        #expect(AppleHeroScrim.tv(tone: tone, copyTrailing: 0.4) == AppleHeroScrim(bottom: AppleHeroScrim.tvBottom))
        #expect(AppleHeroScrim.featured(tone: tone, copyTrailing: 0.4)
            == AppleHeroScrim(bottom: AppleHeroScrim.featuredBottom))
    }

    @Test("The iPhone's standard fade is the approved one: clear to 32 %, 55 % at 62 %, black from 86 % (top down)")
    func phoneFadeMatchesTheApprovedOne() {
        let bottom = AppleHeroScrim.phoneBottom
        #expect(AppleHeroScrim.opacity(of: bottom, at: 1 - 0.32) < 0.0001)
        #expect(abs(AppleHeroScrim.opacity(of: bottom, at: 1 - 0.62) - 0.55) < 0.0001)
        #expect(AppleHeroScrim.opacity(of: bottom, at: 1 - 0.86) == 1)
        #expect(AppleHeroScrim.opacity(of: bottom, at: 0) == 1)
    }

    @Test("Bright art: a leading fade sized to the copy, a deeper bottom one and a shadow on every hero")
    func brightStrengthens() {
        let wide = AppleHeroScrim.wide(tone: .bright, videoIsShowing: false, copyTrailing: 0.37)
        #expect(covers(wide.leading, AppleMacHeroFade.leading))
        #expect(covers(wide.bottom, AppleMacHeroFade.bottom))
        #expect(wide.copyShadow == AppleHeroScrim.brightCopyShadow)

        let phone = AppleHeroScrim.phone(tone: .bright)
        #expect(covers(phone.bottom, AppleHeroScrim.phoneBottom))
        #expect(phone.copyShadow != nil)

        let tv = AppleHeroScrim.tv(tone: .bright, copyTrailing: 0.4)
        #expect(!tv.leading.isEmpty)
        #expect(covers(tv.bottom, AppleHeroScrim.tvBottom))
        #expect(tv.copyShadow != nil)

        let featured = AppleHeroScrim.featured(tone: .bright, copyTrailing: 0.5)
        #expect(!featured.leading.isEmpty)
        #expect(covers(featured.bottom, AppleHeroScrim.featuredBottom))
        #expect(featured.copyShadow != nil)
    }

    @Test("The leading fade holds across the copy column and clears after it",
          arguments: [CGFloat(0.2), 0.37, 0.5, 0.7])
    func leadingFadeFollowsTheCopy(copyTrailing: CGFloat) throws {
        for scrim in [AppleHeroScrim.tv(tone: .bright, copyTrailing: copyTrailing),
                      .featured(tone: .bright, copyTrailing: copyTrailing),
                      .wide(tone: .bright, videoIsShowing: false, copyTrailing: copyTrailing)] {
            #expect(AppleHeroScrim.opacity(of: scrim.leading, at: copyTrailing) >= 0.55)
            let clear = try #require(scrim.leading.last)
            #expect(clear.opacity == 0)
            #expect(clear.location > copyTrailing)
            #expect(scrim.leading.map(\.location) == scrim.leading.map(\.location).sorted())
        }
    }

    @Test("While a Mac trailer plays the standard fade stays, whatever the still was (N27, N30)",
          arguments: [AppleHeroArtTone.bright, .dark, .unknown])
    func videoKeepsTheStandardFade(tone: AppleHeroArtTone) {
        let scrim = AppleHeroScrim.wide(tone: tone, videoIsShowing: true, copyTrailing: 0.37)
        #expect(scrim == AppleHeroScrim.wide(tone: .unknown, videoIsShowing: false, copyTrailing: 0.37))
    }

    @Test("Every scrim's stops run in order")
    func stopsInOrder() {
        let scrims: [AppleHeroScrim] = [AppleHeroArtTone.bright, .dark].flatMap { tone in
            [.wide(tone: tone, videoIsShowing: false, copyTrailing: 0.4), .phone(tone: tone),
             .tv(tone: tone, copyTrailing: 0.45), .featured(tone: tone, copyTrailing: 0.6)]
        }
        for scrim in scrims {
            #expect(scrim.bottom.map(\.location) == scrim.bottom.map(\.location).sorted())
            #expect(scrim.leading.map(\.location) == scrim.leading.map(\.location).sorted())
        }
    }

    @Test("Opacity between stops is linear and flat past the ends")
    func interpolation() {
        let stops: [AppleHeroScrim.Stop] = [.init(location: 0.2, opacity: 1), .init(location: 0.6, opacity: 0)]
        #expect(AppleHeroScrim.opacity(of: stops, at: 0) == 1)
        #expect(abs(AppleHeroScrim.opacity(of: stops, at: 0.4) - 0.5) < 0.0001)
        #expect(AppleHeroScrim.opacity(of: stops, at: 0.9) == 0)
        #expect(AppleHeroScrim.opacity(of: [], at: 0.5) == 0)
    }
}

@Suite("Hero copy regions")
struct AppleHeroCopyRegionTests {
    @Test("The wide hero's region is the copy column, bottom-left, above the buttons")
    func wide() {
        let layout = AppleMacHeroLayout(contentWidth: 1440, windowHeight: 900, topInset: 52)
        let region = AppleHeroCopyRegion.wide(layout)
        #expect(region.minX == layout.horizontalPadding)
        #expect(region.width == AppleMacHeroLayout.copyMaxWidth)
        #expect(region.maxY < layout.height - layout.copyBottomPadding)
        #expect(region.minY > layout.height / 3)
        let fraction = AppleHeroCopyRegion.trailingFraction(region, in: CGSize(width: 1440, height: layout.height))
        #expect(abs(fraction - (layout.horizontalPadding + 480) / 1440) < 0.0001)
    }

    @Test("A narrow iPad in Split View keeps the column inside the hero")
    func narrowWide() {
        let layout = AppleMacHeroLayout(contentWidth: 400, windowHeight: 900, platform: .pad)
        let region = AppleHeroCopyRegion.wide(layout)
        #expect(region.maxX <= 400 - layout.horizontalPadding + 0.001)
    }

    @Test("The iPhone's region is centred over the art, above the buttons")
    func phone() {
        let region = AppleHeroCopyRegion.phone(width: 402, artHeight: 640)
        #expect(abs(region.midX - 201) < 0.001)
        #expect(region.maxY < 640 - AppleHomePhoneHeroLayout.copyBottomInset)
    }

    @Test("The Apple TV's region sits in the copy column above the pills")
    func tv() {
        let region = AppleHeroCopyRegion.tv
        #expect(region.minX == AppleTVBillboardMetrics.copyLeadingInset)
        #expect(region.maxY < AppleTVBillboardMetrics.copyBottom)
        #expect(region.maxX < AppleTVBillboardMetrics.screenSize.width / 2)
    }
}

@Suite("iPad full-bleed hero")
@MainActor
struct AppleIPadHeroLayoutTests {
    @Test("Height is min(900, 90 % of the width, 66 % of the screen), in portrait and landscape",
          arguments: [
              (CGFloat(1024), CGFloat(1366), CGFloat(900)),     // 13" portrait: the ceiling
              (CGFloat(1366), CGFloat(1024), CGFloat(675.84)),  // 13" landscape: 66 % of the screen
              (CGFloat(834), CGFloat(1194), CGFloat(750.6)),    // 11" portrait: 90 % of the width
              (CGFloat(1194), CGFloat(834), CGFloat(550.44)),   // 11" landscape
              (CGFloat(375), CGFloat(500), CGFloat(420)),       // Slide Over: never under the floor
          ])
    func height(width: CGFloat, screen: CGFloat, expected: CGFloat) {
        let layout = AppleMacHeroLayout(contentWidth: width, windowHeight: screen, topInset: 74, platform: .pad)
        #expect(abs(layout.height - expected) < 0.01)
    }

    @Test("It never takes more than two thirds of the screen, so the first row still shows")
    func leavesTheFirstRow() {
        for width in stride(from: CGFloat(700), through: 1400, by: 50) {
            for screen in stride(from: CGFloat(700), through: 1400, by: 50) {
                let pad = AppleMacHeroLayout(contentWidth: width, windowHeight: screen, platform: .pad)
                #expect(pad.height <= max(screen * AppleMacHeroLayout.padScreenFraction, AppleMacHeroLayout.padMinimumHeight) + 0.001)
                #expect(pad.height <= AppleMacHeroLayout.padMaximumHeight)
            }
        }
    }

    @Test("The art runs under the status bar, navigation bar and tab bar to the top edge")
    func underTheBars() {
        let layout = AppleMacHeroLayout(contentWidth: 1024, windowHeight: 1366, topInset: 74, platform: .pad)
        #expect(layout.topOverlap == 74 + AppleMacHeroLayout.stackTopPadding)
    }

    @Test("Before the screen is measured it keeps a sensible height, and the Mac keeps its own rule")
    func unmeasured() {
        #expect(AppleMacHeroLayout(platform: .pad).height == AppleMacHeroLayout.padMinimumHeight)
        #expect(AppleMacHeroLayout().platform == .mac)
        // The window less the first row's peek.
        #expect(AppleMacHeroLayout(contentWidth: 1200, windowHeight: 800).height == 800 - AppleMacHeroLayout.firstRowPeek)
    }

    @Test("The page dots sit centred under the copy's bottom inset")
    func dots() {
        #expect(AppleMacHeroLayout.padDotsCentreInset < AppleMacHeroLayout.bottomPadding)
        #expect(AppleMacHeroLayout.padDotsCentreInset - AppleHomePhoneHeroPageIndicator.height / 2 >= 0)
    }
}
