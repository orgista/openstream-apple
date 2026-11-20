import Foundation
import Testing
@testable import OpenStreamApple

/// The full-screen Top Shelf carousel (owner 2026-10-15, Apple TV 4K): the
/// Apple TV app's shelf, backdrops edge to edge, Continue Watching then Top
/// Picks, no progress bars.
@Suite("Top Shelf carousel")
struct AppleTopShelfCarouselTests {
    private func item(_ id: String, backdrop: Bool = true, progress: Double? = nil) -> AppleTopShelfSnapshot.Item {
        .init(
            id: id, title: id.uppercased(), kind: "movie",
            artworkURL: URL(string: "https://image.tmdb.org/t/p/w500/\(id).jpg"),
            displayURL: URL(string: "openstream://media/\(id)?action=display")!,
            playURL: URL(string: "openstream://media/\(id)?action=play"),
            progress: progress,
            landscapeArtworkURL: backdrop ? URL(string: "https://image.tmdb.org/t/p/original/\(id)-wide.jpg") : nil
        )
    }

    private func snapshot(continueWatching: [AppleTopShelfSnapshot.Item],
                          topPicks: [AppleTopShelfSnapshot.Item]) -> AppleTopShelfSnapshot {
        AppleTopShelfSnapshot(version: 1, generatedAt: .now, continueWatching: continueWatching,
                              recentlyAdded: [], favorites: [], topPicks: topPicks)
    }

    @Test("Continue Watching comes first, then Recently Added, each title once, only titles with a backdrop")
    func mapping() {
        let pages = AppleTopShelfContentBuilder.carouselItems(for: snapshot(
            continueWatching: [item("a", progress: 0.4), item("b", backdrop: false, progress: 0.7)],
            topPicks: [item("a"), item("c"), item("d")]))
        #expect(pages.map(\.item.id) == ["a", "c", "d"])
        #expect(pages.map(\.contextTitle) == ["Continue Watching", "Recently Added", "Recently Added"])
        #expect(pages.map(\.imageURL) == pages.map(\.item.landscapeArtworkURL))
        #expect(pages.allSatisfy { $0.imageURL?.absoluteString.hasSuffix("-wide.jpg") == true })
        #expect(pages[0].item.playURL?.absoluteString == "openstream://media/a?action=play")
        #expect(pages[0].item.displayURL.absoluteString == "openstream://media/a?action=display")
    }

    @Test("No backdrop anywhere leaves the carousel empty and the rows serve instead")
    func fallsBackToRows() {
        let value = snapshot(continueWatching: [item("a", backdrop: false)], topPicks: [item("b", backdrop: false)])
        #expect(AppleTopShelfContentBuilder.carouselItems(for: value).isEmpty)
        #expect(AppleTopShelfContentBuilder.sections(for: value).map(\.title) == ["Continue Watching", "Recently Added"])
    }

    @Test("The carousel stays short")
    func capped() {
        let pages = AppleTopShelfContentBuilder.carouselItems(for: snapshot(
            continueWatching: (0..<8).map { item("c\($0)") }, topPicks: (0..<10).map { item("t\($0)") }))
        #expect(pages.count == AppleTopShelfContentBuilder.carouselLimit)
        #expect(pages.prefix(8).allSatisfy { $0.contextTitle == "Continue Watching" })
    }

    @Test("Snapshots written before the details decode without them")
    func legacyDecode() throws {
        let legacyJSON = """
        {"version":1,"generatedAt":0,"continueWatching":[{"id":"a","title":"A","kind":"movie",\
        "displayURL":"openstream://media/a?action=display","progress":0.4,\
        "landscapeArtworkURL":"https://image.tmdb.org/t/p/original/a.jpg"}],"recentlyAdded":[],"favorites":[]}
        """
        let decoded = try JSONDecoder().decode(AppleTopShelfSnapshot.self, from: Data(legacyJSON.utf8))
        let value = try #require(decoded.continueWatching.first)
        #expect(value.summary == nil && value.genre == nil && value.year == nil && value.durationSeconds == nil)
        #expect(AppleTopShelfContentBuilder.carouselItems(for: decoded).map(\.item.id) == ["a"])
    }

    @Test("The writer fills each page's genre, year, running time and synopsis")
    func writerDetails() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "openstream-topshelf-carousel-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let backdrop = URL(string: "https://image.tmdb.org/t/p/original/matilda.jpg")!
        let film = AppleCatalogItem(mediaID: "tt0117008", type: "movie", name: "Matilda",
                                    posterURL: URL(string: "https://image.tmdb.org/t/p/w500/matilda.jpg"),
                                    backgroundURL: backdrop, summary: "A gifted girl.", releaseInfo: "1996",
                                    genres: ["Comedy", "Family"], runtimeMinutes: 98)
        var record = AppleMediaIngestion.catalogRecord(instanceID: UUID(), item: film)
        record.progress = 0.3
        let hero = AppleTopShelfHero(
            item: AppleTopShelfSnapshotWriter.catalogItem(id: record.id, title: record.title, kind: record.kind.rawValue, item: film),
            backdropURL: backdrop, wordmarkURL: nil)

        let writer = AppleTopShelfSnapshotWriter(containerProvider: { root })
        try await writer.write(records: [record], heroes: [hero], enabled: true)
        let written = try #require(AppleTopShelfSnapshotReader(containerProvider: { root }).read())

        let page = try #require(written.heroes.first)
        #expect(page.genre == "Comedy")
        #expect(page.year == 1996)
        #expect(page.durationSeconds == 5_880)
        #expect(page.summary == "A gifted girl.")
        let continued = try #require(written.continueWatching.first)
        #expect(continued.year == 1996)
        #expect(continued.summary == "A gifted girl.")
        #expect(continued.landscapeArtworkURL == backdrop)

        let pages = AppleTopShelfContentBuilder.carouselItems(for: written)
        #expect(pages.map(\.contextTitle) == ["Continue Watching"])
        #expect(pages.first?.item.genre == "Comedy")
        #expect(pages.first?.imageURL == backdrop)
    }
}
