import Foundation
import Testing
@testable import OpenStreamApple

@MainActor
struct ApplePlaybackBlobStorageTests {
    /// Apple TV keeps playback maps in defaults and reads them from a copy;
    /// a write by any path must show on the next read.
    @Test func defaultsBackedReadsSeeEveryWriteAtOnce() throws {
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "openstream.playback.progress.v1"
        let storage = ApplePlaybackBlobStorage(defaults: defaults, directory: nil)
        #expect(storage.data(forKey: key) == nil)

        let first = Data("{\"a\":1}".utf8)
        storage.set(first, forKey: key)
        #expect(storage.data(forKey: key) == first)

        let direct = Data("{\"a\":2}".utf8)
        defaults.set(direct, forKey: key)
        #expect(storage.data(forKey: key) == direct)

        let other = ApplePlaybackBlobStorage(defaults: defaults, directory: nil)
        other.removeObject(forKey: key)
        #expect(storage.data(forKey: key) == nil)
    }

    @Test func verifiedMigrationRetainsExactLegacyDataAndSurvivesReopen() throws {
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let key = "openstream.playback.terminals.v1"
        let data = try JSONEncoder().encode(["owner": ApplePlaybackTerminalEvents(playedAt: Date(timeIntervalSince1970: 100))])
        defaults.set(data, forKey: key)
        let storage = ApplePlaybackBlobStorage(defaults: defaults, directory: root)
        #expect(storage.data(forKey: key) == data)
        #expect(defaults.data(forKey: key) == nil)
        let reopened = ApplePlaybackBlobStorage(defaults: defaults, directory: root)
        #expect(reopened.data(forKey: key) == data)
        try Data("broken".utf8).write(to: storage.fileURL(forKey: key))
        #expect(ApplePlaybackBlobStorage(defaults: defaults, directory: root).data(forKey: key) == data)
    }

    @Test func repeatedReadsDoNotRewriteRegisteredDefaults() throws {
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let key = "registered-playback"
        let data = Data("{}".utf8)
        // Argument/registration domains cannot be retired with removeObject.
        defaults.register(defaults: [key: data])
        let storage = ApplePlaybackBlobStorage(defaults: defaults, directory: root)
        #expect(storage.data(forKey: key) == data)
        let sentinel = Data("unchanged-by-a-read".utf8)
        try sentinel.write(to: storage.fileURL(forKey: key))
        for _ in 0..<10 { #expect(storage.data(forKey: key) == data) }
        #expect(try Data(contentsOf: storage.fileURL(forKey: key)) == sentinel)
        let newer = Data("{\"owner\":42}".utf8)
        storage.set(newer, forKey: key)
        #expect(storage.data(forKey: key) == newer)
        #expect(ApplePlaybackBlobStorage(defaults: defaults, directory: root).data(forKey: key) == newer)
    }

    @Test func failedFileWriteRetainsDefaultsAndPlayback() throws {
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        try Data([0]).write(to: root)
        let key = "owner-progress"
        let data = try JSONEncoder().encode(["owner": ApplePlaybackProgress(position: 300, duration: 3000)])
        defaults.set(data, forKey: key)
        let storage = ApplePlaybackBlobStorage(defaults: defaults, directory: root)
        #expect(storage.data(forKey: key) == data)
        #expect(defaults.data(forKey: key) == data)
        storage.set(data, forKey: key)
        #expect(defaults.data(forKey: key) == data)
    }

    @Test func aFailedUpdateNeverLetsAnOlderFileReplaceNewerDefaults() throws {
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let aside = root.appendingPathExtension("saved")
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: aside)
        }
        let key = "owner-progress"
        let old = Data("{\"position\":20}".utf8)
        let newer = Data("{\"position\":40}".utf8)
        let storage = ApplePlaybackBlobStorage(defaults: defaults, directory: root)
        storage.set(old, forKey: key)
        try FileManager.default.moveItem(at: root, to: aside)
        try Data([0]).write(to: root)
        storage.set(newer, forKey: key)
        #expect(storage.data(forKey: key) == newer)
        #expect(defaults.data(forKey: key) == newer)
        try FileManager.default.removeItem(at: root)
        try FileManager.default.moveItem(at: aside, to: root)
        let reopened = ApplePlaybackBlobStorage(defaults: defaults, directory: root)
        #expect(reopened.data(forKey: key) == newer)
        reopened.set(newer, forKey: key)
        #expect(defaults.data(forKey: key) == nil)
        #expect(ApplePlaybackBlobStorage(defaults: defaults, directory: root).data(forKey: key) == newer)
    }

    @Test func fileBackedStorePreservesAllPlaybackMapsAndBoundsEpisodeCache() async throws {
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let store = ApplePlaybackStore(defaults: defaults, blobDirectory: root)
        store.save(mediaID: "tt1", position: 300, duration: 3000)
        store.markWatched(mediaID: "tt2")
        store.restoreConfigurationPlaybackActivity(Dictionary(uniqueKeysWithValues: (0..<205).map {
            ("tt\($0)", ApplePlaybackProgress(position: 300, duration: 3000, updatedAt: Date(timeIntervalSince1970: Double($0))))
        }))
        let saved = store.configurationProgress()
        let watched = store.configurationWatchedHistory()
        let terminals = store.configurationPlaybackTerminals()
        for index in 0..<205 {
            await store.recordEpisodes([.init(id: "tt\(index):1:1", title: "", season: 1, episode: 1,
                releaseInfo: "2099-01-01T23:15:00Z")], mediaID: "tt\(index)")
        }
        #expect(await store.availableEpisodes().count <= 200)
        let showKey = try #require(ApplePlaybackIdentity.storageKey(for: "tt1"))
        #expect(await store.availableEpisodes()[showKey]?.first?.releaseInfo == "2099-01-01T23:15:00Z")
        let reopened = ApplePlaybackStore(defaults: defaults, blobDirectory: root)
        #expect(reopened.configurationProgress() == saved)
        #expect(reopened.configurationWatchedHistory() == watched)
        #expect(reopened.configurationPlaybackTerminals() == terminals)
        #expect(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("openstream.playback.") }.isEmpty)
    }
}
