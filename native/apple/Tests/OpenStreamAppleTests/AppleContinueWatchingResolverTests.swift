import Foundation
import Testing
@testable import OpenStreamApple

/// N52: Continue Watching dropped a title in progress once no loaded shelf
/// listed it. Discover's row and the Top Shelf now resolve every record the
/// same way Search does, so they list the same titles, and hide — with a
/// logged reason — only the ones nothing can open.
struct AppleContinueWatchingResolverTests {
    private let catalog = AppleStremioCatalog(type: "series", id: "fixture-continue")
    private let source: AppleSource
    private let listed = AppleCatalogItem(
        mediaID: "tt0000101", type: "series", name: "Harbor Lights",
        posterURL: URL(string: "https://fixture.example/harbor-poster.jpg"),
        backgroundURL: URL(string: "https://fixture.example/harbor-wide.jpg"),
        releaseInfo: "2021"
    )
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    init() {
        source = AppleSource(kind: .stremio, name: "Fixture", url: URL(string: "https://fixture.example/manifest.json")!,
                             resources: ["catalog"], catalogs: [catalog])
    }

    private var sections: [AppleCatalogSection] {
        [.init(source: source, catalog: catalog, items: [listed])]
    }

    private func lookup(sources: [AppleSource]? = nil) -> AppleCatalogSearchLookup {
        AppleCatalogSearchLookup(sections: sections, sources: sources ?? [source])
    }

    /// A catalog record the index kept, part-way through.
    private func record(_ item: AppleCatalogItem, progress: Double = 0.4) -> AppleMediaRecord {
        var value = AppleMediaIngestion.catalogRecord(instanceID: source.id, item: item)
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

    private func localFile(progress: Double) -> AppleMediaRecord {
        AppleMediaRecord(kind: .video, title: "Home Movie",
                         availability: [.init(instanceID: UUID(), capability: .direct,
                                              itemReference: "http://127.0.0.1/home.mkv")],
                         progress: progress)
    }

    // MARK: Order

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

    // MARK: Each case

    @Test func aListedTitleOpensItsListedItem() {
        let resolution = AppleContinueWatchingResolver.resolve(record(listed), in: [lookup()])
        #expect(resolution == .listed(AppleCatalogSearchMatch(item: listed, source: source)))
    }

    /// The finding itself: off every shelf, still in progress, still shown —
    /// on the same record id, so the progress pill finds its position.
    @Test func anUnlistedTitleWithAnIMDbIDIsRebuiltWithItsSavedArt() throws {
        let item = unlisted("tt0000105", name: "Night Train")
        let value = record(item)

        let match = try #require(AppleContinueWatchingResolver.resolve(value, in: [lookup()]).match)

        #expect(AppleContinueWatchingResolver.resolve(value, in: [lookup()]) == .rebuilt(match))
        #expect(match.source.id == source.id)
        #expect(match.item.name == "Night Train")
        #expect(match.item.backgroundURL == item.backgroundURL)
        #expect(match.item.posterURL == item.posterURL)
        #expect(AppleMediaIngestion.catalogRecord(instanceID: source.id, item: match.item).id == value.id)
    }

    /// A record saved before backdrops were kept still draws a still: the
    /// image service's backdrop for its IMDb id, then its poster.
    @Test func aRecordWithoutASavedBackdropFallsBackToTheImageServiceStill() throws {
        let item = unlisted("tt0000106", name: "Old Record", backdrop: false)
        let match = try #require(AppleContinueWatchingResolver.resolve(record(item), in: [lookup()]).match)

        let candidates = AppleCatalogArtworkPolicy.candidates(item: match.item, landscape: true)
        #expect(candidates.first == AppleCatalogArtworkPolicy.imageServiceURL(kind: "background", mediaID: "tt0000106"))
        #expect(candidates.dropFirst().first == item.posterURL)
    }

    /// A merged record keeps the id of a copy no shelf lists; the listed item
    /// its other source names opens.
    @Test func aMergedRecordOpensTheListedItemOfItsOtherSource() throws {
        let otherSource = AppleSource(kind: .stremio, name: "Other", url: URL(string: "https://fixture.example/other.json")!,
                                      resources: ["catalog"], catalogs: [catalog])
        let dropped = AppleCatalogItem(mediaID: "fixture:harbor", type: "series", name: "Harbor Lights")
        var value = AppleMediaIngestion.catalogRecord(instanceID: otherSource.id, item: dropped)
        value.availability += AppleMediaIngestion.catalogRecord(instanceID: source.id, item: listed).availability
        value.progress = 0.5
        let lookup = AppleCatalogSearchLookup(sections: sections, sources: [source, otherSource])

        #expect(lookup.match(for: value.id) == nil)
        #expect(AppleContinueWatchingResolver.resolve(value, in: [lookup])
            == .listed(AppleCatalogSearchMatch(item: listed, source: source)))
    }

    @Test(arguments: [false, true])
    func aTitleWhoseAddOnIsDisabledOrRemovedIsHidden(removed: Bool) {
        var disabled = source
        disabled.isEnabled = false
        let lookup = AppleCatalogSearchLookup(sections: sections, sources: removed ? [] : [disabled])

        let resolution = AppleContinueWatchingResolver.resolve(record(listed), in: [lookup])

        #expect(resolution == .unavailable(.sourceUnavailable))
    }

