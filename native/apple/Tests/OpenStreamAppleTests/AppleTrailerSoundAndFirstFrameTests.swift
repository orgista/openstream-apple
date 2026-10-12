import Foundation
import Testing
@testable import OpenStreamApple

/// Owner items 2–4 (2026-10-09, iOS 18): trailers had no sound and no way to
/// unmute, and flashed as they began.
@Suite struct AppleTrailerSoundAndFirstFrameTests {
    @Test func turningSoundOnLiftsTheMutedOnlyRule() {
        let on = AppleTrailerSoundBridge.tapped(isMuted: true, allowsSound: false)
        #expect(on.isMuted == false)
        #expect(on.allowsSound)
        let off = AppleTrailerSoundBridge.tapped(isMuted: false, allowsSound: true)
        #expect(off.isMuted)
        #expect(off.allowsSound)
    }

    @Test func theSoundOnCommandUnmutesThePage() {
        let next = AppleTrailerSoundBridge.tapped(isMuted: true, allowsSound: false)
        #expect(AppleTrailerSoundBridge.allowsSoundJavascriptCommand(allowsSound: next.allowsSound, isMuted: next.isMuted)
            == "window.setTrailerAllowsSound(true, false);")
    }

    @Test func autoplayStaysMutedUntilAsked() {
        let embed = URL(string: "https://www.youtube-nocookie.com/embed/fixture")!
        let autoplay = AppleYouTubePreviewHTML.document(embedURL: embed, startsPlaying: true, startsMuted: false)
        #expect(autoplay.contains("mute=1"))
        let pressed = AppleYouTubePreviewHTML.document(embedURL: embed, startsPlaying: true, startsMuted: false, allowsSound: true)
        #expect(pressed.contains("mute=0"))
    }

    @Test func theYouTubeFrameReportsItsFirstFrames() {
        let script = AppleYouTubePreviewHTML.playerChromeScript
        #expect(script.contains("requestVideoFrameCallback"))
        #expect(script.contains("state: '\(AppleTrailerFirstFrameGate.framesState)'"))
        #expect(script.contains("seen >= \(AppleTrailerFirstFrameGate.minimumFrames)"))
        // Re-armed on every start, so a resume or replay waits for frames too.
        #expect(script.contains("addEventListener('playing'"))
        #expect(AppleTrailerFirstFrameGate.cap > AppleTrailerRevealPolicy.portraitCap)
    }

    @Test func theCrossfadeIsShort() {
        #expect(AppleTrailerArtFirstPolicy.crossfadeDuration(reduceMotion: false) == 0.4)
        #expect(AppleTrailerArtFirstPolicy.crossfadeDuration(reduceMotion: true) == 0)
    }
}
