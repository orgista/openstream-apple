import Foundation
import Synchronization
import Testing
@testable import OpenStreamApple

/// The shared snapshot is the only thing the Top Shelf provider and the
/// iOS/iPadOS widgets can see — they are separate processes with no access to
/// the app's own container. These cover the round trip through the app group
/// file, which is what a widget actually does.
@Suite("Widget snapshot")
struct AppleWidgetSnapshotTests {
    private func temporaryContainer() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "widget-snapshot-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func record(_ title: String, progress: Double?, favorite: Bool = false) -> AppleMediaRecord {
        var value = AppleMediaRecord(
            canonicalID: title,
            kind: .movie,
            title: title,
            artworkURL: URL(string: "https://image.tmdb.org/t/p/w500/x.jpg"),
            availability: [.init(instanceID: UUID(), capability: .direct, itemReference: title)]
        )
        value.progress = progress
        value.isFavorite = favorite
        return value
    }

    @Test func artworkStagingDoesNotNotifyUntilTheCompletedSnapshotIsSaved() async throws {
        let root = temporaryContainer()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = AppleTopShelfSnapshotWriter.snapshotURL(in: root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let notifications = Mutex<[AppleTopShelfSnapshot?]>([])
        let writer = AppleTopShelfSnapshotWriter(containerProvider: { root },
            snapshotLocation: { AppleTopShelfSnapshotWriter.snapshotURL(in: $0) },
            artwork: nil, trailerFiles: nil, didChange: {
                let snapshot = AppleTopShelfSnapshotReader(containerProvider: { root }).read()
                notifications.withLock { $0.append(snapshot) }
            })
        var snapshot = AppleTopShelfSnapshot(version: 1, generatedAt: .now,
            continueWatching: [], recentlyAdded: [], favorites: [])
        try await writer.save(snapshot, to: url, notify: false)
        #expect(notifications.withLock { $0.isEmpty })
        #expect(AppleTopShelfSnapshotReader(containerProvider: { root }).read() == snapshot)

        snapshot.widgetHero = AppleWidgetHeroArtwork(itemID: "fixture", backdropFile: "fixture.jpg", wordmarkFile: nil)
        try await writer.save(snapshot, to: url)
        #expect(notifications.withLock { $0 } == [snapshot])
    }

    @Test func aPublishNotifiesOnce() async throws {
        let root = temporaryContainer()
        defer { try? FileManager.default.removeItem(at: root) }
        try await confirmation(expectedCount: 1) { changed in
            let writer = AppleTopShelfSnapshotWriter(containerProvider: { root },
                snapshotLocation: { AppleTopShelfSnapshotWriter.snapshotURL(in: $0) },
                artwork: nil, trailerFiles: nil, didChange: { changed() })
            try await writer.write(records: [], enabled: true)
        }
    }

    @Test func unchangedStagingPreservesTheFileAndNotifiesOnlyForNewContent() async throws {
        let root = temporaryContainer()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = AppleTopShelfSnapshotWriter.snapshotURL(in: root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let changes = Mutex(0)
        let writer = AppleTopShelfSnapshotWriter(containerProvider: { root },
            snapshotLocation: { AppleTopShelfSnapshotWriter.snapshotURL(in: $0) },
            artwork: nil, trailerFiles: nil, didChange: { changes.withLock { $0 += 1 } })
        let first = AppleTopShelfSnapshot(version: 1, generatedAt: Date(timeIntervalSince1970: 1),
            continueWatching: [], recentlyAdded: [], favorites: [])
        #expect(try await writer.save(first, to: url, notify: false))
        #expect(changes.withLock { $0 } == 0)
        #expect(try await writer.save(first, to: url))
        #expect(changes.withLock { $0 } == 1)
        let original = try Data(contentsOf: url)

        let unchanged = AppleTopShelfSnapshot(version: 1, generatedAt: Date(timeIntervalSince1970: 2),
            continueWatching: [], recentlyAdded: [], favorites: [])
        #expect(try await writer.save(unchanged, to: url, notify: false) == false)
        #expect(try await writer.save(unchanged, to: url) == false)
        #expect(changes.withLock { $0 } == 1)
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func aWidgetReadsWhatTheAppWrote() async throws {
        let root = temporaryContainer()
        let writer = AppleTopShelfSnapshotWriter(containerProvider: { root })
        try await writer.write(
            records: [record("Halfway", progress: 0.4), record("Fresh", progress: nil)],
            enabled: true
        )

        let snapshot = AppleTopShelfSnapshotReader(containerProvider: { root }).read()
        #expect(snapshot != nil)
        #expect(snapshot?.continueWatching.map(\.title) == ["Halfway"])
        #expect(snapshot?.recentlyAdded.isEmpty == false)
    }

    /// A widget on a device where the app has never run, or with the group
    /// container unavailable, gets nil and draws its empty state rather than
    /// crashing.
    @Test func noSnapshotReadsAsNil() {
        #expect(AppleTopShelfSnapshotReader(containerProvider: { self.temporaryContainer() }).read() == nil)
        #expect(AppleTopShelfSnapshotReader(containerProvider: { nil }).read() == nil)
    }

    /// Turning the feature off removes the file, so the widget empties out
    /// rather than showing what the viewer just opted out of.
    @Test func disablingClearsWhatTheWidgetCanSee() async throws {
        let root = temporaryContainer()
        let writer = AppleTopShelfSnapshotWriter(containerProvider: { root })
        try await writer.write(records: [record("Halfway", progress: 0.4)], enabled: true)
        #expect(AppleTopShelfSnapshotReader(containerProvider: { root }).read() != nil)

        try await writer.write(records: [record("Halfway", progress: 0.4)], enabled: false)
        #expect(AppleTopShelfSnapshotReader(containerProvider: { root }).read() == nil)
    }

    @Test func optOutSurvivesRelaunchAndEnableDisableCycles() async throws {
        let root = temporaryContainer()
        defer { try? FileManager.default.removeItem(at: root) }
        let changes = Mutex(0)
        func writer() -> AppleTopShelfSnapshotWriter {
            AppleTopShelfSnapshotWriter(containerProvider: { root },
                snapshotLocation: { AppleTopShelfSnapshotWriter.snapshotURL(in: $0) },
                artwork: nil, trailerFiles: nil, didChange: { changes.withLock { $0 += 1 } })
        }
        let first = writer()
        #expect(try await first.write(records: [], enabled: false) == false)
        #expect(try await first.write(records: [], enabled: false) == false)
        #expect(try await writer().write(records: [], enabled: false) == false)
        #expect(changes.withLock { $0 } == 0)
        #expect(try await first.write(records: [], enabled: true))
        #expect(changes.withLock { $0 } == 1)
        #expect(try await writer().write(records: [], enabled: false))
        #expect(changes.withLock { $0 } == 2)
        #expect(try await first.write(records: [], enabled: false) == false)
        #expect(try await first.write(records: [], enabled: true))
        #expect(try await first.write(records: [], enabled: false))
        #expect(try await writer().write(records: [], enabled: false) == false)
        #expect(changes.withLock { $0 } == 4)
    }

    /// Artwork a widget renders must be a plain https URL on a trusted host —
    /// never a credentialed or query-carrying URL from a private source.
    @Test func widgetArtworkIsOnlyEverPublic() async throws {
        let root = temporaryContainer()
        var private_ = record("Private", progress: 0.5)
        private_.artworkURL = URL(string: "https://192.168.1.95:8090/art.jpg?token=abc")
        let writer = AppleTopShelfSnapshotWriter(containerProvider: { root })
        try await writer.write(records: [private_], enabled: true)

        let snapshot = AppleTopShelfSnapshotReader(containerProvider: { root }).read()
        #expect(snapshot?.continueWatching.first?.artworkURL == nil)
    }
}
