import Foundation
import Testing
@testable import OpenStreamApple

@Suite("Apple TV guide metrics")
struct AppleTVGuideMetricsTests {
    private let metrics = AppleTVGuideMetrics.standard

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: iso)!
    }

    @Test func specValuesFromSectionC() {
        #expect(metrics.horizontalSafeInset == 80)
        #expect(metrics.verticalSafeInset == 60)
        #expect(metrics.railWidth == 340)
        #expect(metrics.logoSize == CGSize(width: 64, height: 36))
        #expect(metrics.slotMinutes == 30)
        #expect(metrics.slotWidth == 240)
        #expect(metrics.rowHeight == 68)
        #expect(metrics.nowLineWidth == 3)
        #expect(metrics.titleFontSize == 29)
        #expect(metrics.subtitleFontSize == 25)
        #expect(metrics.railNameFontSize == 25)
        #expect(metrics.cellFontSize == 25)
        #expect(metrics.headerFontSize == 23)
        #expect(metrics.pillFontSize == 31)
        #expect(metrics.pillSize == CGSize(width: 220, height: 66))
    }

    /// The flat guide cells: a 4 pt gap between them, an 8 pt corner and an
    /// info panel tall enough for a description and a watchable preview.
    @Test func cellsAreFlatWithAFourPointGap() {
        #expect(metrics.cellGap == 4)
        #expect(metrics.cornerRadius == 8)
        #expect(metrics.stripHeight == 196)
    }

    /// The preview tile is 16:9 and large enough to read as a picture rather
    /// than a thumbnail (owner: "i'd like a bigger preview like paramount").
    @Test func theChannelPreviewIsWidescreenAndFitsTheStrip() {
        #expect(metrics.stripLogoSize == CGSize(width: 320, height: 180))
        #expect(metrics.stripLogoSize.width / metrics.stripLogoSize.height == 16.0 / 9.0 as CGFloat)
        #expect(metrics.stripLogoSize.height <= metrics.stripHeight)
    }

    @Test func timelineFillsTheSafeAreaBesideTheRail() {
        #expect(metrics.contentWidth == 1760)
        #expect(metrics.timelineWidth == 1420)
        #expect(abs(metrics.visibleSlots - 1420.0 / 240.0) < 0.0001)
        #expect(metrics.cellHeight == 64)
    }

    /// The dense guide (owner + Strand users, 2026-10-01): close to three
    /// hours across and at least six channels down in the space that showed
    /// two and a half hours and four and a half channels.
    @Test func theDenseGuideShowsThreeHoursAndSixRows() {
        #expect(metrics.visibleSlots * Double(metrics.slotMinutes) >= 170)
        #expect(metrics.visibleRowCount(availableHeight: 470) >= 6)
        // A compact rail line: logo, number and name side by side.
        #expect(metrics.logoSize.width + metrics.railNumberWidth + 160 <= metrics.railPlayWidth)
        #expect(metrics.logoSize.height < metrics.cellHeight)
    }

    @Test func onlyTheProgrammeOnNowHasProgress() {
        let start = date("2026-09-14T20:30:00Z")
        let end = start.addingTimeInterval(3600)
        #expect(metrics.progress(start: start, end: end, now: start.addingTimeInterval(900)) == 0.25)
        #expect(metrics.progress(start: start, end: end, now: start) == 0)
        #expect(metrics.progress(start: start, end: end, now: end) == nil)
        #expect(metrics.progress(start: start, end: end, now: start.addingTimeInterval(-1)) == nil)
        #expect(metrics.progress(start: end, end: start, now: start) == nil)
    }

    @Test func windowStartsAtTheCurrentHalfHourAndRunsToMidnight() {
        let now = date("2026-09-14T20:47:12Z")
        let window = metrics.window(now: now, calendar: utc)
        #expect(window.start == date("2026-09-14T20:30:00Z"))
        #expect(window.end == date("2026-09-15T00:00:00Z"))
    }

    @Test func windowNeverShrinksBelowThreeHoursLateAtNight() {
        let now = date("2026-09-14T23:50:00Z")
        let window = metrics.window(now: now, calendar: utc)
        #expect(window.start == date("2026-09-14T23:30:00Z"))
        #expect(window.end == date("2026-09-15T02:30:00Z"))
    }

    @Test func timelineContentWidthRoundsUpToWholeSlots() {
        let start = date("2026-09-14T20:30:00Z")
        #expect(metrics.timelineContentWidth(for: DateInterval(start: start, duration: 2 * 3600)) == 960)
        #expect(metrics.timelineContentWidth(for: DateInterval(start: start, duration: 2 * 3600 + 900)) == 1200)
        #expect(metrics.timelineContentWidth(for: DateInterval(start: start, duration: 0)) == 0)
    }

    @Test func xOffsetMapsMinutesToPointsAndClamps() {
        let start = date("2026-09-14T20:30:00Z")
        let window = DateInterval(start: start, duration: 3 * 3600)
        #expect(metrics.xOffset(of: start.addingTimeInterval(45 * 60), in: window) == 360)
        #expect(metrics.xOffset(of: start.addingTimeInterval(-600), in: window) == 0)
        #expect(metrics.xOffset(of: start.addingTimeInterval(10 * 3600), in: window) == 1440)
    }

    @Test func cellWidthLeavesTheGapAndNeverGoesNegative() {
        #expect(metrics.cellWidth(columnSpan: 1) == 236)
        #expect(metrics.cellWidth(columnSpan: 3) == 716)
        #expect(metrics.cellWidth(columnSpan: 0.001) == 0)
    }

    /// A cell draws its title or nothing; there is no subtitle to drop, so the
    /// only threshold that matters is the one that silences the cell entirely.
    @Test func narrowCellsDropTheirTextEntirely() {
        #expect(metrics.showsText(cellWidth: 236))
        #expect(metrics.showsText(cellWidth: 156))
        #expect(metrics.showsText(cellWidth: metrics.textMinimumCellWidth))
        #expect(!metrics.showsText(cellWidth: metrics.textMinimumCellWidth - 1))
        #expect(!metrics.showsText(cellWidth: 40))
        #expect(!metrics.showsText(cellWidth: 0))
    }

    @Test func gapCellsAreRecognisedByTheGridModelName() {
        #expect(metrics.isGapCell(id: "ch1-gap-1757880000.0"))
        #expect(!metrics.isGapCell(id: "ch1-programme-1757880000.0"))
    }

    @Test func visibleRowsAreWholeRows() {
        #expect(metrics.visibleRowCount(availableHeight: 590) == 8)
        #expect(metrics.visibleRowCount(availableHeight: 0) == 0)
    }

    @Test func nowLineFollowsTheScrolledTimeline() {
        let start = date("2026-09-14T20:30:00Z")
        let window = DateInterval(start: start, duration: 3 * 3600)
        let now = start.addingTimeInterval(20 * 60)
        #expect(metrics.nowLineX(now: now, window: window, scrolledX: 0) == CGFloat(20.0 / 30.0) * 240)
        #expect(metrics.nowLineX(now: now, window: window, scrolledX: 480) == nil)
        #expect(metrics.nowLineX(now: start.addingTimeInterval(-60), window: window, scrolledX: 0) == nil)
    }

    @Test func headerSlotsMatchTheSlotWidth() {
        let start = date("2026-09-14T20:30:00Z")
        let window = DateInterval(start: start, duration: 3 * 3600)
        let header = AppleGuideGridModel.build(channels: [], programmes: [:], window: window,
            slotWidthMinutes: metrics.slotMinutes, now: start)
        #expect(header.headerSlots.count == 6)
        #expect(CGFloat(header.headerSlots.count) * metrics.slotWidth == metrics.timelineContentWidth(for: window))
    }
}

/// Apple TV pass 2026-10-02 (16): a programme that started before the visible
/// left edge drew an empty cell — its title sat at the off-screen start.
@Test func guideTitlePinsToTheVisibleLeftEdge() {
    let metrics = AppleTVGuideMetrics.standard
    let inset = metrics.cellInset
    // Cell start on screen: no slide.
    #expect(metrics.pinnedTitleOffset(titleMinX: 200 + inset, cellWidth: 480) == 0)
    // Cell started 300 pt off screen: the title lands at the visible edge + inset.
    #expect(metrics.pinnedTitleOffset(titleMinX: -300 + inset, cellWidth: 900) == 300)
    // Nearly scrolled past: never slides beyond the cell's last readable stretch.
    #expect(metrics.pinnedTitleOffset(titleMinX: -1000, cellWidth: 480)
        == 480 - metrics.textMinimumCellWidth)
}
