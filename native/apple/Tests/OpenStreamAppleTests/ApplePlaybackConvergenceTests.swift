import Foundation
import Testing
@testable import OpenStreamApple

struct ApplePlaybackConvergenceTests {
    private let old = Date(timeIntervalSince1970: 100)
    private let terminal = Date(timeIntervalSince1970: 200)
    private let later = Date(timeIntervalSince1970: 300)

    @Test(arguments: [false, true]) func completionBlocksOldProgressAndUnwatchPreservesResume(reset: Bool) {
        let events = ApplePlaybackTerminalEvents(completedAt: reset ? nil : terminal, resetAt: reset ? terminal : nil)
        let finished = AppleConfigurationSnapshot(playbackTerminals: ["film": events])
        let offline = AppleConfigurationSnapshot(playbackProgress: ["film": .init(position: 600, duration: 3600, updatedAt: old)])
        #expect(finished.merging(offline).playbackProgress.isEmpty == (reset == false))
        #expect(offline.merging(finished).playbackProgress.isEmpty == (reset == false))
        let rewind = AppleConfigurationSnapshot(playbackProgress: ["film": .init(position: 30, duration: 3600, updatedAt: later)])
        #expect(finished.merging(rewind).playbackProgress["film"]?.position == 30)
        #expect(rewind.merging(finished).playbackProgress["film"]?.position == 30)
    }


    @Test func finishingAnEpisodePreservesAnotherEpisodesResumeInEitherMergeOrder() {
        let resume = ApplePlaybackProgress(position: 1200, duration: 3600, updatedAt: old, partID: "show:2:4")
        let completed = ApplePlaybackProgress(position: 3590, duration: 3600, updatedAt: terminal, partID: "show:1:1")
        let tv = AppleConfigurationSnapshot(playbackProgress: ["show": resume])
        // Includes the old-format show terminal to verify existing owner snapshots remain readable.
        let phone = AppleConfigurationSnapshot(playbackTerminals: ["show": .init(completedAt: terminal, playedAt: terminal)],
            playbackActivity: ["show": completed])
        #expect(tv.merging(phone).playbackProgress["show"] == resume)
        #expect(phone.merging(tv).playbackProgress["show"] == resume)
        let sameEpisode = AppleConfigurationSnapshot(playbackProgress: ["show": .init(position: 1200, duration: 3600,
            updatedAt: old, partID: "show:1:1")])
        #expect(sameEpisode.merging(phone).playbackProgress.isEmpty)
    }

    @MainActor @Test func episodeSaveRecordsCompletionUnderTheFinishedPart() throws {
        let name = "playback-episode.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = ApplePlaybackStore(defaults: defaults)
        store.save(mediaID: "show", position: 3590, duration: 3600, partID: "show:1:1")
        let show = try #require(ApplePlaybackIdentity.storageKey(for: "show"))
        let episode = try #require(ApplePlaybackIdentity.storageKey(for: "show:1:1"))
        #expect(store.configurationPlaybackTerminals()[show]?.completedAt == nil)
        #expect(store.configurationPlaybackTerminals()[episode]?.completedAt != nil)
    }

    @MainActor @Test func localSaveSurvivesAFutureRemoteClockAndRepeatedRestore() throws {
        let name = "playback-clock.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = ApplePlaybackStore(defaults: defaults)
        let key = try #require(ApplePlaybackIdentity.storageKey(for: "film"))
        let future = Date(timeIntervalSinceNow: 180)
        store.restoreConfigurationPlaybackTerminals([key: .init(playedAt: future)])
        store.save(mediaID: "film", position: 2400, duration: 3600)
        let saved = try #require(store.progress(for: "film"))
        #expect(saved.updatedAt > future)
        #expect(store.lastActivity(for: "film") == saved)
        store.restoreConfigurationPlaybackTerminals([key: .init(playedAt: future)])
        let reloaded = ApplePlaybackStore(defaults: defaults)
        #expect(reloaded.progress(for: "film") == saved)
        #expect(reloaded.activities()[key] == saved)
    }

