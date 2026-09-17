import SwiftUI
import AVFoundation
import ImageIO
#if os(iOS) || os(visionOS)
import Combine
import UIKit
import WebKit
#endif

func catalogConfigurationIdentity(_ sources: [AppleSource]) -> String {
    sources
        .filter { $0.kind == .stremio }
        .map { "\($0.id.uuidString)|\($0.configurationRevision)|\($0.isEnabled)" }
        .joined(separator: ";")
}

private func searchConfigurationIdentity(_ sources: [AppleSource]) -> String {
    sources
        .map { "\($0.id.uuidString)|\($0.configurationRevision)|\($0.isEnabled)|\($0.name)" }
        .joined(separator: ";")
}

@MainActor
private func applyCatalogRefreshHealth(
    reports: [AppleCatalogSourceRefreshReport],
    to sourceStore: AppleSourceStore
) {
    let validationDate = Date.now
    for report in reports {
        if let failureSummary = report.failureSummary {
            sourceStore.recordValidationFailure(
                id: report.sourceID,
                summary: failureSummary,
                at: validationDate
            )
        }
        guard report.successfulCatalogCount > 0 else { continue }
        let titleLabel = report.itemCount == 1 ? "title" : "titles"
        var summary = "Refreshed \(report.itemCount) \(titleLabel)"
        if report.failedCatalogCount > 0 {
            let catalogLabel = report.failedCatalogCount == 1 ? "catalog" : "catalogs"
            summary += " · \(report.failedCatalogCount) \(catalogLabel) unavailable"
        }
        sourceStore.recordValidationSuccess(
            id: report.sourceID,
            summary: summary,
            discoveredItemCount: report.itemCount,
            at: validationDate
        )
    }
}

@MainActor
struct AppleDiscoverView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var viewportSize: CGSize = .zero
    @State private var loadedCache = false
    @State private var showsSearch = false
    #if DEBUG && (os(visionOS) || os(tvOS) || os(iOS))
    @State private var visionReviewDetail = false
    @State private var visionReviewAutoPlay = false
    #endif
    @State private var catalogLookup = AppleCatalogSearchLookup()
    @State private var top10Week: AppleNetflixTop10Week?
    @State private var top10Error: String?
    @State private var library = AppleLocalLibraryStore.shared
    /// Wordmark art for the rotating heroes, keyed by media id. The prefetcher
    /// already warms these into the preview-assets cache for the home screen;
    /// the billboard simply never asked, which is why heroes only ever showed
    /// text (owner 2026-09-15).
    @State private var heroWordmarks: [String: URL] = [:]

    let catalogStore: AppleCatalogStore
    let sourceStore: AppleSourceStore
    let mediaIndex: AppleMediaIndexStore
    let router: AppleAppRouter
    let settings: AppleSettingsStore
    let openSettings: () -> Void
    private let playbackResolver: AppleStremioPlaybackResolver

    private struct IndexedCatalogItem: Identifiable {
        let record: AppleMediaRecord
        let item: AppleCatalogItem
        let source: AppleSource
        var id: String { record.id }
    }

    init(
        catalogStore: AppleCatalogStore,
        sourceStore: AppleSourceStore,
        mediaIndex: AppleMediaIndexStore,
        router: AppleAppRouter,
        settings: AppleSettingsStore,
        openSettings: @escaping () -> Void,
        playbackResolver: AppleStremioPlaybackResolver = AppleStremioPlaybackResolver()
    ) {
        self.catalogStore = catalogStore
        self.sourceStore = sourceStore
        self.mediaIndex = mediaIndex
        self.router = router
        self.settings = settings
        self.openSettings = openSettings
        self.playbackResolver = playbackResolver
    }

    private var visibleSections: [AppleCatalogSection] {
        let activeSourceIDs = Set(
            sourceStore.sources
                .filter(\.isEnabled)
                .map(\.id)
        )
        let sections = catalogStore.sections.filter {
            activeSourceIDs.contains($0.sourceID) && !$0.items.isEmpty
        }
        var seenTitles = Set<String>()
        return sections
            .sorted {
                let left = appleCatalogShelfTitle(sourceName: $0.sourceName, catalogType: $0.catalog.type, catalogName: $0.catalog.name)
                let right = appleCatalogShelfTitle(sourceName: $1.sourceName, catalogType: $1.catalog.type, catalogName: $1.catalog.name)
                let titleOrder = left.localizedCaseInsensitiveCompare(right)
                if titleOrder != .orderedSame { return titleOrder == .orderedAscending }

                // Metadata add-ons often expose several catalogs that map to
                // the same human-facing shelf. Keep Cinemeta's `top` catalog
                // as the representative section so Popular Movies/Shows are
                // deterministic instead of depending on concurrent refresh
                // completion order.
                let leftIsTop = $0.catalog.id.caseInsensitiveCompare("top") == .orderedSame
                let rightIsTop = $1.catalog.id.caseInsensitiveCompare("top") == .orderedSame
                if leftIsTop != rightIsTop { return leftIsTop }
                return $0.catalog.id.localizedCaseInsensitiveCompare($1.catalog.id) == .orderedAscending
            }
            .filter { seenTitles.insert(appleCatalogShelfTitle(sourceName: $0.sourceName, catalogType: $0.catalog.type, catalogName: $0.catalog.name)).inserted }
    }

    var body: some View {
        Group {
            if visibleSections.isEmpty && library.groups.isEmpty {
                AppleSourceEmptyState(
                    title: sourceStore.sources.isEmpty ? "No Sources" : "Nothing to Show",
                    actionTitle: "Open Settings",
                    action: openSettings
                )
                // The black ground was on the populated branch only, so an
                // empty Discover fell through to the tvOS system material —
                // measured rgb(39,41,37) against Library's rgb(0,0,0), and not
                // even flat: two points sampled two different values, because
                // it is a material. The owner saw it as "oled mode is only on
                // some tabs but not others" (2026-09-16).
                #if os(tvOS)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.ignoresSafeArea())
                #endif
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: sectionSpacing) {
                        // The billboard cycles through the candidates. Only
                        // this subtree re-renders on the tick; the shelves
                        // below it are untouched.
                        let heroes = featuredCandidates
                        if !heroes.isEmpty {
                            #if DEBUG
                            let _ = AppleLaunchClock.mark("discover.hero")
                            #endif
                            TimelineView(.periodic(from: .now, by: AppleHeroRotation.interval)) { context in
                                if let index = AppleHeroRotation.index(at: context.date, count: heroes.count) {
                                    featuredHero(heroes[index], rotationCount: heroes.count, rotationIndex: index)
                                        .padding(.horizontal, heroHorizontalPadding)
                                }
                            }
                            .task(id: heroes.map(\.item.mediaID).joined(separator: ",")) {
                                // The prefetch lands after the first pass, so
                                // look again shortly rather than only once.
                                await resolveHeroWordmarks(heroes)
                                try? await Task.sleep(for: .seconds(2))
                                await resolveHeroWordmarks(heroes)
                            }
                        }

                        if !continueWatching.isEmpty {
                            indexedShelf(
                                title: "Continue Watching",
                                identifier: "continue",
                                values: continueWatching,
                                showsProgress: true
                            )
                        }

                        if !library.resolvedGroups.isEmpty {
                            AppleLocalTitleShelf(title: "Your Library", groups: library.resolvedGroups,
                                sourceStore: sourceStore, mediaIndex: mediaIndex, settings: settings, openSettings: openSettings)
                                .accessibilityIdentifier("home.your-library")
                        }

                        if !topPicks.isEmpty {
                            indexedShelf(title: "Top Picks for You", identifier: "top-picks", values: topPicks, showsProgress: false)
                        }

                        if settings.top10ListsEnabled {
                            top10Shelf(title: "Top 10 Movies in the US", entries: top10Week?.films ?? [], type: "movie")
                            top10Shelf(title: "Top 10 Shows in the US", entries: top10Week?.tv ?? [], type: "series")
                            if top10Week?.isStale == true {
                                Text("Top 10 lists are stale because the latest update could not be downloaded.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 16)
                            }
                        }

                        ForEach(visibleSections) { section in
                            if let source = sourceStore.sources.first(where: { $0.id == section.sourceID }) {
                                AppleCatalogSectionView(
                                    section: section,
                                    source: source,
                                    relatedItems: catalogLookup.relatedItems(for: source.id),
                                    mediaIndex: mediaIndex,
                                    playbackSources: sourceStore.sources,
                                    metadataConfiguration: metadataConfiguration,
                                    gatewayConfig: gatewayConfig,
                                    streamingServerConfiguration: streamingServerConfiguration,
                                    playbackResolver: playbackResolver,
                                    settings: settings,
                                    openSettings: openSettings
                                )
                            }
                        }
                    }
                    #if os(tvOS)
                    .padding(.bottom, AppleTVBillboardMetrics.contentBottomInset)
                    #else
                    .padding(.vertical)
                    #endif
                }
                .scrollIndicators(AppleDesignTokens.scrollIndicatorVisibility)
                #if os(tvOS)
                // The billboard runs under the top safe area and bleeds past the
                // horizontal one; rows keep the stock 80 pt inset. Black ground so
                // the fade meets the page with no seam.
                .ignoresSafeArea(edges: .top)
                .scrollClipDisabled()
                .background(Color.black.ignoresSafeArea())
                #endif
            }
        }
        .overlay(alignment: .top) {
            if catalogStore.isLoading {
                ProgressView()
                    .padding()
            }
        }
        .environment(\.appleTMDBConfiguration, metadataConfiguration)
        #if os(visionOS)
        .buttonStyle(.plain)
        #endif
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { viewportSize = $0 }
        // tvOS: no toolbar items. Search is its own tab there and the catalog
        // refreshes on appear, so nothing floats over the billboard (X4).
        #if !os(tvOS)
        .toolbar {
            ToolbarItem(placement: discoverActionPlacement) {
                Button {
                    showsSearch = true
                } label: {
                    Label("Search", systemImage: "magnifyingglass")
                }
                .accessibilityLabel("Search")
                .appleVisionActionTarget()
            }
            ToolbarItem(placement: discoverActionPlacement) {
                Button {
                    refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .accessibilityLabel("Refresh")
                .appleVisionActionTarget()
                .disabled(catalogStore.isLoading)
            }
        }
        #endif
        #if DEBUG && (os(visionOS) || os(tvOS) || os(iOS))
        .navigationDestination(isPresented: $visionReviewDetail) {
            if let value = visionReviewItem { detail(value, initialAutoPlay: visionReviewAutoPlay) }
        }
        .task(id: visibleSections.count) {
            let screen = UserDefaults.standard.string(forKey: "OpenStreamVisionScreen")
            // "play" opens the same title page and starts its first stream, so
            // the player can be captured headlessly on the TV simulator.
            if (screen == "detail" || screen == "episodes" || screen == "play"), visionReviewItem != nil {
                // `OpenStreamDetailDelaySeconds` waits on the home screen
                // before pushing the content page, so the metadata prefetch
                // has the head start a real viewer gives it. Without it this
                // hook opens the page at launch and measures the cold path.
                let delay = UserDefaults.standard.double(forKey: "OpenStreamDetailDelaySeconds")
                if delay > 0 {
                    try? await Task.sleep(for: .seconds(delay))
                    guard !Task.isCancelled else { return }
                }
                visionReviewAutoPlay = screen == "play"
                visionReviewDetail = true
            }
        }
        #endif
        .appleTraceScreen("discover", detail: "\(visibleSections.count) sections, loading=\(catalogStore.isLoading)")
        .navigationDestination(isPresented: $showsSearch) {
            AppleSearchView(
                catalogStore: catalogStore,
                sourceStore: sourceStore,
                mediaIndex: mediaIndex,
                router: router,
                settings: settings,
                openSettings: openSettings
            )
            .navigationTitle("Search")
            .appleTraceScreen("search")
        }
        .onChange(of: settings.top10ListsEnabled) { _, enabled in
            if enabled { loadTop10() }
            else { top10Week = nil; top10Error = nil }
        }
        .task(id: router.revision) {
            switch router.route {
            case .search:
                // On a platform with its own Search tab the route already
                // selected it; pushing here would stack a second one.
                if AppleSearchRoutePolicy.discoverPushesSearch(
                    hasDedicatedSearchTab: AppleSearchRoutePolicy.platformHasDedicatedSearchTab) {
                    showsSearch = true
                }
            case .media:
                showsSearch = true
            case .continueWatching, .none:
                break
            }
        }
        .task(id: catalogConfigurationIdentity(sourceStore.sources)) {
            await mediaIndex.load()
            try? await mediaIndex.synchronizePlaybackProgress()
            if !loadedCache {
                await catalogStore.loadCachedSections(sources: sourceStore.sources)
                loadedCache = true
            }
            await catalogStore.refresh(sources: sourceStore.sources)
            applyCatalogRefreshHealth(reports: catalogStore.sourceRefreshReports, to: sourceStore)
            await indexCatalogs()
            try? await mediaIndex.synchronizePlaybackProgress()
        }
        .task(id: catalogLookupIdentity) {
            await rebuildCatalogLookup()
        }
        // Fetch, while the viewer is still on the home screen, what a content
        // page would otherwise wait 1.36 s for (owner: "preload metadata like
        // wordmark art so that it loads basically instantly").
        .task(id: prefetchIdentity) {
            await AppleMetadataPrefetcher.warm(
                featuredCandidates.map {
                    AppleMetadataPrefetcher.Title(type: $0.item.type, mediaID: $0.item.mediaID)
                },
                sources: sourceStore.sources
            )
        }
        .task(id: settings.top10ListsEnabled) {
            guard settings.top10ListsEnabled else { return }
            loadTop10()
        }
    }

    /// The billboard candidates, as a key: the prefetch re-runs when the set
    /// changes, not when the rotation moves through it.
    private var prefetchIdentity: String {
        featuredCandidates.map(\.item.mediaID).joined(separator: "\u{1f}")
    }

    /// What the hero rotates through: what the owner is part-way into first,
    /// then the recommendations, then the newest catalog items (FEEDBACK X9).
    private var featuredCandidates: [IndexedCatalogItem] {
        var values = continueWatching
        values += topPicks
        if let section = visibleSections.first,
           let source = sourceStore.sources.first(where: { $0.id == section.sourceID }) {
            values += section.items.prefix(AppleHeroRotation.maximumCandidates).map { item in
                IndexedCatalogItem(record: AppleMediaIngestion.catalogRecord(instanceID: source.id, item: item),
                                   item: item, source: source)
            }
        }
        return AppleHeroRotation.candidates(values, id: \.record.id)
    }

    /// Most recently watched first, like every other Continue Watching row.
    /// It was sorted by how far through each title was, which put whatever was
    /// closest to finishing at the front — and the billboard follows this
    /// order, so the home screen led with the wrong title too.
    private var continueWatching: [IndexedCatalogItem] {
        let store = ApplePlaybackStore()
        let unfinished = mediaIndex.records
            .filter { ($0.progress ?? 0) > 0 && ($0.progress ?? 1) < ApplePlaybackProgress.completionFraction }
        var watchedAt: [String: Date] = [:]
        for record in unfinished {
            watchedAt[record.id] = store.progress(for: record.id)?.updatedAt ?? record.lastVerified
        }
        return unfinished
            .sorted { (watchedAt[$0.id] ?? .distantPast) > (watchedAt[$1.id] ?? .distantPast) }
            .compactMap { record in
                guard let match = catalogLookup.match(for: record.id) else { return nil }
                return IndexedCatalogItem(record: record, item: match.item, source: match.source)
            }
            .prefix(12)
            .map { $0 }
    }

    private var topPicks: [IndexedCatalogItem] {
        let ratingStore = AppleTitleRatingStore()
        let ratings = ratingStore.allRatings
        let history = continueWatching.map { value in
                AppleViewingSignal(
                    titleID: ApplePlaybackIdentity.digest(for: value.item.mediaID),
                    genres: [],
                    at: value.record.lastVerified,
                    completed: value.record.progress.map { $0 >= ApplePlaybackProgress.completionFraction } ?? false
                )
            }
        guard !history.isEmpty || !ratings.isEmpty else { return [] }
        var values: [String: IndexedCatalogItem] = [:]
        for section in visibleSections {
            guard let source = sourceStore.sources.first(where: { $0.id == section.sourceID }) else { continue }
            for item in section.items {
                let record = AppleMediaIngestion.catalogRecord(instanceID: source.id, item: item)
                values[record.id] = IndexedCatalogItem(record: record, item: item, source: source)
            }
        }
        let rankable = values.values.map { value in
            AppleRankableTitle(
                id: ApplePlaybackIdentity.digest(for: value.item.mediaID),
                genres: [],
                releaseYear: Int(value.item.releaseInfo ?? ""),
                metadataCompleteness: Double([
                    value.item.summary != nil,
                    value.item.posterURL != nil,
                    value.item.releaseInfo != nil,
                    value.item.rating != nil
                ].filter { $0 }.count) / 4,
                isResumable: (value.record.progress ?? 0) > 0 && (value.record.progress ?? 1) < ApplePlaybackProgress.completionFraction,
                isCompleted: (value.record.progress ?? 0) >= ApplePlaybackProgress.completionFraction
            )
        }
        let ranked = AppleRecommendationRanker.rank(rankable, history: history, ratings: ratings, now: .now, limit: 20)
        return ranked.compactMap { rankedTitle in
            values.values.first { ApplePlaybackIdentity.digest(for: $0.item.mediaID) == rankedTitle.id }
        }
    }

    private func loadTop10() {
        Task {
            do {
                top10Week = try await AppleNetflixTop10Client(session: .shared).latestWeek()
                top10Error = nil
            } catch {
                top10Error = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private func top10Shelf(title: String, entries: [AppleNetflixTop10Entry], type: String) -> some View {
        let ordered = entries.sorted { $0.rank < $1.rank }
        if !ordered.isEmpty {
            // Same shelf as every other row (header size, inset, gaps, focus
            // treatment); only the rank badge marks it as a Top 10 row.
            AppleMediaShelf(title: title) {
                ForEach(ordered, id: \.rank) { entry in
                    Group {
                        let match = catalogLookup.match(title: entry.title, type: type, seasonTitle: entry.seasonTitle)
                        if let match {
                            let record = AppleMediaIngestion.catalogRecord(instanceID: match.source.id, item: match.item)
                            let value = IndexedCatalogItem(record: record, item: match.item, source: match.source)
                            NavigationLink { detail(value) } label: { AppleTop10Card(item: match.item, rank: entry.rank) }
                        } else {
                            AppleTop10SearchCard(entry: entry, type: type, sources: sourceStore.sources) { match in
                                let record = AppleMediaIngestion.catalogRecord(instanceID: match.source.id, item: match.item)
                                detail(IndexedCatalogItem(record: record, item: match.item, source: match.source))
                            }
                        }
                    }
                    .accessibilityIdentifier("home.top10.\(type).\(entry.rank)")
                }
            }
        }
    }

    @ViewBuilder
    private func featuredHero(_ value: IndexedCatalogItem, rotationCount: Int = 0, rotationIndex: Int = 0) -> some View {
        AppleFeaturedHero(
            item: value.item,
            viewportSize: viewportSize,
            wordmark: heroWordmarks[value.item.mediaID],
            rotationCount: rotationCount,
            rotationIndex: rotationIndex
        ) { featuredActions(value) }
    }

    /// Reads whatever the prefetcher has already cached for the heroes. Cache
    /// only — never a fetch — so the home screen cannot be made slower by
    /// looking for a logo it may not have.
    private func resolveHeroWordmarks(_ heroes: [IndexedCatalogItem]) async {
        var found: [String: URL] = [:]
        for hero in heroes {
            let key = AppleStremioPreviewAssetsCache.key(
                type: hero.item.type, mediaID: hero.item.mediaID
            )
            if let logo = await AppleStremioPreviewAssetsCache.shared.entry(for: key)?.assets?.logoURL {
                found[hero.item.mediaID] = logo
            }
        }
        guard !Task.isCancelled, found != heroWordmarks else { return }
        heroWordmarks = found
    }

    /// The tvOS billboard is 1920 wide inside the safe-area column, so it is
    /// pulled out by the inset on both sides; other platforms keep the card margin.
    private var heroHorizontalPadding: CGFloat {
        #if os(tvOS)
        -AppleTVChromeMetrics.horizontalSafeInset
        #else
        16
        #endif
    }

    #if DEBUG && (os(visionOS) || os(tvOS) || os(iOS))
    private var visionReviewItem: IndexedCatalogItem? {
        guard let section = visibleSections.first(where: { $0.catalog.type == "series" }),
              let item = section.items.first,
              let source = sourceStore.sources.first(where: { $0.id == section.sourceID }) else { return nil }
        return IndexedCatalogItem(record: AppleMediaIngestion.catalogRecord(instanceID: source.id, item: item), item: item, source: source)
    }
    #endif

    private var discoverActionPlacement: ToolbarItemPlacement {
        #if os(visionOS)
        .bottomOrnament
        #else
        .primaryAction
        #endif
    }

    private func featuredActions(_ value: IndexedCatalogItem) -> some View {
        AppleFeaturedActions(viewportSize: viewportSize) {
            detail(value, initialAutoPlay: true)
        } detailDestination: { detail(value) }
    }

    @ViewBuilder
    private func indexedShelf(
        title: String,
        identifier: String,
        values: [IndexedCatalogItem],
        showsProgress: Bool
    ) -> some View {
        AppleMediaShelf(title: title) {
            ForEach(values) { value in
                NavigationLink { detail(value) } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        AppleCatalogCard(item: value.item)
                        if showsProgress {
                            // The bar belongs to the card above it, so it takes
                            // the card's width. A fixed 140 pt was narrower than
                            // the poster on every platform and, in a
                            // leading-aligned stack, sat short and off to one
                            // side — the owner's "these progress bars are not
                            // symmetrical" (2026-09-15).
                            ProgressView(value: value.record.progress ?? 0)
                                .frame(maxWidth: .infinity)
                                .tint(.white)
                        }
                    }
                }.accessibilityIdentifier("home.\(identifier).\(value.id)")
            }
        }
    }

    private func detail(_ value: IndexedCatalogItem, initialAutoPlay: Bool = false) -> some View {
        AppleCatalogItemDetailView(
            item: value.item,
            source: value.source,
            relatedItems: catalogLookup.relatedItems(for: value.source.id),
            mediaIndex: mediaIndex,
            playbackSources: sourceStore.sources,
            metadataConfiguration: metadataConfiguration,
            gatewayConfig: gatewayConfig,
            streamingServerConfiguration: streamingServerConfiguration,
            playbackResolver: playbackResolver,
            settings: settings,
            openSettings: openSettings,
            initialAutoPlay: initialAutoPlay
        )
    }

    private var catalogLookupIdentity: String {
        "\(catalogStore.contentRevision)#\(searchConfigurationIdentity(sourceStore.sources))"
    }

    private func rebuildCatalogLookup() async {
        let updated = await AppleCatalogSearchLookup.buildOffMain(
            sections: catalogStore.sections,
            sources: sourceStore.sources
        )
        guard !Task.isCancelled else { return }
        catalogLookup = updated
    }

    private var featuredHeight: CGFloat {
        #if os(tvOS)
        540
        #else
        isLandscapeIPad ? min(viewportSize.height * 0.55, (viewportSize.width - 32) * 9 / 16) : 390
        #endif
    }

    private var isLandscapeIPad: Bool {
        #if os(iOS)
        horizontalSizeClass == .regular && viewportSize.width > viewportSize.height
        #else
        false
        #endif
    }

    private var sectionSpacing: CGFloat {
        #if os(tvOS)
        48
        #else
        30
        #endif
    }

    private var gatewayConfig: AppleTranscodeGatewayConfig? {
        guard settings.gatewayEnabled else { return nil }
        return try? AppleTranscodeGatewayConfig(
            baseURL: settings.gatewayURL,
            sessionToken: settings.gatewayToken,
            isEnabled: true
        )
    }

    private var streamingServerConfiguration: AppleStremioStreamingServerConfiguration? {
        nil
    }

    private var metadataConfiguration: AppleTMDBConfiguration? {
        guard settings.metadataEnabled else { return nil }
        return try? AppleTMDBConfiguration(credential: settings.tmdbAPIKey)
    }

    private func refresh() {
        Task { @MainActor in
            await catalogStore.refresh(sources: sourceStore.sources, force: true)
            applyCatalogRefreshHealth(reports: catalogStore.sourceRefreshReports, to: sourceStore)
            await indexCatalogs()
        }
    }

    private func indexCatalogs() async {
        for source in sourceStore.sources where source.kind == .stremio && source.isEnabled {
            let records = catalogStore.sections
                .filter { $0.sourceID == source.id }
                .flatMap { AppleMediaIngestion.catalogRecords(section: $0) }
            try? await mediaIndex.replaceCatalog(instanceID: source.id, with: records)
        }
    }
}

