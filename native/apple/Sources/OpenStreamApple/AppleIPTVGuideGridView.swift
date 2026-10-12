import SwiftUI

@MainActor
@Observable
private final class GuideScrollState {
    var horizontalOffset: CGFloat = 0
}

/// A lazy schedule with one shared timeline and a pinned channel rail.
public struct AppleIPTVGuideGridView: View {
    let channels: [AppleIPTVChannel]
    let guide: AppleIPTVGuide
    /// Bumped by `AppleIPTVGuideStore` whenever programmes arrive. Without it
    /// in the projection's identity the grid kept whatever it had projected
    /// before the guide loaded — every row reading "No information" until the
    /// next minute tick happened to rebuild it (measured on the iPad,
    /// 2026-09-20: the channel picker listed real programmes while the grid
    /// behind it still said there were none).
    let guideRevision: Int
    let entries: [AppleChannelLineupEntry]
    let favoriteIDs: Set<String>
    let favoriteOrder: [String]
    let onSelect: (AppleIPTVChannel) -> Void
    /// A programme that already aired on a channel with catch-up; the live
    /// channel is `onSelect`.
    let onSelectProgramme: (AppleIPTVChannel, AppleIPTVProgramme) -> Void
    let onToggleFavorite: (String) -> Void
    let onVisibleChannels: (Set<String>) async -> Void
    /// Last health result per channel id, built by the Live tab once per
    /// lineup or history change. Rows only look their own id up.
    let health: [String: AppleChannelHealthResult]
    let onShowHealth: ((AppleIPTVChannel) -> Void)?
    
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    
    @State private var rows: [AppleGuideRowModel] = []
    @State private var headerSlots: [AppleGuideGridHeaderSlot] = []
    @State private var scrollState = GuideScrollState()
    @State private var visibleIDs = Set<String>()
    /// Days the guide may scroll back into, from the lineup's catch-up
    /// channels (`AppleIPTVCatchUp.maximumGuideDays` at most).
    @State private var lookbackDays: Int?
    @State private var horizontalPosition = ScrollPosition()
    /// Window start the timeline was last placed in, so the scroll keeps the
    /// same clock time when the window's past edge moves.
    @State private var placedWindowStart: Date?
    
    @ScaledMetric(relativeTo: .body) private var rowHeight = 76.0

    public init(channels: [AppleIPTVChannel], guide: AppleIPTVGuide, guideRevision: Int = 0,
                entries: [AppleChannelLineupEntry],
                favoriteIDs: Set<String>, favoriteOrder: [String] = [], onSelect: @escaping (AppleIPTVChannel) -> Void,
                onToggleFavorite: @escaping (String) -> Void,
                onVisibleChannels: @escaping (Set<String>) async -> Void,
                health: [String: AppleChannelHealthResult] = [:],
                onShowHealth: ((AppleIPTVChannel) -> Void)? = nil,
                onSelectProgramme: @escaping (AppleIPTVChannel, AppleIPTVProgramme) -> Void = { _, _ in }) {
        self.onSelectProgramme = onSelectProgramme
        self.channels = channels
        self.guide = guide
        self.guideRevision = guideRevision
        self.entries = entries
        self.favoriteIDs = favoriteIDs
        self.favoriteOrder = favoriteOrder
        self.onSelect = onSelect
        self.onToggleFavorite = onToggleFavorite
        self.onVisibleChannels = onVisibleChannels
        self.health = health
        self.onShowHealth = onShowHealth
    }

    private let railWidth: CGFloat = 144
    private let cellWidth: CGFloat = 160

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let window = AppleGuideChannelProjection.window(day: context.date, now: context.date,
                earliest: lookbackDays.map { context.date.addingTimeInterval(-Double($0) * 86_400) })
            let timelineWidth = CGFloat(window.duration / 1800) * cellWidth
            let tick = floor(context.date.timeIntervalSince1970 / 60)
            