    @MainActor @Test func unwatchPreservesAnUnfinishedRewatchAfterRelaunch() throws {
        let name = "playback-unwatch.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = ApplePlaybackStore(defaults: defaults)
        store.markWatched(mediaID: "show:1:1", at: old)
        store.save(mediaID: "show", position: 1200, duration: 3600, partID: "show:1:1")
        store.markUnwatched(mediaID: "show:1:1", at: Date(timeIntervalSinceNow: 60))
        let reloaded = ApplePlaybackStore(defaults: defaults)
        #expect(reloaded.isWatched(mediaID: "show:1:1") == false)
        #expect(reloaded.progress(for: "show")?.position == 1200)
        #expect(reloaded.lastActivity(for: "show")?.position == 1200)
    }

    @MainActor @Test func cachedTerminalsFollowSavesAndAnotherStoresChanges() throws {
        let name = "playback-cache.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = ApplePlaybackStore(defaults: defaults)
        store.save(mediaID: "film", position: 1200, duration: 3600)
        let key = try #require(ApplePlaybackIdentity.storageKey(for: "film"))
        #expect(store.configurationPlaybackTerminals()[key]?.playedAt == store.progress(for: "film")?.updatedAt)
        store.save(mediaID: "film", position: 3590, duration: 3600)
        #expect(store.configurationPlaybackTerminals()[key]?.completedAt == store.lastActivity(for: "film")?.updatedAt)
        let future = Date(timeIntervalSinceNow: 180)
        ApplePlaybackStore(defaults: defaults).markUnwatched(mediaID: "film", at: future)
        #expect(store.configurationPlaybackTerminals()[key]?.resetAt == future)
        #expect(store.isWatched(mediaID: "film") == false)
    }

    @MainActor @Test func immediateLocalUserEventsFollowMonotonicPlaybackClock() throws {
        let name = "playback-events.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = ApplePlaybackStore(defaults: defaults)
        let film = try #require(ApplePlaybackIdentity.storageKey(for: "film"))
        store.restoreConfigurationPlaybackTerminals([film: .init(playedAt: Date(timeIntervalSinceNow: 180))])
        store.save(mediaID: "film", position: 1200, duration: 3600)
        store.save(mediaID: "film", position: 1500, duration: 3600)
        store.removeFromContinueWatching(mediaID: "film")
        #expect(store.isRemovedFromContinueWatching(mediaID: "film"))
        store.save(mediaID: "film", position: 3590, duration: 3600)
        #expect(store.isRemovedFromContinueWatching(mediaID: "film") == false)
        store.markUnwatched(mediaID: "film")
        #expect(store.isWatched(mediaID: "film") == false)
        #expect(store.lastActivity(for: "film") == nil)
        store.markWatched(mediaID: "film")
        #expect(store.isWatched(mediaID: "film"))
        let key = try #require(ApplePlaybackIdentity.storageKey(for: "historical"))
        let historical = Date(timeIntervalSince1970: 1)
        store.removeFromContinueWatching(mediaID: "historical", at: historical)
        #expect(store.configurationPlaybackTerminals()[key]?.removedAt == historical)
    }

    @Test func equalTimestampProgressMergesDeterministically() {
        let a = AppleConfigurationSnapshot(playbackProgress: ["film": .init(position: 20, duration: 3600, updatedAt: old)])
        let b = AppleConfigurationSnapshot(playbackProgress: ["film": .init(position: 60, duration: 3600, updatedAt: old)])
        #expect(a.merging(b).playbackProgress == b.merging(a).playbackProgress)
    }

    @Test func equalClocksDistinguishAbsentAndEmptyPart() {
        let a = ApplePlaybackProgress(position: 60, duration: 3600, updatedAt: old)
        let b = ApplePlaybackProgress(position: 60, duration: 3600, updatedAt: old, partID: "")
        #expect(ApplePlaybackConvergence.freshest(a, b) == ApplePlaybackConvergence.freshest(b, a))
    }

