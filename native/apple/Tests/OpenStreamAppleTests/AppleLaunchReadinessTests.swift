import Testing
@testable import OpenStreamApple

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
