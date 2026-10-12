import Testing
@testable import OpenStreamApple

/// Trailers are art-first (owner, 2026-09-24): art, then — maybe — video.
@Suite struct AppleTrailerArtFirstPolicyTests {
    typealias Policy = AppleTrailerArtFirstPolicy

    @Test func lateTrailerMetadataChangesTheAutoplayRequest() {
        let empty = Policy.autoplayRequestID(itemID: "fixture", enabled: true, art: .loaded, keys: [])
        let filled = Policy.autoplayRequestID(itemID: "fixture", enabled: true, art: .loaded, keys: ["fixture-key"])
        #expect(empty != filled)
    }

    @Test func aPreviousCandidateCannotPauseTheNewTrailer() {
        #expect(Policy.acceptsMessage(messageKey: "old", currentKey: "new") == false)
        #expect(Policy.acceptsMessage(messageKey: "new", currentKey: "new"))
        #expect(Policy.acceptsMessage(messageKey: nil, currentKey: "new") == false)
    }

    @Test func startupOnlyTimesOutWhileWaitingForVideo() {
        #expect(Policy.startupHasTimedOut(active: true, videoIsOnScreen: false, elapsed: 15))
        #expect(Policy.startupHasTimedOut(active: true, videoIsOnScreen: false, elapsed: 14) == false)
        #expect(Policy.startupHasTimedOut(active: false, videoIsOnScreen: false, elapsed: 30) == false)
        #expect(Policy.startupHasTimedOut(active: true, videoIsOnScreen: true, elapsed: 30) == false)
    }

    @Test(arguments: [false, true])
    func noTrailerIsAskedForWhileTheArtIsLoading(pressed: Bool) {
        #expect(Policy.mayRequestTrailer(art: .loading, pressed: pressed) == false)
    }

    @Test(arguments: [false, true])
    func theTrailerIsAskedForOnceTheArtHasLoaded(pressed: Bool) {
        #expect(Policy.mayRequestTrailer(art: .loaded, pressed: pressed))
    }

    @Test func failedArtStillPlaysAPressedTrailerButNeverAutoplays() {
        #expect(Policy.mayRequestTrailer(art: .failed, pressed: true))
        #expect(Policy.mayRequestTrailer(art: .failed, pressed: false) == false)
    }

    @Test func loadedArtStaysLoadedThroughALaterFailure() {
        #expect(Policy.Art.loaded.settling(with: .failed) == .loaded)
        #expect(Policy.Art.loading.settling(with: .loaded) == .loaded)
        #expect(Policy.Art.loading.settling(with: .failed) == .failed)
        #expect(Policy.Art.failed.settling(with: .loaded) == .loaded)
    }

    @Test(arguments: ["ready", "playing", "iframe-state-1", "iframe-state-3", "muted", "unmuted"])
    func theVideoStaysHiddenUntilItIsRevealed(state: String) {
        #expect(Policy.videoLayerChange(forPlayerState: state) == nil)
    }

    @Test func aRevealedVideoCrossfadesIn() {
        #expect(Policy.videoLayerChange(forPlayerState: "revealed") == .reveal)
    }

    @Test(arguments: ["ended", "paused", "error", "autoplay-blocked", "concealed", Policy.webContentTerminatedState])
    func anEndedOrFailedVideoGoesBackToTheArt(state: String) {
        #expect(Policy.videoLayerChange(forPlayerState: state) == .returnToArt)
    }

    /// N22b: a crashed WebContent process (iPad sim, 2026-09-23) drops the
    /// video layer for good, as an error does — never a blank frame.
    @Test(arguments: ["error", "autoplay-blocked", Policy.webContentTerminatedState])
    func aDeadTrailerDropsItsVideoLayer(state: String) {
        #expect(Policy.dropsVideoLayer(forPlayerState: state))
    }

    @Test(arguments: ["ready", "revealed", "ended", "paused", "concealed"])
    func aLiveOrEndedTrailerKeepsItsVideoLayer(state: String) {
        #expect(Policy.dropsVideoLayer(forPlayerState: state) == false)
    }

    @Test(arguments: ["ended", "error", "autoplay-blocked", Policy.webContentTerminatedState])
    func aFinishedOrDeadTrailerLeavesTheArtOnScreen(state: String) {
        #expect(Policy.leavesForTheArt(forPlayerState: state))
    }

    @Test(arguments: ["ready", "playing", "revealed", "paused", "concealed", "muted"])
    func aLiveOrPausedTrailerKeepsItsLayer(state: String) {
        #expect(Policy.leavesForTheArt(forPlayerState: state) == false)
    }

    @Test func theTerminationStateIsNotOneThePageSends() {
        #expect(Policy.webContentTerminatedState == "web-content-terminated")
    }

    @Test func theCrossfadeIsSixTenthsOfASecondAndInstantWithReduceMotion() {
        #expect(Policy.crossfadeDuration(reduceMotion: false) == 0.4)
        #expect(Policy.crossfadeDuration(reduceMotion: true) == 0)
    }

    @Test func aPressedCardSaysItIsLoadingUntilItsVideoIsOnScreen() {
        #expect(Policy.pressedCardIsLoading(cardKey: "abc123", pressedKey: "abc123", videoIsOnScreen: false))
        #expect(Policy.pressedCardIsLoading(cardKey: "abc123", pressedKey: "abc123", videoIsOnScreen: true) == false)
    }

    @Test func onlyThePressedCardSaysItIsLoading() {
        #expect(Policy.pressedCardIsLoading(cardKey: "other1", pressedKey: "abc123", videoIsOnScreen: false) == false)
        // An autoplaying trailer was pressed on no card.
        #expect(Policy.pressedCardIsLoading(cardKey: "abc123", pressedKey: nil, videoIsOnScreen: false) == false)
    }

    /// iOS 18.6 regression 2026-10-01: Play Trailer over the hero's muted
    /// autoplay preview did nothing. It restarts the trailer with sound; only
    /// a pressed trailer that is already on screen ignores a second press.
    @Test func aHeroPressOverTheMutedPreviewRequestsTheTrailer() {
        #expect(Policy.heroPressRequestsTrailer(videoIsOnScreen: true, pressedTrailerPlaying: false))
        #expect(Policy.heroPressRequestsTrailer(videoIsOnScreen: false, pressedTrailerPlaying: false))
        // Pressed, still loading behind the art (or ended): press again.
        #expect(Policy.heroPressRequestsTrailer(videoIsOnScreen: false, pressedTrailerPlaying: true))
        #expect(Policy.heroPressRequestsTrailer(videoIsOnScreen: true, pressedTrailerPlaying: true) == false)
    }
}
