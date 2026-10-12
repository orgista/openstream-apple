import Foundation
import Testing
@testable import OpenStreamApple

/// Edge cases the base `AppleTVGuidePreviewPolicyTests` suite does not cover:
/// falling through an empty rail focus to the timeline, combinations of the
/// two gates (`isEnabled`/`isPlayerOpen`), and the exact dwell value.
@Suite("Guide channel preview — edge cases")
struct AppleTVGuidePreviewPolicyEdgeTests {
    /// An empty (but non-nil) rail focus is not a real channel, so the
    /// timeline's focused cell should still be offered.
    @Test func anEmptyRailFocusFallsThroughToTheTimelineCell() {
        #expect(AppleTVGuidePreviewPolicy.target(
            focusedChannelID: "", focusedCellChannelID: "fox", isEnabled: true) == "fox")
    }

    /// Both focus sources present but empty: nothing to preview.
    @Test func emptyRailAndEmptyTimelineFocusBothYieldNil() {
        #expect(AppleTVGuidePreviewPolicy.target(
            focusedChannelID: "", focusedCellChannelID: "", isEnabled: true) == nil)
    }

    /// The two gates are independent; failing either one alone already
    /// suppresses the preview, so failing both together must too.
    @Test func autoplayOffAndPlayerOpenTogetherStillYieldNil() {
        #expect(AppleTVGuidePreviewPolicy.target(
            focusedChannelID: "cbs", isEnabled: false, isPlayerOpen: true) == nil)
    }

    /// The player-open gate applies to a timeline-cell focus too, not just a
    /// rail focus.
    @Test func thePlayerOpenGateAlsoSuppressesTheTimelineCell() {
        #expect(AppleTVGuidePreviewPolicy.target(
            focusedChannelID: nil, focusedCellChannelID: "fox", isEnabled: true, isPlayerOpen: true) == nil)
    }

    /// Only `isEmpty` is checked, not whitespace — a whitespace-only id is
    /// treated as a real channel id and returned as-is. Documenting current
    /// behaviour; callers are expected to hand in real channel ids or nil.
    @Test func aWhitespaceOnlyChannelIDIsTreatedAsPresent() {
        #expect(AppleTVGuidePreviewPolicy.target(focusedChannelID: " ", isEnabled: true) == " ")
    }

    /// The dwell is pinned to an exact value, not just a loose range.
    @Test func theDwellIsExactlyTwelveHundredMilliseconds() {
        #expect(AppleTVGuidePreviewPolicy.dwell == .milliseconds(1200))
    }
}
