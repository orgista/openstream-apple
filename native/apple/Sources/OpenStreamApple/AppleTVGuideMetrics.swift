import CoreGraphics
import Foundation

/// Apple TV guide geometry: a 1920x1080 point canvas with 80/60 safe insets.
///
/// Dense since 2026-10-01 (TiviMate-style, the owner's and Strand users' top
/// complaint about the guide): a 340 pt rail with one compact line per channel
/// (64x36 logo, number, name), 68 pt rows and 240 pt per half hour, so about
/// seven channels and three hours are on screen instead of four and a half
/// channels and two and a half hours. Every value is plain data so the layout
/// can be asserted without a view.
public struct AppleTVGuideMetrics: Sendable, Equatable {
    public static let standard = AppleTVGuideMetrics()

    public var screenSize = CGSize(width: 1920, height: 1080)
    public var horizontalSafeInset: CGFloat = 80
    public var verticalSafeInset: CGFloat = 60

    public var railWidth: CGFloat = 340
    public var logoSize = CGSize(width: 64, height: 36)
    /// The channel number column, wide enough for four digits.
    public var railNumberWidth: CGFloat = 60
    public var slotMinutes = 30
    public var slotWidth: CGFloat = 240
    public var rowHeight: CGFloat = 68
    public var cellGap: CGFloat = 4
    public var cellInset: CGFloat = 14
    public var cornerRadius: CGFloat = 8
    public var headerHeight: CGFloat = 36
    public var nowLineWidth: CGFloat = 3
    /// The elapsed-time bar under the programme on now.
    public var progressBarHeight: CGFloat = 4

    /// The info panel above the category row: tall enough for a title, the
    /// channel and time line, and two lines of description — and for a
    /// channel preview big enough to actually watch.
    ///
    /// The preview tile was 160x90, which the owner called out beside the
    /// competition: "preview is small on live i'd like a bigger preview like
    /// paramount" (2026-09-15). At 320x180 the picture is four times the area
    /// and the panel costs 76 pt of guide height — under one row.
    public var stripHeight: CGFloat = 196
    public var stripLogoSize = CGSize(width: 320, height: 180)
    /// The info strip's text column; a description wraps to two lines inside it.
    public var stripTextMaxWidth: CGFloat = 1200
    public var pillSize = CGSize(width: 220, height: 66)
    public var categoryPillHeight: CGFloat = 56
    public var sectionSpacing: CGFloat = 14

    /// The channel footer over full-screen live playback: card size, the
    /// logo inside it and the row's height including its padding.
    /// Tall enough for the logo, the channel name on its own line and the
    /// programme now showing (owner 2026-09-15: "would like to also see what
    /// is playing"). The card was 176 when the name and LIVE shared one row.
    public var footerCardSize = CGSize(width: 224, height: 214)
    public var footerLogoSize = CGSize(width: 200, height: 112)
    public var footerHeight: CGFloat = 278
    public var footerCardSpacing: CGFloat = 24

    // tvOS SF Pro text styles: Body 29, Callout 31, Caption 1 25, Caption 2 23.
    public var titleFontSize: CGFloat = 29
    public var subtitleFontSize: CGFloat = 25
    public var railNameFontSize: CGFloat = 25
    /// Programme titles in the grid: Caption 1, one step under the strip's
    /// title so a 68 pt row holds the title and the progress bar.
    public var cellFontSize: CGFloat = 25
    public var headerFontSize: CGFloat = 23
    public var badgeFontSize: CGFloat = 23
    public var pillFontSize: CGFloat = 31
    public var categoryFontSize: CGFloat = 29
    /// The phone's 6 pt health dot, scaled with the rail name (25 against
    /// the phone's 12 pt caption) so it still reads across a room.
    public var healthDotSize: CGFloat = 10

    public init() {}

    public var slotDuration: TimeInterval { TimeInterval(slotMinutes * 60) }
    public var contentWidth: CGFloat { screenSize.width - horizontalSafeInset * 2 }
    public var timelineWidth: CGFloat { contentWidth - railWidth }
    public var visibleSlots: Double { Double(timelineWidth / slotWidth) }
    public var cellHeight: CGFloat { rowHeight - cellGap }

    /// The play target inside a rail cell: the whole rail minus the column
    /// gap, so the cell lines up with the first programme cell beside it.
    public var railPlayWidth: CGFloat { railWidth - cellGap }

    /// How far through `start..<end` the moment `now` is, 0...1; nil when
    /// `now` is outside it (only the programme on now draws a bar).
    public func progress(start: Date, end: Date, now: Date) -> Double? {
        let length = end.timeIntervalSince(start)
        guard length > 0, now >= start, now < end else { return nil }
        return min(1, max(0, now.timeIntervalSince(start) / length))
    }

    /// Cells narrower than this draw no text at all.
    public var textMinimumCellWidth: CGFloat { 60 }

