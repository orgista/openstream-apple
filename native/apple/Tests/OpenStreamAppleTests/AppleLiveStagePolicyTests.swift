import CoreGraphics
import Testing
@testable import OpenStreamApple

@Suite("Live stage layout")
struct AppleLiveStagePolicyTests {
    @Test func phonesAndPortraitWindowsStack() {
        #expect(!AppleLiveStagePolicy.sideBySide(isRegularWidth: false, size: CGSize(width: 430, height: 932)))
        #expect(!AppleLiveStagePolicy.sideBySide(isRegularWidth: true, size: CGSize(width: 1032, height: 1376)))
        #expect(!AppleLiveStagePolicy.sideBySide(isRegularWidth: false, size: CGSize(width: 932, height: 430)))
    }

    @Test func wideRegularVisionWindowsSitSideBySide() {
        #expect(AppleLiveStagePolicy.sideBySide(isRegularWidth: true, size: CGSize(width: 1376, height: 1032)))
    }

    /// Owner 2026-10-21: iPad Live fills the screen like Paramount+ in every window.
    @Test(arguments: [
        CGSize(width: 1376, height: 1032), CGSize(width: 1032, height: 1376),
        CGSize(width: 1180, height: 820), CGSize(width: 678, height: 1032), CGSize(width: 1024, height: 700),
    ])
    func everyIPadWindowStacks(_ size: CGSize) {
        #expect(!AppleLiveStagePolicy.sideBySide(isRegularWidth: true, size: size, isPad: true))
    }

    @Test func anUprightStageSpansTheWidthAtSixteenByNine() {
        #expect(AppleLiveStagePolicy.stackedStageHeight(size: CGSize(width: 1032, height: 1300)) == 580)
        #expect(AppleLiveStagePolicy.stackedStageHeight(size: CGSize(width: 678, height: 1000)) == 381)
    }

    /// 1376 wide at 16:9 is 774 pt, which leaves under three rows below the strip.
    @Test func aStageOnItsSideGivesUpHeightForThreeRows() {
        let size = CGSize(width: 1376, height: 1000)
        let height = AppleLiveStagePolicy.stackedStageHeight(size: size)
        #expect(height == 1000 - AppleLiveStagePolicy.phoneCategoryHeight
            - CGFloat(AppleLiveStagePolicy.minimumStackedRows) * AppleLiveStagePolicy.phoneChannelRowHeight)
        #expect(height < size.width * 9 / 16)
    }

    @Test func anUnmeasuredWindowHasNoStage() {
        #expect(AppleLiveStagePolicy.stackedStageHeight(size: .zero) == 0)
    }

    @Test func playerTakesSixtyTwoPercentButLeavesTheGuideRoom() {
        #expect(AppleLiveStagePolicy.playerWidth(total: 1376) == 853)
        #expect(AppleLiveStagePolicy.playerWidth(total: 900) == 558)
        #expect(AppleLiveStagePolicy.playerWidth(total: 600) == 260)
    }
}
