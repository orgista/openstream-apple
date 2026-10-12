import SwiftUI

/// What a Continue Watching still says: the progress bar, the "MIN LEFT"
/// pill and the line under the title.
struct AppleContinueWatchingTileInfo: Equatable {
    var progress: Double
    var remainingLabel: String?
    var subtitle: String

    @MainActor
    static func live(type: String, recordID: String, recordProgress: Double?,
                     store: ApplePlaybackStore) -> Self {
        let saved = store.progress(for: recordID)
        let fraction = AppleContinueWatchingResolver.progress(isSeries: type == "series", saved: saved,
                                                              recordProgress: recordProgress)
        return Self(
            progress: fraction ?? 0,
            remainingLabel: fraction == nil ? nil : saved.flatMap {
                AppleContinueWatchingCaption.remainingLabel(position: $0.position, duration: $0.duration)
            },
            subtitle: AppleContinueWatchingCaption.subtitle(type: type, partID: saved?.partID)
        )
    }
}

/// A2: a 16:9 still with the pill and bar on it, and under it the title, the
/// "Continue · S1, E3" line and a ⋯ menu of the actions the app already has
/// (the same actions are also the tile's long-press and right-click menu).
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
                    AppleCatalogCard(item: item, sizing: .continueWatching, progress: info.progress)
                }
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
                                 remainingLabel: info.remainingLabel)
            }
            .accessibilityValue([info.remainingLabel?.capitalized, info.subtitle].compactMap { $0 }.joined(separator: ", "))
            .contextMenu { actions }
            HStack(alignment: .top, spacing: 4) {
                VStack(alignment: .leading, spacing: 2) {
                    AppleWordClampedText(text: item.name, lines: dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                        .font(style.captionTitleFont)
                    Text(info.subtitle)
                        .font(style.captionMetaFont)
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                }
                Menu {
                    actions
                } label: {
                    Image(systemName: "ellipsis")
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
        Button(item.type == "movie" ? "Go to Movie" : "Go to Show", systemImage: "info.circle",
               action: onOpenTitle)
        Button(isInList ? "Remove from My List" : "Add to My List",
               systemImage: isInList ? "checkmark" : "plus", action: onToggleList)
        Button("Remove from Continue Watching", systemImage: "xmark.circle", action: onRemove)
    }
}

