import Foundation
import Testing
@testable import OpenStreamApple

/// Edge-case tests for AppleCatalogShelfPolicy.visibleSections and mostlyRepeats.
@Suite("Catalog shelf policy edge cases")
struct AppleCatalogShelfPolicyEdgeTests {
    private let primary = AppleSource(kind: .stremio, name: "Primary",
        url: URL(string: "https://fixture.example/primary/manifest.json")!)
    private let secondary = AppleSource(kind: .stremio, name: "Secondary",
        url: URL(string: "https://fixture.example/secondary/manifest.json")!)

    private func section(_ source: AppleSource, _ catalogID: String, _ type: String, _ name: String,
                         items: [AppleCatalogItem]) -> AppleCatalogSection {
        AppleCatalogSection(source: source,
                            catalog: AppleStremioCatalog(type: type, id: catalogID, name: name),
                            items: items)
    }

    // ─── mostlyRepeats 50 % boundary ───────────────────────────────

    @Test("Exactly 50 percent overlap triggers mostlyRepeats")
    func exactFiftyPercentOverlapIsRejected() {
        let first20 = (0..<20).map { AppleCatalogItem(mediaID: "id-\($0)", type: "movie",
                                                       name: "Movie \($0)") }
        let shared10 = (0..<10).map { AppleCatalogItem(mediaID: "id-\($0)", type: "movie",
                                                         name: "Movie \($0)") }
        let other10 = (100..<110).map { AppleCatalogItem(mediaID: "id-\($0)", type: "movie",
                                                            name: "Movie \($0)") }

        let s1 = section(primary, "a", "movie", "Popular", items: first20)
        let s2 = section(primary, "b", "movie", "Popular", items: shared10 + other10)

        let visible = AppleCatalogShelfPolicy.visibleSections([s1, s2],
            activeSourceIDs: [primary.id])

        #expect(visible.count == 1)
        #expect(visible[0].id == s1.id)
    }

    @Test("45 percent overlap does not trigger mostlyRepeats")
    func belowFiftyPercentOverlapIsKept() {
        let first20 = (0..<20).map { AppleCatalogItem(mediaID: "id-\($0)", type: "movie",
                                                       name: "Movie \($0)") }
        let shared9 = (0..<9).map { AppleCatalogItem(mediaID: "id-\($0)", type: "movie",
                                                        name: "Movie \($0)") }
        let other11 = (100..<111).map { AppleCatalogItem(mediaID: "id-\($0)", type: "movie",
                                                             name: "Movie \($0)") }

        let s1 = section(primary, "a", "movie", "Popular", items: first20)
        let s2 = section(primary, "b", "movie", "Popular", items: shared9 + other11)

        let visible = AppleCatalogShelfPolicy.visibleSections([s1, s2],
            activeSourceIDs: [primary.id])

        // One row per heading, and no "· <add-on>" suffix (Apple TV pass
        // 2026-10-02): the later row is not drawn.
        #expect(visible.count == 1)
        #expect(visible[0].shelfTitle == "Popular")
    }

    // ─── short rows ────────────────────────────────────────────────

    @Test("A second same-titled row with fewer than 20 items is filtered when it repeats")
    func shortRowThatRepeatsIsFiltered() {
        let long = (0..<20).map { AppleCatalogItem(mediaID: "id-\($0)", type: "movie",
                                                     name: "Movie \($0)") }
        let short = (0..<3).map { AppleCatalogItem(mediaID: "id-\($0)", type: "movie",
                                                      name: "Movie \($0)") }

        let s1 = section(primary, "a", "movie", "Popular", items: long)
        let s2 = section(primary, "b", "movie", "Popular", items: short)

        let visible = AppleCatalogShelfPolicy.visibleSections([s1, s2],
            activeSourceIDs: [primary.id, secondary.id])

        #expect(visible.count == 1)
    }

    @Test("A second same-titled row is not drawn even when distinct")
    func shortRowThatIsDistinctIsKept() {
        let long = (0..<20).map { AppleCatalogItem(mediaID: "id-\($0)", type: "movie",
                                                     name: "Movie \($0)") }
        let short = (100..<103).map { AppleCatalogItem(mediaID: "id-\($0)", type: "movie",
                                                          name: "Movie \($0)") }

        let s1 = section(primary, "a", "movie", "Popular", items: long)
        let s2 = section(primary, "b", "movie", "Popular", items: short)

        let visible = AppleCatalogShelfPolicy.visibleSections([s1, s2],
            activeSourceIDs: [primary.id, secondary.id])

        // One row per heading since the Apple TV pass 2026-10-02.
        #expect(visible.count == 1)
    }

    // ─── three same-heading rows ───────────────────────────────────

