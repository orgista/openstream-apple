import CoreGraphics
import SwiftUI
import Testing
@testable import OpenStreamApple

/// The Vision Pro player takes over the app's window, keeps its width, takes
/// the film's shape, and gives the window back at the size it had.
struct AppleVisionPlayerWindowPolicyTests {
    @Test func sixteenByNineKeepsTheWidth() {
        let size = AppleVisionPlayerWindowPolicy.playerSize(current: CGSize(width: 1100, height: 760), aspect: 16.0 / 9.0)
        #expect(size == CGSize(width: 1100, height: 619))
    }

    @Test func scopeKeepsTheWidthAndFillsEdgeToEdge() {
        let size = AppleVisionPlayerWindowPolicy.playerSize(current: CGSize(width: 1400, height: 900), aspect: 2.39)
        #expect(size.width == 1400)
        #expect(size.height == (1400 / 2.39).rounded())
    }

    @Test func noAspectMeansSixteenByNine() {
        let size = AppleVisionPlayerWindowPolicy.playerSize(current: CGSize(width: 1280, height: 800), aspect: nil)
        #expect(size == CGSize(width: 1280, height: 720))
        #expect(AppleVisionPlayerWindowPolicy.aspect(of: nil) == AppleVisionPlayerWindowPolicy.defaultAspect)
        #expect(AppleVisionPlayerWindowPolicy.aspect(of: CGSize(width: 0, height: 0)) == AppleVisionPlayerWindowPolicy.defaultAspect)
        #expect(AppleVisionPlayerWindowPolicy.aspect(of: CGSize(width: 1920, height: 800)) == 2.4)
    }

    @Test func aNarrowWindowIsWidenedToTheFloor() {
        let size = AppleVisionPlayerWindowPolicy.playerSize(current: CGSize(width: 500, height: 500), aspect: 16.0 / 9.0)
        #expect(size == CGSize(width: 640, height: 360))
        #expect(AppleVisionPlayerWindowPolicy.floor(forAspect: 16.0 / 9.0) == CGSize(width: 640, height: 360))
    }

    @Test func extremeShapesAreClamped() {
        // A vertical clip letterboxes in a square window; nothing wider than
        // Ultra Panavision.
        let tall = AppleVisionPlayerWindowPolicy.playerSize(current: CGSize(width: 1100, height: 760), aspect: 9.0 / 16.0)
        #expect(tall == CGSize(width: 1100, height: 1100))
        let wide = AppleVisionPlayerWindowPolicy.floor(forAspect: 10)
        #expect(wide == CGSize(width: 640, height: (640 / 2.76).rounded()))
        #expect(AppleVisionPlayerWindowPolicy.playerContentMinimum == wide)
        #expect(AppleVisionPlayerWindowPolicy.playerContentMinimum.height < 360)
    }

    @Test func anUnknownWindowStartsFromTheOpeningWidth() {
        let size = AppleVisionPlayerWindowPolicy.playerSize(current: nil, aspect: 16.0 / 9.0)
        #expect(size.width == AppleVisionPlayerWindowPolicy.defaultWindowSize.width)
    }

    @Test func closingRestoresTheSavedSize() {
        let saved = CGSize(width: 1320, height: 900)
        #expect(AppleVisionPlayerWindowPolicy.restoredSize(saved: saved) == saved)
    }

    @Test(arguments: [nil, CGSize.zero, CGSize(width: 0, height: 700), CGSize(width: CGFloat.nan, height: 700)])
    func anUnknownSavedSizeRestoresTheOpeningSize(_ saved: CGSize?) {
        #expect(AppleVisionPlayerWindowPolicy.restoredSize(saved: saved) == AppleVisionPlayerWindowPolicy.defaultWindowSize)
    }

    /// The browse window never gets small enough to leave the iPad's
    /// landscape Live stage, player and channel list side by side.
    @Test func theBrowseWindowKeepsTheIPadLiveStage() {
        for size in [AppleVisionPlayerWindowPolicy.defaultWindowSize, AppleVisionPlayerWindowPolicy.browseMinimum] {
            #expect(AppleLiveStagePolicy.sideBySide(isRegularWidth: true, size: size))
        }
    }

    /// Owner report: audio played on after the window closed.
    @Test func leavingTheForegroundStopsThePlayer() {
        #expect(AppleVisionPlayerWindowPolicy.stopsPlayback(on: .background))
        #expect(AppleVisionPlayerWindowPolicy.stopsPlayback(on: .inactive) == false)
        #expect(AppleVisionPlayerWindowPolicy.stopsPlayback(on: .active) == false)
    }
}
