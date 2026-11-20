import Testing
@testable import OpenStreamApple

/// The title page's hero holds its trailer by key (build 16 on the owner's
/// iPhone, 2026-10-08: the trailer showed for a moment, then the art came
/// back; a Trailers card often played nothing). The candidate list is the
/// enriched details' trailers followed by the source.s, and it changes under
/// a playing trailer as those details land late or are cleared for a reload.
@Suite struct AppleHeroTrailerKeyTests {
    typealias Policy = AppleTrailerArtFirstPolicy

    @Test func beforeAnyTrailerStartsTheHeroOffersTheFirstCandidate() {
        #expect(Policy.heroTrailerKey(pinned: nil, gaveUp: false, candidates: ["source-a", "source-b"]) == "source-a")
        #expect(Policy.heroTrailerKey(pinned: nil, gaveUp: false, candidates: []) == nil)
    }

    /// The details' trailers are prepended once they land: the key at index 0
    /// becomes a different video. The playing one must stay.
    @Test func aStartedTrailerSurvivesDetailsPrependingTheirTrailers() {
        let before = ["source-a", "source-b"]
        let after = ["tmdb-x", "tmdb-y", "source-a", "source-b"]
        let playing = Policy.heroTrailerKey(pinned: nil, gaveUp: false, candidates: before)
        #expect(Policy.heroTrailerKey(pinned: playing, gaveUp: false, candidates: after) == "source-a")
    }

    /// A reload clears the details and preview for a moment; the trailer that
    /// is playing must not be pulled out from under the viewer.
    @Test func aStartedTrailerSurvivesTheListEmptyingForAReload() {
        #expect(Policy.heroTrailerKey(pinned: "source-a", gaveUp: false, candidates: []) == "source-a")
    }

    @Test func aPressedCardWinsOverThePlaceItHadInTheList() {
        let list = ["tmdb-x", "tmdb-y", "source-a"]
        #expect(Policy.heroTrailerKey(pinned: "tmdb-y", gaveUp: false, candidates: list) == "tmdb-y")
    }

    @Test func afterEveryCandidateFailedThereIsNoTrailer() {
        #expect(Policy.heroTrailerKey(pinned: "source-a", gaveUp: true, candidates: ["source-a"]) == nil)
        #expect(Policy.heroTrailerKey(pinned: nil, gaveUp: true, candidates: ["source-a"]) == nil)
    }

    @Test func theNextCandidateIsSearchedForAfterTheFailedKeyWhereverItNowIs() {
        let list = ["tmdb-x", "tmdb-y", "source-a", "source-b"]
        #expect(Policy.nextCandidateStart(after: "source-a", in: list) == 3)
        #expect(Policy.nextCandidateStart(after: "source-b", in: list) == 4)
        // Gone from the list (or none): from the top; failed keys are skipped there.
        #expect(Policy.nextCandidateStart(after: "gone", in: list) == 0)
        #expect(Policy.nextCandidateStart(after: nil, in: list) == 0)
    }

    /// A provisional duration (a pre-roll, the first buffered range) must not
    /// become the preview's cap, or the trailer ends the moment it shows.
    @Test func thePreviewCapIgnoresAShortProvisionalDuration() throws {
        let url = try #require(AppleTrailerPreviewPolicy.embedURL(for: "fixture-key"))
        let html = AppleYouTubePreviewHTML.document(embedURL: url, startsPlaying: true, startupChromeCanShow: false)
        #expect(html.contains("var minimumTrustedDuration = 10;"))
        #expect(html.contains("var cap = duration >= minimumTrustedDuration ? Math.min(duration, previewCapSeconds) : previewCapSeconds;"))
        #expect(!html.contains("var cap = duration > 0 ?"))
        #expect(html.contains("duration: duration};"))
    }
}
