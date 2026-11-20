import SwiftUI

/// Provider-only libraries use the same home carousel and billboard as local libraries.
struct AppleXtreamLibraryHero: View {
    let items: [AppleCatalogItem]
    let sourceStore: AppleSourceStore
    let mediaIndex: AppleMediaIndexStore
    let settings: AppleSettingsStore
    let openSettings: () -> Void
    let viewportSize: CGSize
    let phoneLayout: AppleHomePhoneHeroLayout
    let wideLayout: AppleMacHeroLayout
    @State private var selectedItem: AppleCatalogItem?
    @State private var autoPlay = false
    @State private var showsDetails = false
    @Environment(\.appleTabToolbar) private var tabToolbar

    var body: some View {
        AppleHomeHeroCarousel(pageIDs: items.map(\.id), items: items, wordmarks: items.map(\.logoURL),
            viewportSize: viewportSize, phoneLayout: phoneLayout, wideLayout: wideLayout) { index, failed, mode, count, shown, tv in
            page(items[index], failed: failed, mode: mode, count: count, index: shown, tv: tv)
        }
        .navigationDestination(isPresented: $showsDetails) {
            if let item = selectedItem, let reference = AppleXtreamReference.parse(item.mediaID),
               let source = AppleXtreamLibraryStore.shared.source(reference) {
                AppleCatalogItemDetailView(item: item, source: source, mediaIndex: mediaIndex,
                    playbackSources: sourceStore.sources, metadataConfiguration: settings.tmdbConfiguration,
                    settings: settings,
                    openSettings: openSettings, initialAutoPlay: autoPlay, tabToolbar: tabToolbar)
                    .environment(\.appleDiscoverRows, nil)
            }
        }
    }

    @ViewBuilder private func page(_ item: AppleCatalogItem, failed: Bool, mode: AppleHomePresentationPolicy.Hero,
                                  count: Int, index: Int, tv: AppleHomeTVHeroContext?) -> some View {
        if let reference = AppleXtreamReference.parse(item.mediaID) {
            let record = AppleMediaIngestion.catalogRecord(instanceID: reference.sourceID, item: item)
            AppleHomeBillboard(item: item, sources: sourceStore.sources, progressID: record.id,
                preferredSourceID: reference.sourceID, onPlay: { select(item, play: true) },
                onOpenDetails: { select(item, play: false) }, settings: settings, viewportSize: viewportSize,
                wordmark: failed ? nil : item.logoURL, rotationCount: count, rotationIndex: index,
                phone: mode == .phone ? .init(artHeight: phoneLayout.artHeight, copyFadeLine: phoneLayout.topInset) : nil,
                mac: mode == .mac || mode == .pad ? .init(layout: wideLayout) : nil,
                tv: tv.map { .init(cycle: $0.cycle) }) { button, perform in
                AppleHomeHeroActions(mode: mode, viewportSize: viewportSize, button: button,
                    isInList: mediaIndex.record(id: record.id)?.isFavorite ?? false, tv: tv,
                    onPlay: perform, onToggleList: { toggleList(record) }, onDetails: { select(item, play: false) })
            }
        }
    }

    private func select(_ item: AppleCatalogItem, play: Bool) {
        selectedItem = item
        autoPlay = play
        showsDetails = true
    }

    private func toggleList(_ record: AppleMediaRecord) {
        Task {
            let favorite = mediaIndex.record(id: record.id)?.isFavorite ?? false
            if mediaIndex.record(id: record.id) == nil { try? await mediaIndex.upsert(record) }
            try? await mediaIndex.setFavorite(!favorite, recordID: record.id)
        }
    }
}
