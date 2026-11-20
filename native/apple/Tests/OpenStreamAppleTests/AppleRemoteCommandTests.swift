import Foundation
import Testing
@testable import OpenStreamApple

/// Owner 2026-09-16: AirPods "pause/play features". A stem press sends
/// `togglePlayPause`, so the mapping has to resolve against what is playing.
@Suite("Remote commands")
struct AppleRemoteCommandTests {
    @Test func aStemPressPausesWhilePlaying() {
        #expect(AppleRemoteCommandPolicy.resolve(.toggle, isPlaying: true) == .pause)
    }

    @Test func aStemPressPlaysWhilePaused() {
        #expect(AppleRemoteCommandPolicy.resolve(.toggle, isPlaying: false) == .play)
    }

    /// An explicit command from Control Centre is obeyed as given, not
    /// reinterpreted against the current state.
    @Test func explicitCommandsAreNotReinterpreted() {
        #expect(AppleRemoteCommandPolicy.resolve(.play, isPlaying: true) == .play)
        #expect(AppleRemoteCommandPolicy.resolve(.pause, isPlaying: false) == .pause)
    }

    @Test func skippingMovesByTheInterval() {
        #expect(AppleRemoteCommandPolicy.destination(from: 100, offset: 10, duration: 600) == 110)
        #expect(AppleRemoteCommandPolicy.destination(from: 100, offset: -10, duration: 600) == 90)
    }

    /// Nudging forward near the end must not run off the end and stop
    /// playback — it lands on the last frame.
    @Test func skippingPastTheEndClampsToTheEnd() {
        #expect(AppleRemoteCommandPolicy.destination(from: 595, offset: 10, duration: 600) == 600)
    }

    @Test func skippingBeforeTheStartClampsToZero() {
        #expect(AppleRemoteCommandPolicy.destination(from: 3, offset: -10, duration: 600) == 0)
    }

    /// A live stream has no duration; skipping still must not produce a
    /// negative position.
    @Test func anUnknownDurationStillClampsAtZero() {
        #expect(AppleRemoteCommandPolicy.destination(from: 3, offset: -10, duration: nil) == 0)
        #expect(AppleRemoteCommandPolicy.destination(from: 100, offset: 10, duration: nil) == 110)
    }

    /// Every way of skipping in the app moves the same amount.
    @Test func theSkipIntervalMatchesTheOnScreenControls() {
        #expect(AppleRemoteCommand.skipInterval == 10)
    }
}
