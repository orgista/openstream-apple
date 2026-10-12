import Foundation
import Testing
@testable import OpenStreamApple

/// Discover's row headings (owner, 2026-09-24: "Prime Video" drew twice, once
/// as "Prime  Video"; he wants "Prime Movies" and "Prime Shows").
@Suite("Catalog row titles")
struct AppleCatalogRowTitleTests {
    private let source = AppleSource(kind: .stremio, name: "Streaming Catalogs",
                                     url: URL(string: "https://fixture.example/manifest.json")!)

    private func section(_ id: String, _ type: String, _ name: String?, source: AppleSource? = nil) -> AppleCatalogSection {
        AppleCatalogSection(source: source ?? self.source,
                            catalog: AppleStremioCatalog(type: type, id: id, name: name),
                            items: [AppleCatalogItem(mediaID: "tt0000001", type: type, name: "Fixture")])
    }

    /// Owner 2026-10-01 (compliance B4): a row is headed by what the add-on
    /// called the list — the app never turns a catalog id into a brand.
    @Test("A catalog keeps the add-on's own name, whatever its id", arguments: [
        ("amp", "Prime  Video", "Prime Video"),
        ("nfx", "Netflix", "Netflix"),
        ("dnp", "Disney+", "Disney+"),
        ("streaming.hbm", "HBO Max", "HBO Max"),
        ("nfx", "Streaming Picks", "Streaming Picks"),
        ("streaming.amp", "New on Prime", "New on Prime"),
    ])
    func catalogsKeepTheirOwnName(id: String, name: String, expected: String) {
        #expect(AppleCatalogShelfPolicy.title(for: AppleStremioCatalog(type: "movie", id: id, name: name)) == expected)
        #expect(AppleCatalogShelfPolicy.title(for: AppleStremioCatalog(type: "series", id: id, name: name)) == expected)
    }

    @Test("A known service id with no name gets a neutral heading, not the brand", arguments: [
        ("nfx", "movie", "Movies"), ("dnp", "series", "Shows"), ("netflix-top10-us", "movie", "Movies"),
        ("streaming.amp", "series", "Shows"), ("hbm", "other", "Catalog"),
    ])
    func unnamedServiceCatalogsAreNeutral(id: String, type: String, expected: String) {
        #expect(AppleCatalogShelfPolicy.title(for: AppleStremioCatalog(type: type, id: id, name: nil)) == expected)
    }

    @Test func aNameIsNeverRewrittenToAServiceBrand() {
        // "Prime Video" used to become "Prime Movies"; " netflix " became "Netflix Shows".
        #expect(AppleCatalogShelfPolicy.title(for: AppleStremioCatalog(type: "movie", id: "custom-1", name: "Prime Video")) == "Prime Video")
        #expect(AppleCatalogShelfPolicy.title(for: AppleStremioCatalog(type: "series", id: "custom-2", name: " netflix ")) == "netflix")
    }

    @Test func otherCatalogsKeepTheirNameWithWhitespaceCollapsed() {
        #expect(AppleCatalogShelfPolicy.title(for: AppleStremioCatalog(type: "movie", id: "top", name: "Popular")) == "Popular")
        #expect(AppleCatalogShelfPolicy.title(for: AppleStremioCatalog(type: "series", id: "disney", name: "Top 10  Disney+")) == "Top 10 Disney+")
        #expect(AppleCatalogShelfPolicy.title(for: AppleStremioCatalog(type: "movie", id: "netflix-top10-us", name: "Netflix Top 10 US")) == "Netflix Top 10 US")
        #expect(AppleCatalogShelfPolicy.title(for: AppleStremioCatalog(type: "movie", id: "x", name: "New\t Releases\n")) == "New Releases")
    }

    @Test func streamingCatalogsManifestDrawsTwoDistinctPrimeRows() throws {
        let sections = [section("amp", "movie", "Prime  Video"), section("amp", "series", "Prime Video")]
        let visible = AppleCatalogShelfPolicy.visibleSections(sections, activeSourceIDs: [source.id])
        #expect(visible.map(\.shelfTitle) == ["Prime Video Movies", "Prime Video Shows"])
    }

    @Test func noTwoRowsEverShareATitle() {
        let other = AppleSource(kind: .stremio, name: "TMDB", url: URL(string: "https://fixture.example/tmdb/manifest.json")!)
        let sections = [
            section("amp", "movie", "Prime Video"),
            section("streaming.amp", "movie", "Prime Video", source: other),
            section("amp", "series", "Prime Video"),
            section("top", "movie", "Popular"),
            section("top", "series", "Popular"),
            section("top", "movie", "Popular", source: other),
        ]
        let visible = AppleCatalogShelfPolicy.visibleSections(sections, activeSourceIDs: [source.id, other.id])
        let titles = visible.compactMap(\.shelfTitle)
        #expect(titles.count == visible.count)
        #expect(Set(titles.map { $0.lowercased() }).count == titles.count)
        #expect(titles == ["Popular Movies", "Popular Shows", "Prime Video Movies", "Prime Video Shows"])
    }

