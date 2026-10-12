import Foundation
import Testing
@testable import OpenStreamApple

@Suite("Remove from Continue Watching")
struct AppleContinueWatchingRemovalTests {
    private let suiteName = "continue-watching-removal-tests.\(UUID())"

    @MainActor
    private func makeStore() throws -> (ApplePlaybackStore, UserDefaults) {
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (ApplePlaybackStore(defaults: defaults), defaults)
    }

    @Test func removalHidesUntilPlayedAfterIt() {
        let removed = Date(timeIntervalSince1970: 1_000)
        #expect(!AppleContinueWatchingRemovalPolicy.isRemoved(removedAt: nil, lastPlayedAt: removed))
        #expect(AppleContinueWatchingRemovalPolicy.isRemoved(removedAt: removed, lastPlayedAt: nil))
        #expect(AppleContinueWatchingRemovalPolicy.isRemoved(removedAt: removed, lastPlayedAt: removed.addingTimeInterval(-60)))
        #expect(!AppleContinueWatchingRemovalPolicy.isRemoved(removedAt: removed, lastPlayedAt: removed.addingTimeInterval(60)))
    }

    @Test func mergeKeepsTheNewestRemovalPerTitle() {
        let older = Date(timeIntervalSince1970: 100), newer = Date(timeIntervalSince1970: 200)
        let merged = AppleContinueWatchingRemovalPolicy.merged(["a": older, "b": newer], ["a": newer, "b": older, "c": older])
        #expect(merged == ["a": newer, "b": newer, "c": older])
    }

    @MainActor @Test func removingKeepsProgressAndHistoryAndSurvivesRelaunch() throws {
        let (store, defaults) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        store.save(mediaID: "fixture-film", position: 600, duration: 6_000)
        store.save(mediaID: "fixture-other", position: 900, duration: 6_000)
        store.removeFromContinueWatching(mediaID: "fixture-film")

        #expect(store.isRemovedFromContinueWatching(mediaID: "fixture-film"))
        #expect(!store.isRemovedFromContinueWatching(mediaID: "fixture-other"))
        #expect(store.progress(for: "fixture-film")?.resumePosition == 600)
        #expect(!store.isWatched(mediaID: "fixture-film"))
        #expect(ApplePlaybackStore(defaults: defaults).isRemovedFromContinueWatching(mediaID: "fixture-film"))
    }

    @MainActor @Test func playingItAgainBringsItBack() throws {
        let (store, defaults) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        store.save(mediaID: "fixture-film", position: 600, duration: 6_000)
        store.removeFromContinueWatching(mediaID: "fixture-film")
        #expect(store.isRemovedFromContinueWatching(mediaID: "fixture-film"))

        store.save(mediaID: "fixture-film", position: 660, duration: 6_000)
        #expect(!store.isRemovedFromContinueWatching(mediaID: "fixture-film"))
        #expect(store.configurationContinueWatchingRemovals().isEmpty)
    }

    @MainActor @Test func removalsTravelWithTheConfigurationSnapshot() throws {
        let (store, defaults) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let removedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = AppleConfigurationSnapshot(
            continueWatchingRemovals: [try #require(ApplePlaybackIdentity.storageKey(for: "fixture-film")): removedAt])
        let decoded = try JSONDecoder().decode(
            AppleConfigurationSnapshot.self, from: AppleConfigurationSnapshot.encoder.encode(snapshot))
        #expect(decoded.continueWatchingRemovals == snapshot.continueWatchingRemovals)

        store.restoreConfigurationContinueWatchingRemovals(decoded.continueWatchingRemovals)
        #expect(store.isRemovedFromContinueWatching(mediaID: "fixture-film"))

        let older = AppleConfigurationSnapshot()
        let olderData = try AppleConfigurationSnapshot.encoder.encode(older)
        #expect(!String(decoding: olderData, as: UTF8.self).contains("continueWatchingRemovals"))
        #expect(try JSONDecoder().decode(AppleConfigurationSnapshot.self, from: olderData)
            .continueWatchingRemovals.isEmpty)
    }
}
