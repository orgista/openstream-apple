import Foundation
import Testing
@testable import OpenStreamApple

@Suite struct AppleHomeDesignPolicyTests {
    @Test func trailersStayOutOfSystemPlayback() {
        let preview = ApplePlaybackSessionPolicy.trailer
        #expect(preview.audioCategory == .ambient)
        #expect(!preview.publishesNowPlaying)
        #expect(!preview.registersRemoteCommands)
        #expect(ApplePlaybackSessionPolicy.playback.audioCategory == .playback)
        #expect(ApplePlaybackSessionPolicy.playback.publishesNowPlaying)
        #expect(ApplePlaybackSessionPolicy.playback.registersRemoteCommands)
    }

    @Test func trailersCannotRestoreLongFormAudioOrUnmuteWebPlayback() throws {
        let preview = ApplePlaybackSessionPolicy.trailer
        #expect(preview.requiresMutedWebPlayback)
        #expect(!preview.shouldRestoreAudioSession(hasPlaybackRequest: true))
        #expect(!preview.shouldRestoreAudioSession(hasPlaybackRequest: false))
        #expect(!ApplePlaybackSessionPolicy.playback.requiresMutedWebPlayback)
        #expect(ApplePlaybackSessionPolicy.playback.shouldRestoreAudioSession(hasPlaybackRequest: true))
        #expect(!ApplePlaybackSessionPolicy.playback.shouldRestoreAudioSession(hasPlaybackRequest: false))

        let embed = try #require(URL(string: "https://fixture.example/embed/trailer?mute=0&playsinline=0"))
        let html = AppleYouTubePreviewHTML.document(embedURL: embed, startsPlaying: true, startsMuted: false,
            startupChromeCanShow: false)
        #expect(html.contains("mute=1"))
        #expect(html.contains("playsinline=1"))
        #expect(!html.contains("mute=0"))
        #expect(!html.contains("playsinline=0"))
        #expect(html.contains("var desiredMuted = true;"))
        #expect(html.contains("desiredMuted = requiresMutedPlayback || Boolean(isMuted);"))
    }

    /// An explicit "Play Trailer" press lifts the muted-only rule
    /// independently of autoplay's `startsMuted` guess, and the two flags
    /// travel together so a caller can never send one without the other.
    @Test func explicitPressAllowsSoundIndependentlyOfAutoplayGuess() throws {
        let embed = try #require(URL(string: "https://fixture.example/embed/trailer"))
        // Autoplay: no press, no sound allowed — muted regardless of the caller's guess.
        let autoplay = AppleYouTubePreviewHTML.document(embedURL: embed, startsPlaying: true, startsMuted: false,
            startupChromeCanShow: false)
        #expect(autoplay.contains("var requiresMutedPlayback = true;"))
        // Pressed: sound allowed even though the page still opens with the
        // viewer's last mute preference, which may itself be muted.
        let pressed = AppleYouTubePreviewHTML.document(embedURL: embed, startsPlaying: true,
                                                        startsMuted: true, allowsSound: true, startupChromeCanShow: false)
        #expect(pressed.contains("var requiresMutedPlayback = false;"))
        #expect(pressed.contains("window.setTrailerAllowsSound = function"))
        #expect(AppleTrailerSoundBridge.allowsSoundJavascriptCommand(allowsSound: true, isMuted: false)
                == "window.setTrailerAllowsSound(true, false);")
        #expect(AppleTrailerSoundBridge.allowsSoundJavascriptCommand(allowsSound: false, isMuted: true)
                == "window.setTrailerAllowsSound(false, true);")
    }
}
