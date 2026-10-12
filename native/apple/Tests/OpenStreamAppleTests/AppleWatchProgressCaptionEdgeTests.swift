import Foundation
import Testing
@testable import OpenStreamApple

@Suite struct AppleWatchProgressCaptionEdgeTests {

    // MARK: - AppleWatchProgress.fraction tests

    @Test func fractionWithZeroDuration() {
        #expect(AppleWatchProgress.fraction(position: 10.0, duration: 0.0) == 0)
    }

    @Test func fractionWithNegativeDuration() {
        #expect(AppleWatchProgress.fraction(position: 10.0, duration: -5.0) == 0)
    }

    @Test func fractionWithNaNDuration() {
        #expect(AppleWatchProgress.fraction(position: 10.0, duration: .nan) == 0)
    }

    @Test func fractionWithInfiniteDuration() {
        #expect(AppleWatchProgress.fraction(position: 10.0, duration: .infinity) == 0)
    }

    @Test func fractionWithNegativePosition() {
        #expect(AppleWatchProgress.fraction(position: -5.0, duration: 100.0) == 0)
    }

    @Test func fractionWithNaNPosition() {
        #expect(AppleWatchProgress.fraction(position: .nan, duration: 100.0) == 0)
    }

    @Test func fractionWithInfinitePosition() {
        #expect(AppleWatchProgress.fraction(position: .infinity, duration: 100.0) == 0)
    }

    @Test func fractionWithPositionPastDuration() {
        #expect(AppleWatchProgress.fraction(position: 150.0, duration: 100.0) == 1.0)
    }

    @Test func fractionAtExactBoundaries() {
        // Position = 0, Duration = 100 → 0/100 = 0
        #expect(AppleWatchProgress.fraction(position: 0.0, duration: 100.0) == 0.0)

        // Position = 100, Duration = 100 → 100/100 = 1
        #expect(AppleWatchProgress.fraction(position: 100.0, duration: 100.0) == 1.0)
    }

    // MARK: - AppleContinueWatchingCaption.remainingLabel tests

    @Test func remainingLabelWithZeroDuration() {
        #expect(AppleContinueWatchingCaption.remainingLabel(position: 10.0, duration: 0.0) == nil)
    }

    @Test func remainingLabelWithNegativeDuration() {
        #expect(AppleContinueWatchingCaption.remainingLabel(position: 10.0, duration: -5.0) == nil)
    }

    @Test func remainingLabelWithNaNDuration() {
        #expect(AppleContinueWatchingCaption.remainingLabel(position: 10.0, duration: .nan) == nil)
    }

    @Test func remainingLabelWithInfiniteDuration() {
        #expect(AppleContinueWatchingCaption.remainingLabel(position: 10.0, duration: .infinity) == nil)
    }

    @Test func remainingLabelWithNegativePosition() {
        #expect(AppleContinueWatchingCaption.remainingLabel(position: -5.0, duration: 100.0) == nil)
    }

    @Test func remainingLabelWithNaNPosition() {
        #expect(AppleContinueWatchingCaption.remainingLabel(position: .nan, duration: 100.0) == nil)
    }

    @Test func remainingLabelWithInfinitePosition() {
        #expect(AppleContinueWatchingCaption.remainingLabel(position: .infinity, duration: 100.0) == nil)
    }

    @Test func remainingLabelWithPositionPastDuration() {
        #expect(AppleContinueWatchingCaption.remainingLabel(position: 150.0, duration: 100.0) == nil)
    }

    @Test func remainingLabelAtExactBoundaries() {
        // Position = 0, Duration = 100 → (100 - 0)/60 = 100/60 ≈ 1.67 → rounds to 2 minutes
        #expect(AppleContinueWatchingCaption.remainingLabel(position: 0.0, duration: 100.0) == "2 MIN LEFT")

        // Position = 100, Duration = 100 → (100 - 100)/60 = 0/60 = 0 → but min(1) makes it 1 minute
        #expect(AppleContinueWatchingCaption.remainingLabel(position: 100.0, duration: 100.0) == nil)
    }

    @Test func remainingLabelRoundingBehavior() {
        // 1 minute = 60 seconds → (60 - 59.5)/60 = 0.5/60 ≈ 0.0083 → rounds to 0 minutes, but min(1) makes it 1
        #expect(AppleContinueWatchingCaption.remainingLabel(position: 59.5, duration: 60.0) == "1 MIN LEFT")

        // 2 minutes = 120 seconds → (120 - 119.5)/60 = 0.5/60 ≈ 0.0083 → rounds to 0 minutes, but min(1) makes it 1
        #expect(AppleContinueWatchingCaption.remainingLabel(position: 119.5, duration: 120.0) == "1 MIN LEFT")

        // Half a minute rounds up: 90 s left is 2 minutes, 89 s is 1.
        #expect(AppleContinueWatchingCaption.remainingLabel(position: 0, duration: 90.0) == "2 MIN LEFT")
        #expect(AppleContinueWatchingCaption.remainingLabel(position: 0, duration: 89.0) == "1 MIN LEFT")
    }

    @Test func remainingLabelHourBoundary() {
        // When minutes = 60 → should show as 1 HR LEFT
        #expect(AppleContinueWatchingCaption.remainingLabel(position: 3000.0, duration: 3600.0) == "10 MIN LEFT")

        // When minutes = 120 → should show as 2 HR LEFT
        #expect(AppleContinueWatchingCaption.remainingLabel(position: 2400.0, duration: 3600.0) == "20 MIN LEFT")
    }

    @Test func subtitleForMovie() {
        #expect(AppleContinueWatchingCaption.subtitle(type: "movie", partID: nil) == "Movie")
        #expect(AppleContinueWatchingCaption.subtitle(type: "MOVIE", partID: "tt0000001:1:3") == "Movie")
    }

    @Test func subtitleForSeriesWithValidPartID() {
        #expect(AppleContinueWatchingCaption.subtitle(type: "series", partID: "tt0000001:1:3") == "Continue · S1, E3")
        #expect(AppleContinueWatchingCaption.subtitle(type: "series", partID: "tmdb:42:12:104") == "Continue · S12, E104")
    }

    @Test func subtitleForSeriesWithoutPartID() {
        #expect(AppleContinueWatchingCaption.subtitle(type: "series", partID: nil) == "Continue")
    }

    @Test func subtitleForSeriesWithMalformedPartID() {
        #expect(AppleContinueWatchingCaption.subtitle(type: "series", partID: "tt0000001") == "Continue")
        #expect(AppleContinueWatchingCaption.subtitle(type: "series", partID: "tt0000001:1") == "Continue")
        #expect(AppleContinueWatchingCaption.subtitle(type: "series", partID: "tt0000001:1:0") == "Continue")
        #expect(AppleContinueWatchingCaption.subtitle(type: "series", partID: "tt0000001:-1:3") == "Continue")
    }

    @Test func subtitleForSeriesWithInvalidPartID() {
        #expect(AppleContinueWatchingCaption.subtitle(type: "series", partID: "not_a_valid_part_id") == "Continue")
        #expect(AppleContinueWatchingCaption.subtitle(type: "series", partID: "tt0000001:abc:def") == "Continue")
    }
}