import CoreGraphics
import Foundation
import Testing
@testable import OpenStreamApple

@Suite("Mac Discover hero")
struct AppleMacHeroLayoutTests {
    @Test("Height is the window less a peek of the first row, as the Apple TV app's",
          arguments: [
              (CGFloat(1440), CGFloat(900), CGFloat(724)),    // a 1440 × 900 window
              (CGFloat(1928), CGFloat(1107), CGFloat(931)),   // the Apple TV app's 930 in this window
              (CGFloat(3440), CGFloat(1440), CGFloat(1264)),  // the owner's display, maximised
              (CGFloat(3440), CGFloat(1312), CGFloat(1136)),  // full-screen sized
              (CGFloat(900), CGFloat(600), CGFloat(424)),     // a small window
              (CGFloat(700), CGFloat(500), CGFloat(360)),     // never shorter than the floor
              (CGFloat(800), CGFloat(1400), CGFloat(600)),    // tall and narrow: 75 % of the width
          ])
    func heightFollowsTheWindow(width: CGFloat, window: CGFloat, expected: CGFloat) {
        let layout = AppleMacHeroLayout(contentWidth: width, windowHeight: window, topInset: 52)
        #expect(layout.height == expected)
    }

    @Test("The first row's header and the top of its cards always show, and the hero grows with the window")
    func firstRowPeeks() {
        for width in stride(from: CGFloat(900), through: 3440, by: 170) {
            var previous: CGFloat = 0
            for window in stride(from: CGFloat(600), through: 1440, by: 60) {
                let layout = AppleMacHeroLayout(contentWidth: width, windowHeight: window)
                #expect(window - layout.height >= AppleMacHeroLayout.firstRowPeek)
                #expect(layout.height <= width * AppleMacHeroLayout.widthFraction)
                #expect(layout.height >= previous)
                previous = layout.height
            }
        }
    }

    @Test("A resize changes the height by what the window changed, with no step")
    func resizeIsContinuous() {
        let width: CGFloat = 3440
        for window in stride(from: CGFloat(900), to: 1440, by: 1) {
            let a = AppleMacHeroLayout(contentWidth: width, windowHeight: window).height
            let b = AppleMacHeroLayout(contentWidth: width, windowHeight: window + 1).height
            #expect(b - a == 1)
        }
    }

    @Test("The copy grows gently with the hero, within its bounds",
          arguments: [
              (CGFloat(1440), CGFloat(900), CGFloat(1), CGFloat(40)),
              (CGFloat(1928), CGFloat(1107), CGFloat(1.143), CGFloat(51)),
              (CGFloat(3440), CGFloat(1440), CGFloat(1.2), CGFloat(70)),
              (CGFloat(3440), CGFloat(1312), CGFloat(1.2), CGFloat(62)),
              (CGFloat(900), CGFloat(600), CGFloat(0.85), CGFloat(32)),
          ])
    func copyScales(width: CGFloat, window: CGFloat, scale: CGFloat, bottom: CGFloat) {
        let layout = AppleMacHeroLayout(contentWidth: width, windowHeight: window)
        #expect(abs(layout.copyScale - scale) < 0.001)
        #expect(layout.copyBottomPadding == bottom)
        // The wordmark stays inside the 480 pt copy column.
        #expect(layout.wordmarkDrawnSize.width <= AppleMacHeroLayout.copyMaxWidth)
    }

    @Test("The iPad's hero and copy are unchanged")
    func padUnchanged() {
        let pad = AppleMacHeroLayout(contentWidth: 1180, windowHeight: 820, platform: .pad)
        #expect(abs(pad.height - 541.2) < 0.01)
        #expect(pad.copyScale == 1)
        #expect(pad.copyBottomPadding == AppleMacHeroLayout.bottomPadding)
        #expect(abs(AppleMacHeroLayout(contentWidth: 1366, windowHeight: 1024, platform: .pad).height - 675.84) < 0.01)
    }

    @Test("Before the window is measured the hero keeps a sensible height")
    func unmeasured() {
        #expect(AppleMacHeroLayout().height == AppleMacHeroLayout.minimumHeight)
    }

    @Test("The copy inset grows from 24 to 48 pt with the width")
    func copyInset() {
        #expect(AppleMacHeroLayout(contentWidth: 800).horizontalPadding == 24)
        #expect(AppleMacHeroLayout(contentWidth: 1250).horizontalPadding == 36)
        #expect(AppleMacHeroLayout(contentWidth: 1600).horizontalPadding == 48)
        #expect(AppleMacHeroLayout(contentWidth: 2400).horizontalPadding == 48)
    }

    @Test("The fallback title is 6 % of the width, between 36 and 72 pt")
    func titleSize() {
        #expect(AppleMacHeroLayout(contentWidth: 500).titleFontSize == 36)
        #expect(AppleMacHeroLayout(contentWidth: 1000).titleFontSize == 60)
        #expect(AppleMacHeroLayout(contentWidth: 1600).titleFontSize == 72)
        // The hero's scales with the copy.
        #expect(AppleMacHeroLayout(contentWidth: 1440, windowHeight: 900).heroTitleFontSize == 72)
        #expect(AppleMacHeroLayout(contentWidth: 3440, windowHeight: 1440).heroTitleFontSize == 86)
    }

