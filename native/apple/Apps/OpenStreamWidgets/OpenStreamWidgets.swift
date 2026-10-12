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
}

/// How many posters each family shows — and therefore how many the provider
/// fetches and how wide each one is. The view and the provider must agree, or
/// the widget fetches art it never draws.
enum ContinueWatchingLayout {
    static func visibleCount(for family: WidgetFamily) -> Int {
        switch family {
        case .systemSmall: 1
        case .systemMedium: 3
        default: 6
        }
    }
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
            completion(entry(artwork: [:]))
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
        let entry = entry(artwork: [:])
        let visible = Array(entry.items.prefix(ContinueWatchingLayout.visibleCount(for: layout.family)))
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

    private func entry(artwork: [String: Data]) -> ContinueWatchingEntry {
        let snapshot = reader.read()
        return ContinueWatchingEntry(
            date: .now,
            items: snapshot?.continueWatching ?? [],
            artwork: artwork,
            emptyState: .state(hasSnapshot: snapshot != nil)
        )
    }
}

struct ContinueWatchingWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ContinueWatchingEntry

    private var visibleCount: Int { ContinueWatchingLayout.visibleCount(for: family) }

    var body: some View {
        Group {
            if entry.items.isEmpty {
                empty
            } else {
                content
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
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

    @ViewBuilder
    private var content: some View {
        if family == .systemSmall, let item = entry.items.first {
            poster(item)
        } else {
            HStack(spacing: 8) {
                ForEach(entry.items.prefix(visibleCount), id: \.id) { item in
                    poster(item)
                }
            }
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
    }
}

@main
struct OpenStreamWidgets: WidgetBundle {
    var body: some Widget {
        ContinueWatchingWidget()
        OpenStreamDownloadActivity()
    }
}