            VStack(spacing: 0) {
                if rows.isEmpty {
                    ContentUnavailableView("No Channels", systemImage: "tv")
                } else if dynamicTypeSize.isAccessibilitySize {
                    accessibleSchedule(window: window)
                } else {
                    GeometryReader { geometry in
                        ScrollView(.horizontal) {
                            ScrollView(.vertical) {
                                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                                    Section {
                                        ForEach(rows) { row in
                                            HStack(spacing: 0) {
                                                GuideChannelRail(row: row, isFavorite: favoriteIDs.contains(row.id),
                                                    health: AppleChannelHealthIndicator(result: health[row.id]),
                                                    scrollState: scrollState, railWidth: railWidth,
                                                    onSelect: { onSelect(row.channel) }, onToggleFavorite: { onToggleFavorite(row.id) },
                                                    onShowHealth: onShowHealth.map { show in { show(row.channel) } })
                                                    .frame(width: railWidth, height: rowHeight)
                                                    .background(Color.black)
                                                    .offset(x: scrollState.horizontalOffset)
                                                    .zIndex(1)
                                                GuideScheduleRow(row: row, cellWidth: cellWidth, height: rowHeight, scrollState: scrollState,
                                                    onSelect: { onSelect(row.channel) },
                                                    onSelectSpan: { span in
                                                        guard let start = span.airStart, let end = span.airEnd else { return }
                                                        onSelectProgramme(row.channel, AppleIPTVProgramme(
                                                            id: span.id, channelID: row.id, title: span.title, subtitle: nil,
                                                            description: span.subtitle, start: start, end: end, category: nil, isLive: false))
                                                    })
                                                    .equatable()
                                                    .mask(GuideProgrammeClip(scrollState: scrollState))
                                            }
                                            .onAppear { visibleIDs.insert(row.id) }
                                            .onDisappear { visibleIDs.remove(row.id) }
                                        }
                                    } header: {
                                        HStack(spacing: 0) {
                                            Text("Channels").font(.caption.bold())
                                                .padding(.leading, 8)
                                                .frame(width: railWidth, height: 36, alignment: .leading)
                                                .background(Color.black)
                                                .offset(x: scrollState.horizontalOffset).zIndex(1)
                                            GuideTimelineHeader(slots: headerSlots, cellWidth: cellWidth,
                                                scrollState: scrollState)
                                                .mask(GuideProgrammeClip(scrollState: scrollState))
                                        }
                                    }
                                }
                                .overlay(alignment: .topLeading) {
                                    if context.date >= window.start && context.date < window.end {
                                        let offset = context.date.timeIntervalSince(window.start) / 1800
                                        Rectangle().fill(AppleDesignTokens.brandAccent).frame(width: 1)
                                            .offset(x: railWidth + CGFloat(offset) * cellWidth)
                                            .padding(.top, 36)
                                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                            .mask(GuideProgrammeClip(scrollState: scrollState, leadingWidth: railWidth))
                                            .allowsHitTesting(false).accessibilityHidden(true)
                                    }
                                }
                            }
                            .scrollIndicators(.never)
                            .frame(width: railWidth + timelineWidth, height: geometry.size.height)
                        }
                        .scrollIndicators(.never)
                        .scrollPosition($horizontalPosition)
                        .onScrollGeometryChange(for: CGFloat.self) { max(0, $0.contentOffset.x) } action: { _, offset in
                            scrollState.horizontalOffset = offset
                        }
                        .onChange(of: window.start, initial: true) { _, start in
                            placeTimeline(window: window, now: context.date, viewportWidth: geometry.size.width)
                        }
                    }
                }
            }
            .background(Color.black)
            .task(id: GuideProjectionInput(channels: channels, guideRevision: guideRevision, entries: entries, favoriteIDs: favoriteIDs, window: window, tick: tick, favoriteOrder: favoriteOrder)) {
                let input = GuideProjectionInput(channels: channels, guideRevision: guideRevision, entries: entries, favoriteIDs: favoriteIDs, window: window, tick: tick, favoriteOrder: favoriteOrder)
                let now = context.date
                
                let result = await Task.detached(priority: .userInitiated) {
                    let projected = AppleGuideChannelProjection.rows(channels: input.channels, entries: input.entries,
                        favoriteIDs: input.favoriteIDs, favoritesOnly: false, sortByNumber: true, favoriteOrder: input.favoriteOrder)
                    let channelIDs = projected.map { $0.id }
                    
                    let gridIndex = AppleGuideGridModel.index(
                        channels: channelIDs,
                        guide: guide,
                        window: input.window,
                        slotWidthMinutes: 30,
                        now: now
                    )
                    
                    let newRows = projected.map { channel in
                        let cells = gridIndex.cells(for: channel.id)
                        let spans = cells.map { cell in
                            let isGap = cell.id.contains("-gap-")
                            return AppleGuideProgrammeSpan(
                                id: cell.id,
                                startOffset: cell.columnOffset,
                                width: cell.columnSpan,
                                title: cell.title,
                                subtitle: cell.subtitle,
                                isNow: cell.isLive || (cell.start <= now && cell.end > now),
                                airStart: isGap ? nil : cell.airStart,
                                airEnd: isGap ? nil : cell.airEnd,
                                isCatchUp: !isGap && AppleIPTVCatchUp.isAvailable(
                                    start: cell.airStart, end: cell.airEnd, on: channel.channel, now: now)
                            )
                        }
                        return AppleGuideRowModel(id: channel.id, channel: channel.channel, number: channel.number, spans: spans)
                    }
                    let lookback = projected.lazy
                        .filter { AppleIPTVCatchUp.supportsCatchUp($0.channel) }
                        .compactMap { $0.channel.catchUpDays }
                        .map { min($0, AppleIPTVCatchUp.maximumGuideDays) }
                        .max()
                    return (newRows, gridIndex.headerSlots, lookback)
                }.value
                
                guard !Task.isCancelled else { return }
                self.rows = result.0
                self.headerSlots = result.1
                self.lookbackDays = result.2
            }
        }
        .task(id: visibleIDs) {
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            await onVisibleChannels(visibleIDs)
        }
    }

    /// The guide opens on the current half hour, however far back the window
    /// reaches; when the window's past edge moves the rows keep showing the
    /// same clock time.
    private func placeTimeline(window: DateInterval, now: Date, viewportWidth: CGFloat) {
        defer { placedWindowStart = window.start }
        let x: CGFloat
        if let previous = placedWindowStart {
            guard previous != window.start else { return }
            x = scrollState.horizontalOffset + CGFloat(previous.timeIntervalSince(window.start) / 1800) * cellWidth
        } else {
            let nowSlot = AppleGuideChannelProjection.halfHour(of: now)
            x = CGFloat(max(0, nowSlot.timeIntervalSince(window.start)) / 1800) * cellWidth
        }
        let contentWidth = railWidth + CGFloat(window.duration / 1800) * cellWidth
        let placed = max(0, min(x, contentWidth - viewportWidth))
        guard abs(placed - scrollState.horizontalOffset) > 0.5 else { return }
        horizontalPosition.scrollTo(x: placed)
    }

    private func accessibleSchedule(window: DateInterval) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top, spacing: 12) {
                            let indicator = AppleChannelHealthIndicator(result: health[row.id])
                            Button { onSelect(row.channel) } label: {
                                HStack(spacing: 8) {
                                    Text((row.number.map { "\($0) · " } ?? "") + row.channel.name)
                                        .font(.headline).multilineTextAlignment(.leading)
                                    if let indicator { AppleChannelHealthDot(indicator: indicator, size: 10) }
                                }
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Play \(row.channel.name)")
                            .accessibilityValue(indicator?.accessibilityLabel ?? "")
                            .contextMenu {
                                AppleChannelQuickActions(channel: row.channel)
                                if let onShowHealth {
                                    Button("Channel Info", systemImage: "info.circle") { onShowHealth(row.channel) }
                                }
                            }
                            Button { onToggleFavorite(row.id) } label: {
                                Image(systemName: favoriteIDs.contains(row.id) ? "heart.fill" : "heart")
                                    .frame(minWidth: 44, minHeight: 44)
                                    .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(favoriteIDs.contains(row.id) ? "Remove" : "Add") \(row.channel.name) \(favoriteIDs.contains(row.id) ? "from" : "to") favorites")
                        }
                        let programmes = guide.programmes(channelID: row.id, in: window)
                        if programmes.isEmpty { Text("No information").foregroundStyle(.secondary) }
                        ForEach(programmes) { programme in
                            let catchUp = AppleIPTVCatchUp.isAvailable(programme, on: row.channel)
                            Button {
                                if catchUp { onSelectProgramme(row.channel, programme) } else { onSelect(row.channel) }
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(spacing: 6) {
                                        if catchUp {
                                            Image(systemName: "arrow.counterclockwise").font(.caption2)
                                                .foregroundStyle(.secondary).accessibilityHidden(true)
                                        }
                                        Text(programme.start, format: .dateTime.hour().minute()).font(.caption)
                                    }
                                    Text(programme.title).font(.body)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12).background(AppleDesignTokens.surface)
                            }
                            .contextMenu {
                                if AppleIPTVCatchUp.canStartOver(programme, on: row.channel) {
                                    Button("Start Over") { onSelectProgramme(row.channel, programme) }
                                        .accessibilityIdentifier("guide.startOver")
                                }
                                AppleProgrammeReminderAction(channel: row.channel, title: programme.title, start: programme.start, end: programme.end)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .onAppear { visibleIDs.insert(row.id) }
                    .onDisappear { visibleIDs.remove(row.id) }
                }
            }
            .padding(12)
        }
        .scrollIndicators(.hidden)
    }
}

