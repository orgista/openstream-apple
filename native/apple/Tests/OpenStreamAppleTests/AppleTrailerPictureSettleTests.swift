import CoreGraphics
import Foundation
import Testing
@testable import OpenStreamApple

/// N46b: the iPhone and iPad hero decides its trailer's crop before the art
/// fades, so the video never grows while it is seen (Project Hail Mary grew
/// 1.30→1.73× 1.1 s after the fade when its band was measured late).
@Suite("iPhone and iPad hero: the trailer's crop is final before the art fades")
struct AppleTrailerPictureSettleTests {
    private let start = Date(timeIntervalSinceReferenceDate: 1_000)
    private let hero = CGSize(width: 402, height: 638)
    private let band: ClosedRange<CGFloat> = 0.125...0.875

    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    @Test("One measurement is not enough: the band must hold for 300 ms")
    func waitsForTheBandToHold() {
        var gate = AppleTrailerPictureSettle()
        #expect(gate.record(band, size: hero, at: at(0)) == .wait)
        #expect(gate.record(band, size: hero, at: at(0.2)) == .wait)
        #expect(gate.record(band, size: hero, at: at(0.31)) == .reveal(window: band, settled: true))
    }

    @Test("A full-frame trailer settles the same way, on the whole raster")
    func fullFrameSettles() {
        var gate = AppleTrailerPictureSettle()
        #expect(gate.record(0...1, size: hero, at: at(0)) == .wait)
        #expect(gate.record(0...1, size: hero, at: at(0.35)) == .reveal(window: 0...1, settled: true))
    }

    @Test("A dark opening frame breaks the run, so a late band is still found before the fade")
    func darkFrameRestartsTheRun() {
        var gate = AppleTrailerPictureSettle()
        #expect(gate.record(nil, size: hero, at: at(0)) == .wait)
        #expect(gate.record(band, size: hero, at: at(0.1)) == .wait)
        #expect(gate.record(nil, size: hero, at: at(0.2)) == .wait)
        #expect(gate.record(band, size: hero, at: at(0.3)) == .wait)
        #expect(gate.record(band, size: hero, at: at(0.6)) == .reveal(window: band, settled: true))
    }

    @Test("A band that changes restarts the run; one snapshot row of jitter does not")
    func changedBandRestarts() {
        var gate = AppleTrailerPictureSettle()
        #expect(gate.record(0...1, size: hero, at: at(0)) == .wait)
        #expect(gate.record(band, size: hero, at: at(0.2)) == .wait)
        #expect(gate.record(0.13...0.87, size: hero, at: at(0.4)) == .wait)
        #expect(gate.record(band, size: hero, at: at(0.51)) == .reveal(window: band, settled: true))
    }

    @Test("A hero that resizes under the art restarts the run")
    func resizedHeroRestarts() {
        var gate = AppleTrailerPictureSettle()
        #expect(gate.record(band, size: hero, at: at(0)) == .wait)
        #expect(gate.record(band, size: CGSize(width: 834, height: 750.6), at: at(0.3)) == .wait)
    }

    @Test("After 3 s it reveals at the last band it measured")
    func timesOutWithTheLastBand() {
        var gate = AppleTrailerPictureSettle()
        #expect(gate.record(band, size: hero, at: at(0)) == .wait)
        #expect(gate.record(nil, size: hero, at: at(0.2)) == .wait)
        #expect(gate.record(nil, size: hero, at: at(3)) == .reveal(window: band, settled: false))
    }

    @Test("An opening still blank at 3 s waits for its band: PHM's title-page trailer (N50)")
    func blankOpeningWaitsForTheBand() {
        var gate = AppleTrailerPictureSettle()
        #expect(gate.record(nil, size: hero, at: at(0)) == .wait)
        #expect(gate.record(nil, size: hero, at: at(3.05)) == .wait)
        #expect(gate.record(band, size: hero, at: at(3.9)) == .wait)
        #expect(gate.record(band, size: hero, at: at(4.25)) == .reveal(window: band, settled: true))
    }

    @Test("Nothing measurable in 8 s reveals the whole raster")
    func timesOutWithNothing() {
        var gate = AppleTrailerPictureSettle()
        #expect(gate.record(nil, size: hero, at: at(0)) == .wait)
        #expect(gate.record(nil, size: hero, at: at(3.05)) == .wait)
        #expect(gate.record(nil, size: hero, at: at(8)) == .reveal(window: nil, settled: false))
    }

    @Test("A band first seen after a blank 3 s that never holds reveals at 8 s, at that band")
    func blankOpeningThenUnstableBand() {
        var gate = AppleTrailerPictureSettle()
        #expect(gate.record(nil, size: hero, at: at(0)) == .wait)
        #expect(gate.record(nil, size: hero, at: at(3.1)) == .wait)
        #expect(gate.record(band, size: hero, at: at(7.9)) == .wait)
        #expect(gate.record(nil, size: hero, at: at(8)) == .reveal(window: band, settled: false))
    }
}

