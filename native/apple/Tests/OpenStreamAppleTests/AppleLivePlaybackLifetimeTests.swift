import Testing
@testable import OpenStreamApple

@MainActor
@Suite struct AppleLivePlaybackLifetimeTests {
    @Test func recreatingADeferredHostDoesNotClearTheRunningPlayersPictureInPictureFlag() throws {
        let engine = try AetherPlaybackEngine()
        defer { engine.stop() }
        engine.setPictureWhereabouts(pictureInPicture: true, external: false)
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        let audio = AppleAudioSessionCoordinator()
        let discardedInitialValue = ApplePlayerHost(coordinator: coordinator, audioSession: audio,
            activateImmediately: false)
        #expect(engine.aetherEngine.pictureInPictureActive)
        #expect(audio.onInterruption == nil)
        _ = discardedInitialValue
    }
    @Test func pictureInPictureStartIsProtectedWithoutAnEarlyCaptionHandoff() {
        let watcher = ApplePictureInPictureWatcher()
        watcher.willStart()
        #expect(watcher.isStartingOrActive && !watcher.isActive)
        watcher.set(false, event: "failedToStart")
        #expect(!watcher.isStartingOrActive)
        watcher.willStart()
        watcher.set(true, event: "didStart")
        #expect(watcher.isStartingOrActive && watcher.isActive)
        watcher.set(false, event: "willStop")
        #expect(!watcher.isStartingOrActive)
    }
    @Test func coveringAndReturningToGuidePreservesPlaybackButLeavingStopsIt() {
        let engine = FakePlaybackEngine()
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        let audio = AppleAudioSessionCoordinator()
        let host = ApplePlayerHost(coordinator: coordinator, audioSession: audio)
        let lifetime = AppleLivePlaybackLifetime()
        #expect(lifetime.beginLoad(identity: "channel:1"))
        engine.play()
        coordinator.update(.playing)

        lifetime.isFullScreen = true
        lifetime.inlineDisappeared(host: host, coordinator: coordinator)
        #expect(engine.stopCount == 0)
        #expect(coordinator.phase == .playing)
        #expect(audio.onInterruption != nil)

        lifetime.isFullScreen = false
        #expect(!lifetime.beginLoad(identity: "channel:1"))
        #expect(engine.stopCount == 0)
        // A deliberate channel change/retry must still load.
        #expect(lifetime.beginLoad(identity: "channel:2"))

        lifetime.inlineDisappeared(host: host, coordinator: coordinator)
        #expect(engine.stopCount == 1)
        #expect(coordinator.phase == .idle)
        #expect(audio.onInterruption == nil)
        #expect(lifetime.beginLoad(identity: "channel:2"))
    }

    @Test func backgroundStopsEvenWhenFullScreenAndAllowsResume() {
        let coordinator = ApplePlaybackCoordinator(engine: FakePlaybackEngine())
        let audio = AppleAudioSessionCoordinator()
        let host = ApplePlayerHost(coordinator: coordinator, audioSession: audio)
        let lifetime = AppleLivePlaybackLifetime()
        #expect(lifetime.beginLoad(identity: "channel"))
        lifetime.isFullScreen = true
        lifetime.stop(host: host, coordinator: coordinator)
        #expect(audio.onInterruption == nil)
        #expect(lifetime.beginLoad(identity: "channel"))
    }

    @Test func activePictureInPictureKeepsTheLiveStreamAndLoadIdentityInBackground() {
        let engine = FakePlaybackEngine()
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        let host = ApplePlayerHost(coordinator: coordinator, audioSession: AppleAudioSessionCoordinator())
        let lifetime = AppleLivePlaybackLifetime()
        #expect(lifetime.beginLoad(identity: "channel"))
        host.pictureInPictureDidChange(true)
        lifetime.enteredBackground(host: host, coordinator: coordinator)
        #expect(engine.stopCount == 0)
        #expect(!lifetime.beginLoad(identity: "channel"))
        lifetime.enteredForeground()
        host.pictureInPictureDidChange(false)
        #expect(engine.stopCount == 0)
        lifetime.enteredBackground(host: host, coordinator: coordinator)
        #expect(engine.stopCount == 1)
        #expect(lifetime.beginLoad(identity: "channel"))
    }
}
