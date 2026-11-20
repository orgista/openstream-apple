import Testing
@testable import OpenStreamApple

/// Scrubber presses on a 45-minute (2700 s) film, 5% (135 s) each, while
/// the seeks land slowly (share film, resume job 2026-10-31).
@Suite struct AppleSeekTargetPolicyTests {
    private let film = 0.0 ... 2700.0
    private let start = ContinuousClock.now

    private func at(_ seconds: Double) -> ContinuousClock.Instant { start.advanced(by: .seconds(seconds)) }

    private func press(_ policy: inout AppleSeekTargetPolicy, position: Double, by delta: Double = 135) -> Double? {
        let target = AppleSeekTargetPolicy.step(from: policy.base(position: position), by: delta, in: film)
        return policy.request(target)?.target
    }

    @Test func pressesAddUpFromTheTargetWhileThePositionLags() {
        var policy = AppleSeekTargetPolicy()
        let first = press(&policy, position: 1.6)
        #expect(abs((first ?? 0) - 136.6) < 0.001)
        for _ in 0 ..< 16 { #expect(press(&policy, position: 1.6) == nil) }
        #expect(abs(policy.base(position: 1.6) - 2296.6) < 0.001)
    }

    @Test func pressesDuringASeekFoldIntoOneFollowUp() throws {
        var policy = AppleSeekTargetPolicy()
        let firstSeek = policy.request(135)
        let first = try #require(firstSeek)
        #expect(press(&policy, position: 0) == nil)
        #expect(press(&policy, position: 0) == nil)
        let followUpSeek = policy.returned(first, now: at(1))
        let followUp = try #require(followUpSeek)
        #expect(followUp.target == 405)
        #expect(policy.returned(followUp, now: at(2)) == nil)
        #expect(policy.inFlight == nil)
    }

    @Test func aPressAfterTheSeekReturnedStartsANewSeek() throws {
        var policy = AppleSeekTargetPolicy()
        let firstSeek = policy.request(135)
        let first = try #require(firstSeek)
        #expect(policy.returned(first, now: at(1)) == nil)
        #expect(press(&policy, position: 0) == 270)
    }

    @Test func aStaleTickNeverMovesTheTargetBackwards() {
        var policy = AppleSeekTargetPolicy()
        _ = press(&policy, position: 10)
        policy.observe(position: 11, now: at(0.25))
        policy.observe(position: 11.25, now: at(0.5))
        #expect(policy.base(position: 11.25) == 145)
        #expect(press(&policy, position: 11.25) == nil)
        #expect(policy.pending == 280)
    }

    @Test func theTargetClearsOnceThePositionArrives() throws {
        var policy = AppleSeekTargetPolicy()
        let seekSeek = policy.request(135)
        let seek = try #require(seekSeek)
        _ = policy.returned(seek, now: at(1))
        policy.observe(position: 135.4, now: at(1.25))
        #expect(policy.pending == nil)
        #expect(policy.base(position: 135.4) == 135.4)
    }

    /// A seek that returns as soon as it is issued (SharePlay) keeps the
    /// target while the position catches up, however many ticks that takes;
    /// one that settled away from the target lets the position win after
    /// `releaseAfter`.
    @Test func theTargetHoldsForATimeBudgetAfterTheSeekReturns() throws {
        var policy = AppleSeekTargetPolicy()
        let seekSeek = policy.request(135)
        let seek = try #require(seekSeek)
        _ = policy.returned(seek, now: at(0))
        for tick in 1 ... 11 { policy.observe(position: 1, now: at(Double(tick) * 0.25)) }
        #expect(policy.pending == 135)
        #expect(press(&policy, position: 1) == 270)
        let second = try #require(policy.inFlight)
        _ = policy.returned(second, now: at(3))
        policy.observe(position: 264, now: at(5.9))
        #expect(policy.pending == 270)
        policy.observe(position: 264, now: at(6))
        #expect(policy.pending == nil)
    }

    @Test func timeAloneCannotSupersedeASlowSeekOrLoseItsLatestTarget() throws {
        var policy = AppleSeekTargetPolicy()
        let started = policy.request(135)
        let first = try #require(started)
        #expect(policy.request(405) == nil)
        policy.observe(position: 0.75, now: at(120))
        #expect(policy.pending == 405)
        #expect(policy.inFlight == first)
        let returned = policy.returned(first, now: at(121))
        let followUp = try #require(returned)
        #expect(followUp.target == 405)
    }

    /// The item changed while a seek ran: the old seek's return cannot end
    /// the new item's seek, so two never run at once.
    @Test func aSeekFromBeforeAResetCannotEndTheNextOne() throws {
        var policy = AppleSeekTargetPolicy()
        let oldSeek = policy.request(135)
        let old = try #require(oldSeek)
        policy.reset()
        #expect(policy.pending == nil)
        let newSeek = policy.request(60)
        let new = try #require(newSeek)
        #expect(policy.returned(old, now: at(2)) == nil)
        #expect(policy.inFlight == new)
        #expect(policy.request(90) == nil)
    }

    @Test func stepsClampToTheFilm() {
        #expect(AppleSeekTargetPolicy.step(from: 2650, by: 135, in: film) == 2700)
        #expect(AppleSeekTargetPolicy.step(from: 60, by: -135, in: film) == 0)
        var policy = AppleSeekTargetPolicy()
        _ = press(&policy, position: 2650)
        #expect(press(&policy, position: 2650) == nil)
        #expect(policy.pending == 2700)
    }

    @Test func reversingAcrossTheOldPositionDoesNotDiscardTheFollowUp() throws {
        var policy = AppleSeekTargetPolicy()
        let started = policy.request(900)
        let first = try #require(started)
        _ = policy.request(101)
        policy.observe(position: 100, now: at(0.2))
        #expect(policy.pending == 101)
        let followUp = policy.returned(first, now: at(0.3))
        let reversed = try #require(followUp)
        #expect(reversed.target == 101)
    }

    @Test func anOptimisticPositionCannotReleaseAnUnfinishedSeek() throws {
        var policy = AppleSeekTargetPolicy()
        let started = policy.request(900)
        let first = try #require(started)
        policy.observe(position: 900, now: at(0.1))
        #expect(policy.pending == 900)
        _ = policy.returned(first, now: at(0.2))
        policy.observe(position: 900, now: at(0.3))
        #expect(policy.pending == nil)
    }
}
