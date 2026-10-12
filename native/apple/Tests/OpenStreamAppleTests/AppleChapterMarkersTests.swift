import Foundation
import Testing
@testable import OpenStreamApple

/// Skip Intro from the stream's own chapter markers. Approved 2026-09-15;
/// audio fingerprinting across a season is a separate, parked decision.
@Suite("Chapter markers")
struct AppleChapterMarkersTests {
    private func chapter(_ title: String, _ start: Double, _ end: Double) -> AppleChapter {
        AppleChapter(title: title, start: start, end: end)
    }

    private var episode: [AppleChapter] {
        [chapter("Recap", 0, 30), chapter("Opening Credits", 30, 90), chapter("Act One", 90, 1500)]
    }

    @Test func theOpeningIsFound() {
        let intro = AppleChapterMarkers.intro(in: episode, duration: 1500)
        #expect(intro?.start == 30)
        #expect(AppleChapterMarkers.skipDestination(intro: intro!) == 90)
    }

    @Test func spellingAndPunctuationDoNotMatter() {
        for name in ["Intro", "intro", "OPENING", "opening-credits", "Main  Titles", "Theme Song", "OP"] {
            let found = AppleChapterMarkers.intro(in: [chapter(name, 0, 60)], duration: 1500)
            #expect(found != nil, "failed for \(name)")
        }
    }

    /// The whole point of matching whole names rather than substrings: a
    /// documentary's first chapter is content, not an opening sequence.
    @Test func introductionIsNotAnIntro() {
        #expect(AppleChapterMarkers.intro(in: [chapter("Introduction", 0, 240)], duration: 3600) == nil)
        #expect(AppleChapterMarkers.intro(in: [chapter("Introducing the Cast", 0, 60)], duration: 3600) == nil)
    }

    @Test func aStreamWithNoChaptersOffersNothing() {
        #expect(AppleChapterMarkers.intro(in: [], duration: 1500) == nil)
        #expect(AppleChapterMarkers.intro(in: [chapter("Act One", 0, 1500)], duration: 1500) == nil)
    }

    /// A mislabelled file whose "opening" is most of the runtime must not
    /// offer to skip the programme.
    @Test func anOpeningThatIsMostOfTheRuntimeIsRejected() {
        #expect(AppleChapterMarkers.intro(in: [chapter("Opening", 0, 1400)], duration: 1500) == nil)
    }

    @Test func anOpeningTooShortOrTooLongIsRejected() {
        #expect(AppleChapterMarkers.intro(in: [chapter("Opening", 0, 3)], duration: 1500) == nil)
        #expect(AppleChapterMarkers.intro(in: [chapter("Opening", 0, 400)], duration: 36000) == nil)
    }

    // MARK: When the button shows

    @Test func theButtonShowsOnlyInsideTheOpening() {
        let intro = chapter("Opening Credits", 30, 90)
        #expect(!AppleChapterMarkers.shouldOfferSkip(position: 10, intro: intro))
        #expect(AppleChapterMarkers.shouldOfferSkip(position: 30, intro: intro))
        #expect(AppleChapterMarkers.shouldOfferSkip(position: 89, intro: intro))
        #expect(!AppleChapterMarkers.shouldOfferSkip(position: 90, intro: intro))
    }

    /// Once skipped, seeking back must not put the button up again and invite
    /// a loop.
    @Test func skippingIsStickyForTheRestOfTheItem() {
        let intro = chapter("Opening Credits", 30, 90)
        #expect(!AppleChapterMarkers.shouldOfferSkip(position: 45, intro: intro, hasSkipped: true))
    }

    /// Full test 2026-09-30: 16 chapters reported, no marks on the scrubber.
    @Test func chapterStartsBecomeScrubberMarks() {
        let movie = [chapter("Chapter 01", 0, 600), chapter("Chapter 02", 600, 1800),
                     chapter("Chapter 03", 1800, 3600), chapter("Duplicate", 1800, 3600),
                     chapter("Past the end", 4000, 4100)]
        #expect(AppleChapterMarkers.scrubberFractions(chapters: movie, duration: 3600) == [600.0 / 3600, 0.5])
    }

    @Test func noRuntimeMeansNoMarks() {
        #expect(AppleChapterMarkers.scrubberFractions(chapters: episode, duration: nil).isEmpty)
        #expect(AppleChapterMarkers.scrubberFractions(chapters: episode, duration: 0).isEmpty)
    }

    @Test func noIntroMeansNoButton() {
        #expect(!AppleChapterMarkers.shouldOfferSkip(position: 45, intro: nil))
    }
}
