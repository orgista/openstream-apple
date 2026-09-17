import Foundation
import Testing
@testable import OpenStreamApple

@Suite("Apple TV Settings split layout")
struct AppleTVSettingsLayoutTests {
    private let metrics = AppleTVSettingsMetrics.standard

    @Test func sectionsListInTheOwnerOrder() {
        #expect(AppleTVSettingsSection.allCases.map(\.title) == [
            "Sources", "Channel Manager", "Live TV", "Discover", "Services",
            "Playback", "Privacy", "Storage", "About",
        ])
        #expect(AppleTVSettingsSection.allCases.count == 9)
        #expect(AppleTVSettingsSection.defaultSelection == .sources)
        #expect(AppleTVSettingsSection.allCases.first == .sources)
        #expect(AppleTVSettingsSection.allCases.last == .about)
    }

    @Test func everySectionHasItsOwnGlyphAndIdentity() {
        let images = AppleTVSettingsSection.allCases.map(\.systemImage)
        #expect(Set(images).count == images.count)
        #expect(images.allSatisfy { !$0.isEmpty })

        let ids = AppleTVSettingsSection.allCases.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(AppleTVSettingsSection(rawValue: "channels") == .channels)
    }

    @Test func specValuesFromSectionC() {
        #expect(metrics.horizontalSafeInset == 80)
        #expect(metrics.sidebarWidth == 420)
        #expect(metrics.rowHeight == 72)
        #expect(metrics.iconSpacing == 16)
        #expect(metrics.headerFontSize == 48)
        #expect(metrics.bodyFontSize == 29)
        #expect(metrics.captionFontSize == 25)
        #expect(metrics.pillFontSize == 31)
        #expect(metrics.pillSize == CGSize(width: 220, height: 66))
    }

    @Test func sidebarStartsAtTheSafeInsetAndTheDetailFillsTheRest() {
        #expect(metrics.sidebarMinX == 80)
        #expect(metrics.detailMinX == 80 + 420 + metrics.columnSpacing)
        #expect(metrics.detailMinX + metrics.detailWidth + metrics.horizontalSafeInset == metrics.screenWidth)
        #expect(metrics.detailWidth >= metrics.formMaximumWidth)
        #expect(metrics.formColumnWidth <= metrics.formMaximumWidth)
    }

    @Test func nineRowsFitAboveTheBottomSafeInsetWithoutScrolling() {
        let rows = CGFloat(AppleTVSettingsSection.allCases.count)
        let listHeight = rows * metrics.rowHeight + (rows - 1) * metrics.rowSpacing
        // 1080 pt screen less the 60 pt top and bottom insets and the 68 pt
        // tab bar with its 46 pt top offset.
        let available: CGFloat = 1080 - 60 - 60 - 68 - 46
        #expect(listHeight <= available)
    }
}
