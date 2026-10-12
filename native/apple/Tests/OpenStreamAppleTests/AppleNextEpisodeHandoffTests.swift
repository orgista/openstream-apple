import Foundation
import Testing
@testable import OpenStreamApple

/// iPhone 27 v2 re-run: the "Next Episode in 20s" countdown ran out, the
/// player closed to the title page and nothing played (2/2). The end of an
/// episode now hands over to the next one, which keeps the service, audio and
/// subtitle choices of the one that ended, and Continue Watching keeps the
/// show once an episode is finished.
@MainActor
@Suite("Next episode handoff")
struct AppleNextEpisodeHandoffTests {
    private static let device = AppleStreamDeviceCapabilities(supportsHDR: true, supportsDolbyVision: false)

    // MARK: The end of the stream

    /// The last position tick lands a few frames short of the duration; the
    /// engine's end report is what starts the next episode.
    @Test func theEnginesEndStartsTheNextEpisodeEvenShortOfTheDuration() {
        #expect(AppleNextEpisodePolicy.shouldAutoAdvance(
            position: 1795.2, duration: 1800, nextTitle: "S1 E2", hasEnded: true))
    }

    @Test func aTickWithinHalfASecondOfTheEndCounts() {
        #expect(AppleNextEpisodePolicy.shouldAutoAdvance(position: 1799.6, duration: 1800, nextTitle: "S1 E2"))
        #expect(!AppleNextEpisodePolicy.shouldAutoAdvance(position: 1799.4, duration: 1800, nextTitle: "S1 E2"))
    }

    @Test func theEndStillRespectsNotNowAndTheSetting() {
        #expect(!AppleNextEpisodePolicy.shouldAutoAdvance(
            position: 1795, duration: 1800, nextTitle: "S1 E2", isDismissed: true, hasEnded: true))
        #expect(!AppleNextEpisodePolicy.shouldAutoAdvance(
            position: 1795, duration: 1800, nextTitle: "S1 E2", isEnabled: false, hasEnded: true))
        #expect(!AppleNextEpisodePolicy.shouldAutoAdvance(
            position: 1795, duration: 1800, nextTitle: nil, hasEnded: true))
    }

    /// The player stays open at the end only when the next episode is coming.
    @Test func thePlayerStaysOpenAtTheEndOnlyForAHandover() {
        #expect(AppleNextEpisodePolicy.handsOffAtEnd(hasNext: true, isLive: false, isDismissed: false, isEnabled: true))
        #expect(!AppleNextEpisodePolicy.handsOffAtEnd(hasNext: false, isLive: false, isDismissed: false, isEnabled: true))
        #expect(!AppleNextEpisodePolicy.handsOffAtEnd(hasNext: true, isLive: false, isDismissed: true, isEnabled: true))
        #expect(!AppleNextEpisodePolicy.handsOffAtEnd(hasNext: true, isLive: false, isDismissed: false, isEnabled: false))
        #expect(!AppleNextEpisodePolicy.handsOffAtEnd(hasNext: true, isLive: true, isDismissed: false, isEnabled: true))
    }

    @Test func theTransportTellsTheCoordinatorAboutTheHandover() {
        let coordinator = ApplePlaybackCoordinator(engine: FakePlaybackEngine())
        let model = AppleTransportOverlayModel(coordinator: coordinator, isLive: false)
        #expect(!coordinator.handsOffAtEnd)
        model.nextEpisodeTitle = "S1 E2"
        model.nextEpisode = { }
        #expect(coordinator.handsOffAtEnd)
        model.dismissNextEpisode()
        #expect(!coordinator.handsOffAtEnd)
    }

    /// SwiftUI can build more than one transport model for one player; the
    /// advance is remembered on the shared coordinator, so a second model
    /// sees it already happened.
    @Test func theAdvanceIsRememberedOnTheCoordinator() {
        let coordinator = ApplePlaybackCoordinator(engine: FakePlaybackEngine())
        let first = AppleTransportOverlayModel(coordinator: coordinator, isLive: false)
        var starts = 0
        first.nextEpisodeTitle = "S1 E2"
        first.nextEpisode = { starts += 1 }
        first.playNextEpisode()
        #expect(starts == 1)
        #expect(coordinator.hasAdvancedToNextEpisode)
    }

    // MARK: Source preference

    @Test func theNextEpisodeKeepsToTheServiceTheLastOnePlayedFrom() {
        func candidate(_ file: String, addon: String) -> AppleStremioHTTPPlaybackCandidate {
            AppleStremioHTTPPlaybackCandidate(title: file, sourceURL: URL(string: "https://media.fixture.example/\(file)")!,
                                              filename: file, sourceName: addon)
        }
        let streams = [
            candidate("A.1080p.mkv", addon: "Addon A"),
            candidate("B.1080p.mkv", addon: "Addon B"),
            candidate("B.720p.mkv", addon: "Addon B"),
        ]
        let preferred = streams[1].serviceKey
        let order = AppleStremioCandidateRanking.playbackOrder(
            streams, choice: .automatic, device: Self.device, preferredService: preferred)
        #expect(order.map(\.title) == ["B.1080p.mkv", "A.1080p.mkv", "B.720p.mkv"])
        // Without one the order is unchanged.
        let plain = AppleStremioCandidateRanking.playbackOrder(streams, choice: .automatic, device: Self.device)
        #expect(plain.map(\.title) == ["A.1080p.mkv", "B.1080p.mkv", "B.720p.mkv"])
    }

    // MARK: Audio and subtitle carry-over

    private let englishAudio = ApplePlaybackTrack(id: 1, title: "English", language: "eng", codec: "aac")
    private let spanishAudio = ApplePlaybackTrack(id: 2, title: "Spanish", language: "spa", codec: "aac")
    private let englishSubs = ApplePlaybackTrack(id: 10, title: "English", language: "en", codec: "subrip")
    private let spanishSubs = ApplePlaybackTrack(id: 11, title: "Spanish", language: "es", codec: "subrip")

    @Test func theChoicesAreCapturedByLanguage() {
        let carry = AppleTrackCarryOver.capture(
            audioTracks: [englishAudio, spanishAudio], activeAudioID: 2,
            subtitleTracks: [englishSubs, spanishSubs], activeSubtitleID: 11)
        #expect(carry.audioLanguage == "es")
        #expect(carry.subtitle == .language("es", hearingImpaired: false, forced: false))
    }

    @Test func subtitlesOffIsCarriedAsOff() {
        let carry = AppleTrackCarryOver.capture(
            audioTracks: [englishAudio], activeAudioID: 1,
            subtitleTracks: [englishSubs], activeSubtitleID: nil)
        #expect(carry.subtitle == .off)
        #expect(carry.subtitleSelection(in: [englishSubs]) == .some(nil))
    }

    /// Track ids differ from file to file; the next episode's tracks are
    /// matched by language, whatever form the language is written in.
    @Test func theNextEpisodesTracksAreMatchedByLanguage() {
        let carry = AppleTrackCarryOver(audioLanguage: "es", subtitle: .language("es", hearingImpaired: false, forced: false))
        let nextAudio = [ApplePlaybackTrack(id: 7, title: "English", language: "en"),
                         ApplePlaybackTrack(id: 8, title: "Comentario", language: "es", isCommentary: true),
                         ApplePlaybackTrack(id: 9, title: "Castellano", language: "spa")]
        let nextSubs = [ApplePlaybackTrack(id: 20, title: "English", language: "eng"),
                        ApplePlaybackTrack(id: 21, title: "Spanish", language: "Spanish")]
        #expect(carry.audioTrackID(in: nextAudio) == 9)
        #expect(carry.subtitleSelection(in: nextSubs) == .some(21))
    }

    @Test func aLanguageTheNextEpisodeLacksChangesNothing() {
        let carry = AppleTrackCarryOver(audioLanguage: "fr", subtitle: .language("fr", hearingImpaired: false, forced: false))
        #expect(carry.audioTrackID(in: [englishAudio]) == nil)
        #expect(carry.subtitleSelection(in: [englishSubs]) == nil)
        #expect(AppleTrackCarryOver.none.isEmpty)
    }

    // MARK: Continue Watching

    @Test func aFinishedEpisodeKeepsTheShowInContinueWatching() {
        let source = AppleSource(kind: .stremio, name: "Fixture", url: URL(string: "https://fixture.example/manifest.json")!,
                                 resources: ["catalog"], catalogs: [])
        let show = AppleCatalogItem(mediaID: "tt0072562", type: "series", name: "Saturday Night Live")
        var record = AppleMediaIngestion.catalogRecord(instanceID: source.id, item: show)
        record.progress = 1
        let finishedEpisode = ApplePlaybackProgress(position: 3_900, duration: 3_900, partID: "tt0072562:1:1")
        let midEpisode = ApplePlaybackProgress(position: 600, duration: 3_900, partID: "tt0072562:1:1")

        #expect(AppleContinueWatchingResolver.isUpNext(record, saved: finishedEpisode))
        #expect(!AppleContinueWatchingResolver.isUpNext(record, saved: midEpisode))
        #expect(AppleContinueWatchingResolver.inProgress([record], saved: { _ in finishedEpisode }) { _ in .now }.count == 1)
        // Without the saved episode it is a finished title, as before.
        #expect(AppleContinueWatchingResolver.inProgress([record]) { _ in .now }.isEmpty)

        let film = AppleCatalogItem(mediaID: "tt0111161", type: "movie", name: "A Film")
        var filmRecord = AppleMediaIngestion.catalogRecord(instanceID: source.id, item: film)
        filmRecord.progress = 1
        #expect(!AppleContinueWatchingResolver.isUpNext(filmRecord,
            saved: ApplePlaybackProgress(position: 100, duration: 100, partID: "tt0111161")))
    }
}
