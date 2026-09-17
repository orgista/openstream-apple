import SwiftUI

/// A lazy schedule with one shared timeline and a pinned channel rail.
public struct AppleIPTVGuideGridView: View {
    let channels: [AppleIPTVChannel]
    let guide: AppleIPTVGuide
    let entries: [AppleChannelLineupEntry]
    let favoriteIDs: Set<String>
    let onSelect: (AppleIPTVChannel) -> Void
    let onToggleFavorite: (String) -> Void
    let onVisibleChannels: (Set<String>) async -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var rows: [AppleGuideChannel] = []
    @State private var horizontalOffset: CGFloat = 0
    @State private var visibleIDs = Set<String>()
    @ScaledMetric(relativeTo: .body) private var rowHeight = 76.0

    public init(channels: [AppleIPTVChannel], guide: AppleIPTVGuide, entries: [AppleChannelLineupEntry],
                favoriteIDs: Set<String>, onSelect: @escaping (AppleIPTVChannel) -> Void,
                onToggleFavorite: @escaping (String) -> Void,
                onVisibleChannels: @escaping (Set<String>) async -> Void) {
        self.channels = channels
        self.guide = guide
        self.entries = entries
        self.favoriteIDs = favoriteIDs
        self.onSelect = onSelect
        self.onToggleFavorite = onToggleFavorite
        self.onVisibleChannels = onVisibleChannels
    }

    private let railWidth: CGFloat = 144
    private let cellWidth: CGFloat = 160

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let window = AppleGuideChannelProjection.window(day: context.date, now: context.date)
            let header = AppleGuideGridModel.build(channels: [], programmes: [:], window: window,
                slotWidthMinutes: 30, now: context.date)
            let timelineWidth = CGFloat(window.duration / 1800) * cellWidth
            VStack(spacing: 0) {
                if rows.isEmpty {
                    ContentUnavailableView("No Channels", systemImage: "tv")
                } else if dynamicTypeSize.isAccessibilitySize {
                    accessibleSchedule(window: window)
                } else {
                    GeometryReader { geometry in
                        ScrollView(.horizontal, showsIndicators: false) {
                            ScrollView(.vertical, showsIndicators: false) {
                                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                                    Section {
                                        ForEach(rows) { row in
                                            HStack(spacing: 0) {
                                                GuideChannelRail(row: row, isFavorite: favoriteIDs.contains(row.id),
                                                    onSelect: { onSelect(row.channel) }, onToggleFavorite: { onToggleFavorite(row.id) })
                                                    .frame(width: railWidth, height: rowHeight)
                                                    .background(Color.black)
                                                    .offset(x: horizontalOffset)
                                                    .zIndex(1)
                                                GuideScheduleRow(channel: row.channel, guide: guide, window: window,
                                                    now: context.date, cellWidth: cellWidth, height: rowHeight,
                                                    onSelect: { onSelect(row.channel) })
                                            }
                                            .onAppear { visibleIDs.insert(row.id) }
                                            .onDisappear { visibleIDs.remove(row.id) }
                                        }
                                    } header: {
                                        HStack(spacing: 0) {
                                            // 8 pt is `GuideChannelRail`'s own
                                            // leading inset; without it this
                                            // header sat hard against the screen
                                            // edge while every channel name
                                            // under it was indented.
                                            Text("Channels").font(.caption.bold())
                                                .padding(.leading, 8)
                                                .frame(width: railWidth, height: 36, alignment: .leading)
                                                .background(Color.black)
                                                .offset(x: horizontalOffset).zIndex(1)
                                            HStack(spacing: 0) {
                                                ForEach(header.headerSlots) { slot in
                                                    Text(slot.time, format: .dateTime.hour().minute())
                                                        .font(.caption).foregroundStyle(.secondary)
                                                        .frame(width: cellWidth, height: 36, alignment: .leading)
                                                }
                                            }
                                            .background(Color.black)
                                    }
                                }
                            }
                            }
                            .scrollIndicators(.hidden)
                            .frame(width: railWidth + timelineWidth, height: geometry.size.height)
                        }
                        .scrollIndicators(.hidden)
                        .onScrollGeometryChange(for: CGFloat.self) { max(0, $0.contentOffset.x) } action: { _, offset in
                            horizontalOffset = offset
                        }
                    }
                }
            }
        }
        .background(Color.black)
        .task(id: projectionInput) {
            let input = projectionInput
            let projected = await Task.detached(priority: .userInitiated) {
                AppleGuideChannelProjection.rows(channels: input.channels, entries: input.entries,
                    favoriteIDs: input.favoriteIDs, favoritesOnly: false, sortByNumber: true)
            }.value
            guard !Task.isCancelled else { return }
            rows = projected
        }
        .task(id: visibleIDs) {
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            await onVisibleChannels(visibleIDs)
        }
    }

    private func accessibleSchedule(window: DateInterval) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top, spacing: 12) {
                            Button { onSelect(row.channel) } label: {
                                Text((row.number.map { "\($0) · " } ?? "") + row.channel.name)
                                    .font(.headline).multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Play \(row.channel.name)")
                            Button { onToggleFavorite(row.id) } label: {
                                Image(systemName: favoriteIDs.contains(row.id) ? "heart.fill" : "heart")
                                    .frame(minWidth: 44, minHeight: 44)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(favoriteIDs.contains(row.id) ? "Remove" : "Add") \(row.channel.name) \(favoriteIDs.contains(row.id) ? "from" : "to") favorites")
                        }
                        let programmes = guide.programmes(channelID: row.id, in: window)
                        if programmes.isEmpty { Text("No information").foregroundStyle(.secondary) }
                        ForEach(programmes) { programme in
                            Button { onSelect(row.channel) } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(programme.start, format: .dateTime.hour().minute()).font(.caption)
                                    Text(programme.title).font(.body)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12).background(AppleDesignTokens.surface)
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

    private var projectionInput: GuideProjectionInput {
        GuideProjectionInput(channels: channels, entries: entries, favoriteIDs: favoriteIDs)
    }
}

private struct GuideProjectionInput: Equatable, Sendable {
    let channels: [AppleIPTVChannel]
    let entries: [AppleChannelLineupEntry]
    let favoriteIDs: Set<String>
}

private struct GuideChannelRail: View {
    let row: AppleGuideChannel
    let isFavorite: Bool
    let onSelect: () -> Void
    let onToggleFavorite: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onSelect) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        AppleRemoteImage(url: row.channel.logoURL, contentMode: .fit, placeholderSystemImage: "")
                            .frame(width: 34, height: 24)
                        // A channel number is an identifier, not a quantity:
                        // `.number` applies the locale's thousands grouping, so
                        // channel 1001 drew as "1,001" here while the rail's own
                        // label (which interpolates) drew "1001". Owner B17.
                        if let number = row.number {
                            Text(number, format: AppleChannelNumberFormat.style)
                                .font(.caption.monospacedDigit())
                        }
                    }
                    Text(row.channel.name).font(.caption.bold()).lineLimit(2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play \(row.channel.name)")
            .accessibilityIdentifier("guide.play.\(row.id)")
            Button(action: onToggleFavorite) {
                Image(systemName: isFavorite ? "heart.fill" : "heart")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(isFavorite ? AppleDesignTokens.brandAccent : .secondary)
            .accessibilityLabel("\(isFavorite ? "Remove" : "Add") \(row.channel.name) \(isFavorite ? "from" : "to") favorites")
            .accessibilityIdentifier("guide.favorite.\(row.id)")
        }
        .padding(.leading, 8)
    }
}

