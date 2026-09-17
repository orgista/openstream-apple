import OpenStreamApple
import SwiftUI
import WidgetKit

/// Continue Watching on the Home Screen.
///
/// The widget is a separate process with no access to the app's container, so
/// everything here comes from the snapshot the app writes into the shared app
/// group — the same file Top Shelf reads on Apple TV. No network, no fetching:
/// a widget that waits on a request draws a placeholder instead of content.
struct ContinueWatchingEntry: TimelineEntry {
    let date: Date
    let items: [AppleTopShelfSnapshot.Item]
    /// Distinguishes "you have finished everything" from "nothing was ever
    /// published", which the widget used to report identically.
    let emptyState: AppleWidgetEmptyState
}

struct ContinueWatchingProvider: TimelineProvider {
    private let reader = AppleTopShelfSnapshotReader()

    func placeholder(in context: Context) -> ContinueWatchingEntry {
        ContinueWatchingEntry(date: .now, items: [], emptyState: .nothingInProgress)
    }

    func getSnapshot(in context: Context, completion: @escaping (ContinueWatchingEntry) -> Void) {
        completion(entry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ContinueWatchingEntry>) -> Void) {
        // The app reloads timelines whenever it rewrites the snapshot, so this
        // interval is only a backstop for a device the app has not run on in a
        // while — not the mechanism that keeps the widget current.
        completion(Timeline(entries: [entry()], policy: .after(.now.addingTimeInterval(60 * 60))))
    }

    private func entry() -> ContinueWatchingEntry {
        let snapshot = reader.read()
        return ContinueWatchingEntry(
            date: .now,
            items: snapshot?.continueWatching ?? [],
            emptyState: .state(hasSnapshot: snapshot != nil)
        )
    }
}

struct ContinueWatchingWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ContinueWatchingEntry

    private var visibleCount: Int {
        switch family {
        case .systemSmall: 1
        case .systemMedium: 3
        default: 6
        }
    }

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
                ZStack {
                    Color.secondary.opacity(0.18)
                    if let url = item.artworkURL {
                        // `AppleSystemArtworkPolicy` has already restricted this
                        // to a plain https URL on a trusted host — a widget
                        // renders outside the app's sandbox.
                        AsyncImage(url: url) { image in
                            image.resizable().aspectRatio(contentMode: .fill)
                        } placeholder: {
                            Color.clear
                        }
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
