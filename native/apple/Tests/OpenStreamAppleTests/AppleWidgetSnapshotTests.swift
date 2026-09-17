import Foundation
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
