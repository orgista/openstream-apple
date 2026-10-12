import Testing
@testable import OpenStreamApple

/// Edge-case tests for AppleTitlePagePolicy.heroEpisode covering scenarios
/// not exercised by the existing ApplePlaybackRouteTests and
/// AppleWatchedHistoryTests suites.
@Suite struct AppleTitlePageHeroEpisodeEdgeTests {

    // MARK: - Helpers

    private var series: AppleCatalogItem {
        AppleCatalogItem(mediaID: "tt1234567", type: "series", name: "Fixture")
    }

    private func ep(_ season: Int, _ number: Int) -> AppleStremioEpisode {
        AppleStremioEpisode(
            id: "tt1234567:\(season):\(number)",
            title: "Episode \(season).\(number)",
            season: season,
            episode: number
        )
    }

    // MARK: - Tests

    @Test("saved partID names an episode not in the episodes list falls through to upNext")
    func savedPartIDNotInEpisodesList() throws {
        // Progress points to an episode that isn't in the supplied list.
        // savedEpisode returns nil; the function falls through to upNext.
        let progress = ApplePlaybackProgress(position: 120, duration: 2400, partID: "tt1234567:5:1")
        let episodes = [ep(1, 1), ep(1, 2)]
        let result = try #require(
            AppleTitlePagePolicy.heroEpisode(item: series, progress: progress, episodes: episodes))
        #expect(result.id == ep(1, 1).id)
    }

    @Test("saved progress finished on the last episode cycles back to first")
    func finishedProgressOnLastEpisode() throws {
        // All three episodes are "completed" and progress is on the last one
        // (isComplete → resumePosition is nil). savedEpisode yields nil, upNext
        // finds no uncompleted episode after the last and falls back to
        // candidates.first — the first episode of the show.
        let e1 = ep(1, 1), e2 = ep(1, 2), e3 = ep(1, 3)
        let progress = ApplePlaybackProgress(position: 2370, duration: 2400, partID: e3.id)
        #expect(progress.isComplete)
        #expect(progress.resumePosition == nil)
        let result = try #require(AppleTitlePagePolicy.heroEpisode(item: series, progress: progress,
                                                      episodes: [e1, e2, e3],
                                                      completedIDs: [e1.id, e2.id, e3.id]))
        #expect(result.id == e1.id)
    }

    @Test("saved progress finished on a middle episode picks next in order")
    func finishedProgressOnMiddleEpisode() throws {
        // S1E2 is finished; S1E1 and S1E3 are not.
        // savedEpisode is nil (resumePosition == nil). upNext finds S1E2 as
        // the last completed in order, then the first uncompleted after it —
        // which is S1E3 (not S1E1, which is before S1E2 in order).
        let e1 = ep(1, 1), e2 = ep(1, 2), e3 = ep(1, 3)
        let progress = ApplePlaybackProgress(position: 2300, duration: 2400, partID: e2.id)
        #expect(progress.isComplete)
        let result = try #require(AppleTitlePagePolicy.heroEpisode(
            item: series, progress: progress,
            episodes: [e1, e2, e3],
            completedIDs: [e2.id]))
        #expect(result.id == e3.id)  // first uncompleted after last completed in order
    }

    @Test("episodes out of order in the list still resolves correct upNext")
    func episodesOutOfOrder() throws {
        // Episodes are supplied S3, S1, S2 order — upNext should still return
        // S1E1 after internal sorting.
        let episodes = [ep(3, 1), ep(1, 1), ep(2, 1)]
        let result = try #require(
            AppleTitlePagePolicy.heroEpisode(item: series, progress: nil, episodes: episodes))
        #expect(result.id == ep(1, 1).id)
    }

    @Test("season-zero specials are used when they are the only episodes")
    func seasonZeroSpecialsOnly() throws {
        // A show with only specials (season 0) — upNext includes them as
        // fallback because there are no "regular" episodes.
        let specialA = ep(0, 1), specialB = ep(0, 2)
        let result = try #require(AppleTitlePagePolicy.heroEpisode(
            item: series, progress: nil, episodes: [specialA, specialB]))
        #expect(result.id == specialA.id)
    }

    @Test("no progress and no episodes returns nil")
    func noProgressNoEpisodes() {
        #expect(AppleTitlePagePolicy.heroEpisode(
            item: series, progress: nil, episodes: []) == nil)
    }

    @Test("movie with no episodes returns nil regardless of progress")
    func movieWithNoEpisodes() throws {
        let movie = AppleCatalogItem(mediaID: "tt9876543", type: "movie", name: "A Film")
        let progress = ApplePlaybackProgress(position: 600, duration: 7200, partID: "tt9876543")
        #expect(AppleTitlePagePolicy.heroEpisode(
            item: movie, progress: progress, episodes: []) == nil)
    }

    @Test("media-server item with saved partID not in episode list creates synthetic episode")
    func mediaServerSyntheticEpisode() throws {
        // The item has an ms: prefix mediaID and progress has a resumePosition;
        // savedEpisode finds nothing, but the media-server fallback creates a
        // synthetic episode from the partID.
        let msItem = AppleCatalogItem(
            mediaID: "ms:00000000-0000-0000-0000-000000000001:fixture",
            type: "series",
            name: "Local Series")
        let progress = ApplePlaybackProgress(position: 300, duration: 2400,
                                             partID: "tt1111111:2:5")
        let episodes: [AppleStremioEpisode] = []  // no episodes supplied
        let result = try #require(AppleTitlePagePolicy.heroEpisode(
            item: msItem, progress: progress, episodes: episodes))
        #expect(result.id == "tt1111111:2:5")
        #expect(result.title == "")
        #expect(result.season == 2)
        #expect(result.episode == 5)
    }
}