    /// gpt-6-luna review of d605c9f kept both rows, the later one suffixed
    /// with its add-on; the owner's rules (no provider in a heading, never two
    /// rows under one heading) leave one.
    @Test func sameHeadingWithDifferentTitlesKeepsOneRow() {
        let other = AppleSource(kind: .stremio, name: "TMDB", url: URL(string: "https://fixture.example/tmdb/manifest.json")!)
        let first = AppleCatalogSection(source: source, catalog: AppleStremioCatalog(type: "series", id: "a", name: "Popular"),
                                        items: [AppleCatalogItem(mediaID: "tt0000001", type: "series", name: "One")])
        let different = AppleCatalogSection(source: other, catalog: AppleStremioCatalog(type: "series", id: "b", name: "Popular"),
                                            items: [AppleCatalogItem(mediaID: "tt0000002", type: "series", name: "Two")])
        let visible = AppleCatalogShelfPolicy.visibleSections([first, different], activeSourceIDs: [source.id, other.id])
        // Apple TV pass 2026-10-02: no "· <add-on>" suffix, and never a
        // second row under the same heading — the later one is not drawn.
        #expect(visible.compactMap(\.shelfTitle) == ["Popular"])
    }

    /// N32 #12: "TMDB Popular Movies" named the add-on in the heading.
    @Test("A leading provider name is dropped from the heading", arguments: [
        ("TMDB Popular Movies", "Popular Movies"),
        ("TMDB Top Rated Shows", "Top Rated Shows"),
        ("Trakt - Trending", "Trending"),
        ("Cinemeta: Popular", "Popular"),
        ("tmdb  Top  Rated", "Top Rated"),
        ("TMDB", "TMDB"),
        ("Netflix Top 10 US", "Netflix Top 10 US"),
        ("TMDBX Picks", "TMDBX Picks"),
        ("RT: Certified Fresh", "Certified Fresh"),
        ("RT - Certified Fresh", "Certified Fresh"),
        ("RTL Classics", "RTL Classics"),
    ])
    func providerPrefixIsStripped(name: String, expected: String) {
        #expect(AppleCatalogShelfPolicy.title(for: AppleStremioCatalog(type: "movie", id: "x", name: name)) == expected)
    }

    @Test func strippedHeadingsStillMergeByType() {
        let sections = [section("pop", "movie", "TMDB Popular"), section("pop", "series", "Cinemeta Popular")]
        let visible = AppleCatalogShelfPolicy.visibleSections(sections, activeSourceIDs: [source.id])
        #expect(visible.map(\.shelfTitle) == ["Popular Movies", "Popular Shows"])
    }

    @Test func typedTitleSwapsAnExistingTypeWord() {
        #expect(AppleCatalogShelfPolicy.typedTitle("Popular Movies", type: "series") == "Popular Shows")
        #expect(AppleCatalogShelfPolicy.typedTitle("Trending", type: "movie") == "Trending Movies")
        #expect(AppleCatalogShelfPolicy.typedTitle("Trending", type: "channel") == "Trending")
        // Apple TV pass 2026-10-02: the type word reads as English.
        #expect(AppleCatalogShelfPolicy.typedTitle("Year", type: "movie") == "Movies by Year")
        #expect(AppleCatalogShelfPolicy.typedTitle("Year", type: "series") == "Shows by Year")
        #expect(AppleCatalogShelfPolicy.typedTitle("Latest Releases", type: "movie") == "Latest Movie Releases")
        #expect(AppleCatalogShelfPolicy.typedTitle("Top Rated", type: "series") == "Top Rated Shows")
    }
}

/// Full test 2026-09-30: "Trending Movies · AIOMetadata  | ElfHosted".
@Test func rowHeadingsShowAddonNamesWithoutHostSuffix() {
    #expect(AppleCatalogShelfPolicy.displaySourceName("AIOMetadata  | ElfHosted") == "AIOMetadata")
    #expect(AppleCatalogShelfPolicy.displaySourceName("  Cinemeta  ") == "Cinemeta")
    #expect(AppleCatalogShelfPolicy.displaySourceName("Torrentio   Lite") == "Torrentio Lite")
    #expect(AppleCatalogShelfPolicy.displaySourceName("| Only Host") == "| Only Host")
}
