#if os(tvOS)
import AVKit
import SwiftUI
import UIKit

/// Focus targets in the Apple TV Live tab. One enum so the guide can hand
/// focus back to the last played channel when the player closes.
enum AppleTVGuideFocus: Hashable {
    case watch
    case category(String)
    case search
    case channel(String)
    case favorite(String)
    case cell(AppleTVGuideCellFocus)
}

/// The focused programme cell, carried in the focus value so the info panel
/// above the grid can describe it without looking the cell up again.
struct AppleTVGuideCellFocus: Hashable {
    let cellID: String
    let channelID: String
    let title: String
    let summary: String?
    let start: Date
    let end: Date
    let airStart: Date
    let airEnd: Date

    init(cell: AppleGuideGridCell) {
        cellID = cell.id
        channelID = cell.channelID
        title = cell.title
        summary = cell.subtitle
        start = cell.start
        end = cell.end
        airStart = cell.airStart
        airEnd = cell.airEnd
    }
}

/// Focus targets inside the full-screen live player: the invisible surface
/// that holds focus while the video plays, or one card of the channel footer.
enum AppleTVLivePlayerFocus: Hashable {
    case lastChannel
    case surface
    case card(String)
    /// "Watch on <other list>" over a channel that could not be recovered.
    case otherList
    /// "Watch Live" over a programme played from the archive.
    case watchLive
}

/// The guide's shared horizontal scroll offset. Held in a reference type so
/// only the views that actually draw at this offset — the hour labels, the
/// now-line and the rows themselves — re-render while a row scrolls. As plain
/// `@State` on the screen it invalidated the whole body, and with it the info
/// panel, the chips and the header model, on every scroll tick.
@MainActor
@Observable
final class AppleTVGuideTimeline {
    /// Tracked: the hour labels, the now-line and the rows follow this.
    private(set) var x: CGFloat = 0
    /// The same number, readable from a child view's `init` — which runs
    /// inside the *parent's* observation scope, so reading `x` there would
    /// make the whole screen follow the scroll again.
    @ObservationIgnored private(set) var untracked: CGFloat = 0

    func update(_ value: CGFloat) {
        untracked = value
        x = value
    }
}

/// Which channel rows are on screen, for the guide's background refresh. The
/// set itself is untracked and only a counter is observed, so a rail cell
/// appearing during a vertical scroll repaints the zero-size reporter below
/// instead of the whole screen.
@MainActor
@Observable
final class AppleTVGuideVisibility {
    @ObservationIgnored private var ids = Set<String>()
    private(set) var revision = 0

    var snapshot: Set<String> { ids }

    func insert(_ id: String) {
        if ids.insert(id).inserted { revision &+= 1 }
    }

    func remove(_ id: String) {
        if ids.remove(id) != nil { revision &+= 1 }
    }
}

/// Identity for the full-screen live player cover. The playing channel lives
/// in separate state so switching channels from the content footer updates the
/// player in place instead of dismissing and re-presenting the cover.
struct AppleTVLivePlayerPresentation: Identifiable {
    let id = UUID()
}

// MARK: - Guide screen (tab root)

/// The Live tab root on Apple TV: an info panel for whatever has focus, the
/// category pills with the search glyph, the hour labels, then the guide grid.
/// Rows scroll vertically as one list; every row's timeline is a horizontal
/// scroll view kept at one shared offset so the rail stays pinned and the
/// focus engine only ever has to reveal the cell it lands on.
@MainActor
struct AppleTVLiveGuideScreen<Search: View>: View {
    let metrics: AppleTVGuideMetrics
    let channels: [AppleIPTVChannel]
    let channelIndex: AppleIPTVChannelIndex
    let categories: [String]
    /// Channels the 300 cap kept off the guide; drawn as one line under the
    /// category row when non-zero. `var` with a default so the memberwise
    /// initialiser keeps every existing call site compiling.
    var hiddenCount: Int = 0
    @Binding var selectedCategory: String
    let guide: AppleIPTVGuide
    /// `AppleIPTVGuideStore.revision`: the grid model is rebuilt when this
    /// moves, never because a view body happened to run again.
    let guideRevision: Int
    let entries: [AppleChannelLineupEntry]
    let favoriteIDs: Set<String>
    let favoriteOrder: [String]
    let nowPlaying: AppleIPTVChannel?
    let hasActiveSearch: Bool
    /// Previews follow the trailer-autoplay preference rather than adding a
    /// setting of their own, and never run behind the full-screen player.
    let previewsEnabled: Bool
    let isPlayerOpen: Bool
    let focusRestoreToken: Int
    let focusRestoreChannelID: String
    let searchDestination: () -> Search
    let onSelect: (AppleIPTVChannel) -> Void
    /// A programme that already aired on a channel with catch-up; the live
    /// channel is `onSelect`.
    let onSelectProgramme: (AppleIPTVChannel, AppleIPTVProgramme) -> Void
    let onToggleFavorite: (String) -> Void
    let onVisibleChannels: (Set<String>) async -> Void
    /// Last health result per channel id, built by the Live tab once per
    /// lineup or history change; `healthRevision` moves with it so the
    /// equatable grid redraws only then.
    let health: [String: AppleChannelHealthResult]
    let healthRevision: Int
    let onShowHealth: (AppleIPTVChannel) -> Void
    /// nil hides "Watch in Multiview" (while Picture in Picture is up).
    let onMultiview: ((AppleIPTVChannel) -> Void)?

    @FocusState private var focus: AppleTVGuideFocus?
    /// Days the guide may scroll back into, from the lineup's catch-up
    /// channels (`AppleIPTVCatchUp.maximumGuideDays` at most); nil without
    /// any archive. Found once per projection, never in the body.
    @State private var lookbackDays: Int?
    /// Window start the timeline was last placed in, so the shared scroll
    /// keeps the same clock time when the window's past edge moves.
    @State private var placedWindowStart: Date?
    @State private var rows: [AppleGuideChannel] = []
    @State private var visibility = AppleTVGuideVisibility()
    @State private var timeline = AppleTVGuideTimeline()
    @State private var gridIndex = AppleGuideGridIndex.empty
    @State private var gridNextBoundary = Date.distantPast
    @State private var gridBuildRevision = 0
    @State private var preview = AppleTVChannelPreview()
    /// A cheap stand-in for `rows` so `AppleTVGuideGrid` can decide whether
    /// to redraw without comparing the array.
    @State private var rowsRevision = 0

    init(
        metrics: AppleTVGuideMetrics = .standard,
        channels: [AppleIPTVChannel],
        channelIndex: AppleIPTVChannelIndex,
        categories: [String],
        hiddenCount: Int = 0,
        selectedCategory: Binding<String>,
        guide: AppleIPTVGuide,
        guideRevision: Int = 0,
        entries: [AppleChannelLineupEntry],
        favoriteIDs: Set<String>,
        favoriteOrder: [String] = [],
        nowPlaying: AppleIPTVChannel?,
        hasActiveSearch: Bool = false,
        previewsEnabled: Bool = true,
        isPlayerOpen: Bool = false,
        focusRestoreToken: Int,
        focusRestoreChannelID: String,
        @ViewBuilder searchDestination: @escaping () -> Search,
        onSelect: @escaping (AppleIPTVChannel) -> Void,
        onToggleFavorite: @escaping (String) -> Void,
        onVisibleChannels: @escaping (Set<String>) async -> Void,
        health: [String: AppleChannelHealthResult] = [:],
        healthRevision: Int = 0,
        onShowHealth: @escaping (AppleIPTVChannel) -> Void = { _ in },
        onMultiview: ((AppleIPTVChannel) -> Void)? = { _ in },
        onSelectProgramme: @escaping (AppleIPTVChannel, AppleIPTVProgramme) -> Void = { _, _ in }
    ) {
        self.metrics = metrics
        self.channels = channels
        self.channelIndex = channelIndex
        self.categories = categories
        self.hiddenCount = hiddenCount
        _selectedCategory = selectedCategory
        self.guide = guide
        self.guideRevision = guideRevision
        self.entries = entries
        self.favoriteIDs = favoriteIDs
        self.favoriteOrder = favoriteOrder
        self.nowPlaying = nowPlaying
        self.hasActiveSearch = hasActiveSearch
        self.previewsEnabled = previewsEnabled
        self.isPlayerOpen = isPlayerOpen
        self.focusRestoreToken = focusRestoreToken
        self.focusRestoreChannelID = focusRestoreChannelID
        self.searchDestination = searchDestination
        self.onSelect = onSelect
        self.onToggleFavorite = onToggleFavorite
        self.onVisibleChannels = onVisibleChannels
        self.health = health
        self.healthRevision = healthRevision
        self.onShowHealth = onShowHealth
        self.onMultiview = onMultiview
        self.onSelectProgramme = onSelectProgramme
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            #if DEBUG
            let now = AppleTVGuideLatencyProbe.shared.fixtureDate ?? context.date
            #else
            let now = context.date
            #endif
            let window = metrics.window(now: now, earliest: lookbackDays.map { now.addingTimeInterval(-Double($0) * 86_400) })
            VStack(alignment: .leading, spacing: metrics.sectionSpacing) {
                nowPlayingStrip(now: now)
                categoryRow
                guideHeader(window: window, now: now, slots: gridIndex.headerSlots)
                grid(window: window, now: now)
            }
            .task(id: gridIdentity(window: window, now: now)) {
                placeTimeline(window: window, now: now)
                let inputChannels = rows.map(\.id)
                let currentWindow = window
                let currentNow = now
                let currentGuide = guide
                let slotMin = metrics.slotMinutes
                let index = await Task.detached(priority: .utility) {
                    AppleGuideGridModel.index(channels: inputChannels, guide: currentGuide, window: currentWindow, slotWidthMinutes: slotMin, now: currentNow)
                }.value
                
                guard !Task.isCancelled else { return }
                
                var next = Date.distantFuture
                for cells in index.cellsByChannel.values {
                    for cell in cells {
                        if cell.start > currentNow, cell.start < next { next = cell.start }
                        if cell.end > currentNow, cell.end < next { next = cell.end }
                    }
                }
                
                gridIndex = index
                gridNextBoundary = next == .distantFuture ? currentNow.addingTimeInterval(3600) : next
                gridBuildRevision &+= 1
                #if DEBUG
                appleTrace("guide tick: rebuilt \(index.cellsByChannel.values.lazy.flatMap({ $0 }).count) cells")
                #endif
            }
            .onChange(of: Int(now.timeIntervalSince1970 / 60)) { oldMinute, newMinute in
                if now < gridNextBoundary {
                    #if DEBUG
                    appleTrace("guide tick: no boundary, skipped")
                    #endif
                }
            }
            .padding(.horizontal, metrics.horizontalSafeInset)
            .padding(.top, 12)
            .padding(.bottom, metrics.verticalSafeInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            // Inside the timeline closure so the minute tick re-keys it. The
            // grid model is built here, once, instead of once per row per
            // render — the Live tab's main cost (owner 18:55, "slow").
        }
        .background(Color.black.ignoresSafeArea())
        .ignoresSafeArea(.container, edges: [.horizontal, .bottom])
        .onChange(of: focusRestoreToken) { _, _ in
            let id = rows.first(where: { $0.id == focusRestoreChannelID })?.id ?? rows.first?.id ?? ""
            guard !id.isEmpty else { return }
            Task { @MainActor in
                // Let the cover finish dismissing before the rail takes focus.
                try? await Task.sleep(for: .milliseconds(200))
                focus = .channel(id)
            }
        }
        .task(id: projectionInput) {
            let input = projectionInput
            let projected = await Task.detached(priority: .userInitiated) {
                AppleGuideChannelProjection.rows(channels: input.channels, entries: input.entries,
                    favoriteIDs: input.favoriteIDs, favoritesOnly: false, sortByNumber: true, favoriteOrder: input.favoriteOrder)
            }.value
            guard !Task.isCancelled else { return }
            rows = projected
            rowsRevision &+= 1
            lookbackDays = projected.lazy
                .filter { AppleIPTVCatchUp.supportsCatchUp($0.channel) }
                .compactMap { $0.channel.catchUpDays }
                .map { min($0, AppleIPTVCatchUp.maximumGuideDays) }
                .max()
            #if DEBUG
            if !projected.isEmpty { AppleLaunchClock.mark("live.rows") }
            AppleTVGuideLatencyProbe.shared.rowsReady(count: projected.count)
            #endif
        }
        // The guide opens on the first channel, like the TV app's guide, and
        // the strip describes what it is showing. `userInitiated` re-evaluates
        // the default when the rows arrive, which a plain assignment from the
        // projection task could not do (the rail cells were not built yet).
        .defaultFocus($focus, initialFocus, priority: .userInitiated)
        .onExitCommand(perform: menuToCategoryRow)
        .background {
            AppleTVGuideVisibilityReporter(visibility: visibility, nowPlayingID: nowPlaying?.id,
                report: onVisibleChannels)
        }
        .onChange(of: previewTargetID, initial: true) { _, id in
            preview.show(id.flatMap { channel(id: $0) })
        }
        .onChange(of: focus) { _, value in
            #if DEBUG
            AppleTVGuideLatencyProbe.shared.focusChanged()
            AppleInteractionTrace.record(.focus, "guide \(value.map(String.init(describing:)) ?? "none")")
            #endif
        }
        .onDisappear {
            preview.stop()
            #if DEBUG
            AppleInteractionTrace.record(.screen, "live guide gone")
            #endif
        }
        .onAppear {
            #if DEBUG
            AppleInteractionTrace.record(.screen, "live guide, \(rows.count) channels")
            #endif
        }
    }

