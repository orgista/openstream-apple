import Testing
@testable import OpenStreamApple

@MainActor
@Suite("Live full-screen chrome")
struct AppleLiveSystemChromePolicyTests {
    @Test func skipsNeedARewindWindowLongerThanThirtySeconds() {
        #expect(!AppleLiveSystemChromePolicy.showsSkips(dvrSpan: 0))
        #expect(!AppleLiveSystemChromePolicy.showsSkips(dvrSpan: 30))
        #expect(AppleLiveSystemChromePolicy.showsSkips(dvrSpan: 31))
    }

    @Test func behindTextOnlyWhileBehindTheEdge() throws {
        let range = try #require(AppleSeekableRange(start: 0, end: 600))
        #expect(AppleLiveSystemChromePolicy.behindText(position: 600, range: range, tolerance: 5) == nil)
        #expect(AppleLiveSystemChromePolicy.behindText(position: 597, range: range, tolerance: 5) == nil)
        #expect(AppleLiveSystemChromePolicy.behindText(position: 558, range: range, tolerance: 5) == "−0:42")
        #expect(AppleLiveSystemChromePolicy.behindText(position: 300, range: nil, tolerance: 5) == nil)
    }

    @Test func zapSwipesStartOnlyInTheMiddleSixtyPercent() {
        #expect(!AppleLiveSystemChromePolicy.acceptsZapSwipe(startY: 50, height: 1000))
        #expect(AppleLiveSystemChromePolicy.acceptsZapSwipe(startY: 200, height: 1000))
        #expect(AppleLiveSystemChromePolicy.acceptsZapSwipe(startY: 500, height: 1000))
        #expect(!AppleLiveSystemChromePolicy.acceptsZapSwipe(startY: 900, height: 1000))
        #expect(!AppleLiveSystemChromePolicy.acceptsZapSwipe(startY: 500, height: 0))
    }

    @Test func liveChromeHidesAfterFourSeconds() {
        #expect(AppleLiveSystemChromePolicy.autoHideSeconds == 4)
    }
}
