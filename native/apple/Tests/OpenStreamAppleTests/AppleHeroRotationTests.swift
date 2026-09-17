import Foundation
import Testing
@testable import OpenStreamApple

/// The Discover and Library billboards cycle rather than pinning one title
/// (owner 2026-09-14). The index comes from the clock so both screens agree
/// and nothing has to be invalidated to advance it.
@Suite("Hero rotation")
struct AppleHeroRotationTests {
    private let epoch = Date(timeIntervalSinceReferenceDate: 0)

    @Test func nothingToShowHasNoIndex() {
        #expect(AppleHeroRotation.index(at: epoch, count: 0) == nil)
    }

    @Test func oneCandidateNeverMoves() {
        #expect(AppleHeroRotation.index(at: epoch, count: 1) == 0)
        #expect(AppleHeroRotation.index(at: epoch.addingTimeInterval(10_000), count: 1) == 0)
    }

    @Test func theIndexAdvancesOncePerInterval() {
        let interval = AppleHeroRotation.interval
        #expect(AppleHeroRotation.index(at: epoch, count: 3) == 0)
        #expect(AppleHeroRotation.index(at: epoch.addingTimeInterval(interval - 0.1), count: 3) == 0)
        #expect(AppleHeroRotation.index(at: epoch.addingTimeInterval(interval), count: 3) == 1)
        #expect(AppleHeroRotation.index(at: epoch.addingTimeInterval(interval * 2), count: 3) == 2)
        #expect(AppleHeroRotation.index(at: epoch.addingTimeInterval(interval * 3), count: 3) == 0)
    }

    @Test func theIndexStaysInRangeBeforeTheReferenceDate() {
        for step in 1 ... 5 {
            let date = epoch.addingTimeInterval(-AppleHeroRotation.interval * Double(step))
            let index = AppleHeroRotation.index(at: date, count: 4)
            #expect(index != nil)
            #expect(index! >= 0 && index! < 4)
        }
    }

    @Test func candidatesDropRepeatsAndStopAtTheCap() {
        let values = ["a", "b", "a", "c", "d", "e", "f", "g"]
        let result = AppleHeroRotation.candidates(values, id: { $0 })
        #expect(result == ["a", "b", "c", "d", "e"])
        #expect(result.count == AppleHeroRotation.maximumCandidates)
    }

    @Test func candidatesKeepTheOrderTheyWereGiven() {
        #expect(AppleHeroRotation.candidates(["z", "y"], id: { $0 }) == ["z", "y"])
        #expect(AppleHeroRotation.candidates([String](), id: { $0 }).isEmpty)
    }

    /// The wordmark waits three seconds before giving up (owner 2026-09-14).
    @Test func theWordmarkFallsBackToTextOnlyAfterThreeSeconds() {
        #expect(AppleTitleLogoPolicy.loadingGrace == 3.0)
        #expect(AppleTitleLogoPolicy.resolvedState(validated: true, loadResult: nil, elapsed: 0) == .hidden)
        #expect(AppleTitleLogoPolicy.resolvedState(validated: true, loadResult: nil, elapsed: 2.9) == .hidden)
        #expect(AppleTitleLogoPolicy.resolvedState(validated: true, loadResult: nil, elapsed: 3.0) == .text)
        // A wordmark that arrives late still wins over the stand-in text.
        #expect(AppleTitleLogoPolicy.resolvedState(validated: true, loadResult: true, elapsed: 10) == .logo)
    }

    // MARK: - Rotation indicator (owner 2026-09-15: "a little bar … it's about
    // to cycle through")

    @Test func progressRunsFromZeroToOneAcrossTheInterval() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        #expect(AppleHeroRotation.progress(at: start, interval: 12) == 0)
        #expect(abs(AppleHeroRotation.progress(at: start.addingTimeInterval(6), interval: 12) - 0.5) < 0.0001)
        #expect(abs(AppleHeroRotation.progress(at: start.addingTimeInterval(11.99), interval: 12) - 0.999166) < 0.001)
    }

    @Test func progressRestartsWhenTheBillboardChanges() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        // The instant the index advances, the bar is empty again.
        let boundary = start.addingTimeInterval(12)
        #expect(AppleHeroRotation.progress(at: boundary, interval: 12) == 0)
        #expect(AppleHeroRotation.index(at: boundary, count: 3) != AppleHeroRotation.index(at: start, count: 3))
    }

    @Test func progressIsSafeBeforeTheReferenceDateAndWithNoInterval() {
        // `%`-style maths on negative dates must not produce a negative bar.
        let past = Date(timeIntervalSinceReferenceDate: -30)
        let value = AppleHeroRotation.progress(at: past, interval: 12)
        #expect(value >= 0 && value <= 1)
        #expect(AppleHeroRotation.progress(at: past, interval: 0) == 0)
    }
}
