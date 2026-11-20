import Testing
@testable import OpenStreamApple

@Suite("Apple TV title page opening focus")
struct AppleTVDetailOpeningFocusTests {
    @Test func onlyPlaySettlesTheOpening() {
        #expect(AppleTVDetailOpeningFocus.settles(on: .play))
        #expect(!AppleTVDetailOpeningFocus.settles(on: .rate))
        #expect(!AppleTVDetailOpeningFocus.settles(on: nil))
    }

    @Test(arguments: [AppleTVDetailFocus.startFromBeginning, .myList, .rate, .rateChoice(0)])
    func focusCarriedOntoTheTitleRowGoesBackToPlay(_ focus: AppleTVDetailFocus) {
        #expect(AppleTVDetailOpeningFocus.correction(for: focus, hasHadAnyFocus: true) == .play)
        #expect(AppleTVDetailOpeningFocus.correction(for: focus, hasHadAnyFocus: false) == .play)
    }

    @Test func aPageWithNothingFocusedAsksForPlay() {
        #expect(AppleTVDetailOpeningFocus.correction(for: nil, hasHadAnyFocus: false) == .play)
    }

    @Test func focusBelowTheTitleRowIsLeftAlone() {
        #expect(AppleTVDetailOpeningFocus.correction(for: nil, hasHadAnyFocus: true) == nil)
        #expect(AppleTVDetailOpeningFocus.correction(for: .play, hasHadAnyFocus: true) == nil)
    }
}

/// N22c: a title page with nothing to play has no Play, so the opening
/// focus goes to My List.
@Suite("Apple TV title page opening focus without Play")
struct AppleTVDetailOpeningFocusWithoutPlayTests {
    @Test func theTargetIsMyListWithoutPlay() {
        #expect(AppleTVDetailOpeningFocus.target(showsPlay: true) == .play)
        #expect(AppleTVDetailOpeningFocus.target(showsPlay: false) == .myList)
    }

    @Test func myListSettlesTheOpening() {
        #expect(AppleTVDetailOpeningFocus.settles(on: .myList, target: .myList))
        #expect(!AppleTVDetailOpeningFocus.settles(on: .rate, target: .myList))
    }

    @Test(arguments: [AppleTVDetailFocus.play, .rate, .rateChoice(0)])
    func otherTitleRowFocusGoesToMyList(_ focus: AppleTVDetailFocus) {
        #expect(AppleTVDetailOpeningFocus.correction(for: focus, hasHadAnyFocus: true, target: .myList) == .myList)
    }

    @Test func nothingFocusedAsksForMyList() {
        #expect(AppleTVDetailOpeningFocus.correction(for: nil, hasHadAnyFocus: false, target: .myList) == .myList)
        #expect(AppleTVDetailOpeningFocus.correction(for: .myList, hasHadAnyFocus: true, target: .myList) == nil)
    }
}

/// N41: Up from a shelf lands on the title row wherever the geometry says,
/// usually Rate; the page sends it to its primary action instead.
@Suite("Apple TV title page focus coming back up")
struct AppleTVDetailReturnFocusTests {
    @Test(arguments: [AppleTVDetailFocus.myList, .rate, .rateChoice(1)])
    func climbingOntoTheTitleRowGoesToPlay(_ landing: AppleTVDetailFocus) {
        #expect(AppleTVDetailReturnFocus.correction(from: nil, to: landing, target: .play) == .play)
    }

    @Test func withoutPlayItGoesToMyList() {
        #expect(AppleTVDetailReturnFocus.correction(from: nil, to: .rate, target: .myList) == .myList)
        #expect(AppleTVDetailReturnFocus.correction(from: nil, to: .myList, target: .myList) == nil)
    }

    @Test func landingOnPlayNeedsNothing() {
        #expect(AppleTVDetailReturnFocus.correction(from: nil, to: .play, target: .play) == nil)
    }

    @Test(arguments: [(AppleTVDetailFocus.play, AppleTVDetailFocus.myList), (.myList, .rate), (.rate, .rateChoice(0)),
                      (.rateChoice(2), .rate)])
    func movesAlongTheRowAreLeftAlone(_ old: AppleTVDetailFocus, _ new: AppleTVDetailFocus) {
        #expect(AppleTVDetailReturnFocus.correction(from: old, to: new, target: .play) == nil)
    }