private struct GuideProjectionInput: Equatable, Sendable {
    let channels: [AppleIPTVChannel]
    let guideRevision: Int
    let entries: [AppleChannelLineupEntry]
    let favoriteIDs: Set<String>
    let window: DateInterval
    let tick: Double
    var favoriteOrder: [String] = []
}

private struct GuideChannelRail: View {
    let row: AppleGuideRowModel
    let isFavorite: Bool
    let health: AppleChannelHealthIndicator?
    let scrollState: GuideScrollState
    let railWidth: CGFloat
    let onSelect: () -> Void
    let onToggleFavorite: () -> Void
    /// Nil when the channel has never been checked: the menu then has no
    /// health item, like the row has no dot.
    let onShowHealth: (() -> Void)?

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onSelect) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        if let logoURL = row.channel.logoURL {
                            AppleRemoteImage(url: logoURL, contentMode: .fit, placeholderSystemImage: "")
                                .frame(width: 34, height: 24)
                        }
                        if let number = row.number {
                            Text(number, format: AppleChannelNumberFormat.style)
                                .font(.caption.monospacedDigit())
                        }
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(row.channel.name).font(.caption.bold()).lineLimit(2)
                        if let health {
                            AppleChannelHealthDot(indicator: health)
                                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play \(row.channel.name)")
            .accessibilityValue(health?.accessibilityLabel ?? "")
            .accessibilityIdentifier("guide.play.\(row.id)")
            .contextMenu {
                AppleChannelQuickActions(channel: row.channel)
                Button("Play", systemImage: "play.fill", action: onSelect)
                Button(isFavorite ? "Remove from Favorites" : "Add to Favorites",
                       systemImage: isFavorite ? "heart.fill" : "heart", action: onToggleFavorite)
                if let onShowHealth {
                    Button("Channel Info", systemImage: "info.circle", action: onShowHealth)
                }
            }
            Button(action: onToggleFavorite) {
                Image(systemName: isFavorite ? "heart.fill" : "heart")
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("\(isFavorite ? "Remove" : "Add") \(row.channel.name) \(isFavorite ? "from" : "to") favorites")
            .accessibilityIdentifier("guide.favorite.\(row.id)")
        }
        .padding(.leading, 8)
    }
}

