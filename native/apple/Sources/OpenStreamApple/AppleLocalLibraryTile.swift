import SwiftUI

struct AppleLocalLibraryTile: View {
    let group: AppleLibrarySeries
    let sourceStore: AppleSourceStore
    let mediaIndex: AppleMediaIndexStore
    let settings: AppleSettingsStore
    let openSettings: () -> Void
    let tabToolbar: AppleTabToolbarContext?
    var showsProgress = false
    @State private var library = AppleLocalLibraryStore.shared
    @State private var showsDetails = false
    @State private var continueWatchingInfo: AppleContinueWatchingTileInfo?

    private var item: AppleCatalogItem { library.catalogItem(for: group) }
    private var record: AppleMediaRecord? {
        guard let file = group.items.first,
              let source = library.sources.first(where: { $0.id == file.sourceID }) else { return nil }
        return AppleMediaIngestion.catalogRecord(instanceID: source.id, item: item)
    }
    private var isInList: Bool { record.flatMap { mediaIndex.record(id: $0.id) }?.isFavorite ?? false }
    var body: some View {
        Group {
            if showsProgress {
                AppleContinueWatchingTile(item: item,
                    info: continueWatchingInfo ?? .make(type: item.type, saved: nil, recordProgress: nil), isInList: isInList,
                    onOpenTitle: { showsDetails = true }, onToggleList: toggleList, onRemove: remove) { destination }
            } else {
                NavigationLink { destination } label: { AppleCatalogCard(item: item) }
            }
        }
        .environment(\.appleLibraryPoster, library.poster(for: group))
        .appleCatalogCardButtonStyle()
        #if os(iOS)
        .simultaneousGesture(TapGesture().onEnded {
            AppleDetailFillTimeline.navigationTap(title: item.name)
        })
        #endif
        .accessibilityIdentifier("library.title.\(group.parsed.title)")
        .navigationDestination(isPresented: $showsDetails) { destination }
        .task(id: "\(group.id)|\(library.contentRevision)|\(ApplePlaybackProgressFeed.shared.revision)|\(showsProgress)") {
            guard showsProgress else { return }
            continueWatchingInfo = library.continueWatchingInfo(for: group, store: ApplePlaybackStore())
        }
    }

    private var destination: some View {
        AppleLocalTitleDestination(group: group, sourceStore: sourceStore, mediaIndex: mediaIndex,
            settings: settings, openSettings: openSettings, tabToolbar: tabToolbar)
            .environment(\.appleDiscoverRows, nil)
            .environment(\.appleLibraryPoster, nil)
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
        let store = ApplePlaybackStore()
        for file in group.items { store.removeFromContinueWatching(mediaID: library.playbackID(file)) }
        library.refreshProgress()
    }
}
