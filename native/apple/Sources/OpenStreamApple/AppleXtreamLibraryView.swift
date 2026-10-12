import SwiftUI

struct AppleXtreamLibrarySections: View {
    let sourceStore: AppleSourceStore
    let mediaIndex: AppleMediaIndexStore
    let settings: AppleSettingsStore
    let openSettings: () -> Void
    var accessory: AnyView? = nil
    @AppStorage("openstream.library.sort") private var sort = AppleLibrarySort.added
    @State private var library = AppleXtreamLibraryStore.shared
    var body: some View {
        if !library.continueWatching.isEmpty {
            AppleHomeShelf(title: "Continue Watching", headingIdentifier: "library.xtream.continue") {
                ForEach(library.continueWatching) { item in
                    AppleXtreamTitleLink(item: item, sourceStore: sourceStore, mediaIndex: mediaIndex,
                        settings: settings, openSettings: openSettings, showsProgress: true)
                }
            } destination: {
                List(library.continueWatching) { item in
                    AppleXtreamTitleLink(item: item, sourceStore: sourceStore, mediaIndex: mediaIndex,
                        settings: settings, openSettings: openSettings, showsProgress: true)
                }.navigationTitle("Continue Watching")
                    .task { library.refreshProgress() }
            }
        }
        ForEach(library.failures.keys.sorted(by: { $0.uuidString < $1.uuidString }), id: \.self) { id in
            if let message = library.failures[id] {
                Label(message, systemImage: "exclamationmark.triangle").padding(.horizontal, 16)
                    .accessibilityIdentifier("library.xtream.failure")
            }
        }
        ForEach(library.shelves.filter { !$0.preview.isEmpty }) { shelf in
            AppleXtreamLibraryShelf(shelf: shelf, sort: sort, accessory: shelf.id == library.shelves.first(where: { !$0.preview.isEmpty })?.id ? accessory : nil, sourceStore: sourceStore,
                mediaIndex: mediaIndex, settings: settings, openSettings: openSettings)
        }
    }
}

struct AppleXtreamTitleLink: View {
    let item: AppleCatalogItem
    let sourceStore: AppleSourceStore
    let mediaIndex: AppleMediaIndexStore
    let settings: AppleSettingsStore
    let openSettings: () -> Void
    var showsProgress = false
    @Environment(\.appleTabToolbar) private var tabToolbar
    @State private var showsDetails = false
    private var record: AppleMediaRecord? {
        guard let reference = AppleXtreamReference.parse(item.mediaID) else { return nil }
        return AppleMediaIngestion.catalogRecord(instanceID: reference.sourceID, item: item)
    }
    private var isInList: Bool { record.flatMap { mediaIndex.record(id: $0.id) }?.isFavorite ?? false }

    var body: some View {
        Group {
            if let reference = AppleXtreamReference.parse(item.mediaID), let source = AppleXtreamLibraryStore.shared.source(reference) {
                Group {
                    if showsProgress, let record {
                        AppleContinueWatchingTile(item: item,
                            info: .live(type: item.type, recordID: record.id, recordProgress: nil, store: ApplePlaybackStore()),
                            isInList: isInList, onOpenTitle: { showsDetails = true }, onToggleList: toggleList, onRemove: remove) {
                            detail(source)
                        }
                    } else {
                        NavigationLink { detail(source) } label: { AppleCatalogCard(item: item) }

                    }
                }
                .navigationDestination(isPresented: $showsDetails) { detail(source) }

            }
        }
        .appleCatalogCardButtonStyle()
        .accessibilityIdentifier("library.xtream.title.\(item.name)")
    }

    private func detail(_ source: AppleSource) -> some View {
        AppleCatalogItemDetailView(item: item, source: source, mediaIndex: mediaIndex,
            playbackSources: sourceStore.sources, metadataConfiguration: settings.tmdbConfiguration,
            gatewayConfig: nil, playbackResolver: AppleStremioPlaybackResolver(), settings: settings,
            openSettings: openSettings, tabToolbar: tabToolbar)
            .environment(\.appleDiscoverRows, nil)
    }

    private func toggleList() {
        guard let record else { return }
        Task {
            let favorite = mediaIndex.record(id: record.id)?.isFavorite ?? false
            if mediaIndex.record(id: record.id) == nil { try? await mediaIndex.upsert(record) }
            try? await mediaIndex.setFavorite(!favorite, recordID: record.id)
        }
    }

    private func remove() {
        guard let record else { return }
        ApplePlaybackStore().removeFromContinueWatching(mediaID: record.id)
        AppleXtreamLibraryStore.shared.refreshProgress()
    }

}

struct AppleXtreamCategoryView: View {
    let shelf: AppleXtreamLibraryStore.Shelf
    let sourceStore: AppleSourceStore
    let mediaIndex: AppleMediaIndexStore
    let settings: AppleSettingsStore
    let openSettings: () -> Void
    @AppStorage("openstream.library.sort") private var sort = AppleLibrarySort.added
    @State private var limit = AppleXtreamLibraryPolicy.pageSize
    @ScaledMetric(relativeTo: .body) private var columnWidth = 150.0

    private var columns: [GridItem] {
        #if os(tvOS)
        // A standard TV poster is 230 points wide; leave room for its focus lift.
        [GridItem(.adaptive(minimum: 260, maximum: 300))]
        #else
        let minimum = min(max(columnWidth, 150), 260)
        return [GridItem(.adaptive(minimum: minimum, maximum: max(220, minimum)))]
        #endif
    }
    private var displayedItems: [AppleCatalogItem] {
        let references = sort == .added ? Array(shelf.references.prefix(limit)) : shelf.references
        return Array(AppleLibraryCatalogSort.sorted(references.compactMap {
            AppleXtreamLibraryStore.shared.catalog($0)
        }, by: sort).prefix(limit))
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(displayedItems) { item in
                        AppleXtreamTitleLink(item: item, sourceStore: sourceStore, mediaIndex: mediaIndex,
                            settings: settings, openSettings: openSettings)
                }
            }.padding()
            if limit < shelf.references.count {
                Button("Show More", action: showMore).padding()
                    .accessibilityIdentifier("library.xtream.more")
            }
        }
        .scrollIndicators(AppleDesignTokens.scrollIndicatorVisibility)
        .navigationTitle(shelf.title)
        .task(id: shelf.id) { AppleXtreamLibraryStore.shared.refreshProgress() }
    }
    private func showMore() { limit = min(limit + AppleXtreamLibraryPolicy.pageSize, shelf.references.count) }
}