    /// The channel whose picture the info panel should show, if any.
    private var previewTargetID: String? {
        var focusedChannel: String?
        var focusedCell: String?
        switch focus {
        case .channel(let id), .favorite(let id): focusedChannel = id
        case .cell(let cell): focusedCell = cell.channelID
        case .watch, .category, .search, nil: break
        }
        return AppleTVGuidePreviewPolicy.target(
            focusedChannelID: focusedChannel,
            focusedCellChannelID: focusedCell,
            isEnabled: previewsEnabled,
            isPlayerOpen: isPlayerOpen
        )
    }

    /// Menu from anywhere in the grid lands on the current category chip, so
    /// Favorites and the search glyph are one press away from any row (owner
    /// 2026-09-21: "back goes to the main top nav bar"). From the chip row
    /// there is no handler, and the system takes Menu on to the tab bar.
    private var menuToCategoryRow: (() -> Void)? {
        switch focus {
        case .channel, .favorite, .cell:
            guard let chip = categories.contains(selectedCategory) ? selectedCategory : categories.first else { return nil }
            return { focus = .category(chip) }
        case .watch, .category, .search, nil:
            return nil
        }
    }

    /// Left from the channel rail goes to the categories (TiviMate's group
    /// list sits there). The chip row is above the grid, so the focus engine
    /// alone finds nothing to the left and the press would be lost.
    private func focusCategories(from origin: String) {
        guard let chip = categories.contains(selectedCategory) ? selectedCategory : categories.first else { return }
        #if DEBUG
        AppleInteractionTrace.record(.press, "guide left from \(origin) → category \(chip)")
        #endif
        focus = .category(chip)
    }

    /// First channel once the rows exist; the current category chip until then.
    private var initialFocus: AppleTVGuideFocus {
        if let first = rows.first { return .channel(first.id) }
        return .category(selectedCategory)
    }

    private struct GridUpdateIdentity: Equatable {
        let rowsRevision: Int
        let guideRevision: Int
        let windowStart: Date
        let windowEnd: Date
        let forceMinute: Int
    }

    private func gridIdentity(window: DateInterval, now: Date) -> GridUpdateIdentity {
        GridUpdateIdentity(
            rowsRevision: rowsRevision,
            guideRevision: guideRevision,
            windowStart: window.start,
            windowEnd: window.end,
            forceMinute: now >= gridNextBoundary ? Int(now.timeIntervalSince1970 / 60) : 0
        )
    }

    private var projectionInput: AppleTVGuideProjectionInput {
        AppleTVGuideProjectionInput(channels: channels, entries: entries, favoriteIDs: favoriteIDs, favoriteOrder: favoriteOrder)
    }

    /// The guide opens on the current slot, however far back the window
    /// reaches; when the window's past edge moves (a new slot every half
    /// hour, or the archive channels arriving) the rows keep showing the
    /// same clock time.
    private func placeTimeline(window: DateInterval, now: Date) {
        defer { placedWindowStart = window.start }
        let x: CGFloat
        if let previous = placedWindowStart {
            guard previous != window.start else { return }
            x = timeline.untracked + CGFloat(previous.timeIntervalSince(window.start) / metrics.slotDuration) * metrics.slotWidth
        } else {
            x = metrics.xOffset(of: metrics.slotStart(of: now), in: window)
        }
        let placed = max(0, min(x, metrics.timelineContentWidth(for: window) - metrics.timelineWidth))
        guard abs(placed - timeline.untracked) > 0.5 else { return }
        timeline.update(placed)
        #if DEBUG
        appleTrace("guide window from \(window.start.formatted(date: .numeric, time: .shortened)): timeline x=\(Int(placed))")
        #endif
    }

    // MARK: Strip

    /// The info panel for whatever has focus: the focused programme cell, the
    /// current programme of the focused channel, or the playing channel when
    /// focus is elsewhere. Logo, then title over the channel, time span and
    /// description; the Watch pill plays the channel being described.
    @ViewBuilder
    private func nowPlayingStrip(now: Date) -> some View {
        if let info = stripInfo(now: now) {
            HStack(spacing: 24) {
                ZStack {
                    AppleTVGuideLogoTile(
                        logoURL: info.channel.logoURL,
                        fallbackText: AppleTVGuideLogoTile.fallbackText(name: info.channel.name, number: nil),
                        size: metrics.stripLogoSize,
                        cornerRadius: metrics.cornerRadius,
                        fontSize: metrics.titleFontSize
                    )
                    // The picture replaces the logo once the channel has held
                    // focus long enough to have started (owner: "there is no
                    // preview of the channel"). The logo stays underneath, so
                    // a channel that never starts simply keeps showing it.
                    if preview.channelID == info.channel.id, let engine = preview.engine {
                        // Either route: AVPlayer draws through its own layer,
                        // the libavcodec route through its sample-buffer
                        // surface. Most of the owner's lineup is MPEG-TS and
                        // takes the second one.
                        AppleTVChannelPreviewSurface(
                            engine: engine,
                            player: preview.player,
                            cornerRadius: metrics.cornerRadius
                        )
                        .frame(width: metrics.stripLogoSize.width, height: metrics.stripLogoSize.height)
                        .id(preview.revision)
                        .transition(.opacity)
                        .accessibilityHidden(true)
                    }
                }
                .animation(.easeOut(duration: 0.2), value: preview.channelID)
                VStack(alignment: .leading, spacing: 2) {
                    Text(info.title)
                        .font(.system(size: metrics.titleFontSize, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if let detail = info.detail {
                        Text(detail)
                            .font(.system(size: metrics.subtitleFontSize))
                            .foregroundStyle(AppleDesignTokens.textSecondary)
                            .lineLimit(1)
                    }
                    if let summary = info.summary {
                        Text(summary)
                            .font(.system(size: metrics.subtitleFontSize))
                            .foregroundStyle(AppleDesignTokens.textSecondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: metrics.stripTextMaxWidth, alignment: .leading)
                Spacer(minLength: 0)
            }
            // Read-only panel (owner 18:50: the Watch pill "looks weird");
            // Select on a channel or a cell plays it.
            .frame(height: metrics.stripHeight, alignment: .top)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("live.tv.info")
        }
    }

    /// The focused cell wins; a focused rail cell or anything else falls back
    /// to that channel's current programme, then to the playing channel.
    private func stripInfo(now: Date) -> AppleTVGuideStripInfo? {
        #if DEBUG
        let infoStart = CACurrentMediaTime()
        defer { AppleTVGuideLatencyProbe.shared.infoResolved(since: infoStart) }
        #endif
        if let focus {
            switch focus {
            case .cell(let cell):
                if let channel = channel(id: cell.channelID) {
                    return AppleTVGuideStripInfo(
                        channel: channel,
                        title: cell.title,
                        detail: "\(channel.name) · \(AppleTVGuideTimeSpan.text(from: cell.airStart, to: cell.airEnd))",
                        summary: cell.summary
                    )
                }
            case .channel(let id), .favorite(let id):
                if let channel = channel(id: id) { return currentInfo(channel: channel, now: now) }
            case .watch, .category, .search:
                break
            }
        }
        // With nothing playing yet the first channel stands in, so the panel
        // never collapses while focus is on the chips.
        guard let channel = nowPlaying ?? rows.first?.channel else { return nil }
        return currentInfo(channel: channel, now: now)
    }

    private func currentInfo(channel: AppleIPTVChannel, now: Date) -> AppleTVGuideStripInfo {
        guard let programme = guide.nowAndNext(channelID: channel.id, at: now).now else {
            return AppleTVGuideStripInfo(channel: channel, title: channel.name, detail: nil, summary: nil)
        }
        return AppleTVGuideStripInfo(
            channel: channel,
            title: programme.title,
            detail: "\(channel.name) · \(AppleTVGuideTimeSpan.text(from: programme.start, to: programme.end))",
            summary: programme.description ?? programme.subtitle
        )
    }

    private func channel(id: String) -> AppleIPTVChannel? {
        channelIndex[id]
    }

    // MARK: Categories

    /// The category pills with the search glyph at the trailing end of the
    /// row; it pushes the existing channel search and stays filled while a
    /// search is active.
    private var categoryRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            categoryChipsAndSearch
            // One line, only when the cap kept channels off the guide (owner,
            // 2026-09-17: "note to the user… they reached the limit"). Same
            // line the phone shows; the count is the whole message.
            if hiddenCount > 0 {
                Text("Showing \(channels.count) of \(channels.count + hiddenCount) channels")
                    .font(.system(size: metrics.categoryFontSize * 0.8))
                    .foregroundStyle(AppleDesignTokens.textSecondary)
                    .accessibilityIdentifier("live.cap.notice")
            }
        }
    }

    private var categoryChipsAndSearch: some View {
        // 24 pt of spacing leaves 12 pt beside the glyph once the pill row's
        // negative padding has widened its clip.
        HStack(spacing: 24) {
            ScrollView(.horizontal) {
                HStack(spacing: 16) {
                    ForEach(categories, id: \.self) { category in
                        Button(category) { selectedCategory = category }
                            .buttonStyle(AppleTVChipStyle(
                                isSelected: selectedCategory == category,
                                height: metrics.categoryPillHeight,
                                fontSize: metrics.categoryFontSize
                            ))
                            .focused($focus, equals: .category(category))
                            .accessibilityAddTraits(selectedCategory == category ? .isSelected : [])
                            .accessibilityIdentifier("live.category.\(category)")
                    }
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 12)
            }
            .scrollIndicators(.hidden)
            // tvOS scroll views do not clip on their own. Widen the clip by the
            // inner padding so the focus ring survives while the first pill still
            // starts at the 80 pt inset.
            .padding(.horizontal, -12)
            .clipped()

            NavigationLink {
                searchDestination()
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: metrics.pillFontSize, weight: .medium))
            }
            .buttonStyle(AppleTVGlyphStyle(isSelected: hasActiveSearch))
            .focused($focus, equals: .search)
            .accessibilityLabel(hasActiveSearch ? "Search Channels, filter active" : "Search Channels")
            .accessibilityIdentifier("live.search")
        }
        .focusSection()
    }

