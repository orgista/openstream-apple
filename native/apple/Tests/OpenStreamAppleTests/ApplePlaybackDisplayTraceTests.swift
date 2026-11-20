import Testing
import AVFoundation
@testable import OpenStreamApple

struct ApplePlaybackDisplayTraceTests {
    @Test(arguments: ["DV", "HDR10", "HDR10+", "HLG", "SDR", "unknown"])
    func recordsSourceWithoutClaimingDisplayMatch(_ range: String) {
        let trace = ApplePlaybackDisplayTrace(source: range, profile: range == "DV" ? "8.1" : nil,
            renderer: range, preferredCriteria: "present", matchingEnabled: true,
            switchInProgress: false, currentMode: "3840x2160;HDMI-range-unavailable")
        #expect(trace.line.contains("source=\(range)"))
        #expect(trace.line.contains("isDisplayCriteriaMatchingEnabled=true"))
        #expect(trace.line.contains("displayModeSwitchInProgress=false"))
        #expect(trace.line.contains("dynamicRangeMatched=unverified"))
        #expect(trace.line.contains("dvProfile=\(range == "DV" ? "8.1" : "unknown")"))
    }

    @Test func unavailableAPIsStayUnknown() {
        #expect(ApplePlaybackDisplayTrace().line ==
            "display source=unknown dvProfile=unknown renderer=unknown preferredDisplayCriteria=unavailable "
            + "isDisplayCriteriaMatchingEnabled=unavailable displayModeSwitchInProgress=unavailable "
            + "currentMode=unavailable dynamicRangeRequested=unavailable dynamicRangeMatched=unverified")
    }

    @Test func disabledMatchingAndPendingSwitchAreExplicit() {
        let trace = ApplePlaybackDisplayTrace(source: "DV", preferredCriteria: "none",
            matchingEnabled: false, switchInProgress: true)
        #expect(trace.line.contains("preferredDisplayCriteria=none"))
        #expect(trace.line.contains("isDisplayCriteriaMatchingEnabled=false"))
        #expect(trace.line.contains("displayModeSwitchInProgress=true"))
        #expect(trace.line.contains("dynamicRangeMatched=unverified"))
    }

    @Test func sourceCanDifferFromRenderer() {
        let trace = ApplePlaybackDisplayTrace(source: "DV", profile: "5", renderer: "SDR")
        #expect(trace.line.contains("source=DV dvProfile=5 renderer=SDR"))
    }
    @Test func hlsVariantRangeIsKnownWithoutInventingDV() {
        #expect(ApplePlaybackDisplayTrace.hlsSource(videoRanges: [.pq]).source == "PQ")
        #expect(ApplePlaybackDisplayTrace.hlsSource(videoRanges: [.hlg, .hlg]).source == "HLG")
        #expect(ApplePlaybackDisplayTrace.hlsSource(videoRanges: [.sdr]).source == "SDR")
        #expect(ApplePlaybackDisplayTrace.hlsSource(videoRanges: [.pq, .sdr]).source == "unknown")
        #expect(ApplePlaybackDisplayTrace.hlsSource(videoRanges: []).source == "unknown")
        #expect(ApplePlaybackDisplayTrace.hlsSource(videoRanges: [.pq]).profile == nil)
    }

    @Test func displayRequestIsExplicitButMatchingRemainsUnverified() {
        #expect(ApplePlaybackDisplayTrace(preferredCriteria: "present", matchingEnabled: true).line.contains("dynamicRangeRequested=true"))
        #expect(ApplePlaybackDisplayTrace(preferredCriteria: "none", matchingEnabled: true).line.contains("dynamicRangeRequested=false"))
        #expect(ApplePlaybackDisplayTrace().line.contains("dynamicRangeRequested=unavailable"))
    }

}
