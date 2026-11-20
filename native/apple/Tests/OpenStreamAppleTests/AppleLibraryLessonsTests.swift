import Foundation
import Testing
@testable import OpenStreamApple

@Suite("Owned library parsing and corrections")
struct AppleLibraryLessonsTests {
    private func file(_ name: String, source: UUID, folder: String = "Movies") -> AppleLibraryItem {
        .init(sourceID: source, name: name, url: URL(fileURLWithPath: "/" + name),
            relativePath: folder + "/" + name, sizeBytes: 1)
    }

    @Test func episodeRangeAndSpecials() {
        let range = AppleLibraryTitleParser.parse(name: "Show.S01E01-E02.mkv")
        #expect(range.episodeNumbers == [1, 2])
        #expect(range.confidence == 1)
        #expect(AppleLibraryTitleParser.parse(name: "Show.S00E03.mkv").season == 0)
        #expect(AppleLibraryTitleParser.parse(name: "Show.S01E03-E01.mkv").episodeNumbers.isEmpty)
    }

    @Test(arguments: ["Show.2026-10-12.mkv", "Show.2026.10.12.mkv"])
    func airDates(_ name: String) {
        let parsed = AppleLibraryTitleParser.parse(name: name)
        #expect(parsed.airDate == "2026-10-12")
        #expect(parsed.kind == .show)
        #expect(parsed.title == "Show")
        #expect(parsed.year == nil)
        #expect(parsed.episode == nil)
    }

    @Test(arguments: ["trailer", "featurette", "behind-the-scenes", "deleted-scenes", "sample"])
    func extras(_ role: String) {
        let parsed = AppleLibraryTitleParser.parse(name: "Film.2024-\(role).mkv")
        #expect(parsed.role != .feature)
        #expect(parsed.episodeNumbers.isEmpty)
        let folder = AppleLibraryTitleParser.parse(name: "clip.mkv", parentPath: "Movies/Film (2024)/\(role)")
        #expect(folder.role == parsed.role)
        #expect(folder.title == "Film")
    }

    @Test @MainActor func ambiguousShowFilesNeverAcquireCopyOrderCoordinates() {
        let source = UUID()
        let files = [file("Pilot.mkv", source: source, folder: "Shows/Show/Season 1"),
            file("Unknown.mkv", source: source, folder: "Shows/Show/Season 1")]
        let groups = AppleLibrarySeries.groups(files)
        #expect(groups.flatMap(\.items).map(\.id).sorted() == files.map(\.id).sorted())
        #expect(groups.allSatisfy { AppleLocalLibraryStore.episodes(group: $0, mediaID: "tt1", enriched: []).allSatisfy { $0.episode == nil && $0.season == nil } })
        let rows = groups.flatMap { AppleLocalLibraryStore.episodes(group: $0, mediaID: "tt1", enriched: []) }
        #expect(AppleLocalLibraryStore.visibleEpisodes(in: 1, from: rows).count == files.count)
        #expect(rows.allSatisfy { row in files.contains { AppleLocalLibraryStore.matchesEpisode($0, episode: row) } })
        #expect(AppleLibraryTitleParser.parse(files[0]).confidence < 1)
    }

    @Test func partsChainButVersionsDoNot() throws {
        let source = UUID()
        for marker in ["cd", "part"] {
            let first = file("Film.2024.1080p.\(marker)1.mkv", source: source)
            let second = file("Film.2024.1080p.\(marker)2.mkv", source: source)
            let alternative = file("Film.2024.4K.\(marker)2.mkv", source: source)
            let edition = file("Film.2024.Directors.Edition.\(marker)2.mkv", source: source)
            let group = try #require(AppleLibrarySeries.groups([second, first, alternative, edition]).first)
            #expect(group.nextPart(after: first)?.id == second.id)
            #expect(group.nextPart(after: second) == nil)
            #expect(AppleLibraryTitleParser.parse(edition).version?.contains("edition") == true)
        }
        let copies = [file("Film.2024.1080p.mkv", source: source), file("Film.2024.4K.mkv", source: source)]
        #expect(AppleLibrarySeries.groups(copies).first?.nextPart(after: copies[0]) == nil)
    }

