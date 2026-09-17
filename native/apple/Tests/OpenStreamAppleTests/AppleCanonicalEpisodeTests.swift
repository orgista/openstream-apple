import Foundation
import Testing
@testable import OpenStreamApple

@Suite(.serialized)
struct AppleCanonicalEpisodeTests {
    @Test
    func canonicalIDsRejectMalformedZeroAndCrossSeriesEpisodes() {
        #expect(AppleStremioMetadataClient.canonicalMediaID("tt1234567") == "tt1234567")
        #expect(AppleStremioMetadataClient.canonicalMediaID("tt1234567:0:1") == "tt1234567:0:1")
        #expect(AppleStremioMetadataClient.canonicalMediaID("tt1234567:1:2") == "tt1234567:1:2")

        for value in [
            "tt1234567:", "tt1234567:1", "tt1234567::2", "tt1234567:-1:2",
            "tt1234567:1:0", "tt1234567:1:two", "tt7654321:1:2"
        ] {
            #expect(AppleStremioMetadataClient.episodeIdentity(value, expectedSeriesID: "tt1234567") == nil)
        }
    }

    @Test
    func metadataSourcesMergeValidEpisodesAndSelectionKeepsEpisodeTarget() async throws {
        let primary = AppleSource(
            kind: .stremio,
            name: "Primary",
            url: URL(string: "https://primary.fixture/manifest.json")!,
            manifestID: "com.linvo.cinemeta",
            resources: ["meta"]
        )
        let secondary = AppleSource(
            kind: .stremio,
            name: "Secondary",
            url: URL(string: "https://secondary.fixture/manifest.json")!,
            resources: ["meta"]
        )
        let client = AppleStremioMetadataClient { request in
            let host = request.url?.host ?? ""
            let body: String
            if host == "primary.fixture" {
                body = """
                {"meta":{"videos":[
                    {"id":"tt1234567:1:2","title":"Second","season":1,"episode":2},
                    {"id":"tt1234567:1:2","title":"Duplicate","season":1,"episode":2},
                    {"id":"tt1234567:1:0","title":"Zero","season":1,"episode":0},
                    {"id":"tt7654321:1:1","title":"Other Series","season":1,"episode":1},
                    {"id":"tt1234567:1:3","title":"Malformed Number","season":"bad","episode":3},
                    {"title":"Missing ID"},
                    {"id":"tt1234567:1:4","title":"Fourth","season":1,"episode":4}
                ]}}
                """
            } else {
                body = """
                {"meta":{"videos":[
                    {"id":"tt1234567:0:1","title":"Special","season":0,"episode":1},
                    {"id":"tt1234567:1:1","title":"Pilot","season":"1","episode":"1"},
                    {"id":"tt1234567:1:3","title":"Third","season":1,"episode":3}
                ]}}
                """
            }
            return (
                Data(body.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }

        let episodes = try await client.episodes(
            sources: [primary, secondary],
            preferredSourceID: primary.id,
            mediaID: "tt1234567"
        )

        #expect(episodes.map(\.id) == [
            "tt1234567:0:1", "tt1234567:1:1", "tt1234567:1:2",
            "tt1234567:1:3", "tt1234567:1:4"
        ])
        #expect(episodes.map(\.displayTitle) == [
            "S0 E1 · Special", "S1 E1 · Pilot", "S1 E2 · Second",
            "S1 E3 · Third", "S1 E4 · Fourth"
        ])

        #expect(AppleStremioEpisodePolicy.initialSeason(in: episodes) == 1)
        #expect(AppleStremioEpisodePolicy.initialSeason(in: episodes.filter { $0.season == 0 }) == 0)

        let selected = try #require(episodes.first { $0.id == "tt1234567:1:3" })
        let selection = try #require(
            AppleStremioEpisodeSelection(seriesMediaID: "tt1234567", episode: selected)
        )
        let item = AppleCatalogItem(mediaID: "tt1234567", type: "series", name: "Series")
        let playbackItem = item.withMediaID(selection.mediaID)
        #expect(selection.mediaID == "tt1234567:1:3")
        #expect(selection.displayTitle == "S1 E3 · Third")
        #expect(playbackItem.mediaID == selection.mediaID)
        #expect(playbackItem.mediaID != "tt1234567")
    }

    @Test
    func nextUnwatchedEpisodeSkipsCompletedEpisodesButKeepsPartialResumeTarget() throws {
        let episodes = [
            AppleStremioEpisode(id: "tt1234567:1:1", title: "Pilot", season: 1, episode: 1),
            AppleStremioEpisode(id: "tt1234567:1:2", title: "Second", season: 1, episode: 2),
            AppleStremioEpisode(id: "tt1234567:1:3", title: "Third", season: 1, episode: 3)
        ]

        let next = AppleStremioEpisodePolicy.nextUnwatched(
            in: 1,
            from: episodes,
            completedIDs: ["tt1234567:1:1"]
        )
        #expect(next?.id == "tt1234567:1:2")

        let partial = ApplePlaybackProgress(position: 120, duration: 600)
        #expect(!partial.isComplete)
        let resumeTarget = AppleStremioEpisodePolicy.nextUnwatched(
            in: 1,
            from: episodes,
            completedIDs: []
        )
        #expect(resumeTarget?.id == "tt1234567:1:1")
    }
}

@Test func episodeArtworkSurvivesCanonicalSelectionAndRejectsUnsafeURLs() throws {
    let good = AppleStremioEpisode(id: "tt1234567:1:1", title: "Pilot", season: 1, episode: 1,
        thumbnailURL: URL(string: "https://images.example/pilot.jpg"))
    let selection = try #require(AppleStremioEpisodeSelection(seriesMediaID: "tt1234567", episode: good))
    #expect(selection.episode.thumbnailURL == good.thumbnailURL)
    let unsafe = AppleStremioEpisode(id: "tt1234567:1:2", title: "Second", thumbnailURL: URL(string: "file:///private/image.jpg"))
    #expect(unsafe.thumbnailURL == nil)
}
