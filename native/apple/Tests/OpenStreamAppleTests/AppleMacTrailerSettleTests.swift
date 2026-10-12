#if os(macOS)
import CoreGraphics
import Foundation
import Testing
@testable import OpenStreamApple

/// N31: the art fades only once YouTube's player page has reached the web
/// view's final size with its video fitted to it. Faded any earlier, a
/// letterboxed trailer came in at the art's size and then grew (measured:
/// the web view went 1440×810 → 1600×900 at the fade while the page was
/// still 1440×810, and caught up ~90 ms into the fade).
@Suite("Mac hero: the trailer holds its size once it can be seen")
struct AppleMacTrailerSettleTests {
    private typealias Policy = AppleMacTrailerSettlePolicy

    private func geometry(_ frame: CGSize, _ video: CGRect?) -> AppleMacTrailerGeometry {
        AppleMacTrailerGeometry(frame: frame, video: video)
    }

    @Test("A page still at its old size is not settled")
    func oldPageSizeWaits() {
        let old = geometry(CGSize(width: 1_440, height: 810), CGRect(x: 0, y: 0, width: 1_440, height: 810))
        #expect(!Policy.isSettled(old, expected: CGSize(width: 1_600, height: 900)))
    }

    @Test("A page at the new size whose video has not been re-laid out yet is not settled")
    func staleVideoWaits() {
        let stale = geometry(CGSize(width: 1_600, height: 900), CGRect(x: 0, y: 0, width: 1_440, height: 810))
        #expect(!Policy.isSettled(stale, expected: CGSize(width: 1_600, height: 900)))
    }

    @Test("A page at the new size with its video filling it is settled, at either layout scale",
          arguments: [CGSize(width: 1_600, height: 900), CGSize(width: 3_200, height: 1_800)])
    func filledPageSettles(size: CGSize) {
        let filled = geometry(size, CGRect(origin: .zero, size: size))
        #expect(Policy.isSettled(filled, expected: size))
    }

    @Test("A 1.85:1 source YouTube letterboxes itself, centred in the page, is settled")
    func selfLetterboxedSourceSettles() {
        let page = CGSize(width: 1_440, height: 810)
        #expect(Policy.isSettled(geometry(page, CGRect(x: 0, y: 17, width: 1_440, height: 777)), expected: page))
        // Off-centre is YouTube mid-layout.
        #expect(!Policy.isSettled(geometry(page, CGRect(x: 0, y: 0, width: 1_440, height: 777)), expected: page))
    }

    @Test("Web view points that round to the page's CSS px still match")
    func roundingIsTolerated() {
        let page = CGSize(width: 1_630, height: 916)
        let reported = geometry(page, CGRect(x: 1, y: 0, width: 1_628, height: 916))
        #expect(Policy.isSettled(reported, expected: CGSize(width: 1_630.19, height: 916.98)))
    }

    @Test("No report, or no video yet, is not settled")
    func missingVideoWaits() {
        let page = CGSize(width: 1_440, height: 810)
        #expect(!Policy.isSettled(nil, expected: page))
        #expect(!Policy.isSettled(geometry(page, nil), expected: page))
        #expect(!Policy.isSettled(geometry(page, CGRect(x: 720, y: 405, width: 0, height: 0)), expected: page))
    }

    @Test("The picture must hold still before the fade, and the wait is bounded")
    func timing() {
        #expect(Policy.stableInterval >= 0.3)
        #expect(Policy.timeout > Policy.stableInterval && Policy.timeout <= 3)
    }

    @Test("The player page's report is read as sent")
    func payloadParses() {
        let payload: [String: Any] = ["state": "geometry", "frame": [3_200.0, 1_800.0],
                                      "video": [0.0, 0.0, 3_200.0, 1_800.0], "source": [1_920.0, 1_080.0]]
        #expect(AppleMacTrailerGeometry(payload: payload)
            == geometry(CGSize(width: 3_200, height: 1_800), CGRect(x: 0, y: 0, width: 3_200, height: 1_800)))
        let noVideo = AppleMacTrailerGeometry(payload: ["state": "geometry", "frame": [640.0, 360.0], "video": NSNull()])
        #expect(noVideo == geometry(CGSize(width: 640, height: 360), nil))
        #expect(AppleMacTrailerGeometry(payload: ["state": "geometry"]) == nil)
    }

    @Test("The script in YouTube's frame reports geometry, keeps captions and the glyph hidden, and only runs there")
    func frameScript() {
        let script = AppleYouTubePreviewHTML.macPlayerFrameScript
        #expect(script.contains("state: 'geometry'"))
        #expect(script.contains("getBoundingClientRect()"))
        #expect(script.contains(".ytp-caption-window-container"))
        #expect(script.contains(".ytp-bezel"))
        #expect(script.contains("youtube(-nocookie)?\\.com$/.test(location.hostname)) return;"))
        // The page every host loads never carries it; only the Mac web view injects it.
        let page = AppleYouTubePreviewHTML.document(embedURL: URL(string: "https://fixture.example/embed/x")!,
                                                    startsPlaying: true, isLandscape: true)
        #expect(!page.contains("state: 'geometry'"))
    }
}
#endif
