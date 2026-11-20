import SwiftUI

struct AppleHomeServicePage<Destination: View>: View {
    let service: AppleStreamingService
    let sourceStore: AppleSourceStore
    let mediaServerLibrary: AppleMediaServerLibraryStore
    let settings: AppleSettingsStore
    @ViewBuilder let destination: (AppleCatalogItem, AppleSource) -> Destination
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selection = AppleHomeServices.MediaType.movies
    @State private var isPaging = false
    @State private var itemCache = AppleHomeServices.ItemCache()
    #if os(tvOS)
    private enum Focus: Hashable { case picker, item(String) }
    @FocusState private var focusedControl: Focus?
    #endif

    private var libraries: [AppleMediaServerLibraryStore.Shelf] {
        let enabled = Set(sourceStore.sources.filter { $0.isEnabled && $0.kind == .mediaServer }.map(\.id))
        return mediaServerLibrary.serviceLibraries.filter {
            enabled.contains($0.sourceID) && AppleHomeServices.service(in: $0.libraryName ?? "") == service
        }
    }

    var body: some View {
        let libraries = libraries
        let group = AppleHomeServices.Service(service: service, libraries: libraries)
        let types = group.mediaTypes
        let type = types.contains(selection) ? selection : types.first ?? .movies
        let items = itemCache.items(revision: mediaServerLibrary.contentRevision, libraries: libraries, type: type)
        GeometryReader { geometry in
            let layout = AppleHomeServiceLayout(width: geometry.size.width, regularWidth: horizontalSizeClass != .compact)
            ScrollView {
                VStack(alignment: .leading, spacing: layout.rowGap) {
                    #if os(tvOS)
                    Text(group.title(customNames: settings.homeRowNames))
                        .font(.system(size: 57, weight: .bold))
                        .accessibilityAddTraits(.isHeader)
                    #endif
                    if types.count > 1 { typePicker(types) }
                    posterGrid(items, layout: layout, libraries: libraries, type: type)
                }
                .padding(.horizontal, layout.inset)
                .padding(.vertical, layout.rowGap)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
            .scrollClipDisabled()
            .background(.background)
            #if os(tvOS)
            .defaultFocus($focusedControl, types.count > 1 ? .picker : items.first.map { .item($0.id) }, priority: .userInitiated)
            #endif
        }
        #if !os(tvOS)
        .navigationTitle(group.title(customNames: settings.homeRowNames))
        #endif
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.service.page.\(service.rawValue)")
        .task(id: libraries.map(\.id)) {
            for library in libraries { await mediaServerLibrary.refreshIfNeeded(shelfID: library.id) }
        }
    }

    private func typePicker(_ types: [AppleHomeServices.MediaType]) -> some View {
        Picker("Type", selection: $selection) {
            ForEach(types) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        #if !os(tvOS)
        .tint(.gray)
        #endif
        .accessibilityIdentifier("home.service.types")
        #if os(tvOS)
        .focused($focusedControl, equals: .picker)
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
        #endif
    }

    private func posterGrid(_ items: [AppleCatalogItem], layout: AppleHomeServiceLayout,
                            libraries: [AppleMediaServerLibraryStore.Shelf], type: AppleHomeServices.MediaType) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(layout.posterWidth), spacing: layout.columnGap, alignment: .top),
                                 count: layout.columnCount), alignment: .leading, spacing: layout.rowGap) {
            ForEach(items) { item in
                if let reference = AppleMediaServerItemReference.parse(item.mediaID),
                   let source = sourceStore.sources.first(where: { $0.id == reference.sourceID && $0.isEnabled && $0.kind == .mediaServer }) {
                    NavigationLink { destination(item, source) } label: {
                        AppleCatalogCard(item: item, width: layout.posterWidth)
                    }
                    .appleCatalogCardButtonStyle()
                    .accessibilityIdentifier("home.service.title.\(item.mediaID)")
                    #if os(tvOS)
                    .focused($focusedControl, equals: .item(item.id))
                    #endif
                    .task {
                        guard AppleCatalogPaging.isNearEnd(itemID: item.id, in: items) else { return }
                        await loadMore(libraries, type: type)
                    }
                }
            }
            if isPaging {
                ForEach(0..<layout.columnCount, id: \.self) { _ in
                    AppleDiscoverLoadingPoster(width: layout.posterWidth)
                        .accessibilityHidden(true)
                }
            }
        }
        .appleCatalogFocusSection()
        #if !os(tvOS)
        .environment(\.appleDiscoverRows, horizontalSizeClass != .compact ? .pad(contentWidth: layout.posterWidth * CGFloat(layout.columnCount)) : .phone)
        #else
        .environment(\.appleDiscoverRows, nil)
        #endif
    }

    private func loadMore(_ libraries: [AppleMediaServerLibraryStore.Shelf], type: AppleHomeServices.MediaType) async {
        guard !isPaging else { return }
        isPaging = true
        defer { isPaging = false }
        for library in libraries where (library.collectionType != .movies || type == .movies)
            && (library.collectionType != .tvshows || type == .shows) {
            guard !Task.isCancelled else { return }
            await mediaServerLibrary.loadMore(shelfID: library.id)
        }
    }
}