    /// B22 again (full test 2026-10-01): Rate's button goes away as its
    /// choices appear, so focus passes through `nil` for a frame.
    @Test func openingRateThroughABriefNilKeepsTheChoice() {
        #expect(AppleTVDetailReturnFocus.correction(
            from: nil, to: .rateChoice(0), leftTitleRowAgo: .milliseconds(16), target: .play) == nil)
    }

    @Test func aLongStayBelowStillComesBackToPlay() {
        #expect(AppleTVDetailReturnFocus.correction(
            from: nil, to: .rate, leftTitleRowAgo: .seconds(2), target: .play) == .play)
    }

    @Test func leavingTheRowIsLeftAlone() {
        #expect(AppleTVDetailReturnFocus.correction(from: .rate, to: nil, target: .play) == nil)
        #expect(AppleTVDetailReturnFocus.correction(from: nil, to: nil, target: .play) == nil)
    }
}

/// N43: Down from Play on a movie landed on the third More Like This poster;
/// the Apple TV app goes to the first item of the next row.
@Suite("Apple TV title page focus going down to More Like This")
struct AppleTVDetailShelfEntryTests {
    @Test(arguments: [AppleTVDetailFocus.play, .myList, .rate, .rateChoice(1)])
    func downFromTheTitleRowGoesToTheFirstCard(_ old: AppleTVDetailFocus) {
        #expect(AppleTVDetailShelfEntry.correction(from: old, to: .similar("third"), firstSimilarID: "first")
            == .similar("first"))
    }

    @Test func landingOnTheFirstCardNeedsNothing() {
        #expect(AppleTVDetailShelfEntry.correction(from: .play, to: .similar("first"), firstSimilarID: "first") == nil)
    }

    @Test func movesAlongTheRowAreLeftAlone() {
        #expect(AppleTVDetailShelfEntry.correction(from: .similar("first"), to: .similar("second"),
                                                   firstSimilarID: "first") == nil)
    }

    /// The engine reports `nil` for a frame between Play and the card.
    @Test func aBriefNilRightAfterTheTitleRowIsTheSameMove() {
        #expect(AppleTVDetailShelfEntry.correction(from: nil, to: .similar("third"),
                                                   leftTitleRowAgo: .milliseconds(16), firstSimilarID: "first")
            == .similar("first"))
    }

    @Test func aLongStayBelowTheTitleRowIsAnotherMove() {
        #expect(AppleTVDetailShelfEntry.correction(from: nil, to: .similar("third"),
                                                   leftTitleRowAgo: .seconds(3), firstSimilarID: "first") == nil)
    }

    @Test func comingFromAnEpisodeIsLeftAlone() {
        // An episode or the season picker holds focus as `nil`.
        #expect(AppleTVDetailShelfEntry.correction(from: nil, to: .similar("third"), firstSimilarID: "first") == nil)
    }

    @Test func noSuggestionsNeedNothing() {
        #expect(AppleTVDetailShelfEntry.correction(from: .play, to: .similar("third"), firstSimilarID: nil) == nil)
        #expect(AppleTVDetailShelfEntry.correction(from: .play, to: .rate, firstSimilarID: "first") == nil)
    }

    @Test func upFromACardStillGoesToPlay() {
        #expect(AppleTVDetailReturnFocus.correction(from: .similar("third"), to: .rate, target: .play) == .play)
        #expect(AppleTVDetailReturnFocus.correction(from: .similar("third"), to: .play, target: .play) == nil)
    }

    @Test func aCardNeverTriggersTheOpeningOrReturnCorrections() {
        #expect(AppleTVDetailOpeningFocus.correction(for: .similar("first"), hasHadAnyFocus: true) == nil)
        #expect(AppleTVDetailReturnFocus.correction(from: nil, to: .similar("first"), target: .play) == nil)
        #expect(AppleTVDetailReturnFocus.correction(from: .play, to: .similar("first"), target: .play) == nil)
    }
}
