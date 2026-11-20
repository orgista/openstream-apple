import Testing
@testable import OpenStreamApple

/// A billboard page change is atomic: the page on screen stays until the next
/// one's art is ready (sim finding c, 2026-09-22).
@Suite("Hero page swap")
struct AppleHeroPageSwapTests {
    @Test func scrollingOutAndBackDoesNotDiscardHeroArt() {
        var visit = AppleHeroPageSwap.FadeVisit()
        visit.update(isActive: true, isCovered: false, routeRevision: 0)
        let revision = visit.revision
        visit.update(isActive: true, isCovered: false, routeRevision: 0)
        visit.update(isActive: true, isCovered: false, routeRevision: 0)
        #expect(visit.revision == revision)
    }

    @Test func theFirstPageNeverWaitsForItsArt() {
        #expect(AppleHeroPageSwap.pageToShow(shown: nil, requested: "hamlet") { _ in false } == "hamlet")
    }

    @Test func theShownPageStaysUntilTheRequestedArtIsReady() {
        #expect(AppleHeroPageSwap.pageToShow(shown: "hamlet", requested: "reacher") { _ in false } == "hamlet")
    }

    @Test func theRequestedPageShowsOnceItsArtIsReady() {
        #expect(AppleHeroPageSwap.pageToShow(shown: "hamlet", requested: "reacher") { $0 == "reacher" } == "reacher")
    }

    @Test func theShownPageIsNeverHeldBackByItsOwnReadiness() {
        #expect(AppleHeroPageSwap.pageToShow(shown: "hamlet", requested: "hamlet") { _ in false } == "hamlet")
    }

    @Test func failedOrTimedOutBackdropKeepsThePreviousPage() {
        for backdrop in [false, nil] as [Bool?] {
            #expect(!AppleHeroPageSwap.artIsReady(backdrop: backdrop, hasWordmark: true,
                                                 wordmark: true, timedOut: true))
        }
    }

    @Test func missingWordmarkMayUseTextOnceBackdropIsLoaded() {
        #expect(AppleHeroPageSwap.artIsReady(backdrop: true, hasWordmark: true,
                                            wordmark: nil, timedOut: true))
        #expect(AppleHeroPageSwap.artIsReady(backdrop: true, hasWordmark: false,
                                            wordmark: nil, timedOut: false))
        #expect(!AppleHeroPageSwap.artIsReady(backdrop: true, hasWordmark: true,
                                             wordmark: nil, timedOut: false))
    }

    @Test func warmsTheRequestedPageAndTheOneAfterIt() {
        #expect(AppleHeroPageSwap.pagesToWarm(requested: 1, count: 5) == [1, 2])
        #expect(AppleHeroPageSwap.pagesToWarm(requested: 4, count: 5) == [4, 0])
    }

    @Test func warmsOnePageWhenThereIsOnlyOne() {
        #expect(AppleHeroPageSwap.pagesToWarm(requested: 0, count: 1) == [0])
    }

    @Test func warmsNothingOutOfRange() {
        #expect(AppleHeroPageSwap.pagesToWarm(requested: 0, count: 0).isEmpty)
        #expect(AppleHeroPageSwap.pagesToWarm(requested: 5, count: 5).isEmpty)
    }

    /// Spec S3 G3: art 1.0 s, copy out then in within it, Reduce Motion cuts.
    @Test func pagesCrossfadeOverOneSecondAndReduceMotionCuts() throws {
        let fade = try #require(AppleHeroPageSwap.crossfade(reduceMotion: false))
        #expect(abs(fade.art - 1.0) <= 0.1)
        #expect(fade.copyOut > 0 && fade.copyIn > 0)
        #expect(fade.copyInDelay >= fade.copyOut)
        #expect(fade.copyInDelay + fade.copyIn <= fade.art)
        #expect(AppleHeroPageSwap.crossfade(reduceMotion: true) == nil)
    }
}