private struct GuideScheduleRow: View, Equatable {
    let row: AppleGuideRowModel
    let cellWidth: CGFloat
    let height: CGFloat
    let scrollState: GuideScrollState
    let onSelect: () -> Void
    /// A past programme the channel's archive still holds.
    var onSelectSpan: (AppleGuideProgrammeSpan) -> Void = { _ in }
    
    nonisolated static func == (lhs: GuideScheduleRow, rhs: GuideScheduleRow) -> Bool {
        lhs.row == rhs.row && lhs.cellWidth == rhs.cellWidth && lhs.height == rhs.height
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(row.spans) { cell in
                Button(action: cell.isCatchUp ? { onSelectSpan(cell) } : onSelect) {
                    GuideProgrammeTitle(cell: cell, cellWidth: cellWidth, height: height, scrollState: scrollState)
                    .background(Color.white.opacity(cell.isNow ? 0.12 : 0.06))
                    .overlay(Rectangle().stroke(.white.opacity(0.08), lineWidth: 1))
                    .clipped()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(row.channel.name), \(cell.title)" + (cell.isCatchUp ? ", available to watch" : ""))
                .contextMenu {
                    if let start = cell.airStart, let end = cell.airEnd,
                       AppleIPTVCatchUp.canStartOver(AppleIPTVProgramme(id: cell.id, channelID: row.channel.id,
                           title: cell.title, subtitle: cell.subtitle, description: nil,
                           start: start, end: end, category: nil, isLive: false), on: row.channel) {
                        Button("Start Over") { onSelectSpan(cell) }
                            .accessibilityIdentifier("guide.startOver")
                    }
                    AppleProgrammeReminderAction(channel: row.channel, title: cell.title, start: cell.airStart, end: cell.airEnd)
                }
            }
        }
    }
}

