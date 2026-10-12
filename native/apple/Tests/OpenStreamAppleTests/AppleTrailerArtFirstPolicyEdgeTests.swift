import Testing
@testable import OpenStreamApple

/// Edge cases for art-first trailers (owner, 2026-09-24) that
/// `AppleTrailerArtFirstPolicyTests` does not already cover: the parts of
/// `Art.settling` the main suite leaves untested, player states that are
/// empty, mistyped or simply not one the page ever sends, and how
/// `settling` and `mayRequestTrailer` compose for a title whose art fails.
@Suite struct AppleTrailerArtFirstPolicyEdgeTests {
    typealias Policy = AppleTrailerArtFirstPolicy

    @Test func pressedTrailerGiveUpIsThirtySeconds() {
        #expect(Policy.pressedTrailerGiveUp == 30)
    }

    /// The main suite only proves `.loaded` stays put through a later
    /// `.failed`. It stays put for the other two outcomes too, including
    /// the identity case (already-loaded settling with "loaded" again).
    @Test(arguments: [Policy.Art.loading, .loaded])
    func settlingStaysLoadedForOutcomesTheMainSuiteDoesNotCover(outcome: Policy.Art) {
        #expect(Policy.Art.loaded.settling(with: outcome) == .loaded)
    }

    /// The main suite only proves the *loading*/*failed* states change to
    /// whatever they are given. Settling with their own current state
    /// (a repeat report of the same outcome) leaves them unchanged too.
    @Test func settlingWhenNotYetLoadedIsIdempotentOnItsOwnState() {
        #expect(Policy.Art.loading.settling(with: .loading) == .loading)
        #expect(Policy.Art.failed.settling(with: .failed) == .failed)
    }

    /// The main suite covers loading→loaded and loading→failed. The other
    /// direction (a retry after a previous failure starts loading again) is
    /// untested: a stalled trailer request should be free to try again.
    @Test func settlingCanMoveBetweenTheTwoNotYetLoadedStates() {
        #expect(Policy.Art.failed.settling(with: .loading) == .loading)
    }

    /// Empty, mistyped or unknown states — none of which the page actually
    /// sends — must leave the video layer exactly where it was, the same as
    /// any other state `videoLayerChange` does not recognise.
    @Test(arguments: ["", "REVEALED", "Ready", "revealed ", " ended", "unknown-state"])
    func unrecognizedOrMistypedStatesLeaveTheVideoLayerUnchanged(state: String) {
        #expect(Policy.videoLayerChange(forPlayerState: state) == nil)
    }

    /// Same idea for `dropsVideoLayer`: an empty or mistyped state must not
    /// be mistaken for a state that ends the trailer for good.
    @Test(arguments: ["", "ERROR", "Error", "autoplay-Blocked", " error", "unknown-state"])
    func unrecognizedOrMistypedStatesDoNotDropTheVideoLayer(state: String) {
        #expect(Policy.dropsVideoLayer(forPlayerState: state) == false)
    }

    /// The main suite tests `mayRequestTrailer(art: .failed, ...)` directly
    /// with the `.failed` case literal. This checks the two APIs compose:
    /// once a *loading* title settles into `.failed`, a press still plays
    /// the trailer and an autoplay still does not.
    @Test func aTitleThatFinishesLoadingAsFailedStillHonoursAPressedPlay() {
        let settled = Policy.Art.loading.settling(with: .failed)
        #expect(Policy.mayRequestTrailer(art: settled, pressed: true))
        #expect(Policy.mayRequestTrailer(art: settled, pressed: false) == false)
    }
}
