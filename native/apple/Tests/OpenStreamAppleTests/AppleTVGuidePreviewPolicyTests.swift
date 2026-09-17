import Foundation
import Testing
@testable import OpenStreamApple

/// Owner 2026-09-14: "live is still slow and there is no preview of the
/// channel". A preview is a second live connection, so the rules about when
/// one may start are worth asserting on their own.
@Suite("Guide channel preview")
struct AppleTVGuidePreviewPolicyTests {
    @Test func aFocusedChannelPreviews() {
        #expect(AppleTVGuidePreviewPolicy.target(focusedChannelID: "cbs", isEnabled: true) == "cbs")
    }

    @Test func aFocusedProgrammePreviewsItsChannel() {
        #expect(AppleTVGuidePreviewPolicy.target(
            focusedChannelID: nil, focusedCellChannelID: "fox", isEnabled: true) == "fox")
    }

    @Test func theRailWinsOverTheTimeline() {
        #expect(AppleTVGuidePreviewPolicy.target(
            focusedChannelID: "cbs", focusedCellChannelID: "fox", isEnabled: true) == "cbs")
    }

    @Test func nothingPreviewsFromTheChipsOrSearch() {
        #expect(AppleTVGuidePreviewPolicy.target(focusedChannelID: nil, isEnabled: true) == nil)
        #expect(AppleTVGuidePreviewPolicy.target(focusedChannelID: "", isEnabled: true) == nil)
    }

    /// A viewer who turned trailer autoplay off does not want a guide that
    /// plays by itself either, so the two share one switch.
    @Test func autoplayOffMeansNoPreview() {
        #expect(AppleTVGuidePreviewPolicy.target(focusedChannelID: "cbs", isEnabled: false) == nil)
    }

    @Test func nothingPreviewsBehindTheFullScreenPlayer() {
        #expect(AppleTVGuidePreviewPolicy.target(
            focusedChannelID: "cbs", isEnabled: true, isPlayerOpen: true) == nil)
    }

    /// Long enough that running the rail never opens a stream per row.
    @Test func theDwellIsLongEnoughToScrollPast() {
        #expect(AppleTVGuidePreviewPolicy.dwell >= .milliseconds(800))
        #expect(AppleTVGuidePreviewPolicy.dwell <= .seconds(2))
    }
}
