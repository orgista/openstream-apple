import Observation
import Testing
@testable import OpenStreamApple

struct AppleSoftwareAudioSwitchTests {
    @Test @MainActor func surfaceRetentionObservesBothSwitchStartAndCleanup() async {
        let pending = AppleSoftwareAudioSwitch()
        await confirmation("The surface observes switch start") { changed in
            withObservationTracking { _ = pending.selection } onChange: { changed() }
            pending.begin(trackID: 2, position: 400, paused: true)
        }
        await confirmation("The surface observes timeout cleanup") { changed in
            withObservationTracking { _ = pending.selection } onChange: { changed() }
            _ = pending.finish(awaitingLatePlayback: true)
        }
        #expect(pending.selection == nil)
    }

    @Test func rejectedTrackPausesImmediately() {
        let pending = AppleSoftwareAudioSwitch()
        pending.begin(trackID: 2, position: 400, paused: false)
        let pauseImmediately = pending.pause(activeTrackID: 1)
        #expect(pauseImmediately)
        let pauseOnTimeout = pending.finish()
        #expect(pauseOnTimeout)
        #expect(pending.selection == nil)
    }

    @Test func reloadWaitsForAFrameInsteadOfPausingTheColdRenderer() {
        let pending = AppleSoftwareAudioSwitch()
        pending.begin(trackID: 2, position: 400, paused: true)
        let pauseImmediately = pending.pause(activeTrackID: nil, isLoading: true)
        #expect(!pauseImmediately)
        let pauseOnTimeout = pending.finish()
        #expect(pauseOnTimeout)
    }

    @Test func timeoutOrFailureClearsTheSwitchAndHonoursPause() {
        let pending = AppleSoftwareAudioSwitch()
        pending.begin(trackID: 2, position: 400, paused: false)
        let pauseImmediately = pending.pause(activeTrackID: 2)
        #expect(!pauseImmediately)
        let restore = pending.restore(activeTrackID: 2, hasClock: false)
        #expect(restore == nil)
        let pauseOnTimeout = pending.finish(awaitingLatePlayback: true)
        #expect(pauseOnTimeout)
        #expect(pending.selection == nil)
        let latePause = pending.consumeLatePause()
        #expect(latePause)
        let repeatedLatePause = pending.consumeLatePause()
        #expect(!repeatedLatePause)
        let secondPause = pending.finish()
        #expect(!secondPause)
        #expect(pending.pauseRequested, "A renderer arriving after timeout must still honour Pause")
        pending.reset()
        #expect(!pending.pauseRequested)
    }

    @Test func aTimeoutWithoutAnEarlierPauseStopsTheSwitchAndItsLateRenderer() {
        let pending = AppleSoftwareAudioSwitch()
        pending.begin(trackID: 2, position: 400, paused: false)
        let pause = pending.timeOut()
        #expect(pause)
        #expect(pending.selection == nil)
        let latePause = pending.consumeLatePause()
        #expect(latePause)
        let repeatedPause = pending.consumeLatePause()
        #expect(!repeatedPause)
    }

    @Test func anOrdinaryPauseDoesNotRepeatWhenScrubbingPublishesPlaying() {
        let pending = AppleSoftwareAudioSwitch()
        let pauseImmediately = pending.pause(activeTrackID: 1)
        #expect(pauseImmediately)
        #expect(!pending.awaitsLatePlayback)
        let repeatedPause = pending.consumeLatePause()
        #expect(!repeatedPause)
    }

    @Test func aUserSeekReplacesTheSavedPosition() throws {
        let pending = AppleSoftwareAudioSwitch()
        pending.begin(trackID: 2, position: 400, paused: true)
        pending.userSeek(to: 864)
        let restored = pending.restore(activeTrackID: 2, hasClock: true)
        let restore = try #require(restored)
        #expect(restore.position == 864)
        let pause = pending.finish()
        #expect(pause)
    }

    @Test func restoreWaitsForTheSelectedTracksClockAndRunsOnce() {
        let pending = AppleSoftwareAudioSwitch()
        pending.begin(trackID: 2, position: 400, paused: true)
        let wrongTrack = pending.restore(activeTrackID: 1, hasClock: true)
        #expect(wrongTrack == nil)
        let coldRenderer = pending.restore(activeTrackID: 2, hasClock: false)
        #expect(coldRenderer == nil)
        let restore = pending.restore(activeTrackID: 2, hasClock: true)
        #expect(restore?.position == 400)
        let repeated = pending.restore(activeTrackID: 2, hasClock: true)
        #expect(repeated == nil)
        pending.play()
        let pause = pending.finish()
        #expect(!pause)
    }
}
