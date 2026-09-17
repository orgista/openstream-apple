import Foundation
import Testing
@testable import OpenStreamApple

@Test func libraryReleaseNamesAndOwnerCases() {
    let owner = AppleLibraryTitleParser.parse(name: "[ Torrent911.lol ] Small.Things.Like.These.2024.1080p.BluRay.x265.HDR.DV.Atmos.mkv")
    #expect(owner.title == "Small Things Like These")
    #expect(owner.year == 2024)
    #expect(owner.kind == .movie)
    // The screenshot clips both names; cover the visible prefix and the hash shape.
    #expect(AppleLibraryTitleParser.parse(name: "[ Torrent911.lol ] Small.Thin…").title == "Small Thin…")
    let hash = "7a11e36cfd6d49bb97d90123456789ab.mkv"
    let recovered = AppleLibraryTitleParser.parse(name: hash, parentPath: "Movies/Inception (2010)")
    #expect(recovered.title == "Inception")
    #expect(recovered.year == 2010)
    let unknown = AppleLibraryTitleParser.parse(name: hash, parentPath: "aabbccddeeff00112233445566778899")
    #expect(unknown.kind == .other)
    #expect(unknown.title.count == 25)
    #expect(unknown.title.hasSuffix("…"))
    #expect(AppleLibraryTitleParser.parse(name: "[Group] [Site] The_Matrix_(1999)_1080p_WEB-DL.mkv").title == "The Matrix")
    #expect(AppleLibraryTitleParser.parse(name: "1917.1080p.mkv").title == "1917")
    #expect(AppleLibraryTitleParser.parse(name: "Atmosphere.mkv").title == "Atmosphere")
    #expect(AppleLibraryTitleParser.parse(name: "2001.A.Space.Odyssey.1968.1080p.mkv").year == 1968)
}

@Test func libraryEpisodeAndFolderPatterns() {
    for name in ["Breaking.Bad.S01E02.1080p.mkv", "Breaking_Bad.1x02.WEB-DL.mkv"] {
        let parsed = AppleLibraryTitleParser.parse(name: name)
        #expect(parsed.title == "Breaking Bad")
        #expect(parsed.season == 1)
        #expect(parsed.episode == 2)
        #expect(parsed.kind == .show)
    }
    let folder = AppleLibraryTitleParser.parse(name: "Episode 2.mkv", parentPath: "Shows/Breaking Bad/Season 1")
    #expect(folder.title == "Breaking Bad")
    #expect(folder.season == 1)
    #expect(folder.episode == 2)
    #expect(AppleLibraryTitleParser.parse(name: "Pilot.mkv", parentPath: "Shows/Breaking Bad/Season 1").title == "Breaking Bad")
    #expect(AppleLibraryTitleParser.parse(name: "aabbccddeeff00112233.mkv", parentPath: "Shows/aabbccddeeff00112233/Season 1").kind == .other)
    #expect(AppleLibraryTitleParser.parse(name: "Pilot.mkv", parentPath: "Shows").kind == .show)
    #expect(AppleLibraryTitleParser.parse(name: "aabbccddeeff00112233.mkv", parentPath: "Shows/Breaking Bad/Season 2").title == "Breaking Bad")
}

private func libraryTestItem(_ path: String, size: Int64 = 1, source: UUID = UUID()) -> AppleLibraryItem {
    .init(sourceID: source, name: (path as NSString).lastPathComponent,
          url: URL(fileURLWithPath: "/fixture/" + path), relativePath: path, sizeBytes: size)
}

@Test func libraryGroupsSeasonsAndSeparatesSources() {
    let source = UUID()
    let items = ["Shows/Breaking Bad/Season 2/Breaking.Bad.S02E01.mkv", "Shows/Breaking Bad/Season 1/Breaking.Bad.S01E02.mkv",
                 "Shows/Breaking Bad/Season 1/Breaking.Bad.S01E01.mkv", "Movies/Inception.2010.mkv"].map { libraryTestItem($0, source: source) }
    let groups = AppleLibrarySeries.groups(items)
    #expect(groups.count == 2)
    let series = groups.first { $0.parsed.kind == .show }
    #expect(series?.items.count == 3)
    #expect(series?.items.first?.relativePath.hasSuffix("S01E01.mkv") == true)
    #expect(AppleLibrarySeries.groups(items + [libraryTestItem("Breaking.Bad.S01E01.mkv")]).count == 3)
}

