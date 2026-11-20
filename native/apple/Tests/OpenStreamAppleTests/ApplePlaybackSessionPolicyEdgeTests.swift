import Foundation
import Testing
@testable import OpenStreamApple

/// Edge cases the happy-path suite (`AppleHomeDesignPolicyTests`) does not
/// cover: enum equality and the invariant tying the ownership flags together.
@Suite("Playback session policy edge cases")
struct ApplePlaybackSessionPolicyEdgeTests {
    @Test func trailerAndPlaybackAreDistinctAndSelfEqual() {
        #expect(ApplePlaybackSessionPolicy.trailer == ApplePlaybackSessionPolicy.trailer)
        #expect(ApplePlaybackSessionPolicy.playback == ApplePlaybackSessionPolicy.playback)
        #expect(ApplePlaybackSessionPolicy.trailer != ApplePlaybackSessionPolicy.playback)
    }

    /// The three system-ownership flags never disagree: a case either owns
    /// now-playing and remote commands and allows unmuted web audio, or it
    /// owns none of them and requires muting.
    @Test("Now-playing, remote commands and muting never disagree",
          arguments: [ApplePlaybackSessionPolicy.trailer, .playback])
    func ownershipFlagsAgree(_ policy: ApplePlaybackSessionPolicy) {
        #expect(policy.publishesNowPlaying == policy.registersRemoteCommands)
        #expect(policy.requiresMutedWebPlayback != policy.publishesNowPlaying)
    }
}