/// The programme canvas starts at the rail's right edge even after scrolling.
/// Its mask observes scrolling without rebuilding the programme projection.
private struct GuideProgrammeClip: View {
    let scrollState: GuideScrollState
    var leadingWidth: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            let leading = min(proxy.size.width, leadingWidth + scrollState.horizontalOffset)
            Rectangle()
                .frame(width: max(0, proxy.size.width - leading), height: proxy.size.height)
                .offset(x: leading)
        }
    }
}

/// Keep the first visible clock label wholly to the right of Channels.
private struct GuideTimelineHeader: View {
    let slots: [AppleGuideGridHeaderSlot]
    let cellWidth: CGFloat
    let scrollState: GuideScrollState

    var body: some View {
        let offset = scrollState.horizontalOffset
        let first = min(max(0, Int(offset / cellWidth)), max(0, slots.count - 1))
        ZStack(alignment: .leading) {
            HStack(spacing: 0) {
                ForEach(Array(slots.enumerated()), id: \.element.id) { index, slot in
                    Text(slot.label)
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(width: cellWidth, height: 36, alignment: .leading)
                        .opacity(CGFloat(index) * cellWidth >= offset + 96 ? 1 : 0)
                }
            }
            if !slots.isEmpty {
                Text(slots[first].label)
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.leading, 8)
                    .frame(width: 96, height: 36, alignment: .leading)
                    .background(Color.black)
                    .offset(x: offset)
            }
        }
        .background(Color.black)
    }
}

/// A partly visible programme keeps its title beside the pinned channel rail.
private struct GuideProgrammeTitle: View {
    let cell: AppleGuideProgrammeSpan
    let cellWidth: CGFloat
    let height: CGFloat
    let scrollState: GuideScrollState

    var body: some View {
        let width = cellWidth * CGFloat(cell.width)
        let inset = CGFloat(AppleGuideGridModel.visibleTitleInset(
            start: Double(cellWidth) * cell.startOffset, width: Double(width),
            scrollOffset: Double(scrollState.horizontalOffset)))
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                if cell.isCatchUp {
                    Image(systemName: "arrow.counterclockwise").font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary).accessibilityHidden(true)
                }
                Text(cell.title).font(.caption.bold()).lineLimit(2)
            }
            if let subtitle = cell.subtitle {
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(8)
        .frame(width: max(0, width - inset), height: height, alignment: .topLeading)
        .frame(width: width, height: height, alignment: .trailing)
        .clipped()
    }
}
