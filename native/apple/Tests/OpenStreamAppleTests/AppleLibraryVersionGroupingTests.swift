import Foundation
import Testing
@testable import OpenStreamApple

/// N32 #13: Library "Movies" drew "Tony" twice — several files of one film.
@Suite("Library film versions")
struct AppleLibraryVersionGroupingTests {
    private let source = UUID()

    private func file(_ name: String, source: UUID? = nil) -> AppleLibraryItem {
        AppleLibraryItem(sourceID: source ?? self.source, name: name, url: URL(fileURLWithPath: "/" + name),
                         relativePath: "Movies/" + name, sizeBytes: 1)
    }

    @Test func datedCopiesOfOneFilmAreOneGroupBestCopyFirst() throws {
        let groups = AppleLibrarySeries.groups([file("Example.Film.2026.1080p.mkv"), file("Example Film (2026) 2160p.mkv")])
        let group = try #require(groups.first)
        #expect(groups.count == 1)
        #expect(group.items.map(\.name) == ["Example Film (2026) 2160p.mkv", "Example.Film.2026.1080p.mkv"])
    }

    @Test func differentYearsOrUndatedFilmsStaySeparate() {
        #expect(AppleLibrarySeries.groups([file("Example.Film.2026.mkv"), file("Example.Film.1990.mkv")]).count == 2)
        #expect(AppleLibrarySeries.groups([file("Example Film.mkv"), file("Example Film copy.mkv")]).count == 2)
    }

    @Test func sameFilmOnTwoSourcesStaysPerSource() {
        #expect(AppleLibrarySeries.groups([file("Example.Film.2026.mkv"), file("Example.Film.2026.mkv", source: UUID())]).count == 2)
    }

    @Test func filesResolvingToOneIMDbTitleDrawOneCard() {
        let groups = AppleLibrarySeries.groups([file("Example.Film.2026.mkv"), file("Example Film 4K.mkv"), file("Other.2020.mkv")])
            .sorted { $0.id < $1.id }
        #expect(groups.count == 3)
        let decorated = groups.map { group in
            (group: group, item: AppleCatalogItem(mediaID: group.parsed.title.hasPrefix("Other") ? "tt0000002" : "tt0000001",
                                                  type: "movie", name: group.parsed.title))
        }
        let shown = AppleLocalLibraryStore.collapsingVersions(decorated)
        #expect(shown.count == 2)
        #expect(shown.first?.id == groups.first?.id)
    }

    @Test func unresolvedFilmsAreNeverCollapsed() {
        let groups = AppleLibrarySeries.groups([file("Example A.mkv"), file("Example B.mkv")])
        let decorated = groups.map { (group: $0, item: AppleCatalogItem(mediaID: "local-same", type: "movie", name: "Example")) }
        #expect(AppleLocalLibraryStore.collapsingVersions(decorated).count == 2)
    }
}