    @Test("Three rows with the same heading keeps the first two distinct ones")
    func threeSameHeadingRows() {
        let first20 = (0..<20).map { AppleCatalogItem(mediaID: "id-\($0)", type: "movie",
                                                        name: "Movie \($0)") }
        let other20 = (50..<70).map { AppleCatalogItem(mediaID: "id-\($0)", type: "movie",
                                                          name: "Movie \($0)") }
        let repeat10 = (0..<10).map { AppleCatalogItem(mediaID: "id-\($0)", type: "movie",
                                                          name: "Movie \($0)") }

        let s1 = section(primary, "a", "movie", "Popular", items: first20)
        let s2 = section(primary, "b", "movie", "Popular", items: other20)
        let s3 = section(primary, "c", "movie", "Popular", items: repeat10)

        let visible = AppleCatalogShelfPolicy.visibleSections([s1, s2, s3],
            activeSourceIDs: [primary.id])

        // One row per heading, and no "· <add-on>" suffix (Apple TV pass
        // 2026-10-02): the later row is not drawn.
        #expect(visible.count == 1)
        #expect(visible[0].shelfTitle == "Popular")
    }

    // ─── empty rows ────────────────────────────────────────────────

    @Test("Empty sections are excluded from visible sections")
    func emptySectionsAreExcluded() {
        let items = [AppleCatalogItem(mediaID: "id-1", type: "movie", name: "Movie 1")]

        let s1 = section(primary, "a", "movie", "Popular", items: items)
        let s2 = section(secondary, "b", "movie", "Trending", items: [])
        let s3 = section(primary, "c", "movie", "New", items: items)

        let visible = AppleCatalogShelfPolicy.visibleSections([s1, s2, s3],
            activeSourceIDs: [primary.id, secondary.id])

        #expect(visible.count == 2)
        #expect(visible.map(\.shelfTitle) == ["New", "Popular"])
    }

    @Test("Inactive source sections are excluded regardless of content")
    func inactiveSourceSectionsAreExcluded() {
        let items = [AppleCatalogItem(mediaID: "id-1", type: "movie", name: "Movie 1")]

        let s1 = section(primary, "a", "movie", "Popular", items: items)
        let s2 = section(secondary, "b", "movie", "Trending", items: items)

        let visible = AppleCatalogShelfPolicy.visibleSections([s1, s2],
            activeSourceIDs: [primary.id])

        #expect(visible.count == 1)
        #expect(visible[0].shelfTitle == "Popular")
    }

    // ─── title normalization (case / whitespace) ───────────────────

    @Test("Rows whose titles differ only by case are treated as same heading")
    func titlesDifferingByCaseAreSameHeading() {
        let first10 = (0..<10).map { AppleCatalogItem(mediaID: "id-\($0)", type: "movie",
                                                         name: "Movie \($0)") }
        let other10 = (100..<110).map { AppleCatalogItem(mediaID: "id-\($0)", type: "movie",
                                                             name: "Movie \($0)") }

        let s1 = section(primary, "a", "movie", "Popular", items: first10)
        let s2 = section(primary, "b", "movie", "popular", items: other10)

        let visible = AppleCatalogShelfPolicy.visibleSections([s1, s2],
            activeSourceIDs: [primary.id])

        #expect(visible.count == 1)
        #expect(visible[0].shelfTitle?.contains("·") == false)
    }

    @Test("Rows whose titles differ only by whitespace are treated as same heading")
    func titlesDifferingByWhitespaceAreSameHeading() {
        let first10 = (0..<10).map { AppleCatalogItem(mediaID: "id-\($0)", type: "movie",
                                                         name: "Movie \($0)") }
        let other10 = (100..<110).map { AppleCatalogItem(mediaID: "id-\($0)", type: "movie",
                                                             name: "Movie \($0)") }

        let s1 = section(primary, "a", "movie", "Popular", items: first10)
        let s2 = section(primary, "b", "movie", " Popular ", items: other10)

        let visible = AppleCatalogShelfPolicy.visibleSections([s1, s2],
            activeSourceIDs: [primary.id, secondary.id])

        #expect(visible.count == 1)
        #expect(visible[0].shelfTitle == "Popular")
    }

    @Test("Mixed case and whitespace title variants with overlapping content are filtered")
    func titleVariantWithOverlapIsFiltered() {
        let items20 = (0..<20).map { AppleCatalogItem(mediaID: "id-\($0)", type: "movie",
                                                         name: "Movie \($0)") }
        let half10 = (0..<10).map { AppleCatalogItem(mediaID: "id-\($0)", type: "movie",
                                                         name: "Movie \($0)") }
        let rest10 = (100..<110).map { AppleCatalogItem(mediaID: "id-\($0)", type: "movie",
                                                            name: "Movie \($0)") }

        let s1 = section(primary, "a", "movie", "Popular", items: items20)
        let s2 = section(primary, "b", "movie", "POPULAR  ", items: half10 + rest10)

        let visible = AppleCatalogShelfPolicy.visibleSections([s1, s2],
            activeSourceIDs: [primary.id, secondary.id])

        #expect(visible.count == 1)
    }
}
