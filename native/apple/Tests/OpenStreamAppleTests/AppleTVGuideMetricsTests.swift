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
        #expect(metrics.railWidth == 260)
        #expect(metrics.logoSize == CGSize(width: 88, height: 50))
        #expect(metrics.slotMinutes == 30)
        #expect(metrics.slotWidth == 320)
        #expect(metrics.rowHeight == 100)
        #expect(metrics.nowLineWidth == 3)
        #expect(metrics.titleFontSize == 29)
        #expect(metrics.subtitleFontSize == 25)
        #expect(metrics.railNameFontSize == 25)
        #expect(metrics.headerFontSize == 23)
        #expect(metrics.pillFontSize == 31)
        #expect(metrics.pillSize == CGSize(width: 220, height: 66))
    }

    /// The flat guide cells: a 6 pt gap between them, an 8 pt corner and an
    /// info panel tall enough for a description and a watchable preview.
    @Test func cellsAreFlatWithASixPointGap() {
        #expect(metrics.cellGap == 6)
        #expect(metrics.cornerRadius == 8)
        #expect(metrics.stripHeight == 196)
    }

    /// The preview tile is 16:9 and large enough to read as a picture rather
    /// than a thumbnail (owner: "i'd like a bigger preview like paramount").
    @Test func theChannelPreviewIsWidescreenAndFitsTheStrip() {
        #expect(metrics.stripLogoSize == CGSize(width: 320, height: 180))
        #expect(metrics.stripLogoSize.width / metrics.stripLogoSize.height == 16.0 / 9.0)
        #expect(metrics.stripLogoSize.height <= metrics.stripHeight)
    }

    @Test func timelineFillsTheSafeAreaBesideTheRail() {
        #expect(metrics.contentWidth == 1760)
        #expect(metrics.timelineWidth == 1500)
        #expect(abs(metrics.visibleSlots - 4.6875) < 0.0001)
        #expect(metrics.cellHeight == 94)
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
        #expect(metrics.timelineContentWidth(for: DateInterval(start: start, duration: 2 * 3600)) == 1280)
        #expect(metrics.timelineContentWidth(for: DateInterval(start: start, duration: 2 * 3600 + 900)) == 1600)
        #expect(metrics.timelineContentWidth(for: DateInterval(start: start, duration: 0)) == 0)
    }

    @Test func xOffsetMapsMinutesToPointsAndClamps() {
        let start = date("2026-09-14T20:30:00Z")
        let window = DateInterval(start: start, duration: 3 * 3600)
        #expect(metrics.xOffset(of: start.addingTimeInterval(45 * 60), in: window) == 480)
        #expect(metrics.xOffset(of: start.addingTimeInterval(-600), in: window) == 0)
        #expect(metrics.xOffset(of: start.addingTimeInterval(10 * 3600), in: window) == 1920)
    }

    @Test func cellWidthLeavesTheGapAndNeverGoesNegative() {
        #expect(metrics.cellWidth(columnSpan: 1) == 314)
        #expect(metrics.cellWidth(columnSpan: 3) == 954)
        #expect(metrics.cellWidth(columnSpan: 0.001) == 0)
    }

    /// A cell draws its title or nothing; there is no subtitle to drop, so the
    /// only threshold that matters is the one that silences the cell entirely.
    @Test func narrowCellsDropTheirTextEntirely() {
        #expect(metrics.showsText(cellWidth: 314))
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
        #expect(metrics.visibleRowCount(availableHeight: 590) == 5)
        #expect(metrics.visibleRowCount(availableHeight: 0) == 0)
    }

    @Test func nowLineFollowsTheScrolledTimeline() {
        let start = date("2026-09-14T20:30:00Z")
        let window = DateInterval(start: start, duration: 3 * 3600)
        let now = start.addingTimeInterval(20 * 60)
        #expect(metrics.nowLineX(now: now, window: window, scrolledX: 0) == CGFloat(20.0 / 30.0) * 320)
        #expect(metrics.nowLineX(now: now, window: window, scrolledX: 640) == nil)
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
