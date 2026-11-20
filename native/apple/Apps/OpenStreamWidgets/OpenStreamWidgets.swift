import OpenStreamApple
import SwiftUI
import UIKit
import WidgetKit

/// Continue Watching on the Home Screen.
///
/// The widget is a separate process with no access to the app's container, so
/// the titles come from the snapshot the app writes into the shared app group —
/// the same file Top Shelf reads on Apple TV.
///
/// The posters cannot come from `AsyncImage`. A WidgetKit view is rendered once
/// into a static snapshot, and a fetch that resolves after that snapshot is
/// captured never draws: the widget shipped with a real title over a blank grey
/// square (owner's home screen, 2026-09-20). Artwork is therefore resolved in
/// the provider, before the entry exists, and the view only draws bytes it
/// already holds.
struct ContinueWatchingEntry: TimelineEntry {
    let date: Date
    let items: [AppleTopShelfSnapshot.Item]
    /// Poster thumbnails keyed by item id, already decoded to roughly the size
    /// they are drawn at. An id with no entry draws the brand mark.
    let artwork: [String: Data]
    /// Distinguishes "you have finished everything" from "nothing was ever
    /// published", which the widget used to report identically.
    let emptyState: AppleWidgetEmptyState
    var heroBackdrop: Data? = nil
    var heroWordmark: Data? = nil
}

struct ContinueWatchingProvider: TimelineProvider {
    private let reader = AppleTopShelfSnapshotReader()
    private let artwork = AppleWidgetArtworkStore()

    func placeholder(in context: Context) -> ContinueWatchingEntry {
        ContinueWatchingEntry(date: .now, items: [], artwork: [:], emptyState: .nothingInProgress)
    }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (ContinueWatchingEntry) -> Void) {
        // The gallery preview has to appear instantly, so it draws the titles
        // over the brand mark rather than waiting on any artwork.
        guard !context.isPreview else {
            completion(entry(artwork: [:], family: context.family, isPreview: true))
            return
        }
        let layout = Layout(context)
        Task { completion(await loadedEntry(layout)) }
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<ContinueWatchingEntry>) -> Void) {
        let layout = Layout(context)
        Task {
            // The app reloads timelines whenever it rewrites the snapshot, so
            // this interval is only a backstop for a device the app has not run
            // on in a while — not the mechanism that keeps the widget current.
            completion(Timeline(
                entries: [await loadedEntry(layout)],
                policy: .after(.now.addingTimeInterval(60 * 60))
            ))
        }
    }

    /// What the artwork load needs from the context, copied out before the
    /// Task: `TimelineProviderContext` is not Sendable, and Swift 6.4 rejects
    /// sending a closure that captures it (region-isolation error).
    struct Layout: Sendable {
        let family: WidgetFamily
        let widthInPoints: Double
        let scale: Double

        init(_ context: Context) {
            family = context.family
            widthInPoints = context.displaySize.width
            scale = Double(context.environmentVariants[\.displayScale]?.max() ?? 3)
        }
    }

    private func loadedEntry(_ layout: Layout) async -> ContinueWatchingEntry {
        let entry = entry(artwork: [:], family: layout.family)
        guard layout.family == .systemSmall else { return entry }
        let visible = Array(entry.items.prefix(1))
        guard !visible.isEmpty else { return entry }
        let pixelSize = AppleWidgetArtworkPolicy.pixelSize(
            widthInPoints: layout.widthInPoints,
            columns: visible.count,
            scale: layout.scale
        )
        return ContinueWatchingEntry(
            date: entry.date,
            items: entry.items,
            artwork: await artwork.thumbnails(for: visible, pixelSize: pixelSize),
            emptyState: entry.emptyState
        )
    }

    private func entry(artwork: [String: Data], family: WidgetFamily, isPreview: Bool = false) -> ContinueWatchingEntry {
        let snapshot = reader.read()
        let hero = family != .systemSmall && !isPreview ? snapshot?.widgetHero : nil
        let root = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppleTopShelfSnapshotWriter.appGroup)
        let matches = hero?.itemID == snapshot?.continueWatching.first?.id
        return ContinueWatchingEntry(
            date: .now,
            items: snapshot?.continueWatching ?? [],
            artwork: artwork,
            emptyState: .state(hasSnapshot: snapshot != nil),
            heroBackdrop: matches ? root.flatMap { AppleWidgetHeroArtworkStore.read(hero?.backdropFile, in: $0) } : nil,
            heroWordmark: matches ? root.flatMap { AppleWidgetHeroArtworkStore.read(hero?.wordmarkFile, in: $0) } : nil
        )
    }
}