private struct GuideScheduleRow: View {
    let channel: AppleIPTVChannel
    let guide: AppleIPTVGuide
    let window: DateInterval
    let now: Date
    let cellWidth: CGFloat
    let height: CGFloat
    let onSelect: () -> Void

    var body: some View {
        let result = AppleGuideGridModel.build(channels: [channel.id],
            programmes: [channel.id: guide.programmes(channelID: channel.id, in: window)],
            window: window, slotWidthMinutes: 30, now: now)
        HStack(spacing: 0) {
            ForEach(result.rows.first?.cells ?? []) { cell in
                Button(action: onSelect) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(cell.title).font(.caption.bold()).lineLimit(2)
                        if let subtitle = cell.subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    .padding(8)
                    .frame(width: cellWidth * CGFloat(cell.columnSpan), height: height, alignment: .topLeading)
                    .background(cell.start <= now && cell.end > now ? AppleDesignTokens.brandAccent.opacity(0.14) : AppleDesignTokens.surface)
                    .overlay(Rectangle().stroke(.white.opacity(0.08), lineWidth: 1))
                    .clipped()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(channel.name), \(cell.title)")
            }
        }
        .overlay(alignment: .leading) {
            if let offset = result.nowOffset {
                Rectangle().fill(AppleDesignTokens.brandAccent).frame(width: 2)
                    .offset(x: CGFloat(offset) * cellWidth).allowsHitTesting(false).accessibilityHidden(true)
            }
        }
    }
}
