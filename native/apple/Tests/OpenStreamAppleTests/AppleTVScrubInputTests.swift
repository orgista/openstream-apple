import Foundation
import Testing
@testable import OpenStreamApple

@Suite struct AppleTVScrubInputTests {
    @Test func touchMovesUseTenSecondStepsWithoutRepeatingCumulativeTranslation() {
        var input = AppleTVScrubInput()
        let belowStep = input.move(translation: 39)
        let firstStep = input.move(translation: 40)
        let remainder = input.move(translation: 42)
        let forward = input.move(translation: 120)
        let reversed = input.move(translation: 40)
        #expect(belowStep == nil)
        #expect(firstStep == 10)
        #expect(remainder == nil)
        #expect(forward == 20)
        #expect(reversed == -20)
        input.end()
        let nextGesture = input.move(translation: -40)
        #expect(nextGesture == -10)
    }

    @Test func hundredsOfSmallMovesAndReversalsKeepTheRemainder() {
        var input = AppleTVScrubInput()
        var seconds: Double = 0
        for point in 0...800 { seconds += input.move(translation: Double(point)) ?? 0 }
        #expect(seconds == 200)
        for point in stride(from: 799, through: -800, by: -1) {
            seconds += input.move(translation: Double(point)) ?? 0
        }
        #expect(seconds == -200)
        let nan = input.move(translation: .nan)
        let infinity = input.move(translation: .infinity)
        #expect(nan == nil)
        #expect(infinity == nil)
    }
    @Test(arguments: [1.0, -1.0])
    func ringTurnsMapToDirectionalStepsAndReverse(_ direction: Double) {
        var input = AppleTVScrubInput()
        input.begin()
        var seconds = 0.0
        for sample in 0...64 {
            let angle = direction * Double(sample) * .pi / 32
            seconds += input.move(x: 120 * (cos(angle) - 1), y: 120 * sin(angle)) ?? 0
        }
        #expect(seconds * direction >= 60)
        #expect(seconds * direction <= 80)
        let before = seconds
        for sample in stride(from: 63, through: 0, by: -1) {
            let angle = direction * Double(sample) * .pi / 32
            seconds += input.move(x: 120 * (cos(angle) - 1), y: 120 * sin(angle)) ?? 0
        }
        #expect((seconds - before) * direction <= -60)
    }

    @Test func aTouchAndItsMoveCommandsCannotDoubleTheScrub() {
        var input = AppleTVScrubInput()
        let start = ContinuousClock.now
        input.begin()
        let touch = input.move(x: 80, y: 0)
        #expect(touch == 20)
        #expect(input.directionalStep(1, now: start) == nil)
        #expect(input.directionalStep(-1, now: start) == nil)
        input.end(now: start)
        #expect(input.directionalStep(1, now: start.advanced(by: .milliseconds(100))) == nil)
        #expect(input.directionalStep(1, now: start.advanced(by: .seconds(1))) == 10)
    }

}