    @Test(arguments: [true, false])
    func olderCacheEntriesKeepTheirTitleAndAddedDateButNotTheirArtwork(lookupHasGenres: Bool) async throws {
        struct Seed: Codable {
            let value: AppleCatalogItem
            let checkedAt: Date
            let addedAt: Date
            let schema: Int
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let item = file("Film.2024.mkv", source: UUID())
        let group = try #require(AppleLibrarySeries.groups([item]).first)
        let poster = try #require(URL(string: "https://fixture.example/poster.jpg"))
        let old = AppleCatalogItem(mediaID: "tt0000004", type: "movie", name: "Film", posterURL: poster)
        let enriched = AppleCatalogItem(mediaID: old.mediaID, type: old.type, name: old.name,
            posterURL: poster, genres: ["Drama", "Adventure"])
        let resolver = AppleLibraryMetadataResolver(directory: root) { _, _, _ in lookupHasGenres ? enriched : nil }
        let folder = root.appendingPathComponent(item.sourceID.uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let cache = folder.appendingPathComponent(AppleLibraryMetadataResolver.cacheKey(item) + ".json")
        let addedAt = Date(timeIntervalSince1970: 1_700_000_000)
        try JSONEncoder().encode(Seed(value: old, checkedAt: .now, addedAt: addedAt, schema: 1)).write(to: cache)
        #expect(await resolver.cachedLookups(for: [group]).metadata[group.id] == old.withoutArtwork)
        #expect(await resolver.needsRevalidation(item, tmdbKey: "", omdbKey: ""))
        let expected = lookupHasGenres ? enriched : old.withoutArtwork
        #expect(try await resolver.resolve(item, tmdbKey: "", omdbKey: "") == expected)
        let saved = try JSONDecoder().decode(Seed.self, from: Data(contentsOf: cache))
        #expect(saved.addedAt == addedAt)
        #expect(saved.value.posterURL == expected.posterURL)
        #expect(saved.value.genres == expected.genres)
        #expect(!(await resolver.needsRevalidation(item, tmdbKey: "", omdbKey: "")))
    }

    @MainActor
    @Test func genreShelvesNeedTwoTitlesAndFollowTheSort() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = UUID()
        let titles = AppleLibrarySeries.groups(["Alpha.2020.mkv", "Beta.2021.mkv", "Gamma.2022.mkv"].map { file($0, source: source) })
        let resolver = AppleLibraryMetadataResolver(directory: root) { _, _, _ in nil }
        let store = AppleLocalLibraryStore(resolver: resolver, groups: titles)
        let genres = ["Alpha": ["Drama", "Comedy"], "Beta": ["Drama"], "Gamma": ["Drama", "Horror"]]
        for (index, title) in titles.enumerated() {
            let name = title.parsed.title
            try await store.correctMatch(title, candidate: AppleCatalogItem(mediaID: "tt000000\(index)", type: "movie",
                name: name, genres: genres[name]), provider: "manualSearch", resolver: resolver)
        }
        let shelves = store.genreShelves(.title)
        #expect(shelves.map(\.genre) == ["Drama"])
        #expect(shelves.first?.groups.map(\.parsed.title) == ["Alpha", "Beta", "Gamma"])
    }

    @MainActor
    @Test func addedSortUsesEachTitlesNewestFile() {
        let source = UUID()
        func dated(_ name: String, folder: String, day: Double) -> AppleLibraryItem {
            .init(sourceID: source, name: name, url: URL(fileURLWithPath: "/" + name), relativePath: folder + "/" + name,
                sizeBytes: 1, addedAt: Date(timeIntervalSince1970: day * 86_400))
        }
        let titles = AppleLibrarySeries.groups([
            dated("Alpha.2020.mkv", folder: "Movies", day: 2),
            dated("Show.S01E01.mkv", folder: "Show", day: 1),
            dated("Show.S01E02.mkv", folder: "Show", day: 4),
            dated("Gamma.2022.mkv", folder: "Movies", day: 3),
        ])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let resolver = AppleLibraryMetadataResolver(directory: root) { _, _, _ in nil }
        let store = AppleLocalLibraryStore(resolver: resolver, groups: titles)
        #expect(store.sorted(.added).map(\.parsed.title) == ["Show", "Gamma", "Alpha"])
    }

    @Test func unavailableMatchDirectoryKeepsLookupAndLegacyCacheUsable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let blocked = root.appendingPathComponent("not-a-directory")
        try Data([0]).write(to: blocked)
        let item = file("Film.2024.mkv", source: UUID())
        let candidate = AppleCatalogItem(mediaID: "tt0000004", type: "movie", name: "Film")
        let cache = root.appendingPathComponent("cache")
        let resolver = AppleLibraryMetadataResolver(directory: cache, matchDirectory: blocked) { _, _, _ in candidate }
        #expect(try await resolver.resolve(item, tmdbKey: "", omdbKey: "") == candidate)
        let reopened = AppleLibraryMetadataResolver(directory: cache, matchDirectory: blocked) { _, _, _ in
            Issue.record("A saved metadata entry must avoid another lookup")
            return nil
        }
        #expect(try await reopened.resolve(item, tmdbKey: "", omdbKey: "") == candidate)
        #expect(await reopened.cachedLookups(for: AppleLibrarySeries.groups([item])).metadata.values.first == candidate)
        #expect(await reopened.matchRecord(for: item) == nil)
    }

