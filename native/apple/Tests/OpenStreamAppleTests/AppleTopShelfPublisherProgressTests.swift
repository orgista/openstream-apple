import Foundation
import Testing
@testable import OpenStreamApple

/// Review of 2b1f930: the Top Shelf bar follows the playback store, so a
/// new saved position republishes even when the media records are unchanged.
@MainActor
struct AppleTopShelfPublisherProgressTests {
    @Test func aNewSavedPositionRepublishesWithUnchangedRecords() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "openstream-topshelf-publisher-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "openstream-topshelf-publisher-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let source = AppleSource(kind: .stremio, name: "Cinemeta",
                                 url: URL(string: "https://fixture.example/manifest.json")!)
        let item = AppleCatalogItem(mediaID: "tt0000001", type: "series", name: "Series")
        let sections = [AppleCatalogSection(source: source, catalog: AppleStremioCatalog(type: "series", id: "top"),
                                            items: [item])]
        var record = AppleMediaIngestion.catalogRecord(instanceID: source.id, item: item)
        record.progress = 0.2
        let store = ApplePlaybackStore(defaults: defaults)
        let publisher = AppleTopShelfPublisher(writer: AppleTopShelfSnapshotWriter(containerProvider: { root }))
        let reader = AppleTopShelfSnapshotReader(containerProvider: { root })

        store.save(mediaID: record.id, position: 600, duration: 3000, partID: "tt0000001:1:1")
        await publisher.publish(records: [record], sections: sections, sources: [source], enabled: true, playbackStore: store)
        let first = try #require(reader.read()?.continueWatching.first?.progress)
        #expect(abs(first - 0.2) < 0.001)

        store.save(mediaID: record.id, position: 1500, duration: 3000, partID: "tt0000001:1:1")
        await publisher.publish(records: [record], sections: sections, sources: [source], enabled: true, playbackStore: store)
        let second = try #require(reader.read()?.continueWatching.first?.progress)
        #expect(abs(second - 0.5) < 0.001)
    }
}
