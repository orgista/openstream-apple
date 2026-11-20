import SwiftUI
import Combine
import AVFoundation
import ImageIO
#if os(iOS) || os(visionOS)
import UIKit
import WebKit
import CoreFoundation
#endif

private func searchConfigurationIdentity(_ sources: [AppleSource]) -> String {
    sources
        .map { "\($0.id.uuidString)|\($0.configurationRevision)|\($0.isEnabled)|\($0.name)" }
        .joined(separator: ";")
}

/// Draws `content` only while its tab is selected. A hidden tab keeps what it last drew and reads none of
/// the stores, so another tab's loading (Live's lineup, a library scan) does not redraw or re-sort it.
private struct AppleHiddenTabGate<Content: View>: View {
    private final class Drawn {
        var content: Content?
    }

    let isActive: Bool
    @ViewBuilder let content: () -> Content
    @State private var drawn = Drawn()

    var body: some View {
        if isActive || drawn.content != nil {
            shown
        } else {
            Color.clear
        }
    }

    private var shown: Content {
        if !isActive, let page = drawn.content { return page }
        let page = content()
        drawn.content = page
        return page
    }
}

@MainActor
struct AppleDiscoverView: View {
    @Environment(\.appleIsLargeLayout) private var isLargeLayout
    @Environment(\.appleUsesPadLandingChrome) private var usesPadLandingChrome
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.displayScale) private var displayScale
    @Environment(\.scenePhase) private var scenePhase
    @ScaledMetric(relativeTo: .body) private var artworkCardWidth = 140.0
    @State private var viewportSize: CGSize = .zero
    /// The page's side safe areas, which the hero's art runs under (`AppleHeroSideBleed`).
    @State private var sideInsets = EdgeInsets()
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
    @State private var continueWatchingChangeRevision = 0
    @State private var loadedCache = false
    @State private var launchHold = AppleDiscoverLaunchHold.restoring
    @State private var launchHoldExpired = false
    @State private var launchWordmarkFailed = false
    @State private var launchHoldStarted: ContinuousClock.Instant?
    /// The lowest Discover row the lazy stack has made, for artwork lookahead.
    @State private var lowestShownRail = 0
    /// Captured when the first catalog arrives; only viewer changes restart
    /// the initial build, while catalog arrivals preserve its cache write.
    @State private var initialRecommendationContext: String?
    @State private var continueWatchingCacheReady = false
    /// False until the first load has read the index and the servers; until
    /// then an empty page is loading, not empty.
    @State private var hasSettled = false
    @State private var showsSearch = false
    /// The router revision Discover last acted on (see its `router.revision` `onChange`).
    @State private var handledRouteRevision = 0
    @State private var selectedHero: IndexedCatalogItem?
    @State private var selectedHeroAutoPlay = false
    @State private var showsSelectedHero = false
    @State private var showsContinueWatching = false
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
    @State private var ratingStoreRevision = AppleTitleRatingStore.revision
    @State private var relationRevision = AppleTMDBRelationCache.revision
    @State private var recommendations = RecommendationResult()
    @State private var recommendationsPublication = 0
    @State private var serverRowsPublication = 0
    @State private var chartPublication = 0
    @State private var displayedRailCache = AppleDiscoverRailCache<[DisplayedRail]>()
    @State private var featuredPin = FeaturedPin()
    @State private var serverRowCache = AppleDiscoverServerRows.Cache()
    @State private var homeServiceCache = AppleHomeServices.Cache()
    @State private var recentlyAddedCache = RecentlyAddedCache()
    @State private var serverRows: [AppleDiscoverServerRows.Row] = []
    @State private var displayedRailOrder: [DiscoverRail] = []
    @State private var recommendationsRevision: String?
    @State private var top10: AppleTop10Store.Chart?
    @State private var visibleTop10: AppleTop10Store.Chart?
    @State private var publishedContinueWatching: AppleDiscoverContinueWatchingPublication.Snapshot?
    @State private var visibleTop10SourceIdentity = ""
    @State private var library = AppleLocalLibraryStore.shared
    /// The heroes (media ids) whose wordmark lookup has finished; until then
    /// a hero with no wordmark yet holds its title slot empty rather than
    /// drawing the name a found logo would replace (N63).
    @State private var heroWordmarksResolved: Set<String> = []
    /// Textless hero art, keyed by media id. The first saved hero's upgrade
    /// is restored with its deck; the other pages load as the carousel mounts.
    @State private var heroArtwork: [String: AppleHeroArtworkUpgrade.Artwork] = [:]
    /// The hero list that last held still for `AppleHeroTrailerGate.settleDelay`.
    @State private var settledHeroes: AppleHeroTrailerGate.SettlementInput?

    let sourceStore: AppleSourceStore
    let mediaIndex: AppleMediaIndexStore
    let mediaServerLibrary: AppleMediaServerLibraryStore
    let router: AppleAppRouter
    let settings: AppleSettingsStore
    let openSettings: () -> Void
    /// Backup & Sync, for No Sources' restore and import. Nil until the root
    /// view has made it.
    let backupController: AppleConfigurationController?
    /// Discover is the selected tab (`AppleHiddenTabGate`).
    let isActive: Bool

    struct IndexedCatalogItem: Identifiable, Equatable, Sendable {
        let record: AppleMediaRecord
        let item: AppleCatalogItem
        let source: AppleSource
        var continueWatchingUpdatedAt: Date? = nil
        var continueWatchingInfo: AppleContinueWatchingTileInfo? = nil
        /// Playback keys of a library title's files, so its watch state counts.
        var progressKeys: [String] = []
        /// When a library title was added.
        var addedAt: Date? = nil
        var localGroupID: String? = nil
        var id: String { record.id }
    }

    nonisolated static func showsLoadingContent(hasContent: Bool, isLoading: Bool) -> Bool {
        isLoading && !hasContent
    }

    struct RecommendationResult: Sendable {
        var continueWatching: [IndexedCatalogItem] = []
        var heroes: [IndexedCatalogItem] = []
        var seedRows: [SeedRow] = []
        var featuredMovies: [IndexedCatalogItem] = []
        var featuredShows: [IndexedCatalogItem] = []
        /// Every title this pass could put in the Movies or TV Shows row,
        /// before the cut to `featuredLimit`.
        var featuredIdentities: Set<String> = []
    }

    /// A prepared recommendation row rendered by the shared shelf.
    struct SeedRow: Sendable {
        let heading: String
        let items: [IndexedCatalogItem]
        var minimumCount: Int = AppleRecommendationRowPolicy.minimumItems
    }

    /// Capture actor-owned data once, then transfer only immutable values.
    struct RecommendationSnapshot: Sendable {
        let relations: [AppleTMDBRelation]
        let sources: [AppleSource]
        let records: [AppleMediaRecord]
        let progress: [String: ApplePlaybackProgress]
        let activity: [String: ApplePlaybackProgress]
        let completed: [String: Date]
        let unwatched: [String: Date]
        let removed: [String: Date]
        let ratings: [String: AppleTitleRating]
        let serverContinueWatching: [IndexedCatalogItem]
        let serverShelves: [AppleMediaServerLibraryStore.Shelf]
        let artwork: [String: AppleHeroArtworkUpgrade.Artwork]
        let debugHeroTitle: String?
        let now: Date
        var localItems: [IndexedCatalogItem] = []
        var trending: [AppleCatalogItem] = []
        /// The newest library titles, ranked for Top Picks and the seed rows.
        var libraryItems: [IndexedCatalogItem] = []
    }

    /// How many of the newest library titles the ranker weighs.
    nonisolated static let rankedLibraryLimit = 800

    init(
        sourceStore: AppleSourceStore,
        mediaIndex: AppleMediaIndexStore,
        mediaServerLibrary: AppleMediaServerLibraryStore,
        router: AppleAppRouter,
        settings: AppleSettingsStore,
        openSettings: @escaping () -> Void,
        backupController: AppleConfigurationController? = nil,
        isActive: Bool = true
    ) {
        self.sourceStore = sourceStore
        self.mediaIndex = mediaIndex
        self.mediaServerLibrary = mediaServerLibrary
        self.router = router
        self.settings = settings
        self.openSettings = openSettings
        self.backupController = backupController
        self.isActive = isActive
    }

    var body: some View {
        AppleHiddenTabGate(isActive: isActive) { page }
    }

    @ViewBuilder
    private var page: some View {
        let continueWatching = shownContinueWatching
        let serverRows = serverRows
        let rails = displayedRails(continueWatching: continueWatching, serverRows: serverRows)
        let top10PublicationSnapshot = top10CandidateRevision
        let continueWatchingPublicationSnapshot = continueWatchingCandidateRevision
        let launchArtworkID = startupArtworkID
        let heroes = recommendations.heroes
        let heroSettlement = AppleHeroTrailerGate.SettlementInput(heroIDs: heroes.map(\.id), catalogReviewDone: true)
        let recommendationRevision = recommendationRevision
        let hasContent = !heroes.isEmpty || AppleCatalogShelfPolicy.hasDiscoverContent(
            hasLocalLibrary: !library.groups.isEmpty,
            hasMediaServerItems: mediaServerLibrary.shelves.contains { !$0.items.isEmpty }
                || !AppleXtreamLibraryStore.shared.continueWatching.isEmpty,
            hasTop10: !(shownTop10?.items.isEmpty ?? true)
        )
        let launchContent = AppleDiscoverLaunchHold.content(launchHold)
        Group {
            if launchContent == .page && !hasContent && !discoverIsLoading && !reviewLoadingState {
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
                        if launchContent == .blank {
                            // The saved deck and its hero still are a moment away.
                        } else if Self.showsLoadingContent(hasContent: hasContent, isLoading: discoverIsLoading) || reviewLoadingState {
                            AppleDiscoverLoadingContent(presentation: heroPresentation, viewport: viewportSize,
                                phoneLayout: phoneHeroLayout, wideLayout: usesPadHero ? padHeroLayout : macHeroLayout,
                                rowStyle: discoverRowStyle)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel("Loading")
                                .accessibilityIdentifier("home.loading")
                                .allowsHitTesting(false)
                                .transaction { $0.animation = nil }
                        } else {
                            // The billboard cycles through the candidates. Only
                            // this subtree re-renders on the tick; the shelves
                            // below it are untouched.
                            if !heroes.isEmpty {
                                #if DEBUG
                                let _ = AppleLaunchClock.mark("discover.hero")
                                #endif
                                AppleHomeHeroCarousel(
                                    pageIDs: heroes.map(\.id), items: heroes.map { Self.heroItem($0.item, artwork: heroArtwork) },
                                    wordmarks: heroes.map { Self.heroItem($0.item, artwork: heroArtwork).logoURL },
                                    viewportSize: viewportSize, phoneLayout: phoneHeroLayout,
                                    wideLayout: usesPadHero ? padHeroLayout : macHeroLayout
                                ) { index, failed, mode, count, shown, tv in
                                    featuredHero(heroes[index], rotationCount: count, rotationIndex: shown,
                                        wordmarkFailed: failed || (index == 0 && launchWordmarkFailed), phone: mode == .phone, mac: mode == .mac,
                                        pad: mode == .pad, tv: tv)
                                }
                                .environment(\.appleHeroesSettled, heroSettlement.isSettled(by: settledHeroes))
                                #if os(iOS)
                                .modifier(AppleHeroSideBleed(insets: sideInsets))
                                #endif
                                .task(id: heroSettlement) {
                                    settledHeroes = nil
                                    guard heroSettlement.catalogReviewDone else { return }
                                    do { try await Task.sleep(for: AppleHeroTrailerGate.settleDelay) } catch { return }
                                    guard !Task.isCancelled else { return }
                                    settledHeroes = heroSettlement
                                }
                                .task(id: heroes.map(\.item.mediaID).joined(separator: ",")) {
                                    // Only after the billboard has drawn: the
                                    // textless backdrop is an upgrade, never
                                    // something first paint waits on.
                                    await upgradeHeroArtwork(heroes)
                                }
                            }

                            ForEach(rails) { row in
                                railView(row.rail, continueWatching: continueWatching, payload: row.payload, serverRows: serverRows)
                                    .environment(\.appleHomeRowContext, homeRowContext(row.rail, payload: row.payload))
                                    #if DEBUG
                                    .accessibilityElement(children: .contain)
                                    .accessibilityIdentifier("home.row.\(row.rail)")
                                    #endif
                                    .onAppear {
                                        if let index = rails.firstIndex(where: { $0.id == row.id }), index > lowestShownRail {
                                            lowestShownRail = index
                                        }
                                        if case .mediaServer = row.rail { AppleLaunchMarks.record(.serverRowShown) }
                                        if row.id == rails.first?.id, launchContent != .hidden {
                                            AppleLaunchMarks.record(.firstRow, rowTitle(row.rail, serverRows: serverRows))
                                        }
                                    }
                            }
                        }
                    }
                    #if os(tvOS)
                    .padding(.bottom, AppleTVBillboardMetrics.contentBottomInset)
                    #else
                    .padding(.vertical)
                    #endif
                    .environment(\.appleDiscoverRows, discoverRowStyle)
                    .opacity(launchContent == .hidden ? 0 : 1)
                    .allowsHitTesting(launchContent != .hidden)
                    .accessibilityHidden(launchContent == .hidden)
                }
                .scrollIndicators(AppleDesignTokens.scrollIndicatorVisibility)
                #if os(iOS)
                .scrollClipDisabled(sideInsets != EdgeInsets())
                #endif
                #if os(iOS) || os(visionOS)
                .refreshable { await refreshContent() }
                #endif
                #if DEBUG
                .scrollPosition($reviewScrollPosition)
                #endif
                #if os(iOS) || os(visionOS)
                .modifier(AppleDiscoverHeroLayoutReader(page: "discover", phone: $phoneHeroLayout, pad: $padHeroLayout))
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
        .navigationDestination(isPresented: $showsContinueWatching) {
            let shelf = recommendations.continueWatching
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    continueWatchingCards(shelf)
                }
                .padding()
            }
            .task(id: recommendationRevision) {
                // A cached rail can open before Discover finishes its index load.
                if !loadedCache && !continueWatchingCacheReady {
                    await mediaIndex.load()
                    guard !Task.isCancelled else { return }
                    mediaIndex.beginSynchronizingPlaybackProgress()
                    continueWatchingCacheReady = true
                }
                await rebuildRecommendations(for: recommendationRevision)
            }
            .navigationTitle("Continue Watching")
            .scrollIndicators(.never)
            .environment(\.appleDiscoverRows, discoverRowStyle)
            .environment(\.appleTabToolbar, tabToolbarContext)
        }
        .navigationDestination(isPresented: $showsSelectedHero) {
            if let selectedHero {
                detail(selectedHero, initialAutoPlay: selectedHeroAutoPlay)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: ApplePlaybackProgressFeed.continueWatchingChangeNotification)) { _ in
            continueWatchingChangeRevision &+= 1
        }
        .task(id: continueWatchingChangeRevision) {
            guard continueWatchingChangeRevision > 0 else { return }
            do { try await Task.sleep(for: AppleContinueWatchingResolver.refreshDelay) } catch { return }
            continueWatchingRemovalRevision &+= 1
        }
        .task(id: recommendationRevision) {
            if recommendationsRevision == nil, initialRecommendationContext != nil || hasInitialRecommendationCatalog {
                initialRecommendationContext = recommendationCacheRevision
                return
            }
            await rebuildRecommendations(for: recommendationRevision)
        }
        // Catalog arrivals must not cancel the first build; viewer changes must retry it.
        .task(id: initialRecommendationContext.map { "\(loadedCache)|\($0)" }) {
            guard loadedCache, let initialRecommendationContext, recommendations.heroes.isEmpty else { return }
            await rebuildRecommendations(for: recommendationRevision, initialContext: initialRecommendationContext)
        }
        .onReceive(NotificationCenter.default.publisher(for: AppleTitleRatingStore.changeNotification)
            .receive(on: RunLoop.main)) { _ in
                ratingStoreRevision = AppleTitleRatingStore.revision
            }
        .onReceive(NotificationCenter.default.publisher(for: AppleTMDBRelationCache.changeNotification)
            .receive(on: RunLoop.main)) { _ in relationRevision = AppleTMDBRelationCache.revision }
        .environment(\.appleTMDBConfiguration, metadataConfiguration)
        .environment(\.appleHeroReturnRevision, router.revision)
        .environment(\.appleReportsLaunchRows, false)
        #if os(visionOS)
        .buttonStyle(.plain)
        #endif
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { viewportSize = AppleHomePageViewport.settled(drawn: viewportSize, measured: $0) }
        #if os(iOS)
        .onGeometryChange(for: EdgeInsets.self, of: AppleHeroSideBleed.sides) { sideInsets = $0 }
        #endif
        // tvOS: no toolbar items. Search is its own tab there and the catalog
        // refreshes on appear, so nothing floats over the billboard (X4).
        #if !os(tvOS)
        .toolbar {
            #if os(iOS)
            if usesPadLandingChrome {
                AppleTabToolbar(tab: .home, isRefreshing: isRefreshing,
                                onSearch: { showsSearch = true }, onRefresh: refresh)
            }
            #else
            AppleTabToolbar(tab: .home, isRefreshing: isRefreshing,
                            onSearch: { showsSearch = true }, onRefresh: refresh)
            #endif
        }
        #endif
        #if os(iOS)
        .modifier(ApplePhoneLandingChrome(title: "Discover", identifier: "discover.compact-title",
            hasHero: !heroes.isEmpty && hasContent && !reviewLoadingState,
            isRefreshing: isRefreshing,
            onSearch: { showsSearch = true }, onRefresh: refresh, accessory: { EmptyView() }))
        #endif
        #if os(macOS)
        .onChange(of: AppleMacCommandCenter.shared.refreshRevision) {
            guard AppleMacCommandCenter.shared.refreshTarget == .discover, !isRefreshing else { return }
            appleTrace("discover refresh from the menu")
            refresh()
        }
        #endif
        #if DEBUG
        .navigationDestination(isPresented: $visionReviewDetail) {
            if let value = visionReviewItem { detail(value, initialAutoPlay: visionReviewAutoPlay) }
        }
        // Again once a media server's titles arrive: a local library can make
        // Discover non-empty before the server's shelves (the review title) load.
        .task(id: "\(hasContent):\(visionReviewItem != nil)") {
            let screen = UserDefaults.standard.string(forKey: "OpenStreamVisionScreen")
            // Search is a page pushed from Discover everywhere except Apple TV,
            // so it had no debug route at all and no sweep could reach it —
            // the macOS sweep recorded it as NOT TESTED for exactly that
            // reason. Pushing it here is the same one-line hook every other
            // screen already has.
            if screen == "search" { showsSearch = true }
            let scrollY = UserDefaults.standard.double(forKey: "OpenStreamDiscoverScrollY")
            if scrollY > 0, hasContent {
                // `OpenStreamDiscoverScrollDelay` scrolls later than 3 s, so a
                // capture can see the hero's trailer playing and then stop.
                let delay = UserDefaults.standard.double(forKey: "OpenStreamDiscoverScrollDelay")
                try? await Task.sleep(for: .seconds(delay > 0 ? delay : 3))
                guard !Task.isCancelled else { return }
                reviewScrollPosition.scrollTo(y: scrollY)
                appleTrace("discover proof scroll down")
                let returnAfter = UserDefaults.standard.double(forKey: "OpenStreamDiscoverScrollReturnAfter")
                if returnAfter > 0 {
                    do { try await Task.sleep(for: .seconds(returnAfter)) } catch { return }
                    reviewScrollPosition.scrollTo(edge: .top)
                    appleTrace("discover proof scroll return")
                }
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
        .appleTraceScreen("discover", detail: "loading=\(discoverIsLoading)")
        .navigationDestination(isPresented: $showsSearch) {
            AppleSearchView(
                sourceStore: sourceStore,
                mediaIndex: mediaIndex,
                router: router,
                settings: settings,
                openSettings: openSettings,
                mediaServerLibrary: mediaServerLibrary
            )
            .navigationTitle("Search")
            .appleTraceScreen("search")
            .environment(\.appleTabToolbar, tabToolbarContext)
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
            showsContinueWatching = false
            #if DEBUG
            visionReviewDetail = false
            #endif
            let wantsSearch = AppleSearchRoutePolicy.discoverShowsSearch(
                for: route, hasDedicatedSearchTab: AppleSearchRoutePolicy.platformHasDedicatedSearchTab)
            if AppleSearchRoutePolicy.discoverReopensSearch(for: route, wantsSearch: wantsSearch,
                    searchShowing: showsSearch, playerOnScreen: ApplePlaybackCoordinator.isPlayerOnScreen) {
                appleTrace("discover reopens search for a new route")
                openSearchFromPushedPage()
            } else {
                showsSearch = wantsSearch
            }
        }
        .task {
            let index = mediaIndex
            async let savedStillWarmed: Void = AppleLaunchHeroStill.warm()
            if recommendationsRevision == nil { await restoreCachedRecommendations() }
            async let heroArtworkWarmed: Void = warmInitialHeroArtwork()
            let indexStarted = ContinuousClock.now
            await index.load()
            guard !Task.isCancelled else { return }
            appleTrace("discover index ready \(AppleLaunchMarks.milliseconds(indexStarted.duration(to: .now)))ms records=\(mediaIndex.records.count)")
            #if DEBUG
            AppleLaunchClock.mark("index.loaded(\(mediaIndex.records.count))")
            #endif
            let progressStarted = ContinuousClock.now
            let progressWrite = mediaIndex.beginSynchronizingPlaybackProgress()
            appleTrace("discover progress projected \(AppleLaunchMarks.milliseconds(progressStarted.duration(to: .now)))ms")
            if !loadedCache {
                loadedCache = true
                #if DEBUG
                AppleLaunchClock.mark("discover.cache(0)")
                #endif
            }
            AppleLaunchReadiness.shared.markFirstScreenReady()
            try? await progressWrite.value
            appleTrace("discover progress synchronized \(AppleLaunchMarks.milliseconds(progressStarted.duration(to: .now)))ms")
            guard !Task.isCancelled else { return }
            hasSettled = true
            try? await mediaIndex.synchronizePlaybackProgress()
            await heroArtworkWarmed
            await savedStillWarmed
        }
        .task(id: "\(hasSettled)|\(library.hasRestoredPersistedIndex)|\(recommendations.heroes.isEmpty)|\(library.hasLoaded)|\(library.groups.isEmpty)|\(mediaServerLibrary.isLoading)|\(recommendationsRevision != nil)") {
            guard launchHold == .restoring else { return }
            if !recommendations.heroes.isEmpty {
                launchHoldStarted = .now
                launchHold = .warmingHero
            } else if hasSettled, library.hasRestoredPersistedIndex,
                !library.groups.isEmpty || library.hasLoaded, !mediaServerLibrary.isLoading, recommendationsRevision != nil {
                releaseLaunchHold(started: .now)
            }
        }
        .task(id: "\(settings.top10ListsEnabled):\(AppleCatalogArtworkPolicy.configurationMarker(metadataConfiguration))") {
            await loadTop10()
        }
        .task(id: continueWatchingPublicationSnapshot) {
            let revision = continueWatchingPublicationSnapshot
            guard revision.viewportReady, !Task.isCancelled,
                  revision == continueWatchingCandidateRevision else { return }
            let outcome = await AppleDiscoverArtworkPublication.warm(revision.requests)
            guard outcome != .cancelled, !Task.isCancelled,
                  revision == continueWatchingCandidateRevision else { return }
            publishedContinueWatching = revision
            recommendationsPublication &+= 1
            appleTrace("discover continue watching published with visible artwork")
        }
        .task(id: top10PublicationSnapshot) {
            let revision = top10PublicationSnapshot
            guard !Task.isCancelled, revision == top10CandidateRevision else { return }
            guard let candidate = top10Candidate else {
                visibleTop10 = nil
                chartPublication &+= 1
                return
            }
            guard revision.viewportReady else { return }
            guard let ready = await AppleDiscoverTop10Publication.readyChart(candidate, requests: revision.requests,
                allowsArtworkFailure: top10CandidateIsFeed),
                !Task.isCancelled, revision == top10CandidateRevision else { return }
            visibleTop10 = ready
            visibleTop10SourceIdentity = revision.preferredSource ?? ""
            chartPublication &+= 1
            appleTrace("discover top 10 published with visible artwork")
        }
        .onChange(of: serverRowsIdentity, initial: true) { updateServerRows() }
        .onChange(of: incomingDiscoverRails, initial: true) { _, incoming in
            displayedRailOrder = RailOrder.rows(incoming, previous: displayedRailOrder, serverIDs: Set(serverRows.map(\.id)))
        }
        .task(id: "\(isActive)|\(scenePhase == .active)") {
            guard isActive, scenePhase == .active else { return }
            await mediaServerLibrary.refreshSourcesIfReady(sources: sourceStore.sources, sourceStore: sourceStore)
        }
        .task(id: startupHeroArtworkID, priority: .userInitiated) {
            await warmInitialHeroArtwork()
        }
        .background(alignment: .topLeading) {
            if isActive, launchHold == .warmingHero {
                AppleDiscoverLaunchArtwork(requests: startupArtworkRequests, wordmark: startupWordmark,
                    wordmarkSize: startupWordmarkSize, wordmarkLookupPending: startupWordmarkLookupPending) { wordmarkFailed, timedOut in
                        guard launchArtworkID == startupArtworkID else { return }
                        launchWordmarkFailed = wordmarkFailed || timedOut
                        if timedOut, let hero = recommendations.heroes.first { heroWordmarksResolved.insert(hero.item.mediaID) }
                        launchHoldExpired = timedOut
                        releaseLaunchHold(started: launchHoldStarted ?? .now)
                    }
                    .id(launchArtworkID)
            }
        }
        .task(id: launchHold == .released ? startupSpeculativeArtworkRequests : []) {
            guard isActive, launchHold == .released else { return }
            await AppleRemoteImageCache.shared.prefetch(startupSpeculativeArtworkRequests)
        }
        .task(id: launchHold == .released ? lookaheadArtworkRequests(rails) : []) {
            guard isActive, launchHold == .released else { return }
            await AppleRemoteImageCache.shared.prefetch(lookaheadArtworkRequests(rails))
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
        #if os(tvOS)
        // The Top Shelf carousel shows the same pages, art and wordmarks. On
        // the Group, not the billboard, so an empty list clears the shelf too.
        .onChange(of: topShelfHeroes(heroes), initial: true) { _, pages in
            AppleTopShelfHeroFeed.shared.update(pages)
        }
        #endif
        // The same Search and Refresh on every page pushed from here.
        .environment(\.appleTabToolbar, tabToolbarContext)
    }

    /// All selection inputs have cheap revision tokens. Geometry, scrolling,
    /// carousel ticks and wordmark publication do not invalidate this snapshot.
    private var recommendationRevision: String {
        "\(searchConfigurationIdentity(sourceStore.sources))|loaded:\(loadedCache || continueWatchingCacheReady)|play:\(ApplePlaybackProgressFeed.shared.revision)"
            + "|ratings:\(ratingStoreRevision)|index:\(mediaIndex.revision)|server:\(mediaServerLibrary.contentRevision)"
            + "|library:\(library.contentRevision):\(library.hasRestoredPersistedIndex)|chart:\(settings.top10ListsEnabled):\(top10?.fetchedAt.timeIntervalSinceReferenceDate ?? 0)"
            + "|relations:\(relationRevision)|metadata:\(AppleCatalogArtworkPolicy.configurationMarker(metadataConfiguration))"
            + "|xtream:\(AppleXtreamLibraryStore.shared.revision)|removed:\(continueWatchingRemovalRevision)"
            + "|credentials:\(sourceStore.credentialsRestoreRevision)"
    }

    private var recommendationCacheScope: String {
        AppleDiscoverRecommendationCache.scope(sourceIdentity: searchConfigurationIdentity(sourceStore.sources),
            namespace: ApplePlaybackStore().namespace, metadataConfiguration: metadataConfiguration,
            top10ListsEnabled: settings.top10ListsEnabled,
            heroTitle: UserDefaults.standard.string(forKey: "OpenStreamHeroTitle") ?? "")
    }

    private var recommendationCacheRevision: String {
        recommendationCacheScope + "|play:\(ApplePlaybackProgressFeed.shared.revision)|ratings:\(AppleTitleRatingStore.revision)"
            + "|removed:\(continueWatchingChangeRevision)"
    }

    private func recommendationWatchState(_ store: ApplePlaybackStore) -> AppleDiscoverRecommendationCache.WatchState {
        .init(progress: store.configurationProgress(), activity: store.activities(),
            completed: store.configurationWatchedHistory(), unwatched: store.configurationWatchedTombstones(),
            removed: store.configurationContinueWatchingRemovals(), ratings: AppleTitleRatingStore().allRatings.mapValues(\.rawValue))
    }

    private func restoreCachedRecommendations() async {
        let scope = recommendationCacheScope
        let started = ContinuousClock.now
        let state = recommendationWatchState(ApplePlaybackStore())
        appleTrace("discover cache watch state \(AppleLaunchMarks.milliseconds(started.duration(to: .now)))ms")
        guard let key = AppleDiscoverRecommendationCache.key(scope: scope, state: state),
              var cached = await AppleDiscoverRecommendationCache.restore(key, sources: sourceStore.sources) else {
            appleTrace("discover recommendations cache miss")
            return
        }
        var restoredHeroArtwork: (mediaID: String, artwork: AppleHeroArtworkUpgrade.Artwork)?
        if let hero = cached.heroes.first {
            let hasMetadataMatch = library.matchingGroups(hero.item).contains { library.metadata[$0.id] != nil }
            if let artwork = await AppleHeroArtworkUpgrade.shared.cachedArtwork(for: hero.item,
                hasLibraryMetadataMatch: hasMetadataMatch, source: hero.source, namespace: ApplePlaybackStore().namespace) {
                restoredHeroArtwork = (hero.item.mediaID, artwork)
            }
        }
        guard !Task.isCancelled, scope == recommendationCacheScope, recommendationsRevision == nil else { return }
        let store = ApplePlaybackStore()
        guard key == AppleDiscoverRecommendationCache.key(scope: scope, state: recommendationWatchState(store)) else { return }
        cached.continueWatching = cached.continueWatching.map { value in
            var refreshed = value
            refreshed.continueWatchingInfo = Self.continueWatchingInfo(value, store: store)
            return refreshed
        }
        if let restoredHeroArtwork {
            heroArtwork[restoredHeroArtwork.mediaID] = restoredHeroArtwork.artwork
            heroWordmarksResolved.insert(restoredHeroArtwork.mediaID)
            appleTrace("discover cached hero artwork restored")
        }
        recommendations = cached
        recommendationsPublication &+= 1
        // The cached rows were what the last session ended on: keep them.
        featuredPin.scope = scope
        recommendationsRevision = "cache|\(key.fingerprint)"
        appleTrace("discover recommendations cache hit heroes=\(cached.heroes.count)")
    }

    private var hasInitialRecommendationCatalog: Bool {
        !library.resolvedGroups.isEmpty || mediaServerLibrary.shelves.contains { $0.libraryName == nil && !$0.items.isEmpty }
    }

    nonisolated static func canPublishRecommendations(requestedRevision: String, currentRevision: String,
        initialContext: String?, currentContext: String, hasHeroes: Bool) -> Bool {
        requestedRevision == currentRevision || (initialContext == currentContext && !hasHeroes)
    }

    nonisolated static func canPersistRecommendations(requestedRevision: String, currentRevision: String,
        publishedRevision: String?, initialContext: String?, currentContext: String) -> Bool {
        publishedRevision == requestedRevision && (requestedRevision == currentRevision || initialContext == currentContext)
    }

    private func rebuildRecommendations(for revision: String, initialContext: String? = nil) async {
        func canPublish() -> Bool {
            Self.canPublishRecommendations(requestedRevision: revision, currentRevision: recommendationRevision,
                initialContext: initialContext, currentContext: recommendationCacheRevision, hasHeroes: !recommendations.heroes.isEmpty)
        }
        guard loadedCache || continueWatchingCacheReady, library.hasRestoredPersistedIndex else { return }
        if !recommendations.heroes.isEmpty {
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
        }
        // A rating may change while this screen is covered and unsubscribed.
        ratingStoreRevision = AppleTitleRatingStore.revision
        relationRevision = AppleTMDBRelationCache.revision
        guard canPublish(), recommendationsRevision != revision else { return }
        let store = ApplePlaybackStore()
        #if DEBUG
        let wanted = UserDefaults.standard.string(forKey: "OpenStreamHeroTitle")
        #else
        let wanted: String? = nil
        #endif
        let sources = sourceStore.sources
        let preparedLibrary: LibraryRecommendationItems
        do {
            preparedLibrary = try await Self.libraryRecommendationItems(library.catalogSnapshot(sources: sources))
        } catch is CancellationError {
            return
        } catch {
            assertionFailure("Unexpected library snapshot error")
            return
        }
        guard !Task.isCancelled, canPublish() else { return }
        let snapshot = RecommendationSnapshot(
            relations: await AppleTMDBRelationCache.shared.snapshot(configuration: metadataConfiguration), sources: sources,
            records: mediaIndex.records, progress: store.configurationProgress(),
            activity: store.activities(),
            completed: store.configurationWatchedHistory(), unwatched: store.configurationWatchedTombstones(),
            removed: store.configurationContinueWatchingRemovals(), ratings: AppleTitleRatingStore().allRatings,
            serverContinueWatching: mergedContinueWatching(local: Self.localContinueWatching(library: library, playbackStore: store)),
            serverShelves: mediaServerLibrary.shelves.filter { $0.libraryName == nil },
            artwork: heroArtwork, debugHeroTitle: wanted, now: .now,
            localItems: preparedLibrary.heroes,
            trending: settings.top10ListsEnabled && metadataConfiguration != nil ? (top10?.items ?? []) : [],
            libraryItems: preparedLibrary.ranked)
        let cacheScope = recommendationCacheScope
        let featuredPass = FeaturedPass(sources: sources, serverShelves: snapshot.serverShelves,
                                        serverIsLoading: mediaServerLibrary.isLoading)
        do {
            let started = ContinuousClock.now
            var result = try await Self.buildRecommendations(snapshot)
            #if DEBUG
            if let pinned = reviewHero(source: result.heroes.first?.source) {
                result.heroes = [pinned]
            }
            #endif
            guard !Task.isCancelled, canPublish() else { return }
            appleTrace("discover recommendations \(AppleLaunchMarks.milliseconds(started.duration(to: .now)))ms"
                + " heroes=\(result.heroes.count)"
                + " serverShelves=\(snapshot.serverShelves.count) local=\(snapshot.localItems.count) library=\(snapshot.libraryItems.count)"
                + " trending=\(snapshot.trending.count) seedRows=\(result.seedRows.count)")
            featuredPin.apply(shown: recommendations, to: &result, scope: cacheScope, sources: sources, pass: featuredPass)
            result.continueWatching = AppleContinueWatchingResolver.merge(recommendations.continueWatching,
                incoming: result.continueWatching, id: { $0.record.id }, timestamp: { $0.continueWatchingUpdatedAt ?? .distantPast })
            recommendations = result
            recommendationsPublication &+= 1
            recommendationsRevision = revision
            let state = AppleDiscoverRecommendationCache.WatchState(progress: snapshot.progress, activity: snapshot.activity,
                completed: snapshot.completed, unwatched: snapshot.unwatched, removed: snapshot.removed,
                ratings: snapshot.ratings.mapValues(\.rawValue))
            do { try await mediaIndex.waitForPlaybackProgressSynchronization() }
            catch {
                appleTraceFailure("discover recommendation cache skipped after index write failure")
                return
            }
            if let key = AppleDiscoverRecommendationCache.key(scope: cacheScope, state: state),
               !Task.isCancelled, Self.canPersistRecommendations(requestedRevision: revision, currentRevision: recommendationRevision,
                publishedRevision: recommendationsRevision, initialContext: initialContext, currentContext: recommendationCacheRevision) {
                await AppleDiscoverRecommendationCache.store(result, key: key,
                    favoriteIDs: Set(snapshot.records.lazy.filter(\.isFavorite).map(\.id)))
            }
        } catch is CancellationError {
            // Disappearance or a newer revision owns the next result.
        } catch {
            assertionFailure("Unexpected recommendation preparation error")
        }
    }

    struct LibraryRecommendationItems: Sendable {
        let ranked: [IndexedCatalogItem]
        let heroes: [IndexedCatalogItem]
    }

    @concurrent nonisolated static func libraryRecommendationItems(_ input: AppleLocalLibraryStore.CatalogSnapshot) async throws -> LibraryRecommendationItems {
        try Task.checkCancellation()
        let ordered = AppleLocalLibraryStore.sortedGroups(input.groups, metadata: input.metadata, sort: .added)
        let titles = AppleLocalLibraryStore.resolvedGroups(ordered, metadata: input.metadata).filter { group in
            guard group.parsed.kind == .movie || group.parsed.kind == .show,
                  let item = input.metadata[group.id] else { return false }
            return item.posterURL != nil || item.backgroundURL != nil
        }
        let sourcesByID = Dictionary(input.sources.filter(\.isEnabled).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func indexed(_ groups: [AppleLibrarySeries]) throws -> [IndexedCatalogItem] {
            try groups.compactMap { group in
                try Task.checkCancellation()
                guard let file = group.items.first(where: { sourcesByID[$0.sourceID] != nil }),
                      let source = sourcesByID[file.sourceID] else { return nil }
                let item = AppleLocalLibraryStore.catalogItem(for: group, metadata: input.metadata)
                return IndexedCatalogItem(record: AppleMediaIngestion.catalogRecord(instanceID: source.id, item: item),
                    item: item, source: source, progressKeys: group.items.map {
                        input.offlineIDs[$0.id] ?? AppleMediaIngestion.libraryPlaybackID(sourceID: $0.sourceID, relativePath: $0.relativePath)
                    }, addedAt: group.addedAt)
            }
        }
        let heroes = AppleHeroRotation.candidates(ordered.filter {
            $0.parsed.kind == .movie && input.metadata[$0.id]?.backgroundURL != nil
        }, id: \.id)
        return try LibraryRecommendationItems(ranked: indexed(Array(titles.prefix(rankedLibraryLimit))),
            heroes: indexed(Array(heroes.prefix(AppleHeroRotation.maximumCandidates))))
    }

    @concurrent nonisolated static func buildRecommendations(_ snapshot: RecommendationSnapshot) async throws -> RecommendationResult {
        try Task.checkCancellation()
        var seen = Set<String>()
        let merged = AppleCatalogShelfPolicy.uniqueByID(snapshot.serverContinueWatching.filter {
            seen.insert($0.item.mediaID).inserted
        })
        let heroContinueWatching = merged.filter { value in
            guard let key = ApplePlaybackIdentity.storageKey(for: value.record.id) else { return true }
            return !AppleContinueWatchingRemovalPolicy.isRemoved(removedAt: snapshot.removed[key],
                lastPlayedAt: snapshot.activity[key]?.updatedAt ?? snapshot.progress[key]?.updatedAt)
        }
        var identities = AppleRecommendationInputs.IdentityMemo()
        let candidates = ownedShelfItems(snapshot)
        let selection = try await personalization(snapshot, candidates: candidates, identities: &identities)
        try Task.checkCancellation()
        let heroes = featuredCandidates(snapshot, continueWatching: heroContinueWatching, relevantTitles: selection.relevantTitles,
            states: selection.states, identities: &identities)
        let featured = canonicalized(candidates.filter {
            $0.item.posterURL != nil || $0.item.backgroundURL != nil
        }, identities: &identities).sorted {
            let left = $0.item.rating ?? -.infinity
            let right = $1.item.rating ?? -.infinity
            if left != right { return left > right }
            return AppleCatalogShelfPolicy.identity($0.item) < AppleCatalogShelfPolicy.identity($1.item)
        }
        func shelf(_ type: String) -> [IndexedCatalogItem] {
            let items = Array(featured.filter { $0.item.type == type }.prefix(featuredLimit))
            return items.count >= minimumFeaturedCount ? items : []
        }
        try Task.checkCancellation()
        return RecommendationResult(continueWatching: heroContinueWatching, heroes: heroes, seedRows: selection.rows,
            featuredMovies: shelf("movie"), featuredShows: shelf("series"),
            featuredIdentities: Set(featured.map { AppleCatalogShelfPolicy.identity($0.item) }))
    }

    /// Lead resume, two relevant unseen picks, one dated unseen release, then today's fallback.
    /// Prepared on the concurrent recommendation pass; rendering only reads the finished deck.
    nonisolated private static func featuredCandidates(_ snapshot: RecommendationSnapshot,
                                    continueWatching: [IndexedCatalogItem],
                                    relevantTitles: [IndexedCatalogItem], states: [String: AppleHeroMixPolicy.State],
                                    identities: inout AppleRecommendationInputs.IdentityMemo) -> [IndexedCatalogItem] {
        let enabled = Set(snapshot.sources.filter(\.isEnabled).map(\.id))
        let localIDs = Set(snapshot.localItems.map(\.id))
        let servers = snapshot.serverShelves.map { shelf in
            shelf.items.filter { !$0.name.isEmpty && AppleCatalogDiscoveryPolicy.isTitleType($0.type) }.compactMap { item -> IndexedCatalogItem? in
                guard let reference = AppleMediaServerItemReference.parse(item.mediaID),
                      let source = snapshot.sources.first(where: { $0.id == reference.sourceID && $0.isEnabled }) else { return nil }
                return IndexedCatalogItem(record: AppleMediaIngestion.catalogRecord(instanceID: source.id, item: item), item: item, source: source)
            }
        }
        let accessible: (IndexedCatalogItem) -> Bool = { value in
            guard enabled.contains(value.source.id) else { return false }
            // Current server shelves already carry playable routes.
            return AppleMediaServerItemReference.parse(value.item.mediaID) != nil
                || AppleXtreamReference.parse(value.item.mediaID) != nil
                || localIDs.contains(value.id)
        }
        var values = continueWatching.filter(accessible) + relevantTitles.filter(accessible) + servers.flatMap { $0 }
        values += AppleHeroMixPolicy.fairlyGather(servers)
        values += snapshot.localItems.filter(accessible)
        let ownedIDs = Set(values.map { identities.identity($0.item, sourceID: $0.source.id.uuidString) })
        let titleIdentity: (AppleCatalogItem) -> String? = { item in
            guard let year = AppleRecommendationInputs.releaseYear(item), !item.name.isEmpty else { return nil }
            return AppleRecommendationInputs.identity(AppleCatalogItem(mediaID: "", type: item.type, name: item.name, year: year))
        }
        let ownedTitles = Set(values.compactMap { titleIdentity($0.item) })
        values += snapshot.trending.filter { item in
            guard !enabled.isEmpty, !item.name.isEmpty, AppleCatalogDiscoveryPolicy.isTitleType(item.type) else { return false }
            let id = identities.identity(item, sourceID: "")
            guard !ownedIDs.contains(id) else { return false }
            guard let title = titleIdentity(item) else { return true }
            return !ownedTitles.contains(title)
        }.map { item in
            let match = AppleCatalogSearchMatch.metadataOnly(item)
            return IndexedCatalogItem(record: AppleMediaIngestion.catalogRecord(instanceID: match.source.id, item: item),
                item: item, source: match.source)
        }
        let relevant = Set(relevantTitles.map { identities.identity($0.item, sourceID: $0.source.id.uuidString) })
        var resumeIDs = Set<String>()
        var resumeDates: [String: Date] = [:]
        for value in continueWatching.filter(accessible) {
            let id = identities.identity(value.item, sourceID: value.source.id.uuidString)
            resumeIDs.insert(id)
            guard let date = value.continueWatchingUpdatedAt else { continue }
            resumeDates[id] = max(resumeDates[id] ?? .distantPast, date)
        }
        // A richer representative may lack the duplicate route's known release date.
        // Use the earliest authoritative date across duplicates, never a year fallback.
        var releaseDates: [String: Date] = [:]
        for value in values {
            guard let date = AppleHeroMixPolicy.releaseDate(value.item.releaseInfo) else { continue }
            let id = identities.identity(value.item, sourceID: value.source.id.uuidString)
            releaseDates[id] = min(releaseDates[id] ?? .distantFuture, date)
        }
        let unique = canonicalized(values, identities: &identities)
        var byID: [String: IndexedCatalogItem] = [:]
        let inputs = unique.map { value in
            let id = identities.identity(value.item, sourceID: value.source.id.uuidString)
            byID[id] = value
            let item = value.item
            let upgraded = snapshot.artwork[item.mediaID].map {
                item.withHeroArtwork(backgroundURL: $0.backdropURL, logoURL: $0.logoURL)
            } ?? item
            return AppleHeroMixPolicy.Candidate(id: id, resumeAt: resumeDates[id], isResume: resumeIDs.contains(id), relevant: relevant.contains(id),
                releaseDate: releaseDates[id], state: states[id] ?? .init(),
                hasBackdrop: AppleHeroRotation.hasBackdrop(upgraded))
        }
        var deck = AppleHeroMixPolicy.select(inputs, now: snapshot.now)
        #if DEBUG
        // Preserve the existing review-only pin without changing production selection.
        if let wanted = snapshot.debugHeroTitle, !wanted.isEmpty,
           let pinned = unique.first(where: { $0.item.name.localizedCaseInsensitiveContains(wanted) }),
           let input = inputs.first(where: { $0.id == identities.identity(pinned.item, sourceID: pinned.source.id.uuidString) }),
           !input.state.disliked {
            deck.removeAll { $0 == input.id }
            deck.insert(input.id, at: 0)
            deck = Array(deck.prefix(AppleHeroRotation.maximumCandidates))
        }
        #endif
        return deck.compactMap { byID[$0] }
    }

    private func removeFromContinueWatching(_ value: IndexedCatalogItem) {
        appleTrace("discover.continue.remove id=\(value.record.id)")
        ApplePlaybackStore().removeFromContinueWatching(mediaID: value.record.id)
        recommendations.continueWatching.removeAll { $0.id == value.id }
        recommendationsPublication &+= 1
        continueWatchingRemovalRevision &+= 1
    }

    private func mergedContinueWatching(local: [IndexedCatalogItem]) -> [IndexedCatalogItem] {
        Self.mergedContinueWatching(local: local, mediaServerLibrary: mediaServerLibrary,
            xtreamItems: AppleXtreamLibraryStore.shared.continueWatching,
            xtreamSource: { AppleXtreamLibraryStore.shared.source($0) },
            sources: sourceStore.sources, playbackStore: ApplePlaybackStore())
    }

    static func localContinueWatching(library: AppleLocalLibraryStore, playbackStore: ApplePlaybackStore) -> [IndexedCatalogItem] {
        library.continueWatching.compactMap { group in
            let ids = group.items.map(library.playbackID)
            let activity = ids.map { playbackStore.lastActivity(for: $0) }
            guard let index = LocalPick.freshest(activity),
                  var record = library.mediaRecord(for: group, file: group.items[index]),
                  let source = library.sources.first(where: { $0.id == group.items[index].sourceID && $0.isEnabled })
            else { return nil }
            record.progress = playbackStore.progress(for: ids[index]).map {
                AppleWatchProgress.fraction(position: $0.position, duration: $0.duration)
            }
            return IndexedCatalogItem(record: record, item: library.catalogItem(for: group), source: source,
                continueWatchingUpdatedAt: activity[index]?.updatedAt,
                continueWatchingInfo: library.continueWatchingInfo(for: group, store: playbackStore), progressKeys: ids)
        }
    }

    /// `localContinueWatching`'s records for the Top Shelf, with the playback
    /// reads done on `state` off the main actor.
    static func localContinueWatching(library: AppleLocalLibraryStore,
                                      state: ApplePlaybackReadState) async -> [AppleMediaRecord] {
        let groups = await library.continueWatching(state: state)
        let picks = await LocalPick.picks(groups.map { $0.items.map(library.playbackID) }, state: state)
        return zip(groups, picks).compactMap { group, pick in
            guard let pick, library.sources.contains(where: { $0.id == group.items[pick.index].sourceID && $0.isEnabled }),
                  var record = library.mediaRecord(for: group, file: group.items[pick.index]) else { return nil }
            record.progress = pick.progress.map { AppleWatchProgress.fraction(position: $0.position, duration: $0.duration) }
            return record
        }
    }

    /// Which file of a library group Continue Watching shows: the one played last.
    struct LocalPick: Sendable {
        let index: Int
        let progress: ApplePlaybackProgress?

        /// The first file with the latest activity; nil for an empty group.
        nonisolated static func freshest(_ activity: [ApplePlaybackProgress?]) -> Int? {
            activity.indices.max { (activity[$0]?.updatedAt ?? .distantPast) < (activity[$1]?.updatedAt ?? .distantPast) }
        }

        @concurrent nonisolated static func picks(_ groups: [[String]], state: ApplePlaybackReadState) async -> [LocalPick?] {
            groups.map { ids in
                freshest(ids.map(state.lastActivity(for:))).map { LocalPick(index: $0, progress: state.progress(for: ids[$0])) }
            }
        }
    }

    /// The production merge with explicit inputs so tests use isolated playback storage.
    static func mergedContinueWatching(local: [IndexedCatalogItem],
        mediaServerLibrary: AppleMediaServerLibraryStore, xtreamItems: [AppleCatalogItem],
        xtreamSource: (AppleXtreamReference) -> AppleSource?, sources: [AppleSource],
        playbackStore: ApplePlaybackStore) -> [IndexedCatalogItem] {
        // Once per pass: `continueWatching` filters the whole media index.
        let serverItems = mediaServerLibrary.continueWatching + xtreamItems
        let visibleLocal = local.filter { value in
            AppleMediaServerItemReference.parse(value.item.mediaID) == nil
                || mediaServerLibrary.shouldIncludeInContinueWatching(mediaID: value.item.mediaID, store: playbackStore)
        }
        let localItems = visibleLocal.map { $0.item }
        let mergedItems = AppleMediaServerLibraryStore.mergedContinueWatching(local: localItems, server: serverItems)

        let resolved = mergedItems.compactMap { item -> IndexedCatalogItem? in
            if let existing = visibleLocal.first(where: { $0.item.mediaID == item.mediaID }) {
                guard AppleMediaServerItemReference.parse(item.mediaID) != nil else {
                    var value = existing
                    if value.continueWatchingInfo == nil {
                        value.continueWatchingInfo = Self.continueWatchingInfo(value, store: playbackStore)
                    }
                    return value
                }
                let record = mediaServerLibrary.continueWatchingRecord(for: item, source: existing.source, store: playbackStore)
                return IndexedCatalogItem(record: record, item: item, source: existing.source,
                    continueWatchingUpdatedAt: mediaServerLibrary.continueWatchingUpdatedAt(for: item.mediaID, store: playbackStore),
                    continueWatchingInfo: mediaServerLibrary.continueWatchingInfo(for: item, store: playbackStore))
            }
            if let reference = AppleXtreamReference.parse(item.mediaID),
               let source = xtreamSource(reference) {
                var record = AppleMediaIngestion.catalogRecord(instanceID: source.id, item: item)
                if let progress = playbackStore.progress(for: record.id) {
                    record.progress = AppleWatchProgress.fraction(position: progress.position, duration: progress.duration)
                }
                return IndexedCatalogItem(record: record, item: item, source: source,
                    continueWatchingUpdatedAt: playbackStore.lastActivity(for: record.id)?.updatedAt,
                    continueWatchingInfo: AppleXtreamLibraryStore.shared.continueWatchingInfo(for: item, store: playbackStore))
            }
            guard let ref = AppleMediaServerItemReference.parse(item.mediaID),
                  let source = sources.first(where: { $0.id == ref.sourceID }) else { return nil }
            let record = mediaServerLibrary.continueWatchingRecord(for: item, source: source, store: playbackStore)
            return IndexedCatalogItem(record: record, item: item, source: source,
                continueWatchingUpdatedAt: mediaServerLibrary.continueWatchingUpdatedAt(for: item.mediaID, store: playbackStore),
                continueWatchingInfo: mediaServerLibrary.continueWatchingInfo(for: item, store: playbackStore))
        }
        // The merge keys on `mediaID`, the shelf keys on `record.id`: a local
        // record and a server record can agree on the second and differ on the
        // first, and then `ForEach` draws the same card twice. Two cards under
        // one identifier is undefined behaviour for SwiftUI and an ambiguous
        // query for a test — `home.continue.<id>` could not even be asked
        // whether it was hittable (2026-09-19).
        return AppleContinueWatchingResolver.merge([], incoming: AppleCatalogShelfPolicy.uniqueByID(resolved),
            id: { $0.id }, timestamp: { $0.continueWatchingUpdatedAt ?? .distantPast })
    }

    /// Keep the first title's slot (in particular the lead resume hero), but
    /// choose a deterministic playable representative and retain every route.
    nonisolated private static func canonicalized(_ values: [IndexedCatalogItem], identities: inout AppleRecommendationInputs.IdentityMemo) -> [IndexedCatalogItem] {
        let representatives = AppleHeroRotation.candidates(values, id: { identities.identity($0.item, sourceID: $0.source.id.uuidString) }, preferring: {
            AppleRecommendationInputs.prefers($0.item, sourceID: $0.source.id.uuidString, accessible: $0.source.isEnabled,
                over: $1.item, sourceID: $1.source.id.uuidString, accessible: $1.source.isEnabled)
        }, limit: .max)
        let groups = Dictionary(grouping: values, by: { identities.identity($0.item, sourceID: $0.source.id.uuidString) })
        return representatives.map { value in
            var record = value.record
            record.availability = AppleRecommendationInputs.playbackRoutes(
                groups[identities.identity(value.item, sourceID: value.source.id.uuidString), default: []].map(\.record))
            return IndexedCatalogItem(record: record, item: value.item, source: value.source,
                progressKeys: value.progressKeys, addedAt: value.addedAt)
        }
    }

    nonisolated private static func ownedShelfItems(_ snapshot: RecommendationSnapshot) -> [IndexedCatalogItem] {
        var candidates = (snapshot.localItems + snapshot.libraryItems).filter { value in
            snapshot.sources.contains { $0.id == value.source.id && $0.isEnabled }
        }
        for shelf in snapshot.serverShelves {
            for item in shelf.items where AppleCatalogDiscoveryPolicy.isTitleType(item.type) {
                guard let reference = AppleMediaServerItemReference.parse(item.mediaID),
                      let source = snapshot.sources.first(where: { $0.id == reference.sourceID && $0.isEnabled }) else { continue }
                candidates.append(IndexedCatalogItem(record: AppleMediaIngestion.catalogRecord(instanceID: source.id, item: item), item: item, source: source))
            }
        }
        return candidates
    }

    nonisolated private static func personalization(_ snapshot: RecommendationSnapshot, candidates: [IndexedCatalogItem],
        identities: inout AppleRecommendationInputs.IdentityMemo) async throws
        -> (states: [String: AppleHeroMixPolicy.State], relevantTitles: [IndexedCatalogItem], rows: [SeedRow]) {
        let now = snapshot.now
        let storedRatings = snapshot.ratings
        let progress = snapshot.progress
        let completed = snapshot.completed
        let unwatched = snapshot.unwatched
        var historyValues = candidates + snapshot.serverContinueWatching
        // Indexed history counts too, from the metadata it was saved with. No enrichment ask.
        for record in snapshot.records where record.kind == .movie || record.kind == .series || record.kind == .episode {
            try Task.checkCancellation()
            if let id = record.canonicalID {
                // Historical episodes may no longer be listed. Their canonical
                // root still lets the ranker cap all of a show's observations.
                let item = candidates.first { $0.item.imdbID == id || $0.item.mediaID == id }?.item
                    ?? AppleCatalogItem(mediaID: id, type: record.kind.rawValue, name: record.title,
                        summary: record.summary, year: record.year)
                let source = record.availability.lazy.compactMap({ route in
                    snapshot.sources.first { $0.id == route.instanceID }
                }).first ?? AppleCatalogSearchMatch.metadataOnly(item).source
                historyValues.append(IndexedCatalogItem(record: record, item: item, source: source))
            }
        }
        var ratings: [String: AppleTitleRating] = [:]
        var signals: [AppleViewingSignal] = []
        var resumable = Set<String>()
        var finished = Set<String>()
        var genresByID: [String: [String]] = [:]
        var heroStates: [String: AppleHeroMixPolicy.State] = [:]
        var recordIdentities: [String: String] = [:]
        for value in historyValues {
            try Task.checkCancellation()
            let id = identities.identity(value.item, sourceID: value.source.id.uuidString)
            for key in [value.record.id] + value.progressKeys {
                recordIdentities[key] = recordIdentities[key] ?? id
            }
            let genres = identities.genres(value.item)
            let people = AppleRecommendationInputs.people(value.item)
            genresByID[id, default: []] += genres
            let keys = Array(Set([value.record.id, value.item.mediaID] + value.progressKeys
                + identities.progressCandidates(value.item, sourceID: value.source.id)))
            let storageKeys = keys.compactMap { ApplePlaybackIdentity.storageKey(for: $0) }
            let saved = storageKeys.compactMap { key in
                let value = progress[key] ?? snapshot.activity[key]
                guard let value, (unwatched[key] ?? .distantPast) < value.updatedAt else { return nil as ApplePlaybackProgress? }
                return value
            }
            let dates = storageKeys.compactMap { completed[$0] }
            // Ratings are persisted by media id; map all alternate IDs to the
            // same recommendation identity. An explicit dislike wins a conflict.
            if let rating = storedRatings[ApplePlaybackIdentity.digest(for: value.item.mediaID)] {
                let old = ratings[id]
                if old != .down, rating == .down || rating.rawValue > (old?.rawValue ?? 0) { ratings[id] = rating }
            }
            var showID: String?
            if AppleMediaSeriesInfo(mediaID: value.item.mediaID) != nil {
                let root = value.item.mediaID.split(separator: ":").dropLast(2).joined(separator: ":")
                let show = AppleCatalogItem(mediaID: root, type: "series", name: value.item.name,
                    year: AppleRecommendationInputs.releaseYear(value.item), imdbID: value.item.imdbID)
                showID = identities.identity(show, sourceID: value.source.id.uuidString)
            }
            let recordProgress = saved.isEmpty && !storageKeys.contains(where: { unwatched[$0] != nil })
                ? value.record.progress : nil
            let heroCompleted = storageKeys.contains { key in
                guard let date = completed[key] else { return false }
                return date > (unwatched[key] ?? .distantPast)
            }
            let heroProgress = saved + storageKeys.compactMap { snapshot.activity[$0] }
            let heroState = AppleHeroMixPolicy.watchState(progress: heroProgress,
                completed: heroCompleted, recordProgress: recordProgress, disliked: ratings[id] == .down)
            heroStates[id, default: .init()].merge(heroState)
            if let showID { heroStates[showID, default: .init()].merge(heroState) }
            if let signal = AppleRecommendationInputs.signal(titleID: id, genres: genres, people: people, progress: saved,
                completedDates: dates, recordProgress: recordProgress, showID: showID, now: now) {
                signals.append(signal)
            }
            // Candidate watched state is independent of which observation has
            // the strongest taste weight (a later rewatch may be only partial).
            if !dates.isEmpty || saved.contains(where: { $0.isComplete })
                || (recordProgress ?? 0) >= ApplePlaybackProgress.completionFraction { finished.insert(id) }
            if saved.contains(where: { $0.resumePosition != nil })
                || (saved.isEmpty && (value.record.progress ?? 0) > 0
                    && (value.record.progress ?? 1) < ApplePlaybackProgress.completionFraction) {
                resumable.insert(id)
            }
        }
        let history = AppleRecommendationInputs.boundedHistory(signals, now: now)
        let listIDs = Set(snapshot.records.filter(\.isFavorite).compactMap { recordIdentities[$0.id] })
        let unique = canonicalized(candidates, identities: &identities)
        let byID = Dictionary(uniqueKeysWithValues: unique.map { (identities.identity($0.item, sourceID: $0.source.id.uuidString), $0) })
        // Intersect cached TMDB links with routes the viewer can actually open.
        // No link creates a synthetic playable item or performs enrichment here.
        var relationIDs: [String: Set<String>] = [:]
        let watched = Set(history.map { $0.showID ?? $0.titleID }).union(ratings.filter { $0.value.rawValue > 0 }.keys)
        let relationIndex = AppleTMDBRelation.accessibleIndex(byID.mapValues(\.item))
        for relation in snapshot.relations {
            try Task.checkCancellation()
            let seedItem = AppleCatalogItem(mediaID: relation.seedID, type: relation.type, name: "")
            let seedID = identities.identity(seedItem, sourceID: "")
            guard watched.contains(seedID) else { continue }
            for target in relation.targets {
                for id in target.accessibleIDs(in: relationIndex) { relationIDs[id, default: []].insert(seedID) }
            }
        }
        let rankable = unique.map { value in
            let id = identities.identity(value.item, sourceID: value.source.id.uuidString)
            return AppleRankableTitle(id: id, genres: genresByID[id] ?? [],
                releaseYear: AppleRecommendationInputs.releaseYear(value.item),
                metadataCompleteness: AppleRecommendationInputs.metadataCompleteness(value.item),
                isResumable: resumable.contains(id), isCompleted: finished.contains(id),
                primaryGenre: value.item.genres?.first,
                franchiseID: AppleCatalogShelfPolicy.franchise(title: value.item.name),
                sourceID: value.source.id.uuidString, people: AppleRecommendationInputs.people(value.item),
                addedAt: value.addedAt, quality: value.item.rating)
        }
        let titles = rankable.compactMap { title -> AppleRecommendationRowScorer.Title? in
            guard let value = byID[title.id] else { return nil }
            return .init(rankable: title, name: value.item.name)
        }
        let rows = try await AppleRecommendationRowScorer.build(titles, history: history, ratings: ratings,
            listIDs: listIDs, relationIDs: relationIDs, now: now)
        let relevant = AppleRecommendationRanker.rankWithProvenance(rankable.filter { !$0.isCompleted && !$0.isResumable },
            history: history, ratings: ratings, now: now, limit: AppleHeroRotation.maximumCandidates,
            preferUnseen: true, relationIDs: relationIDs, requiresAffinity: true)
        return (states: heroStates, relevantTitles: relevant.compactMap { byID[$0.title.id] }, rows: rows.map { row in
                SeedRow(heading: row.heading, items: row.ids.compactMap { byID[$0] }, minimumCount: row.minimumCount)
            })
    }

    /// A row on the home screen, in the order it is drawn.
    enum DiscoverRail: Hashable, Identifiable, Sendable {
        case continueWatching
        case services
        case library
        case top10
        case featuredMovies
        case featuredShows
        case becauseWatched(Int)
        case popularMovies
        case popularShows
        case mediaServer(String)
        var id: Self { self }

        var rowID: String {
            switch self {
            case .continueWatching: AppleDiscoverRowOrder.continueWatching
            case .services: AppleDiscoverRowOrder.services
            case .library: AppleDiscoverRowOrder.recentlyAdded
            case .top10: AppleDiscoverRowOrder.top10
            case .featuredMovies: AppleDiscoverRowOrder.featuredMovies
            case .featuredShows: AppleDiscoverRowOrder.featuredShows
            case .becauseWatched: AppleDiscoverRowOrder.becauseWatched
            case .popularMovies: AppleDiscoverRowOrder.popularMovies
            case .popularShows: AppleDiscoverRowOrder.popularShows
            case .mediaServer(let id): id
            }
        }
    }

    private var serverRowsIdentity: String {
        "\(mediaServerLibrary.contentRevision)|\(searchConfigurationIdentity(sourceStore.sources))|"
            + mediaServerLibrary.pendingShelfIDs.sorted().joined(separator: ";")
    }

    private func updateServerRows() {
        serverRows = serverRowCache.rows(revision: mediaServerLibrary.contentRevision,
            shelves: mediaServerLibrary.shelves, sources: sourceStore.sources,
            pendingShelfIDs: mediaServerLibrary.pendingShelfIDs)
        recentlyAddedCache.invalidate()
        serverRowsPublication &+= 1
    }

    private var incomingDiscoverRails: [DiscoverRail] {
        Self.discoverRails(continueWatching: shownContinueWatching, hasLibrary: !library.resolvedGroups.isEmpty,
            recommendations: recommendations, top10: shownTop10, serverShelfIDs: serverRows.map(\.id), hasServices: !homeServices.isEmpty)
    }

    private var homeServices: [AppleHomeServices.Service] {
        homeServiceCache.services(revision: mediaServerLibrary.contentRevision,
            libraries: mediaServerLibrary.serviceLibraries, sources: sourceStore.sources,
            hidden: settings.homeServicesHidden)
    }

    private func defaultRowTitle(_ rail: DiscoverRail, serverRows: [AppleDiscoverServerRows.Row]) -> String {
        switch rail {
        case .becauseWatched(let index):
            return recommendations.seedRows.indices.contains(index)
                ? recommendations.seedRows[index].heading : AppleDiscoverRowOrder.title(forBuiltIn: rail.rowID) ?? ""
        case .mediaServer(let id): return serverRows.first { $0.id == id }?.title ?? ""
        default: return AppleDiscoverRowOrder.title(forBuiltIn: rail.rowID) ?? ""
        }
    }

    private func rowTitle(_ rail: DiscoverRail, serverRows: [AppleDiscoverServerRows.Row]) -> String {
        AppleDiscoverRowOrder.title(for: rail.rowID, defaultTitle: defaultRowTitle(rail, serverRows: serverRows),
            customNames: settings.homeRowNames)
    }

    private func homeRowContext(_ rail: DiscoverRail, payload: PreparedRail) -> AppleHomeRowContext {
        let shelfIDs: [String]
        if case .catalog(let shelf, _) = payload { shelfIDs = shelf.shelfIDs } else { shelfIDs = [] }
        return AppleHomeRowContext(row: .init(id: rail.rowID, defaultName: defaultRowTitle(rail, serverRows: serverRows)),
            settings: settings, mediaServerLibrary: mediaServerLibrary, shelfIDs: shelfIDs)
    }

    nonisolated private static let minimumFeaturedCount = 6
    nonisolated static let featuredLimit = 20

    /// What one recommendation pass knew about the media servers.
    struct FeaturedPass: Equatable, Sendable {
        /// Every enabled server has its shelves in, or has finished loading.
        /// A cold launch before any shelf is a partial pass and pins nothing.
        var hasServerShelves: Bool
        /// No server is mid-reload, so a title missing from the pass is gone
        /// (deleted, hidden, its source off), not just not loaded yet. The
        /// owner's trace had a reload drop to 1 shelf, then 33, from 70.
        var isSettled: Bool

        init(hasServerShelves: Bool, isSettled: Bool) {
            self.hasServerShelves = hasServerShelves
            self.isSettled = isSettled
        }

        init(sources: [AppleSource], serverShelves: [AppleMediaServerLibraryStore.Shelf], serverIsLoading: Bool) {
            let withShelves = Set(serverShelves.map(\.sourceID))
            let servers = sources.filter { $0.kind == .mediaServer && $0.isEnabled }
            self.init(hasServerShelves: !serverIsLoading || servers.allSatisfy { withShelves.contains($0.id) },
                      isSettled: !serverIsLoading)
        }
    }

    /// The Movies and TV Shows rows keep the titles they show for the
    /// session (owner recording 2026-11-04: "Inception just switched to
    /// Holes" when a server reloaded its shelves and the row re-ranked).
    /// Rows are pinned after the first pass with the server shelves, under
    /// the scope (profile, sources, metadata) they were built for; a new
    /// scope starts over.
    struct FeaturedPin: Sendable {
        var scope: String?

        mutating func apply(shown: RecommendationResult, to result: inout RecommendationResult, scope: String,
                            sources: [AppleSource], pass: FeaturedPass) {
            let pinned = self.scope == scope
            let present = pass.isSettled ? result.featuredIdentities : nil
            result.featuredMovies = AppleDiscoverView.sessionStableFeatured(shown: pinned ? shown.featuredMovies : [],
                incoming: result.featuredMovies, sources: sources, present: present)
            result.featuredShows = AppleDiscoverView.sessionStableFeatured(shown: pinned ? shown.featuredShows : [],
                incoming: result.featuredShows, sources: sources, present: present)
            self.scope = pinned || pass.hasServerShelves ? scope : nil
        }
    }

    /// A shown title keeps its place; new titles only fill free places. A
    /// title leaves when its source is off, or when a settled pass
    /// (`present` non-nil) no longer has it.
    nonisolated static func sessionStableFeatured(shown: [IndexedCatalogItem], incoming: [IndexedCatalogItem],
                                                  sources: [AppleSource],
                                                  present: Set<String>? = nil) -> [IndexedCatalogItem] {
        let enabled = Set(sources.filter(\.isEnabled).map(\.id))
        let fresh = Dictionary(incoming.map { (AppleCatalogShelfPolicy.identity($0.item), $0) },
            uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        let kept = shown.compactMap { value -> IndexedCatalogItem? in
            let key = AppleCatalogShelfPolicy.identity(value.item)
            guard enabled.contains(value.source.id), present?.contains(key) ?? true,
                  seen.insert(key).inserted else { return nil }
            // Fresh data for the same title from the same source only.
            return fresh[key].flatMap { $0.source.id == value.source.id ? $0 : nil } ?? value
        }
        let added = incoming.filter { seen.insert(AppleCatalogShelfPolicy.identity($0.item)).inserted }
        return Array((kept + added).prefix(featuredLimit))
    }
    nonisolated static let minimumTop10Count = 5

    enum RailOrder {
        static func rows(_ incoming: [DiscoverRail], previous: [DiscoverRail], serverIDs: Set<String>) -> [DiscoverRail] {
            let retainedServers = previous.filter {
                if case .mediaServer(let id) = $0 { return serverIDs.contains(id) && !incoming.contains($0) }
                return false
            }
            let rows = AppleStableRefresh.merge(previous, incoming: incoming + retainedServers, id: \.id)
            let byID = Dictionary(rows.map { ($0.rowID, $0) }, uniquingKeysWith: { first, _ in first })
            return AppleDiscoverRowOrder.ordered(rows.map(\.rowID)).compactMap { byID[$0] }
        }
    }

    private func discoverRails(continueWatching: [IndexedCatalogItem], serverRows: [AppleDiscoverServerRows.Row]) -> [DiscoverRail] {
        let incoming = Self.discoverRails(continueWatching: continueWatching, hasLibrary: !library.resolvedGroups.isEmpty,
            recommendations: recommendations, top10: shownTop10, serverShelfIDs: serverRows.map(\.id), hasServices: !homeServices.isEmpty)
        return RailOrder.rows(incoming, previous: displayedRailOrder, serverIDs: Set(serverRows.map(\.id)))
    }

    static func discoverRails(continueWatching: [IndexedCatalogItem], hasLibrary: Bool, recommendations: RecommendationResult,
                              top10: AppleTop10Store.Chart?, serverShelfIDs: [String], hasServices: Bool = false) -> [DiscoverRail] {
        var rails: [DiscoverRail] = []
        if !continueWatching.isEmpty { rails.append(.continueWatching) }
        if hasServices { rails.append(.services) }
        if (top10?.items.count ?? 0) >= minimumTop10Count { rails.append(.top10) }
        if recommendations.featuredMovies.count >= minimumFeaturedCount || serverShelfIDs.contains(AppleDiscoverRowOrder.featuredMovies) {
            rails.append(.featuredMovies)
        }
        if hasLibrary || serverShelfIDs.contains(AppleDiscoverRowOrder.recentlyAdded) { rails.append(.library) }
        if recommendations.featuredShows.count >= minimumFeaturedCount || serverShelfIDs.contains(AppleDiscoverRowOrder.featuredShows) {
            rails.append(.featuredShows)
        }
        if let seed = recommendations.seedRows.indices.first(where: {
            recommendations.seedRows[$0].items.count >= AppleRecommendationRowPolicy.minimumItems
        }) { rails.append(.becauseWatched(seed)) }
        if serverShelfIDs.contains(AppleDiscoverRowOrder.popularMovies) { rails.append(.popularMovies) }
        if serverShelfIDs.contains(AppleDiscoverRowOrder.popularShows) { rails.append(.popularShows) }
        rails += serverShelfIDs.filter { !AppleDiscoverRowOrder.builtInIDs.contains($0) }.map { .mediaServer($0) }
        return rails
    }

    nonisolated private static func selectedRows(_ rails: [DiscoverRail], keys: [[String]], seedMinimumCounts: [Int],
                                                hiddenRows: Set<String>, loadingRowIDs: Set<String>) -> [AppleDiscoverRowOrder.Row] {
        let candidates = rails.indices.map { index in
            var minimum = 0
            if case .becauseWatched(let seed) = rails[index], seedMinimumCounts.indices.contains(seed) {
                minimum = seedMinimumCounts[seed]
            }
            return AppleDiscoverRowOrder.Row(id: rails[index].rowID, keys: keys[index], minimumCount: minimum,
                isLoading: loadingRowIDs.contains(rails[index].rowID))
        }
        return AppleDiscoverRowOrder.rows(candidates, hidden: hiddenRows)
    }

    nonisolated static func displayedRowIDs(_ rails: [DiscoverRail], keys: [[String]], seedMinimumCounts: [Int],
                                            hiddenRows: Set<String> = []) -> [[String]] {
        let rows = selectedRows(rails, keys: keys, seedMinimumCounts: seedMinimumCounts, hiddenRows: hiddenRows, loadingRowIDs: [])
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.keys) })
        return rails.map { byID[$0.rowID] ?? [] }
    }

    private struct DisplayedRail: Identifiable {
        let rail: DiscoverRail
        let payload: PreparedRail
        var id: DiscoverRail { rail }
    }

    nonisolated static func rowIdentity(_ item: AppleCatalogItem) -> String {
        AppleRecommendationRowScorer.displayIdentity(item)
    }

    private func serverValues(for id: String, serverRows: [AppleDiscoverServerRows.Row],
                              sourcesByID: [UUID: AppleSource]) -> [IndexedCatalogItem] {
        (serverRows.first { $0.id == id }?.items ?? []).compactMap { item in
            guard let reference = AppleMediaServerItemReference.parse(item.mediaID),
                  let source = sourcesByID[reference.sourceID] else { return nil }
            return IndexedCatalogItem(record: AppleMediaIngestion.catalogRecord(instanceID: source.id, item: item), item: item,
                source: source, addedAt: mediaServerLibrary.addedAt(for: item.mediaID))
        }
    }

    @MainActor
    final class RecentlyAddedCache {
        private var libraryRevision: Int?
        private var sources: [AppleSource] = []
        private var prepared: [IndexedCatalogItem] = []

        func invalidate() { libraryRevision = nil }

        func values(libraryRevision: Int, sources: [AppleSource], build: () -> [IndexedCatalogItem]) -> [IndexedCatalogItem] {
            if self.libraryRevision != libraryRevision || self.sources != sources {
                prepared = build()
                self.libraryRevision = libraryRevision
                self.sources = sources
            }
            return prepared
        }
    }

    nonisolated static func recentlyAdded(local: [IndexedCatalogItem], server: [IndexedCatalogItem]) -> [IndexedCatalogItem] {
        (local + server).enumerated().sorted {
            let left = $0.element.addedAt ?? .distantPast, right = $1.element.addedAt ?? .distantPast
            return left == right ? $0.offset < $1.offset : left > right
        }.map(\.element)
    }

    private func railValues(_ rail: DiscoverRail, continueWatching: [IndexedCatalogItem],
                            serverRows: [AppleDiscoverServerRows.Row], sourcesByID: [UUID: AppleSource]) -> [IndexedCatalogItem] {
        func server() -> [IndexedCatalogItem] {
            serverValues(for: rail.rowID, serverRows: serverRows, sourcesByID: sourcesByID)
        }
        switch rail {
        case .continueWatching: return AppleContinueWatchingResolver.rail(continueWatching)
        case .library:
            return recentlyAddedCache.values(libraryRevision: library.contentRevision, sources: sourceStore.sources) {
                let local = library.resolvedGroups.compactMap { group -> IndexedCatalogItem? in
                    guard let file = group.items.first(where: { sourcesByID[$0.sourceID] != nil }),
                          let source = sourcesByID[file.sourceID] else { return nil }
                    let item = library.catalogItem(for: group)
                    return IndexedCatalogItem(record: AppleMediaIngestion.catalogRecord(instanceID: source.id, item: item), item: item,
                        source: source, addedAt: group.addedAt, localGroupID: group.id)
                }
                return Self.recentlyAdded(local: local, server: server())
            }
        case .featuredMovies: return recommendations.featuredMovies + server()
        case .featuredShows: return recommendations.featuredShows + server()
        case .becauseWatched(let index): return recommendations.seedRows.indices.contains(index) ? recommendations.seedRows[index].items : []
        case .popularMovies, .popularShows, .mediaServer: return server()
        case .top10, .services: return []
        }
    }

    private func displayedRails(continueWatching: [IndexedCatalogItem], serverRows: [AppleDiscoverServerRows.Row]) -> [DisplayedRail] {
        let key = AppleDiscoverRailCache<[DisplayedRail]>.Key(
            recommendationsPublication: recommendationsPublication, serverRowsPublication: serverRowsPublication,
            chartPublication: chartPublication, libraryRevision: library.contentRevision,
            servicesRevision: mediaServerLibrary.contentRevision, sources: sourceStore.sources,
            order: displayedRailOrder, hiddenRows: settings.homeRowsHidden, rowNames: settings.homeRowNames,
            hiddenServices: settings.homeServicesHidden, top10Enabled: settings.top10ListsEnabled,
            top10Available: settings.top10ListsAvailable)
        return displayedRailCache.value(for: key) {
            prepareDisplayedRails(continueWatching: continueWatching, serverRows: serverRows)
        }
    }

    private func prepareDisplayedRails(continueWatching: [IndexedCatalogItem], serverRows: [AppleDiscoverServerRows.Row]) -> [DisplayedRail] {
        let rails = discoverRails(continueWatching: continueWatching, serverRows: serverRows)
        let sourcesByID = Dictionary(sourceStore.sources.filter(\.isEnabled).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let values = Dictionary(uniqueKeysWithValues: rails.map {
            ($0, railValues($0, continueWatching: continueWatching, serverRows: serverRows, sourcesByID: sourcesByID))
        })
        let keys = rails.map { rail -> [String] in
            if rail == .services { return homeServices.map { "service:" + $0.id } }
            if rail == .top10 { return (shownTop10?.items ?? []).map(Self.rowIdentity) }
            return (values[rail] ?? []).map { Self.rowIdentity($0.item) }
        }
        let selected = Self.selectedRows(rails, keys: keys, seedMinimumCounts: recommendations.seedRows.map(\.minimumCount),
            hiddenRows: settings.homeRowsHidden, loadingRowIDs: Set(serverRows.filter(\.isLoading).map(\.id)))
        let byID = Dictionary(rails.map { ($0.rowID, $0) }, uniquingKeysWith: { first, _ in first })
        return selected.compactMap { row in
            guard let rail = byID[row.id] else { return nil }
            return DisplayedRail(rail: rail, payload: preparedRail(rail, values: values[rail] ?? [],
                allowed: Set(row.keys), serverRows: serverRows))
        }
    }

    private func rowItems(_ values: [IndexedCatalogItem], allowed: Set<String>) -> [IndexedCatalogItem] {
        var seen = Set<String>()
        return values.filter {
            let key = Self.rowIdentity($0.item)
            return allowed.contains(key) && seen.insert(key).inserted
        }
    }

    private var startupHeroArtworkID: String {
        guard let hero = recommendations.heroes.first else { return "" }
        let item = Self.heroItem(hero.item, artwork: heroArtwork)
        return "\(isActive)|\(item.id)|\(item.backgroundURL?.absoluteString ?? "")|\(item.logoURL?.absoluteString ?? "")"
    }

    private func warmInitialHeroArtwork() async {
        guard isActive, let hero = recommendations.heroes.first else { return }
        let item = Self.heroItem(hero.item, artwork: heroArtwork)
        let art = startupHeroArtworkRequest
        if let art { AppleLaunchHeroStill.remember(art) }
        await withDiscardingTaskGroup { group in
            if let art {
                group.addTask {
                    _ = try? await AppleRemoteImageCache.shared.image(url: art.url,
                        maximumPixelDimension: art.maximumPixelDimension, priority: .foreground)
                }
            }
            if let logo = item.logoURL {
                group.addTask {
                    _ = await AppleTransparentPNGLogoValidator.firstValid(in: [logo])
                }
                group.addTask { await AppleTrimmedTitleLogo.warmTrimmedFromDisk(logo) }
            }
        }
    }

    private func releaseLaunchHold(started: ContinuousClock.Instant) {
        launchHold = .released
        appleTrace("discover launch hold released \(AppleLaunchMarks.milliseconds(started.duration(to: .now)))ms"
            + " expired=\(launchHoldExpired)")
        recordFirstRowSeen()
    }

    /// The rows appeared while hidden; this is when they are seen.
    private func recordFirstRowSeen() {
        let serverRows = serverRows
        if let first = displayedRails(continueWatching: shownContinueWatching, serverRows: serverRows).first {
            AppleLaunchMarks.record(.firstRow, rowTitle(first.rail, serverRows: serverRows))
        }
    }

    private var startupArtworkID: String {
        "\(isActive)|\(startupWordmark?.absoluteString ?? "")|\(startupWordmarkLookupPending)|" + startupArtworkRequests.map { "\($0.url.absoluteString)|\($0.maximumPixelDimension)" }.joined(separator: ";")
    }

    private var startupWordmark: URL? {
        recommendations.heroes.first.map { Self.heroItem($0.item, artwork: heroArtwork) }?.logoURL
    }

    private var startupWordmarkLookupPending: Bool {
        guard let hero = recommendations.heroes.first else { return false }
        return startupWordmark == nil && !heroWordmarksResolved.contains(hero.item.mediaID)
    }

    private var startupWordmarkSize: CGSize {
        switch heroPresentation {
        case .phone:
            CGSize(width: 280, height: dynamicTypeSize.isAccessibilitySize ? 120 : AppleDetailMetrics.titleLogoMaxHeight)
        case .mac, .pad:
            AppleMacHeroLayout.wordmarkSize
        case .tv:
            CGSize(width: AppleTVBillboardMetrics.copyColumnWidth * 0.62, height: AppleTVBillboardMetrics.titleFontSize * 2.2)
        case .rotating:
            #if os(tvOS)
            CGSize(width: AppleTVBillboardMetrics.copyColumnWidth * 0.62, height: AppleTVBillboardMetrics.titleFontSize * 2.2)
            #else
            AppleFeaturedHeroMetrics.wordmarkSize(viewport: viewportSize)
            #endif
        }
    }

    private var startupHeroArtworkRequest: AppleArtworkPrefetchPolicy.Request? {
        guard let hero = recommendations.heroes.first.map({ Self.heroItem($0.item, artwork: heroArtwork) }) else { return nil }
        let display: AppleCatalogArtworkPolicy.DisplayRequest
        if usesPhoneHero {
            let art = AppleTitlePageSlotArt.choose(
                backdrops: AppleTitlePageSlotArt.landingBackdrops(item: hero, details: AppleTMDBDetails(),
                    remembered: AppleHeroPortraitMemory.art(for: hero.mediaID)), posters: [hero.posterURL])
            display = .init(url: art?.url, fixedPixelDimension: AppleHeroPortraitArt.pixelDimension, waitsForGeometry: false)
        } else {
            display = AppleCatalogArtworkPolicy.heroRequest(item: hero, pixelWidth: AppleCatalogArtworkPolicy.heroPixelWidth)
        }
        if let url = display.url, let pixels = display.fixedPixelDimension {
            return .init(url: url, maximumPixelDimension: AppleArtworkSizePolicy.bucket(pixels))
        }
        return nil
    }

    private var startupArtworkRequests: [AppleArtworkPrefetchPolicy.Request] {
        let serverRows = serverRows
        var requests: [AppleArtworkPrefetchPolicy.Request] = []
        if let hero = startupHeroArtworkRequest { requests.append(hero) }
        let displayed = displayedRails(continueWatching: shownContinueWatching, serverRows: serverRows)
        if let first = displayed.first { requests += firstScreensArtworkRequests(first, screens: 1) }
        var seen = Set<AppleArtworkPrefetchPolicy.Request>()
        return requests.filter { seen.insert($0).inserted }
    }

    private var startupSpeculativeArtworkRequests: [AppleArtworkPrefetchPolicy.Request] {
        let serverRows = serverRows
        return displayedRails(continueWatching: shownContinueWatching, serverRows: serverRows)
            .prefix(2).flatMap { firstScreensArtworkRequests($0) }
    }

    /// The art a row shows on its first screens.
    private func firstScreensArtworkRequests(_ row: DisplayedRail, screens: Int = 2) -> [AppleArtworkPrefetchPolicy.Request] {
        let payload = row.payload
        let width = AppleCatalogCard.width(sizing: payload.sizing, rowStyle: discoverRowStyle, scaledCardWidth: artworkCardWidth,
            viewportWidth: viewportSize.width, regularWidth: horizontalSizeClass == .regular)
        let height = AppleCatalogCard.height(sizing: payload.sizing, width: width)
        let count = AppleArtworkPrefetchPolicy.screenCount(viewportWidth: viewportSize.width, cardWidth: width,
            gap: discoverRowStyle?.cardGap ?? AppleTVBillboardMetrics.cardGap)
        var resumeStills: [String: URL] = [:]
        if case .continueWatching(let values) = payload {
            for value in values {
                if let still = value.continueWatchingInfo?.episode?.thumbnailURL { resumeStills[value.item.id] = still }
            }
        }
        return AppleArtworkPrefetchPolicy.requests(items: payload.items,
            pixels: CGSize(width: width * displayScale, height: height * displayScale),
            landscape: AppleCatalogCard.isLandscape(payload.sizing), resumeStills: resumeStills, limit: min(20, count * screens))
    }

    /// The rows below the lowest one shown. A row's own prefetch starts only
    /// when the lazy stack makes it, the same moment its tiles ask for their
    /// art, so a fast swipe met posters still downloading (owner 393 ms).
    private func lookaheadArtworkRequests(_ rails: [DisplayedRail]) -> [AppleArtworkPrefetchPolicy.Request] {
        rails.dropFirst(lowestShownRail + 1).prefix(AppleArtworkPrefetchPolicy.lookaheadRows)
            .flatMap { firstScreensArtworkRequests($0) }
    }

    private enum PreparedRail {
        case continueWatching([IndexedCatalogItem])
        case services([AppleHomeServices.Service])
        case catalog(AppleDiscoverServerRows.Row, [IndexedCatalogItem])
        case posters(title: String, identifier: String, values: [IndexedCatalogItem])
        case portraitPromo(title: String, identifier: String, values: [IndexedCatalogItem])
        case top10(ranked: [(offset: Int, element: AppleCatalogItem)])

        var items: [AppleCatalogItem] {
            switch self {
            case .continueWatching(let values), .catalog(_, let values), .posters(_, _, let values), .portraitPromo(_, _, let values): values.map(\.item)
            case .top10(let ranked): ranked.map(\.element)
            case .services: []
            }
        }

        var sizing: AppleCatalogCardSizing {
            switch self {
            case .continueWatching: .continueWatching
            case .catalog: .catalog
            case .posters: .catalog
            case .portraitPromo: .portraitPromo
            case .top10: .ranked
            case .services: .catalog
            }
        }
    }

    private func preparedRail(_ rail: DiscoverRail, values: [IndexedCatalogItem],
                              allowed: Set<String>, serverRows: [AppleDiscoverServerRows.Row]) -> PreparedRail {
        let title = rowTitle(rail, serverRows: serverRows)
        let values = rowItems(values, allowed: allowed)
        switch rail {
        case .continueWatching: return .continueWatching(values)
        case .services: return .services(homeServices.filter { allowed.contains("service:" + $0.id) })
        case .library, .popularMovies, .popularShows, .mediaServer:
            let row = serverRows.first { $0.id == rail.rowID }
            return .catalog(.init(id: rail.rowID, title: title, items: values.map(\.item),
                shelfIDs: row?.shelfIDs ?? [], isLoading: row?.isLoading ?? false), values)
        case .becauseWatched(let index):
            return .posters(title: title, identifier: index == 0 ? "because-watched" : "because-watched-\(index)", values: values)
        case .featuredMovies, .featuredShows:
            return .portraitPromo(title: title, identifier: rail == .featuredMovies ? "featured-movies" : "featured-shows", values: values)
        case .top10:
            var seen = Set<String>()
            return .top10(ranked: (shownTop10?.items ?? []).enumerated().filter {
                allowed.contains(Self.rowIdentity($0.element)) && seen.insert(Self.rowIdentity($0.element)).inserted
            })
        }
    }

    @ViewBuilder
    private func railView(_ rail: DiscoverRail, continueWatching: [IndexedCatalogItem],
                          payload: PreparedRail, serverRows: [AppleDiscoverServerRows.Row]) -> some View {
        switch payload {
        case .services(let services):
            AppleHomeServiceStrip(title: rowTitle(rail, serverRows: serverRows), services: services,
                customNames: settings.homeRowNames) { service in
                AppleHomeServicePage(service: service, sourceStore: sourceStore, mediaServerLibrary: mediaServerLibrary,
                    settings: settings) { item, source in
                    detail(IndexedCatalogItem(record: AppleMediaIngestion.catalogRecord(instanceID: source.id, item: item),
                        item: item, source: source))
                }
            }
        case .continueWatching(let values):
            AppleMediaShelf(title: rowTitle(rail, serverRows: serverRows),
                onOpen: AppleContinueWatchingResolver.hasFullList(count: continueWatching.count)
                    ? { showsContinueWatching = true } : nil,
                headingIdentifier: "home.continue.heading",
                artworkItems: payload.items, artworkSizing: payload.sizing) {
                continueWatchingCards(values)
            }
        case .catalog(let shelf, let values):
            let localIDs = Set(values.compactMap(\.localGroupID))
            let groups = localIDs.isEmpty ? [] : library.resolvedGroups.filter { localIDs.contains($0.id) }
            let items = values.map(\.item)
            let byID = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
            Group {
                if values.isEmpty && shelf.isLoading {
                    AppleDiscoverLoadingRail(landscape: false, rowStyle: discoverRowStyle)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(shelf.title), Loading")
                } else {
                    AppleMediaShelf(title: shelf.title, artworkItems: items, artworkSizing: payload.sizing) {
                        ForEach(values) { value in
                            if let id = value.localGroupID, let group = byID[id] {
                                AppleLocalLibraryTile(group: group, sourceStore: sourceStore, mediaIndex: mediaIndex,
                                    settings: settings, openSettings: openSettings, tabToolbar: tabToolbarContext)
                                    .appleShelfFocusItem(id: value.item.id)
                            } else {
                                NavigationLink { detail(value) } label: { AppleCatalogCard(item: value.item) }
                                    .appleShelfFocusItem(id: value.item.id)
                                    .accessibilityIdentifier("home.ms.\(shelf.id).\(value.item.mediaID)")
                                    .onAppear {
                                        guard AppleCatalogPaging.isNearEnd(itemID: value.item.id, in: items) else { return }
                                        Task {
                                            for id in shelf.shelfIDs { await mediaServerLibrary.loadMore(shelfID: id) }
                                        }
                                    }
                            }
                        }
                    }
                }
            }
            .accessibilityIdentifier(rail == .library ? "home.your-library" : "home.ms.\(shelf.id)")
            .task(id: values.map(\.id)) {
                for id in shelf.shelfIDs { await mediaServerLibrary.refreshIfNeeded(shelfID: id) }
                if !groups.isEmpty {
                    await library.resolveMetadata(groups, tmdbKey: settings.tmdbAPIKey, omdbKey: settings.omdbAPIKey)
                }
            }
            #if !os(iOS)
            .contextMenu {
                if !shelf.shelfIDs.isEmpty {
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        Task {
                            for id in shelf.shelfIDs { await mediaServerLibrary.refresh(shelfID: id) }
                        }
                    }
                }
            }
            #endif
        case .posters(let title, let identifier, let values):
            indexedShelf(title: title, identifier: identifier, values: values, showsProgress: false, cardSizing: .catalog)
        case .portraitPromo(let title, let identifier, let values):
            indexedShelf(title: title, identifier: identifier, values: values, showsProgress: false,
                cardSizing: payload.sizing, viewportWidth: viewportSize.width)
                .accessibilityIdentifier("home.\(identifier)")
        case .top10(let ranked):
            top10Shelf(title: rowTitle(rail, serverRows: serverRows), ranked: ranked)
        }
    }

    private func continueWatchingCards(_ values: [IndexedCatalogItem]) -> some View {
        #if os(tvOS)
        return indexedCards(identifier: "continue", values: values, showsProgress: true)
        #else
        return ForEach(Array(values.enumerated()), id: \.element.id) { index, value in
            AppleContinueWatchingTile(
                item: value.item,
                info: value.continueWatchingInfo ?? .make(type: value.item.type, saved: nil, recordProgress: value.record.progress),
                isInList: mediaIndex.record(id: value.record.id)?.isFavorite ?? value.record.isFavorite,
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
        #endif
    }

    static func continueWatchingInfo(_ value: IndexedCatalogItem, store: ApplePlaybackStore) -> AppleContinueWatchingTileInfo {
        let key = AppleTitleProgressIdentity.key(
            among: value.progressKeys + [value.record.id] + AppleTitleProgressIdentity.candidates(item: value.item, sourceID: value.source.id),
            progress: { store.progress(for: $0) }) ?? value.record.id
        guard let saved = store.progress(for: key) else {
            return value.continueWatchingInfo ?? .make(type: value.item.type, saved: nil, recordProgress: value.record.progress)
        }
        var episode = value.continueWatchingInfo?.episode
        if let partID = saved.partID, partID != episode?.id { episode = nil }
        var info = AppleContinueWatchingTileInfo.make(type: value.item.type, saved: saved,
            recordProgress: value.record.progress, episode: episode)
        info.title = value.continueWatchingInfo?.title
        return info
    }

    /// TMDB's weekly charts, drawn from the kept copy first. Off, or with no
    /// TMDB key, there are no Top 10 rows.
    private func loadTop10() async {
        guard settings.top10ListsEnabled, let metadataConfiguration else {
            top10 = nil
            return
        }
        if top10 == nil {
            let stored = await AppleTop10Store.shared.stored()
            guard !Task.isCancelled else { return }
            top10 = stored
        }
        do {
            let latest = try await AppleTop10Store.shared.latest(configuration: metadataConfiguration)
            // The rows were turned off or the key removed meanwhile.
            guard !Task.isCancelled else { return }
            top10 = latest
            appleTrace("discover top 10 loaded")
        } catch {
            AppleInteractionTrace.record(.network, "discover top 10 failed \(appleErrorLabel(error))")
        }
    }

    private var continueWatchingSourceContext: String {
        AppleTasteNamespace.local + "|" + searchConfigurationIdentity(sourceStore.sources)
    }

    private var continueWatchingCandidate: [IndexedCatalogItem] {
        let enabled = Dictionary(sourceStore.sources.filter(\.isEnabled).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        return recommendations.continueWatching.filter { value in
            guard let source = enabled[value.source.id] else { return false }
            return source.configurationRevision == value.source.configurationRevision
                && source.url == value.source.url && source.kind == value.source.kind
        }
    }

    private var continueWatchingCandidateRevision: AppleDiscoverContinueWatchingPublication.Snapshot {
        let values = continueWatchingCandidate
        let row = DisplayedRail(rail: .continueWatching,
            payload: .continueWatching(AppleContinueWatchingResolver.rail(values)))
        return .init(values: values, sourceContext: continueWatchingSourceContext,
            requests: firstScreensArtworkRequests(row, screens: 1), viewportReady: viewportSize.width > 0)
    }

    private var shownContinueWatching: [IndexedCatalogItem] {
        AppleDiscoverContinueWatchingPublication.visible(publishedContinueWatching, current: continueWatchingCandidate,
            sourceContext: continueWatchingSourceContext)
    }

    private var top10Candidate: AppleTop10Store.Chart? {
        AppleDiscoverTop10Publication.candidate(
            feed: feedTop10Items,
            fallback: top10, enabled: settings.top10ListsEnabled, metadataAvailable: settings.top10ListsAvailable)
    }

    private var feedTop10Items: [AppleCatalogItem] {
        (serverRows.first(where: { $0.id == AppleDiscoverRowOrder.top10 })?.items ?? [])
            .filter { mediaServerSource(for: $0) != nil }
    }

    private var top10CandidateIsFeed: Bool { !feedTop10Items.isEmpty }

    private var preferredTop10SourceIdentity: String? {
        guard top10Candidate != nil else { return nil }
        let context = searchConfigurationIdentity(sourceStore.sources)
        guard top10CandidateIsFeed else { return context + "|tmdb" }
        let sources = Set(feedTop10Items.compactMap { AppleMediaServerItemReference.parse($0.mediaID)?.sourceID.uuidString })
        return context + "|feed:" + sources.sorted().joined(separator: ",")
    }

    private var top10CandidateRevision: AppleDiscoverTop10Publication.Snapshot {
        let items = top10Candidate?.items ?? []
        let row = DisplayedRail(rail: .top10, payload: .top10(ranked: Array(items.enumerated())))
        return .init(items: items, preferredSource: preferredTop10SourceIdentity,
            requests: firstScreensArtworkRequests(row, screens: 1), viewportReady: viewportSize.width > 0)
    }

    /// Late charts enter with their visible posters decoded, preserving the complete viewport.
    private var shownTop10: AppleTop10Store.Chart? {
        AppleDiscoverTop10Publication.visible(visibleTop10, publishedSource: visibleTop10SourceIdentity,
            preferredSource: preferredTop10SourceIdentity)
    }

    /// The enabled server a feed Top 10 title comes from.
    private func mediaServerSource(for item: AppleCatalogItem) -> AppleSource? {
        guard let reference = AppleMediaServerItemReference.parse(item.mediaID) else { return nil }
        return sourceStore.sources.first { $0.id == reference.sourceID && $0.isEnabled && $0.kind == .mediaServer }
    }

    @ViewBuilder
    private func top10Shelf(title: String, ranked: [(offset: Int, element: AppleCatalogItem)]) -> some View {
        if !ranked.isEmpty {
            // Ranked shelves retain the standard row spacing and focus treatment.
            AppleMediaShelf(title: title, artworkItems: ranked.map(\.element), artworkSizing: .ranked) {
                ForEach(ranked, id: \.offset) { rank, item in
                    let source = mediaServerSource(for: item) ?? AppleCatalogSearchMatch.metadataOnly(item).source
                    let record = AppleMediaIngestion.catalogRecord(instanceID: source.id, item: item)
                    NavigationLink { detail(IndexedCatalogItem(record: record, item: item, source: source)) } label: {
                        AppleTop10Card(item: item, rank: rank + 1)
                    }
                    .appleShelfFocusItem(id: item.id)
                    .accessibilityIdentifier("home.top10.\(rank + 1)")
                }
            }
        }
    }

    /// Not `@ViewBuilder`: it returns one view, and the `let` below needs an
    /// explicit `return`, which would switch the builder off anyway.
    private func featuredHero(
        _ value: IndexedCatalogItem, rotationCount: Int = 0, rotationIndex: Int = 0, wordmarkFailed: Bool = false,
        phone: Bool = false, mac: Bool = false, pad: Bool = false, tv: AppleHomeTVHeroContext? = nil
    ) -> some View {
        let item = Self.heroItem(mediaServerLibrary.titlePageDestination(for: value.item).item, artwork: heroArtwork)
        let progressID = AppleTitleProgressIdentity.key(
            among: AppleTitleProgressIdentity.candidates(item: item, sourceID: value.source.id),
            progress: { ApplePlaybackProgressFeed.shared.progress(for: $0) }) ?? value.record.id
        return AppleHomeBillboard(
            item: item,
            sources: sourceStore.sources,
            progressID: progressID,
            preferredSourceID: value.source.id,
            onPlay: { selectHero(value, autoPlay: true) },
            onOpenDetails: { selectHero(value, autoPlay: false) },
            settings: settings,
            viewportSize: viewportSize,
            wordmark: wordmarkFailed ? nil : item.logoURL,
            wordmarkLookupPending: AppleHeroTitlePolicy.wordmarkLookupPending(
                mediaID: value.item.mediaID, resolved: heroWordmarksResolved, wordmarkFailed: wordmarkFailed
            ),
            rotationCount: rotationCount,
            rotationIndex: rotationIndex,
            mediaServerLibrary: mediaServerLibrary,
            phone: phone ? .init(artHeight: phoneHeroLayout.artHeight,
                                 copyFadeLine: phoneHeroLayout.topInset) : nil,
            mac: mac || pad ? .init(layout: pad ? padHeroLayout : macHeroLayout) : nil,
            tv: tv.map { .init(cycle: $0.cycle) }
        ) { button, perform in
            AppleHomeHeroActions(mode: phone ? .phone : pad ? .pad : mac ? .mac : tv != nil ? .tv : .rotating,
                viewportSize: viewportSize, button: button,
                isInList: mediaIndex.record(id: value.record.id)?.isFavorite ?? value.record.isFavorite, tv: tv,
                onPlay: perform, onToggleList: { toggleHeroInList(value) },
                onDetails: { selectHero(value, autoPlay: false) })
        }
    }

    /// The iPhone hero's My List button: the same favourite the title page's
    /// My List toggles. A title first seen on the hero has no record yet — the
    /// title page writes one when it opens — so it is written here first.
    private func toggleHeroInList(_ value: IndexedCatalogItem) {
        Task { @MainActor in
            try? await Self.toggleHeroInList(value, mediaIndex: mediaIndex)
        }
    }

    static func toggleHeroInList(_ value: IndexedCatalogItem, mediaIndex: AppleMediaIndexStore) async throws {
        await mediaIndex.load()
        let isInList = mediaIndex.record(id: value.record.id)?.isFavorite ?? value.record.isFavorite
        if mediaIndex.record(id: value.record.id) == nil { try await mediaIndex.upsert(value.record) }
        try await mediaIndex.setFavorite(!isInList, recordID: value.record.id)
    }

    /// N11's upright phone stays on the presentation policy, so landscape
    /// phones retain their own rows. iPad and N13 Mac use separate sizes.
    private var discoverRowStyle: AppleDiscoverRowStyle? {
        #if os(iOS)
        return AppleHomePresentationPolicy.rows(hero: heroPresentation,
            width: viewportSize.width, inset: 16, isLargeLayout: isLargeLayout)
        #else
        return AppleHomePresentationPolicy.rows(hero: heroPresentation,
            width: macHeroLayout.contentWidth, inset: macHeroLayout.horizontalPadding)
        #endif
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
            compact: horizontalSizeClass == .compact, accessibility: dynamicTypeSize.isAccessibilitySize,
            isLargeLayout: isLargeLayout)
    }

    private func topShelfHeroes(_ heroes: [IndexedCatalogItem]) -> [AppleTopShelfHero] {
        heroes.map { value in
            let item = Self.heroItem(value.item, artwork: heroArtwork)
            return .page(record: value.record, item: item, wordmark: item.logoURL)
        }
    }

    /// The hero's own record, with any textless art that has since arrived.
    /// `id` is unchanged by the swap, so the billboard keeps its identity and
    /// tvOS keeps its focus.
    nonisolated static func heroItem(_ item: AppleCatalogItem, artwork: [String: AppleHeroArtworkUpgrade.Artwork]) -> AppleCatalogItem {
        guard let upgrade = artwork[item.mediaID] else { return item }
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
        for hero in heroes {
            guard let configuration = metadataConfiguration else {
                heroWordmarksResolved.insert(hero.item.mediaID)
                continue
            }
            guard heroArtwork[hero.item.mediaID] == nil else {
                heroWordmarksResolved.insert(hero.item.mediaID)
                continue
            }
            let hasMetadataMatch = library.matchingGroups(hero.item).contains { library.metadata[$0.id] != nil }
            await AppleHeroTitlePolicy.resolveWordmark {
                await AppleHeroArtworkUpgrade.shared.artwork(for: hero.item,
                    hasLibraryMetadataMatch: hasMetadataMatch, configuration: configuration)
            } apply: { upgrade in
                guard heroArtwork[hero.item.mediaID] != upgrade else { return }
                heroArtwork[hero.item.mediaID] = upgrade
            } didResolve: {
                heroWordmarksResolved.insert(hero.item.mediaID)
            }
            guard !Task.isCancelled else { return }
        }
    }

    #if DEBUG
    /// Captures can compare a title that is absent from the current catalog, without saving a source or watch event.
    private func reviewHero(source: AppleSource?) -> IndexedCatalogItem? {
        guard UserDefaults.standard.bool(forKey: "OpenStreamDebugPinHero"), let source,
              let encoded = UserDefaults.standard.string(forKey: "OpenStreamDebugHeroItem"),
              let payload = Data(base64Encoded: encoded),
              let item = try? JSONDecoder().decode(AppleCatalogItem.self, from: payload),
              item.mediaID == UserDefaults.standard.string(forKey: "OpenStreamDebugPlayID"),
              item.type == UserDefaults.standard.string(forKey: "OpenStreamDebugPlayType") else { return nil }
        appleTrace("hero capture pin \(item.mediaID)")
        return IndexedCatalogItem(record: AppleMediaIngestion.catalogRecord(instanceID: source.id, item: item),
            item: item, source: source)
    }

    private var visionReviewItem: IndexedCatalogItem? {
        // "detail-movie" is "detail" for the first film instead of the first
        // series, so a sweep can photograph both kinds of title page.
        // `OpenStreamDetailTitle` picks a title by name, so before and after
        // shots can photograph the same page.
        let type = UserDefaults.standard.string(forKey: "OpenStreamVisionScreen") == "detail-movie" ? "movie" : "series"
        let wanted = UserDefaults.standard.string(forKey: "OpenStreamDetailTitle") ?? ""
        let items = mediaServerLibrary.shelves.flatMap(\.items).filter { $0.type == type }
        let named = wanted.isEmpty ? nil : items.first { $0.name.localizedCaseInsensitiveContains(wanted) }
        // Persisted shelves arrive before the authenticated source index on a warm launch.
        guard let item = named ?? items.first,
              let reference = AppleMediaServerItemReference.parse(item.mediaID),
              let source = mediaServerLibrary.source(for: reference), source.isEnabled else { return nil }
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
        showsProgress: Bool,
        cardSizing: AppleCatalogCardSizing = .featured,
        viewportWidth: CGFloat? = nil
    ) -> some View {
        AppleMediaShelf(title: title, artworkItems: values.map(\.item),
            artworkSizing: showsProgress ? .continueWatching : cardSizing) {
            indexedCards(identifier: identifier, values: values, showsProgress: showsProgress,
                cardSizing: cardSizing, viewportWidth: viewportWidth)
        }
    }

    private func indexedCards(identifier: String, values: [IndexedCatalogItem], showsProgress: Bool,
                              cardSizing: AppleCatalogCardSizing = .featured, viewportWidth: CGFloat? = nil) -> some View {
        return ForEach(values) { value in
            let info = showsProgress ? value.continueWatchingInfo : nil
            NavigationLink { detail(value) } label: {
                AppleCatalogCard(
                    item: value.item,
                    sizing: showsProgress ? .continueWatching : cardSizing,
                    viewportWidth: viewportWidth,
                    progress: info?.progress,
                    resumeCaption: info?.subtitle,
                    resumeStillURL: info?.episode?.thumbnailURL,
                    resumeTitle: info?.title)
            }
            .appleShelfFocusItem(id: value.item.id)
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

    private func detail(_ value: IndexedCatalogItem, initialAutoPlay: Bool = false) -> some View {
        // Built when pushed, not with every link (`AppleLazyDestination`).
        AppleLazyDestination {
            AppleTitleDestinationChooser(source: value.source, item: value.item) { group in
                AppleLocalTitleDestination(group: group, sourceStore: sourceStore, mediaIndex: mediaIndex,
                    settings: settings, openSettings: openSettings, tabToolbar: tabToolbarContext,
                    autoPlay: initialAutoPlay)
            } catalog: {
                AppleCatalogItemDetailView(
                    item: value.item,
                    source: value.source,
                    relatedItems: [],
                    mediaIndex: mediaIndex,
                    playbackSources: sourceStore.sources,
                    metadataConfiguration: metadataConfiguration,
                    settings: settings,
                    openSettings: openSettings,
                    initialAutoPlay: initialAutoPlay,
                    mediaServerLibrary: mediaServerLibrary,
                    tabToolbar: tabToolbarContext
                )
            }
        }
        .environment(\.appleDiscoverRows, nil)
    }

    private var featuredHeight: CGFloat {
        #if os(tvOS)
        540
        #else
        isLandscapeIPad ? min(viewportSize.height * 0.55, (viewportSize.width - 32) * 9 / 16) : 390
        #endif
    }

    private var isLandscapeIPad: Bool {
        #if os(iOS) || os(visionOS)
        horizontalSizeClass == .regular && viewportSize.width > viewportSize.height
        #else
        false
        #endif
    }

    private var sectionSpacing: CGFloat {
        #if os(tvOS)
        AppleTVBillboardMetrics.sectionSpacing
        #else
        discoverRowStyle?.rowSpacing ?? 32
        #endif
    }

    private var metadataConfiguration: AppleTMDBConfiguration? { settings.tmdbConfiguration }

    /// Discover's Search and Refresh, for the pages pushed from here.
    private var tabToolbarContext: AppleTabToolbarContext {
        AppleTabToolbarContext(tab: .home, isRefreshing: { isRefreshing },
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

    private var reviewLoadingState: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "OpenStreamReviewDiscoverLoading")
        #else
        false
        #endif
    }

    private var discoverIsLoading: Bool {
        AppleDiscoverEmptyState.isStillLoading(sourceCount: sourceStore.sources.count, hasSettled: hasSettled && library.hasRestoredPersistedIndex
                && (!library.groups.isEmpty || library.hasLoaded))
            || mediaServerLibrary.isLoading || library.isLoading
    }

    /// No Sources, or sources with nothing in them.
    @ViewBuilder
    private var discoverEmptyState: some View {
        let state = AppleDiscoverEmptyState(sourceCount: sourceStore.sources.count)
        #if os(tvOS)
        openSettingsEmptyState(state)
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
        await mediaServerLibrary.reload(sources: sourceStore.sources, sourceStore: sourceStore) { try sourceStore.mediaServerSession(for: $0) }
        try? await Task.sleep(for: AppleProgressVisibility.remaining(since: started))
    }
}

/// A pushed title's page, chosen once (`AppleTitlePagePolicy.TitleDestinationChoice`).
/// A later scan can update the chosen NAS group, never swap the page type.
private struct AppleTitleDestinationChooser<Local: View, Catalog: View>: View {
    typealias Choice = AppleTitlePagePolicy.TitleDestinationChoice
    let source: AppleSource
    let item: AppleCatalogItem
    @ViewBuilder let local: (AppleLibrarySeries) -> Local
    @ViewBuilder let catalog: () -> Catalog
    @State private var library = AppleLocalLibraryStore.shared
    @State private var choice = Choice()
    @State private var waitExpired = false

    private var current: Choice {
        guard choice.page == nil else { return choice }
        var next = choice
        let isNAS = source.kind == .nas
        next.update(group: isNAS ? AppleTitlePagePolicy.localDestinationGroup(
                        source: source, matchingGroups: library.matchingGroups(item)) : nil,
                    groupCanStillArrive: isNAS && !library.hasLoaded && !waitExpired)
        return next
    }

    var body: some View {
        let current = current
        Group {
            switch current.page {
            case .local(let chosen):
                local(library.matchingGroups(item).first { $0.id == chosen.id } ?? chosen)
            case .catalog:
                catalog()
            case nil:
                ProgressView()
                    .accessibilityIdentifier("detail.waitingForLibrary")
                    .task {
                        try? await Task.sleep(for: Choice.groupWait)
                        waitExpired = true
                    }
            }
        }
        .onChange(of: current, initial: true) { _, latest in
            if choice.page == nil, let page = latest.page {
                appleTrace("title destination: \(page == .catalog ? "catalog" : "library") page")
            }
            choice = latest
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
    /// The query the search task last started a generation for. The live
    /// library's reloads restart that task with the same query; a new
    /// generation then would orphan a shared link the route task is still
    /// resolving (its result dropped, the spinner up for good).
    @State private var sharedLinkGenerationQuery = ""
    @State private var sharedPlayer: AppleMediaPlayerPresentation?
    @State private var pendingSharedPlayer: AppleMediaPlayerPresentation?
    #if os(iOS)
    @Environment(\.scenePhase) private var scenePhase
    @State private var hasCopiedURL = false
    #endif
    @State private var searchStore = AppleCatalogSearchStore()
    @State private var routedResult: RoutedResult?
    @State private var deliveredRouteRevision: Int?
    @State private var recentSearches = AppleRecentSearchStore()
    @State private var library = AppleLocalLibraryStore.shared
    #if DEBUG
    @State private var debugOpenedFirstResult = false
    #endif

    struct RoutedResult: Identifiable, Hashable {
        static let userSelectionRevision = -1

        let record: AppleMediaRecord
        let item: AppleCatalogItem
        let source: AppleSource
        let action: AppleMediaRouteAction
        let revision: Int
        let localGroupID: String?
        let localGroup: AppleLibrarySeries?
        var id: String { "\(record.id):\(action.rawValue):\(revision)" }

        var requiresLocalGroup: Bool {
            localGroupID != nil || source.kind == .nas
                || (source.kind == .library && source.id != AppleMediaAvailability.metadataOnlyInstanceID)
        }

        @MainActor init?(record: AppleMediaRecord, match: AppleCatalogSearchMatch, action: AppleMediaRouteAction,
                        revision: Int, library: AppleLocalLibraryStore) {
            self.record = record
            item = match.item
            source = match.source
            self.action = action
            self.revision = revision
            localGroupID = match.localGroupID
            localGroup = library.searchGroup(for: match)
            guard !requiresLocalGroup || localGroup != nil else { return nil }
        }

        static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    let sourceStore: AppleSourceStore
    let mediaIndex: AppleMediaIndexStore
    let router: AppleAppRouter
    let settings: AppleSettingsStore
    let openSettings: () -> Void
    var mediaServerLibrary: AppleMediaServerLibraryStore? = nil

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
                        description: Text("Titles appear here after you add a source.")
                    )
                } else if !recentSearches.recents.isEmpty {
                    recentSearchesList
                } else {
                    ContentUnavailableView("Search Your Sources", systemImage: "magnifyingglass")
                }
            } else if searchStore.rows.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                List(searchStore.rows) { row in
                    Button {
                        openTitle(row)
                    } label: {
                        HStack {
                            resultRow(row, sourceName: row.match.source.name)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.forward")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                    }
                    .accessibilityRemoveTraits(.isButton)
                    .accessibilityAddTraits(.isLink)
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
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
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
            Button(AppleSemanticAction.play.label, systemImage: AppleSemanticAction.play.symbol) {
                sharedPlayer = presentation
                pendingSharedPlayer = nil
            }
            Button("Cancel", role: .cancel) { pendingSharedPlayer = nil }
        }
        .modifier(AppleMediaPlayerPresentationModifier(presentation: $sharedPlayer))
        // The hero's trailer stops under the player (`AppleHeroTrailerGate`).
        // No hero is known to sit under Search, but keep this: without it
        // testCrawlPlayers' detail→player step failed 6 of 6 runs, with it
        // 4 of 4 passed (exact A/B on the build Mac, 2026-10-14; cause not found).
        .environment(\.appleHeroIsCovered, sharedPlayer != nil)
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
            titleDestination(value)
            .task(id: router.revision) {
                // Search's task sleeps while this title covers it. The visible page
                // closes itself for a newer shared link, then Search resolves that route.
                if router.revision != deliveredRouteRevision, case .sharedLink = router.route {
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
            deliverMediaRoute(revision: revision)
        }
        .onChange(of: library.contentRevision) {
            deliverMediaRoute(revision: router.revision)
        }
        .task(id: searchIdentity) {
            if query != sharedLinkGenerationQuery {
                pendingSharedPlayer = nil
                sharedLinkGenerationQuery = query
                sharedLinkGeneration &+= 1
            }
            let revision = router.revision
            if let link = AppleSharedLinkResolver.link(in: query) {
                await openSharedLink(link, revision: revision)
                return
            }
            await searchStore.search(query: query, resolveMatch: searchMatch) { value in
                await localSearch(value)
            }
            deliverMediaRoute(revision: revision)
            // A query that stayed put and found something is a search worth
            // remembering; the keystrokes on the way to it are not (tvOS has
            // no submit, so this is the only path there).
            guard !Task.isCancelled, !searchStore.rows.isEmpty else { return }
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            recentSearches.record(query)
        }
        .task(id: searchContentIdentity) {
            guard let revision = searchContentIdentity else { return }
            await searchStore.coalesceRevision(revision)
        }
        .task {
            await mediaIndex.load()
        }
        #if DEBUG
        // `-OpenStreamDebugSearchQuery <text>` types a query and opens the
        // first result's title page once, for a headless sweep of Search as
        // an entry point (N53).
        .task(id: searchStore.rows.count) {
            guard let typed = UserDefaults.standard.string(forKey: "OpenStreamDebugSearchQuery"),
                  !typed.isEmpty else { return }
            if query.isEmpty { query = typed; return }
            guard !debugOpenedFirstResult, let row = searchStore.rows.first else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            debugOpenedFirstResult = true
            openTitle(row)
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
            await mediaIndex.load()
            try Task.checkCancellation()
            let configuration = await settings.loadedTMDBConfiguration()
            try Task.checkCancellation()
            let resolution = try await AppleSharedLinkResolution.resolve(link, records: mediaIndex.records,
                                                                         configuration: configuration)
            try Task.checkCancellation()
            guard revision == router.revision, generation == sharedLinkGeneration else { return }
            if case .sharedLink = router.route { deliveredRouteRevision = revision }
            if let record = resolution.record, let match = searchMatch(for: record) {
                query = record.title
                routedResult = .init(record: record, match: match, action: .display, revision: revision, library: library)
                appleTrace("shared link match title page \(record.title)")
            } else if let item = resolution.item {
                let match = AppleCatalogSearchMatch.metadataOnly(item)
                let record = AppleMediaRecord(canonicalID: item.mediaID, kind: item.type == "movie" ? .movie : .series,
                                             title: item.name, year: item.year, availability: [])
                query = item.name
                routedResult = .init(record: record, match: match, action: .display, revision: revision, library: library)
                appleTrace("shared link match metadata title page \(item.name)")
            } else { throw AppleSharedLinkError.unreadable }
        } catch {
            guard !Task.isCancelled, revision == router.revision, generation == sharedLinkGeneration else { return }
            if case .sharedLink = router.route { deliveredRouteRevision = revision }
            sharedLinkError = ((error as? AppleSharedLinkError) ?? .unreadable).errorDescription ?? ""
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

    /// A library or share title's page needs its library group, which a
    /// fresh launch publishes after the route has arrived. Such a route stays
    /// pending until `library.contentRevision` moves.
    private func deliverMediaRoute(revision: Int) {
        guard !Task.isCancelled, revision == router.revision,
              deliveredRouteRevision != revision,
              case .media(let id, let action) = router.route,
              let record = mediaIndex.records.first(where: { $0.id == id }),
              let match = searchMatch(for: record) else { return }
        guard let result = RoutedResult(record: record, match: match, action: action,
                                        revision: revision, library: library) else {
            appleTrace("detail route \"\(match.item.name)\" waiting for the library")
            return
        }
        deliveredRouteRevision = revision
        appleTrace("detail route \"\(match.item.name)\" action=\(action.rawValue)")
        routedResult = result
    }

    private func openTitle(_ row: AppleCatalogSearchRow) {
        routedResult = .init(record: row.record, match: row.match, action: .display,
            revision: RoutedResult.userSelectionRevision, library: library)
    }

    @ViewBuilder
    private func resultRow(_ row: AppleCatalogSearchRow, sourceName: String) -> some View {
        let record = row.record
        HStack(spacing: 14) {
            AppleCatalogArtwork(url: record.artworkURL)
                .frame(width: 58, height: 87)
                .clipShape(.rect(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                Text(row.displayTitle).font(.headline)
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

    @ViewBuilder private func titleDestination(_ value: RoutedResult) -> some View {
        if let group = value.localGroup {
            AppleLocalTitleDestination(group: group, sourceStore: sourceStore, mediaIndex: mediaIndex,
                settings: settings, openSettings: openSettings, tabToolbar: tabToolbar, autoPlay: value.action == .play)
        } else {
            AppleCatalogItemDetailView(item: value.item, source: value.source, mediaIndex: mediaIndex,
                playbackSources: sourceStore.sources, metadataConfiguration: metadataConfiguration,
                settings: settings, openSettings: openSettings, initialAutoPlay: value.action == .play,
                mediaServerLibrary: mediaServerLibrary, tabToolbar: tabToolbar)
        }
    }

    private func searchMatch(for record: AppleMediaRecord) -> AppleCatalogSearchMatch? {
        library.searchMatch(for: record) ?? AppleXtreamLibraryStore.shared.match(record)
            ?? mediaServerLibrary?.searchMatch(for: record)
            ?? AppleCatalogSearchMatch.indexed(record, sources: sourceStore.sources)
    }

    private var searchIdentity: AppleCatalogSearchStore.Identity {
        searchStore.taskIdentity(query: query)
    }

    var searchContentIdentity: String? {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !library.isLoading, !AppleXtreamLibraryStore.shared.isLoading else { return nil }
        return [String(AppleXtreamLibraryStore.shared.revision), String(library.contentRevision),
            String(mediaIndex.revision), String(mediaServerLibrary?.contentRevision ?? 0),
            searchConfigurationIdentity(sourceStore.sources)].joined(separator: "|")
    }

    private func localSearch(_ value: String) async -> [AppleMediaRecord] {
        let indexed = await mediaIndex.search(value)
        let xtream = await AppleXtreamLibraryStore.shared.search(value)
        return await library.searchRecords(indexed: indexed, additional: xtream)
    }


    private var metadataConfiguration: AppleTMDBConfiguration? { settings.tmdbConfiguration }
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

    /// Shown only while the card is focused (Apple TV only).
    @ViewBuilder
    func appleTVFocusedCaption() -> some View {
        #if os(tvOS)
        modifier(AppleTVFocusedCaption())
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
    let resumeCaption: String?
    let resumeStillURL: URL?
    let resumeTitle: String?
    let widthOverride: CGFloat?
    @Environment(\.displayScale) private var displayScale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.appleTMDBConfiguration) private var metadataConfiguration
    @Environment(\.appleLibraryPoster) private var libraryPoster
    @Environment(\.appleDiscoverRows) private var rowStyle
    @ScaledMetric(relativeTo: .body) private var scaledCardWidth = 140.0
    @State private var fallbackArtwork: AppleArtworkResolver.Artwork?
    @State private var failedArtworkURLs: Set<URL> = []
    @State private var artworkRetries = 0
    @State private var artworkLookup = AppleCatalogArtworkPolicy.Lookup()
    /// The loaded art is a logo on a plate (`AppleCatalogArtworkPolicy.plate`).
    @State private var artworkPlate = AppleCatalogArtworkPolicy.Plate.none
    /// How the loaded art sits in the card (`AppleCatalogArtworkPolicy.framing`).
    @State private var artworkFraming = AppleCatalogArtworkPolicy.Framing.fill
    private let discCatalog = AppleDiscCatalog.shared

    init(item: AppleCatalogItem, sizing: AppleCatalogCardSizing = .catalog, viewportWidth: CGFloat? = nil,
         progress: Double? = nil, resumeCaption: String? = nil, resumeStillURL: URL? = nil, resumeTitle: String? = nil,
         width: CGFloat? = nil) {
        self.item = item
        self.sizing = sizing
        self.viewportWidth = viewportWidth
        self.progress = progress
        self.resumeCaption = resumeCaption
        self.resumeStillURL = resumeStillURL
        self.resumeTitle = resumeTitle
        self.widthOverride = width
    }

    /// Discover's sizes apply only to its rails. Detail suggestions and the
    /// full-height Featured card retain their own presentation.
    private var activeRowStyle: AppleDiscoverRowStyle? {
        Self.activeRowStyle(rowStyle, sizing: sizing)
    }

    nonisolated private static func activeRowStyle(_ rowStyle: AppleDiscoverRowStyle?,
                                                   sizing: AppleCatalogCardSizing) -> AppleDiscoverRowStyle? {
        [.catalog, .featured, .continueWatching, .ranked].contains(sizing) ? rowStyle : nil
    }

    private var artworkPurpose: AppleArtworkResolver.Purpose { isLandscapeCard ? .resume : .poster }

    @State private var loadedArtworkURL: URL?
    @State private var artworkTraceID: UUID?

    private var artworkRequestID: String {
        [item.id, item.posterURL?.absoluteString ?? "", item.backgroundURL?.absoluteString ?? "", resumeStillURL?.absoluteString ?? "",
         artworkPurpose.rawValue, artworkPurpose.size(pixelWidth: cardWidth * displayScale),
         AppleCatalogArtworkPolicy.configurationMarker(metadataConfiguration)].joined(separator: "|")
    }

    nonisolated static func resolvedPosterURL(item: AppleCatalogItem, sizing: AppleCatalogCardSizing,
        resumeStillURL: URL? = nil, libraryPoster: AppleLibraryPoster? = nil,
        fallbackArtwork: AppleArtworkResolver.Artwork? = nil, failedArtworkURLs: Set<URL> = []) -> URL? {
        var candidates = sizing == .continueWatching
            ? AppleCatalogArtworkPolicy.resumeCandidates(item: item, still: resumeStillURL, fallback: fallbackArtwork)
            : AppleCatalogArtworkPolicy.candidates(item: item, landscape: isLandscape(sizing), fallback: fallbackArtwork)
        if sizing == .portraitPromo {
            // The big Featured card is a tall 2:3 tile: a 16:9 backdrop filled
            // into it kept a third of the picture and read as broken art. A
            // failed poster falls to the title card instead.
            let backdrops = Set([item.backgroundURL, fallbackArtwork?.backgroundURL].compactMap { $0 })
            candidates.removeAll { backdrops.contains($0) }
        }
        if !isLandscape(sizing), let libraryPoster {
            candidates.insert(libraryPoster.url, at: 0)
        }
        return AppleCatalogArtworkPolicy.next(in: candidates, failed: failedArtworkURLs)
    }

    /// A card never renders as an empty slot: when the artwork is missing or
    /// fails, the tile carries the title instead (FEEDBACK X7), set as a
    /// title card — bold white type, not a grey box with grey text (N49 #20).
    private func artworkPlaceholder(hasArtwork: Bool) -> some View {
        ZStack {
            AppleRemoteImage.defaultLoadingFill
            if sizing != .continueWatching || !hasArtwork {
                Text(item.name)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .minimumScaleFactor(0.6)
                    .padding(12)
            }
        }
    }

    /// The backdrop a logo-on-a-plate poster is drawn over.
    private func plateBackdropURL(showing posterURL: URL?) -> URL? {
        guard artworkPlate != .none, !isLandscapeCard else { return nil }
        return AppleCatalogArtworkPolicy.plateBackdrop(item: item, fallback: fallbackArtwork, showing: posterURL)
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
        let posterURL = Self.resolvedPosterURL(item: item, sizing: sizing, resumeStillURL: resumeStillURL,
            libraryPoster: libraryPoster, fallbackArtwork: fallbackArtwork, failedArtworkURLs: failedArtworkURLs)
        let purpose: AppleArtworkResolver.Purpose = !isLandscapeCard && libraryPoster?.url == posterURL && posterURL != nil ? .poster
            : AppleCatalogArtworkPolicy.purpose(of: posterURL, item: item, fallback: fallbackArtwork, preferred: artworkPurpose)
        let backdropURL = plateBackdropURL(showing: posterURL)
        VStack(alignment: .leading, spacing: 8) {
            AppleCatalogArtwork(url: posterURL, contentMode: posterAspect == nil ? .fill : .fit,
                                onFailure: { artworkDidFail(url: posterURL) }, onImageLoad: { image in
                loadedArtworkURL = posterURL
                if let libraryPoster, libraryPoster.url == posterURL {
                    AppleLocalLibraryStore.shared.posterDidLoad(libraryPoster)
                }
                if let artworkTraceID, AppleLibraryArtworkTrace.shared.isActive {
                    AppleLibraryArtworkTrace.shared.posterShown(artworkTraceID)
                }
                #if DEBUG && os(tvOS)
                AppleLibraryPerformanceProbe.shared.posterReady(item.id)
                #endif
                #if DEBUG
                if sizing == .continueWatching {
                    appleTrace("continue artwork \(ApplePlaybackIdentity.digest(for: item.mediaID).prefix(12)) loaded \(image.width)x\(image.height)")
                }
                #endif
                artworkPlate = AppleCatalogArtworkPolicy.plate(of: image)
                artworkFraming = sizing == .continueWatching ? .fill : AppleCatalogArtworkPolicy.framing(
                    landscapeCard: isLandscapeCard, imageWidth: image.width, imageHeight: image.height)
            }, purpose: purpose, displaySize: CGSize(width: cardWidth, height: cardHeight))
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
                        AppleCatalogArtwork(url: posterURL, displaySize: CGSize(width: cardWidth, height: cardHeight))
                            .frame(width: cardWidth, height: cardHeight)
                            .blur(radius: 24, opaque: true)
                            .clipped()
                            .accessibilityHidden(true)
                    } else if artworkPlate != .none {
                        ZStack {
                            Color(white: 0.12)
                            if let backdropURL {
                                AppleCatalogArtwork(url: backdropURL, displaySize: CGSize(width: cardWidth, height: cardHeight))
                                    .frame(width: cardWidth, height: cardHeight)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                }
                .background(AppleRemoteImage.defaultLoadingFill)
                .overlay {
                    if posterURL == nil || loadedArtworkURL != posterURL { artworkPlaceholder(hasArtwork: posterURL != nil) }
                }
                .overlay(alignment: .bottomLeading) {
                    if sizing == .continueWatching, posterURL != nil {
                        AppleContinueWatchingArtworkTitle(title: resumeTitle ?? item.name, hasProgress: progress != nil)
                    }
                }
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 0) {
                        // A disc image (ISO, VIDEO_TS, BDMV) in the library.
                        if discCatalog.contains(item) { AppleDiscBadge() }
                    }
                }
                .overlay(alignment: .bottom) {
                    if let progress { AppleStillProgressBar(progress: progress, width: cardWidth) }
                }
                .clipShape(.rect(cornerRadius: cornerRadius))
                .appleRowTileLift(activeRowStyle?.platform == .mac)
                .appleTVCardArtworkFocus(cornerRadius: cornerRadius)
                .onChange(of: item.id) { _, _ in
                    failedArtworkURLs = []; fallbackArtwork = nil; artworkRetries = 0
                    let trace = AppleLibraryArtworkTrace.shared
                    guard trace.isActive else { return }
                    if let artworkTraceID { trace.cardDisappeared(artworkTraceID) }
                    traceArtworkAppearance(posterURL: posterURL)
                }
                .onChange(of: posterURL) { _, posterURL in
                    artworkPlate = .none
                    artworkFraming = .fill
                    let trace = AppleLibraryArtworkTrace.shared
                    guard trace.isActive, let artworkTraceID else { return }
                    trace.posterChanged(artworkTraceID,
                        hasPoster: posterURL != nil && loadedArtworkURL == posterURL)
                }
                .onChange(of: resumeStillURL) { _, _ in failedArtworkURLs = []; artworkRetries = 0 }
                .onChange(of: artworkRequestID) { _, _ in
                    artworkLookup = .init(suppliedArtworkFailed: failedArtworkURLs.contains {
                        $0 == item.posterURL || $0 == item.backgroundURL
                    })
                }
                .task(id: failedArtworkURLs.count) {
                    // Out of art after a failure: try the candidates again
                    // shortly, twice, rather than keep the title tile.
                    guard posterURL == nil, !failedArtworkURLs.isEmpty,
                          let delay = AppleCatalogArtworkPolicy.retryDelay(afterRetries: artworkRetries) else { return }
                    try? await Task.sleep(for: delay)
                    guard !Task.isCancelled else { return }
                    artworkRetries += 1
                    failedArtworkURLs = []
                }
                .task(id: artworkRequestID + "|lookup:\(artworkLookup.attempt)") {
                    let attempt = artworkLookup.attempt
                    guard artworkLookup.completedAttempt != attempt else { return }
                    #if DEBUG
                    if sizing == .ranked {
                        AppleInteractionTrace.record(.network,
                            "ranked artwork title=\(item.name) background=\(AppleCatalogArtworkPolicy.traceID(item.backgroundURL)) poster=\(AppleCatalogArtworkPolicy.traceID(item.posterURL))")
                    }
                    #endif
                    let artwork = await AppleArtworkResolver.shared.resolve(
                        mediaID: item.imdbID ?? item.mediaID,
                        type: item.type,
                        existingPosterURL: attempt == 0 ? item.posterURL : nil,
                        existingBackgroundURL: attempt == 0 ? item.backgroundURL : nil,
                        purpose: artworkPurpose,
                        pixelWidth: cardWidth * displayScale,
                        configuration: metadataConfiguration
                    )
                    guard !Task.isCancelled else { return }
                    artworkLookup.complete(attempt: attempt)
                    fallbackArtwork = artwork
                    #if DEBUG
                    if sizing == .continueWatching {
                        appleTrace("continue artwork lookup \(ApplePlaybackIdentity.digest(for: item.mediaID).prefix(12)) backdrop=\(artwork?.backgroundURL != nil) poster=\(artwork?.posterURL != nil)")
                    }
                    #endif
                }

                .task(id: artworkPlate) {
                    // A logo-only poster with no backdrop of its own: look one
                    // up once, for the card to draw the logo over.
                    guard artworkPlate != .none, !isLandscapeCard, fallbackArtwork == nil,
                          backdropURL == nil else { return }
                    fallbackArtwork = await AppleArtworkResolver.shared.resolve(
                        mediaID: item.mediaID,
                        type: item.type,
                        existingPosterURL: nil,
                        existingBackgroundURL: nil,
                        purpose: .resume,
                        pixelWidth: cardWidth * displayScale,
                        configuration: metadataConfiguration
                    )
                }

            if sizing == .continueWatching, let resumeCaption {
                Text(resumeCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                    .frame(width: cardWidth, alignment: .leading)
                    .appleTVCardCaptionFocus()
            } else if showsTitle, let activeRowStyle {
                AppleWordClampedText(text: item.name, lines: dynamicTypeSize.isAccessibilitySize ? 4 : 2,
                                     reservesSpace: true)
                    .font(activeRowStyle.posterTitleFont)
                    .foregroundStyle(Color.primary.opacity(0.7))
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
        .overlay(alignment: .topLeading) {
            if showsFocusTitle {
                // Posters stay clean until focused (owner 2026-10-12).
                // The caption draws in the row gap without changing layout.
                Text(item.name)
                    .font(.system(size: AppleTVBillboardMetrics.focusedTitleFontSize))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: cardWidth, alignment: .leading)
                    .offset(y: cardHeight + AppleTVBillboardMetrics.focusedTitleGap)
                    .appleTVFocusedCaption()
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .foregroundStyle(.primary)
        // A combined element with no text of its own left the link without a
        // name: every Apple TV poster (N41) and the iPad's full-height
        // Featured posters (N49) had a blank VoiceOver label.
        .accessibilityElement(children: AppleCatalogCardAccessibility.namesItself(drawsTitle: showsTitle)
            ? .ignore : .combine)
        .accessibilityLabel(resumeTitle ?? item.accessibilityTitle)
        .accessibilityValue(resumeCaption ?? item.releaseInfo ?? "")
        .appleHoverAffordance()
        .onAppear { traceArtworkAppearance(posterURL: posterURL) }
        .onDisappear {
            let trace = AppleLibraryArtworkTrace.shared
            guard trace.isActive, let artworkTraceID else { return }
            trace.cardDisappeared(artworkTraceID)
        }
    }

    private func traceArtworkAppearance(posterURL: URL?) {
        let trace = AppleLibraryArtworkTrace.shared
        guard trace.isActive else { return }
        let cardID = artworkTraceID ?? UUID()
        artworkTraceID = cardID
        trace.cardAppeared(cardID, catalogID: item.id,
            hasPoster: posterURL != nil && loadedArtworkURL == posterURL)
    }

    private func artworkDidFail(url: URL?) {
        if let url {
            if url == item.posterURL || url == item.backgroundURL {
                artworkLookup.suppliedArtworkFailed()
            }
            #if DEBUG
            if sizing == .continueWatching {
                appleTrace("continue artwork failed \(ApplePlaybackIdentity.digest(for: item.mediaID).prefix(12)) attempt=\(failedArtworkURLs.count + 1)")
            }
            if sizing == .ranked {
                AppleInteractionTrace.record(.failure,
                    "ranked artwork title=\(item.name) failed=\(AppleCatalogArtworkPolicy.traceID(url))")
            }
            #endif
            failedArtworkURLs.insert(url)
        }
    }

    private var isLandscapeCard: Bool { Self.isLandscape(sizing) }

    nonisolated static func isLandscape(_ sizing: AppleCatalogCardSizing) -> Bool {
        sizing == .featured || sizing == .continueWatching || sizing == .ranked
    }

    /// The poster's width over height when it is drawn whole in a 16:9 card.
    private var posterAspect: Double? {
        if case .posterInFrame(let aspect) = artworkFraming { return aspect }
        return nil
    }

    private var showsTitle: Bool {
        if sizing == .ranked || sizing == .portraitPromo || sizing == .continueWatching { return false }
        #if os(tvOS)
        return isLandscapeCard
        #else
        return true
        #endif
    }

    /// Apple TV portrait posters: a one-line title shown only while focused.
    private var showsFocusTitle: Bool {
        #if os(tvOS)
        return !showsTitle && !isLandscapeCard && sizing != .portraitPromo
        #else
        return false
        #endif
    }

    private var cardWidth: CGFloat {
        widthOverride ?? Self.width(sizing: sizing, rowStyle: rowStyle, scaledCardWidth: scaledCardWidth,
                   viewportWidth: viewportWidth, regularWidth: horizontalSizeClass == .regular)
    }

    private var cardHeight: CGFloat {
        Self.height(sizing: sizing, width: cardWidth)
    }

    /// The tile's size in points.
    nonisolated static func width(sizing: AppleCatalogCardSizing, rowStyle: AppleDiscoverRowStyle?,
                                  scaledCardWidth: CGFloat, viewportWidth: CGFloat?, regularWidth: Bool,
                                  platform: AppleUIPlatform = .current) -> CGFloat {
        if let activeRowStyle = activeRowStyle(rowStyle, sizing: sizing) {
            switch sizing {
            case .ranked: return activeRowStyle.rankedWidth
            case .continueWatching, .featured: return activeRowStyle.stillWidth
            default: return activeRowStyle.posterWidth
            }
        }
        if sizing == .portraitPromo {
            if platform == .tvOS { return AppleTVBillboardMetrics.posterWidth }
            if rowStyle?.platform == .pad { return 260 }
            if rowStyle?.platform == .phone { return 200 }
            if platform == .iOS { return regularWidth ? 260 : 200 }
            let width = viewportWidth.flatMap { $0 > 0 ? $0 : nil } ?? 390
            return max(1, min(width - 32, 480))
        }
        if isLandscape(sizing) {
            // Continue Watching is a quarter-width card on the TV's 1920 pt
            // stage, like Up Next; 360 pt read as an afterthought by the hero.
            if platform == .tvOS { return 480 }
            if platform == .iOS, sizing == .continueWatching { return regularWidth ? 320 : 248 }
            return sizing == .continueWatching ? 260 : 320
        }
        if sizing == .detailSuggestions {
            #if os(iOS) || os(visionOS)
            if regularWidth { return 150 }
            let width = viewportWidth.flatMap { $0 > 0 ? $0 : nil } ?? 390
            return max(1, (width - 48) / 2.7)
            #else
            return 150
            #endif
        }
        if platform == .tvOS { return AppleTVBillboardMetrics.posterWidth }
        if platform == .iOS { return regularWidth ? 180 : 148 }
        return min(max(scaledCardWidth, 140), 220)
    }

    nonisolated static func height(sizing: AppleCatalogCardSizing, width: CGFloat) -> CGFloat {
        width * (isLandscape(sizing) ? 9.0 / 16.0 : 1.5)
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
    var loadingFill: Color = AppleRemoteImage.defaultLoadingFill
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

    var purpose: AppleArtworkResolver.Purpose? = nil
    var displaySize: CGSize? = nil
    var priority: AppleArtworkRequestQueue.Priority = .visible
    @Environment(\.displayScale) private var displayScale
    @State private var displayedPixels = CGSize.zero

    private var displayRequest: AppleCatalogArtworkPolicy.DisplayRequest {
        let pixels = displaySize.map { CGSize(width: $0.width * displayScale, height: $0.height * displayScale) } ?? displayedPixels
        return AppleCatalogArtworkPolicy.displayRequest(url: url, pixels: pixels, purpose: purpose)
    }

    var body: some View {
        let request = displayRequest
        AppleRemoteImage(url: request.url, contentMode: contentMode, placeholderSystemImage: "",
                         onLoad: onLoad == nil && onImageLoad == nil ? nil : { [onLoad, onImageLoad] image in
                             onLoad?()
                             onImageLoad?(image)
                         },
                         onFailure: request.waitsForGeometry ? nil : onFailure,
                         loadingFill: loadingFill,
                         keepsImageWhileReloading: keepsImageWhileReloading || request.fixedPixelDimension != nil,
                         fixedPixelDimension: request.fixedPixelDimension, priority: priority)
            .background { if request.waitsForGeometry { loadingFill } }
            .onGeometryChange(for: CGSize.self) { [displayScale] geometry in
                CGSize(width: (geometry.size.width * displayScale).rounded(.up),
                       height: (geometry.size.height * displayScale).rounded(.up))
            } action: { displayedPixels = $0 }
    }
}

@MainActor
struct AppleCatalogItemDetailView: View {
    @Environment(\.appleIsLargeLayout) private var isLargeLayout
    @Environment(\.appleExpandsPhoneLayout) private var expandsPhoneLayout
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    /// The title's trailer on the user's server (`AppleServerTrailerStore`):
    /// the Trailer button plays it, on every platform.
    @State private var serverTrailer: AppleServerTrailer?
    @State private var showsServerTrailer = false
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

    private let navigationItem: AppleCatalogItem
    @State private var serverDestination: AppleTitlePagePolicy.ServerDestination
    var item: AppleCatalogItem { serverDestination.displayItem(navigationItem: navigationItem) }
    let source: AppleSource
    let relatedItems: [AppleCatalogItem]
    let mediaIndex: AppleMediaIndexStore
    let playbackSources: [AppleSource]
    let metadataConfiguration: AppleTMDBConfiguration?
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
    @State private var titleMediaVersions: [AppleMediaVersion] = []
    @State private var selectedServerVersion: String?
    @State private var serverTitleMatches: [AppleMediaServerTitleMatch] = []
    @State private var serverTitleMatchCache: [AppleMediaServerTitleQuery: [AppleMediaServerTitleMatch]] = [:]
    @State private var selectedServerTitleID: String?
    @State private var serverFailedVersions: Set<String> = []
    @State private var serverConversionAttempted = false
    @State private var serverRetrying = false
    @State private var automaticLocalVersionFallback = false
    @State private var versionResume: AppleVersionResumeConfirmation?
    @State private var confirmsVersionResume = false
    @State private var confirmedVersionID: String?
    @State private var discFile: AppleLibraryItem?
    @State private var hasMatchingLocalGroup = false
    @State private var titlePageStreamBadges: [AppleStreamFormatBadge] = []

    private var isDiscTitle: Bool { discFile != nil }
    /// A DVD, whose menu Play Disc opens. A Blu-ray has no menu here
    /// (`AppleDiscFormat`): its Play is the main feature and there is no
    /// Skip to Movie.
    private var discOffersMenu: Bool {
        discFile.map { AppleDiscCatalog.shared.format(for: $0).supportsMenu } ?? false
    }
    /// What the disc page's Play does: the menu on a DVD, the main feature
    /// on a Blu-ray.
    private var discPlayStart: AppleDiscPlaybackStart { discOffersMenu ? .menu : .mainTitle }

    /// Library matching is tied to content changes, never playback progress.
    private func refreshTitleLocalFiles() {
        let matched = item.withMediaID(pageMetadata.resolvedMediaID ?? item.mediaID)
        hasMatchingLocalGroup = localGroup != nil || !library.matchingGroups(matched).isEmpty
        if hasMatchingLocalGroup {
            serverTitleMatches = []
            selectedServerTitleID = nil
        }
        let files = library.localFiles(for: matched, group: localGroup,
            episode: episodeList.episodes.first { $0.id == episodeList.selectedEpisodeID })
        if localFiles.first?.id != files.first?.id { playbackUI.localInspection = nil }
        localFiles = files
        discFile = library.discFile(in: localFiles)
        refreshTitleStreamBadges()
    }

    /// The disc's titles, from the engine's read of the local image or from
    /// the last play of it; empty for one title.
    private var discTitles: AppleDiscTitleList {
        guard let discFile else { return AppleDiscTitleList() }
        return AppleDiscTitleList(AppleDiscCatalog.shared.titles[discFile.url] ?? [])
    }

    /// Play Disc (the disc's menu, the main title until the engine has one),
    /// Skip to Movie (the main feature), or one title from the Titles row.
    private func startDisc(_ start: AppleDiscPlaybackStart, titleID: Int? = nil) {
        guard canStartPlayback else { return }
        let format = discFile.map { AppleDiscCatalog.shared.format(for: $0) } ?? .dvd
        playbackUI.disc = AppleDiscPlaybackChoice(start: start, titleID: titleID, format: format)
        // The menu and a chosen title start from the top; Skip to Movie
        // resumes where the film was left.
        if start == .menu || titleID != nil { playbackUI.startsFromBeginning = true }
        appleTrace("title page disc: \(start.rawValue)\(titleID.map { " title \($0)" } ?? "")")
        playbackUI.request = UUID()
    }

    /// Format badges for this title: the local file's probe (or name). No network.
    private func refreshTitleStreamBadges() {
        titlePageStreamBadges = localFiles.first.map {
            playbackUI.localInspection?.badges ?? AppleStreamFormatBadge.parse($0.name)
        } ?? []
    }

    @State private var playbackCoordinator = ApplePlaybackCoordinator.forBrowsing()
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
    /// The displayed title's own media-server reference.
    private var serverReference: AppleMediaServerItemReference? {
        AppleMediaServerItemReference.parse(item.mediaID)
    }
    /// A media-server title's catalog details, for Cast & Crew only.
    @State private var catalogCredits: AppleTMDBDetails?
    @State private var shownCreditOrigin: AppleTitlePagePolicy.CreditOrigin?
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
    @State private var detailHeroIsOffscreen = false
    // The text title and its metadata line grow with Dynamic Type; fixed
    // point sizes stayed small at the accessibility sizes (iPad v2 re-run).
    @ScaledMetric(relativeTo: .title3) private var scaledLandscapeTitleSize: CGFloat = AppleDetailMetrics.landscapeTitleFontSize
    @ScaledMetric(relativeTo: .headline) private var scaledPortraitTitleSize: CGFloat = AppleDetailMetrics.portraitTitleFontSize
    @ScaledMetric(relativeTo: .subheadline) private var scaledMetadataSize: CGFloat = AppleDetailMetrics.metadataFontSize
    private let playbackStore = ApplePlaybackStore()
    private let ratingStore = AppleTitleRatingStore()

    private let metadataResolver = AppleMetadataResolver()
    private let playbackPreparer = ApplePlaybackPreparer()

    init(
        item: AppleCatalogItem,
        source: AppleSource,
        relatedItems: [AppleCatalogItem] = [],
        mediaIndex: AppleMediaIndexStore,
        playbackSources: [AppleSource],
        metadataConfiguration: AppleTMDBConfiguration?,
        settings: AppleSettingsStore,
        openSettings: @escaping () -> Void,
        initialAutoPlay: Bool = false,
        localGroup: AppleLibrarySeries? = nil,
        localSourceStore: AppleSourceStore? = nil,
        mediaServerLibrary: AppleMediaServerLibraryStore? = nil,
        tabToolbar: AppleTabToolbarContext?
    ) {
        self.navigationItem = item
        _serverDestination = State(initialValue: AppleTitlePagePolicy.ServerDestination(item: item))
        self.source = source
        self.relatedItems = relatedItems
        self.mediaIndex = mediaIndex
        self.playbackSources = playbackSources
        self.metadataConfiguration = metadataConfiguration
        self.settings = settings
        self.openSettings = openSettings
        self.initialAutoPlay = initialAutoPlay
        self.localGroup = localGroup
        self.localSourceStore = localSourceStore
        self.mediaServerLibrary = mediaServerLibrary
        self.tabToolbar = tabToolbar
        _slotArt = State(initialValue: AppleTitlePageSlotArtState(itemID: item.id))
        _pageMetadata = State(initialValue: AppleTitlePageMetadataState(
            isPreparing: ApplePlayGatingPolicy.isPreparingOnAppear(mediaID: item.mediaID)
        ))
    }

    var body: some View {
        Group {
            #if DEBUG
            ScrollViewReader { reader in
                AppleTitlePageContent(page: self).task(id: episodeList.episodes.count) {
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
            AppleTitlePageContent(page: self)
            #endif
        }
        .environment(\.appleTMDBConfiguration, metadataConfiguration)
        .task(id: "\(item.mediaID):\(AppleServerTrailerStore.shared.revision):\(settings.titlePageTrailersEnabled)") {
            guard settings.titlePageSections.trailers else {
                serverTrailer = nil
                return
            }
            // Throws only when the servers changed; the task runs again then.
            do { serverTrailer = try await AppleServerTrailerStore.shared.trailer(for: item) } catch {}
        }
        .appleServerTrailerPresentation(serverTrailer, isPresented: $showsServerTrailer)
    }

    static let serverTrailerSymbol = "film"

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

    private var detailContentBase: some View {
        Group {
            // The player owns progress and transport updates while covering this
            // page. Remove the covered content's Observation subscriptions;
            // on dismissal it reads the latest saved progress again.
            if titlePageIsCovered {
                Color.clear
            } else {
                #if os(tvOS)
                tvOSDetailLayout
                    .accessibilityIdentifier("detail.screen.\(item.type).\(item.mediaID)")
                #else
                ScrollView {
                    AppleTitlePageScrollContent(page: self)
                }
                .accessibilityIdentifier("detail.screen.\(item.type).\(item.mediaID)")
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
                .appleStatusBarShield(topInset: pageGeometry.safeAreaInsets.top, usesPhoneLayout: usesPhoneTitleChrome)
                #endif
            }
        }
        .scrollIndicators(AppleDesignTokens.scrollIndicatorVisibility)
        .coordinateSpace(name: "detail-scroll")
        .alert(versionResumeTitle, isPresented: $confirmsVersionResume) {
            versionResumeButtons
        }
        #if os(iOS) || os(visionOS)
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
        #if os(macOS) || os(iOS) || os(visionOS)
        .appleTitlePageToolbar(pageID: item.id, title: displayTitle, heroIsOffscreen: detailHeroIsOffscreen,
                              topInset: pageGeometry.safeAreaInsets.top,
                              usesPhoneLayout: usesPhoneTitleChrome,
                              backIsBlocked: playbackUI.presentation != nil) { dismiss() }
        .environment(\.appleTabToolbar, tabToolbar)
        #endif
        #if os(iOS) || os(visionOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        #endif
        #if os(iOS) || os(visionOS)
        // On iPhone the bar is hidden. The inline title mode, dark toolbar
        // scheme and hidden bar background here still serve iPad and
        // visionOS, where the bar stays over the hero as on Discover:
        // see-through, the art running up under it (the hero pulls itself up
        // by the page's top inset, which includes the bar).
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
        .onChange(of: library.contentRevision, initial: true) { _, _ in
            guard !titlePageIsCovered else { return }
            refreshTitleLocalFiles()
        }
        .onChange(of: titlePageIsCovered) { _, covered in
            // Metadata for unrelated library titles can finish during playback.
            // Defer the matching pass until this page is visible again.
            if !covered {
                refreshTitleLocalFiles()
                advanceCompletedServerEpisode()
            }
        }
        .onChange(of: pageMetadata.resolvedMediaID) { _, _ in refreshTitleLocalFiles() }
    }

    // Split from detailContentBase: one chain of every modifier is more than the visionOS
    // type checker finishes in reasonable time.
    var detailContent: some View {
        detailContentBase
        .task(id: serverTitleQuery) {
            guard AppleMediaServerItemReference.parse(item.mediaID) == nil,
                  AppleXtreamReference.parse(item.mediaID) == nil,
                  !hasMatchingLocalGroup, let mediaServerLibrary else { return }
            let query = serverTitleQuery
            let matches: [AppleMediaServerTitleMatch]
            if let cached = serverTitleMatchCache[query] {
                matches = cached
            } else {
                matches = await mediaServerLibrary.titleMatches(query: query)
            }
            guard !Task.isCancelled, !hasMatchingLocalGroup else { return }
            serverTitleMatchCache[query] = matches
            let selection = matches.first { $0.id == selectedServerTitleID } ?? matches.first
            serverTitleMatches = matches
            if selectedServerTitleID != selection?.id { selectServerTitle(selection) }
        }
        .onChange(of: episodeList.episodes) { _, _ in refreshTitleLocalFiles() }
        .onChange(of: episodeList.selectedEpisodeID) { previous, selected in
            serverDestination.selectionChanged(from: previous, to: selected)
            refreshTitleLocalFiles()
        }
        .onChange(of: watchedEpisodeIDs) { _, _ in advanceCompletedServerEpisode() }
        // The local file's format and, for a disc image, its titles: read by
        // the engine from the file itself, once per page.
        .task(id: localFiles.map(\.id)) {
            guard let file = discFile ?? localFiles.first else { titleMediaVersions = []; return }
            let inspection = await library.inspection(for: file)
            guard !Task.isCancelled else { return }
            playbackUI.localInspection = inspection
            let references = Set(localFiles.map(\.id))
            titleMediaVersions = library.mediaVersions(for: file).filter { $0.isAvailable(references: references) }
            refreshTitleStreamBadges()
        }
        .task(id: "versions:\(playbackServerReference?.mediaID ?? item.id):\(episodeList.selectedEpisodeID ?? "")") {
            guard localFiles.isEmpty, let msLibrary = mediaServerLibrary,
                  let reference = playbackServerReference else { return }
            do {
                let detail = try await msLibrary.detail(for: reference)
                let selected = detail.episodesBySeason.values.flatMap { $0 }.first { $0.id == episodeList.selectedEpisodeID } ?? detail.item
                let versions = try await msLibrary.mediaVersions(for: selected, in: detail)
                guard !Task.isCancelled else { return }
                titleMediaVersions = versions
                await msLibrary.preparePlayback(for: selected, in: detail)
            } catch { }
        }
        .task(id: "trailer-reset:\(item.id):\(allowsTrailerAutoplay)") {
            heroTrailer.isActive = false
            heroTrailer.isPlaying = false
            heroTrailer.hasStarted = false
            heroTrailer.wasPressed = false
            heroTrailer.pageShownAt = .now
            // Autoplay is muted (the page clamps it anyway); the sound
            // control or Play Trailer turns sound on.
            heroTrailer.muted = true
            heroTrailer.allowsSound = false
        }
        // Art-first: the autoplaying trailer is not even looked for until the
        // hero still is on screen, and at low priority behind the page.
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange).receive(on: RunLoop.main)) { _ in
            lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        .task(id: AppleTrailerArtFirstPolicy.autoplayRequestID(
            itemID: item.id, enabled: allowsTrailerAutoplay, art: heroStill.art, keys: trailerCandidates
        ), priority: .low) {
            guard allowsTrailerAutoplay,
                  AppleTrailerArtFirstPolicy.mayRequestTrailer(art: heroStill.art, pressed: false) else { return }
            // A pressed Play Trailer got there first.
            guard !Task.isCancelled, !heroTrailer.hasStarted else { return }
            guard let playableKey = await resolvePlayableTrailerKey(startingAt: 0) else { return }
            // The still's delay runs from the page appearing; the probe's time counts against it.
            let remaining = AppleTrailerStartPolicy.remainingDelay(on: AppleTrailerStartPolicy.current(isLargeLayout: isLargeLayout),
                                                                   pageShownAt: heroTrailer.pageShownAt, now: .now)
            if remaining > 0 { try? await Task.sleep(for: .seconds(remaining)) }
            // …or while its first candidate was being probed. Nor under or
            // after a Play that is still loading (a disc reads for 14 s).
            guard !Task.isCancelled, !heroTrailer.hasStarted, !titlePageIsCovered,
                  !playbackCoordinator.phase.isBusy else { return }
            heroTrailer.pinnedKey = playableKey
            heroTrailer.muted = AppleTrailerSoundMemory.autoplayStartsMuted()
            heroTrailer.allowsSound = !heroTrailer.muted
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
        // Keyed on the IMDb id too: a title opened before the server's rows
        // listed it (deep link, search) asks again once they do.
        .task(id: "catalog-credits:\(item.id):\(catalogCreditsIMDbID ?? "")") { await loadCatalogCredits() }
        .onChange(of: item.id) {
            catalogCredits = nil
            shownCreditOrigin = nil
        }
        .onChange(of: creditOrigin, initial: true) { _, origin in
            if shownCreditOrigin == nil { shownCreditOrigin = origin }
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
            // can fail it (an SVG, an opaque plate) where the preview logo the
            // Discover hero draws passes (Project Hail Mary, iPad v2).
            if let logoURL = await AppleTransparentPNGLogoValidator.firstValid(in: candidates), !Task.isCancelled {
                #if DEBUG
                AppleLaunchClock.mark("detail.validated")
                #endif
                titleWordmark.state = .valid(logoURL)
                return
            }
            if !Task.isCancelled { titleWordmark.state = .unavailable }
        }
        // Keep these tasks off the page's already large modifier chain.
        .background { slotArtWatcher }
        .background { optionalDetailTasks }
        // Keyed by the item only: a wordmark URL that arrives late must not
        // hide a text title that is already on screen; the text stays until
        // the wordmark has actually loaded.
        .task(id: "title-logo-grace:\(item.id)") {
            titleWordmark.graceExpired = false
            try? await Task.sleep(for: .seconds(AppleTitleLogoPolicy.loadingGrace))
            guard !Task.isCancelled else { return }
            titleWordmark.graceExpired = true
        }
        .task(id: recordID) {
            let viewedRecord = titleActions.openedRecord(item: item, sourceID: source.id, mediaIndex: mediaIndex)
            try? await mediaIndex.upsert(viewedRecord)
        }
        .task(id: navigationItem.id) {
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
            fillTimeline.observeFirstRefresh()
            if usesPhoneTitlePage, slotArt.itemID == item.id, heroStill.image != nil {
                fillTimeline.recordArtworkDecoded()
            }
            markOverviewIfVisible(source: "catalog")
            #if DEBUG
            AppleLaunchClock.mark("detail.prepare")
            #endif
            await prepare()
            if !Task.isCancelled {
                pageMetadata.detailsAnswered = true
                pageMetadata.detailsSettled = true
                fillTimeline.mark(.done)
            }
            await refreshOfflineState()
            // A hero's Play opens the page to play — but only what the page
            // itself would offer: a series whose catalog lists no episodes
            // has no Play here, and starting one anyway could only end in
            // "Playback Unavailable" (iOS 18.6 regression 2026-10-01).
            let canPlay = hasPlaybackRoute
            if await ApplePlayRequestLedger.takeInitialAutoPlay(initialAutoPlay,
                    from: { playbackUI.ledger }, update: { playbackUI.ledger = $0 },
                    after: { if canPlay { await AppleNavigationTransition.settled() } }) {
                if canPlay {
                    playbackUI.request = UUID()
                } else {
                    appleTrace("detail autoplay skipped: nothing on this page can play (\(item.name))")
                }
            }
        }
        .task(id: "similar:\(item.id):\(relatedItems.count):\(pageMetadata.details?.mediaID ?? "")") {
            await refreshSuggestions()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active else { return }
            pauseTrailerPreview(reason: "scene \(phase)")
        }
        .onDisappear {
            fillTimeline.cancelFrameObservation()
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
            episodeList.selectEpisode(in: season,
                defaultID: nextUnwatchedEpisodeID(in: season, from: episodeList.episodes))
        }
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(
            for: UIAccessibility.videoAutoplayStatusDidChangeNotification
        )) { _ in
            systemVideoAutoplayEnabled = UIAccessibility.isVideoAutoplayEnabled
        }
        #endif
        .modifier(AppleMediaPlayerPresentationModifier(presentation: $playbackUI.presentation,
            startup: playbackUI.startup, resolve: resolvePlaybackPress))
        .onChange(of: playbackUI.startup.phase) { _, _ in
            playbackUI.resetCancelledStartup(playbackCoordinator)
        }
        // Hosted on its own view so tvOS takes the system tint: a page opened
        // from Search inherits its `.tint(.primary)`, which drew the focused
        // button's title white on the white focus fill (Apple TV, 2026-10-01).
        .background { playbackUnavailableAlertHost }
    }

    private var playbackUnavailableAlertHost: some View {
        let canPresent = !playbackUI.startup.isPresented && !playbackUI.startup.isLoading
        return Color.clear
        .alert("Playback Unavailable", isPresented: Binding(
            // A failure while the player is up is the player's: it shows its
            // own alert, or hands an every-stream-failed press over (the
            // OpenStream fallback, or `unavailableMessage`) and is closed. Presenting from here as well took
            // the player's cover down and lost the failure with it.
            get: { canPresent
                && (playbackUI.unavailableMessage != nil || (playbackFailure != nil && playbackUI.presentation == nil)) },
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
        #if os(tvOS)
        .tint(nil)
        #else
        .tint(.primary)
        #endif
    }

    /// The iPad, landscape and Vision title page: the hero, the title block
    /// and the rails below it. (The iPhone in portrait and the Mac have their
    /// own pages; see `AppleTitlePageScrollContent`.)
    @ViewBuilder
    var regularTitlePage: some View {
        detailHero
            #if os(iOS) || os(visionOS)
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

            if let summary = titlePageSynopsis {
                Text(summary)
                    .lineLimit(settings.titlePageSections.synopsisLineLimit)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: detailContentWidth, alignment: .leading)
                    .padding(.top, AppleDetailMetrics.iconRowToSynopsisSpacing)
                    .shadow(color: .black.opacity(0.6), radius: 6, y: 1)
            }

            #if !os(iOS) && !os(visionOS)
            if showsEpisodeSection {
                episodeSection
                    .id("vision-episodes")
                    .padding(.top, AppleDetailMetrics.sectionHeaderTopSpacing)
            }
            #endif

        }
        .frame(maxWidth: detailContentWidth, alignment: .leading)
        .padding(.horizontal, detailHorizontalInset)
        .frame(maxWidth: .infinity, alignment: .leading)

        #if os(iOS) || os(visionOS)
        // A rail, outside the column for the same reason as More Like This.
        if showsEpisodeSection {
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
        #if os(iOS) || os(visionOS)
        // The iPhone's and the Mac's Cast & Crew rail: the iPad had
        // none, so its portraits were nowhere (N37).
        let credits = titlePageCredits
        if !credits.isEmpty {
            // The page's margin, the one the synopsis and More Like This
            // use: 40 pt in a wide iPad layout, not the phone's 16 (iPad v2).
            phoneCastSection(credits, inset: detailHorizontalInset)
                .padding(.top, AppleDetailMetrics.sectionHeaderTopSpacing)
        }
        if let summary = titlePageAboutSummary {
            phoneAboutSection(summary, inset: detailHorizontalInset)
                .padding(.top, AppleDetailMetrics.sectionHeaderTopSpacing)
        }
        let information = titlePageInformation
        if !information.isEmpty {
            phoneFactSection("Information", facts: information, identifier: "detail.information", inset: detailHorizontalInset)
                .padding(.top, AppleDetailMetrics.sectionHeaderTopSpacing)
        }
        let languages = titlePageLanguages
        if !languages.isEmpty {
            phoneFactSection("Languages", facts: languages, identifier: "detail.languages", inset: detailHorizontalInset)
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
                AppleTitlePageHeroOverlay(page: self, size: proxy.size)
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
    private func trailerPreview(controlTopInset: CGFloat? = nil, phoneArt: Bool = false) -> some View {
        if trailerPreviewIsShown, let embedURL = trailerEmbedURL {
            AppleYouTubeAutoPreview(
                url: embedURL,
                artworkURL: phoneArt ? phoneSlotArt?.url : heroArtworkURL,
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
                settlesPictureBeforeReveal: true,
                fitsFrame: trailerFitsHeader
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
        #elseif os(iOS) || os(visionOS)
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
        // full-screen Mac display and read as a letterbox strip.
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
        pageGeometry.viewportSize == .zero ? AppleVisionPlayerWindowPolicy.defaultWindowSize : pageGeometry.viewportSize
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
        #if os(iOS) || os(visionOS)
        horizontalSizeClass == .regular
            && viewportSize.width > viewportSize.height
        #elseif os(macOS)
        // A Mac window is resizable to any shape, so there is no size class to
        // ask — the window's own proportions are the answer.
        AppleMacChromeMetrics.isRegularLayout(viewport: viewportSize)
        #else
        false
        #endif
    }

    /// Landscape on any device, including the compact phone. Drives the
    /// full-screen hero and its overlaid title, metadata and actions.
    private var isLandscapeLayout: Bool {
        #if os(iOS) || os(visionOS)
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
        #if os(iOS) || os(visionOS)
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

    func landscapeHeroOverlay(in heroSize: CGSize) -> some View {
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
            matchedServerSource
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
        #if os(iOS) || os(visionOS)
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
    /// (80, bottom 60); focus walks down to the synopsis, Episodes, More
    /// Like This and Cast & Crew, scrolling the page. There is no back
    /// control (Menu pops the page) and no Download action. The backdrop
    /// stays a still: the Apple TV plays no trailer
    /// (`AppleTitlePagePolicy.offersTrailers`), so there is no trailer
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
                    if discOffersMenu {
                        tvOSSkipToMovieButton
                    }
                    if offersStartFromBeginning {
                        tvOSStartFromBeginningButton
                    }
                }
                tvOSIconRow
            }
            matchedServerSource
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
        playbackCoordinator.phase.isBusy || playWaitsForPreparation
    }

    /// Stays focusable while metadata prepares so the default focus lands on
    /// it immediately; the press is ignored until playback can start.
    private var tvOSPlayButton: some View {
        Button {
            guard canStartPlayback else { return }
            if isDiscTitle { startDisc(discPlayStart) } else { playbackUI.request = UUID() }
        } label: {
            HStack(spacing: AppleTVDetailMetrics.pillGlyphSpacing) {
                if tvOSPlayIsBusy, !playbackUI.startup.isLoading, isDiscTitle {
                    AppleDiscSpinner(tint: .black, size: AppleTVDetailMetrics.pillGlyphSize)
                } else if tvOSPlayIsBusy, !playbackUI.startup.isLoading {
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
            versionMenu
            AppleLibraryFixMatchMenuAction()
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
            if serverTrailer != nil {
                Button { showsServerTrailer = true } label: {
                    AppleTVDetailIconLabel(title: "Trailer", systemImage: Self.serverTrailerSymbol)
                }
                .buttonStyle(AppleTVBareButtonStyle())
                .focused($tvDetailFocus, equals: .trailer)
                .accessibilityLabel("Play Trailer")
                .accessibilityIdentifier("detail.serverTrailer")
            }
            Button(action: toggleFavorite) {
                AppleTVDetailIconLabel(title: "My List", systemImage: AppleSemanticAction.myList(saved: titleActions.isFavorite).symbol)
            }
            .buttonStyle(AppleTVBareButtonStyle())
            .focused($tvDetailFocus, equals: .myList)
            .accessibilityLabel(AppleSemanticAction.myList(saved: titleActions.isFavorite).label)
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
            if let summary = titlePageSynopsis {
                // With About off it stays as the hero's short synopsis and
                // stops being a focus stop, so Down skips it.
                AppleTVFocusableParagraph(text: summary,
                                          isFocusable: !showsEpisodeSection && settings.titlePageSections.about)
                    .lineLimit(settings.titlePageSections.synopsisLineLimit)
                    .padding(.horizontal, AppleTVDetailMetrics.overlayLeadingInset)
            }
            if showsEpisodeSection {
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
            let credits = titlePageCredits
            if !credits.isEmpty {
                tvOSCastShelf(credits)
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
                HStack(spacing: AppleTVDetailMetrics.episodeCardGap) {
                    AppleTitlePageEpisodePlaceholder(width: AppleTVDetailMetrics.episodeCardSize.width)
                    AppleTitlePageEpisodePlaceholder(width: AppleTVDetailMetrics.episodeCardSize.width)
                }
                .padding(.horizontal, AppleTVDetailMetrics.overlayLeadingInset)
            case .unavailable:
                EmptyView()
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
                                settings: settings,
                                openSettings: openSettings,
                                mediaServerLibrary: mediaServerLibrary,
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

    private func tvOSCastShelf(_ people: [AppleCreditPerson]) -> some View {
        VStack(alignment: .leading, spacing: AppleTVDetailMetrics.shelfTitleSpacing) {
            AppleTVShelfTitle(title: "Cast & Crew")
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: AppleTVDetailMetrics.posterGap) {
                    ForEach(people) { person in
                        AppleTVCreditCard(person: person)
                    }
                }
                .padding(.vertical, AppleTVDetailMetrics.shelfVerticalBleed)
            }
            .contentMargins(.horizontal, AppleTVDetailMetrics.overlayLeadingInset, for: .scrollContent)
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
            .focusSection()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail.cast")
    }
    #endif

    /// The hero still that is on screen, handed to the trailer preview so its
    /// cover paints the same pixels the moment it is inserted.
    /// Fitted to the trailer's letterbox while a fitted trailer is up, so
    /// the still, the trailer's cover and the video share one frame and the
    /// reveal does not reframe the picture.
    private var heroArtwork: some View {
        GeometryReader { proxy in
            let frame = stillFitsHeader ? AppleTrailerPreviewLayout.fitFrame(in: proxy.size) : CGRect(origin: .zero, size: proxy.size)
            AppleRemoteImage(
                url: heroArtworkURL,
                placeholderSystemImage: "",
                onLoad: { image in
                    heroStill.image = image
                    heroStill.art = heroStill.art.settling(with: .loaded)
                    fillTimeline.recordArtworkDecoded()
                },
                onFailure: heroArtworkFailed,
                keepsImageWhileReloading: true,
                priority: .foreground
            )
            .frame(width: frame.width, height: frame.height)
            .clipped()
            .offset(x: frame.minX, y: frame.minY)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: stillFitsHeader)
    }

    /// The iPad and landscape title pages fit the trailer, unzoomed
    /// (`AppleTrailerPreviewLayout.fitsHeader`). Vision Pro keeps its fill.
    private var trailerFitsHeader: Bool {
        #if os(iOS)
        AppleTrailerPreviewLayout.fitsHeader(isPad: horizontalSizeClass == .regular,
                                             isLandscape: viewportSize.width > viewportSize.height)
        #else
        false
        #endif
    }

    private var stillFitsHeader: Bool {
        trailerFitsHeader && !reduceMotion && heroTrailer.hasStarted && trailerEmbedURL != nil
    }

    private var slotArtWatcher: some View {
        Color.clear
            .task(id: item.id) {
                if slotArt.itemID != item.id {
                    slotArt = AppleTitlePageSlotArtState(itemID: item.id)
                    heroStill.image = nil
                }
                updateSlotArtIfReady()
            }
            .onChange(of: phoneSlotArtCandidate) { _, _ in updateSlotArtIfReady() }
            .onChange(of: pageMetadata.detailsAnswered) { _, _ in updateSlotArtIfReady() }
            .accessibilityHidden(true)
    }

    /// Optional work has the same view lifetime and cancellation ownership,
    /// but cannot delay metadata, episode publication or the done milestone.
    private var usesCatalogDetailEnrichment: Bool {
        AppleXtreamReference.parse(item.mediaID) == nil && AppleMediaServerItemReference.parse(item.mediaID) == nil
    }

    private var optionalDetailTasks: some View {
        AppleTitlePageOptionalTasks(enabled: usesCatalogDetailEnrichment, generation: preparationGeneration,
            resolvedMediaID: pageMetadata.resolvedMediaID, detailsSettled: pageMetadata.detailsSettled,
            episodesLoadFinished: episodeList.loadFinished,
            episodeCount: episodeList.episodes.count,
            loadWatchProviders: loadWatchProviders, loadArtwork: loadOptionalDetailArtwork,
            recordEpisodes: recordDetailEpisodeProgress)
        .task(id: "episodes:\(preparationGeneration):\(episodeList.selectedSeason ?? -1)") {
            await enrichLocalEpisodes()
        }
    }

    private func loadOptionalDetailArtwork() async {
        let generation = preparationGeneration
        guard !Task.isCancelled, AppleTitlePageOptionalTaskPolicy.resolvesFallbackArtwork(
            detailsSettled: pageMetadata.detailsSettled, hasItemPoster: item.posterURL != nil,
            hasDetailsArt: pageMetadata.details?.backdropURL != nil || pageMetadata.details?.posterURL != nil) else { return }
        let artwork = await AppleArtworkResolver.shared.resolve(
            mediaID: pageMetadata.resolvedMediaID ?? item.mediaID, type: item.type,
            existingPosterURL: item.posterURL, existingBackgroundURL: item.backgroundURL,
            configuration: metadataConfiguration)
        guard !Task.isCancelled, preparationGeneration == generation else { return }
        pageMetadata.fallbackArtwork = artwork
    }

    private func recordDetailEpisodeProgress() async {
        guard !Task.isCancelled, episodeList.loadFinished else { return }
        await playbackStore.recordEpisodes(episodeList.episodes, mediaID: progressRecordID)
    }

    /// Reruns the wordmark lookup when its candidates change or the page's
    /// details first answer. Built here: inline, the page's modifier chain
    /// went past the type checker's limit on visionOS.
    private var titleLogoTaskID: String {
        let candidates = titleLogoCandidates.map(\.absoluteString).joined(separator: "|")
        return "title-logo:\(titleMetadataAnswered):\(candidates)"
    }

    /// Nil metadata is an answer too; it must not restart a loading state.
    private var titleMetadataAnswered: Bool { pageMetadata.detailsAnswered }

    private var phoneSlotArt: AppleTitlePageSlotArt? {
        slotArt.itemID == item.id ? slotArt.chosen ?? phoneSlotArtCandidate : phoneSlotArtCandidate
    }

    private func updateSlotArtIfReady() {
        guard slotArt.itemID == item.id,
              AppleTitlePageSlotArt.isReady(knownArt: phoneSlotArtCandidate, detailsAnswered: titleMetadataAnswered) else { return }
        slotArt.chosen = AppleTitlePageSlotArt.updating(slotArt.chosen, with: phoneSlotArtCandidate)
        if slotArt.chosen == nil, titleMetadataAnswered, usesPhoneTitlePage {
            heroStill.art = heroStill.art.settling(with: .failed)
        }
    }

    private var phoneSlotArtCandidate: AppleTitlePageSlotArt? {
        AppleTitlePageSlotArt.choose(item: item, details: pageMetadata.details,
            fallback: pageMetadata.fallbackArtwork, failed: slotArt.failed)
    }

    private func phoneSlotArtFailed(_ art: AppleTitlePageSlotArt) {
        guard slotArt.itemID == item.id else { return }
        slotArt.failed.insert(art.url)
        guard phoneSlotArt == art else { return }
        slotArt.chosen = AppleTitlePageSlotArt.updating(heroStill.image == nil ? nil : slotArt.displayed, with: phoneSlotArtCandidate)
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
    /// It took only the first that existed: a backdrop that 404s (some new
    /// titles have none) left the hero black under the
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
        AppleMetadataPresentationPolicy.title(metadata: pageMetadata.details?.title, fallback: item.name)
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

    /// Every wordmark this title has, best first: TMDB's, then the record's.
    private var titleLogoCandidates: [URL] {
        var seen = Set<URL>()
        return [pageMetadata.details?.logoURL, item.logoURL]
            .compactMap { $0 }
            .filter { seen.insert($0).inserted }
    }

    private var trailerEmbedURL: URL? {
        AppleTrailerPreviewPolicy.embedURL(for: trailerKey)
    }

    private var trailerKey: String? {
        // A key pinned before Trailers went off stays pinned; drop it too.
        guard settings.titlePageSections.trailers else { return nil }
        return AppleTrailerArtFirstPolicy.heroTrailerKey(
            pinned: heroTrailer.pinnedKey, gaveUp: heroTrailer.gaveUp, candidates: trailerCandidates
        )
    }

    /// Empty with Settings › Title Page › Trailers off, which leaves the
    /// hero, the Trailers rail and Play Trailer nothing to load.
    private var trailerCandidates: [String] {
        #if DEBUG
        // Deterministic embed-error checks on the existing simulators.
        if let keys = UserDefaults.standard.string(forKey: "OpenStreamDebugTrailerKeys") {
            return settings.titlePageSections.trailerKeys(
                keys.split(separator: ",").compactMap { AppleTrailerPreviewPolicy.validYouTubeKey(String($0)) })
        }
        #endif
        let keys = pageMetadata.details?.trailerYouTubeKeys ?? []
        var seen = Set<String>()
        return settings.titlePageSections.trailerKeys(keys.filter { seen.insert($0).inserted })
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
        !reduceMotion && heroTrailer.hasStarted && trailerEmbedURL != nil
            && AppleHeroTrailerGate.allowsVideo(lowPower: lowPowerMode, systemVideoAutoplay: systemAllowsTrailerVideo,
                                                pressed: heroTrailer.wasPressed)
            && AppleTrailerArtFirstPolicy.mayRequestTrailer(art: heroStill.art, pressed: true)
            && !playbackCoordinator.phase.isBusy && playbackUI.presentation == nil
    }

    /// Never on the Apple TV, which plays no trailer — so its title page
    /// never probes or resolves one either. The Mac's plays by itself as its
    /// Discover hero does (N69, owner 2026-09-25).
    private var systemAllowsTrailerVideo: Bool {
        #if os(iOS) || os(visionOS)
        UIAccessibility.isVideoAutoplayEnabled
        #else
        true
        #endif
    }

    private var allowsTrailerAutoplay: Bool {
        guard !lowPowerMode, systemAllowsTrailerVideo else { return false }
        #if os(visionOS)
        return AppleTrailerPreviewPolicy.titlePageAutoplays(on: .vision, setting: settings.autoPlayTrailer, reduceMotion: reduceMotion)
        #elseif os(iOS)
        return AppleTrailerPreviewPolicy.titlePageAutoplays(
            on: .phoneOrPad, setting: settings.autoPlayTrailer, reduceMotion: reduceMotion,
            systemVideoAutoplayEnabled: systemVideoAutoplayEnabled
        )
        #elseif os(macOS)
        return usesMacTitlePage
            && AppleTrailerPreviewPolicy.titlePageAutoplays(on: .mac, setting: settings.autoPlayTrailer, reduceMotion: reduceMotion)
        #else
        return AppleTrailerPreviewPolicy.titlePageAutoplays(on: .tv, setting: settings.autoPlayTrailer, reduceMotion: reduceMotion)
        #endif
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
        if shouldPlay { heroTrailer.wasPressed = true }
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
        AppleTrailerSoundMemory.remember(soundOn: !next.isMuted)
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
        #if os(iOS)
        if usesPhoneTitleChrome, frame != .zero {
            detailHeroIsOffscreen = frame.maxY <= AppleDesignTokens.minimumActionSize
        }
        #endif
        #if os(iOS) || os(visionOS) || os(macOS)
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
        return true
        #elseif os(macOS)
        // No audio session to set up; the Mac title page's hero plays it.
        usesMacTitlePage
        #else
        false
        #endif
    }

    private func handleTrailerState(_ state: String, muted: Bool, errorCode: Int?) {
        appleTrace("title trailer \(state): \(item.name) key=\(trailerKey ?? "none") error=\(errorCode.map(String.init) ?? "none") active=\(heroTrailer.isActive)")
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
        appleTrace("title trailer unavailable: \(item.name) key=\(trailerKey ?? "none") reason=\(reason)")
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

    private var selectedEpisodeSelection: AppleMediaEpisodeSelection? {
        guard let selectedEpisodeID = episodeList.selectedEpisodeID,
              let episode = episodeList.episodes.first(where: { $0.id == selectedEpisodeID }) else { return nil }
        return AppleMediaEpisodeSelection(
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
        if discOffersMenu { return "Play Disc" }
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
            title: playbackCoordinator.phase.isBusy || playWaitsForPreparation
                ? (playbackCoordinator.phase.isBusy ? "Preparing" : "Loading")
                : regularPlayTitle,
            glyph: (playbackCoordinator.phase.isBusy || playWaitsForPreparation) && !playbackUI.startup.isLoading
                ? (isDiscTitle ? .disc : .progress) : .systemImage("play.fill"),
            kind: .play,
            width: actionButtonWidth
        ) {
            if isDiscTitle { startDisc(discPlayStart) } else { playbackUI.request = UUID() }
        }
        .disabled(!canStartPlayback)
        .accessibilityLabel(
            playbackCoordinator.phase.isBusy || playWaitsForPreparation
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
        if expandsPhoneLayout { return .infinity }
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
        #if os(iOS) || os(visionOS)
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
            if discOffersMenu, watchOnAction == nil {
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
            if serverTrailer != nil {
                detailIconAction("Trailer", systemImage: Self.serverTrailerSymbol) { showsServerTrailer = true }
                    .accessibilityLabel("Play Trailer")
                    .accessibilityIdentifier("detail.serverTrailer")
            }
            detailIconAction("My List", systemImage: AppleSemanticAction.myList(saved: titleActions.isFavorite).symbol, action: toggleFavorite)
                .accessibilityLabel(AppleSemanticAction.myList(saved: titleActions.isFavorite).label)
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

    /// How far this page's own download has got, once its size is known.
    private var downloadFraction: Double? {
        switch downloadCoordinator.state {
        case .downloading(_, _, let received, let expected), .resuming(_, _, let received, let expected),
             .paused(_, _, let received, let expected):
            AppleEpisodeDownloadIndicator.fraction(received, expected)
        default: nil
        }
    }

    private var downloadGlyph: AppleDetailActionButtonGlyph {
        switch downloadCoordinator.state {
        case .resolving: .progress
        case .downloading, .resuming:
            .systemImage(AppleSemanticAction.download(.active).symbol)
        case .paused:
            .systemImage(AppleSemanticAction.download(.paused).symbol)
        case .completed:
            .systemImage(AppleSemanticAction.download(.completed).symbol)
        case .failed, .cancelled:
            .systemImage(AppleSemanticAction.download(.retry).symbol)
        case .idle:
            .systemImage(AppleSemanticAction.download(.idle).symbol)
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
                .accessibilityIdentifier("detail.season")
        }
    }

    /// A series' episodes, unless the lookup found none: then the section is
    /// left out rather than saying so.
    private var showsEpisodeSection: Bool {
        item.type == "series" && episodeListPresentation != .unavailable
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
    private func episodeDownloadTitle(_ episode: AppleMediaEpisode) -> String {
        AppleMediaEpisodeSelection(seriesMediaID: pageMetadata.resolvedMediaID ?? item.mediaID, episode: episode)?.displayTitle
            ?? episode.displayTitle
    }

    private func episodeDownloadIndicator(for episode: AppleMediaEpisode) -> AppleEpisodeDownloadIndicator {
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
            Image(systemName: AppleSemanticAction.download(.idle).symbol)
        case .otherInProgress:
            Image(systemName: AppleSemanticAction.download(.active).symbol)
        case .downloaded:
            Image(systemName: AppleSemanticAction.download(.completed).symbol)
        case .preparing:
            ProgressView().controlSize(.small)
        case .downloading(let fraction), .paused(let fraction):
            ZStack {
                AppleDownloadRing(fraction: fraction)
                if case .paused = indicator {
                    Image(systemName: "play.fill").font(.system(size: 8, weight: .bold))
                } else if fraction != nil {
                    RoundedRectangle(cornerRadius: 1.5).frame(width: 7, height: 7)
                }
            }
            .frame(width: 24, height: 24)
        }
    }

    private func episodeRow(_ episode: AppleMediaEpisode, isWatched: Bool) -> some View {
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
    private func episodeDownloadButton(_ episode: AppleMediaEpisode) -> some View {
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
                #if !os(iOS) && !os(visionOS)
                .padding(.leading, detailHorizontalInset)
                #endif
            }
            #if os(iOS) || os(visionOS)
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
                    settings: settings,
                    openSettings: openSettings,
                    mediaServerLibrary: mediaServerLibrary,
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
            candidates: candidates.map { AppleSimilarTitleProfile(item: $0, sourceID: source.id.uuidString) },
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

    private func episodeNumber(_ episode: AppleMediaEpisode) -> String {
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
            isPreparing: playWaitsForPreparation || playbackCoordinator.phase.isBusy,
            hasSelectedEpisode: episodeList.selectedEpisodeID != nil,
            picksEpisodeAtStart: isMediaServerTitle
        )
    }

    private var isMediaServerTitle: Bool { serverReference != nil }

    private var playWaitsForPreparation: Bool {
        AppleTitlePagePolicy.playWaitsForPreparation(isPreparing: pageMetadata.isPreparing,
                                                     isMediaServerTitle: isMediaServerTitle)
    }

    /// The episode Play starts: the opening episode, else the next unwatched
    /// one in the up-next episode's season, else in the first season.
    private func startEpisodeID(in episodes: [AppleMediaEpisode]) -> String? {
        let season = upNextEpisode(in: episodes)?.season ?? AppleMediaEpisodePolicy.initialSeason(in: episodes)
        return serverDestination.startEpisodeID(in: episodes,
            fallbackID: nextUnwatchedEpisodeID(in: season, from: episodes)
                ?? ApplePlayGatingPolicy.defaultEpisodeID(episodes: episodes))
    }

    private func advanceCompletedServerEpisode() {
        guard isMediaServerTitle,
              serverDestination.playbackCompleted(selectedEpisodeID: episodeList.selectedEpisodeID,
                  watchedEpisodeIDs: watchedEpisodeIDs) else { return }
        episodeList.selectInitialServerEpisode(startEpisodeID(in: episodeList.episodes))
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

    /// A film's files save under their own playback ids, so those count too.
    private var progressCandidates: [String] {
        let keys = AppleTitleProgressIdentity.candidates(
            item: item, sourceID: source.id, resolvedMediaID: pageMetadata.resolvedMediaID)
        guard item.type != "series" else { return keys }
        return keys + localFiles.map { library.playbackID($0) }.filter { !keys.contains($0) }
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

    private var offlineRecordID: String {
        if let reference = AppleMediaServerItemReference.parse(item.mediaID) {
            return AppleMediaServerItemReference(sourceID: reference.sourceID,
                itemID: serverDestination.offlineItemID(selectedEpisodeID: episodeList.selectedEpisodeID,
                    referenceID: reference.itemID)).mediaID
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
        return AppleTitlePagePolicy.offersDownload(item: item, hasCompletedDownload: downloadCoordinator.state.isCompleted)
    }

    private var canStartDownload: Bool {
        showsDownloadAction
            && !pageMetadata.isPreparing
            && !downloadCoordinator.state.ownsDownload
            && !downloadCoordinator.state.isCompleted
            && (item.type != "series" || episodeList.selectedEpisodeID != nil)
    }

    private var seasonNumbers: [Int] {
        AppleMediaEpisodePolicy.seasons(in: episodeList.episodes)
    }

    private var visibleEpisodes: [AppleMediaEpisode] {
        AppleLocalLibraryStore.visibleEpisodes(in: episodeList.selectedSeason, from: episodeList.episodes)
    }

    private func episodeMetadata(_ episode: AppleMediaEpisode) -> String {
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
        AppleSemanticAction.rating(value, selected: selected).symbol
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
            guard let selection = AppleMediaEpisodeSelection(
                seriesMediaID: pageMetadata.resolvedMediaID ?? item.mediaID,
                episode: episode
            ) else { return nil }
            return (episode.id, "\(recordID):\(selection.mediaID)")
        }
        let downloaded = await downloadCoordinator.downloadedMediaIDs(among: Set(resolvedIDs.map(\.1)))
        guard !Task.isCancelled else { return }
        offlineState.downloadedEpisodeIDs = Set(resolvedIDs.filter { downloaded.contains($0.1) }.map(\.0))
    }

    private func configuredSources(_ presentation: AppleMediaPlayerPresentation, selectedID: URL? = nil) -> AppleMediaPlayerPresentation {
        var result = presentation
        result.handOff(to: playbackUI.startup)
        result.sourceID = presentation.request.hints.libraryFileURL ?? selectedID ?? presentation.request.url
        // Every path that opens the player from this page comes through here,
        // so wiring the next episode once covers all of them.
        result.nextEpisode = nextLocalPartContext(selectedID: result.sourceID) ?? nextEpisodeContext()
        result.coordinator.trackCarryOver = playbackUI.trackCarryOver
        playbackUI.trackCarryOver = nil
        // Every stream failed before anything played: close the player, then
        // start again on the OpenStream engine when the Native player failed,
        // or say why here (`ApplePlaybackEngineFallback`).
        let fellBack = presentation.engineOverride != nil
        let fromBeginning = playbackUI.pressFromBeginning
        result.onUnplayable = { unplayable in
            if presentation.request.sourceKind == .mediaServer, let version = presentation.request.hints.versionID {
                presentation.coordinator.stop()
                playbackUI.presentation = nil
                // The player already tried the other sources it was handed.
                serverFailedVersions.formUnion(presentation.fallbackCandidates
                    .filter { unplayable.triedSourceURLs.contains($0.url) }.compactMap(\.hints.versionID))
                // The retry itself checks for a real TranscodingUrl and moves to
                // the next version when the server offers no conversion.
                let nextStep = ApplePlaybackFallbackPolicy.next(triedConversion: serverConversionAttempted,
                    nextVersionAvailable: titleMediaVersions.contains { $0.id != version && !serverFailedVersions.contains($0.id) })
                if nextStep == .conversion {
                    selectedServerVersion = version
                    serverConversionAttempted = true
                    serverRetrying = true
                    playbackUI.request = UUID()
                    return
                }
                serverFailedVersions.insert(version)
                if nextStep == .nextVersion, retryNextServerVersion(after: version) { return }
            }
            let engineStep = ApplePlaybackEngineFallback.afterEveryStreamFailed(unplayable.failure,
                engine: unplayable.engine, alreadyFellBack: fellBack)
            // The engine fallback runs first (design §4.2 rule 7): the same
            // version again on the OpenStream engine, then the next version.
            if let version = presentation.request.hints.versionID,
               presentation.request.hints.libraryFileURL != nil {
                presentation.coordinator.stop()
                if engineStep == .openStream {
                    // The same version again, past the prompt it already answered.
                    confirmedVersionID = version
                } else if let next = titleMediaVersions.first(where: { $0.id != version && !serverFailedVersions.contains($0.id) }),
                          let reference = next.parts.first?.reference,
                          let file = localFiles.first(where: { $0.id == reference }) {
                    serverFailedVersions.insert(version)
                    playbackUI.presentation = nil
                    playbackUI.selectedLocalFile = file
                    automaticLocalVersionFallback = true
                    serverRetrying = true
                    playbackUI.request = UUID()
                    return
                }
            }
            playbackUI.presentation = nil
            switch engineStep {
            case .openStream:
                appleTrace("native fallback → openStream after \(unplayable.triedSourceURLs.count) failures")
                playbackUI.engineOverride = .openStream
                playbackUI.startsFromBeginning = fromBeginning
                playbackCoordinator.beginResolving()
                playbackUI.request = UUID()
            case .alert(let message):
                playbackUI.unavailableMessage = message
                playbackUI.startup.cancel()
            case nil:
                playbackCoordinator.reset()
                playbackUI.startup.cancel()
            }
        }
        if presentation.request.hints.versionID != nil {
            result.sourceOptionsLoader = nil
            return result
        }
        let files = localFiles
        let library = library
        let settings = settings
        let store = localSourceStore ?? AppleSourceStore()
        result.sourceOptionsLoader = {
            files.map { file in
                ApplePlaybackSourceOption(id: file.url) {
                    try await library.presentation(for: file, sourceStore: store, settings: settings)
                }
            }
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
    private func nextLocalPartContext(selectedID: URL?) -> AppleNextEpisodeContext? {
        guard let selectedID,
              let group = ((localGroup.map { [$0] } ?? []) + library.matchingGroups(item)).first(where: {
                  $0.items.contains { $0.url == selectedID }
              }), let current = group.items.first(where: { $0.url == selectedID }),
              let next = group.nextPart(after: current) else { return nil }
        return AppleNextEpisodeContext(title: next.name, isPartBoundary: true) { carryOver in
            Task { @MainActor in
                guard self.playbackUI.presentation?.sourceID == selectedID else { return }
                let ending = self.playbackUI.presentation?.id
                let engineOverride = self.playbackUI.presentation?.engineOverride
                do {
                    let presentation = try await self.library.presentation(for: next,
                        sourceStore: self.localSourceStore ?? AppleSourceStore(), settings: self.settings, continuingPart: true, engineOverride: engineOverride)
                    guard !Task.isCancelled, self.playbackUI.presentation?.id == ending else { return }
                    self.playbackUI.trackCarryOver = carryOver.isEmpty ? nil : carryOver
                    self.playbackCoordinator = presentation.coordinator
                    self.playbackUI.presentation = self.configuredSources(presentation, selectedID: next.url)
                } catch is CancellationError {
                    return
                } catch {
                    guard self.playbackUI.presentation?.id == ending else { return }
                    self.playbackUI.presentation = nil
                    self.playbackCoordinator.fail(error)
                }
            }
        }
    }

    private func nextEpisodeContext() -> AppleNextEpisodeContext? {
        guard let selectedEpisodeID = episodeList.selectedEpisodeID,
              let current = episodeList.episodes.first(where: { $0.id == selectedEpisodeID }) else { return nil }
        let currentFiles = library.localFiles(for: item, group: localGroup, episode: current)
        let remaining = episodeList.episodes.filter { candidate in
            candidate.id == current.id || !currentFiles.contains { AppleLocalLibraryStore.matchesEpisode($0, episode: candidate) }
        }
        guard let next = AppleMediaEpisodePolicy.following(current, in: remaining) else { return nil }
        return AppleNextEpisodeContext(title: next.displayTitle) { carryOver in
            Task { @MainActor in
                // One handover per episode, however many times it is asked for.
                guard self.episodeList.selectedEpisodeID != next.id else { return }
                appleTrace("next episode → \(next.displayTitle)")
                let ending = self.playbackUI.presentation?.id
                self.playbackUI.trackCarryOver = carryOver.isEmpty ? nil : carryOver
                self.episodeList.selectedEpisodeID = next.id
                // The ending player keeps its own coordinator; the page
                // resolves on a fresh one so a failure lands here, not on it.
                self.playbackCoordinator = ApplePlaybackCoordinator.forBrowsing()
                self.playbackUI.request = UUID()
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

    private func retryNextServerVersion(after version: String) -> Bool {
        serverFailedVersions.insert(version)
        guard titleMediaVersions.contains(where: { !serverFailedVersions.contains($0.id) }) else { return false }
        selectedServerVersion = nil
        serverConversionAttempted = false
        serverRetrying = true
        playbackUI.request = UUID()
        return true
    }

    private func resolvePlaybackPress() async {
        guard let request = playbackUI.startup.resolutionID,
              playbackUI.ledger.consume(request) else { return }
        if playbackUI.request != request {
            playbackUI.presentation?.coordinator.stop()
            playbackUI.presentation = nil
            playbackUI.request = request
        }
        pauseTrailerPreview(reason: "play pressed")
        await resolvePlayback()
        if playbackUI.presentation == nil, playbackUI.request == request,
           playbackUI.startup.phase != .timedOut, !Task.isCancelled { playbackUI.startup.cancel() }
    }

    private func resolvePlayback() async {
        #if DEBUG
        if AppleNetworkStub.isActive, UserDefaults.standard.bool(forKey: "OpenStreamDebugPlaybackUnavailable") {
            playbackUI.unavailableMessage = "Playback is unavailable."
            return
        }
        #endif
        let resolvingRequest = playbackUI.request
        if !serverRetrying {
            serverFailedVersions = []
            serverConversionAttempted = false
        }
        serverRetrying = false
        let retryStartedAt = playbackUI.retryStartedAt
        playbackUI.retryStartedAt = nil
        let engineOverride = playbackUI.engineOverride
        playbackUI.engineOverride = nil
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
                let presentation = AppleMediaPlayerPresentation(request: request, settings: settings, engineOverride: engineOverride)
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
                let presentation = AppleMediaPlayerPresentation(request: request, settings: settings,
                    engineOverride: engineOverride)
                if let reference = AppleMediaServerItemReference.parse(offline.mediaID) {
                    serverDestination.playbackStarted(episodeID: reference.itemID,
                        wasWatched: playbackStore.isWatched(mediaID: reference.itemID))
                }
                playbackCoordinator = presentation.coordinator
                playbackUI.presentation = configuredSources(presentation, selectedID: offline.localURL)
                return
            }
            if let msLibrary = mediaServerLibrary, let msRef = playbackServerReference,
               await downloadCoordinator.record(for: offlineRecordID) == nil {
                let msDetail = try await msLibrary.detail(for: msRef)

                let episodeToPlay: AppleMediaServerItem
                if item.type == "series" || msDetail.item.type == .series || msDetail.item.type == .episode {
                    guard let found = AppleTitlePagePolicy.serverEpisodeToPlay(
                        selectedID: episodeList.selectedEpisodeID,
                        startID: startEpisodeID(in: msLibrary.episodes(from: msDetail)),
                        referenceID: msRef.itemID, referenceIsEpisode: msDetail.item.type == .episode,
                        episodesBySeason: msDetail.episodesBySeason)
                        ?? AppleTitlePagePolicy.standaloneServerEpisode(in: msDetail) else {
                        throw AppleMediaServerError.unsupported
                    }
                    episodeToPlay = found
                } else {
                    episodeToPlay = msDetail.item
                }

                let confirmed = confirmedVersionID
                confirmedVersionID = nil
                var candidates = try await msLibrary.playbackCandidates(for: episodeToPlay, in: msDetail, resume: !fromBeginning,
                    versionID: selectedServerVersion, afterFailure: serverConversionAttempted,
                    failedVersions: serverFailedVersions, confirmedVersionID: confirmed)
                guard !Task.isCancelled, playbackUI.request == resolvingRequest else { return }
                if item.type == "series" {
                    for index in candidates.indices {
                        candidates[index].hints.progressParentID = progressRecordID
                        candidates[index].hints.progressPartID = episodeToPlay.id
                    }
                }
                let req = candidates[0]
                selectedServerVersion = nil
                let presentation = AppleMediaPlayerPresentation(request: req, fallbackCandidates: Array(candidates.dropFirst()),
                    settings: settings, engineOverride: engineOverride)
                if episodeToPlay.type == .episode {
                    serverDestination.playbackStarted(episodeID: episodeToPlay.id,
                        wasWatched: playbackStore.isWatched(mediaID: episodeToPlay.id))
                }
                msLibrary.attach(to: presentation.coordinator)
                playbackCoordinator = presentation.coordinator
                playbackUI.presentation = configuredSources(presentation, selectedID: req.url)
                return
            }

            let automaticFallback = automaticLocalVersionFallback
            automaticLocalVersionFallback = false
            let explicitlySelected = playbackUI.selectedLocalFile != nil && !automaticFallback
            let confirmed = confirmedVersionID
            confirmedVersionID = nil
            let untried = localFiles.filter { !ApplePlaybackFailureHistory.shared.contains($0.url) }
            // Play again after every copy failed tries them again, so the
            // viewer sees why they fail rather than "No video files were found".
            let files = playbackUI.selectedLocalFile.map { selected in
                [selected] + untried.filter { $0.id != selected.id }
            } ?? (untried.isEmpty ? localFiles : untried)
            playbackUI.selectedLocalFile = nil
            var lastFileError: (any Error)?
            for (fileIndex, file) in files.enumerated() {
                var attempted = file
                do {
                    let presentation = try await library.presentation(attempting: &attempted,
                        sourceStore: localSourceStore ?? AppleSourceStore(), settings: settings,
                        fromBeginning: fromBeginning, disc: discChoice,
                        explicitVersion: explicitlySelected && fileIndex == 0, confirmedVersionID: fileIndex == 0 ? confirmed : nil,
                        automaticFallback: automaticFallback || fileIndex > 0, engineOverride: engineOverride)
                    guard !Task.isCancelled, playbackUI.request == resolvingRequest else { return }
                    playbackCoordinator = presentation.coordinator
                    playbackUI.presentation = configuredSources(presentation, selectedID: file.url)
                    return
                } catch let confirmation as AppleVersionResumeConfirmation {
                    guard !Task.isCancelled, playbackUI.request == resolvingRequest else { return }
                    versionResume = confirmation
                    confirmsVersionResume = true
                    playbackCoordinator.reset()
                    return
                } catch is CancellationError { throw CancellationError() }
                catch {
                    ApplePlaybackFailureHistory.shared.record(attempted.url)
                    lastFileError = error
                }
            }
            if let offlineRecord = await downloadCoordinator.record(for: offlineRecordID),
               !ApplePlaybackFailureHistory.shared.contains(offlineRecord.localURL) {
                do {
                    playbackCoordinator.update(.loading)
                    let inspection = try await AppleAssetInspector.inspect(url: offlineRecord.localURL)
                    playbackCoordinator.update(.loading)
                    let prepared = try await playbackPreparer.prepare(
                        sourceURL: offlineRecord.localURL,
                        decision: ApplePlaybackPreparer.decision(for: inspection),
                        inspectedAsset: inspection
                    )
                    let presentation = AppleMediaPlayerPresentation(
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
                            hints: .init(titleMediaID: selectedPlaybackMediaID, titleMediaType: item.type)
                        ),
                        settings: settings,
                        engineOverride: engineOverride
                    )
                    playbackCoordinator = presentation.coordinator
                    playbackUI.presentation = configuredSources(presentation, selectedID: offlineRecord.localURL)
                    return
                } catch is CancellationError { throw CancellationError() }
                catch { ApplePlaybackFailureHistory.shared.record(offlineRecord.localURL) }
            }

            throw lastFileError ?? AppleLibrarySourceError.noMedia
        } catch let confirmation as AppleVersionResumeConfirmation {
            guard !Task.isCancelled, playbackUI.request == resolvingRequest else { return }
            versionResume = confirmation
            confirmsVersionResume = true
            playbackCoordinator.reset()
        } catch is CancellationError {
            if playbackUI.request == resolvingRequest { playbackCoordinator.reset() }
        } catch {
            guard !Task.isCancelled, playbackUI.request == resolvingRequest else { return }
            if serverConversionAttempted, let version = selectedServerVersion,
               retryNextServerVersion(after: version) { return }
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

    private func startDownload(episode: AppleMediaEpisode? = nil) {
        guard !seasonDownloads.isRunning else { return }
        let selection = episode.flatMap { AppleMediaEpisodeSelection(seriesMediaID: pageMetadata.resolvedMediaID ?? item.mediaID, episode: $0) }
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
                guard let reference = AppleMediaServerItemReference.parse(item.mediaID), let mediaServerLibrary else { return [] }
                let target = AppleMediaServerItemReference(sourceID: reference.sourceID, itemID: episode?.id ?? episodeList.selectedEpisodeID ?? reference.itemID)
                return [try await mediaServerLibrary.downloadPlan(reference: target)]
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
        guard let reference = AppleMediaServerItemReference.parse(item.mediaID), let mediaServerLibrary else { return }
        startServerSeasonDownload(reference: reference, library: mediaServerLibrary)
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

    private func enrichLocalEpisodes() async {
        guard let localGroup, item.type == "series", let season = episodeList.selectedSeason,
              let configuration = metadataConfiguration else { return }
        let generation = preparationGeneration
        let mediaID = pageMetadata.resolvedMediaID ?? item.mediaID
        guard let episodes = try? await AppleTMDBClient().seasonEpisodes(mediaID: mediaID, season: season,
            configuration: configuration), !Task.isCancelled, preparationGeneration == generation,
              episodeList.selectedSeason == season else { return }
        episodeList.applyProviderEpisodes(episodes, season: season, group: localGroup, mediaID: mediaID)
    }

    private func applyEpisodes(_ fetched: [AppleMediaEpisode]) {
        let mediaID = pageMetadata.resolvedMediaID ?? item.mediaID
        episodeList.applyEpisodes(fetched, localGroup: localGroup, mediaID: mediaID)
        offlineState.downloadedEpisodeIDs = []
        episodeList.selectedSeason = savedEpisode(in: episodeList.episodes)?.season
            ?? library.resumeEpisode(for: item, group: localGroup, episodes: episodeList.episodes)?.season
            ?? upNextEpisode(in: episodeList.episodes)?.season
            ?? AppleMediaEpisodePolicy.initialSeason(in: episodeList.episodes)
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
            await playbackStore.recordEpisodes(episodeList.episodes, mediaID: progressRecordID)
            guard !Task.isCancelled, preparationGeneration == generation else { return }
            episodeList.selectedSeason = savedEpisode(in: episodeList.episodes)?.season
                ?? upNextEpisode(in: episodeList.episodes)?.season
                ?? AppleMediaEpisodePolicy.initialSeason(in: episodeList.episodes)
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
        pageMetadata.detailsAnswered = true
        fillTimeline.mark(.usableMetadata, detail: "provider")
        fillTimeline.mark(.metadata, detail: pageMetadata.details?.overview?.isEmpty == false ? "overview" : "no-overview")
        markOverviewIfVisible(source: "enriched")
    }

    private func markOverviewIfVisible(source: String) {
        guard AppleMetadataPresentationPolicy.synopsis(
            catalog: item.summary,
            enriched: pageMetadata.details?.overview
        ) != nil else { return }
        fillTimeline.mark(.usableMetadata, detail: source)
        fillTimeline.mark(.overview, detail: source)
    }

    /// Resolve the item to its IMDB id, then (for series) load episodeList.episodes keyed
    /// by that id so both metadata and streams resolve against one canonical
    /// identifier.
    private func prepare() async {
        let generation = UUID()
        preparationGeneration = generation
        pageMetadata.details = nil
        pageMetadata.detailsAnswered = false
        pageMetadata.detailsSettled = false
        pageMetadata.fallbackArtwork = nil
        episodeList.reset()
        pageMetadata.resolvedMediaID = nil
        pageMetadata.watchProviders = []
        pageMetadata.streamingIDs = nil

        if let reference = AppleXtreamReference.parse(item.mediaID) {
            await prepareXtream(reference, generation: generation)
            return
        }

        if let msLibrary = mediaServerLibrary, let msRef = AppleMediaServerItemReference.parse(navigationItem.mediaID) {
            if !serverDestination.isResolved {
                serverDestination.resolve(msLibrary.titlePageDestination(for: navigationItem))
            }
            pageMetadata.isPreparing = true
            do {
                let msDetail = try await msLibrary.detail(for: msRef)
                guard !Task.isCancelled, preparationGeneration == generation else { return }
                serverDestination.resolve(msLibrary.titlePageDestination(for: navigationItem))
                self.pageMetadata.details = msLibrary.metadata(from: msDetail)
                self.pageMetadata.resolvedMediaID = item.mediaID
                self.episodeList.episodes = msLibrary.episodes(from: msDetail)
                self.episodeList.selectInitialServerEpisode(startEpisodeID(in: self.episodeList.episodes))
                await playbackStore.recordEpisodes(episodeList.episodes, mediaID: progressRecordID)
                guard !Task.isCancelled, preparationGeneration == generation else { return }
                markMetadataArrived()
                fillTimeline.mark(.episodes, detail: "\(self.episodeList.episodes.count)")
                self.offlineState.serverDownloadsAllowed = (try? await msLibrary.downloadsAllowed(in: msDetail)) == true
                guard !Task.isCancelled, preparationGeneration == generation else { return }
                self.offlineState.downloadedEpisodeIDs = []
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
        // The item's own canonical `tt…` id, else its catalog id, is the id
        // every lookup uses, so Play is usable before anything is awaited. A
        // series takes its episodes from the local files; the enriched
        // details are drawn the moment they arrive.
        let mediaID = ApplePlayGatingPolicy.canonicalMediaID(item.mediaID) ?? item.mediaID
        pageMetadata.resolvedMediaID = mediaID
        pageMetadata.isPreparing = false
        rating = ratingStore.rating(for: item.mediaID)
        if isSeries { applyEpisodes([]) }

        let publishDetails: @MainActor @Sendable (AppleTMDBDetails) -> Void = { details in
            guard !Task.isCancelled, preparationGeneration == generation else { return }
            pageMetadata.details = details
            pageMetadata.detailsAnswered = true
            markMetadataArrived()
        }
        #if DEBUG
        // `-OpenStreamDebugDetailsDelay <s>`: the enriched details (and
        // their trailers) land that late, as on a slow phone network.
        let delay = UserDefaults.standard.double(forKey: "OpenStreamDebugDetailsDelay")
        if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
        #endif
        let details = try? await metadataResolver.resolve(
            sources: playbackSources,
            preferredSourceID: source.id,
            type: item.type,
            mediaID: mediaID,
            configuration: metadataConfiguration,
            fallbackName: item.name,
            onUpdate: { details in await publishDetails(details) }
        )
        guard !Task.isCancelled, preparationGeneration == generation else { return }
        pageMetadata.detailsAnswered = true
        pageMetadata.detailsSettled = true
        pageMetadata.details = details
        if details != nil { markMetadataArrived() }
    }

    /// Where else this title can be watched, filtered to the services the
    /// viewer subscribes to.
    ///
    /// The whole call is skipped when they have not opted in — no request goes
    /// out at all, rather than one being made and the answer thrown away.
    private func loadWatchProviders() async {
        guard !Task.isCancelled else { return }
        let generation = preparationGeneration
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
        guard !Task.isCancelled, preparationGeneration == generation else { return }
        let visible = AppleWatchProviderPolicy.visible(all, enabledProviderIDs: enabled)
        appleTrace("watch providers: \(visible.count) for \(item.name) (enabled \(enabled.count), \(all.count) in \(region))")
        pageMetadata.watchProviders = visible
        // Only when Watch on takes Play's place does the IMDb id go to
        // Wikidata — and nothing else does.
        guard watchOnAction != nil, AppleWikidataStreamingQuery.isIMDbID(imdbID) else { return }
        let ids = await AppleWikidataStreamingIDClient.shared.ids(for: imdbID)
        guard !Task.isCancelled, preparationGeneration == generation else { return }
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
    private func savedEpisode(in loaded: [AppleMediaEpisode]) -> AppleMediaEpisode? {
        AppleMediaEpisodePolicy.savedEpisode(progress: playbackStore.progress(for: progressRecordID), in: loaded)
    }

    private func nextUnwatchedEpisodeID(
        in season: Int?,
        from loadedEpisodes: [AppleMediaEpisode]
    ) -> String? {
        if let saved = savedEpisode(in: loadedEpisodes.filter { $0.season == season }) { return saved.id }
        if let resumed = library.resumeEpisode(for: item, group: localGroup,
            episodes: loadedEpisodes.filter { $0.season == season }) { return resumed.id }
        let completed = AppleLocalLibraryStore.completedEpisodeIDs(loadedEpisodes, group: localGroup,
            mediaID: pageMetadata.resolvedMediaID ?? item.mediaID, store: playbackStore)
        return AppleMediaEpisodePolicy.defaultEpisode(in: season, from: loadedEpisodes,
            completedIDs: completed)?.id
            ?? AppleLocalLibraryStore.nextFilenameEpisode(in: loadedEpisodes, completedIDs: completed)?.id
    }

    /// The Apple TV app's Up Next across the whole show — the season the page
    /// opens on when nothing is part-watched.
    private func upNextEpisode(in loaded: [AppleMediaEpisode]) -> AppleMediaEpisode? {
        let completed = AppleLocalLibraryStore.completedEpisodeIDs(loaded, group: localGroup,
            mediaID: pageMetadata.resolvedMediaID ?? item.mediaID, store: playbackStore)
        return AppleMediaEpisodePolicy.upNext(from: loaded, completedIDs: completed)
            ?? AppleLocalLibraryStore.nextFilenameEpisode(in: loaded, completedIDs: completed)
    }

    /// Mark as Watched / Mark as Unwatched on an episode (the Apple TV app's
    /// episode menu). Marking the episode Continue Watching names as watched
    /// also takes it off Continue Watching. Play then moves to the new Up Next.
    private func setWatched(_ watched: Bool, episode: AppleMediaEpisode) {
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
    private func watchedMenuButton(_ episode: AppleMediaEpisode, isWatched: Bool) -> some View {
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
        if !titlePageIsCovered { _ = ApplePlaybackProgressFeed.shared.revision }
        return AppleLocalLibraryStore.completedEpisodeIDs(visibleEpisodes, group: localGroup,
            mediaID: pageMetadata.resolvedMediaID ?? item.mediaID, store: playbackStore)
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
    @Environment(\.appleHeroSideBleed) private var sideBleed
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
    /// Fits the 16:9 picture inside the frame, unzoomed, on black, instead of
    /// cropping it to fill (`AppleTrailerPreviewLayout.fitsHeader`).
    var fitsFrame = false

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
            container?.setPreviewVisible(false, animated: false)
            webView?.layer.removeAllAnimations()
            webView?.alpha = 1
        }

        /// `animated` crossfades back to the art (a trailer that ends or
        /// fails); `completion` runs once the art is fully up.
        func hidePreview(animated: Bool = false, completion: (() -> Void)? = nil) {
            playbackIntent = false
            revealGeneration += 1
            lastPlaying = false
            container?.setPreviewVisible(false, animated: animated, completion: completion)
            webView?.layer.removeAllAnimations()
            webView?.alpha = 1
        }

        private func reveal(muted: Bool) {
            guard playbackIntent, let webView, let container else { return }
            let generation = revealGeneration
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
                switch gate.record(window, size: container.pictureSize, at: Date()) {
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
            if state == "revealed" {
                guard playbackIntent else { return }
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
        private var artworkCover: (UIView & UIContentView)?
        private var artworkURL: URL?
        let touchShield = AppleTrailerTouchShield(type: .custom)
        let muteButton = AppleTrailerControlButton(type: .system)
        var onTap: (() -> Void)?
        var onMute: (() -> Void)?
        var onPause: (() -> Void)?
        var onReplay: (() -> Void)?
        var isLandscape = false { didSet { setNeedsLayout() } }
        var fitsFrame = false { didSet { if oldValue != fitsFrame { setNeedsLayout() } } }
        var controlTopInset: CGFloat? = nil { didSet { if oldValue != controlTopInset { setNeedsLayout() } } }
        /// The art under a side safe area; the control stays beside it (`AppleHeroSideBleed`).
        var controlSideInsets = EdgeInsets() { didSet { if oldValue != controlSideInsets { setNeedsLayout() } } }
        var coverSize: CGSize? = nil { didSet { if oldValue != coverSize { setNeedsLayout() } } }
        var pictureWindow: ClosedRange<CGFloat> = 0...1 { didSet { setNeedsLayout() } }
        var hasMeasuredPicture = false
        var settlesPictureBeforeReveal = false
        /// The frame the picture is drawn in: the hero's, or the fitted letterbox.
        var pictureSize: CGSize { cover.frame.size }
        #if DEBUG && os(iOS)
        var probe: AppleHeroTrailerProbeIOS?
        #endif
        private var isPlaying = true
        private var showsReplay = false
        private var previewVisible = false
        var hasPlayedPreview = false

        init(frame: CGRect, messageHandler: WKScriptMessageHandler, artworkURL: URL?) {
            self.artworkURL = artworkURL
            if let artworkURL {
                artworkCover = UIHostingConfiguration {
                    AppleCatalogArtwork(url: artworkURL)
                }.margins(.all, 0).makeContentView()
            }
            let configuration = WKWebViewConfiguration()
            configuration.allowsInlineMediaPlayback = true
            configuration.mediaTypesRequiringUserActionForPlayback = []
            configuration.allowsPictureInPictureMediaPlayback = false
            configuration.allowsAirPlayForMediaPlayback = false
            configuration.websiteDataStore = AppleTrailerPlayerPrefetch.dataStore
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
            // The phone already supplies a decoded still; it needs no SwiftUI host.
            if let artworkCover {
                artworkCover.clipsToBounds = true
                cover.addSubview(artworkCover)
            }
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
            if fitsFrame {
                webView.transform = .identity
                webView.frame = AppleTrailerPreviewLayout.fitFrame(in: bounds.size)
                backgroundColor = .black
            } else {
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
                backgroundColor = .clear
            }
            if fitsFrame {
                cover.frame = webView.frame
            } else if let coverSize, coverSize.width > 0, coverSize.height > 0 {
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
            artworkCover?.frame = cover.bounds
            touchShield.frame = bounds
            // Placed in the part that is on screen: the hero's 16:9 view
            // overhangs its art frame, and a control at its own corner was
            // clipped off the screen.
            let rightToLeft = effectiveUserInterfaceLayoutDirection == .rightToLeft
            let visible = cover.frame.intersection(bounds).inset(by: UIEdgeInsets(
                top: 0, left: rightToLeft ? controlSideInsets.trailing : controlSideInsets.leading,
                bottom: 0, right: rightToLeft ? controlSideInsets.leading : controlSideInsets.trailing))
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
            guard let url else {
                artworkCover?.removeFromSuperview()
                artworkCover = nil
                return
            }
            let configuration = UIHostingConfiguration {
                AppleCatalogArtwork(url: url)
            }.margins(.all, 0)
            if let artworkCover {
                artworkCover.configuration = configuration
            } else {
                let view = configuration.makeContentView()
                view.clipsToBounds = true
                cover.addSubview(view)
                artworkCover = view
                setNeedsLayout()
            }
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
                urlArtworkShows: artworkCover.map { !$0.isHidden && $0.alpha > 0 } ?? false,
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

    final class PlayerHost: UIView {
        private let coordinator: Coordinator
        private var latest: AppleYouTubeAutoPreview?
        private var container: PlayerContainer?
        private var preparedContainer: PlayerContainer?
        private var creationScheduled = false
        private var pendingTurn: CFRunLoopObserver?
        private var generation = 0
        private var dismantled = false

        init(coordinator: Coordinator) {
            self.coordinator = coordinator
            super.init(frame: .zero)
            backgroundColor = .clear
            clipsToBounds = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        func update(_ preview: AppleYouTubeAutoPreview) {
            latest = preview
            guard window != nil, !dismantled else { return }
            if let container {
                preview.update(container, coordinator: coordinator)
            } else {
                scheduleCreation()
            }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil {
                cancelPlayer()
            } else if !dismantled {
                scheduleCreation()
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            container?.frame = bounds
        }

        private func scheduleCreation() {
            guard !creationScheduled, container == nil, latest != nil else { return }
            creationScheduled = true
            let scheduledGeneration = generation
            // WebKit initialization must not extend SwiftUI's layout transaction.
            nextRunLoopTurn { [weak self] in
                guard let self, self.generation == scheduledGeneration,
                      self.window != nil, !self.dismantled, let latest = self.latest else { return }
                let started = ContinuousClock.now
                let player = PlayerContainer(frame: self.bounds, messageHandler: self.coordinator, artworkURL: latest.artworkURL)
                appleTrace("trailer web initialized \(AppleLaunchMarks.milliseconds(started.duration(to: .now)))ms")
                self.preparedContainer = player
                // Attach and load after the WebKit initialization turn has returned.
                self.nextRunLoopTurn { [weak self] in
                    guard let self, self.generation == scheduledGeneration,
                          self.window != nil, !self.dismantled, let latest = self.latest,
                          let player = self.preparedContainer else { return }
                    let started = ContinuousClock.now
                    self.preparedContainer = nil
                    self.container = player
                    self.creationScheduled = false
                    player.frame = self.bounds
                    self.addSubview(player)
                    latest.configure(player, coordinator: self.coordinator)
                    appleTrace("trailer web attached \(AppleLaunchMarks.milliseconds(started.duration(to: .now)))ms")
                }
            }
        }

        private func nextRunLoopTurn(_ action: @escaping @MainActor @Sendable () -> Void) {
            let scheduledGeneration = generation
            let observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault,
                CFRunLoopActivity.afterWaiting.rawValue, false, 0) { [weak self] observer, _ in
                    CFRunLoopObserverInvalidate(observer)
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == scheduledGeneration else { return }
                        self.pendingTurn = nil
                        action()
                    }
                }
            pendingTurn = observer
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }

        func dismantle() {
            dismantled = true
            latest = nil
            cancelPlayer()
        }

        private func cancelPlayer() {
            if let pendingTurn { CFRunLoopObserverInvalidate(pendingTurn) }
            pendingTurn = nil
            generation += 1
            creationScheduled = false
            if let player = container ?? preparedContainer {
                AppleYouTubeAutoPreview.stop(player, coordinator: coordinator)
                player.removeFromSuperview()
            }
            container = nil
            preparedContainer = nil
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PlayerHost {
        let host = PlayerHost(coordinator: context.coordinator)
        host.update(self)
        return host
    }

    func updateUIView(_ view: PlayerHost, context: Context) {
        view.update(self)
    }

    private func configure(_ container: PlayerContainer, coordinator: Coordinator) {
        coordinator.onStateChange = onStateChange
        coordinator.lastMuted = isMuted
        coordinator.lastAllowsSound = allowsSound
        coordinator.lastReplayGeneration = replayGeneration
        coordinator.setPlaybackIntent(isPlaying)
        container.webView.navigationDelegate = coordinator
        container.updateArtwork(artworkURL)
        container.updateStill(artworkImage)
        appleTrace("trailer view inserted, still=\(artworkImage.map { "\($0.width)px" } ?? "none")")
        container.isLandscape = isLandscape
        container.fitsFrame = fitsFrame
        container.controlTopInset = controlTopInset
        container.controlSideInsets = sideBleed
        container.coverSize = coverSize
        container.settlesPictureBeforeReveal = settlesPictureBeforeReveal
        #if DEBUG && os(iOS)
        if settlesPictureBeforeReveal, let probe = AppleHeroTrailerProbeIOS.fromDefaults() {
            probe.container = container
            container.probe = probe
        }
        // `-OpenStreamHeroNoSettle YES`: reveal, then re-measure, for a
        // before/after run on one build.
        if UserDefaults.standard.bool(forKey: "OpenStreamHeroNoSettle") {
            container.settlesPictureBeforeReveal = false
        }
        #endif
        container.onTap = onTap
        container.onMute = onMute
        container.onReplay = onReplay
        container.onPause = { [coordinator] in coordinator.hidePreview() }
        coordinator.attach(to: container)
        container.updateControls(
            isPlaying: isPlaying,
            isMuted: isMuted,
            showsReplay: showsReplay
        )
        load(url, in: container.webView, coordinator: coordinator)
    }

    private func update(_ view: PlayerContainer, coordinator: Coordinator) {
        coordinator.onStateChange = onStateChange
        view.onTap = onTap
        view.onMute = onMute
        view.onReplay = onReplay
        view.onPause = { [coordinator] in coordinator.hidePreview() }
        view.isLandscape = isLandscape
        view.fitsFrame = fitsFrame
        view.controlTopInset = controlTopInset
        view.controlSideInsets = sideBleed
        view.coverSize = coverSize
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
        if coordinator.loadedURL != url {
            view.hasPlayedPreview = false
            view.pictureWindow = 0...1
            view.hasMeasuredPicture = false
            coordinator.prepareForPlayback()
            coordinator.setPlaybackIntent(isPlaying)
            load(url, in: view.webView, coordinator: coordinator)
        }
        if coordinator.loadedLandscape != isLandscape {
            coordinator.loadedLandscape = isLandscape
            view.webView.evaluateJavaScript("window.setTrailerLandscape(\(isLandscape ? "true" : "false"));", completionHandler: nil)
        }
        if coordinator.lastPlaying != isPlaying {
            if isPlaying { ApplePlaybackSessionPolicy.prepareTrailerAudio(pressed: allowsSound) }
            coordinator.lastPlaying = isPlaying
            if isPlaying {
                coordinator.prepareForPlayback()
            } else {
                coordinator.hidePreview()
            }
            view.webView.evaluateJavaScript(
                "window.setTrailerPlaying(\(isPlaying ? "true" : "false"));",
                completionHandler: nil
            )
        }
        if coordinator.lastReplayGeneration != replayGeneration {
            ApplePlaybackSessionPolicy.prepareTrailerAudio(pressed: allowsSound)
            coordinator.lastReplayGeneration = replayGeneration
            coordinator.prepareForPlayback()
            view.webView.evaluateJavaScript("window.restartTrailer();", completionHandler: nil)
        }
        guard coordinator.lastMuted != isMuted || coordinator.lastAllowsSound != allowsSound else { return }
        coordinator.lastMuted = isMuted
        coordinator.lastAllowsSound = allowsSound
        // One call, carrying both flags: `allowsSound` and `isMuted` can
        // change together (a press unmutes and unlocks sound in the same
        // beat), and two separate bridge calls would race on which one the
        // page saw first.
        view.webView.evaluateJavaScript(
            AppleTrailerSoundBridge.allowsSoundJavascriptCommand(allowsSound: allowsSound, isMuted: isMuted),
            completionHandler: nil
        )
    }

    static func dismantleUIView(_ view: PlayerHost, coordinator: Coordinator) {
        view.dismantle()
    }

    private static func stop(_ view: PlayerContainer, coordinator: Coordinator) {
        coordinator.hidePreview()
        view.webView.evaluateJavaScript("window.setTrailerPlaying(false);", completionHandler: nil)
        view.webView.stopLoading()
        view.webView.loadHTMLString("", baseURL: AppleTrailerPreviewPolicy.embedOrigin)
        coordinator.loadedURL = nil
        coordinator.loadedLandscape = nil
        coordinator.onStateChange = nil
        view.webView.configuration.userContentController.removeScriptMessageHandler(forName: "trailerState")
        view.webView.navigationDelegate = nil
    }

    private func load(_ url: URL, in view: WKWebView, coordinator: Coordinator) {
        ApplePlaybackSessionPolicy.prepareTrailerAudio(pressed: allowsSound)
        coordinator.loadedURL = url
        coordinator.loadedLandscape = isLandscape
        coordinator.lastAllowsSound = allowsSound
        let html = AppleYouTubePreviewHTML.document(
            embedURL: url,
            startsPlaying: isPlaying,
            isLandscape: isLandscape,
            startsMuted: isMuted,
            allowsSound: allowsSound,
            startupChromeCanShow: AppleTrailerRevealPolicy.startupChromeCanShow(for: UIDevice.current.userInterfaceIdiom)
        )
        appleTrace("trailer web load key=\(url.lastPathComponent) autoplay=\(isPlaying) allowsSound=\(allowsSound)")
        view.loadHTMLString(html, baseURL: AppleTrailerPreviewPolicy.embedOrigin)
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

    /// Where the trailer's one control sits in the `visible` part of its
    /// view: paused, centred; playing, in the bottom-right corner, or
    /// `topInset` below the top when the caller's copy covers the bottom.
    static func controlFrame(in visible: CGRect, paused: Bool, topInset: CGFloat?) -> CGRect {
        if paused {
            let side = pausedControlSide
            return CGRect(x: visible.midX - side / 2, y: visible.midY - side / 2, width: side, height: side)
        }
        let side = minimumControlSide
        let edgeInset = topInset == nil ? controlInset : AppleDesignTokens.phoneHeroControlInset
        return CGRect(x: visible.maxX - edgeInset - side,
                      y: topInset.map { visible.minY + $0 } ?? (visible.maxY - controlInset - side),
                      width: side, height: side)
    }

    /// Whether a title page's trailer fits its header instead of filling it:
    /// on the iPad and in landscape, where filling meant a 1.35× zoom upright
    /// and a 14 % / 9 % top and bottom crop on its side. The Apple TV app and
    /// Netflix fit or fill the header box without zooming past it (REA
    /// round 4 §2). The iPhone held upright keeps its full-bleed header.
    static func fitsHeader(isPad: Bool, isLandscape: Bool) -> Bool {
        isPad || isLandscape
    }

    /// The 16:9 player fitted inside `size` and centred: the whole picture,
    /// letterboxed or pillarboxed.
    static func fitFrame(in size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return CGRect(origin: .zero, size: size) }
        let scale = min(size.width / 16, size.height / 9)
        let width = 16 * scale, height = 9 * scale
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
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
    /// The viewer started this trailer (the still or a Trailers card): it
    /// plays under Low Power Mode and with the system's video autoplay off.
    var wasPressed = false
    /// When the page appeared: the autoplay start delay runs from here.
    var pageShownAt = Date.now
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

/// The iPhone title page's requested and displayed header art.
private struct AppleTitlePageSlotArtState {
    var itemID: String?
    var chosen: AppleTitlePageSlotArt?
    var displayed: AppleTitlePageSlotArt?
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
    /// Apple TV's "Watch on…" page of services.
    var watchOnMenu = false
    /// "Open <Service> and search for <Title>" when nothing could be opened.
    var watchOnInstructions: AppleWatchOnInstructions?
}

@MainActor
struct AppleTitlePageActionState {
    var isFavorite = false
    var rateChoicesExpanded = false
    var ratingSelectionGeneration = 0

    mutating func openedRecord(item: AppleCatalogItem, sourceID: AppleSource.ID,
                              mediaIndex: AppleMediaIndexStore) -> AppleMediaRecord {
        let record = AppleMediaIngestion.catalogRecord(instanceID: sourceID, item: item)
        isFavorite = mediaIndex.record(id: record.id)?.isFavorite ?? false
        return record
    }
}

@MainActor
struct AppleTitlePagePlaybackState {
    let startup = ApplePlaybackStartup()
    var request: UUID? {
        didSet {
            if let request, request != oldValue { startup.begin(request) }
        }
    }
    /// Which request has been resolved, and whether the opening auto-play
    /// has fired, so neither happens again when the page reappears.
    var ledger = ApplePlayRequestLedger()
    /// When Retry was pressed, so a failure that comes straight back still
    /// shows the loading state first (`ApplePlaybackFailureRecovery`).
    var retryStartedAt: ContinuousClock.Instant?
    var presentation: AppleMediaPlayerPresentation?
    var selectedLocalFile: AppleLibraryItem?
    /// The previous episode's audio and subtitle choices. Used once.
    var trackCarryOver: AppleTrackCarryOver?
    /// Every stream of the last press failed before anything played, on the
    /// OpenStream engine too; the player has closed and the page's alert
    /// says why.
    var unavailableMessage: String?
    /// The Native player's OpenStream fallback: the engine for the next press
    /// only. Used once.
    var engineOverride: ApplePlaybackEngineKind?
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

    func resetCancelledStartup(_ coordinator: ApplePlaybackCoordinator) {
        guard startup.phase == .idle, presentation == nil, coordinator.phase.isBusy else { return }
        coordinator.reset()
    }
}

private struct AppleTitlePageMetadataState {
    var details: AppleTMDBDetails?
    /// The first provider answered (a partial update counts).
    var detailsAnswered = false
    /// Every provider answered: the resolver's final value is in.
    var detailsSettled = false
    var fallbackArtwork: AppleArtworkResolver.Artwork?
    var isPreparing = true
    // The item's canonical IMDB id: the id actually used for episode and
    // stream lookups.
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

/// Local episode rows retain provider enrichment across later file-list loads.
@MainActor
struct AppleTitlePageEpisodeState {
    var episodes: [AppleMediaEpisode] = []
    private var fetchedEpisodes: [AppleMediaEpisode] = []
    private var providerEpisodes: [Int: [AppleMediaEpisode]] = [:]
    var selectedSeason: Int?
    var selectedEpisodeID: String?
    var isLoading = false
    /// Set only when the current title's episode load has finished, so a
    /// superseded load clearing `isLoadingEpisodes` cannot surface the
    /// "not available" text while the newer fetch is still in flight.
    var loadFinished = false

    mutating func selectInitialServerEpisode(_ id: String?) {
        selectedEpisodeID = episodes.first { $0.id == id }?.id
        selectedSeason = episodes.first { $0.id == selectedEpisodeID }?.season
            ?? AppleMediaEpisodePolicy.initialSeason(in: episodes)
    }

    mutating func selectEpisode(in season: Int?, defaultID: String?) {
        if let selected = episodes.first(where: { $0.id == selectedEpisodeID }), selected.season == season { return }
        selectedEpisodeID = defaultID
    }

    mutating func applyEpisodes(_ fetched: [AppleMediaEpisode], localGroup: AppleLibrarySeries?, mediaID: String) {
        fetchedEpisodes = fetched
        rebuildEpisodes(localGroup: localGroup, mediaID: mediaID)
    }

    mutating func applyProviderEpisodes(_ fetched: [AppleMediaEpisode], season: Int,
                                       group: AppleLibrarySeries, mediaID: String) {
        providerEpisodes[season] = fetched
        rebuildEpisodes(localGroup: group, mediaID: mediaID)
    }

    mutating func reset() {
        episodes = []
        fetchedEpisodes = []
        providerEpisodes = [:]
        loadFinished = false
        selectedSeason = nil
        selectedEpisodeID = nil
    }

    private mutating func rebuildEpisodes(localGroup: AppleLibrarySeries?, mediaID: String) {
        let enriched = providerEpisodes.values.flatMap { $0 }.map { provider in
            guard let fetched = fetchedEpisodes.first(where: {
                $0.season == provider.season && $0.episode == provider.episode
            }) else { return provider }
            return AppleMediaEpisode(id: provider.id, title: provider.title.isEmpty ? fetched.title : provider.title,
                season: provider.season, episode: provider.episode,
                releaseInfo: provider.releaseInfo ?? fetched.releaseInfo,
                runtimeMinutes: provider.runtimeMinutes ?? fetched.runtimeMinutes,
                overview: provider.overview ?? fetched.overview,
                thumbnailURL: provider.thumbnailURL ?? fetched.thumbnailURL)
        }
        episodes = localGroup.map { AppleLocalLibraryStore.episodes(group: $0, mediaID: mediaID,
            enriched: enriched + fetchedEpisodes) } ?? fetchedEpisodes
    }
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
    static let portraitTabletWidthThreshold = AppleLayoutClass.minimumShortSide

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
        // Plain words, never a licensed format's name or logo (licence audit 2026-10-22).
        case "DV", "DOLBY VISION": return .text("HDR")
        default: return nil
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
            guard case .text(let title) = AppleFormatBadgeKind.resolve(raw) else { return nil }
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
    /// stream format badges ("HDR", "5.1").
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
}

struct AppleMediaPlayerPresentationModifier: ViewModifier {
    @Binding var presentation: AppleMediaPlayerPresentation?
    var startup: ApplePlaybackStartup? = nil
    var resolve: (@MainActor () async -> Void)? = nil

    @State private var coverVisible = false

    func body(content: Content) -> some View {
        #if os(visionOS)
        // Inside the app's one window, like the Mac, and not a second
        // "Player" window (owner, 2026-10-07). See `AppleVisionPlayerStage`.
        content.modifier(AppleVisionPlayerStagePresenter(presentation: $presentation, startup: startup, resolve: resolve))
        #elseif os(macOS)
        // The player takes over the window it was opened from — edge to
        // edge, over the toolbar and the tab bar — rather than a sheet. The
        // sheet was a 1024 x 576 card floating over the page (owner,
        // 2026-09-24); the Apple TV app's separate player window is the other
        // thing the owner did not want. See `AppleMacPlayerStage`.
        content.modifier(AppleMacPlayerStagePresenter(presentation: $presentation, startup: startup, resolve: resolve))
        #else
        content.fullScreenCover(isPresented: $coverVisible, onDismiss: {
            presentation = nil
            startup?.cancel()
            startup?.presentationDidDismiss()
        }) {
            AppleMediaPlayerContainer(presentation: presentation, startup: startup, resolve: resolve)
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
        .onChange(of: startup?.requestID, initial: true) { _, _ in updateCoverVisibility() }
        .onChange(of: startup?.phase) { _, _ in updateCoverVisibility() }
        .onChange(of: presentation?.id, initial: true) { _, _ in updateCoverVisibility() }
        #endif
    }

    #if os(iOS) || os(tvOS)
    private func updateCoverVisibility() {
        let loading = startup ?? presentation?.startup
        let visible = loading?.needsPresentation(hasPlayer: presentation != nil) ?? (presentation != nil)
        var transaction = Transaction()
        transaction.disablesAnimations = visible && loading?.isLoading == true
        withTransaction(transaction) { coverVisible = visible }
        if visible { loading?.presentationWillAppear() }
    }
    #endif
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

    /// The phone's back button, title and status-bar handling, in either
    /// orientation: under a landscape player the page keeps the chrome it will
    /// show when the player closes. Every iPad window is large.
    var usesPhoneTitleChrome: Bool {
        #if os(iOS)
        !isLargeLayout
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
        return VStack(alignment: .leading, spacing: 0) {
            phoneHero
            phoneHeroFooter(chips: chips)
                .padding(.horizontal, Self.phoneInset)
            if showsEpisodeSection {
                phoneEpisodesSection
                    .id("vision-episodes")
                    .padding(.top, Self.phoneSectionSpacing - 8)
            }
            // Stable section heights avoid lazy placement feedback while UIKit restores the bars on Back.
            VStack(alignment: .leading, spacing: 0) {
                if !discTitles.isEmpty {
                    AppleDiscTitlesRow(titles: discTitles, horizontalInset: Self.phoneInset) { startDisc(.mainTitle, titleID: $0.id) }
                        .padding(.top, Self.phoneSectionSpacing)
                }
                if !titlePageTrailerKeys.isEmpty {
                    phoneTrailersSection
                        .padding(.top, Self.phoneSectionSpacing)
                }
                if !suggestedItems.isEmpty {
                    moreLikeThisSection(title: "More Like This")
                        .padding(.top, Self.phoneSectionSpacing - 8)
                }
                if !credits.isEmpty {
                    phoneCastSection(credits)
                        .padding(.top, Self.phoneSectionSpacing - 8)
                }
                if let summary = titlePageAboutSummary {
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
            }
        }
        .padding(.bottom, 24)
    }

    // MARK: Hero

    /// From the top edge of the screen: 70 % of it, as the Apple TV app's
    /// title page and build 15, never less than the home hero's floor.
    private var phoneHeroArtHeight: CGFloat {
        AppleTitlePageSlotArt.heroHeight(screenHeight: viewportSize.height)
    }

    /// The full-bleed header of build 15 (owner 2026-10-17, undoing 13a2677's
    /// 16:9 box): the art and trailer run up under the status bar, the copy
    /// sits over the bottom of the art in the one approved fade.
    private var phoneHero: some View {
        VStack(spacing: 12) {
            phoneTitleLockup
            phoneMetadataLine
            phoneActionRow
                .padding(.top, 4)
            matchedServerSource
        }
        // Past accessibility 2 the header ran under the back button, Play
        // was clipped and the round buttons hit the screen
        // edges (iPhone 27 v2 re-run, AX-XXXL). The episode text below the
        // hero still follows the full size.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .padding(.horizontal, Self.phoneInset)
        .padding(.bottom, AppleHomePhoneHeroLayout.titlePageCopyBottomInset)
        // Clear of the status bar and the navigation buttons at the
        // accessibility sizes; the hero grows downwards instead.
        .padding(.top, dynamicTypeSize.isAccessibilitySize ? pageGeometry.safeAreaInsets.top + 56 : 0)
        .frame(maxWidth: .infinity)
        // The copy is laid out in the flow, anchored to the bottom of the art:
        // at the accessibility sizes it grows the hero downwards rather than
        // clipping the buttons, and the fade is solid black by then.
        .frame(minHeight: phoneHeroArtHeight, alignment: .bottom)
        .background(alignment: .top) {
            phoneHeroStage
                .frame(maxWidth: .infinity)
                .frame(height: phoneHeroArtHeight)
                .clipped()
                #if os(iOS)
                .modifier(AppleHeroSideBleed(insets: AppleHeroSideColumn.insets(
                    leading: pageGeometry.safeAreaInsets.leading, trailing: pageGeometry.safeAreaInsets.trailing)))
                #endif
        }
        .background(.black)
        // Where the hero sits in the page, read without a GeometryReader
        // in the tree or a preference climbing it on every scroll frame.
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named("detail-scroll"))
        } action: { frame in
            detailHeroFrameChanged(frame)
        }
        // With the navigation bar hidden, the art runs up under the status bar.
        .padding(.top, -pageGeometry.safeAreaInsets.top)
        .accessibilityElement(children: .contain)
    }

    /// The still, the inline trailer over it once started (art until its
    /// first frames, then a crossfade), and the one approved billboard fade.
    private var phoneHeroStage: some View {
        ZStack {
            phoneSlotArtwork
                .accessibilityHidden(true)
            heroTrailerStartButton
            #if os(iOS) || os(visionOS)
            // Top-trailing, under Search: the bottom of this art is under the
            // title, the buttons and the fade, which hid a bottom control.
            trailerPreview(controlTopInset: pageGeometry.safeAreaInsets.top + 10, phoneArt: true)
            #endif
        }
        .overlay {
            AppleHomePhoneHeroFade()
                .allowsHitTesting(false)
        }
    }

    private var cachedPhoneSlotArt: (art: AppleTitlePageSlotArt, image: CGImage)? {
        AppleTitlePageSlotArt.chooseCached(
            backdrops: [pageMetadata.details?.textlessBackdropURL, pageMetadata.details?.backdropURL,
                item.backgroundURL, pageMetadata.fallbackArtwork?.backgroundURL],
            posters: [pageMetadata.details?.posterURL, item.posterURL, pageMetadata.fallbackArtwork?.posterURL],
            cachedImage: { AppleRemoteImageCache.shared.cachedPlaceholderImage(url: $0) })
    }

    /// Known art renders immediately. Keep the previous decoded picture
    /// visible until a replacement has decoded.
    private var phoneSlotArtwork: some View {
        ApplePhoneHeroArtwork(art: phoneSlotArt, cachedArt: cachedPhoneSlotArt,
            isReadyForLoadResult: slotArt.itemID == item.id, onLoad: phoneSlotArtLoaded, onFailure: phoneSlotArtFailed)
            .id(item.id)
    }

    private func phoneSlotArtLoaded(_ image: CGImage, art: AppleTitlePageSlotArt) {
        guard slotArt.itemID == item.id,
              AppleTitlePageSlotArt.acceptsLoadedArt(art, requested: phoneSlotArt, displayed: slotArt.displayed) else { return }
        if slotArt.chosen == nil { slotArt.chosen = phoneSlotArtCandidate ?? art }
        slotArt.displayed = art
        heroStill.image = image
        heroStill.art = heroStill.art.settling(with: .loaded)
        fillTimeline.recordArtworkDecoded()
    }

    /// The wordmark once it has drawn, otherwise the name in black-weight
    /// capitals; the space is held while the wordmark resolves.
    private var phoneTitleLockup: some View {
        ApplePhoneHeroTitle(name: displayTitle, presentation: titleLogoPresentation,
            logoURL: titleLogoURL) { loaded in
                guard AppleTitleLogoPolicy.keepsLoadResult(loaded, shown: titleLogoPresentation) else { return }
                titleWordmark.loadResult = loaded
                if loaded { fillTimeline.mark(.wordmark) }
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

    private var phoneMetadataLine: some View {
        AppleHomePhoneHeroMetadata(item: item, values: titlePageMetadataValues,
            contentRating: pageMetadata.details?.contentRating ?? item.contentRating)
    }

    private var selectedEpisode: AppleMediaEpisode? {
        guard let selectedEpisodeID = episodeList.selectedEpisodeID else { return nil }
        return episodeList.episodes.first { $0.id == selectedEpisodeID }
    }

    private var selectedServerTitle: AppleMediaServerTitleMatch? {
        serverTitleMatches.first { $0.id == selectedServerTitleID }
    }

    private var serverTitleQuery: AppleMediaServerTitleQuery {
        let title = pageMetadata.details.map { item.merging(details: $0) } ?? item
        return .init(item: title, resolvedMediaID: pageMetadata.resolvedMediaID)
    }

    private var playbackServerReference: AppleMediaServerItemReference? {
        serverReference ?? selectedServerTitle?.reference
    }

    private func selectServerTitle(_ match: AppleMediaServerTitleMatch?) {
        selectedServerTitleID = match?.id
        guard item.type == "series", let match, let mediaServerLibrary else { return }
        episodeList.episodes = mediaServerLibrary.episodes(from: match.detail)
        episodeList.selectedSeason = match.playableItem.parentIndexNumber
        episodeList.selectedEpisodeID = match.playableItem.id
        episodeList.isLoading = false
        episodeList.loadFinished = true
    }

    @ViewBuilder private var matchedServerSource: some View {
        if let selected = selectedServerTitle {
            if serverTitleMatches.count > 1 {
                Menu {
                    ForEach(serverTitleMatches) { match in
                        Button(match.detail.source.name) { selectServerTitle(match) }
                    }
                } label: {
                    Text(selected.detail.source.name)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: AppleDesignTokens.minimumActionSize, minHeight: AppleDesignTokens.minimumActionSize)
                        .contentShape(.rect)
                }
                .accessibilityIdentifier("detail.media-server-source")
            } else {
                Text(selected.detail.source.name)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(minHeight: AppleDesignTokens.minimumActionSize)
                    .accessibilityIdentifier("detail.media-server-source")
            }
        }
    }

    /// Whether anything on this page can start: a media-server or library
    /// title, files on a share matched to this title, or a finished download —
    /// and, for a series, an episode list to play from.
    private var hasPlaybackRoute: Bool {
        if let reference = AppleXtreamReference.parse(item.mediaID) {
            return AppleXtreamLibraryStore.shared.source(reference)?.isEnabled == true
                && (item.type != "series" || !episodeList.episodes.isEmpty)
        }
        return AppleTitlePagePolicy.hasPlaybackRoute(
            item: item, hasLocalGroup: hasMatchingLocalGroup,
            hasCompletedDownload: downloadCoordinator.state.isCompleted,
            hasServerMatch: selectedServerTitle != nil
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
                if discOffersMenu, !state.isTrailer { phoneSkipToMovieButton }
            }
            HStack(spacing: 12) {
                if serverTrailer != nil {
                    Button { showsServerTrailer = true } label: {
                        AppleTitlePageRoundButtonLabel(title: "Trailer", systemImage: Self.serverTrailerSymbol)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Play Trailer")
                    .accessibilityIdentifier("detail.serverTrailer")
                }
                Button(action: toggleFavorite) {
                    AppleTitlePageRoundButtonLabel(
                        title: AppleSemanticAction.myList(saved: titleActions.isFavorite).label,
                        systemImage: AppleSemanticAction.myList(saved: titleActions.isFavorite).symbol
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
        let isBusy = !isTrailer && !playbackUI.startup.isLoading
            && (playbackCoordinator.phase.isBusy || playWaitsForPreparation)
        let title: String = if isBusy {
            playbackCoordinator.phase.isBusy ? "Preparing" : "Loading"
        } else if !isTrailer, discOffersMenu {
            "Play Disc"
        } else {
            action.displayTitle(hasCompletedDownload: downloadCoordinator.state.isCompleted)
        }
        return TitlePagePrimaryButtonState(title: title, isTrailer: isTrailer, isBusy: isBusy,
                                           isEnabled: isTrailer || canStartPlayback)
    }

    private var offersStartFromBeginning: Bool {
        // A DVD's Play Disc already starts from the top; a Blu-ray resumes
        // its main feature like any film.
        AppleTitlePagePolicy.offersStartFromBeginning(titlePagePrimaryAction) && watchOnAction == nil && !discOffersMenu
    }

    /// The title (or the episode Resume names) from the top; its saved
    /// position is overwritten as it plays.
    private func startFromBeginning() {
        guard canStartPlayback else { return }
        playbackUI.startsFromBeginning = true
        playbackUI.request = UUID()
    }

    private var versionResumeTitle: String {
        "Resume from \(AppleTransportOverlayModel.timeText(versionResume?.position ?? 0))?"
    }

    @ViewBuilder private var versionResumeButtons: some View {
        Button("Resume") {
            confirmedVersionID = versionResume?.versionID
            playbackUI.request = UUID()
        }
        Button("Start from Beginning") {
            confirmedVersionID = versionResume?.versionID
            playbackUI.startsFromBeginning = true
            playbackUI.request = UUID()
        }
        Button("Cancel", role: .cancel) { selectedServerVersion = nil }
    }

    @ViewBuilder private var versionMenu: some View {
        if titleMediaVersions.count > 1 {
            Menu("Play version…") {
                ForEach(titleMediaVersions) { version in
                    Button(version.menuLabel) {
                        if let reference = version.parts.first?.reference,
                           let file = localFiles.first(where: { $0.id == reference }) {
                            playbackUI.selectedLocalFile = file
                        } else { selectedServerVersion = version.id }
                        playbackUI.request = UUID()
                    }
                }
            }
        }
    }

    /// "Start from Beginning" in the one button's context menu on the iPhone,
    /// iPad, Mac and Vision Pro.
    @ViewBuilder
    private var playButtonMenuItems: some View {
        versionMenu
        AppleLibraryFixMatchMenuAction()
        if discOffersMenu {
            Button("Skip to Movie", systemImage: "forward.end.fill") { startDisc(.mainTitle) }
        }
        if offersStartFromBeginning {
            Button("Start from Beginning", systemImage: "arrow.counterclockwise", action: startFromBeginning)
                .accessibilityIdentifier("detail.startOver")
        }
    }

    /// Play (or resume), or the trailer when nothing here can play.
    fileprivate func performTitlePagePrimaryAction() {
        if titlePagePrimaryButtonState?.isTrailer == true {
            if let key = trailerKey { playTrailerInHero(key: key) }
        } else if isDiscTitle {
            startDisc(discPlayStart)
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
                AppleTitlePageRoundButtonLabel(title: downloadButtonLabel, systemImage: AppleSemanticAction.download(.preparing).symbol, showsProgress: true)
            case .systemImage(let name):
                AppleTitlePageRoundButtonLabel(title: downloadButtonLabel, systemImage: name,
                                               downloadFraction: seasonDownloads.isRunning ? nil : downloadFraction)
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
            // No progress line here: it pushed the episodes ~28 pt down as a download began.
            // The ring on the download button (and on the episode's card) shows it in place.
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
                EmptyView()
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
                EmptyView()
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

    private static func progressFraction(_ saved: ApplePlaybackProgress?, for episode: AppleMediaEpisode) -> Double? {
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
            heroTrailer.wasPressed = true
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

    private var creditOrigin: AppleTitlePagePolicy.CreditOrigin? {
        func hasCredits(_ details: AppleTMDBDetails?) -> Bool {
            details.map { !$0.cast.isEmpty || !$0.castMembers.isEmpty } ?? false
        }
        return AppleTitlePagePolicy.creditOrigin(pageHasCredits: hasCredits(pageMetadata.details),
            catalogHasCredits: hasCredits(catalogCredits), shown: shownCreditOrigin)
    }

    /// The IMDb id a media-server title's catalog credits are read by: the
    /// item's own, else the one the server listed in its rows.
    private var catalogCreditsIMDbID: String? {
        guard let serverReference else { return nil }
        return item.imdbID ?? mediaServerLibrary?.imdbID(for: serverReference)
    }

    /// TMDB's details for a media-server title, read alongside the server's
    /// own detail call, from the metadata disk cache when the title was seen
    /// before (`AppleTMDBClient.cachedDetails`).
    private func loadCatalogCredits() async {
        guard let configuration = metadataConfiguration, let imdbID = catalogCreditsIMDbID else { return }
        // Optional: without them the section waits for the server's credits.
        let details = try? await AppleTMDBClient().cachedDetails(imdbID: imdbID,
            kind: item.type == "series" ? .series : .movie, configuration: configuration)
        guard !Task.isCancelled else { return }
        catalogCredits = details
    }

    private var titlePageCredits: [AppleCreditPerson] {
        let details = creditOrigin == .catalog ? catalogCredits : pageMetadata.details
        let cast = details?.cast.isEmpty == false ? details?.cast ?? [] : item.cast ?? []
        let writers = details?.writers.isEmpty == false ? details?.writers ?? [] : item.writers ?? []
        return settings.titlePageSections.credits(AppleTitlePagePolicy.credits(
            detailed: details?.castMembers ?? [],
            cast: cast,
            director: details?.director ?? item.director,
            writers: writers
        ))
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

    private func phoneAboutSection(_ summary: String, inset: CGFloat = Self.phoneInset) -> some View {
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
        .padding(.horizontal, inset)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail.about")
    }

    private var titlePageInformation: [AppleTitlePagePolicy.Fact] {
        settings.titlePageSections.facts(AppleTitlePagePolicy.information(
            year: pageMetadata.details?.year ?? item.year,
            releaseInfo: displayReleaseInfo,
            contentRating: pageMetadata.details?.contentRating ?? item.contentRating,
            countries: pageMetadata.details?.countries ?? []
        ))
    }

    private var titlePageLanguages: [AppleTitlePagePolicy.Fact] {
        settings.titlePageSections.facts(AppleTitlePagePolicy.languages(
            originalLanguage: pageMetadata.details?.originalLanguage,
            spokenLanguages: pageMetadata.details?.spokenLanguages ?? []
        ))
    }

    /// The About section's text; the hero's short synopsis stays either way.
    private var titlePageAboutSummary: String? {
        settings.titlePageSections.aboutSummary(titlePageSynopsis)
    }

    private func phoneFactSection(_ title: String, facts: [AppleTitlePagePolicy.Fact], identifier: String,
                                  inset: CGFloat = Self.phoneInset) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            AppleTitlePageSectionTitle(title)
            AppleTitlePageFactList(facts: facts)
        }
        .padding(.horizontal, inset)
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
        let reference = macReferenceBlocks()
        return VStack(alignment: .leading, spacing: 0) {
            macHero(layout: layout, chips: chips)
            // Lazy: the push builds only the sections on screen (the
            // episodes under a series' hero); the rest are built as they
            // scroll in, as Discover's shelves are (N47).
            LazyVStack(alignment: .leading, spacing: AppleTitlePageMacLayout.sectionSpacing) {
                if showsEpisodeSection {
                    macEpisodesSection(layout: layout)
                        .id("vision-episodes")
                }
                if !titlePageTrailerKeys.isEmpty {
                    macTrailersSection
                }
                if !suggestedItems.isEmpty {
                    AppleMediaShelf(title: "More Like This", headingIdentifier: "detail.more-like-this") {
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
                if let summary = titlePageAboutSummary {
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
                        fillTimeline.recordArtworkDecoded()
                    },
                    onFailure: heroArtworkFailed,
                    keepsImageWhileReloading: true,
                    fixedPixelDimension: AppleMacHeroLayout.stillPixelDimension,
                    // Centred like the trailer's cover over it (N44).
                    fillAlignment: .center,
                    priority: .foreground
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
                    .frame(minWidth: 180, minHeight: AppleDesignTokens.minimumActionSize)
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
                    .frame(minWidth: 180, minHeight: AppleDesignTokens.minimumActionSize)
                }
                .buttonStyle(AppleMacHeroButtonStyle(kind: .primary))
                .disabled(!state.isEnabled)
                .accessibilityLabel(state.isBusy ? "Preparing playback" : state.title)
                .accessibilityIdentifier("detail.play")
                .contextMenu {
                    playButtonMenuItems
                }

                Menu {
                    playButtonMenuItems
                } label: {
                    AppleTitlePageMacRoundLabel(title: "More", systemImage: "ellipsis")
                }
                .menuStyle(.button)
                .buttonStyle(AppleMacHeroButtonStyle(kind: .round))
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")
                .accessibilityIdentifier("detail.play.more")
            }

            if serverTrailer != nil {
                Button { showsServerTrailer = true } label: {
                    AppleTitlePageMacRoundLabel(title: "Trailer", systemImage: Self.serverTrailerSymbol)
                }
                .buttonStyle(AppleMacHeroButtonStyle(kind: .round))
                .help("Play Trailer")
                .accessibilityIdentifier("detail.serverTrailer")
            }

            Button(action: toggleFavorite) {
                AppleTitlePageMacRoundLabel(title: AppleSemanticAction.myList(saved: titleActions.isFavorite).label,
                                            systemImage: AppleSemanticAction.myList(saved: titleActions.isFavorite).symbol)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(AppleMacHeroButtonStyle(kind: .round))
            .help(AppleSemanticAction.myList(saved: titleActions.isFavorite).label)
            .accessibilityValue(titleActions.isFavorite ? "Saved" : "Not saved")
            .accessibilityIdentifier("detail.my-list")

            if showsDownloadAction {
                Button(action: performDownloadAction) {
                    switch downloadGlyph {
                    case .progress, .disc:
                        AppleTitlePageMacRoundLabel(title: downloadButtonLabel, systemImage: AppleSemanticAction.download(.preparing).symbol, showsProgress: true)
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
            // No progress line: see `phoneHeroFooter`.
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
                EmptyView()
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

    /// Information and Languages, each only when it has something real to say.
    private func macReferenceBlocks() -> [AppleTitlePageMacReferenceBlock] {
        var blocks: [AppleTitlePageMacReferenceBlock] = []
        let information = titlePageInformation
        if !information.isEmpty { blocks.append(.facts(title: "Information", facts: information, identifier: "detail.information")) }
        let languages = titlePageLanguages
        if !languages.isEmpty { blocks.append(.facts(title: "Languages", facts: languages, identifier: "detail.languages")) }
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
