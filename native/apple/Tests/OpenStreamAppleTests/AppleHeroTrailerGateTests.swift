import Foundation
import Testing
@testable import OpenStreamApple

/// Owner 2026-10-14: the iPhone hero's trailers are back, on the Apple TV
/// app's rules (REA report §1): muted autoplay once the still has settled,
/// stopped whenever the hero can't be seen.
@Suite struct AppleHeroTrailerGateTests {
    @Test func serverTrailerRunRestartsAfterReturningToTheVisibleHero() throws {
        let url = try #require(URL(string: "https://fixture.example/trailer.mp4"))
        let visible = AppleServerTrailerStageRun(url: url, plays: true, restart: nil,
            isPresented: true, sceneIsActive: true, isCovered: false, returnRevision: 0)
        let scrolledAway = AppleServerTrailerStageRun(url: url, plays: true, restart: nil,
            isPresented: false, sceneIsActive: true, isCovered: false, returnRevision: 0)
        let background = AppleServerTrailerStageRun(url: url, plays: true, restart: nil,
            isPresented: true, sceneIsActive: false, isCovered: false, returnRevision: 0)
        let returned = AppleServerTrailerStageRun(url: url, plays: true, restart: nil,
            isPresented: true, sceneIsActive: true, isCovered: false, returnRevision: 1)
        #expect(visible.plays)
        #expect(scrolledAway.plays == false)
        #expect(background.plays == false)
        #expect(visible != scrolledAway)
        #expect(visible != background)
        #expect(returned.plays)
        #expect(returned != visible)
    }

    @Test func anUnreviewedListCannotSettle() {
        let list = AppleHeroTrailerGate.SettlementInput(heroIDs: ["first"], catalogReviewDone: false)
        #expect(!list.isSettled(by: list))
        #expect(!AppleHeroTrailerGate.plays(.init(heroesSettled: list.isSettled(by: list))))
        #expect(AppleHeroTrailerGate.plays(.init(heroesSettled: list.isSettled(by: list), pressed: true)))
    }

    @Test func reviewCompletionNeedsItsOwnStableInterval() {
        let provisional = AppleHeroTrailerGate.SettlementInput(heroIDs: ["first"], catalogReviewDone: false)
        let reviewed = AppleHeroTrailerGate.SettlementInput(heroIDs: ["first"], catalogReviewDone: true)
        #expect(!reviewed.isSettled(by: provisional))
        #expect(!reviewed.isSettled(by: nil))
        #expect(reviewed.isSettled(by: reviewed))
    }

    @Test func aReplacementListRejectsThePreviousTimersCompletion() {
        let first = AppleHeroTrailerGate.SettlementInput(heroIDs: ["first", "next"], catalogReviewDone: true)
        let replacement = AppleHeroTrailerGate.SettlementInput(heroIDs: ["next", "first"], catalogReviewDone: true)
        #expect(!replacement.isSettled(by: first))
        #expect(replacement.isSettled(by: replacement))
        let reviewing = AppleHeroTrailerGate.SettlementInput(heroIDs: replacement.heroIDs, catalogReviewDone: false)
        #expect(!reviewing.isSettled(by: replacement))
    }

    @Test func autoplayRunsWhenEverythingAllowsIt() {
        #expect(AppleHeroTrailerGate.plays(.init()))
    }

    @Test(arguments: [
        AppleHeroTrailerGate.Conditions(autoPlaySetting: false),
        AppleHeroTrailerGate.Conditions(reduceMotion: true),
        AppleHeroTrailerGate.Conditions(lowPower: true),
        AppleHeroTrailerGate.Conditions(systemVideoAutoplay: false),
        AppleHeroTrailerGate.Conditions(sceneIsActive: false),
        AppleHeroTrailerGate.Conditions(halfVisible: false),
        AppleHeroTrailerGate.Conditions(isPresented: false),
        AppleHeroTrailerGate.Conditions(isCovered: true),
        AppleHeroTrailerGate.Conditions(windowIsVisible: false),
        AppleHeroTrailerGate.Conditions(art: .loading),
        AppleHeroTrailerGate.Conditions(art: .failed),
        AppleHeroTrailerGate.Conditions(heroesSettled: false),
    ])
    func autoplayStopsForEachRule(_ conditions: AppleHeroTrailerGate.Conditions) {
        #expect(!AppleHeroTrailerGate.plays(conditions))
    }

    @Test func aPressSkipsTheSettingFailedArtLowPowerAndTheSystemSwitch() {
        #expect(AppleHeroTrailerGate.plays(.init(autoPlaySetting: false, pressed: true)))
        #expect(AppleHeroTrailerGate.plays(.init(art: .failed, pressed: true)))
        // REA round 3 §1.2: Low Power and Auto-Play Video Previews gate only automatic playback.
        #expect(AppleHeroTrailerGate.plays(.init(lowPower: true, pressed: true)))
        #expect(AppleHeroTrailerGate.plays(.init(systemVideoAutoplay: false, pressed: true)))
        // The launch settle (`settleDelay`) holds back autoplay only.
        #expect(AppleHeroTrailerGate.plays(.init(heroesSettled: false, pressed: true)))
        #expect(!AppleHeroTrailerGate.plays(.init(art: .loading, pressed: true)))
        #expect(!AppleHeroTrailerGate.plays(.init(reduceMotion: true, pressed: true)))
        #expect(!AppleHeroTrailerGate.plays(.init(halfVisible: false, pressed: true)))
        #expect(!AppleHeroTrailerGate.plays(.init(isCovered: true, pressed: true)))
        #expect(!AppleHeroTrailerGate.plays(.init(sceneIsActive: false, pressed: true)))
    }

