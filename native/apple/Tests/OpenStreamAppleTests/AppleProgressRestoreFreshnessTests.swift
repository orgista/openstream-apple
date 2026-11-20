import Foundation
import Testing
@testable import OpenStreamApple

/// V6: resume uses the freshest of local vs. a restored/synced snapshot.
/// V10: a 10k-title history restores in bounded time and memory.
@Suite("Progress restore freshness and scale")
struct AppleProgressRestoreFreshnessTests {
    private func makeDefaults() throws -> (UserDefaults, String) {
        let name = "progress-freshness.\(UUID())"
        return (try #require(UserDefaults(suiteName: name)), name)
    }

    @MainActor @Test func anOlderSnapshotNeverWindsALocalResumeBack() throws {
        let (defaults, name) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = ApplePlaybackStore(defaults: defaults)
        store.save(mediaID: "fresh", position: 900, duration: 3_600)
        store.save(mediaID: "stale", position: 100, duration: 3_600)
        let fresh = try #require(ApplePlaybackIdentity.storageKey(for: "fresh"))
        let stale = try #require(ApplePlaybackIdentity.storageKey(for: "stale"))
        let other = try #require(ApplePlaybackIdentity.storageKey(for: "other"))
        let past = Date(timeIntervalSinceNow: -3_600)
        ApplePlaybackStore(defaults: defaults).restoreConfigurationProgress([
            fresh: .init(position: 300, duration: 3_600, updatedAt: past),
            stale: .init(position: 2_000, duration: 3_600, updatedAt: Date(timeIntervalSinceNow: 60)),
            other: .init(position: 50, duration: 100, updatedAt: past),
        ])
        #expect(store.progress(for: "fresh")?.position == 900)
        #expect(store.progress(for: "stale")?.position == 2_000)
        #expect(store.progress(for: "other")?.position == 50)
    }

    @Test func snapshotMergeKeepsTheFreshestPositionPerTitle() {
        let past = Date(timeIntervalSince1970: 1_000)
        let now = Date(timeIntervalSince1970: 2_000)
        let mine = AppleConfigurationSnapshot(playbackProgress: [
            "a": .init(position: 10, duration: 1_000, updatedAt: now),
            "b": .init(position: 10, duration: 1_000, updatedAt: past),
        ])
        let theirs = AppleConfigurationSnapshot(playbackProgress: [
            "a": .init(position: 90, duration: 1_000, updatedAt: past),
            "b": .init(position: 90, duration: 1_000, updatedAt: now),
            "c": .init(position: 5, duration: 1_000, updatedAt: past),
        ])
        let merged = mine.merging(theirs).playbackProgress
        #expect(merged["a"]?.position == 10)
        #expect(merged["b"]?.position == 90)
        #expect(merged["c"]?.position == 5)
    }

    @MainActor @Test(.timeLimit(.minutes(1))) func tenThousandTitlesRestoreInBoundedTime() throws {
        let (defaults, name) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        var progress: [String: ApplePlaybackProgress] = [:]
        var watched: [String: Date] = [:]
        for index in 0 ..< 10_000 {
            let key = "tt\(1_000_000 + index):1:\(index % 24)"
            progress[key] = .init(position: Double(index % 3_000), duration: 3_600,
                                  updatedAt: Date(timeIntervalSince1970: Double(index)))
            watched[key] = Date(timeIntervalSince1970: Double(index) - 1)
        }
        let snapshot = AppleConfigurationSnapshot(playbackProgress: progress, watchedHistory: watched)
        let clock = ContinuousClock()
        let elapsed = try clock.measure {
            let data = try JSONEncoder().encode(snapshot)
            let decoded = try JSONDecoder().decode(AppleConfigurationSnapshot.self, from: data)
            let store = ApplePlaybackStore(defaults: defaults)
            store.restoreConfigurationProgress(decoded.playbackProgress)
            store.restoreConfigurationWatchedHistory(decoded.watchedHistory, tombstones: decoded.watchedTombstones)
            #expect(store.configurationProgress().count == 10_000)
            _ = try decoded.cloudData()
        }
        #expect(elapsed < .seconds(10), "10k-title restore took \(elapsed)")
    }
}
