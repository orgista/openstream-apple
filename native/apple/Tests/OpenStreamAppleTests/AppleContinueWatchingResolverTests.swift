import Foundation
import Testing
@testable import OpenStreamApple

/// N52: Continue Watching order, the progress bar Discover and the Top Shelf
/// share, and the backdrop a record keeps.
struct AppleContinueWatchingResolverTests {
    private let sourceID = UUID()
    private let listed = AppleCatalogItem(
        mediaID: "tt0000101", type: "series", name: "Harbor Lights",
        posterURL: URL(string: "https://fixture.example/harbor-poster.jpg"),
        backgroundURL: URL(string: "https://fixture.example/harbor-wide.jpg"),
        releaseInfo: "2021"
    )
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// A catalog record the index kept, part-way through.
    private func record(_ item: AppleCatalogItem, progress: Double = 0.4) -> AppleMediaRecord {
        var value = AppleMediaIngestion.catalogRecord(instanceID: sourceID, item: item)
        value.progress = progress
        return value
    }

    private func unlisted(_ mediaID: String, name: String, backdrop: Bool = true) -> AppleCatalogItem {
        AppleCatalogItem(
            mediaID: mediaID, type: "movie", name: name,
            posterURL: URL(string: "https://fixture.example/\(mediaID)-poster.jpg"),
            backgroundURL: backdrop ? URL(string: "https://fixture.example/\(mediaID)-wide.jpg") : nil
        )
    }

    // MARK: Order

    @Test(arguments: [0, 11, 12, 13, 30])
    func fullListActionExistsOnlyBeyondRailCap(count: Int) {
        let entries = Array(0..<count)
        #expect(AppleContinueWatchingResolver.rail(entries) == Array(entries.prefix(12)))
        #expect(AppleContinueWatchingResolver.hasFullList(count: count) == (count > 12))
        #expect(entries.count == count)
    }

    @Test func listsOnlyUnfinishedTitlesMostRecentlyWatchedFirst() {
        let older = record(listed, progress: 0.9)
        let newer = record(unlisted("tt0000102", name: "Night Train"), progress: 0.1)
        let finished = record(unlisted("tt0000103", name: "Done"), progress: 0.97)
        let unstarted = record(unlisted("tt0000104", name: "Unstarted"), progress: 0)
        let watchedAt = [older.id: now.addingTimeInterval(-3_600), newer.id: now,
                         finished.id: now, unstarted.id: now]

        let ordered = AppleContinueWatchingResolver.inProgress([older, finished, unstarted, newer]) {
            watchedAt[$0.id] ?? .distantPast
        }

        #expect(ordered.map(\.id) == [newer.id, older.id])
    }

    // MARK: The bar (N59)

    /// A series' bar is the episode Resume plays, not the record's copy made
    /// at the last index sync.
    @Test func aSeriesBarIsTheSavedEpisodes() throws {
        let saved = ApplePlaybackProgress(position: 1_200, duration: 2_400, partID: "tt0000101:1:3")
        let value = try #require(AppleContinueWatchingResolver.progress(isSeries: true, saved: saved,
                                                                        recordProgress: 0.0003))
        #expect(abs(value - 0.5) < 0.0001)
    }

    /// The episode finished: the store drops the show's entry, or it names no
    /// episode to resume. Play starts the next episode from the beginning, so
    /// there is no bar, whatever the record's stale copy says.
    @Test func aSeriesWithNothingToResumeHasNoBar() {
        let finished = ApplePlaybackProgress(position: 2_390, duration: 2_400, partID: "tt0000101:1:3")
        let unnamed = ApplePlaybackProgress(position: 1_200, duration: 2_400)
        #expect(AppleContinueWatchingResolver.progress(isSeries: true, saved: nil, recordProgress: 0.5) == nil)
        #expect(AppleContinueWatchingResolver.progress(isSeries: true, saved: finished, recordProgress: 0.5) == nil)
        #expect(AppleContinueWatchingResolver.progress(isSeries: true, saved: unnamed, recordProgress: 0.5) == nil)
    }

    @Test func aFilmBarIsUnchanged() throws {
        let saved = ApplePlaybackProgress(position: 600, duration: 2_400)
        let value = try #require(AppleContinueWatchingResolver.progress(isSeries: false, saved: saved,
                                                                        recordProgress: 0.1))
        #expect(abs(value - 0.25) < 0.0001)
        #expect(AppleContinueWatchingResolver.progress(isSeries: false, saved: nil, recordProgress: 0.4) == 0.4)
    }

    @Test func noDataHasNoBar() {
        #expect(AppleContinueWatchingResolver.progress(isSeries: true, saved: nil, recordProgress: nil) == nil)
        #expect(AppleContinueWatchingResolver.progress(isSeries: false, saved: nil, recordProgress: nil) == nil)
    }

    /// The Top Shelf draws the same bar as Discover when given the store.
    @Test func theTopShelfBarFollowsTheSavedEpisode() async throws {
        let series = record(listed, progress: 0.0003)
        let film = record(unlisted("tt0000110", name: "Night Train"), progress: 0.4)
        let root = FileManager.default.temporaryDirectory
            .appending(path: "openstream-continue-bar-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = AppleTopShelfSnapshotWriter(containerProvider: { root })
        let saved = [series.id: ApplePlaybackProgress(position: 1_200, duration: 2_400, updatedAt: now,
                                                      partID: "tt0000101:1:3")]
        try await writer.write(records: [series, film], watchedAt: [series.id: now],
                               savedProgress: saved, enabled: true)
        let snapshot = try #require(AppleTopShelfSnapshotReader(containerProvider: { root }).read())
        let bars = Dictionary(uniqueKeysWithValues: snapshot.continueWatching.map { ($0.id, $0.progress) })
        #expect(bars[series.id] == 0.5)
        #expect(bars[film.id] == 0.4)
    }

    // MARK: The saved backdrop

    @Test func aCatalogRecordSavesTheItemsBackdrop() {
        #expect(record(listed).backdropURL == listed.backgroundURL)
    }

    @Test func aRecordWrittenBeforeBackdropsDecodesWithNone() throws {
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(record(listed))) as? [String: Any])
        json.removeValue(forKey: "backdropURL")
        let decoded = try JSONDecoder().decode(AppleMediaRecord.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.backdropURL == nil)
        #expect(decoded.id == record(listed).id)
    }
}
