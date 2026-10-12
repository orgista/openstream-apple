import SwiftUI
#if os(iOS)
import UIKit
#endif

enum OpenStreamTab: String, CaseIterable, Identifiable {
    /// tvOS only: Search is a tab there, the stock TV pattern, instead of a
    /// glyph over the billboard (FEEDBACK X4). Other platforms keep it in the
    /// Discover toolbar and never show this tab.
    case search
    case home
    case library
    case live
    case settings

    static func visible(liveTVEnabled: Bool) -> [Self] {
        OpenStreamTabVisibility.visibleTabs(discover: true, library: true, live: liveTVEnabled)
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .search: "Search"
        case .home: "Discover"
        case .library: "Library"
        case .live: "Live"
        case .settings: "Settings"
        }
    }

    /// Search sits in the bar as a bare magnifying glass, like the stock TV
    /// app: the word says nothing the glyph does not, and it pushed the other
    /// tabs off centre (owner 2026-09-14). The title is still the
    /// accessibility label.
    var showsTitleInTabBar: Bool { self != .search }

    /// Tab bars substitute the `.fill` variant automatically, so a symbol is
    /// only ever as light as its filled form. `sparkles.tv` has one, and at tab
    /// size `sparkles.tv.fill` loses the sparkles entirely and renders as a
    /// blank white slab — the boxed icon the owner rejected (2026-09-16).
    /// `sparkles` has no filled counterpart, so it stays line art everywhere.
    var systemImage: String {
        switch self {
        case .search: "magnifyingglass"
        case .home: "sparkles"
        case .library: "books.vertical"
        case .live: "dot.radiowaves.left.and.right"
        case .settings: "gearshape"
        }
    }
}

/// Which tabs the bar shows. Settings is always there; Discover, Library and
/// Live each follow their own toggle, and the last content tab left on can
/// never be hidden, so the bar never collapses to Settings alone.
enum OpenStreamTabVisibility {
    static let contentTabs: [OpenStreamTab] = [.home, .library, .live]

    static func visibleTabs(discover: Bool, library: Bool, live: Bool) -> [OpenStreamTab] {
        var content = contentTabs.filter { tab in
            switch tab {
            case .home: discover
            case .library: library
            case .live: live
            case .settings: true
            case .search: false
            }
        }
        // Every toggle off is unreachable through the UI (the last one is
        // disabled); if stored defaults ever say so, keep Discover.
        if content.isEmpty { content = [.home] }
        return content + [.settings]
    }

    /// Whether a content tab's toggle may be **operated** — in either direction.
    ///
    /// This used to be `canHide`, and the name is what caused the bug: reading
    /// it literally, "a tab that is already off has nothing to hide" looks like
    /// it should return false, and a test said exactly that. But the call site
    /// is `.disabled(!canHide(...))`, so a false answer greys the toggle out —
    /// and a tab you had switched off could never be switched back on. A tester
    /// hit that on build 10 and it is a dead end: the only way back was
    /// reinstalling.
    ///
    /// The rule the app actually wants has two halves, and only the second one
    /// is about hiding:
    /// * a tab that is **off** can always be turned on;
    /// * a tab that is **on** can be turned off unless it is the last one.
    static func canToggle(_ tab: OpenStreamTab, discover: Bool, library: Bool, live: Bool) -> Bool {
        guard tab != .settings else { return false }
        let visible = visibleTabs(discover: discover, library: library, live: live)
        guard visible.contains(tab) else { return true }
        return visible.count > 2
    }

    /// Keeps the current tab when it is still shown; otherwise moves to the
    /// first visible tab.
    static func selection(current: OpenStreamTab, visible: [OpenStreamTab]) -> OpenStreamTab {
        visible.contains(current) ? current : (visible.first ?? .settings)
    }
}

/// Whether a selected tab's stack failed to come on screen (tvOS; see the
/// root view's `onChange(of: selectedTab)`).
enum OpenStreamTabMountWatchdog {
    /// Long enough for a normal tab switch to appear, short enough that an
    /// empty tab is not noticed.
    static let grace: Duration = .milliseconds(1200)

    static func needsRemount<Tab: Hashable>(selected: Tab, mounted: Set<Tab>) -> Bool {
        !mounted.contains(selected)
    }
}

/// Decides what a tab bar selection means. Re-selecting the tab that is
/// already showing pops that tab's navigation stack back to its root.
enum OpenStreamTabReselection {
    static func popsToRoot(current: OpenStreamTab, selected: OpenStreamTab) -> Bool {
        current == selected
    }
}

