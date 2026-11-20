import Foundation
import Testing
@testable import OpenStreamApple

@Suite(.serialized)
struct AppleCanonicalEpisodeTests {
    @Test
    func canonicalIDsRejectMalformedZeroAndCrossSeriesEpisodes() {
        #expect(AppleMediaIdentifier.canonicalMediaID("tt1234567") == "tt1234567")
        #expect(AppleMediaIdentifier.canonicalMediaID("tt1234567:0:1") == "tt1234567:0:1")
        #expect(AppleMediaIdentifier.canonicalMediaID("tt1234567:1:2") == "tt1234567:1:2")

        for value in [
            "tt1234567:", "tt1234567:1", "tt1234567::2", "tt1234567:-1:2",
            "tt1234567:1:0", "tt1234567:1:two", "tt7654321:1:2"
        ] {
            #expect(AppleMediaIdentifier.episodeIdentity(value, expectedSeriesID: "tt1234567") == nil)
        }
    }

    @Test
    func nextUnwatchedEpisodeSkipsCompletedEpisodesButKeepsPartialResumeTarget() throws {
        let episodes = [
            AppleMediaEpisode(id: "tt1234567:1:1", title: "Pilot", season: 1, episode: 1),
            AppleMediaEpisode(id: "tt1234567:1:2", title: "Second", season: 1, episode: 2),
            AppleMediaEpisode(id: "tt1234567:1:3", title: "Third", season: 1, episode: 3)
        ]

        let next = AppleMediaEpisodePolicy.nextUnwatched(
            in: 1,
            from: episodes,
            completedIDs: ["tt1234567:1:1"]
        )
        #expect(next?.id == "tt1234567:1:2")

        let partial = ApplePlaybackProgress(position: 120, duration: 600)
        #expect(!partial.isComplete)
        let resumeTarget = AppleMediaEpisodePolicy.nextUnwatched(
            in: 1,
            from: episodes,
            completedIDs: []
        )
        #expect(resumeTarget?.id == "tt1234567:1:1")
    }
}

@Test func episodeArtworkSurvivesCanonicalSelectionAndRejectsUnsafeURLs() throws {
    let good = AppleMediaEpisode(id: "tt1234567:1:1", title: "Pilot", season: 1, episode: 1,
        thumbnailURL: URL(string: "https://images.example/pilot.jpg"))
    let selection = try #require(AppleMediaEpisodeSelection(seriesMediaID: "tt1234567", episode: good))
    #expect(selection.episode.thumbnailURL == good.thumbnailURL)
    let unsafe = AppleMediaEpisode(id: "tt1234567:1:2", title: "Second", thumbnailURL: URL(string: "file:///private/image.jpg"))
    #expect(unsafe.thumbnailURL == nil)
}
