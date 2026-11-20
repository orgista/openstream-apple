import Foundation
import Testing
#if canImport(UIKit)
import UIKit
#endif
@testable import OpenStreamApple

@Suite("Trailer page: reveal once the video advances, preserving attribution")
struct AppleTrailerRevealPolicyTests {
    private let fast = AppleTrailerRevealPolicy.rule(startupChromeCanShow: false)

    @Test("Without start-up chrome: revealed at 0.5 s once 0.3 s of media has played")
    func revealsOnceTheVideoAdvances() {
        #expect(fast.allowsReveal(sincePlaying: 0.5, mediaAdvance: 0.3))
        #expect(fast.allowsReveal(sincePlaying: 0.8, mediaAdvance: 0.7))
    }

    @Test("Never before the minimum wait, however far the media has moved")
    func neverBeforeTheMinimumWait() {
        #expect(fast.allowsReveal(sincePlaying: 0.49, mediaAdvance: 2) == false)
        #expect(fast.allowsReveal(sincePlaying: 0, mediaAdvance: 0.3) == false)
    }

    @Test("A stalled first buffer stays under the art without a time limit")
    func stalledVideoNeverReveals() {
        #expect(fast.allowsReveal(sincePlaying: 1.5, mediaAdvance: 0.05) == false)
        #expect(fast.allowsReveal(sincePlaying: 3.19, mediaAdvance: 0) == false)
        #expect(fast.allowsReveal(sincePlaying: 3.2, mediaAdvance: 0) == false)
        #expect(fast.allowsReveal(sincePlaying: 60, mediaAdvance: 0.05) == false)
        #expect(fast.allowsReveal(sincePlaying: 2, mediaAdvance: -40) == false)
        #expect(fast.allowsReveal(sincePlaying: 60, mediaAdvance: -40) == false)
    }

    @Test("Non-phone players wait for start-up chrome without a timeout reveal")
    func startupChromeWait() {
        let rule = AppleTrailerRevealPolicy.rule(startupChromeCanShow: true)
        // N75: the title strip, link and "More videos" are up until 3.9–4.2 s of media time.
        #expect(rule.allowsReveal(sincePlaying: 4.3, mediaAdvance: 4.2) == false)
        #expect(rule.allowsReveal(sincePlaying: 4.6, mediaAdvance: 4.5))
        #expect(rule.allowsReveal(sincePlaying: 11.9, mediaAdvance: 1) == false)
        #expect(rule.allowsReveal(sincePlaying: 60, mediaAdvance: 1) == false)
    }

    private static let iPhoneWaits = AppleTrailerRevealPolicy.iPhoneWaitsForStartupChrome

    @Test("iPad, Apple TV, Vision Pro and the Mac always wait; iPhone follows the pending owner decision", arguments: [
        (AppleUIPlatform.iOS, true, iPhoneWaits), (.iOS, false, true),
        (.macOS, true, true), (.macOS, false, true),
        (.tvOS, true, true), (.tvOS, false, true),
        (.visionOS, true, true), (.visionOS, false, true)
    ])
    func platformAndIdiom(platform: AppleUIPlatform, isPhone: Bool, waits: Bool) {
        #expect(AppleTrailerRevealPolicy.startupChromeCanShow(on: platform, isPhone: isPhone) == waits)
    }

    #if canImport(UIKit)
    #if os(iOS)
    @Test(arguments: [(UIUserInterfaceIdiom.phone, iPhoneWaits), (.pad, true), (.tv, true),
                      (.mac, true), (.vision, true), (.unspecified, true)])
    #else
    @Test(arguments: [(UIUserInterfaceIdiom.phone, true), (.pad, true), (.tv, true),
                      (.mac, true), (.vision, true), (.unspecified, true)])
    #endif
    func userInterfaceIdiom(idiom: UIUserInterfaceIdiom, waits: Bool) {
        #expect(AppleTrailerRevealPolicy.startupChromeCanShow(for: idiom) == waits)
    }
    #endif

    @Test("Each platform passes its explicit reveal choice to the page")
    func currentPlatformReveal() throws {
        let embed = try #require(AppleTrailerPreviewPolicy.embedURL(for: "trailer_456"))
        let waits = AppleTrailerRevealPolicy.startupChromeCanShow(isPhone: true)
        let html = AppleYouTubePreviewHTML.document(embedURL: embed, startsPlaying: true, startupChromeCanShow: waits)
        #if os(iOS)
        #expect(waits == Self.iPhoneWaits)
        #expect(html.contains(Self.iPhoneWaits ? "var revealRule = [500, 4.5];" : "var revealRule = [500, 0.3];"))
        #else
        #expect(waits)
        #expect(html.contains("var revealRule = [500, 4.5];"))
        #endif
    }

    @Test("The page carries the same numbers as the Swift rule")
    func pageCarriesTheRule() throws {
        let embed = try #require(AppleTrailerPreviewPolicy.embedURL(for: "trailer_456"))
        let phone = AppleYouTubePreviewHTML.document(embedURL: embed, startsPlaying: true, isLandscape: true,
                                                     startupChromeCanShow: false)
        #expect(phone.contains("var revealRule = [500, 0.3];"))
        let pad = AppleYouTubePreviewHTML.document(embedURL: embed, startsPlaying: true, isLandscape: true,
                                                   startupChromeCanShow: true)
        #expect(pad.contains("var revealRule = [500, 4.5];"))
    }

    @Test("Known trailer offsets survive initial play and replay", arguments: ["12", "0", "-1", "nan"])
    func suppliedOffsetIsHonored(_ value: String) throws {
        let embed = try #require(URL(string: "https://www.youtube-nocookie.com/embed/trailer_456?start=\(value)"))
        let html = AppleYouTubePreviewHTML.document(embedURL: embed, startsPlaying: true, startupChromeCanShow: false)
        let expected = value == "12" ? 12 : 0
        #expect(html.contains("start: \(expected),"))
        #expect(html.contains("player.seekTo(\(expected), true)"))
    }
}
