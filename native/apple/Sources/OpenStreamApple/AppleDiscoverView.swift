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
        .filter { $0.isAddon }
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
    /// The scroll view's height and bar insets, which size the iPhone
    /// portrait hero and pull it up under the navigation bar.
    @State private var phoneHeroLayout = AppleHomePhoneHeroLayout()
    /// The Mac hero's size, off the window and the toolbar's inset.
    @State private var macHeroLayout = AppleMacHeroLayout()
    /// The iPad's: the same hero, off the screen and the bars' insets.
    @State private var padHeroLayout = AppleMacHeroLayout(platform: .pad)
    /// Held up for `AppleProgressVisibility.minimum` even when the catalogues
    /// come back at once, so a press on Refresh is visible as a refresh.
    @State private var isRefreshing = false
    /// Moves when the viewer removes a title from Continue Watching, so the
    /// row redraws without it (the store itself is not observed here).
    @State private var continueWatchingRemovalRevision = 0
    @State private var loadedCache = false
    /// The source configuration whose catalog refresh last finished; until it
    /// matches the current one an empty page is loading, not empty.
    @State private var settledCatalogIdentity: String?
    @State private var showsSearch = false
    /// The router revision Discover last acted on (see its `router.revision` `onChange`).
    @State private var handledRouteRevision = 0
    @State private var selectedHero: IndexedCatalogItem?
    @State private var selectedHeroAutoPlay = false
    @State private var showsSelectedHero = false
    @State private var selectedCatalog: AppleCatalogSection?
    @State private var showsCatalog = false
    // macOS is in this list now. It was left out of all four of these debug
    // review hooks, which is why a headless macOS sweep could photograph the
    // Settings tree but never the title page, the episode list or the player —
    // the three screens this app is mostly about (macOS sweep, 2026-09-21).
    #if DEBUG
    @State private var visionReviewDetail = false
    @State private var visionReviewAutoPlay = false
    @State private var visionReviewDetailOpened = false
    /// Moved by `OpenStreamDiscoverScrollY`, so a headless sweep can capture
    /// the page scrolled (the collapsed navigation bar over the hero).
    @State private var reviewScrollPosition = ScrollPosition(edge: .top)
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
    /// The heroes (media ids) whose wordmark lookup has finished; until then
    /// a hero with no wordmark yet holds its title slot empty rather than
    /// drawing the name a found logo would replace (N63).
    @State private var heroWordmarksResolved: Set<String> = []
    /// Textless hero art, keyed by media id, once TMDB has been asked. Empty
    /// through first paint by design — see `upgradeHeroArtwork`.
    @State private var heroArtwork: [String: AppleHeroArtworkUpgrade.Artwork] = [:]

    let catalogStore: AppleCatalogStore
    let sourceStore: AppleSourceStore
    let mediaIndex: AppleMediaIndexStore
    let mediaServerLibrary: AppleMediaServerLibraryStore
    let router: AppleAppRouter
    let settings: AppleSettingsStore
    let openSettings: () -> Void
    /// Backup & Sync, for No Sources' restore and import. Nil until the root
    /// view has made it.
    let backupController: AppleConfigurationController?
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
        mediaServerLibrary: AppleMediaServerLibraryStore,
        router: AppleAppRouter,
        settings: AppleSettingsStore,
        openSettings: @escaping () -> Void,
        backupController: AppleConfigurationController? = nil,
        playbackResolver: AppleStremioPlaybackResolver = AppleStremioPlaybackResolver()
    ) {
        self.catalogStore = catalogStore
        self.sourceStore = sourceStore
        self.mediaIndex = mediaIndex
        self.mediaServerLibrary = mediaServerLibrary
        self.router = router
        self.settings = settings
        self.openSettings = openSettings
        self.backupController = backupController
        self.playbackResolver = playbackResolver
    }

    private var visibleSections: [AppleCatalogSection] {
        let activeSourceIDs = Set(
            sourceStore.sources
                .filter(\.isEnabled)
                .map(\.id)
        )
        return AppleCatalogShelfPolicy.visibleSections(catalogStore.sections, activeSourceIDs: activeSourceIDs)
    }

    var body: some View {
        // Once per pass. The billboard, the Top Picks row, Continue Watching
        // and the prefetch key each rebuilt these on their own — Top Picks
        // walks and digests every catalog item — and all of it ran on the
        // main thread between the catalog cache landing and the billboard's
        // first draw at launch.
        let localContinueWatching = continueWatching
        let picks = topPicks(continueWatching: localContinueWatching)
        let heroes = featuredCandidates(continueWatching: withoutRemoved(mergedContinueWatching(local: localContinueWatching)), picks: picks)
        let hasContent = AppleCatalogShelfPolicy.hasDiscoverContent(
            hasCatalog: !visibleSections.isEmpty, hasLocalLibrary: !library.groups.isEmpty,
            hasMediaServerItems: mediaServerLibrary.shelves.contains { !$0.items.isEmpty }
                || !AppleXtreamLibraryStore.shared.continueWatching.isEmpty
        )
        Group {
            if !hasContent && (catalogIsStillLoading || mediaServerLibrary.isLoading) {
                ProgressView()
                    .controlSize(.large)
                    .accessibilityLabel("Loading")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    #if os(tvOS)
                    .background(Color.black.ignoresSafeArea())
                    #endif
            } else if !hasContent {
                discoverEmptyState
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
                        if !heroes.isEmpty {
                            #if DEBUG
                            let _ = AppleLaunchClock.mark("discover.hero")
                            #endif
                            AppleHomeHeroCarousel(
                                pageIDs: heroes.map(\.id), items: heroes.map { heroItem($0.item) },
                                wordmarks: heroes.map { heroWordmark($0, item: heroItem($0.item)) },
                                viewportSize: viewportSize, phoneLayout: phoneHeroLayout,
                                wideLayout: usesPadHero ? padHeroLayout : macHeroLayout
                            ) { index, failed, mode, count, shown, tv in
                                featuredHero(heroes[index], rotationCount: count, rotationIndex: shown,
                                    wordmarkFailed: failed, phone: mode == .phone, mac: mode == .mac,
                                    pad: mode == .pad, tv: tv)
                            }
                            .task(id: heroes.map(\.item.mediaID).joined(separator: ",")) {
                                // What the cache already knows draws at once;
                                // the rest is asked for now that the billboard
                                // has drawn, first page first. Two fixed cache
                                // peeks left a fresh install on the names for
                                // the whole session (owner 2026-09-29).
                                var unanswered = await resolveHeroWordmarks(heroes)
                                unanswered = await fetchHeroWordmarks(unanswered)
                                guard !Task.isCancelled else { return }
                                heroWordmarksResolved.formUnion(heroes.map(\.item.mediaID))
                                // Last, and only after the billboard has long
                                // since drawn: the textless backdrop is an
                                // upgrade, never something first paint waits on.
                                await upgradeHeroArtwork(heroes)
                                // An add-on that could not be reached is asked
                                // again, a bounded number of times.
                                var retry = 1
                                while !unanswered.isEmpty, let delay = AppleHeroWordmarkFetch.retryDelay(retry) {
                                    try? await Task.sleep(for: delay)
                                    guard !Task.isCancelled else { return }
                                    unanswered = await fetchHeroWordmarks(unanswered)
                                    retry += 1
                                }
                            }
                        }

                        // One list of rails. The iPhone held upright and the
                        // Mac order it by the A4 rhythm (stills, then posters,
                        // then stills); everywhere else it is the list as built.
                        let continueShelf = continueWatchingShelf(local: localContinueWatching)
                        ForEach(discoverRails(continueWatching: continueShelf.values, picks: picks)) { rail in
                            railView(rail, continueWatching: continueShelf, picks: picks)
                        }
                    }
                    #if os(tvOS)
                    .padding(.bottom, AppleTVBillboardMetrics.contentBottomInset)
                    #else
                    .padding(.vertical)
                    #endif
                    .environment(\.appleDiscoverRows, discoverRowStyle)
                }
                .scrollIndicators(AppleDesignTokens.scrollIndicatorVisibility)
                #if os(iOS)
                .refreshable { await refreshContent() }
                #endif
                #if DEBUG
                .scrollPosition($reviewScrollPosition)
                #endif
                #if os(iOS)
                .onScrollGeometryChange(for: AppleHomePhoneHeroLayout.self) { geometry in
                    // The container is the part between the bars.
                    AppleHomePhoneHeroLayout(containerHeight: geometry.containerSize.height
                                                 + geometry.contentInsets.top + geometry.contentInsets.bottom,
                                             topInset: geometry.contentInsets.top,
                                             bottomInset: geometry.contentInsets.bottom)
                } action: { _, layout in
                    phoneHeroLayout = layout
                    appleTrace("discover phone hero layout h=\(Int(layout.containerHeight)) top=\(Int(layout.topInset)) bottom=\(Int(layout.bottomInset)) art=\(Int(layout.artHeight))")
                }
                .onScrollGeometryChange(for: AppleMacHeroLayout.self) { geometry in
                    AppleMacHeroLayout(contentWidth: geometry.containerSize.width,
                                       windowHeight: geometry.containerSize.height
                                           + geometry.contentInsets.top + geometry.contentInsets.bottom,
                                       topInset: geometry.contentInsets.top,
                                       platform: .pad)
                } action: { _, layout in
                    padHeroLayout = layout
                }
                #elseif os(macOS)
                .onScrollGeometryChange(for: AppleMacHeroLayout.self) { geometry in
                    AppleMacHeroLayout(contentWidth: geometry.containerSize.width,
                                       windowHeight: geometry.containerSize.height
                                           + geometry.contentInsets.top + geometry.contentInsets.bottom,
                                       topInset: geometry.contentInsets.top)
                } action: { _, layout in
                    macHeroLayout = layout
                }
                .appleMacHeroUnderToolbar()
                #endif
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
        .navigationDestination(isPresented: $showsCatalog) {
            if let selectedCatalog,
               let source = sourceStore.sources.first(where: { $0.id == selectedCatalog.sourceID }) {
                // The live shelf, so pages loaded while the list is open show in it.
                catalogSection(liveSection(selectedCatalog), source: source).catalogList
                    .environment(\.appleTabToolbar, tabToolbarContext)
            }
        }
        .navigationDestination(isPresented: $showsSelectedHero) {
            if let selectedHero {
                detail(selectedHero, initialAutoPlay: selectedHeroAutoPlay)
            }
        }
        .overlay(alignment: .top) {
            // Not over the centred loading state, which already says it.
            if catalogStore.isLoading, hasContent {
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
            AppleTabToolbar(tab: .home, isRefreshing: isRefreshing || catalogStore.isLoading,
                            onSearch: { showsSearch = true }, onRefresh: refresh)
        }
        #endif
        #if os(macOS)
        .onChange(of: AppleMacCommandCenter.shared.refreshRevision) {
            guard AppleMacCommandCenter.shared.refreshTarget == .discover, !isRefreshing, !catalogStore.isLoading else { return }
            appleTrace("discover refresh from the menu")
            refresh()
        }
        #endif
        #if DEBUG
        .navigationDestination(isPresented: $visionReviewDetail) {
            if let value = visionReviewItem { detail(value, initialAutoPlay: visionReviewAutoPlay) }
        }
        .task(id: visibleSections.count) {
            let screen = UserDefaults.standard.string(forKey: "OpenStreamVisionScreen")
            // Search is a page pushed from Discover everywhere except Apple TV,
            // so it had no debug route at all and no sweep could reach it —
            // the macOS sweep recorded it as NOT TESTED for exactly that
            // reason. Pushing it here is the same one-line hook every other
            // screen already has.
            if screen == "search" { showsSearch = true }
            let scrollY = UserDefaults.standard.double(forKey: "OpenStreamDiscoverScrollY")
            if scrollY > 0, visibleSections.count > 0 {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                reviewScrollPosition.scrollTo(y: scrollY)
            }
            // "play" opens the same title page and starts its first stream, so
            // the player can be captured headlessly on the TV simulator.
            // Once only: this task runs again when Discover reappears, and
            // re-pushing the page there made its Back button look dead (N24).
            if (screen == "detail" || screen == "detail-movie" || screen == "episodes" || screen == "play"),
               visionReviewItem != nil, !visionReviewDetailOpened {
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
                visionReviewDetailOpened = true
                AppleTitlePageOpenProbe.pushed("first")
                visionReviewDetail = true
                // `OpenStreamDetailReopen N` pops the page after 6 s and pushes
                // it again, N times, so a trace sees repeat opens as well as
                // the first. Not this task: Discover's tasks end when it is
                // covered.
                let reopens = UserDefaults.standard.integer(forKey: "OpenStreamDetailReopen")
                if reopens > 0 {
                    Task {
                        for _ in 0..<reopens {
                            try? await Task.sleep(for: .seconds(6))
                            visionReviewDetail = false
                            try? await Task.sleep(for: .seconds(3))
                            appleTrace("detail reopen")
                            AppleTitlePageOpenProbe.pushed("reopen")
                            visionReviewDetail = true
                        }
                    }
                }
                // `OpenStreamDetailPopAfter <seconds>` goes back to Discover
                // that long after, so a probe sees the hero come back (N44).
                // Unstructured: this task sleeps while the page covers it.
                let pop = UserDefaults.standard.double(forKey: "OpenStreamDetailPopAfter")
                if pop > 0 {
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(pop))
                        appleTrace("debug detail pop")
                        visionReviewDetail = false
                    }
                }
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
            .environment(\.appleTabToolbar, tabToolbarContext)
        }
        .onChange(of: settings.top10ListsEnabled) { _, enabled in
            if enabled { loadTop10() }
            else { top10Week = nil; top10Error = nil }
        }
        // A deep link, widget, Spotlight result or App Intent moves Discover's
        // own navigation state. The stack itself keeps its identity: it used
        // to be rebuilt for every route, and replacing the visible navigation
        // controller inside the tab bar crashes iOS 18. On a platform with its
        // own Search tab the route already selected it, so a search route does
        // not push a second one here (`AppleSearchRoutePolicy`).
        //
        // `onChange`, not `task(id:)`: a task only runs while Discover is on
        // screen, so a route that arrived with a page pushed over Discover sat
        // unapplied until the viewer went back. `initial` picks up a route that
        // arrived before Discover first appeared.
        .onChange(of: router.revision, initial: true) {
            guard let route = router.route,
                  AppleSearchRoutePolicy.discoverHandlesRoute(
                    revision: router.revision, handledRevision: handledRouteRevision) else { return }
            handledRouteRevision = router.revision
            showsSelectedHero = false
            showsCatalog = false
            #if DEBUG
            visionReviewDetail = false
            #endif
            showsSearch = AppleSearchRoutePolicy.discoverShowsSearch(
                for: route, hasDedicatedSearchTab: AppleSearchRoutePolicy.platformHasDedicatedSearchTab)
        }
        .task(id: catalogConfigurationIdentity(sourceStore.sources)) {
            await mediaIndex.load()
            #if DEBUG
            AppleLaunchClock.mark("index.loaded(\(mediaIndex.records.count))")
            #endif
            try? await mediaIndex.synchronizePlaybackProgress()
            if !loadedCache {
                await catalogStore.loadCachedSections(sources: sourceStore.sources)
                loadedCache = true
                #if DEBUG
                AppleLaunchClock.mark("discover.cache(\(catalogStore.sections.count))")
                #endif
                // Nothing cached to put in the billboard: the launch cover
                // has nothing to wait for. (Not the billboard candidates —
                // building them walks the media index and digests every
                // catalog item, ~90 ms on the Apple TV sim, and sat between
                // the cache and the billboard's first draw.)
                if catalogStore.sections.allSatisfy(\.items.isEmpty) {
                    AppleLaunchReadiness.shared.markFirstScreenReady()
                }
            }
            await catalogStore.refresh(sources: sourceStore.sources)
            if !Task.isCancelled {
                settledCatalogIdentity = catalogConfigurationIdentity(sourceStore.sources)
            }
            #if DEBUG
            AppleInteractionTrace.record(.network,
                "catalog review sources=\(sourceStore.sources.count) credentialError=\(sourceStore.credentialError != nil) sections=\(catalogStore.sections.count) failures=\(catalogStore.partialErrors.count)")
            #endif
            await mediaServerLibrary.reload(sources: sourceStore.sources) { try sourceStore.mediaServerSession(for: $0) }
            applyCatalogRefreshHealth(reports: catalogStore.sourceRefreshReports, to: sourceStore)
            await indexCatalogs()
            try? await mediaIndex.synchronizePlaybackProgress()
        }
        .task(id: catalogLookupIdentity) {
            await rebuildCatalogLookup()
        }
        // The billboard titles' preview assets, which a content page would
        // otherwise wait 1.36 s for (owner: "preload metadata like wordmark
        // art so that it loads basically instantly"), are fetched by the
        // hero's own task (`fetchHeroWordmarks`), which also draws each
        // wordmark as it lands. A second warm here asked every add-on twice.
        .task(id: settings.top10ListsEnabled) {
            guard settings.top10ListsEnabled else { return }
            loadTop10()
        }
        #if DEBUG
        // `-OpenStreamDebugOpenHeroDetails YES` presses the billboard's
        // Details once, so a headless sweep reaches the title page the way a
        // viewer does from the hero (N53: every entry point keeps the bar).
        .task(id: heroes.first?.id) {
            guard UserDefaults.standard.bool(forKey: "OpenStreamDebugOpenHeroDetails"),
                  let first = heroes.first, !visionReviewDetailOpened else { return }
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            visionReviewDetailOpened = true
            selectHero(first, autoPlay: false)
        }
        #endif
        // The same Search and Refresh on every page pushed from here.
        .environment(\.appleTabToolbar, tabToolbarContext)
    }

    /// What the hero rotates through: what the owner is part-way into first,
    /// then the recommendations, then the newest catalog items (FEEDBACK X9) —
    /// only titles with a backdrop, so no page is a poster or a placeholder
    /// with no title over it. The first catalog offers more than five so the
    /// rotation can still fill once the art-less ones are passed over.
    private func featuredCandidates(continueWatching: [IndexedCatalogItem],
                                    picks: [IndexedCatalogItem]) -> [IndexedCatalogItem] {
        var values = continueWatching
        values += picks
        // A media-server-only library has no add-on catalog sections, but its
        // titles belong in the billboard just like every other playable title.
        values += mediaServerLibrary.shelves.flatMap(\.items)
            .filter { !$0.name.isEmpty && AppleCatalogDiscoveryPolicy.isTitleType($0.type) }
            .compactMap { item in
                guard let reference = AppleMediaServerItemReference.parse(item.mediaID),
                      let source = sourceStore.sources.first(where: { $0.id == reference.sourceID }) else { return nil }
                return IndexedCatalogItem(record: AppleMediaIngestion.catalogRecord(instanceID: source.id, item: item),
                                          item: item, source: source)
            }
        // Movies and shows only: a tv or channel shelf is no billboard.
        if let section = visibleSections.first(where: { AppleCatalogDiscoveryPolicy.isTitleType($0.catalog.type) }),
           let source = sourceStore.sources.first(where: { $0.id == section.sourceID }) {
            // A poster-only entry (no name) has no title to put on a billboard.
            values += section.items.filter { !$0.name.isEmpty }
                .prefix(AppleHeroRotation.maximumCandidates * 4).map { item in
                IndexedCatalogItem(record: AppleMediaIngestion.catalogRecord(instanceID: source.id, item: item),
                                   item: item, source: source)
            }
        }
        #if DEBUG
        // `OpenStreamHeroTitle` leads the rotation with a title picked by
        // name, so a headless sweep can photograph one particular hero.
        if let wanted = UserDefaults.standard.string(forKey: "OpenStreamHeroTitle"), !wanted.isEmpty,
           let pinned = visibleSections.lazy.compactMap({ section in
               section.items.first { $0.name.localizedCaseInsensitiveContains(wanted) }.flatMap { item in
                   self.sourceStore.sources.first { $0.id == section.sourceID }.map { source in
                       IndexedCatalogItem(record: AppleMediaIngestion.catalogRecord(instanceID: source.id, item: item),
                                          item: item, source: source)
                   }
               }
           }).first {
            values.insert(pinned, at: 0)
        }
        #endif
        return AppleHeroRotation.candidates(values, id: \.record.id,
                                            hasBackdrop: { AppleHeroRotation.hasBackdrop(heroItem($0.item)) })
    }

    /// Most recently watched first, like every other Continue Watching row.
    /// It was sorted by how far through each title was, which put whatever was
    /// closest to finishing at the front — and the billboard follows this
    /// order, so the home screen led with the wrong title too.
    ///
    /// A title no loaded shelf lists any more still shows: it resolves as
    /// Search does, through its merged sources or its IMDb id
    /// (`AppleContinueWatchingResolver`, N52). Only one nothing can open is
    /// left out, and that is logged once — not before the lookup's first
    /// off-main build lands, when it knows no sources and everything fails.
    private var continueWatching: [IndexedCatalogItem] {
        let store = ApplePlaybackStore()
        let ordered = AppleContinueWatchingResolver.inProgress(mediaIndex.records,
            saved: { store.progress(for: $0.id) }) {
            store.progress(for: $0.id)?.updatedAt ?? $0.lastVerified
        }
        let entries = AppleContinueWatchingResolver.entries(ordered, in: [catalogLookup])
        if catalogLookup.hasSources { AppleContinueWatchingResolver.logHidden(entries) }
        return entries
            .compactMap { entry in
                entry.resolution.match.map { IndexedCatalogItem(record: entry.record, item: $0.item, source: $0.source) }
            }
            .prefix(AppleContinueWatchingResolver.maximumCount)
            .map { $0 }
    }

    /// Continue Watching less the titles the viewer removed and has not
    /// played since. Top Picks still reads the full list as viewing history.
    private func withoutRemoved(_ values: [IndexedCatalogItem]) -> [IndexedCatalogItem] {
        _ = continueWatchingRemovalRevision
        let store = ApplePlaybackStore()
        return values.filter { !store.isRemovedFromContinueWatching(mediaID: $0.record.id) }
    }

    private func removeFromContinueWatching(_ value: IndexedCatalogItem) {
        appleTrace("discover.continue.remove id=\(value.record.id)")
        ApplePlaybackStore().removeFromContinueWatching(mediaID: value.record.id)
        continueWatchingRemovalRevision &+= 1
    }

    private func mergedContinueWatching(local: [IndexedCatalogItem]) -> [IndexedCatalogItem] {
        let serverItems = mediaServerLibrary.continueWatching + AppleXtreamLibraryStore.shared.continueWatching
        // Once per pass: `continueWatching` filters the whole media index, and
        // it was being rebuilt again for every merged item below.
        let localItems = local.map { $0.item }
        let mergedItems = AppleMediaServerLibraryStore.mergedContinueWatching(local: localItems, server: serverItems)

        let resolved = mergedItems.compactMap { item -> IndexedCatalogItem? in
            if let existing = local.first(where: { $0.item.mediaID == item.mediaID }) {
                return existing
            }
            if let reference = AppleXtreamReference.parse(item.mediaID),
               let source = AppleXtreamLibraryStore.shared.source(reference) {
                var record = AppleMediaIngestion.catalogRecord(instanceID: source.id, item: item)
                if let progress = ApplePlaybackStore().progress(for: record.id) {
                    record.progress = AppleWatchProgress.fraction(position: progress.position, duration: progress.duration)
                }
                return IndexedCatalogItem(record: record, item: item, source: source)
            }
            guard let ref = AppleMediaServerItemReference.parse(item.mediaID),
                  let source = sourceStore.sources.first(where: { $0.id == ref.sourceID }) else { return nil }
            let record = mediaServerLibrary.continueWatchingRecord(for: item, source: source)
            return IndexedCatalogItem(record: record, item: item, source: source)
        }
        // The merge keys on `mediaID`, the shelf keys on `record.id`: a local
        // record and a server record can agree on the second and differ on the
        // first, and then `ForEach` draws the same card twice. Two cards under
        // one identifier is undefined behaviour for SwiftUI and an ambiguous
        // query for a test — `home.continue.<id>` could not even be asked
        // whether it was hittable (2026-09-19).
        return AppleCatalogShelfPolicy.uniqueByID(resolved)
    }

    private func topPicks(continueWatching: [IndexedCatalogItem]) -> [IndexedCatalogItem] {
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
        // One digest per title. The lookup below used to digest every
        // candidate again for every ranked title — twenty passes over the
        // whole catalog.
        var byDigest: [String: IndexedCatalogItem] = [:]
        let finished = ApplePlaybackStore().completedMediaIDs(among: Array(values.keys))
        let rankable = values.values.map { value in
            let digest = ApplePlaybackIdentity.digest(for: value.item.mediaID)
            if byDigest[digest] == nil { byDigest[digest] = value }
            return AppleRankableTitle(
                id: digest,
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
                    || finished.contains(value.record.id)
            )
        }
        let ranked = AppleRecommendationRanker.rank(rankable, history: history, ratings: ratings, now: .now, limit: 20)
        return ranked.compactMap { byDigest[$0.id] }
    }

    /// A row on the home screen, in the order it is drawn.
    private enum DiscoverRail: Hashable, Identifiable {
        case continueWatching
        case library
        case mediaServer(String)
        case topPicks
        case top10(String)
        case top10StaleNote
        case catalog(String)
        var id: Self { self }

        /// The stable id the Discover Rows setting stores for this rail.
        var rowID: String {
            switch self {
            case .continueWatching: AppleDiscoverRowOrder.continueWatching
            case .library: AppleDiscoverRowOrder.library
            case .mediaServer: AppleDiscoverRowOrder.mediaServers
            case .topPicks: AppleDiscoverRowOrder.topPicks
            case .top10(let type): type == "movie" ? AppleDiscoverRowOrder.top10Movies : AppleDiscoverRowOrder.top10Shows
            case .top10StaleNote: "top10StaleNote"
            case .catalog(let id): AppleDiscoverRowOrder.catalogID(id)
            }
        }
    }

    /// The saved Discover Rows order; review builds can stand in one from
    /// `-OpenStreamDebugDiscoverOrder` without writing settings.
    private var customRowOrder: [String]? {
        #if DEBUG
        if let tokens = UserDefaults.standard.string(forKey: "OpenStreamDebugDiscoverOrder"), !tokens.isEmpty {
            return AppleDiscoverRowOrder.debugOrder(
                tokens, catalogTitles: visibleSections.map { ($0.id, $0.shelfTitle ?? AppleCatalogShelfPolicy.title(for: $0.catalog)) })
        }
        #endif
        return settings.discoverRowOrder
    }

    /// Continue Watching as the shelf shows it. Review builds can stand in an
    /// in-memory fixture (`-OpenStreamDebugContinueWatching YES`) when the
    /// simulator has no progress; it is never written anywhere.
    private func continueWatchingShelf(local: [IndexedCatalogItem]) -> (values: [IndexedCatalogItem], isFixture: Bool) {
        let merged = withoutRemoved(mergedContinueWatching(local: local))
        #if DEBUG
        if merged.isEmpty, AppleContinueWatchingFixture.isEnabled { return (continueWatchingFixture, true) }
        #endif
        return (merged, false)
    }

    private func discoverRails(continueWatching: [IndexedCatalogItem], picks: [IndexedCatalogItem]) -> [DiscoverRail] {
        var rails: [(DiscoverRail, AppleDiscoverRailRhythm.Shape)] = []
        if !continueWatching.isEmpty { rails.append((.continueWatching, .still)) }
        if !library.resolvedGroups.isEmpty { rails.append((.library, .poster)) }
        rails += mediaServerLibrary.shelves.map { (.mediaServer($0.id), .poster) }
        if !picks.isEmpty { rails.append((.topPicks, .still)) }
        if settings.top10ListsEnabled {
            if !(top10Week?.films ?? []).isEmpty { rails.append((.top10("movie"), .still)) }
            if !(top10Week?.tv ?? []).isEmpty { rails.append((.top10("series"), .still)) }
        }
        for section in visibleSections where sourceStore.sources.contains(where: { $0.id == section.sourceID }) {
            let isRanked = AppleCatalogShelfPolicy.style(for: section.catalog) == .ranked
            rails.append((.catalog(section.id), isRanked ? .still : .poster))
        }
        var ordered: [DiscoverRail]
        if let custom = customRowOrder {
            // The viewer's order wins over the A4 rhythm. Media-server
            // shelves share one id and move together, in their own order.
            let ids = rails.map { $0.0.rowID }
            var unique: [String] = []
            for id in ids where !unique.contains(id) { unique.append(id) }
            ordered = AppleDiscoverRowOrder.resolve(available: unique, custom: custom).flatMap { id in
                rails.map(\.0).filter { $0.rowID == id }
            }
        } else {
            ordered = discoverRowStyle != nil
                ? AppleDiscoverRailRhythm.order(rails.map(\.1)).map { rails[$0].0 }
                : rails.map(\.0)
        }
        if settings.top10ListsEnabled, top10Week?.isStale == true {
            let lastTop10 = ordered.lastIndex { if case .top10 = $0 { true } else { false } }
            ordered.insert(.top10StaleNote, at: lastTop10.map { $0 + 1 } ?? ordered.count)
        }
        return ordered
    }

    @ViewBuilder
    private func railView(_ rail: DiscoverRail, continueWatching: (values: [IndexedCatalogItem], isFixture: Bool),
                          picks: [IndexedCatalogItem]) -> some View {
        switch rail {
        case .continueWatching:
            if discoverRowStyle != nil {
                continueWatchingRowShelf(continueWatching.values, isFixture: continueWatching.isFixture)
            } else {
                indexedShelf(title: "Continue Watching", identifier: "continue", values: continueWatching.values,
                             showsProgress: true)
            }
        case .library:
            AppleLocalTitleShelf(title: "Your Library", groups: library.resolvedGroups,
                sourceStore: sourceStore, mediaIndex: mediaIndex, settings: settings, openSettings: openSettings,
                tabToolbar: tabToolbarContext, opensFullList: false)
                .accessibilityIdentifier("home.your-library")
        case .mediaServer(let id):
            if let shelf = mediaServerLibrary.shelves.first(where: { $0.id == id }) {
                AppleMediaShelf(title: shelf.title) {
                    ForEach(shelf.items, id: \.mediaID) { item in
                        if let ref = AppleMediaServerItemReference.parse(item.mediaID),
                           let source = sourceStore.sources.first(where: { $0.id == ref.sourceID }) {
                            let record = AppleMediaIngestion.catalogRecord(instanceID: source.id, item: item)
                            let value = IndexedCatalogItem(record: record, item: item, source: source)
                            NavigationLink { detail(value) } label: {
                                AppleCatalogCard(item: item)
                            }
                            .accessibilityIdentifier("home.ms.\(shelf.id).\(item.mediaID)")
                        }
                    }
                }
            }
        case .topPicks:
            indexedShelf(title: "Top Picks for You", identifier: "top-picks", values: picks, showsProgress: false)
        case .top10(let type):
            if type == "movie" {
                top10Shelf(title: "Top 10 Movies in the US", entries: top10Week?.films ?? [], type: "movie")
            } else {
                top10Shelf(title: "Top 10 Shows in the US", entries: top10Week?.tv ?? [], type: "series")
            }
        case .top10StaleNote:
            Text("Top 10 lists are stale because the latest update could not be downloaded.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
        case .catalog(let id):
            if let section = visibleSections.first(where: { $0.id == id }),
               let source = sourceStore.sources.first(where: { $0.id == section.sourceID }) {
                catalogSection(section, source: source)
            }
        }
    }

    /// A2 on the iPhone and the Mac: stills with the time left, the accent
    /// bar, and a caption row carrying a ⋯ menu.
    private func continueWatchingRowShelf(_ values: [IndexedCatalogItem], isFixture: Bool) -> some View {
        let store = ApplePlaybackStore()
        return AppleMediaShelf(title: "Continue Watching") {
            ForEach(Array(values.enumerated()), id: \.element.id) { index, value in
                AppleContinueWatchingTile(
                    item: value.item,
                    info: continueWatchingInfo(value, index: index, isFixture: isFixture, store: store),
                    isInList: mediaIndex.record(id: value.record.id)?.isFavorite ?? false,
                    onOpenTitle: { selectHero(value, autoPlay: false) },
                    onToggleList: { toggleHeroInList(value) },
                    onRemove: { removeFromContinueWatching(value) }
                ) {
                    detail(value)
                }
                #if DEBUG
                .environment(\.appleDebugTileHover, AppleRailHoverFixture.isEnabled && index == 1)
                #endif
                .accessibilityIdentifier("home.continue.\(value.id)")
            }
        }
    }

    private func continueWatchingInfo(_ value: IndexedCatalogItem, index: Int, isFixture: Bool,
                                      store: ApplePlaybackStore) -> AppleContinueWatchingTileInfo {
        #if DEBUG
        if isFixture { return AppleContinueWatchingFixture.info(index: index, type: value.item.type) }
        #endif
        let key = AppleTitleProgressIdentity.key(
            among: AppleTitleProgressIdentity.candidates(item: value.item, sourceID: value.source.id),
            progress: { store.progress(for: $0) }) ?? value.record.id
        return .live(type: value.item.type, recordID: key, recordProgress: value.record.progress, store: store)
    }

    #if DEBUG
    /// Real catalogue titles with backdrops standing in as Continue Watching.
    private var continueWatchingFixture: [IndexedCatalogItem] {
        var values: [IndexedCatalogItem] = []
        for section in visibleSections {
            guard let source = sourceStore.sources.first(where: { $0.id == section.sourceID }) else { continue }
            for item in section.items where item.backgroundURL != nil
                && !values.contains(where: { $0.item.mediaID == item.mediaID }) {
                let record = AppleMediaIngestion.catalogRecord(instanceID: source.id, item: item)
                values.append(IndexedCatalogItem(record: record, item: item, source: source))
                if values.count == AppleContinueWatchingFixture.count { return values }
            }
        }
        return values
    }
    #endif

    private func loadTop10() {
        #if DEBUG
        if AppleTop10Fixture.isEnabled { return }
        #endif
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
            // Ranked shelves retain the standard row spacing and focus treatment.
            AppleMediaShelf(title: title) {
                ForEach(ordered, id: \.rank) { entry in
                    Group {
                        let match = catalogLookup.match(title: entry.title, type: type, seasonTitle: entry.seasonTitle, ignoringLeadingArticle: true)
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

    /// `section` as the store holds it now (more pages may have landed),
    /// keeping the heading Discover gave it.
    private func liveSection(_ section: AppleCatalogSection) -> AppleCatalogSection {
        guard var live = catalogStore.sections.first(where: { $0.id == section.id }) else { return section }
        live.shelfTitle = section.shelfTitle
        return live
    }

    private func catalogSection(_ section: AppleCatalogSection, source: AppleSource) -> AppleCatalogSectionView {
        AppleCatalogSectionView(
            section: section,
            source: source,
            viewportWidth: viewportSize.width,
            relatedItems: catalogLookup.relatedItems(for: source.id),
            mediaIndex: mediaIndex,
            playbackSources: sourceStore.sources,
            metadataConfiguration: metadataConfiguration,
            gatewayConfig: gatewayConfig,
            playbackResolver: playbackResolver,
            settings: settings,
            openSettings: openSettings,
            tabToolbar: tabToolbarContext,
            onOpen: { selectedCatalog = section; showsCatalog = true },
            onReachEnd: { [catalogStore, sourceStore] in
                Task { await catalogStore.loadNextPage(sectionID: section.id, sources: sourceStore.sources) }
            }
        )
    }

    /// Not `@ViewBuilder`: it returns one view, and the `let` below needs an
    /// explicit `return`, which would switch the builder off anyway.
    private func featuredHero(
        _ value: IndexedCatalogItem, rotationCount: Int = 0, rotationIndex: Int = 0, wordmarkFailed: Bool = false,
        phone: Bool = false, mac: Bool = false, pad: Bool = false, tv: AppleHomeTVHeroContext? = nil
    ) -> some View {
        let item = heroItem(value.item)
        return AppleHomeBillboard(
            item: item,
            sources: sourceStore.sources,
            progressID: value.record.id,
            preferredSourceID: value.source.id,
            onPlay: { selectHero(value, autoPlay: true) },
            onOpenDetails: { selectHero(value, autoPlay: false) },
            settings: settings,
            viewportSize: viewportSize,
            wordmark: wordmarkFailed ? nil : heroWordmark(value, item: item),
            wordmarkLookupPending: AppleHeroTitlePolicy.wordmarkLookupPending(
                mediaID: value.item.mediaID, resolved: heroWordmarksResolved, wordmarkFailed: wordmarkFailed
            ),
            rotationCount: rotationCount,
            rotationIndex: rotationIndex,
            phone: phone ? .init(artHeight: phoneHeroLayout.artHeight,
                                 copyFadeLine: phoneHeroLayout.topInset) : nil,
            mac: mac || pad ? .init(layout: pad ? padHeroLayout : macHeroLayout) : nil,
            tv: tv.map { .init(cycle: $0.cycle) }
        ) { button, perform in
            AppleHomeHeroActions(mode: phone ? .phone : pad ? .pad : mac ? .mac : tv != nil ? .tv : .rotating,
                viewportSize: viewportSize, button: button,
                isInList: mediaIndex.record(id: value.record.id)?.isFavorite ?? false, tv: tv,
                onPlay: perform, onToggleList: { toggleHeroInList(value) },
                onDetails: { selectHero(value, autoPlay: false) })
        }
    }

    /// The iPhone hero's My List button: the same favourite the title page's
    /// My List toggles. A title first seen on the hero has no record yet — the
    /// title page writes one when it opens — so it is written here first.
    private func toggleHeroInList(_ value: IndexedCatalogItem) {
        let isInList = mediaIndex.record(id: value.record.id)?.isFavorite ?? false
        Task { @MainActor in
            if mediaIndex.record(id: value.record.id) == nil { try? await mediaIndex.upsert(value.record) }
            try? await mediaIndex.setFavorite(!isInList, recordID: value.record.id)
        }
    }

    /// The Apple TV app row style for Discover's rails: the iPhone held upright
    /// and the Mac. The iPad, a phone on its side, Apple TV and Vision Pro keep
    /// their own rows.
    private var discoverRowStyle: AppleDiscoverRowStyle? {
        AppleHomePresentationPolicy.rows(hero: heroPresentation,
            width: macHeroLayout.contentWidth, inset: macHeroLayout.horizontalPadding)
    }

    /// Discover's hero on an iPad, either way up (N20): the Mac's full-bleed
    /// hero. The accessibility text sizes keep the featured hero, which
    /// moves the copy under a shorter still instead of over it.
    private var usesPadHero: Bool {
        heroPresentation == .pad
    }

    /// Discover's hero on an iPhone held upright. The iPad has its own; a
    /// phone on its side and every other platform keep the featured hero.
    private var usesPhoneHero: Bool {
        heroPresentation == .phone
    }

    private var heroPresentation: AppleHomePresentationPolicy.Hero {
        AppleHomeHeroCarousel<EmptyView>.presentation(viewport: viewportSize,
            compact: horizontalSizeClass == .compact, accessibility: dynamicTypeSize.isAccessibilitySize)
    }

    private func heroWordmark(_ value: IndexedCatalogItem, item: AppleCatalogItem) -> URL? {
        heroWordmarks[value.item.mediaID] ?? item.logoURL
    }

    /// The hero's own record, with any textless art that has since arrived.
    /// `id` is unchanged by the swap, so the billboard keeps its identity and
    /// tvOS keeps its focus.
    private func heroItem(_ item: AppleCatalogItem) -> AppleCatalogItem {
        guard let upgrade = heroArtwork[item.mediaID] else { return item }
        return item.withHeroArtwork(backgroundURL: upgrade.backdropURL, logoURL: upgrade.logoURL)
    }

    /// Asks TMDB for a backdrop with no title burned into it, for the five
    /// titles the billboard rotates through.
    ///
    /// This runs after the wordmark passes, so the art on screen is already
    /// the art the catalog gave us; a textless backdrop replaces it only if
    /// one exists. `AppleHeroArtworkUpgrade` answers from the metadata disk
    /// cache once a title has been seen, so later launches draw the right art
    /// straight away.
    private func upgradeHeroArtwork(_ heroes: [IndexedCatalogItem]) async {
        guard let configuration = metadataConfiguration else { return }
        for hero in heroes {
            guard heroArtwork[hero.item.mediaID] == nil,
                  let imdbID = AppleHeroArtworkUpgrade.upgradeableIMDBID(for: hero.item) else { continue }
            let upgrade = await AppleHeroArtworkUpgrade.shared.artwork(
                imdbID: imdbID,
                kind: hero.item.type == "series" ? .series : .movie,
                configuration: configuration
            )
            guard !Task.isCancelled else { return }
            heroArtwork[hero.item.mediaID] = upgrade
        }
    }

    /// Reads whatever is already cached for the heroes. Cache only — never a
    /// fetch — so the first draw cannot be made slower by looking for a logo.
    /// A hero the cache has answered is resolved; the rest are returned, in
    /// page order, for `fetchHeroWordmarks`.
    private func resolveHeroWordmarks(_ heroes: [IndexedCatalogItem]) async -> [IndexedCatalogItem] {
        var found: [String: URL] = [:]
        var answered: Set<String> = []
        var unanswered: [IndexedCatalogItem] = []
        for hero in heroes {
            let key = AppleStremioPreviewAssetsCache.key(
                type: hero.item.type, mediaID: hero.item.mediaID
            )
            guard let entry = await AppleStremioPreviewAssetsCache.shared.entry(for: key) else {
                unanswered.append(hero)
                continue
            }
            answered.insert(hero.item.mediaID)
            if let logo = entry.assets?.logoURL {
                found[hero.item.mediaID] = logo
            }
        }
        guard !Task.isCancelled else { return [] }
        let merged = heroWordmarks.merging(found) { _, new in new }
        if merged != heroWordmarks { heroWordmarks = merged }
        heroWordmarksResolved.formUnion(answered)
        return unanswered
    }

    /// Asks the add-ons for the preview assets of the heroes the cache could
    /// not answer, in page order and at most
    /// `AppleMetadataPrefetcher.maximumConcurrent` at a time, and draws each
    /// wordmark as it arrives. This is also what warms the cache for the
    /// title pages the heroes open. Returns the heroes no add-on could be
    /// reached for, so they can be asked again.
    ///
    /// A page already showing its name keeps it
    /// (`AppleHeroTitlePolicy`, N62/N63: the title never swaps under the
    /// viewer); the found mark is drawn the next time that page comes round.
    private func fetchHeroWordmarks(_ heroes: [IndexedCatalogItem]) async -> [IndexedCatalogItem] {
        let requests = heroes.map {
            HeroWordmarkRequest(mediaID: $0.item.mediaID, type: $0.item.type, title: $0.item.name,
                                preferredSourceID: $0.source.id)
        }
        guard !requests.isEmpty else { return [] }
        let sources = sourceStore.sources
        var unanswered: Set<String> = []
        await withTaskGroup(of: HeroWordmarkAnswer.self) { group in
            var next = 0
            var inFlight = 0
            while true {
                // At most `maximumConcurrent` asks at a time: add-ons are
                // someone else's server.
                while inFlight < AppleMetadataPrefetcher.maximumConcurrent, next < requests.count {
                    let request = requests[next]
                    next += 1
                    inFlight += 1
                    group.addTask { await Self.askHeroWordmark(request, sources: sources) }
                }
                guard let answer = await group.next() else { break }
                inFlight -= 1
                if Task.isCancelled {
                    group.cancelAll()
                    return
                }
                AppleInteractionTrace.record(.network, AppleHeroWordmarkFetch.traceLine(
                    title: answer.request.title, outcome: answer.outcome, milliseconds: answer.milliseconds
                ))
                switch answer.outcome {
                case .found(let logo):
                    heroWordmarks[answer.request.mediaID] = logo
                case .none:
                    break
                case .transient:
                    unanswered.insert(answer.request.mediaID)
                }
                // The lookup has finished either way: a page with no mark
                // stops holding its slot and draws the name.
                heroWordmarksResolved.insert(answer.request.mediaID)
            }
        }
        guard !Task.isCancelled else { return [] }
        return heroes.filter { unanswered.contains($0.item.mediaID) }
    }

    private struct HeroWordmarkRequest: Sendable {
        let mediaID: String
        let type: String
        let title: String
        let preferredSourceID: AppleSource.ID
    }

    private struct HeroWordmarkAnswer: Sendable {
        let request: HeroWordmarkRequest
        let outcome: AppleHeroWordmarkFetch.Outcome
        let milliseconds: Int
    }

    /// One hero's ask, off the main actor. `previewAssets` caches every
    /// answer, so an empty cache afterwards means no add-on was reached.
    private nonisolated static func askHeroWordmark(
        _ request: HeroWordmarkRequest, sources: [AppleSource]
    ) async -> HeroWordmarkAnswer {
        let clock = ContinuousClock()
        let start = clock.now
        let assets = await AppleStremioMetadataClient().previewAssets(
            sources: sources, preferredSourceID: request.preferredSourceID,
            type: request.type, mediaID: request.mediaID
        )
        let key = AppleStremioPreviewAssetsCache.key(type: request.type, mediaID: request.mediaID)
        let answered = await AppleStremioPreviewAssetsCache.shared.entry(for: key) != nil
        let elapsed = (clock.now - start).components
        let milliseconds = Int(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000)
        return HeroWordmarkAnswer(
            request: request,
            outcome: AppleHeroWordmarkFetch.outcome(assets: assets, answered: answered),
            milliseconds: milliseconds
        )
    }

    #if DEBUG
    private var visionReviewItem: IndexedCatalogItem? {
        // "detail-movie" is "detail" for the first film instead of the first
        // series, so a sweep can photograph both kinds of title page.
        // `OpenStreamDetailTitle` picks a title by name, so before and after
        // shots can photograph the same page.
        // `OpenStreamDebugPlayID tt… -OpenStreamDebugPlayType movie|series`:
        // any title by its IMDb id, opened as a Discover add-on title is, so
        // a playback sweep can reach titles no Discover row lists.
        if let playID = UserDefaults.standard.string(forKey: "OpenStreamDebugPlayID"),
           ApplePlayGatingPolicy.canonicalMediaID(playID) != nil,
           let section = visibleSections.first,
           let source = sourceStore.sources.first(where: { $0.id == section.sourceID }) {
            let item = AppleCatalogItem(
                mediaID: playID,
                type: UserDefaults.standard.string(forKey: "OpenStreamDebugPlayType") ?? "movie",
                name: UserDefaults.standard.string(forKey: "OpenStreamDebugPlayName") ?? playID
            )
            return IndexedCatalogItem(record: AppleMediaIngestion.catalogRecord(instanceID: source.id, item: item), item: item, source: source)
        }
        let type = UserDefaults.standard.string(forKey: "OpenStreamVisionScreen") == "detail-movie" ? "movie" : "series"
        let wanted = UserDefaults.standard.string(forKey: "OpenStreamDetailTitle") ?? ""
        let sections = visibleSections.filter { $0.catalog.type == type }
        let named = wanted.isEmpty ? nil : sections.lazy.compactMap { section in
            section.items.first { $0.name.localizedCaseInsensitiveContains(wanted) }.map { (section, $0) }
        }.first
        guard let pick = named ?? sections.first.flatMap({ section in section.items.first.map { (section, $0) } }),
              let source = sourceStore.sources.first(where: { $0.id == pick.0.sourceID }) else { return nil }
        let item = pick.1
        return IndexedCatalogItem(record: AppleMediaIngestion.catalogRecord(instanceID: source.id, item: item), item: item, source: source)
    }
    #endif

    private func selectHero(_ value: IndexedCatalogItem, autoPlay: Bool) {
        // Capture the tapped title outside the rotating hero. Timeline ticks
        // must never replace the item in an already presented detail page.
        selectedHero = value
        selectedHeroAutoPlay = autoPlay
        showsSelectedHero = true
    }

    @ViewBuilder
    private func indexedShelf(
        title: String,
        identifier: String,
        values: [IndexedCatalogItem],
        showsProgress: Bool
    ) -> some View {
        let store = ApplePlaybackStore()
        AppleMediaShelf(title: title) {
            ForEach(values) { value in
                NavigationLink { detail(value) } label: {
                    AppleCatalogCard(
                        item: value.item,
                        sizing: showsProgress ? .continueWatching : .featured,
                        progress: showsProgress ? (AppleContinueWatchingResolver.progress(
                            isSeries: value.item.type == "series", saved: store.progress(for: value.item.mediaID) ?? store.progress(for: value.record.id),
                            recordProgress: value.record.progress) ?? 0) : nil)
                }
                .contextMenu {
                    if showsProgress {
                        Button("Remove from Continue Watching", systemImage: "xmark.circle") {
                            removeFromContinueWatching(value)
                        }
                    }
                }
                .accessibilityIdentifier("home.\(identifier).\(value.id)")
            }
        }
    }

    private func detail(_ value: IndexedCatalogItem, initialAutoPlay: Bool = false) -> some View {
        // Built when pushed, not with every link (`AppleLazyDestination`).
        AppleLazyDestination {
            AppleCatalogItemDetailView(
                item: value.item,
                source: value.source,
                relatedItems: catalogLookup.relatedItems(for: value.source.id),
                mediaIndex: mediaIndex,
                playbackSources: sourceStore.sources,
                metadataConfiguration: metadataConfiguration,
                gatewayConfig: gatewayConfig,
                playbackResolver: playbackResolver,
                settings: settings,
                openSettings: openSettings,
                initialAutoPlay: initialAutoPlay,
                mediaServerLibrary: mediaServerLibrary,
                tabToolbar: tabToolbarContext
            )
            .environment(\.appleDiscoverRows, nil)
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
        #if DEBUG
        // Only once the lookup exists, so every fixture rank matches a
        // catalogue title and nothing falls back to a network search.
        if AppleTop10Fixture.isEnabled { top10Week = AppleTop10Fixture.week(sections: catalogStore.sections) }
        #endif
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
        32
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

    private var metadataConfiguration: AppleTMDBConfiguration? { settings.tmdbConfiguration }

    /// Discover's Search and Refresh, for the pages pushed from here.
    private var tabToolbarContext: AppleTabToolbarContext {
        AppleTabToolbarContext(tab: .home, isRefreshing: { isRefreshing || catalogStore.isLoading },
                               onSearch: openSearchFromPushedPage, onRefresh: refresh)
    }

    /// Search from a pushed page. A title page opened from a search result
    /// sits above Search, where `showsSearch` is already true and setting it
    /// again did nothing (UX tour 2026-10-08: a dead magnifier). That stack
    /// drops back to Discover without animation and a fresh Search is pushed.
    private func openSearchFromPushedPage() {
        guard showsSearch else { showsSearch = true; return }
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { showsSearch = false }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            showsSearch = true
        }
    }

    private var catalogIsStillLoading: Bool {
        AppleDiscoverEmptyState.isStillLoading(
            sourceCount: sourceStore.sources.count,
            isLoading: catalogStore.isLoading,
            hasSettled: settledCatalogIdentity == catalogConfigurationIdentity(sourceStore.sources)
        )
    }

    /// No Sources, a catalog that couldn't be read (Try Again, then
    /// Settings), or sources with nothing in them.
    @ViewBuilder
    private var discoverEmptyState: some View {
        let state = AppleDiscoverEmptyState(
            sources: sourceStore.sources,
            catalogFailureCount: catalogStore.partialErrors.count,
            hasSourceError: sourceStore.credentialError != nil
        )
        if state.offersRetry {
            AppleSourceEmptyState(
                title: state.title,
                systemImage: OpenStreamTab.home.systemImage,
                actionTitle: "Try Again",
                action: refresh,
                secondaryActionTitle: "Open Settings",
                secondaryAction: openSettings
            )
        } else {
            #if os(tvOS)
            if state == .noSources {
                // Apple TV can't import a file: its setup comes from iCloud or from an iPhone over the LAN.
                AppleSourceEmptyState(
                    title: state.title,
                    systemImage: OpenStreamTab.home.systemImage,
                    actionTitle: AppleSetupTransferDevice.receiveTitle,
                    action: { AppleSetupTransferCenter.shared.presentReceiver() },
                    secondaryActionTitle: "Open Settings",
                    secondaryAction: openSettings,
                    footnote: state.footnote
                )
            } else {
                openSettingsEmptyState(state)
            }
            #else
            // No Sources with Backup & Sync at hand: restore or import first.
            if state == .noSources, let backupController {
                AppleDiscoverRestoreEmptyState(
                    title: state.title, footnote: state.footnote, controller: backupController,
                    offersICloud: state.offersICloudRestore(AppleICloudSyncProbe.current()),
                    openSettings: openSettings)
            } else {
                openSettingsEmptyState(state)
            }
            #endif
        }
    }

    private func openSettingsEmptyState(_ state: AppleDiscoverEmptyState) -> some View {
        AppleSourceEmptyState(
            title: state.title,
            systemImage: OpenStreamTab.home.systemImage,
            actionTitle: "Open Settings",
            action: openSettings,
            footnote: state.footnote
        )
    }

    private func refresh() {
        Task { await refreshContent() }
    }

    private func refreshContent() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        let started = ContinuousClock.now
        defer { isRefreshing = false }
        await catalogStore.refresh(sources: sourceStore.sources, force: true)
        await mediaServerLibrary.reload(sources: sourceStore.sources) { try sourceStore.mediaServerSession(for: $0) }
        applyCatalogRefreshHealth(reports: catalogStore.sourceRefreshReports, to: sourceStore)
        await indexCatalogs()
        try? await Task.sleep(for: AppleProgressVisibility.remaining(since: started))
    }

    private func indexCatalogs() async {
        for source in sourceStore.sources where source.isAddon && source.isEnabled {
            let records = catalogStore.sections
                .filter { $0.sourceID == source.id }
                .flatMap { AppleMediaIngestion.catalogRecords(section: $0) }
            try? await mediaIndex.replaceCatalog(instanceID: source.id, with: records)
        }
    }
}

@MainActor
struct AppleSearchView: View {
    @Environment(\.appleTabToolbar) private var tabToolbar
    @State private var query = ""
    @State private var sharedLinkError = ""
    @State private var showsSharedLinkError = false
    @State private var sharedLinkLoading = false
    @State private var sharedLinkGeneration = 0
    @State private var sharedPlayer: AppleStremioPlayerPresentation?
    @State private var pendingSharedPlayer: AppleStremioPlayerPresentation?
    #if os(iOS)
    @Environment(\.scenePhase) private var scenePhase
    @State private var hasCopiedURL = false
    #endif
    @State private var searchStore = AppleCatalogSearchStore()
    @State private var routedResult: RoutedResult?
    @State private var deliveredRouteRevision: Int?
    @State private var catalogLookup = AppleCatalogSearchLookup()
    @State private var recentSearches = AppleRecentSearchStore()
    #if DEBUG
    @State private var debugOpenedFirstResult = false
    #endif

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
            if sharedLinkLoading {
                ProgressView()
            } else if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
                } else if !recentSearches.recents.isEmpty {
                    recentSearchesList
                } else {
                    ContentUnavailableView("Search Your Sources", systemImage: "magnifyingglass")
                }
            } else if listedResults.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                List(listedResults) { record in
                    if let result = searchMatch(for: record) {
                        NavigationLink {
                            AppleCatalogItemDetailView(
                                item: result.item,
                                source: result.source,
                                relatedItems: relatedItems(for: result.source.id),
                                mediaIndex: mediaIndex,
                                playbackSources: sourceStore.sources,
                                metadataConfiguration: metadataConfiguration,
                                gatewayConfig: gatewayConfig,
                                playbackResolver: playbackResolver,
                                settings: settings,
                                openSettings: openSettings,
                                tabToolbar: tabToolbar
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
        // Always-visible field: with Refresh in the toolbar, iPadOS folds the
        // default placement into a second magnifier, so the Search button
        // opened a page with nothing to type into (N35 regression sweep).
        #if os(iOS)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search movies, shows, and channels")
        #else
        .searchable(text: $query, prompt: "Search movies, shows, and channels")
        #endif
        .onSubmit(of: .search) {
            if AppleSharedLinkResolver.link(in: query) == nil { recentSearches.record(query) }
        }
        .alert(sharedLinkError, isPresented: $showsSharedLinkError) { }
        .confirmationDialog("Play YouTube Video", isPresented: Binding(
            get: { pendingSharedPlayer != nil },
            set: { if !$0 { pendingSharedPlayer = nil } }
        ), titleVisibility: .visible, presenting: pendingSharedPlayer) { presentation in
            Button("Play", systemImage: "play.fill") {
                sharedPlayer = presentation
                pendingSharedPlayer = nil
            }
            Button("Cancel", role: .cancel) { pendingSharedPlayer = nil }
        }
        .modifier(AppleMediaPlayerPresentationModifier(presentation: $sharedPlayer))
        #if os(iOS)
        .safeAreaInset(edge: .bottom) {
            if hasCopiedURL {
                AppleCopiedLinkButton(query: $query)
            }
        }
        .task { await detectCopiedURL() }
        .onChange(of: scenePhase) {
            if scenePhase == .active { Task { await detectCopiedURL() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in
            Task { await detectCopiedURL() }
        }
        #endif
        .navigationDestination(item: $routedResult) { value in
            AppleCatalogItemDetailView(
                item: value.item,
                source: value.source,
                relatedItems: catalogLookup.relatedItems(for: value.source.id),
                mediaIndex: mediaIndex,
                playbackSources: sourceStore.sources,
                metadataConfiguration: metadataConfiguration,
                gatewayConfig: gatewayConfig,
                playbackResolver: playbackResolver,
                settings: settings,
                openSettings: openSettings,
                initialAutoPlay: value.action == .play,
                tabToolbar: tabToolbar
            )
            .task(id: router.revision) {
                // Search's task sleeps while this title covers it. The visible page
                // closes itself for a newer shared link, then Search resolves that route.
                if router.revision != value.revision, case .sharedLink = router.route {
                    routedResult = nil
                }
            }
        }
        .task(id: router.searchQuery) {
            if !router.searchQuery.isEmpty { query = router.searchQuery }
        }
        .onChange(of: router.revision) {
            pendingSharedPlayer = nil
            if case .sharedLink = router.route {
                routedResult = nil
                sharedPlayer = nil
            }
        }
        .task(id: router.revision) {
            let revision = router.revision
            if case .sharedLink(let link) = router.route {
                guard deliveredRouteRevision != revision else { return }
                routedResult = nil
                await openSharedLink(link, revision: revision)
                return
            }
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
        .task(id: query + ":" + String(AppleXtreamLibraryStore.shared.revision)) {
            pendingSharedPlayer = nil
            sharedLinkGeneration &+= 1
            let revision = router.revision
            if let link = AppleSharedLinkResolver.link(in: query) {
                await openSharedLink(link, revision: revision)
                return
            }
            await searchStore.search(
                query: query,
                sources: sourceStore.sources,
                baseSections: catalogStore.sections
            ) { value in
                await mediaIndex.search(value) + AppleXtreamLibraryStore.shared.search(value)
            }
            deliverMediaRoute(revision: revision)
            // A query that stayed put and found something is a search worth
            // remembering; the keystrokes on the way to it are not (tvOS has
            // no submit, so this is the only path there).
            guard !listedResults.isEmpty else { return }
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            recentSearches.record(query)
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
        #if DEBUG
        // `-OpenStreamDebugSearchQuery <text>` types a query and opens the
        // first result's title page once, for a headless sweep of Search as
        // an entry point (N53).
        .task(id: listedResults.count) {
            guard let typed = UserDefaults.standard.string(forKey: "OpenStreamDebugSearchQuery"),
                  !typed.isEmpty else { return }
            if query.isEmpty { query = typed; return }
            guard !debugOpenedFirstResult, let record = listedResults.first,
                  let match = searchMatch(for: record) else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            debugOpenedFirstResult = true
            routedResult = RoutedResult(record: record, item: match.item, source: match.source,
                                        action: .display, revision: -1)
        }
        #endif
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
                            await mediaIndex.search(value) + AppleXtreamLibraryStore.shared.search(value)
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

    #if os(iOS)
    private func detectCopiedURL() async {
        hasCopiedURL = await AppleCopiedLinkDetection.detect()
    }
    #endif

    private func openSharedLink(_ link: SharedLink, revision: Int) async {
        appleTrace("shared link parse \(link.provider)")
        pendingSharedPlayer = nil
        sharedLinkGeneration &+= 1
        let generation = sharedLinkGeneration
        sharedLinkLoading = true
        defer { if generation == sharedLinkGeneration { sharedLinkLoading = false } }
        do {
            if case .youtube(let videoID) = link {
                #if OPENSTREAM_ADDONS
                // Only installed sources that advertise a YouTube catalog or identity are eligible.
                let sources = AppleSharedLinkYouTubePolicy.sources(in: sourceStore.sources)
                for source in sources {
                    let item = AppleSharedLinkYouTubePolicy.item(videoID: videoID, source: source)
                    do {
                        let resolved = try await AppleMediaPlaybackResolver().resolve(source: source, item: item, gatewayConfig: gatewayConfig)
                        try Task.checkCancellation()
                        guard revision == router.revision, generation == sharedLinkGeneration else { return }
                        pendingSharedPlayer = AppleStremioPlayerPresentation(request: ApplePlaybackRequest(
                            url: resolved.preparedPlayback.url, headers: resolved.preparedPlayback.requestHeaders,
                            mediaID: item.mediaID, title: item.name, sourceKind: .catalog,
                            hints: .init(addonMediaID: item.mediaID, addonMediaType: item.type)), settings: settings)
                        if case .sharedLink = router.route { deliveredRouteRevision = revision }
                        appleTrace("shared link YouTube playable stream")
                        return
                    } catch is CancellationError { throw CancellationError() }
                    catch { continue }
                }
                #endif
                throw AppleSharedLinkError.unsupportedYouTube
            }
            await mediaIndex.load()
            await catalogStore.loadCachedSections(sources: sourceStore.sources)
            await rebuildCatalogLookup()
            try Task.checkCancellation()
            let resolution = try await AppleSharedLinkResolution.resolve(link, records: mediaIndex.records,
                sources: sourceStore.sources, configuration: metadataConfiguration) { name in
                    await searchStore.search(query: name, sources: sourceStore.sources, baseSections: catalogStore.sections) {
                        await mediaIndex.search($0)
                    }
                    return searchStore.results
                }
            try Task.checkCancellation()
            guard revision == router.revision, generation == sharedLinkGeneration else { return }
            if case .sharedLink = router.route { deliveredRouteRevision = revision }
            if let record = resolution.record, let match = searchMatch(for: record) {
                query = record.title
                routedResult = .init(record: record, item: match.item, source: match.source, action: .display, revision: revision)
                appleTrace("shared link match title page \(record.title)")
            } else if let item = resolution.item {
                let source = sourceStore.sources.first { $0.isEnabled && $0.isAddon }
                    ?? AppleSource(kind: .library, name: "oStream", url: URL(string: "https://fixture.example/shared-link")!)
                let record = AppleMediaRecord(canonicalID: item.mediaID, kind: item.type == "movie" ? .movie : .series,
                                             title: item.name, year: item.year, availability: [])
                query = item.name
                routedResult = .init(record: record, item: item, source: source, action: .display, revision: revision)
                appleTrace("shared link match metadata title page \(item.name)")
            } else if let title = resolution.title {
                query = title.name
                appleTrace("shared link match ambiguous or unavailable → search")
            } else { throw AppleSharedLinkError.unreadable }
        } catch {
            guard !Task.isCancelled, revision == router.revision, generation == sharedLinkGeneration else { return }
            if case .sharedLink = router.route { deliveredRouteRevision = revision }
            sharedLinkError = (error as? AppleSharedLinkError)?.errorDescription ?? "Couldn't read that link"
            showsSharedLinkError = true
            appleTrace("shared link resolution failed \(link.provider)")
        }
    }

    /// The last searches, newest first, while the field is empty: a row
    /// re-runs that search, the last row forgets them all. Plain rows, no
    /// colour (owner rule), the way the TV app lists its recents.
    private var recentSearchesList: some View {
        List {
            Section("Recent Searches") {
                ForEach(recentSearches.recents, id: \.self) { entry in
                    Button(entry) { query = entry }
                        .accessibilityIdentifier("search.recent.row")
                }
                Button("Clear Recent Searches") { recentSearches.clear() }
                    .accessibilityIdentifier("search.recent.clear")
            }
        }
        .scrollIndicators(AppleDesignTokens.scrollIndicatorVisibility)
    }

    private func deliverMediaRoute(revision: Int) {
        guard !Task.isCancelled, revision == router.revision,
              deliveredRouteRevision != revision,
              case .media(let id, let action) = router.route,
              let record = mediaIndex.records.first(where: { $0.id == id }),
              let result = searchMatch(for: record) else { return }
        deliveredRouteRevision = revision
        appleTrace("detail route \"\(result.item.name)\"")
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
                // The same name the row headings show ("AIOMetadata", not
                // "AIOMetadata  | ElfHosted").
                Text(AppleCatalogShelfPolicy.displaySourceName(sourceName)).font(.caption).foregroundStyle(.secondary)
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

    private func searchMatch(for record: AppleMediaRecord) -> AppleCatalogSearchMatch? {
        AppleXtreamLibraryStore.shared.match(record) ?? AppleCatalogSearchLookup.match(for: record, in: [searchStore.lookup, catalogLookup])
    }

    /// Every row either opens its title page or is not a catalog title at all
    /// (a file or a channel); see `AppleCatalogSearchLookup.listsUnmatched`.
    private var listedResults: [AppleMediaRecord] {
        searchStore.results.filter {
            AppleCatalogSearchLookup.listsUnmatched($0) || searchMatch(for: $0) != nil
        }
    }

    private func relatedItems(for sourceID: AppleSource.ID) -> [AppleCatalogItem] {
        let searchItems = searchStore.lookup.relatedItems(for: sourceID)
        return searchItems.isEmpty ? catalogLookup.relatedItems(for: sourceID) : searchItems
    }

    private func indexCatalogs() async {
        for source in sourceStore.sources where source.isAddon && source.isEnabled {
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


    private var metadataConfiguration: AppleTMDBConfiguration? { settings.tmdbConfiguration }
}

private struct AppleCatalogSectionView: View {
    let section: AppleCatalogSection
    let source: AppleSource
    let viewportWidth: CGFloat
    let relatedItems: [AppleCatalogItem]
    let mediaIndex: AppleMediaIndexStore
    let playbackSources: [AppleSource]
    let metadataConfiguration: AppleTMDBConfiguration?
    let gatewayConfig: AppleTranscodeGatewayConfig?
    let playbackResolver: AppleStremioPlaybackResolver
    let settings: AppleSettingsStore
    let openSettings: () -> Void
    /// Discover's Search and Refresh, for the title pages its posters open.
    let tabToolbar: AppleTabToolbarContext?
    let onOpen: () -> Void
    /// Asks for the catalog's next page (`AppleCatalogPaging`); the store
    /// ignores it for a catalog without `skip` or one that has run out.
    var onReachEnd: (() -> Void)? = nil
    @FocusState private var focusedItemID: String?

    private var title: String {
        section.shelfTitle ?? AppleCatalogShelfPolicy.title(for: section.catalog)
    }

    private var displayedItems: [AppleCatalogItem] {
        AppleCatalogShelfPolicy.style(for: section.catalog) == .ranked
            ? Array(section.items.prefix(10)) : section.items
    }

    var body: some View {
        AppleHomeShelf(title: title,
                        headingIdentifier: "discover.shelf.\(source.manifestID ?? source.id.uuidString).\(section.catalog.type).\(section.catalog.id)", onOpen: onOpen) {
            ForEach(Array(displayedItems.enumerated()), id: \.element.id) { index, item in
                NavigationLink {
                    detail(item)
                } label: {
                    if AppleCatalogShelfPolicy.style(for: section.catalog) == .ranked {
                        AppleTop10Card(item: item, rank: index + 1)
                    } else if AppleCatalogShelfPolicy.style(for: section.catalog) == .featured {
                        ApplePortraitPromoCard(item: item, viewportWidth: viewportWidth)
                    } else {
                        AppleCatalogCard(item: item)
                    }
                }
                .focused($focusedItemID, equals: item.id)
                .accessibilityIdentifier("home.media.\(item.id)")
                .onAppear { requestMoreIfNearEnd(item) }
            }
        } destination: { catalogList }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.catalog.\(section.id)")
        #if os(tvOS)
        .defaultFocus($focusedItemID, section.items.first?.id)
        // A poster that keeps focus is the next page the viewer opens, so
        // its details and episodes are fetched while they decide. Moving on
        // cancels the wait, so a swipe across a row costs nothing.
        .task(id: focusedItemID) {
            guard let focusedItemID,
                  let item = section.items.first(where: { $0.id == focusedItemID }),
                  let title = AppleMetadataPrefetcher.detailTarget(type: item.type, mediaID: item.mediaID)
            else { return }
            try? await Task.sleep(for: AppleMetadataPrefetcher.focusDwell)
            guard !Task.isCancelled else { return }
            await AppleMetadataPrefetcher.warmDetail(
                title,
                sources: playbackSources,
                preferredSourceID: source.id,
                configuration: metadataConfiguration
            )
        }
        #endif
    }

    var catalogList: some View {
        List(section.items) { item in
            NavigationLink { detail(item) } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name).font(.headline)
                    let subtitle = AppleCatalogShelfPolicy.rankedSubtitle(for: item)
                    if !subtitle.isEmpty { Text(subtitle).foregroundStyle(.secondary) }
                }
                .frame(minHeight: 44, alignment: .leading)
            }
            .onAppear { requestMoreIfNearEnd(item) }
        }
        .navigationTitle(title)
        .scrollIndicators(.hidden)
        .tint(.primary)
    }

    /// A ranked Top 10 row shows ten and never pages.
    private func requestMoreIfNearEnd(_ item: AppleCatalogItem) {
        guard let onReachEnd, AppleCatalogShelfPolicy.style(for: section.catalog) != .ranked,
              AppleCatalogPaging.isNearEnd(itemID: item.id, in: section.items) else { return }
        onReachEnd()
    }

    private func detail(_ item: AppleCatalogItem) -> some View {
        // Built when pushed, not with every card (`AppleLazyDestination`).
        AppleLazyDestination {
            AppleCatalogItemDetailView(
                item: item,
                source: source,
                relatedItems: relatedItems,
                mediaIndex: mediaIndex,
                playbackSources: playbackSources,
                metadataConfiguration: metadataConfiguration,
                gatewayConfig: gatewayConfig,
                playbackResolver: playbackResolver,
                settings: settings,
                openSettings: openSettings,
                initialAutoPlay: AppleCatalogDiscoveryPolicy.opensStraightToPlayback(item: item, source: source),
                tabToolbar: tabToolbar
            )
            .environment(\.appleDiscoverRows, nil)
        }
    }

}

private struct AppleTop10Card: View {
    let item: AppleCatalogItem
    let rank: Int
    @Environment(\.appleDiscoverRows) private var rowStyle

    private var cardWidth: CGFloat {
        #if os(tvOS)
        480
        #else
        320
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AppleCatalogCard(item: item, sizing: .ranked)
            if rowStyle != nil {
                AppleTop10RowCaption(item: item, rank: rank)
            } else {
                standardCaption
                    .appleTVCardCaptionFocus()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(rank), \(item.accessibilityTitle)")
        .accessibilityValue(AppleCatalogShelfPolicy.rankedSubtitle(for: item))
    }

    private var standardCaption: some View {
        HStack(alignment: .center, spacing: 12) {
            AppleTop10RankNumeral(rank: rank)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                let subtitle = AppleCatalogShelfPolicy.rankedSubtitle(for: item)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.gray)
                        .lineLimit(2)
                }
            }
            // The card is a link label, which centres a two-line title.
            .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .frame(width: cardWidth, alignment: .leading)
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
                // No spinner: it sat against the caption, beside the title,
                // and read as part of the name. The title tile is the
                // placeholder, as on every other card still waiting for art.
                AppleTop10UnresolvedCard(title: entry.title, rank: entry.rank)
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
        AppleTop10Card(
            item: AppleCatalogItem(mediaID: "unresolved-rank-\(rank)", type: "movie", name: title),
            rank: rank
        )
    }
}

extension View {
    @ViewBuilder
    func appleCatalogFocusSection() -> some View {
        #if os(tvOS)
        // One focus treatment for every card on the Apple TV, the Apple TV
        // app's: the artwork lifts, tilts with the remote and catches the
        // light (`appleTVCardArtworkFocus`), never the stock platter behind
        // it (owner 16:20, "still not great") and never a ring.
        focusSection().buttonStyle(.borderless)
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
        self.buttonStyle(.borderless)
        #else
        self.buttonStyle(.plain)
        #endif
    }

    /// The Apple TV app's focus on a card's artwork: in a `.borderless`
    /// button, the art alone lifts with a shadow, tilts with the remote and
    /// catches the light; the name under it stays where it is, so it stays
    /// legible. Other platforms keep their own treatment.
    /// The name under a card's artwork slides clear of the lifted art while
    /// the card is focused (Apple TV only).
    @ViewBuilder
    func appleTVCardCaptionFocus() -> some View {
        #if os(tvOS)
        modifier(AppleTVCardCaptionFocus())
        #else
        self
        #endif
    }

    @ViewBuilder
    func appleTVCardArtworkFocus(cornerRadius: CGFloat) -> some View {
        #if os(tvOS)
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        self.clipShape(shape)
            .contentShape(.hoverEffect, shape)
            .hoverEffect(.highlight)
        #else
        self
        #endif
    }
}

struct AppleCatalogCard: View {
    let item: AppleCatalogItem
    let sizing: AppleCatalogCardSizing
    let viewportWidth: CGFloat?
    let progress: Double?
    /// "57 MIN LEFT" on a Discover Continue Watching still (iPhone, Mac).
    let remainingLabel: String?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.appleTMDBConfiguration) private var metadataConfiguration
    @Environment(\.appleDiscoverRows) private var rowStyle
    @ScaledMetric(relativeTo: .body) private var scaledCardWidth = 140.0
    @State private var fallbackArtwork: AppleArtworkResolver.Artwork?
    @State private var failedArtworkURLs: Set<URL> = []
    @State private var artworkRetries = 0
    /// The loaded art is a logo on a plate (`AppleCatalogArtworkPolicy.plate`).
    @State private var artworkPlate = AppleCatalogArtworkPolicy.Plate.none
    /// How the loaded art sits in the card (`AppleCatalogArtworkPolicy.framing`).
    @State private var artworkFraming = AppleCatalogArtworkPolicy.Framing.fill
    private let discCatalog = AppleDiscCatalog.shared

    init(item: AppleCatalogItem, sizing: AppleCatalogCardSizing = .catalog, viewportWidth: CGFloat? = nil,
         progress: Double? = nil, remainingLabel: String? = nil) {
        self.item = item
        self.sizing = sizing
        self.viewportWidth = viewportWidth
        self.progress = progress
        self.remainingLabel = remainingLabel
    }

    /// The Discover row style (iPhone, Mac) applies to the home rails only,
    /// never to a detail page's suggestions or the full-width promo card.
    private var activeRowStyle: AppleDiscoverRowStyle? {
        [.catalog, .featured, .continueWatching, .ranked].contains(sizing) ? rowStyle : nil
    }

    private var usesRowStyle: Bool { activeRowStyle != nil }

    private var resolvedPosterURL: URL? {
        AppleCatalogArtworkPolicy.next(
            in: AppleCatalogArtworkPolicy.candidates(item: item, landscape: isLandscapeCard, fallback: fallbackArtwork),
            failed: failedArtworkURLs
        )
    }

    /// A card never renders as an empty slot: when the artwork is missing or
    /// fails, the tile carries the title instead (FEEDBACK X7), set as a
    /// title card — bold white type, not a grey box with grey text (N49 #20).
    private var artworkPlaceholder: some View {
        ZStack {
            Color(white: 0.12)
            Text(item.name)
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .minimumScaleFactor(0.6)
                .padding(12)
        }
    }

    /// The backdrop a logo-on-a-plate poster is drawn over.
    private var plateBackdropURL: URL? {
        guard artworkPlate != .none, !isLandscapeCard else { return nil }
        return AppleCatalogArtworkPolicy.plateBackdrop(item: item, fallback: fallbackArtwork, showing: resolvedPosterURL)
    }

    /// "2013–2018" under the title; none on a card that shows progress.
    private var captionYear: String? {
        guard progress == nil, let releaseInfo = item.releaseInfo else { return nil }
        let year = AppleReleaseYearText.display(releaseInfo)
        return year.isEmpty ? nil : year
    }

    /// Title and year, left-aligned: the card is a link label, and a link
    /// label centres a two-line title.
    private func captionLines(reservingTitleLines: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.name)
                .font(.caption)
                .lineLimit(2, reservesSpace: reservingTitleLines)
                .truncationMode(.tail)
            if let captionYear {
                Text(captionYear)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
            }
        }
        .multilineTextAlignment(.leading)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AppleCatalogArtwork(url: resolvedPosterURL, contentMode: posterAspect == nil ? .fill : .fit,
                                onFailure: artworkDidFail, onImageLoad: { image in
                artworkPlate = AppleCatalogArtworkPolicy.plate(of: image)
                artworkFraming = AppleCatalogArtworkPolicy.framing(
                    landscapeCard: isLandscapeCard, imageWidth: image.width, imageHeight: image.height)
            })
                // A portrait poster in a 16:9 card is drawn whole, centred.
                .frame(width: posterAspect.map { cardHeight * $0 } ?? cardWidth, height: cardHeight)
                // A black plate lets the tile through where it is black; the
                // logo itself is brighter than the tile and draws unchanged.
                .blendMode(artworkPlate == .black && posterAspect == nil ? .lighten : .normal)
                .frame(width: cardWidth, height: cardHeight)
                .background {
                    if posterAspect != nil {
                        // The poster's own colours, blurred, extend it to the
                        // card's edges: no dark bands, no scrim.
                        AppleCatalogArtwork(url: resolvedPosterURL)
                            .frame(width: cardWidth, height: cardHeight)
                            .blur(radius: 24, opaque: true)
                            .clipped()
                            .accessibilityHidden(true)
                    } else if artworkPlate != .none {
                        ZStack {
                            Color(white: 0.12)
                            if let plateBackdropURL {
                                AppleCatalogArtwork(url: plateBackdropURL)
                                    .frame(width: cardWidth, height: cardHeight)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                }
                // A Top 10 tile has no caption over its art, so while the art
                // is in flight (or a load stalls) the title tile sits behind
                // it rather than an empty dark box (Wonka's, 2026-10-01).
                .background { if sizing == .ranked, resolvedPosterURL != nil { artworkPlaceholder } }
                .overlay { if resolvedPosterURL == nil { artworkPlaceholder } }
                .overlay {
                    // Figma's diagonal on the Top 10 tile (owner: follow the
                    // Figma for card gradients, these rows only).
                    if usesRowStyle && sizing == .ranked {
                        LinearGradient(colors: [.black.opacity(0.45), .clear],
                                       startPoint: .bottomLeading, endPoint: .topTrailing)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 0) {
                        if let activeRowStyle, let remainingLabel {
                            AppleRemainingTimePill(label: remainingLabel, fontSize: activeRowStyle.pillFontSize)
                        }
                        // A disc image (ISO, VIDEO_TS, BDMV) in the library.
                        if discCatalog.contains(item) { AppleDiscBadge() }
                    }
                }
                .overlay(alignment: .bottom) {
                    if usesRowStyle, let progress { AppleStillProgressBar(progress: progress, width: cardWidth) }
                }
                .clipShape(.rect(cornerRadius: cornerRadius))
                .overlay(alignment: .bottom) {
                    if !usesRowStyle, let progress {
                        artworkProgressBar(progress)
                    }
                }
                .appleRowTileLift(activeRowStyle?.platform == .mac)
                .appleTVCardArtworkFocus(cornerRadius: cornerRadius)
                .onChange(of: item.id) { _, _ in
                    failedArtworkURLs = []; fallbackArtwork = nil; artworkRetries = 0; artworkPlate = .none
                    artworkFraming = .fill
                }
                .task(id: failedArtworkURLs.count) {
                    // Out of art after a failure: try the candidates again
                    // shortly, twice, rather than keep the title tile.
                    guard resolvedPosterURL == nil, !failedArtworkURLs.isEmpty,
                          let delay = AppleCatalogArtworkPolicy.retryDelay(afterRetries: artworkRetries) else { return }
                    try? await Task.sleep(for: delay)
                    guard !Task.isCancelled else { return }
                    artworkRetries += 1
                    failedArtworkURLs = []
                }
                .task(id: item.id) {
                    #if DEBUG
                    if sizing == .ranked {
                        AppleInteractionTrace.record(.network,
                            "ranked artwork title=\(item.name) background=\(AppleCatalogArtworkPolicy.traceID(item.backgroundURL)) poster=\(AppleCatalogArtworkPolicy.traceID(item.posterURL))")
                    }
                    #endif
                    // A Discover row still (iPhone, Mac) wants the backdrop: a
                    // title that arrives with a poster only (a Top 10 match
                    // found by search) asks TMDB for one rather than cropping
                    // the poster into 16:9. Other platforms keep their behaviour.
                    let wantsBackdrop = usesRowStyle && isLandscapeCard && item.backgroundURL == nil
                    guard item.posterURL == nil || wantsBackdrop else { return }
                    fallbackArtwork = await AppleArtworkResolver.shared.resolve(
                        mediaID: item.mediaID,
                        type: item.type,
                        existingPosterURL: wantsBackdrop ? nil : item.posterURL,
                        existingBackgroundURL: item.backgroundURL,
                        configuration: metadataConfiguration
                    )
                }
                .task(id: artworkPlate) {
                    // A logo-only poster with no backdrop of its own: look one
                    // up once, for the card to draw the logo over.
                    guard artworkPlate != .none, !isLandscapeCard, fallbackArtwork == nil,
                          plateBackdropURL == nil else { return }
                    fallbackArtwork = await AppleArtworkResolver.shared.resolve(
                        mediaID: item.mediaID,
                        type: item.type,
                        existingPosterURL: nil,
                        existingBackgroundURL: nil,
                        configuration: metadataConfiguration
                    )
                }

            if showsTitle, let activeRowStyle {
                // Figma: 12 pt medium at 70 % white, clamped at a word.
                AppleWordClampedText(text: item.name, lines: dynamicTypeSize.isAccessibilitySize ? 4 : 2,
                                     reservesSpace: true)
                    .font(activeRowStyle.posterTitleFont)
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: cardWidth, alignment: .leading)
            } else if showsTitle {
                // The two title lines stay reserved (a lazy rail sizes every
                // card off the first) but below the year, so a one-line title
                // no longer leaves a blank line above it.
                captionLines(reservingTitleLines: true)
                    .hidden()
                    .overlay(alignment: .topLeading) { captionLines(reservingTitleLines: false) }
                    .frame(width: cardWidth, alignment: .leading)
                    .appleTVCardCaptionFocus()
            }
        }
        .contentShape(Rectangle())
        .foregroundStyle(.primary)
        // A combined element with no text of its own left the link without a
        // name: every Apple TV poster (N41) and the iPad's full-height
        // Featured posters (N49) had a blank VoiceOver label.
        .accessibilityElement(children: AppleCatalogCardAccessibility.namesItself(drawsTitle: showsTitle)
            ? .ignore : .combine)
        .accessibilityLabel(item.accessibilityTitle)
        .accessibilityValue(item.releaseInfo ?? "")
        .appleHoverAffordance()
    }

    private func artworkDidFail() {
        if let url = resolvedPosterURL {
            #if DEBUG
            if sizing == .ranked {
                AppleInteractionTrace.record(.failure,
                    "ranked artwork title=\(item.name) failed=\(AppleCatalogArtworkPolicy.traceID(url))")
            }
            #endif
            failedArtworkURLs.insert(url)
        }
    }

    private var isLandscapeCard: Bool { sizing == .featured || sizing == .continueWatching || sizing == .ranked }

    /// The poster's width over height when it is drawn whole in a 16:9 card.
    private var posterAspect: Double? {
        if case .posterInFrame(let aspect) = artworkFraming { return aspect }
        return nil
    }

    private var showsTitle: Bool {
        if sizing == .ranked || sizing == .portraitPromo { return false }
        // The Continue Watching tile draws its own caption row, with the menu.
        if usesRowStyle && sizing == .continueWatching { return false }
        #if os(tvOS)
        return isLandscapeCard
        #else
        return true
        #endif
    }

    private var cardWidth: CGFloat {
        if let activeRowStyle {
            switch sizing {
            case .ranked: return activeRowStyle.rankedWidth
            case .continueWatching, .featured: return activeRowStyle.stillWidth
            default: return activeRowStyle.posterWidth
            }
        }
        if sizing == .portraitPromo {
            #if os(tvOS)
            return 400
            #else
            let width = viewportWidth.flatMap { $0 > 0 ? $0 : nil } ?? 390
            return max(1, min(width - 32, 480))
            #endif
        }
        if isLandscapeCard {
            #if os(tvOS)
            // Continue Watching is the row people come back to, so it is not
            // the smallest one on the screen: 480 on a 1920 pt stage is the
            // same quarter-width card the Apple TV app's Up Next uses. It was
            // 360, which read as an afterthought next to the billboard.
            return 480
            #else
            return sizing == .continueWatching ? 260 : 320
            #endif
        }
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
        cardWidth * (isLandscapeCard ? 9.0 / 16.0 : 1.5)
    }

    /// The bar sits inside the artwork, inset from its edges as in the
    /// Apple TV app. On the very bottom edge the Apple TV's focus lift
    /// dropped it from the focused card (N58: `03-discover-down-2`), so
    /// the card you are on lost its progress. The artwork is framed at
    /// `cardWidth`, so the bar needs no GeometryReader to learn its width.
    private func artworkProgressBar(_ progress: Double) -> some View {
        let inset = AppleCatalogCardMetrics.progressBarInset
        let width = max(cardWidth - inset.horizontal * 2, 0)
        return Capsule()
            .fill(AppleDesignTokens.artworkProgressTrack)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(.white)
                    .frame(width: width * min(max(progress, 0), 1))
            }
            .frame(width: width, height: 3)
            .background {
                Capsule()
                    .fill(AppleDesignTokens.artworkProgressBacking)
                    .padding(-AppleDesignTokens.artworkProgressBackingOutset)
            }
            .shadow(color: AppleDesignTokens.artworkProgressShadow, radius: 1)
            .padding(.bottom, inset.bottom)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
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
    case featured
    case portraitPromo
    case ranked
    case continueWatching
}

struct AppleCatalogArtwork: View {
    let url: URL?
    var contentMode: AppleRemoteImageContentMode = .fill
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
    /// See `AppleRemoteImage.keepsImageWhileReloading`.
    var keepsImageWhileReloading = false
    /// The decoded image, for a hero that measures its art (`AppleHeroLuminanceMap`).
    var onImageLoad: ((CGImage) -> Void)? = nil

    var body: some View {
        AppleRemoteImage(url: url, contentMode: contentMode, placeholderSystemImage: "",
                         onLoad: onLoad == nil && onImageLoad == nil ? nil : { [onLoad, onImageLoad] image in
                             onLoad?()
                             onImageLoad?(image)
                         },
                         onFailure: onFailure,
                         loadingFill: loadingFill,
                         keepsImageWhileReloading: keepsImageWhileReloading)
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
    @Environment(\.appleOpenSourcesSettings) private var openSourcesSettings
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
    let playbackResolver: AppleStremioPlaybackResolver
    let settings: AppleSettingsStore
    let openSettings: () -> Void
    let initialAutoPlay: Bool
    let localGroup: AppleLibrarySeries?
    let localSourceStore: AppleSourceStore?
    let mediaServerLibrary: AppleMediaServerLibraryStore?
    /// The bar of the tab this page was opened from — Search and Refresh
    /// beside Back, from every entry point (owner 2026-09-24, N49 #21).
    /// Required, so a new way in cannot forget it. Nil only where the
    /// platform has no tab bar items (Apple TV).
    let tabToolbar: AppleTabToolbarContext?
    @State private var library = AppleLocalLibraryStore.shared

    @State private var localFiles: [AppleLibraryItem] = []
    @State private var discFile: AppleLibraryItem?
    @State private var hasMatchingLocalGroup = false
    @State private var titlePageStreamBadges: [AppleStreamFormatBadge] = []

    private var isDiscTitle: Bool { discFile != nil }

    /// Library matching is tied to content changes, never playback progress.
    private func refreshTitleLocalFiles() {
        let matched = item.withMediaID(pageMetadata.resolvedMediaID ?? item.mediaID)
        hasMatchingLocalGroup = localGroup != nil || !library.matchingGroups(matched).isEmpty
        let files = library.localFiles(for: matched, group: localGroup,
            episode: episodeList.episodes.first { $0.id == episodeList.selectedEpisodeID })
        if localFiles.first?.id != files.first?.id { playbackUI.localInspection = nil }
        localFiles = files
        discFile = library.discFile(in: localFiles)
        refreshTitleStreamBadges()
    }

    /// The disc's titles, from the engine's read of the local image or from
    /// the last play of it; empty for one title.
    private var discTitles: [AppleDiscTitle] {
        guard let discFile else { return [] }
        return AppleDiscTitle.rowTitles(AppleDiscCatalog.shared.titles[discFile.url] ?? [])
    }

    /// Play Disc (the disc's menu, the main title until the engine has one),
    /// Skip to Movie (the main feature), or one title from the Titles row.
    private func startDisc(_ start: AppleDiscPlaybackStart, titleID: Int? = nil) {
        guard canStartPlayback else { return }
        playbackUI.disc = AppleDiscPlaybackChoice(start: start, titleID: titleID)
        // The menu and a chosen title start from the top; Skip to Movie
        // resumes where the film was left.
        if start == .menu || titleID != nil { playbackUI.startsFromBeginning = true }
        appleTrace("title page disc: \(start.rawValue)\(titleID.map { " title \($0)" } ?? "")")
        playbackUI.request = UUID()
    }

    /// Format badges for this title: the local file's probe (or name), else
    /// the stream Automatic would play, once streams are known. No network.
    private func refreshTitleStreamBadges() {
        if let file = localFiles.first {
            titlePageStreamBadges = playbackUI.localInspection?.badges ?? AppleStreamFormatBadge.parse(file.name)
            return
        }
        guard !playbackUI.streamChoices.isEmpty else { titlePageStreamBadges = []; return }
        let first = AppleStremioCandidateRanking.playbackOrder(
            playbackUI.streamChoices, choice: .automatic, device: .current,
            title: item.name, year: item.year).first
        titlePageStreamBadges = first.map { AppleStreamFormatBadge.normalized(AppleStreamFormatBadge.badges(for: $0)) } ?? []
    }

    /// The badges a Quality row shows for `choice`: those of the stream it
    /// would play, less the resolution the row already names.
    private func qualityRowBadges(_ choice: AppleStreamQualityChoice) -> [AppleStreamFormatBadge] {
        // Automatic plays this title's own file first when there is one.
        if choice == .automatic, !localFiles.isEmpty {
            return AppleStreamFormatBadge.rowBadges(titlePageStreamBadges)
        }
        let first = AppleStremioCandidateRanking.playbackOrder(
            playbackUI.streamChoices, choice: choice, device: .current,
            title: item.name, year: item.year).first
        return first.map { AppleStreamFormatBadge.rowBadges(AppleStreamFormatBadge.normalized(AppleStreamFormatBadge.badges(for: $0))) } ?? []
    }

    @State private var playbackCoordinator = ApplePlaybackCoordinator()
    @State private var downloadCoordinator = AppleOfflineDownloadCoordinator()
    @State private var seasonDownloads = AppleSeasonDownloadQueue()
    // The page's own values, grouped (N45): SwiftUI sets up and checks each
    // dynamic property of a view, and the page had sixty.
    @State private var heroTrailer = AppleTitlePageTrailerState()
    @State private var heroStill = AppleTitlePageHeroStill()
    @State private var slotArt = AppleTitlePageSlotArtState()
    /// Hero art URLs that failed to load on this page; the next candidate is
    /// tried (`AppleTitlePagePolicy.heroArtworkURL`).
    @State private var failedHeroArtworkURLs: Set<URL> = []
    @State private var titleWordmark = AppleTitlePageWordmarkState()
    @State private var pageGeometry = AppleTitlePageGeometry()
    @State private var prompts = AppleTitlePagePrompts()
    @State private var titleActions = AppleTitlePageActionState()
    @State private var playbackUI = AppleTitlePagePlaybackState()
    @State private var pageMetadata = AppleTitlePageMetadataState()
    @State private var episodeList = AppleTitlePageEpisodeState()
    @State private var offlineState = AppleTitlePageOfflineState()
    @State private var rating: AppleTitleRating?
    @State private var preparationGeneration = UUID()
    @State private var fillTimeline = AppleDetailFillTimeline()
    #if os(iOS)
    @State private var systemVideoAutoplayEnabled = UIAccessibility.isVideoAutoplayEnabled
    #endif
    #if os(tvOS)
    @FocusState private var tvDetailFocus: AppleTVDetailFocus?
    /// When focus last left the title row for `nil` (`AppleTVDetailShelfEntry`).
    @State private var tvTitleRowExit: ContinuousClock.Instant?
    /// Set once Play has held focus; see `AppleTVDetailOpeningFocus`.
    @State private var tvDetailOpeningSettled = false
    #endif
    /// Scrolls the page back to the hero when a trailer is chosen below it.
    @State private var detailScrollPosition = ScrollPosition(edge: .top)
    @ScaledMetric(relativeTo: .largeTitle) private var phoneTitleSize: CGFloat = 44
    // The text title and its metadata line grow with Dynamic Type; fixed
    // point sizes stayed small at the accessibility sizes (iPad v2 re-run).
    @ScaledMetric(relativeTo: .title3) private var scaledLandscapeTitleSize: CGFloat = AppleDetailMetrics.landscapeTitleFontSize
    @ScaledMetric(relativeTo: .headline) private var scaledPortraitTitleSize: CGFloat = AppleDetailMetrics.portraitTitleFontSize
    @ScaledMetric(relativeTo: .subheadline) private var scaledMetadataSize: CGFloat = AppleDetailMetrics.metadataFontSize
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
        playbackResolver: AppleStremioPlaybackResolver,
        settings: AppleSettingsStore,
        openSettings: @escaping () -> Void,
        initialAutoPlay: Bool = false,
        localGroup: AppleLibrarySeries? = nil,
        localSourceStore: AppleSourceStore? = nil,
        mediaServerLibrary: AppleMediaServerLibraryStore? = nil,
        tabToolbar: AppleTabToolbarContext?
    ) {
        self.item = item
        self.source = source
        self.relatedItems = relatedItems
        self.mediaIndex = mediaIndex
        #if DEBUG
        self.playbackSources = AppleTitlePageStreamFixture.opensQuality
            ? AppleTitlePageStreamFixture.sources
            : playbackSources + AppleTitlePageStreamFixture.sources
        #else
        self.playbackSources = playbackSources
        #endif
        self.metadataConfiguration = metadataConfiguration
        self.gatewayConfig = gatewayConfig
        self.playbackResolver = playbackResolver
        self.settings = settings
        self.openSettings = openSettings
        self.initialAutoPlay = initialAutoPlay
        self.localGroup = localGroup
        self.localSourceStore = localSourceStore
        self.mediaServerLibrary = mediaServerLibrary
        self.tabToolbar = tabToolbar
        _pageMetadata = State(initialValue: AppleTitlePageMetadataState(
            isPreparing: ApplePlayGatingPolicy.isPreparingOnAppear(mediaID: item.mediaID)
        ))
    }

    var body: some View {
        Group {
            #if DEBUG
            ScrollViewReader { reader in
                detailContent.task(id: episodeList.episodes.count) {
                    guard UserDefaults.standard.string(forKey: "OpenStreamVisionScreen") == "episodes", !episodeList.episodes.isEmpty else { return }
                    try? await Task.sleep(for: .milliseconds(700))
                    reader.scrollTo("vision-episodes", anchor: .top)
                    // `OpenStreamDebugSeasonSwitch YES` then steps through the
                    // first seasons, for a trace of the switch.
                    guard UserDefaults.standard.bool(forKey: "OpenStreamDebugSeasonSwitch") else { return }
                    for season in seasonNumbers.dropFirst().prefix(3) + seasonNumbers.prefix(1) {
                        try? await Task.sleep(for: .seconds(3))
                        guard !Task.isCancelled else { return }
                        appleTrace("season switch \(season)")
                        episodeList.selectedSeason = season
                    }
                }
            }
            .onAppear { AppleTitlePageOpenProbe.appeared() }
            // `OpenStreamDetailScrollY` scrolls the title page this far once
            // it has filled, so a headless sweep can photograph each section.
            .task {
                let scrollY = UserDefaults.standard.double(forKey: "OpenStreamDetailScrollY")
                guard scrollY > 0 else { return }
                try? await Task.sleep(for: .seconds(6))
                // A screen at a time, as a viewer scrolls: the sections below
                // the hero are built as they come into view (N47), and one
                // jump past unbuilt ones lands on their estimated heights.
                var y = 0.0
                while y < scrollY {
                    guard !Task.isCancelled else { return }
                    y = min(scrollY, y + 500)
                    detailScrollPosition.scrollTo(y: y)
                    try? await Task.sleep(for: .milliseconds(400))
                }
            }
            // `OpenStreamDebugDownloadOptions title|season` opens the title's
            // Download Options (or Season Download Options) once the page has
            // settled, showing the choices of a running download. Nothing is
            // downloaded and a choice only closes it, so the prompt can be
            // photographed and left with Menu.
            .task {
                let which = UserDefaults.standard.string(forKey: "OpenStreamDebugDownloadOptions") ?? ""
                guard which == "title" || which == "season" else { return }
                try? await Task.sleep(for: .seconds(6))
                guard !Task.isCancelled else { return }
                prompts.optionsPreview = true
                if which == "season" {
                    prompts.seasonDownloadActions = true
                } else {
                    prompts.downloadActions = true
                }
                // Left with Menu or Cancel: the page's real prompts again.
                while prompts.downloadActions || prompts.seasonDownloadActions {
                    try? await Task.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled else { return }
                }
                prompts.optionsPreview = false
            }
            #else
            detailContent
            #endif
        }
        .environment(\.appleTMDBConfiguration, metadataConfiguration)
        .accessibilityIdentifier("detail.screen.\(item.type).\(item.mediaID)")
    }

    private func applyDetailViewport(_ viewport: AppleDetailViewport) {
        pageGeometry.safeAreaInsets = viewport.insets
        pageGeometry.viewportSize = CGSize(
            width: viewport.size.width + viewport.insets.leading + viewport.insets.trailing,
            height: viewport.size.height + viewport.insets.top + viewport.insets.bottom
        )
    }

    /// Wordmark, text title, or nothing while the wordmark resolves.
    private var titleLogoPresentation: AppleTitleLogoPresentation {
        AppleTitleLogoPolicy.resolvedState(
            validated: titleWordmark.state.validation,
            loadResult: titleWordmark.loadResult,
            elapsed: titleWordmark.graceExpired ? AppleTitleLogoPolicy.loadingGrace : 0
        )
    }

    private var titlePageIsCovered: Bool {
        #if os(iOS) || os(tvOS)
        playbackUI.presentation != nil
        #else
        false
        #endif
    }

    private var detailContent: some View {
        Group {
            // The player owns progress and transport updates while covering this
            // page. Remove the covered content's Observation subscriptions;
            // on dismissal it reads the latest saved progress again.
            if titlePageIsCovered {
                Color.clear
            } else {
                #if os(tvOS)
                tvOSDetailLayout
                #else
                ScrollView {
                    AppleTitlePageScrollContent(page: self)
                }
                .scrollPosition($detailScrollPosition)
                #if os(macOS)
                // Discover's: the hero runs up under the toolbar with no backing.
                .appleMacHeroUnderToolbar()
                #endif
                // The navigation bar is hidden here so the hero can bleed to the top
                // of the screen. With no bar there is nothing behind the status bar
                // once the page scrolls, and the synopsis was drawn through the
                // clock. Applied to the scroll view itself, not the group, because
                // it reads that scroll view's offset.
                .appleStatusBarShield(topInset: pageGeometry.safeAreaInsets.top)
                #endif
            }
        }
        .scrollIndicators(AppleDesignTokens.scrollIndicatorVisibility)
        .coordinateSpace(name: "detail-scroll")
        #if os(iOS)
        // The hero extends into the top safe area in both orientations; the
        // status-bar shield above protects text once the page scrolls.
        .scrollClipDisabled()
        #else
        // The Mac title page's art always runs up under the toolbar.
        .scrollClipDisabled(isLandscapeLayout || usesMacTitlePage)
        #endif
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
        #if os(macOS) || os(iOS)
        // Discover's bar, unchanged, with ‹ at its leading edge (N37).
        .appleTitlePageToolbar(pageID: item.id, backIsBlocked: playbackUI.presentation != nil) { dismiss() }
        .environment(\.appleTabToolbar, tabToolbar)
        #endif
        #if os(iOS) || os(visionOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        #endif
        #if os(iOS)
        // The bar stays, as it is over Discover's hero: see-through, the
        // art running up under it (the hero pulls itself up by the page's
        // top inset, which now includes the bar).
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        #endif
        #if os(tvOS)
        // The backdrop fills 1920x1080; the tab bar returns when Menu pops.
        .toolbar(.hidden, for: .tabBar)
        #endif
        #if os(tvOS)
        // Pages, not dialogs: tvOS drew a focused Pause or Resume white on the
        // white focus fill (N73). Menu pops them, as the dialogs' Cancel did.
        .navigationDestination(isPresented: $prompts.downloadActions) {
            AppleTVDownloadOptionsPage(
                title: "Download Options",
                message: downloadActionMessage,
                choices: downloadOptionChoices(season: false),
                onChoose: performDownloadOption
            )
        }
        .navigationDestination(isPresented: $prompts.seasonDownloadActions) {
            AppleTVDownloadOptionsPage(
                title: "Season Download Options",
                message: seasonDownloadMessage,
                choices: downloadOptionChoices(season: true),
                onChoose: performDownloadOption
            )
        }
        #else
        .confirmationDialog(
            "Download Options",
            isPresented: $prompts.downloadActions,
            titleVisibility: .visible
        ) {
            ForEach(downloadOptionChoices(season: false)) { choice in
                Button(choice.title, role: choice.isDestructive ? .destructive : nil) {
                    performDownloadOption(choice)
                }
            }
        } message: {
            Text(downloadActionMessage)
        }
        .confirmationDialog(
            "Season Download Options",
            isPresented: $prompts.seasonDownloadActions,
            titleVisibility: .visible
        ) {
            ForEach(downloadOptionChoices(season: true)) { choice in
                Button(choice.title, role: choice.isDestructive ? .destructive : nil) {
                    performDownloadOption(choice)
                }
            }
        } message: {
            Text(seasonDownloadMessage)
        }
        #endif
        #if os(tvOS)
        .navigationDestination(isPresented: $prompts.watchOnMenu) {
            AppleTVWatchOnPage(choices: watchOnAction?.choices ?? [], onChoose: openWatchOn)
        }
        #endif
        .sheet(item: $prompts.watchOnInstructions) { instructions in
            AppleWatchOnInstructionsView(instructions: instructions)
        }
        .sheet(isPresented: $prompts.streamPicker) {
            streamPicker
                #if os(visionOS)
                .frame(width: 720, height: 540)
                #endif
        }
        // Exactly once per press: SwiftUI reruns this task whenever the page
        // reappears (another tab and back), and an unconsumed request then
        // started playback by itself without the episode it named
        // (`ApplePlayRequestLedger`).
        .task(id: playbackUI.request) {
            guard playbackUI.ledger.consume(playbackUI.request) else { return }
            await resolvePlayback()
        }
        .onChange(of: library.contentRevision, initial: true) { _, _ in
            guard !titlePageIsCovered else { return }
            refreshTitleLocalFiles()
        }
        .onChange(of: titlePageIsCovered) { _, covered in
            // Metadata for unrelated library titles can finish during playback.
            // Defer the matching pass until this page is visible again.
            if !covered { refreshTitleLocalFiles() }
        }
        .onChange(of: pageMetadata.resolvedMediaID) { _, _ in refreshTitleLocalFiles() }
        .onChange(of: episodeList.episodes) { _, _ in refreshTitleLocalFiles() }
        .onChange(of: episodeList.selectedEpisodeID) { _, _ in refreshTitleLocalFiles() }
        .onChange(of: playbackUI.streamChoices) { _, _ in refreshTitleStreamBadges() }
        // The local file's format and, for a disc image, its titles: read by
        // the engine from the file itself, once per page.
        .task(id: localFiles.first?.id) {
            guard let file = discFile ?? localFiles.first else { return }
            let inspection = await library.inspection(for: file)
            guard !Task.isCancelled else { return }
            playbackUI.localInspection = inspection
            refreshTitleStreamBadges()
        }
        .task(id: "trailer-reset:\(item.id):\(allowsTrailerAutoplay)") {
            heroTrailer.isActive = false
            heroTrailer.isPlaying = false
            heroTrailer.hasStarted = false
            // Autoplay is muted (the page clamps it anyway); the sound
            // control or Play Trailer turns sound on.
            heroTrailer.muted = true
            heroTrailer.allowsSound = false
        }
        // Art-first: the autoplaying trailer is not even looked for until the
        // hero still is on screen, and at low priority behind the page.
        .task(id: AppleTrailerArtFirstPolicy.autoplayRequestID(
            itemID: item.id, enabled: allowsTrailerAutoplay, art: heroStill.art, keys: trailerCandidates
        ), priority: .low) {
            guard allowsTrailerAutoplay,
                  AppleTrailerArtFirstPolicy.mayRequestTrailer(art: heroStill.art, pressed: false) else { return }
            try? await Task.sleep(for: .seconds(2))
            // A pressed Play Trailer got there first.
            guard !Task.isCancelled, !heroTrailer.hasStarted else { return }
            guard let playableKey = await resolvePlayableTrailerKey(startingAt: 0) else { return }
            // …or while its first candidate was being probed.
            guard !Task.isCancelled, !heroTrailer.hasStarted else { return }
            heroTrailer.pinnedKey = playableKey
            heroTrailer.muted = true
            guard prepareTrailerAudio() else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.45)) {
                heroTrailer.hasStarted = true
                heroTrailer.isActive = true
            }
        }
        .task(id: "trailer-startup:\(trailerKey ?? "none"):\(heroTrailer.replayGeneration):\(heroTrailer.isActive):\(heroTrailer.isPlaying)") {
            guard heroTrailer.isActive, !heroTrailer.isPlaying else { return }
            try? await Task.sleep(for: .seconds(AppleTrailerArtFirstPolicy.startupTimeout))
            guard !Task.isCancelled,
                  AppleTrailerArtFirstPolicy.startupHasTimedOut(
                    active: heroTrailer.isActive, videoIsOnScreen: heroTrailer.isPlaying,
                    elapsed: AppleTrailerArtFirstPolicy.startupTimeout
                  ) else { return }
            appleTrace("title trailer startup timed out: \(item.name)")
            handleTrailerState("error", muted: heroTrailer.muted, errorCode: nil)
        }
        .onChange(of: settings.autoMuteTrailer) { _, muted in heroTrailer.muted = muted }
        .onChange(of: trailerCandidates) { old, new in
            guard heroTrailer.hasStarted else { return }
            appleTrace("title trailer candidates changed \(old.count)→\(new.count) while started; key=\(trailerKey ?? "none")")
        }
        // A pressed trailer that never comes on screen stops saying it is
        // loading after the same wait the Discover hero gives it.
        .task(id: heroTrailer.pressedKey) {
            guard heroTrailer.pressedKey != nil else { return }
            try? await Task.sleep(for: .seconds(AppleTrailerArtFirstPolicy.pressedTrailerGiveUp))
            guard !Task.isCancelled else { return }
            heroTrailer.pressedKey = nil
        }
        .task(id: titleLogoTaskID) {
            titleWordmark.loadResult = nil
            let candidates = titleLogoCandidates
            guard !candidates.isEmpty else {
                // Until the page's details have answered, no wordmark yet is
                // not "no wordmark": the title's place is held, so a text
                // title never draws and then gives way to the logo.
                titleWordmark.state = titleMetadataAnswered ? .unavailable : .loading
                return
            }
            titleWordmark.state = .loading
            #if DEBUG
            AppleLaunchClock.mark("detail.logoURL")
            #endif
            // The first wordmark that is a clean transparent PNG. TMDB's pick
            // can fail it (an SVG, an opaque plate) where the add-on's logo the
            // Discover hero draws passes (Project Hail Mary, iPad v2).
            for logoURL in candidates {
                guard !Task.isCancelled else { return }
                if await AppleTransparentPNGLogoValidator.isValid(url: logoURL), !Task.isCancelled {
                    #if DEBUG
                    AppleLaunchClock.mark("detail.validated")
                    #endif
                    titleWordmark.state = .valid(logoURL)
                    return
                }
            }
            if !Task.isCancelled { titleWordmark.state = .unavailable }
        }
        // The iPhone header's art is chosen once the details answer or a
        // deadline passes (`AppleTitlePageSlotArt`). Kept off this chain,
        // which is already at the type checker's limit on visionOS.
        .background { slotArtWatcher }
        // Keyed by the item only: a wordmark URL that arrives late must not
        // hide a text title that is already on screen; the text stays until
        // the wordmark has actually loaded.
        .task(id: "title-logo-grace:\(item.id)") {
            titleWordmark.graceExpired = false
            try? await Task.sleep(for: .seconds(AppleTitleLogoPolicy.loadingGrace))
            guard !Task.isCancelled else { return }
            titleWordmark.graceExpired = true
        }
        .task(id: item.id) {
            heroTrailer.pinnedKey = nil
            heroTrailer.gaveUp = false
            heroTrailer.isActive = false
            heroTrailer.isPlaying = false
            heroTrailer.muted = true
            heroTrailer.allowsSound = false
            titleWordmark.loadResult = nil
            titleWordmark.graceExpired = false
            #if DEBUG
            AppleLaunchClock.mark("detail.task")
            #endif
            fillTimeline.begin(title: item.name)
            fillTimeline.mark(.paint)
            markOverviewIfVisible(source: "catalog")
            // Recording that this title was opened is bookkeeping. Awaiting it
            // cost ~294 ms — a disk write plus a rebuild of the whole record
            // array — and the favourite lookup another ~219 ms, all of it
            // before the page asked for the metadata it is about to draw.
            // The favourite state is read first (a new record is never a
            // favourite, so the answer is the same either way), the write runs
            // on its own, and the metadata starts immediately.
            titleActions.isFavorite = mediaIndex.record(id: recordID)?.isFavorite ?? false
            let viewedRecord = AppleMediaIngestion.catalogRecord(instanceID: source.id, item: item)
            Task { try? await mediaIndex.upsert(viewedRecord) }
            #if DEBUG
            AppleLaunchClock.mark("detail.prepare")
            #endif
            await prepare()
            if !Task.isCancelled { fillTimeline.mark(.done) }
            await refreshOfflineState()
            // A hero's Play opens the page to play — but only what the page
            // itself would offer: a series whose catalog lists no episodes
            // has no Play here, and starting one anyway could only end in
            // "Playback Unavailable" (iOS 18.6 regression 2026-10-01).
            if playbackUI.ledger.takeInitialAutoPlay(initialAutoPlay) {
                if hasPlaybackRoute {
                    playbackUI.request = UUID()
                } else {
                    appleTrace("detail autoplay skipped: nothing on this page can play (\(item.name))")
                }
            }
            #if DEBUG
            if AppleTitlePageStreamFixture.opensQuality { await chooseStreams() }
            #endif
        }
        .task(id: "similar:\(item.id):\(relatedItems.count):\(pageMetadata.details?.mediaID ?? "")") {
            await refreshSuggestions()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active else { return }
            pauseTrailerPreview(reason: "scene \(phase)")
        }
        .onDisappear {
            pauseTrailerPreview(reason: "page gone")
            if AppleMediaServerItemReference.parse(item.mediaID) == nil {
                seasonDownloads.cancel()
                if downloadCoordinator.state.ownsDownload { downloadCoordinator.cancel() }
            }
        }
        .task(id: "offline:\(episodeList.selectedEpisodeID ?? ""):\(seasonDownloads.isRunning)") {
            guard !seasonDownloads.isRunning, !downloadCoordinator.state.ownsDownload else { return }
            await refreshOfflineState()
        }
        .task(id: "downloaded-episodes:\(episodeList.episodes.count):\(seasonDownloads.completed):\(downloadCoordinator.state.isCompleted)") {
            await refreshDownloadedEpisodeIDs()
        }
        .onChange(of: episodeList.selectedSeason) { _, season in
            episodeList.selectedEpisodeID = nextUnwatchedEpisodeID(in: season, from: episodeList.episodes)
        }
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(
            for: UIAccessibility.videoAutoplayStatusDidChangeNotification
        )) { _ in
            systemVideoAutoplayEnabled = UIAccessibility.isVideoAutoplayEnabled
        }
        #endif
        .modifier(AppleStremioPlayerPresentationModifier(presentation: $playbackUI.presentation))
        // Hosted on its own view so it takes the system tint: a page opened
        // from Search inherits its `.tint(.primary)`, which drew the focused
        // button's title white on the white focus fill (Apple TV, 2026-10-01).
        .background { playbackUnavailableAlertHost }
    }

    private var playbackUnavailableAlertHost: some View {
        Color.clear
        .alert("Playback Unavailable", isPresented: Binding(
            // A failure while the player is up is the player's: it shows its
            // own alert, or hands an every-stream-failed press over (the
            // OpenStream fallback, or `unavailableMessage`) and is closed. Presenting from here as well took
            // the player's cover down and lost the failure with it.
            get: { playbackUI.unavailableMessage != nil || (playbackFailure != nil && playbackUI.presentation == nil) },
            // The alert reports itself dismissed after its animation, by
            // which time Retry has already put the page into Preparing;
            // resetting then dropped that state and the page sat on Play.
            set: {
                guard !$0 else { return }
                if playbackUI.unavailableMessage != nil { playbackUI.unavailableMessage = nil; return }
                if playbackFailure != nil { playbackCoordinator.reset() }
            }
        )) {
            if playbackUI.unavailableMessage != nil {
                Button("OK", role: .cancel) {
                    playbackUI.unavailableMessage = nil
                    playbackCoordinator.reset()
                }
            } else {
                // Retry only where another attempt can end differently; a missing
                // or unusable source fails the same way every time, and there
                // the way on is Sources.
                switch playbackFailure.map(ApplePlaybackFailureRecovery.init) {
                case .retry:
                    Button("Retry", action: retryPlayback)
                case .sources:
                    Button("Sources…", action: openSourcesAfterPlaybackFailure)
                case .closeOnly, nil:
                    EmptyView()
                }
                Button("Close", role: .cancel) { playbackCoordinator.reset() }
            }
        } message: {
            if let unavailableMessage = playbackUI.unavailableMessage {
                Text(unavailableMessage)
            } else if let playbackFailure {
                Text(playbackFailure.userMessage)
            }
        }
        .tint(nil)
    }

    /// The iPad, landscape and Vision title page: the hero, the title block
    /// and the rails below it. (The iPhone in portrait and the Mac have their
    /// own pages; see `AppleTitlePageScrollContent`.)
    @ViewBuilder
    var regularTitlePage: some View {
        detailHero
            #if os(iOS)
            // With the navigation bar hidden, extend the hero through
            // the status-bar safe area in portrait as well as landscape.
            .padding(.top, -pageGeometry.safeAreaInsets.top)
            #else
            .padding(.top, isLandscapeLayout ? -pageGeometry.safeAreaInsets.top : 0)
            #endif
            .padding(.leading, isLandscapeLayout ? -pageGeometry.safeAreaInsets.leading : 0)
            .padding(.trailing, isLandscapeLayout ? -pageGeometry.safeAreaInsets.trailing : 0)

        VStack(alignment: .leading, spacing: 0) {
            if usesOverlayHero {
                EmptyView()
            } else {
                if titleLogoPresentation != .text {
                    portraitTrailerTitle
                        .padding(.top, heroTrailer.isPlaying ? AppleDetailMetrics.heroToTitleSpacing : 0)
                } else {
                    Text(displayTitle)
                        .font(.system(size: scaledPortraitTitleSize, weight: .semibold))
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
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
            if let tagline = pageMetadata.details?.tagline, !tagline.isEmpty {
                Text(tagline)
                    .font(.headline)
                    .italic()
                    .padding(.top, 12)
            }

            if let summary = AppleMetadataPresentationPolicy.synopsis(
                catalog: item.summary,
                enriched: pageMetadata.details?.overview
            ) {
                Text(summary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: detailContentWidth, alignment: .leading)
                    .padding(.top, AppleDetailMetrics.iconRowToSynopsisSpacing)
                    .shadow(color: .black.opacity(0.6), radius: 6, y: 1)
            }

            #if !os(iOS)
            if item.type == "series" {
                episodeSection
                    .id("vision-episodes")
                    .padding(.top, AppleDetailMetrics.sectionHeaderTopSpacing)
            }
            #endif

        }
        .frame(maxWidth: detailContentWidth, alignment: .leading)
        .padding(.horizontal, detailHorizontalInset)
        .frame(maxWidth: .infinity, alignment: .leading)

        #if os(iOS)
        // A rail, outside the column for the same reason as More Like This.
        if item.type == "series" {
            padEpisodesSection
                .id("vision-episodes")
                .padding(.top, AppleDetailMetrics.sectionHeaderTopSpacing)
        }
        #endif

        // Outside the column on purpose. Prose belongs in a readable
        // width; a poster rail does not — every other rail in the app
        // (Discover, Library) runs to the page edge. Inside the column
        // the fifth card was sliced vertically at 695 pt of an 834 pt
        // iPad page with 139 pt of black beside it, which reads as a
        // rendering fault rather than "there is more to the right"
        // (measured 2026-09-17). It carries its own leading inset.
        if !discTitles.isEmpty {
            AppleDiscTitlesRow(titles: discTitles, horizontalInset: detailHorizontalInset) { startDisc(.mainTitle, titleID: $0.id) }
                .padding(.top, AppleDetailMetrics.sectionHeaderTopSpacing)
        }
        if !suggestedItems.isEmpty {
            moreLikeThisSection(title: "More Like This")
                .padding(.top, AppleDetailMetrics.sectionHeaderTopSpacing)
        }
        #if os(iOS)
        // The iPhone's and the Mac's Cast & Crew rail: the iPad had
        // none, so its portraits were nowhere (N37).
        let credits = titlePageCredits
        if !credits.isEmpty {
            // The page's margin, the one the synopsis and More Like This
            // use: 40 pt in a wide iPad layout, not the phone's 16 (iPad v2).
            phoneCastSection(credits, inset: detailHorizontalInset)
                .padding(.top, AppleDetailMetrics.sectionHeaderTopSpacing)
        }
        #endif
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
                .frame(maxWidth: .infinity)
                .frame(height: heroHeight)
                .clipped()
                .accessibilityHidden(true)
            heroTrailerStartButton

            #if os(iOS) || os(visionOS)
            trailerPreview()
            #endif

            if !isLandscapeLayout, !usesPadPortraitHero, case .valid = titleWordmark.state, let logoURL = titleLogoURL {
                AppleTrimmedTitleLogo(url: logoURL) { loaded in
                    guard AppleTitleLogoPolicy.keepsLoadResult(loaded, shown: titleLogoPresentation) else { return }
                    titleWordmark.loadResult = loaded
                    if loaded { fillTimeline.mark(.wordmark) }
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
                    .opacity(heroTrailer.isPlaying || titleLogoPresentation != .logo ? 0 : 1)
                    .animation(reduceMotion ? nil : .easeInOut(duration: AppleDetailMetrics.trailerCrossfadeDuration), value: heroTrailer.isPlaying)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(item.name)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityHidden(heroTrailer.isActive)
            }

            if usesPadHeroFades {
                // Discover's iPad hero fades, so the copy reads over the art
                // exactly as it does there.
                AppleHeroScrimView(scrim: .wide(tone: .unknown, videoIsShowing: heroTrailer.isPlaying, copyTrailing: 0))
                    .animation(.easeInOut(duration: 0.6), value: heroTrailer.isPlaying)
            }

            if usesOverlayHero, landscapeOverlaysVisible {
                landscapeHeroOverlay(in: proxy.size)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(.leading, overlayLeadingMargin)
                    .padding(.bottom, overlayBottomMargin)
                    .transition(.opacity)
            }

            if isLandscapeLayout, let trailerInteractionGlyph = heroTrailer.interactionGlyph {
                Image(systemName: trailerInteractionGlyph)
                    .font(.system(size: 56))
                    .foregroundStyle(.white.opacity(0.70))
                    .transition(.opacity)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
            }

            // Not on macOS: the navigation bar is only hidden on iOS and
            // visionOS, so a Mac window already has a back chevron in its
            // titlebar and this drew a second one over the artwork two points
            // below it (macOS sweep, 2026-09-21).
            #if os(tvOS)
            detailBackButton
                .padding(.leading, isLandscapeLayout ? pageGeometry.safeAreaInsets.leading : 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            #endif
        }
        }
        .frame(maxWidth: .infinity)
        .frame(height: heroHeight)
        .background(.black)
        .clipped()
        // Where the hero sits in the page, read without a GeometryReader
        // in the tree or a preference climbing it on every scroll frame.
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named("detail-scroll"))
        } action: { frame in
            detailHeroFrameChanged(frame)
        }
        .accessibilityElement(children: .contain)
    }

    #if os(iOS) || os(visionOS)
    /// The inline trailer over the hero still, once it has been started.
    /// `controlTopInset` moves its mute/replay control to the top right, for
    /// the iPhone title page whose copy covers the bottom of the art.
    @ViewBuilder
    private func trailerPreview(controlTopInset: CGFloat? = nil, exactSlot: Bool = false) -> some View {
        if trailerPreviewIsShown, let embedURL = trailerEmbedURL {
            AppleYouTubeAutoPreview(
                url: embedURL,
                artworkURL: exactSlot ? phoneSlotArt?.url : heroArtworkURL,
                artworkImage: heroStill.image,
                isLandscape: viewportSize.width > viewportSize.height,
                isPlaying: $heroTrailer.isActive,
                isMuted: $heroTrailer.muted,
                allowsSound: heroTrailer.allowsSound,
                replayGeneration: $heroTrailer.replayGeneration,
                showsReplay: !heroTrailer.isActive,
                onStateChange: { state, muted, errorCode in
                    guard AppleTrailerArtFirstPolicy.acceptsMessage(
                        messageKey: embedURL.lastPathComponent, currentKey: trailerKey
                    ) else { return }
                    handleTrailerState(state, muted: muted, errorCode: errorCode)
                },
                onTap: toggleTrailerPlayback,
                onMute: toggleTrailerSound,
                onReplay: restartTrailer,
                controlTopInset: controlTopInset,
                // Final crop before the art fades, as the hero's (N46b): the
                // page revealed first and grew 1.35→1.80× in view (N50).
                settlesPictureBeforeReveal: !exactSlot,
                exactSlot: exactSlot
            )
                .id(embedURL.lastPathComponent)
                .frame(maxWidth: .infinity)
                .frame(maxHeight: .infinity)
                .transition(.opacity)
        }
    }
    #endif

    // tvOS only: iOS and the Mac put ‹ in the toolbar (`appleTitlePageToolbar`).
    // Apple TV keeps the bare glyph — no boxed icons there.
    #if os(tvOS)
    private var detailBackButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: AppleDesignTokens.minimumActionSize, height: AppleDesignTokens.minimumActionSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back")
        .accessibilityIdentifier("detail.back")
        .padding(.leading, 12)
        .padding(.top, 10)
    }
    #endif

    private var heroHeight: CGFloat {
        #if os(tvOS)
        460
        #elseif os(visionOS)
        min(viewportSize.height * 0.78, viewportSize.width * 9 / 16)
        #elseif os(iOS)
        usesPadPortraitHero
            // The iPad's Discover hero, from the same screen.
            ? AppleMacHeroLayout(contentWidth: viewportSize.width, windowHeight: viewportSize.height,
                                 platform: .pad).height
            : AppleDetailMetrics.heroHeight(
                in: viewportSize,
                horizontalSizeClassIsRegular: horizontalSizeClass == .regular
            )
        #elseif os(macOS)
        // Was a flat 420 pt at every window size, which is a third of a
        // full-screen Mac display and read as a letterbox strip. The same
        // proportion visionOS uses, so the two agree on what a wide hero is.
        min(viewportSize.height * 0.78, viewportSize.width * 9 / 16)
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
        pageGeometry.viewportSize == .zero ? CGSize(width: 1100, height: 760) : pageGeometry.viewportSize
        #elseif os(iOS)
        pageGeometry.viewportSize
        #elseif os(macOS)
        // `pageGeometry.viewportSize` has always been measured on macOS too — the
        // `.onGeometryChange` that fills it is unconditional — but this
        // property threw the measurement away and answered `.zero`, so every
        // metric derived from it fell back to a constant and the detail page
        // never changed shape however large the window was dragged (macOS
        // sweep, 2026-09-21). A Mac window with no measurement yet is assumed
        // to be the default opening size rather than nothing, the same
        // substitution visionOS makes for its own default.
        pageGeometry.viewportSize == .zero ? CGSize(width: 1280, height: 860) : pageGeometry.viewportSize
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
        #elseif os(macOS)
        // A Mac window is resizable to any shape, so there is no size class to
        // ask — the window's own proportions are the answer, which is exactly
        // how visionOS decides it.
        AppleMacChromeMetrics.isRegularLayout(viewport: viewportSize)
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
        #elseif os(macOS)
        isLandscapeRegularLayout
        #else
        false
        #endif
    }

    /// The title, metadata and buttons drawn over the art: landscape, and
    /// the iPad either way up (N37, owner 2026-09-24: "it should be a full
    /// hero like the main page even on the content page"). Upright, the iPad
    /// drew the art as a box with the title under it, unlike its Discover
    /// hero (N20); it now opens on that hero's height with the copy on it.
    private var usesOverlayHero: Bool {
        isLandscapeLayout || usesPadPortraitHero
    }

    /// The iPad's hero draws Discover's iPad fades under its copy.
    private var usesPadHeroFades: Bool {
        #if os(iOS)
        horizontalSizeClass == .regular && usesOverlayHero
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
            ? AppleDetailMetrics.compactLandscapeOverlayLeadingMargin + pageGeometry.safeAreaInsets.leading
            : AppleDetailMetrics.landscapeOverlayLeadingMargin
    }

    private var overlayBottomMargin: CGFloat {
        isCompactLandscapeLayout
            ? max(AppleDetailMetrics.compactLandscapeOverlayBottomMargin, pageGeometry.safeAreaInsets.bottom)
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
        !copyYieldsToTrailer
    }

    /// A playing trailer hides the copy over the art on the phone held
    /// sideways. The iPad keeps it on the trailer, as its Discover hero does
    /// (N37): upright, hiding it left the hero with no title or buttons.
    private var copyYieldsToTrailer: Bool {
        heroTrailer.isPlaying && !usesPadHeroFades
    }

    private var isWideLandscape: Bool {
        isLandscapeRegularLayout && viewportSize.width >= AppleDetailMetrics.wideEpisodeThreshold
    }

    private func landscapeHeroOverlay(in heroSize: CGSize) -> some View {
        VStack(alignment: .leading, spacing: AppleDetailMetrics.landscapeOverlaySpacing) {
            if case .valid = titleWordmark.state, let logoURL = titleLogoURL {
                ZStack(alignment: .leading) {
                    AppleTrimmedTitleLogo(url: logoURL, alignment: .leading) { loaded in
                    guard AppleTitleLogoPolicy.keepsLoadResult(loaded, shown: titleLogoPresentation) else { return }
                    titleWordmark.loadResult = loaded
                    if loaded { fillTimeline.mark(.wordmark) }
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
                        .opacity(copyYieldsToTrailer || titleLogoPresentation != .logo ? 0 : 1)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(item.name)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityHidden(copyYieldsToTrailer || titleLogoPresentation != .logo)

                    trailerTitleText
                        .opacity(copyYieldsToTrailer || titleLogoPresentation == .text ? 1 : 0)
                        .accessibilityHidden(!copyYieldsToTrailer && titleLogoPresentation != .text)
                }
                .frame(
                    width: min(
                        heroSize.width * AppleDetailMetrics.landscapeTitleLogoWidthFraction,
                        overlayLogoMaxWidth
                    ),
                    height: copyYieldsToTrailer ? AppleDetailMetrics.landscapeTitleFontSize : overlayLogoMaxHeight,
                    alignment: .leading
                )
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: AppleDetailMetrics.trailerCrossfadeDuration),
                    value: copyYieldsToTrailer
                )
            } else {
                trailerTitleText
                    .opacity(titleLogoPresentation == .hidden ? 0 : 1)
                    .accessibilityHidden(titleLogoPresentation == .hidden)
            }

            titleMetadata
                .frame(width: actionColumnWidth, alignment: .leading)
            if hasPrimaryActionRow {
                primaryActionButtons
            }
            // The overlay hero (iPad and landscape) never drew this line, so
            // it did not appear with services added (full test 2026-09-30).
            AppleWatchProviderRow(providers: alsoAvailableProviders)
                .frame(width: actionColumnWidth, alignment: .leading)
            seasonDownloadStatus
            secondaryActionRow
        }
    }

    private var trailerTitleText: some View {
        Text(displayTitle)
            .font(.system(size: isLandscapeLayout ? scaledLandscapeTitleSize : scaledPortraitTitleSize, weight: .semibold))
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .shadow(color: .black.opacity(0.6), radius: 6, y: 1)
            .accessibilityAddTraits(.isHeader)
            .animation(
            reduceMotion ? nil : .easeInOut(duration: AppleDetailMetrics.trailerCrossfadeDuration),
                value: heroTrailer.isPlaying
            )
    }

    /// The iPad held upright: its title page opens on the iPad Discover
    /// hero's height with the copy over the art (`usesOverlayHero`, N37).
    /// It had been a box of art with the title under it (N32 #9).
    private var usesPadPortraitHero: Bool {
        #if os(iOS)
        horizontalSizeClass == .regular && !isLandscapeLayout
        #else
        false
        #endif
    }

    private var portraitTrailerTitle: some View {
        trailerTitleText
            .frame(height: heroTrailer.isPlaying ? 20 : 0, alignment: .leading)
            .clipped()
            .opacity(heroTrailer.isPlaying ? 1 : 0)
            .accessibilityHidden(!heroTrailer.isPlaying)
            .animation(
            reduceMotion ? nil : .easeInOut(duration: AppleDetailMetrics.trailerCrossfadeDuration),
                value: heroTrailer.isActive
            )
    }

    #if os(tvOS)
    // MARK: - Apple TV title page (FEEDBACK rework plan, task 5)

    /// Full-screen backdrop with the title block anchored bottom-leading at
    /// (80, bottom 60); scrolling down reveals the synopsis, Episodes and
    /// More Like This. There is no back control (Menu pops the page) and no
    /// Download action. The backdrop stays a still: the Apple TV plays no
    /// trailer (`AppleTitlePagePolicy.offersTrailers`), so there is no trailer
    /// button, rail or preview. Every number comes from `AppleTVDetailMetrics`.
    private var tvOSDetailLayout: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                AppleTitlePageTVHero(page: self)
                AppleTitlePageTVBelowFold(page: self)
            }
        }
        .scrollClipDisabled()
        .ignoresSafeArea()
        .defaultFocus($tvDetailFocus, tvOpeningFocusTarget, priority: .userInitiated)
        .task { await settleTVOpeningFocus() }
        .onChange(of: tvDetailFocus) { old, focus in
            let leftTitleRowAgo = tvTitleRowExit.map { ContinuousClock.now - $0 }
            tvTitleRowExit = old?.isOnTitleRow == true && focus == nil ? .now : nil
            guard !tvDetailOpeningSettled else {
                if let correction = AppleTVDetailReturnFocus.correction(
                    from: old, to: focus, leftTitleRowAgo: leftTitleRowAgo, target: tvOpeningFocusTarget
                ) ?? AppleTVDetailShelfEntry.correction(
                    from: old, to: focus, leftTitleRowAgo: leftTitleRowAgo,
                    firstSimilarID: suggestedItems.first?.id
                ) {
                    appleTrace("detail focus: \(String(describing: focus)) corrected to \(correction)")
                    tvDetailFocus = correction
                }
                return
            }
            if AppleTVDetailOpeningFocus.settles(on: focus, target: tvOpeningFocusTarget) {
                tvDetailOpeningSettled = true
            } else if let correction = AppleTVDetailOpeningFocus.correction(
                for: focus, hasHadAnyFocus: true, target: tvOpeningFocusTarget
            ) {
                tvDetailFocus = correction
            }
        }
        .onChange(of: tvOSShowsPlay) { _, showsPlay in
            // Play went away under focus (the episode list came back empty).
            if !showsPlay, tvDetailFocus == .play { tvDetailFocus = .myList }
        }
        .onChange(of: titleActions.rateChoicesExpanded) { _, expanded in
            if !expanded { tvDetailFocus = .rate }
        }
    }

    /// Asks for Play until it has held focus once: the first requests land
    /// while the push is still animating and are dropped.
    private func settleTVOpeningFocus() async {
        for _ in 0 ..< AppleTVDetailOpeningFocus.attempts {
            guard !tvDetailOpeningSettled, !Task.isCancelled else { return }
            if let correction = AppleTVDetailOpeningFocus.correction(
                for: tvDetailFocus, hasHadAnyFocus: false, target: tvOpeningFocusTarget
            ) {
                tvDetailFocus = correction
            }
            try? await Task.sleep(for: AppleTVDetailOpeningFocus.interval)
        }
        appleTrace("detail focus: the title row never took focus on open (focus=\(String(describing: tvDetailFocus)))")
    }

    var tvOSHero: some View {
        ZStack(alignment: .bottomLeading) {
            heroArtwork
                .frame(
                    width: AppleTVDetailMetrics.screenSize.width,
                    height: AppleTVDetailMetrics.screenSize.height
                )
                .clipped()
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: AppleTVDetailMetrics.backdropFadeStartFraction),
                            .init(color: .clear, location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .accessibilityHidden(true)
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
                if let watchOnAction {
                    tvOSWatchOnButton(watchOnAction)
                } else if tvOSShowsPlay {
                    tvOSPlayButton
                    if isDiscTitle {
                        tvOSSkipToMovieButton
                    }
                    if offersStartFromBeginning {
                        tvOSStartFromBeginningButton
                    }
                }
                tvOSIconRow
            }
        }
    }

    /// Same policy as the other platforms: the wordmark when it has loaded,
    /// the text title only if it fails, nothing while it resolves.
    @ViewBuilder
    private var tvOSTitleBlock: some View {
        if case .valid = titleWordmark.state, let logoURL = titleLogoURL {
            ZStack(alignment: .leading) {
                AppleTrimmedTitleLogo(url: logoURL, alignment: .leading) { loaded in
                    guard AppleTitleLogoPolicy.keepsLoadResult(loaded, shown: titleLogoPresentation) else { return }
                    titleWordmark.loadResult = loaded
                    if loaded { fillTimeline.mark(.wordmark) }
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

    /// No Play at all when nothing here can play (no trailers on the Apple
    /// TV), rather than one that is dead at rest (N22c).
    private var tvOSShowsPlay: Bool {
        titlePagePrimaryAction != nil || watchOnAction != nil
    }

    /// Watch on in Play's place, holding Play's focus slot. Several services
    /// push a page of them rather than a menu (`AppleTVWatchOnPage`).
    private func tvOSWatchOnButton(_ action: AppleWatchOnAction) -> some View {
        Button {
            switch action {
            case .single(let choice): openWatchOn(choice)
            case .menu: prompts.watchOnMenu = true
            }
        } label: {
            HStack(spacing: AppleTVDetailMetrics.pillGlyphSpacing) {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: AppleTVDetailMetrics.pillGlyphSize, weight: .semibold))
                Text(action.title)
            }
        }
        .buttonStyle(AppleTVPillStyle(
            isSelected: true,
            minimumSize: AppleTVDetailMetrics.pillSize,
            fontSize: AppleTVDetailMetrics.pillFontSize
        ))
        .focused($tvDetailFocus, equals: .play)
        .accessibilityLabel(action.title)
        .accessibilityHint(action.choices.count == 1 ? watchOnHint(action.choices[0]) : "")
        .accessibilityIdentifier("detail.watchOn")
    }

    private var tvOpeningFocusTarget: AppleTVDetailFocus {
        AppleTVDetailOpeningFocus.target(showsPlay: tvOSShowsPlay)
    }

    private var tvOSPlayIsBusy: Bool {
        playbackCoordinator.phase.isBusy || pageMetadata.isPreparing
    }

    /// Stays focusable while metadata prepares so the default focus lands on
    /// it immediately; the press is ignored until playback can start.
    private var tvOSPlayButton: some View {
        Button {
            guard canStartPlayback else { return }
            if isDiscTitle { startDisc(.menu) } else { playbackUI.request = UUID() }
        } label: {
            HStack(spacing: AppleTVDetailMetrics.pillGlyphSpacing) {
                if tvOSPlayIsBusy, isDiscTitle {
                    AppleDiscSpinner(tint: .black, size: AppleTVDetailMetrics.pillGlyphSize)
                } else if tvOSPlayIsBusy {
                    ProgressView().tint(.black)
                } else {
                    Image(systemName: "play.fill")
                        .font(.system(size: AppleTVDetailMetrics.pillGlyphSize, weight: .semibold))
                }
                // The page's own verb (Resume once there is a saved position):
                // this label was a literal "Play", so the Apple TV said Play
                // after watching whatever the progress key resolved to
                // (Apple TV check 2026-10-01).
                Text(tvOSPlayIsBusy ? (playbackCoordinator.phase.isBusy ? "Preparing" : "Loading") : regularPlayTitle)
            }
        }
        .buttonStyle(AppleTVPillStyle(
            isSelected: true,
            minimumSize: AppleTVDetailMetrics.pillSize,
            fontSize: AppleTVDetailMetrics.pillFontSize
        ))
        .focused($tvDetailFocus, equals: .play)
        .accessibilityLabel(tvOSPlayIsBusy ? "Preparing playback" : regularPlayTitle)
        .task(id: regularPlayTitle) { traceTitleProgress() }
        .accessibilityIdentifier("detail.play")
        .contextMenu {
            Button("Quality", systemImage: "slider.horizontal.3") {
                Task { await chooseStreams() }
            }
        }
    }

    /// Beside Play Disc, a quieter pill: the main feature, past the menu.
    private var tvOSSkipToMovieButton: some View {
        Button { startDisc(.mainTitle) } label: {
            HStack(spacing: AppleTVDetailMetrics.pillGlyphSpacing) {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: AppleTVDetailMetrics.pillGlyphSize, weight: .semibold))
                Text("Skip to Movie")
            }
        }
        .buttonStyle(AppleTVPillStyle(
            isSelected: false,
            minimumSize: AppleTVDetailMetrics.pillSize,
            fontSize: AppleTVDetailMetrics.pillFontSize
        ))
        .focused($tvDetailFocus, equals: .skipToMovie)
        .disabled(tvOSPlayIsBusy)
        .accessibilityIdentifier("detail.disc.skipToMovie")
    }

    /// Beside Resume, a quieter pill: the title or episode from the top.
    private var tvOSStartFromBeginningButton: some View {
        Button(action: startFromBeginning) {
            HStack(spacing: AppleTVDetailMetrics.pillGlyphSpacing) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: AppleTVDetailMetrics.pillGlyphSize, weight: .semibold))
                Text("Start from Beginning")
            }
        }
        .buttonStyle(AppleTVPillStyle(
            isSelected: false,
            minimumSize: AppleTVDetailMetrics.pillSize,
            fontSize: AppleTVDetailMetrics.pillFontSize
        ))
        .focused($tvDetailFocus, equals: .startFromBeginning)
        .disabled(tvOSPlayIsBusy)
        .accessibilityIdentifier("detail.startOver")
    }

    private var tvOSIconRow: some View {
        HStack(alignment: .appleTVControlCenter, spacing: 0) {
            Button(action: toggleFavorite) {
                AppleTVDetailIconLabel(title: "My List", systemImage: titleActions.isFavorite ? "checkmark" : "plus")
            }
            .buttonStyle(AppleTVBareButtonStyle())
            .focused($tvDetailFocus, equals: .myList)
            .accessibilityLabel(titleActions.isFavorite ? "Remove from My List" : "Add to My List")
            .accessibilityValue(titleActions.isFavorite ? "Saved" : "Not saved")
            tvOSRateControl
        }
        .accessibilityIdentifier("detail.icon-row")
    }

    /// Rate expands in place into the three choices at the same 120 pt pitch.
    @ViewBuilder
    private var tvOSRateControl: some View {
        if titleActions.rateChoicesExpanded {
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
                withAnimation(rateAnimation) { titleActions.rateChoicesExpanded = true }
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

    var tvOSBelowFold: some View {
        VStack(alignment: .leading, spacing: AppleTVDetailMetrics.sectionSpacing) {
            // Directly under the hero's Play/icon row above, in secondary
            // text, competing with nothing — easier to spot than buried in
            // the synopsis, but still not a second Play (owner 2026-09-28).
            AppleWatchProviderRow(providers: alsoAvailableProviders)
                .padding(.horizontal, AppleTVDetailMetrics.overlayLeadingInset)
            if let summary = AppleMetadataPresentationPolicy.synopsis(
                catalog: item.summary,
                enriched: pageMetadata.details?.overview
            ) {
                AppleTVFocusableParagraph(text: summary)
                    .padding(.horizontal, AppleTVDetailMetrics.overlayLeadingInset)
            }
            if item.type == "series" {
                tvOSEpisodeShelf
                    .id("vision-episodes")
            }
            if !discTitles.isEmpty {
                AppleDiscTitlesRow(titles: discTitles, horizontalInset: AppleTVDetailMetrics.overlayLeadingInset) {
                    startDisc(.mainTitle, titleID: $0.id)
                }
                .focusSection()
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
            } else if let season = episodeList.selectedSeason {
                Text(seasonName(season))
                    .font(.system(size: AppleTVDetailMetrics.seasonPillFontSize))
                    .foregroundStyle(AppleDesignTokens.textSecondary)
                    .padding(.horizontal, AppleTVDetailMetrics.overlayLeadingInset)
            }
            switch episodeListPresentation {
            case .loading:
                ProgressView()
                    .tint(.white)
                    .padding(.horizontal, AppleTVDetailMetrics.overlayLeadingInset)
            case .unavailable:
                Text("Episodes aren’t available from the connected metadata sources.")
                    .font(.system(size: AppleTVDetailMetrics.episodeTitleFontSize))
                    .foregroundStyle(AppleDesignTokens.textSecondary)
                    .padding(.horizontal, AppleTVDetailMetrics.overlayLeadingInset)
            case .episodes:
                let watched = watchedEpisodeIDs
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: AppleTVDetailMetrics.episodeCardGap) {
                        ForEach(visibleEpisodes) { episode in
                            AppleTVEpisodeCard(
                                episode: episode,
                                subtitle: episodeMetadata(episode),
                                isSelected: episodeList.selectedEpisodeID == episode.id,
                                isWatched: watched.contains(episode.id),
                                seriesBackdropURL: episodeFallbackStillURL
                            ) {
                                episodeList.selectedEpisodeID = episode.id
                                playbackUI.request = UUID()
                            }
                            .contextMenu { watchedMenuButton(episode, isWatched: watched.contains(episode.id)) }
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
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail.episodes")
    }

    private var tvOSCurrentSeason: Int {
        episodeList.selectedSeason ?? seasonNumbers.first ?? 1
    }

    /// One dropdown showing the current season instead of a pill per season
    /// (owner 16:28). A single-season title shows the label alone.
    @ViewBuilder
    private var tvOSSeasonRow: some View {
        if seasonNumbers.count > 1 {
            Menu {
                ForEach(AppleTVDetailMetrics.seasonMenuOrder(seasonNumbers, selected: tvOSCurrentSeason), id: \.self) { season in
                    Button {
                        episodeList.selectedSeason = season
                    } label: {
                        if episodeList.selectedSeason == season {
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
            // The picker is a pill at the leading edge; without a section as
            // wide as the rail, Up from any episode but the first missed it
            // and landed on the title row (N41 survey).
            .frame(maxWidth: .infinity, alignment: .leading)
            .focusSection()
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
                                playbackResolver: playbackResolver,
                                settings: settings,
                                openSettings: openSettings,
                                tabToolbar: tabToolbar
                            )
                        } label: {
                            AppleTVPosterCard(item: suggestion)
                        }
                        .buttonStyle(.borderless)
                        .focused($tvDetailFocus, equals: .similar(suggestion.id))
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

    /// The hero still that is on screen, handed to the trailer preview so its
    /// cover paints the same pixels the moment it is inserted.
    private var heroArtwork: some View {
        AppleRemoteImage(
            url: heroArtworkURL,
            placeholderSystemImage: "",
            onLoad: { image in
                heroStill.image = image
                heroStill.art = heroStill.art.settling(with: .loaded)
                fillTimeline.mark(.artwork)
            },
            onFailure: heroArtworkFailed,
            keepsImageWhileReloading: true
        )
    }

    private var slotArtWatcher: some View {
        Color.clear
            .task(id: item.id) {
                if slotArt.itemID != item.id { slotArt = AppleTitlePageSlotArtState(itemID: item.id) }
                lockSlotArtIfReady()
                try? await Task.sleep(for: AppleTitlePageSlotArt.deadline)
                guard !Task.isCancelled else { return }
                slotArt.deadlinePassed = true
                lockSlotArtIfReady()
            }
            .onChange(of: pageMetadata.details) { _, _ in lockSlotArtIfReady() }
            .accessibilityHidden(true)
    }

    /// Reruns the wordmark lookup when its candidates change or the page's
    /// details first answer. Built here: inline, the page's modifier chain
    /// went past the type checker's limit on visionOS.
    private var titleLogoTaskID: String {
        let candidates = titleLogoCandidates.map(\.absoluteString).joined(separator: "|")
        return "title-logo:\(titleMetadataAnswered):\(candidates)"
    }

    /// The page's details have answered, or the slot-art deadline passed.
    private var titleMetadataAnswered: Bool {
        AppleTitlePageSlotArt.isReady(detailsAnswered: pageMetadata.details != nil,
                                      deadlinePassed: slotArt.itemID == item.id && slotArt.deadlinePassed)
    }

    /// The iPhone header's art, once chosen; nil while the page is still
    /// finding out (black, then the final art).
    private var phoneSlotArt: AppleTitlePageSlotArt? {
        slotArt.itemID == item.id ? slotArt.chosen : nil
    }

    /// Chooses the iPhone header's art once, when the page knows enough.
    /// Only a failed load moves it on to the next candidate.
    private func lockSlotArtIfReady() {
        guard slotArt.itemID == item.id, slotArt.chosen == nil, titleMetadataAnswered else { return }
        slotArt.chosen = phoneSlotArtCandidate
        if let chosen = slotArt.chosen {
            appleTrace("title slot art \(chosen.isPosterCard ? "poster card" : "backdrop") (\(item.name))")
        } else {
            appleTrace("title slot art: none (\(item.name))")
            if usesPhoneTitlePage { heroStill.art = heroStill.art.settling(with: .failed) }
        }
    }

    private var phoneSlotArtCandidate: AppleTitlePageSlotArt? {
        AppleTitlePageSlotArt.choose(
            backdrops: [pageMetadata.details?.textlessBackdropURL, pageMetadata.details?.backdropURL,
                        item.backgroundURL, pageMetadata.fallbackArtwork?.backgroundURL],
            posters: [pageMetadata.details?.posterURL, item.posterURL, pageMetadata.fallbackArtwork?.posterURL],
            failed: slotArt.failed)
    }

    private func phoneSlotArtFailed() {
        guard let chosen = phoneSlotArt else { return }
        slotArt.failed.insert(chosen.url)
        slotArt.chosen = phoneSlotArtCandidate
        appleTrace("title slot art failed, \(slotArt.chosen == nil ? "none left" : "trying the next") (\(item.name))")
        if slotArt.chosen == nil {
            heroStill.image = nil
            heroStill.art = heroStill.art.settling(with: .failed)
        }
    }

    /// The art that failed is skipped for the next candidate; only when none
    /// is left is the art failed for good.
    private func heroArtworkFailed() {
        if let url = heroArtworkURL {
            failedHeroArtworkURLs.insert(url)
            if let next = heroArtworkURL {
                #if DEBUG
                appleTrace("title hero art failed, trying \(AppleCatalogArtworkPolicy.traceID(next)) (\(item.name))")
                #else
                _ = next
                #endif
                return
            }
        }
        appleTrace("title hero art failed: none left (\(item.name))")
        heroStill.image = nil
        heroStill.art = heroStill.art.settling(with: .failed)
    }

    /// Landscape art only: a poster cropped to 16:9 reads worse than the
    /// placeholder it replaces.
    private var episodeFallbackStillURL: URL? {
        pageMetadata.details?.backdropURL ?? item.backgroundURL ?? pageMetadata.fallbackArtwork?.backgroundURL
    }

    /// The first art that has not failed, in the order the page prefers it.
    /// It took only the first that existed: a catalog backdrop that 404s
    /// (metahub has none for new titles) left the hero black under the
    /// copy, and black again once a trailer ended — "back to the art" with
    /// no art (iOS 18.6 regression 2026-10-01, screens 14/16).
    private var heroArtworkURL: URL? {
        AppleTitlePagePolicy.heroArtworkURL(candidates: [
            pageMetadata.details?.backdropURL,
            item.backgroundURL,
            pageMetadata.details?.posterURL,
            item.posterURL,
            pageMetadata.fallbackArtwork?.backgroundURL,
            pageMetadata.fallbackArtwork?.posterURL
        ], failed: failedHeroArtworkURLs)
    }

    private var displayTitle: String {
        pageMetadata.details?.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? pageMetadata.details?.title ?? item.name
            : item.name
    }

    private var displayReleaseInfo: String? {
        let value = pageMetadata.details?.releaseInfo ?? item.releaseInfo
        let clean = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return clean.isEmpty ? nil : clean
    }

    /// The wordmark that passed validation, once one has.
    private var titleLogoURL: URL? {
        if case .valid(let url) = titleWordmark.state { return url }
        return nil
    }

    /// Every wordmark this title has, best first: TMDB's, the add-on's (the
    /// one the Discover hero draws), then the catalog record's.
    private var titleLogoCandidates: [URL] {
        var seen = Set<URL>()
        return [pageMetadata.details?.logoURL, pageMetadata.previewAssets?.logoURL, item.logoURL]
            .compactMap { $0 }
            .filter { seen.insert($0).inserted }
    }

    private var trailerEmbedURL: URL? {
        AppleTrailerPreviewPolicy.embedURL(for: trailerKey)
    }

    private var trailerKey: String? {
        AppleTrailerArtFirstPolicy.heroTrailerKey(
            pinned: heroTrailer.pinnedKey, gaveUp: heroTrailer.gaveUp, candidates: trailerCandidates
        )
    }

    private var trailerCandidates: [String] {
        #if DEBUG
        // Deterministic embed-error checks on the existing simulators.
        if let keys = UserDefaults.standard.string(forKey: "OpenStreamDebugTrailerKeys") {
            return keys.split(separator: ",").compactMap { AppleTrailerPreviewPolicy.validYouTubeKey(String($0)) }
        }
        #endif
        let keys = (pageMetadata.details?.trailerYouTubeKeys ?? [])
            + (pageMetadata.previewAssets?.trailerYouTubeKeys ?? [])
        var seen = Set<String>()
        return keys.filter { seen.insert($0).inserted }
    }

    /// Whether pressing the hero still can start a trailer. Until the
    /// metadata has named one, after every candidate has failed, and on Apple
    /// TV (no YouTube embed) the press did nothing at all while the still
    /// still read as a "Play preview" button (ui-smoke 20260923-2209). Once
    /// the trailer's own layer is up it covers the still, and its touch
    /// shield (`detail.trailer.toggle`, silent until the video is on
    /// screen — trailers are art-first) takes the presses instead.
    private var heroTrailerCanPlay: Bool {
        #if os(iOS) || os(visionOS)
        trailerEmbedURL != nil && !heroTrailer.hasStarted
        #else
        false
        #endif
    }

    /// A press on the hero still starts the trailer — present only while
    /// one can start. It sits over the still rather than wrapping it, so the
    /// still keeps its identity (and its decoded image) as the button comes
    /// and goes; toggling `accessibilityHidden` on a wrapping button left a
    /// "Play preview" that refused touches in the accessibility tree.
    @ViewBuilder
    private var heroTrailerStartButton: some View {
        if heroTrailerCanPlay {
            Button(action: toggleTrailerPlayback) {
                Color.clear.contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play preview")
        }
    }

    /// The same test `trailerPreview` draws by.
    /// The trailer's web view — its request — only goes in once the hero
    /// still has settled; until then a started trailer waits, unseen.
    private var trailerPreviewIsShown: Bool {
        heroTrailer.hasStarted && trailerEmbedURL != nil
            && AppleTrailerArtFirstPolicy.mayRequestTrailer(art: heroStill.art, pressed: true)
            && !playbackCoordinator.phase.isBusy && playbackUI.presentation == nil
    }

    /// Never on the Apple TV, which plays no trailer — so its title page
    /// never probes or resolves one either. The Mac's plays by itself as its
    /// Discover hero does (N69, owner 2026-09-25).
    private var allowsTrailerAutoplay: Bool {
        #if os(visionOS)
        AppleTrailerPreviewPolicy.titlePageAutoplays(on: .vision, setting: settings.autoPlayTrailer, reduceMotion: reduceMotion)
        #elseif os(iOS)
        AppleTrailerPreviewPolicy.titlePageAutoplays(
            on: .phoneOrPad, setting: settings.autoPlayTrailer, reduceMotion: reduceMotion,
            systemVideoAutoplayEnabled: systemVideoAutoplayEnabled
        )
        #elseif os(macOS)
        usesMacTitlePage
            && AppleTrailerPreviewPolicy.titlePageAutoplays(on: .mac, setting: settings.autoPlayTrailer, reduceMotion: reduceMotion)
        #else
        AppleTrailerPreviewPolicy.titlePageAutoplays(on: .tv, setting: settings.autoPlayTrailer, reduceMotion: reduceMotion)
        #endif
    }

    /// Automatic and one row per resolution this device can play — no
    /// codecs, containers or source names (owner 2026-09-24). A resolution
    /// plays its best candidate for this device, falling to the nearest one.
    private var streamPicker: some View {
        let tiers = AppleStremioCandidateRanking.qualityTiers(playbackUI.streamChoices, device: .current)
        return NavigationStack {
            List {
                Button {
                    choosePlaybackQuality(nil)
                } label: {
                    qualityRowLabel("Automatic", badges: qualityRowBadges(.automatic))
                }
                .accessibilityIdentifier("detail.quality.automatic")
                ForEach(tiers, id: \.self) { tier in
                    Button {
                        choosePlaybackQuality(tier)
                    } label: {
                        qualityRowLabel(tier.title, badges: qualityRowBadges(.tier(tier)))
                    }
                    .accessibilityIdentifier("detail.quality.\(tier.title)")
                }
            }
            .scrollIndicators(AppleDesignTokens.scrollIndicatorVisibility)
            .navigationTitle("Quality")
            #if os(iOS) || os(visionOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { prompts.streamPicker = false }
                        .accessibilityIdentifier("detail.quality.done")
                }
            }
            #elseif os(macOS)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { prompts.streamPicker = false } }
            }
            #endif
        }
        #if os(macOS)
        .frame(width: 360, height: 300)
        #endif
        .presentationDetents([.medium])
    }

    /// A Quality row: the resolution, then the format badges of the stream
    /// it plays (Dolby Vision, Atmos, 5.1, Remux).
    private func qualityRowLabel(_ title: String, badges: [AppleStreamFormatBadge]) -> some View {
        HStack(spacing: 8) {
            Text(title)
            if !badges.isEmpty { AppleStreamFormatBadgeInline(badges: badges) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func choosePlaybackQuality(_ tier: AppleStreamQualityTier?) {
        playbackUI.selectedLocalFile = nil
        playbackUI.selectedQuality = tier
        prompts.streamPicker = false
        playbackUI.request = UUID()
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
        let shouldPlay = !heroTrailer.isActive
        if shouldPlay, !prepareTrailerAudio() { return }
        if !shouldPlay { heroTrailer.pressedKey = nil }
        if shouldPlay, heroTrailer.pinnedKey == nil { heroTrailer.pinnedKey = trailerKey }
        heroTrailer.hasStarted = true
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
            heroTrailer.isActive = shouldPlay
            heroTrailer.isPlaying = false
        }
        if isLandscapeLayout {
            showTrailerInteractionGlyph(shouldPlay ? "play.circle.fill" : "pause.circle.fill")
        }
        #endif
    }

    /// The sound control over a playing trailer (owner items 2 and 3).
    private func toggleTrailerSound() {
        let next = AppleTrailerSoundBridge.tapped(isMuted: heroTrailer.muted, allowsSound: heroTrailer.allowsSound)
        if !next.isMuted, !prepareTrailerAudio(pressed: true) { return }
        heroTrailer.allowsSound = next.allowsSound
        heroTrailer.muted = next.isMuted
        appleTrace("trailer sound \(next.isMuted ? "off" : "on") (sound control)")
    }

    private func restartTrailer() {
        guard trailerEmbedURL != nil, prepareTrailerAudio(pressed: heroTrailer.allowsSound) else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: AppleDetailMetrics.trailerCrossfadeDuration)) {
            heroTrailer.isActive = true
            heroTrailer.isPlaying = false
        }
        heroTrailer.replayGeneration &+= 1
    }

    private func pauseTrailerPreview(reason: String) {
        guard heroTrailer.isActive else { return }
        appleTrace("title trailer paused: \(reason) (\(item.name))")
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
            heroTrailer.isActive = false
            heroTrailer.isPlaying = false
        }
    }

    private func detailHeroFrameChanged(_ frame: CGRect) {
        #if os(iOS) || os(macOS)
        // Rotation can briefly report a stale frame. Stop only after the
        // hero has actually scrolled above the viewport.
        if frame != .zero, frame.maxY <= 0, heroTrailer.isActive { pauseTrailerPreview(reason: "hero scrolled off, maxY=\(Int(frame.maxY))") }
        // At the top the hero runs up under the toolbar, by the top inset.
        let atTop = frame.minY >= -pageGeometry.safeAreaInsets.top - 1
        if frame != .zero, atTop != heroTrailer.heroAtTop {
            #if DEBUG
            appleTrace("title hero minY=\(Int(frame.minY)) atTop=\(atTop)")
            #endif
            heroTrailer.heroAtTop = atTop
        }
        #endif
    }

    private func prepareTrailerAudio(pressed: Bool = false) -> Bool {
        #if os(iOS) || os(visionOS)
        ApplePlaybackSessionPolicy.prepareTrailerAudio(pressed: pressed)
        #elseif os(macOS)
        // No audio session to set up; the Mac title page's hero plays it.
        usesMacTitlePage
        #else
        false
        #endif
    }

    private func handleTrailerState(_ state: String, muted: Bool, errorCode: Int?) {
        print("[OpenStream] trailer title=\(item.name) key=\(trailerKey ?? "none") state=\(state) error=\(errorCode.map(String.init) ?? "none") active=\(heroTrailer.isActive)")
        if state == AppleTrailerArtFirstPolicy.webContentTerminatedState {
            // No next candidate: the web view itself died, not the video.
            heroTrailer.failedKeys.formUnion(trailerCandidates)
            heroTrailer.gaveUp = true
            showTrailerArtworkOnly()
            logTrailerFailure("the trailer's web content process stopped")
            return
        }
        if state == "error" || state == "autoplay-blocked" {
            let failedKey = trailerKey
            if let failedKey { heroTrailer.failedKeys.insert(failedKey) }
            heroTrailer.isActive = false
            heroTrailer.isPlaying = false
            let candidates = trailerCandidates
            let nextIndex = AppleTrailerArtFirstPolicy.nextCandidateStart(after: failedKey, in: candidates)
            let code = errorCode.map(String.init) ?? "none"
            if nextIndex < candidates.count {
                Task { @MainActor in
                    let next = await resolvePlayableTrailerKey(startingAt: nextIndex)
                    // A Trailers card pressed while this looked for the next
                    // key has already chosen what plays; leave it be.
                    guard heroTrailer.pinnedKey == failedKey || heroTrailer.pinnedKey == nil else {
                        appleTrace("title trailer error=\(code) key=\(failedKey ?? "none"): another trailer was chosen meanwhile")
                        return
                    }
                    guard let next else {
                        appleTrace("title trailer error=\(code) key=\(failedKey ?? "none"): no playable key left, giving up")
                        heroTrailer.gaveUp = true
                        showTrailerArtworkOnly()
                        logTrailerFailure("video provider could not play this trailer (error \(errorCode.map(String.init) ?? "unknown"))")
                        return
                    }
                    appleTrace("title trailer error=\(code) key=\(failedKey ?? "none"): trying key=\(next)")
                    heroTrailer.pinnedKey = next
                    heroTrailer.isActive = true
                }
            } else {
                appleTrace("title trailer error=\(code) key=\(failedKey ?? "none") (\(candidates.count) candidates): giving up")
                heroTrailer.gaveUp = true
                showTrailerArtworkOnly()
                logTrailerFailure("video provider could not play this trailer (error \(errorCode.map(String.init) ?? "unknown"))")
            }
            return
        }
        heroTrailer.muted = muted
        if state == "revealed", heroTrailer.isActive {
            heroTrailer.isPlaying = true
            heroTrailer.pressedKey = nil
        } else if state == "concealed" {
            heroTrailer.isPlaying = false
        } else if state == "paused" {
            appleTrace("title trailer paused by the player: back to the art (\(item.name), active=\(heroTrailer.isActive))")
            heroTrailer.isActive = false
            heroTrailer.isPlaying = false
        } else if AppleTrailerArtFirstPolicy.leavesForTheArt(forPlayerState: state) {
            // Finished: the art crossfades back and the video layer goes, so
            // the page's own still is what stays. Pressing the art plays the
            // same trailer again.
            appleTrace("title trailer ended: back to the art (\(item.name))")
            showTrailerArtworkOnly()
        }
    }

    /// Back to the art, crossfading over whatever the player showed, and
    /// nothing said: a trailer that cannot play simply is not there.
    private func showTrailerArtworkOnly() {
        withAnimation(.easeInOut(duration: AppleTrailerArtFirstPolicy.crossfadeDuration(reduceMotion: reduceMotion))) {
            heroTrailer.hasStarted = false
            heroTrailer.isActive = false
        }
        heroTrailer.isPlaying = false
        heroTrailer.pressedKey = nil
        heroTrailer.interactionGeneration &+= 1
        heroTrailer.interactionGlyph = nil
    }

    /// The first key from `index` on that is neither a known failure nor a
    /// portrait clip, as a key: the list can change while frames are probed.
    private func resolvePlayableTrailerKey(startingAt index: Int) async -> String? {
        let keys = trailerCandidates
        var searchIndex = index
        while let candidateIndex = AppleTrailerPreviewPolicy.firstPlayableCandidate(
            keys,
            portraitKeys: heroTrailer.portraitKeys.union(heroTrailer.failedKeys),
            startingAt: searchIndex
        ) {
            guard !Task.isCancelled else { return nil }
            let key = keys[candidateIndex]
            appleTrace("title trailer candidate \(candidateIndex + 1)/\(keys.count) key=\(key)")
            if !heroTrailer.landscapeKeys.contains(key) {
                await probeTrailerFrameAspect(for: key)
            }
            guard !Task.isCancelled else { return nil }
            if heroTrailer.portraitKeys.contains(key) {
                searchIndex = candidateIndex + 1
                continue
            }
            return key
        }
        return nil
    }

    private func probeTrailerFrameAspect(for key: String) async {
        guard let url = AppleTrailerPreviewPolicy.frameProbeURL(for: key) else {
            heroTrailer.landscapeKeys.insert(key)
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
                heroTrailer.landscapeKeys.insert(key)
                return
            }
            if AppleTrailerPreviewPolicy.isPortraitFrame(CGSize(width: width, height: height)) {
                heroTrailer.portraitKeys.insert(key)
            } else {
                heroTrailer.landscapeKeys.insert(key)
            }
        } catch {
            heroTrailer.landscapeKeys.insert(key)
        }
    }

    private func logTrailerFailure(_ reason: String) {
        appleTrace("title trailer unavailable: \(item.name) reason=\(reason)")
        print("[OpenStream] trailer unavailable title=\(item.name) key=\(trailerKey ?? "none") reason=\(reason)")
    }

    private func showTrailerInteractionGlyph(_ glyph: String) {
        heroTrailer.interactionGeneration &+= 1
        let generation = heroTrailer.interactionGeneration
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
            heroTrailer.interactionGlyph = glyph
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1_200))
            guard !Task.isCancelled, generation == heroTrailer.interactionGeneration else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                heroTrailer.interactionGlyph = nil
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
            ForEach(titleMetadataStreamBadges, id: \.self) { badge in
                AppleFormatBadge(text: badge)
            }
        }
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
            .minimumScaleFactor(0.68)
            .frame(maxWidth: .infinity, alignment: .leading)
            .font(.system(size: scaledMetadataSize, weight: .regular))
            .foregroundStyle(titleMetadataColor)
            .shadow(color: .black.opacity(0.6), radius: 6, y: 1)
            .accessibilityElement(children: .combine)
    }

    /// The tvOS line always sits on artwork, so it is always light; the
    /// simulator's light appearance otherwise painted it black on the art.
    private var titleMetadataColor: Color {
        #if os(tvOS)
        .white
        #else
        colorScheme == .dark ? .white.opacity(0.60) : .black.opacity(0.60)
        #endif
    }

    private var titleMetadataBadges: [String] {
        AppleTitleMetadataPresentation.orderedBadges(
            contentRating: pageMetadata.details?.contentRating ?? item.contentRating,
            formatBadges: pageMetadata.details?.formatBadges ?? item.formatBadges ?? [],
            limit: AppleDetailMetrics.maxBadgeCount
        )
    }

    /// The stream's format badges after the catalog's own, none twice.
    private var titleMetadataStreamBadges: [String] {
        AppleStreamFormatBadge.titles(titlePageStreamBadges, excludingCatalogBadges: titleMetadataBadges)
    }

    private var titleMetadataTextValues: [String] {
        AppleTitleMetadataPresentation.textValues(
            genres: pageMetadata.details?.genres ?? [],
            releaseInfo: displayReleaseInfo,
            runtimeMinutes: pageMetadata.details?.runtimeMinutes
        )
    }

    private var downloadLabel: String {
        if item.type == "series", episodeList.selectedEpisodeID != nil {
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

    /// The Download Options / Season Download Options choices for the
    /// current download (`AppleDownloadOptionChoice.choices`).
    private func downloadOptionChoices(season: Bool) -> [AppleDownloadOptionChoice] {
        #if DEBUG
        if prompts.optionsPreview {
            return AppleDownloadOptionChoice.choices(
                for: .downloading(item: item.name, destination: "", received: 0, expected: nil),
                supportsPauseResume: true, season: season)
        }
        #endif
        return AppleDownloadOptionChoice.choices(
            for: downloadCoordinator.state,
            supportsPauseResume: downloadCoordinator.supportsPauseResume,
            season: season)
    }

    private func performDownloadOption(_ choice: AppleDownloadOptionChoice) {
        prompts.downloadActions = false
        prompts.seasonDownloadActions = false
        #if DEBUG
        // The preview has no download behind it: a choice only closes it.
        if prompts.optionsPreview {
            prompts.optionsPreview = false
            return
        }
        #endif
        switch choice {
        case .pause: downloadCoordinator.pause()
        case .resume: downloadCoordinator.resume()
        case .cancelDownload: downloadCoordinator.cancel()
        case .cancelSeasonDownload:
            seasonDownloads.cancel()
            downloadCoordinator.cancel()
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
        guard let id = episodeList.selectedEpisodeID,
              let episode = episodeList.episodes.first(where: { $0.id == id }) else { return "episode" }
        return episodeNumber(episode).replacingOccurrences(of: " ", with: ":")
    }

    private var selectedEpisodeSelection: AppleStremioEpisodeSelection? {
        guard let selectedEpisodeID = episodeList.selectedEpisodeID,
              let episode = episodeList.episodes.first(where: { $0.id == selectedEpisodeID }) else { return nil }
        return AppleStremioEpisodeSelection(
            seriesMediaID: pageMetadata.resolvedMediaID ?? item.mediaID,
            episode: episode
        )
    }

    private var selectedPlaybackMediaID: String {
        selectedEpisodeSelection?.mediaID ?? pageMetadata.resolvedMediaID ?? item.mediaID
    }

    /// Play, Play Trailer, or nothing (`titlePagePrimaryAction`); the row
    /// closes up around a missing one.
    @ViewBuilder
    private var primaryPlayButton: some View {
        if let watchOnAction {
            watchOnControl(watchOnAction) {
                AppleDetailActionButtonLabel(title: watchOnAction.title, glyph: .systemImage("arrow.up.forward.app"),
                                             kind: .play, width: actionButtonWidth)
            }
            .buttonStyle(.plain)
        } else {
            titlePagePlayButton
        }
    }

    /// One service is a button, several are a menu; both are the same
    /// control on the iPhone, iPad, Vision Pro and Mac. The caller sets the
    /// button style, which the menu's label takes too.
    @ViewBuilder
    private func watchOnControl<Label: View>(_ action: AppleWatchOnAction,
                                             @ViewBuilder label: () -> Label) -> some View {
        switch action {
        case .single(let choice):
            Button { openWatchOn(choice) } label: { label() }
                .accessibilityLabel(choice.title)
                .accessibilityHint(watchOnHint(choice))
                .accessibilityIdentifier("detail.watchOn")
        case .menu(let choices):
            Menu {
                ForEach(choices) { choice in
                    Button(choice.service.displayName) { openWatchOn(choice) }
                        .accessibilityLabel(choice.title)
                        .accessibilityHint(watchOnHint(choice))
                        .accessibilityIdentifier("detail.watchOn.\(choice.id)")
                }
            } label: {
                label()
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .accessibilityLabel(action.title)
            .accessibilityIdentifier("detail.watchOn")
        }
    }

    @ViewBuilder
    private var titlePagePlayButton: some View {
        switch titlePagePrimaryAction {
        case nil:
            EmptyView()
        case .playTrailer?:
            AppleDetailActionButton(title: "Play Trailer", glyph: .systemImage("play.fill"),
                                    kind: .play, width: actionButtonWidth) {
                if let key = trailerKey { playTrailerInHero(key: key) }
            }
            .accessibilityIdentifier("detail.play")
        default:
            regularPlayButton
        }
    }

    /// "Resume" (with the episode) once there is a saved position, as the
    /// phone's button already says; the Apple TV page said Play after
    /// watching (Apple TV regression 2026-10-01).
    private var regularPlayTitle: String {
        if isDiscTitle { return "Play Disc" }
        if case .resume? = titlePagePrimaryAction, let titlePagePrimaryAction {
            return titlePagePrimaryAction.title
        }
        return downloadCoordinator.state.isCompleted ? "Play Offline" : "Play"
    }

    /// Beside Play Disc: straight into the main feature, past the menu.
    private var skipToMovieButton: some View {
        AppleDetailActionButton(title: "Skip to Movie", glyph: .systemImage("forward.end.fill"),
                                kind: .download, width: actionButtonWidth) {
            startDisc(.mainTitle)
        }
        .disabled(!canStartPlayback || playbackCoordinator.phase.isBusy)
        .accessibilityIdentifier("detail.disc.skipToMovie")
    }

    private var regularPlayButton: some View {
        AppleDetailActionButton(
            title: playbackCoordinator.phase.isBusy || pageMetadata.isPreparing
                ? (playbackCoordinator.phase.isBusy ? "Preparing" : "Loading")
                : regularPlayTitle,
            glyph: playbackCoordinator.phase.isBusy || pageMetadata.isPreparing
                ? (isDiscTitle ? .disc : .progress) : .systemImage("play.fill"),
            kind: .play,
            width: actionButtonWidth
        ) {
            if isDiscTitle { startDisc(.menu) } else { playbackUI.request = UUID() }
        }
        .disabled(!canStartPlayback)
        .accessibilityLabel(
            playbackCoordinator.phase.isBusy || pageMetadata.isPreparing
                ? "Preparing playback"
                : regularPlayTitle
        )
        .accessibilityIdentifier("detail.play")
        .contextMenu {
            playButtonMenuItems
        }
    }

    @ViewBuilder
    private var secondaryActionButtons: some View {
        VStack(alignment: .leading, spacing: 0) {
            if hasPrimaryActionRow {
                primaryActionButtons
            }
            // Directly under Play/Trailer, in secondary text — easier to
            // spot than buried in the synopsis, but still not a second Play
            // (owner 2026-09-28).
            AppleWatchProviderRow(providers: alsoAvailableProviders)
                .padding(.top, hasPrimaryActionRow ? AppleDetailMetrics.buttonsToIconRowSpacing : 0)
            seasonDownloadStatus
            secondaryActionRow
                .padding(.top, hasPrimaryActionRow ? AppleDetailMetrics.buttonsToIconRowSpacing : 0)
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
                    - pageGeometry.safeAreaInsets.leading
                    - pageGeometry.safeAreaInsets.trailing
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

    /// Whether the Play / Download row has anything in it.
    private var hasPrimaryActionRow: Bool {
        titlePagePrimaryAction != nil || watchOnAction != nil || showsDownloadAction
    }

    private var actionButtonWidth: CGFloat {
        showsDownloadAction && (titlePagePrimaryAction != nil || watchOnAction != nil)
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
            if isDiscTitle, watchOnAction == nil {
                skipToMovieButton
            }
            if showsDownloadAction {
                downloadActionButton
            }
        }
    }

    @ViewBuilder
    private var seasonDownloadStatus: some View {
        if item.type == "series", !visibleEpisodes.isEmpty, seasonDownloads.total > 0 {
            HStack {
                Text("\(offlineState.downloadSeason.map(seasonName) ?? "Season"): \(seasonDownloads.completed) of \(seasonDownloads.total) downloaded")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if seasonDownloads.isRunning {
                    Button { seasonDownloads.cancel(); downloadCoordinator.cancel() } label: {
                        Text("Cancel")
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(.rect)
                    }
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
            detailIconAction("My List", systemImage: titleActions.isFavorite ? "checkmark" : "plus", action: toggleFavorite)
                .accessibilityLabel(titleActions.isFavorite ? "Remove from My List" : "Add to My List")
                .accessibilityValue(titleActions.isFavorite ? "Saved" : "Not saved")
            rateControl
        }
        .frame(
            width: dynamicTypeSize.isAccessibilitySize ? nil : primaryActionRowWidth,
            alignment: .leading
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("My List, Rate")
        .accessibilityIdentifier("detail.icon-row")
    }

    @ViewBuilder
    private var downloadActionButton: some View {
        AppleDetailActionButton(
            title: downloadButtonLabel,
            glyph: downloadGlyph,
            kind: .download,
            width: actionButtonWidth,
            action: performDownloadAction
        )
        .disabled(pageMetadata.isPreparing || downloadCoordinator.state.isCompleted)
        .accessibilityIdentifier(item.type == "series" && !visibleEpisodes.isEmpty ? "detail.download.season" : "detail.download")
        .accessibilityLabel(downloadButtonLabel)
        .accessibilityValue(offlineAccessibilityValue)
    }

    /// Download, or its options while one runs: the season for a series, the
    /// title otherwise.
    private func performDownloadAction() {
        if item.type == "series", !visibleEpisodes.isEmpty {
            if seasonDownloads.isRunning {
                prompts.seasonDownloadActions = true
            } else {
                startSeasonDownload()
            }
        } else {
            switch downloadCoordinator.state {
            case .resolving, .downloading, .resuming, .paused:
                prompts.downloadActions = true
            case .idle, .failed, .cancelled:
                startDownload()
            default:
                break
            }
        }
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
            return "Download \(episodeList.selectedSeason.map(seasonName) ?? "Season")"
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
            .frame(minWidth: 44, minHeight: max(44, scaledIconRowHeight))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
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
            Picker("Season", selection: $episodeList.selectedSeason) {
                ForEach(seasonNumbers, id: \.self) { season in
                    Text(seasonName(season)).tag(Optional(season))
                }
            }
            .pickerStyle(.menu)
            .appleVisionActionTarget()
            .accessibilityIdentifier("detail.season")
        } else if let season = episodeList.selectedSeason {
            Text(seasonName(season))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private var episodeListPresentation: AppleEpisodeListPresentation {
        AppleEpisodeListPresentation.resolve(
            episodeCount: episodeList.episodes.count,
            isLoading: episodeList.isLoading,
            hasFinishedLoading: episodeList.loadFinished
        )
    }

    private var episodeSection: some View {
        VStack(alignment: .leading, spacing: AppleDetailMetrics.sectionHeaderBottomSpacing) {
            episodeSectionHeader

            if episodeListPresentation == .loading {
                VStack(spacing: 10) {
                    episodePlaceholderRow
                    episodePlaceholderRow
                }
                .redacted(reason: .placeholder)
            } else if episodeListPresentation == .unavailable {
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
                    let watched = watchedEpisodeIDs
                    ForEach(visibleEpisodes) { episode in
                        episodeRow(episode, isWatched: watched.contains(episode.id))
                    }
                }
            } else {
                let watched = watchedEpisodeIDs
                LazyVStack(spacing: 0) {
                    ForEach(visibleEpisodes) { episode in
                        episodeRow(episode, isWatched: watched.contains(episode.id))

                        if episode.id != visibleEpisodes.last?.id {
                            Divider().overlay(.white.opacity(0.12))
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail.episodes")
    }

    /// The title `startDownload(episode:)` hands the coordinator, so a row can
    /// tell its own download from another episode's.
    private func episodeDownloadTitle(_ episode: AppleStremioEpisode) -> String {
        AppleStremioEpisodeSelection(seriesMediaID: pageMetadata.resolvedMediaID ?? item.mediaID, episode: episode)?.displayTitle
            ?? episode.displayTitle
    }

    private func episodeDownloadIndicator(for episode: AppleStremioEpisode) -> AppleEpisodeDownloadIndicator {
        AppleEpisodeDownloadIndicator.resolve(
            episodeTitle: episodeDownloadTitle(episode),
            coordinatorState: downloadCoordinator.state,
            isDownloaded: offlineState.downloadedEpisodeIDs.contains(episode.id))
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

    private func episodeRow(_ episode: AppleStremioEpisode, isWatched: Bool) -> some View {
        HStack(spacing: 0) {
            Button {
                episodeList.selectedEpisodeID = episode.id
                playbackUI.request = UUID()
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
                    .overlay(alignment: .bottomTrailing) {
                        if isWatched {
                            Image(systemName: "checkmark.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.black, .white)
                                .font(.footnote)
                                .padding(4)
                        }
                    }
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
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(AppleDetailRowButtonStyle())
            .appleHoverAffordance()
            .accessibilityLabel("Play \(episode.displayTitle)")
            .accessibilityValue([episodeNumber(episode), isWatched ? "Watched" : nil,
                                 episodeList.selectedEpisodeID == episode.id ? "selected" : nil].compactMap { $0 }.joined(separator: ", "))
            .accessibilityAddTraits(episodeList.selectedEpisodeID == episode.id ? .isSelected : [])
            .contextMenu { watchedMenuButton(episode, isWatched: isWatched) }
            episodeDownloadButton(episode)
                .padding(.trailing, 8)
        }
    }

    /// The per-episode download control; none for a library title or where
    /// downloads are not offered.
    @ViewBuilder
    private func episodeDownloadButton(_ episode: AppleStremioEpisode) -> some View {
        #if os(iOS) || os(macOS)
        if localGroup == nil,
           AppleTitlePagePolicy.showsEpisodeDownload(offersDownload: offersDownload,
                                                     isDownloaded: offlineState.downloadedEpisodeIDs.contains(episode.id)) {
            Button {
                if seasonDownloads.isRunning {
                    prompts.seasonDownloadActions = true
                } else if downloadCoordinator.state.ownsDownload {
                    prompts.downloadActions = true
                } else {
                    episodeList.selectedEpisodeID = episode.id
                    startDownload(episode: episode)
                }
            } label: {
                episodeDownloadGlyph(episodeDownloadIndicator(for: episode))
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .disabled(pageMetadata.isPreparing || downloadCoordinator.state.isCompleted)
            .accessibilityLabel(episodeDownloadIndicator(for: episode).accessibilityLabel(episodeTitle: episodeDownloadTitle(episode)))
            .accessibilityIdentifier("detail.episode.download")
        }
        #endif
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

    private func moreLikeThisSection(title: String) -> some View {
        VStack(alignment: .leading, spacing: AppleDetailMetrics.sectionHeaderBottomSpacing) {
            Text(title)
                .font(.title2.bold())
                .padding(.leading, detailHorizontalInset)
                .accessibilityAddTraits(.isHeader)

            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: isLandscapeRegularLayout || horizontalSizeClass == .regular ? 10 : 8) {
                    suggestedCards()
                }
                .appleShelfSnapTargets()
                .padding(.vertical, 8)
                // Leading only: the first card lines up with the heading and the
                // last one runs off the edge, which is what says "keep scrolling".
                #if !os(iOS)
                .padding(.leading, detailHorizontalInset)
                #endif
            }
            #if os(iOS)
            // A content margin, which the whole-tile snap lands on (N65).
            .contentMargins(.leading, detailHorizontalInset, for: .scrollContent)
            #endif
            .appleShelfTileSnapping()
            .scrollIndicators(.never)
        }
        .accessibilityIdentifier("detail.more-like-this")
    }

    /// `sizing` is the detail page's own suggestion card, or `.catalog` for
    /// the Mac title page's Related rail, which draws the Discover poster.
    @ViewBuilder
    private func suggestedCards(sizing: AppleCatalogCardSizing = .detailSuggestions) -> some View {
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
                    playbackResolver: playbackResolver,
                    settings: settings,
                    openSettings: openSettings,
                    tabToolbar: tabToolbar
                )
            } label: {
                AppleCatalogCard(
                    item: suggestion,
                    sizing: sizing,
                    viewportWidth: viewportSize.width
                )
            }
            .accessibilityIdentifier("detail.similar.\(suggestion.id)")
        }
    }

    private var suggestedItems: [AppleCatalogItem] { pageMetadata.rankedSuggestions }

    /// Ranks the in-memory catalog against this title on genre, synopsis
    /// keywords, cast and crew, year and rating. No network call.
    private func refreshSuggestions() async {
        let target = pageMetadata.details.map { item.merging(details: $0) } ?? item
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
        pageMetadata.rankedSuggestions = ranked.compactMap { itemsByID[$0.profile.id] }
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
        if let episode = episodeList.selectedEpisodeID,
           !episode.isEmpty {
            return !episode.isEmpty ? "Episode \(episode)".trimmingCharacters(in: .whitespacesAndNewlines) : "Series episode"
        }
        return "\(item.type.isEmpty ? "item" : item.type)"
    }

    private var canStartPlayback: Bool {
        AppleTitlePagePolicy.canStartPlayback(
            type: item.type, hasPlaybackRoute: hasPlaybackRoute,
            isPreparing: pageMetadata.isPreparing || playbackCoordinator.phase.isBusy,
            hasSelectedEpisode: episodeList.selectedEpisodeID != nil
        )
    }

    private var recordID: String {
        AppleMediaIngestion.catalogRecord(instanceID: source.id, item: item).id
    }

    /// Where this title's saved position lives: `recordID`, or the key the
    /// same title was saved under when it was opened another way
    /// (`AppleTitleProgressIdentity`). Read and written through this one key.
    /// The covered page stops observing the progress feed; dismissal reads
    /// the latest saved position and restores the button's subscription.
    private var progressRecordID: String {
        let candidates = progressCandidates
        return AppleTitleProgressIdentity.key(among: candidates) {
            !titlePageIsCovered
                ? ApplePlaybackProgressFeed.shared.progress(for: $0, in: playbackStore)
                : playbackStore.progress(for: $0)
        } ?? recordID
    }

    private var progressCandidates: [String] {
        AppleTitleProgressIdentity.candidates(
            item: item, sourceID: source.id, resolvedMediaID: pageMetadata.resolvedMediaID)
    }

    /// Every key the page tries, what each holds, the one it chose and the
    /// verb it shows — the ids are catalog ids, never stream URLs.
    private func traceTitleProgress() {
        let held = progressCandidates.map { key -> String in
            let saved = playbackStore.progress(for: key)
            return "\(key)=\(saved.map { "\(Int($0.position))/\(Int($0.duration)) part=\($0.partID ?? "-")" } ?? "none")"
        }
        AppleInteractionTrace.record(.screen,
            "title progress candidates=[\(held.joined(separator: ", "))] chosen=\(progressRecordID) label=\(regularPlayTitle)")
    }

    /// The stock player's line above the title (`ApplePlaybackRequest.subtitle`
    /// and `releaseYear`): the show for an episode, and the year it aired or
    /// the film's year.
    private var stockPlayerSubtitle: String? {
        item.type == "series" ? item.name : nil
    }

    private var stockPlayerYear: Int? {
        let releaseInfo = item.type == "series" ? selectedEpisode?.releaseInfo : item.releaseInfo
        return releaseInfo.flatMap { Int($0.prefix(4)) } ?? (item.type == "series" ? nil : item.year)
    }

    private var offlineRecordID: String {
        if let reference = AppleMediaServerItemReference.parse(item.mediaID) {
            return AppleMediaServerItemReference(sourceID: reference.sourceID, itemID: episodeList.selectedEpisodeID ?? reference.itemID).mediaID
        }
        return selectedEpisodeSelection.map { "\(recordID):\($0.mediaID)" } ?? recordID
    }

    private var showsDownloadAction: Bool {
        if AppleMediaServerItemReference.parse(item.mediaID) != nil {
            return AppleLocalDownloadPlatformPolicy.isSupportedOnCurrentPlatform && offlineState.serverDownloadsAllowed
        }
        guard localGroup == nil else { return false }
        guard AppleLocalDownloadPlatformPolicy.isSupportedOnCurrentPlatform else { return false }
        guard offersDownload else { return false }
        #if os(tvOS) || os(visionOS)
        return false
        #else
        // Keyed lookup. This was `records.first { $0.id == recordID }`, which
        // rebuilt the catalog record for every entry in the index, several
        // times per body pass — seconds of main thread inside the push, so
        // Discover's large title stayed drawn over this page (F-e).
        let indexedRecord = mediaIndex.record(id: recordID)
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

    /// Whether a download could start here at all (a stream-capable source
    /// or a media-server title), or one already finished.
    private var offersDownload: Bool {
        if AppleMediaServerItemReference.parse(item.mediaID) != nil {
            return offlineState.serverDownloadsAllowed || downloadCoordinator.state.isCompleted
        }
        return AppleTitlePagePolicy.offersDownload(
            item: item, sources: playbackSources,
            hasCompletedDownload: downloadCoordinator.state.isCompleted,
            episodesUnavailable: episodeListPresentation == .unavailable
        )
    }

    private var canStartDownload: Bool {
        showsDownloadAction
            && !pageMetadata.isPreparing
            && !downloadCoordinator.state.ownsDownload
            && !downloadCoordinator.state.isCompleted
            && (item.type != "series" || episodeList.selectedEpisodeID != nil)
    }

    private var seasonNumbers: [Int] {
        AppleStremioEpisodePolicy.seasons(in: episodeList.episodes)
    }

    private var visibleEpisodes: [AppleStremioEpisode] {
        AppleStremioEpisodePolicy.episodes(in: episodeList.selectedSeason, from: episodeList.episodes)
    }

    private func episodeMetadata(_ episode: AppleStremioEpisode) -> String {
        [episodeNumber(episode), episode.formattedReleaseInfo, episode.runtimeMinutes.map { "\($0) min" }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder
    private var rateControl: some View {
        #if os(tvOS)
        Menu {
            titlePageRateChoices
        } label: {
            rateControlLabel
        }
        .appleBareMenu()
        .foregroundStyle(.white)
        .accessibilityLabel("Rate")
        .accessibilityValue(rating?.title ?? "Not rated")
        #else
        // One element, as on the iPhone (`AppleTitlePageRatePicker`).
        AppleTitlePageRatePicker(rating: rating, glyph: ratingGlyph(for:selected:), onSelect: selectRating) {
            rateControlLabel
        }
        .foregroundStyle(.white)
        #endif
    }

    private var rateControlLabel: some View {
        VStack(spacing: AppleDetailMetrics.iconLabelSpacing) {
            Image(systemName: ratingGlyph(for: rating, selected: rating != nil))
                .font(.system(size: scaledIconGlyphSize))
            Text("Rate")
                .font(.system(size: scaledIconLabelFontSize, weight: .semibold))
        }
        .frame(width: dynamicTypeSize.isAccessibilitySize ? nil : AppleDetailMetrics.iconActionWidth)
        .frame(minWidth: 44, minHeight: max(44, scaledIconRowHeight))
        .contentShape(.rect)
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
        #if os(tvOS)
        titleActions.ratingSelectionGeneration += 1
        let generation = titleActions.ratingSelectionGeneration
        withAnimation(rateAnimation) { titleActions.rateChoicesExpanded = true }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, generation == titleActions.ratingSelectionGeneration else { return }
            withAnimation(rateAnimation) { titleActions.rateChoicesExpanded = false }
        }
        #endif
    }

    private func toggleFavorite() {
        let next = !titleActions.isFavorite
        titleActions.isFavorite = next
        Task { @MainActor in
            do {
                try await mediaIndex.setFavorite(next, recordID: recordID)
            } catch {
                titleActions.isFavorite.toggle()
            }
        }
    }

    private func refreshOfflineState() async {
        await downloadCoordinator.loadExisting(mediaID: offlineRecordID, itemTitle: offlineDisplayTitle)
    }

    private func refreshDownloadedEpisodeIDs() async {
        guard item.type == "series" else { return }
        let resolvedIDs = episodeList.episodes.compactMap { episode -> (String, String)? in
            if let reference = AppleMediaServerItemReference.parse(item.mediaID) {
                return (episode.id, AppleMediaServerItemReference(sourceID: reference.sourceID, itemID: episode.id).mediaID)
            }
            guard let selection = AppleStremioEpisodeSelection(
                seriesMediaID: pageMetadata.resolvedMediaID ?? item.mediaID,
                episode: episode
            ) else { return nil }
            return (episode.id, "\(recordID):\(selection.mediaID)")
        }
        let downloaded = await downloadCoordinator.downloadedMediaIDs(among: Set(resolvedIDs.map(\.1)))
        guard !Task.isCancelled else { return }
        offlineState.downloadedEpisodeIDs = Set(resolvedIDs.filter { downloaded.contains($0.1) }.map(\.0))
    }

    private func chooseStreams() async {
        playbackUI.pickingStreams = true
        defer { playbackUI.pickingStreams = false }
        do {
            playbackUI.streamChoices = try await playbackResolver.rankedCandidates(sources: playbackSources,
                preferredSourceID: source.id, item: item.withMediaID(selectedPlaybackMediaID))
        } catch {
            playbackUI.streamChoices = []
            if localFiles.isEmpty { playbackCoordinator.fail(error); return }
        }
        prompts.streamPicker = true
    }

    private func configuredSources(_ presentation: AppleStremioPlayerPresentation, selectedID: URL? = nil) -> AppleStremioPlayerPresentation {
        var result = presentation
        result.sourceID = selectedID ?? presentation.request.url
        // Every path that opens the player from this page comes through here,
        // so wiring the next episode once covers all of them.
        result.nextEpisode = nextEpisodeContext()
        result.coordinator.trackCarryOver = playbackUI.trackCarryOver
        playbackUI.trackCarryOver = nil
        // Every stream failed before anything played: close the player, then
        // start again on the OpenStream engine when the Native player failed,
        // or say why here (`ApplePlaybackEngineFallback`).
        let fellBack = presentation.engineOverride != nil
        let fromBeginning = playbackUI.pressFromBeginning
        result.onUnplayable = { unplayable in
            playbackUI.presentation = nil
            switch ApplePlaybackEngineFallback.afterEveryStreamFailed(unplayable.failure,
                engine: unplayable.engine, alreadyFellBack: fellBack) {
            case .openStream:
                appleTrace("native fallback → openStream after \(unplayable.triedSourceURLs.count) failures")
                playbackUI.engineOverride = .openStream
                playbackUI.fallbackTriedSources = Set(unplayable.triedSourceURLs)
                playbackUI.startsFromBeginning = fromBeginning
                playbackCoordinator.beginResolving()
                playbackUI.request = UUID()
            case .alert(let message):
                playbackUI.unavailableMessage = message
            case nil:
                playbackCoordinator.reset()
            }
        }
        let engineOverride = presentation.engineOverride
        let files = localFiles
        let library = library
        let settings = settings
        let store = localSourceStore ?? AppleSourceStore()
        let selectedItem = item.withMediaID(selectedPlaybackMediaID)
        let mediaID = progressRecordID
        let title = selectedEpisodeSelection?.displayTitle ?? item.name
        let subtitle = stockPlayerSubtitle
        let releaseYear = stockPlayerYear
        let artwork = item.posterURL
        let episode = AppleStremioSeriesInfo(mediaID: selectedItem.mediaID).map { (season: $0.season, episode: $0.episode) }
        let runtime = expectedRuntime
        // MP4-first order only under the DEBUG Native override; the OpenStream
        // engine keeps the quality-first order.
        let stockPlayerOnly = (engineOverride ?? settings.playbackEngine) == .native
        result.sourceOptionsLoader = {
            let localOptions = files.map { file in
                ApplePlaybackSourceOption(id: file.url, tier: nil) { _ in
                    try await library.presentation(for: file, sourceStore: store, settings: settings)
                }
            }
            var streams: [AppleStremioHTTPPlaybackCandidate] = []
            var loadError: Error?
            do {
                streams = try await playbackResolver.rankedCandidates(sources: playbackSources,
                    preferredSourceID: source.id, item: selectedItem)
            } catch { loadError = error }
            if localOptions.isEmpty && streams.isEmpty, let loadError { throw loadError }
            let partID = AppleDetailResume.partID(type: selectedItem.type, mediaID: selectedItem.mediaID)
            @MainActor func option(_ candidate: AppleStremioHTTPPlaybackCandidate) -> ApplePlaybackSourceOption {
                ApplePlaybackSourceOption(id: candidate.sourceURL,
                    tier: AppleStremioCandidateRanking.traits(of: candidate).tier,
                    serviceKey: candidate.serviceKey,
                    badges: AppleStreamFormatBadge.normalized(AppleStreamFormatBadge.badges(for: candidate))) { resume in
                        AppleStremioPlayerPresentation(request: candidate.playbackRequest(mediaID: mediaID, title: title,
                            resume: resume ?? AppleDetailResume.position(mediaID: mediaID, partID: partID),
                            addonMediaID: selectedItem.mediaID, addonMediaType: selectedItem.type,
                            expectedRuntime: runtime, subtitle: subtitle, releaseYear: releaseYear,
                            artworkURL: artwork), settings: settings,
                            engineOverride: engineOverride)
                    }
            }
            let device = AppleStreamDeviceCapabilities.current
            @MainActor func order(_ choice: AppleStreamQualityChoice) -> [ApplePlaybackSourceOption] {
                AppleStremioCandidateRanking.playbackOrder(streams, choice: choice, device: device,
                    episode: episode, title: selectedItem.name, year: selectedItem.year,
                    unhealthyServices: AppleStreamServiceHealth.shared.unhealthyKeys(),
                    stockPlayerOnly: stockPlayerOnly).map(option)
            }
            let tiers = AppleStremioCandidateRanking.qualityTiers(streams, device: device)
            return ApplePlaybackSourceOptions(
                tiers: tiers,
                automatic: localOptions + order(.automatic),
                byTier: Dictionary(uniqueKeysWithValues: tiers.map { ($0, order(.tier($0))) }))
        }
        return result
    }

    /// The episode after the one about to play, and how to start it.
    ///
    /// Selecting it and re-running `resolvePlayback()` is exactly what
    /// choosing that episode by hand does, so the next episode resolves its own
    /// sources and resume position. It prefers the service the ending episode
    /// played from and takes its audio and subtitle choices along. Nil for a
    /// movie, for a series with nothing selected, and for the last episode of
    /// the last season.
    ///
    /// The ending player stays up while the next one resolves and is then
    /// replaced in one step. Closing it first and presenting the next a moment
    /// later raced the cover's dismissal: the new player was never shown and
    /// the viewer was left on the title page (iPhone 27 v2 re-run, 2/2).
    private func nextEpisodeContext() -> AppleNextEpisodeContext? {
        guard let selectedEpisodeID = episodeList.selectedEpisodeID,
              let current = episodeList.episodes.first(where: { $0.id == selectedEpisodeID }),
              let next = AppleStremioEpisodePolicy.following(current, in: episodeList.episodes) else { return nil }
        return AppleNextEpisodeContext(title: next.displayTitle) { carryOver in
            Task { @MainActor in
                // One handover per episode, however many times it is asked for.
                guard self.episodeList.selectedEpisodeID != next.id else { return }
                appleTrace("next episode → \(next.displayTitle)")
                let ending = self.playbackUI.presentation?.id
                self.playbackUI.preferredServiceKey = self.playbackCoordinator.currentRequest?.hints.serviceKey
                self.playbackUI.trackCarryOver = carryOver.isEmpty ? nil : carryOver
                self.episodeList.selectedEpisodeID = next.id
                // The ending player keeps its own coordinator; the page
                // resolves on a fresh one so a failure lands here, not on it.
                self.playbackCoordinator = ApplePlaybackCoordinator()
                await self.resolvePlayback()
                // Nothing replaced it: close it, and the page's alert says why.
                if self.playbackUI.presentation?.id == ending { self.playbackUI.presentation = nil }
            }
        }
    }

    private var playbackFailure: ApplePlaybackFailure? {
        if case .failed(let failure) = playbackCoordinator.phase { return failure }
        return nil
    }

    /// Takes the alert down and puts the page into its loading state before
    /// anything is asked again, so the press is seen to do something even when
    /// the answer comes back at once.
    private func retryPlayback() {
        playbackUI.retryStartedAt = .now
        playbackCoordinator.beginResolving()
        playbackUI.request = UUID()
    }

    private func openSourcesAfterPlaybackFailure() {
        playbackCoordinator.reset()
        if let openSourcesSettings { openSourcesSettings() } else { openSettings() }
    }

    private func resolvePlayback() async {
        let retryStartedAt = playbackUI.retryStartedAt
        playbackUI.retryStartedAt = nil
        let engineOverride = playbackUI.engineOverride
        playbackUI.engineOverride = nil
        let fallbackTried = playbackUI.fallbackTriedSources
        playbackUI.fallbackTriedSources = []
        let fromBeginning = playbackUI.startsFromBeginning
        playbackUI.startsFromBeginning = false
        playbackUI.pressFromBeginning = fromBeginning
        let discChoice = playbackUI.disc
        playbackUI.disc = nil
        if fromBeginning { appleTrace("title page: start from beginning") }
        playbackUI.unavailableMessage = nil
        playbackCoordinator.beginResolving()
        do {
            if let reference = AppleXtreamReference.parse(item.mediaID) {
                let partID = item.type == "series" ? episodeList.selectedEpisodeID : nil
                let request = try await AppleXtreamLibraryStore.shared.request(reference: reference,
                    episodeID: partID, mediaID: progressRecordID, fromBeginning: fromBeginning)
                let presentation = AppleStremioPlayerPresentation(request: request, settings: settings, engineOverride: engineOverride)
                let identity = progressRecordID
                let store = ApplePlaybackStore()
                presentation.coordinator.progressWriter = { position, duration in
                    store.save(mediaID: identity, position: position, duration: duration, partID: partID)
                }
                playbackCoordinator = presentation.coordinator
                playbackUI.presentation = configuredSources(presentation)
                return
            }
            if AppleMediaServerItemReference.parse(item.mediaID) != nil,
               let offline = await downloadCoordinator.record(for: offlineRecordID) {
                let request = try AppleMediaServerLibraryStore.offlinePlaybackRequest(record: offline,
                    title: offlineDisplayTitle, resumePosition: fromBeginning ? nil : ApplePlaybackStore().progress(for: offline.mediaID)?.position)
                let presentation = AppleStremioPlayerPresentation(request: request, settings: settings,
                    engineOverride: engineOverride)
                playbackCoordinator = presentation.coordinator
                playbackUI.presentation = configuredSources(presentation, selectedID: offline.localURL)
                return
            }
            if let msLibrary = mediaServerLibrary, let msRef = AppleMediaServerItemReference.parse(item.mediaID),
               await downloadCoordinator.record(for: offlineRecordID) == nil {
                let msDetail = try await msLibrary.detail(for: msRef)

                let episodeToPlay: AppleMediaServerItem
                if item.type == "series" || msDetail.item.type == .series || msDetail.item.type == .episode {
                    let epID = episodeList.selectedEpisodeID ?? msRef.itemID
                    var found: AppleMediaServerItem?
                    for eps in msDetail.episodesBySeason.values {
                        if let e = eps.first(where: { $0.id == epID }) { found = e; break }
                    }
                    guard let foundEp = found else { throw AppleMediaServerError.unsupported }
                    episodeToPlay = foundEp
                } else {
                    episodeToPlay = msDetail.item
                }

                let req = try await msLibrary.playbackRequest(for: episodeToPlay, in: msDetail, resume: !fromBeginning)
                let presentation = AppleStremioPlayerPresentation(request: req, settings: settings)
                playbackCoordinator = presentation.coordinator
                playbackUI.presentation = configuredSources(presentation, selectedID: req.url)
                return
            }

            if playbackUI.selectedQuality == nil {
                let files = playbackUI.selectedLocalFile.map { [$0] } ?? localFiles.filter { !ApplePlaybackFailureHistory.shared.contains($0.url) }
                playbackUI.selectedLocalFile = nil
                for file in files {
                    do {
                        let presentation = try await library.presentation(for: file,
                            sourceStore: localSourceStore ?? AppleSourceStore(), settings: settings,
                            fromBeginning: fromBeginning, disc: discChoice)
                        playbackCoordinator = presentation.coordinator
                        playbackUI.presentation = configuredSources(presentation, selectedID: file.url)
                        return
                    } catch is CancellationError { throw CancellationError() }
                    catch { ApplePlaybackFailureHistory.shared.record(file.url) }
                }
            }
            if playbackUI.selectedQuality == nil, let offlineRecord = await downloadCoordinator.record(for: offlineRecordID),
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
                            resumePosition: AppleTitlePagePolicy.startPosition(
                                saved: AppleDetailResume.position(mediaID: progressRecordID,
                                    partID: AppleDetailResume.partID(type: item.type, mediaID: selectedPlaybackMediaID)),
                                fromBeginning: fromBeginning),
                            mediaID: progressRecordID,
                            title: item.name,
                            sourceKind: .catalog,
                            // Names the episode, so its position is saved
                            // under it (`AppleSeriesProgressGuard`).
                            hints: .init(addonMediaID: selectedPlaybackMediaID, addonMediaType: item.type)
                        ),
                        settings: settings
                    )
                    playbackCoordinator = presentation.coordinator
                    playbackUI.presentation = configuredSources(presentation, selectedID: offlineRecord.localURL)
                    return
                } catch is CancellationError { throw CancellationError() }
                catch { ApplePlaybackFailureHistory.shared.record(offlineRecord.localURL) }
            }

            // Series: play the selected episode id (already IMDB-shaped from the
            // resolved series meta). Movie: play the resolved IMDB id, falling
            // back to the raw catalog id only if meta resolution found nothing.
            let streamID = selectedPlaybackMediaID
            let selectedItem = item.withMediaID(streamID)
            let ranked = try await playbackResolver.rankedCandidates(
                sources: playbackSources,
                preferredSourceID: source.id,
                item: selectedItem
            )
            try Task.checkCancellation()
            playbackUI.streamChoices = ranked
            // Automatic, or the resolution picked in the Quality sheet: the
            // best candidate this device plays, then the rest as fallbacks.
            let chosen = playbackUI.selectedQuality
            let ordered = AppleStremioCandidateRanking.playbackOrder(
                ranked, choice: chosen.map(AppleStreamQualityChoice.tier) ?? .automatic,
                device: AppleStreamDeviceCapabilities.current,
                episode: AppleStremioSeriesInfo(mediaID: streamID).map { (season: $0.season, episode: $0.episode) },
                title: item.name, year: item.year,
                unhealthyServices: AppleStreamServiceHealth.shared.unhealthyKeys(),
                preferredService: playbackUI.preferredServiceKey,
                // DEBUG Native override only; quality-first otherwise.
                stockPlayerOnly: (engineOverride ?? settings.playbackEngine) == .native)
            playbackUI.preferredServiceKey = nil
            let mediaID = progressRecordID
            let title = selectedEpisodeSelection?.displayTitle ?? item.name
            let subtitle = stockPlayerSubtitle
            let releaseYear = stockPlayerYear
            let artwork = item.posterURL
            let runtime = expectedRuntime
            // A stream the Native player failed is not a failure for the
            // OpenStream engine, so its fallback keeps them all, the ones the
            // Native player never tried first.
            let kept = ordered.filter { chosen != nil || engineOverride != nil
                || !ApplePlaybackFailureHistory.shared.contains($0.sourceURL) }
            let requests = ApplePlaybackEngineFallback.fallbackOrder(kept, url: \.sourceURL,
                tried: fallbackTried).map { candidate in
                candidate.playbackRequest(mediaID: mediaID, title: title,
                    resume: AppleTitlePagePolicy.startPosition(
                        saved: AppleDetailResume.position(mediaID: mediaID,
                            partID: AppleDetailResume.partID(type: selectedItem.type, mediaID: selectedItem.mediaID)),
                        fromBeginning: fromBeginning),
                    addonMediaID: selectedItem.mediaID, addonMediaType: selectedItem.type,
                    expectedRuntime: runtime, subtitle: subtitle, releaseYear: releaseYear,
                    artworkURL: artwork)
            }
            playbackUI.selectedQuality = nil
            guard let first = requests.first else { throw AppleLibrarySourceError.noMedia }
            let presentation = AppleStremioPlayerPresentation(
                request: first,
                fallbackCandidates: Array(requests.dropFirst()),
                settings: settings,
                engineOverride: engineOverride
            )
            playbackCoordinator = presentation.coordinator
            playbackUI.presentation = configuredSources(presentation)
        } catch is CancellationError {
            playbackCoordinator.reset()
        } catch {
            if let retryStartedAt {
                let hold = ApplePlaybackFailureRecovery.remainingRetryFeedback(elapsed: .now - retryStartedAt)
                if hold > .zero { try? await Task.sleep(for: hold) }
                guard !Task.isCancelled else {
                    playbackCoordinator.reset()
                    return
                }
            }
            playbackCoordinator.fail(error)
        }
    }

    private func startDownload(episode: AppleStremioEpisode? = nil) {
        guard !seasonDownloads.isRunning else { return }
        let selection = episode.flatMap { AppleStremioEpisodeSelection(seriesMediaID: pageMetadata.resolvedMediaID ?? item.mediaID, episode: $0) }
        let streamID = selection?.mediaID ?? selectedPlaybackMediaID
        let selectedItem = item.withMediaID(streamID)
        let sources = playbackSources
        let preferredSourceID = source.id
        downloadCoordinator.start(
            request: .init(
                mediaID: AppleMediaServerItemReference.parse(item.mediaID) != nil ? offlineRecordID : (selection.map { "\(recordID):\($0.mediaID)" } ?? offlineRecordID),
                itemTitle: selection?.displayTitle ?? offlineDisplayTitle,
                subtitle: selection?.displayTitle ?? offlineSubtitle,
                artworkURL: item.posterURL,
                destinationLabel: "oStream Offline Storage"
            ),
            resolvePlans: {
                // Automatic, by owner decision (2026-09-17): no source sheet.
                // The resolver returns up to 12 ranked plans and the
                // coordinator walks them in order when one fails, which is what
                // makes "a source is chosen by default but is not necessarily
                // available" (tester, build 10) safe without asking.
                if let reference = AppleMediaServerItemReference.parse(item.mediaID), let mediaServerLibrary {
                    let target = AppleMediaServerItemReference(sourceID: reference.sourceID, itemID: episode?.id ?? episodeList.selectedEpisodeID ?? reference.itemID)
                    return [try await mediaServerLibrary.downloadPlan(reference: target)]
                }
                return try await playbackResolver.resolveDownloadPlans(
                    sources: sources,
                    preferredSourceID: preferredSourceID,
                    item: selectedItem
                )
            },
            revokeCapabilities: { capabilities in
                for capability in capabilities {
                    await AppleProtectedHTTPPlaybackServer.shared.revoke(playbackURL: capability)
                }
            }
        )
    }

    private func startServerSeasonDownload(reference: AppleMediaServerItemReference, library: AppleMediaServerLibraryStore) {
        let episodes = visibleEpisodes
        let byID = Dictionary(episodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let mediaIDs = Set(episodes.map { AppleMediaServerItemReference(sourceID: reference.sourceID, itemID: $0.id).mediaID })
        var plans: [String: AppleOfflineDownloadPlan] = [:]
        seasonDownloads.start(episodeIDs: episodes.map(\.id), onCancel: {
            AppleMediaServerBackgroundDownloads.shared.cancel(mediaIDs: mediaIDs)
        }) { id in
            // Resolve and enqueue the entire season before waiting on its first item.
            // The OS then retains every transfer even if the process is terminated.
            if plans.isEmpty {
                for episode in episodes {
                    try Task.checkCancellation()
                    let target = AppleMediaServerItemReference(sourceID: reference.sourceID, itemID: episode.id)
                    if await downloadCoordinator.record(for: target.mediaID) != nil { continue }
                    plans[episode.id] = try await library.downloadPlan(reference: target)
                }
                try Task.checkCancellation()
                for episode in episodes {
                    guard let plan = plans[episode.id] else { continue }
                    let target = AppleMediaServerItemReference(sourceID: reference.sourceID, itemID: episode.id)
                    _ = AppleMediaServerBackgroundDownloads.shared.start(
                        request: .init(mediaID: target.mediaID, itemTitle: "\(item.name) · \(episode.displayTitle)",
                            subtitle: episode.displayTitle, artworkURL: item.posterURL, destinationLabel: "oStream Offline Storage"),
                        plan: plan, observer: { _ in })
                }
            }
            guard let episode = byID[id] else { return }
            let target = AppleMediaServerItemReference(sourceID: reference.sourceID, itemID: id)
            try await downloadCoordinator.downloadAndWait(
                request: .init(mediaID: target.mediaID, itemTitle: "\(item.name) · \(episode.displayTitle)",
                    subtitle: episode.displayTitle, artworkURL: item.posterURL, destinationLabel: "oStream Offline Storage"),
                resolvePlans: {
                    guard let plan = plans[id] else { return [] }
                    return [plan]
                }, revokeCapabilities: { _ in }
            )
        }
    }

    private func startSeasonDownload() {
        guard !pageMetadata.isPreparing, !downloadCoordinator.state.ownsDownload else { return }
        offlineState.downloadSeason = episodeList.selectedSeason
        if let reference = AppleMediaServerItemReference.parse(item.mediaID), let mediaServerLibrary {
            startServerSeasonDownload(reference: reference, library: mediaServerLibrary)
            return
        }
        let selections = visibleEpisodes.compactMap {
            AppleStremioEpisodeSelection(seriesMediaID: pageMetadata.resolvedMediaID ?? item.mediaID, episode: $0)
        }
        let byID = selections.reduce(into: [String: AppleStremioEpisodeSelection]()) { $0[$1.mediaID] = $1 }
        let baseID = recordID
        seasonDownloads.start(episodeIDs: selections.map(\.mediaID)) { id in
            guard let selection = byID[id] else { return }
            let selectedItem = item.withMediaID(id)
            try await downloadCoordinator.downloadAndWait(
                request: .init(mediaID: "\(baseID):\(id)", itemTitle: "\(item.name) · \(selection.displayTitle)",
                    subtitle: selection.displayTitle, artworkURL: item.posterURL,
                    destinationLabel: "oStream Offline Storage"),
                resolvePlans: {
                    return try await playbackResolver.resolveDownloadPlans(sources: playbackSources,
                        preferredSourceID: source.id, item: selectedItem)
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
        if AppleMediaServerItemReference.parse(item.mediaID) != nil,
           let episode = episodeList.episodes.first(where: { $0.id == episodeList.selectedEpisodeID }) {
            return "\(item.name) · \(episode.displayTitle)"
        }
        return selectedEpisodeSelection?.displayTitle ?? item.name
    }

    private var offlineSubtitle: String? {
        guard let selectedEpisodeID = episodeList.selectedEpisodeID,
              let episode = episodeList.episodes.first(where: { $0.id == selectedEpisodeID }) else {
            return item.releaseInfo
        }
        let title = episode.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? episodeNumber(episode) : "\(episodeNumber(episode)) · \(title)"
    }

    private func applyEpisodes(_ fetched: [AppleStremioEpisode]) {
        let mediaID = pageMetadata.resolvedMediaID ?? item.mediaID
        episodeList.episodes = localGroup.map { AppleLocalLibraryStore.episodes(group: $0,
            mediaID: mediaID, enriched: fetched) } ?? fetched
        offlineState.downloadedEpisodeIDs = []
        episodeList.selectedSeason = savedEpisode(in: episodeList.episodes)?.season
            ?? library.resumeEpisode(for: item, group: localGroup, episodes: episodeList.episodes)?.season
            ?? upNextEpisode(in: episodeList.episodes)?.season
            ?? AppleStremioEpisodePolicy.initialSeason(in: episodeList.episodes)
        // Play needs an episode: fall back to the first episode of the
        // first season so the button works the moment the list arrives.
        episodeList.selectedEpisodeID = nextUnwatchedEpisodeID(in: episodeList.selectedSeason, from: episodeList.episodes)
            ?? ApplePlayGatingPolicy.defaultEpisodeID(episodes: episodeList.episodes)
        episodeList.isLoading = false
        episodeList.loadFinished = true
        fillTimeline.mark(.episodes, detail: "\(episodeList.episodes.count)")
    }

    private func prepareXtream(_ reference: AppleXtreamReference, generation: UUID) async {
        pageMetadata.isPreparing = item.type == "series"
        episodeList.isLoading = item.type == "series"
        pageMetadata.resolvedMediaID = item.mediaID
        do {
            let detail = try await AppleXtreamLibraryStore.shared.detail(reference)
            guard !Task.isCancelled, preparationGeneration == generation else { return }
            let title = detail.title
            pageMetadata.details = AppleTMDBDetails(title: title.name, imdbRating: title.rating, year: title.year,
                overview: title.plot, posterURL: title.poster, backdropURL: title.backdrop)
            episodeList.episodes = AppleXtreamLibraryStore.shared.episodes(detail, sourceID: reference.sourceID)
            episodeList.selectedSeason = savedEpisode(in: episodeList.episodes)?.season
                ?? upNextEpisode(in: episodeList.episodes)?.season
                ?? AppleStremioEpisodePolicy.initialSeason(in: episodeList.episodes)
            episodeList.selectedEpisodeID = nextUnwatchedEpisodeID(in: episodeList.selectedSeason, from: episodeList.episodes)
                ?? ApplePlayGatingPolicy.defaultEpisodeID(episodes: episodeList.episodes)
            pageMetadata.isPreparing = false
            episodeList.isLoading = false
            episodeList.loadFinished = true
            markMetadataArrived()
            // Provider metadata and playback are usable before optional TMDB enrichment.
            if let id = title.tmdbID.flatMap(Int.init), id > 0, let configuration = metadataConfiguration,
               let enriched = try? await AppleTMDBClient().sharedLinkDetails(id: id,
                    kind: item.type == "series" ? .show : .movie, configuration: configuration),
               !Task.isCancelled, preparationGeneration == generation {
                pageMetadata.details = AppleTMDBDetails(title: title.name, imdbRating: title.rating, year: title.year ?? enriched.year,
                    overview: title.plot ?? enriched.summary, posterURL: title.poster ?? enriched.posterURL,
                    backdropURL: title.backdrop ?? enriched.backgroundURL)
            }
        } catch is CancellationError { return }
        catch {
            guard !Task.isCancelled, preparationGeneration == generation else { return }
            pageMetadata.isPreparing = false
            episodeList.isLoading = false
            episodeList.loadFinished = true
            if item.type == "series" {
                playbackUI.unavailableMessage = AppleXtreamLibraryError.unavailable.localizedDescription
            }
        }
    }

    private func markMetadataArrived() {
        fillTimeline.mark(.metadata, detail: pageMetadata.details?.overview?.isEmpty == false ? "overview" : "no-overview")
        markOverviewIfVisible(source: "enriched")
    }

    private func markOverviewIfVisible(source: String) {
        guard AppleMetadataPresentationPolicy.synopsis(
            catalog: item.summary,
            enriched: pageMetadata.details?.overview
        ) != nil else { return }
        fillTimeline.mark(.overview, detail: source)
    }

    /// Resolve the item to its IMDB id, then (for series) load episodeList.episodes keyed
    /// by that id so both metadata and streams resolve against a stream-add-on
    /// friendly identifier.
    private func prepare() async {
        let generation = UUID()
        preparationGeneration = generation
        pageMetadata.details = nil
        pageMetadata.previewAssets = nil
        pageMetadata.fallbackArtwork = nil
        episodeList.episodes = []
        episodeList.loadFinished = false
        episodeList.selectedSeason = nil
        episodeList.selectedEpisodeID = nil
        pageMetadata.resolvedMediaID = nil
        pageMetadata.watchProviders = []
        pageMetadata.streamingIDs = nil

        if let reference = AppleXtreamReference.parse(item.mediaID) {
            await prepareXtream(reference, generation: generation)
            return
        }

        if let msLibrary = mediaServerLibrary, let msRef = AppleMediaServerItemReference.parse(item.mediaID) {
            pageMetadata.isPreparing = true
            do {
                let msDetail = try await msLibrary.detail(for: msRef)
                guard !Task.isCancelled, preparationGeneration == generation else { return }
                self.pageMetadata.details = msLibrary.metadata(from: msDetail)
                self.pageMetadata.resolvedMediaID = item.mediaID
                self.episodeList.episodes = msLibrary.episodes(from: msDetail)
                markMetadataArrived()
                fillTimeline.mark(.episodes, detail: "\(self.episodeList.episodes.count)")
                self.offlineState.serverDownloadsAllowed = (try? await msLibrary.downloadsAllowed(in: msDetail)) == true
                guard !Task.isCancelled, preparationGeneration == generation else { return }
                self.offlineState.downloadedEpisodeIDs = []
                self.episodeList.selectedSeason = upNextEpisode(in: self.episodeList.episodes)?.season
                    ?? AppleStremioEpisodePolicy.initialSeason(in: self.episodeList.episodes)
                self.episodeList.selectedEpisodeID = nextUnwatchedEpisodeID(in: self.episodeList.selectedSeason, from: self.episodeList.episodes)
                    ?? ApplePlayGatingPolicy.defaultEpisodeID(episodes: self.episodeList.episodes)
                self.pageMetadata.isPreparing = false
                self.episodeList.isLoading = false
                self.episodeList.loadFinished = true
                await refreshOfflineState()
                await refreshDownloadedEpisodeIDs()
            } catch {
                guard !Task.isCancelled, preparationGeneration == generation else { return }
                self.pageMetadata.isPreparing = false
                self.episodeList.isLoading = false
                self.episodeList.loadFinished = true
                self.pageMetadata.details = AppleTMDBDetails(
                    mediaID: item.mediaID,
                    title: item.name,
                    overview: (error as? AppleMediaServerError).map { AppleMediaServerFormPolicy.message(for: $0) } ?? "An unexpected error occurred."
                )
            }
            return
        }

        let isSeries = item.type == "series"
        // An item that already carries a canonical `tt…` id needs no meta
        // add-on round trip, so Play is usable before anything is awaited.
        let canonicalID = ApplePlayGatingPolicy.canonicalMediaID(item.mediaID)
        if let canonicalID {
            pageMetadata.resolvedMediaID = canonicalID
            pageMetadata.isPreparing = false
        } else {
            pageMetadata.isPreparing = true
        }
        if isSeries { episodeList.isLoading = true }
        rating = ratingStore.rating(for: item.mediaID)

        // Preview art, the canonical id, the episode list and the enriched
        // details all load at once, and each is drawn the moment it arrives.
        // The details used to be requested only after the episodeList.episodes and the
        // preview art had both come back, so one slow add-on held the
        // overview back too.
        let client = metadataClient
        let resolver = metadataResolver
        let sources = playbackSources
        let preferredSourceID = source.id
        let type = item.type
        let catalogID = item.mediaID
        let itemName = item.name
        let configuration = metadataConfiguration
        // The episodeList.episodes and details requests go out before this task gets
        // the main actor back: the page is still being built then, and
        // waiting for it cost ~0.4-0.8 s on the Apple TV.
        func addLookups(to group: inout TaskGroup<AppleDetailPrepareOutcome>, mediaID: String) {
            if isSeries {
                group.addTask {
                    do {
                        return .episodes(try await client.episodes(
                            sources: sources,
                            preferredSourceID: preferredSourceID,
                            mediaID: mediaID
                        ))
                    } catch is CancellationError {
                        return .episodes(nil)
                    } catch {
                        return .episodes([])
                    }
                }
            }
            group.addTask {
                let details = try? await resolver.resolve(
                    sources: sources,
                    preferredSourceID: preferredSourceID,
                    type: type,
                    mediaID: mediaID,
                    configuration: configuration,
                    fallbackName: itemName
                )
                #if DEBUG
                // `-OpenStreamDebugDetailsDelay <s>`: the enriched details (and
                // their trailers) land that late, as on a slow phone network.
                let delay = UserDefaults.standard.double(forKey: "OpenStreamDebugDetailsDelay")
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                #endif
                return .details(details)
            }
        }
        await withTaskGroup(of: AppleDetailPrepareOutcome.self) { group in
            group.addTask {
                .preview(await client.previewAssets(
                    sources: sources,
                    preferredSourceID: preferredSourceID,
                    type: type,
                    mediaID: catalogID
                ))
            }
            if let canonicalID {
                addLookups(to: &group, mediaID: canonicalID)
            } else {
                group.addTask {
                    .identity(await client.imdbIdentifier(
                        sources: sources,
                        preferredSourceID: preferredSourceID,
                        type: type,
                        id: catalogID
                    ))
                }
            }
            while let outcome = await group.next() {
                guard !Task.isCancelled, preparationGeneration == generation else {
                    group.cancelAll()
                    break
                }
                switch outcome {
                case .identity(let resolved):
                    // Play and Download depend on the canonical id (and, for a
                    // series, an episode), not on optional preview art or TMDB
                    // enrichment. Make the actions usable as soon as that
                    // identity is ready.
                    let mediaID = resolved ?? catalogID
                    pageMetadata.resolvedMediaID = mediaID
                    pageMetadata.isPreparing = false
                    addLookups(to: &group, mediaID: mediaID)
                case .episodes(let fetched):
                    guard let fetched else { continue }
                    applyEpisodes(fetched)
                    await refreshDownloadedEpisodeIDs()
                case .preview(let preview):
                    pageMetadata.previewAssets = preview
                case .details(let details):
                    pageMetadata.details = details
                    if details != nil { markMetadataArrived() }
                }
            }
        }
        if isSeries, preparationGeneration == generation { episodeList.isLoading = false }
        guard !Task.isCancelled, preparationGeneration == generation else { return }
        await loadWatchProviders()
        guard !Task.isCancelled, preparationGeneration == generation else { return }
        if item.posterURL == nil, pageMetadata.details?.backdropURL == nil, pageMetadata.details?.posterURL == nil {
            let artwork = await AppleArtworkResolver.shared.resolve(
                mediaID: pageMetadata.resolvedMediaID ?? item.mediaID,
                type: item.type,
                existingPosterURL: item.posterURL,
                existingBackgroundURL: item.backgroundURL,
                configuration: metadataConfiguration
            )
            guard !Task.isCancelled, preparationGeneration == generation else { return }
            pageMetadata.fallbackArtwork = artwork
        }
    }

    /// Where else this title can be watched, filtered to the services the
    /// viewer subscribes to.
    ///
    /// The whole call is skipped when they have not opted in — no request goes
    /// out at all, rather than one being made and the answer thrown away.
    private func loadWatchProviders() async {
        let enabled = settings.watchProviderIDs
        let imdbID = pageMetadata.resolvedMediaID ?? item.mediaID
        guard !enabled.isEmpty, let configuration = metadataConfiguration, imdbID.hasPrefix("tt") else {
            // The full test found no provider line in the trace at all
            // (2026-09-30); every way out says why.
            appleTrace("watch providers: skipped for \(item.name) (enabled \(enabled.count), "
                + "metadata \(metadataConfiguration == nil ? "off" : "on"), id \(imdbID.hasPrefix("tt") ? "imdb" : "other"))")
            pageMetadata.watchProviders = []
            return
        }
        let kind: AppleMediaKind = item.type == "series" ? .series : .movie
        let region = AppleWatchProviderResponse.currentRegion()
        let all: [AppleWatchProvider]
        do {
            all = try await AppleTMDBClient().watchProviders(
                imdbID: imdbID, kind: kind, region: region, configuration: configuration)
        } catch {
            appleTrace("watch providers: failed for \(item.name) (\(region)) — \(error.localizedDescription)")
            all = []
        }
        guard !Task.isCancelled else { return }
        let visible = AppleWatchProviderPolicy.visible(all, enabledProviderIDs: enabled)
        appleTrace("watch providers: \(visible.count) for \(item.name) (enabled \(enabled.count), \(all.count) in \(region))")
        pageMetadata.watchProviders = visible
        // Only when Watch on takes Play's place does the IMDb id go to
        // Wikidata — and nothing else does.
        guard watchOnAction != nil, AppleWikidataStreamingQuery.isIMDbID(imdbID) else { return }
        let ids = await AppleWikidataStreamingIDClient.shared.ids(for: imdbID)
        guard !Task.isCancelled else { return }
        pageMetadata.streamingIDs = ids
    }

    /// Watch on <Service> in Play's place: nothing in the app can play this
    /// title and a service the viewer added carries it.
    private var watchOnAction: AppleWatchOnAction? {
        AppleWatchOnPolicy.action(hasInAppSource: hasPlaybackRoute, visibleProviders: pageMetadata.watchProviders)
    }

    /// The "Also available on" line, which Watch on replaces when it is the
    /// main button (it would only repeat it).
    private var alsoAvailableProviders: [AppleWatchProvider] {
        watchOnAction == nil ? pageMetadata.watchProviders : []
    }

    private func watchOnLinks(_ choice: AppleWatchOnChoice, ids: AppleStreamingIDs?) -> [AppleWatchOnLink] {
        AppleWatchOnLinkPolicy.links(for: choice.service, ids: ids ?? AppleStreamingIDs(), title: item.name)
    }

    private func watchOnHint(_ choice: AppleWatchOnChoice) -> String {
        AppleWatchOnLinkPolicy.accessibilityHint(
            service: choice.service, links: watchOnLinks(choice, ids: pageMetadata.streamingIDs)
        ) ?? ""
    }

    /// Opens the service: the title in its app where possible, then the
    /// fallbacks (`AppleWatchOnPolicy.attempts`), ending on instructions.
    private func openWatchOn(_ choice: AppleWatchOnChoice) {
        prompts.watchOnMenu = false
        let imdbID = pageMetadata.resolvedMediaID ?? item.mediaID
        let cached = pageMetadata.streamingIDs
        let title = item.name
        Task {
            var ids = cached
            if ids == nil, AppleWikidataStreamingQuery.isIMDbID(imdbID) {
                ids = await AppleWikidataStreamingIDClient.shared.ids(for: imdbID)
                pageMetadata.streamingIDs = ids
            }
            let links = watchOnLinks(choice, ids: ids)
            let outcome = await AppleWatchOnPolicy.run(
                AppleWatchOnPolicy.attempts(for: links, platform: .current),
                open: { url, appOnly in await appleOpenWatchOnURL(url, appOnly: appOnly) }
            )
            appleTrace("watch-on: \(title) → \(choice.service.displayName) (\(outcome.traceDetail))")
            if case .instructions(let link) = outcome {
                prompts.watchOnInstructions = AppleWatchOnInstructions(service: choice.service, title: title, link: link)
            }
        }
    }

    /// The episode the show's saved position names — what Continue Watching
    /// and the home hero's Resume button promise — when it is in `loaded`.
    private func savedEpisode(in loaded: [AppleStremioEpisode]) -> AppleStremioEpisode? {
        AppleStremioEpisodePolicy.savedEpisode(progress: playbackStore.progress(for: progressRecordID), in: loaded)
    }

    private func nextUnwatchedEpisodeID(
        in season: Int?,
        from loadedEpisodes: [AppleStremioEpisode]
    ) -> String? {
        if let saved = savedEpisode(in: loadedEpisodes.filter { $0.season == season }) { return saved.id }
        if let resumed = library.resumeEpisode(for: item, group: localGroup,
            episodes: loadedEpisodes.filter { $0.season == season }) { return resumed.id }
        return AppleStremioEpisodePolicy.defaultEpisode(in: season, from: loadedEpisodes,
            completedIDs: playbackStore.completedMediaIDs(among: loadedEpisodes.map(\.id)))?.id
    }

    /// The Apple TV app's Up Next across the whole show — the season the page
    /// opens on when nothing is part-watched.
    private func upNextEpisode(in loaded: [AppleStremioEpisode]) -> AppleStremioEpisode? {
        AppleStremioEpisodePolicy.upNext(from: loaded,
            completedIDs: playbackStore.completedMediaIDs(among: loaded.map(\.id)))
    }

    /// Mark as Watched / Mark as Unwatched on an episode (the Apple TV app's
    /// episode menu). Marking the episode Continue Watching names as watched
    /// also takes it off Continue Watching. Play then moves to the new Up Next.
    private func setWatched(_ watched: Bool, episode: AppleStremioEpisode) {
        if watched {
            playbackStore.markWatched(mediaID: episode.id)
            if playbackStore.progress(for: progressRecordID)?.partID == episode.id {
                playbackStore.clear(mediaID: progressRecordID)
            }
        } else {
            playbackStore.markUnwatched(mediaID: episode.id)
        }
        episodeList.selectedEpisodeID = nextUnwatchedEpisodeID(in: episodeList.selectedSeason, from: episodeList.episodes) ?? episodeList.selectedEpisodeID
    }

    @ViewBuilder
    private func watchedMenuButton(_ episode: AppleStremioEpisode, isWatched: Bool) -> some View {
        if isWatched {
            Button("Mark as Unwatched", systemImage: "minus.circle") { setWatched(false, episode: episode) }
                .accessibilityIdentifier("detail.episode.markUnwatched")
        } else {
            Button("Mark as Watched", systemImage: "checkmark.circle") { setWatched(true, episode: episode) }
                .accessibilityIdentifier("detail.episode.markWatched")
        }
    }

    /// Finished episodeList.episodes on the visible list, read through the feed so a
    /// finish, mark or unmark redraws the ticks.
    private var watchedEpisodeIDs: Set<String> {
        !titlePageIsCovered
            ? ApplePlaybackProgressFeed.shared.completedMediaIDs(among: visibleEpisodes.map(\.id), in: playbackStore)
            : playbackStore.completedMediaIDs(among: visibleEpisodes.map(\.id))
    }
}

enum AppleDetailActionButtonGlyph: Sendable {
    case systemImage(String)
    case progress
    /// The turning disc, while a disc item opens.
    case disc
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
            HStack(spacing: AppleDetailMetrics.actionButtonGlyphSpacing) {
                switch glyph {
                case .systemImage(let name):
                    Image(systemName: name)
                        .font(.system(size: glyphSize))
                case .progress:
                    ProgressView()
                        .tint(kind.foreground)
                case .disc:
                    AppleDiscSpinner(tint: kind.foreground, size: glyphSize)
                }
                Text(title)
                    .font(.system(size: labelFontSize, weight: .semibold))
                    // A fixed width cannot hold a label this size, so above the
                    // accessibility threshold the button hugs its content and
                    // the label may take a second line.
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    .minimumScaleFactor(AppleDetailMetrics.actionButtonLabelMinimumScale)
                    .allowsTightening(true)
            }
            .foregroundStyle(kind.foreground)
            .padding(.horizontal, AppleDetailMetrics.actionButtonHorizontalPadding)
            .frame(
                width: AppleDetailMetrics.actionButtonLabelFrameWidth(
                    width, isAccessibilitySize: dynamicTypeSize.isAccessibilitySize
                )
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
            .frame(minWidth: AppleDesignTokens.minimumActionSize, minHeight: AppleDesignTokens.minimumActionSize)
            .contentShape(.rect)
    }
}

private struct AppleDetailRowButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        // The inset belongs to the label, which is already asked to fill the
        // row: padding it here grew the button twenty points past the width it
        // was given, and the overflow lay over the download glyph beside it —
        // on the iPad XCUITest could find no hit point on that button at all
        // (button crawl, 2026-09-19).
        configuration.label
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
/// The trailer's full-frame pause control. Touches go to a tap recognizer
/// (`AppleYouTubeAutoPreview.PlayerContainer`), so VoiceOver's activate is
/// routed here rather than to a control action.
final class AppleTrailerTouchShield: UIButton {
    var onAccessibilityActivate: (() -> Void)?

    override func accessibilityActivate() -> Bool {
        guard let onAccessibilityActivate else { return false }
        onAccessibilityActivate()
        return true
    }
}

/// The trailer's one small control (sound, or play when paused): drawn
/// small and quiet in the corner, touched through a 44 pt target.
final class AppleTrailerControlButton: UIButton {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let grow = max(0, (44 - bounds.width) / 2)
        return bounds.insetBy(dx: -grow, dy: -grow).contains(point)
    }
}

struct AppleYouTubeAutoPreview: UIViewRepresentable {
    let url: URL
    let artworkURL: URL?
    /// The caller's already-decoded still, when it has one. The cover shows it
    /// synchronously; without it the cover's own image load left the black
    /// iframe showing for as long as that load took (sim finding f).
    var artworkImage: CGImage? = nil
    let isLandscape: Bool
    @Binding var isPlaying: Bool
    @Binding var isMuted: Bool
    /// Set by an explicit "Play Trailer" press, never by autoplay: lifts the
    /// document's muted-only rule so `isMuted` can actually take the caller
    /// to audible (`ApplePlaybackSessionPolicy.trailer.requiresMutedWebPlayback`).
    var allowsSound = false
    @Binding var replayGeneration: Int
    let showsReplay: Bool
    /// The frame the caller's still fills, when this view is laid out
    /// larger than it (the hero's 16:9 box over a taller frame). The cover
    /// is cropped to it, so it paints exactly the pixels the still does —
    /// otherwise a tall still, aspect-filled into the wider box, showed a
    /// different part of the picture the moment the trailer went in.
    var coverSize: CGSize? = nil
    let onStateChange: (String, Bool, Int?) -> Void
    let onTap: () -> Void
    let onMute: () -> Void
    let onReplay: () -> Void
    /// Puts the mute/replay control this far from the top instead of at the
    /// bottom right (the iPhone title page draws its buttons over the bottom).
    var controlTopInset: CGFloat? = nil
    /// Set by the iPhone and iPad hero and title page: the art stays up until
    /// the trailer's crop is final (`AppleTrailerPictureSettle`), and it is
    /// never re-measured once seen. Unset, it reveals and then re-measures.
    var settlesPictureBeforeReveal = false
    /// The caller's frame is itself 16:9 (the iPhone title page's header):
    /// the player fills it exactly, with no crop zoom and no picture
    /// measuring, so the trailer is never zoomed after it appears (the
    /// Taskmaster zoom ~1 s in) and never cut off.
    var exactSlot = false

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var loadedURL: URL?
        var loadedLandscape: Bool?
        var lastMuted = true
        var lastAllowsSound = false
        var lastPlaying = true
        var lastReplayGeneration = 0
        var onStateChange: ((String, Bool, Int?) -> Void)?
        private weak var webView: WKWebView?
        private weak var container: PlayerContainer?
        private var playbackIntent = true
        private var revealGeneration = 0
        /// The YouTube frame's `<video>` has presented real frames since the
        /// last start (`AppleYouTubePreviewHTML.playerChromeScript`). The art
        /// holds until then, so the crossfade never runs over a black or
        /// still-buffering player (owner item 4: "flashes as it begins").
        private var framesPresented = false
        private var pendingRevealMuted: Bool?

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
            framesPresented = false
            pendingRevealMuted = nil
            container?.setPreviewVisible(false, animated: false)
            webView?.layer.removeAllAnimations()
            webView?.alpha = 1
        }

        /// `animated` crossfades back to the art (a trailer that ends or
        /// fails); `completion` runs once the art is fully up.
        func hidePreview(animated: Bool = false, completion: (() -> Void)? = nil) {
            playbackIntent = false
            revealGeneration += 1
            framesPresented = false
            pendingRevealMuted = nil
            lastPlaying = false
            container?.setPreviewVisible(false, animated: animated, completion: completion)
            webView?.layer.removeAllAnimations()
            webView?.alpha = 1
        }

        private func reveal(muted: Bool) {
            guard playbackIntent, let webView, let container else { return }
            let generation = revealGeneration
            if container.exactSlot {
                // A 16:9 player in a 16:9 slot: nothing to measure or crop.
                container.pictureWindow = 0...1
                container.hasMeasuredPicture = true
                container.layoutIfNeeded()
                webView.alpha = 1
                container.setPreviewVisible(true)
                appleTrace("trailer native reveal: exact 16:9 slot")
                onStateChange?("revealed", muted, nil)
                return
            }
            if container.settlesPictureBeforeReveal, AppleTrailerPictureSettle.snapshotsShowVideo {
                settlePicture(generation: generation, gate: AppleTrailerPictureSettle(), muted: muted)
                return
            }
            if !AppleTrailerPictureSettle.snapshotsShowVideo {
                // Nothing to measure on a device: show the whole raster now,
                // as the gate's unmeasured timeout did, minus the 8 s wait.
                container.pictureWindow = 0...1
                container.hasMeasuredPicture = true
                container.layoutIfNeeded()
                webView.alpha = 1
                container.setPreviewVisible(true)
                appleTrace("trailer native reveal: live viewport (device, unmeasured)")
                onStateChange?("revealed", muted, nil)
                return
            }
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
                appleTrace("trailer native reveal: live viewport")
                self.onStateChange?("revealed", muted, nil)
                if !container.hasMeasuredPicture {
                    self.scheduleRemeasure(generation: generation, remaining: 3)
                }
            }
        }

        /// Measures a frame every `pollInterval` under the art until the gate
        /// settles, applies that crop under the art, then fades the art away.
        private func settlePicture(generation: Int, gate: AppleTrailerPictureSettle, muted: Bool) {
            guard revealGeneration == generation, playbackIntent, let webView else { return }
            measurePicture(webView: webView) { [weak self] window in
                guard let self, self.revealGeneration == generation, self.playbackIntent,
                      let webView = self.webView, let container = self.container else { return }
                var gate = gate
                switch gate.record(window, size: container.bounds.size, at: Date()) {
                case .wait:
                    DispatchQueue.main.asyncAfter(deadline: .now() + AppleTrailerPictureSettle.pollInterval) { [weak self] in
                        self?.settlePicture(generation: generation, gate: gate, muted: muted)
                    }
                case let .reveal(window, settled):
                    appleTrace("trailer picture \(settled ? "settled" : "unsettled") window=\(window.map { "\($0.lowerBound)...\($0.upperBound)" } ?? "nil")")
                    container.pictureWindow = window ?? 0...1
                    container.hasMeasuredPicture = true
                    container.layoutIfNeeded()
                    webView.alpha = 1
                    container.setPreviewVisible(true)
                    appleTrace("trailer native reveal: live viewport")
                    self.onStateChange?("revealed", muted, nil)
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
                    appleTrace("trailer picture snapshot: no image")
                    completion(nil)
                    return
                }
                let window = AppleTrailerPreviewLayout.pictureWindow(in: cgImage)
                appleTrace("trailer picture snapshot: \(cgImage.width)x\(cgImage.height) window=\(window.map { "\($0.lowerBound)...\($0.upperBound)" } ?? "nil")")
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
            let duration = payload["duration"] as? Double ?? 0
            #if DEBUG && os(iOS)
            if state == "chromeProbe" {
                let items = payload["items"] as? [String] ?? []
                appleTrace("trailer chrome t=\(payload["t"] as? Double ?? -1) n=\(items.count) \(items.joined(separator: " | "))")
                return
            }
            #endif
            guard AppleTrailerArtFirstPolicy.acceptsMessage(
                messageKey: payload["videoKey"] as? String, currentKey: loadedURL?.lastPathComponent
            ) else {
                appleTrace("trailer ignored state from previous candidate")
                return
            }
            appleTrace("trailer iframe state=\(state) time=\(mediaTime) duration=\(duration) muted=\(muted) quality=\(quality) error=\(errorCode.map(String.init) ?? "none")")
            #if DEBUG && os(iOS)
            if state == "playing" { container?.probe?.begin() }
            #endif
            if state == AppleTrailerFirstFrameGate.framesState {
                framesPresented = true
                if let pending = pendingRevealMuted, playbackIntent {
                    pendingRevealMuted = nil
                    appleTrace("trailer first frames presented: revealing")
                    reveal(muted: pending)
                }
                return
            }
            if state == "revealed" {
                guard playbackIntent else { return }
                guard framesPresented else {
                    // The page saw PLAYING, but no frame has been drawn yet:
                    // hold the art, and reveal anyway after the cap rather
                    // than never (a WebKit without frame callbacks).
                    pendingRevealMuted = muted
                    let generation = revealGeneration
                    appleTrace("trailer waiting for first frames")
                    DispatchQueue.main.asyncAfter(deadline: .now() + AppleTrailerFirstFrameGate.cap) { [weak self] in
                        guard let self, self.revealGeneration == generation, self.playbackIntent,
                              let pending = self.pendingRevealMuted else { return }
                        self.pendingRevealMuted = nil
                        appleTrace("trailer first frames not reported: revealing at the cap")
                        self.reveal(muted: pending)
                    }
                    return
                }
                reveal(muted: muted)
                return
            } else if state == "ended" {
                // Acknowledge only after the art is back over the video. The
                // page pauses the player on this acknowledgement, never
                // before it, so the crossfade runs over live frames.
                hidePreview(animated: true) { [weak self] in
                    self?.webView?.evaluateJavaScript("window.completeTrailerEnd();", completionHandler: nil)
                }
            } else if state == "error" {
                hidePreview(animated: true)
            } else if state == "paused" {
                // At once: a paused YouTube player can paint related videos.
                hidePreview()
            } else if state == "concealed" {
                revealGeneration += 1
                container?.setPreviewVisible(false, animated: false)
                webView?.layer.removeAllAnimations()
                webView?.alpha = 1
            }
            onStateChange?(state, muted, errorCode)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            appleTrace("trailer web document loaded")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            reportNavigationFailure(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            reportNavigationFailure(error)
        }

        private func reportNavigationFailure(_ error: Error) {
            let failure = error as NSError
            guard failure.code != NSURLErrorCancelled else { return }
            appleTrace("trailer web load failed domain=\(failure.domain) code=\(failure.code)")
            hidePreview(animated: true)
            onStateChange?("error", lastMuted, nil)
        }

        /// WebKit's content process died under a trailer (the iPad sim's
        /// JIT trap, 2026-09-23): the dead page draws nothing, so the art
        /// crossfades back over it and the caller drops the video layer.
        /// Nothing reloads here: a page that crashed once is not retried.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            appleTrace("trailer web content process terminated")
            hidePreview(animated: true)
            onStateChange?(AppleTrailerArtFirstPolicy.webContentTerminatedState, lastMuted, nil)
        }
    }

    final class PlayerContainer: UIView {
        let webView: WKWebView
        /// Everything that stands in for the video until it has frames: the
        /// caller's still under the URL-loaded artwork. Faded as one on reveal.
        private let cover = UIView()
        private let artworkStill = UIImageView()
        private let artworkCover: UIView & UIContentView
        private var artworkURL: URL?
        let touchShield = AppleTrailerTouchShield(type: .custom)
        let muteButton = AppleTrailerControlButton(type: .system)
        var onTap: (() -> Void)?
        var onMute: (() -> Void)?
        var onPause: (() -> Void)?
        var onReplay: (() -> Void)?
        var isLandscape = false { didSet { setNeedsLayout() } }
        var controlTopInset: CGFloat? = nil { didSet { if oldValue != controlTopInset { setNeedsLayout() } } }
        var coverSize: CGSize? = nil { didSet { if oldValue != coverSize { setNeedsLayout() } } }
        var pictureWindow: ClosedRange<CGFloat> = 0...1 { didSet { setNeedsLayout() } }
        var hasMeasuredPicture = false
        var settlesPictureBeforeReveal = false
        var exactSlot = false { didSet { if oldValue != exactSlot { setNeedsLayout() } } }
        #if DEBUG && os(iOS)
        var probe: AppleHeroTrailerProbeIOS?
        #endif
        private var isPlaying = true
        private var showsReplay = false
        private var previewVisible = false
        var hasPlayedPreview = false

        init(frame: CGRect, messageHandler: WKScriptMessageHandler, artworkURL: URL?) {
            self.artworkURL = artworkURL
            artworkCover = UIHostingConfiguration {
                AppleCatalogArtwork(url: artworkURL)
            }.margins(.all, 0).makeContentView()
            let configuration = WKWebViewConfiguration()
            configuration.allowsInlineMediaPlayback = true
            configuration.mediaTypesRequiringUserActionForPlayback = []
            configuration.allowsPictureInPictureMediaPlayback = false
            configuration.allowsAirPlayForMediaPlayback = false
            configuration.websiteDataStore = .nonPersistent()
            configuration.userContentController.addUserScript(WKUserScript(
                source: ApplePlaybackSessionPolicy.trailer.webMediaSessionSuppressionScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            ))
            #if DEBUG && os(iOS)
            // `-OpenStreamTrailerNoChromeCSS YES` (N75): without the chrome CSS, to film what it hides.
            let injectsChromeCSS = !UserDefaults.standard.bool(forKey: "OpenStreamTrailerNoChromeCSS")
            #else
            let injectsChromeCSS = true
            #endif
            if injectsChromeCSS {
                configuration.userContentController.addUserScript(WKUserScript(
                    source: AppleYouTubePreviewHTML.playerChromeScript,
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: false
                ))
            }
            #if DEBUG && os(iOS)
            if UserDefaults.standard.bool(forKey: "OpenStreamHeroTrailerProbe") {
                configuration.userContentController.addUserScript(WKUserScript(
                    source: AppleHeroTrailerProbeIOS.frameChromeScript,
                    injectionTime: .atDocumentEnd,
                    forMainFrameOnly: false
                ))
            }
            #endif
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
            cover.isUserInteractionEnabled = false
            cover.accessibilityElementsHidden = true
            cover.clipsToBounds = true
            artworkStill.contentMode = .scaleAspectFill
            artworkStill.clipsToBounds = true
            artworkStill.accessibilityIgnoresInvertColors = true
            cover.addSubview(artworkStill)
            artworkCover.clipsToBounds = true
            cover.addSubview(artworkCover)
            addSubview(cover)

            // WKWebView can still become the effective UIKit touch surface
            // beneath SwiftUI's transparent layers. Keep the iframe entirely
            // non-interactive and put the two owned controls in this same
            // container so YouTube never receives a user gesture.
            touchShield.backgroundColor = .clear
            touchShield.accessibilityIdentifier = "detail.trailer.toggle"
            // A tap, never the button's own touch-up: that fired on any touch
            // lifting inside the shield, so the hero carousel's left swipe
            // over a playing preview paused it and the page under the swipe
            // took it as a tap (iOS 18.6 regression 2026-10-01). A tap
            // recognizer fails once the finger travels, and the swipe pages.
            touchShield.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapPreview)))
            touchShield.onAccessibilityActivate = { [weak self] in self?.tapPreview() }
            addSubview(touchShield)

            muteButton.tintColor = .white
            #if os(visionOS)
            muteButton.backgroundColor = .clear
            muteButton.hoverStyle = .init(effect: .highlight)
            #else
            muteButton.backgroundColor = .clear
            muteButton.layer.shadowColor = UIColor.black.cgColor
            muteButton.layer.shadowOpacity = 0.4
            muteButton.layer.shadowRadius = 3
            muteButton.layer.shadowOffset = .zero
            #endif
            #if os(visionOS)
            muteButton.clipsToBounds = true
            #else
            // The shadow draws outside the glyph's bounds.
            muteButton.clipsToBounds = false
            #endif
            muteButton.accessibilityIdentifier = "detail.trailer.mute"
            muteButton.addTarget(self, action: #selector(mutePreview), for: .primaryActionTriggered)
            addSubview(muteButton)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func layoutSubviews() {
            super.layoutSubviews()
            let viewport = exactSlot ? AppleTrailerPreviewLayout.slotFrame(in: bounds.size)
                : AppleTrailerPreviewLayout.playerFrame(in: bounds.size, isLandscape: isLandscape)
            let picture = exactSlot ? viewport : AppleTrailerPreviewLayout.playerFrame(
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
            if let coverSize, coverSize.width > 0, coverSize.height > 0 {
                cover.frame = CGRect(x: bounds.midX - coverSize.width / 2, y: bounds.midY - coverSize.height / 2,
                                     width: coverSize.width, height: coverSize.height)
            } else {
                cover.frame = bounds
            }
            // Pinned top-leading, as the SwiftUI still under it is
            // (`AppleRemoteImage` fills from its top-leading corner). Centred,
            // a wide backdrop showed another part of the picture for the
            // moments before the URL artwork above it drew: the art jumped
            // and flashed as the trailer view went in (owner item 4).
            if let size = artworkStill.image?.size, size.width > 0, size.height > 0 {
                let fill = AppleTrailerPreviewLayout.aspectFillFrame(of: size, in: cover.bounds.size)
                artworkStill.frame = CGRect(origin: .zero, size: fill.size)
            } else {
                artworkStill.frame = cover.bounds
            }
            artworkCover.frame = cover.bounds
            touchShield.frame = bounds
            // Placed in the part that is on screen: the hero's 16:9 view
            // overhangs its art frame, and a control at its own corner was
            // clipped off the screen.
            let visible = cover.frame.intersection(bounds)
            #if os(visionOS)
            let controlSide: CGFloat = 60
            muteButton.layer.cornerRadius = controlSide / 2
            muteButton.frame = CGRect(
                x: visible.maxX - 12 - controlSide,
                y: controlTopInset.map { visible.minY + $0 } ?? (visible.maxY - 12 - controlSide),
                width: controlSide, height: controlSide
            )
            #else
            // Paused: one play.fill centred on the picture. Playing: the sound
            // glyph in its corner. Both bare glyphs with a shadow, no ring
            // (Mythos §2.2, spec §4.3), each a 44 pt target or larger.
            let frame = AppleTrailerPreviewLayout.controlFrame(in: visible, paused: showsReplay,
                                                               topInset: controlTopInset)
            muteButton.frame = frame
            muteButton.layer.cornerRadius = 0
            #endif
            bringSubviewToFront(muteButton)
        }

        func updateControls(isPlaying: Bool, isMuted: Bool, showsReplay: Bool) {
            self.isPlaying = isPlaying
            if self.showsReplay != showsReplay { setNeedsLayout() }
            self.showsReplay = showsReplay
            #if !os(visionOS)
            muteButton.setPreferredSymbolConfiguration(
                UIImage.SymbolConfiguration(pointSize: showsReplay ? AppleTrailerPreviewLayout.pausedGlyphSize
                                                                   : AppleTrailerPreviewLayout.soundGlyphSize,
                                            weight: showsReplay ? .regular : .semibold),
                forImageIn: .normal)
            #endif
            updatePlaybackValue()
            touchShield.accessibilityLabel = isPlaying ? "Pause trailer preview" : "Play trailer preview"
            // One glyph in one quiet circle: paused shows play.fill, not a
            // play.circle inside the button's own circle (owner item 5).
            muteButton.setImage(
                UIImage(systemName: showsReplay
                    ? "play.fill"
                    : (isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")),
                for: .normal
            )
            muteButton.accessibilityLabel = showsReplay
                ? "Play trailer"
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

        func updateStill(_ image: CGImage?) {
            guard artworkStill.image?.cgImage !== image else { return }
            artworkStill.image = image.map { UIImage(cgImage: $0) }
            setNeedsLayout()
        }

        /// Reveal cross-fades the cover away over the live frames. Hiding
        /// crossfades it back when `animated` (the page acts on "ended" only
        /// in `completion`, once the video pixels are covered), and puts it
        /// back at once otherwise. Reduce Motion swaps instantly both ways.
        func setPreviewVisible(_ visible: Bool, animated: Bool = true, completion: (() -> Void)? = nil) {
            let wasVisible = previewVisible
            if visible != wasVisible { appleTrace("trailer cover \(visible ? "fading out" : "up")") }
            #if DEBUG && os(iOS)
            if visible, !wasVisible { probe?.markFade() }
            #endif
            previewVisible = visible
            if visible { hasPlayedPreview = true }
            cover.layer.removeAllAnimations()
            let duration = AppleTrailerArtFirstPolicy.crossfadeDuration(reduceMotion: UIAccessibility.isReduceMotionEnabled)
            if visible != wasVisible, animated, duration > 0 {
                UIView.animate(
                    withDuration: duration,
                    delay: 0,
                    options: [.curveEaseInOut, .beginFromCurrentState],
                    animations: { self.cover.alpha = visible ? 0 : 1 },
                    completion: { _ in completion?() }
                )
            } else {
                cover.alpha = visible ? 0 : 1
                completion?()
            }
            updatePlaybackValue()
        }

        /// Art-first: until the video is on screen nothing is added over the
        /// art and VoiceOver hears nothing about it — no "Loading", no
        /// control. Once it plays, the shield pauses it and speaks for it.
        private func updatePlaybackValue() {
            let loading = !hasPlayedPreview || (isPlaying && !previewVisible)
            touchShield.isAccessibilityElement = !loading
            touchShield.accessibilityValue = isPlaying ? "Playing" : "Paused"
            // Autoplay starts muted; once the video is up the sound control
            // shows, and turning sound on lifts the page's muted-only rule
            // (owner 2026-10-09: no sound and no way to unmute).
            muteButton.isHidden = !hasPlayedPreview || (!showsReplay && loading)
        }

        #if DEBUG && os(iOS)
        var probeCover: UIView? { cover }

        var probeGeometry: AppleHeroTrailerProbeGeometry {
            let still = artworkStill.image?.cgImage.map { CGSize(width: $0.width, height: $0.height) }
            let web = convert(webView.frame, to: nil)
            let picture = CGRect(x: web.minX, y: web.minY + web.height * pictureWindow.lowerBound, width: web.width,
                                 height: web.height * (pictureWindow.upperBound - pictureWindow.lowerBound))
            return AppleHeroTrailerProbeGeometry(
                hero: convert(cover.frame, to: nil),
                // The hero's SwiftUI still: aspect-fill, pinned top-leading.
                still: still.map { size in
                    let fill = AppleTrailerPreviewLayout.aspectFillFrame(of: size, in: cover.bounds.size)
                    return cover.convert(CGRect(origin: .zero, size: fill.size), to: nil)
                },
                // As UIKit draws it: `scaleAspectFill` centres the overhang.
                coverArt: still.map { size in
                    artworkStill.convert(AppleTrailerPreviewLayout.aspectFillFrame(of: size, in: artworkStill.bounds.size), to: nil)
                },
                urlArtworkShows: !artworkCover.isHidden && artworkCover.alpha > 0,
                web: web, picture: picture,
                coverOpacity: cover.layer.presentation()?.opacity ?? cover.layer.opacity)
        }
        #endif

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
        context.coordinator.lastAllowsSound = allowsSound
        context.coordinator.lastReplayGeneration = replayGeneration
        context.coordinator.setPlaybackIntent(isPlaying)
        let container = PlayerContainer(frame: .zero, messageHandler: context.coordinator, artworkURL: artworkURL)
        container.webView.navigationDelegate = context.coordinator
        container.updateStill(artworkImage)
        appleTrace("trailer view inserted, still=\(artworkImage.map { "\($0.width)px" } ?? "none")")
        container.isLandscape = isLandscape
        container.controlTopInset = controlTopInset
        container.coverSize = coverSize
        container.settlesPictureBeforeReveal = settlesPictureBeforeReveal
        container.exactSlot = exactSlot
        #if DEBUG && os(iOS)
        if settlesPictureBeforeReveal, let probe = AppleHeroTrailerProbeIOS.fromDefaults() {
            probe.container = container
            container.probe = probe
        }
        // `-OpenStreamHeroNoSettle YES`, as on the Mac: reveal, then
        // re-measure, for a before/after run on one build.
        if UserDefaults.standard.bool(forKey: "OpenStreamHeroNoSettle") {
            container.settlesPictureBeforeReveal = false
        }
        #endif
        container.onTap = onTap
        container.onMute = onMute
        container.onReplay = onReplay
        container.onPause = { [coordinator = context.coordinator] in coordinator.hidePreview() }
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
        view.onPause = { [coordinator = context.coordinator] in coordinator.hidePreview() }
        view.isLandscape = isLandscape
        view.controlTopInset = controlTopInset
        view.coverSize = coverSize
        view.exactSlot = exactSlot
        view.updateArtwork(artworkURL)
        view.updateStill(artworkImage)
        view.updateControls(
            isPlaying: isPlaying,
            isMuted: isMuted,
            showsReplay: showsReplay
        )
        // Rotation changes the crop geometry but must not tear down the
        // YouTube player. Keep the WKWebView alive and let layoutSubviews plus
        // the page resize handler update its frame in place.
        if context.coordinator.loadedURL != url {
            view.hasPlayedPreview = false
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
            if isPlaying, !ApplePlaybackSessionPolicy.prepareTrailerAudio(pressed: allowsSound) { return }
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
            guard ApplePlaybackSessionPolicy.prepareTrailerAudio(pressed: allowsSound) else { return }
            context.coordinator.lastReplayGeneration = replayGeneration
            context.coordinator.prepareForPlayback()
            view.webView.evaluateJavaScript("window.restartTrailer();", completionHandler: nil)
        }
        guard context.coordinator.lastMuted != isMuted || context.coordinator.lastAllowsSound != allowsSound else { return }
        context.coordinator.lastMuted = isMuted
        context.coordinator.lastAllowsSound = allowsSound
        // One call, carrying both flags: `allowsSound` and `isMuted` can
        // change together (a press unmutes and unlocks sound in the same
        // beat), and two separate bridge calls would race on which one the
        // page saw first.
        view.webView.evaluateJavaScript(
            AppleTrailerSoundBridge.allowsSoundJavascriptCommand(allowsSound: allowsSound, isMuted: isMuted),
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
        guard ApplePlaybackSessionPolicy.prepareTrailerAudio(pressed: allowsSound) else { return }
        context.coordinator.loadedURL = url
        context.coordinator.loadedLandscape = isLandscape
        context.coordinator.lastAllowsSound = allowsSound
        let html = AppleYouTubePreviewHTML.document(
            embedURL: url,
            startsPlaying: isPlaying,
            isLandscape: isLandscape,
            startsMuted: isMuted,
            allowsSound: allowsSound
        )
        appleTrace("trailer web load key=\(url.lastPathComponent) autoplay=\(isPlaying) allowsSound=\(allowsSound)")
        view.loadHTMLString(html, baseURL: URL(string: "https://openstream.app"))
    }
}
#endif

enum AppleTrailerPreviewLayout {
    /// The paused state's one `play.fill` and the sound glyph (Mythos §2.2).
    static let pausedGlyphSize: CGFloat = 44
    static let soundGlyphSize: CGFloat = 20
    /// The smallest touch target either control gets.
    static let minimumControlSide: CGFloat = 44
    static let pausedControlSide: CGFloat = 64
    static let controlInset: CGFloat = 4

    /// A 16:9 slot's player: exactly the slot, no crop zoom.
    static func slotFrame(in size: CGSize) -> CGRect {
        CGRect(origin: .zero, size: size)
    }

    /// Where the trailer's one control sits in the `visible` part of its
    /// view: paused, centred; playing, in the bottom-right corner, or
    /// `topInset` below the top when the caller's copy covers the bottom.
    static func controlFrame(in visible: CGRect, paused: Bool, topInset: CGFloat?) -> CGRect {
        if paused {
            let side = pausedControlSide
            return CGRect(x: visible.midX - side / 2, y: visible.midY - side / 2, width: side, height: side)
        }
        let side = minimumControlSide
        return CGRect(x: visible.maxX - controlInset - side,
                      y: topInset.map { visible.minY + $0 } ?? (visible.maxY - controlInset - side),
                      width: side, height: side)
    }

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

    /// The 16:9 player sized and centred to fill `size` exactly as a 16:9
    /// still does — aspect-fill, centre crop, no extra zoom (N30: the frame
    /// "jumped" when the video came in 1.3× larger than the art). The Mac
    /// hero draws it at its own still's geometry (`artMatchedFrame`).
    static func coverFrame(in size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return CGRect(origin: .zero, size: size) }
        return aspectFillFrame(of: CGSize(width: 16, height: 9), in: size)
    }

    /// The Mac hero's trailer frame over its art (N44): the 16:9 player at
    /// the art's own aspect-fill scale about the same centre — for a 16:9
    /// still, exactly the still's rect — so the crossfade from the art to
    /// its trailer never reads as a zoom. It was sized to crop a letterboxed
    /// trailer's mattes off the hero, which drew
    /// the picture 11–13 % larger than the art it replaced in a window under
    /// ~1,600 pt wide: the "grow" the owner still saw after N31. A letterboxed
    /// trailer's band is then made to cover the hero (N62). No still yet: as a 16:9 still would be drawn (`coverFrame`).
    /// A measured `pictureWindow` (the band inside the raster, mattes
    /// outside it) must still cover the hero: see `coveringPicture`.
    static func artMatchedFrame(in size: CGSize, art: CGSize?,
                                pictureWindow: ClosedRange<CGFloat> = 0...1) -> CGRect {
        guard let art, art.width > 0, art.height > 0 else {
            return coveringPicture(coverFrame(in: size), in: size, pictureWindow: pictureWindow)
        }
        let drawn = aspectFillFrame(of: art, in: size)
        let player = aspectFillFrame(of: CGSize(width: 16, height: 9), in: drawn.size)
        return coveringPicture(player.offsetBy(dx: drawn.minX, dy: drawn.minY), in: size, pictureWindow: pictureWindow)
    }

    /// N62 (owner): a letterboxed trailer played as a band with black above
    /// and below it in the hero, because its mattes are baked into the 16:9
    /// raster. The picture band must cover the hero like the art does. The
    /// raster keeps the art's frame when its band already covers the hero
    /// (a tall window, a full-width 3440 one); it moves up or down only as
    /// far as needed when the band is tall enough but off-centre; otherwise
    /// it grows just enough for the band to fill the hero's height, the
    /// band centred on the hero, the raster centred across it.
    static func coveringPicture(_ raster: CGRect, in size: CGSize,
                                pictureWindow: ClosedRange<CGFloat>) -> CGRect {
        let fraction = pictureWindow.upperBound - pictureWindow.lowerBound
        guard fraction > 0, fraction < 1, raster.height > 0, size.height > 0 else { return raster }
        let bandTop = raster.minY + raster.height * pictureWindow.lowerBound
        let bandBottom = raster.minY + raster.height * pictureWindow.upperBound
        if bandTop <= 0, bandBottom >= size.height { return raster }
        if raster.height * fraction >= size.height {
            let lowest = size.height - raster.height * pictureWindow.upperBound
            let highest = -raster.height * pictureWindow.lowerBound
            return CGRect(x: raster.minX, y: min(max(raster.minY, lowest), highest),
                          width: raster.width, height: raster.height)
        }
        let height = size.height / fraction
        let width = raster.width * height / raster.height
        let y = size.height / 2 - height * (pictureWindow.lowerBound + fraction / 2)
        return CGRect(x: raster.midX - width / 2, y: y, width: width, height: height)
    }

    /// The same aspect-fill rect for a still of `imageSize` — what the hero's
    /// art occupies, for the gate to compare the two.
    static func aspectFillFrame(of imageSize: CGSize, in size: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return CGRect(origin: .zero, size: size) }
        let scale = max(size.width / imageSize.width, size.height / imageSize.height)
        let width = imageSize.width * scale, height = imageSize.height * scale
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
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

// The title page's state, grouped so SwiftUI keeps a dozen dynamic properties
// for the page rather than sixty (N45).

private struct AppleTitlePageTrailerState {
    var isActive = false
    var isPlaying = false
    var hasStarted = false
    var muted = false
    /// An explicit press, not autoplay's guess — lifts the web player's
    /// muted-only rule so `muted` can actually go false
    /// (`ApplePlaybackSessionPolicy`, `AppleYouTubePreviewHTML`).
    var allowsSound = false
    /// The trailer playing or loading, held by key (`heroTrailerKey`); nil
    /// until one starts, when the hero offers the list's first.
    var pinnedKey: String?
    /// Every candidate failed: no trailer until the page is opened again.
    var gaveUp = false
    var portraitKeys: Set<String> = []
    var failedKeys: Set<String> = []
    var landscapeKeys: Set<String> = []
    var replayGeneration = 0
    var interactionGlyph: String?
    var interactionGeneration = 0
    /// The Trailers card last pressed; its card shows it is loading until
    /// the video is on screen (N69).
    var pressedKey: String?
    /// The hero is at the top of the page, so a press needs no scroll first.
    var heroAtTop = true
}

private struct AppleTitlePageHeroStill {
    /// The hero still's load; the trailer waits on it (art-first).
    var art = AppleTrailerArtFirstPolicy.Art.loading
    var image: CGImage?
}

/// The iPhone title page's 16:9 header art, held once chosen
/// (`AppleTitlePageSlotArt`).
private struct AppleTitlePageSlotArtState {
    var itemID: String?
    var chosen: AppleTitlePageSlotArt?
    var deadlinePassed = false
    var failed: Set<URL> = []
}

private struct AppleTitlePageWordmarkState {
    var state = AppleTitleLogoState.loading
    var loadResult: Bool?
    var graceExpired = false
}

private struct AppleTitlePageGeometry {
    var viewportSize: CGSize = .zero
    var safeAreaInsets = EdgeInsets()
}

private struct AppleTitlePagePrompts {
    var downloadActions = false
    var seasonDownloadActions = false
    #if DEBUG
    /// `OpenStreamDebugDownloadOptions`: the prompt shows the choices of a
    /// running download with no download behind it (N73).
    var optionsPreview = false
    #endif
    var streamPicker = false
    /// Apple TV's "Watch on…" page of services.
    var watchOnMenu = false
    /// "Open <Service> and search for <Title>" when nothing could be opened.
    var watchOnInstructions: AppleWatchOnInstructions?
}

private struct AppleTitlePageActionState {
    var isFavorite = false
    var rateChoicesExpanded = false
    var ratingSelectionGeneration = 0
}

private struct AppleTitlePagePlaybackState {
    var request: UUID?
    /// Which request has been resolved, and whether the opening auto-play
    /// has fired, so neither happens again when the page reappears.
    var ledger = ApplePlayRequestLedger()
    /// When Retry was pressed, so a failure that comes straight back still
    /// shows the loading state first (`ApplePlaybackFailureRecovery`).
    var retryStartedAt: ContinuousClock.Instant?
    var presentation: AppleStremioPlayerPresentation?
    var streamChoices: [AppleStremioHTTPPlaybackCandidate] = []
    /// A resolution picked in the Quality sheet for the next Play; nil is Automatic.
    var selectedQuality: AppleStreamQualityTier?
    var selectedLocalFile: AppleLibraryItem?
    var pickingStreams = false
    /// The service the previous episode played from, preferred for the next
    /// one (`AppleStremioCandidateRanking.playbackOrder`). Used once.
    var preferredServiceKey: String?
    /// The previous episode's audio and subtitle choices. Used once.
    var trackCarryOver: AppleTrackCarryOver?
    /// Every stream of the last press failed before anything played, on the
    /// OpenStream engine too; the player has closed and the page's alert
    /// says why.
    var unavailableMessage: String?
    /// The Native player's OpenStream fallback: the engine for the next press
    /// only. Used once.
    var engineOverride: ApplePlaybackEngineKind?
    /// The streams the Native player tried before that fallback; they go last.
    var fallbackTriedSources: Set<URL> = []
    /// "Start from Beginning": the next press plays from the top. Used once.
    var startsFromBeginning = false
    /// The press under way started from the top, so its OpenStream fallback
    /// does too.
    var pressFromBeginning = false
    /// A disc page's Play Disc / Skip to Movie / Titles choice for the next
    /// press. Used once.
    var disc: AppleDiscPlaybackChoice?
    /// What the engine read from this title's local file (format badges,
    /// disc titles), once per page.
    var localInspection: AppleLocalFileInspection?
}

private struct AppleTitlePageMetadataState {
    var details: AppleTMDBDetails?
    var fallbackArtwork: AppleArtworkResolver.Artwork?
    var previewAssets: AppleStremioPreviewAssets?
    var isPreparing = true
    // The item's canonical IMDB id, resolved via a meta add-on. Catalog add-ons
    // (RT, Streaming Catalogs) key items by non-IMDB ids that stream add-ons
    // can't resolve; this is the id actually used for episode + stream lookups.
    var resolvedMediaID: String?
    /// Services the viewer subscribes to that also carry this title. Empty
    /// unless they have opted in — see `AppleWatchProviderPolicy`.
    var watchProviders: [AppleWatchProvider] = []
    /// The title's per-service ids from Wikidata, fetched only when Watch on
    /// replaces Play (`AppleWatchOnPolicy`).
    var streamingIDs: AppleStreamingIDs?
    var rankedSuggestions: [AppleCatalogItem] = []
    /// The title page's schedule badge (iPhone and Mac), worked out once per
    /// episode list rather than on every redraw.
}

private struct AppleTitlePageEpisodeState {
    var episodes: [AppleStremioEpisode] = []
    var selectedSeason: Int?
    var selectedEpisodeID: String?
    var isLoading = false
    /// Set only when the current title's episode load has finished, so a
    /// superseded load clearing `isLoadingEpisodes` cannot surface the
    /// "not available" text while the newer fetch is still in flight.
    var loadFinished = false
}

private struct AppleTitlePageOfflineState {
    var serverDownloadsAllowed = false
    var downloadedEpisodeIDs = Set<String>()
    var downloadSeason: Int?
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
    /// The featured hero's landscape pair (Play / Details). The detail page's
    /// landscape pair uses `portraitIPadActionButtonWidth`.
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
    static let trailerCrossfadeDuration = AppleTrailerArtFirstPolicy.crossfadeDuration

    static let portraitTitleFontSize: CGFloat = 17
    /// iPad portrait's title slot under the hero: the Mac hero's wordmark
    /// box, and a large title when there is no wordmark.
    static let padTitleLogoMaxSize = CGSize(width: 360, height: 110)
    static let padTitleFontSize: CGFloat = 40

    /// An iPad episode card: about two and a half across upright, three and
    /// a half on its side, as the Apple TV app's iPad rail shows them.
    static func padEpisodeCardWidth(viewportWidth: CGFloat, isLandscape: Bool) -> CGFloat {
        guard viewportWidth > 0 else { return 300 }
        return min(360, max(260, viewportWidth / (isLandscape ? 3.6 : 2.6)))
    }

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
        case .portraitIPad, .landscapeIPad:
            // Landscape takes the portrait pill too. At 140 pt "Download
            // Season 1" truncated to "Download Se…" even at the smallest
            // scale the label allows (N60 iPad walk, 2026-09-25); 180 is the
            // width portrait already proved it fits in.
            return portraitIPadActionButtonWidth
        }
    }

    /// The smallest a pill's label may scale before it would truncate.
    static let actionButtonLabelMinimumScale: CGFloat = 0.8
    /// Between a pill's glyph and its label.
    static let actionButtonGlyphSpacing: CGFloat = 6

    /// The narrowest pill that shows a label `labelWidth` wide (at full size)
    /// without truncating, given the scale-down the label allows.
    static func actionButtonWidthFitting(labelWidth: CGFloat, glyphWidth: CGFloat) -> CGFloat {
        labelWidth * actionButtonLabelMinimumScale + actionButtonGlyphSpacing + glyphWidth
            + 2 * actionButtonHorizontalPadding
    }

    /// The fixed width a pill's label is drawn at, or `nil` to hug the label.
    /// At accessibility sizes no fixed width holds the label, so the pill
    /// hugs it and the label may take a second line instead of truncating.
    static func actionButtonLabelFrameWidth(_ width: CGFloat?, isAccessibilitySize: Bool) -> CGFloat? {
        isAccessibilitySize ? nil : (width ?? defaultActionButtonWidth)
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
    /// "TV-MA", "PG-13": a rating, not a capability.
    static func isContentRating(_ value: String) -> Bool {
        ["G", "PG", "PG-13", "R", "NC-17", "NR", "TV-Y", "TV-Y7", "TV-G", "TV-PG", "TV-14", "TV-MA"]
            .contains(value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())
    }

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
        guard let date = releaseDayFormatter.date(from: day), releaseDayFormatter.string(from: date) == day else {
            return AppleReleaseYearText.display(cleanValue)
        }
        return releaseDisplayFormatter.string(from: date)
    }

    // Built once: the title page's meta line asks on every redraw, and a
    // DateFormatter is expensive to make (N47). Neither is changed after
    // this, and formatting from several threads is safe.
    nonisolated(unsafe) private static let releaseDayFormatter = releaseFormatter("yyyy-MM-dd")
    nonisolated(unsafe) private static let releaseDisplayFormatter = releaseFormatter("MMM d, yyyy")

    private static func releaseFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        return formatter
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

    /// A badge that draws `text` as given, in the same grey outline: the
    /// stream format badges ("Dolby Vision", "Atmos", "5.1") are words, never
    /// the wordmark art `resolve` maps some of them to.
    init(text: String) {
        kind = .text(text)
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

struct AppleMediaPlayerPresentationModifier: ViewModifier {
    @Binding var presentation: AppleStremioPlayerPresentation?

    func body(content: Content) -> some View {
        #if os(visionOS)
        // Inside the app's one window, like the Mac, and not a second
        // "Player" window (owner, 2026-10-07). See `AppleVisionPlayerStage`.
        content.modifier(AppleVisionPlayerStagePresenter(presentation: $presentation))
        #elseif os(macOS)
        // The player takes over the window it was opened from — edge to
        // edge, over the toolbar and the tab bar — rather than a sheet. The
        // sheet was a 1024 x 576 card floating over the page (owner,
        // 2026-09-24); the Apple TV app's separate player window is the other
        // thing the owner did not want. See `AppleMacPlayerStage`.
        content.modifier(AppleMacPlayerStagePresenter(presentation: $presentation))
        #else
        content.fullScreenCover(item: $presentation) {
            AppleStremioPlayerView(presentation: $0)
                #if os(tvOS)
                // A player opened from a settings page (a share, a pasted
                // URL) inherited the form's white tint, and its "Playback
                // Failed" alert drew Retry white on the white focus fill
                // (full test 2026-10-01). The system tint flips with focus.
                .tint(nil)
                #endif
                #if os(iOS)
                // Opened from Search the keyboard's safe-area inset was still
                // applied under the cover, so the transport and its tap area
                // filled only the top ~458 pt on iPad until a rotation
                // (full test 2026-09-30). The player never takes text input.
                .ignoresSafeArea(.keyboard)
                .onAppear {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    AppleOrientationLock.shared.allowsLandscape = true
                }
                .onDisappear { AppleOrientationLock.shared.allowsLandscape = false }
                #endif
        }
        #endif
    }
}

extension AppleMediaServerLibraryStore {
    public static func mergedContinueWatching(local: [AppleCatalogItem], server: [AppleCatalogItem]) -> [AppleCatalogItem] {
        var merged = local
        var seen = Set(local.map { $0.mediaID })
        for item in server {
            if !seen.contains(item.mediaID) {
                seen.insert(item.mediaID)
                merged.append(item)
            }
        }
        return merged
    }
}

/// What each of a title page's opening requests came back with, so they can
/// run side by side and be applied in whatever order they finish.
private enum AppleDetailPrepareOutcome: Sendable {
    /// The canonical id, or nil when no add-on could map the catalog id.
    case identity(String?)
    /// A series' episodes; nil when the request was cancelled.
    case episodes([AppleStremioEpisode]?)
    case preview(AppleStremioPreviewAssets?)
    case details(AppleTMDBDetails?)
}

// MARK: - iPhone title page

/// The iPhone title page in portrait, after the Apple TV app's (N17;
/// INSPO-TEARDOWN §7, PDF pages 11–16): art from the top edge with the
/// wordmark, meta line and one state-derived button over it; the next episode
/// and the capability chips; the season menu and 16:9 episode cards; then
/// Trailers, Related, Cast & Crew, About, Information, Languages and
/// Accessibility — each only when there is real data for it. The back button
/// and navigation stay as they were. The Mac has its own title page (below);
/// iPad, landscape and every other platform keep the layout above.
extension AppleCatalogItemDetailView {
    private static let phoneSectionSpacing: CGFloat = 32
    private static let phoneInset: CGFloat = AppleDetailMetrics.portraitColumnInset

    var usesPhoneTitlePage: Bool {
        #if os(iOS)
        horizontalSizeClass == .compact && !isLandscapeLayout
        #else
        false
        #endif
    }

    /// The Mac title page (N18, below) replaces the Mac's detail page at
    /// every window size.
    var usesMacTitlePage: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    var phoneTitlePage: some View {
        let chips = titlePageCapabilityChips
        let credits = titlePageCredits
        let information = titlePageInformation
        let languages = titlePageLanguages
        let glossary = AppleTitlePagePolicy.accessibilityGlossary(chips: chips)
        return VStack(alignment: .leading, spacing: 0) {
            phoneHero
            phoneHeroFooter(chips: chips)
                .padding(.horizontal, Self.phoneInset)
            // Not lazy: the episodes sit right under the hero, on screen when
            // the page opens. Inside the LazyVStack below, a series pushed
            // from Discover hung iOS 18 for good: the lazy stack's height kept
            // changing while UIKit laid out the push's bottom bars, and each
            // change asked for another layout (2026-10-01, iOS 18.6 sim).
            if item.type == "series" {
                phoneEpisodesSection
                    .id("vision-episodes")
                    .padding(.top, Self.phoneSectionSpacing - 8)
            }
            // Lazy: the push builds only the sections on screen; the rest
            // are built as they scroll in, as Discover's shelves are (N47).
            LazyVStack(alignment: .leading, spacing: 0) {
                if !discTitles.isEmpty {
                    AppleDiscTitlesRow(titles: discTitles, horizontalInset: Self.phoneInset) { startDisc(.mainTitle, titleID: $0.id) }
                        .padding(.top, Self.phoneSectionSpacing)
                }
                if !titlePageTrailerKeys.isEmpty {
                    phoneTrailersSection
                        .padding(.top, Self.phoneSectionSpacing)
                }
                if !suggestedItems.isEmpty {
                    moreLikeThisSection(title: "Related")
                        .padding(.top, Self.phoneSectionSpacing - 8)
                }
                if !credits.isEmpty {
                    phoneCastSection(credits)
                        .padding(.top, Self.phoneSectionSpacing - 8)
                }
                if let summary = titlePageSynopsis {
                    phoneAboutSection(summary)
                        .padding(.top, Self.phoneSectionSpacing)
                }
                if !information.isEmpty {
                    phoneFactSection("Information", facts: information, identifier: "detail.information")
                        .padding(.top, Self.phoneSectionSpacing)
                }
                if !languages.isEmpty {
                    phoneFactSection("Languages", facts: languages, identifier: "detail.languages")
                        .padding(.top, Self.phoneSectionSpacing)
                }
                if !glossary.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        AppleTitlePageSectionTitle("Accessibility")
                        AppleTitlePageAccessibilityGlossary(entries: glossary)
                    }
                    .padding(.horizontal, Self.phoneInset)
                    .padding(.top, Self.phoneSectionSpacing)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("detail.accessibility")
                }
            }
        }
        .padding(.bottom, 24)
    }

    // MARK: Hero

    /// The 16:9 header (Mythos §5): the trailer plays in it exactly, so it
    /// is never cropped, zoomed or off centre, and the title block sits
    /// under it on black.
    private var phoneSlotHeight: CGFloat {
        AppleTitlePageSlotArt.slotHeight(width: viewportSize.width)
    }

    private var phoneHero: some View {
        VStack(spacing: 0) {
            phoneHeroStage
                .frame(maxWidth: .infinity)
                .frame(height: phoneSlotHeight)
                .clipped()
            VStack(spacing: 12) {
                phoneTitleLockup
                phoneMetadataLine
                phoneActionRow
                    .padding(.top, 4)
            }
            // Past accessibility 2 Play was clipped and the round buttons
            // hit the screen edges (iPhone 27 v2 re-run, AX-XXXL). The
            // episode text below the hero still follows the full size.
            .dynamicTypeSize(...DynamicTypeSize.accessibility2)
            .padding(.horizontal, Self.phoneInset)
            .padding(.top, 16)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity)
        }
        // Under the status bar, black; the slot starts below it.
        .padding(.top, pageGeometry.safeAreaInsets.top)
        .background(.black)
        // Where the hero sits in the page, read without a GeometryReader
        // in the tree or a preference climbing it on every scroll frame.
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named("detail-scroll"))
        } action: { frame in
            detailHeroFrameChanged(frame)
        }
        // With the navigation bar hidden, the page runs up under the status bar.
        .padding(.top, -pageGeometry.safeAreaInsets.top)
        .accessibilityElement(children: .contain)
    }

    /// The still and, once started, the trailer over it (art until its
    /// first frames, then a crossfade). No fade over the video.
    private var phoneHeroStage: some View {
        ZStack {
            phoneSlotArtwork
                .accessibilityHidden(true)
            heroTrailerStartButton
            #if os(iOS) || os(visionOS)
            // The slot is all video: the sound control sits bottom-right,
            // clear of the back and search buttons over its top.
            trailerPreview(exactSlot: true)
            #endif
        }
    }

    /// The header's still, chosen once (`AppleTitlePageSlotArt`); black
    /// until then, so the first art drawn is the final one.
    @ViewBuilder
    private var phoneSlotArtwork: some View {
        ZStack {
            Color.black
            if let art = phoneSlotArt {
                switch art {
                case .backdrop(let url):
                    AppleRemoteImage(url: url, placeholderSystemImage: "", onLoad: phoneSlotArtLoaded,
                                     onFailure: phoneSlotArtFailed, loadingFill: .black, fillAlignment: .center)
                case .posterCard(let url):
                    AppleRemoteImage(url: url, placeholderSystemImage: "", loadingFill: .black, fillAlignment: .center)
                        .blur(radius: 30)
                        .overlay(Color.black.opacity(0.35))
                    // Sized to a 2:3 poster: a fitted image in
                    // `AppleRemoteImage` is pinned to its leading edge.
                    AppleRemoteImage(url: url, contentMode: .fit, placeholderSystemImage: "", onLoad: phoneSlotArtLoaded,
                                     onFailure: phoneSlotArtFailed, loadingFill: .clear)
                        .frame(width: max(0, phoneSlotHeight - 24) * 2 / 3, height: max(0, phoneSlotHeight - 24))
                        .clipShape(.rect(cornerRadius: 8))
                }
            }
        }
        .id(phoneSlotArt?.url)
        .transition(.opacity)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: phoneSlotArt)
    }

    private func phoneSlotArtLoaded(_ image: CGImage) {
        heroStill.image = image
        heroStill.art = heroStill.art.settling(with: .loaded)
        fillTimeline.mark(.artwork)
    }

    /// The wordmark once it has drawn, otherwise the name in black-weight
    /// capitals; the space is held while the wordmark resolves.
    @ViewBuilder
    private var phoneTitleLockup: some View {
        let logoHeight: CGFloat = dynamicTypeSize.isAccessibilitySize ? 120 : AppleDetailMetrics.titleLogoMaxHeight
        switch titleLogoPresentation {
        case .text:
            Text(displayTitle.uppercased())
                .font(.system(size: min(max(phoneTitleSize, 34), dynamicTypeSize.isAccessibilitySize ? 58 : 48), weight: .black))
                .tracking(1)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .minimumScaleFactor(0.6)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.8), radius: 12, y: 2)
                .frame(maxWidth: .infinity)
                .accessibilityLabel(displayTitle)
                .accessibilityAddTraits(.isHeader)
        case .logo, .hidden:
            ZStack {
                if case .valid = titleWordmark.state, let logoURL = titleLogoURL {
                    AppleTrimmedTitleLogo(url: logoURL, alignment: .center) { loaded in
                        guard AppleTitleLogoPolicy.keepsLoadResult(loaded, shown: titleLogoPresentation) else { return }
                        titleWordmark.loadResult = loaded
                        if loaded { fillTimeline.mark(.wordmark) }
                    }
                    .opacity(titleLogoPresentation == .logo ? 1 : 0)
                }
            }
            .frame(maxWidth: 280)
            .frame(height: logoHeight)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(displayTitle)
            .accessibilityAddTraits(.isHeader)
            .accessibilityHidden(titleLogoPresentation != .logo)
        }
    }

    /// "Comedy · 2026 · 51 min": the first genre, the year for a film or the
    /// run for a series, and the running time.
    private var titlePageMetadataValues: [String] {
        var values: [String] = []
        let genres = pageMetadata.details?.genres.isEmpty == false ? pageMetadata.details?.genres ?? [] : item.genres ?? []
        if let genre = genres.first(where: { !$0.isEmpty }) { values.append(genre) }
        let year = pageMetadata.details?.year ?? item.year
        if item.type != "series", let year {
            values.append(String(year))
        } else if let release = AppleTitleMetadataPresentation.formattedReleaseInfo(displayReleaseInfo) {
            values.append(release)
        } else if let year {
            values.append(String(year))
        }
        if let minutes = pageMetadata.details?.runtimeMinutes, (1 ... 24 * 60).contains(minutes) {
            values.append(AppleTitleMetadataPresentation.formattedRuntime(minutes))
        }
        return values
    }

    @ViewBuilder
    private var phoneMetadataLine: some View {
        let values = titlePageMetadataValues
        let rating = AppleBillboardCopy.ratingBadge(pageMetadata.details?.contentRating ?? item.contentRating)
        if !values.isEmpty || rating != nil {
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(spacing: 6))
                : AnyLayout(HStackLayout(spacing: 8))
            layout {
                if !values.isEmpty {
                    Text(values.joined(separator: AppleBillboardCopy.separator))
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                }
                if let rating {
                    Text(rating)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .overlay {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .strokeBorder(.white.opacity(0.4), lineWidth: 1)
                        }
                        .accessibilityLabel("Rated \(rating)")
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var selectedEpisode: AppleStremioEpisode? {
        guard let selectedEpisodeID = episodeList.selectedEpisodeID else { return nil }
        return episodeList.episodes.first { $0.id == selectedEpisodeID }
    }

    /// The selected episode's runtime (or the title's), in seconds, so a
    /// provider's error clip can be told from the title at playback.
    private var expectedRuntime: Double? {
        let minutes = item.type == "series"
            ? selectedEpisode?.runtimeMinutes ?? pageMetadata.details?.runtimeMinutes
            : pageMetadata.details?.runtimeMinutes
        return minutes.map { Double($0) * 60 }
    }

    /// Whether anything on this page can start: a media-server or library
    /// title, files on a share matched to this title, a finished download, or
    /// an enabled add-on that serves streams — and, for a series, an episode
    /// list to play from.
    private var hasPlaybackRoute: Bool {
        if let reference = AppleXtreamReference.parse(item.mediaID) {
            return AppleXtreamLibraryStore.shared.source(reference)?.isEnabled == true
                && (item.type != "series" || !episodeList.episodes.isEmpty)
        }
        return AppleTitlePagePolicy.hasPlaybackRoute(
            item: item, sources: playbackSources,
            hasLocalGroup: hasMatchingLocalGroup,
            hasCompletedDownload: downloadCoordinator.state.isCompleted,
            episodesUnavailable: episodeListPresentation == .unavailable
        )
    }

    private var titlePagePrimaryAction: AppleTitlePagePolicy.PrimaryAction? {
        AppleTitlePagePolicy.titlePagePrimaryAction(
            type: item.type,
            progress: !titlePageIsCovered
                ? ApplePlaybackProgressFeed.shared.progress(for: progressRecordID, in: playbackStore)
                : playbackStore.progress(for: progressRecordID),
            selectedEpisode: selectedEpisode,
            isPlayable: hasPlaybackRoute,
            hasTrailer: trailerEmbedURL != nil,
            namesEpisode: true
        )
    }

    private var phoneActionRow: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 12))
            : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            if let watchOnAction {
                watchOnControl(watchOnAction) { phoneWatchOnLabel(watchOnAction.title) }
                    .buttonStyle(.plain)
            } else if let state = titlePagePrimaryButtonState {
                phonePrimaryButton(state)
                if isDiscTitle, !state.isTrailer { phoneSkipToMovieButton }
            }
            HStack(spacing: 12) {
                Button(action: toggleFavorite) {
                    AppleTitlePageRoundButtonLabel(
                        title: titleActions.isFavorite ? "Remove from My List" : "Add to My List",
                        systemImage: titleActions.isFavorite ? "checkmark" : "plus"
                    )
                    .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .accessibilityValue(titleActions.isFavorite ? "Saved" : "Not saved")
                .accessibilityIdentifier("detail.my-list")
                #if os(iOS)
                .sensoryFeedback(.selection, trigger: titleActions.isFavorite)
                #endif
                if showsDownloadAction {
                    phoneDownloadButton
                }
                phoneRateMenu
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("detail.icon-row")
        }
    }

    /// The one button's words and state, shared by the iPhone and the Mac.
    fileprivate struct TitlePagePrimaryButtonState {
        let title: String
        let isTrailer: Bool
        let isBusy: Bool
        let isEnabled: Bool
    }

    /// Nil when the page has no primary button (`titlePagePrimaryAction`).
    fileprivate var titlePagePrimaryButtonState: TitlePagePrimaryButtonState? {
        guard let action = titlePagePrimaryAction else { return nil }
        let isTrailer = action == .playTrailer
        let isBusy = !isTrailer && (playbackCoordinator.phase.isBusy || pageMetadata.isPreparing)
        let title: String = if isBusy {
            playbackCoordinator.phase.isBusy ? "Preparing" : "Loading"
        } else if !isTrailer, isDiscTitle {
            "Play Disc"
        } else {
            action.displayTitle(hasCompletedDownload: downloadCoordinator.state.isCompleted)
        }
        return TitlePagePrimaryButtonState(title: title, isTrailer: isTrailer, isBusy: isBusy,
                                           isEnabled: isTrailer || canStartPlayback)
    }

    private var offersStartFromBeginning: Bool {
        // A disc's Play Disc already starts from the top.
        AppleTitlePagePolicy.offersStartFromBeginning(titlePagePrimaryAction) && watchOnAction == nil && !isDiscTitle
    }

    /// The title (or the episode Resume names) from the top; its saved
    /// position is overwritten as it plays.
    private func startFromBeginning() {
        guard canStartPlayback else { return }
        playbackUI.startsFromBeginning = true
        playbackUI.request = UUID()
    }

    /// "Start from Beginning" in the one button's context menu on the iPhone,
    /// iPad, Mac and Vision Pro, beside Quality.
    @ViewBuilder
    private var playButtonMenuItems: some View {
        if isDiscTitle {
            Button("Skip to Movie", systemImage: "forward.end.fill") { startDisc(.mainTitle) }
        }
        if offersStartFromBeginning {
            Button("Start from Beginning", systemImage: "arrow.counterclockwise", action: startFromBeginning)
                .accessibilityIdentifier("detail.startOver")
        }
        Button("Quality", systemImage: "slider.horizontal.3") {
            Task { await chooseStreams() }
        }
    }

    /// Play (or resume), or the trailer when nothing here can play.
    fileprivate func performTitlePagePrimaryAction() {
        if titlePagePrimaryButtonState?.isTrailer == true {
            if let key = trailerKey { playTrailerInHero(key: key) }
        } else if isDiscTitle {
            startDisc(.menu)
        } else {
            playbackUI.request = UUID()
        }
    }

    private func phoneWatchOnLabel(_ title: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.up.forward.app")
                .accessibilityHidden(true)
            Text(title)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                .minimumScaleFactor(0.8)
        }
        .font(.body.weight(.semibold))
        .foregroundStyle(.black)
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, minHeight: 50)
        .background(.white, in: .rect(cornerRadius: 12, style: .continuous))
        .contentShape(.rect(cornerRadius: 12, style: .continuous))
    }

    /// The phone's Skip to Movie, the same size as Play Disc, quieter.
    private var phoneSkipToMovieButton: some View {
        Button { startDisc(.mainTitle) } label: {
            HStack(spacing: 8) {
                Image(systemName: "forward.end.fill")
                    .accessibilityHidden(true)
                Text("Skip to Movie")
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    .minimumScaleFactor(0.8)
            }
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(.white.opacity(0.14), in: .rect(cornerRadius: 12, style: .continuous))
            .contentShape(.rect(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!canStartPlayback || playbackCoordinator.phase.isBusy)
        .accessibilityIdentifier("detail.disc.skipToMovie")
    }

    private func phonePrimaryButton(_ state: TitlePagePrimaryButtonState) -> some View {
        let isBusy = state.isBusy
        let title = state.title
        return Button(action: performTitlePagePrimaryAction) {
            HStack(spacing: 8) {
                if isBusy, isDiscTitle {
                    AppleDiscSpinner(tint: .black)
                } else if isBusy {
                    ProgressView().tint(.black)
                } else {
                    Image(systemName: "play.fill")
                        .accessibilityHidden(true)
                }
                Text(title)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    .minimumScaleFactor(0.8)
                    // Two lines get their height rather than being clipped.
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.body.weight(.semibold))
            .foregroundStyle(.black)
            .padding(.horizontal, 20)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(.white, in: .rect(cornerRadius: 12, style: .continuous))
            .contentShape(.rect(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!state.isEnabled)
        .accessibilityLabel(isBusy ? "Preparing playback" : title)
        .accessibilityIdentifier("detail.play")
        .contextMenu {
            playButtonMenuItems
        }
    }

    private var phoneDownloadButton: some View {
        Button(action: performDownloadAction) {
            switch downloadGlyph {
            case .progress, .disc:
                AppleTitlePageRoundButtonLabel(title: downloadButtonLabel, systemImage: "arrow.down", showsProgress: true)
            case .systemImage(let name):
                AppleTitlePageRoundButtonLabel(title: downloadButtonLabel, systemImage: name)
            }
        }
        .buttonStyle(.plain)
        .disabled(pageMetadata.isPreparing || downloadCoordinator.state.isCompleted)
        .accessibilityIdentifier(item.type == "series" && !visibleEpisodes.isEmpty ? "detail.download.season" : "detail.download")
        .accessibilityLabel(downloadButtonLabel)
        .accessibilityValue(offlineAccessibilityValue)
    }

    /// The Rate menu's choices, on the iPhone and the Mac.
    fileprivate var titlePageRateChoices: some View {
        ForEach(AppleTitleRating.selectableCases, id: \.rawValue) { value in
            Button {
                selectRating(value)
            } label: {
                Label(value.title, systemImage: ratingGlyph(for: value, selected: rating == value))
            }
        }
    }

    @ViewBuilder
    private var phoneRateMenu: some View {
        #if os(tvOS)
        Menu {
            titlePageRateChoices
        } label: {
            AppleTitlePageRoundButtonLabel(title: "Rate", systemImage: ratingGlyph(for: rating, selected: rating != nil))
        }
        .appleBareMenu()
        .accessibilityLabel("Rate")
        .accessibilityValue(rating?.title ?? "Not rated")
        #else
        AppleTitlePageRatePicker(rating: rating, glyph: ratingGlyph(for:selected:), onSelect: selectRating) {
            AppleTitlePageRoundButtonLabel(title: "Rate", systemImage: ratingGlyph(for: rating, selected: rating != nil))
        }
        #endif
    }

    /// Under the hero, on black: the episode Play starts ("S4, E8 · Title"
    /// and its synopsis) — or, for a film, the synopsis — then the chips and
    /// any download status.
    private func phoneHeroFooter(chips: [String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Directly under the hero's action row above, in secondary
            // text — easier to spot than buried in the synopsis, but still
            // not a second Play (owner 2026-09-28).
            AppleWatchProviderRow(providers: alsoAvailableProviders)
            if item.type == "series", let episode = selectedEpisode,
               let heading = AppleTitlePagePolicy.nextEpisodeHeading(episode) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(heading)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 2)
                    if let overview = episode.overview {
                        AppleWordClampedText(text: overview, lines: dynamicTypeSize.isAccessibilitySize ? 5 : 3)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("detail.next-episode")
            } else if let summary = titlePageSynopsis {
                AppleWordClampedText(text: summary, lines: dynamicTypeSize.isAccessibilitySize ? 5 : 3)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
            }
            if !chips.isEmpty {
                AppleTitlePageChipRow(chips: chips)
            }
            if !titlePageStreamBadgesBesideChips(chips).isEmpty {
                AppleStreamFormatBadgeRow(badges: titlePageStreamBadgesBesideChips(chips))
            }
            if downloadCoordinator.state.ownsDownload, !seasonDownloads.isRunning {
                Text(downloadButtonLabel)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("detail.download.progress")
            }
            downloadFailureNotice
            seasonDownloadStatus
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The stream badges the chip row does not already show.
    private func titlePageStreamBadgesBesideChips(_ chips: [String]) -> [AppleStreamFormatBadge] {
        let titles = Set(AppleStreamFormatBadge.titles(titlePageStreamBadges, excludingCatalogBadges: chips))
        return titlePageStreamBadges.filter { titles.contains($0.title) }
    }

    private var titlePageSynopsis: String? {
        AppleMetadataPresentationPolicy.synopsis(catalog: item.summary, enriched: pageMetadata.details?.overview)
    }

    private var titlePageCapabilityChips: [String] {
        let badges = pageMetadata.details?.formatBadges.isEmpty == false
            ? pageMetadata.details?.formatBadges ?? []
            : item.formatBadges ?? []
        return AppleTitlePagePolicy.capabilityChips(formatBadges: badges)
    }

    // MARK: Episodes

    private var phoneCardWidth: CGFloat {
        let available = max(0, viewportSize.width - Self.phoneInset)
        return min(360, available * (dynamicTypeSize.isAccessibilitySize ? 0.86 : 0.74))
    }

    private var phoneEpisodesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            AppleTitlePageSeasonPicker(seasons: seasonNumbers, selection: $episodeList.selectedSeason, name: seasonName)
                .padding(.horizontal, Self.phoneInset)
            switch episodeListPresentation {
            case .loading:
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        AppleTitlePageEpisodePlaceholder(width: phoneCardWidth)
                        AppleTitlePageEpisodePlaceholder(width: phoneCardWidth)
                    }
                }
                .contentMargins(.horizontal, Self.phoneInset, for: .scrollContent)
                .scrollIndicators(.hidden)
                .scrollDisabled(true)
            case .unavailable:
                Text("Episodes aren’t available from the connected metadata sources.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Self.phoneInset)
            case .episodes:
                phoneEpisodeRail
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail.episodes")
    }

    /// The iPad's episodes: the heading and season menu across the page,
    /// the rail running to its edge like More Like This below it.
    private var padEpisodesSection: some View {
        let cardWidth = AppleDetailMetrics.padEpisodeCardWidth(viewportWidth: viewportSize.width,
                                                               isLandscape: isLandscapeLayout)
        return VStack(alignment: .leading, spacing: AppleDetailMetrics.sectionHeaderBottomSpacing) {
            episodeSectionHeader
                .padding(.horizontal, detailHorizontalInset)
            switch episodeListPresentation {
            case .loading:
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        AppleTitlePageEpisodePlaceholder(width: cardWidth)
                        AppleTitlePageEpisodePlaceholder(width: cardWidth)
                        AppleTitlePageEpisodePlaceholder(width: cardWidth)
                    }
                }
                .contentMargins(.horizontal, detailHorizontalInset, for: .scrollContent)
                .scrollIndicators(.hidden)
                .scrollDisabled(true)
            case .unavailable:
                Text("Episodes aren’t available from the connected metadata sources.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, detailHorizontalInset)
            case .episodes:
                episodeRail(cardWidth: cardWidth, inset: detailHorizontalInset)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail.episodes")
    }

    private var phoneEpisodeRail: some View {
        episodeRail(cardWidth: phoneCardWidth, inset: Self.phoneInset)
    }

    /// The Apple TV app's episode rail — the iPhone's, and the iPad's since
    /// N32 #10 (its list stopped at 83 % of the page beside a full-width
    /// More Like This).
    private func episodeRail(cardWidth: CGFloat, inset: CGFloat) -> some View {
        let saved = playbackStore.progress(for: progressRecordID)
        let watched = watchedEpisodeIDs
        let now = Date.now
        return ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(visibleEpisodes) { episode in
                        AppleTitlePageEpisodeCard(
                            episode: episode,
                            eyebrow: AppleTitlePagePolicy.episodeEyebrow(episode, now: now),
                            isWatched: watched.contains(episode.id),
                            isSelected: episodeList.selectedEpisodeID == episode.id,
                            progress: Self.progressFraction(saved, for: episode),
                            width: cardWidth,
                            seriesBackdropURL: episodeFallbackStillURL
                        ) {
                            episodeList.selectedEpisodeID = episode.id
                            playbackUI.request = UUID()
                        } accessory: {
                            episodeDownloadButton(episode)
                                .font(.body)
                                .foregroundStyle(.white.opacity(0.8))
                        }
                        .contextMenu { watchedMenuButton(episode, isWatched: watched.contains(episode.id)) }
                        .id(episode.id)
                    }
                }
                .appleShelfSnapTargets()
            }
            .contentMargins(.horizontal, inset, for: .scrollContent)
            .appleShelfTileSnapping()
            .scrollIndicators(.hidden)
            // Lands on the episode Play starts, as the Apple TV app does.
            .task(id: "\(episodeList.selectedSeason ?? -1):\(visibleEpisodes.count)") {
                guard let target = episodeList.selectedEpisodeID, target != visibleEpisodes.first?.id,
                      visibleEpisodes.contains(where: { $0.id == target }) else { return }
                proxy.scrollTo(target, anchor: .leading)
            }
        }
    }

    private static func progressFraction(_ saved: ApplePlaybackProgress?, for episode: AppleStremioEpisode) -> Double? {
        guard let saved, saved.partID == episode.id, saved.resumePosition != nil, saved.duration > 0 else { return nil }
        return saved.position / saved.duration
    }

    // MARK: Trailers

    /// The trailers the hero could play; ones already found to be portrait
    /// clips are left out, as the hero skips them.
    private var titlePageTrailerKeys: [String] {
        #if os(iOS) || os(macOS)
        trailerCandidates.filter { !heroTrailer.portraitKeys.contains($0) && !heroTrailer.failedKeys.contains($0) }
        #else
        []
        #endif
    }

    private var phoneTrailersSection: some View {
        let keys = titlePageTrailerKeys
        return VStack(alignment: .leading, spacing: 10) {
            AppleTitlePageSectionTitle("Trailers")
                .padding(.horizontal, Self.phoneInset)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(keys, id: \.self) { key in
                        let number = (keys.firstIndex(of: key) ?? 0) + 1
                        AppleTitlePageTrailerCard(
                            key: key,
                            caption: number == 1 ? "Trailer" : "Trailer \(number)",
                            width: phoneCardWidth,
                            isLoading: trailerCardIsLoading(key)
                        ) {
                            playTrailerInHero(key: key)
                        }
                    }
                }
                .appleShelfSnapTargets()
            }
            .contentMargins(.horizontal, Self.phoneInset, for: .scrollContent)
            .appleShelfTileSnapping()
            .scrollIndicators(.hidden)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail.trailers")
    }

    private func trailerCardIsLoading(_ key: String) -> Bool {
        AppleTrailerArtFirstPolicy.pressedCardIsLoading(
            cardKey: key, pressedKey: heroTrailer.pressedKey, videoIsOnScreen: heroTrailer.isPlaying
        )
    }

    /// Plays trailer `key` in the hero, scrolling back up to it first.
    private func playTrailerInHero(key: String) {
        #if os(iOS) || os(visionOS) || os(macOS)
        guard trailerCandidates.contains(key) || key == trailerKey else { return }
        let scrolls = !heroTrailer.heroAtTop
        appleTrace("title trailer press \(item.name) key=\(key) scrolls=\(scrolls) top=\(Int(pageGeometry.safeAreaInsets.top))")
        // The card says it is loading at once; the art stays in the hero.
        heroTrailer.pressedKey = key
        if scrolls {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.35)) {
                detailScrollPosition.scrollTo(edge: .top)
            }
        }
        Task { @MainActor in
            // Started after the scroll, or the hero's off-screen pause
            // (the frame preference) would stop it straight away. A hero
            // already at the top starts its trailer's load straight away.
            if scrolls {
                try? await Task.sleep(for: .milliseconds(reduceMotion ? 50 : 450))
            }
            // A later press won while this one waited (review of 28f7fb7).
            guard heroTrailer.pressedKey == key else { return }
            // An explicit press starts with sound — autoplay never does. Set
            // with the switch, not before it: set at the press, it unmuted the
            // trailer being replaced for the moment before the new one loaded.
            heroTrailer.muted = false
            heroTrailer.allowsSound = true
            appleTrace("trailer unmuted (explicit press)")
            if key == trailerKey, heroTrailer.hasStarted {
                restartTrailer()
                return
            }
            guard prepareTrailerAudio(pressed: true) else { return }
            heroTrailer.pinnedKey = key
            heroTrailer.gaveUp = false
            heroTrailer.failedKeys.remove(key)
            // One transaction: a web view first made paused loads its page
            // with autoplay off and waits on a second message to start.
            withAnimation(reduceMotion ? nil : .easeInOut(duration: AppleDetailMetrics.trailerCrossfadeDuration)) {
                heroTrailer.hasStarted = true
                heroTrailer.isActive = true
                heroTrailer.isPlaying = false
            }
        }
        #endif
    }

    // MARK: Cast, About, Information, Languages

    private var titlePageCredits: [AppleCreditPerson] {
        let details = pageMetadata.details
        let cast = details?.cast.isEmpty == false ? details?.cast ?? [] : item.cast ?? []
        let writers = details?.writers.isEmpty == false ? details?.writers ?? [] : item.writers ?? []
        return AppleTitlePagePolicy.credits(
            detailed: details?.castMembers ?? [],
            cast: cast,
            director: details?.director ?? item.director,
            writers: writers
        )
    }

    private func phoneCastSection(_ people: [AppleCreditPerson], inset: CGFloat = Self.phoneInset) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            AppleTitlePageSectionTitle("Cast & Crew")
                .padding(.horizontal, inset)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 4) {
                    ForEach(people) { person in
                        AppleTitlePageCreditPortrait(person: person)
                    }
                }
                .appleShelfSnapTargets()
            }
            // The portraits carry 8 pt either side, so the first lines up.
            .contentMargins(.horizontal, inset - 8, for: .scrollContent)
            .appleShelfTileSnapping()
            .scrollIndicators(.hidden)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail.cast")
    }

    private func phoneAboutSection(_ summary: String) -> some View {
        let genres = (pageMetadata.details?.genres.isEmpty == false ? pageMetadata.details?.genres ?? [] : item.genres ?? [])
            .prefix(2).joined(separator: AppleBillboardCopy.separator)
        return VStack(alignment: .leading, spacing: 12) {
            AppleTitlePageSectionTitle("About")
            VStack(alignment: .leading, spacing: 4) {
                Text(displayTitle)
                    .font(.headline)
                    .foregroundStyle(.white)
                if !genres.isEmpty {
                    Text(genres.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.6))
                }
                AppleMoreText(text: summary, lineLimit: 4)
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.top, 8)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.08), in: .rect(cornerRadius: 12, style: .continuous))
        }
        .padding(.horizontal, Self.phoneInset)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail.about")
    }

    private var titlePageInformation: [AppleTitlePagePolicy.Fact] {
        AppleTitlePagePolicy.information(
            year: pageMetadata.details?.year ?? item.year,
            releaseInfo: displayReleaseInfo,
            contentRating: pageMetadata.details?.contentRating ?? item.contentRating,
            countries: pageMetadata.details?.countries ?? []
        )
    }

    private var titlePageLanguages: [AppleTitlePagePolicy.Fact] {
        AppleTitlePagePolicy.languages(
            originalLanguage: pageMetadata.details?.originalLanguage,
            spokenLanguages: pageMetadata.details?.spokenLanguages ?? []
        )
    }

    private func phoneFactSection(_ title: String, facts: [AppleTitlePagePolicy.Fact], identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            AppleTitlePageSectionTitle(title)
            AppleTitlePageFactList(facts: facts)
        }
        .padding(.horizontal, Self.phoneInset)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}

// MARK: - Mac title page

#if os(macOS)
/// The Mac title page, after the Apple TV app's on the Mac (N18;
/// INSPO-TEARDOWN §7, PDF pages 11–16) and the iPhone's (N17), whose policy,
/// words and section views it shares: the art edge to edge from the top of
/// the window, under the toolbar, about two thirds of it tall
/// (`AppleTitlePageMacLayout`); bottom-left over the Mac hero's two fades the
/// wordmark, the meta line and rating, one state-derived button with round My
/// List, Download and Rate buttons, the episode Play starts (or the film's
/// synopsis) clamped with MORE, and the capability chips. Below, on the
/// Discover rails' inset and with their hover lift and ‹ › paging: the season
/// menu and 16:9 episode cards, Trailers, Related, Cast & Crew, then About and
/// the Information, Languages and Accessibility blocks side by side in a wide
/// window. A section with nothing real to say is left out. The toolbar, its
/// back button and the sidebar are the window's own and are not touched.
extension AppleCatalogItemDetailView {
    private var macLayout: AppleTitlePageMacLayout {
        AppleTitlePageMacLayout(contentWidth: viewportSize.width, windowHeight: viewportSize.height)
    }

    /// The Mac Discover rails' tile sizes and inset, so the title page's rails
    /// are the same rails.
    private var macRowStyle: AppleDiscoverRowStyle {
        .mac(contentWidth: viewportSize.width, inset: macLayout.horizontalInset)
    }

    var macTitlePage: some View {
        let layout = macLayout
        let chips = titlePageCapabilityChips
        let credits = titlePageCredits
        let reference = macReferenceBlocks(chips: chips)
        return VStack(alignment: .leading, spacing: 0) {
            macHero(layout: layout, chips: chips)
            // Lazy: the push builds only the sections on screen (the
            // episodes under a series' hero); the rest are built as they
            // scroll in, as Discover's shelves are (N47).
            LazyVStack(alignment: .leading, spacing: AppleTitlePageMacLayout.sectionSpacing) {
                if item.type == "series" {
                    macEpisodesSection(layout: layout)
                        .id("vision-episodes")
                }
                if !titlePageTrailerKeys.isEmpty {
                    macTrailersSection
                }
                if !suggestedItems.isEmpty {
                    AppleMediaShelf(title: "Related", headingIdentifier: "detail.more-like-this") {
                        suggestedCards(sizing: .catalog)
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("detail.more-like-this")
                }
                if !credits.isEmpty {
                    AppleMediaShelf(title: "Cast & Crew") {
                        ForEach(credits) { person in
                            AppleTitlePageCreditPortrait(person: person, side: AppleTitlePageMacLayout.portraitSide)
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("detail.cast")
                }
                if let summary = titlePageSynopsis {
                    macAboutSection(summary)
                        .padding(.horizontal, layout.horizontalInset)
                }
                if !reference.isEmpty {
                    macReferenceGrid(reference, layout: layout)
                        .padding(.horizontal, layout.horizontalInset)
                }
            }
            .padding(.top, 28)
            .padding(.bottom, 40)
        }
        .environment(\.appleDiscoverRows, macRowStyle)
    }

    // MARK: Hero

    private func macHero(layout: AppleTitlePageMacLayout, chips: [String]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            macTitleLockup(layout: layout)
                .padding(.bottom, 10)
            macMetadataLine
                .padding(.bottom, 18)
            macActionRow
            macHeroDetails(chips: chips)
                .padding(.top, 18)
        }
        .frame(width: layout.copyWidth, alignment: .leading)
        .padding(.leading, layout.horizontalInset)
        .padding(.bottom, AppleTitlePageMacLayout.heroBottomPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The copy is in the flow, anchored to the bottom of the art: in a
        // short window it grows the hero downwards onto black rather than
        // clipping the buttons.
        .frame(minHeight: layout.heroHeight, alignment: .bottomLeading)
        .background(alignment: .top) {
            macHeroStage
                .frame(maxWidth: .infinity)
                .frame(height: layout.heroHeight)
                .clipped()
        }
        .background(.black)
        // Where the hero sits in the page, read without a GeometryReader
        // in the tree or a preference climbing it on every scroll frame.
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named("detail-scroll"))
        } action: { frame in
            detailHeroFrameChanged(frame)
        }
        // From the top of the window, under the toolbar.
        .padding(.top, -pageGeometry.safeAreaInsets.top)
        .accessibilityElement(children: .contain)
    }

    /// The still — decoded once at one size, so a live resize never reloads
    /// it — the trailer over it once one has been started, the mute button
    /// while it plays, and the Mac hero's two fades.
    private var macHeroStage: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: toggleTrailerPlayback) {
                AppleRemoteImage(
                    url: heroArtworkURL,
                    placeholderSystemImage: "",
                    onLoad: { image in
                        heroStill.image = image
                        heroStill.art = heroStill.art.settling(with: .loaded)
                        fillTimeline.mark(.artwork)
                    },
                    onFailure: heroArtworkFailed,
                    keepsImageWhileReloading: true,
                    fixedPixelDimension: AppleMacHeroLayout.stillPixelDimension,
                    // Centred like the trailer's cover over it (N44).
                    fillAlignment: .center
                )
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .clipped()
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            // A key press lands here only while a trailer is up to pause.
            .focusable(heroTrailer.hasStarted)
            .accessibilityLabel(heroTrailer.isActive ? "Pause trailer" : "Play trailer")
            .accessibilityHidden(!heroTrailer.hasStarted && titlePageTrailerKeys.isEmpty)
            if trailerPreviewIsShown, let embedURL = trailerEmbedURL {
                AppleMacYouTubeHeroPreview(url: embedURL, artworkImage: heroStill.image,
                                           isPlaying: heroTrailer.isActive, isMuted: heroTrailer.muted,
                                           onStateChange: handleTrailerState)
                    // A card pressed again replays from the start: the Mac
                    // web view has no replay message, so it is made afresh
                    // (the still covers it again until the video is up).
                    .id(heroTrailer.replayGeneration)
                    // Only the frame offered, never the web view's own size
                    // (the zero-minimum lesson, 2026-09-22).
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                    .clipped()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .transition(.opacity)
            }
        }
        .overlay {
            AppleMacHeroFadeView(videoIsShowing: heroTrailer.hasStarted && heroTrailer.isPlaying)
                .allowsHitTesting(false)
                .animation(.easeInOut(duration: 0.6), value: heroTrailer.hasStarted && heroTrailer.isPlaying)
        }
        .overlay(alignment: .topTrailing) {
            // Nothing over the art until the video is really on screen.
            if heroTrailer.hasStarted, heroTrailer.isPlaying {
                AppleMacHeroMuteButton(isMuted: heroTrailer.muted) { heroTrailer.muted.toggle() }
                    .padding(.top, pageGeometry.safeAreaInsets.top + AppleMacHeroLayout.muteTopInset)
                    .padding(.trailing, AppleMacHeroLayout.muteTrailingInset)
            }
        }
        #if DEBUG
        // What holds a started trailer's web view back, for the N69 timeline.
        .onChange(of: trailerGateTrace, initial: true) { _, gate in appleTrace("title trailer gate \(gate)") }
        // `-OpenStreamDebugPlayTrailer YES` presses the first Trailers card
        // 6 s after the page has one, so a headless sweep can photograph a
        // trailer playing in the hero. Hung on the hero, not on the lazily
        // built Trailers row: a series' row is not built until it scrolls
        // in, so the press there came late or never (N69).
        .task(id: titlePageTrailerKeys.first) {
            guard UserDefaults.standard.bool(forKey: "OpenStreamDebugPlayTrailer"),
                  titlePageTrailerKeys.first != nil else { return }
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled, let key = titlePageTrailerKeys.first else { return }
            playTrailerInHero(key: key)
        }
        #endif
    }

    #if DEBUG
    private var trailerGateTrace: String {
        "started=\(heroTrailer.hasStarted) active=\(heroTrailer.isActive) url=\(trailerEmbedURL != nil) art=\(heroStill.art) busy=\(playbackCoordinator.phase.isBusy) presented=\(playbackUI.presentation != nil) shown=\(trailerPreviewIsShown)"
    }
    #endif

    /// The wordmark once it has drawn, otherwise the name in black weight;
    /// the slot is held while the wordmark resolves.
    @ViewBuilder
    private func macTitleLockup(layout: AppleTitlePageMacLayout) -> some View {
        switch titleLogoPresentation {
        case .text:
            Text(displayTitle)
                .font(.system(size: layout.titleFontSize, weight: .black))
                .tracking(-0.02 * layout.titleFontSize)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.6), radius: 10, y: 2)
                .accessibilityAddTraits(.isHeader)
        case .logo, .hidden:
            ZStack(alignment: .bottomLeading) {
                if case .valid = titleWordmark.state, let logoURL = titleLogoURL {
                    AppleTrimmedTitleLogo(url: logoURL, alignment: .bottomLeading) { loaded in
                        guard AppleTitleLogoPolicy.keepsLoadResult(loaded, shown: titleLogoPresentation) else { return }
                        titleWordmark.loadResult = loaded
                        if loaded { fillTimeline.mark(.wordmark) }
                    }
                    .opacity(titleLogoPresentation == .logo ? 1 : 0)
                }
            }
            .frame(width: min(AppleMacHeroLayout.wordmarkSize.width, layout.copyWidth),
                   height: AppleMacHeroLayout.wordmarkSize.height, alignment: .bottomLeading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(displayTitle)
            .accessibilityAddTraits(.isHeader)
            .accessibilityHidden(titleLogoPresentation != .logo)
        }
    }

    /// "Crime · 2025– · 47 min" and the outlined rating, as the Mac Discover
    /// hero draws its line.
    @ViewBuilder
    private var macMetadataLine: some View {
        let values = titlePageMetadataValues
        let rating = AppleBillboardCopy.ratingBadge(pageMetadata.details?.contentRating ?? item.contentRating)
        if !values.isEmpty || rating != nil {
            HStack(spacing: 8) {
                if !values.isEmpty {
                    Text(values.joined(separator: AppleBillboardCopy.separator))
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
                if let rating {
                    Text(rating)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .overlay {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(.white.opacity(0.35), lineWidth: 1)
                        }
                        .accessibilityLabel("Rated \(rating)")
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// The one white button and the round ones, with the Mac hero's hover
    /// and pressed states and a tooltip on each round one.
    private var macActionRow: some View {
        HStack(spacing: 12) {
            if let watchOnAction {
                watchOnControl(watchOnAction) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.up.forward.app")
                            .accessibilityHidden(true)
                        Text(watchOnAction.title)
                            .lineLimit(1)
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .frame(minWidth: 180)
                }
                .buttonStyle(AppleMacHeroButtonStyle(kind: .primary))
            } else if let state = titlePagePrimaryButtonState {
                Button(action: performTitlePagePrimaryAction) {
                    HStack(spacing: 8) {
                        if state.isBusy, isDiscTitle {
                            AppleDiscSpinner(tint: Color(white: 0.07), size: 13)
                        } else if state.isBusy {
                            ProgressView()
                                .controlSize(.small)
                                .tint(Color(white: 0.07))
                        } else {
                            Image(systemName: "play.fill")
                                .accessibilityHidden(true)
                        }
                        Text(state.title)
                            .lineLimit(1)
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .frame(minWidth: 180)
                }
                .buttonStyle(AppleMacHeroButtonStyle(kind: .primary))
                .disabled(!state.isEnabled)
                .accessibilityLabel(state.isBusy ? "Preparing playback" : state.title)
                .accessibilityIdentifier("detail.play")
                .contextMenu {
                    playButtonMenuItems
                }
            }

            Button(action: toggleFavorite) {
                AppleTitlePageMacRoundLabel(title: titleActions.isFavorite ? "Remove from My List" : "Add to My List",
                                            systemImage: titleActions.isFavorite ? "checkmark" : "plus")
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(AppleMacHeroButtonStyle(kind: .round))
            .help(titleActions.isFavorite ? "Remove from My List" : "Add to My List")
            .accessibilityValue(titleActions.isFavorite ? "Saved" : "Not saved")
            .accessibilityIdentifier("detail.my-list")

            if showsDownloadAction {
                Button(action: performDownloadAction) {
                    switch downloadGlyph {
                    case .progress, .disc:
                        AppleTitlePageMacRoundLabel(title: downloadButtonLabel, systemImage: "arrow.down", showsProgress: true)
                    case .systemImage(let name):
                        AppleTitlePageMacRoundLabel(title: downloadButtonLabel, systemImage: name)
                    }
                }
                .buttonStyle(AppleMacHeroButtonStyle(kind: .round))
                .disabled(pageMetadata.isPreparing || downloadCoordinator.state.isCompleted)
                .help(downloadButtonLabel)
                .accessibilityIdentifier(item.type == "series" && !visibleEpisodes.isEmpty ? "detail.download.season" : "detail.download")
                .accessibilityLabel(downloadButtonLabel)
                .accessibilityValue(offlineAccessibilityValue)
            }

            Menu {
                titlePageRateChoices
            } label: {
                AppleTitlePageMacRoundLabel(title: "Rate", systemImage: ratingGlyph(for: rating, selected: rating != nil))
            }
            .menuStyle(.button)
            .buttonStyle(AppleMacHeroButtonStyle(kind: .round))
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Rate")
            .accessibilityLabel("Rate")
            .accessibilityValue(rating?.title ?? "Not rated")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail.icon-row")
    }

    /// Under the buttons: the episode Play starts ("S1, E3 · Title" and its
    /// synopsis) or the film's synopsis, clamped with MORE; the chips; and
    /// any download status.
    private func macHeroDetails(chips: [String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if item.type == "series", let episode = selectedEpisode,
               let heading = AppleTitlePagePolicy.nextEpisodeHeading(episode) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(heading)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    if let overview = episode.overview {
                        AppleMoreText(text: overview, lineLimit: 3, style: .body)
                            .foregroundStyle(.white.opacity(0.75))
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("detail.next-episode")
            } else if let summary = titlePageSynopsis {
                AppleMoreText(text: summary, lineLimit: 3, style: .body)
                    .foregroundStyle(.white.opacity(0.75))
            }
            if !chips.isEmpty {
                AppleTitlePageChipRow(chips: chips)
            }
            if !titlePageStreamBadgesBesideChips(chips).isEmpty {
                AppleStreamFormatBadgeRow(badges: titlePageStreamBadgesBesideChips(chips))
            }
            if downloadCoordinator.state.ownsDownload, !seasonDownloads.isRunning {
                Text(downloadButtonLabel)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("detail.download.progress")
            }
            downloadFailureNotice
            seasonDownloadStatus
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Rails

    private func macEpisodesSection(layout: AppleTitlePageMacLayout) -> some View {
        let style = macRowStyle
        return VStack(alignment: .leading, spacing: 4) {
            AppleTitlePageSeasonPicker(seasons: seasonNumbers, selection: $episodeList.selectedSeason, name: seasonName)
                .padding(.horizontal, layout.horizontalInset)
            switch episodeListPresentation {
            case .loading:
                HStack(alignment: .top, spacing: style.cardGap) {
                    AppleTitlePageEpisodePlaceholder(width: style.stillWidth)
                    AppleTitlePageEpisodePlaceholder(width: style.stillWidth)
                    AppleTitlePageEpisodePlaceholder(width: style.stillWidth)
                }
                .padding(.horizontal, layout.horizontalInset)
                .padding(.vertical, 12)
            case .unavailable:
                Text("Episodes aren’t available from the connected metadata sources.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, layout.horizontalInset)
            case .episodes:
                macEpisodeRail(style: style)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail.episodes")
    }

    private func macEpisodeRail(style: AppleDiscoverRowStyle) -> some View {
        let saved = playbackStore.progress(for: progressRecordID)
        let watched = watchedEpisodeIDs
        let now = Date.now
        return AppleMacRail {
            LazyHStack(alignment: .top, spacing: style.cardGap) {
                ForEach(visibleEpisodes) { episode in
                    AppleTitlePageEpisodeCard(
                        episode: episode,
                        eyebrow: AppleTitlePagePolicy.episodeEyebrow(episode, now: now),
                        isWatched: watched.contains(episode.id),
                        isSelected: episodeList.selectedEpisodeID == episode.id,
                        progress: Self.progressFraction(saved, for: episode),
                        width: style.stillWidth,
                        seriesBackdropURL: episodeFallbackStillURL
                    ) {
                        episodeList.selectedEpisodeID = episode.id
                        playbackUI.request = UUID()
                    } accessory: {
                        episodeDownloadButton(episode)
                            .font(.body)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .contextMenu { watchedMenuButton(episode, isWatched: watched.contains(episode.id)) }
                    .id(episode.id)
                }
            }
            .padding(.horizontal, style.horizontalInset)
            .padding(.vertical, 12)
        }
    }

    private var macTrailersSection: some View {
        let keys = titlePageTrailerKeys
        let width = macRowStyle.stillWidth
        return AppleMediaShelf(title: "Trailers") {
            ForEach(keys, id: \.self) { key in
                let number = (keys.firstIndex(of: key) ?? 0) + 1
                AppleTitlePageTrailerCard(
                    key: key,
                    caption: number == 1 ? "Trailer" : "Trailer \(number)",
                    width: width,
                    isLoading: trailerCardIsLoading(key)
                ) {
                    playTrailerInHero(key: key)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail.trailers")
    }

    // MARK: About and reference

    private func macAboutSection(_ summary: String) -> some View {
        let genres = (pageMetadata.details?.genres.isEmpty == false ? pageMetadata.details?.genres ?? [] : item.genres ?? [])
            .prefix(2).joined(separator: AppleBillboardCopy.separator)
        return VStack(alignment: .leading, spacing: 12) {
            AppleTitlePageSectionTitle("About")
            VStack(alignment: .leading, spacing: 4) {
                Text(displayTitle)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                if !genres.isEmpty {
                    Text(genres.uppercased())
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.6))
                }
                AppleMoreText(text: summary, lineLimit: 4, style: .body)
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.top, 8)
            }
            .padding(20)
            .frame(maxWidth: AppleTitlePageMacLayout.aboutMaxWidth, alignment: .leading)
            .background(.white.opacity(0.08), in: .rect(cornerRadius: 12, style: .continuous))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail.about")
    }

    /// Information, Languages and Accessibility, each only when it has
    /// something real to say.
    private func macReferenceBlocks(chips: [String]) -> [AppleTitlePageMacReferenceBlock] {
        var blocks: [AppleTitlePageMacReferenceBlock] = []
        let information = titlePageInformation
        if !information.isEmpty { blocks.append(.facts(title: "Information", facts: information, identifier: "detail.information")) }
        let languages = titlePageLanguages
        if !languages.isEmpty { blocks.append(.facts(title: "Languages", facts: languages, identifier: "detail.languages")) }
        let glossary = AppleTitlePagePolicy.accessibilityGlossary(chips: chips)
        if !glossary.isEmpty { blocks.append(.accessibility(glossary)) }
        return blocks
    }

    private func macReferenceGrid(_ blocks: [AppleTitlePageMacReferenceBlock], layout: AppleTitlePageMacLayout) -> some View {
        let columns = layout.referenceColumns(count: blocks.count)
        // A lone block in a wide window spreads its facts instead.
        let factColumns = blocks.count == 1 ? layout.referenceColumns(count: AppleTitlePageMacLayout.maximumColumns) : 1
        let stack = columns > 1
            ? AnyLayout(HStackLayout(alignment: .top, spacing: AppleTitlePageMacLayout.columnSpacing))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: AppleTitlePageMacLayout.sectionSpacing))
        return stack {
            ForEach(blocks) { block in
                AppleTitlePageMacReferenceBlockView(block: block, factColumns: factColumns)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }
}
#endif

#if DEBUG
/// Review builds only: `-OpenStreamDebugStreamFixture YES` gives each title
/// page a stream add-on on 127.0.0.1:8765, so a simulator with only metadata
/// sources can photograph a playable page (Play naming its episode). It lives
/// in the page's own source list — never in the source store, a backup or
/// iCloud.
enum AppleTitlePageStreamFixture {
    /// `-OpenStreamDebugOpenQuality YES` (with the fixture): the page opens
    /// its Quality sheet once loaded, over the fixture's streams alone — no
    /// saved add-on is asked for streams and nothing plays (N38 proof).
    static var opensQuality: Bool {
        UserDefaults.standard.bool(forKey: "OpenStreamDebugStreamFixture")
            && UserDefaults.standard.bool(forKey: "OpenStreamDebugOpenQuality")
    }

    static var sources: [AppleSource] {
        guard UserDefaults.standard.bool(forKey: "OpenStreamDebugStreamFixture"),
              let url = URL(string: "http://127.0.0.1:8765/manifest.json") else { return [] }
        return [AppleSource(id: UUID(uuidString: "5E1F1C1E-0000-4000-8000-000000000019") ?? UUID(),
                            kind: .stremio, name: "Fixture Streams", url: url, resources: ["stream"])]
    }
}
#endif

typealias AppleStremioPlayerPresentationModifier = AppleMediaPlayerPresentationModifier