/// The Apple TV hero's server trailer reveals through the same
/// gate, fed from `AppleServerTrailerPlayback.measuredFrameSize` frames. A
/// frame stands in for the fixture clip (`trailer-letterbox-fade.mp4`): black,
/// then a letterboxed picture fading in.
@Suite("Server trailer: measured frames hold the art until a settled picture")
struct AppleServerTrailerMeasuredSettleTests {
    private let start = Date(timeIntervalSinceReferenceDate: 1_000)
    private let hero = CGSize(width: 1_920, height: 1_080)

    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    /// A measured frame: black, with `band` (raster fractions) filled at
    /// `level` (0–255).
    private func frame(band: ClosedRange<CGFloat> = 0...1, level: CGFloat) throws -> CGImage {
        let size = AppleServerTrailerPlayback.measuredFrameSize
        let context = try #require(CGContext(
            data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height))
        let gray = level / 255
        context.setFillColor(CGColor(red: gray, green: gray, blue: gray, alpha: 1))
        let height = CGFloat(size.height)
        context.fill(CGRect(x: 0, y: height * (1 - band.upperBound), width: CGFloat(size.width),
                            height: height * (band.upperBound - band.lowerBound)))
        return try #require(context.makeImage())
    }

    private func measure(_ image: CGImage) -> ClosedRange<CGFloat>? {
        AppleTrailerPreviewLayout.pictureWindow(in: image)
    }

    @Test("Both caps are far under the 60 s preview cap, so a trailer that stays dark still reveals")
    func capsAreShort() {
        #expect(AppleTrailerPictureSettle.timeout < AppleTrailerPictureSettle.blankTimeout)
        #expect(AppleTrailerPictureSettle.blankTimeout <= 8)
    }

    @Test("A black frame measures as nothing and keeps the art up")
    func blackKeepsTheArt() throws {
        let black = try measure(frame(level: 0))
        #expect(black == nil)
        var gate = AppleTrailerPictureSettle()
        for tenth in 0..<79 {
            #expect(gate.record(black, size: hero, at: at(Double(tenth) / 10)) == .wait)
        }
    }

    @Test("A fade from black waits for the picture, then for it to hold")
    func fadeInWaitsForThePicture() throws {
        let letterbox: ClosedRange<CGFloat> = 0.125...0.875
        var gate = AppleTrailerPictureSettle()
        let fade: [(TimeInterval, CGFloat)] = [(0, 0), (0.1, 4), (0.2, 10), (0.3, 64), (0.4, 128), (0.5, 128), (0.65, 128)]
        var verdicts: [AppleTrailerPictureSettle.Verdict] = []
        for (time, level) in fade {
            verdicts.append(gate.record(try measure(frame(band: letterbox, level: level)), size: hero, at: at(time)))
        }
        #expect(verdicts.dropLast() == Array(repeating: .wait, count: fade.count - 1))
        guard case let .reveal(window?, settled) = verdicts.last else {
            Issue.record("the settled picture never revealed: \(verdicts)")
            return
        }
        #expect(settled)
        #expect(abs(window.lowerBound - letterbox.lowerBound) <= AppleTrailerPictureSettle.tolerance)
        #expect(abs(window.upperBound - letterbox.upperBound) <= AppleTrailerPictureSettle.tolerance)
    }

    @Test("A band that grows under the art restarts the run, so the reveal is at its final crop")
    func bandGrowthRestarts() throws {
        let narrow = try #require(measure(frame(band: 0.2...0.8, level: 128)))
        let wide = try #require(measure(frame(band: 0.125...0.875, level: 128)))
        var gate = AppleTrailerPictureSettle()
        #expect(gate.record(narrow, size: hero, at: at(0)) == .wait)
        #expect(gate.record(narrow, size: hero, at: at(0.2)) == .wait)
        #expect(gate.record(wide, size: hero, at: at(0.3)) == .wait)
        #expect(gate.record(wide, size: hero, at: at(0.5)) == .wait)
        #expect(gate.record(wide, size: hero, at: at(0.65)) == .reveal(window: wide, settled: true))
    }

    @Test("A picture that never holds still reveals at the timeout, at the last band measured")
    func timeoutThenReveal() throws {
        let narrow = try #require(measure(frame(band: 0.2...0.8, level: 128)))
        let wide = try #require(measure(frame(band: 0.125...0.875, level: 128)))
        var gate = AppleTrailerPictureSettle()
        var tenth = 0
        var verdict = AppleTrailerPictureSettle.Verdict.wait
        while verdict == .wait, tenth < 100 {
            verdict = gate.record(tenth.isMultiple(of: 2) ? narrow : wide, size: hero, at: at(Double(tenth) / 10))
            if verdict == .wait { tenth += 1 }
        }
        #expect(Double(tenth) / 10 == AppleTrailerPictureSettle.timeout)
        #expect(verdict == .reveal(window: tenth.isMultiple(of: 2) ? narrow : wide, settled: false))
    }
}
