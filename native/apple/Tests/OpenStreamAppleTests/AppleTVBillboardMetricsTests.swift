import CoreGraphics
import Testing
@testable import OpenStreamApple

@Suite("Apple TV billboard metrics")
struct AppleTVBillboardMetricsTests {
    private typealias M = AppleTVBillboardMetrics

    @Test func artFillsTheTopOfTheScreenEdgeToEdge() {
        #expect(M.screenSize == CGSize(width: 1920, height: 1080))
        #expect(M.artHeight >= M.screenSize.height * 0.6)
        #expect(M.artHeight < M.screenSize.height)
    }

    /// N43: the buttons' focus section spans the screen inside the gutters,
    /// so a tab anywhere along the bar is above it.
    @Test func theButtonsFocusSectionSpansTheSafeZone() {
        #expect(M.actionsFocusWidth == M.screenSize.width - 2 * M.copyLeadingInset)
        #expect(M.actionsFocusWidth > M.copyColumnWidth)
    }

    @Test func copySitsInTheSafeZoneAboveTheFirstRow() {
        #expect(M.copyLeadingInset == AppleTVChromeMetrics.horizontalSafeInset)
        #expect(M.copyBottom < M.firstRowTop)
    }

    /// The first row peeks; it is not fully on screen.
    ///
    /// This used to require the opposite — a whole row of posters visible
    /// without scrolling — which is why the hero was only 65 % of the screen.
    /// The owner asked for the hero to "take more of the screen" and Continue
    /// Watching to move "until you scroll down" (2026-09-15), matching the
    /// reference apps. The guarantee worth keeping is that the row is
    /// *discoverable*: its header is on screen so there is visibly more below,
    /// but reaching the row means scrolling.
    @Test func firstRowPeeksSoTheHeroOwnsTheScreen() {
        let posterHeight = M.posterWidth * 1.5
        let rowTopToPosterBottom = M.rowTitleFontSize + M.rowTitleSpacing + posterHeight

        // Visible enough to say "there is more here".
        #expect(M.firstRowTop < M.screenSize.height)
        #expect(M.screenSize.height - M.firstRowTop >= 100)
        // But not the whole row, or there would be nothing to scroll for.
        #expect(M.firstRowTop + rowTopToPosterBottom > M.screenSize.height)
        // And the hero really does own most of the screen.
        #expect(M.artHeight >= M.screenSize.height * 0.85)
    }

    @Test func firstRowClimbsIntoTheFade() {
        #expect(M.rowOverlap > 0)
        #expect(M.firstRowTop < M.artHeight)
        #expect(M.usesFade)
        #expect(M.fadeStartFraction > 0 && M.fadeStartFraction < 0.5)
        // The row header sits where the fade is already near black.
        let headerFraction = M.firstRowTop / M.artHeight
        #expect(headerFraction > 0.8)
    }

    @Test func pillsMatchTheTitlePagePill() {
        #expect(M.pillSize.height == AppleTVDetailMetrics.pillSize.height)
        #expect(M.pillFontSize == AppleTVDetailMetrics.pillFontSize)
        #expect(M.pillGlyphSize == AppleTVDetailMetrics.pillGlyphSize)
    }

    /// Apple TV walk 9: the focused first card covered its row title, and the
    /// Library's focused header touched the posters.
    @Test func aFocusedCardClearsItsTitleAndTheRowsBreatheEvenly() {
        #expect(M.rowTitleSpacing >= M.focusLift + 16)
        // A 600 pt poster at the system's largest card scale (1.1).
        #expect(M.focusLift >= M.posterWidth * 1.5 * 0.05)
        // A title sits nearer its own row than the row above.
        #expect(M.sectionSpacing > M.rowTitleSpacing)
        // The focused poster's caption stays clear of the next title.
        #expect(M.sectionSpacing >= M.focusedCaptionBottom + 16)
    }

    /// The first row's header stays where the billboard was composed for.
    @Test func widerRowsLeaveTheFirstRowHeaderWhereItWas() {
        #expect(M.firstRowTop == 904)
        #expect(M.artHeight - M.rowOverlap + M.sectionSpacing == M.firstRowTop)
    }

    @Test func rowsShareTheCopyColumn() {
        #expect(M.rowHorizontalInset == 0)
        #expect(M.cardGap >= 16)
    }
}
