import SwiftUI

/// The progress bar, episode artwork and caption a Continue Watching still displays.
struct AppleContinueWatchingTileInfo: Codable, Equatable, Sendable {
    var progress: Double?
    var subtitle: String
    var episode: AppleMediaEpisode? = nil
    var title: String? = nil

    static func make(type: String, saved: ApplePlaybackProgress?, recordProgress: Double?,
                     episode: AppleMediaEpisode? = nil, isNext: Bool = false) -> Self {
        let fraction = isNext ? nil : AppleContinueWatchingResolver.progress(
            isSeries: type == "series" && episode == nil, saved: saved, recordProgress: recordProgress)
        let partID = isNext ? episode?.id : saved?.partID
        let fallback = AppleContinueWatchingCaption.subtitle(type: type, partID: partID,
            episode: episode, isNext: isNext)
        let line = isNext ? nil : saved.flatMap {
            AppleContinueWatchingCaption.tvLine(type: type, partID: partID,
                position: $0.position, duration: $0.duration, episode: episode)
        }
        return Self(progress: fraction, subtitle: line ?? fallback, episode: episode)
    }
}

/// A 16:9 still with progress on its artwork and a compact caption below.
/// The caption menu and the still's context menu expose the same title actions.
struct AppleContinueWatchingTile<Destination: View>: View {
    let item: AppleCatalogItem
    let info: AppleContinueWatchingTileInfo
    let isInList: Bool
    let onOpenTitle: () -> Void
    let onToggleList: () -> Void
    let onRemove: () -> Void
    @ViewBuilder let destination: () -> Destination
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.appleDiscoverRows) private var rowStyle

    var body: some View {
        Group {
            if rowStyle != nil {
                captionedTile
            } else {
                NavigationLink(destination: destination) {
                    AppleCatalogCard(item: item, sizing: .continueWatching, progress: info.progress,
                                     resumeCaption: info.subtitle, resumeStillURL: info.episode?.thumbnailURL,
                                     resumeTitle: info.title)
                }
                .accessibilityValue(info.subtitle)
                .contextMenu {
                    Button("Remove from Continue Watching", systemImage: "xmark.circle", action: onRemove)
                }
            }
        }
    }

    private var captionedTile: some View {
        let style = rowStyle ?? .phone
        return VStack(alignment: .leading, spacing: 6) {
            NavigationLink(destination: destination) {
                AppleCatalogCard(item: item, sizing: .continueWatching, progress: info.progress,
                                 resumeStillURL: info.episode?.thumbnailURL, resumeTitle: info.title)
            }
            .accessibilityValue(info.subtitle)
            .contextMenu { actions }
            HStack(alignment: .top, spacing: 4) {
                Text(info.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                Spacer(minLength: 0)
                Menu {
                    actions
                } label: {
                    Image(systemName: AppleSemanticAction.more.symbol)
                        .font(style.menuGlyphFont)
                        .foregroundStyle(.white.opacity(0.4))
                        .frame(width: 44, height: 32)
                        .contentShape(.rect)
                }
                .appleBareMenu()
                .accessibilityLabel("More for \(item.name)")
                .padding(.trailing, -12)
                .appleHoverAffordance()
            }
            .frame(width: style.stillWidth, alignment: .leading)
        }
    }

    @ViewBuilder
    private var actions: some View {
        Button(item.type == "movie" ? "Go to Movie" : "Go to Show", systemImage: AppleSemanticAction.info.symbol,
               action: onOpenTitle)
        Button(AppleSemanticAction.myList(saved: isInList).label,
               systemImage: AppleSemanticAction.myList(saved: isInList).symbol, action: onToggleList)
        Button("Remove from Continue Watching", systemImage: "xmark.circle", action: onRemove)
    }
}
