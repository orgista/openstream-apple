import Foundation
import Testing
@testable import OpenStreamApple

/// The Apple TV Discover hero's paging and cycle rules (N12).
@Suite("Apple TV hero paging")
struct AppleTVHeroPagingTests {
    @Test func theLeftStopTurnsBackAndReturnsFocusToPlay() {
        #expect(AppleTVHeroPaging.turn(for: .previousPage) == .init(offset: -1, refocus: .play))
    }

    @Test func theRightStopTurnsOnAndReturnsFocusToTheLastButton() {
        #expect(AppleTVHeroPaging.turn(for: .nextPage) == .init(offset: 1, refocus: .details))
    }

    @Test(arguments: [AppleTVHeroPaging.Target.play, .myList, .details])
    func buttonsNeverTurnThePage(_ target: AppleTVHeroPaging.Target) {
        #expect(AppleTVHeroPaging.turn(for: target) == nil)
    }

    @Test func detailsFocusFallsBackToMyListWhenThePrimaryAlreadyOpensDetails() {
        #expect(AppleTVHeroPaging.availableTarget(.details, showsDetailsButton: false) == .myList)
        #expect(AppleTVHeroPaging.availableTarget(.details, showsDetailsButton: true) == .details)
    }

    @Test(arguments: [AppleTVHeroPaging.Target.play, .myList, .previousPage, .nextPage])
    func hidingDetailsKeepsOtherFocusTargets(_ target: AppleTVHeroPaging.Target) {
        #expect(AppleTVHeroPaging.availableTarget(target, showsDetailsButton: false) == target)
    }

    @Test func noFocusNeverTurnsThePage() {
        #expect(AppleTVHeroPaging.turn(for: nil) == nil)
    }

    @Test func theStopsOnlyTakeFocusFromInsideTheHero() {
        #expect(AppleTVHeroPaging.stopsAreFocusable(focused: .play, pageCount: 5))
        #expect(AppleTVHeroPaging.stopsAreFocusable(focused: .nextPage, pageCount: 5))
        // Focus in the tab bar or a row: down or up can never land on a stop.
        #expect(!AppleTVHeroPaging.stopsAreFocusable(focused: nil, pageCount: 5))
    }

    @Test func oneOrNoPagesHasNothingToTurnTo() {
        #expect(!AppleTVHeroPaging.stopsAreFocusable(focused: .play, pageCount: 1))
        #expect(!AppleTVHeroPaging.stopsAreFocusable(focused: .play, pageCount: 0))
    }

    /// N43: Down from the tab bar (or Up from a row) lands on the nearest
    /// button; the Apple TV app's hero lands on its primary one.
    @Test(arguments: [AppleTVHeroPaging.Target.play, .myList, .details])
    func focusArrivingInTheHeroGoesToPlay(_ arriving: AppleTVHeroPaging.Target) {
        #expect(AppleTVHeroPaging.entry(arriving: arriving, returningTo: nil) == .play)
    }

    @Test func closingThePageDetailsOpenedReturnsToDetails() {
        #expect(AppleTVHeroPaging.entry(arriving: .details, returningTo: .details) == .details)
    }

    @Test func arrivingSomewhereElseThanTheOpenerStillGoesToPlay() {
        #expect(AppleTVHeroPaging.entry(arriving: .myList, returningTo: .details) == .play)
        #expect(AppleTVHeroPaging.entry(arriving: .play, returningTo: .details) == .play)
    }

    @Test func theCycleHoldsForInputAndCoversNotForFocus() {
        #expect(!AppleTVHeroPaging.cycleIsPaused(holdingForInput: false, isCovered: false))
        #expect(AppleTVHeroPaging.cycleIsPaused(holdingForInput: true, isCovered: false))
        #expect(AppleTVHeroPaging.cycleIsPaused(holdingForInput: false, isCovered: true))
        #expect(AppleTVHeroPaging.inputHold == .seconds(5))
    }

    @Test func focusMovedByTheCarouselIsNotRemoteInput() {
        #expect(!AppleTVHeroPaging.isRemoteInput(focusedNow: .myList, movedByCode: .myList))
        #expect(!AppleTVHeroPaging.isRemoteInput(focusedNow: .play, movedByCode: .play))
        #expect(AppleTVHeroPaging.isRemoteInput(focusedNow: .details, movedByCode: .myList))
        #expect(AppleTVHeroPaging.isRemoteInput(focusedNow: .play, movedByCode: nil))
        #expect(AppleTVHeroPaging.isRemoteInput(focusedNow: nil, movedByCode: .play))
    }

    /// Spec S3 G2: Apple TV idle on Home with Play focused turns at least four
    /// pages in 60 s. Focus sits on Play the whole time; nothing holds.
    @Test func anIdleHeroWithPlayFocusedTurnsAPageEveryDwell() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        #expect(!AppleTVHeroPaging.cycleIsPaused(holdingForInput: false, isCovered: false))
        var cycle = AppleHeroRotation.Cycle(count: 5, now: start)
        var turns = 0
        while let due = cycle.dueDate, due <= start.addingTimeInterval(60) {
            if cycle.advanceIfDue(at: due) { turns += 1 }
        }
        #expect(turns >= 4)
        #expect(turns == Int(60 / AppleHeroRotation.interval))
    }

    @Test func inputHoldsThePageAndTheTimerRunsOnFromWhereItStopped() throws {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        var cycle = AppleHeroRotation.Cycle(count: 3, now: start)
        cycle.pause(at: start.addingTimeInterval(2))
        let inputHold = TimeInterval(AppleTVHeroPaging.inputHold.components.seconds)
        let released = start.addingTimeInterval(2 + inputHold)
        #expect(cycle.dueDate == nil)
        cycle.resume(at: released)
        let due = try #require(cycle.dueDate)
        #expect(due == released.addingTimeInterval(cycle.interval - 2))
    }

    @Test func turningWhilePausedKeepsTheCycleHeldWithAFreshTimer() throws {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        var cycle = AppleHeroRotation.Cycle(count: 5, now: start)
        cycle.pause(at: start.addingTimeInterval(6))
        let turn = try #require(AppleTVHeroPaging.turn(for: .previousPage))
        cycle.step(by: turn.offset, at: start.addingTimeInterval(7))
        #expect(cycle.index == 4)
        #expect(cycle.isPaused)
        #expect(cycle.progress(at: start.addingTimeInterval(60)) == 0)
        #expect(cycle.dueDate == nil)
    }
}
