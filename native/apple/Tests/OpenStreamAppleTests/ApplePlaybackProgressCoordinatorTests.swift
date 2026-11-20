import AVFoundation
import Foundation
import Testing
@testable import OpenStreamApple

/// `ApplePlaybackProgressCoordinator` is the one place that turns a player's
/// current time into a saved resume point. These pin what it hands to the
/// store: the identity and part it was built with, the near-end-to-complete
/// rule, and that a live/unknown-duration position is never written.
@Suite("Playback progress coordinator")
struct ApplePlaybackProgressCoordinatorTests {
    @MainActor
    private func makeStore() throws -> (ApplePlaybackStore, UserDefaults, String) {
        let suiteName = "openstream-progress-coordinator-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (ApplePlaybackStore(defaults: defaults), defaults, suiteName)
    }

    @MainActor
    @Test func initExposesTheMediaIdentityAndPartIDAndRecordSavesBothToTheStore() throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = ApplePlaybackProgressCoordinator(
            store: store,
            mediaIdentity: "record:show",
            partID: "tt1234567:1:2"
        )

        #expect(coordinator.mediaIdentity == "record:show")
        #expect(coordinator.partID == "tt1234567:1:2")

        coordinator.record(position: 600, duration: 3_000)

        let saved = try #require(store.progress(for: "record:show"))
        #expect(saved.resumePosition == 600)
        #expect(saved.partID == "tt1234567:1:2")
    }

    @MainActor
    @Test func recordingNearTheEndMarksTheTitleWatchedAndDropsTheStoredPosition() throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = ApplePlaybackProgressCoordinator(store: store, mediaIdentity: "record:finale")

        // Ten seconds from the end: inside the completion window.
        coordinator.record(position: 2_990, duration: 3_000)

        #expect(store.progress(for: "record:finale") == nil)
        #expect(store.isWatched(mediaID: "record:finale"))
    }

    @MainActor
    @Test func recordingWithNoOrInvalidDurationSavesNothing() throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = ApplePlaybackProgressCoordinator(store: store, mediaIdentity: "record:live-channel")

        // A live channel reports no duration.
        coordinator.record(position: 120, duration: 0)
        #expect(store.progress(for: "record:live-channel") == nil)

        coordinator.record(position: 120, duration: .nan)
        #expect(store.progress(for: "record:live-channel") == nil)

        coordinator.record(position: -5, duration: 3_000)
        #expect(store.progress(for: "record:live-channel") == nil)
    }

    @MainActor
    @Test func markCompleteClearsAnInProgressPositionEvenWhenFarFromTheEnd() throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = ApplePlaybackProgressCoordinator(store: store, mediaIdentity: "record:mid-watch")

        coordinator.record(position: 300, duration: 3_000)
        #expect(store.progress(for: "record:mid-watch")?.resumePosition == 300)

        coordinator.markComplete()
        #expect(store.progress(for: "record:mid-watch") == nil)
    }

    @MainActor
    @Test func saveCurrentProgressReadsFromARealPlayerAndSavesNothingWithoutADuration() throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = ApplePlaybackProgressCoordinator(store: store, mediaIdentity: "record:no-item")

        // No player has been observed yet: this must not crash and must not save.
        coordinator.saveCurrentProgress()
        #expect(store.progress(for: "record:no-item") == nil)

        // An empty composition is a real AVPlayer item with a zero duration,
        // the same shape a not-yet-ready or live item reports.
        let player = AVPlayer(playerItem: AVPlayerItem(asset: AVMutableComposition()))
        coordinator.startObserving(player)
        coordinator.saveCurrentProgress()
        #expect(store.progress(for: "record:no-item") == nil)
    }

    @MainActor
    @Test func replacingTheObservedPlayerStopsTheOldObserverAndStaysUsable() throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = ApplePlaybackProgressCoordinator(store: store, mediaIdentity: "record:switch")

        let first = AVPlayer(playerItem: AVPlayerItem(asset: AVMutableComposition()))
        coordinator.startObserving(first)
        let second = AVPlayer(playerItem: AVPlayerItem(asset: AVMutableComposition()))
        coordinator.startObserving(second)

        coordinator.record(position: 500, duration: 3_000)
        #expect(store.progress(for: "record:switch")?.resumePosition == 500)

        coordinator.stopObserving()
        // A second call must be a no-op, never a double removal of the observer.
        coordinator.stopObserving()
    }
}
