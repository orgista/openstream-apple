import Foundation
import Testing
@testable import OpenStreamApple

@Suite struct AppleSeekableRangeTests {
    @Test func rejectsNonFiniteBounds() {
        #expect(AppleSeekableRange(start: .nan, end: 10) == nil)
        #expect(AppleSeekableRange(start: 0, end: .infinity) == nil)
    }

    @Test func rejectsAnInvertedRange() {
        #expect(AppleSeekableRange(start: 90, end: 30) == nil)
    }

    @Test func acceptsAnEmptyRange() throws {
        let range = try #require(AppleSeekableRange(start: 42, end: 42))
        #expect(range.span == 0)
    }

    @Test func spanIsTheDistanceBetweenTheBounds() throws {
        let range = try #require(AppleSeekableRange(start: 3_600, end: 3_690))
        #expect(range.span == 90)
        #expect(range.contains(3_650))
        #expect(!range.contains(3_599))
        #expect(!range.contains(3_691))
    }

    @Test func intersectionTakesTheNarrowerBounds() throws {
        let claimed = try #require(AppleSeekableRange(start: 1_800, end: 3_600))
        let item = try #require(AppleSeekableRange(start: 3_540, end: 3_610))
        let folded = try #require(claimed.intersected(with: item))
        #expect(folded.start == 3_540)
        #expect(folded.end == 3_600)
    }

    @Test func intersectionOfDisjointRangesIsNil() throws {
        let a = try #require(AppleSeekableRange(start: 0, end: 10))
        let b = try #require(AppleSeekableRange(start: 20, end: 30))
        #expect(a.intersected(with: b) == nil)
    }

    /// The playhead is always seekable to where it already is, so a range
    /// sampled a tick behind it must widen rather than exclude it.
    @Test func expandingToIncludeThePlayheadWidensEitherBound() throws {
        let range = try #require(AppleSeekableRange(start: 100, end: 200))
        #expect(range.expanded(toInclude: 205) == AppleSeekableRange(start: 100, end: 205))
        #expect(range.expanded(toInclude: 95) == AppleSeekableRange(start: 95, end: 200))
        #expect(range.expanded(toInclude: 150) == range)
        #expect(range.expanded(toInclude: .nan) == range)
    }
}

@Suite struct AppleLiveSeekPolicyTests {
    private func range(_ start: Double, _ end: Double) throws -> AppleSeekableRange {
        try #require(AppleSeekableRange(start: start, end: end))
    }

    // MARK: - offersDVR

    @Test func noRangeOffersNoDVR() {
        #expect(!AppleLiveSeekPolicy.offersDVR(nil))
    }

    /// A sliding-window IPTV playlist lists a handful of segments. That is not
    /// a DVR and must not be dressed as one.
    @Test func aWindowNarrowerThanTheMinimumOffersNoDVR() throws {
        let narrow = try range(3_600, 3_600 + AppleLiveSeekPolicy.minimumUsefulSpan - 1)
        #expect(!AppleLiveSeekPolicy.offersDVR(narrow))
    }

    @Test func aWindowAtTheMinimumOffersDVR() throws {
        let exact = try range(0, AppleLiveSeekPolicy.minimumUsefulSpan)
        #expect(AppleLiveSeekPolicy.offersDVR(exact))
    }

    // MARK: - skipTarget

    @Test func skipBackLandsTenSecondsEarlierInsideTheWindow() throws {
        let target = AppleLiveSeekPolicy.skipTarget(from: 3_690, by: -10, in: try range(3_600, 3_690))
        #expect(target == 3_680)
    }

    @Test func skipForwardLandsTenSecondsLaterInsideTheWindow() throws {
        let target = AppleLiveSeekPolicy.skipTarget(from: 3_650, by: 10, in: try range(3_600, 3_690))
        #expect(target == 3_660)
    }

    /// The window's floor is a floor, not a wrap: a 10 s step from 5 s above it
    /// lands ON it, not 5 s below.
    @Test func skipBackClampsToTheFloorOfTheWindow() throws {
        let target = AppleLiveSeekPolicy.skipTarget(from: 3_605, by: -10, in: try range(3_600, 3_690))
        #expect(target == 3_600)
    }

    @Test func skipForwardClampsToTheLiveEdge() throws {
        let target = AppleLiveSeekPolicy.skipTarget(from: 3_685, by: 10, in: try range(3_600, 3_690))
        #expect(target == 3_690)
    }

    @Test func skipAtTheFloorHasNowhereToGo() throws {
        #expect(AppleLiveSeekPolicy.skipTarget(from: 3_600, by: -10, in: try range(3_600, 3_690)) == nil)
    }

