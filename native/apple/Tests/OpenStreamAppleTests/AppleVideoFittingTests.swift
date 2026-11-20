import CoreGraphics
import Foundation
import Testing
@testable import OpenStreamApple

/// Where a subtitle belongs. The overlay pinned cues to the bottom of the
/// screen, which is the bottom of the picture on Apple TV and 450 pt below it
/// on a phone in portrait (2026-09-16).
@Suite("Video fitting")
struct AppleVideoFittingTests {
    private let phonePortrait = CGSize(width: 393, height: 852)
    private let tv = CGSize(width: 1920, height: 1080)

    @Test func aFullBleedVideoNeedsNoExtraInset() {
        // Apple TV: 16:9 in a 16:9 container fills it, so nothing changes and
        // the caption keeps the inset it always had.
        #expect(AppleVideoFitting.captionBottomInset(
            container: tv, videoSize: CGSize(width: 1920, height: 1080)) == 0)
    }

    /// The case that was broken: the picture occupies a band and the caption
    /// must come up to meet it.
    @Test func aLetterboxedPortraitVideoLiftsTheCaption() {
        let inset = AppleVideoFitting.captionBottomInset(
            container: phonePortrait, videoSize: CGSize(width: 1920, height: 1080))
        // 393 wide at 16:9 is ~221 tall, centred in 852 → ~315 of black below.
        #expect(inset > 300)
        #expect(inset < 330)
    }

    @Test func theFittedRectIsCentred() {
        let rect = AppleVideoFitting.fittedRect(
            container: phonePortrait, videoSize: CGSize(width: 1920, height: 1080))
        #expect(rect.width == phonePortrait.width)
        #expect(abs(rect.midY - phonePortrait.height / 2) < 0.5)
    }

    /// A route that cannot report its dimensions still gets a sane answer
    /// rather than falling back to the screen bottom.
    @Test func anUnknownSizeAssumesSixteenByNine() {
        let guessed = AppleVideoFitting.captionBottomInset(container: phonePortrait, videoSize: nil)
        let known = AppleVideoFitting.captionBottomInset(
            container: phonePortrait, videoSize: CGSize(width: 1920, height: 1080))
        #expect(abs(guessed - known) < 0.5)
    }

    /// Guessing narrower than the truth puts the caption slightly *inside* a
    /// wide film, which is what every player does. Guessing wider would push it
    /// back into the letterbox — the fault being fixed.
    @Test func aWidescreenFilmPutsTheCaptionInsideThePicture() {
        let scope = CGSize(width: 2390, height: 1000) // 2.39:1
        let actual = AppleVideoFitting.captionBottomInset(container: phonePortrait, videoSize: scope)
        let assumed = AppleVideoFitting.captionBottomInset(container: phonePortrait, videoSize: nil)
        #expect(actual > assumed)
    }

    /// A video *narrower* than the container is pillarboxed: it fills the
    /// height, there is no black below it, and the caption stays where it was.
    ///
    /// 9:16 does not qualify — a 393x852 phone is proportionally taller still
    /// (0.461 against 0.5625), so even a portrait video letterboxes a little.
    /// That caught a wrong expectation in this test rather than a wrong rule.
    @Test func aVideoNarrowerThanTheContainerFillsTheHeight() {
        let inset = AppleVideoFitting.captionBottomInset(
            container: phonePortrait, videoSize: CGSize(width: 400, height: 1000))
        #expect(inset == 0)
    }

    @Test func aPortraitVideoStillLetterboxesSlightlyOnATallerPhone() {
        let inset = AppleVideoFitting.captionBottomInset(
            container: phonePortrait, videoSize: CGSize(width: 1080, height: 1920))
        #expect(inset > 70 && inset < 85)
    }

    @Test func degenerateInputsAreSafe() {
        #expect(AppleVideoFitting.fittedRect(container: .zero, videoSize: nil) == .zero)
        #expect(AppleVideoFitting.captionBottomInset(container: .zero, videoSize: nil) == 0)
        #expect(AppleVideoFitting.aspectRatio(of: CGSize(width: 0, height: 100)) == nil)
    }
}