    // MARK: Header row

    /// Hour labels only. The rail column is an empty spacer so the labels stay
    /// aligned with the programme cells underneath them.
    private func guideHeader(window: DateInterval, now: Date, slots: [AppleGuideGridHeaderSlot]) -> some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: metrics.railWidth, height: metrics.headerHeight)
                .accessibilityHidden(true)

            AppleTVGuideHeaderLabels(slots: slots, metrics: metrics, timeline: timeline)
        }
    }

    // MARK: Grid

    private func grid(window: DateInterval, now: Date) -> some View {
        AppleTVGuideGrid(
            rows: rows,
            rowsRevision: rowsRevision,
            gridIndex: gridIndex,
            gridBuildRevision: gridBuildRevision,
            favoriteIDs: favoriteIDs,
            metrics: metrics,
            window: window,
            now: now,
            timeline: timeline,
            visibility: visibility,
            focus: $focus,
            onSelect: onSelect,
            onSelectProgramme: onSelectProgramme,
            onToggleFavorite: onToggleFavorite,
            health: health,
            healthRevision: healthRevision,
            onShowHealth: onShowHealth,
            onMultiview: onMultiview,
            offersMultiview: onMultiview != nil,
            onRailMoveLeft: { focusCategories(from: "rail") }
        )
        .equatable()
    }
}

/// The channel rail and the timeline beside it.
///
/// Its own `EquatableView`, and that is the point: `@FocusState` lives on the
/// screen, so moving focus one channel re-runs the screen's body — and with the
/// grid inline that rebuilt every visible rail cell and every programme button,
/// context menus and all, on each press. Holding a direction on the remote then
/// queued those rebuilds and the guide stopped answering (owner 2026-09-14,
/// "freezes when trying to flip through channels"). The focus binding is not a
/// dynamic property here, so this view redraws only when the data it draws
/// actually changes; the revisions stand in for the two collections so the
/// comparison stays O(1) on a thousand-channel lineup.
private struct AppleTVGuideGrid: View, Equatable {
    let rows: [AppleGuideChannel]
    let rowsRevision: Int
    let gridIndex: AppleGuideGridIndex
    let gridBuildRevision: Int
    let favoriteIDs: Set<String>
    let metrics: AppleTVGuideMetrics
    let window: DateInterval
    let now: Date
    let timeline: AppleTVGuideTimeline
    let visibility: AppleTVGuideVisibility
    let focus: FocusState<AppleTVGuideFocus?>.Binding
    let onSelect: (AppleIPTVChannel) -> Void
    let onSelectProgramme: (AppleIPTVChannel, AppleIPTVProgramme) -> Void
    let onToggleFavorite: (String) -> Void
    let health: [String: AppleChannelHealthResult]
    let healthRevision: Int
    let onShowHealth: (AppleIPTVChannel) -> Void
    let onMultiview: ((AppleIPTVChannel) -> Void)?
    /// `onMultiview != nil`, for the comparison.
    let offersMultiview: Bool
    let onRailMoveLeft: () -> Void

    // `View` infers `@MainActor` for the whole type; the comparison reads only
    // Sendable value properties, so it stays outside that isolation.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.rowsRevision == rhs.rowsRevision
            && lhs.gridBuildRevision == rhs.gridBuildRevision
            && lhs.window == rhs.window
            && lhs.now == rhs.now
            && lhs.favoriteIDs == rhs.favoriteIDs
            && lhs.metrics == rhs.metrics
            && lhs.healthRevision == rhs.healthRevision
            && lhs.offersMultiview == rhs.offersMultiview
    }

    /// Right from the rail lands on the programme on now (else the next one),
    /// which is where the row is scrolled to; the engine's own choice is the
    /// row's first cell, days back in the archive.
    private func focusEntryCell(of channelID: String) {
        let cells = gridIndex.cells(for: channelID)
        guard let entry = cells.first(where: { $0.start <= now && $0.end > now }) ?? cells.first(where: { $0.end > now }) else { return }
        focus.wrappedValue = .cell(AppleTVGuideCellFocus(cell: entry))
    }

    var body: some View {
        if rows.isEmpty {
            Text("No Channels")
                .font(.system(size: 48, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        HStack(alignment: .top, spacing: 0) {
                            AppleTVGuideRailCell(
                                row: row,
                                model: AppleTVGuideRailCellModel(row: row, favoriteIDs: favoriteIDs),
                                health: AppleChannelHealthIndicator(result: health[row.id]),
                                metrics: metrics,
                                focus: focus,
                                onSelect: { onSelect(row.channel) },
                                onToggleFavorite: { onToggleFavorite(row.id) },
                                onShowHealth: { onShowHealth(row.channel) },
                                onMultiview: onMultiview.map { action in { action(row.channel) } },
                                onMoveLeft: onRailMoveLeft,
                                onMoveRight: { focusEntryCell(of: row.id) }
                            )
                            .frame(width: metrics.railWidth, height: metrics.rowHeight, alignment: .topLeading)
                            .onAppear { visibility.insert(row.id) }
                            .onDisappear { visibility.remove(row.id) }
                            .focusSection()

                            AppleTVGuideScheduleRow(
                                channel: row.channel,
                                cells: gridIndex.cells(for: row.id),
                                window: window,
                                now: now,
                                metrics: metrics,
                                isFavorite: favoriteIDs.contains(row.id),
                                timeline: timeline,
                                focus: focus,
                                onSelect: { onSelect(row.channel) },
                                onSelectCell: { onSelectProgramme(row.channel, $0.programme) },
                                onToggleFavorite: { onToggleFavorite(row.id) },
                                onShowHealth: { onShowHealth(row.channel) },
                                onMultiview: onMultiview.map { action in { action(row.channel) } }
                            )
                            .frame(width: metrics.timelineWidth)
                            .focusSection()
                        }
                    }
                }
                .overlay(alignment: .topLeading) {
                    AppleTVGuideNowLine(metrics: metrics, window: window, now: now, timeline: timeline)
                        .offset(x: metrics.railWidth)
                }
            }
            .scrollIndicators(.hidden)
            .clipped()
        }
    }
}

private struct AppleTVGuideProjectionInput: Equatable, Sendable {
    let channels: [AppleIPTVChannel]
    let entries: [AppleChannelLineupEntry]
    let favoriteIDs: Set<String>
    var favoriteOrder: [String] = []
}

private struct AppleTVGuideGridIdentity: Equatable {
    let rowsRevision: Int
    let guideRevision: Int
    let windowStart: Date
    let windowEnd: Date
    let minute: Int
}

/// Reports the on-screen channels to the guide store. A zero-size view so the
/// debounce and the report hang off something that is cheap to re-render.
private struct AppleTVGuideVisibilityReporter: View {
    let visibility: AppleTVGuideVisibility
    let nowPlayingID: String?
    let report: (Set<String>) async -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .task(id: reportIdentity) {
                // Long enough that a fast scroll through the rail reports once
                // at the end instead of at every row.
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                var ids = visibility.snapshot
                if let nowPlayingID { ids.insert(nowPlayingID) }
                await report(ids)
            }
    }

    private var reportIdentity: String { "\(visibility.revision)|\(nowPlayingID ?? "")" }
}

/// The hour labels, riding the shared scroll offset. Their own view so a
/// horizontal scroll repaints this strip and not the info panel above it.
private struct AppleTVGuideHeaderLabels: View {
    let slots: [AppleGuideGridHeaderSlot]
    let metrics: AppleTVGuideMetrics
    let timeline: AppleTVGuideTimeline

    var body: some View {
        HStack(spacing: 0) {
            ForEach(slots) { slot in
                Text(slot.time, format: .dateTime.hour().minute())
                    .font(.system(size: metrics.headerFontSize, weight: .medium))
                    .foregroundStyle(AppleDesignTokens.textSecondary)
                    .frame(width: metrics.slotWidth, alignment: .leading)
            }
        }
        .offset(x: -timeline.x)
        .frame(width: metrics.timelineWidth, height: metrics.headerHeight, alignment: .leading)
        .clipped()
    }
}

/// The brand now-line over the grid; off screen once the viewer scrolls past
/// the current half hour.
private struct AppleTVGuideNowLine: View {
    let metrics: AppleTVGuideMetrics
    let window: DateInterval
    let now: Date
    let timeline: AppleTVGuideTimeline

