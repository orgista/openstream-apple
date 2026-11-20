import Foundation
import Testing
@testable import OpenStreamApple

@Suite("Title page optional tasks")
struct AppleTitlePageOptionalTaskPolicyTests {
    typealias Policy = AppleTitlePageOptionalTaskPolicy

    @Test func artworkWaitsForEveryProviderAndSkipsWhenOneBroughtArt() {
        // First partial answer: a later provider may still have the art.
        #expect(!Policy.resolvesFallbackArtwork(detailsSettled: false, hasItemPoster: false, hasDetailsArt: false))
        #expect(Policy.resolvesFallbackArtwork(detailsSettled: true, hasItemPoster: false, hasDetailsArt: false))
        #expect(!Policy.resolvesFallbackArtwork(detailsSettled: true, hasItemPoster: false, hasDetailsArt: true))
        #expect(!Policy.resolvesFallbackArtwork(detailsSettled: true, hasItemPoster: true, hasDetailsArt: false))
    }

    @Test func artworkTaskReRunsWhenTheDetailsSettle() {
        let generation = UUID()
        #expect(Policy.artworkTaskID(generation: generation, resolvedMediaID: "tt1234567", detailsSettled: false)
            != Policy.artworkTaskID(generation: generation, resolvedMediaID: "tt1234567", detailsSettled: true))
    }

    @Test func anEmptySeriesStillRecordsOnceItsLoadFinishes() {
        let generation = UUID()
        let loading = Policy.episodesTaskID(generation: generation, loadFinished: false, episodeCount: 0)
        let finishedEmpty = Policy.episodesTaskID(generation: generation, loadFinished: true, episodeCount: 0)
        #expect(loading != finishedEmpty)
        #expect(finishedEmpty != Policy.episodesTaskID(generation: generation, loadFinished: true, episodeCount: 8))
    }
}
