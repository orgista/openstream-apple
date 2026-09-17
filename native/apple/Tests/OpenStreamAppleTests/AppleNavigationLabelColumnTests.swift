import SwiftUI
import Testing
@testable import OpenStreamApple

/// At accessibility text sizes a stock `Label` re-flows and lets the wrapped
/// line escape the title column: "Channel Manager" put "Manager" on a second
/// line starting at the row's leading edge, underneath the glyph. Measured on
/// an iPhone 16 Pro at `accessibility-extra-extra-extra-large`.
@Suite("Settings row icon column")
struct AppleNavigationLabelColumnTests {
    @Test func ordinarySizesKeepTheStockLabel() {
        for size in [DynamicTypeSize.xSmall, .small, .medium, .large, .xLarge, .xxLarge, .xxxLarge] {
            #expect(!AppleTVNavigationLabel.usesFixedIconColumn(for: size),
                    "\(size) should use the stock label, which is correct there")
        }
    }

    @Test func everyAccessibilitySizeTakesTheColumnOver() {
        for size in [DynamicTypeSize.accessibility1, .accessibility2,
                     .accessibility3, .accessibility4, .accessibility5] {
            #expect(AppleTVNavigationLabel.usesFixedIconColumn(for: size))
        }
    }

    /// Once a size takes the fixed column, every larger size must too —
    /// otherwise the wrap bug returns at the very top of the range.
    @Test func theBehaviourNeverReversesAsTypeGrows() {
        let sizes = DynamicTypeSize.allCases.sorted()
        var seenFixed = false
        for size in sizes {
            let fixed = AppleTVNavigationLabel.usesFixedIconColumn(for: size)
            if seenFixed { #expect(fixed, "\(size) reverted to the stock label") }
            seenFixed = seenFixed || fixed
        }
    }

    @Test func thePhoneSlotIsNarrowerThanTheTelevisionOne() {
        #expect(AppleTVNavigationLabel.compactIconSlotWidth
                < AppleTVNavigationLabel.iconSlotWidth)
        #expect(AppleTVNavigationLabel.compactIconSlotWidth > 0)
    }
}
