import SwiftUI

struct AppleXtreamLibraryShelf: View {
    let shelf: AppleXtreamLibraryStore.Shelf
    let sort: AppleLibrarySort
    var accessory: AnyView? = nil
    let sourceStore: AppleSourceStore
    let mediaIndex: AppleMediaIndexStore
    let settings: AppleSettingsStore
    let openSettings: () -> Void
    @FocusState private var focusedItemID: String?

    private var items: [AppleCatalogItem] {
        sort == .added ? shelf.preview
            : AppleLibraryCatalogSort.sorted(shelf.references.compactMap { AppleXtreamLibraryStore.shared.catalog($0) }, by: sort)
    }

    var body: some View {
        AppleHomeShelf(title: shelf.title, accessory: accessory, headingIdentifier: "library.xtream.category.\(shelf.id)") {
            ForEach(items.prefix(24)) { item in
                AppleXtreamTitleLink(item: item, sourceStore: sourceStore, mediaIndex: mediaIndex,
                    settings: settings, openSettings: openSettings)
                    .focused($focusedItemID, equals: item.id)
            }
        } destination: {
            AppleXtreamCategoryView(shelf: shelf, sourceStore: sourceStore, mediaIndex: mediaIndex,
                settings: settings, openSettings: openSettings)
        }
        #if os(tvOS)
        .defaultFocus($focusedItemID, items.first?.id)
        .task(id: focusedItemID) {
            guard let focusedItemID, let item = items.first(where: { $0.id == focusedItemID }),
                  let reference = AppleXtreamReference.parse(item.mediaID) else { return }
            try? await Task.sleep(for: AppleMetadataPrefetcher.focusDwell)
            guard !Task.isCancelled else { return }
            _ = try? await AppleXtreamLibraryStore.shared.detail(reference)
        }
        #endif
    }
}
