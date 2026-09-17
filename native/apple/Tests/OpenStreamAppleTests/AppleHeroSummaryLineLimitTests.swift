import SwiftUI
import Testing
@testable import OpenStreamApple

/// At the largest accessibility text size the hero's four-line summary pushed
/// **Play and Details off the bottom of the screen** — the primary action on
/// the landing screen was only reachable by scrolling. Measured on an iPhone
/// 16 Pro at `accessibility-extra-extra-extra-large`.
@Suite("Hero summary line limit")
struct AppleHeroSummaryLineLimitTests {
    @Test func ordinarySizesKeepThreeLines() {
        for size in [DynamicTypeSize.xSmall, .small, .medium, .large, .xLarge, .xxLarge, .xxxLarge] {
            #expect(AppleHeroSummaryLineLimit.lines(for: size) == 3)
        }
    }

    /// The sizes that were actually pushing the buttons off.
    @Test func theLargestSizesShowASingleLine() {
        for size in [DynamicTypeSize.accessibility3, .accessibility4, .accessibility5] {
            #expect(AppleHeroSummaryLineLimit.lines(for: size) == 1)
        }
    }

    @Test func theFirstAccessibilityStepsKeepTwo() {
        for size in [DynamicTypeSize.accessibility1, .accessibility2] {
            #expect(AppleHeroSummaryLineLimit.lines(for: size) == 2)
        }
    }

    /// The whole point: more text must never mean more lines.
    @Test func theLimitNeverGrowsAsTypeGrows() {
        let sizes = DynamicTypeSize.allCases.sorted()
        for (smaller, larger) in zip(sizes, sizes.dropFirst()) {
            #expect(AppleHeroSummaryLineLimit.lines(for: larger)
                    <= AppleHeroSummaryLineLimit.lines(for: smaller),
                    "\(larger) shows more lines than \(smaller)")
        }
    }

    @Test func everySizeShowsAtLeastOneLine() {
        for size in DynamicTypeSize.allCases {
            #expect(AppleHeroSummaryLineLimit.lines(for: size) >= 1)
        }
    }
}
