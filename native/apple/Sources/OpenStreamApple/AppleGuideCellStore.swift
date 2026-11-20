import Foundation

/// Programme cells for the rows that are actually on screen, built once each.
///
/// The Apple TV guide first built one grid model per row inside every row's
/// body, then — fixing that — built the model for *every* channel once a
/// minute. On the owner's lineup that is **9376 channels**, roughly 200,000
/// cells, to draw the fifteen rows a television can show. This builds a
/// channel's cells the first time a row asks for them and keeps them until the
/// window, the minute or the guide data moves, so the work is proportional to
/// what is visible rather than to the size of the lineup.
///
/// Not `@Observable`: rows read it during `body`, and a cache fill must not
/// invalidate anything.
@MainActor
public final class AppleGuideCellStore {
    private var token = ""
    private var guide = AppleIPTVGuide(programmes: [])
    private var window = DateInterval(start: .distantPast, duration: 0)
    private var now = Date.distantPast
    private var slotMinutes = 30
    private var cells: [String: [AppleGuideGridCell]] = [:]

    /// The hour labels, which do not depend on any channel.
    public private(set) var headerSlots: [AppleGuideGridHeaderSlot] = []

    public init() {}

    /// Points the store at a window. Everything cached is dropped when `token`
    /// changes; the same token is a no-op, so this is safe to call from `body`.
    public func configure(
        token: String,
        guide: AppleIPTVGuide,
        window: DateInterval,
        now: Date,
        slotMinutes: Int
    ) {
        guard token != self.token else { return }
        self.token = token
        self.guide = guide
        self.window = window
        self.now = now
        self.slotMinutes = slotMinutes
        cells.removeAll(keepingCapacity: true)
        headerSlots = AppleGuideGridModel.build(channels: [], programmes: [:], window: window,
            slotWidthMinutes: slotMinutes, now: now).headerSlots
    }

    public func cells(for channelID: String) -> [AppleGuideGridCell] {
        if let cached = cells[channelID] { return cached }
        let built = AppleGuideGridModel.build(
            channels: [channelID],
            programmes: [channelID: guide.programmes(channelID: channelID, in: window)],
            window: window,
            slotWidthMinutes: slotMinutes,
            now: now
        ).rows.first?.cells ?? []
        cells[channelID] = built
        return built
    }

    /// How many channels have been built. Test hook, and a cheap way to assert
    /// that the store stays proportional to what is on screen.
    public var builtChannelCount: Int { cells.count }
}
