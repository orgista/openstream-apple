import CoreGraphics
import Testing
@testable import OpenStreamApple

/// Edge cases for AppleMacHeroCrop.visibleFraction — the pure geometry
/// that computes what fraction of a picture is visible through a viewport.
@Suite("Mac hero crop: visible fraction edge cases")
struct AppleMacHeroCropEdgeTests {
    private func closeEnough(_ a: CGRect, _ b: CGRect, within tolerance: CGFloat = 0.0001) {
        #expect(abs(a.minX - b.minX) < tolerance)
        #expect(abs(a.minY - b.minY) < tolerance)
        #expect(abs(a.width - b.width) < tolerance)
        #expect(abs(a.height - b.height) < tolerance)
    }

    /// Viewport sits entirely inside the drawn picture rect.
    @Test("Viewport fully inside the drawn rect")
    func viewportFullyInsideDrawn() {
        let drawn = CGRect(x: 0, y: 0, width: 2_000, height: 1_200)
        let viewport = CGRect(x: 500, y: 300, width: 1_000, height: 600)
        let fraction = AppleMacHeroCrop.visibleFraction(of: drawn, through: viewport)
        // 500/2000 = 0.25, 300/1200 = 0.25, 1000/2000 = 0.5, 600/1200 = 0.5
        closeEnough(fraction, CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
    }

    /// The drawn rect is smaller than the viewport, fully contained within it.
    @Test("Drawn rect fully inside the viewport")
    func drawnFullyInsideViewport() {
        let drawn = CGRect(x: 200, y: 100, width: 800, height: 600)
        let viewport = CGRect(x: 0, y: 0, width: 1_600, height: 1_200)
        let fraction = AppleMacHeroCrop.visibleFraction(of: drawn, through: viewport)
        // (0 - 200)/800 = -0.25, (0 - 100)/600 = -0.1667, 1600/800 = 2.0, 1200/600 = 2.0
        closeEnough(fraction, CGRect(x: -0.25, y: -100.0 / 600.0,
                                     width: 2.0, height: 2.0))
    }

    /// Viewport and drawn rect share no overlap at all.
    @Test("No overlap between viewport and drawn rect")
    func noOverlap() {
        let drawn = CGRect(x: 0, y: 0, width: 500, height: 500)
        let viewport = CGRect(x: 1_000, y: 1_000, width: 500, height: 500)
        let fraction = AppleMacHeroCrop.visibleFraction(of: drawn, through: viewport)
        // (1000 - 0)/500 = 2.0, (1000 - 0)/500 = 2.0, 500/500 = 1.0, 500/500 = 1.0
        closeEnough(fraction, CGRect(x: 2.0, y: 2.0, width: 1.0, height: 1.0))
    }

    /// Zero-size viewport produces zero-area fraction.
    @Test("Zero-size viewport yields zero-area fraction")
    func zeroSizeViewport() {
        let drawn = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
        let viewport = CGRect.zero
        let fraction = AppleMacHeroCrop.visibleFraction(of: drawn, through: viewport)
        closeEnough(fraction, CGRect(x: 0, y: 0, width: 0, height: 0))
    }

    /// Art drawn centred with negative coordinates (larger art, smaller window).
    @Test("Drawn rect offset negatively: centred art larger than window")
    func drawnRectNegativelyOffset() {
        // A 1920x1080 picture drawn into a 1000x500 viewport centred at origin
        // gives drawn rect: x = -460, y = -290, width = 1920, height = 1080
        let drawn = CGRect(x: -460, y: -290, width: 1_920, height: 1_080)
        let viewport = CGRect(x: 0, y: 0, width: 1_000, height: 500)
        let fraction = AppleMacHeroCrop.visibleFraction(of: drawn, through: viewport)
        // (0 - (-460))/1920 = 460/1920, (0 - (-290))/1080 = 290/1080
        let expectedX: CGFloat = 460.0 / 1_920.0
        let expectedY: CGFloat = 290.0 / 1_080.0
        let expectedW: CGFloat = 1_000.0 / 1_920.0
        let expectedH: CGFloat = 500.0 / 1_080.0
        closeEnough(fraction, CGRect(x: expectedX, y: expectedY,
                                     width: expectedW, height: expectedH))
    }

    /// Ultrawide 3440x1440 window viewing standard 16:9 art (1920x1080).
    @Test("Ultrawide 3440x1440 window over 16:9 art")
    func ultrawideWindowOverStandardArt() {
        let drawn = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
        let viewport = CGRect(x: 0, y: 0, width: 3_440, height: 1_440)
        let fraction = AppleMacHeroCrop.visibleFraction(of: drawn, through: viewport)
        // x = 0, y = 0, width = 3440/1920, height = 1440/1080
        let expectedW: CGFloat = 3_440.0 / 1_920.0
        let expectedH: CGFloat = 1_440.0 / 1_080.0
        closeEnough(fraction, CGRect(x: 0, y: 0, width: expectedW, height: expectedH))
    }

    /// Drawn rect has zero width but non-zero height — still returns .zero.
    @Test("Zero-width drawn rect returns .zero")
    func zeroWidthDrawn() {
        let drawn = CGRect(x: 0, y: 0, width: 0, height: 1_080)
        let viewport = CGRect(x: 0, y: 0, width: 1_440, height: 675)
        #expect(AppleMacHeroCrop.visibleFraction(of: drawn, through: viewport) == .zero)
    }

    /// Drawn rect has zero height but non-zero width — still returns .zero.
    @Test("Zero-height drawn rect returns .zero")
    func zeroHeightDrawn() {
        let drawn = CGRect(x: 0, y: 0, width: 1_920, height: 0)
        let viewport = CGRect(x: 0, y: 0, width: 1_440, height: 675)
        #expect(AppleMacHeroCrop.visibleFraction(of: drawn, through: viewport) == .zero)
    }
}
