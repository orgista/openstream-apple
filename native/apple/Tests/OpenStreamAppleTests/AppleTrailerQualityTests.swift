import Foundation
import Testing
@testable import OpenStreamApple

/// The Mac hero asks for the best trailer stream it can show pixel for pixel
/// (owner, 2026-09-24: the playing trailer looked muddy next to the Apple TV
/// app's), and a fade that leaves the centre and right of the video alone.
@Suite("Trailer quality and fade")
struct AppleTrailerQualityTests {
    @Test("Highest quality no taller than the frame", arguments: [
        (2_400.0, "hd2160"), (2_160.0, "hd2160"), (1_935.0, "hd1440"), (1_360.0, "hd1080"),
        (1_080.0, "hd1080"), (877.0, "hd720"), (600.0, "large"), (200.0, "medium"),
    ])
    func qualityFitsTheFrame(pixelHeight: Double, expected: String) {
        #expect(AppleTrailerPreviewPolicy.quality(forPixelHeight: pixelHeight) == expected)
    }

    @Test func embedURLCarriesTheChosenQuality() throws {
        let url = try #require(AppleTrailerPreviewPolicy.embedURL(for: "abcdefghijk", quality: "hd1080"))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "vq" }?.value == "hd1080")
    }

    @Test func videoFadeLeavesTheCentreAndRightUntouched() {
        let scrim = AppleHeroScrim.wide(tone: .unknown, videoIsShowing: true, copyTrailing: 0.37)
        #expect(scrim.leading.last?.opacity == 0)
        #expect((scrim.leading.last?.location ?? 1) <= 0.5)
        #expect(scrim.bottom.last?.opacity == 0)
        #expect((scrim.bottom.last?.location ?? 1) <= 0.35)
    }
}