@MainActor
struct AppleSearchView: View {
    @State private var query = ""
    @State private var searchStore = AppleCatalogSearchStore()
    @State private var routedResult: RoutedResult?
    @State private var deliveredRouteRevision: Int?
    @State private var catalogLookup = AppleCatalogSearchLookup()

    private struct RoutedResult: Identifiable, Hashable {
        let record: AppleMediaRecord
        let item: AppleCatalogItem
        let source: AppleSource
        let action: AppleMediaRouteAction
        let revision: Int
        var id: String { "\(record.id):\(action.rawValue):\(revision)" }

        static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    let catalogStore: AppleCatalogStore
    let sourceStore: AppleSourceStore
    let mediaIndex: AppleMediaIndexStore
    let router: AppleAppRouter
    let settings: AppleSettingsStore
    let openSettings: () -> Void
    private let playbackResolver = AppleStremioPlaybackResolver()

    var body: some View {
        Group {
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // With sources configured the description read "Search movies,
                // shows, files, and channels" — the field's own placeholder,
                // restated a few hundred points lower. The standing rule is
                // that empty states carry no explainer copy; the no-sources
                // line stays because it is the one case where the viewer needs
                // telling what to do next.
                if sourceStore.sources.isEmpty {
                    ContentUnavailableView(
                        "Search Your Sources",
                        systemImage: "magnifyingglass",
                        description: Text("Titles appear here after you add and refresh a catalog source.")
                    )
                } else {
                    ContentUnavailableView("Search Your Sources", systemImage: "magnifyingglass")
                }
            } else if searchStore.results.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                List(searchStore.results) { record in
                    if let result = searchMatch(for: record.id) {
                        NavigationLink {
                            AppleCatalogItemDetailView(
                                item: result.item,
                                source: result.source,
                                relatedItems: relatedItems(for: result.source.id),
                                mediaIndex: mediaIndex,
                                playbackSources: sourceStore.sources,
                                metadataConfiguration: metadataConfiguration,
                                gatewayConfig: gatewayConfig,
                                streamingServerConfiguration: streamingServerConfiguration,
                                playbackResolver: playbackResolver,
                                settings: settings,
                                openSettings: openSettings
                            )
                        } label: {
                            resultRow(record, sourceName: result.source.name)
                        }
                    } else {
                        resultRow(record, sourceName: sourceName(for: record))
                    }
                }
                .scrollIndicators(AppleDesignTokens.scrollIndicatorVisibility)
            }
        }
        .searchable(text: $query, prompt: "Search movies, shows, and channels")
        .navigationDestination(item: $routedResult) { value in
            AppleCatalogItemDetailView(
                item: value.item,
                source: value.source,
                relatedItems: catalogLookup.relatedItems(for: value.source.id),
                mediaIndex: mediaIndex,
                playbackSources: sourceStore.sources,
                metadataConfiguration: metadataConfiguration,
                gatewayConfig: gatewayConfig,
                streamingServerConfiguration: streamingServerConfiguration,
                playbackResolver: playbackResolver,
                settings: settings,
                openSettings: openSettings,
                initialAutoPlay: value.action == .play
            )
        }
        .task(id: router.searchQuery) {
            if !router.searchQuery.isEmpty { query = router.searchQuery }
        }
        .task(id: router.revision) {
            let revision = router.revision
            guard case .media(let id, _) = router.route else {
                routedResult = nil
                return
            }
            await mediaIndex.load()
            guard !Task.isCancelled, router.revision == revision else { return }
            guard let record = mediaIndex.records.first(where: { $0.id == id }) else {
                query = ""
                return
            }
            query = record.title
            await catalogStore.loadCachedSections(sources: sourceStore.sources)
            await rebuildCatalogLookup()
            deliverMediaRoute(revision: revision)
        }
        .task(id: query) {
            let revision = router.revision
            await searchStore.search(
                query: query,
                sources: sourceStore.sources,
                baseSections: catalogStore.sections
            ) { value in
                await mediaIndex.search(value)
            }
            deliverMediaRoute(revision: revision)
        }
        .task {
            await mediaIndex.load()
            if catalogStore.sections.isEmpty {
                await catalogStore.loadCachedSections(sources: sourceStore.sources)
            }
        }
        .task(id: catalogLookupIdentity) {
            await rebuildCatalogLookup()
        }
        // tvOS: no Refresh. It drew as a boxed glyph floating over the empty
        // state beside the keyboard (owner 2026-09-14) and there is nothing
        // for it to do that typing does not already do — the same call the
        // owner made for the Discover toolbar (X4).
        #if !os(tvOS)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { @MainActor in
                        await catalogStore.refresh(sources: sourceStore.sources, force: true)
                        applyCatalogRefreshHealth(reports: catalogStore.sourceRefreshReports, to: sourceStore)
                        await indexCatalogs()
                        await rebuildCatalogLookup()
                        await searchStore.search(
                            query: query,
                            sources: sourceStore.sources,
                            baseSections: catalogStore.sections
                        ) { value in
                            await mediaIndex.search(value)
                        }
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .accessibilityLabel("Refresh")
                .disabled(catalogStore.isLoading)
            }
        }
        #endif
    }

    private func deliverMediaRoute(revision: Int) {
        guard !Task.isCancelled, revision == router.revision,
              deliveredRouteRevision != revision,
              case .media(let id, let action) = router.route,
              let record = mediaIndex.records.first(where: { $0.id == id }),
              let result = searchMatch(for: id) else { return }
        deliveredRouteRevision = revision
        routedResult = .init(record: record, item: result.item, source: result.source,
                             action: action, revision: revision)
    }

    @ViewBuilder
    private func resultRow(_ record: AppleMediaRecord, sourceName: String) -> some View {
        HStack(spacing: 14) {
            AppleCatalogArtwork(url: record.artworkURL)
                .frame(width: 58, height: 87)
                .clipShape(.rect(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                Text(record.title).font(.headline)
                Text(sourceName).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text(record.kind.rawValue.capitalized)
                    if let year = record.year { Text(String(year)) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func sourceName(for record: AppleMediaRecord) -> String {
        searchStore.lookup.sourceName(for: record)
    }

    private func searchMatch(for recordID: String) -> AppleCatalogSearchMatch? {
        searchStore.lookup.match(for: recordID) ?? catalogLookup.match(for: recordID)
    }

    private func relatedItems(for sourceID: AppleSource.ID) -> [AppleCatalogItem] {
        let searchItems = searchStore.lookup.relatedItems(for: sourceID)
        return searchItems.isEmpty ? catalogLookup.relatedItems(for: sourceID) : searchItems
    }

    private func indexCatalogs() async {
        for source in sourceStore.sources where source.kind == .stremio && source.isEnabled {
            let records = catalogStore.sections
                .filter { $0.sourceID == source.id }
                .flatMap { AppleMediaIngestion.catalogRecords(section: $0) }
            try? await mediaIndex.replaceCatalog(instanceID: source.id, with: records)
        }
    }

    private var catalogLookupIdentity: String {
        "\(catalogStore.contentRevision)#\(searchConfigurationIdentity(sourceStore.sources))"
    }

    private func rebuildCatalogLookup() async {
        let updated = await AppleCatalogSearchLookup.buildOffMain(
            sections: catalogStore.sections,
            sources: sourceStore.sources
        )
        guard !Task.isCancelled else { return }
        catalogLookup = updated
    }

    private var gatewayConfig: AppleTranscodeGatewayConfig? {
        guard settings.gatewayEnabled else { return nil }
        return try? AppleTranscodeGatewayConfig(
            baseURL: settings.gatewayURL,
            sessionToken: settings.gatewayToken,
            isEnabled: true
        )
    }

    private var streamingServerConfiguration: AppleStremioStreamingServerConfiguration? {
        nil
    }


    private var metadataConfiguration: AppleTMDBConfiguration? {
        guard settings.metadataEnabled else { return nil }
        return try? AppleTMDBConfiguration(credential: settings.tmdbAPIKey)
    }
}

private struct AppleCatalogSectionView: View {
    let section: AppleCatalogSection
    let source: AppleSource
    let relatedItems: [AppleCatalogItem]
    let mediaIndex: AppleMediaIndexStore
    let playbackSources: [AppleSource]
    let metadataConfiguration: AppleTMDBConfiguration?
    let gatewayConfig: AppleTranscodeGatewayConfig?
    let streamingServerConfiguration: AppleStremioStreamingServerConfiguration?
    let playbackResolver: AppleStremioPlaybackResolver
    let settings: AppleSettingsStore
    let openSettings: () -> Void
    @FocusState private var focusedItemID: String?

    private var title: String {
        appleCatalogShelfTitle(sourceName: section.sourceName, catalogType: section.catalog.type, catalogName: section.catalog.name)
    }

    var body: some View {
        AppleMediaShelf(title: title) {
                    ForEach(section.items) { item in
                        NavigationLink {
                            AppleCatalogItemDetailView(
                                item: item,
                                source: source,
                                relatedItems: relatedItems,
                                mediaIndex: mediaIndex,
                                playbackSources: playbackSources,
                                metadataConfiguration: metadataConfiguration,
                                gatewayConfig: gatewayConfig,
                                streamingServerConfiguration: streamingServerConfiguration,
                                playbackResolver: playbackResolver,
                                settings: settings,
                                openSettings: openSettings
                            )
                        } label: {
                            AppleCatalogCard(item: item)
                        }
                .focused($focusedItemID, equals: item.id)
                .accessibilityIdentifier("home.media.\(item.id)")
                    }
        }
        #if os(tvOS)
        .defaultFocus($focusedItemID, section.items.first?.id)
        #endif
    }

    private var cardSpacing: CGFloat {
        #if os(tvOS)
        28
        #else
        16
        #endif
    }
}

func appleCatalogShelfTitle(sourceName: String, catalogType: String, catalogName: String? = nil) -> String {
    let provider = sourceName.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    let catalog = catalogName?.trimmingCharacters(in: .whitespacesAndNewlines)
    let lowerProvider = provider.lowercased()
    let metadataService = ["cinemeta", "rotten tomatoes", "tmdb", "the movie database", "omdb"].contains(lowerProvider)
    let streamingCatalog = lowerProvider.contains("streaming catalog")
    let serviceFromCatalog = streamingCatalog
        ? AppleCatalogServiceName.service(fromCatalogID: nil, name: catalog)
        : nil
    let base = metadataService || streamingCatalog
        ? (serviceFromCatalog ?? (metadataService ? "Popular" : "Streaming"))
        : provider
    switch catalogType.lowercased() {
    case "series": return "\(base) Shows"
    case "movie": return "\(base) Movies"
    default: return base
    }
}

private struct AppleTop10Card: View {
    let item: AppleCatalogItem
    let rank: Int
    var body: some View {
        ZStack(alignment: .topLeading) { AppleCatalogCard(item: item); AppleTop10RankBadge(rank: rank).padding(8) }
    }
}

private struct AppleTop10SearchCard<Destination: View>: View {
    let entry: AppleNetflixTop10Entry
    let type: String
    let sources: [AppleSource]
    @ViewBuilder let destination: (AppleCatalogSearchMatch) -> Destination
    @State private var match: AppleCatalogSearchMatch?
    @State private var isLoading = true

    var body: some View {
        Group {
            if let match {
                NavigationLink { destination(match) } label: { AppleTop10Card(item: match.item, rank: entry.rank) }
            } else {
                AppleTop10UnresolvedCard(title: entry.title, rank: entry.rank)
                    .overlay(alignment: .bottomTrailing) {
                        if isLoading { ProgressView().padding(8) }
                    }
                    .accessibilityValue(isLoading ? "Finding artwork" : "Unavailable from connected catalogs")
            }
        }
        .task(id: "\(entry.title):\(catalogConfigurationIdentity(sources))") {
            match = nil
            isLoading = true
            match = await AppleTop10ArtworkLookup.find(title: entry.title, type: type,
                seasonTitle: entry.seasonTitle, sources: sources)
            guard !Task.isCancelled else { return }
            isLoading = false
        }
    }
}

private struct AppleTop10UnresolvedCard: View {
    let title: String
    let rank: Int
    var body: some View {
        #if os(tvOS)
        // Card-sized titled tile, like every other artless card on tvOS (X7).
        ZStack(alignment: .topLeading) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(white: 0.12))
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .padding(12)
            }
            .frame(width: 230, height: 345)
            AppleTop10RankBadge(rank: rank).padding(8)
        }
        #else
        legacyBody
        #endif
    }

    #if !os(tvOS)
    private var legacyBody: some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.13)).overlay { Image(systemName: "film").font(.title).foregroundStyle(.secondary) }.frame(width: 140, height: 210)
                Text(title).font(.headline).lineLimit(3).frame(width: 140, alignment: .leading)
            }
            AppleTop10RankBadge(rank: rank).padding(8)
        }
    }
    #endif
}

private struct AppleTop10RankBadge: View {
    let rank: Int
    var body: some View { Text("\(rank)").font(.headline.bold()).foregroundStyle(.white).frame(width: 34, height: 34).background(Color(white: 0.08), in: Circle()) }
}

extension View {
    @ViewBuilder
    func appleCatalogFocusSection() -> some View {
        #if os(tvOS)
        // One focus treatment for every home row: the title page's lift and
        // shadow on the artwork itself, never the stock platter behind it
        // (owner 16:20, "still not great").
        focusSection().buttonStyle(AppleTVDetailCardStyle())
        #elseif os(visionOS)
        self.buttonStyle(.plain)
        #else
        self
        #endif
    }

    /// The button style a card link inside a shelf uses on each platform;
    /// tvOS must not fall back to `.plain`, which draws the stock platter.
    @ViewBuilder
    func appleCatalogCardButtonStyle() -> some View {
        #if os(tvOS)
        self.buttonStyle(AppleTVDetailCardStyle())
        #else
        self.buttonStyle(.plain)
        #endif
    }
}

struct AppleCatalogCard: View {
    let item: AppleCatalogItem
    let sizing: AppleCatalogCardSizing
    let viewportWidth: CGFloat?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.appleTMDBConfiguration) private var metadataConfiguration
    @ScaledMetric(relativeTo: .body) private var scaledCardWidth = 140.0
    @State private var fallbackArtwork: AppleArtworkResolver.Artwork?
    @State private var artworkFailed = false

    init(item: AppleCatalogItem, sizing: AppleCatalogCardSizing = .catalog, viewportWidth: CGFloat? = nil) {
        self.item = item
        self.sizing = sizing
        self.viewportWidth = viewportWidth
    }

    private var resolvedPosterURL: URL? {
        item.posterURL ?? fallbackArtwork?.posterURL ?? item.backgroundURL
    }

    /// A card never renders as an empty slot: when the artwork is missing or
    /// fails, the tile carries the title instead (FEEDBACK X7).
    private var artworkPlaceholder: some View {
        ZStack {
            Color(white: 0.12)
            Text(item.name)
                .font(.headline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .padding(12)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AppleCatalogArtwork(url: resolvedPosterURL, onFailure: { artworkFailed = true },
                                onLoad: { artworkFailed = false })
                .frame(width: cardWidth, height: cardHeight)
                .overlay { if artworkFailed { artworkPlaceholder } }
                .clipShape(.rect(cornerRadius: cornerRadius))
                .onChange(of: resolvedPosterURL) { _, _ in artworkFailed = false }
                .task(id: item.id) {
                    guard item.posterURL == nil else { return }
                    fallbackArtwork = await AppleArtworkResolver.shared.resolve(
                        mediaID: item.mediaID,
                        type: item.type,
                        existingPosterURL: item.posterURL,
                        existingBackgroundURL: item.backgroundURL,
                        configuration: metadataConfiguration
                    )
                }

            // tvOS rows are art only, like the TV app and the reference; the
            // title lives on the artwork or in the X7 placeholder tile.
            #if !os(tvOS)
            Text(item.name)
                .font(.headline)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                .frame(width: cardWidth, alignment: .leading)

            if let releaseInfo = item.releaseInfo, !releaseInfo.isEmpty {
                Text(releaseInfo)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
            }
            #endif
        }
        .contentShape(Rectangle())
        .foregroundStyle(.primary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.name)
        .accessibilityValue(item.releaseInfo ?? "")
        .appleVisionHover()
    }

    private var cardWidth: CGFloat {
        if sizing == .detailSuggestions {
            #if os(iOS)
            if horizontalSizeClass == .regular { return 150 }
            let width = viewportWidth.flatMap { $0 > 0 ? $0 : nil } ?? 390
            return max(1, (width - 48) / 2.7)
            #else
            return 150
            #endif
        }
        #if os(visionOS)
        return max(180, min(scaledCardWidth, 240))
        #elseif os(tvOS)
        return 230
        #else
        return min(max(scaledCardWidth, 140), 220)
        #endif
    }

    private var cardHeight: CGFloat {
        cardWidth * 1.5
    }

    private var cornerRadius: CGFloat {
        #if os(tvOS)
        18
        #else
        12
        #endif
    }
}

enum AppleCatalogCardSizing {
    case catalog
    case detailSuggestions
}

struct AppleCatalogArtwork: View {
    let url: URL?
    /// Billboards pass `AppleDesignTokens.surface`; shelf posters keep the
    /// near-invisible default. See `AppleRemoteImage.loadingFill`.
    var loadingFill: Color = .white.opacity(0.025)
    var onFailure: (() -> Void)? = nil
    /// Clears a card's failed state when the poster does arrive. Without this
    /// a single transient failure latched the card to its text tile for as
    /// long as it stayed on screen — which is why "1992" and "2073" read as
    /// bare numbers on the Apple TV while the same two titles showed full
    /// artwork on the phone (2026-09-15).
    var onLoad: (() -> Void)? = nil

    var body: some View {
        AppleRemoteImage(url: url, placeholderSystemImage: "",
                         onLoad: onLoad.map { callback in { _ in callback() } },
                         onFailure: onFailure,
                         loadingFill: loadingFill)
    }
}

