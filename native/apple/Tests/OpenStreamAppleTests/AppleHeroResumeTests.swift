import Foundation
import Testing
@testable import OpenStreamApple

/// The home hero's "Resume S1, E3" has to start S1, E3 where it stopped. The
/// button opens the title page — the same page a Continue Watching tile opens
/// — and that page picked the next unwatched episode, not the one the saved
/// entry names (driver review, 2026-09-22). These pin the label and the
/// action to the same entry.
@Suite("Hero resume")
struct AppleHeroResumeTests {
    private let record = "instance:series:tt1234567"
    private let episodes = [
        AppleStremioEpisode(id: "tt1234567:1:1", title: "One", season: 1, episode: 1),
        AppleStremioEpisode(id: "tt1234567:1:2", title: "Two", season: 1, episode: 2),
        AppleStremioEpisode(id: "tt1234567:1:3", title: "Three", season: 1, episode: 3),
        AppleStremioEpisode(id: "tt1234567:2:1", title: "Four", season: 2, episode: 1),
    ]

    @MainActor
    private func makeStore() throws -> (ApplePlaybackStore, UserDefaults, String) {
        let suiteName = "openstream-hero-resume-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (ApplePlaybackStore(defaults: defaults), defaults, suiteName)
    }

    /// The hero asks this for every episode on each redraw; one store read
    /// must answer exactly what per-episode lookups would. Finished episodes
    /// leave the progress map, so the answer comes from the watched history.
    @MainActor
    @Test func completedEpisodesMatchPerEpisodeLookups() throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        store.save(mediaID: "tt1234567:1:1", position: 2_990, duration: 3_000)
        store.save(mediaID: "tt1234567:1:2", position: 600, duration: 3_000)
        store.save(mediaID: "tt1234567:2:1", position: 3_000, duration: 3_000)
        let ids = ["tt1234567:1:1", "tt1234567:1:2", "tt1234567:1:3", "tt1234567:2:1", ""]

        let batch = store.completedMediaIDs(among: ids)

        #expect(batch == ["tt1234567:1:1", "tt1234567:2:1"])
        #expect(batch == Set(ids.filter { store.isWatched(mediaID: $0) }))
    }

    @MainActor
    @Test(arguments: ["tt1234567:1:3", "tt1234567:2:1", "tt1234567:1:1"])
    func theButtonStartsTheEpisodeItNamesAtItsPosition(part: String) throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        // Episodes 1 and 2 finished: the page's own choice would be episode 3
        // (or the first of season 2), whatever the saved entry says.
        store.save(mediaID: "tt1234567:1:1", position: 2_990, duration: 3_000)
        store.save(mediaID: record, position: 1_234, duration: 3_000, partID: part)
        let progress = try #require(store.progress(for: record))

        let label = AppleBillboardCopy.playTitle(progress: progress, type: "series")
        let target = try #require(AppleStremioEpisodePolicy.savedEpisode(progress: progress, in: episodes))
        let identity = try #require(AppleStremioMetadataClient.episodeIdentity(part))

        #expect(label == "Resume S\(identity.season), E\(identity.episode)")
        #expect(target.id == part)
        #expect(target.season == identity.season && target.episode == identity.episode)
        #expect(AppleDetailResume.position(mediaID: record,
                                           partID: AppleDetailResume.partID(type: "series", mediaID: target.id),
                                           store: store) == 1_234)
    }

    @Test func playPromisesNothingAndPicksNothing() {
        // No entry, a position too early to resume, a finished episode.
        let entries: [ApplePlaybackProgress?] = [
            nil,
            .init(position: 5, duration: 3_000, partID: "tt1234567:1:3"),
            .init(position: 2_990, duration: 3_000, partID: "tt1234567:1:3"),
        ]
        for entry in entries {
            #expect(AppleBillboardCopy.playTitle(progress: entry, type: "series") == "Play")
            #expect(AppleStremioEpisodePolicy.savedEpisode(progress: entry, in: episodes) == nil)
        }
    }

    @Test func aSeriesEntryWithNoEpisodeSaysPlay() {
        // Saved before entries named their episode: the page cannot resume it.
        let legacy = ApplePlaybackProgress(position: 600, duration: 3_000)
        #expect(AppleBillboardCopy.playTitle(progress: legacy, type: "series") == "Play")
        #expect(AppleStremioEpisodePolicy.savedEpisode(progress: legacy, in: episodes) == nil)
        // A film has no parts, so the same entry is a real resume.
        #expect(AppleBillboardCopy.playTitle(progress: legacy, type: "movie") == "Resume")
    }

    @Test func anEpisodeMissingFromTheListLeavesThePageChoice() {
        let progress = ApplePlaybackProgress(position: 600, duration: 3_000, partID: "tt1234567:9:9")
        #expect(AppleStremioEpisodePolicy.savedEpisode(progress: progress, in: episodes) == nil)
    }
}
