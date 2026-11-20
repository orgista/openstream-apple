import Testing
@testable import OpenStreamApple

@Suite("Runtime completion bands")
struct AppleCompletionPolicyTests {
    @Test(arguments: [(9.0, 9.0), (10, 9), (60, 54), (899, 889), (900, 720), (1799, 1619),
                      (1800, 1560), (3899, 3659), (3900, 3420), (5999, 5519), (6000, 5340)])
    func edges(_ band: (Double, Double)) {
        let (duration, threshold) = band
        #expect(AppleCompletionPolicy.playedThreshold(duration: duration) == threshold)
        #expect(AppleCompletionPolicy.isComplete(position: threshold, duration: duration))
        if threshold > 0 {
            #expect(AppleCompletionPolicy.isComplete(position: threshold - 0.01, duration: duration) == false)
        }
    }

    @Test func rejectsInvalidClocksAndHonoursProvider() {
        #expect(AppleCompletionPolicy.isComplete(position: 0, duration: 0) == false)
        #expect(AppleCompletionPolicy.isComplete(position: .nan, duration: 100) == false)
        #expect(AppleCompletionPolicy.isComplete(position: -1, duration: 100) == false)
        #expect(AppleCompletionPolicy.isComplete(position: 100, duration: .infinity) == false)
        #expect(AppleCompletionPolicy.isComplete(position: 0, duration: 100, providerWatched: true))
        #expect(AppleCompletionPolicy.isComplete(position: 100, duration: 100, providerWatched: false) == false)
    }
}
