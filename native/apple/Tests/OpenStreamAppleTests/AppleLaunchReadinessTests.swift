import Testing
@testable import OpenStreamApple

@Suite("Launch cover hold")
struct AppleLaunchCoverPolicyTests {
    @Test("Before the first screen is ready the cover holds to the old 1.3 s cap")
    func holdsToCapUntilReady() {
        #expect(AppleLaunchCoverPolicy.remainingHold(elapsed: .zero, firstScreenIsReady: false, reduceMotion: false)
            == .milliseconds(1_300))
        #expect(AppleLaunchCoverPolicy.remainingHold(elapsed: .milliseconds(500), firstScreenIsReady: false, reduceMotion: false)
            == .milliseconds(800))
        #expect(AppleLaunchCoverPolicy.remainingHold(elapsed: .seconds(2), firstScreenIsReady: false, reduceMotion: false)
            == .zero)
    }

    @Test("Once ready, the cover lifts at once unless the mark has barely drawn")
    func liftsWhenReady() {
        #expect(AppleLaunchCoverPolicy.remainingHold(elapsed: .milliseconds(540), firstScreenIsReady: true, reduceMotion: false)
            == .zero)
        #expect(AppleLaunchCoverPolicy.remainingHold(elapsed: .milliseconds(100), firstScreenIsReady: true, reduceMotion: false)
            == .milliseconds(250))
    }

    @Test("Reduce Motion keeps its short static hand-off and never waits longer")
    func reduceMotion() {
        #expect(AppleLaunchCoverPolicy.remainingHold(elapsed: .zero, firstScreenIsReady: false, reduceMotion: true)
            == .milliseconds(220))
        #expect(AppleLaunchCoverPolicy.remainingHold(elapsed: .zero, firstScreenIsReady: true, reduceMotion: true)
            == .zero)
    }
}

@MainActor
@Suite("Launch readiness")
struct AppleLaunchReadinessTests {
    @Test("Marking ready is one-way and idempotent")
    func markIsIdempotent() {
        let readiness = AppleLaunchReadiness()
        #expect(!readiness.firstScreenIsReady)
        readiness.markFirstScreenReady()
        readiness.markFirstScreenReady()
        #expect(readiness.firstScreenIsReady)
    }
}
