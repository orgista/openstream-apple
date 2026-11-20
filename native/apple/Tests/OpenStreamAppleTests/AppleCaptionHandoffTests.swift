import Testing
@testable import OpenStreamApple

/// The caption handoff between the app's cue layer and AVKit's Picture in
/// Picture / AirPlay rendering (N42). Each test drives the pure state machine
/// the way `AetherPlaybackEngine` does and checks the actions it asks for.
@MainActor
struct AppleCaptionHandoffTests {
    private let english = 2

    // MARK: - Picture in Picture

    @Test func startingPictureInPictureDeclaresThenRendersTheViewersTrack() {
        var handoff = AppleCaptionHandoff()
        #expect(handoff.update(pictureIsAway: true, wantedTrackID: english) == [.reload(declaringRenditions: true)])
        #expect(handoff.stage == .declaring)
        #expect(handoff.reloadFinished(succeeded: true) == [.nativeRendering(true)])
        #expect(handoff.stage == .native)
        #expect(handoff.renderedTrackID == english)
    }

    @Test func stoppingPictureInPictureDeselectsThenWithdrawsTheRenditions() {
        var handoff = nativeHandoff()
        #expect(handoff.update(pictureIsAway: false, wantedTrackID: english)
            == [.nativeRendering(false), .reload(declaringRenditions: false)])
        #expect(handoff.stage == .withdrawing)
        #expect(handoff.reloadFinished(succeeded: true) == [])
        #expect(handoff.stage == .app)
    }

    /// A viewer with captions off loses nothing in PiP, so nothing rebuilds.
    @Test func captionsOffNeverRebuildsTheItem() {
        var handoff = AppleCaptionHandoff()
        #expect(handoff.update(pictureIsAway: true, wantedTrackID: nil) == [])
        #expect(handoff.stage == .app)
        #expect(handoff.update(pictureIsAway: false, wantedTrackID: nil) == [])
    }

    /// A viewer who turns captions on while AirPlay holds the picture gets
    /// them on the receiver.
    @Test func turningCaptionsOnWhileAwayDeclaresThen() {
        var handoff = AppleCaptionHandoff()
        _ = handoff.update(pictureIsAway: true, wantedTrackID: nil)
        #expect(handoff.update(pictureIsAway: true, wantedTrackID: english) == [.reload(declaringRenditions: true)])
    }

    // MARK: - Changes while the picture is away

    @Test func aDifferentTrackWhileAwayReselectsWithoutARebuild() {
        var handoff = nativeHandoff()
        #expect(handoff.update(pictureIsAway: true, wantedTrackID: 5) == [.nativeRendering(true)])
        #expect(handoff.renderedTrackID == 5)
        #expect(handoff.update(pictureIsAway: true, wantedTrackID: 5) == [])
    }

    /// Off while away deselects; the renditions stay until the picture
    /// returns, so turning captions off costs no restart on the receiver.
    @Test func offWhileAwayDeselectsButKeepsTheRenditions() {
        var handoff = nativeHandoff()
        #expect(handoff.update(pictureIsAway: true, wantedTrackID: nil) == [.nativeRendering(false)])
        #expect(handoff.stage == .native)
        #expect(handoff.update(pictureIsAway: true, wantedTrackID: english) == [.nativeRendering(true)])
    }

    // MARK: - Edges that land mid-reload

    @Test func pictureBackBeforeTheDeclareLandsWithdrawsInstead() {
        var handoff = AppleCaptionHandoff()
        _ = handoff.update(pictureIsAway: true, wantedTrackID: english)
        #expect(handoff.update(pictureIsAway: false, wantedTrackID: english) == [])
        #expect(handoff.reloadFinished(succeeded: true) == [.reload(declaringRenditions: false)])
        #expect(handoff.stage == .withdrawing)
        #expect(handoff.reloadFinished(succeeded: true) == [])
        #expect(handoff.stage == .app)
    }

    @Test func pictureAwayAgainBeforeTheWithdrawLandsDeclaresAgain() {
        var handoff = nativeHandoff()
        _ = handoff.update(pictureIsAway: false, wantedTrackID: english)
        #expect(handoff.update(pictureIsAway: true, wantedTrackID: english) == [])
        #expect(handoff.reloadFinished(succeeded: true) == [.reload(declaringRenditions: true)])
        #expect(handoff.stage == .declaring)
    }

    /// The picture goes away again, then the withdraw fails: the declare is
    /// tried once anyway, or PiP / AirPlay would stay caption-less until the
    /// next track, route or whereabouts change.
    @Test func aFailedWithdrawWithThePictureAwayAgainDeclaresOnce() {
        var handoff = nativeHandoff()
        _ = handoff.update(pictureIsAway: false, wantedTrackID: english)
        _ = handoff.update(pictureIsAway: true, wantedTrackID: english)
        #expect(handoff.reloadFinished(succeeded: false) == [.reload(declaringRenditions: true)])
        #expect(handoff.stage == .declaring)
        #expect(handoff.reloadFinished(succeeded: true) == [.nativeRendering(true)])
        #expect(handoff.stage == .native)
        #expect(handoff.renderedTrackID == english)
    }

    /// The other order: the withdraw fails while the picture is still here,
    /// and the picture leaves afterwards. The handoff is back in `.app`, so
    /// leaving declares as it would from scratch.
    @Test func aFailedWithdrawThenThePictureAwayDeclares() {
        var handoff = nativeHandoff()
        _ = handoff.update(pictureIsAway: false, wantedTrackID: english)
        #expect(handoff.reloadFinished(succeeded: false) == [])
        #expect(handoff.stage == .app)
        #expect(handoff.update(pictureIsAway: true, wantedTrackID: english) == [.reload(declaringRenditions: true)])
        #expect(handoff.stage == .declaring)
    }

    /// The retry is one retry: a session that can neither withdraw nor
    /// declare is left alone until the picture comes back.
    @Test func aFailedRetryAfterAFailedWithdrawWaitsForThePicture() {
        var handoff = nativeHandoff()
        _ = handoff.update(pictureIsAway: false, wantedTrackID: english)
        _ = handoff.update(pictureIsAway: true, wantedTrackID: english)
        _ = handoff.reloadFinished(succeeded: false)
        #expect(handoff.reloadFinished(succeeded: false) == [])
        #expect(handoff.stage == .app)
        #expect(handoff.declineUntilPictureReturns)
        #expect(handoff.update(pictureIsAway: true, wantedTrackID: 5) == [])
        _ = handoff.update(pictureIsAway: false, wantedTrackID: english)
        #expect(handoff.update(pictureIsAway: true, wantedTrackID: english) == [.reload(declaringRenditions: true)])
    }

    /// Away again with captions off: nothing to hand over, so the failed
    /// withdraw rebuilds nothing; turning a track on declares from `.app`.
    @Test func aFailedWithdrawAwayWithoutATrackWaitsForOne() {
        var handoff = nativeHandoff()
        _ = handoff.update(pictureIsAway: false, wantedTrackID: english)
        _ = handoff.update(pictureIsAway: true, wantedTrackID: nil)
        #expect(handoff.reloadFinished(succeeded: false) == [])
        #expect(handoff.stage == .app)
        #expect(handoff.update(pictureIsAway: true, wantedTrackID: english) == [.reload(declaringRenditions: true)])
    }

    /// The engine rebuilds the item under a transient nil track; the
    /// rendition follows whatever the track is when the rebuild lands.
    @Test func theTrackAtTheMomentTheDeclareLandsIsTheOneRendered() {
        var handoff = AppleCaptionHandoff()
        _ = handoff.update(pictureIsAway: true, wantedTrackID: english)
        _ = handoff.update(pictureIsAway: true, wantedTrackID: nil)
        #expect(handoff.reloadFinished(succeeded: true) == [])
        #expect(handoff.stage == .native)
        #expect(handoff.update(pictureIsAway: true, wantedTrackID: english) == [.nativeRendering(true)])
    }

    @Test func aFailedDeclareIsNotRetriedUntilThePictureReturns() {
        var handoff = AppleCaptionHandoff()
        _ = handoff.update(pictureIsAway: true, wantedTrackID: english)
        #expect(handoff.reloadFinished(succeeded: false) == [])
        #expect(handoff.stage == .app)
        #expect(handoff.update(pictureIsAway: true, wantedTrackID: 5) == [])
        _ = handoff.update(pictureIsAway: false, wantedTrackID: english)
        #expect(handoff.update(pictureIsAway: true, wantedTrackID: english) == [.reload(declaringRenditions: true)])
    }

    @Test func aNewLoadMayRebuildWhereTheLastSessionCouldNot() {
        var handoff = AppleCaptionHandoff()
        _ = handoff.update(pictureIsAway: true, wantedTrackID: english)
        _ = handoff.reloadFinished(succeeded: false)
        #expect(handoff.declineUntilPictureReturns)
        #expect(handoff.loadStarted(eligible: true) == true)
    }

    // MARK: - Who draws, and whose selections count

    @Test func theAppDrawsOnlyWhileThePictureIsHere() {
        var handoff = AppleCaptionHandoff()
        #expect(handoff.appDrawsCaptions)
        _ = handoff.update(pictureIsAway: true, wantedTrackID: nil)
        #expect(!handoff.appDrawsCaptions)
        _ = handoff.update(pictureIsAway: false, wantedTrackID: nil)
        #expect(handoff.appDrawsCaptions)
    }

    /// Mid-reload the item changes under the engine's own selects; the
    /// stock-selection mirror must not read any of them as the viewer's.
    @Test func selectionsMidReloadAreNotTheViewers() {
        var handoff = AppleCaptionHandoff()
        #expect(handoff.acceptsStockSelection)
        _ = handoff.update(pictureIsAway: true, wantedTrackID: english)
        #expect(!handoff.acceptsStockSelection)
        _ = handoff.reloadFinished(succeeded: true)
        #expect(handoff.acceptsStockSelection)
        _ = handoff.update(pictureIsAway: false, wantedTrackID: english)
        #expect(!handoff.acceptsStockSelection)
    }

    // MARK: - Loads

    @Test func anEpisodeStartingInPictureInPictureDeclaresAtLoad() {
        var handoff = nativeHandoff()
        #expect(handoff.loadStarted(eligible: true) == true)
        #expect(handoff.stage == .declaring)
        #expect(handoff.renderedTrackID == nil)
        // The next episode's track arrives after the load.
        #expect(handoff.reloadFinished(succeeded: true) == [])
        #expect(handoff.update(pictureIsAway: true, wantedTrackID: 3) == [.nativeRendering(true)])
    }

    @Test func aLoadWithThePictureHereDeclaresNothing() {
        var handoff = AppleCaptionHandoff()
        #expect(handoff.loadStarted(eligible: true) == false)
        #expect(handoff.stage == .app)
        #expect(handoff.reloadFinished(succeeded: true) == [])
    }

    /// Remote HLS carries its own renditions: the handoff leaves it alone
    /// even with the picture away, and a pending rebuild is forgotten.
    @Test func anIneligibleLoadResetsTheHandoff() {
        var handoff = AppleCaptionHandoff()
        _ = handoff.update(pictureIsAway: true, wantedTrackID: english)
        #expect(handoff.loadStarted(eligible: false) == false)
        #expect(handoff.stage == .app)
        #expect(handoff.reloadFinished(succeeded: true) == [])
    }

    // MARK: - Which tracks travel

    @Test func embeddedTextTracksTravelSidecarFilesAndCEA708DoNot() {
        let tracks = [
            ApplePlaybackTrack(id: 2, title: "English", language: "eng", codec: "subrip"),
            ApplePlaybackTrack(id: 3, title: "English", language: "eng", codec: "hdmv_pgs_subtitle"),
            ApplePlaybackTrack(id: 4, title: "CC1", language: "eng", codec: "eia_608"),
            ApplePlaybackTrack(id: 5, title: "CC", language: "eng", codec: "eia_708"),
            ApplePlaybackTrack(id: AetherPlaybackEngine.externalSubtitleTrackIDBase, title: "Sidecar",
                               language: "eng", codec: "srt"),
        ]
        #expect(AppleCaptionHandoff.wantedTrack(activeTrackID: 2, tracks: tracks) == 2)
        #expect(AppleCaptionHandoff.wantedTrack(activeTrackID: 3, tracks: tracks) == 3)
        #expect(AppleCaptionHandoff.wantedTrack(activeTrackID: 4, tracks: tracks) == 4)
        #expect(AppleCaptionHandoff.wantedTrack(activeTrackID: 5, tracks: tracks) == nil)
        #expect(AppleCaptionHandoff.wantedTrack(
            activeTrackID: AetherPlaybackEngine.externalSubtitleTrackIDBase, tracks: tracks) == nil)
        #expect(AppleCaptionHandoff.wantedTrack(activeTrackID: nil, tracks: tracks) == nil)
        #expect(AppleCaptionHandoff.wantedTrack(activeTrackID: 9, tracks: tracks) == nil)
    }

    // MARK: - AirPlay route

    @Test(arguments: [
        // (player flag, wireless route, was active) -> active
        (true, false, false, true),
        (true, true, false, true),
        (false, true, false, false),  // AirPlay to a speaker: no picture to follow
        (false, true, true, true),    // the engine's LAN rebuild clears the flag for a moment
        (false, false, true, false),  // receiver gone
        (false, false, false, false),
    ])
    func airPlayHoldsThePictureAcrossTheEnginesOwnRebuild(
        player: Bool, wireless: Bool, wasActive: Bool, expected: Bool
    ) {
        #expect(AppleCaptionHandoff.externalPictureActive(
            playerReportsExternal: player, externalRouteHoldsAudio: wireless, wasActive: wasActive) == expected)
    }

    /// A full AirPlay session as the host reports it tick by tick: receiver
    /// joins, the engine's own rebuild blips the player flag, receiver leaves.
    @Test func anAirPlaySessionDeclaresOnceAndWithdrawsOnce() {
        var handoff = AppleCaptionHandoff()
        var external = false
        var actions: [AppleCaptionHandoff.Action] = []
        func tick(player: Bool, wireless: Bool) {
            external = AppleCaptionHandoff.externalPictureActive(
                playerReportsExternal: player, externalRouteHoldsAudio: wireless, wasActive: external)
            actions += handoff.update(pictureIsAway: external, wantedTrackID: english)
        }
        tick(player: false, wireless: false)
        tick(player: true, wireless: true)       // receiver joins
        tick(player: false, wireless: true)      // engine's LAN rebuild
        actions += handoff.reloadFinished(succeeded: true)
        tick(player: true, wireless: true)
        tick(player: false, wireless: false)     // receiver leaves
        actions += handoff.reloadFinished(succeeded: true)
        #expect(actions == [
            .reload(declaringRenditions: true), .nativeRendering(true),
            .nativeRendering(false), .reload(declaringRenditions: false),
        ])
        #expect(handoff.stage == .app)
    }

    private func nativeHandoff() -> AppleCaptionHandoff {
        var handoff = AppleCaptionHandoff()
        _ = handoff.update(pictureIsAway: true, wantedTrackID: english)
        _ = handoff.reloadFinished(succeeded: true)
        return handoff
    }
}