struct ContinueWatchingWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.showsWidgetContainerBackground) private var showsBackground
    @Environment(\.widgetContentMargins) private var margins
    let entry: ContinueWatchingEntry

    private var isHero: Bool { family != .systemSmall && !entry.items.isEmpty }
    private var usesArtwork: Bool { renderingMode == .fullColor && showsBackground }

    var body: some View {
        Group {
            if entry.items.isEmpty {
                empty.padding(margins)
            } else if isHero, let item = entry.items.first {
                hero(item)
            } else if let item = entry.items.first {
                poster(item).padding(margins)
            }
        }
        .widgetURL(entry.items.first.map { $0.playURL ?? $0.displayURL })
        .containerBackground(for: .widget) {
            if isHero, usesArtwork, let data = entry.heroBackdrop, let image = UIImage(data: data) {
                ZStack {
                    GeometryReader { geometry in
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .clipped()
                    }
                    LinearGradient(stops: [
                        .init(color: .clear, location: 0.35),
                        .init(color: .black.opacity(0.65), location: 1),
                    ], startPoint: .top, endPoint: .bottom)
                }
            } else {
                Color(uiColor: .tertiarySystemFill)
            }
        }
    }

    /// Title and nothing else: a widget has no room for explanatory copy, and
    /// the app's standing rule is that empty states carry none.
    private var empty: some View {
        VStack(spacing: 6) {
            OpenStreamThreeBarMark()
                .frame(width: 34, height: 24)
            Text(entry.emptyState.message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func hero(_ item: AppleTopShelfSnapshot.Item) -> some View {
        Link(destination: item.playURL ?? item.displayURL) {
            VStack(alignment: .leading, spacing: 6) {
                Spacer(minLength: 0)
                if usesArtwork, entry.heroBackdrop != nil, let data = entry.heroWordmark, let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 220, maxHeight: family == .systemLarge ? 80 : 52, alignment: .bottomLeading)
                        .accessibilityLabel(item.title)
                } else {
                    Text(item.title)
                        .font(.system(.title2, weight: .black))
                        .lineLimit(family == .systemMedium ? 1 : 2)
                        .widgetAccentable()
                }
                resumeCue(item)
                    .font(.caption)
                    .lineLimit(family == .systemMedium ? 1 : 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(margins)
            .foregroundStyle(usesArtwork && entry.heroBackdrop != nil ? Color.white : Color.primary)
            .accessibilityElement(children: .combine)
        }
    }

    private func resumeCue(_ item: AppleTopShelfSnapshot.Item) -> Text {
        if let minutes = item.remainingMinutes {
            Text("Resume · \(minutes) min left")
        } else {
            Text("Continue Watching")
        }
    }

    private func poster(_ item: AppleTopShelfSnapshot.Item) -> some View {
        Link(destination: item.playURL ?? item.displayURL) {
            VStack(alignment: .leading, spacing: 4) {
                // The artwork is an overlay, not a stacked child: a poster
                // scaled to fill reports a size larger than it was offered, and
                // as a `ZStack` child that size becomes the tile's — which ate
                // the whole widget and pushed the title out of it. An overlay
                // draws over the surface without resizing it.
                Color.secondary.opacity(0.18)
                    .overlay {
                        if let data = entry.artwork[item.id], let image = UIImage(data: data) {
                            Image(uiImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } else {
                            // No network here: whatever the provider did not
                            // resolve in time is the brand mark, not a void.
                            OpenStreamThreeBarMark()
                                .frame(width: 28, height: 20)
                                .opacity(0.6)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(item.title)
                    .font(.caption2)
                    .lineLimit(1)
            }
        }
    }
}

struct ContinueWatchingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.orgista.openstream.widget.continue", provider: ContinueWatchingProvider()) { entry in
            ContinueWatchingWidgetView(entry: entry)
        }
        .configurationDisplayName("Continue Watching")
        .description("Pick up where you left off.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

@main
struct OpenStreamWidgets: WidgetBundle {
    var body: some Widget {
        ContinueWatchingWidget()
        OpenStreamDownloadActivity()
    }
}
