import Foundation
import Testing
@testable import OpenStreamApple

struct ApplePlaybackRouteTests {
    private let movie = AppleCatalogItem(mediaID: "tt1234567", type: "movie", name: "Fixture")
    private let series = AppleCatalogItem(mediaID: "tt1234567", type: "series", name: "Fixture")

    @Test func titleWithNoRouteOffersTrailer() {
        let playable = AppleTitlePagePolicy.hasPlaybackRoute(item: movie)
        #expect(playable == false)
        #expect(AppleTitlePagePolicy.primaryAction(type: movie.type, progress: nil, selectedEpisode: nil,
                                                 isPlayable: playable, hasTrailer: true) == .playTrailer)
    }

    /// iPad v2 (2026-10-01): an IPTV playlist, a network share or a media
    /// server being added is no route to a catalog title; only files matched
    /// to the title (`hasLocalGroup`) are.
    @Test func filesMatchedToTheTitleAreARoute() {
        #expect(AppleTitlePagePolicy.hasPlaybackRoute(item: movie, hasLocalGroup: true))
        #expect(AppleTitlePagePolicy.hasPlaybackRoute(item: series, hasLocalGroup: true))
    }

    @Test func watchOnShowsWithoutARoute() {
        let route = AppleTitlePagePolicy.hasPlaybackRoute(item: movie)
        let netflix = AppleWatchProvider(id: 8, name: "Netflix", offer: .subscription)
        #expect(route == false)
        #expect(AppleWatchOnPolicy.action(hasInAppSource: route, visibleProviders: [netflix]) != nil)
    }

    @Test func mediaServerItemIsARoute() {
        let item = AppleCatalogItem(mediaID: "ms:00000000-0000-0000-0000-000000000001:fixture", type: "series", name: "Fixture")
        #expect(AppleTitlePagePolicy.hasPlaybackRoute(item: item))
    }

    @Test func finishedDownloadIsARoute() {
        #expect(AppleTitlePagePolicy.hasPlaybackRoute(item: series, hasCompletedDownload: true))
    }

    /// N17e on the iPhone sim: nothing can play the title. The hero says Details;
    /// the title page must not offer an enabled Play that can only fail.
    @Test func withNoRouteHeroAndTitlePageAgreeNothingPlays() {
        let route = AppleTitlePagePolicy.hasPlaybackRoute(item: series)
        #expect(AppleTitlePagePolicy.heroPrimaryAction(
            type: series.type, progress: nil, selectedEpisode: nil, isPlayable: route, trailer: .none) == .details)
        #expect(AppleTitlePagePolicy.canStartPlayback(type: series.type, hasPlaybackRoute: route,
                                                     isPreparing: false, hasSelectedEpisode: true) == false)
    }

    @Test func titlePagePlayNeedsARouteAnEpisodeAndNoWork() {
        #expect(AppleTitlePagePolicy.canStartPlayback(type: "series", hasPlaybackRoute: true, isPreparing: false, hasSelectedEpisode: true))
        #expect(AppleTitlePagePolicy.canStartPlayback(type: "series", hasPlaybackRoute: true, isPreparing: false, hasSelectedEpisode: false) == false)
        #expect(AppleTitlePagePolicy.canStartPlayback(type: "series", hasPlaybackRoute: true, isPreparing: true, hasSelectedEpisode: true) == false)
        #expect(AppleTitlePagePolicy.canStartPlayback(type: "movie", hasPlaybackRoute: true, isPreparing: false, hasSelectedEpisode: false))
        #expect(AppleTitlePagePolicy.canStartPlayback(type: "movie", hasPlaybackRoute: false, isPreparing: false, hasSelectedEpisode: false) == false)
    }

    @Test func heroResumesExactSavedEpisode() throws {
        let first = AppleMediaEpisode(id: "tt1234567:1:1", title: "First", season: 1, episode: 1, releaseInfo: nil)
        let saved = AppleMediaEpisode(id: "tt1234567:2:3", title: "Saved", season: 2, episode: 3, releaseInfo: nil)
        let progress = ApplePlaybackProgress(position: 742, duration: 3_000, partID: saved.id)
        let selected = try #require(AppleTitlePagePolicy.heroEpisode(item: series, progress: progress, episodes: [first, saved]))
        #expect(selected.id == saved.id)
        #expect(progress.resumePosition == 742)
        #expect(AppleTitlePagePolicy.primaryAction(type: "series", progress: progress, selectedEpisode: selected,
            isPlayable: AppleTitlePagePolicy.hasPlaybackRoute(item: series, hasLocalGroup: true),
            hasTrailer: true) == .resume(episode: "S2, E3"))
    }

    @Test func mediaServerHeroRetainsResumeWithOpaqueEpisodeID() throws {
        let item = AppleCatalogItem(mediaID: "ms:00000000-0000-0000-0000-000000000001:fixture", type: "series", name: "Fixture")
        let progress = ApplePlaybackProgress(position: 742, duration: 3_000, partID: "server-episode")
        let selected = try #require(AppleTitlePagePolicy.heroEpisode(item: item, progress: progress, episodes: []))
        #expect(selected.id == progress.partID)
        #expect(AppleTitlePagePolicy.primaryAction(type: item.type, progress: progress, selectedEpisode: selected,
            isPlayable: AppleTitlePagePolicy.hasPlaybackRoute(item: item),
            hasTrailer: true) == .resume(episode: nil))
    }


    @Test func downloadedPlayLabelAgreesOnHeroAndTitlePage() {
        #expect(AppleTitlePagePolicy.PrimaryAction.play.displayTitle(hasCompletedDownload: true) == "Play Offline")
        #expect(AppleTitlePagePolicy.PrimaryAction.play.displayTitle(hasCompletedDownload: false) == "Play")
        #expect(AppleTitlePagePolicy.PrimaryAction.resume(episode: "S2, E3").displayTitle(hasCompletedDownload: true) == "Resume S2, E3")
    }


    @Test func heroChoosesSameNextUnwatchedEpisodeAsTitlePage() {
        let first = AppleMediaEpisode(id: "tt1234567:1:1", title: "First", season: 1, episode: 1, releaseInfo: nil)
        let next = AppleMediaEpisode(id: "tt1234567:1:2", title: "Next", season: 1, episode: 2, releaseInfo: nil)
        #expect(AppleTitlePagePolicy.heroEpisode(item: series, progress: nil, episodes: [first, next],
                                               completedIDs: [first.id]) == next)
        #expect(AppleTitlePagePolicy.heroEpisode(item: series, progress: nil, episodes: [first, next],
                                               localResumeEpisode: next) == next)
    }

    /// iOS 18.6 regression 2026-10-01: a title page whose first art 404'd
    /// stayed black, and black again after its trailer ended. It moves on to
    /// the next art the metadata named.
    @Test func titlePageHeroArtSkipsArtThatFailed() {
        let backdrop = URL(string: "https://fixture.example/backdrop.jpg")!
        let background = URL(string: "https://fixture.example/background.jpg")!
        let poster = URL(string: "https://fixture.example/poster.jpg")!
        let candidates: [URL?] = [nil, backdrop, background, nil, poster]
        #expect(AppleTitlePagePolicy.heroArtworkURL(candidates: candidates, failed: []) == backdrop)
        #expect(AppleTitlePagePolicy.heroArtworkURL(candidates: candidates, failed: [backdrop]) == background)
        #expect(AppleTitlePagePolicy.heroArtworkURL(candidates: candidates, failed: [backdrop, background]) == poster)
        #expect(AppleTitlePagePolicy.heroArtworkURL(candidates: candidates, failed: [backdrop, background, poster]) == nil)
    }
}
