import Foundation
import Testing
@testable import OpenStreamApple

/// The watch showed a play button while the phone was playing. `attach` was the
/// only thing that published a play/pause state and it runs while the engine is
/// still loading, so the wrist kept the loading-time value forever — nothing
/// republished when the phase changed, because `refreshRemoteCommands`, the one
/// method that would have, had no callers.
///
/// The republish is now driven off the player's 0.25 s bind timer, which only
/// works if an unchanged context is dropped.
@Suite("Watch link payload signature")
struct AppleWatchPayloadSignatureTests {
    @Test func theSameStateProducesTheSameSignature() {
        #expect(AppleWatchPayload.signature(title: "S1 E1 · First Response", isPlaying: true)
                == AppleWatchPayload.signature(title: "S1 E1 · First Response", isPlaying: true))
    }

    /// The exact transition that was being missed.
    @Test func startingToPlayChangesTheSignature() {
        let loading = AppleWatchPayload.signature(title: "S1 E1 · First Response", isPlaying: false)
        let playing = AppleWatchPayload.signature(title: "S1 E1 · First Response", isPlaying: true)
        #expect(loading != playing)
    }

    @Test func changingTitleChangesTheSignature() {
        #expect(AppleWatchPayload.signature(title: "One", isPlaying: true)
                != AppleWatchPayload.signature(title: "Two", isPlaying: true))
    }

    @Test func noTitleIsDistinctFromATitle() {
        #expect(AppleWatchPayload.signature(title: nil, isPlaying: false)
                != AppleWatchPayload.signature(title: "One", isPlaying: false))
    }

    /// Detaching has to look different from anything that was playing, or the
    /// watch keeps showing a title after the player closed.
    @Test func detachingIsDistinctFromPlaying() {
        #expect(AppleWatchPayload.signature(title: nil, isPlaying: false)
                != AppleWatchPayload.signature(title: "One", isPlaying: true))
    }

    /// A title that happens to contain the separator must not collide.
    @Test func aTitleContainingTheSeparatorDoesNotCollide() {
        #expect(AppleWatchPayload.signature(title: "true|X", isPlaying: false)
                != AppleWatchPayload.signature(title: "X", isPlaying: true))
    }
}
