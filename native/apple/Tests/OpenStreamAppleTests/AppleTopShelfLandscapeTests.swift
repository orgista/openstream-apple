import Foundation
import Testing
@testable import OpenStreamApple

/// N48: Top Shelf tiles go 16:9 with the title's backdrop, as the Apple TV
/// app's do, when every tile in the row has one.
struct AppleTopShelfLandscapeTests {
    private func item(_ id: String, poster: String? = nil, backdrop: String? = nil) -> AppleTopShelfSnapshot.Item {
        .init(
            id: id, title: id, kind: "movie",
            artworkURL: poster.flatMap { URL(string: "https://image.tmdb.org/t/p/w500/\($0).jpg") },
            displayURL: URL(string: "openstream://media/\(id)?action=display")!, playURL: nil,
            landscapeArtworkURL: backdrop.flatMap { URL(string: "https://image.tmdb.org/t/p/w1280/\($0).jpg") }
        )
    }

    private func temporaryContainer() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "openstream-topshelf-landscape-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func landscapeArtworkRoundTrips() throws {
        let value = item("a", poster: "poster", backdrop: "backdrop")
        let snapshot = AppleTopShelfSnapshot(version: 1, generatedAt: .now, continueWatching: [value],
                                             recentlyAdded: [], favorites: [], topPicks: [value])
        let decoded = try JSONDecoder().decode(AppleTopShelfSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded.continueWatching == [value])
        #expect(decoded.topPicks.first?.landscapeArtworkURL == value.landscapeArtworkURL)
    }

    @Test func snapshotsWrittenBeforeTheFieldDecodeWithNoLandscapeArt() throws {
        let legacyJSON = """
        {"version":1,"generatedAt":0,"continueWatching":[{"id":"a","title":"A","kind":"movie",\
        "artworkURL":"https://image.tmdb.org/t/p/w500/a.jpg","displayURL":"openstream://media/a?action=display",\
        "progress":0.4}],"recentlyAdded":[],"favorites":[],"topPicks":[]}
        """
        let decoded = try JSONDecoder().decode(AppleTopShelfSnapshot.self, from: Data(legacyJSON.utf8))
        let value = try #require(decoded.continueWatching.first)
        #expect(value.landscapeArtworkURL == nil)
        #expect(value.progress == 0.4)
        let section = try #require(AppleTopShelfContentBuilder.sections(for: decoded).first)
        #expect(section.imageShape == .poster)
        #expect(section.imageURL(for: value) == value.artworkURL)
    }

    @Test func aRowWhereEveryTileHasABackdropIsLandscape() {
        let section = AppleTopShelfSection(title: "Top Picks",
                                           items: [item("a", poster: "a", backdrop: "a-wide"), item("b", backdrop: "b-wide")])
        #expect(section.imageShape == .hdtv)
        #expect(section.items.map(section.imageURL(for:)) == section.items.map(\.landscapeArtworkURL))
    }

    @Test func aMixedRowStaysPostersAndFallsBackToTheBackdropOnlyWithoutAPoster() {
        let withBoth = item("a", poster: "a", backdrop: "a-wide")
        let posterOnly = item("b", poster: "b")
        let backdropOnly = item("c", backdrop: "c-wide")
        let section = AppleTopShelfSection(title: "Continue Watching", items: [withBoth, posterOnly, backdropOnly])
        #expect(section.imageShape == .poster)
        #expect(section.imageURL(for: withBoth) == withBoth.artworkURL)
        #expect(section.imageURL(for: posterOnly) == posterOnly.artworkURL)
        #expect(section.imageURL(for: backdropOnly) == backdropOnly.landscapeArtworkURL)
    }

    @Test func writerTakesContinueWatchingBackdropsFromTheMatchingCatalogItem() async throws {
        let root = try temporaryContainer()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = AppleSource(kind: .stremio, name: "Cinemeta",
                                 url: URL(string: "https://fixture.example/manifest.json")!)
        let backdrop = URL(string: "https://image.tmdb.org/t/p/w1280/wide.jpg")!
        let catalogItems = [
            AppleCatalogItem(mediaID: "tt0000001", type: "series", name: "Wide",
                             posterURL: URL(string: "https://image.tmdb.org/t/p/w500/tall.jpg"),
                             backgroundURL: backdrop),
            AppleCatalogItem(mediaID: "tt0000002", type: "movie", name: "Private Backdrop",
                             backgroundURL: URL(string: "https://nas.local/backdrop.jpg")),
        ]
        let sections = [AppleCatalogSection(source: source, catalog: AppleStremioCatalog(type: "movie", id: "top"),
                                            items: catalogItems)]
        var records = catalogItems.map { AppleMediaIngestion.catalogRecord(instanceID: source.id, item: $0) }
        var unmatched = AppleMediaIngestion.catalogRecord(
            instanceID: source.id, item: AppleCatalogItem(mediaID: "tt0000003", type: "movie", name: "Unlisted")
        )
        unmatched.progress = 0.2
        records[0].progress = 0.6
        records[1].progress = 0.4
        records.append(unmatched)

        // Most recently watched first (N52), so the order is stated outright.
        let now = Date.now
        let watchedAt = Dictionary(uniqueKeysWithValues: records.enumerated().map {
            ($1.id, now.addingTimeInterval(-Double($0) * 60))
        })

        let writer = AppleTopShelfSnapshotWriter(containerProvider: { root })
        try await writer.write(records: records, sections: sections, watchedAt: watchedAt, enabled: true)
        let snapshot = try #require(AppleTopShelfSnapshotReader(containerProvider: { root }).read())

        #expect(snapshot.continueWatching.map(\.title) == ["Wide", "Private Backdrop", "Unlisted"])
        #expect(snapshot.continueWatching.map(\.landscapeArtworkURL) == [backdrop, nil, nil])
        #expect(snapshot.topPicks.map(\.landscapeArtworkURL) == [backdrop, nil])
        // Other shelves stay posters only.
        #expect(snapshot.favorites.allSatisfy { $0.landscapeArtworkURL == nil })
        #expect(snapshot.recentlyAdded.allSatisfy { $0.landscapeArtworkURL == nil })
    }

    @Test func aLaterShelfWithABackdropStillSuppliesIt() async throws {
        let root = try temporaryContainer()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = AppleSource(kind: .stremio, name: "Cinemeta",
                                 url: URL(string: "https://fixture.example/manifest.json")!)
        let backdrop = URL(string: "https://image.tmdb.org/t/p/w1280/wide.jpg")!
        let bare = AppleCatalogItem(mediaID: "tt0000001", type: "series", name: "Wide")
        let withBackdrop = AppleCatalogItem(mediaID: "tt0000001", type: "series", name: "Wide", backgroundURL: backdrop)
        let sections = [
            AppleCatalogSection(source: source, catalog: AppleStremioCatalog(type: "series", id: "new"), items: [bare]),
            AppleCatalogSection(source: source, catalog: AppleStremioCatalog(type: "series", id: "top"), items: [withBackdrop]),
        ]
        var record = AppleMediaIngestion.catalogRecord(instanceID: source.id, item: bare)
        record.progress = 0.5

        let writer = AppleTopShelfSnapshotWriter(containerProvider: { root })
        try await writer.write(records: [record], sections: sections, enabled: true)
        let snapshot = try #require(AppleTopShelfSnapshotReader(containerProvider: { root }).read())

        #expect(snapshot.continueWatching.map(\.landscapeArtworkURL) == [backdrop])
    }
}
