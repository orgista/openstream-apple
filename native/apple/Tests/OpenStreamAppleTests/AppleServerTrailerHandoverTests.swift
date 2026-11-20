import Foundation
import Testing
@testable import OpenStreamApple

/// Seamless handover (2026-10-29): a server trailer taken down
/// while seen stays on its last frame, its sound fading, until the still is
/// back over it; one never seen just stops.
@Suite("Server trailer: the still ↔ video handover")
struct AppleServerTrailerHandoverTests {
    private typealias Handover = AppleServerTrailerHandover

    private func playing(crossfade: TimeInterval = AppleTrailerArtFirstPolicy.crossfadeDuration) -> Handover {
        var handover = Handover(crossfade: crossfade)
        _ = handover.start()
        _ = handover.reveal()
        return handover
    }

    @Test("Revealed, it crossfades in and its sound comes up once the crossfade is done")
    func revealBringsTheSoundUpAfterTheCrossfade() {
        var handover = Handover()
        #expect(handover.start() == .none)
        #expect(handover.phase == .loading)
        #expect(handover.reveal() == AppleTrailerArtFirstPolicy.crossfadeDuration)
        #expect(handover.phase == .playing)
        #expect(handover.reveal() == nil)
    }

    @Test("With Reduce Motion the swap is instant and the sound comes up at once")
    func reduceMotionHasNoSoundDelay() {
        var handover = Handover(crossfade: AppleTrailerArtFirstPolicy.crossfadeDuration(reduceMotion: true))
        _ = handover.start()
        #expect(handover.reveal() == 0)
        #expect(handover.finish(.ended) == .hold(soundFade: 0))
    }

    @Test("At the end it holds the last frame, fading its sound, and is let go only once the still is up")
    func endHoldsUntilTheStillIsUp() {
        var handover = playing()
        #expect(handover.finish(.ended) == .hold(soundFade: AppleTrailerArtFirstPolicy.crossfadeDuration))
        #expect(handover.phase == .ended)
        #expect(handover.shown == .held)
        #expect(handover.stillIsUp() == true)
        #expect(handover.shown == .current)
        #expect(handover.stillIsUp() == false)
    }

    @Test("A failure while seen is held the same way")
    func failureWhileSeenHolds() {
        var handover = playing()
        #expect(handover.finish(.failed) == .hold(soundFade: AppleTrailerArtFirstPolicy.crossfadeDuration))
        #expect(handover.shown == .held)
    }

    @Test("Concealed while playing, its sound fades over the crossfade and its frame holds")
    func concealWhilePlayingFadesTheSound() {
        var handover = playing()
        #expect(handover.conceal() == .hold(soundFade: AppleTrailerArtFirstPolicy.crossfadeDuration))
        #expect(handover.phase == .idle)
        #expect(handover.shown == .held)
    }

    @Test("Never seen, it just stops: concealed or failed while loading")
    func neverSeenStops() {
        var handover = Handover()
        _ = handover.start()
        #expect(handover.conceal() == .discard)
        #expect(handover.shown == .current)
        _ = handover.start()
        #expect(handover.finish(.failed) == .discard)
        #expect(handover.phase == .failed)
        #expect(handover.stillIsUp() == false)
    }

    @Test("Started over mid-play, the old frame holds under the still instead of cutting")
    func restartMidPlayingHolds() {
        var handover = playing()
        #expect(handover.start() == .hold(soundFade: AppleTrailerArtFirstPolicy.crossfadeDuration))
        #expect(handover.phase == .loading)
        #expect(handover.shown == .held)
        // The still is back: the old frame goes, the new trailer loads under it.
        #expect(handover.stillIsUp() == true)
        #expect(handover.shown == .current)
    }

    @Test("Started over and revealed before the still was fully back: the held frame goes at the reveal")
    func restartRevealedReleasesTheHeldFrame() {
        var handover = playing()
        _ = handover.start()
        #expect(handover.reveal() != nil)
        #expect(handover.shown == .current)
        #expect(handover.stillIsUp() == false)
    }

    @Test("A late end after it was taken down changes nothing")
    func lateEndIsIgnored() {
        var handover = playing()
        _ = handover.conceal()
        #expect(handover.finish(.ended) == .none)
        #expect(handover.phase == .idle)
    }

    @Test("Stop lets everything go at once")
    func stopReleasesAll() {
        var handover = playing()
        _ = handover.finish(.ended)
        handover.stop()
        #expect(handover.phase == .idle)
        #expect(handover.shown == .current)
        #expect(handover.stillIsUp() == false)
    }

    @Test(arguments: [Handover.Phase.loading, .playing, .ended, .failed])
    func leavingTheHeroDiscardsInterruptedVideoAndIgnoresLateFrames(phase: AppleServerTrailerHandover.Phase) {
        var handover = Handover()
        _ = handover.start()
        if phase != .loading { _ = handover.reveal() }
        if phase == .ended || phase == .failed { _ = handover.finish(phase) }
        handover.stop()
        #expect(handover.phase == .idle)
        #expect(!handover.holdsLastFrame)
        #expect(handover.reveal() == nil)
        #expect(handover.finish(.ended) == .none)
        #expect(handover.start() == .none)
        #expect(handover.shown == .current)
    }

    @Test("The YouTube page ends its preview early enough for the crossfade back to finish over live frames")
    func youTubeHideLeadCoversTheCrossfade() throws {
        let embed = try #require(AppleTrailerPreviewPolicy.embedURL(for: "trailer_456"))
        let html = AppleYouTubePreviewHTML.document(embedURL: embed, startsPlaying: true, startupChromeCanShow: true)
        let lead = try #require(html.firstMatch(of: /previewHideLeadSeconds = ([0-9.]+);/).flatMap { Double($0.1) })
        #expect(lead > AppleTrailerArtFirstPolicy.crossfadeDuration)
    }
}
