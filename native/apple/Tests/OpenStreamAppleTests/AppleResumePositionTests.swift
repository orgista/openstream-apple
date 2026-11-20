import Foundation
import Testing
@testable import OpenStreamApple

/// Pressing Play on a Continue Watching title has to start where the viewer
/// stopped. Every detail-page play path passed `resume: nil`, so it restarted
/// from zero even though the progress bar under the poster was correct
/// (owner 2026-09-14). A series keeps one entry under the show, so the stored
/// position also has to name the part it belongs to.
@Suite("Resume position")
struct AppleResumePositionTests {
    @MainActor
    private func makeStore() throws -> (ApplePlaybackStore, UserDefaults, String) {
        let suiteName = "openstream-resume-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (ApplePlaybackStore(defaults: defaults), defaults, suiteName)
    }

    @MainActor
    @Test func aFilmResumesWhereItStopped() throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        store.save(mediaID: "record:tt1234567", position: 1_800, duration: 7_200, partID: "tt1234567")
        #expect(AppleDetailResume.position(mediaID: "record:tt1234567", partID: "tt1234567", store: store) == 1_800)
    }

    @MainActor
    @Test func anotherEpisodeOfTheSameShowStartsAtTheBeginning() throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Half an hour into Reacher S1E1, stored under the show's record.
        store.save(mediaID: "record:reacher", position: 1_800, duration: 3_600, partID: "tt9288030:1:1")
        #expect(AppleDetailResume.position(mediaID: "record:reacher", partID: "tt9288030:1:1", store: store) == 1_800)
        #expect(AppleDetailResume.position(mediaID: "record:reacher", partID: "tt9288030:1:2", store: store) == nil)
    }

    @MainActor
    @Test func aPositionSavedBeforePartsExistedOnlyResumesSomethingWithoutOne() throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        store.save(mediaID: "record:legacy", position: 1_200, duration: 7_200)
        #expect(AppleDetailResume.position(mediaID: "record:legacy", partID: nil, store: store) == 1_200)
        #expect(AppleDetailResume.position(mediaID: "record:legacy", partID: "tt42:1:1", store: store) == nil)
    }

    @MainActor
    @Test func anUnwatchedOrFinishedTitleHasNoResumePoint() throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(AppleDetailResume.position(mediaID: "record:never-played", partID: nil, store: store) == nil)
        // Under 15 s in is a false start, not a resume point.
        store.save(mediaID: "record:glance", position: 9, duration: 7_200)
        #expect(AppleDetailResume.position(mediaID: "record:glance", partID: nil, store: store) == nil)
        // Finished titles are dropped from the store entirely.
        store.save(mediaID: "record:done", position: 7_190, duration: 7_200)
        #expect(AppleDetailResume.position(mediaID: "record:done", partID: nil, store: store) == nil)
    }

    /// Entries written by earlier builds have no `partID` key at all.
    @Test func progressDecodesWithoutAPartID() throws {
        let json = #"{"position":1200,"duration":7200,"updatedAt":760000000}"#
        let progress = try JSONDecoder().decode(ApplePlaybackProgress.self, from: Data(json.utf8))
        #expect(progress.partID == nil)
        #expect(progress.resumePosition == 1_200)
        #expect(progress.resumePosition(for: nil) == 1_200)
    }

    @MainActor
    @Test func thePartIDSurvivesTheRoundTripThroughDefaults() throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        store.save(mediaID: "record:dark-matter", position: 2_400, duration: 3_300, partID: "tt20918274:1:4")
        let reloaded = ApplePlaybackStore(defaults: defaults)
        #expect(reloaded.progress(for: "record:dark-matter")?.partID == "tt20918274:1:4")
        #expect(AppleDetailResume.position(mediaID: "record:dark-matter", partID: "tt20918274:1:4", store: reloaded) == 2_400)
    }
}

/// Only a series has parts. A film's resolved id can differ between launches
/// (metadata resolution answering or not), and tying its position to that id
/// would silently lose the resume point.
@Suite("Resume part identity")
struct AppleResumePartIdentityTests {
    @Test func onlyASeriesCarriesAPart() {
        #expect(AppleDetailResume.partID(type: "series", mediaID: "tt9288030:1:2") == "tt9288030:1:2")
        #expect(AppleDetailResume.partID(type: "movie", mediaID: "tt1234567") == nil)
        #expect(AppleDetailResume.partID(type: nil, mediaID: "tt1234567") == nil)
        #expect(AppleDetailResume.partID(type: "series", mediaID: nil) == nil)
    }

    @MainActor
    @Test func aFilmStillResumesWhenItsResolvedIDChanges() throws {
        let suiteName = "openstream-resume-part-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ApplePlaybackStore(defaults: defaults)

        // Saved while metadata had resolved the IMDB id.
        store.save(mediaID: "record:film", position: 2_000, duration: 7_200,
            partID: AppleDetailResume.partID(type: "movie", mediaID: "tt1234567"))
        // Next launch resolution failed and the raw catalog id stands in.
        let partID = AppleDetailResume.partID(type: "movie", mediaID: "catalog:film")
        #expect(AppleDetailResume.position(mediaID: "record:film", partID: partID, store: store) == 2_000)
    }
}
