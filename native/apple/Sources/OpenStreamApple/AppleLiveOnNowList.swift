#if os(iOS) || os(visionOS)
import SwiftUI

/// The Live tab's channel list on iPhone and iPad (owner items 7 and 8): one
/// row per channel with its logo, name and what is on now; the channel being
/// watched shows the system playing waveform, as Music marks the song playing.
/// The only thing on the Live tab that scrolls.
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
    var usesParamountStyle = false
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
                .listRowBackground(panel)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("live.sourceError")
            }
            ForEach(channels) { channel in
                row(channel)
            }
            if channels.isEmpty, showsEmptyText, sourceProblems.isEmpty {
                Text("No channels")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .listRowBackground(panel)
                    .listRowSeparator(.hidden)
            }
            if hiddenCount > 0 {
                Text("Showing \(channels.count) of \(channels.count + hiddenCount) channels")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(panel)
                    .listRowSeparator(.hidden)
                    .accessibilityIdentifier("live.cap.notice")
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.hidden)
        .background(panel)
        .environment(\.defaultMinListRowHeight, AppleDesignTokens.minimumActionSize)
        .task(id: appearedRevision) {
            guard !appeared.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let ids = appeared
            await onVisibleChannels(ids)
        }
        .accessibilityIdentifier("live.list")
    }

    /// The Paramount+ panel continues the category strip's flat colour under the rows.
    private var panel: Color { usesParamountStyle ? AppleLiveStagePolicy.phonePanel : .black }

    private func row(_ channel: AppleIPTVChannel) -> some View {
        let isFavorite = favoriteIDs.contains(channel.id)
        let programme = guide.nowAndNext(channelID: channel.id).now
        let title = programme?.title
        let isWatching = channel.id == currentChannelID
        return Button { onSelect(channel) } label: {
            AppleLiveOnNowRow(channel: channel, programme: programme,
                              isWatching: isWatching, usesParamountStyle: usesParamountStyle)
        }
        .buttonStyle(.plain)
        .appleHoverAffordance()
        .listRowBackground(usesParamountStyle && isWatching ? AppleDesignTokens.surface : panel)
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        .accessibilityLabel("Play \(channel.displayName)")
        .accessibilityValue(title ?? "")
        .accessibilityAddTraits(channel.id == currentChannelID ? .isSelected : [])
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
        .onDisappear {
            if appeared.remove(channel.id) != nil { appearedRevision &+= 1 }
        }
    }
}

private struct AppleLiveOnNowRow: View {
    let channel: AppleIPTVChannel
    let programme: AppleIPTVProgramme?
    let isWatching: Bool
    let usesParamountStyle: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: 12) {
            if !dynamicTypeSize.isAccessibilitySize {
                AppleLiveLogoMark(url: channel.logoURL,
                    height: usesParamountStyle ? AppleLiveStagePolicy.phoneLogoSize.height : 32,
                    maxWidth: usesParamountStyle ? AppleLiveStagePolicy.phoneLogoSize.width : 48,
                    channelName: channel.displayName)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(channel.displayName)
                    .font(.body)
                    .foregroundStyle(.white)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                Text(programme?.title ?? " ")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                if usesParamountStyle, let programme {
                    AppleLiveProgrammeLine(programme: programme,
                        lineHeight: AppleLiveStagePolicy.phoneProgrammeLineHeight)
                        .padding(.top, 4)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
            if isWatching {
                Image(systemName: "waveform")
                    .font(.body)
                    .foregroundStyle(.primary)
                    .symbolEffect(.variableColor.iterative)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, usesParamountStyle ? AppleDesignTokens.spacingSmall : 0)
        .frame(minHeight: usesParamountStyle ? AppleLiveStagePolicy.phoneChannelRowHeight : 60)
        .contentShape(.rect)
        .task(id: programme?.id) {
            if programme != nil { AppleLaunchMarks.record(.liveGuideShown) }
        }
    }
}
#endif
