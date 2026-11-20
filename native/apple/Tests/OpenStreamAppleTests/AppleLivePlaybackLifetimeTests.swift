import Testing
import Observation
import Synchronization
@testable import OpenStreamApple

@MainActor
@Suite struct AppleLivePlaybackLifetimeTests {
    @Test func onlyResourceReplacementInvalidatesObservers() throws {
        let lifetime = AppleLivePlaybackLifetime()
        let coordinator = ApplePlaybackCoordinator(engine: FakePlaybackEngine())
        let resourcesChanged = Mutex(0)
        let bookkeepingChanged = Mutex(0)
        withObservationTracking {
            _ = lifetime.resources(for: coordinator)
        } onChange: {
            resourcesChanged.withLock { $0 += 1 }
        }
        withObservationTracking {
            _ = lifetime.isFullScreen
            _ = lifetime.isInBackground
            _ = lifetime.beginLoad(identity: "first")
        } onChange: {
            bookkeepingChanged.withLock { $0 += 1 }
        }
        lifetime.isFullScreen = true
        _ = lifetime.beginLoad(identity: "second")
        lifetime.configure(for: coordinator)
        let resources = try #require(lifetime.resources(for: coordinator))
        lifetime.enteredBackground(host: resources.host, coordinator: coordinator)
        lifetime.enteredForeground()
        #expect(resourcesChanged.withLock { $0 } == 1)
        #expect(bookkeepingChanged.withLock { $0 } == 0)
    }

    @Test func playerResourcesAreCreatedOnlyOnAppearance() throws {
        var allocations = 0
        let lifetime = AppleLivePlaybackLifetime { coordinator in
            allocations += 1
            let audio = AppleAudioSessionCoordinator()
            return (host: ApplePlayerHost(coordinator: coordinator, audioSession: audio,
                activateImmediately: false), audioSession: audio)
        }
        let coordinator = ApplePlaybackCoordinator(engine: FakePlaybackEngine())

        #expect(allocations == 0)
        #expect(lifetime.resources(for: coordinator) == nil)
        #expect(allocations == 0)
        lifetime.configure(for: coordinator)
        let resources = try #require(lifetime.resources(for: coordinator))
        #expect(allocations == 1)
        #expect(resources.audioSession.onInterruption == nil)
    }

    @Test func repeatedResourceReadsReuseTheHostAndAudioSession() throws {
        var allocations = 0
        let lifetime = AppleLivePlaybackLifetime { coordinator in
            allocations += 1
            let audio = AppleAudioSessionCoordinator()
            return (host: ApplePlayerHost(coordinator: coordinator, audioSession: audio,
                activateImmediately: false), audioSession: audio)
        }
        let engine = FakePlaybackEngine()
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        lifetime.configure(for: coordinator)
        let first = try #require(lifetime.resources(for: coordinator))
        defer { lifetime.stop(host: first.host, coordinator: coordinator) }
        first.host.activate()
        #expect(lifetime.beginLoad(identity: "channel:1"))
        coordinator.update(.playing)

        let second = try #require(lifetime.resources(for: coordinator))
        #expect(allocations == 1)
        #expect(first.host === second.host)
        #expect(first.audioSession === second.audioSession)
        #expect(second.audioSession.onInterruption != nil)
        #expect(coordinator.phase == .playing)
        #expect(engine.stopCount == 0)
        #expect(lifetime.beginLoad(identity: "channel:1") == false)
    }

    @Test func changingCoordinatorOnlyTearsDownInTheExplicitHook() throws {
        var allocations = 0
        let lifetime = AppleLivePlaybackLifetime { coordinator in
            allocations += 1
            let audio = AppleAudioSessionCoordinator()
            return (host: ApplePlayerHost(coordinator: coordinator, audioSession: audio,
                activateImmediately: false), audioSession: audio)
        }
        let oldEngine = FakePlaybackEngine()
        let oldCoordinator = ApplePlaybackCoordinator(engine: oldEngine)
        lifetime.configure(for: oldCoordinator)
        let first = try #require(lifetime.resources(for: oldCoordinator))
        first.host.activate()
        #expect(lifetime.beginLoad(identity: "channel:1"))
        oldCoordinator.update(.playing)
        let newEngine = FakePlaybackEngine()
        let newCoordinator = ApplePlaybackCoordinator(engine: newEngine)

        #expect(lifetime.resources(for: newCoordinator) == nil)
        #expect(oldEngine.stopCount == 0)
        #expect(allocations == 1)
        #expect(lifetime.resources(for: oldCoordinator)?.host === first.host)
        lifetime.configure(for: newCoordinator)
        let replacement = try #require(lifetime.resources(for: newCoordinator))
        #expect(allocations == 2)
        #expect(first.host !== replacement.host)
        #expect(first.audioSession !== replacement.audioSession)
        #expect(first.audioSession.onInterruption == nil)
        #expect(oldEngine.stopCount == 1)
        #expect(oldCoordinator.phase == .idle)
        #expect(replacement.audioSession.onInterruption == nil)
        #expect(newEngine.stopCount == 0)
        #expect(lifetime.beginLoad(identity: "channel:1"))
        lifetime.configure(for: newCoordinator)
        let reused = try #require(lifetime.resources(for: newCoordinator))
        #expect(reused.host === replacement.host)
        #expect(reused.audioSession === replacement.audioSession)
        #expect(allocations == 2)
    }

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

    @Test func searchingKeepsPlaybackAndLeavingLiveStillStopsIt() {
        let engine = FakePlaybackEngine()
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        let audio = AppleAudioSessionCoordinator()
        let host = ApplePlayerHost(coordinator: coordinator, audioSession: audio)
        let lifetime = AppleLivePlaybackLifetime()
        #expect(lifetime.beginLoad(identity: "channel"))
        engine.play()
        coordinator.update(.playing)

        lifetime.inlineDisappeared(host: host, coordinator: coordinator, isSearching: true)
        #expect(engine.stopCount == 0)
        #expect(coordinator.phase == .playing)
        #expect(audio.onInterruption != nil)
        #expect(!lifetime.beginLoad(identity: "channel"))

        lifetime.inlineDisappeared(host: host, coordinator: coordinator)
        #expect(engine.stopCount == 1)
        #expect(coordinator.phase == .idle)
        #expect(audio.onInterruption == nil)
        #expect(lifetime.beginLoad(identity: "channel"))
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
