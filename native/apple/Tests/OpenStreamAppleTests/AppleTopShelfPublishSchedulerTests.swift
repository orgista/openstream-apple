import Testing
@testable import OpenStreamApple

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct AppleTopShelfPublishSchedulerTests {
    @Test func revisionsCoalesceForFiveSecondsAndKeepEveryTrigger() async {
        let clock = ManualClock()
        let scheduler = AppleTopShelfPublishScheduler(clock: clock)
        var publications: [[String]] = []
        let first = scheduler.schedule("index") { publications.append($0) }
        await clock.waitForSleeps(1)
        clock.advance(by: .seconds(4))
        #expect(publications.isEmpty)
        let latest = scheduler.schedule("heroes") { publications.append($0) }
        await clock.waitForSleeps(2)
        await first.value
        #expect(first.isCancelled)
        #expect(clock.pendingDeadlines == [.seconds(9)])
        clock.advance(by: .seconds(4))
        #expect(publications.isEmpty)
        clock.advance(by: .seconds(1))
        await latest.value
        #expect(publications == [["heroes", "index"]])
    }

    @Test func backgroundCancelsTheDebounceAndSkipsTheLaunchWindow() async {
        let clock = ManualClock()
        let scheduler = AppleTopShelfPublishScheduler(clock: clock)
        var publications: [[String]] = []
        let idle = scheduler.schedule("index", delay: .seconds(30)) { publications.append($0) }
        await clock.waitForSleeps(1)
        let background = scheduler.schedule("background", immediately: true, delay: .seconds(30)) {
            publications.append($0)
        }
        await background.value
        await idle.value
        #expect(idle.isCancelled)
        #expect(clock.requestedDeadlines == [.seconds(30)])
        #expect(clock.pendingSleepers == 0)
        #expect(publications == [["background", "index"]])
    }

    @Test func cancelledPublishDoesNotRunAndLaterBurstsStartFresh() async {
        let clock = ManualClock()
        let scheduler = AppleTopShelfPublishScheduler(clock: clock)
        var publications: [[String]] = []
        let cancelled = scheduler.schedule("sources") { publications.append($0) }
        await clock.waitForSleeps(1)
        cancelled.cancel()
        await cancelled.value
        #expect(publications.isEmpty)
        #expect(clock.pendingSleepers == 0)
        let latest = scheduler.schedule("settings", immediately: true) { publications.append($0) }
        await latest.value
        let next = scheduler.schedule("channels", immediately: true) { publications.append($0) }
        await next.value
        #expect(publications == [["settings", "sources"], ["channels"]])
    }
}
