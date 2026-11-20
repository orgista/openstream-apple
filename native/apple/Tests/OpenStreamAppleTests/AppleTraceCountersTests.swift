import Testing
@testable import OpenStreamApple

@Suite("Trace playback counters")
struct AppleTraceCountersTests {
    @Test func summarisesLiveAndOnDemandSeparatelyWithReasonsByCount() {
        var counters = AppleTraceCounters()
        for _ in 0 ..< 4 { counters.recordAttempt(isLive: true) }
        counters.recordStarted(isLive: true)
        counters.recordFailure(.authentication, isLive: true)
        counters.recordFailure(.authentication, isLive: true)
        counters.recordFailure(.network, isLive: true)
        counters.recordAttempt(isLive: false)
        counters.recordStarted(isLive: false)
        #expect(counters.summary
            == "live: 4 tried, 1 played, 3 failed (authentication 2, network 1); on demand: 1 tried, 1 played, 0 failed")
    }

    @Test func aChannelSwitchIsNotAFailure() {
        var counters = AppleTraceCounters()
        counters.recordAttempt(isLive: true)
        counters.recordFailure(.cancelled, isLive: true)
        #expect(counters.live.failed == 0)
        #expect(counters.summary == "live: 1 tried, 0 played, 0 failed")
    }

    @Test func nothingTriedSaysNothing() {
        #expect(AppleTraceCounters().summary.isEmpty)
    }
}