    var body: some View {
        if let x = metrics.nowLineX(now: now, window: window, scrolledX: timeline.x) {
            Rectangle()
                .fill(AppleDesignTokens.brandAccent)
                .frame(width: metrics.nowLineWidth)
                .offset(x: x)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Rows and cells

/// One rail cell: a single play target holding the logo tile, the number and
/// the channel name. Press and hold adds or removes the favorite, so the row
/// keeps one focus stop and the grid beside it never shifts.
private struct AppleTVGuideRailCell: View {
    let row: AppleGuideChannel
    let model: AppleTVGuideRailCellModel
    /// Nil for a working or never-checked channel: silence means healthy.
    let health: AppleChannelHealthIndicator?
    let metrics: AppleTVGuideMetrics
    let focus: FocusState<AppleTVGuideFocus?>.Binding
    let onSelect: () -> Void
    let onToggleFavorite: () -> Void
    /// The health detail, from the long-press menu, so the row keeps one
    /// focus stop. Nil when the channel has never been checked.
    let onShowHealth: (() -> Void)?
    var onMultiview: (() -> Void)? = nil
    /// Left from the rail: nothing lies to its left, so the press goes to
    /// the categories instead of being swallowed.
    let onMoveLeft: () -> Void
    /// Right from the rail: with an archive the row begins days before the
    /// screen, and the focus engine would pick that first, hidden cell; the
    /// grid names the programme on now instead.
    var onMoveRight: (() -> Void)? = nil

    var body: some View {
        Button(action: onSelect) {
            // One compact line, TiviMate-style: logo, number, name.
            HStack(alignment: .center, spacing: 12) {
                AppleTVGuideLogoTile(
                    logoURL: row.channel.logoURL,
                    fallbackText: AppleTVGuideLogoTile.fallbackText(name: model.name, number: model.numberText),
                    size: metrics.logoSize,
                    cornerRadius: metrics.cornerRadius - 2,
                    fontSize: metrics.badgeFontSize - 6
                )
                if let number = model.numberText {
                    Text(number)
                        .font(.system(size: metrics.badgeFontSize, weight: .medium).monospacedDigit())
                        .foregroundStyle(AppleDesignTokens.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(width: metrics.railNumberWidth - 12, alignment: .trailing)
                }
                Text(model.name)
                    .font(.system(size: metrics.railNameFontSize, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if model.isFavorite {
                    // The only favourite marker on the rail.
                    Image(systemName: "heart.fill")
                        .font(.system(size: metrics.badgeFontSize - 6, weight: .semibold))
                        .foregroundStyle(AppleDesignTokens.brandAccent)
                        .accessibilityLabel("Favorite")
                }
                if let health {
                    AppleChannelHealthDot(indicator: health, size: metrics.healthDotSize)
                }
            }
            .padding(.horizontal, 10)
            .frame(width: metrics.railPlayWidth, height: metrics.cellHeight, alignment: .leading)
        }
        .buttonStyle(AppleTVGuideRailStyle(cornerRadius: metrics.cornerRadius))
        .focused(focus, equals: .channel(row.id))
        .onMoveCommand { direction in
            if direction == .left { onMoveLeft() }
            if direction == .right, let onMoveRight { onMoveRight() }
        }
        .contextMenu {
            AppleChannelQuickActions(channel: row.channel)
            if let onMultiview { Button("Watch in Multiview", action: onMultiview) }
            Button(model.favoriteActionTitle, systemImage: model.favoriteGlyph, action: onToggleFavorite)
            if let onShowHealth {
                Button("Channel Info", systemImage: "info.circle", action: onShowHealth)
            }
        }
        .accessibilityLabel(model.playAccessibilityLabel)
        .accessibilityValue(health?.accessibilityLabel ?? "")
        .accessibilityIdentifier("guide.play.\(row.id)")
        .frame(width: metrics.railWidth, height: metrics.cellHeight, alignment: .leading)
    }

}

/// A channel logo on a faint tile. White-on-transparent logos need a ground to
/// read against, and the tile shows the channel's first word until a logo
/// actually decodes — so a slow, broken or 1-pixel logo leaves a readable name
/// rather than the empty tiles CBS, FOX and ABC drew (L6b/L6c). The rail and
/// the info panel share it, so a network reads the same in both.
private struct AppleTVGuideLogoTile: View {
    let logoURL: URL?
    let fallbackText: String
    let size: CGSize
    let cornerRadius: CGFloat
    let fontSize: CGFloat
    @State private var loaded = false

    /// Below this a "logo" is a spacer or a tracking pixel, not a mark.
    private static let minimumPixelSize = 8

    static func fallbackText(name: String, number: String?) -> String {
        if let word = name.split(separator: " ").first { return String(word) }
        return number ?? ""
    }

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.white.opacity(0.08))
            .frame(width: size.width, height: size.height)
            .overlay {
                ZStack {
                    Text(fallbackText)
                        .font(.system(size: fontSize, weight: .semibold))
                        .foregroundStyle(AppleDesignTokens.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .padding(6)
                        .opacity(loaded ? 0 : 1)
                    if let logoURL {
                        // Kept in the hierarchy while hidden so a logo that is
                        // simply slow still arrives and replaces the name.
                        AppleRemoteImage(
                            url: logoURL,
                            contentMode: .fit,
                            placeholderSystemImage: "tv",
                            onLoad: { loaded = $0.width >= Self.minimumPixelSize && $0.height >= Self.minimumPixelSize },
                            onFailure: { loaded = false }
                        )
                        .padding(6)
                        .opacity(loaded ? 1 : 0)
                    }
                }
            }
            .onChange(of: logoURL) { _, _ in loaded = false }
    }
}

/// The long-press menu on a programme cell: play the channel or change the
/// favorite, like the other platforms.
private struct AppleTVChannelActions: View {
    let model: AppleTVGuideRailCellModel
    let onPlay: () -> Void
    let onToggleFavorite: () -> Void
    let onShowHealth: (() -> Void)?
    var onMultiview: (() -> Void)? = nil

    var body: some View {
        if let onMultiview { Button("Watch in Multiview", action: onMultiview) }
        ForEach(model.contextActions, id: \.self) { action in
            switch action {
            case .play:
                Button("Play", systemImage: "play.fill", action: onPlay)
            case .favorite:
                Button(model.favoriteActionTitle, systemImage: model.favoriteGlyph, action: onToggleFavorite)
            }
        }
        if let onShowHealth {
            Button("Channel Info", systemImage: "info.circle", action: onShowHealth)
        }
    }
}

/// One channel's programmes. Its horizontal scroll position is mirrored into
/// the shared `timelineX` so every row, the header and the now-line move as
/// one; a row that scrolls because focus landed on a partly hidden cell drags
/// the others along, and a freshly created row starts where the others are.
@MainActor
private struct AppleTVGuideScheduleRow: View {
    let channel: AppleIPTVChannel
    /// Already built by the screen; a row never runs the grid model itself.
    let cells: [AppleGuideGridCell]
    let window: DateInterval
    let now: Date
    let metrics: AppleTVGuideMetrics
    let isFavorite: Bool
    let timeline: AppleTVGuideTimeline
    let focus: FocusState<AppleTVGuideFocus?>.Binding
    let onSelect: () -> Void
    /// A past programme the channel's archive still holds.
    let onSelectCell: (AppleGuideGridCell) -> Void
    let onToggleFavorite: () -> Void
    let onShowHealth: (() -> Void)?
    var onMultiview: (() -> Void)? = nil
    @State private var position: ScrollPosition

    init(channel: AppleIPTVChannel, cells: [AppleGuideGridCell], window: DateInterval, now: Date,
         metrics: AppleTVGuideMetrics, isFavorite: Bool, timeline: AppleTVGuideTimeline,
         focus: FocusState<AppleTVGuideFocus?>.Binding,
         onSelect: @escaping () -> Void,
         onSelectCell: @escaping (AppleGuideGridCell) -> Void = { _ in },
         onToggleFavorite: @escaping () -> Void,
         onShowHealth: (() -> Void)? = nil,
         onMultiview: (() -> Void)? = nil) {
        self.channel = channel
        self.onSelectCell = onSelectCell
        self.cells = cells
        self.window = window
        self.now = now
        self.metrics = metrics
        self.isFavorite = isFavorite
        self.timeline = timeline
        self.focus = focus
        self.onSelect = onSelect
        self.onToggleFavorite = onToggleFavorite
        self.onShowHealth = onShowHealth
        self.onMultiview = onMultiview
        // `untracked`, never `x`: this init runs inside the screen's body, and
        // reading the tracked value here would put the whole screen back on
        // the scroll's invalidation path.
        _position = State(initialValue: ScrollPosition(point: CGPoint(x: timeline.untracked, y: 0)))
    }

    private var ownsTimeline: Bool {
        guard case .cell(let cell) = focus.wrappedValue else { return false }
        return cell.channelID == channel.id
    }

    var body: some View {
        let actions = AppleTVGuideRailCellModel(channelID: channel.id, name: channel.name, number: nil, isFavorite: isFavorite)
        ScrollView(.horizontal) {
            // Not lazy: a lazy stack ignored the shared scroll offset until
            // its cells existed, so rows with a days-long archive opened on
            // the gap at the far left while the header sat on the present.
            HStack(spacing: 0) {
                ForEach(cells) { cell in
                    let width = metrics.cellWidth(columnSpan: cell.columnSpan)
                    let isGap = metrics.isGapCell(id: cell.id)
                    let catchUp = !isGap && AppleIPTVCatchUp.isAvailable(start: cell.airStart, end: cell.airEnd, on: channel, now: now)
                    Button(action: catchUp ? { onSelectCell(cell) } : onSelect) {
                        AppleTVGuideCellLabel(cell: cell, width: width, metrics: metrics,
                            progress: isGap ? nil
                                : metrics.progress(start: cell.airStart, end: cell.airEnd, now: now),
                            isCatchUp: catchUp)
                    }
                    .buttonStyle(AppleTVGuideCellStyle(
                        isCurrent: cell.start <= now && cell.end > now,
                        isGap: isGap,
                        isPast: cell.end <= now && !catchUp,
                        cornerRadius: metrics.cornerRadius
                    ))
                    .focused(focus, equals: .cell(AppleTVGuideCellFocus(cell: cell)))
                    .contextMenu {
                        if !isGap, AppleIPTVCatchUp.canStartOver(cell.programme, on: channel, now: now) {
                            Button("Start Over") { onSelectCell(cell) }
                                .accessibilityIdentifier("guide.startOver")
                        }
                        if !isGap {
                            AppleProgrammeReminderAction(channel: channel, title: cell.title, start: cell.airStart, end: cell.airEnd)
                        }
                        AppleChannelQuickActions(channel: channel)
                        AppleTVChannelActions(model: actions, onPlay: onSelect, onToggleFavorite: onToggleFavorite,
                            onShowHealth: onShowHealth, onMultiview: onMultiview)
                    }
                    .frame(width: width, height: metrics.cellHeight)
                    .padding(.trailing, metrics.cellGap)
                    .accessibilityLabel("\(channel.name), \(cell.title)" + (catchUp ? ", available to watch" : ""))
                }
            }
            .frame(width: metrics.timelineContentWidth(for: window), alignment: .leading)
            .frame(height: metrics.rowHeight, alignment: .top)
        }
        .scrollPosition($position)
        .scrollIndicators(.hidden)
        .onScrollGeometryChange(for: CGFloat.self) { max(0, $0.contentOffset.x) } action: { _, x in
            // Only the focused row drives the shared position. Followers
            // report intermediate offsets while catching up; feeding those
            // back can undo the focus engine’s reveal and hide its target.
            guard ownsTimeline else { return }
            if abs(x - timeline.untracked) > 0.5 { timeline.update(x) }
        }
        .onChange(of: timeline.x) { _, x in
            // Let the focus engine finish revealing its own target.
            if !ownsTimeline { position.scrollTo(x: x) }
        }
        .onAppear { position.scrollTo(x: timeline.untracked) }
        .frame(height: metrics.rowHeight)
        .focusSection()
    }
}

/// The title, nothing else: the description belongs to the info panel above
/// the grid, so a row of cells stays one line of text like the system guide.
private struct AppleTVGuideCellLabel: View {
    let cell: AppleGuideGridCell
    let width: CGFloat
    let metrics: AppleTVGuideMetrics
    /// How far the programme on now has run; nil for every other cell.
    var progress: Double? = nil
    /// Already aired and still in the channel's archive: a small replay
    /// glyph before the title, in the cell's own text colour.
    var isCatchUp = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if metrics.showsText(cellWidth: width) {
                HStack(spacing: 8) {
                    if isCatchUp {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: metrics.cellFontSize * 0.75, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    Text(cell.title)
                        .font(.system(size: metrics.cellFontSize, weight: .medium))
                        .lineLimit(1)
                }
                // A programme that began left of the visible timeline keeps
                // its title on screen, pinned at the left edge (the cell's
                // own start is scrolled off). A visual effect, not state: it
                // follows the scroll without re-running any body.
                .visualEffect { [metrics, width] content, proxy in
                    content.offset(x: metrics.pinnedTitleOffset(
                        titleMinX: proxy.frame(in: .scrollView(axis: .horizontal)).minX,
                        cellWidth: width))
                }
            }
            if let progress {
                // Elapsed time on the programme on now. Hierarchical styles
                // follow the cell's own text colour, white at rest and black
                // under focus — no colour of its own.
                Capsule()
                    .fill(.quaternary)
                    .frame(height: metrics.progressBarHeight)
                    .overlay(alignment: .leading) {
                        GeometryReader { proxy in
                            Capsule()
                                .fill(.primary)
                                .frame(width: max(metrics.progressBarHeight, proxy.size.width * progress))
                        }
                    }
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, metrics.cellInset)
        .frame(width: width, height: metrics.cellHeight, alignment: .leading)
        .clipped()
        .contentShape(Rectangle())
    }
}

/// What the info panel above the grid shows: the channel its Watch pill
/// plays, and the programme being described.
private struct AppleTVGuideStripInfo {
    let channel: AppleIPTVChannel
    let title: String
    /// "CBS · 6:00 – 6:30 PM"; nil when the channel has no programme data.
    let detail: String?
    let summary: String?
}

/// One programme's time span in the viewer's locale, with a shared meridiem
/// written once ("6:00 – 6:30 PM").
private enum AppleTVGuideTimeSpan {
    static func text(from start: Date, to end: Date) -> String {
        (start..<max(start, end)).formatted(.interval.hour().minute())
    }
}

// MARK: - Styles

/// Guide cells: a flat translucent tile that turns solid white with black
/// text when focused, the way the system TV app's guide highlights the cell
/// under focus. The programme on now is a shade brighter; the brand accent
/// stays on the now-line.
struct AppleTVGuideCellStyle: ButtonStyle {
    let isCurrent: Bool
    let isGap: Bool
    /// Over and in no archive: the title is dimmed like a gap's.
    var isPast = false
    let cornerRadius: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        StyledBody(configuration: configuration, isCurrent: isCurrent, isGap: isGap, isPast: isPast, cornerRadius: cornerRadius)
    }

    private struct StyledBody: View {
        @Environment(\.isFocused) private var isFocused
        let configuration: ButtonStyleConfiguration
        let isCurrent: Bool
        let isGap: Bool
        let isPast: Bool
        let cornerRadius: CGFloat

        var body: some View {
            configuration.label
                .foregroundStyle(isFocused ? Color.black : (isGap || isPast ? AppleDesignTokens.textSecondary : Color.white))
                .background(fill, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                // The white fill alone read as weak beside the brighter
                // on-now tiles (full test 2026-10-01); a shadow lifts the
                // focused cell off the grid. No scale: cells abut, and a
                // scaled cell would slide under its neighbour.
                .shadow(color: .black.opacity(isFocused ? 0.6 : 0), radius: 10, y: 4)
                .opacity(configuration.isPressed ? 0.85 : 1)
                .animation(.easeOut(duration: 0.12), value: isFocused)
                #if DEBUG
                .onChange(of: isFocused) { _, focused in
                    if focused { AppleTVGuideLatencyProbe.shared.highlightChanged() }
                }
                #endif
        }

        private var fill: Color {
            if isFocused { return .white }
            if isCurrent { return Color.white.opacity(0.12) }
            return Color.white.opacity(0.06)
        }
    }
}

/// Rail cells keep their logo legible: a translucent white tile when focused.
struct AppleTVGuideRailStyle: ButtonStyle {
    let cornerRadius: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        StyledBody(configuration: configuration, cornerRadius: cornerRadius)
    }

    private struct StyledBody: View {
        @Environment(\.isFocused) private var isFocused
        let configuration: ButtonStyleConfiguration
        let cornerRadius: CGFloat

        var body: some View {
            configuration.label
                .background(Color.white.opacity(isFocused ? 0.3 : 0), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                // A ring as well as the tile: a 22% tile alone was easy to
                // lose on the guide (full test 2026-10-01). Not a solid white
                // fill, which would swallow white logos.
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(isFocused ? 0.9 : 0), lineWidth: 3)
                }
                .opacity(configuration.isPressed ? 0.85 : 1)
                .animation(.easeOut(duration: 0.12), value: isFocused)
                #if DEBUG
                .onChange(of: isFocused) { _, focused in
                    if focused { AppleTVGuideLatencyProbe.shared.highlightChanged() }
                }
                #endif
        }
    }
}

/// Capsule pills for Watch and the category row. Selected pills are white
/// with black text; unselected ones are 8% white with a 55% stroke. Focus adds
/// the same ring, glow and lift the brand primary button uses.
/// Category chips: plain text at rest, a quiet capsule for the selected
/// category, solid white with black text when focused. Ten outlined capsules
/// in a row read as clutter (owner 18:50, "gui needs to be worked still").
struct AppleTVChipStyle: ButtonStyle {
    var isSelected: Bool
    var height: CGFloat
    var fontSize: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        StyledBody(configuration: configuration, isSelected: isSelected, height: height, fontSize: fontSize)
    }

    private struct StyledBody: View {
        @Environment(\.isFocused) private var isFocused
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        let configuration: ButtonStyleConfiguration
        let isSelected: Bool
        let height: CGFloat
        let fontSize: CGFloat

        var body: some View {
            configuration.label
                .font(.system(size: fontSize, weight: isSelected || isFocused ? .semibold : .medium))
                .foregroundStyle(isFocused ? Color.black : (isSelected ? Color.white : Color.white.opacity(0.7)))
                .padding(.horizontal, 22)
                .frame(minHeight: height)
                .background(isFocused ? Color.white : Color.white.opacity(isSelected ? 0.18 : 0), in: .capsule)
                .scaleEffect(reduceMotion ? 1 : (isFocused ? 1.06 : 1))
                .opacity(configuration.isPressed ? 0.7 : 1)
                .contentShape(.capsule)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isFocused)
        }
    }
}

struct AppleTVPillStyle: ButtonStyle {
    var isSelected: Bool
    var minimumSize: CGSize
    var fontSize: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        StyledBody(configuration: configuration, isSelected: isSelected, minimumSize: minimumSize, fontSize: fontSize)
    }

