#if os(iOS)
import SwiftUI

/// The Live tab's channel list on iPhone and iPad (owner items 7 and 8): one
/// row per channel with its logo, name and what is on now; the channel being
/// watched carries the only badge on the screen, WATCHING. No time grid, no
/// progress line under every row, no trailing glyph. The only thing on the
/// Live tab that scrolls.
struct AppleLiveOnNowList: View {
    struct SourceProblem: Identifiable, Equatable {
        let id: UUID
        let title: String
    }

    let channels: [AppleIPTVChannel]
    let guide: AppleIPTVGuide
    let guideRevision: Int
    let currentChannelID: String?
    let favoriteIDs: Set<String>
    let hiddenCount: Int
    /// False until the lineup has been sorted once, so "No channels" never
    /// flashes before the rows arrive.
    let showsEmptyText: Bool
    let sourceProblems: [SourceProblem]
    let onSelect: (AppleIPTVChannel) -> Void
    let onToggleFavorite: (String) -> Void
    let onHide: (AppleIPTVChannel) -> Void
    let onShowInfo: (AppleIPTVChannel) -> Void
    let onRetrySources: () -> Void
    let onVisibleChannels: (Set<String>) async -> Void

    @State private var appeared: Set<String> = []
    @State private var appearedRevision = 0

    var body: some View {
        List {
            ForEach(sourceProblems) { problem in
                HStack(spacing: 12) {
                    Text(problem.title)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Try Again", action: onRetrySources)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.primary)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .listRowBackground(Color.black)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("live.sourceError")
            }
            ForEach(channels) { channel in
                row(channel)
            }
            if channels.isEmpty, showsEmptyText {
                Text("No channels")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .listRowBackground(Color.black)
                    .listRowSeparator(.hidden)
            }
            if hiddenCount > 0 {
                Text("Showing \(channels.count) of \(channels.count + hiddenCount) channels")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.black)
                    .listRowSeparator(.hidden)
                    .accessibilityIdentifier("live.cap.notice")
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.hidden)
        .background(Color.black)
        .environment(\.defaultMinListRowHeight, 44)
        .task(id: appearedRevision) {
            guard !appeared.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let ids = appeared
            await onVisibleChannels(ids)
        }
        .accessibilityIdentifier("live.list")
    }

    private func row(_ channel: AppleIPTVChannel) -> some View {
        let isFavorite = favoriteIDs.contains(channel.id)
        let title = guide.nowAndNext(channelID: channel.id).now?.title
        return Button { onSelect(channel) } label: {
            AppleLiveOnNowRow(channel: channel, programmeTitle: title,
                              isWatching: channel.id == currentChannelID)
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.black)
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        .accessibilityLabel("Play \(channel.name)")
        .accessibilityValue([title, channel.id == currentChannelID ? "Watching" : nil]
            .compactMap { $0 }.joined(separator: ", "))
        .accessibilityIdentifier("guide.play.\(channel.id)")
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button { onToggleFavorite(channel.id) } label: {
                Label(isFavorite ? "Unfavorite" : "Favorite", systemImage: isFavorite ? "heart.slash" : "heart")
            }
            .tint(AppleDesignTokens.brandAccent)
        }
        .swipeActions(edge: .trailing) {
            Button { onHide(channel) } label: {
                Label("Hide", systemImage: "eye.slash")
            }
            .tint(.gray)
        }
        .contextMenu {
            Button { onToggleFavorite(channel.id) } label: {
                Label(isFavorite ? "Unfavorite" : "Favorite", systemImage: isFavorite ? "heart.slash" : "heart")
            }
            Button { onShowInfo(channel) } label: {
                Label("Channel Info", systemImage: "info.circle")
            }
            Button { onHide(channel) } label: {
                Label("Hide", systemImage: "eye.slash")
            }
        }
        .onAppear {
            if appeared.insert(channel.id).inserted { appearedRevision &+= 1 }
        }
    }
}

/// One On Now row: logo slot 48 × 32, name over programme, WATCHING pill.
private struct AppleLiveOnNowRow: View {
    let channel: AppleIPTVChannel
    let programmeTitle: String?
    let isWatching: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: 12) {
            if !dynamicTypeSize.isAccessibilitySize {
                AppleLiveLogoMark(url: channel.logoURL, height: 32, maxWidth: 48)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(channel.name)
                    .font(.body)
                    .foregroundStyle(.white)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                Text(programmeTitle ?? " ")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
            if isWatching {
                AppleLiveWatchingPill()
            }
        }
        .frame(minHeight: 60)
        .contentShape(.rect)
    }
}

/// The only badge on the Live screen, and the only pink besides the
/// favourite swipe: 11 pt bold, tracking 0.5, a 20 pt capsule.
struct AppleLiveWatchingPill: View {
    var body: some View {
        Text("WATCHING")
            .font(.system(size: 11, weight: .bold))
            .tracking(0.5)
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .frame(minHeight: 20)
            .background(Capsule().fill(AppleDesignTokens.brandAccent))
            .fixedSize()
            .accessibilityIdentifier("live.watching")
    }
}
#endif