@Test func libraryMetadataRequiresMatchingYearAndKind() {
    let parsed = AppleLibraryTitleParser.parse(name: "Dune.2021.mkv")
    let values = [AppleCatalogItem(mediaID: "old", type: "movie", name: "Dune", releaseInfo: "1984"),
                  AppleCatalogItem(mediaID: "show", type: "series", name: "Dune", releaseInfo: "2021"),
                  AppleCatalogItem(mediaID: "new", type: "movie", name: "Dune", releaseInfo: "2021")]
    #expect(AppleLibraryMetadataResolver.bestMatch(values, parsed: parsed)?.mediaID == "new")
}

/// Owner 2026-09-15: "1992 still does not have album art".
///
/// `movies/1992 (2024)/1992.2024.2160p…mkv` parses correctly to title "1992",
/// year 2024. Cinemeta's `tt4959750` is plainly the same film — Tyrese Gibson,
/// Ray Liotta, Scott Eastwood, `released: 2024-08-30` — but its `releaseInfo`
/// carries the production year, 2022. Requiring the years to be equal threw
/// away a correct match and left the card blank.
@Test func libraryMetadataKeepsALoneNameMatchWhenTheProvidersYearDisagrees() {
    let parsed = AppleLibraryTitleParser.parse(name: "1992.2024.2160p.WEB-DL.mkv")
    #expect(parsed.title == "1992")
    #expect(parsed.year == 2024)
    let values = [AppleCatalogItem(mediaID: "tt4959750", type: "movie", name: "1992", releaseInfo: "2022")]
    #expect(AppleLibraryMetadataResolver.bestMatch(values, parsed: parsed)?.mediaID == "tt4959750")
}

@Test func libraryMetadataStillPrefersTheExactYearWhenOneIsOffered() {
    let parsed = AppleLibraryTitleParser.parse(name: "Dune.2021.mkv")
    let values = [AppleCatalogItem(mediaID: "near", type: "movie", name: "Dune", releaseInfo: "2020"),
                  AppleCatalogItem(mediaID: "exact", type: "movie", name: "Dune", releaseInfo: "2021")]
    #expect(AppleLibraryMetadataResolver.bestMatch(values, parsed: parsed)?.mediaID == "exact")
}

@Test func libraryMetadataPicksTheNearestYearAmongSameNamedFilms() {
    let parsed = AppleLibraryTitleParser.parse(name: "Dune.2021.mkv")
    let values = [AppleCatalogItem(mediaID: "old", type: "movie", name: "Dune", releaseInfo: "1984"),
                  AppleCatalogItem(mediaID: "close", type: "movie", name: "Dune", releaseInfo: "2020")]
    #expect(AppleLibraryMetadataResolver.bestMatch(values, parsed: parsed)?.mediaID == "close")
}

@Test func libraryMetadataSortsYearlessCandidatesLastRatherThanTreatingThemAsYearZero() {
    let parsed = AppleLibraryTitleParser.parse(name: "Dune.2021.mkv")
    let values = [AppleCatalogItem(mediaID: "unknown", type: "movie", name: "Dune", releaseInfo: nil),
                  AppleCatalogItem(mediaID: "old", type: "movie", name: "Dune", releaseInfo: "1984")]
    #expect(AppleLibraryMetadataResolver.bestMatch(values, parsed: parsed)?.mediaID == "old")
}

@Test func libraryMetadataStillRefusesADifferentTitleOrKind() {
    let parsed = AppleLibraryTitleParser.parse(name: "1992.2024.2160p.WEB-DL.mkv")
    // A different film, and the right name on the wrong kind: neither is a match.
    let values = [AppleCatalogItem(mediaID: "other", type: "movie", name: "Unforgiven", releaseInfo: "1992"),
                  AppleCatalogItem(mediaID: "series", type: "series", name: "1992", releaseInfo: "2024")]
    #expect(AppleLibraryMetadataResolver.bestMatch(values, parsed: parsed) == nil)
}

private actor LibraryLookupProbe {
    var active = 0
    var maximum = 0
    var calls = 0
    func lookup(_ title: AppleLibraryTitle) async throws -> AppleCatalogItem? {
        active += 1; calls += 1; maximum = max(maximum, active)
        defer { active -= 1 }
        try await Task.sleep(for: .milliseconds(80))
        return .init(mediaID: "tt1234567", type: "movie", name: title.title)
    }
}