    @Test func correctionSurvivesRescanAndCacheVersionChange() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = UUID()
        let original = file("Dune.2021.1080p.mkv", source: source)
        let wrong = AppleCatalogItem(mediaID: "tt0000001", type: "movie", name: "Dune", releaseInfo: "1984")
        let correct = AppleCatalogItem(mediaID: "tt0000002", type: "movie", name: "Dune", releaseInfo: "2020")
        let resolver = AppleLibraryMetadataResolver(directory: root.appendingPathComponent("cache"), matchDirectory: root.appendingPathComponent("matches")) { _, _, _ in wrong }
        #expect(try await resolver.resolve(original, tmdbKey: "", omdbKey: "") == wrong)
        try await resolver.correctMatch(for: original, candidate: correct, provider: "fixture", explicitIDs: ["imdb": correct.mediaID])
        let reopened = AppleLibraryMetadataResolver(directory: root.appendingPathComponent("cache-v2"), matchDirectory: root.appendingPathComponent("matches")) { _, _, _ in wrong }
        let rescanned = file("Dune.2021.4K.mkv", source: source)
        #expect(try await reopened.resolve(rescanned, tmdbKey: "", omdbKey: "") == correct)
        #expect(try await reopened.resolve(rescanned, tmdbKey: "", omdbKey: "", refresh: true) == correct)
        let record = try #require(await reopened.matchRecord(for: rescanned))
        #expect(record.isManual)
        #expect(record.explicitIDs["imdb"] == correct.mediaID)
        #expect(record.candidate.releaseInfo == "2020")
        #expect(await reopened.cachedLookups(for: AppleLibrarySeries.groups([rescanned])).metadata.values.first == correct)
        let duplicate = file("Dune.1984.mkv", source: source)
        #expect(await reopened.matchRecord(for: duplicate) == nil)
        #expect(original.id == "\(source):\(original.relativePath)")
    }
    @Test @MainActor func correctionKeepsFileProgressAndPublishesImmediately() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let file = file("Film.2024.mkv", source: UUID())
        let store = AppleLocalLibraryStore()
        let playback = ApplePlaybackStore(defaults: defaults)
        let identity = store.playbackID(file)
        playback.save(mediaID: identity, position: 120, duration: 1000)
        let saved = playback.progress(for: identity)
        let group = try #require(AppleLibrarySeries.groups([file]).first)
        let resolver = AppleLibraryMetadataResolver(directory: root) { _, _, _ in nil }
        let candidate = AppleCatalogItem(mediaID: "tt0000003", type: "movie", name: "Correct Film")
        try await store.correctMatch(group, candidate: candidate, provider: "fixture", resolver: resolver)
        #expect(store.catalogItem(for: group) == candidate)
        #expect(store.playbackID(file) == identity)
        #expect(playback.progress(for: identity) == saved)
        #expect(await resolver.matchRecord(for: file)?.isManual == true)
    }

    @Test @MainActor func rangeAndAirDateRowsSelectOnlySupportedFiles() throws {
        let source = UUID()
        let range = file("Show.S01E01-E02.mkv", source: source)
        let group = try #require(AppleLibrarySeries.groups([range]).first)
        let rows = AppleLocalLibraryStore.episodes(group: group, mediaID: "tt1", enriched: [])
        #expect(rows.map(\.episode) == [1, 2])
        #expect(rows.allSatisfy { AppleLocalLibraryStore.matchesEpisode(range, episode: $0) })
        #expect(!AppleLocalLibraryStore.matchesEpisode(range, episode: .init(id: "tt1:1:3", title: "", season: 1, episode: 3)))
        let dated = file("Show.2026-10-12.mkv", source: source)
        let datedGroup = try #require(AppleLibrarySeries.groups([dated]).first)
        let enriched = AppleMediaEpisode(id: "tt1:4:8", title: "News", season: 4, episode: 8, releaseInfo: "2026-10-12")
        #expect(AppleLocalLibraryStore.episodes(group: datedGroup, mediaID: "tt1", enriched: [enriched]) == [enriched])
        #expect(AppleLocalLibraryStore.matchesEpisode(dated, episode: enriched))
        #expect(AppleLibraryTitleParser.parse(name: "Show.2026-02-30.mkv").airDate == nil)
    }

    @Test func explicitIDsOutvoteDuplicateTitleAndYearEvidence() {
        let parsed = AppleLibraryTitleParser.parse(name: "Dune.2021.{imdb-tt0000001}.mkv")
        let selected = AppleCatalogItem(mediaID: "tt0000001", type: "movie", name: "Dune", releaseInfo: "1984")
        let other = AppleCatalogItem(mediaID: "tt0000002", type: "movie", name: "Dune", releaseInfo: "2021")
        #expect(parsed.explicitIDs["imdb"] == selected.mediaID)
        #expect(AppleLibraryMetadataResolver.bestMatch([other, selected], parsed: parsed) == selected)
        #expect(AppleLibraryTitleParser.parse(name: "Trailer.Park.Boys.S01E01.mkv").role == .feature)
        #expect(AppleLibraryTitleParser.parse(name: "Trailer.Park.Boys.S01E01.mkv").title == "Trailer Park Boys")
    }

    @Test func undatedPartsAndUnicodeRemainPlayable() throws {
        let source = UUID()
        let first = file("Été.cd1.mkv", source: source)
        let second = file("Été.cd2.mkv", source: source)
        let group = try #require(AppleLibrarySeries.groups([second, first]).first)
        #expect(group.items.count == 2)
        #expect(group.parsed.title == "Été")
        #expect(group.nextPart(after: first) == second)
    }

    @Test @MainActor func newerSecondPartIsNeverTheDefaultStartingFile() throws {
        let source = UUID()
        let first = file("Film.2024.part1.mkv", source: source)
        let second = AppleLibraryItem(sourceID: source, name: "Film.2024.part2.mkv",
            url: URL(fileURLWithPath: "/Film.2024.part2.mkv"), relativePath: "Movies/Film.2024.part2.mkv",
            sizeBytes: 1, addedAt: .now)
        let group = try #require(AppleLibrarySeries.groups([second, first]).first)
        let files = AppleLocalLibraryStore().localFiles(for: .init(mediaID: "local-film", type: "movie", name: "Film", releaseInfo: "2024"), group: group)
        #expect(files.first == first)
        #expect(group.nextPart(after: first) == second)
    }

    @Test func namedSequelsAreTitlesRatherThanFileParts() throws {
        let first = AppleLibraryTitleParser.parse(name: "Harry Potter and the Deathly Hallows Part 1 (2010).mkv")
        let second = AppleLibraryTitleParser.parse(name: "Harry Potter and the Deathly Hallows Part 2 (2011).mkv")
        #expect(first.title == "Harry Potter and the Deathly Hallows Part 1")
        #expect(second.title == "Harry Potter and the Deathly Hallows Part 2")
        #expect(first.year == 2010)
        #expect(second.year == 2011)
        #expect(first.part == nil && second.part == nil)
        for (number, year) in [(1, 2010), (2, 2011)] {
            let dotted = AppleLibraryTitleParser.parse(name: "Harry.Potter.and.the.Deathly.Hallows.Part.\(number).\(year).UHD.BluRay.2160p.mkv")
            #expect(dotted.title == "Harry Potter and the Deathly Hallows Part \(number)")
            #expect(dotted.year == year && dotted.part == nil)
        }
        let source = UUID()
        let files = [file("Harry Potter and the Deathly Hallows Part 1 (2010).mkv", source: source),
            file("Harry Potter and the Deathly Hallows Part 2 (2011).mkv", source: source)]
        let groups = AppleLibrarySeries.groups(files)
        #expect(groups.count == 2)
        #expect(groups.allSatisfy { group in group.items.allSatisfy { group.nextPart(after: $0) == nil } })
        #expect(AppleLibraryTitleParser.parse(name: "Kill Bill Vol. 1.mkv").title == "Kill Bill Vol 1")
        #expect(AppleLibraryTitleParser.parse(name: "Kill Bill Vol. 1.mkv").part == nil)
        let dune = AppleLibraryTitleParser.parse(name: "Dune Part Two (2024).mkv")
        #expect(dune.title == "Dune Part Two" && dune.year == 2024 && dune.part == nil)
        let odyssey = AppleLibraryTitleParser.parse(name: "2001 A Space Odyssey (1968).mkv")
        #expect(odyssey.title == "2001 A Space Odyssey" && odyssey.year == 1968)
    }

    @Test func seasonDiscFolderDoesNotAssignMovieParts() {
        let episode = AppleLibraryTitleParser.parse(name: "Example.S01E03.mkv", parentPath: "Shows/Example/Season 1/Disc 2")
        #expect(episode.kind == .show)
        #expect(episode.title == "Example")
        #expect(episode.season == 1 && episode.episode == 3)
        #expect(episode.part == nil)
        let ambiguous = AppleLibraryTitleParser.parse(name: "Pilot.mkv", parentPath: "Shows/Example/Season 1/Disc 2")
        #expect(ambiguous.kind == .show && ambiguous.part == nil && ambiguous.episode == nil)
    }

}
