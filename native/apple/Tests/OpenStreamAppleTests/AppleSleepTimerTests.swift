import Foundation
import Testing
@testable import OpenStreamApple

@Suite("Sleep timer policy")
struct AppleSleepTimerTests {
    @Test(arguments: [15, 30, 45, 60, 90, 120])
    func minutesHaveExactDeadlines(minutes: Int) {
        let now = Date(timeIntervalSince1970: 1000)
        #expect(AppleSleepTimerPolicy.deadline(minutes: minutes, now: now) == now.addingTimeInterval(Double(minutes) * 60))
    }
    @Test func offAndFinishedProgrammeCannotArm() {
        let now = Date(timeIntervalSince1970: 1000)
        #expect(AppleSleepTimerPolicy.deadline(minutes: 0, now: now) == nil)
        #expect(AppleSleepTimerPolicy.programmeDeadline(end: nil, now: now) == nil)
        #expect(AppleSleepTimerPolicy.programmeDeadline(end: now, now: now) == nil)
        #expect(AppleSleepTimerPolicy.programmeDeadline(end: now.addingTimeInterval(30), now: now) == now.addingTimeInterval(30))
    }
    @MainActor @Test func expiryPausesOnceAndCancellationPreventsExpiry() {
        let timer = ApplePlaybackSleepTimer()
        let now = Date(timeIntervalSince1970: 1000)
        var pauses = 0
        timer.arm(minutes: 15, now: now) { pauses += 1 }
        timer.expireIfNeeded(now: now.addingTimeInterval(899))
        #expect(pauses == 0)
        timer.expireIfNeeded(now: now.addingTimeInterval(900))
        timer.expireIfNeeded(now: now.addingTimeInterval(1000))
        #expect(pauses == 1)
        #expect(timer.stillWatching)
        timer.arm(minutes: 30, now: now) { pauses += 1 }
        timer.cancel()
        timer.expireIfNeeded(now: now.addingTimeInterval(1800))
        #expect(pauses == 1)
        #expect(!timer.stillWatching)
    }
}