/// Native Apple app shell with one independent navigation stack per tab.
@MainActor
public struct OpenStreamRootView: View {
    @State private var selectedTab = OpenStreamTab.home
    @State private var navigationPaths: [OpenStreamTab: NavigationPath] = [:]
    #if os(tvOS)
    /// The tabs whose stack is on screen right now, and a remount counter per
    /// tab for the watchdog below (`OpenStreamTabMountWatchdog`).
    @State private var mountedTabs: Set<OpenStreamTab> = []
    @State private var tabMountGeneration: [OpenStreamTab: Int] = [:]
    @State private var tabMountWatchdog: Task<Void, Never>?
    /// The player in the Picture in Picture window, for its way back.
    @State private var pictureInPicture = AppleTVPictureInPicture.shared
    #endif
    #if os(iOS)
    @State private var rootViewportSize: CGSize = .zero
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @Environment(\.scenePhase) private var restrictionScenePhase
    @State private var sourceStore = AppleSourceStore()
    @State private var catalogStore = AppleCatalogStore()
    @State private var settingsStore = AppleSettingsStore()
    @State private var mediaIndex = AppleMediaIndexStore()
    @State private var backupController: AppleConfigurationController?
    @State private var mediaServerLibrary = AppleMediaServerLibraryStore()
    private let router: AppleAppRouter
    #if os(macOS)
    /// The menu bar's end of the wire. Not `@State`: the menu bar outlives
    /// every view and owns this, so the root view only observes it.
    private let macCommands = AppleMacCommandCenter.shared
    /// This window's player, drawn over everything while something plays.
    @State private var macPlayerStage = AppleMacPlayerStage()
    #endif
    #if os(visionOS)
    /// This window's player, drawn over everything while something plays.
    @State private var visionPlayerStage = AppleVisionPlayerStage()
    #endif
    @State private var intentHandoff = AppleAppIntentHandoff.shared
    @State private var sharePlay = AppleSharePlaySessionStore.shared
    @AppStorage("openstream.firstRunGuidanceSeen") private var firstRunGuidanceSeen = false
    #if DEBUG
    @State private var debugForcesFirstRun = false
    #endif

    private let webManagement: any AppleWebManagementServing

    public init(
        webManagement: (any AppleWebManagementServing)? = nil,
        router: AppleAppRouter? = nil
    ) {
        self.webManagement = webManagement ?? AppleWebManagementController()
        self.router = router ?? AppleAppRouter()
    }

    /// Tapping the tab that is already showing goes back to its root, the way
    /// every stock iOS app behaves. The system tab bar does the popping (and
    /// the scroll to top) itself; this only empties the value path to match.
    ///
    /// The stacks keep one identity for their whole life. Re-selecting used to
    /// bump a counter folded into each stack's `.id`, which made SwiftUI throw
    /// away the visible navigation controller inside the tab bar controller
    /// and build a new one. iOS 18 asserts on that ("Layout requested for
    /// visible navigation bar … when the top item belongs to a different
    /// navigation bar") and the app crashed on every re-tap of a tab.
    private var tabSelection: Binding<OpenStreamTab> {
        Binding(
            get: { selectedTab },
            set: { tab in
                #if os(iOS)
                if OpenStreamTabReselection.popsToRoot(current: selectedTab, selected: tab) {
                    navigationPaths[tab] = NavigationPath()
                }
                #endif
                selectedTab = tab
            }
        )
    }

    /// The tabs the bar shows right now. A SharePlay session keeps Live on
    /// screen even when its toggle is off.
    private var visibleTabs: [OpenStreamTab] {
        let tabs = OpenStreamTabVisibility.visibleTabs(
            discover: settingsStore.discoverEnabled,
            library: settingsStore.libraryEnabled,
            live: settingsStore.liveTVEnabled || sharePlay.channel != nil
        )
        #if os(tvOS)
        return [.search] + tabs
        #else
        return tabs
        #endif
    }

    private var tabs: some View {
        TabView(selection: tabSelection) {
            ForEach(visibleTabs) { tab in
                #if os(visionOS)
                NavigationStack(path: Binding(
                    get: { navigationPaths[tab] ?? NavigationPath() },
                    set: { navigationPaths[tab] = $0 }
                )) {
                    content(for: tab)
                        // The tab ornament leaves while the player has the window.
                        .toolbar(visionPlayerStage.isPresenting ? .hidden : .automatic, for: .tabBar)
                }
                .modifier(AppleSettingsPINLock(active: tab == .settings))
                .tabItem { Label(tab.title, systemImage: tab.systemImage) }
                .tag(tab)
                #elseif os(iOS)
                let path = Binding(
                    get: { navigationPaths[tab] ?? NavigationPath() },
                    set: { navigationPaths[tab] = $0 }
                )
                Group {
                    if tab == .settings, settingsUsesSplitView {
                        // Settings brings its own split view: a stack around
                        // it cannot hold one (iPad v2, landscape).
                        content(for: tab, settingsSplitPath: path)
                    } else {
                        NavigationStack(path: path) {
                            content(for: tab)
                                // The system tab bar as each OS draws it (owner,
                                // 2026-09-17): the floating glass bar on iOS 26, the
                                // classic bar on iOS 18 — no background or colour
                                // scheme of our own.
                                .toolbar(iPadTabBarIsHidden ? .hidden : .automatic, for: .tabBar)
                        }
                    }
                }
                .modifier(AppleSettingsPINLock(active: tab == .settings))
                .tabItem {
                    Label(tab.title, systemImage: tab.systemImage)
                }
                .tag(tab)
            #elseif os(tvOS)
                NavigationStack(path: Binding(
                    get: { navigationPaths[tab] ?? NavigationPath() },
                    set: { navigationPaths[tab] = $0 }
                )) {
                    content(for: tab)
                }
                // Remounted only by the watchdog, when the tab was selected
                // and its stack never came on screen.
                .id(tabMountGeneration[tab] ?? 0)
                .onAppear { mountedTabs.insert(tab) }
                .onDisappear { mountedTabs.remove(tab) }
                .modifier(AppleSettingsPINLock(active: tab == .settings))
                .tabItem {
                    if tab.showsTitleInTabBar {
                        Label(tab.title, systemImage: tab.systemImage)
                    } else {
                        Label(tab.title, systemImage: tab.systemImage)
                            .labelStyle(.iconOnly)
                    }
                }
                .tag(tab)
                .onExitCommand(perform: exitCommandHandler(for: tab))
                #else
                // macOS. This branch is `#else` and not `#elseif os(macOS)` on
                // purpose. While the chain was closed, macOS matched none of
                // the three branches above, so the `ForEach` body compiled to
                // `EmptyView`, the `TabView` was built with no tabs in it, and
                // the app opened a window whose hosting view had zero
                // subviews — build 13 shipped a completely blank window. A
                // trailing `#else` is the only shape of this chain that no
                // platform can fall out of.
                //
                // The shell itself is the visionOS one: a plain stack per tab,
                // with no `.toolbar(_:for: .tabBar)` (that placement does not
                // exist on macOS) and no iPad size-class handling.
                NavigationStack(path: Binding(
                    get: { navigationPaths[tab] ?? NavigationPath() },
                    set: { navigationPaths[tab] = $0 }
                )) {
                    content(for: tab)
                }
                .modifier(AppleSettingsPINLock(active: tab == .settings))
                .tabItem { Label(tab.title, systemImage: tab.systemImage) }
                .tag(tab)
                #endif
            }
        }
        #if os(tvOS)
        // Owner (16:20): keep the stock top tab bar; the sidebar experiment
        // (X8) read as "the top bar is gone". The bar hides while scrolling.
        .onExitCommand(perform: exitCommandHandler(for: selectedTab))
        // A quick run along the tab bar ending in Select could leave the
        // chosen tab empty for a minute or more — no spinner, no task, the
        // trace only "tab → search" — until the viewer moved off and back
        // (Apple TV full pass 2026-10-02, 55). The selected tab's stack never
        // appeared, so nothing inside it ever started. If it has not appeared
        // shortly after the selection settles, remount it: the same thing
        // moving off and back did, without the viewer having to.
        .onChange(of: selectedTab) { _, tab in
            tabMountWatchdog?.cancel()
            tabMountWatchdog = Task { @MainActor in
                try? await Task.sleep(for: OpenStreamTabMountWatchdog.grace)
                guard !Task.isCancelled, selectedTab == tab,
                      OpenStreamTabMountWatchdog.needsRemount(selected: tab, mounted: mountedTabs) else { return }
                appleTraceFailure("tab \(tab): content never appeared after selection — remounting")
                tabMountGeneration[tab, default: 0] += 1
            }
        }
        #endif
    }