    /// The guide starts at the current half hour and runs to the end of the
    /// day, never shorter than `minimumHours` so a late-evening guide still has
    /// a few columns to browse.
    ///
    /// - Parameter earliest: how far back the guide may scroll for channels
    ///   with catch-up (`AppleIPTVCatchUp.earliestGuideTime`); the window then
    ///   opens on that slot instead of the current one. The current slot is
    ///   still where the guide first lands (`xOffset(of:)` of `nowSlot`).
    public func window(now: Date, calendar: Calendar = .current, minimumHours: Int = 3,
                       earliest: Date? = nil) -> DateInterval {
        let start = slotStart(of: min(now, earliest ?? now), calendar: calendar)
        let startOfDay = calendar.startOfDay(for: now)
        let nextDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? startOfDay.addingTimeInterval(86400)
        let minimumEnd = start.addingTimeInterval(TimeInterval(minimumHours) * 3600)
        return DateInterval(start: start, end: max(nextDay, minimumEnd))
    }

    /// The slot `date` falls in, rounded down to `slotMinutes`.
    public func slotStart(of date: Date, calendar: Calendar = .current) -> Date {
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        var rounded = components
        rounded.minute = ((components.minute ?? 0) / slotMinutes) * slotMinutes
        return calendar.date(from: rounded) ?? date
    }

    /// Width of one row's timeline content: whole slots, rounded up.
    public func timelineContentWidth(for window: DateInterval) -> CGFloat {
        guard window.duration > 0 else { return 0 }
        let slots = (window.duration / slotDuration).rounded(.up)
        return CGFloat(slots) * slotWidth
    }

    /// Horizontal position of `date` inside the timeline, clamped to the content.
    public func xOffset(of date: Date, in window: DateInterval) -> CGFloat {
        let seconds = date.timeIntervalSince(window.start)
        guard seconds > 0 else { return 0 }
        return min(timelineContentWidth(for: window), CGFloat(seconds / slotDuration) * slotWidth)
    }

    /// A cell spanning `columnSpan` slots, minus the gap to its neighbour.
    public func cellWidth(columnSpan: Double) -> CGFloat {
        max(0, CGFloat(columnSpan) * slotWidth - cellGap)
    }

    /// A guide cell draws its title and nothing else — the description lives in
    /// the info panel above the grid, the way the system guide does it. There
    /// was a `showsSubtitle` gate here, with a 200 pt threshold and its own
    /// test, long after the subtitle it hid stopped being drawn: dead API that
    /// made the behaviour look covered when nothing called it.
    public func showsText(cellWidth: CGFloat) -> Bool { cellWidth >= textMinimumCellWidth }

    /// How far to slide a cell's title right so it stays on screen when the
    /// cell began left of the visible timeline (a programme that started
    /// before the window's left edge read as an empty cell, 2026-10-02).
    ///
    /// - Parameters:
    ///   - titleMinX: the title's leading edge in the row's visible scroll
    ///     coordinates, before any slide (the cell's leading edge + inset).
    ///   - cellWidth: the cell's drawn width.
    /// - Returns: 0 while the cell's start is on screen; otherwise the slide
    ///   that pins the title at the visible edge plus the inset, never past
    ///   the point where less than `textMinimumCellWidth` of the cell is left.
    public func pinnedTitleOffset(titleMinX: CGFloat, cellWidth: CGFloat) -> CGFloat {
        let wanted = cellInset - titleMinX
        guard wanted > 0 else { return 0 }
        let limit = max(0, cellWidth - textMinimumCellWidth)
        return min(wanted, limit)
    }

    /// `AppleGuideGridModel` names filler cells `<channel>-gap-<time>`.
    public func isGapCell(id: String) -> Bool { id.contains("-gap-") }

    public func visibleRowCount(availableHeight: CGFloat) -> Int {
        guard availableHeight > 0, rowHeight > 0 else { return 0 }
        return Int((availableHeight / rowHeight).rounded(.down))
    }

    /// Where the now-line sits inside the visible timeline once the rows are
    /// scrolled by `scrolledX`; nil when it is off screen.
    public func nowLineX(now: Date, window: DateInterval, scrolledX: CGFloat) -> CGFloat? {
        guard window.contains(now) else { return nil }
        let x = xOffset(of: now, in: window) - scrolledX
        guard x >= 0, x <= timelineWidth else { return nil }
        return x
    }
}

// MARK: - Live playback footer state (Apple TV)