    private struct StyledBody: View {
        @Environment(\.isFocused) private var isFocused
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        let configuration: ButtonStyleConfiguration
        let isSelected: Bool
        let minimumSize: CGSize
        let fontSize: CGFloat

        /// A disabled pill kept the full focused treatment — solid white, black
        /// text, lifted — because this style never read `isEnabled`. While a
        /// network share was testing, both buttons disabled at once and the one
        /// under focus stayed a bright white slab that still looked pressable:
        /// the owner's "test connection gui turns white, can't see what it's
        /// doing" (2026-09-15).
        private var showsFocus: Bool { isFocused && isEnabled }

        var body: some View {
            // Owner (16:20): no ring, no glow. Focused = solid white with black
            // text and a small lift; unfocused = quiet translucent capsule, the
            // way the reference's buttons behave. `isSelected` keeps a slightly
            // brighter capsule so the primary action still reads first.
            configuration.label
                .font(.system(size: fontSize, weight: .semibold))
                .foregroundStyle(showsFocus ? Color.black : Color.white)
                .padding(.horizontal, 28)
                .frame(minWidth: minimumSize.width, minHeight: minimumSize.height)
                .background(showsFocus ? Color.white : Color.white.opacity(isSelected ? 0.28 : 0.16), in: .capsule)
                .scaleEffect(reduceMotion ? 1 : (showsFocus ? 1.06 : 1))
                .shadow(color: .black.opacity(showsFocus ? 0.35 : 0), radius: 14, y: 6)
                // Unavailable, and visibly so, rather than a bright slab that
                // still invites a press.
                .opacity(configuration.isPressed ? 0.7 : (isEnabled ? 1 : 0.4))
                .contentShape(.capsule)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: showsFocus)
        }
    }
}

/// A bare glyph that gains a white disc when focused; no boxed toolbar item.
/// `isSelected` keeps a faint disc while unfocused (an active search filter).
struct AppleTVGlyphStyle: ButtonStyle {
    var isSelected = false

    func makeBody(configuration: Configuration) -> some View {
        StyledBody(configuration: configuration, isSelected: isSelected)
    }

    private struct StyledBody: View {
        @Environment(\.isFocused) private var isFocused
        let configuration: ButtonStyleConfiguration
        let isSelected: Bool

        var body: some View {
            configuration.label
                .foregroundStyle(isFocused ? Color.black : Color.white)
                .frame(width: 56, height: 56)
                .background(Color.white.opacity(isFocused ? 1 : (isSelected ? 0.22 : 0)), in: Circle())
                .opacity(configuration.isPressed ? 0.7 : 1)
                .animation(.easeOut(duration: 0.12), value: isFocused)
        }
    }
}

// MARK: - Content footer (Menu / swipe down while playing)

/// The channel row over full-screen playback: one focus section of channel
/// cards with focus starting on the playing channel, which carries a LIVE
/// badge. Selecting another card switches playback in place. No title, no
/// scrim: the cards sit directly on the video.
struct AppleTVLiveChannelFooter: View {
    let channels: [AppleIPTVChannel]
    let currentID: String
    let metrics: AppleTVGuideMetrics
    let focus: FocusState<AppleTVLivePlayerFocus?>.Binding
    /// Names what is on each channel, so the strip answers "what is playing"
    /// without opening the guide (owner 2026-09-15).
    var guide: AppleIPTVGuide = AppleIPTVGuide(programmes: [])
    let onSelect: (AppleIPTVChannel) -> Void
    var onMultiview: ((AppleIPTVChannel) -> Void)? = nil

    /// Same reason as `playerDefaultFocus`: the footer's body re-runs on every
    /// focus move, so this never builds an array of the whole lineup.
    private var defaultCardID: String? {
        if channels.contains(where: { $0.id == currentID }) { return currentID }
        return channels.first?.id
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: metrics.footerCardSpacing) {
                    ForEach(channels) { channel in
                        let isCurrent = channel.id == currentID
                        Button { onSelect(channel) } label: {
                            // The name and LIVE used to share one row inside a
                            // fixed-width card, so a long name lost most of
                            // itself to the badge — the owner's "the name and
                            // live doesn't fit because channel name is too
                            // long" (2026-09-15). LIVE now rides the logo row,
                            // smaller, leaving the name the full width.
                            VStack(alignment: .leading, spacing: 6) {
                                AppleRemoteImage(url: channel.logoURL, contentMode: .fit, placeholderSystemImage: "tv")
                                    .frame(width: metrics.footerLogoSize.width, height: metrics.footerLogoSize.height)
                                Text(channel.name)
                                    .font(.system(size: metrics.subtitleFontSize, weight: .medium))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                // LIVE shares the bottom line with the
                                // programme rather than the name: the logo is
                                // as wide as the card's content box, so a badge
                                // on either of the rows above has nowhere to go.
                                HStack(spacing: 6) {
                                    if isCurrent {
                                        Text("LIVE")
                                            .font(.system(size: metrics.badgeFontSize - 4, weight: .bold))
                                            .foregroundStyle(.red)
                                    }
                                    if let now = guide.nowAndNext(channelID: channel.id).now {
                                        Text(now.title)
                                            .font(.system(size: metrics.badgeFontSize - 2))
                                            // Hierarchical, not a fixed grey:
                                            // the focused card turns white and
                                            // a light grey title disappeared
                                            // into it.
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(12)
                            .frame(width: metrics.footerCardSize.width, height: metrics.footerCardSize.height, alignment: .topLeading)
                        }
                        .buttonStyle(AppleTVGuideCellStyle(isCurrent: isCurrent, isGap: false, cornerRadius: 14))
                        .focused(focus, equals: .card(channel.id))
                        .accessibilityLabel(isCurrent ? "\(channel.name), live now" : "Play \(channel.name)")
                        .contextMenu {
                            if let onMultiview { Button("Watch in Multiview") { onMultiview(channel) } }
                        }
                        .accessibilityIdentifier("live.footer.\(channel.id)")
                        .id(channel.id)
                    }
                }
                .padding(.horizontal, metrics.horizontalSafeInset)
                .padding(.vertical, 20)
            }
            .scrollIndicators(.hidden)
            .onAppear { proxy.scrollTo(currentID, anchor: .center) }
            .onChange(of: currentID) { _, id in proxy.scrollTo(id, anchor: .center) }
        }
        .frame(height: metrics.footerHeight)
        .focusSection()
        .modifier(AppleTVFooterDefaultFocus(focus: focus, cardID: defaultCardID))
    }
}

