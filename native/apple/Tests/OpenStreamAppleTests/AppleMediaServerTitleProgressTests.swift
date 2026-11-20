import Foundation
import Testing
@testable import OpenStreamApple

@Suite @MainActor
struct AppleMediaServerTitleProgressTests {
    @Test(arguments: [0.0, 450.0])
    func failedPlaybackThenCloseKeepsEpisodeAndSeriesResumePoints(unstartedPosition: Double) async throws {
        let domain = "failed-server-close-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = ApplePlaybackStore(defaults: defaults)
        let source = UUID()
        let series = AppleMediaServerItemReference(sourceID: source, itemID: "series").mediaID
        let episode = AppleMediaServerItemReference(sourceID: source, itemID: "episode").mediaID
        var request = ApplePlaybackRequest(url: try #require(URL(string: "https://fixture.example/episode.mp4")),
            mediaID: episode, sourceKind: .mediaServer)
        request.hints.progressParentID = series
        request.hints.progressPartID = "episode"
        store.save(request: request, position: 600, duration: 1800)
        let episodeProgress = store.progress(for: episode)
        let seriesProgress = store.progress(for: series)
        let engine = FakePlaybackEngine()
        engine.scriptedRoute = .surface
        engine.position = unstartedPosition
        engine.duration = 1800
        engine.failOnLoad = .init(kind: .network, message: "Fixture unavailable")
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        var writes = 0
        coordinator.progressWriter = { position, duration in
            writes += 1
            store.save(request: request, position: position, duration: duration)
        }
        await coordinator.begin(request)
        guard case .failed = coordinator.phase else {
            coordinator.stop()
            Issue.record("The fixture must fail before playback starts")
            return
        }
        ApplePlaybackProgressCoordinator.saveProgressOnClose(coordinator: coordinator, request: request, hasPlayed: false)
        coordinator.stop()
        #expect(writes == 0)
        #expect(store.progress(for: episode) == episodeProgress)
        #expect(store.progress(for: series) == seriesProgress)
    }

    @Test func tvOSCloseAfterSurfacePlaybackSavesEpisodeAndSeriesResumePoints() async throws {
        let domain = "played-server-close-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = ApplePlaybackStore(defaults: defaults)
        let source = UUID()
        let episode = AppleMediaServerItemReference(sourceID: source, itemID: "episode").mediaID
        let series = AppleMediaServerItemReference(sourceID: source, itemID: "series").mediaID
        var request = ApplePlaybackRequest(url: try #require(URL(string: "https://fixture.example/episode.mp4")),
            mediaID: episode, sourceKind: .mediaServer)
        request.hints.progressParentID = series
        request.hints.progressPartID = "episode"
        let engine = FakePlaybackEngine()
        engine.scriptedRoute = .surface
        engine.script([.playing])
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        coordinator.progressWriter = { position, duration in
            store.save(request: request, position: position, duration: duration)
        }
        await coordinator.begin(request)
        defer { coordinator.stop() }
        try #require(coordinator.phase == .playing)
        engine.position = 450
        engine.duration = 1800
        ApplePlaybackProgressCoordinator.saveProgressOnClose(coordinator: coordinator, request: request, hasPlayed: true)
        #expect(store.progress(for: episode)?.resumePosition == 450)
        #expect(store.progress(for: series)?.resumePosition == 450)
    }

    @Test(arguments: [
        (false, ApplePlaybackPresentationRoute.surface, false, 450.0, 1800.0, false),
        (true, .surface, false, 450, 1800, true),
        (true, .surface, true, 450, 1800, false),
        (true, .avPlayer, false, 450, 1800, false),
        (true, .surface, false, 0, 1800, false),
        (true, .surface, false, .nan, 1800, false),
        (true, .surface, false, 450, .infinity, false),
        (true, .surface, false, 450, 0, false),
    ])
    func closeProgressDecision(hasPlayed: Bool, route: ApplePlaybackPresentationRoute, isLive: Bool,
                              position: Double, duration: Double, expected: Bool) {
        #expect(ApplePlaybackProgressCoordinator.shouldSaveOnClose(hasPlayed: hasPlayed, route: route,
            isLive: isLive, position: position, duration: duration) == expected)
    }

    @Test func serverEpisodeSavesItsVersionAndTheSeriesResumeAction() throws {
        let domain = "server-episode-progress-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = ApplePlaybackStore(defaults: defaults)
        let source = UUID()
        let series = AppleMediaServerItemReference(sourceID: source, itemID: "fixture-series").mediaID
        let episode = AppleMediaServerItemReference(sourceID: source, itemID: "fixture-episode").mediaID
        var request = ApplePlaybackRequest(url: try #require(URL(string: "https://fixture.example/episode.mp4")),
            mediaID: episode, sourceKind: .mediaServer)
        request.hints.versionID = "original"
        request.hints.progressParentID = series
        request.hints.progressPartID = "fixture-episode"
        store.save(request: request, position: 450, duration: 1800)
        #expect(store.progress(for: episode)?.resumePosition == 450)
        #expect(store.versionProgress(itemID: episode, versionID: "original")?.resumePosition == 450)
        let selected = AppleMediaEpisode(id: "fixture-episode", title: "First", season: 1, episode: 1)
        let other = AppleMediaEpisode(id: "different-episode", title: "Second", season: 1, episode: 2)
        #expect(AppleTitlePagePolicy.primaryAction(type: "series", progress: store.progress(for: series),
            selectedEpisode: selected, isPlayable: true, hasTrailer: false) == .resume(episode: "S1, E1"))
        #expect(AppleTitlePagePolicy.primaryAction(type: "series", progress: store.progress(for: series),
            selectedEpisode: other, isPlayable: true, hasTrailer: false) == .play)
    }

    @Test func serverPlaybackPositionProducesResumeOnItsCatalogTitlePage() {
        let source = UUID()
        let reference = AppleMediaServerItemReference(sourceID: source, itemID: "fixture-movie")
        let item = AppleCatalogItem(mediaID: reference.mediaID, type: "movie",
                                    name: "Big Buck Bunny", releaseInfo: "2008")
        let saved = ApplePlaybackProgress(position: 65, duration: 634)
        let lookup: (String) -> ApplePlaybackProgress? = { $0 == reference.mediaID ? saved : nil }
        let key = AppleTitleProgressIdentity.key(
            among: AppleTitleProgressIdentity.candidates(item: item, sourceID: source), progress: lookup)
        #expect(key == reference.mediaID)
        #expect(AppleTitlePagePolicy.primaryAction(type: "movie", progress: key.flatMap(lookup),
            selectedEpisode: nil, isPlayable: true, hasTrailer: false) == .resume(episode: nil))
        #expect(AppleTitlePagePolicy.heroPrimaryAction(type: "movie", progress: key.flatMap(lookup),
            selectedEpisode: nil, isPlayable: true, trailer: .none) == .resume(episode: nil))
    }
}
