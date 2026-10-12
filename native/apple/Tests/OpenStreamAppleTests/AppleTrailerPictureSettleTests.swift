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
