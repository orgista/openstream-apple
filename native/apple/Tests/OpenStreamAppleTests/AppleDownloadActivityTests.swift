import Foundation
import Testing
@testable import OpenStreamApple

/// The lock screen, the Dynamic Island and the in-app row all read this one
/// mapping, so they cannot disagree about a download.
@Suite("Download Live Activity")
struct AppleDownloadActivityTests {
    private func state(
        _ received: Int64,
        _ expected: Int64?,
        _ status: AppleDownloadActivityPresentation.Status
    ) -> AppleDownloadActivityState {
        AppleDownloadActivityPresentation.state(received: received, expected: expected, status: status)
    }

    @Test func progressIsTheByteRatio() {
        #expect(state(500, 1000, .downloading).fractionComplete == 0.5)
    }

    /// An unknown total must not be rendered as a precise bar — nil keeps it
    /// indeterminate rather than inventing a number.
    @Test func anUnknownTotalHasNoFraction() {
        #expect(state(500, nil, .downloading).fractionComplete == nil)
        #expect(state(500, 0, .downloading).fractionComplete == nil)
    }

    /// A finished download reads 100% whatever the counters say, so the bar
    /// never stops at 99% on a size mismatch.
    @Test func aFinishedDownloadIsAlwaysComplete() {
        #expect(state(900, 1000, .completed).fractionComplete == 1)
        #expect(state(0, nil, .completed).fractionComplete == 1)
    }

    @Test func progressNeverLeavesTheUnitRange() {
        #expect(state(-5, 1000, .downloading).fractionComplete == 0)
        #expect(state(2000, 1000, .downloading).fractionComplete == 1)
    }

    /// Only these three end the activity; a pause must not dismiss it.
    @Test func onlyTerminalStatesEndTheActivity() {
        #expect(state(1, 2, .completed).isFinal)
        #expect(state(1, 2, .cancelled).isFinal)
        #expect(state(1, 2, .failed("No space")).isFinal)
        #expect(!state(1, 2, .paused).isFinal)
        #expect(!state(1, 2, .downloading).isFinal)
        #expect(!state(1, 2, .resolving).isFinal)
        #expect(!state(1, 2, .resuming).isFinal)
    }

    /// A failure shows its own message rather than the word "Failed".
    @Test func aFailureCarriesItsReason() {
        #expect(state(1, 2, .failed("Not enough space")).statusText == "Not enough space")
    }

    @Test func theByteSummaryReadsAsASentence() {
        #expect(state(0, 1000, .downloading).byteSummary.contains("of"))
        #expect(!state(500, nil, .downloading).byteSummary.contains("of"))
    }

    @Test func pausedAndResumingAreNamed() {
        #expect(state(1, 2, .paused).statusText == "Paused")
        #expect(state(1, 2, .resuming).statusText == "Resuming")
        #expect(state(1, 2, .resolving).statusText == "Preparing")
    }
}

/// `ByteCountFormatter` spells zero as "Zero KB" by default, which read as an
/// unfilled placeholder on the Storage pane beside real values like "4.5 MB".
@Suite("Byte formatting")
struct AppleByteFormattingTests {
    @Test func zeroIsANumberNotAWord() {
        let zero = AppleByteFormatting.string(0)
        #expect(!zero.lowercased().contains("zero"))
        #expect(zero.contains("0"))
    }

    @Test func realSizesStillReadNormally() {
        #expect(AppleByteFormatting.string(4_500_000).contains("MB"))
        #expect(AppleByteFormatting.string(1_500).contains("KB"))
    }

    /// A negative count is a bug upstream, not something to render as "-1 KB".
    @Test func negativeCountsClampToZero() {
        #expect(AppleByteFormatting.string(-5) == AppleByteFormatting.string(0))
    }
}

/// The resume bar on every shelf. Inline division produced NaN before the
/// duration was known, and a `ProgressView` given NaN draws an empty track —
/// "not started" for something half-watched.
@Suite("Watch progress")
struct AppleWatchProgressTests {
    @Test func halfwayIsAHalf() {
        #expect(AppleWatchProgress.fraction(position: 600, duration: 1200) == 0.5)
    }

    @Test func anUnknownDurationIsNotNaN() {
        let value = AppleWatchProgress.fraction(position: 600, duration: 0)
        #expect(!value.isNaN)
        #expect(value == 0)
    }

    @Test func nonFiniteInputsAreSafe() {
        #expect(AppleWatchProgress.fraction(position: 600, duration: .infinity) == 0)
        #expect(AppleWatchProgress.fraction(position: .nan, duration: 1200) == 0)
    }

    @Test func itNeverLeavesTheUnitRange() {
        #expect(AppleWatchProgress.fraction(position: 5000, duration: 1200) == 1)
        #expect(AppleWatchProgress.fraction(position: -10, duration: 1200) == 0)
    }
}
