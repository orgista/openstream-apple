#if os(macOS)
import CoreGraphics
import Foundation
import Testing
@testable import OpenStreamApple

@Suite("Mac touch activity")
struct AppleMacInteractionActivityTests {
    private let start = Date(timeIntervalSinceReferenceDate: 100)

    @Test("An idle view has no tap hold")
    func initiallyIdle() {
        let activity = AppleMacInteractionActivity()
        #expect(activity.isActive == false)
        #expect(activity.expiresAt == nil)
    }

    @Test("The completed timer clears its hold without checking the wall clock again")
    func expiresAfterThreeSeconds() {
        var activity = AppleMacInteractionActivity()
        activity.record(at: start)
        #expect(activity.expiresAt == start.addingTimeInterval(3))
        activity.expire(deadline: start.addingTimeInterval(3))
        #expect(activity.isActive == false)
        #expect(activity.expiresAt == nil)
    }

    @Test("A second click extends the hold; the first timer cannot clear it")
    func repeatedClickExtendsHold() {
        var activity = AppleMacInteractionActivity()
        activity.record(at: start)
        activity.record(at: start.addingTimeInterval(2))
        activity.expire(deadline: start.addingTimeInterval(3))
        #expect(activity.isActive)
        activity.expire(deadline: start.addingTimeInterval(5))
        #expect(activity.isActive == false)
    }

    @Test("Idle and repeated timer callbacks leave the activity idle")
    func repeatedExpiry() {
        var activity = AppleMacInteractionActivity()
        activity.expire(deadline: start)
        activity.record(at: start)
        activity.expire(deadline: start.addingTimeInterval(3))
        activity.expire(deadline: start.addingTimeInterval(3))
        #expect(activity.isActive == false)
    }

    @Test("Mac drags follow the phone hero's distance, prediction and horizontal thresholds", arguments: [
        (CGFloat(-60), CGFloat(10), CGFloat(-60), Int?(1)),
        (CGFloat(60), CGFloat(10), CGFloat(60), Int?(-1)),
        (CGFloat(-25), CGFloat(5), CGFloat(-170), Int?(1)),
        (CGFloat(25), CGFloat(5), CGFloat(170), Int?(-1)),
        (CGFloat(50), CGFloat(5), CGFloat(160), Int?.none),
        (CGFloat(49), CGFloat(5), CGFloat(159), Int?.none),
        (CGFloat(60), CGFloat(60), CGFloat(200), Int?.none),
        (CGFloat(-60), CGFloat(100), CGFloat(-200), Int?.none),
        (CGFloat(0), CGFloat(100), CGFloat(-200), Int?.none),
    ])
    func horizontalDrag(dx: CGFloat, dy: CGFloat, predictedX: CGFloat, expected: Int?) {
        #expect(AppleMacHeroSwipe.dragDirection(translation: CGSize(width: dx, height: dy),
            predictedEndTranslation: CGSize(width: predictedX, height: dy)) == expected)
    }

    @Test("Mac hero targets are touch sized while the dots remain seven points")
    func targetSizes() {
        #expect(AppleMacHeroLayout.muteSide >= 44)
        #expect(AppleMacHeroLayout.listButtonSide >= 44)
        #expect((36...44).contains(AppleMacHeroPageDots.hitSize))
        #expect(AppleMacHeroPageDots.dotSize == 7)
    }

    @Test("Overlapping dot targets select the nearest center", arguments: 0..<5)
    func overlappingDotTargets(index: Int) {
        let frames = AppleMacHeroPageDots.tapFrames(index: index, count: 5)
        for (page, frame) in frames.enumerated() {
            #expect(frame.width >= 36 && frame.height == 36)
            #expect(AppleHeroPageDots.page(at: CGPoint(x: frame.midX, y: frame.midY), frames: frames) == page)
        }
        for (left, right) in zip(frames, frames.dropFirst()) {
            #expect(right.minX - left.maxX + (36 - 7) == 8)
        }
        #expect(AppleHeroPageDots.page(at: CGPoint(x: -1, y: 1), frames: frames) == nil)
    }
}
#endif
