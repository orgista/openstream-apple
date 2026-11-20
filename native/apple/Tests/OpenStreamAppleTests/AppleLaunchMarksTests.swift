import Foundation
import Testing
@testable import OpenStreamApple

@Suite("Launch marks, the launch window and hang marks")
struct AppleLaunchMarksTests {
    @Test func aMarkReadsAsItsNameAndTheProcessAge() {
        #expect(AppleLaunchMarks.line(.firstFrame, age: .milliseconds(812), detail: "") == "first frame +812ms")
        #expect(AppleLaunchMarks.line(.firstRow, age: .milliseconds(1_940), detail: "Continue Watching")
            == "first row +1940ms Continue Watching")
    }

    @Test func anEverydayLaunchCountsFromTheKernelsStartTime() throws {
        try #require(!AppleLaunchMarks.isPrewarmed)
        let start = try #require(AppleProcessStart.date)
        #expect(AppleLaunchMarks.launchAge(now: start.addingTimeInterval(1.5)) == .milliseconds(1_500))
    }

    @Test func millisecondsDropTheRemainder() {
        #expect(AppleLaunchMarks.milliseconds(.nanoseconds(1_940_999_999)) == 1_940)
    }

    @Test func deferredWorkWaitsOutTheFirstTwoSeconds() {
        #expect(AppleLaunchWorkPolicy.remainingLaunchWindow(processAge: .milliseconds(300)) == .milliseconds(1_700))
        #expect(AppleLaunchWorkPolicy.remainingLaunchWindow(processAge: .seconds(2)) == .zero)
        #expect(AppleLaunchWorkPolicy.remainingLaunchWindow(processAge: .seconds(40)) == .zero)
        #expect(AppleLaunchWorkPolicy.remainingLaunchWindow(processAge: nil) == .zero)
    }

    @Test func onlyALateAnswerWhileTheProcessRanIsAHang() {
        let tick = Duration.milliseconds(100)
        #expect(!AppleHangMonitor.isHang(answerDelay: .milliseconds(250), longestTickGap: tick, sinceLastTick: tick))
        #expect(AppleHangMonitor.isHang(answerDelay: .milliseconds(540), longestTickGap: tick, sinceLastTick: tick))
        // Suspended in the background, timer first after resume: it was held as long as the main thread.
        #expect(!AppleHangMonitor.isHang(answerDelay: .seconds(30), longestTickGap: .seconds(30), sinceLastTick: tick))
        // Suspended, answer first after resume: the timer has not ticked since before the suspension.
        #expect(!AppleHangMonitor.isHang(answerDelay: .seconds(30), longestTickGap: .zero, sinceLastTick: .seconds(30)))
        // A tick ran between the answer and its handling.
        #expect(AppleHangMonitor.isHang(answerDelay: .milliseconds(540), longestTickGap: tick,
                                        sinceLastTick: .milliseconds(-5)))
    }
}