private struct AppleTVFooterDefaultFocus: ViewModifier {
    let focus: FocusState<AppleTVLivePlayerFocus?>.Binding
    let cardID: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let cardID {
            content.defaultFocus(focus, .card(cardID))
        } else {
            content
        }
    }
}

// MARK: - Full-screen player

/// Full-screen live playback on Apple TV. AVKit's controller renders the
/// stream; the app owns the remote: Play/Pause toggles, Menu and swipe down
/// show the channel footer, Menu again or swipe up hides it, and Menu with
/// the footer dismissed returns to the guide (see `AppleTVLiveFooterState`).
/// The software surface falls back to the reduced transport overlay. While a
/// stream connects the screen is black with one centered spinner.
@MainActor
struct AppleTVLivePlayerScreen: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @State private var host: ApplePlayerHost
    @State private var audioSession: AppleAudioSessionCoordinator
    @FocusState private var focus: AppleTVLivePlayerFocus?
    /// Whether the channel on screen has ever played a frame. Reset per
    /// channel; it decides what Menu means while the picture is still black.
    @State private var hasPlayed = false
    @State private var playbackMenu = false
    @State private var watchHistory = AppleLiveWatchHistoryStore.shared
    @AppStorage("openstream.live.zappingHintSeen") private var zappingHintSeen = false
    @State private var showsZappingHint = false
    @State private var sleepTimerMenu = false
    /// "Captions on" / "off" / "none", shown briefly after a swipe up.
    @State private var captionsNotice: String?
    @State private var captionsNoticeTask: Task<Void, Never>?
    /// The captions the OpenStream engine leaves to the app on this route.
    @State private var stockSubtitles = AppleStockPlayerSubtitles()
    /// This cover was rebuilt around the player in the Picture in Picture
    /// window: the stream keeps playing, so the first load is skipped.
    @State private var resumesFromPictureInPicture: Bool
    @State private var liveSession: AppleLiveSession
    @Binding var footer: AppleTVLiveFooterState

    let channel: AppleIPTVChannel
    let coordinator: ApplePlaybackCoordinator
    let footerChannels: [AppleIPTVChannel]
    /// The unfiltered lineup, searched for another feed of the same network
    /// when this one is dead. The strip's own list is the curated guide, which
    /// is deduplicated to one feed per network — exactly the feeds that would
    /// be needed as replacements are the ones it has already removed.
    let alternateLineup: [AppleIPTVChannel]
    /// Names of the viewer's lists, for "Watch on <list>".
    let sourceNames: [UUID: String]
    /// Only used to name what is on each channel in the strip.
    let guide: AppleIPTVGuide
    let metrics: AppleTVGuideMetrics
    /// A programme played from the channel's archive instead of the live
    /// stream (`AppleIPTVCatchUp`); nil for live. "Watch Live" is
    /// `onSwitch(channel)`.
    let programme: AppleIPTVProgramme?
    let channelNumber: Int?
    let playbackRevision: Int
    let onSwitch: (AppleIPTVChannel) -> Void
    let onStartOver: (() -> Void)?
    let onLastChannel: (() -> Void)?
    let onMultiview: ((AppleIPTVChannel?) -> Void)?
    let onBack: (() -> Void)?
    /// The Live tab's own player; not a multiview tile or a fixture.
    let allowsPictureInPicture: Bool
    let retainsMultiviewStream: Bool

    init(channel: AppleIPTVChannel, coordinator: ApplePlaybackCoordinator, footerChannels: [AppleIPTVChannel],
         footer: Binding<AppleTVLiveFooterState>, alternateLineup: [AppleIPTVChannel] = [],
         sourceNames: [UUID: String] = [:],
         guide: AppleIPTVGuide = AppleIPTVGuide(programmes: []),
         metrics: AppleTVGuideMetrics = .standard,
         programme: AppleIPTVProgramme? = nil,
         channelNumber: Int? = nil,
         playbackRevision: Int = 0,
         onStartOver: (() -> Void)? = nil,
         onLastChannel: (() -> Void)? = nil,
         onMultiview: ((AppleIPTVChannel?) -> Void)? = nil,
         onBack: (() -> Void)? = nil,
         allowsPictureInPicture: Bool = false,
         retainsMultiviewStream: Bool = false,
         liveSession: AppleLiveSession? = nil,
         onSwitch: @escaping (AppleIPTVChannel) -> Void) {
        self.channel = channel
        self.programme = programme
        self.channelNumber = channelNumber ?? channel.channelNumber
        self.playbackRevision = playbackRevision
        self.coordinator = coordinator
        self.footerChannels = footerChannels
        self.alternateLineup = alternateLineup
        self.sourceNames = sourceNames
        _footer = footer
        self.guide = guide
        self.metrics = metrics
        self.onSwitch = onSwitch
        self.onStartOver = onStartOver
        self.onLastChannel = onLastChannel
        self.onMultiview = onMultiview
        self.onBack = onBack
        self.allowsPictureInPicture = allowsPictureInPicture
        self.retainsMultiviewStream = retainsMultiviewStream
        _liveSession = State(initialValue: liveSession ?? AppleLiveSession(coordinator: coordinator))
        let parked = allowsPictureInPicture ? AppleTVPictureInPicture.shared.parked(for: coordinator) : nil
        let audioSession = parked?.audioSession ?? AppleAudioSessionCoordinator()
        _audioSession = State(initialValue: audioSession)
        _host = State(initialValue: parked?.host ?? ApplePlayerHost(coordinator: coordinator, audioSession: audioSession))
        _resumesFromPictureInPicture = State(initialValue: parked != nil)
    }

    private var request: ApplePlaybackRequest {
        liveSession.request(for: channel, programme: programme)
    }

    /// "Watch Live" for the overlay: only over an archived programme.
    private var watchLiveAction: (() -> Void)? {
        guard programme != nil else { return nil }
        return { watchLive() }
    }

    /// Back to the live channel from an archived programme.
    private func watchLive() {
        #if DEBUG
        AppleInteractionTrace.record(.press, "live watch live \(channel.name)")
        #endif
        onSwitch(channel)
    }

    private var zapAction: ((AppleLiveZappingPolicy.Direction) -> Void)? {
        guard programme == nil else { return nil }
        return { direction in zap(direction) }
    }

    /// The picture: the engine's surface with the overlay, or the stock
    /// player. Split out of `body` so the type-checker can still finish it.
    @ViewBuilder
    private var playbackLayer: some View {
        if coordinator.route == .surface {
            ApplePlaybackSurfaceView(engine: coordinator.engine)
                .ignoresSafeArea()
            // The overlay owns the remote on this route: Menu closes,
            // Play/Pause toggles, the clickpad edges skip.
            AppleTransportOverlay(coordinator: coordinator, request: request,
                                  onShowChannels: { apply(.select) },
                                  onZapChannel: zapAction,
                                  onPlaybackMenu: { playbackMenu = true },
                                  playbackOptions: playbackOptions,
                                  isObscured: footer.isVisible, onClose: { closePlayer() },
                                  onWatchLive: watchLiveAction)
            footerOverlay
        } else {
            stockPlayerWithFooter
        }
    }

    /// The channel strip (and, over an archived programme on the stock
    /// route, the Watch Live pill above it) while the footer is shown.
    @ViewBuilder
    private var footerOverlay: some View {
        if footer.isVisible {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                if let programme, coordinator.route != .surface {
                    // The stock route has no overlay of its own for this;
                    // the pill sits above the channel strip.
                    Button("Back to Live", action: watchLive)
                        .buttonStyle(AppleTVPillStyle(
                            isSelected: true,
                            minimumSize: AppleTVDetailMetrics.pillSize,
                            fontSize: AppleTVDetailMetrics.pillFontSize
                        ))
                        .focused($focus, equals: .watchLive)
                        .accessibilityLabel("Back to Live, leave \(programme.title)")
                        .accessibilityIdentifier("live.watchLive")
                        .padding(.bottom, 24)
                }
                if programme == nil, onLastChannel != nil || previousChannel != nil {
                    Button("Last Channel", action: recallLastChannel)
                        .buttonStyle(AppleTVPillStyle(isSelected: false,
                            minimumSize: AppleTVDetailMetrics.pillSize,
                            fontSize: AppleTVDetailMetrics.pillFontSize))
                        .focused($focus, equals: .lastChannel)
                        .accessibilityIdentifier("live.player.lastChannel")
                        .frame(maxWidth: .infinity)
                        .focusSection()
                        .padding(.bottom, 20)
                }
                AppleTVLiveChannelFooter(
                    channels: footerChannels,
                    currentID: channel.id,
                    metrics: metrics,
                    focus: $focus,
                    guide: guide,
                    onSelect: { selected in
                        guard footer.apply(.channelSelected) == .switchChannel else { return }
                        // Close the row and take focus back to the surface
                        // in the same turn. Leaving it open over a picture
                        // that was reloading is what read as a freeze
                        // (owner 18:55); `reset` keeps Menu meaning
                        // "show the channels" rather than "leave".
                        footer.reset()
                        focus = .surface
                        onSwitch(selected)
                    },
                    onMultiview: onMultiview.map { action in { action($0) } }
                )
                .padding(.bottom, metrics.verticalSafeInset - 20)
            }
            .ignoresSafeArea()
            .transition(.move(edge: .bottom))
        }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            playbackLayer
            if coordinator.isReconnectingLive {
                // A channel that was playing and dropped: say so, quietly,
                // while the coordinator reopens it (`AppleLiveReconnectPolicy`).
                VStack(spacing: 16) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                        .controlSize(.large)
                    Text("Reconnecting…")
                        .font(.system(size: metrics.subtitleFontSize, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.7), radius: 8, y: 1)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Reconnecting to \(channel.name)")
                .accessibilityIdentifier("live.reconnecting")
            } else if coordinator.phase.isBusy {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .controlSize(.large)
                    .accessibilityLabel("Connecting to \(channel.name)")
            }
        }
        .overlay {
            if programme == nil {
                AppleLiveChannelBanner(channel: channel, number: channelNumber, guide: guide)
                    .padding(metrics.verticalSafeInset)
            }
        }
        .overlay(alignment: .topTrailing) {
            if showsZappingHint {
                Text(AppleLiveZappingPolicy.remoteHint)
                    .font(.callout)
                    .foregroundStyle(.white)
                    .shadow(color: .black, radius: 3)
                    .padding(metrics.verticalSafeInset)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("live.player.remoteHint")
            }
        }
        .modifier(AppleLiveWatchTracking(channelID: channel.id, coordinator: coordinator,
            revision: playbackRevision, isLive: programme == nil))
        .task {
            guard programme == nil, !zappingHintSeen else { return }
            showsZappingHint = true
            do { try await Task.sleep(for: .seconds(6)) } catch { return }
            showsZappingHint = false
            zappingHintSeen = true
        }
        .task(id: footer.isVisible) {
            guard footer.isVisible else { return }
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            footer.reset()
            focus = .surface
        }
        .modifier(AppleProgrammeReminderBanner())
        .modifier(AppleSleepTimerPresentation(coordinator: coordinator))
        .confirmationDialog("Sleep Timer", isPresented: $sleepTimerMenu) {
            AppleSleepTimerChoices(coordinator: coordinator, isLive: programme == nil)
        }
        .confirmationDialog("Playback", isPresented: $playbackMenu) {
            playbackOptions
        }
        .onChange(of: coordinator.phase) { _, phase in
            if phase == .playing {
                hasPlayed = true
                if focus == nil, !footer.isVisible { focus = .surface }
            }
            #if DEBUG
            AppleInteractionTrace.record(.playback, "live \(channel.name) phase=\(phase) route=\(coordinator.route)")
            #endif
        }
        .task(id: ObjectIdentifier(coordinator.engine)) {
            for await event in coordinator.engine.events {
                switch event {
                case .tracks, .route:
                    selectArmedCaptionsIfAvailable()
                default:
                    break
                }
            }
        }
        .onChange(of: focus) { _, value in
            #if DEBUG
            AppleInteractionTrace.record(.focus, "live player \(value.map(String.init(describing:)) ?? "none")")
            #endif
        }
        .task(id: "\(channel.id)|\(channel.streamURL.absoluteString)|\(programme?.id ?? "")|\(playbackRevision)|\(onBack != nil && scenePhase == .background)") {
            if retainsMultiviewStream {
                if scenePhase == .background {
                    coordinator.engine.pause()
                    host.teardown()
                    return
                }
                host.activate()
                host.configureLivePlaybackControls()
                coordinator.engine.play()
                hasPlayed = coordinator.phase == .playing
                host.rebind()
                return
            }
            if resumesFromPictureInPicture {
                // Back from the window: the same stream on the same host.
                resumesFromPictureInPicture = false
                hasPlayed = true
                host.activate()
                host.configureLivePlaybackControls()
                return
            }
            hasPlayed = false
            if allowsPictureInPicture { AppleTVPictureInPicture.shared.endForNewPlayback(keeping: host) }
            coordinator.stop()
            if onBack != nil && scenePhase == .background { host.teardown(); return }
            // Drop the controller's reference to the channel that just
            // stopped before the next one starts loading. Without this the
            // AVPlayerViewController kept the previous player until the host's
            // 0.25 s timer noticed, which on a provider that allows one
            // connection is long enough to stall the channel being opened.
            host.rebind()
            host.activate()
            host.configureLivePlaybackControls()
            try? await audioSession.prepareForPlayback()
            guard !Task.isCancelled else { return }
            // A dead channel is replaced by another feed of the same network
            // rather than reported (owner 2026-09-15: "a dead channel could it
            // be replaced?"). The coordinator has done this for on-demand
            // streams all along; live never handed it candidates, which is why
            // every live trace read `attempt 0/0`.
            let alternates = AppleLiveChannelAlternates.alternates(
                for: channel,
                in: alternateLineup,
                hasRecentlyFailed: { ApplePlaybackFailureHistory.shared.contains($0) }
            )
            #if DEBUG
            AppleInteractionTrace.record(
                .playback,
                "live \(channel.name): \(alternates.count) alternate(s) from \(alternateLineup.count) channels"
                    + (alternates.isEmpty ? "" : " — \(alternates.map(\.name).joined(separator: ", "))")
            )
            #endif
            // An archived programme has no stand-in on another list.
            await coordinator.begin(
                request,
                fallbackCandidates: programme == nil ? alternates.map { $0.playbackRequest() } : []
            )
            // Bind the controller to the new stream now instead of waiting for
            // the host's 0.25 s safety timer, so a channel switch changes the
            // picture as soon as it is ready. Not after a cancel: the screen is
            // going away and `onDisappear` has already torn the host down.
            guard !Task.isCancelled else { return }
            host.rebind()
        }
        .onAppear {
            if footer.isVisible { focusFooter() } else { focus = .surface }
            registerPictureInPicture()
        }
        #if DEBUG
        // Whether a given channel is dead changes hour to hour, so the failure
        // state could only be captured by luck. This stages one on demand:
        // `defaults write com.orgista.openstream OpenStreamLiveFailureProbe
        // -string player` (any `ApplePlaybackFailure.Kind` raw value).
        .task {
            guard let raw = UserDefaults.standard.string(forKey: "OpenStreamLiveFailureProbe"),
                  let kind = ApplePlaybackFailure.Kind(rawValue: raw) else { return }
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            coordinator.fail(ApplePlaybackFailure(
                kind: kind,
                message: "Demuxer: open failed (Input/output error (-5))"
            ))
        }
        #endif
        .onDisappear {
            // The cover's item binding is cleared by SwiftUI when the cover
            // is dismissed; nothing here must clear it, or a channel switch
            // that rebuilds this screen would close the player.
            // In the Picture in Picture window it plays on.
            if AppleTVPictureInPicture.shared.holds(host) { return }
            AppleTVPictureInPicture.shared.unregister(host)
            host.teardown(deactivateAudioSession: !retainsMultiviewStream)
            if !retainsMultiviewStream { coordinator.stop() }
        }
        // No alert: the failure is drawn over the picture. What a dead channel
        // needs is the next channel, so the strip opens itself and takes
        // focus. Menu still leaves, exactly as it does with the strip open.
        .onChange(of: failureIdentity) { _, identity in
            guard identity != nil, case .failed(let failure) = coordinator.phase else { return }
            // The same channel on another list beats the next channel: offer
            // it, focused, and leave the strip closed.
            if let other = otherListChannel {
                #if DEBUG
                AppleInteractionTrace.record(
                    .failure,
                    "live \(channel.name) failed (\(failure.kind)) — offering \"\(otherListTitle(for: other))\""
                )
                #endif
                appleTrace("live other-list offer: \(otherListTitle(for: other)) (guide id \(other.guideID == nil ? "no" : "yes"))")
                if footer.isVisible { footer.reset() }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(60))
                    focus = .otherList
                }
                return
            }
            appleTrace("live other-list offer: none for \(channel.name)")
            guard AppleLiveFailurePresentation.opensChannelStrip(for: failure),
                  !footer.isVisible else { return }
            #if DEBUG
            AppleInteractionTrace.record(
                .failure,
                "live \(channel.name) failed (\(failure.kind)): \(failure.message) — opening the channel strip"
            )
            #endif
            _ = footer.apply(.swipeDown)
            focusFooter()
        }
    }

    /// The stock controller renders the stream with its transport bar and
    /// info panel switched off (`AppleTVLivePlayerControllerRepresentable`).
    /// While the footer is hidden an invisible full-screen button holds focus
    /// so the remote's commands reach this view; when the footer is shown that
    /// button leaves the hierarchy and the cards are the only focus targets.
    private var stockPlayerWithFooter: some View {
        ZStack {
            if allowsPictureInPicture {
                // Where the window opens from and lands; under the controller.
                AppleTVPictureInPictureLayer(view: host.pictureInPictureLayerView)
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
            }
            AppleTVLivePlayerControllerRepresentable(viewController: host.viewController)
                .ignoresSafeArea()

            // Below the invisible focus button so it can never be a focus or
            // press target; the strip lifts it rather than covering it.
            if AppleSubtitleCueLayerPolicy.mountsOverStockPlayer(engine: coordinator.engine.kind, route: coordinator.route) {
                AppleStockPlayerCueLayer(engine: coordinator.engine, subtitles: stockSubtitles,
                                         textBottomLift: footer.isVisible ? metrics.footerHeight : 0)
                    .ignoresSafeArea()
            }

            if !footer.isVisible {
                Button {
                    apply(.select)
                } label: {
                    Color.clear.contentShape(.rect)
                }
                // Never `.plain`: tvOS brightens a focused plain button, which
                // painted a light platter over live video (owner 18:52).
                .buttonStyle(AppleTVBareButtonStyle())
                .focused($focus, equals: .surface)
                .accessibilityLabel("Show channels")
                .accessibilityValue(channel.name)
                .contextMenu { playbackOptions }
                .accessibilityIdentifier("live.player.surface")
            }

            if let captionsNotice, !footer.isVisible {
                VStack {
                    Text(captionsNotice)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(.black.opacity(0.6), in: .capsule)
                        .padding(.top, metrics.verticalSafeInset)
                    Spacer()
                }
                .transition(.opacity)
                .accessibilityIdentifier("live.player.captionsNotice")
            }

            if coordinator.phase == .paused {
                Image(systemName: "pause.fill")
                    .font(.system(size: 72, weight: .semibold))
                    .foregroundStyle(.white)
                    .accessibilityLabel("Paused")
            }

            // A dead channel is ordinary in a lineup of thousands, so it reads
            // as a line over the picture rather than a modal that stops the
            // remote. The channel strip opens with it, so the next channel is
            // one press away.
            if case .failed(let failure) = coordinator.phase,
               AppleLiveFailurePresentation.isVisible(failure) {
                VStack(spacing: 20) {
                    Text(AppleLiveFailurePresentation.message(for: failure, channelName: channel.name))
                        .font(.system(size: metrics.titleFontSize, weight: .semibold))
                        .foregroundStyle(.white)
                        // The last frame stays on screen behind this, which can
                        // be anything. A shadow keeps the line readable without
                        // a scrim, the same way the title page's own copy does.
                        .shadow(color: .black.opacity(0.7), radius: 8, y: 1)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 1100)
                    // Names the host that went quiet, so a dead provider does
                    // not read as a broken app.
                    if let detail = AppleLiveFailurePresentation.detail(
                        for: failure,
                        endpoint: channel.streamURL.host()
                    ) {
                        Text(detail)
                            .font(.system(size: metrics.subtitleFontSize))
                            .foregroundStyle(.white.opacity(0.75))
                            .shadow(color: .black.opacity(0.7), radius: 8, y: 1)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 1100)
                    }
                    HStack(spacing: 32) {
                        if let other = otherListChannel {
                            Button(otherListTitle(for: other)) {
                                appleTrace("live other-list chosen: \(otherListTitle(for: other))")
                                #if DEBUG
                                AppleInteractionTrace.record(.press, "live watch on other list \(other.name)")
                                #endif
                                onSwitch(other)
                            }
                            .buttonStyle(AppleTVPillStyle(
                                isSelected: true,
                                minimumSize: AppleTVDetailMetrics.pillSize,
                                fontSize: AppleTVDetailMetrics.pillFontSize
                            ))
                            .focused($focus, equals: .otherList)
                            .accessibilityIdentifier("live.failure.otherList")
                        }
                        Button("Try Again") { Task { await coordinator.retry() } }
                            .buttonStyle(AppleTVPillStyle(
                                isSelected: otherListChannel == nil,
                                minimumSize: AppleTVDetailMetrics.pillSize,
                                fontSize: AppleTVDetailMetrics.pillFontSize
                            ))
                            .accessibilityIdentifier("live.failure.retry")
                    }
                }
                .padding(.bottom, footer.isVisible ? metrics.footerHeight : 0)
                .accessibilityIdentifier("live.failure")
            }

            footerOverlay
        }
        // The `.surface` button only exists while the footer is hidden, so a
        // fixed default aimed at it left focus nowhere the moment the row
        // appeared and the remote went dead (owner 18:55). `userInitiated`
        // re-evaluates this when the row comes and goes.
        .defaultFocus($focus, playerDefaultFocus, priority: .userInitiated)
        .onPlayPauseCommand { togglePlayPause() }
        .onExitCommand { apply(.menu) }
        .onMoveCommand { direction in
            switch direction {
            case .down where programme == nil:
                if case .zap(let direction) = AppleLiveZappingPolicy.action(.down, infoVisible: footer.isVisible) { zap(direction) }
            case .up where programme == nil:
                if footer.isVisible, onLastChannel != nil || previousChannel != nil { focus = .lastChannel }
                else if case .zap(let direction) = AppleLiveZappingPolicy.action(.up, infoVisible: footer.isVisible) { zap(direction) }
            case .down: apply(.swipeDown)
            case .up: apply(.swipeUp)
            // Left/right rewind and catch up inside what the stream really
            // holds (`AppleLiveSeekPolicy`); a live-edge-only channel ignores
            // them. Only while the strip is closed: open, they move the cards.
            case .left where !footer.isVisible: skipLive(by: -10)
            case .right where !footer.isVisible: skipLive(by: 10)
            default: break
            }
        }
        .animation(.easeOut(duration: 0.2), value: footer.isVisible)
    }

    /// The one focus target that is actually in the hierarchy right now.
    /// Evaluated on every body pass, and this screen's body re-runs on every
    /// focus move, so it must not walk the lineup: `map(\.id)` here allocated
    /// an array of every channel id each time a card took focus.
    private var playerDefaultFocus: AppleTVLivePlayerFocus {
        guard footer.isVisible else { return .surface }
        if footerChannels.contains(where: { $0.id == channel.id }) { return .card(channel.id) }
        if let first = footerChannels.first { return .card(first.id) }
        return .surface
    }

    private var playbackOptions: AppleLivePlaybackOptions {
        AppleLivePlaybackOptions(onSleepTimer: openSleepTimer,
            onMultiview: onMultiview.map { action in { action(nil) } }, onCaptions: toggleCaptions,
            onStartOver: programme == nil ? onStartOver : nil, onBackToLive: watchLiveAction,
            onPictureInPicture: pictureInPictureAction)
    }

    /// "Picture in Picture" in the options, where the window can show this
    /// stream (`AppleTVPictureInPicturePolicy.offersMenuEntry`).
    private var pictureInPictureAction: (() -> Void)? {
        guard allowsPictureInPicture, AppleTVPictureInPicturePolicy.offersMenuEntry(
            route: coordinator.route,
            isSupported: AVPictureInPictureController.isPictureInPictureSupported(),
            isPictureInPictureActive: AppleTVPictureInPicture.shared.isActive) else { return nil }
        return { startPictureInPicture() }
    }

    private func startPictureInPicture() {
        #if DEBUG
        AppleInteractionTrace.record(.press, "live picture in picture \(channel.name)")
        #endif
        footer.reset()
        Task { @MainActor in
            // Let the options menu close first, as the sleep timer does.
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            _ = await host.startPictureInPicture()
        }
    }

    /// How this player leaves for the window and comes back from it.
    private func registerPictureInPicture() {
        guard allowsPictureInPicture else { return }
        let pictureInPicture = AppleTVPictureInPicture.shared
        let host = host
        let coordinator = coordinator
        pictureInPicture.register(AppleTVPictureInPicture.Owner(
            host: host, audioSession: audioSession, coordinator: coordinator, content: .live,
            leave: { closePlayer() },
            restore: {},
            end: {
                host.teardown()
                coordinator.stop()
            }))
        pictureInPicture.playerAppeared(host)
    }

    private func openSleepTimer() {
        Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            coordinator.sleepProgrammeEnd = guide.nowAndNext(channelID: channel.id).now?.end
            sleepTimerMenu = true
        }
    }

    private var previousChannel: AppleIPTVChannel? {
        guard let id = liveSession.previousID(currentID: channel.id, programme: programme,
            history: watchHistory.history, availableIDs: Set(footerChannels.map(\.id))) else { return nil }
        return footerChannels.first { $0.id == id }
    }

    private func recallLastChannel() {
        if let onLastChannel {
            footer.reset()
            focus = .surface
            onLastChannel()
            return
        }
        guard let previousChannel else { return }
        switchLiveChannel(previousChannel)
    }

    private func zap(_ direction: AppleLiveZappingPolicy.Direction) {
        guard programme == nil, !playbackMenu,
              let id = liveSession.zapTarget(currentID: channel.id, programme: programme,
                orderedIDs: footerChannels.map(\.id), direction: direction),
              let target = footerChannels.first(where: { $0.id == id }) else { return }
        switchLiveChannel(target)
    }

    private func switchLiveChannel(_ target: AppleIPTVChannel) {
        AppleInteractionTrace.record(.press, "live zap \(channel.name) → \(target.name)")
        footer.reset()
        focus = .surface
        onSwitch(target)
    }

    private func closePlayer() {
        if let onBack { onBack() } else { dismiss() }
    }

    private func apply(_ command: AppleTVLiveFooterState.Command) {
        if command == .menu, onBack != nil { closePlayer(); return }
        if programme != nil, command == .swipeUp, onMultiview != nil { playbackMenu = true; return }
        #if DEBUG
        AppleInteractionTrace.record(.press, "live player \(command) footer=\(footer.phase) played=\(hasPlayed)")
        #endif
        // Menu leaves a channel that has never started. On a dead channel the
        // screen is black, and toggling the channel row over it — the footer's
        // normal answer to Menu — is what read as being stuck with no way out
        // (owner 18:55). Once a frame has played, Menu means the row again.
        if command == .menu, !footer.isVisible, !hasPlayed {
            closePlayer()
            return
        }
        switch footer.apply(command) {
        case .show:
            focusFooter()
        case .hide:
            focus = .surface
        case .exit:
            closePlayer()
        case .toggleCaptions:
            toggleCaptions()
        case .none, .switchChannel:
            break
        }
    }

    /// Live rewind within the engine's real seekable window. The stock
    /// transport is hidden on this route, so this is the only way back.
    private func skipLive(by seconds: Double) {
        let engine = coordinator.engine
        let range = engine.seekableRange
        guard let target = AppleLiveSeekPolicy.skipTarget(from: engine.position, by: seconds, in: range) else {
            appleTrace("live skip \(Int(seconds)) s: no DVR window (span \(range.map { Int($0.span) } ?? 0) s)")
            return
        }
        let behind = (range?.end ?? target) - target
        appleTrace("live skip \(Int(seconds)) s → \(Int(behind)) s behind live (window \(Int(range?.span ?? 0)) s)")
        Task { await coordinator.userSeek(to: target) }
        showNotice(behind < 2 ? "Live" : "\(Int(behind.rounded())) s behind live")
    }

    private func showNotice(_ notice: String) {
        captionsNoticeTask?.cancel()
        withAnimation(.easeOut(duration: 0.2)) { captionsNotice = notice }
        captionsNoticeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { captionsNotice = nil }
        }
    }

    /// The live player hides the stock transport and info panel, so without
    /// this there was no way to reach captions at all during live TV.
    private func toggleCaptions() {
        let engine = coordinator.engine
        let tracks = engine.subtitleTracks
        let next = AppleCaptionsToggle.nextSelection(selected: engine.activeSubtitleTrackID, visible: tracks)
        let notice: String
        if tracks.isEmpty, canArmLiveCaptions {
            notice = footer.togglePendingCaptions()
            // Record a manual choice now, so default-on discovery cannot undo
            // a second swipe (Off) before the first caption packet arrives.
            stockSubtitles.select(nil, on: engine)
        } else if tracks.isEmpty {
            notice = "No captions on this channel"
        } else {
            footer.cancelPendingCaptions()
            // Through the cue layer's object so a pick while paused shows (or
            // clears) the cue at once rather than on the next position tick.
            stockSubtitles.select(next, on: engine)
            notice = next == nil ? "Captions off" : "Captions on"
        }
        #if DEBUG
        AppleInteractionTrace.record(.press, "live captions \(notice) tracks=\(tracks.count)")
        #endif
        captionsNoticeTask?.cancel()
        withAnimation(.easeOut(duration: 0.2)) { captionsNotice = notice }
        captionsNoticeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { captionsNotice = nil }
        }
    }

    /// Raw live input is demuxed by OpenStream. Its loopback route discovers
    /// 608 lazily; HLS/native and software routes keep their existing controls.
    private var canArmLiveCaptions: Bool {
        request.isLive && !request.hints.nativeRemoteHLS
            && coordinator.engine.kind == .openStream
            && (coordinator.route == .none || coordinator.route == .avPlayer)
    }

    private func selectArmedCaptionsIfAvailable() {
        guard canArmLiveCaptions,
              let id = footer.takeArmedCaptionTrack(in: coordinator.engine.subtitleTracks) else { return }
        stockSubtitles.select(id, on: coordinator.engine)
    }

    /// The footer's `defaultFocus` covers the first appearance; this covers
    /// re-shows, where the focus system may keep a stale target.
    private func focusFooter() {
        guard let id = AppleTVLiveFooterState.focusTarget(currentID: channel.id, channelIDs: footerChannels.map(\.id)) else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            guard footer.isVisible else { return }
            focus = .card(id)
        }
    }

    private func togglePlayPause() {
        switch coordinator.phase {
        case .playing, .waiting:
            coordinator.userPause()
        case .paused:
            coordinator.userPlay()
        case .idle, .resolving, .loading, .ended, .failed:
            break
        }
    }

    /// The same channel on another of the viewer's lists, while this one is
    /// failed: matched by guide id, then name (`AppleLiveOtherListMatch`).
    /// Streams this press already tried are not offered again.
    private var otherListChannel: AppleIPTVChannel? {
        guard case .failed(let failure) = coordinator.phase,
              AppleLiveFailurePresentation.isVisible(failure),
              failure.kind != .authentication, failure.kind != .engineUnavailable else { return nil }
        return AppleLiveOtherListMatch.match(
            for: channel,
            in: alternateLineup,
            excludingURLs: Set(coordinator.triedSourceURLs),
            hasRecentlyFailed: { ApplePlaybackFailureHistory.shared.contains($0) }
        )
    }

    private func otherListTitle(for other: AppleIPTVChannel) -> String {
        AppleLiveOtherListMatch.offerTitle(sourceName: sourceNames[other.sourceID])
    }

    /// Changes once per distinct failure, so the strip opens for a new one
    /// without reopening every time the body runs.
    private var failureIdentity: String? {
        guard case .failed(let failure) = coordinator.phase,
              AppleLiveFailurePresentation.isVisible(failure) else { return nil }
        return "\(channel.id)|\(failure.kind)|\(failure.message)"
    }
}

/// Mounts the host's AVPlayerViewController as the rendering surface for live
/// playback. Its transport bar, info panel ("Channels" tab) and remote
/// handling are switched off so the SwiftUI footer and this view's command
/// handlers own the remote; the playback pipeline itself is unchanged.
private struct AppleTVLivePlayerControllerRepresentable: UIViewControllerRepresentable {
    let viewController: AVPlayerViewController

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        viewController.showsPlaybackControls = false
        viewController.customInfoViewControllers = []
        return viewController
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.showsPlaybackControls { controller.showsPlaybackControls = false }
    }
}
#endif
