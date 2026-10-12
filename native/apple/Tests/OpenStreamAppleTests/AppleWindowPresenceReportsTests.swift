import Testing
@testable import OpenStreamApple

/// N22b: the Mac window probe reports after the SwiftUI update that moved
/// it, and only what is still true and new by then.
@Suite struct AppleWindowPresenceReportsTests {
    @Test func theFirstReportGoesOutEitherWay() {
        var inWindow = AppleWindowPresenceReports()
        #expect(inWindow.report(true, stillPresent: true) == true)
        var outOfWindow = AppleWindowPresenceReports()
        #expect(outOfWindow.report(false, stillPresent: false) == false)
    }

    @Test func aRepeatedValueIsSentOnce() {
        var reports = AppleWindowPresenceReports()
        #expect(reports.report(true, stillPresent: true) == true)
        #expect(reports.report(true, stillPresent: true) == nil)
        #expect(reports.report(false, stillPresent: false) == false)
        #expect(reports.report(false, stillPresent: false) == nil)
        #expect(reports.lastReported == false)
    }

    /// Moved out and back in before either report was delivered: the stale
    /// "out" is dropped and only the current "in" goes out.
    @Test func aReportTheViewHasMovedOnFromIsDropped() {
        var reports = AppleWindowPresenceReports()
        #expect(reports.report(true, stillPresent: true) == true)
        #expect(reports.report(false, stillPresent: true) == nil)
        #expect(reports.report(true, stillPresent: true) == nil)
        #expect(reports.lastReported == true)
    }
}