    // MARK: The cycle around a trailer

    private let start = Date(timeIntervalSinceReferenceDate: 1_000)

    @Test func thePageMovesOnASecondAfterItsTrailerEnds() {
        var cycle = AppleHeroRotation.Cycle(count: 3, now: start)
        // The trailer plays from 3 s to 93 s; the timer holds meanwhile.
        cycle.pause(at: start.addingTimeInterval(3))
        cycle.videoEnded(at: start.addingTimeInterval(93))
        #expect(cycle.dueDate == nil)
        cycle.resume(at: start.addingTimeInterval(93))
        #expect(cycle.dueDate == start.addingTimeInterval(93 + AppleHeroRotation.afterVideoDelay))
        #expect(AppleHeroRotation.afterVideoDelay == 1)
    }

    @Test func aRunningCycleAlsoMovesOnASecondAfterTheEnd() {
        var cycle = AppleHeroRotation.Cycle(count: 3, now: start)
        cycle.videoEnded(at: start.addingTimeInterval(2))
        #expect(cycle.dueDate == start.addingTimeInterval(3))
    }

    @Test func theLastPageWrapsASecondAfterItsTrailer() {
        var cycle = AppleHeroRotation.Cycle(count: 2, index: 1, now: start)
        cycle.videoEnded(at: start.addingTimeInterval(60))
        #expect(cycle.dueDate == start.addingTimeInterval(61))
        let wrapped = cycle.advanceIfDue(at: start.addingTimeInterval(61))
        #expect(wrapped)
        #expect(cycle.index == 0)
    }

    @Test func aFailedTrailerGivesTheStillAFullDwell() {
        var cycle = AppleHeroRotation.Cycle(count: 3, now: start)
        cycle.pause(at: start.addingTimeInterval(1))
        cycle.handle(.failed, at: start.addingTimeInterval(9))
        cycle.resume(at: start.addingTimeInterval(9))
        #expect(cycle.dueDate == start.addingTimeInterval(9 + AppleHeroRotation.interval))
    }

    /// The whole Home cycle, five pages, one of them with a trailer: it never
    /// stops, and it comes back round to the first page.
    @Test func theCycleAdvancesThroughEveryPageAndWraps() throws {
        var cycle = AppleHeroRotation.Cycle(count: 5, now: start)
        var now = start
        var visited: [Int] = [cycle.index]
        for _ in 0 ..< 5 {
            if cycle.index == 2 {
                // Page 3's trailer plays 0.5 s in and runs 45 s.
                cycle.pause(at: now.addingTimeInterval(0.5))
                now = now.addingTimeInterval(45.5)
                cycle.handle(.ended, at: now)
                cycle.resume(at: now)
                #expect(cycle.dueDate == now.addingTimeInterval(AppleHeroRotation.afterVideoDelay))
            }
            let due = try #require(cycle.dueDate)
            now = due
            let moved = cycle.advanceIfDue(at: now)
            #expect(moved)
            visited.append(cycle.index)
        }
        #expect(visited == [0, 1, 2, 3, 4, 0])
    }

    @Test func theCarouselSeesEachEndAndFailureOnce() {
        let ended = AppleHomeHeroTrailerStateKey.Value(lastEnd: UUID())
        #expect(ended.cycleEvent(after: .init()) == .ended)
        #expect(ended.cycleEvent(after: ended) == nil)
        let failed = AppleHomeHeroTrailerStateKey.Value(lastEnd: ended.lastEnd, lastFailure: UUID())
        #expect(failed.cycleEvent(after: ended) == .failed)
        #expect(failed.cycleEvent(after: failed) == nil)
        var value = AppleHomeHeroTrailerStateKey.defaultValue
        AppleHomeHeroTrailerStateKey.reduce(value: &value) { failed }
        #expect(value.lastFailure == failed.lastFailure)
    }

    @Test func noAdvanceWhileATrailerPlays() {
        #expect(AppleHeroRotation.cycleIsPaused(isTouching: false, trailerIsPlaying: true, trailerIsMuted: true))
        #expect(!AppleHeroRotation.cycleIsPaused(isTouching: false, trailerIsPlaying: false, trailerIsMuted: true))
    }

    @Test func theEndOfATrailerReachesTheCarousel() {
        var value = AppleHomeHeroTrailerStateKey.defaultValue
        let ended = UUID()
        AppleHomeHeroTrailerStateKey.reduce(value: &value) { .init(lastEnd: ended) }
        #expect(value.lastEnd == ended)
        // A page whose trailer is playing still wins.
        AppleHomeHeroTrailerStateKey.reduce(value: &value) { .init(isPlaying: true) }
        #expect(value.isPlaying)
        AppleHomeHeroTrailerStateKey.reduce(value: &value) { .init(lastEnd: UUID()) }
        #expect(value.isPlaying)
    }
}