    // Compact iPad windows retain their existing landscape behavior.
    // The phone shell is portrait-only, including while a player covers it.
    #if os(iOS)
    private var iPadTabBarIsHidden: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
            && horizontalSizeClass == .compact
            && AppleDetailMetrics.isLandscapeLayout(viewport: rootViewportSize)
    }

    /// Settings as a sidebar and a pane on a regular-width iPad in
    /// landscape; a single pushed stack everywhere else.
    private var settingsUsesSplitView: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
            && horizontalSizeClass == .regular
            && AppleDetailMetrics.isLandscapeLayout(viewport: rootViewportSize)
    }
    #endif

    public var body: some View {
        tabs
        #if os(iOS)
        .modifier(AppleSystemTabBarMinimization())
        #endif
        #if os(tvOS)
        // One black ground for every tab, applied once here.
        //
        // Each tab used to bring its own, and Discover's was on its populated
        // branch only — so an empty tab fell through to the tvOS system
        // material: measured rgb(39,41,37) and rgb(43,40,30) at two points on
        // one screen, i.e. not even a flat colour. The owner saw it as "oled
        // mode is only on some tabs but not others" (2026-09-16). Putting it
        // at the root means no tab, and no branch inside a tab, can drift
        // again.
        .background(Color.black.ignoresSafeArea())
        #elseif os(macOS)
        // The same ground, for the same reason, on the Mac.
        //
        // macOS gave every tab AppKit's window background instead — measured
        // rgb(40,40,40) behind the Discover billboard, behind the Live empty
        // state, behind everything (2026-09-21). The owner's complaint that
        // the Mac app "doesn't match Apple TV or the other apps" starts here:
        // the other three platforms draw this app on black, and a media app on
        // mid-grey reads as a different product. Settings panes sit on it the
        // way an iOS inset-grouped list does, black ground with dark row
        // boxes, because their own scroll background is hidden
        // (`AppleSettingsContentModifier`).
        .background(Color.black.ignoresSafeArea())
        #endif
        #if DEBUG && os(macOS)
        .modifier(AppleDebugMacCaptionsProbe.Presenter(settings: settingsStore))
        #endif
        #if os(macOS)
        .appleMacPlayerStage(macPlayerStage)
        #endif
        #if os(visionOS)
        .appleVisionPlayerStage(visionPlayerStage)
        #endif
        .modifier(ApplePINPresenter())
        .onChange(of: restrictionScenePhase) { _, phase in
            if phase == .background { AppleRestrictionStore.shared.background() }
        }
        .safeAreaInset(edge: .bottom) { AppleImportProgressView() }
        .modifier(AppleProgrammeReminderBanner())
        .onChange(of: AppleProgrammeReminderStore.shared.requestedChannelID, initial: true) { _, id in
            guard id != nil else { return }
            settingsStore.liveTVEnabled = true
            navigationPaths[.live] = NavigationPath()
            selectedTab = .live
        }
        #if os(tvOS)
        // The window's full-screen button. An on-demand player comes back over
        // whichever tab is on screen; a live one in the Live tab, which opens
        // it once it is the tab on screen (`AppleLiveTVView`).
        .modifier(AppleMediaPlayerPresentationModifier(presentation: $pictureInPicture.restoringPresentation))
        .onChange(of: pictureInPicture.liveRestoreRequest) {
            navigationPaths[.live] = NavigationPath()
            selectedTab = .live
        }
        #endif
        .appleTraceSelection("tab", value: selectedTab)
        .modifier(AppleConfigurationSync(
            controller: $backupController, sources: sourceStore, settings: settingsStore, mediaIndex: mediaIndex
        ))
        .modifier(AppleSetupTransferHost(router: router, controller: backupController))
        .confirmationDialog("Play Live TV", isPresented: Binding(
            get: { router.pendingExternalLiveChannelID != nil },
            set: { if !$0 { router.clearExternalLivePlayback() } }
        ), titleVisibility: .visible, presenting: router.pendingExternalLiveChannelID) { id in
            Button("Play", systemImage: "play.fill") { router.open(.live(channelID: id)) }
            Button("Cancel", role: .cancel) { router.clearExternalLivePlayback() }
        }
        #if os(iOS)
        .onGeometryChange(for: CGSize.self) { [isPad = UIDevice.current.userInterfaceIdiom == .pad] proxy in
            isPad ? proxy.size : .zero
        } action: { rootViewportSize = $0 }
        #endif
        #if os(visionOS)
        // While the player has the window its minimum is the film's floor,
        // or this minimum (which `.contentMinSize` turns into the window's)
        // would win over the aspect-locked one (`AppleVisionPlayerStage`).
        .frame(minWidth: visionPlayerStage.isPresenting
                   ? AppleVisionPlayerWindowPolicy.playerContentMinimum.width
                   : AppleVisionPlayerWindowPolicy.browseMinimum.width,
               minHeight: visionPlayerStage.isPresenting
                   ? AppleVisionPlayerWindowPolicy.playerContentMinimum.height
                   : AppleVisionPlayerWindowPolicy.browseMinimum.height)
        .environment(\.defaultMinListRowHeight, 60)
        .scrollIndicators(AppleDesignTokens.scrollIndicatorVisibility)
        .defaultHoverEffect(.highlight)
        #endif
        #if DEBUG
        .onAppear {
            AppleLaunchClock.mark("root.appear")
            #if os(macOS)
            AppleDebugMacHarness.startIfRequested()
            #endif
        }
        .task {
            AppleLaunchClock.begin()
            AppleInteractionTrace.begin()
            // `-OpenStreamDevSources <path>`: the owner's test sources, added
            // through the normal store calls once per launch. The file is the
            // whole setup: no test catalog is seeded beside it.
            let importsDevSources = AppleDevSourcesImport.isPending
            if importsDevSources { sourceStore.markTestCatalogsSeeded() }
            Task { await AppleDevSourcesImport.importPendingIfNeeded(sourceStore: sourceStore, settings: settingsStore) }
            let playbackFixture = UserDefaults.standard.string(forKey: "OpenStreamVisionPlaybackURL").flatMap(URL.init(string:))
            if !importsDevSources, !UserDefaults.standard.bool(forKey: "OpenStreamVisionPlaybackIsLive"), playbackFixture?.isFileURL != true {
        #if OPENSTREAM_ADDONS
                Task { await sourceStore.seedTestCatalogsIfNeeded() }
        #endif
            }
            // Simulator-only navigation to real screens; no fixtures or saved sources.
            let screen = debugScreen
            guard let screen else { return }
            // The first-run card only appears with no sources configured, so
            // the review simulator — which has them — could never show it and
            // it went unreviewed until the owner hit it on a fresh install.
            debugForcesFirstRun = screen == "first-run"
            firstRunGuidanceSeen = true
            if screen == "library" { selectedTab = .library }
            else if screen == "live" { selectedTab = .live }
            // "search" stays on Discover: Search is a page pushed from there
            // off Apple TV, and Discover's own debug hook pushes it.
            else if !["discover", "detail", "detail-movie", "episodes", "play", "search"].contains(screen) {
                selectedTab = .settings
                // Every platform binds its Settings tab to the same
                // `navigationPaths[.settings]` and declares the same
                // `navigationDestination`s, so this was needlessly fenced off
                // from iOS — which is why an iPhone sweep could only ever
                // photograph the settings root and not the pages under it.
                var path = NavigationPath()
                if screen == "subtitle-languages" {
                    path.append(AppleSettingsRoute.playback)
                    path.append(AppleSettingsRoute.subtitleLanguages)
                } else if let route = Self.debugTopLevelSettingsRoutes[screen] {
                    // Panes that hang off Settings directly rather than under
                    // Sources. Listing them here is what makes Privacy, Storage,
                    // About and the three service panes reachable for a headless
                    // screenshot at all — before this, the sweep could only see
                    // the pages that happened to sit under Sources.
                    path.append(route)
                } else {
                    if screen != "settings" {
                        path.append(AppleSettingsRoute.sources)
                    }
                    switch screen {
                    case "add-files": path.append(AppleSourceRoute.addFiles)
                    case "add-live": path.append(AppleSourceRoute.addLiveTV)
                    case "add-media-server": path.append(AppleSourceRoute.addMediaServer)
                    case "add-catalog": path.append(AppleSourceRoute.addManifest)
                    case "network-share": path.append(AppleSourceRoute.addNetworkShare)
                    case "web-management": path.append(AppleSourceRoute.webManagement)
                    default: break
                    }
                }
                navigationPaths[.settings] = path
            }
        }
        #endif
        .task(id: sourceAvailabilityIdentity) {
            await mediaIndex.load()
            let activeSources = sourceStore.sources.filter { $0.isEnabled && ($0.kind == .library || $0.kind == .nas) }

            let published = await AppleLocalLibraryStore.shared.publishPersistedIndex(activeSources: activeSources)

            let delay = AppleLaunchWorkPolicy.scanDelay(hasPersistedIndex: published)
            await Task.yield()
            if delay > .zero { try? await Task.sleep(for: delay) }

            let sourceDigest = ApplePlaybackIdentity.digest(for: activeSources.map(\.id.uuidString).sorted().joined(separator: ","))
            if AppleLaunchWorkPolicy.shouldRescan(published: published, sourceDigest: sourceDigest, now: Date()) {
                let task = Task.detached(priority: AppleLaunchWorkPolicy.backgroundPriority) {
                    await AppleLocalLibraryStore.shared.reload(sourceStore: sourceStore, mediaIndex: mediaIndex, settings: settingsStore)
                }
                await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
            }

            let enabledServerIDs = Set(sourceStore.sources.filter { $0.isEnabled && $0.kind == .mediaServer }.map(\.id))
            let existingServerIDs = Set(mediaServerLibrary.shelves.map(\.sourceID)).union(mediaServerLibrary.failures.keys)
            for id in existingServerIDs where !enabledServerIDs.contains(id) {
                mediaServerLibrary.clear(sourceID: id)
            }
            await mediaServerLibrary.reload(sources: sourceStore.sources) { try sourceStore.mediaServerSession(for: $0) }
        }
        .task(id: sourceAvailabilityIdentity) {
            await AppleXtreamLibraryStore.shared.reload(sourceStore: sourceStore)
        }
        .onChange(of: ApplePlaybackProgressFeed.shared.revision) {
            AppleXtreamLibraryStore.shared.refreshProgress()
        }
        .onChange(of: settingsStore.liveTVEnabled) { _, enabled in
            if !enabled { sharePlay.leave() }
        }
        // `initial: true` also covers launch, when a persisted toggle may
        // already hide the tab the view starts on.
        .onChange(of: visibleTabs, initial: true) { _, visible in
            selectedTab = OpenStreamTabVisibility.selection(current: selectedTab, visible: visible)
            #if os(macOS)
            macCommands.availableTabs = Set(visible.compactMap(AppleMacTabTarget.init(tab:)))
            #endif
        }
        #if os(macOS)
        .onChange(of: macCommands.revision) { applyMacCommand() }
        .onChange(of: selectedTab, initial: true) { _, tab in
            macCommands.selectedTab = AppleMacTabTarget(tab: tab)
        }
        // The owner's "no scroll indicators" rule, which had no macOS branch:
        // `AppleDesignTokens.scrollIndicatorVisibility` was only ever applied
        // under `#if os(visionOS)` here, so every shelf and list on the Mac
        // drew one (macOS sweep, 2026-09-21).
        .scrollIndicators(AppleDesignTokens.scrollIndicatorVisibility)
        #endif
        .task {
            sharePlay.startListening()
            mediaServerLibrary.loadPersisted()
            // The engine's own log in the trace (scrubbed), while tracing is on.
            AppleEngineLogBridge.install()
            // Add-ons saved before catalog paging pick up `skip` (once a day each).
        #if OPENSTREAM_ADDONS
            sourceStore.scheduleDailyManifestRefresh()
        #endif
        }
        .onChange(of: sharePlay.revision) {
            if sharePlay.channel != nil { selectedTab = .live }
            else { selectedTab = OpenStreamTabVisibility.selection(current: selectedTab, visible: visibleTabs) }
        }
        .environment(\.appleOpenSourcesSettings, AppleOpenSourcesSettingsAction { openSourcesSettings() })
        .environment(\.appleMediaServerConnected, AppleMediaServerConnectionAction {
            // Media-server libraries are rendered by Discover, not the local
            // files tab. Clear its old detail stack before showing the shelves.
            navigationPaths[.home] = NavigationPath()
            selectedTab = .home
        })
        .environment(\.appleSettingsNavigator, settingsNavigator)
        .preferredColorScheme(.dark)
        #if !os(tvOS)
        // On Apple TV the global white tint made every tinted control a trap
        // (white label on a white fill, TV7); tvOS controls are styled where
        // they are declared instead (rework plan task 3).
        .tint(.white)
        // Switches alone take the brand accent — see `AppleBrandToggleStyle`.
        .toggleStyle(.brandSwitch)
        #endif
        .appleFirstRunPresentation(isPresented: Binding(
            get: {
                #if DEBUG
                if debugForcesFirstRun { return true }
                #endif
                return !firstRunGuidanceSeen && sourceStore.sources.isEmpty
            },
            set: {
                if !$0 {
                    firstRunGuidanceSeen = true
                    #if DEBUG
                    debugForcesFirstRun = false
                    #endif
                }
            }
        )) {
            AppleFirstRunGuidanceContainer {
                AppleFirstRunGuidanceView {
                    openMediaServerSetup()
                    firstRunGuidanceSeen = true
                    #if DEBUG
                    // The debug route forces the card; without this the card
                    // stays up over the screen it just opened.
                    debugForcesFirstRun = false
                    #endif
                }
                    #if os(visionOS)
                    .frame(width: 560, height: 300)
                    #endif
            }
        }
        .onChange(of: router.revision) {
            guard let route = router.route else { return }
            let revision = router.revision
            Task { @MainActor in
                guard router.revision == revision, router.route == route else { return }
                await apply(route)
            }
        }
        // Siri, Shortcuts and Spotlight arrive here and go through the same
        // router as a deep link, so Discover moves its own navigation state
        // (Search, a title page) instead of the whole stack being rebuilt.
        .onChange(of: intentHandoff.revision) {
            guard let route = intentHandoff.route else { return }
            router.open(route)
        }
        .task {
            if let route = intentHandoff.route { router.open(route) }
            if let route = router.route { await apply(route) }
        }
        .task(id: sourceAvailabilityIdentity) {
            await reconcileMediaAvailability()
        }
        .task(id: arrConfigurationIdentity) {
            await reconcileMediaAvailability()
        }
        .task(id: mediaIndex.records) {
            await AppleSpotlightIndexer.shared.synchronize(
                records: mediaIndex.records,
                enabled: settingsStore.systemSearchEnabled
            )
        }
        .task(id: settingsStore.systemSearchEnabled) {
            await AppleSpotlightIndexer.shared.synchronize(
                records: mediaIndex.records,
                enabled: settingsStore.systemSearchEnabled
            )
        }
        .modifier(AppleSystemSurfacePublishing(
            mediaIndex: mediaIndex, catalogStore: catalogStore, sourceStore: sourceStore,
            settingsStore: settingsStore))
    }

    private var arrConfigurationIdentity: String {
        ApplePlaybackIdentity.digest(for: [
            settingsStore.radarrURL, settingsStore.radarrAPIKey,
            settingsStore.sonarrURL, settingsStore.sonarrAPIKey,
        ].joined(separator: "\u{1f}"))
    }

    private var sourceAvailabilityIdentity: String {
        ApplePlaybackIdentity.digest(for: sourceStore.sources.map {
            "\($0.id.uuidString)|\($0.kind.rawValue)|\($0.isEnabled)|\($0.configurationRevision)"
        }.sorted().joined(separator: "\u{1f}"))
    }

    private func reconcileMediaAvailability() async {
        await mediaIndex.load()
        var active = Set(sourceStore.sources.filter(\.isEnabled).map(\.id))
        if AppleArrClient.isValidAPIKey(settingsStore.radarrAPIKey),
           let id = AppleArrInstanceIdentity.id(kind: .radarr, baseURL: settingsStore.radarrURL) {
            active.insert(id)
        }
        if AppleArrClient.isValidAPIKey(settingsStore.sonarrAPIKey),
           let id = AppleArrInstanceIdentity.id(kind: .sonarr, baseURL: settingsStore.sonarrURL) {
            active.insert(id)
        }
        try? await mediaIndex.retainAvailability(for: active)
    }

    private var settingsNavigator: AppleSettingsNavigator {
        AppleSettingsNavigator(
            depth: { navigationPaths[.settings]?.count ?? 0 },
            push: { route in
                var path = navigationPaths[.settings] ?? NavigationPath()
                path.append(route)
                navigationPaths[.settings] = path
            },
            pop: { depth in
                guard var path = navigationPaths[.settings], path.count > depth else { return }
                path.removeLast(path.count - max(depth, 0))
                navigationPaths[.settings] = path
            }
        )
    }

    private func openMediaServerSetup() {
        selectedTab = .settings
        var path = NavigationPath()
        path.append(AppleSettingsRoute.sources)
        path.append(AppleSourceRoute.addMediaServer)
        navigationPaths[.settings] = path
    }

    /// Settings › Sources, in place of whatever the Settings tab had open.
    private func openSourcesSettings() {
        selectedTab = .settings
        var path = NavigationPath()
        path.append(AppleSettingsRoute.sources)
        navigationPaths[.settings] = path
    }

    @ViewBuilder
    private func content(for tab: OpenStreamTab, settingsSplitPath: Binding<NavigationPath>? = nil) -> some View {
        switch tab {
        case .search:
            AppleSearchView(
                catalogStore: catalogStore,
                sourceStore: sourceStore,
                mediaIndex: mediaIndex,
                router: router,
                settings: settingsStore,
                openSettings: { selectedTab = .settings }
            )
            .appleAlignedTabTitle(tab.title)
        case .home:
            AppleDiscoverView(
                catalogStore: catalogStore,
                sourceStore: sourceStore,
                mediaIndex: mediaIndex,
                mediaServerLibrary: mediaServerLibrary,
                router: router,
                settings: settingsStore,
                openSettings: { selectedTab = .settings },
                backupController: backupController
            )
            .appleAlignedTabTitle(tab.title)
        case .library:
            AppleLibraryView(
                catalogStore: catalogStore,
                sourceStore: sourceStore,
                mediaIndex: mediaIndex,
                settings: settingsStore,
                openSettings: { selectedTab = .settings }
            )
            .appleAlignedTabTitle(tab.title)
        case .live:
            AppleLiveTVView(
                sourceStore: sourceStore,
                mediaIndex: mediaIndex,
                settings: settingsStore,
                openSettings: { selectedTab = .settings },
                isActive: selectedTab == .live
            )
            .appleAlignedTabTitle(tab.title, isLive: true)
        case .settings:
            AppleSettingsView(
                settings: settingsStore,
                sourceStore: sourceStore,
                webManagement: webManagement,
                backupController: backupController,
                catalogStore: catalogStore,
                splitPath: settingsSplitPath
            )
            .appleAlignedTabTitle(tab.title)
        }
    }

    #if os(macOS)
    /// Runs the menu item the viewer just chose.
    ///
    /// Playback commands are not here: the Controls menu calls the player's
    /// own closures through the command centre, because the root view has no
    /// coordinator to hand them to.
    private func applyMacCommand() {
        switch macCommands.command {
        case .selectTab(let target):
            selectedTab = OpenStreamTab(macTarget: target)
        case .openSearch:
            // Search hangs off Discover on macOS, so the tab has to be the one
            // showing before the route can push it.
            selectedTab = OpenStreamTabVisibility.selection(current: .home, visible: visibleTabs)
            router.openSearch()
        case .togglePlayPause, .skipForward, .skipBackward, .volumeUp, .volumeDown, .toggleMute, .none:
            break
        }
    }
    #endif

    private func apply(_ route: AppleAppRoute) async {
        // Every route lands on Discover; when that tab is hidden, stay on the
        // first tab the bar still shows instead of selecting an absent one.
        let target = OpenStreamTabVisibility.selection(current: .home, visible: visibleTabs)
        switch route {
        case .search:
            // Apple TV has a Search tab; selecting it *is* the navigation.
            selectedTab = visibleTabs.contains(.search) ? .search : target
        case .media, .sharedLink:
            selectedTab = target
        case .continueWatching:
            selectedTab = target
        case .live(let id):
            guard visibleTabs.contains(.live), router.route == route,
                  router.pendingExternalLiveChannelID == nil else { return }
            // Entering Live can resume its previous channel, so defer the tab
            // change as well as the requested channel until Play is confirmed.
            AppleLiveSystemChannels.shared.requestedChannelID = id
            selectedTab = .live
        }
    }

    #if os(tvOS)
    /// Menu is only ours to handle when there is a value-pushed screen to pop.
    ///
    /// `onExitCommand` consumes the press whether or not the closure does
    /// anything, and only Settings pushes through `navigationPaths`: every
    /// content page arrives as `NavigationLink { detail(value) }`, whose push
    /// tvOS pops by itself. So the old unconditional handler swallowed Menu
    /// and then returned early on an empty path — the title page could not be
    /// left at all (owner: "if I press esc here it doesn't go back"), and at a
    /// tab root it ate the press that moves focus up to the tab bar (owner:
    /// "I can't go back … from live to go to the top bar … I have to scroll
    /// all the way up"). Returning `nil` leaves the press to tvOS, which pops
    /// the link or hands focus to the tab bar — the stock behaviour.
    private func exitCommandHandler(for tab: OpenStreamTab) -> (() -> Void)? {
        guard navigationPaths[tab]?.isEmpty == false else { return nil }
        return { popOneNavigationLevel(for: tab) }
    }

    private func popOneNavigationLevel(for tab: OpenStreamTab) {
        guard var path = navigationPaths[tab], !path.isEmpty else { return }
        path.removeLast()
        navigationPaths[tab] = path
    }
    #endif

    #if DEBUG
    /// Settings pages that are children of Settings itself, not of Sources.
    private static var debugTopLevelSettingsRoutes: [String: AppleSettingsRoute] {
        var routes: [String: AppleSettingsRoute] = [
        "channels": .channels,
        "restrictions": .restrictions,
        "playback-settings": .playback,
        "metadata": .metadata,
        "server-downloads": .serverDownloads,
        "trakt": .trakt,
        "watch-providers": .watchProviders,
        "discover-rows": .discoverRows,
        "privacy": .privacy,
        "storage": .storage,
        "about": .about,
        ]
        #if !os(tvOS)
        routes["backup"] = .backup
        #endif
        return routes
    }

    private var debugScreen: String? {
        if let stored = UserDefaults.standard.string(forKey: "OpenStreamVisionScreen") {
            return stored
        }
        let arguments = ProcessInfo.processInfo.arguments
        guard let marker = arguments.firstIndex(of: "-OpenStreamVisionScreen"),
              arguments.indices.contains(marker + 1) else { return nil }
        return arguments[marker + 1]
    }
    #endif
}