@Test func libraryCacheSizeIsolationConcurrencyAndCancellation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let probe = LibraryLookupProbe()
    let resolver = AppleLibraryMetadataResolver(directory: root) { title, _, _, _ in try await probe.lookup(title) }
    let source = UUID()
    let item = libraryTestItem("Inception.2010.mkv", source: source)
    _ = try await resolver.resolve(item, sources: [], tmdbKey: "", omdbKey: "")
    let reopened = AppleLibraryMetadataResolver(directory: root) { title, _, _, _ in try await probe.lookup(title) }
    _ = try await reopened.resolve(item, sources: [], tmdbKey: "", omdbKey: "")
    #expect(await probe.calls == 1)
    _ = try await resolver.resolve(libraryTestItem(item.relativePath, size: 2, source: source), sources: [], tmdbKey: "", omdbKey: "")
    #expect(await probe.calls == 2)
    _ = try await resolver.resolve(libraryTestItem(item.relativePath), sources: [], tmdbKey: "", omdbKey: "")
    #expect(await probe.calls == 3)
    try await withThrowingTaskGroup(of: Void.self) { group in
        for index in 0..<12 {
            group.addTask { _ = try await resolver.resolve(libraryTestItem("Movie \(index).mkv", source: source), sources: [], tmdbKey: "", omdbKey: "") }
        }
        try await group.waitForAll()
    }
    #expect(await probe.maximum == 4)
    let cancelled = Task { try await resolver.resolve(libraryTestItem("Cancelled.mkv"), sources: [], tmdbKey: "", omdbKey: "") }
    cancelled.cancel()
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    let dates = try await resolver.datedItems([item], sourceID: source)
    let again = try await reopened.datedItems([item], sourceID: source)
    #expect(dates.first?.addedAt == again.first?.addedAt)
    #expect(dates.first?.addedAt != .distantPast)
}

/// Cases taken from the owner's own library (421 titles dumped from the Apple
/// TV on 2026-09-14): exactly one folder parsed to a number, and one kept a
/// tracker stamp. The numeric *titles* in that library — 1992, 2073 — are the
/// films' real names and must survive untouched.
@Test func discPlaylistFilenamesUseTheFolderTitle() {
    let bluRay = AppleLibraryTitleParser.parse(name: "00526.m2ts", parentPath: "movies/Fantastic Mr. Fox (2009)")
    #expect(bluRay.title == "Fantastic Mr Fox")
    #expect(bluRay.year == 2009)
    #expect(bluRay.kind == .movie)

    let dvd = AppleLibraryTitleParser.parse(name: "VTS_01_1.VOB", parentPath: "movies/Spirited Away (2001)")
    #expect(dvd.title == "Spirited Away")

    let handbrake = AppleLibraryTitleParser.parse(name: "title_t00.mkv", parentPath: "movies/Heat (1995)")
    #expect(handbrake.title == "Heat")
}

@Test func aFilmWhoseTitleIsANumberKeepsIt() {
    let ninetyTwo = AppleLibraryTitleParser.parse(
        name: "1992.2024.2160p.WEB-DL.DDP5.1.HDR.H.265-FLUX.mkv", parentPath: "movies/1992 (2024)")
    #expect(ninetyTwo.title == "1992")
    #expect(ninetyTwo.year == 2024)

    let twentySeventyThree = AppleLibraryTitleParser.parse(
        name: "2073.2024.2160p.AMZN.WEB-DL.DDP5.1.HDR.H.265-FLUX.mkv", parentPath: "movies/2073 (2024)")
    #expect(twentySeventyThree.title == "2073")
    #expect(twentySeventyThree.year == 2024)

    // A bare year folder is still a playlist-free name and stays as it is.
    #expect(AppleLibraryTitleParser.parse(name: "1917.2019.1080p.BluRay.x264.mkv").title == "1917")
}

@Test func trackerStampsAreStrippedFromTheFilename() {
    let stamped = AppleLibraryTitleParser.parse(
        name: "www.UIndex.org    -    Hey Arnold The Movie 2002 1080p AMZN WEB-DL DDP5 1 H 264-BLOOM.mkv",
        parentPath: "movies/Hey Arnold! The Movie (2002)")
    #expect(stamped.title == "Hey Arnold The Movie")
    #expect(stamped.year == 2002)

    #expect(AppleLibraryTitleParser.parse(name: "Torrent911.lol - Dune.2021.1080p.mkv").title == "Dune")
    // A title that merely contains a dot-word is not a tracker stamp.
    #expect(AppleLibraryTitleParser.parse(name: "W.A.R - The Movie 2011 1080p.mkv").title.contains("W A R"))
}
