import Foundation
import Testing
@testable import OpenStreamApple

/// N22c: a title page never draws a Play or a Download that is dead at rest.
@Suite("Title page shows no dead buttons")
struct AppleTitlePageNoDeadButtonTests {
    private let movie = AppleCatalogItem(mediaID: "tt1234567", type: "movie", name: "Fixture")
    private let series = AppleCatalogItem(mediaID: "tt1234567", type: "series", name: "Fixture")
    private let episode = AppleMediaEpisode(id: "tt1234567:1:3", title: "Third", season: 1, episode: 3, releaseInfo: nil)

    private let serverMovie = AppleCatalogItem(mediaID: "ms:00000000-0000-0000-0000-000000000001:movie", type: "movie", name: "Fixture")
    private let serverSeries = AppleCatalogItem(mediaID: "ms:00000000-0000-0000-0000-000000000001:series", type: "series", name: "Fixture")
    private func action(_ item: AppleCatalogItem, hasTrailer: Bool,
                        platform: AppleUIPlatform = .iOS) -> AppleTitlePagePolicy.PrimaryAction? {
        AppleTitlePagePolicy.titlePagePrimaryAction(
            type: item.type, progress: nil, selectedEpisode: item.type == "series" ? episode : nil,
            isPlayable: AppleTitlePagePolicy.hasPlaybackRoute(item: item),
            hasTrailer: hasTrailer, namesEpisode: true, platform: platform)
    }

    // MARK: The three states

    @Test func playableTitleOffersPlayAndDownload() {
        #expect(action(serverMovie, hasTrailer: true) == .play)
        #expect(action(serverSeries, hasTrailer: false) == .playEpisode("S1, E3"))
        #expect(AppleTitlePagePolicy.offersDownload(item: serverSeries))
    }

    @Test(arguments: [AppleUIPlatform.iOS, .macOS, .visionOS])
    func trailerOnlyTitleOffersPlayTrailerAndNoDownload(platform: AppleUIPlatform) {
        #expect(action(movie, hasTrailer: true, platform: platform) == .playTrailer)
        #expect(AppleTitlePagePolicy.offersDownload(item: movie) == false)
    }

    /// JEOPARDY! on the iPhone sim: no route to the title, no trailer.
    @Test(arguments: [AppleUIPlatform.iOS, .macOS, .visionOS, .tvOS])
    func titleWithNothingToPlayHasNoPrimaryButtonAndNoDownload(platform: AppleUIPlatform) {
        #expect(action(series, hasTrailer: false, platform: platform) == nil)
        #expect(AppleTitlePagePolicy.offersDownload(item: series) == false)
    }

    @Test func appleTVWithOnlyATrailerHasNoPrimaryButton() {
        #expect(action(movie, hasTrailer: true, platform: .tvOS) == nil)
    }

    // MARK: Downloads

    @Test func finishedDownloadKeepsItsButton() {
        #expect(AppleTitlePagePolicy.offersDownload(item: movie, hasCompletedDownload: true))
    }

    @Test func episodeDownloadShowsWhereOneCanStartOrOnADownloadedEpisode() {
        #expect(AppleTitlePagePolicy.showsEpisodeDownload(offersDownload: true, isDownloaded: false))
        #expect(AppleTitlePagePolicy.showsEpisodeDownload(offersDownload: false, isDownloaded: true))
        #expect(AppleTitlePagePolicy.showsEpisodeDownload(offersDownload: false, isDownloaded: false) == false)
    }
}
