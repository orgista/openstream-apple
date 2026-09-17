import Foundation
import Testing
@testable import OpenStreamApple

@MainActor @Test func localTitleMatchingPrefersIMDbAndDistinguishesRemakes() {
    let movie = AppleCatalogItem(mediaID: "tt1160419", type: "movie", name: "Dune", releaseInfo: "2021")
    #expect(AppleLocalLibraryStore.matches(movie, .init(mediaID: "tt1160419", type: "movie", name: "Dune: Part One", releaseInfo: "2021")))
    #expect(!AppleLocalLibraryStore.matches(movie, .init(mediaID: "tt0087182", type: "movie", name: "Dune", releaseInfo: "1984")))
    #expect(AppleLocalLibraryStore.matches(movie, .init(mediaID: "local-file", type: "movie", name: "DÚNE", releaseInfo: "2021–")))
    #expect(!AppleLocalLibraryStore.matches(movie, .init(mediaID: "local-file", type: "movie", name: "Dune", releaseInfo: "1984")))
    #expect(!AppleLocalLibraryStore.matches(movie, .init(mediaID: "local-file", type: "series", name: "Dune", releaseInfo: "2021")))
}

@MainActor @Test func localSeasonRowsKeepUncatalogedEpisodesAndDeduplicateCopies() {
    let source = UUID()
    let files = ["Show.S01E01.1080p.mkv", "Show.S01E01.2160p.mkv", "Show.S02E03.1080p.mkv"].map {
        AppleLibraryItem(sourceID: source, name: $0, url: URL(fileURLWithPath: "/" + $0), relativePath: $0, sizeBytes: 1)
    }
    let group = AppleLibrarySeries.groups(files)[0]
    let enriched = AppleStremioEpisode(id: "tt123:1:1", title: "Pilot", season: 1, episode: 1, overview: "Overview")
    let episodes = AppleLocalLibraryStore.episodes(group: group, mediaID: "tt123", enriched: [enriched])
    #expect(episodes.count == 2)
    #expect(episodes[0] == enriched)
    #expect(episodes[1].season == 2)
    #expect(episodes[1].episode == 3)
    #expect(AppleLocalLibraryStore.format(files[0]) == "1080P · MKV")
    let store = AppleLocalLibraryStore()
    let selected = store.localFiles(for: .init(mediaID: "tt123", type: "series", name: "Show"), group: group, episode: episodes[0])
    #expect(selected.count == 2)
    #expect(selected.first?.name == "Show.S01E01.2160p.mkv")
    #expect(store.localFiles(for: .init(mediaID: "tt123", type: "series", name: "Show"), group: group, episode: episodes[1]).count == 1)
}

@MainActor @Test func localUnnumberedEpisodePlaysTheFileShownByItsRow() {
    let file = AppleLibraryItem(sourceID: UUID(), name: "Pilot.mkv", url: URL(fileURLWithPath: "/Pilot.mkv"),
        relativePath: "Shows/Example/Season 1/Pilot.mkv", sizeBytes: 1)
    let group = AppleLibrarySeries.groups([file])[0]
    let episodes = AppleLocalLibraryStore.episodes(group: group, mediaID: "local-example", enriched: [])
    let files = AppleLocalLibraryStore().localFiles(for: .init(mediaID: "local-example", type: "series", name: "Example"),
        group: group, episode: episodes[0])
    #expect(files == [file])
}

@MainActor @Test func localSeriesResumesLatestUnfinishedEpisodeAcrossSeasons() {
    let source = UUID()
    let files = ["Example.S01E01.mkv", "Example.S02E03.mkv", "Example.S02E04.mkv"].map {
        AppleLibraryItem(sourceID: source, name: $0, url: URL(fileURLWithPath: "/" + $0), relativePath: $0, sizeBytes: 1)
    }
    let groups = AppleLibrarySeries.groups(files)
    let episodes = AppleLocalLibraryStore.episodes(group: groups[0], mediaID: "tt-example", enriched: [])
    let resumed = AppleLocalLibraryStore.resumeEpisode(in: groups, episodes: episodes) { file in
        let number = files.firstIndex(of: file)!
        return ApplePlaybackProgress(position: number == 2 ? 1000 : 120, duration: 1000,
            updatedAt: Date(timeIntervalSince1970: Double(number + 1)))
    }
    #expect(resumed?.season == 2)
    #expect(resumed?.episode == 3)
}
