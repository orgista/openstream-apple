#if !os(tvOS)
import SwiftUI

/// Search then Refresh, as `AppleTabToolbarPolicy` lists them for a tab: one
/// set of controls, so Discover's and Library's toolbars cannot drift apart.
struct AppleTabToolbar: ToolbarContent {
    let tab: OpenStreamTab
    /// The arrow turns while the tab reloads. Dimming was the only answer the
    /// button gave, and against cached content that is over in a frame
    /// (button crawl, 2026-09-19); a spinner in its place drew larger than
    /// the Search glyph beside it (owner, 2026-09-26), so the glyph stays and
    /// rotates instead.
    let isRefreshing: Bool
    let onSearch: () -> Void
    let onRefresh: () -> Void
    /// Keeps a pushed page's copy of these items apart from the tab's own.
    /// With the same ids at both levels, a title page pushed by a
    /// `NavigationLink` (a Discover poster, a search result) drew Back alone:
    /// its Search and Refresh were taken for the tab's, already placed
    /// (N49 #21). A page pushed by `navigationDestination` was unaffected.
    var scope = "tab"
    var isTitlePage = false

    var body: some ToolbarContent {
        // On the Mac, Refresh is a new item when it starts or stops: its toolbar
        // caches an item's view by identity, so on a pushed page (a title
        // page, N37) the busy state it was first given never went away. iOS
        // keeps one identity (`AppleTabToolbarPolicy.slotID`).
        ForEach(AppleTabToolbarPolicy.items(for: tab, isTitlePage: isTitlePage).map { Slot(scope: scope, item: $0, isRefreshing: $0 == .refresh && isRefreshing) }) { slot in
            let item = slot.item
            ToolbarItem(placement: Self.placement) {
                switch item {
                case .search:
                    Button(action: onSearch) {
                        Label("Search", systemImage: "magnifyingglass")
                    }
                    .accessibilityLabel("Search")
                    .appleVisionActionTarget()
                case .refresh:
                    Button(action: onRefresh) {
                        Label("Refresh", systemImage: "arrow.clockwise")
                            .symbolEffect(.rotate, options: .repeat(.continuous), isActive: isRefreshing)
                    }
                    .accessibilityLabel("Refresh")
                    .appleVisionActionTarget()
                    .disabled(isRefreshing)
                }
            }
        }
    }

    private struct Slot: Identifiable {
        let scope: String
        let item: AppleTabToolbarPolicy.Item
        let isRefreshing: Bool
        var id: String { AppleTabToolbarPolicy.slotID(scope: scope, item: item, isRefreshing: isRefreshing) }
    }

    private static var placement: ToolbarItemPlacement {
        #if os(visionOS)
        .bottomOrnament
        #else
        .primaryAction
        #endif
    }
}
#endif