    @Test(arguments: [false, true]) func cloudTrimRetainsPlaybackClockAndNeverRestoresOldPartial(hadRemoval: Bool) throws {
        var progress = Dictionary(uniqueKeysWithValues: (0..<500).map {
            ("new-\($0)", ApplePlaybackProgress(position: 30, duration: 3600, updatedAt: later.addingTimeInterval(Double($0 + 1))))
        })
        progress["film"] = .init(position: 60, duration: 3600, updatedAt: later)
        let snapshot = AppleConfigurationSnapshot(playbackProgress: progress,
            continueWatchingRemovals: hadRemoval ? ["film": terminal] : [:],
            playbackTerminals: hadRemoval ? ["film": .init(removedAt: terminal)] : [:], playbackActivity: progress)
        let cloud = try JSONDecoder().decode(AppleConfigurationSnapshot.self, from: snapshot.cloudData())
        #expect(cloud.playbackProgress["film"] == nil)
        #expect(cloud.playbackActivity["film"] == nil)
        #expect(cloud.playbackTerminals["film"]?.playedAt == later)
        let offline = AppleConfigurationSnapshot(playbackProgress: ["film": .init(position: 900, duration: 3600, updatedAt: old)])
        #expect(cloud.merging(offline).playbackProgress["film"] == nil)
        #expect(offline.merging(cloud).playbackProgress["film"] == nil)
        #expect(AppleContinueWatchingRemovalPolicy.isRemoved(removedAt: cloud.playbackTerminals["film"]?.removedAt,
            lastPlayedAt: cloud.playbackTerminals["film"]?.playedAt) == false)
    }

    @MainActor @Test func resetAndCompletionSurviveOldBackupAndRelaunch() throws {
        let name = "playback-convergence.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = ApplePlaybackStore(defaults: defaults)
        let key = try #require(ApplePlaybackIdentity.storageKey(for: "film"))
        store.save(mediaID: "film", position: 3590, duration: 3600)
        store.restoreConfigurationProgress([key: .init(position: 600, duration: 3600, updatedAt: old)])
        #expect(store.progress(for: "film") == nil)
        store.save(mediaID: "film", position: 30, duration: 3600)
        #expect(store.progress(for: "film")?.position == 30)
        store.clear(mediaID: "film")
        let reloaded = ApplePlaybackStore(defaults: defaults)
        reloaded.restoreConfigurationProgress([key: .init(position: 600, duration: 3600, updatedAt: old)])
        #expect(reloaded.progress(for: "film") == nil)
        #expect(reloaded.lastActivity(for: "film") == nil)
        #expect(reloaded.hasLocalPlaybackState(mediaID: "film"))
    }

    @MainActor @Test func legacyCompleteEpisodeMigratesWatchedPartAndLaterRewatchWinsReset() throws {
        let name = "playback-convergence.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = ApplePlaybackStore(defaults: defaults)
        let show = try #require(ApplePlaybackIdentity.storageKey(for: "show"))
        let completed = ApplePlaybackProgress(position: 3590, duration: 3600, updatedAt: old, partID: "show:1:1")
        store.restoreConfigurationProgress([show: completed])
        #expect(store.isWatched(mediaID: "show:1:1"))
        #expect(store.progress(for: "show") == nil)
        store.markUnwatched(mediaID: "show:1:1", at: terminal)
        #expect(store.activities().isEmpty)
        store.restoreConfigurationProgress([show: completed])
        #expect(store.isWatched(mediaID: "show:1:1") == false)
        #expect(store.lastActivity(for: "show") == nil)
        store.restoreConfigurationProgress([show: .init(position: 3590, duration: 3600, updatedAt: later, partID: "show:1:1")])
        #expect(store.isWatched(mediaID: "show:1:1"))
    }

    @MainActor @Test func legacyWatchedAndUnwatchedReconcileInEitherRestoreOrder() throws {
        let key = try #require(ApplePlaybackIdentity.storageKey(for: "film"))
        for progressFirst in [true, false] {
            let name = "playback-convergence.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: name))
            defer { defaults.removePersistentDomain(forName: name) }
            let store = ApplePlaybackStore(defaults: defaults)
            if progressFirst { store.restoreConfigurationProgress([key: .init(position: 600, duration: 3600, updatedAt: old)]) }
            store.restoreConfigurationWatchedHistory([key: terminal])
            if progressFirst == false { store.restoreConfigurationProgress([key: .init(position: 600, duration: 3600, updatedAt: old)]) }
            #expect(store.progress(for: "film") == nil)
            store.markUnwatched(mediaID: "film", at: later)
            store.restoreConfigurationProgress([key: .init(position: 600, duration: 3600, updatedAt: terminal)])
            #expect(store.progress(for: "film") == nil)
        }
    }

    @MainActor @Test func existingDefaultsMigrateBeforeAnyCloudRead() throws {
        let name = "playback-convergence.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let finished = try #require(ApplePlaybackIdentity.storageKey(for: "finished"))
        let reset = try #require(ApplePlaybackIdentity.storageKey(for: "reset"))
        let fresh = try #require(ApplePlaybackIdentity.storageKey(for: "fresh"))
        let show = try #require(ApplePlaybackIdentity.storageKey(for: "show"))
        let entries: [String: ApplePlaybackProgress] = [
            finished: .init(position: 60, duration: 3600, updatedAt: old),
            reset: .init(position: 60, duration: 3600, updatedAt: old),
            fresh: .init(position: 30, duration: 3600, updatedAt: later),
            show: .init(position: 3590, duration: 3600, updatedAt: old, partID: "show:1:1")
        ]
        defaults.set(try JSONEncoder().encode(entries), forKey: "openstream.playback.progress.v1")
        defaults.set(try JSONEncoder().encode([finished: terminal]), forKey: "openstream.playback.watched.v1")
        defaults.set(try JSONEncoder().encode([reset: terminal, fresh: terminal]), forKey: "openstream.playback.unwatched.v1")
        let store = ApplePlaybackStore(defaults: defaults)
        #expect(store.progress(for: "finished") == nil)
        #expect(store.progress(for: "reset")?.position == 60)
        #expect(store.progress(for: "fresh")?.position == 30)
        #expect(store.isWatched(mediaID: "show:1:1"))
        #expect(store.isWatched(mediaID: "show") == false)
        #expect(store.lastActivity(for: "show")?.partID == "show:1:1")
        #expect(store.configurationPlaybackActivity()[show]?.isComplete == true)
        #expect(store.configurationProgress().count == 2)
        let terminals = try #require(defaults.data(forKey: "openstream.playback.terminals.v1"))
        _ = ApplePlaybackStore(defaults: defaults)
        #expect(defaults.data(forKey: "openstream.playback.terminals.v1") == terminals)
    }

    @MainActor @Test func retiredLegacyResetAndRemovalRemainEffective() throws {
        let name = "playback-convergence.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = ApplePlaybackStore(defaults: defaults)
        let key = try #require(ApplePlaybackIdentity.storageKey(for: "film"))
        let resets = Dictionary(uniqueKeysWithValues: (0...ApplePlaybackStore.watchedHistoryLimit).map {
            ("reset-\($0)", terminal.addingTimeInterval(Double($0 + 1)))
        }).merging([key: terminal]) { max($0, $1) }
        store.restoreConfigurationWatchedHistory([:], tombstones: resets)
        #expect(store.configurationWatchedTombstones()[key] == nil)
        store.restoreConfigurationWatchedHistory([key: old])
        #expect(store.isWatched(mediaID: "film") == false)
        #expect(store.configurationWatchedHistory()[key] == nil)
        let snapshot = AppleConfigurationSnapshot(playbackTerminals: [key: .init(resetAt: terminal)])
        let stale = AppleConfigurationSnapshot(watchedHistory: [key: old])
        #expect(snapshot.merging(stale).watchedHistory[key] == nil)
        #expect(stale.merging(snapshot).watchedHistory[key] == nil)
        store.restoreConfigurationWatchedHistory([key: terminal.addingTimeInterval(6000)])
        #expect(store.isWatched(mediaID: "film"))
        let removals = Dictionary(uniqueKeysWithValues: (0...ApplePlaybackStore.continueWatchingRemovalLimit).map {
            ("remove-\($0)", terminal.addingTimeInterval(Double($0 + 1)))
        }).merging([key: terminal]) { max($0, $1) }
        store.restoreConfigurationContinueWatchingRemovals(removals)
        #expect(store.configurationContinueWatchingRemovals()[key] == terminal)
    }

    @Test func removalAndLaterRewatchConvergeAfterCloudActivityTrimming() throws {
        let snapshot = AppleConfigurationSnapshot(playbackProgress: ["film": .init(position: 60, duration: 3600, updatedAt: later)],
            continueWatchingRemovals: ["film": terminal], playbackTerminals: ["film": .init(removedAt: terminal)])
        let cloud = try JSONDecoder().decode(AppleConfigurationSnapshot.self, from: snapshot.cloudData())
        let oldDevice = AppleConfigurationSnapshot(playbackProgress: ["film": .init(position: 900, duration: 3600, updatedAt: old)])
        let merged = oldDevice.merging(cloud)
        #expect(merged.playbackProgress["film"]?.position == 60)
        #expect(AppleContinueWatchingRemovalPolicy.isRemoved(removedAt: merged.playbackTerminals["film"]?.removedAt,
            lastPlayedAt: merged.playbackProgress["film"]?.updatedAt) == false)
    }

    @Test func cloudTerminalHorizonUnionsNewestLinkedPartsAndRecentClocks() throws {
        let newest = Dictionary(uniqueKeysWithValues: (0..<2000).map {
            ("new-\($0)", ApplePlaybackTerminalEvents(resetAt: Date(timeIntervalSince1970: Double(1000 + $0))))
        })
        let part = "linked-part"
        let normalizedPart = try #require(ApplePlaybackIdentity.storageKey(for: part))
        let events = newest.merging([
            part: .init(resetAt: old.addingTimeInterval(-100)),
            normalizedPart: .init(resetAt: old.addingTimeInterval(-100)),
            "recent-clock": .init(completedAt: terminal),
            "obsolete": .init(resetAt: old.addingTimeInterval(-101))
        ]) { $0.merging($1) }
        let active = ApplePlaybackProgress(position: 60, duration: 3600, updatedAt: old, partID: part)
        let snapshot = AppleConfigurationSnapshot(playbackProgress: ["show": active], playbackTerminals: events,
            playbackActivity: ["show": active])
        let data = try snapshot.cloudData()
        let cloud = try JSONDecoder().decode(AppleConfigurationSnapshot.self, from: data)
        #expect(Set(newest.keys).isSubset(of: Set(cloud.playbackTerminals.keys)))
        #expect(cloud.playbackTerminals[part] != nil)
        #expect(cloud.playbackTerminals[normalizedPart] != nil)
        #expect(cloud.playbackTerminals["recent-clock"] != nil)
        #expect(cloud.playbackTerminals["obsolete"] == nil)
        #expect(cloud.playbackProgress["show"] == active)
        #expect(cloud.playbackActivity["show"] == active)
        #expect(try snapshot.cloudData() == data)
    }

    @Test(.timeLimit(.minutes(1))) func twentyThousandFinishedTitlesFitCloudAndKeepNewestActivity() throws {
        let suffix = String(repeating: "x", count: 600)
        let finished = Dictionary(uniqueKeysWithValues: (0..<20_000).map {
            ("episode-\($0)-\(suffix)", Date(timeIntervalSince1970: Double($0)))
        })
        let recent = Dictionary(uniqueKeysWithValues: (0..<3).map {
            ("active-\($0)", ApplePlaybackProgress(position: Double(60 + $0), duration: 3600,
                updatedAt: Date(timeIntervalSince1970: Double(30_000 + $0)),
                partID: "episode-\($0)-" + String(repeating: "p", count: 3000)))
        })
        let snapshot = AppleConfigurationSnapshot(playbackProgress: recent, watchedHistory: finished, playbackActivity: recent)
        let data = try snapshot.cloudData()
        let cloud = try JSONDecoder().decode(AppleConfigurationSnapshot.self, from: data)
        #expect(data.count <= AppleConfigurationSnapshot.maximumCloudBytes)
        #expect(cloud.playbackTerminals.count <= AppleConfigurationSnapshot.cloudTerminalLimit)
        #expect(cloud.playbackTerminals["episode-19999-\(suffix)"]?.completedAt == Date(timeIntervalSince1970: 19999))
        #expect(cloud.playbackTerminals["episode-0-\(suffix)"] == nil)
        #expect(cloud.playbackProgress == recent)
        #expect(cloud.playbackActivity == recent)
        #expect(snapshot.watchedHistory.count == 20_000)
    }

    @Test(arguments: [600.0, 3590.0]) func retiredCloudBarrierRemovesStateThatWouldRegenerateItOnDecode(position: Double) throws {
        let key = "old-show"
        let episode = "old-episode"
        let episodeKey = try #require(ApplePlaybackIdentity.storageKey(for: episode))
        let progress = ApplePlaybackProgress(position: position, duration: 3600, updatedAt: old, partID: episode)
        let newest = Dictionary(uniqueKeysWithValues: (0..<2000).map {
            ("new-\($0)-" + String(repeating: "n", count: 700), ApplePlaybackTerminalEvents(resetAt: later.addingTimeInterval(Double($0))))
        })
        let terminals = newest.merging([key: .init(removedAt: terminal), episodeKey: .init(completedAt: terminal, removedAt: terminal)]) { $0.merging($1) }
        let snapshot = AppleConfigurationSnapshot(playbackProgress: [key: progress], watchedHistory: [episodeKey: old],
            continueWatchingRemovals: [key: old], playbackTerminals: terminals, playbackActivity: [key: progress])
        let data = try snapshot.cloudData()
        let cloud = try JSONDecoder().decode(AppleConfigurationSnapshot.self, from: data)
        #expect(cloud.playbackTerminals[key] == nil)
        #expect(cloud.playbackTerminals[episodeKey] == nil)
        #expect(cloud.playbackProgress[key] == nil)
        #expect(cloud.playbackActivity[key] == nil)
        #expect(cloud.watchedHistory[episodeKey] == nil)
        #expect(cloud.continueWatchingRemovals[key] == nil)
        let decodedAgain = try JSONDecoder().decode(AppleConfigurationSnapshot.self, from: cloud.cloudData())
        #expect(decodedAgain.playbackTerminals[key] == nil)
        #expect(decodedAgain.playbackTerminals[episodeKey] == nil)
    }

    @Test func cloudKeepsTerminalHistoryWithinHorizonAndOldFormatsDefaultSafely() throws {
        let events = Dictionary(uniqueKeysWithValues: (0..<600).map { ("film-\($0)", ApplePlaybackTerminalEvents(resetAt: terminal)) })
        let snapshot = AppleConfigurationSnapshot(playbackTerminals: events)
        let cloud = try JSONDecoder().decode(AppleConfigurationSnapshot.self, from: snapshot.cloudData())
        #expect(cloud.playbackTerminals == events)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(AppleConfigurationSnapshot())) as? [String: Any])
        object.removeValue(forKey: "playbackTerminals")
        object.removeValue(forKey: "playbackActivity")
        let oldFormat = try JSONDecoder().decode(AppleConfigurationSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(oldFormat.playbackTerminals.isEmpty)
        #expect(oldFormat.playbackActivity.isEmpty)
    }
}