    @Test func skipAtTheEdgeHasNowhereToGoForward() throws {
        #expect(AppleLiveSeekPolicy.skipTarget(from: 3_690, by: 10, in: try range(3_600, 3_690)) == nil)
    }

    /// The live edge moves while the playhead rides it, so a sampled position
    /// can sit past the sampled edge. Skipping back from there is measured
    /// from the edge, not from a time the stream does not hold yet.
    @Test func skipBackFromPastTheSampledEdgeAnchorsOnTheEdge() throws {
        let target = AppleLiveSeekPolicy.skipTarget(from: 3_692, by: -10, in: try range(3_600, 3_690))
        #expect(target == 3_680)
    }

    @Test func skipWithNoWindowIsNil() {
        #expect(AppleLiveSeekPolicy.skipTarget(from: 100, by: -10, in: nil) == nil)
    }

    @Test func skipInsideAWindowTooNarrowToMatterIsNil() throws {
        #expect(AppleLiveSeekPolicy.skipTarget(from: 3_608, by: -10, in: try range(3_600, 3_610)) == nil)
    }

    @Test func skipWithANonFinitePositionOrAmountIsNil() throws {
        let window = try range(3_600, 3_690)
        #expect(AppleLiveSeekPolicy.skipTarget(from: .nan, by: -10, in: window) == nil)
        #expect(AppleLiveSeekPolicy.skipTarget(from: 3_650, by: .infinity, in: window) == nil)
    }

    // MARK: - scrubTarget

    @Test func scrubTargetIsAFractionOfTheWindowOnItsOwnAxis() throws {
        #expect(AppleLiveSeekPolicy.scrubTarget(fraction: 0, in: try range(3_600, 3_690)) == 3_600)
        #expect(AppleLiveSeekPolicy.scrubTarget(fraction: 0.5, in: try range(3_600, 3_690)) == 3_645)
        #expect(AppleLiveSeekPolicy.scrubTarget(fraction: 1, in: try range(3_600, 3_690)) == 3_690)
    }

    @Test func scrubTargetClampsAnOutOfBoundsFraction() throws {
        #expect(AppleLiveSeekPolicy.scrubTarget(fraction: -3, in: try range(3_600, 3_690)) == 3_600)
        #expect(AppleLiveSeekPolicy.scrubTarget(fraction: 4, in: try range(3_600, 3_690)) == 3_690)
    }

    @Test func scrubTargetWithNoWindowIsNil() {
        #expect(AppleLiveSeekPolicy.scrubTarget(fraction: 0.5, in: nil) == nil)
    }

    // MARK: - progress

    @Test func progressIsMeasuredFromTheFloorOfTheWindow() throws {
        #expect(AppleLiveSeekPolicy.progress(position: 3_645, in: try range(3_600, 3_690)) == 0.5)
        #expect(AppleLiveSeekPolicy.progress(position: 3_600, in: try range(3_600, 3_690)) == 0)
        #expect(AppleLiveSeekPolicy.progress(position: 3_690, in: try range(3_600, 3_690)) == 1)
    }

    @Test func progressClampsOutsideTheWindow() throws {
        #expect(AppleLiveSeekPolicy.progress(position: 10, in: try range(3_600, 3_690)) == 0)
        #expect(AppleLiveSeekPolicy.progress(position: 9_999, in: try range(3_600, 3_690)) == 1)
    }

    @Test func progressWithNoWindowIsZero() {
        #expect(AppleLiveSeekPolicy.progress(position: 3_645, in: nil) == 0)
    }

    // MARK: - isAtLiveEdge

    @Test func withNoWindowTheViewerIsAlwaysAtTheEdge() {
        #expect(AppleLiveSeekPolicy.isAtLiveEdge(position: 42, in: nil, tolerance: 5))
    }

    @Test func atTheEdgeWithinTolerance() throws {
        let window = try range(3_600, 3_690)
        #expect(AppleLiveSeekPolicy.isAtLiveEdge(position: 3_690, in: window, tolerance: 5))
        #expect(AppleLiveSeekPolicy.isAtLiveEdge(position: 3_686, in: window, tolerance: 5))
    }

    /// The whole visible point of the fix: a ten-second skip back from the
    /// edge takes the badge off "LIVE".
    @Test func tenSecondsBackLeavesTheEdge() throws {
        let window = try range(3_600, 3_690)
        #expect(!AppleLiveSeekPolicy.isAtLiveEdge(position: 3_680, in: window, tolerance: 5))
    }
}
