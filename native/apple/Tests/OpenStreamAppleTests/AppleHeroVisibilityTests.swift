import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import OpenStreamApple

/// N36: the iPhone and iPad page dots tick like the Mac's, and a hero nobody
/// can see holds its page and timer until it is back.
@Suite("Hero visibility")
struct AppleHeroVisibilityTests {
    @Test("The iPhone and iPad dot's fill redraws once per half device pixel",
          arguments: [(3, 12.0 / 120.0), (2, 12.0 / 80.0)] as [(CGFloat, TimeInterval)])
    func phoneFillTicksPerHalfPixel(displayScale: CGFloat, expected: TimeInterval) {
        let cycle = AppleHeroRotation.Cycle(count: 5, interval: 12)
        let tick = cycle.fillTickInterval(width: AppleHeroPageDots.activeWidth, displayScale: displayScale)
        #expect(abs(tick - expected) < 0.000_1)
        #expect(tick > 1.0 / 30.0)
        let pixelsPerTick = AppleHeroPageDots.activeWidth * displayScale * tick / 12
        #expect(pixelsPerTick <= 0.5 + 0.000_1)
    }

    @Test("Only an active scene, on screen, in a visible window counts as seen",
          arguments: [ScenePhase.active, .inactive, .background], [true, false])
    func visibleOnlyWhenEverythingIsShowing(phase: ScenePhase, isOnScreen: Bool) {
        for windowIsVisible in [true, false] {
            let visible = AppleHeroRotation.heroIsVisible(scenePhase: phase, isOnScreen: isOnScreen,
                                                         windowIsVisible: windowIsVisible)
            #expect(visible == (phase == .active && isOnScreen && windowIsVisible))
        }
    }

    @Test func aHiddenHeroHoldsItsCycle() {
        #expect(AppleHeroRotation.cycleIsPaused(isTouching: false, trailerIsPlaying: false, trailerIsMuted: true,
                                                isHidden: true))
        #expect(!AppleHeroRotation.cycleIsPaused(isTouching: false, trailerIsPlaying: false, trailerIsMuted: true,
                                                 isHidden: false))
    }

    @Test func aHeroPicksUpWhereItWasWhenItIsBack() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        var cycle = AppleHeroRotation.Cycle(count: 5, index: 2, interval: 12, now: start)
        // Covered 5 s in, for a minute.
        cycle.pause(at: start.addingTimeInterval(5))
        let back = start.addingTimeInterval(65)
        let movedWhileAway = cycle.advanceIfDue(at: back)
        #expect(!movedWhileAway)
        #expect(cycle.index == 2)
        #expect(abs(cycle.progress(at: back) - 5.0 / 12.0) < 0.000_1)
        #expect(cycle.dueDate == nil)
        cycle.resume(at: back)
        #expect(cycle.dueDate == back.addingTimeInterval(7))
        let early = cycle.advanceIfDue(at: back.addingTimeInterval(6.9))
        let due = cycle.advanceIfDue(at: back.addingTimeInterval(7))
        #expect(!early)
        #expect(due)
        #expect(cycle.index == 3)
    }
}
