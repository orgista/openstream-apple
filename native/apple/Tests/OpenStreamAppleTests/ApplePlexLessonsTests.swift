import Foundation
import Testing
@testable import OpenStreamApple

struct ApplePlexLessonsTests {
    @Test func incompleteScansRetainRecordsAndCompleteScansDelete() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = AppleMediaIndexRepository(fileURL: directory.appendingPathComponent("index.json"))
        let source = UUID()
        let records = (0..<10_001).map { AppleMediaRecord(canonicalID: "file-\($0)", kind: .video,
            title: "File \($0)", availability: [.init(instanceID: source, capability: .direct, itemReference: "\($0)")]) }
        try await repository.replace(instanceID: source, with: records)
        #expect(await repository.records().count == 10_001)
        let stamp = await repository.lastSuccessfulScan(for: source)
        for status in [AppleLibraryScanStatus.partial, .failed] {
            try await repository.replace(instanceID: source, with: [], scanStatus: status)
            #expect(await repository.records().count == 10_001)
            #expect(await repository.lastSuccessfulScan(for: source) == stamp)
            #expect(await repository.records().allSatisfy { $0.availability.allSatisfy { $0.isStale == true } })
        }
        try await repository.replace(instanceID: source, with: [records[0]], scanStatus: .complete)
        #expect(await repository.records().count == 1)
        #expect(await repository.lastSuccessfulScan(for: source) != nil)
        let reopened = AppleMediaIndexRepository(fileURL: directory.appendingPathComponent("index.json"))
        #expect(await reopened.lastSuccessfulScan(for: source) != nil)
    }

    @Test func localLimitIsPartialAndUnreachableRootFails() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<5_001 { FileManager.default.createFile(atPath: root.appendingPathComponent("\(index).mp4").path, contents: Data()) }
        let source = AppleSource(kind: .library, name: "Fixture", url: root)
        let result = await AppleLibraryScanner().scanResult(source: source)
        #expect(result.status == .partial)
        #expect(result.items.count == 5_000)
        let missing = AppleSource(kind: .library, name: "Missing", url: root.appendingPathComponent("missing"))
        #expect(await AppleLibraryScanner().scanResult(source: missing).status == .failed)
    }

    @MainActor @Test func completedSaveRetainsActivityAndOffersOnlyAvailableSuccessor() async throws {
        let name = "plex-lessons-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = ApplePlaybackStore(defaults: defaults)
        let episodes = [AppleMediaEpisode(id: "tt1234567:1:1", title: "One", season: 1, episode: 1),
                        AppleMediaEpisode(id: "tt1234567:1:2", title: "Two", season: 1, episode: 2)]
        let source = UUID()
        let record = AppleMediaRecord(canonicalID: "tt1234567", kind: .series, title: "Fixture",
            availability: [.init(instanceID: source, capability: .resolvable, itemReference: "fixture")])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = AppleMediaIndexRepository(fileURL: directory.appendingPathComponent("index.json"))
        try await repository.replace(instanceID: source, with: [record])
        await store.recordEpisodes(episodes, mediaID: record.id)
        store.save(mediaID: record.id, position: 980, duration: 1_000, partID: episodes[0].id)
        #expect(store.progress(for: record.id) == nil)
        try await repository.updateProgress([:])
        let synchronized = await repository.records()
        #expect(synchronized.first?.progress == nil)
        let activity = try #require(store.lastActivity(for: record.id))
        let completed = store.completedMediaIDs(among: episodes.map(\.id))
        #expect(AppleCompletionPolicy.successor(after: activity.partID, episodes: episodes, completedIDs: completed)?.id == episodes[1].id)
        #expect(AppleContinueWatchingResolver.inProgress(synchronized, activity: { _ in activity },
            successorAvailable: { _ in AppleCompletionPolicy.successor(after: activity.partID,
                episodes: episodes, completedIDs: completed) != nil }, watchedAt: { _ in activity.updatedAt }).count == 1)
        #expect(AppleContinueWatchingResolver.progress(isSeries: true, saved: activity, recordProgress: nil) == nil)
        store.save(mediaID: record.id, position: 980, duration: 1_000, partID: episodes[1].id)
        let finished = try #require(store.lastActivity(for: record.id))
        #expect(AppleCompletionPolicy.successor(after: finished.partID, episodes: episodes,
            completedIDs: store.completedMediaIDs(among: episodes.map(\.id))) == nil)
        #expect(AppleContinueWatchingResolver.inProgress([record], activity: { _ in finished },
            successorAvailable: { _ in false }, watchedAt: { _ in finished.updatedAt }).isEmpty)
        store.removeFromContinueWatching(mediaID: record.id)
        #expect(store.isRemovedFromContinueWatching(mediaID: record.id))
        #expect(ApplePlaybackStore(defaults: defaults).lastActivity(for: record.id) == finished)
        await store.recordEpisodes([], mediaID: record.id)
        let known = await store.availableEpisodes()
        let key = try #require(ApplePlaybackIdentity.storageKey(for: record.id))
        #expect(known[key]?.isEmpty == true)
    }

    @Test func cancelledLocalScanRetainsPreviousSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = AppleSource(kind: .library, name: "Fixture", url: root)
        let previous = AppleLibraryItem(sourceID: source.id, name: "Movie", url: source.url.appendingPathComponent("movie.mp4"),
            relativePath: "movie.mp4", sizeBytes: 0)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await AppleLibraryScanner().scanResult(source: source)
        }
        let result = await task.value
        #expect(result.status == .failed)
        #expect(result.retaining([previous]) == [previous])
    }

    @Test func completeScanRemovesAGenuinelyDeletedFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("one.mp4")
        let second = root.appendingPathComponent("two.mp4")
        try Data().write(to: first)
        try Data().write(to: second)
        let source = AppleSource(kind: .library, name: "Fixture", url: root)
        let scanner = AppleLibraryScanner()
        let before = await scanner.scanResult(source: source)
        #expect(before.status == .complete)
        try FileManager.default.removeItem(at: second)
        let after = await scanner.scanResult(source: source)
        #expect(after.status == .complete)
        #expect(after.retaining(before.items).map(\.relativePath) == ["one.mp4"])
    }

    @Test(arguments: [(0.0, 20.0, false), (90.0, 100.0, true), (89.0, 100.0, false), (819.0, 1000.0, false),
                      (950.0, 1000.0, true), (1969.0, 2000.0, true)])
    func completionBoundaries(_ value: (Double, Double, Bool)) {
        #expect(AppleCompletionPolicy.isComplete(position: value.0, duration: value.1) == value.2)
        #expect(ApplePlaybackProgress(position: value.0, duration: value.1).isComplete == value.2)
    }

    @Test func specialsAndFutureSuccessorsDoNotKeepFinishedRegularSeries() {
        let episodes = [AppleMediaEpisode(id: "special", title: "", season: 0, episode: 1),
                        AppleMediaEpisode(id: "regular", title: "", season: 1, episode: 1),
                        AppleMediaEpisode(id: "future", title: "", season: 1, episode: 2, releaseInfo: "2099-01-01")]
        #expect(AppleCompletionPolicy.successor(after: "regular", episodes: episodes, completedIDs: ["regular"]) == nil)
        let specials = [AppleMediaEpisode(id: "a", title: "", season: 0, episode: 1),
                        AppleMediaEpisode(id: "b", title: "", season: 0, episode: 2)]
        #expect(AppleCompletionPolicy.successor(after: "a", episodes: specials, completedIDs: ["a"])?.id == "b")
    }

    @Test func providerWatchedFlagOverridesLocalCompletion() {
        #expect(AppleCompletionPolicy.isComplete(position: 1, duration: 1_000, providerWatched: true))
        #expect(AppleCompletionPolicy.isComplete(position: 999, duration: 1_000, providerWatched: false) == false)
    }
}
