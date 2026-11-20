import CoreGraphics
import Testing
@testable import OpenStreamApple

/// Seamless handover (2026-10-29): a server trailer draws on its hero
/// still's own pixels — the still aspect-filled and pinned top-leading — so
/// the crossfade between them never reads as a jump.
@Suite("Server trailer: the video keeps the still's geometry")
struct AppleServerTrailerFrameTests {
    /// Apple TV full screen, a shorter tvOS hero, a Vision Pro window and a
    /// tall one.
    private static let heroes: [CGSize] = [
        CGSize(width: 1_920, height: 1_080), CGSize(width: 1_920, height: 900),
        CGSize(width: 1_280, height: 720), CGSize(width: 1_000, height: 1_100),
    ]
    private static let backdrop = CGSize(width: 3_840, height: 2_160)
    private static let video = CGSize(width: 1_920, height: 1_080)

    private func still(_ art: CGSize, in hero: CGSize) -> CGRect {
        CGRect(origin: .zero, size: AppleTrailerPreviewLayout.aspectFillFrame(of: art, in: hero).size)
    }

    private func isClose(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 0.001 && abs(a.minY - b.minY) < 0.001
            && abs(a.width - b.width) < 0.001 && abs(a.height - b.height) < 0.001
    }

    @Test("Over a 16:9 still a 16:9 trailer lands on exactly the still's rect", arguments: heroes)
    func sameRectAsTheStill(hero: CGSize) {
        let frame = AppleServerTrailerFrame.videoFrame(in: hero, art: Self.backdrop, video: Self.video)
        #expect(isClose(frame, still(Self.backdrop, in: hero)))
    }

    @Test("A 4:3 trailer over a 16:9 still fills the still's rect, centred in it")
    func otherShapeFillsTheStill() {
        let hero = CGSize(width: 1_920, height: 900)
        let drawn = still(Self.backdrop, in: hero)
        let frame = AppleServerTrailerFrame.videoFrame(in: hero, art: Self.backdrop, video: CGSize(width: 1_440, height: 1_080))
        #expect(frame.minX <= drawn.minX && frame.maxX >= drawn.maxX)
        #expect(frame.minY <= drawn.minY && frame.maxY >= drawn.maxY)
        #expect(abs(frame.midX - drawn.midX) < 0.001 && abs(frame.midY - drawn.midY) < 0.001)
    }

    @Test("A letterboxed trailer's band covers the hero: no black bars")
    func letterboxBandCoversTheHero() {
        let hero = CGSize(width: 1_920, height: 1_080)
        let band: ClosedRange<CGFloat> = 0.12...0.88
        let frame = AppleServerTrailerFrame.videoFrame(in: hero, art: Self.backdrop, video: Self.video, pictureWindow: band)
        #expect(frame.minY + frame.height * band.lowerBound <= 0.001)
        #expect(frame.minY + frame.height * band.upperBound >= hero.height - 0.001)
        #expect(frame.minX <= 0.001 && frame.maxX >= hero.width - 0.001)
    }

    @Test("No still yet, or no video size yet: the hero's own frame, aspect-filled")
    func fallbacks() {
        let hero = CGSize(width: 1_920, height: 900)
        let noArt = AppleServerTrailerFrame.videoFrame(in: hero, art: nil, video: Self.video)
        #expect(isClose(noArt, AppleTrailerPreviewLayout.aspectFillFrame(of: Self.video, in: hero)))
        let noVideo = AppleServerTrailerFrame.videoFrame(in: hero, art: Self.backdrop, video: .zero)
        #expect(isClose(noVideo, CGRect(origin: .zero, size: hero)))
    }
}