@MainActor
struct AppleCatalogItemDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    // The secondary row (My List, Rate) was missed when the primary buttons were
    // taught to scale: at the largest size its glyphs and 11 pt labels stayed
    // tiny beside buttons that had grown (measured on the iPad, 2026-09-17).
    @ScaledMetric(relativeTo: .body) private var scaledIconGlyphSize: CGFloat =
        AppleDetailMetrics.iconGlyphSize
    @ScaledMetric(relativeTo: .body) private var scaledIconLabelFontSize: CGFloat =
        AppleDetailMetrics.iconLabelFontSize
    @ScaledMetric(relativeTo: .body) private var scaledIconRowHeight: CGFloat =
        AppleDetailMetrics.iconRowHeight

    let item: AppleCatalogItem
    let source: AppleSource
    let relatedItems: [AppleCatalogItem]
    let mediaIndex: AppleMediaIndexStore
    let playbackSources: [AppleSource]
    let metadataConfiguration: AppleTMDBConfiguration?
    let gatewayConfig: AppleTranscodeGatewayConfig?
    let streamingServerConfiguration: AppleStremioStreamingServerConfiguration?
    let playbackResolver: AppleStremioPlaybackResolver
    let settings: AppleSettingsStore
    let openSettings: () -> Void
    let initialAutoPlay: Bool
    let localGroup: AppleLibrarySeries?
    let localSourceStore: AppleSourceStore?
    @State private var library = AppleLocalLibraryStore.shared
    @State private var selectedLocalFile: AppleLibraryItem?
    @State private var pickingStreams = false

    private var localFiles: [AppleLibraryItem] {
        library.localFiles(for: item.withMediaID(resolvedMediaID ?? item.mediaID), group: localGroup,
            episode: episodes.first { $0.id == selectedEpisodeID })
    }


    @State private var playbackCoordinator = ApplePlaybackCoordinator()
    @State private var playRequest: UUID?
    @State private var playerPresentation: AppleStremioPlayerPresentation?
    @State private var episodes: [AppleStremioEpisode] = []
    @State private var selectedSeason: Int?
    @State private var selectedEpisodeID: String?
    @State private var isLoadingEpisodes = false
    @State private var isFavorite = false
    @State private var downloadCoordinator = AppleOfflineDownloadCoordinator()
    @State private var seasonDownloads = AppleSeasonDownloadQueue()
    @State private var downloadSeason: Int?
    @State private var metadataDetails: AppleTMDBDetails?
    @State private var fallbackArtwork: AppleArtworkResolver.Artwork?
    @State private var previewAssets: AppleStremioPreviewAssets?
    @State private var isPreparingMetadata = true
    @State private var trailerIsActive = false
    @State private var trailerIsPlaying = false
    @State private var detailViewportSize: CGSize = .zero
    @State private var detailSafeAreaInsets = EdgeInsets()
    @State private var trailerHasStarted = false
    @State private var trailerMuted = false
    @State private var trailerCandidateIndex = 0
    @State private var trailerPortraitKeys: Set<String> = []
    @State private var trailerLandscapeKeys: Set<String> = []
    @State private var trailerReplayGeneration = 0
    @State private var trailerInteractionGlyph: String?
    @State private var trailerInteractionGeneration = 0
    @State private var titleLogoState = AppleTitleLogoState.loading
    @State private var titleLogoLoadResult: Bool?
    @State private var titleLogoGraceExpired = false
    @State private var streamChoices: [AppleStremioHTTPPlaybackCandidate] = []
    @State private var selectedStream: AppleStremioHTTPPlaybackCandidate?
    @State private var streamPickerPresented = false
    @State private var downloadedEpisodeIDs = Set<String>()
    @State private var downloadActionsPresented = false
    @State private var seasonDownloadActionsPresented = false
    @State private var preparationGeneration = UUID()
    #if os(iOS)
    @State private var systemVideoAutoplayEnabled = UIAccessibility.isVideoAutoplayEnabled
    #endif
    #if os(tvOS)
    @FocusState private var tvDetailFocus: AppleTVDetailFocus?
    /// Native trailer preview on Apple TV: the first playable trailer resolved
    /// to an HLS manifest, shown over the backdrop until it ends.
    @State private var tvTrailerSource: AppleYouTubeStreamResolver.Source?
    @State private var tvTrailerVisible = false
    #endif
    // The item's canonical IMDB id, resolved via a meta add-on. Catalog add-ons
    // (RT, Streaming Catalogs) key items by non-IMDB ids that stream add-ons
    // can't resolve; this is the id actually used for episode + stream lookups.
    @State private var resolvedMediaID: String?
    /// Services the viewer subscribes to that also carry this title. Empty
    /// unless they have opted in — see `AppleWatchProviderPolicy`.
    @State private var watchProviders: [AppleWatchProvider] = []
    @State private var arrRequestKind: AppleArrKind?
    @State private var arrFeedback: String?
    @State private var rating: AppleTitleRating?
    @State private var rankedSuggestions: [AppleCatalogItem] = []
    @State private var rateChoicesExpanded = false
    @State private var ratingSelectionGeneration = 0
    private let playbackStore = ApplePlaybackStore()
    private let ratingStore = AppleTitleRatingStore()

    private let metadataClient = AppleStremioMetadataClient()
    private let metadataResolver = AppleMetadataResolver()
    private let playbackPreparer = ApplePlaybackPreparer()

    init(
        item: AppleCatalogItem,
        source: AppleSource,
        relatedItems: [AppleCatalogItem] = [],
        mediaIndex: AppleMediaIndexStore,
        playbackSources: [AppleSource],
        metadataConfiguration: AppleTMDBConfiguration?,
        gatewayConfig: AppleTranscodeGatewayConfig?,
        streamingServerConfiguration: AppleStremioStreamingServerConfiguration?,
        playbackResolver: AppleStremioPlaybackResolver,
        settings: AppleSettingsStore,
        openSettings: @escaping () -> Void,
        initialAutoPlay: Bool = false,
        localGroup: AppleLibrarySeries? = nil,
        localSourceStore: AppleSourceStore? = nil
    ) {
        self.item = item
        self.source = source
        self.relatedItems = relatedItems
        self.mediaIndex = mediaIndex
        self.playbackSources = playbackSources
        self.metadataConfiguration = metadataConfiguration
        self.gatewayConfig = gatewayConfig
        self.streamingServerConfiguration = streamingServerConfiguration
        self.playbackResolver = playbackResolver
        self.settings = settings
        self.openSettings = openSettings
        self.initialAutoPlay = initialAutoPlay
        self.localGroup = localGroup
        self.localSourceStore = localSourceStore
        _isPreparingMetadata = State(
            initialValue: ApplePlayGatingPolicy.isPreparingOnAppear(mediaID: item.mediaID)
        )
    }

    var body: some View {
        Group {
            #if DEBUG && (os(visionOS) || os(tvOS) || os(iOS))
            ScrollViewReader { reader in
                detailContent.task(id: episodes.count) {
                    guard UserDefaults.standard.string(forKey: "OpenStreamVisionScreen") == "episodes", !episodes.isEmpty else { return }
                    try? await Task.sleep(for: .milliseconds(700))
                    reader.scrollTo("vision-episodes", anchor: .top)
                }
            }
            #else
            detailContent
            #endif
        }
        .environment(\.appleTMDBConfiguration, metadataConfiguration)
    }

    private func applyDetailViewport(_ viewport: AppleDetailViewport) {
        detailSafeAreaInsets = viewport.insets
        detailViewportSize = CGSize(
            width: viewport.size.width + viewport.insets.leading + viewport.insets.trailing,
            height: viewport.size.height + viewport.insets.top + viewport.insets.bottom
        )
    }

    /// Wordmark, text title, or nothing while the wordmark resolves.
    private var titleLogoPresentation: AppleTitleLogoPresentation {
        AppleTitleLogoPolicy.resolvedState(
            validated: titleLogoState.validation,
            loadResult: titleLogoLoadResult,
            elapsed: titleLogoGraceExpired ? AppleTitleLogoPolicy.loadingGrace : 0
        )
    }

    private var detailContent: some View {
        Group {
            #if os(tvOS)
            tvOSDetailLayout
            #else
            ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                detailHero
                    .padding(.top, isLandscapeLayout ? -detailSafeAreaInsets.top : 0)
                    .padding(.leading, isLandscapeLayout ? -detailSafeAreaInsets.leading : 0)
                    .padding(.trailing, isLandscapeLayout ? -detailSafeAreaInsets.trailing : 0)

                VStack(alignment: .leading, spacing: 0) {
                    if isLandscapeLayout {
                        EmptyView()
                    } else {
                        if titleLogoPresentation != .text {
                            portraitTrailerTitle
                                .padding(.top, trailerIsPlaying ? AppleDetailMetrics.heroToTitleSpacing : 0)
                        } else {
                            Text(displayTitle)
                                .font(.system(size: 17, weight: .semibold))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, AppleDetailMetrics.heroToTitleSpacing)
                                .shadow(color: .black.opacity(0.6), radius: 6, y: 1)
                                .accessibilityAddTraits(.isHeader)
                        }
                        titleMetadata
                            .padding(.top, AppleDetailMetrics.titleToMetadataSpacing)
                        secondaryActionButtons
                            .padding(.top, AppleDetailMetrics.metadataToButtonsSpacing)
                    }
                    downloadFailureNotice
                        .padding(.top, 12)
                    if let tagline = metadataDetails?.tagline, !tagline.isEmpty {
                        Text(tagline)
                            .font(.headline)
                            .italic()
                            .padding(.top, 12)
                    }

                    if let summary = AppleMetadataPresentationPolicy.synopsis(
                        catalog: item.summary,
                        enriched: metadataDetails?.overview
                    ) {
                        Text(summary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: detailContentWidth, alignment: .leading)
                            .padding(.top, AppleDetailMetrics.iconRowToSynopsisSpacing)
                            .shadow(color: .black.opacity(0.6), radius: 6, y: 1)
                    }

                    if item.type == "series" {
                        episodeSection
                            .id("vision-episodes")
                            .padding(.top, AppleDetailMetrics.sectionHeaderTopSpacing)
                    }

                }
                .frame(maxWidth: detailContentWidth, alignment: .leading)
                .padding(.horizontal, detailHorizontalInset)
                .frame(maxWidth: .infinity, alignment: .leading)

                // Outside the column on purpose. Prose belongs in a readable
                // width; a poster rail does not — every other rail in the app
                // (Discover, Library) runs to the page edge. Inside the column
                // the fifth card was sliced vertically at 695 pt of an 834 pt
                // iPad page with 139 pt of black beside it, which reads as a
                // rendering fault rather than "there is more to the right"
                // (measured 2026-09-17). It carries its own leading inset.
                if !suggestedItems.isEmpty {
                    moreLikeThisSection
                        .padding(.top, AppleDetailMetrics.sectionHeaderTopSpacing)
                }
            }
            .padding(.bottom)
            }
            // The navigation bar is hidden here so the hero can bleed to the top
            // of the screen. With no bar there is nothing behind the status bar
            // once the page scrolls, and the synopsis was drawn through the
            // clock. Applied to the scroll view itself, not the group, because
            // it reads that scroll view's offset.
            .appleStatusBarShield(topInset: detailSafeAreaInsets.top)
            #endif
        }
        .scrollIndicators(AppleDesignTokens.scrollIndicatorVisibility)
        .simultaneousGesture(
            TapGesture().onEnded {
                guard rateChoicesExpanded else { return }
                withAnimation(rateAnimation) { rateChoicesExpanded = false }
            }
        )
        .coordinateSpace(name: "detail-scroll")
        .scrollClipDisabled(isLandscapeLayout)
        .onGeometryChange(for: AppleDetailViewport.self) { proxy in
            AppleDetailViewport(size: proxy.size, insets: proxy.safeAreaInsets)
        } action: { viewport in
            applyDetailViewport(viewport)
        }
        .background(
            // `onGeometryChange` only fires when the value changes, so a value
            // left over from a push transition can survive the pop. Re-read the
            // viewport whenever this page appears or the item changes.
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        applyDetailViewport(
                            AppleDetailViewport(size: proxy.size, insets: proxy.safeAreaInsets)
                        )
                    }
                    .onChange(of: item.id) {
                        applyDetailViewport(
                            AppleDetailViewport(size: proxy.size, insets: proxy.safeAreaInsets)
                        )
                    }
            }
        )
        #if os(visionOS)
        .buttonStyle(.plain)
        #endif
        .appleTraceScreen("title", detail: "\(item.name) (\(item.mediaID))")
        .navigationTitle("")
        #if os(iOS) || os(visionOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        #endif
        #if os(iOS)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        #if os(tvOS)
        // The backdrop fills 1920x1080; the tab bar returns when Menu pops.
        .toolbar(.hidden, for: .tabBar)
        #endif
        .alert(
            "Download to \(arrRequestKind?.displayName ?? "ARR")",
            isPresented: Binding(
                get: { arrRequestKind != nil },
                set: { if !$0 { arrRequestKind = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { arrRequestKind = nil }
            Button("Add to Queue") {
                guard let kind = arrRequestKind else { return }
                arrRequestKind = nil
                Task { await enqueueARR(kind) }
            }
        } message: {
            Text("Add \(item.name) to your configured \(arrRequestKind?.displayName ?? "ARR") queue?")
        }
        .alert(
            "Download Request",
            isPresented: Binding(
                get: { arrFeedback != nil },
                set: { if !$0 { arrFeedback = nil } }
            )
        ) {
            Button("OK", role: .cancel) { arrFeedback = nil }
        } message: {
            Text(arrFeedback ?? "")
        }
        .confirmationDialog(
            "Download Options",
            isPresented: $downloadActionsPresented,
            titleVisibility: .visible
        ) {
            switch downloadCoordinator.state {
            case .downloading where downloadCoordinator.supportsPauseResume:
                Button("Pause") { downloadCoordinator.pause() }
            case .paused:
                Button("Resume") { downloadCoordinator.resume() }
            default:
                EmptyView()
            }
            if downloadCoordinator.state.ownsDownload {
                Button("Cancel", role: .destructive) { downloadCoordinator.cancel() }
            }
        } message: {
            Text(downloadActionMessage)
        }
        .confirmationDialog(
            "Season Download Options",
            isPresented: $seasonDownloadActionsPresented,
            titleVisibility: .visible
        ) {
            switch downloadCoordinator.state {
            case .downloading where downloadCoordinator.supportsPauseResume:
                Button("Pause") { downloadCoordinator.pause() }
            case .paused:
                Button("Resume") { downloadCoordinator.resume() }
            default:
                EmptyView()
            }
            Button("Cancel", role: .destructive) {
                seasonDownloads.cancel()
                downloadCoordinator.cancel()
            }
        } message: {
            Text(seasonDownloadMessage)
        }
        .sheet(isPresented: $streamPickerPresented) {
            streamPicker
                #if os(visionOS)
                .frame(width: 720, height: 540)
                #endif
        }
        .task(id: playRequest) {
            guard playRequest != nil else { return }
            await resolvePlayback()
        }
        .task(id: "trailer-delay:\(item.id):\(allowsTrailerAutoplay)") {
            trailerIsActive = false
            trailerIsPlaying = false
            trailerHasStarted = false
            trailerMuted = settings.autoMuteTrailer
            guard allowsTrailerAutoplay else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            guard let playableIndex = await resolvePlayableTrailerCandidateIndex(startingAt: trailerCandidateIndex) else { return }
            guard !Task.isCancelled else { return }
            trailerCandidateIndex = playableIndex
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.45)) {
                prepareTrailerAudio()
                trailerHasStarted = true
                trailerIsActive = true
            }
        }
        .onChange(of: settings.autoMuteTrailer) { _, muted in trailerMuted = muted }
        .task(id: "title-logo:\(titleLogoURL?.absoluteString ?? "")") {
            titleLogoLoadResult = nil
            guard let logoURL = titleLogoURL else {
                titleLogoState = .unavailable
                return
            }
            titleLogoState = .loading
            #if DEBUG
            AppleLaunchClock.mark("detail.logoURL")
            #endif
            guard await AppleTransparentPNGLogoValidator.isValid(url: logoURL), !Task.isCancelled else {
                if !Task.isCancelled { titleLogoState = .unavailable }
                return
            }
            #if DEBUG
            AppleLaunchClock.mark("detail.validated")
            #endif
            titleLogoState = .valid(logoURL)
        }
        // Keyed by the item only: a wordmark URL that arrives late must not
        // hide a text title that is already on screen; the text stays until
        // the wordmark has actually loaded.
        .task(id: "title-logo-grace:\(item.id)") {
            titleLogoGraceExpired = false
            try? await Task.sleep(for: .seconds(AppleTitleLogoPolicy.loadingGrace))
            guard !Task.isCancelled else { return }
            titleLogoGraceExpired = true
        }
        .task(id: item.id) {
            trailerCandidateIndex = 0
            trailerIsActive = false
            trailerIsPlaying = false
            trailerMuted = settings.autoMuteTrailer
            titleLogoLoadResult = nil
            titleLogoGraceExpired = false
            #if DEBUG
            AppleLaunchClock.mark("detail.task")
            #endif
            // Recording that this title was opened is bookkeeping. Awaiting it
            // cost ~294 ms — a disk write plus a rebuild of the whole record
            // array — and the favourite lookup another ~219 ms, all of it
            // before the page asked for the metadata it is about to draw.
            // The favourite state is read first (a new record is never a
            // favourite, so the answer is the same either way), the write runs
            // on its own, and the metadata starts immediately.
            isFavorite = mediaIndex.record(id: recordID)?.isFavorite ?? false
            let viewedRecord = AppleMediaIngestion.catalogRecord(instanceID: source.id, item: item)
            Task { try? await mediaIndex.upsert(viewedRecord) }
            #if DEBUG
            AppleLaunchClock.mark("detail.prepare")
            #endif
            await prepare()
            await refreshOfflineState()
            if initialAutoPlay { playRequest = UUID() }
        }
        .task(id: "similar:\(item.id):\(relatedItems.count):\(metadataDetails?.mediaID ?? "")") {
            await refreshSuggestions()
        }
        .onPreferenceChange(AppleDetailHeroFramePreferenceKey.self) { frame in
            #if os(iOS)
            // Rotation can briefly report a stale frame. Stop only after the
            // hero has actually scrolled above the viewport.
            if frame != .zero, frame.maxY <= 0, trailerIsActive { pauseTrailerPreview() }
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active else { return }
            pauseTrailerPreview()
        }
        .onDisappear {
            pauseTrailerPreview()
            seasonDownloads.cancel()
            if downloadCoordinator.state.ownsDownload { downloadCoordinator.cancel() }
        }
        .task(id: "offline:\(selectedEpisodeID ?? ""):\(seasonDownloads.isRunning)") {
            guard !seasonDownloads.isRunning, !downloadCoordinator.state.ownsDownload else { return }
            await refreshOfflineState()
        }
        .task(id: "downloaded-episodes:\(episodes.count):\(seasonDownloads.completed):\(downloadCoordinator.state.isCompleted)") {
            await refreshDownloadedEpisodeIDs()
        }
        .onChange(of: selectedSeason) { _, season in
            selectedEpisodeID = nextUnwatchedEpisodeID(in: season, from: episodes)
        }
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(
            for: UIAccessibility.videoAutoplayStatusDidChangeNotification
        )) { _ in
            systemVideoAutoplayEnabled = UIAccessibility.isVideoAutoplayEnabled
        }
        #endif
        .modifier(AppleStremioPlayerPresentationModifier(presentation: $playerPresentation))
        .alert("Playback Unavailable", isPresented: Binding(
            get: {
                if case .failed = playbackCoordinator.phase { return true }
                return false
            },
            set: { if !$0 { playbackCoordinator.reset() } }
        )) {
            Button("Retry") {
                playbackCoordinator.reset()
                playRequest = UUID()
            }
            Button("Close", role: .cancel) { playbackCoordinator.reset() }
        } message: {
            if case .failed(let failure) = playbackCoordinator.phase {
                Text(failure.message)
            }
        }
    }

    @ViewBuilder
    private var detailHero: some View {
        detailHeroContent
            .frame(maxWidth: .infinity)
            .frame(height: heroHeight)
    }

    private var detailHeroContent: some View {
        GeometryReader { proxy in
            ZStack {
            heroArtwork
                .contentShape(Rectangle())
                .onTapGesture { toggleTrailerPlayback() }
                .frame(maxWidth: .infinity)
                .frame(height: heroHeight)
                .clipped()

            #if os(iOS) || os(visionOS)
            if trailerHasStarted, let embedURL = trailerEmbedURL,
               !playbackCoordinator.phase.isBusy,
               playerPresentation == nil {
                AppleYouTubeAutoPreview(
                    url: embedURL,
                    artworkURL: heroArtworkURL,
                    isLandscape: viewportSize.width > viewportSize.height,
                    isPlaying: $trailerIsActive,
                    isMuted: $trailerMuted,
                    replayGeneration: $trailerReplayGeneration,
                    showsReplay: !trailerIsActive,
                    onStateChange: handleTrailerState,
                    onTap: toggleTrailerPlayback,
                    onMute: { trailerMuted.toggle() },
                    onReplay: restartTrailer
                )
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: .infinity)
            }
            #endif

            if !isLandscapeLayout, case .valid = titleLogoState, let logoURL = titleLogoURL {
                AppleTrimmedTitleLogo(url: logoURL) { loaded in
                    titleLogoLoadResult = loaded
                    #if DEBUG
                    AppleLaunchClock.mark(loaded ? "detail.wordmark" : "detail.wordmark.failed")
                    #endif
                }
                    .frame(width: proxy.size.width * titleLogoWidthFraction, height: titleLogoHeight)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .position(
                        x: proxy.size.width / 2,
                        y: proxy.size.height - AppleDetailMetrics.titleLogoBottomBuffer - titleLogoHeight / 2
                    )
                    .opacity(trailerIsPlaying || titleLogoPresentation != .logo ? 0 : 1)
                    .animation(reduceMotion ? nil : .easeInOut(duration: AppleDetailMetrics.trailerCrossfadeDuration), value: trailerIsPlaying)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(item.name)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityHidden(trailerIsActive)
            }

            if isLandscapeLayout {
                landscapeHeroOverlay(in: proxy.size)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(.leading, overlayLeadingMargin)
                    .padding(.bottom, overlayBottomMargin)
                    .opacity(landscapeOverlaysVisible ? 1 : 0)
                    .allowsHitTesting(landscapeOverlaysVisible)
                    .accessibilityHidden(!landscapeOverlaysVisible)
                    .animation(
                        reduceMotion ? nil : .easeInOut(duration: 0.35),
                        value: landscapeOverlaysVisible
                    )
            } else {
            }

            if isLandscapeLayout, let trailerInteractionGlyph {
                Image(systemName: trailerInteractionGlyph)
                    .font(.system(size: 56))
                    .foregroundStyle(.white.opacity(0.70))
                    .transition(.opacity)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
            }

            #if !os(visionOS)
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(
                        isLandscapeLayout ? .clear : .black.opacity(0.48),
                        in: Circle()
                    )
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back")
            .padding(.leading, isLandscapeLayout ? 12 + detailSafeAreaInsets.leading : 12)
            .padding(.top, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .opacity(trailerIsPlaying ? 0 : 1)
            .allowsHitTesting(!trailerIsPlaying)
            .accessibilityHidden(trailerIsPlaying)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: trailerIsPlaying)
            #endif
        }
        }
        .frame(maxWidth: .infinity)
        .frame(height: heroHeight)
        .background(.black)
        .clipped()
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: AppleDetailHeroFramePreferenceKey.self,
                    value: proxy.frame(in: .named("detail-scroll"))
                )
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var heroHeight: CGFloat {
        #if os(tvOS)
        460
        #elseif os(visionOS)
        min(viewportSize.height * 0.78, viewportSize.width * 9 / 16)
        #elseif os(iOS)
        AppleDetailMetrics.heroHeight(
            in: viewportSize,
            horizontalSizeClassIsRegular: horizontalSizeClass == .regular
        )
        #else
        420
        #endif
    }

    private var titleLogoHeight: CGFloat { AppleDetailMetrics.titleLogoMaxHeight }

    private var titleLogoWidthFraction: CGFloat {
        isLandscapeLayout
            ? AppleDetailMetrics.landscapeTitleLogoWidthFraction
            : AppleDetailMetrics.titleLogoWidthFraction
    }

    private var viewportSize: CGSize {
        #if os(visionOS)
        detailViewportSize == .zero ? CGSize(width: 1100, height: 760) : detailViewportSize
        #elseif os(iOS)
        detailViewportSize
        #else
        .zero
        #endif
    }

    private var isLandscapeRegularLayout: Bool {
        #if os(visionOS)
        viewportSize.width >= 760 && viewportSize.width > viewportSize.height
        #elseif os(iOS)
        horizontalSizeClass == .regular
            && viewportSize.width > viewportSize.height
        #else
        false
        #endif
    }

    /// Landscape on any device, including the compact phone. Drives the
    /// full-screen hero and its overlaid title, metadata and actions.
    private var isLandscapeLayout: Bool {
        #if os(visionOS)
        isLandscapeRegularLayout
        #elseif os(iOS)
        AppleDetailMetrics.isLandscapeLayout(viewport: viewportSize)
        #else
        false
        #endif
    }

    /// Phone landscape: same layout as the iPad, tighter metrics.
    private var isCompactLandscapeLayout: Bool {
        isLandscapeLayout && !isLandscapeRegularLayout
    }

    private var overlayLeadingMargin: CGFloat {
        isCompactLandscapeLayout
            ? AppleDetailMetrics.compactLandscapeOverlayLeadingMargin + detailSafeAreaInsets.leading
            : AppleDetailMetrics.landscapeOverlayLeadingMargin
    }

    private var overlayBottomMargin: CGFloat {
        isCompactLandscapeLayout
            ? max(AppleDetailMetrics.compactLandscapeOverlayBottomMargin, detailSafeAreaInsets.bottom)
            : AppleDetailMetrics.landscapeOverlayBottomMargin
    }

    private var overlayLogoMaxWidth: CGFloat {
        isCompactLandscapeLayout
            ? AppleDetailMetrics.compactLandscapeLogoMaxWidth
            : AppleDetailMetrics.landscapeLogoMaxWidth
    }

    private var overlayLogoMaxHeight: CGFloat {
        isCompactLandscapeLayout
            ? AppleDetailMetrics.compactLandscapeLogoMaxHeight
            : AppleDetailMetrics.landscapeLogoMaxHeight
    }

    private var landscapeOverlaysVisible: Bool {
        !trailerIsPlaying
    }

    private var isWideLandscape: Bool {
        isLandscapeRegularLayout && viewportSize.width >= AppleDetailMetrics.wideEpisodeThreshold
    }

    private func landscapeHeroOverlay(in heroSize: CGSize) -> some View {
        VStack(alignment: .leading, spacing: AppleDetailMetrics.landscapeOverlaySpacing) {
            if case .valid = titleLogoState, let logoURL = titleLogoURL {
                ZStack(alignment: .leading) {
                    AppleTrimmedTitleLogo(url: logoURL, alignment: .leading) { loaded in
                    titleLogoLoadResult = loaded
                    #if DEBUG
                    AppleLaunchClock.mark(loaded ? "detail.wordmark" : "detail.wordmark.failed")
                    #endif
                }
                        .frame(
                            width: min(
                                heroSize.width * AppleDetailMetrics.landscapeTitleLogoWidthFraction,
                                overlayLogoMaxWidth
                            ),
                            height: overlayLogoMaxHeight,
                            alignment: .leading
                        )
                        .opacity(trailerIsPlaying || titleLogoPresentation != .logo ? 0 : 1)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(item.name)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityHidden(trailerIsPlaying || titleLogoPresentation != .logo)

                    trailerTitleText
                        .opacity(trailerIsPlaying || titleLogoPresentation == .text ? 1 : 0)
                        .accessibilityHidden(!trailerIsPlaying && titleLogoPresentation != .text)
                }
                .frame(
                    width: min(
                        heroSize.width * AppleDetailMetrics.landscapeTitleLogoWidthFraction,
                        overlayLogoMaxWidth
                    ),
                    height: trailerIsPlaying ? AppleDetailMetrics.landscapeTitleFontSize : overlayLogoMaxHeight,
                    alignment: .leading
                )
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: AppleDetailMetrics.trailerCrossfadeDuration),
                    value: trailerIsPlaying
                )
            } else {
                trailerTitleText
                    .opacity(titleLogoPresentation == .hidden ? 0 : 1)
                    .accessibilityHidden(titleLogoPresentation == .hidden)
            }

            titleMetadata
                .frame(width: actionColumnWidth, alignment: .leading)
            primaryActionButtons
            seasonDownloadStatus
            secondaryActionRow
        }
    }

    private var trailerTitleText: some View {
        Text(displayTitle)
            .font(.system(size: isLandscapeLayout ? AppleDetailMetrics.landscapeTitleFontSize : AppleDetailMetrics.portraitTitleFontSize, weight: .semibold))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .shadow(color: .black.opacity(0.6), radius: 6, y: 1)
            .accessibilityAddTraits(.isHeader)
            .animation(
            reduceMotion ? nil : .easeInOut(duration: AppleDetailMetrics.trailerCrossfadeDuration),
                value: trailerIsPlaying
            )
    }

    private var portraitTrailerTitle: some View {
        trailerTitleText
            .frame(height: trailerIsPlaying ? 20 : 0, alignment: .leading)
            .clipped()
            .opacity(trailerIsPlaying ? 1 : 0)
            .accessibilityHidden(!trailerIsPlaying)
            .animation(
            reduceMotion ? nil : .easeInOut(duration: AppleDetailMetrics.trailerCrossfadeDuration),
                value: trailerIsActive
            )
    }

    #if os(tvOS)
    // MARK: - Apple TV title page (FEEDBACK rework plan, task 5)

    /// Full-screen backdrop with the title block anchored bottom-leading at
    /// (80, bottom 60); scrolling down reveals the synopsis, Episodes and
    /// More Like This. There is no back control (Menu pops the page) and no
    /// Download action. tvOS has no WebKit, so the trailer is a native HLS
    /// preview (`AppleYouTubeStreamResolver` + `AppleTVTrailerPlayerView`)
    /// that fades in over the backdrop about two seconds after the page
    /// settles and fades out when it ends; failures stay silent. Every number
    /// comes from `AppleTVDetailMetrics`.
    private var tvOSDetailLayout: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                tvOSHero
                tvOSBelowFold
            }
        }
        .scrollClipDisabled()
        .ignoresSafeArea()
        .defaultFocus($tvDetailFocus, .play)
        .onAppear {
            // Belt and braces: the 18:30 capture showed Play unfocused on
            // open, so the page asks for it explicitly as well.
            if tvDetailFocus == nil { tvDetailFocus = .play }
        }
        .onChange(of: rateChoicesExpanded) { _, expanded in
            if !expanded { tvDetailFocus = .rate }
        }
        .task(id: trailerCandidates) { await startTVTrailerPreview() }
        .onChange(of: playerPresentation == nil) { _, closed in
            // Never play the preview under the full-screen player.
            if !closed { hideTVTrailerPreview() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { _ in
            if tvTrailerVisible { hideTVTrailerPreview() }
        }
        .onDisappear { hideTVTrailerPreview() }
    }

    private func startTVTrailerPreview() async {
        hideTVTrailerPreview()
        tvTrailerSource = nil
        let candidates = trailerCandidates
        // Six separate silent exits used to sit between here and a playing
        // trailer, so "trailers still aren't working" could mean any of them.
        // Each one now says so.
        guard allowsTrailerAutoplay else {
            appleTraceFailure("trailer \"\(item.name)\": autoplay off (setting=\(settings.autoPlayTrailer) reduceMotion=\(reduceMotion))")
            return
        }
        guard !candidates.isEmpty else {
            appleTraceFailure("trailer \"\(item.name)\": no candidates (metadata=\(metadataDetails?.trailerYouTubeKeys.count ?? -1) preview=\(previewAssets?.trailerYouTubeKeys.count ?? -1))")
            return
        }
        appleTrace("trailer \"\(item.name)\": \(candidates.count) candidate(s) \(candidates.joined(separator: ","))")
        try? await Task.sleep(for: .seconds(2))
        guard !Task.isCancelled else { return }
        guard let index = await resolvePlayableTrailerCandidateIndex(startingAt: 0),
              !Task.isCancelled else {
            appleTraceFailure("trailer \"\(item.name)\": every candidate rejected by the aspect probe (portrait=\(trailerPortraitKeys.count) landscape=\(trailerLandscapeKeys.count))")
            return
        }
        let key = candidates[index]
        do {
            let stream = try await AppleYouTubeStreamResolver.shared.resolve(videoID: key)
            guard !Task.isCancelled, playerPresentation == nil else {
                appleTraceFailure("trailer \"\(item.name)\": resolved but discarded (cancelled=\(Task.isCancelled) playerOpen=\(playerPresentation != nil))")
                return
            }
            prepareTrailerAudio()
            let kind = if case .hls = stream.source { "hls" } else { "adaptive" }
            appleTrace("trailer \"\(item.name)\" candidate \(index) resolved as \(kind)")
            withAnimation(reduceMotion ? nil : .easeInOut(duration: AppleDetailMetrics.trailerCrossfadeDuration)) {
                tvTrailerSource = stream.source
                tvTrailerVisible = true
            }
        } catch {
            appleTraceFailure("trailer \"\(item.name)\" candidate \(index) failed: \(error)")
        }
    }

    private func hideTVTrailerPreview() {
        guard tvTrailerVisible else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: AppleDetailMetrics.trailerCrossfadeDuration)) {
            tvTrailerVisible = false
        }
    }

    private var tvOSHero: some View {
        ZStack(alignment: .bottomLeading) {
            heroArtwork
                .frame(
                    width: AppleTVDetailMetrics.screenSize.width,
                    height: AppleTVDetailMetrics.screenSize.height
                )
                .clipped()
                .accessibilityHidden(true)
            if let tvTrailerSource, tvTrailerVisible {
                AppleTVTrailerPlayerView(source: tvTrailerSource)
                    .frame(
                        width: AppleTVDetailMetrics.screenSize.width,
                        height: AppleTVDetailMetrics.screenSize.height
                    )
                    .clipped()
                    .transition(.opacity)
                    .accessibilityHidden(true)
            }
            tvOSHeroOverlay
                .padding(.leading, AppleTVDetailMetrics.overlayLeadingInset)
                .padding(.bottom, AppleTVDetailMetrics.overlayBottomInset)
        }
        .frame(
            width: AppleTVDetailMetrics.screenSize.width,
            height: AppleTVDetailMetrics.screenSize.height,
            alignment: .bottomLeading
        )
        .background(.black)
        .focusSection()
        .accessibilityElement(children: .contain)
    }

    private var tvOSHeroOverlay: some View {
        VStack(alignment: .leading, spacing: AppleTVDetailMetrics.overlaySpacing) {
            tvOSTitleBlock
            titleMetadata
                .frame(width: AppleTVDetailMetrics.overlayColumnWidth, alignment: .leading)
            HStack(alignment: .appleTVControlCenter, spacing: AppleTVDetailMetrics.pillToIconSpacing) {
                tvOSPlayButton
                tvOSIconRow
            }
        }
    }

    /// Same policy as the other platforms: the wordmark when it has loaded,
    /// the text title only if it fails, nothing while it resolves.
    @ViewBuilder
    private var tvOSTitleBlock: some View {
        if case .valid = titleLogoState, let logoURL = titleLogoURL {
            ZStack(alignment: .leading) {
                AppleTrimmedTitleLogo(url: logoURL, alignment: .leading) { loaded in
                    titleLogoLoadResult = loaded
                    #if DEBUG
                    AppleLaunchClock.mark(loaded ? "detail.wordmark" : "detail.wordmark.failed")
                    #endif
                }
                    .frame(
                        width: AppleTVDetailMetrics.wordmarkMaxSize.width,
                        height: AppleTVDetailMetrics.wordmarkMaxSize.height,
                        alignment: .leading
                    )
                    .opacity(titleLogoPresentation == .logo ? 1 : 0)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(item.name)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityHidden(titleLogoPresentation != .logo)
                tvOSTitleText
                    .opacity(titleLogoPresentation == .text ? 1 : 0)
                    .accessibilityHidden(titleLogoPresentation != .text)
            }
        } else {
            tvOSTitleText
                .opacity(titleLogoPresentation == .hidden ? 0 : 1)
                .accessibilityHidden(titleLogoPresentation == .hidden)
        }
    }

    private var tvOSTitleText: some View {
        Text(displayTitle)
            .font(.system(size: AppleTVDetailMetrics.titleFontSize, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(AppleTVDetailMetrics.titleLineLimit)
            .truncationMode(.tail)
            .frame(maxWidth: AppleTVDetailMetrics.overlayColumnWidth, alignment: .leading)
            .shadow(color: .black.opacity(0.6), radius: 6, y: 1)
            .accessibilityAddTraits(.isHeader)
    }

    private var tvOSPlayIsBusy: Bool {
        playbackCoordinator.phase.isBusy || isPreparingMetadata
    }

    /// Stays focusable while metadata prepares so the default focus lands on
    /// it immediately; the press is ignored until playback can start.
    private var tvOSPlayButton: some View {
        Button {
            guard canStartPlayback else { return }
            playRequest = UUID()
        } label: {
            HStack(spacing: AppleTVDetailMetrics.pillGlyphSpacing) {
                if tvOSPlayIsBusy {
                    ProgressView().tint(.black)
                } else {
                    Image(systemName: "play.fill")
                        .font(.system(size: AppleTVDetailMetrics.pillGlyphSize, weight: .semibold))
                }
                Text(tvOSPlayIsBusy ? (playbackCoordinator.phase.isBusy ? "Preparing" : "Loading") : "Play")
            }
        }
        .buttonStyle(AppleTVPillStyle(
            isSelected: true,
            minimumSize: AppleTVDetailMetrics.pillSize,
            fontSize: AppleTVDetailMetrics.pillFontSize
        ))
        .focused($tvDetailFocus, equals: .play)
        .accessibilityLabel(tvOSPlayIsBusy ? "Preparing playback" : "Play")
        .accessibilityIdentifier("detail.play")
        .contextMenu {
            Button("Other sources", systemImage: "list.bullet") {
                Task { await chooseStreams() }
            }
        }
    }

    private var tvOSIconRow: some View {
        HStack(alignment: .appleTVControlCenter, spacing: 0) {
            Button(action: toggleFavorite) {
                AppleTVDetailIconLabel(title: "My List", systemImage: isFavorite ? "checkmark" : "plus")
            }
            .buttonStyle(AppleTVBareButtonStyle())
            .focused($tvDetailFocus, equals: .myList)
            .accessibilityLabel(isFavorite ? "Remove from My List" : "Add to My List")
            .accessibilityValue(isFavorite ? "Saved" : "Not saved")
            tvOSRateControl
        }
        .accessibilityIdentifier("detail.icon-row")
    }

    /// Rate expands in place into the three choices at the same 120 pt pitch.
    @ViewBuilder
    private var tvOSRateControl: some View {
        if rateChoicesExpanded {
            ForEach(Array(AppleTitleRating.selectableCases.enumerated()), id: \.offset) { index, value in
                Button {
                    selectRating(value)
                } label: {
                    AppleTVDetailIconLabel(
                        title: value.title,
                        systemImage: ratingGlyph(for: value, selected: rating == value)
                    )
                }
                .buttonStyle(AppleTVBareButtonStyle())
                .focused($tvDetailFocus, equals: .rateChoice(index))
                .accessibilityLabel(value.title)
                .accessibilityAddTraits(rating == value ? .isSelected : [])
            }
        } else {
            Button {
                withAnimation(rateAnimation) { rateChoicesExpanded = true }
                // Hand focus to the first choice in the same breath. The Rate
                // button is gone by the next update, and focus with nowhere to
                // go falls back to `defaultFocus`, which is Play.
                tvDetailFocus = .rateChoice(0)
            } label: {
                AppleTVDetailIconLabel(
                    title: "Rate",
                    systemImage: ratingGlyph(for: rating, selected: rating != nil)
                )
            }
            .buttonStyle(AppleTVBareButtonStyle())
            .focused($tvDetailFocus, equals: .rate)
            .accessibilityLabel("Rate")
            .accessibilityValue(rating?.title ?? "Not rated")
        }
    }

    private var tvOSBelowFold: some View {
        VStack(alignment: .leading, spacing: AppleTVDetailMetrics.sectionSpacing) {
            if let summary = AppleMetadataPresentationPolicy.synopsis(
                catalog: item.summary,
                enriched: metadataDetails?.overview
            ) {
                AppleTVFocusableParagraph(text: summary)
                    .padding(.horizontal, AppleTVDetailMetrics.overlayLeadingInset)
            }
            // Sits with the synopsis, in secondary text, competing with
            // nothing. It is a line of prose rather than a second Play.
            AppleWatchProviderRow(providers: watchProviders)
                .padding(.horizontal, AppleTVDetailMetrics.overlayLeadingInset)
            if item.type == "series" {
                tvOSEpisodeShelf
                    .id("vision-episodes")
            }
            if !suggestedItems.isEmpty {
                tvOSMoreLikeThisShelf
            }
        }
        .padding(.top, AppleTVDetailMetrics.sectionSpacing)
        .padding(.bottom, AppleTVDetailMetrics.overlayBottomInset)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var tvOSEpisodeShelf: some View {
        VStack(alignment: .leading, spacing: AppleTVDetailMetrics.shelfTitleSpacing) {
            AppleTVShelfTitle(title: "Episodes")
            if seasonNumbers.count > 1 {
                tvOSSeasonRow
            } else if let season = selectedSeason {
                Text(seasonName(season))
                    .font(.system(size: AppleTVDetailMetrics.seasonPillFontSize))
                    .foregroundStyle(AppleDesignTokens.textSecondary)
                    .padding(.horizontal, AppleTVDetailMetrics.overlayLeadingInset)
            }
            if isLoadingEpisodes {
                ProgressView()
                    .tint(.white)
                    .padding(.horizontal, AppleTVDetailMetrics.overlayLeadingInset)
            } else if episodes.isEmpty {
                Text("Episodes aren’t available from the connected metadata sources.")
                    .font(.system(size: AppleTVDetailMetrics.episodeTitleFontSize))
                    .foregroundStyle(AppleDesignTokens.textSecondary)
                    .padding(.horizontal, AppleTVDetailMetrics.overlayLeadingInset)
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: AppleTVDetailMetrics.episodeCardGap) {
                        ForEach(visibleEpisodes) { episode in
                            AppleTVEpisodeCard(
                                episode: episode,
                                subtitle: episodeMetadata(episode),
                                isSelected: selectedEpisodeID == episode.id
                            ) {
                                selectedEpisodeID = episode.id
                                playRequest = UUID()
                            }
                        }
                    }
                    .padding(.vertical, AppleTVDetailMetrics.shelfVerticalBleed)
                }
                .contentMargins(.horizontal, AppleTVDetailMetrics.overlayLeadingInset, for: .scrollContent)
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
                .focusSection()
            }
        }
        .accessibilityIdentifier("detail.episodes")
    }

    private var tvOSCurrentSeason: Int {
        selectedSeason ?? seasonNumbers.first ?? 1
    }

    /// One dropdown showing the current season instead of a pill per season
    /// (owner 16:28). A single-season title shows the label alone.
    @ViewBuilder
    private var tvOSSeasonRow: some View {
        if seasonNumbers.count > 1 {
            Menu {
                ForEach(seasonNumbers, id: \.self) { season in
                    Button {
                        selectedSeason = season
                    } label: {
                        if selectedSeason == season {
                            Label(seasonName(season), systemImage: "checkmark")
                        } else {
                            Text(seasonName(season))
                        }
                    }
                }
            } label: {
                HStack(spacing: AppleTVDetailMetrics.pillGlyphSpacing) {
                    Text(seasonName(tvOSCurrentSeason))
                    Image(systemName: "chevron.down")
                        .font(.system(size: AppleTVDetailMetrics.seasonPillFontSize * 0.7, weight: .semibold))
                }
            }
            .menuStyle(.button)
            .buttonStyle(AppleTVPillStyle(
                isSelected: false,
                minimumSize: CGSize(width: 0, height: AppleTVDetailMetrics.seasonPillHeight),
                fontSize: AppleTVDetailMetrics.seasonPillFontSize
            ))
            .padding(.leading, AppleTVDetailMetrics.overlayLeadingInset)
            .padding(.vertical, 12)
            .accessibilityLabel("Season")
            .accessibilityValue(seasonName(tvOSCurrentSeason))
            .accessibilityIdentifier("detail.season")
        } else {
            Text(seasonName(tvOSCurrentSeason))
                .font(.system(size: AppleTVDetailMetrics.seasonPillFontSize, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
                .padding(.leading, AppleTVDetailMetrics.overlayLeadingInset)
                .padding(.vertical, 12)
                .accessibilityIdentifier("detail.season")
        }
    }

    private var tvOSMoreLikeThisShelf: some View {
        VStack(alignment: .leading, spacing: AppleTVDetailMetrics.shelfTitleSpacing) {
            AppleTVShelfTitle(title: "More Like This")
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: AppleTVDetailMetrics.posterGap) {
                    ForEach(suggestedItems) { suggestion in
                        NavigationLink {
                            AppleCatalogItemDetailView(
                                item: suggestion,
                                source: source,
                                relatedItems: relatedItems,
                                mediaIndex: mediaIndex,
                                playbackSources: playbackSources,
                                metadataConfiguration: metadataConfiguration,
                                gatewayConfig: gatewayConfig,
                                streamingServerConfiguration: streamingServerConfiguration,
                                playbackResolver: playbackResolver,
                                settings: settings,
                                openSettings: openSettings
                            )
                        } label: {
                            AppleTVPosterCard(item: suggestion)
                        }
                        .buttonStyle(AppleTVDetailCardStyle())
                        .accessibilityIdentifier("detail.similar.\(suggestion.id)")
                    }
                }
                .padding(.vertical, AppleTVDetailMetrics.shelfVerticalBleed)
            }
            .contentMargins(.horizontal, AppleTVDetailMetrics.overlayLeadingInset, for: .scrollContent)
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
            .focusSection()
        }
        .accessibilityIdentifier("detail.more-like-this")
    }
    #endif

    private var heroArtwork: some View {
        AppleCatalogArtwork(url: heroArtworkURL)
    }

    private var heroArtworkURL: URL? {
        metadataDetails?.backdropURL
                ?? item.backgroundURL
                ?? metadataDetails?.posterURL
                ?? item.posterURL
                ?? fallbackArtwork?.backgroundURL
                ?? fallbackArtwork?.posterURL
    }

    private var displayTitle: String {
        metadataDetails?.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? metadataDetails?.title ?? item.name
            : item.name
    }

    private var displayReleaseInfo: String? {
        let value = metadataDetails?.releaseInfo ?? item.releaseInfo
        let clean = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return clean.isEmpty ? nil : clean
    }

    private var titleLogoURL: URL? {
        metadataDetails?.logoURL ?? previewAssets?.logoURL
    }

    private var trailerEmbedURL: URL? {
        AppleTrailerPreviewPolicy.embedURL(for: trailerKey)
    }

    private var trailerKey: String? {
        guard trailerCandidateIndex < trailerCandidates.count else { return nil }
        return trailerCandidates[trailerCandidateIndex]
    }

    private var trailerCandidates: [String] {
        let keys = (metadataDetails?.trailerYouTubeKeys ?? [])
            + (previewAssets?.trailerYouTubeKeys ?? [])
        var seen = Set<String>()
        return keys.filter { seen.insert($0).inserted }
    }

    private var allowsTrailerAutoplay: Bool {
        #if os(visionOS) || os(tvOS)
        settings.autoPlayTrailer && !reduceMotion
        #elseif os(iOS)
        settings.autoPlayTrailer && AppleTrailerPreviewPolicy.shouldAutoplay(
            reduceMotion: reduceMotion,
            systemVideoAutoplayEnabled: systemVideoAutoplayEnabled
        )
        #else
        false
        #endif
    }

    private var streamPicker: some View {
        NavigationStack {
            List {
                ForEach(localFiles) { file in
                    Button {
                        selectedLocalFile = file
                        selectedStream = nil
                        streamPickerPresented = false
                        playRequest = UUID()
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Local · \(library.sources.first { $0.id == file.sourceID }?.name ?? "Library")")
                                .font(.body.weight(.medium))
                            Text(AppleLocalLibraryStore.format(file)).font(.caption).foregroundStyle(.secondary)
                        }
                    }.accessibilityIdentifier("detail.other-sources.local")
                }
                ForEach(Array(streamChoices.enumerated()), id: \.offset) { index, candidate in
                    Button {
                        selectedLocalFile = nil
                        selectedStream = candidate
                        streamPickerPresented = false
                        playRequest = UUID()
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(appleStreamDisplayText(candidate.title))
                                .font(.body.weight(.medium))
                                .foregroundStyle(.primary)
                            if let sourceName = candidate.sourceName {
                                Text("via \(appleStreamDisplayText(sourceName))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityIdentifier("detail.other-sources.\(index)")
                }
            }
            .scrollIndicators(AppleDesignTokens.scrollIndicatorVisibility)
            .navigationTitle("Other sources")
            #if os(iOS) || os(visionOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
        .presentationDetents([.medium])
    }

    private func toggleTrailerPlayback() {
        #if os(tvOS)
        logTrailerFailure("YouTube embed is unavailable on Apple TV")
        return
        #else
        guard trailerEmbedURL != nil else {
            logTrailerFailure("no trailer is available for this title")
            return
        }
        trailerHasStarted = true
        prepareTrailerAudio()
        let shouldPlay = !trailerIsActive
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
            trailerIsActive = shouldPlay
            trailerIsPlaying = false
        }
        if isLandscapeLayout {
            showTrailerInteractionGlyph(shouldPlay ? "play.circle.fill" : "pause.circle.fill")
        }
        #endif
    }

    private func restartTrailer() {
        prepareTrailerAudio()
        guard trailerEmbedURL != nil else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: AppleDetailMetrics.trailerCrossfadeDuration)) {
            trailerIsActive = true
            trailerIsPlaying = false
        }
        trailerReplayGeneration &+= 1
    }

    private func pauseTrailerPreview() {
        guard trailerIsActive else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
            trailerIsActive = false
            trailerIsPlaying = false
        }
    }

    private func prepareTrailerAudio() {
        #if os(iOS) || os(tvOS) || os(visionOS)
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("[OpenStream] trailer audio unavailable: \(error.localizedDescription)")
        }
        #endif
    }

    private func handleTrailerState(_ state: String, muted: Bool, errorCode: Int?) {
        print("[OpenStream] trailer title=\(item.name) candidate=\(trailerCandidateIndex) state=\(state) error=\(errorCode.map(String.init) ?? "none") active=\(trailerIsActive)")
        if state == "autoplay-blocked" {
            showTrailerArtworkOnly()
            logTrailerFailure("autoplay was blocked by the video provider")
            return
        }
        if state == "error" {
            trailerIsActive = false
            trailerIsPlaying = false
            trailerMuted = settings.autoMuteTrailer
            let nextIndex = trailerCandidateIndex + 1
            let candidates = trailerCandidates
            if nextIndex < candidates.count {
                Task { @MainActor in
                    guard let playableIndex = await resolvePlayableTrailerCandidateIndex(startingAt: nextIndex) else {
                        trailerCandidateIndex = candidates.count
                        showTrailerArtworkOnly()
                        logTrailerFailure("video provider could not play this trailer (error \(errorCode.map(String.init) ?? "unknown"))")
                        return
                    }
                    trailerCandidateIndex = playableIndex
                    trailerIsActive = true
                }
            } else {
                trailerCandidateIndex = candidates.count
                showTrailerArtworkOnly()
                logTrailerFailure("video provider could not play this trailer (error \(errorCode.map(String.init) ?? "unknown"))")
            }
            return
        }
        trailerMuted = muted
        if state == "revealed", trailerIsActive {
            trailerIsPlaying = true
        } else if state == "concealed" {
            trailerIsPlaying = false
        } else if state == "paused" {
            trailerIsActive = false
            trailerIsPlaying = false
        } else if state == "ended" {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: AppleDetailMetrics.trailerCrossfadeDuration)) {
                trailerIsActive = false
                trailerIsPlaying = false
            }
        }
    }

    private func showTrailerArtworkOnly() {
        trailerHasStarted = false
        trailerIsActive = false
        trailerIsPlaying = false
        trailerInteractionGeneration &+= 1
        trailerInteractionGlyph = nil
    }

    private func resolvePlayableTrailerCandidateIndex(startingAt index: Int) async -> Int? {
        let keys = trailerCandidates
        var searchIndex = index
        while let candidateIndex = AppleTrailerPreviewPolicy.firstPlayableCandidate(
            keys,
            portraitKeys: trailerPortraitKeys,
            startingAt: searchIndex
        ) {
            let key = keys[candidateIndex]
            if !trailerLandscapeKeys.contains(key) {
                await probeTrailerFrameAspect(for: key)
            }
            if trailerPortraitKeys.contains(key) {
                searchIndex = candidateIndex + 1
                continue
            }
            return candidateIndex
        }
        return nil
    }

    private func probeTrailerFrameAspect(for key: String) async {
        guard let url = AppleTrailerPreviewPolicy.frameProbeURL(for: key) else {
            trailerLandscapeKeys.insert(key)
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
                  let height = properties[kCGImagePropertyPixelHeight] as? CGFloat else {
                trailerLandscapeKeys.insert(key)
                return
            }
            if AppleTrailerPreviewPolicy.isPortraitFrame(CGSize(width: width, height: height)) {
                trailerPortraitKeys.insert(key)
            } else {
                trailerLandscapeKeys.insert(key)
            }
        } catch {
            trailerLandscapeKeys.insert(key)
        }
    }

    private func logTrailerFailure(_ reason: String) {
        print("[OpenStream] trailer unavailable title=\(item.name) candidate=\(trailerCandidateIndex) reason=\(reason)")
    }

    private func showTrailerInteractionGlyph(_ glyph: String) {
        trailerInteractionGeneration &+= 1
        let generation = trailerInteractionGeneration
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
            trailerInteractionGlyph = glyph
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1_200))
            guard !Task.isCancelled, generation == trailerInteractionGeneration else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                trailerInteractionGlyph = nil
            }
        }
    }

    @ViewBuilder
    private var titleMetadata: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppleDetailMetrics.badgeGap) {
            if !titleMetadataTextValues.isEmpty {
                Text(titleMetadataTextValues.joined(separator: " · "))
            }
            ForEach(Array(titleMetadataBadges.enumerated()), id: \.offset) { _, badge in
                AppleFormatBadge(badge)
            }
        }
            .lineLimit(1)
            .minimumScaleFactor(0.68)
            .frame(maxWidth: .infinity, alignment: .leading)
            .font(.system(size: AppleDetailMetrics.metadataFontSize, weight: .regular))
            .foregroundStyle(titleMetadataColor)
            .shadow(color: .black.opacity(0.6), radius: 6, y: 1)
            .accessibilityElement(children: .combine)
    }

    /// The tvOS line always sits on artwork, so it is always light; the
    /// simulator's light appearance otherwise painted it black on the art.
    private var titleMetadataColor: Color {
        #if os(tvOS)
        .white.opacity(0.8)
        #else
        colorScheme == .dark ? .white.opacity(0.60) : .black.opacity(0.60)
        #endif
    }

    private var titleMetadataBadges: [String] {
        AppleTitleMetadataPresentation.orderedBadges(
            contentRating: metadataDetails?.contentRating ?? item.contentRating,
            formatBadges: metadataDetails?.formatBadges ?? item.formatBadges ?? [],
            limit: AppleDetailMetrics.maxBadgeCount
        )
    }

    private var titleMetadataTextValues: [String] {
        AppleTitleMetadataPresentation.textValues(
            genres: metadataDetails?.genres ?? [],
            releaseInfo: displayReleaseInfo,
            runtimeMinutes: metadataDetails?.runtimeMinutes
        )
    }

    private var downloadLabel: String {
        if item.type == "series", selectedEpisodeID != nil {
            switch downloadCoordinator.state {
            case .resolving: return "Preparing \(selectedEpisodeLabel)"
            case .downloading(_, _, let received, let expected):
                return "Downloading \(selectedEpisodeLabel)\(downloadPercent(received: received, expected: expected))"
            case .paused: return "Resume \(selectedEpisodeLabel)"
            case .resuming: return "Resuming \(selectedEpisodeLabel)"
            case .completed: return "Downloaded \(selectedEpisodeLabel)"
            case .failed, .cancelled: return "Retry \(selectedEpisodeLabel)"
            case .idle: return "Download \(selectedEpisodeLabel)"
            }
        }
        switch downloadCoordinator.state {
        case .resolving: return "Preparing Download"
        case .downloading(_, _, let received, let expected):
            return "Downloading\(downloadPercent(received: received, expected: expected))"
        case .paused: return "Resume Download"
        case .resuming: return "Resuming Download"
        case .completed: return "Downloaded"
        case .failed, .cancelled: return "Retry Download"
        case .idle: return "Download"
        }
    }

    private func downloadPercent(received: Int64, expected: Int64?) -> String {
        guard let expected, expected > 0 else { return "" }
        let percent = Int((Double(received) / Double(expected) * 100).rounded())
        return " · \(min(max(percent, 0), 100))%"
    }

    private var downloadActionMessage: String {
        switch downloadCoordinator.state {
        case .resolving(let title, _): return "Preparing \(title)."
        case .downloading(let title, _, let received, let expected):
            return "\(title)\(downloadPercent(received: received, expected: expected))."
        case .paused(let title, _, let received, let expected):
            return "\(title) is paused\(downloadPercent(received: received, expected: expected))."
        case .resuming(let title, _, _, _): return "Resuming \(title)."
        default: return "Choose an action for this download."
        }
    }

    private var seasonDownloadMessage: String {
        let count = seasonDownloads.total > 0
            ? "\(seasonDownloads.completed) of \(seasonDownloads.total) episodes"
            : "the season"
        return "Downloading \(count)."
    }

    @ViewBuilder
    private var downloadFailureNotice: some View {
        // Shown for series too (2026-09-17): downloads are automatic, so when
        // no source works the only feedback is this line under the buttons.
        Group {
            switch downloadCoordinator.state {
            case .failed(_, let message):
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("detail.download.status")
            case .cancelled:
                Text("Download cancelled. You can retry when you’re ready.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("detail.download.status")
            default:
                EmptyView()
            }
        }
    }

    private var selectedEpisodeLabel: String {
        guard let id = selectedEpisodeID,
              let episode = episodes.first(where: { $0.id == id }) else { return "episode" }
        return episodeNumber(episode).replacingOccurrences(of: " ", with: ":")
    }

    private var selectedEpisodeSelection: AppleStremioEpisodeSelection? {
        guard let selectedEpisodeID,
              let episode = episodes.first(where: { $0.id == selectedEpisodeID }) else { return nil }
        return AppleStremioEpisodeSelection(
            seriesMediaID: resolvedMediaID ?? item.mediaID,
            episode: episode
        )
    }

    private var selectedPlaybackMediaID: String {
        selectedEpisodeSelection?.mediaID ?? resolvedMediaID ?? item.mediaID
    }

    @ViewBuilder
    private var primaryPlayButton: some View {
        AppleDetailActionButton(
            title: playbackCoordinator.phase.isBusy || isPreparingMetadata
                ? (playbackCoordinator.phase.isBusy ? "Preparing" : "Loading")
                : (downloadCoordinator.state.isCompleted ? "Play Offline" : "Play"),
            glyph: playbackCoordinator.phase.isBusy || isPreparingMetadata ? .progress : .systemImage("play.fill"),
            kind: .play,
            width: actionButtonWidth
        ) {
            playRequest = UUID()
        }
        .disabled(!canStartPlayback)
        .accessibilityLabel(
            playbackCoordinator.phase.isBusy || isPreparingMetadata
                ? "Preparing playback"
                : (downloadCoordinator.state.isCompleted ? "Play Offline" : "Play")
        )
        .accessibilityIdentifier("detail.play")
        .contextMenu {
            Button("Other sources", systemImage: "list.bullet") {
                Task { await chooseStreams() }
            }
        }
    }

    @ViewBuilder
    private var secondaryActionButtons: some View {
        VStack(alignment: .leading, spacing: 0) {
            primaryActionButtons
            seasonDownloadStatus
            secondaryActionRow
                .padding(.top, AppleDetailMetrics.buttonsToIconRowSpacing)
        }
        .controlSize(.large)
    }

    /// The page margin the detail column and the More Like This rail share.
    private var detailHorizontalInset: CGFloat {
        isLandscapeRegularLayout ? 40 : 16
    }

    private var detailContentWidth: CGFloat {
        #if os(visionOS)
        max(680, viewportSize.width - 80)
        #else
        if isLandscapeRegularLayout { return AppleDetailMetrics.regularContentWidth }
        if isLandscapeLayout {
            return max(
                320,
                viewportSize.width
                    - 2 * AppleDetailMetrics.portraitColumnInset
                    - detailSafeAreaInsets.leading
                    - detailSafeAreaInsets.trailing
            )
        }
        return AppleDetailMetrics.portraitContentWidth(
            viewportWidth: viewportSize.width,
            actionColumnWidth: actionColumnWidth
        )
        #endif
    }

    private var primaryActionRowWidth: CGFloat {
        actionColumnWidth
    }

    private var actionButtonWidth: CGFloat {
        showsDownloadAction
            ? AppleDetailMetrics.actionButtonWidth(for: detailLayout, screenWidth: viewportSize.width)
            : actionColumnWidth
    }

    private var actionColumnWidth: CGFloat {
        AppleDetailMetrics.iconRowWidth(for: detailLayout, screenWidth: viewportSize.width)
    }

    private var detailLayout: AppleDetailLayout {
        #if os(visionOS)
        return isLandscapeRegularLayout ? .landscapeIPad : .portraitIPad
        #elseif os(iOS)
        if isLandscapeLayout { return .landscapeIPad }
        if horizontalSizeClass == .regular { return .portraitIPad }
        return .portraitPhone
        #else
        return .portraitIPad
        #endif
    }

    private var primaryActionButtons: some View {
        // Side by side when they fit, stacked when they do not — and `ViewThatFits`
        // decides, not a rule about text sizes.
        //
        // The first version of this stacked whenever the type was an accessibility
        // size, which is right on a phone (two scaled buttons do not fit across
        // one, and squeezing them broke "Download Season 1" mid-word into
        // "Downloa / d Seas…") but wrong on a tablet, where the same two come to
        // about 460 pt on an 834 pt page and stacked anyway (measured 2026-09-17).
        // Predicting the width instead would mean guessing how much a hugging
        // button grows, which is exactly the guess that was wrong the first time.
        ViewThatFits(in: .horizontal) {
            primaryActionRow(AnyLayout(HStackLayout(spacing: AppleDetailMetrics.actionButtonGap)))
            primaryActionRow(
                AnyLayout(VStackLayout(alignment: .leading, spacing: AppleDetailMetrics.actionButtonGap))
            )
        }
        .frame(
            width: dynamicTypeSize.isAccessibilitySize ? nil : primaryActionRowWidth,
            alignment: .leading
        )
    }

    private func primaryActionRow(_ layout: AnyLayout) -> some View {
        layout {
            primaryPlayButton
            if showsDownloadAction {
                downloadActionButton
            }
        }
    }

    @ViewBuilder
    private var seasonDownloadStatus: some View {
        if item.type == "series", !visibleEpisodes.isEmpty, seasonDownloads.total > 0 {
            HStack {
                Text("\(downloadSeason.map(seasonName) ?? "Season"): \(seasonDownloads.completed) of \(seasonDownloads.total) downloaded")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if seasonDownloads.isRunning {
                    Button("Cancel") { seasonDownloads.cancel(); downloadCoordinator.cancel() }
                }
            }
            if let failure = seasonDownloads.failure {
                Text(failure)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("detail.download.status")
            }
        }
    }

    private var secondaryActionRow: some View {
        // Zero spacing was safe only while each item sat in a fixed 44 pt slot
        // that supplied its own gap. Now that they hug their labels above the
        // accessibility threshold, "My List" and "Rate" ran together into
        // "My ListRate" (measured on the iPad, 2026-09-17), so the row supplies
        // the gap itself at those sizes.
        HStack(spacing: dynamicTypeSize.isAccessibilitySize ? 16 : 0) {
            detailIconAction("My List", systemImage: isFavorite ? "checkmark" : "plus", action: toggleFavorite)
                .accessibilityLabel(isFavorite ? "Remove from My List" : "Add to My List")
                .accessibilityValue(isFavorite ? "Saved" : "Not saved")
            rateControl
        }
        .frame(
            width: dynamicTypeSize.isAccessibilitySize ? nil : primaryActionRowWidth,
            alignment: .leading
        )
        .overlay {
            Color.clear
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("My List, Rate")
                .accessibilityIdentifier("detail.icon-row")
        }
    }

    @ViewBuilder
    private var downloadActionButton: some View {
        AppleDetailActionButton(
            title: downloadButtonLabel,
            glyph: downloadGlyph,
            kind: .download,
            width: actionButtonWidth
        ) {
            if item.type == "series", !visibleEpisodes.isEmpty {
                if seasonDownloads.isRunning {
                    seasonDownloadActionsPresented = true
                } else {
                    startSeasonDownload()
                }
            } else {
                switch downloadCoordinator.state {
                case .resolving, .downloading, .resuming, .paused:
                    downloadActionsPresented = true
                case .idle, .failed, .cancelled:
                    startDownload()
                default:
                    break
                }
            }
        }
        .disabled(isPreparingMetadata || downloadCoordinator.state.isCompleted)
        .accessibilityIdentifier(item.type == "series" && !visibleEpisodes.isEmpty ? "detail.download.season" : "detail.download")
        .accessibilityLabel(downloadButtonLabel)
        .accessibilityValue(offlineAccessibilityValue)
    }

    private var downloadButtonLabel: String {
        if item.type == "series", !visibleEpisodes.isEmpty {
            if seasonDownloads.failure != nil { return "Failed · Retry" }
            if seasonDownloads.isRunning {
                let percent = seasonDownloads.total > 0
                    ? Int((Double(seasonDownloads.completed) / Double(seasonDownloads.total) * 100).rounded())
                    : 0
                return "Downloading · \(percent)%"
            }
            return "Download \(selectedSeason.map(seasonName) ?? "Season")"
        }

        switch downloadCoordinator.state {
        case .resolving: return "Preparing"
        case .downloading(_, _, let received, let expected):
            return "Downloading\(downloadPercent(received: received, expected: expected))"
        case .paused: return "Resume"
        case .resuming: return "Resuming"
        case .completed: return "Downloaded"
        case .failed, .cancelled: return "Failed · Retry"
        case .idle: return "Download"
        }
    }

    private var downloadGlyph: AppleDetailActionButtonGlyph {
        switch downloadCoordinator.state {
        case .resolving: .progress
        case .downloading, .resuming:
            .systemImage("arrow.down.circle")
        case .paused:
            .systemImage("pause.circle")
        case .completed:
            .systemImage("checkmark.square")
        case .failed, .cancelled:
            .systemImage("arrow.clockwise")
        case .idle:
            .systemImage("arrow.down")
        }
    }

    private func detailIconAction(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: AppleDetailMetrics.iconLabelSpacing) {
                Image(systemName: systemImage)
                    .font(.system(size: scaledIconGlyphSize))
                Text(title)
                    .font(.system(size: scaledIconLabelFontSize, weight: .semibold))
            }
            // A fixed 44 pt slot cannot hold "My List" at these sizes, so above
            // the threshold the label decides its own width.
            .frame(width: dynamicTypeSize.isAccessibilitySize ? nil : AppleDetailMetrics.iconActionWidth)
            .frame(minHeight: scaledIconRowHeight)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }

    private var configuredARR: AppleArrKind? {
        switch item.type.lowercased() {
        case "movie":
            guard AppleArrEndpointPolicy.isAllowed(settings.radarrURL),
                  AppleArrClient.isValidAPIKey(settings.radarrAPIKey),
                  !settings.radarrRootFolderPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  Int(settings.radarrQualityProfileID) ?? 0 > 0 else { return nil }
            return .radarr
        case "series":
            guard AppleArrEndpointPolicy.isAllowed(settings.sonarrURL),
                  AppleArrClient.isValidAPIKey(settings.sonarrAPIKey),
                  !settings.sonarrRootFolderPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  Int(settings.sonarrQualityProfileID) ?? 0 > 0 else { return nil }
            return .sonarr
        default:
            return nil
        }
    }

    private func enqueueARR(_ kind: AppleArrKind) async {
        do {
            switch kind {
            case .radarr:
                _ = try await AppleArrClient().enqueueIfMissing(
                    kind: kind,
                    baseURL: settings.radarrURL,
                    apiKey: settings.radarrAPIKey,
                    title: item.name,
                    year: Int(item.releaseInfo ?? ""),
                    mediaID: resolvedMediaID ?? item.id,
                    rootFolderPath: settings.radarrRootFolderPath,
                    qualityProfileID: settings.radarrQualityProfileID
                )
            case .sonarr:
                _ = try await AppleArrClient().enqueueIfMissing(
                    kind: kind,
                    baseURL: settings.sonarrURL,
                    apiKey: settings.sonarrAPIKey,
                    title: item.name,
                    year: Int(item.releaseInfo ?? ""),
                    mediaID: resolvedMediaID ?? item.id,
                    rootFolderPath: settings.sonarrRootFolderPath,
                    qualityProfileID: settings.sonarrQualityProfileID
                )
            }
            arrFeedback = "Added \(item.name) to the \(kind.displayName) queue."
        } catch {
            arrFeedback = error.localizedDescription
        }
    }

    private func byteLabel(_ count: Int64) -> String {
        AppleByteFormatting.string(count)
    }

    /// "Episodes" and the season control side by side, or stacked once the type
    /// is large enough that they cannot share a line.
    ///
    /// At the largest accessibility size the two of them in one `HStack` left
    /// the heading no room and it broke **mid-word** — "Episod" over "es"
    /// (measured on the phone, 2026-09-17). The hero's action row already
    /// restacks at these sizes; this is the same answer for the same problem.
    @ViewBuilder
    private var episodeSectionHeader: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) {
                episodesHeading
                seasonControl
            }
        } else {
            HStack(alignment: .top) {
                episodesHeading
                Spacer()
                seasonControl
            }
        }
    }

    private var episodesHeading: some View {
        Text("Episodes")
            .font(.title2.bold())
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private var seasonControl: some View {
        if seasonNumbers.count > 1 {
            Picker("Season", selection: $selectedSeason) {
                ForEach(seasonNumbers, id: \.self) { season in
                    Text(seasonName(season)).tag(Optional(season))
                }
            }
            .pickerStyle(.menu)
            .appleVisionActionTarget()
            .accessibilityIdentifier("detail.season")
        } else if let season = selectedSeason {
            Text(seasonName(season))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private var episodeSection: some View {
        VStack(alignment: .leading, spacing: AppleDetailMetrics.sectionHeaderBottomSpacing) {
            episodeSectionHeader

            if isLoadingEpisodes {
                VStack(spacing: 10) {
                    episodePlaceholderRow
                    episodePlaceholderRow
                }
                .redacted(reason: .placeholder)
            } else if episodes.isEmpty {
                Text("Episodes aren’t available from the connected metadata sources.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if isWideLandscape {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 24, alignment: .top),
                        GridItem(.flexible(), spacing: 24, alignment: .top),
                    ],
                    spacing: 0
                ) {
                    ForEach(visibleEpisodes) { episode in
                        episodeRow(episode)
                    }
                }
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(visibleEpisodes) { episode in
                        episodeRow(episode)

                        if episode.id != visibleEpisodes.last?.id {
                            Divider().overlay(.white.opacity(0.12))
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("detail.episodes")
    }

    /// The title `startDownload(episode:)` hands the coordinator, so a row can
    /// tell its own download from another episode's.
    private func episodeDownloadTitle(_ episode: AppleStremioEpisode) -> String {
        AppleStremioEpisodeSelection(seriesMediaID: resolvedMediaID ?? item.mediaID, episode: episode)?.displayTitle
            ?? episode.displayTitle
    }

    private func episodeDownloadIndicator(for episode: AppleStremioEpisode) -> AppleEpisodeDownloadIndicator {
        AppleEpisodeDownloadIndicator.resolve(
            episodeTitle: episodeDownloadTitle(episode),
            coordinatorState: downloadCoordinator.state,
            isDownloaded: downloadedEpisodeIDs.contains(episode.id))
    }

    /// App Store-style ring while this episode downloads; the plain arrow
    /// otherwise. Automatic downloads have no sheet, so the ring is the
    /// viewer's only sign that the tap took (tester, build 10: "percentage
    /// bar during download").
    @ViewBuilder
    private func episodeDownloadGlyph(_ indicator: AppleEpisodeDownloadIndicator) -> some View {
        switch indicator {
        case .idle:
            Image(systemName: "arrow.down")
        case .otherInProgress:
            Image(systemName: "arrow.down.circle.fill")
        case .downloaded:
            Image(systemName: "checkmark.square")
        case .preparing:
            ProgressView().controlSize(.small)
        case .downloading(let fraction), .paused(let fraction):
            ZStack {
                Circle().stroke(.white.opacity(0.25), lineWidth: 2.5)
                if let fraction {
                    Circle().trim(from: 0, to: fraction)
                        .stroke(.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.25), value: fraction)
                } else {
                    ProgressView().controlSize(.mini)
                }
                if case .paused = indicator {
                    Image(systemName: "play.fill").font(.system(size: 8, weight: .bold))
                } else if fraction != nil {
                    RoundedRectangle(cornerRadius: 1.5).frame(width: 7, height: 7)
                }
            }
            .frame(width: 24, height: 24)
        }
    }

    private func episodeRow(_ episode: AppleStremioEpisode) -> some View {
        HStack(spacing: 0) {
            Button {
                selectedEpisodeID = episode.id
                playRequest = UUID()
            } label: {
                HStack(spacing: 14) {
                    ZStack {
                        AppleRemoteImage(url: episode.thumbnailURL, placeholderSystemImage: "play.fill")
                        if episode.thumbnailURL != nil {
                            Image(systemName: "play.circle.fill").font(.title2)
                                .shadow(radius: 3)
                        }
                    }
                    .frame(width: 104, height: 64)
                    .background(.white.opacity(0.09))
                    .clipShape(.rect(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(episode.title.isEmpty ? episode.displayTitle : episode.title)
                            .font(.headline).lineLimit(2)
                        Text(episodeMetadata(episode)).font(.caption).foregroundStyle(.secondary)
                        if let overview = episode.overview, !overview.isEmpty {
                            Text(overview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    Spacer(minLength: 8)
                }
                .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(AppleDetailRowButtonStyle())
            .appleVisionHover()
            .accessibilityLabel("Play \(episode.displayTitle)")
            .accessibilityValue(selectedEpisodeID == episode.id ? "\(episodeNumber(episode)), selected" : episodeNumber(episode))
            .accessibilityAddTraits(selectedEpisodeID == episode.id ? .isSelected : [])
            #if os(iOS) || os(macOS)
            if localGroup == nil {
            Button {
                if seasonDownloads.isRunning {
                    seasonDownloadActionsPresented = true
                } else if downloadCoordinator.state.ownsDownload {
                    downloadActionsPresented = true
                } else {
                    selectedEpisodeID = episode.id
                    startDownload(episode: episode)
                }
            } label: {
                episodeDownloadGlyph(episodeDownloadIndicator(for: episode))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .disabled(isPreparingMetadata || downloadCoordinator.state.isCompleted)
            .accessibilityLabel(episodeDownloadIndicator(for: episode).accessibilityLabel(episodeTitle: episodeDownloadTitle(episode)))
            .accessibilityIdentifier("detail.episode.download")
            }
            #endif
        }
    }

    private var episodePlaceholderRow: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 8)
                .fill(.white.opacity(0.08))
                .frame(width: 104, height: 64)
            VStack(alignment: .leading, spacing: 8) {
                Capsule().fill(.white.opacity(0.12)).frame(width: 170, height: 12)
                Capsule().fill(.white.opacity(0.08)).frame(width: 110, height: 10)
                Capsule().fill(.white.opacity(0.08)).frame(width: 220, height: 10)
            }
            Spacer()
        }
        .frame(minHeight: 72)
    }

    private var moreLikeThisSection: some View {
        VStack(alignment: .leading, spacing: AppleDetailMetrics.sectionHeaderBottomSpacing) {
            Text("More Like This")
                .font(.title2.bold())
                .padding(.leading, detailHorizontalInset)
                .accessibilityAddTraits(.isHeader)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: isLandscapeRegularLayout || horizontalSizeClass == .regular ? 10 : 8) {
                    suggestedCards
                }
                .padding(.vertical, 8)
                // Leading only: the first card lines up with the heading and the
                // last one runs off the edge, which is what says "keep scrolling".
                .padding(.leading, detailHorizontalInset)
            }
            .scrollIndicators(AppleDesignTokens.scrollIndicatorVisibility)
        }
        .accessibilityIdentifier("detail.more-like-this")
    }

    @ViewBuilder
    private var suggestedCards: some View {
        ForEach(suggestedItems) { suggestion in
            NavigationLink {
                AppleCatalogItemDetailView(
                    item: suggestion,
                    source: source,
                    relatedItems: relatedItems,
                    mediaIndex: mediaIndex,
                    playbackSources: playbackSources,
                    metadataConfiguration: metadataConfiguration,
                    gatewayConfig: gatewayConfig,
                    streamingServerConfiguration: streamingServerConfiguration,
                    playbackResolver: playbackResolver,
                    settings: settings,
                    openSettings: openSettings
                )
            } label: {
                AppleCatalogCard(
                    item: suggestion,
                    sizing: .detailSuggestions,
                    viewportWidth: viewportSize.width
                )
            }
            .accessibilityIdentifier("detail.similar.\(suggestion.id)")
        }
    }

    private var suggestedItems: [AppleCatalogItem] { rankedSuggestions }

    /// Ranks the in-memory catalog against this title on genre, synopsis
    /// keywords, cast and crew, year and rating. No network call.
    private func refreshSuggestions() async {
        let target = metadataDetails.map { item.merging(details: $0) } ?? item
        let candidates = relatedItems
        let ranked = await AppleSimilarTitleKeywordCache.shared.rankSimilar(
            target: AppleSimilarTitleProfile(item: target),
            candidates: candidates.map(AppleSimilarTitleProfile.init(item:)),
            limit: 12
        )
        guard !Task.isCancelled else { return }
        var itemsByID: [String: AppleCatalogItem] = [:]
        for candidate in candidates where itemsByID[candidate.id] == nil {
            itemsByID[candidate.id] = candidate
        }
        rankedSuggestions = ranked.compactMap { itemsByID[$0.profile.id] }
    }

    private func seasonName(_ season: Int) -> String {
        season == 0 ? "Specials" : "Season \(season)"
    }

    private func episodeNumber(_ episode: AppleStremioEpisode) -> String {
        if let season = episode.season, let number = episode.episode {
            return "S\(season) E\(number)"
        }
        if let number = episode.episode { return "Episode \(number)" }
        return "Episode"
    }

    private var offlineAccessibilityValue: String {
        switch downloadCoordinator.state {
        case .idle: "Not downloaded"
        case .resolving: "Resolving stream"
        case .downloading(_, let destination, let received, let expected):
            downloadCoordinator.supportsPauseResume
                ? "Downloading \(offlineDisplayTitle), \(byteLabel(received)) of \(expected.map(byteLabel) ?? "unknown size"), to \(destination)"
                : "Downloading \(offlineDisplayTitle) to \(destination)"
        case .paused(_, _, let received, let expected):
            "Paused at \(byteLabel(received)) of \(expected.map(byteLabel) ?? "unknown size")"
        case .resuming: "Resuming download"
        case .completed: "Downloaded"
        case .failed: "Download failed"
        case .cancelled: "Download cancelled"
        }
    }

    private var offlineDisplayTitle: String {
        let title = offlineTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return String(title.prefix(120)) }
        let mediaID = item.mediaID.split(separator: ":").first.map(String.init) ?? item.mediaID
        let cleanedMediaID = mediaID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanedMediaID.isEmpty { return String(cleanedMediaID.prefix(120)) }
        if let episode = selectedEpisodeID,
           !episode.isEmpty {
            return !episode.isEmpty ? "Episode \(episode)".trimmingCharacters(in: .whitespacesAndNewlines) : "Series episode"
        }
        return "\(item.type.isEmpty ? "item" : item.type)"
    }

    private var canStartPlayback: Bool {
        !isPreparingMetadata
            && !playbackCoordinator.phase.isBusy
            && (item.type != "series" || selectedEpisodeID != nil)
    }

    private var recordID: String {
        AppleMediaIngestion.catalogRecord(instanceID: source.id, item: item).id
    }

    private var offlineRecordID: String {
        selectedEpisodeSelection.map { "\(recordID):\($0.mediaID)" } ?? recordID
    }

    private var showsDownloadAction: Bool {
        guard localGroup == nil else { return false }
        guard AppleLocalDownloadPlatformPolicy.isSupportedOnCurrentPlatform else { return false }
        #if os(tvOS) || os(visionOS)
        return false
        #else
        let indexedRecord = mediaIndex.records.first { $0.id == recordID }
        let availabilityIDs = Set(indexedRecord?.availability.map(\.instanceID) ?? [])
        let hasLiveAvailability = source.kind == .liveTV || playbackSources.contains {
            $0.kind == .liveTV && availabilityIDs.contains($0.id)
        }
        return AppleOfflineActionPolicy.isAvailable(
            sourceKind: source.kind,
            itemType: item.type,
            indexedKind: indexedRecord?.kind,
            hasLiveAvailability: hasLiveAvailability
        )
        #endif
    }

    private var canStartDownload: Bool {
        showsDownloadAction
            && !isPreparingMetadata
            && !downloadCoordinator.state.ownsDownload
            && !downloadCoordinator.state.isCompleted
            && (item.type != "series" || selectedEpisodeID != nil)
    }

    private var seasonNumbers: [Int] {
        AppleStremioEpisodePolicy.seasons(in: episodes)
    }

    private var visibleEpisodes: [AppleStremioEpisode] {
        AppleStremioEpisodePolicy.episodes(in: selectedSeason, from: episodes)
    }

    private func episodeMetadata(_ episode: AppleStremioEpisode) -> String {
        [episodeNumber(episode), episode.formattedReleaseInfo, episode.runtimeMinutes.map { "\($0) min" }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private var rateControl: some View {
        ZStack(alignment: .leading) {
            Button {
                withAnimation(rateAnimation) { rateChoicesExpanded.toggle() }
            } label: {
                VStack(spacing: AppleDetailMetrics.iconLabelSpacing) {
                    Image(systemName: ratingGlyph(for: rating, selected: rating != nil))
                        .font(.system(size: scaledIconGlyphSize))
                    Text("Rate")
                        .font(.system(size: scaledIconLabelFontSize, weight: .semibold))
                }
                .frame(
                    width: dynamicTypeSize.isAccessibilitySize ? nil : AppleDetailMetrics.iconActionWidth,
                    alignment: .leading
                )
                .frame(minHeight: scaledIconRowHeight)
            }
            .buttonStyle(.plain)
            .opacity(rateChoicesExpanded ? 0 : 1)
            .accessibilityHidden(rateChoicesExpanded)

            if rateChoicesExpanded {
                HStack(spacing: 14) {
                    ForEach(Array(AppleTitleRating.selectableCases.enumerated()), id: \.offset) { index, value in
                        Button {
                            selectRating(value)
                        } label: {
                            Image(systemName: ratingGlyph(for: value, selected: rating == value))
                                .font(.system(size: 24, weight: .semibold))
                                #if os(visionOS)
                                .frame(width: 60, height: 60)
                                #else
                                .frame(width: 32, height: 40)
                                #endif
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(value.title)
                        .accessibilityAddTraits(rating == value ? .isSelected : [])
                        .scaleEffect(rateChoicesExpanded ? 1 : 0.35)
                        .opacity(rateChoicesExpanded ? 1 : 0)
                        .animation(rateAnimation.delay(Double(index) * 0.04), value: rateChoicesExpanded)
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 60)
                .background(.black.opacity(0.92), in: .capsule)
                .transition(.scale(scale: 0.25, anchor: .leading).combined(with: .opacity))
                .zIndex(2)
            }
        }
        .frame(width: AppleDetailMetrics.iconActionWidth, alignment: .leading)
        .frame(height: AppleDetailMetrics.iconRowHeight)
        .foregroundStyle(.white)
        .accessibilityLabel("Rate")
        .accessibilityValue(rating?.title ?? "Not rated")
    }

    private var rateAnimation: Animation {
        reduceMotion ? .linear(duration: 0.01) : .spring(response: 0.35, dampingFraction: 0.8)
    }

    private func ratingGlyph(for value: AppleTitleRating?, selected: Bool) -> String {
        switch value {
        case .down: return selected ? "hand.thumbsdown.fill" : "hand.thumbsdown"
        case .up: return selected ? "hand.thumbsup.fill" : "hand.thumbsup"
        case .doubleUp: return selected ? "heart.fill" : "heart"
        case .some(.none), nil: return "hand.thumbsup"
        }
    }

    private func selectRating(_ value: AppleTitleRating) {
        rating = value
        ratingStore.set(value, for: item.mediaID)
        ratingSelectionGeneration += 1
        let generation = ratingSelectionGeneration
        withAnimation(rateAnimation) { rateChoicesExpanded = true }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, generation == ratingSelectionGeneration else { return }
            withAnimation(rateAnimation) { rateChoicesExpanded = false }
        }
    }

    private func toggleFavorite() {
        let next = !isFavorite
        isFavorite = next
        Task { @MainActor in
            do {
                try await mediaIndex.setFavorite(next, recordID: recordID)
            } catch {
                isFavorite.toggle()
            }
        }
    }

    private func refreshOfflineState() async {
        await downloadCoordinator.loadExisting(mediaID: offlineRecordID, itemTitle: offlineDisplayTitle)
    }

    private func refreshDownloadedEpisodeIDs() async {
        guard item.type == "series" else { return }
        let resolvedIDs = episodes.compactMap { episode -> (String, String)? in
            guard let selection = AppleStremioEpisodeSelection(
                seriesMediaID: resolvedMediaID ?? item.mediaID,
                episode: episode
            ) else { return nil }
            return (episode.id, "\(recordID):\(selection.mediaID)")
        }
        var completed = Set<String>()
        for (episodeID, mediaID) in resolvedIDs {
            if await downloadCoordinator.record(for: mediaID) != nil {
                completed.insert(episodeID)
            }
        }
        guard !Task.isCancelled else { return }
        downloadedEpisodeIDs = completed
    }

    private func chooseStreams() async {
        pickingStreams = true
        defer { pickingStreams = false }
        do {
            streamChoices = try await playbackResolver.rankedCandidates(sources: playbackSources,
                preferredSourceID: source.id, item: item.withMediaID(selectedPlaybackMediaID),
                streamingServerConfiguration: streamingServerConfiguration)
        } catch {
            streamChoices = []
            if localFiles.isEmpty { playbackCoordinator.fail(error); return }
        }
        streamPickerPresented = true
    }

    private func configuredSources(_ presentation: AppleStremioPlayerPresentation, selectedID: URL? = nil) -> AppleStremioPlayerPresentation {
        var result = presentation
        result.sourceID = selectedID ?? presentation.request.url
        // Every path that opens the player from this page comes through here,
        // so wiring the next episode once covers all of them.
        result.nextEpisode = nextEpisodeContext()
        let files = localFiles
        let library = library
        let settings = settings
        let store = localSourceStore ?? AppleSourceStore()
        let selectedItem = item.withMediaID(selectedPlaybackMediaID)
        let mediaID = recordID
        let title = selectedEpisodeSelection?.displayTitle ?? item.name
        result.sourceOptionsLoader = {
            let localOptions = files.map { file in
                ApplePlaybackSourceOption(id: file.url,
                    title: "Local · \(library.sources.first { $0.id == file.sourceID }?.name ?? "Library")",
                    detail: AppleLocalLibraryStore.format(file)) {
                        try await library.presentation(for: file, sourceStore: store, settings: settings)
                    }
            }
            // Local files carry no structured quality metadata, only a name,
            // so grouping falls back to scanning it — the one case the
            // grouping type's doc comment calls out explicitly.
            var candidates = files.map { AppleStreamSourceGrouping.Candidate(text: $0.name, isLocal: true) }
            var streamOptions: [ApplePlaybackSourceOption] = []
            var loadError: Error?
            do {
                let streams = try await playbackResolver.rankedCandidates(sources: playbackSources,
                    preferredSourceID: source.id, item: selectedItem,
                    streamingServerConfiguration: streamingServerConfiguration)
                streamOptions = streams.map { candidate in
                    ApplePlaybackSourceOption(id: candidate.sourceURL,
                        title: AppleStreamSourceGrouping.strippingProviderTag(from: appleStreamDisplayText(candidate.title)),
                        detail: candidate.sourceName.map { "via \(appleStreamDisplayText($0))" } ?? "Add-on") {
                            AppleStremioPlayerPresentation(request: candidate.playbackRequest(mediaID: mediaID, title: title,
                                resume: AppleDetailResume.position(mediaID: mediaID,
                                    partID: AppleDetailResume.partID(type: selectedItem.type, mediaID: selectedItem.mediaID)),
                                addonMediaID: selectedItem.mediaID, addonMediaType: selectedItem.type), settings: settings)
                        }
                }
                candidates += streams.map {
                    AppleStreamSourceGrouping.Candidate(
                        text: [$0.qualityDescription ?? $0.title, $0.filename ?? ""].joined(separator: " "),
                        isLocal: false
                    )
                }
            } catch { loadError = error }
            let all = localOptions + streamOptions
            if all.isEmpty, let loadError { throw loadError }
            let grouped = AppleStreamSourceGrouping.choices(for: candidates).compactMap { choice in
                all.indices.contains(choice.index) ? ApplePlaybackSourceOption(id: all[choice.index].id, title: choice.title,
                    detail: all[choice.index].detail, prepare: all[choice.index].prepare) : nil
            }
            return ApplePlaybackSourceOptions(grouped: grouped, all: all)
        }
        return result
    }

    /// The episode after the one about to play, and how to start it.
    ///
    /// Selecting it and re-running `resolvePlayback()` is exactly what
    /// choosing that episode by hand does, so the next episode resolves its own
    /// sources, resume position and subtitles rather than inheriting this
    /// one's. Nil for a movie, for a series with nothing selected, and for the
    /// last episode of the last season.
    private func nextEpisodeContext() -> AppleNextEpisodeContext? {
        guard let selectedEpisodeID,
              let current = episodes.first(where: { $0.id == selectedEpisodeID }),
              let next = AppleStremioEpisodePolicy.following(current, in: episodes) else { return nil }
        return AppleNextEpisodeContext(title: next.displayTitle) {
            Task { @MainActor in
                appleTrace("next episode → \(next.displayTitle)")
                self.playerPresentation = nil
                self.selectedEpisodeID = next.id
                await self.resolvePlayback()
            }
        }
    }

    private func resolvePlayback() async {
        playbackCoordinator.beginResolving()
        do {
            if selectedStream == nil {
                let files = selectedLocalFile.map { [$0] } ?? localFiles.filter { !ApplePlaybackFailureHistory.shared.contains($0.url) }
                selectedLocalFile = nil
                for file in files {
                    do {
                        let presentation = try await library.presentation(for: file,
                            sourceStore: localSourceStore ?? AppleSourceStore(), settings: settings)
                        playbackCoordinator = presentation.coordinator
                        playerPresentation = configuredSources(presentation, selectedID: file.url)
                        return
                    } catch is CancellationError { throw CancellationError() }
                    catch { ApplePlaybackFailureHistory.shared.record(file.url) }
                }
            }
            if selectedStream == nil, let offlineRecord = await downloadCoordinator.record(for: offlineRecordID),
               !ApplePlaybackFailureHistory.shared.contains(offlineRecord.localURL) {
                do {
                    playbackCoordinator.update(.loading)
                    let inspection = try await AppleAssetInspector.inspect(url: offlineRecord.localURL)
                    playbackCoordinator.update(.loading)
                    let prepared = try await playbackPreparer.prepare(
                        sourceURL: offlineRecord.localURL,
                        decision: AppleStremioPlaybackResolver.decision(for: inspection),
                        inspectedAsset: inspection,
                        gatewayRequest: nil
                    )
                    let presentation = AppleStremioPlayerPresentation(
                        request: ApplePlaybackRequest(
                            url: prepared.url,
                            headers: prepared.requestHeaders,
                            resumePosition: AppleDetailResume.position(mediaID: recordID,
                                partID: AppleDetailResume.partID(type: item.type, mediaID: selectedPlaybackMediaID)),
                            mediaID: recordID,
                            title: item.name,
                            sourceKind: .stremio
                        ),
                        settings: settings
                    )
                    playbackCoordinator = presentation.coordinator
                    playerPresentation = configuredSources(presentation, selectedID: offlineRecord.localURL)
                    return
                } catch is CancellationError { throw CancellationError() }
                catch { ApplePlaybackFailureHistory.shared.record(offlineRecord.localURL) }
            }

            // Series: play the selected episode id (already IMDB-shaped from the
            // resolved series meta). Movie: play the resolved IMDB id, falling
            // back to the raw catalog id only if meta resolution found nothing.
            let streamID = selectedPlaybackMediaID
            let selectedItem = item.withMediaID(streamID)
            let ranked: [AppleStremioHTTPPlaybackCandidate]
            if let selectedStream {
                ranked = [selectedStream]
            } else {
                ranked = try await playbackResolver.rankedCandidates(
                    sources: playbackSources,
                    preferredSourceID: source.id,
                    item: selectedItem,
                    streamingServerConfiguration: streamingServerConfiguration
                )
            }
            try Task.checkCancellation()
            streamChoices = ranked
            let mediaID = AppleMediaIngestion.catalogRecord(instanceID: source.id, item: item).id
            let title = selectedEpisodeSelection?.displayTitle ?? item.name
            let requests = ranked.filter { selectedStream != nil || !ApplePlaybackFailureHistory.shared.contains($0.sourceURL) }.map { candidate in
                candidate.playbackRequest(mediaID: mediaID, title: title,
                    resume: AppleDetailResume.position(mediaID: mediaID,
                        partID: AppleDetailResume.partID(type: selectedItem.type, mediaID: selectedItem.mediaID)),
                    addonMediaID: selectedItem.mediaID, addonMediaType: selectedItem.type)
            }
            selectedStream = nil
            guard let first = requests.first else { throw AppleLibrarySourceError.noMedia }
            let presentation = AppleStremioPlayerPresentation(
                request: first,
                fallbackCandidates: Array(requests.dropFirst()),
                settings: settings
            )
            playbackCoordinator = presentation.coordinator
            playerPresentation = configuredSources(presentation)
        } catch is CancellationError {
            playbackCoordinator.reset()
        } catch {
            playbackCoordinator.fail(error)
        }
    }

    private func startDownload(episode: AppleStremioEpisode? = nil) {
        guard !seasonDownloads.isRunning else { return }
        let selection = episode.flatMap { AppleStremioEpisodeSelection(seriesMediaID: resolvedMediaID ?? item.mediaID, episode: $0) }
        let streamID = selection?.mediaID ?? selectedPlaybackMediaID
        let selectedItem = item.withMediaID(streamID)
        let sources = playbackSources
        let preferredSourceID = source.id
        let serverConfiguration = streamingServerConfiguration
        downloadCoordinator.start(
            request: .init(
                mediaID: selection.map { "\(recordID):\($0.mediaID)" } ?? offlineRecordID,
                itemTitle: selection?.displayTitle ?? offlineDisplayTitle,
                subtitle: selection?.displayTitle ?? offlineSubtitle,
                artworkURL: item.posterURL,
                destinationLabel: "OpenStream Offline Storage"
            ),
            resolvePlans: {
                // Automatic, by owner decision (2026-09-17): no source sheet.
                // The resolver returns up to 12 ranked plans and the
                // coordinator walks them in order when one fails, which is what
                // makes "a source is chosen by default but is not necessarily
                // available" (tester, build 10) safe without asking.
                try await playbackResolver.resolveDownloadPlans(
                    sources: sources,
                    preferredSourceID: preferredSourceID,
                    item: selectedItem,
                    streamingServerConfiguration: serverConfiguration
                )
            },
            revokeCapabilities: { capabilities in
                for capability in capabilities {
                    await AppleProtectedHTTPPlaybackServer.shared.revoke(playbackURL: capability)
                }
            }
        )
    }

    private func startSeasonDownload() {
        guard !isPreparingMetadata, !downloadCoordinator.state.ownsDownload else { return }
        downloadSeason = selectedSeason
        let selections = visibleEpisodes.compactMap {
            AppleStremioEpisodeSelection(seriesMediaID: resolvedMediaID ?? item.mediaID, episode: $0)
        }
        let byID = selections.reduce(into: [String: AppleStremioEpisodeSelection]()) { $0[$1.mediaID] = $1 }
        let baseID = recordID
        seasonDownloads.start(episodeIDs: selections.map(\.mediaID)) { id in
            guard let selection = byID[id] else { return }
            let selectedItem = item.withMediaID(id)
            try await downloadCoordinator.downloadAndWait(
                request: .init(mediaID: "\(baseID):\(id)", itemTitle: "\(item.name) · \(selection.displayTitle)",
                    subtitle: selection.displayTitle, artworkURL: item.posterURL,
                    destinationLabel: "OpenStream Offline Storage"),
                resolvePlans: {
                    try await playbackResolver.resolveDownloadPlans(sources: playbackSources,
                        preferredSourceID: source.id, item: selectedItem,
                        streamingServerConfiguration: streamingServerConfiguration)
                },
                revokeCapabilities: { capabilities in
                    for capability in capabilities {
                        await AppleProtectedHTTPPlaybackServer.shared.revoke(playbackURL: capability)
                    }
                }
            )
        }
    }

    private var offlineTitle: String {
        selectedEpisodeSelection?.displayTitle ?? item.name
    }

    private var offlineSubtitle: String? {
        guard let selectedEpisodeID,
              let episode = episodes.first(where: { $0.id == selectedEpisodeID }) else {
            return item.releaseInfo
        }
        let title = episode.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? episodeNumber(episode) : "\(episodeNumber(episode)) · \(title)"
    }

    /// Resolve the item to its IMDB id, then (for series) load episodes keyed
    /// by that id so both metadata and streams resolve against a stream-add-on
    /// friendly identifier.
    private func prepare() async {
        let generation = UUID()
        preparationGeneration = generation
        let isSeries = item.type == "series"
        // An item that already carries a canonical `tt…` id needs no meta
        // add-on round trip, so Play is usable before anything is awaited.
        let canonicalID = ApplePlayGatingPolicy.canonicalMediaID(item.mediaID)
        if let canonicalID {
            resolvedMediaID = canonicalID
            isPreparingMetadata = false
        } else {
            isPreparingMetadata = true
        }
        if isSeries { isLoadingEpisodes = true }
        rating = ratingStore.rating(for: item.mediaID)

        // Preview art, the canonical id and (when the id is already canonical)
        // the episode list all load at once; nothing waits on the others.
        async let loadedPreviewAssets = metadataClient.previewAssets(
            sources: playbackSources,
            preferredSourceID: source.id,
            type: item.type,
            mediaID: item.mediaID
        )
        async let resolvedIdentifier: String? = canonicalID == nil
            ? await metadataClient.imdbIdentifier(
                sources: playbackSources,
                preferredSourceID: source.id,
                type: item.type,
                id: item.mediaID
            )
            : canonicalID
        let concurrentEpisodeID: String? = isSeries ? canonicalID : nil
        async let concurrentEpisodes: [AppleStremioEpisode]? = concurrentEpisodeID == nil
            ? nil
            : (try? await metadataClient.episodes(
                sources: playbackSources,
                preferredSourceID: source.id,
                mediaID: concurrentEpisodeID ?? item.mediaID
            ))

        let resolved = await resolvedIdentifier
        guard !Task.isCancelled, preparationGeneration == generation else { return }
        resolvedMediaID = resolved ?? item.mediaID
        // Play and Download depend on the canonical id (and, for a series, an
        // episode), not on optional preview art or TMDB enrichment. Make the
        // actions usable as soon as that identity is ready.
        isPreparingMetadata = false

        if isSeries {
            var loadedEpisodes = await concurrentEpisodes
            if loadedEpisodes == nil {
                do {
                    loadedEpisodes = try await metadataClient.episodes(
                        sources: playbackSources,
                        preferredSourceID: source.id,
                        mediaID: resolvedMediaID ?? item.mediaID
                    )
                } catch is CancellationError {
                    isLoadingEpisodes = false
                    return
                } catch {
                    loadedEpisodes = []
                }
            }
            guard !Task.isCancelled, preparationGeneration == generation else {
                isLoadingEpisodes = false
                return
            }
            let fetched = loadedEpisodes ?? []
            episodes = localGroup.map { AppleLocalLibraryStore.episodes(group: $0,
                mediaID: resolvedMediaID ?? item.mediaID, enriched: fetched) } ?? fetched
            downloadedEpisodeIDs = []
            selectedSeason = library.resumeEpisode(for: item, group: localGroup, episodes: episodes)?.season
                ?? AppleStremioEpisodePolicy.initialSeason(in: episodes)
            // Play needs an episode: fall back to the first episode of the
            // first season so the button works the moment the list arrives.
            selectedEpisodeID = nextUnwatchedEpisodeID(in: selectedSeason, from: episodes)
                ?? ApplePlayGatingPolicy.defaultEpisodeID(episodes: episodes)
            isLoadingEpisodes = false
            await refreshDownloadedEpisodeIDs()
            guard !Task.isCancelled, preparationGeneration == generation else { return }
        }
        let preview = await loadedPreviewAssets
        guard !Task.isCancelled, preparationGeneration == generation else { return }
        previewAssets = preview
        do {
            metadataDetails = try await metadataResolver.resolve(
                sources: playbackSources,
                preferredSourceID: source.id,
                type: item.type,
                mediaID: resolvedMediaID ?? item.mediaID,
                configuration: metadataConfiguration
            )
        } catch is CancellationError {
            return
        } catch {
            metadataDetails = nil
        }
        guard !Task.isCancelled, preparationGeneration == generation else { return }
        await loadWatchProviders()
        guard !Task.isCancelled, preparationGeneration == generation else { return }
        if item.posterURL == nil, metadataDetails?.backdropURL == nil, metadataDetails?.posterURL == nil {
            fallbackArtwork = await AppleArtworkResolver.shared.resolve(
                mediaID: resolvedMediaID ?? item.mediaID,
                type: item.type,
                existingPosterURL: item.posterURL,
                existingBackgroundURL: item.backgroundURL,
                configuration: metadataConfiguration
            )
        }
    }

    /// Where else this title can be watched, filtered to the services the
    /// viewer subscribes to.
    ///
    /// The whole call is skipped when they have not opted in — no request goes
    /// out at all, rather than one being made and the answer thrown away.
    private func loadWatchProviders() async {
        let enabled = settings.watchProviderIDs
        guard !enabled.isEmpty,
              let configuration = metadataConfiguration,
              let imdbID = (resolvedMediaID ?? item.mediaID) as String?,
              imdbID.hasPrefix("tt") else {
            watchProviders = []
            return
        }
        let kind: AppleMediaKind = item.type == "series" ? .series : .movie
        let all = try? await AppleTMDBClient().watchProviders(
            imdbID: imdbID,
            kind: kind,
            region: AppleWatchProviderResponse.currentRegion(),
            configuration: configuration
        )
        guard !Task.isCancelled else { return }
        watchProviders = AppleWatchProviderPolicy.visible(all ?? [], enabledProviderIDs: enabled)
    }

    private func nextUnwatchedEpisodeID(
        in season: Int?,
        from loadedEpisodes: [AppleStremioEpisode]
    ) -> String? {
        if let resumed = library.resumeEpisode(for: item, group: localGroup,
            episodes: loadedEpisodes.filter { $0.season == season }) { return resumed.id }
        let completedIDs = Set(
            loadedEpisodes.compactMap { episode in
                playbackStore.progress(for: episode.id)?.isComplete == true ? episode.id : nil
            }
        )
        return AppleStremioEpisodePolicy
            .nextUnwatched(in: season, from: loadedEpisodes, completedIDs: completedIDs)?.id
    }
}

enum AppleDetailActionButtonGlyph: Sendable {
    case systemImage(String)
    case progress
}

enum AppleDetailActionButtonKind: Sendable {
    case play
    case download

    var foreground: Color {
        switch self {
        case .play: .black
        case .download: .white
        }
    }

    var fill: Color {
        switch self {
        case .play: .white
        case .download: .white.opacity(0.08)
        }
    }

    var stroke: Color {
        switch self {
        case .play: .clear
        case .download: .white.opacity(0.55)
        }
    }
}

struct AppleDetailActionButton: View {
    let title: String
    let glyph: AppleDetailActionButtonGlyph
    let kind: AppleDetailActionButtonKind
    let width: CGFloat?
    let action: () -> Void

    init(
        title: String,
        glyph: AppleDetailActionButtonGlyph,
        kind: AppleDetailActionButtonKind,
        width: CGFloat? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.glyph = glyph
        self.kind = kind
        self.width = width
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            AppleDetailActionButtonLabel(title: title, glyph: glyph, kind: kind, width: width)
        }
        .buttonStyle(.plain)
    }
}

struct AppleDetailActionButtonLabel: View {
    let title: String
    let glyph: AppleDetailActionButtonGlyph
    let kind: AppleDetailActionButtonKind
    let width: CGFloat?

    // Play, Download, My List and Rate were the only things on the detail page
    // that did not grow with the text size: a hard-coded 15 pt label and a
    // pinned 36 pt height meant that at the largest accessibility size the two
    // most important controls stayed exactly as small as they are now while the
    // synopsis beside them was enormous (measured on the phone, 2026-09-17).
    // These scale from the same numbers, so nothing moves at the default size.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var labelFontSize: CGFloat =
        AppleDetailMetrics.actionButtonLabelFontSize
    @ScaledMetric(relativeTo: .body) private var glyphSize: CGFloat =
        AppleDetailMetrics.actionButtonGlyphSize
    @ScaledMetric(relativeTo: .body) private var buttonHeight: CGFloat =
        AppleDetailMetrics.actionButtonHeight

    var body: some View {
            HStack(spacing: 6) {
                switch glyph {
                case .systemImage(let name):
                    Image(systemName: name)
                        .font(.system(size: glyphSize))
                case .progress:
                    ProgressView()
                        .tint(kind.foreground)
                }
                Text(title)
                    .font(.system(size: labelFontSize, weight: .semibold))
                    // A fixed width cannot hold a label this size, so above the
                    // accessibility threshold the button hugs its content and
                    // the label may take a second line.
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    .minimumScaleFactor(0.8)
                    .allowsTightening(true)
            }
            .foregroundStyle(kind.foreground)
            .padding(.horizontal, AppleDetailMetrics.actionButtonHorizontalPadding)
            .frame(
                width: dynamicTypeSize.isAccessibilitySize
                    ? nil
                    : (width ?? AppleDetailMetrics.defaultActionButtonWidth)
            )
            .frame(minHeight: buttonHeight)
            .background(
                kind.fill,
                in: RoundedRectangle(cornerRadius: AppleDetailMetrics.actionButtonCornerRadius)
            )
            .overlay {
                RoundedRectangle(cornerRadius: AppleDetailMetrics.actionButtonCornerRadius)
                    .stroke(kind.stroke, lineWidth: 1)
            }
            .contentShape(
                RoundedRectangle(cornerRadius: AppleDetailMetrics.actionButtonCornerRadius)
            )
    }
}

private struct AppleDetailRowButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 10)
            .background(
                .white.opacity(isFocused ? 0.16 : (configuration.isPressed ? 0.1 : 0)),
                in: .rect(cornerRadius: 12)
            )
            .scaleEffect(reduceMotion ? 1 : (isFocused ? 1.02 : 1))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isFocused)
    }
}

#if os(iOS) || os(visionOS)
@MainActor
private struct AppleYouTubeAutoPreview: UIViewRepresentable {
    let url: URL
    let artworkURL: URL?
    let isLandscape: Bool
    @Binding var isPlaying: Bool
    @Binding var isMuted: Bool
    @Binding var replayGeneration: Int
    let showsReplay: Bool
    let onStateChange: (String, Bool, Int?) -> Void
    let onTap: () -> Void
    let onMute: () -> Void
    let onReplay: () -> Void

    final class Coordinator: NSObject, WKScriptMessageHandler {
        var loadedURL: URL?
        var loadedLandscape: Bool?
        var lastMuted = true
        var lastPlaying = true
        var lastReplayGeneration = 0
        var onStateChange: ((String, Bool, Int?) -> Void)?
        private weak var webView: WKWebView?
        private weak var container: PlayerContainer?
        private var playbackIntent = true
        private var revealGeneration = 0

        func attach(to container: PlayerContainer) {
            self.container = container
            self.webView = container.webView
        }

        func setPlaybackIntent(_ isPlaying: Bool) {
            playbackIntent = isPlaying
            lastPlaying = isPlaying
        }

        func prepareForPlayback() {
            playbackIntent = true
            revealGeneration += 1
            container?.setPreviewVisible(false)
            webView?.layer.removeAllAnimations()
            webView?.alpha = 1
        }

        func hidePreview() {
            playbackIntent = false
            revealGeneration += 1
            lastPlaying = false
            container?.setPreviewVisible(false)
            webView?.layer.removeAllAnimations()
            webView?.alpha = 1
        }

        private func reveal(muted: Bool) {
            guard playbackIntent, let webView, let container else { return }
            let generation = revealGeneration
            measurePicture(webView: webView) { [weak self] window in
                guard let self, self.revealGeneration == generation, self.playbackIntent,
                      let webView = self.webView, let container = self.container else { return }
                if let window {
                    container.pictureWindow = window
                    container.hasMeasuredPicture = true
                }
                // The artwork cover hides loading frames while WebKit remains
                // renderable. Reveal the live view, never a captured video
                // frame — the snapshot above is only ever measured, never
                // displayed.
                webView.alpha = 1
                container.setPreviewVisible(true)
                print("[OpenStream] trailer native reveal: live viewport")
                self.onStateChange?("revealed", muted, nil)
                if !container.hasMeasuredPicture {
                    self.scheduleRemeasure(generation: generation, remaining: 3)
                }
            }
        }

        // Measures the non-black picture band of the current frame. The
        // snapshot is used only to read pixels and is never shown.
        private func measurePicture(webView: WKWebView, completion: @escaping (ClosedRange<CGFloat>?) -> Void) {
            let config = WKSnapshotConfiguration()
            config.afterScreenUpdates = false
            config.snapshotWidth = NSNumber(value: 256)
            webView.takeSnapshot(with: config) { image, _ in
                guard let cgImage = image?.cgImage else {
                    print("[OpenStream] trailer picture snapshot: no image")
                    completion(nil)
                    return
                }
                let window = AppleTrailerPreviewLayout.pictureWindow(in: cgImage)
                print("[OpenStream] trailer picture snapshot: \(cgImage.width)x\(cgImage.height) window=\(window.map { "\($0.lowerBound)...\($0.upperBound)" } ?? "nil")")
                completion(window)
            }
        }

        // A blank or ambiguous first frame (fade-in, title card) means the
        // reveal shows an unmeasured crop. Keep trying while still playing so
        // a wide, letterboxed trailer settles into its true picture band
        // shortly after appearing, instead of staying uncropped for good.
        private func scheduleRemeasure(generation: Int, remaining: Int) {
            guard remaining > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self, self.revealGeneration == generation, self.playbackIntent,
                      let webView = self.webView, let container = self.container,
                      !container.hasMeasuredPicture else { return }
                self.measurePicture(webView: webView) { [weak self] window in
                    guard let self, self.revealGeneration == generation, !container.hasMeasuredPicture else { return }
                    if let window {
                        container.hasMeasuredPicture = true
                        UIView.animate(withDuration: 0.25) {
                            container.pictureWindow = window
                            container.layoutIfNeeded()
                        }
                    } else {
                        self.scheduleRemeasure(generation: generation, remaining: remaining - 1)
                    }
                }
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "trailerState",
                  let payload = message.body as? [String: Any],
                  let state = payload["state"] as? String else { return }
            let muted = payload["muted"] as? Bool ?? lastMuted
            lastMuted = muted
            let errorCode = payload["errorCode"] as? Int
            let mediaTime = payload["mediaTime"] as? Double ?? 0
            let quality = payload["quality"] as? String ?? ""
            print("[OpenStream] trailer iframe state=\(state) time=\(mediaTime) muted=\(muted) quality=\(quality) error=\(errorCode.map(String.init) ?? "none")")
            if state == "revealed" {
                guard playbackIntent else { return }
                reveal(muted: muted)
                return
            } else if state == "ended" {
                // Acknowledge only after native pixels are hidden. The page
                // pauses the player on this acknowledgement, never before it.
                hidePreview()
                webView?.evaluateJavaScript("window.completeTrailerEnd();", completionHandler: nil)
            } else if state == "paused" || state == "error" {
                hidePreview()
            } else if state == "concealed" {
                revealGeneration += 1
                container?.setPreviewVisible(false)
                webView?.layer.removeAllAnimations()
                webView?.alpha = 1
            }
            onStateChange?(state, muted, errorCode)
        }
    }

    final class PlayerContainer: UIView {
        let webView: WKWebView
        private let artworkCover: UIView & UIContentView
        private var artworkURL: URL?
        let touchShield = UIButton(type: .custom)
        let muteButton = UIButton(type: .system)
        var onTap: (() -> Void)?
        var onMute: (() -> Void)?
        var onPause: (() -> Void)?
        var onReplay: (() -> Void)?
        var isLandscape = false { didSet { setNeedsLayout() } }
        var pictureWindow: ClosedRange<CGFloat> = 0...1 { didSet { setNeedsLayout() } }
        var hasMeasuredPicture = false
        private var isPlaying = true
        private var previewVisible = false

        init(frame: CGRect, messageHandler: WKScriptMessageHandler, artworkURL: URL?) {
            self.artworkURL = artworkURL
            artworkCover = UIHostingConfiguration {
                AppleCatalogArtwork(url: artworkURL)
            }.margins(.all, 0).makeContentView()
            let configuration = WKWebViewConfiguration()
            configuration.allowsInlineMediaPlayback = true
            configuration.mediaTypesRequiringUserActionForPlayback = []
            configuration.allowsPictureInPictureMediaPlayback = false
            configuration.websiteDataStore = .nonPersistent()
            configuration.userContentController.add(messageHandler, name: "trailerState")
            webView = WKWebView(frame: .zero, configuration: configuration)
            super.init(frame: frame)

            backgroundColor = .clear
            clipsToBounds = true
            layer.masksToBounds = true
            webView.isOpaque = false
            webView.backgroundColor = .clear
            webView.clipsToBounds = true
            webView.layer.masksToBounds = true
            webView.scrollView.backgroundColor = .clear
            webView.scrollView.isScrollEnabled = false
            webView.scrollView.clipsToBounds = true
            webView.scrollView.pinchGestureRecognizer?.isEnabled = false
            webView.scrollView.contentInsetAdjustmentBehavior = .never
            webView.accessibilityIgnoresInvertColors = true
            webView.isAccessibilityElement = false
            webView.accessibilityElementsHidden = true
            webView.isUserInteractionEnabled = false
            webView.alpha = 1
            addSubview(webView)

            // Measure WebKit under artwork, but keep native controls above
            // the cover so pause, sound, and replay always remain available.
            artworkCover.isUserInteractionEnabled = false
            artworkCover.accessibilityElementsHidden = true
            artworkCover.clipsToBounds = true
            addSubview(artworkCover)

            // WKWebView can still become the effective UIKit touch surface
            // beneath SwiftUI's transparent layers. Keep the iframe entirely
            // non-interactive and put the two owned controls in this same
            // container so YouTube never receives a user gesture.
            touchShield.backgroundColor = .clear
            touchShield.accessibilityIdentifier = "detail.trailer.toggle"
            touchShield.addTarget(self, action: #selector(tapPreview), for: .primaryActionTriggered)
            addSubview(touchShield)

            muteButton.tintColor = .white
            #if os(visionOS)
            muteButton.backgroundColor = .clear
            muteButton.hoverStyle = .init(effect: .highlight)
            #else
            muteButton.backgroundColor = UIColor.black.withAlphaComponent(0.5)
            #endif
            muteButton.layer.cornerRadius = 17
            muteButton.clipsToBounds = true
            muteButton.accessibilityIdentifier = "detail.trailer.mute"
            muteButton.addTarget(self, action: #selector(mutePreview), for: .primaryActionTriggered)
            addSubview(muteButton)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func layoutSubviews() {
            super.layoutSubviews()
            let viewport = AppleTrailerPreviewLayout.playerFrame(in: bounds.size, isLandscape: isLandscape)
            let picture = AppleTrailerPreviewLayout.playerFrame(
                in: bounds.size, isLandscape: isLandscape, pictureWindow: pictureWindow
            )
            // Keep the WebKit viewport stable while applying the cover crop.
            // A native transform avoids resizing the playing iframe for a crop.
            if webView.bounds.size != viewport.size {
                webView.bounds = CGRect(origin: .zero, size: viewport.size)
            }
            webView.center = CGPoint(x: picture.midX, y: picture.midY)
            if viewport.width > 0, viewport.height > 0 {
                webView.transform = CGAffineTransform(scaleX: picture.width / viewport.width, y: picture.height / viewport.height)
            }
            artworkCover.frame = bounds
            touchShield.frame = bounds
            #if os(visionOS)
            let controlSide: CGFloat = 60
            #else
            let controlSide: CGFloat = 34
            #endif
            muteButton.frame = CGRect(
                x: bounds.maxX - 12 - controlSide,
                y: bounds.maxY - 12 - controlSide,
                width: controlSide, height: controlSide
            )
            bringSubviewToFront(muteButton)
        }

        func updateControls(isPlaying: Bool, isMuted: Bool, showsReplay: Bool) {
            self.isPlaying = isPlaying
            updatePlaybackValue()
            // Keep the owned bottom-right control mounted in every trailer
            // state. UIKit sits above SwiftUI hit testing, so replay must be
            // handled here as well as drawn here.
            muteButton.isHidden = false
            touchShield.accessibilityLabel = isPlaying ? "Pause trailer preview" : "Play trailer preview"
            muteButton.setImage(
                UIImage(systemName: showsReplay
                    ? "arrow.counterclockwise"
                    : (isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")),
                for: .normal
            )
            muteButton.accessibilityLabel = showsReplay
                ? "Replay trailer"
                : (isMuted ? "Turn trailer sound on" : "Mute trailer")
            muteButton.accessibilityIdentifier = showsReplay ? "detail.trailer.replay" : "detail.trailer.mute"
            muteButton.accessibilityValue = showsReplay ? nil : (isMuted ? "Muted" : "Sound on")
        }

        func updateArtwork(_ url: URL?) {
            guard artworkURL != url else { return }
            artworkURL = url
            artworkCover.configuration = UIHostingConfiguration {
                AppleCatalogArtwork(url: url)
            }.margins(.all, 0)
        }

        func setPreviewVisible(_ visible: Bool) {
            previewVisible = visible
            artworkCover.isHidden = visible
            updatePlaybackValue()
        }

        private func updatePlaybackValue() {
            touchShield.accessibilityValue = isPlaying ? (previewVisible ? "Playing" : "Loading") : "Paused"
        }

        @objc private func tapPreview() {
            if isPlaying {
                onPause?()
                webView.alpha = 1
                webView.evaluateJavaScript("window.setTrailerPlaying(false);", completionHandler: nil)
            }
            onTap?()
        }

        @objc private func mutePreview() {
            if isPlaying {
                onMute?()
            } else {
                onReplay?()
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PlayerContainer {
        context.coordinator.onStateChange = onStateChange
        context.coordinator.lastMuted = isMuted
        context.coordinator.lastReplayGeneration = replayGeneration
        context.coordinator.setPlaybackIntent(isPlaying)
        let container = PlayerContainer(frame: .zero, messageHandler: context.coordinator, artworkURL: artworkURL)
        container.isLandscape = isLandscape
        container.onTap = onTap
        container.onMute = onMute
        container.onReplay = onReplay
        container.onPause = context.coordinator.hidePreview
        context.coordinator.attach(to: container)
        container.updateControls(
            isPlaying: isPlaying,
            isMuted: isMuted,
            showsReplay: showsReplay
        )
        load(url, in: container.webView, context: context)
        return container
    }

    func updateUIView(_ view: PlayerContainer, context: Context) {
        context.coordinator.onStateChange = onStateChange
        view.onTap = onTap
        view.onMute = onMute
        view.onReplay = onReplay
        view.onPause = context.coordinator.hidePreview
        view.isLandscape = isLandscape
        view.updateArtwork(artworkURL)
        view.updateControls(
            isPlaying: isPlaying,
            isMuted: isMuted,
            showsReplay: showsReplay
        )
        // Rotation changes the crop geometry but must not tear down the
        // YouTube player. Keep the WKWebView alive and let layoutSubviews plus
        // the page resize handler update its frame in place.
        if context.coordinator.loadedURL != url {
            view.pictureWindow = 0...1
            view.hasMeasuredPicture = false
            context.coordinator.prepareForPlayback()
            context.coordinator.setPlaybackIntent(isPlaying)
            load(url, in: view.webView, context: context)
        }
        if context.coordinator.loadedLandscape != isLandscape {
            context.coordinator.loadedLandscape = isLandscape
            view.webView.evaluateJavaScript("window.setTrailerLandscape(\(isLandscape ? "true" : "false"));", completionHandler: nil)
        }
        if context.coordinator.lastPlaying != isPlaying {
            context.coordinator.lastPlaying = isPlaying
            if isPlaying {
                context.coordinator.prepareForPlayback()
            } else {
                context.coordinator.hidePreview()
            }
            view.webView.evaluateJavaScript(
                "window.setTrailerPlaying(\(isPlaying ? "true" : "false"));",
                completionHandler: nil
            )
        }
        if context.coordinator.lastReplayGeneration != replayGeneration {
            context.coordinator.lastReplayGeneration = replayGeneration
            context.coordinator.prepareForPlayback()
            view.webView.evaluateJavaScript("window.restartTrailer();", completionHandler: nil)
        }
        guard context.coordinator.lastMuted != isMuted else { return }
        context.coordinator.lastMuted = isMuted
        view.webView.evaluateJavaScript(
            AppleTrailerSoundBridge.javascriptCommand(isMuted: isMuted),
            completionHandler: nil
        )
    }

    static func dismantleUIView(_ view: PlayerContainer, coordinator: Coordinator) {
        coordinator.hidePreview()
        view.webView.evaluateJavaScript("window.setTrailerPlaying(false);", completionHandler: nil)
        view.webView.stopLoading()
        view.webView.loadHTMLString("", baseURL: nil)
        coordinator.loadedURL = nil
        coordinator.loadedLandscape = nil
        coordinator.onStateChange = nil
    }

    private func load(_ url: URL, in view: WKWebView, context: Context) {
        context.coordinator.loadedURL = url
        context.coordinator.loadedLandscape = isLandscape
        let html = AppleYouTubePreviewHTML.document(
            embedURL: url,
            startsPlaying: isPlaying,
            isLandscape: isLandscape,
            startsMuted: isMuted
        )
        view.loadHTMLString(html, baseURL: URL(string: "https://openstream.app"))
    }
}
#endif

enum AppleTrailerPreviewLayout {
    // A 4:3 hero needs only the minimal cover scale for a 16:9 source. The
    // negative offset puts the visible source window below YouTube's title
    // strip and above its lower branding row.
    static let cropZoom: CGFloat = 1.35
    static let landscapeTopCrop: CGFloat = 0.14
    static let landscapeBottomCrop: CGFloat = 0.09
    static let landscapeZoom: CGFloat = 1 / (1 - landscapeTopCrop - landscapeBottomCrop)
    static let verticalOffsetFraction: CGFloat = -0.08

    static var visiblePlayerWindow: ClosedRange<CGFloat> {
        let start = (cropZoom - 1) / (2 * cropZoom) - verticalOffsetFraction / cropZoom
        return start...(start + 1 / cropZoom)
    }

    static func playerFrame(in size: CGSize, isLandscape: Bool, pictureWindow: ClosedRange<CGFloat> = 0...1) -> CGRect {
        let zoom = isLandscape ? landscapeZoom : cropZoom
        let pictureFraction = pictureWindow.upperBound - pictureWindow.lowerBound
        let height = max(size.height * zoom / pictureFraction, size.width * 9 / 16)
        let width = height * 16 / 9
        // The picture band (measured raster minus any baked-in mattes) stands
        // in for the full raster: crop zoom and offset apply relative to the
        // band, not the raw 0...1 iframe, so mattes never reach the hero edge.
        let topCrop = isLandscape ? landscapeTopCrop : visiblePlayerWindow.lowerBound
        let y = -height * (pictureWindow.lowerBound + pictureFraction * topCrop)
            - max(0, height * pictureFraction / zoom - size.height) / 2
        return CGRect(x: (size.width - width) / 2, y: y, width: width, height: height)
    }

    // Raster fraction (top...bottom) of the 16:9 iframe that ends up visible
    // on screen for a given hero size. Used by tests to assert a measured
    // picture band never lets its own mattes show.
    static func visibleRasterWindow(
        in size: CGSize, isLandscape: Bool, pictureWindow: ClosedRange<CGFloat> = 0...1
    ) -> ClosedRange<CGFloat> {
        let frame = playerFrame(in: size, isLandscape: isLandscape, pictureWindow: pictureWindow)
        let top = -frame.minY / frame.height
        let bottom = (size.height - frame.minY) / frame.height
        return top...bottom
    }

    // The iframe remains 16:9. Wide trailers can bake black mattes into that
    // raster, so measure their picture before applying the 14% / 9% crop.
    // nil means an opening fade/blank snapshot, not a usable video frame.
    static func pictureWindow(in image: CGImage) -> ClosedRange<CGFloat>? {
        let width = 256
        let height = max(1, Int(CGFloat(width) * CGFloat(image.height) / CGFloat(image.width)))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        func isBlack(_ row: Int) -> Bool {
            let range = (width / 10)..<(width * 9 / 10)
            let dark = range.filter { x in
                let i = (row * width + x) * 4
                return max(pixels[i], pixels[i + 1], pixels[i + 2]) < 16
            }.count
            return CGFloat(dark) / CGFloat(range.count) > 0.97
        }
        guard (0..<height).contains(where: { !isBlack($0) }) else { return nil }
        let top = (0..<height).prefix(while: isBlack).count
        let bottom = (0..<height).reversed().prefix(while: isBlack).count
        if top <= 2 && bottom <= 2 { return 0...1 }
        // A title card or dark opening shot does not establish that the
        // source is unletterboxed. Wait for a measurable frame instead.
        guard top > 2, bottom > 2, top < height / 4, bottom < height / 4,
              abs(top - bottom) <= max(2, height / 40) else { return nil }
        return CGFloat(top) / CGFloat(height)...(1 - CGFloat(bottom) / CGFloat(height))
    }
}

private struct AppleDetailViewport: Equatable {
    let size: CGSize
    let insets: EdgeInsets
}

private enum AppleTitleLogoState: Equatable {
    case unavailable
    case loading
    case valid(URL)

    var hasOverlay: Bool {
        if case .valid = self { return true }
        return false
    }

    /// `nil` while the wordmark is still being validated.
    var validation: Bool? {
        switch self {
        case .unavailable: false
        case .loading: nil
        case .valid: true
        }
    }
}

enum AppleDetailLayout: Sendable {
    case portraitPhone
    case portraitIPad
    case landscapeIPad
}

struct AppleDetailMetrics {
    // Action controls
    #if os(visionOS)
    static let actionButtonHeight: CGFloat = 60
    #else
    static let actionButtonHeight: CGFloat = 36
    #endif
    static let actionButtonCornerRadius: CGFloat = 18
    #if os(visionOS)
    static let actionButtonLabelFontSize: CGFloat = 20
    #else
    static let actionButtonLabelFontSize: CGFloat = 15
    #endif
    #if os(visionOS)
    static let actionButtonGlyphSize: CGFloat = 18
    #else
    static let actionButtonGlyphSize: CGFloat = 13
    #endif
    static let actionButtonHorizontalPadding: CGFloat = 16
    static let actionButtonGap: CGFloat = 10
    static let defaultActionButtonWidth: CGFloat = 140

    // Secondary icon row
    static let iconGlyphSize: CGFloat = 20
    #if os(visionOS)
    static let iconLabelFontSize: CGFloat = 16
    #else
    static let iconLabelFontSize: CGFloat = 11
    #endif
    static let iconLabelSpacing: CGFloat = 2
    static let iconActionWidth: CGFloat = 96
    #if os(visionOS)
    static let iconRowHeight: CGFloat = 72
    #else
    static let iconRowHeight: CGFloat = 44
    #endif

    // Content-page rhythm
    static let heroToTitleSpacing: CGFloat = 8
    static let titleToMetadataSpacing: CGFloat = 6
    static let metadataToButtonsSpacing: CGFloat = 12
    static let buttonsToIconRowSpacing: CGFloat = 12
    static let iconRowToSynopsisSpacing: CGFloat = 16
    static let sectionHeaderTopSpacing: CGFloat = 20
    static let sectionHeaderBottomSpacing: CGFloat = 10

    // Layout-resolved widths
    static let portraitColumnInset: CGFloat = 16

    /// The widest a column of prose is allowed to get on a regular-width
    /// screen. Already the landscape-iPad figure; now the portrait one too, so
    /// the detail page reads the same width whichever way the iPad is held.
    static let regularContentWidth: CGFloat = 680

    /// The detail page's content column in portrait.
    ///
    /// This used to be the *action row* width, which is right on a phone purely
    /// by coincidence — there, two half-column pills plus the gap come to
    /// exactly the content column. On an iPad the action row is two fixed
    /// 150 pt pills, so the whole page (synopsis, Episodes header, every episode
    /// row) was squeezed into **310 pt of an 834 pt page**, with the episode
    /// titles wrapping to two lines and their dates to three while ~500 pt sat
    /// empty beside them (measured on the review iPad, 2026-09-17).
    static func portraitContentWidth(viewportWidth: CGFloat, actionColumnWidth: CGFloat) -> CGFloat {
        min(regularContentWidth, max(actionColumnWidth, viewportWidth - 2 * portraitColumnInset))
    }
    /// 180, not 150, because the download action's label is variable-length —
    /// "Download Season 1", "Download Specials" — and at 150 it truncated to
    /// "Download Seas…" on the review iPad (2026-09-17). A phone's pill is
    /// `(width − 32 − 10) / 2` ≈ 180 and the same label fits there, so the
    /// smaller device had the larger button. This is that number, made explicit.
    static let portraitIPadActionButtonWidth: CGFloat = 180
    #if os(visionOS)
    static let landscapeIPadActionButtonWidth: CGFloat = 180
    #else
    static let landscapeIPadActionButtonWidth: CGFloat = 140
    #endif

    // Landscape overlay
    static let landscapeOverlaySpacing: CGFloat = 10
    static let landscapeOverlayBottomMargin: CGFloat = 28
    static let landscapeOverlayLeadingMargin: CGFloat = 40
    static let landscapeLogoMaxWidth: CGFloat = 320
    static let landscapeLogoMaxHeight: CGFloat = 80
    // Phone landscape uses the same overlay with tighter margins and a smaller wordmark.
    static let compactLandscapeOverlayBottomMargin: CGFloat = 16
    static let compactLandscapeOverlayLeadingMargin: CGFloat = 16
    static let compactLandscapeLogoMaxWidth: CGFloat = 220
    static let compactLandscapeLogoMaxHeight: CGFloat = 56
    static let landscapeTitleLogoWidthFraction: CGFloat = 0.40
    static let landscapeTitleFontSize: CGFloat = 20

    // Badge geometry and typography (Apple TV values come from
    // `AppleTVDetailMetrics`: Body 29 metadata with Caption 2 badges)
    #if os(visionOS)
    static let metadataFontSize: CGFloat = 18
    #elseif os(tvOS)
    static let metadataFontSize: CGFloat = AppleTVDetailMetrics.metadataFontSize
    #else
    static let metadataFontSize: CGFloat = 13
    #endif
    #if os(visionOS)
    static let badgeFontSize: CGFloat = 13
    #elseif os(tvOS)
    static let badgeFontSize: CGFloat = AppleTVDetailMetrics.badgeFontSize
    #else
    static let badgeFontSize: CGFloat = 9.5
    #endif
    static let badgeTracking: CGFloat = 0.6
    static let badgeStrokeWidth: CGFloat = 1
    #if os(tvOS)
    static let badgeCornerRadius: CGFloat = AppleTVDetailMetrics.badgeCornerRadius
    static let badgeHorizontalPadding: CGFloat = AppleTVDetailMetrics.badgeHorizontalPadding
    #else
    static let badgeCornerRadius: CGFloat = 3
    static let badgeHorizontalPadding: CGFloat = 4
    #endif
    static let badgeVerticalPadding: CGFloat = 1.5
    #if os(visionOS)
    static let badgeHeight: CGFloat = 24
    #elseif os(tvOS)
    static let badgeHeight: CGFloat = AppleTVDetailMetrics.badgeHeight
    #else
    static let badgeHeight: CGFloat = 16
    #endif
    #if os(tvOS)
    static let badgeGap: CGFloat = AppleTVDetailMetrics.badgeGap
    #else
    static let badgeGap: CGFloat = 6
    #endif
    static let maxBadgeCount = 6

    // Existing hero geometry
    static let phoneAspectRatio: CGFloat = 4.0 / 3.0
    static let iPadHeightFraction: CGFloat = 0.60
    static let featuredHeroPortraitHeight: CGFloat = 390
    static let featuredHeroLandscapeHeightFraction: CGFloat = 0.55
    static let landscapeHeightFraction: CGFloat = 1.0
    static let titleLogoWidthFraction: CGFloat = 0.70
    static let titleLogoMaxHeight: CGFloat = 96
    static let titleLogoIntrusion: CGFloat = 14
    static let titleLogoBottomBuffer: CGFloat = 24
    static let wideEpisodeThreshold: CGFloat = 1_000
    static let bottomGradientHeight: CGFloat = 24
    static let trailerCrossfadeDuration: Double = 0.6

    static let portraitTitleFontSize: CGFloat = 17

    /// Landscape in any size class, so the phone gets the same full-screen hero
    /// as the iPad instead of the portrait 4:3 crop.
    static func isLandscapeLayout(viewport: CGSize) -> Bool {
        viewport.width > 0 && viewport.height > 0 && viewport.width > viewport.height
    }

    static func heroHeight(
        in viewport: CGSize,
        horizontalSizeClassIsRegular: Bool
    ) -> CGFloat {
        let fourByThree = viewport.width * 0.75
        guard viewport.width > 0, viewport.height > 0 else { return fourByThree }
        if isLandscapeLayout(viewport: viewport) {
            return viewport.height * landscapeHeightFraction
        }
        if horizontalSizeClassIsRegular {
            return min(fourByThree, viewport.height * iPadHeightFraction)
        }
        return fourByThree
    }

    /// Discover's featured hero: portrait keeps its fixed height, landscape is
    /// capped at 55% of the viewport so the shelves stay in view.
    static func featuredHeroHeight(in viewport: CGSize) -> CGFloat {
        guard isLandscapeLayout(viewport: viewport) else { return featuredHeroPortraitHeight }
        return min(
            viewport.height * featuredHeroLandscapeHeightFraction,
            (viewport.width - 32) * 9 / 16
        )
    }

    static func actionButtonWidth(for layout: AppleDetailLayout, screenWidth: CGFloat) -> CGFloat {
        switch layout {
        case .portraitPhone:
            let column = max(0, screenWidth - 2 * portraitColumnInset)
            return max(0, (column - actionButtonGap) / 2)
        case .portraitIPad:
            return portraitIPadActionButtonWidth
        case .landscapeIPad:
            return landscapeIPadActionButtonWidth
        }
    }

    /// The narrowest viewport that is a tablet rather than a phone in portrait.
    /// Every iPad portrait width (744 mini, 834, 1024) is above it; every phone
    /// portrait width (320–440) is below.
    static let portraitTabletWidthThreshold: CGFloat = 600

    /// How wide a featured-hero action button should be in portrait, or `nil`
    /// for "fill the column".
    ///
    /// Filling the column is right on the phone, where half of 402 pt is a
    /// normal-looking pill. On an iPad in portrait the same rule gave *Play* a
    /// **367 pt** capsule with a 40 pt label marooned in the middle of it
    /// (measured on the review iPad, 2026-09-17) — the phone layout simply
    /// stretched. The detail page already uses a fixed pill there; the hero now
    /// uses the same one.
    static func featuredActionButtonWidth(portraitViewportWidth width: CGFloat) -> CGFloat? {
        width >= portraitTabletWidthThreshold ? portraitIPadActionButtonWidth : nil
    }

    static func iconRowWidth(for layout: AppleDetailLayout, screenWidth: CGFloat) -> CGFloat {
        actionButtonWidth(for: layout, screenWidth: screenWidth) * 2 + actionButtonGap
    }

    static func actionButtonFrames(
        for layout: AppleDetailLayout,
        screenWidth: CGFloat
    ) -> (play: CGRect, download: CGRect) {
        let width = actionButtonWidth(for: layout, screenWidth: screenWidth)
        let play = CGRect(x: 0, y: 0, width: width, height: actionButtonHeight)
        let download = CGRect(
            x: play.maxX + actionButtonGap,
            y: play.minY,
            width: width,
            height: actionButtonHeight
        )
        return (play, download)
    }
}

enum AppleFormatBadgeKind: Equatable, Sendable {
    case text(String)
    case image(String)

    static func resolve(_ value: String) -> Self? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "4K": return .text("4K")
        case "HD": return .text("HD")
        case "HDR": return .text("HDR")
        case "HDR10+": return .text("HDR10+")
        case "CC": return .text("CC")
        case "AD": return .text("AD")
        case "SDH": return .text("SDH")
        case "G", "PG", "PG-13", "R", "NC-17", "NR", "TV-Y", "TV-Y7", "TV-G", "TV-PG", "TV-14", "TV-MA":
            return .text(value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())
        case "DV", "DOLBY VISION": return .image("dolby-vision")
        case "DOLBY ATMOS": return .image("dolby-atmos")
        case "DOLBY AUDIO": return .image("dolby-audio")
        default: return nil
        }
    }

    static func isRenderable(_ kind: Self) -> Bool {
        switch kind {
        case .text: return true
        case .image(let name):
            return Bundle.module.url(forResource: name, withExtension: "pdf", subdirectory: "Badges") != nil
                || Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "Badges") != nil
        }
    }
}

enum AppleTitleMetadataPresentation {
    static func textValues(genres: [String], releaseInfo: String?, runtimeMinutes: Int?) -> [String] {
        var values: [String] = []
        if let genre = genres.map(clean).first(where: { !$0.isEmpty }) { values.append(genre) }
        if let releaseInfo = formattedReleaseInfo(releaseInfo) { values.append(releaseInfo) }
        if let runtimeMinutes, (1 ... 24 * 60).contains(runtimeMinutes) {
            values.append(formattedRuntime(runtimeMinutes))
        }
        return values
    }

    static func orderedBadges(contentRating: String?, formatBadges: [String], limit: Int) -> [String] {
        let candidates = [contentRating].compactMap { $0 } + formatBadges
        let ranked = candidates.compactMap { raw -> (String, Int)? in
            guard let kind = AppleFormatBadgeKind.resolve(raw) else { return nil }
            switch kind {
            case .text(let title):
                let rank: Int
                switch title {
                case "4K", "HD": rank = 10
                case "HDR", "HDR10+": rank = 30
                case "CC": rank = 50
                case "SDH": rank = 60
                case "AD": rank = 70
                default: rank = 0
                }
                return (title, rank)
            case .image:
                // Owner policy: no third-party wordmarks on title metadata.
                return nil
            }
        }
        .sorted { lhs, rhs in lhs.1 == rhs.1 ? lhs.0 < rhs.0 : lhs.1 < rhs.1 }

        var seen = Set<String>()
        let has4K = ranked.contains { $0.0 == "4K" }
        return ranked.compactMap { value in
            let key = value.0.uppercased()
            if key == "HD", has4K { return nil }
            guard seen.insert(key).inserted else { return nil }
            return value.0
        }.prefix(max(0, limit)).map { $0 }
    }

    static func formattedRuntime(_ minutes: Int) -> String {
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours == 0 { return "\(remainder) min" }
        if remainder == 0 { return "\(hours) hr" }
        return "\(hours) hr \(remainder) min"
    }

    static func formattedReleaseInfo(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleanValue = clean(value)
        guard !cleanValue.isEmpty else { return nil }
        let day = String(cleanValue.prefix(10))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: day), formatter.string(from: date) == day else { return cleanValue }
        formatter.dateFormat = "MMM d, yyyy"
        return formatter.string(from: date)
    }

    private static func clean(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct AppleFormatBadge: View {
    private let kind: AppleFormatBadgeKind?
    @Environment(\.colorScheme) private var colorScheme

    init(_ value: String) {
        kind = AppleFormatBadgeKind.resolve(value)
    }

    @ViewBuilder
    var body: some View {
        switch kind {
        case .text(let title):
            Text(title)
                .font(.system(
                    size: AppleDetailMetrics.badgeFontSize,
                    weight: .bold,
                    design: .rounded
                ))
                .tracking(AppleDetailMetrics.badgeTracking)
                .foregroundStyle(badgeForeground)
                .padding(.horizontal, AppleDetailMetrics.badgeHorizontalPadding)
                .padding(.vertical, AppleDetailMetrics.badgeVerticalPadding)
                .frame(height: AppleDetailMetrics.badgeHeight)
                .overlay {
                    RoundedRectangle(cornerRadius: AppleDetailMetrics.badgeCornerRadius)
                        .stroke(badgeStroke, lineWidth: AppleDetailMetrics.badgeStrokeWidth)
                }
                .alignmentGuide(.firstTextBaseline) { dimensions in
                    dimensions[.bottom]
                }
        case .image(let name):
            if Self.assetExists(named: name) {
                Image("Badges/\(name)", bundle: .module)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 14)
                    .foregroundStyle(badgeForeground)
                    .padding(.horizontal, AppleDetailMetrics.badgeHorizontalPadding)
                    .frame(height: AppleDetailMetrics.badgeHeight)
                    .overlay {
                        RoundedRectangle(cornerRadius: AppleDetailMetrics.badgeCornerRadius)
                            .stroke(badgeStroke, lineWidth: AppleDetailMetrics.badgeStrokeWidth)
                    }
                    .alignmentGuide(.firstTextBaseline) { dimensions in
                        dimensions[.bottom]
                    }
            } else {
                EmptyView()
            }
        case nil:
            EmptyView()
        }
    }

    private var badgeForeground: Color {
        colorScheme == .dark ? .white.opacity(0.75) : .black.opacity(0.75)
    }

    private var badgeStroke: Color {
        colorScheme == .dark ? .white.opacity(0.60) : .black.opacity(0.60)
    }

    private static func assetExists(named name: String) -> Bool {
        Bundle.module.url(forResource: name, withExtension: "pdf", subdirectory: "Badges") != nil
            || Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "Badges") != nil
    }
}

private struct AppleDetailHeroFramePreferenceKey: PreferenceKey {
    static let defaultValue = CGRect.zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

struct AppleStremioPlayerPresentationModifier: ViewModifier {
    @Binding var presentation: AppleStremioPlayerPresentation?

    func body(content: Content) -> some View {
        #if os(visionOS)
        content.modifier(AppleVisionPlayerPresentationModifier(presentation: $presentation))
        #elseif os(macOS)
        content.sheet(item: $presentation) { AppleStremioPlayerView(presentation: $0) }
        #else
        content.fullScreenCover(item: $presentation) { AppleStremioPlayerView(presentation: $0) }
        #endif
    }
}

func appleStreamDisplayText(_ value: String) -> String {
    value.replacingOccurrences(of: #"(?i)\b(?:stremio|torrent\w*)\b"#, with: "Add-on", options: .regularExpression)
}