/// Wraps the first-run card in a `NavigationStack` everywhere except Apple TV,
/// where the page owns its whole layout and has nowhere to navigate.
private struct AppleFirstRunGuidanceContainer<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        #if os(tvOS)
        content
        #else
        NavigationStack { content }
        #endif
    }
}

private extension View {
    /// Presents first-run guidance the way each platform expects.
    ///
    /// A tvOS `.sheet` is a fixed-size inset card that the content cannot
    /// shrink, so a title and two buttons sat in the middle of a mostly empty
    /// box (owner: "GUI with no content needs work", 2026-09-15). Apple TV
    /// setup screens are full-screen pages; this one is too.
    @ViewBuilder
    func appleFirstRunPresentation<Content: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        #if os(tvOS)
        fullScreenCover(isPresented: isPresented, content: content)
        #else
        sheet(isPresented: isPresented, content: content)
        #endif
    }
}

private struct AppleFirstRunGuidanceView: View {
    let openSettings: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        #if os(tvOS)
        tvBody
        #else
        // The phone sheet had every fault the Apple TV card had, because only
        // the tvOS branch was rewritten on 2026-09-15 and this one was left
        // alone: "Not Now" orphaned above the title, **two** titles stacked
        // ("Getting Started" over "Welcome to OpenStream"), no brand mark, and
        // a `Spacer` opening roughly 700 pt of nothing on an SE-sized screen
        // before the button. Seen on a clean install, 2026-09-16.
        VStack(spacing: AppleDesignTokens.spacingLarge) {
            Spacer(minLength: 0)
            OpenStreamThreeBarMark()
                .frame(width: 64, height: 46)
            Text("Welcome to oStream")
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
            Spacer(minLength: 0)
            Button("Connect Media Server", action: openSettings)
                .buttonStyle(.brandPrimary)
            Button("Not Now") { dismiss() }
                .buttonStyle(.brandSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(AppleDesignTokens.spacingLarge)
        #endif
    }

    #if os(tvOS)
    /// The first-run page lays itself out on Apple TV.
    ///
    /// tvOS draws a `.navigationTitle` *over* the page rather than above it
    /// (the same bug `AppleSettingsPageTitleModifier` exists to avoid), and it
    /// puts a `.cancellationAction` toolbar item in that same corner — so the
    /// card showed "Not Now" sitting on top of a truncated "Getting…", with
    /// the real title below the buttons and a `Spacer` holding a screen-tall
    /// void above a full-width platter (owner photo, 2026-09-15). The brand
    /// mark, the title, then the two actions as content-sized pills, centred
    /// on the page — the stock shape of an Apple TV setup screen.
    private var tvBody: some View {
        VStack(spacing: AppleDesignTokens.spacingExtraLarge) {
            OpenStreamThreeBarMark()
                .frame(width: 132, height: 96)
            Text("Welcome to oStream")
                .font(.system(size: AppleTVChromeMetrics.pageHeaderFontSize, weight: .bold))
                .accessibilityAddTraits(.isHeader)
            // The same gap the billboard uses, which is wide enough that a
            // focused pill's ring and glow clear its neighbour.
            HStack(spacing: AppleTVBillboardMetrics.pillGap) {
                // Apple TV can't import a file; most owners set it up from their iPhone.
                Button(AppleSetupTransferDevice.receiveTitle) {
                    dismiss()
                    // The receiver is a root-level presentation: let this one close first.
                    Task {
                        try? await Task.sleep(for: .milliseconds(450))
                        AppleSetupTransferCenter.shared.presentReceiver()
                    }
                }
                .buttonStyle(.brandPrimary)
                Button("Connect Media Server", action: openSettings)
                    .buttonStyle(.brandSecondary)
                Button("Not Now") { dismiss() }
                    .buttonStyle(.brandSecondary)
            }
            .padding(.top, AppleDesignTokens.spacingSmall)
        }
        .padding(AppleTVChromeMetrics.horizontalSafeInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
    #endif
}

public struct OpenStreamThreeBarMark: View {
    public init() {}

    public var body: some View {
        GeometryReader { geometry in
            let stroke = max(3, geometry.size.height * 0.18)
            VStack(spacing: geometry.size.height * 0.12) {
                bar(width: 0.72, stroke: stroke)
                bar(width: 1, stroke: stroke)
                bar(width: 0.72, stroke: stroke)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityHidden(true)
    }

    private func bar(width: CGFloat, stroke: CGFloat) -> some View {
        Capsule()
            .fill(Color.white)
            .frame(maxWidth: .infinity)
            .frame(height: stroke)
            .scaleEffect(x: width, y: 1)
    }
}

/// Keeps the shared snapshot that the system surfaces read up to date.
///
/// The snapshot is the *only* data source the iOS/iPadOS widgets have — they
/// run outside the app's container and can see nothing else. These call sites
/// used to be `#if os(tvOS)`, so on a phone the file was never written and the
/// Continue Watching widget could only ever be empty, however much the widget
/// itself was doing right. `AppleTopShelfWriter.notify()` has always reloaded
/// widget timelines on iOS, which is what gave the mismatch away.
///
/// It lives in its own modifier rather than inline on the root view: four more
/// modifiers on that body put the iOS type-checker over its limit.
///
/// Gated by the same "show in Apple services" toggle as the Top Shelf, because
/// a widget is exactly that kind of surface.
@MainActor
private struct AppleSystemSurfacePublishing: ViewModifier {
    let mediaIndex: AppleMediaIndexStore
    let catalogStore: AppleCatalogStore
    let sourceStore: AppleSourceStore
    let settingsStore: AppleSettingsStore

    func body(content: Content) -> some View {
        #if os(tvOS) || os(iOS) || os(visionOS)
        content
            .task {
                await mediaIndex.load()
                await publish(records: mediaIndex.records, sections: catalogStore.sections)
            }
            .onChange(of: mediaIndex.records) { _, records in
                Task { await publish(records: records, sections: catalogStore.sections) }
            }
            .onChange(of: catalogStore.sections) { _, sections in
                Task { await publish(records: mediaIndex.records, sections: sections) }
            }
            .onChange(of: sourceStore.sources) {
                Task { await publish(records: mediaIndex.records, sections: catalogStore.sections) }
            }
            .onChange(of: AppleLiveSystemChannels.shared.revision) {
                Task { await publish(records: mediaIndex.records, sections: catalogStore.sections) }
            }
            .onChange(of: settingsStore.topShelfEnabled) { _, enabled in
                Task {
                    await publish(records: mediaIndex.records,
                                  sections: catalogStore.sections, enabled: enabled)
                }
            }
        #else
        // macOS. The shared app group container works here now (the
        // entitlement was added and `AppleTopShelfSnapshotWriter.appGroup`
        // takes the team-id prefix it needs — see that file), but there is no
        // macOS widget or Top Shelf target, so nothing in the system would
        // read a snapshot written on this platform. This stays excluded on
        // purpose rather than by omission, which is what it was before; the
        // day a Mac widget target exists, delete this branch.
        content
        #endif
    }

    private func publish(
        records: [AppleMediaRecord],
        sections: [AppleCatalogSection],
        enabled: Bool? = nil
    ) async {
        await AppleTopShelfPublisher.shared.publish(
            records: records,
            sections: sections,
            sources: sourceStore.sources,
            enabled: enabled ?? settingsStore.topShelfEnabled
        )
    }
}

#if os(iOS)
private struct AppleSystemTabBarMinimization: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26, *), UIDevice.current.userInterfaceIdiom == .phone {
            content.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            content
        }
    }
}
#endif
