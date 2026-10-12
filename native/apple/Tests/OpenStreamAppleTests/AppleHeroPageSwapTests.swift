import Testing
@testable import OpenStreamApple

/// A billboard page change is atomic: the page on screen stays until the next
/// one's art is ready (sim finding c, 2026-09-22).
@Suite("Hero page swap")
struct AppleHeroPageSwapTests {
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
}
