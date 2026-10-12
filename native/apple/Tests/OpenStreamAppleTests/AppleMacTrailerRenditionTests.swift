import CoreGraphics
import Foundation
import Testing
@testable import OpenStreamApple

/// N31: YouTube picks its stream from the player's own size, so the Mac hero
/// lays its player out twice as large and scales it back down, drawing in the
/// same place and size, to get a sharper stream on a 1x display.
@Suite("Mac hero: sharper trailer stream")
struct AppleMacTrailerRenditionTests {
    private let embed = URL(string: "https://fixture.example/embed/trailer")!
    private let scaledRule = "iframe{width:200%;height:200%;transform:scale(0.5);transform-origin:0 0}"

    @Test("A 1x display doubles the player; a Retina display is already doubled",
          arguments: [(1.0, 2), (1.5, 2), (2.0, 1), (3.0, 1)])
    func layoutScaleFollowsTheDisplay(displayScale: Double, expected: Int) {
        #expect(AppleTrailerPreviewPolicy.macLayoutScale(displayScale: displayScale) == expected)
    }

    @Test("The Mac page lays the player out at twice its size and scales it back from the top left")
    func macPageScalesThePlayer() {
        let mac = AppleYouTubePreviewHTML.document(embedURL: embed, startsPlaying: true, isLandscape: true,
                                                   startsMuted: true, allowsSound: true, layoutScale: 2)
        #expect(mac.contains(scaledRule))
        // The player is told the doubled size too, so YouTube sizes its stream for it.
        #expect(mac.contains("var layoutScale = 2;"))
        #expect(mac.contains("Math.round(window.innerWidth * layoutScale)"))
        // Captions and annotations stay off.
        #expect(mac.contains("iv_load_policy: 3"))
        #expect(mac.contains("player.setOption('captions', 'track', {})"))
    }

    @Test("iPhone and iPad pages are unchanged: no scaling")
    func otherPagesDoNotScale() {
        for landscape in [false, true] {
            let page = AppleYouTubePreviewHTML.document(embedURL: embed, startsPlaying: true, isLandscape: landscape)
            #expect(!page.contains("transform:scale"))
            #expect(page.contains("var layoutScale = 1;"))
        }
    }

    @Test("The crop the page is drawn into does not depend on the stream size")
    func cropIsUnchanged() {
        let hero = CGSize(width: 1_440, height: 675)
        let frame = AppleTrailerPreviewLayout.coverFrame(in: hero)
        #expect(abs(frame.width - 1_440) < 0.001)
        #expect(abs(frame.height - 810) < 0.001)
        #expect(abs(frame.minY + 67.5) < 0.001)
    }
}
