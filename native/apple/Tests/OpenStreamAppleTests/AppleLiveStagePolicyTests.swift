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

    @Test func wideRegularWindowsSitSideBySide() {
        #expect(AppleLiveStagePolicy.sideBySide(isRegularWidth: true, size: CGSize(width: 1376, height: 1032)))
    }

    @Test func playerTakesSixtyTwoPercentButLeavesTheGuideRoom() {
        #expect(AppleLiveStagePolicy.playerWidth(total: 1376) == 853)
        #expect(AppleLiveStagePolicy.playerWidth(total: 900) == 558)
        #expect(AppleLiveStagePolicy.playerWidth(total: 600) == 260)
    }
}