    @Test("The synopsis shows only when the hero has room for it")
    func synopsisNeedsRoom() {
        #expect(AppleMacHeroLayout(contentWidth: 1200, windowHeight: 800).showsDescription)
        #expect(!AppleMacHeroLayout(contentWidth: 1200, windowHeight: 600).showsDescription)
    }

    @Test("The art is pulled up under the toolbar and past the stack's top padding")
    func pulledUnderToolbar() {
        #expect(AppleMacHeroLayout(contentWidth: 1200, windowHeight: 800, topInset: 52).topOverlap == 68)
    }

    @Test("Both fades are present: left 58 % to clear at 48 %, bottom from the page's black to clear at 34 %")
    func fades() throws {
        let leading = AppleMacHeroFade.leading
        #expect(try #require(leading.first) == .init(location: 0, opacity: 0.58))
        #expect(try #require(leading.last) == .init(location: 0.48, opacity: 0))
        let bottom = AppleMacHeroFade.bottom
        #expect(try #require(bottom.first) == .init(location: 0, opacity: 1))
        #expect(try #require(bottom.last) == .init(location: 0.34, opacity: 0))
        // Stops run in order, so the gradients draw as specified.
        #expect(leading.map(\.location) == leading.map(\.location).sorted())
        #expect(bottom.map(\.location) == bottom.map(\.location).sorted())
    }

    @Test("Dots: the active page is the wide capsule, every other page a 7 pt dot")
    func dots() {
        #expect(AppleMacHeroPageDots.size(position: 2, index: 2, count: 5) == CGSize(width: 22, height: 7))
        for position in [0, 1, 3, 4] {
            #expect(AppleMacHeroPageDots.size(position: position, index: 2, count: 5) == CGSize(width: 7, height: 7))
        }
        #expect(AppleMacHeroPageDots.size(position: 5, index: 2, count: 5) == .zero)
        #expect(AppleMacHeroPageDots.size(position: 0, index: 0, count: 0) == .zero)
        #expect(AppleMacHeroPageDots.hitSize > AppleMacHeroPageDots.dotSize)
    }

    @Test("A horizontal swipe turns one page per gesture, either way")
    func swipeTurnsOnePage() {
        var swipe = AppleMacHeroSwipe()
        swipe.begin()
        #expect(swipe.scroll(deltaX: -30, deltaY: 2) == nil)
        #expect(swipe.scroll(deltaX: -40, deltaY: 1) == 1)
        // The rest of the same gesture does nothing.
        #expect(swipe.scroll(deltaX: -200, deltaY: 0) == nil)
        swipe.begin()
        #expect(swipe.scroll(deltaX: 70, deltaY: 5) == -1)
    }

    @Test("Vertical scrolling over the hero never turns a page")
    func verticalScrollPassesThrough() {
        var swipe = AppleMacHeroSwipe()
        swipe.begin()
        for _ in 0 ..< 20 {
            #expect(swipe.scroll(deltaX: 10, deltaY: -40) == nil)
        }
    }

    @Test("The Mac trailer may play sound; every other trailer page stays muted")
    func macTrailerAllowsSound() throws {
        let embed = try #require(URL(string: "https://fixture.example/embed/trailer"))
        let mac = AppleYouTubePreviewHTML.document(embedURL: embed, startsPlaying: true, isLandscape: true,
                                                   startsMuted: true, allowsSound: true)
        #expect(mac.contains("var requiresMutedPlayback = false;"))
        #expect(mac.contains("mute=1"))
        let other = AppleYouTubePreviewHTML.document(embedURL: embed, startsPlaying: true, startsMuted: false)
        #expect(other.contains("var requiresMutedPlayback = true;"))
    }

    #if DEBUG && os(macOS)
    @Test("-OpenStreamSnapshotWindow takes an absolute PNG path and waits 12 s by default")
    func snapshotWindowArgument() throws {
        let request = try #require(AppleMacWindowShot.request(
            arguments: ["OpenStream", "-OpenStreamSnapshotWindow", "/tmp/fixture/mac-after.png",
                        "-OpenStreamWindowShotSize", "1600x1000"]))
        #expect(request.destination?.path == "/tmp/fixture/mac-after.png")
        #expect(request.delay == 12)
        #expect(request.size == CGSize(width: 1600, height: 1000))
        #expect(AppleMacWindowShot.request(arguments: ["OpenStream", "-OpenStreamSnapshotWindow", "relative.png"]) == nil)
        #expect(AppleMacWindowShot.request(arguments: ["OpenStream", "-OpenStreamSnapshotWindow", "/tmp/shot.txt"]) == nil)
    }
    #endif
}