/// The channel footer over full-screen live playback on Apple TV, as a pure
/// state machine so the remote can be asserted without a view.
///
/// From a fresh player the footer is hidden. Menu, Select or a swipe down
/// shows it; Menu again or a swipe up hides it. With the footer off screen a
/// swipe up toggles captions instead (owner 2026-09-21: swipe down already
/// means the channel picker, so captions take the other direction). Once it
/// has been dismissed,
/// Menu leaves playback and returns to the guide. The view applies each
/// remote command here and acts on the returned effect, so `onExitCommand`
/// never swallows a Menu press the viewer meant as "back".
public struct AppleTVLiveFooterState: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// Fresh player; the footer has not been shown yet.
        case hidden
        /// The channel row is on screen with focus on one of its cards.
        case shown
        /// The footer was shown and hidden again; Menu now exits.
        case dismissed
    }

    public enum Command: Equatable, Sendable {
        case menu
        case swipeDown
        case swipeUp
        /// Select on the bare surface (no card focused).
        case select
        /// Select on a channel card in the footer.
        case channelSelected
    }

    public enum Effect: Equatable, Sendable {
        case none
        case show
        case hide
        case exit
        case switchChannel
        case toggleCaptions
    }

    public private(set) var phase: Phase
    /// A live TS may not announce 608 until its first packet. Remember the
    /// viewer's choice until discovery, without treating an empty list as Off.
    public private(set) var captionsArmed = false

    public mutating func togglePendingCaptions() -> String {
        captionsArmed.toggle()
        return captionsArmed ? "Captions on" : "Captions off"
    }

    public mutating func cancelPendingCaptions() {
        captionsArmed = false
    }

    /// Consume the intent once. Later track updates must not undo a menu pick.
    public mutating func takeArmedCaptionTrack(in tracks: [ApplePlaybackTrack]) -> Int? {
        guard captionsArmed, let track = tracks.first(where: { $0.id == 99_608 }) else { return nil }
        captionsArmed = false
        return track.id
    }

    public init(phase: Phase = .hidden) { self.phase = phase }

    public var isVisible: Bool { phase == .shown }

    /// `true` when the next Menu press leaves playback instead of toggling
    /// the footer.
    public var menuExits: Bool { phase == .dismissed }

    @discardableResult
    public mutating func apply(_ command: Command) -> Effect {
        switch (command, phase) {
        case (.menu, .hidden):
            phase = .shown
            return .show
        case (.menu, .shown):
            phase = .dismissed
            return .hide
        case (.menu, .dismissed):
            return .exit

        case (.swipeDown, .hidden), (.swipeDown, .dismissed), (.select, .hidden), (.select, .dismissed):
            phase = .shown
            return .show
        case (.swipeDown, .shown), (.select, .shown):
            return .none

        case (.swipeUp, .shown):
            phase = .dismissed
            return .hide
        case (.swipeUp, .hidden), (.swipeUp, .dismissed):
            return .toggleCaptions

        case (.channelSelected, .shown):
            return .switchChannel
        case (.channelSelected, .hidden), (.channelSelected, .dismissed):
            return .none
        }
    }

    /// Picking a channel closes the row and returns the footer to its fresh
    /// state, so the next Menu press shows the row again instead of leaving
    /// playback. Without this the row stayed over the picture after a switch
    /// and the player read as hung (owner 18:55).
    public mutating func reset() {
        phase = .hidden
        captionsArmed = false
    }

    /// The card that takes focus when the footer appears: the playing
    /// channel, or the first card when it is not in the row.
    public static func focusTarget(currentID: String, channelIDs: [String]) -> String? {
        if channelIDs.contains(currentID) { return currentID }
        return channelIDs.first
    }
}

// MARK: - Rail cell model (Apple TV)

/// What one channel-rail cell shows and offers, derived once from the
/// projected row and the favorites set so the view stays declarative and the
/// texts can be asserted.
public struct AppleTVGuideRailCellModel: Equatable, Sendable {
    public enum Action: Hashable, Sendable, CaseIterable {
        case play
        case favorite
    }

    public let channelID: String
    public let name: String
    public let number: Int?
    public let isFavorite: Bool

    public init(channelID: String, name: String, number: Int?, isFavorite: Bool) {
        self.channelID = channelID
        self.name = name
        self.number = number
        self.isFavorite = isFavorite
    }

    public init(channelID: String, name: String, number: Int?, favoriteIDs: Set<String>) {
        self.init(channelID: channelID, name: name, number: number, isFavorite: favoriteIDs.contains(channelID))
    }

    init(row: AppleGuideChannel, favoriteIDs: Set<String>) {
        self.init(channelID: row.id, name: row.channel.name, number: row.number, favoriteIDs: favoriteIDs)
    }

    /// Channel numbers are identifiers, never grouped ("1001", not "1,001").
    public var numberText: String? { number.map { String($0) } }

    public var favoriteGlyph: String { isFavorite ? "heart.fill" : "heart" }

    public var favoriteActionTitle: String { isFavorite ? "Remove from Favorites" : "Add to Favorites" }

    public var favoriteAccessibilityLabel: String {
        isFavorite ? "Remove \(name) from favorites" : "Add \(name) to favorites"
    }

    public var playAccessibilityLabel: String { "Play \(name)" }

    /// Long-press actions in the order the menu lists them.
    public var contextActions: [Action] { [.play, .favorite] }

    /// The same toggle the iOS guide applies to `favoriteChannelIDs`.
    public static func togglingFavorite(_ channelID: String, in favoriteIDs: Set<String>) -> Set<String> {
        var values = favoriteIDs
        if values.contains(channelID) { values.remove(channelID) } else { values.insert(channelID) }
        return values
    }
}