    @Test func anUnlistedTitleWithOnlyAnAddOnIDIsHidden() {
        let value = record(AppleCatalogItem(mediaID: "kitsu:fixture-7", type: "series", name: "Add-on Only"))
        #expect(AppleContinueWatchingResolver.resolve(value, in: [lookup()]) == .unavailable(.unlistedWithoutIMDbID))
    }

    @Test func aLocalFileIsNotACatalogTitle() {
        #expect(AppleContinueWatchingResolver.resolve(localFile(progress: 0.3), in: [lookup()]) == .notCatalog)
    }

    /// Two records that open the same title are one tile: the more recent.
    @Test func twoRecordsOpeningTheSameTitleKeepTheMoreRecent() {
        let fresh = record(listed)
        var merged = AppleMediaIngestion.catalogRecord(
            instanceID: UUID(), item: AppleCatalogItem(mediaID: "fixture:other-copy", type: "series", name: "Harbor Lights")
        )
        merged.availability += fresh.availability
        merged.progress = 0.2

        let entries = AppleContinueWatchingResolver.entries([merged, fresh], in: [lookup()])

        #expect(entries.map(\.record.id) == [merged.id])
    }

    // MARK: Discover and the Top Shelf agree

    /// One fixture of every case: Discover's row (entries that open a title
    /// page, as `AppleDiscoverView.continueWatching` builds it) and the Top
    /// Shelf list the same catalog titles in the same order; the Top Shelf
    /// adds the local file, which Library's Continue Watching lists.
    @Test func discoverAndTheTopShelfListTheSameTitles() async throws {
        var disabledSource = AppleSource(kind: .stremio, name: "Off", url: URL(string: "https://fixture.example/off.json")!,
                                         resources: ["catalog"], catalogs: [catalog])
        disabledSource.isEnabled = false
        let sources = [source, disabledSource]
        let listedRecord = record(listed)
        let rebuilt = record(unlisted("tt0000107", name: "Night Train"))
        let rebuiltWithoutBackdrop = record(unlisted("tt0000108", name: "Old Record", backdrop: false))
        let addOnOnly = record(AppleCatalogItem(mediaID: "kitsu:fixture-8", type: "series", name: "Add-on Only"))
        var fromDisabled = AppleMediaIngestion.catalogRecord(instanceID: disabledSource.id,
                                                             item: unlisted("tt0000109", name: "Switched Off"))
        fromDisabled.progress = 0.6
        let file = localFile(progress: 0.3)
        let records = [listedRecord, rebuilt, addOnOnly, fromDisabled, file, rebuiltWithoutBackdrop]
        let watchedAt = Dictionary(uniqueKeysWithValues: records.enumerated().map {
            ($1.id, now.addingTimeInterval(-Double($0) * 60))
        })

        let ordered = AppleContinueWatchingResolver.inProgress(records) { watchedAt[$0.id] ?? .distantPast }
        let lookup = AppleCatalogSearchLookup(sections: sections, sources: sources)
        let discover = AppleContinueWatchingResolver.entries(ordered, in: [lookup])
            .filter { $0.resolution.match != nil }
            .map(\.record.id)

        let root = FileManager.default.temporaryDirectory
            .appending(path: "openstream-continue-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = AppleTopShelfSnapshotWriter(containerProvider: { root })
        try await writer.write(records: records, sections: sections, sources: sources,
                               watchedAt: watchedAt, enabled: true)
        let snapshot = try #require(AppleTopShelfSnapshotReader(containerProvider: { root }).read())

        #expect(discover == [listedRecord.id, rebuilt.id, rebuiltWithoutBackdrop.id])
        #expect(snapshot.continueWatching.map(\.id) == [listedRecord.id, rebuilt.id, file.id, rebuiltWithoutBackdrop.id])
        #expect(snapshot.continueWatching.filter { $0.id != file.id }.map(\.id) == discover)
        // Landscape art: the listed backdrop, the backdrop saved with the
        // record, and nothing for the old record — never the image service,
        // whose URL carries the IMDb id.
        #expect(snapshot.continueWatching.map(\.landscapeArtworkURL) == [
            listed.backgroundURL, URL(string: "https://fixture.example/tt0000107-wide.jpg"), nil, nil,
        ])
        let text = String(decoding: try Data(contentsOf: root.appending(path: AppleTopShelfSnapshotWriter.filename)),
                          as: UTF8.self)
        #expect(!text.contains("metahub"))
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
        try await writer.write(records: [series, film], sections: sections, watchedAt: [series.id: now],
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

    /// Re-listing a title from a shelf that carries no backdrop keeps the one
    /// the record already had.
    @Test func reingestingWithoutABackdropKeepsTheSavedOne() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "openstream-continue-index-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = AppleMediaIndexRepository(fileURL: root.appending(path: "index.json"))
        let bare = AppleCatalogItem(mediaID: listed.mediaID, type: "series", name: listed.name)

        try await repository.replaceCatalog(instanceID: source.id, with: [record(listed)])
        try await repository.replaceCatalog(instanceID: source.id,
                                            with: [AppleMediaIngestion.catalogRecord(instanceID: source.id, item: bare)])

        #expect(await repository.records().first?.backdropURL == listed.backgroundURL)
    }
}
