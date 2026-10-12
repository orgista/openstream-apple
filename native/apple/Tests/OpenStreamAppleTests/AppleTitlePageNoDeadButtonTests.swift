import Foundation
import Testing
@testable import OpenStreamApple

/// N22c: a title page never draws a Play or a Download that is dead at rest.
@Suite("Title page shows no dead buttons")
struct AppleTitlePageNoDeadButtonTests {
    private let movie = AppleCatalogItem(mediaID: "tt1234567", type: "movie", name: "Fixture")
    private let series = AppleCatalogItem(mediaID: "tt1234567", type: "series", name: "Fixture")
    private let episode = AppleStremioEpisode(id: "tt1234567:1:3", title: "Third", season: 1, episode: 3, releaseInfo: nil)

    private func source(resources: [String]) -> AppleSource {
        AppleSource(kind: .stremio, name: "Fixture", url: URL(string: "https://fixture.example/manifest.json")!,
                    resources: resources)
    }

    private var streaming: [AppleSource] { [source(resources: ["catalog", "meta", "stream"])] }
    private var metadataOnly: [AppleSource] { [source(resources: ["catalog", "meta"])] }

    private func action(_ item: AppleCatalogItem, sources: [AppleSource], hasTrailer: Bool,
                        platform: AppleUIPlatform = .iOS) -> AppleTitlePagePolicy.PrimaryAction? {
        AppleTitlePagePolicy.titlePagePrimaryAction(
            type: item.type, progress: nil, selectedEpisode: item.type == "series" ? episode : nil,
            isPlayable: AppleTitlePagePolicy.hasPlaybackRoute(item: item, sources: sources),
            hasTrailer: hasTrailer, namesEpisode: true, platform: platform)
    }

    // MARK: The three states

    @Test func playableTitleOffersPlayAndDownload() {
        #expect(action(movie, sources: streaming, hasTrailer: true) == .play)
        #expect(action(series, sources: streaming, hasTrailer: false) == .playEpisode("S1, E3"))
        #expect(AppleTitlePagePolicy.offersDownload(item: series, sources: streaming))
    }

    @Test(arguments: [AppleUIPlatform.iOS, .macOS, .visionOS])
    func trailerOnlyTitleOffersPlayTrailerAndNoDownload(platform: AppleUIPlatform) {
        #expect(action(movie, sources: metadataOnly, hasTrailer: true, platform: platform) == .playTrailer)
        #expect(AppleTitlePagePolicy.offersDownload(item: movie, sources: metadataOnly) == false)
    }

    /// JEOPARDY! on the iPhone sim: only a metadata add-on, no trailer.
    @Test(arguments: [AppleUIPlatform.iOS, .macOS, .visionOS, .tvOS])
    func titleWithNothingToPlayHasNoPrimaryButtonAndNoDownload(platform: AppleUIPlatform) {
        #expect(action(series, sources: metadataOnly, hasTrailer: false, platform: platform) == nil)
        #expect(action(series, sources: [], hasTrailer: false, platform: platform) == nil)
        #expect(AppleTitlePagePolicy.offersDownload(item: series, sources: metadataOnly) == false)
    }

    @Test func appleTVWithOnlyATrailerHasNoPrimaryButton() {
        #expect(action(movie, sources: metadataOnly, hasTrailer: true, platform: .tvOS) == nil)
    }

    // MARK: Downloads

    @Test func seriesWhoseEpisodesAreUnavailableOffersNoDownload() {
        #expect(AppleTitlePagePolicy.offersDownload(item: series, sources: streaming, episodesUnavailable: true) == false)
    }

    @Test func mediaServerTitleOffersDownloadWithoutAnAddOn() {
        let item = AppleCatalogItem(mediaID: "ms:00000000-0000-0000-0000-000000000001:fixture", type: "series", name: "Fixture")
        #expect(AppleTitlePagePolicy.offersDownload(item: item, sources: []))
    }

    @Test func finishedDownloadKeepsItsButton() {
        #expect(AppleTitlePagePolicy.offersDownload(item: movie, sources: metadataOnly, hasCompletedDownload: true))
    }

    @Test func episodeDownloadShowsWhereOneCanStartOrOnADownloadedEpisode() {
        #expect(AppleTitlePagePolicy.showsEpisodeDownload(offersDownload: true, isDownloaded: false))
        #expect(AppleTitlePagePolicy.showsEpisodeDownload(offersDownload: false, isDownloaded: true))
        #expect(AppleTitlePagePolicy.showsEpisodeDownload(offersDownload: false, isDownloaded: false) == false)
    }
}
