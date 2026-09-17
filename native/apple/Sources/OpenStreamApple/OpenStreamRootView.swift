import SwiftUI

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

/// Decides what a tab bar selection means. Re-selecting the tab that is
/// already showing pops that tab's navigation stack back to its root.
enum OpenStreamTabReselection {
    static func popsToRoot(current: OpenStreamTab, selected: OpenStreamTab) -> Bool {
        current == selected
    }
}

/// Decides whether the tab bar shows. The phone hides it in landscape so the
/// content fills the screen the way it does on iPad; portrait keeps it.
enum OpenStreamTabBarVisibility {
    static func isHidden(viewport: CGSize, horizontalSizeClassIsCompact: Bool) -> Bool {
        horizontalSizeClassIsCompact && AppleDetailMetrics.isLandscapeLayout(viewport: viewport)
    }
}

/// Native Apple app shell with one independent navigation stack per tab.
@MainActor
public struct OpenStreamRootView: View {
    @State private var selectedTab = OpenStreamTab.home
    @State private var navigationPaths: [OpenStreamTab: NavigationPath] = [:]
    @State private var rootResets: [OpenStreamTab: Int] = [:]
    @State private var rootViewportSize: CGSize = .zero
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @State private var sourceStore = AppleSourceStore()
    @State private var catalogStore = AppleCatalogStore()
    @State private var settingsStore = AppleSettingsStore()
    @State private var mediaIndex = AppleMediaIndexStore()
    private let router: AppleAppRouter
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
    /// every stock iOS app behaves.
    private var tabSelection: Binding<OpenStreamTab> {
        Binding(
            get: { selectedTab },
            set: { tab in
                #if os(iOS)
                if OpenStreamTabReselection.popsToRoot(current: selectedTab, selected: tab) {
                    navigationPaths[tab] = NavigationPath()
                    rootResets[tab, default: 0] += 1
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
                }
                .id(navigationIdentity(for: tab))
                .tabItem { Label(tab.title, systemImage: tab.systemImage) }
                .tag(tab)
                #elseif os(iOS)
                NavigationStack(path: Binding(
                    get: { navigationPaths[tab] ?? NavigationPath() },
                    set: { navigationPaths[tab] = $0 }
                )) {
                    content(for: tab)
                        .toolbar(tabBarIsHidden ? .hidden : .automatic, for: .tabBar)
                        .toolbarBackground(Color(white: 0.055), for: .tabBar)
                        .toolbarBackground(.visible, for: .tabBar)
                        .toolbarColorScheme(.dark, for: .tabBar)
                }
                .id(navigationIdentity(for: tab))
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
                .id(navigationIdentity(for: tab))
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
                #endif
            }
        }
        #if os(tvOS)
        // Owner (16:20): keep the stock top tab bar; the sidebar experiment
        // (X8) read as "the top bar is gone". The bar hides while scrolling.
        .onExitCommand(perform: exitCommandHandler(for: selectedTab))
        #endif
    }

    private var tabBarIsHidden: Bool {
        #if os(iOS)
        return OpenStreamTabBarVisibility.isHidden(
            viewport: rootViewportSize,
            horizontalSizeClassIsCompact: horizontalSizeClass == .compact
        )
        #else
        return false
        #endif
    }

    private func navigationIdentity(for tab: OpenStreamTab) -> String {
        let reset = rootResets[tab] ?? 0
        return tab == .home
            ? "home:\(router.revision):\(intentHandoff.revision):\(reset)"
            : "\(tab.rawValue):\(reset)"
    }

    public var body: some View {
        tabs
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
        #endif
        .appleTraceSelection("tab", value: selectedTab)
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { rootViewportSize = $0 }
        #if os(visionOS)
        .frame(minWidth: 760, minHeight: 540)
        .environment(\.defaultMinListRowHeight, 60)
        .scrollIndicators(AppleDesignTokens.scrollIndicatorVisibility)
        .defaultHoverEffect(.highlight)
        #endif
        #if DEBUG
        .task {
            AppleLaunchClock.begin()
            AppleInteractionTrace.begin()
            Task { await sourceStore.seedTestCatalogsIfNeeded() }
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
            else if screen != "discover" && screen != "detail" && screen != "episodes" && screen != "play" {
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
            await AppleLocalLibraryStore.shared.reload(sourceStore: sourceStore, mediaIndex: mediaIndex, settings: settingsStore)
        }
        .onChange(of: settingsStore.liveTVEnabled) { _, enabled in
            if !enabled { sharePlay.leave() }
        }
        // `initial: true` also covers launch, when a persisted toggle may
        // already hide the tab the view starts on.
        .onChange(of: visibleTabs, initial: true) { _, visible in
            selectedTab = OpenStreamTabVisibility.selection(current: selectedTab, visible: visible)
        }
        .task { sharePlay.startListening() }
        .onChange(of: sharePlay.revision) {
            if sharePlay.channel != nil { selectedTab = .live }
            else { selectedTab = OpenStreamTabVisibility.selection(current: selectedTab, visible: visibleTabs) }
        }
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
                    selectedTab = .settings
                    #if os(visionOS)
                    var path = NavigationPath()
                    path.append(AppleSettingsRoute.sources)
                    navigationPaths[.settings] = path
                    #endif
                    firstRunGuidanceSeen = true
                }
                    #if os(visionOS)
                    .frame(width: 560, height: 300)
                    #endif
            }
        }
        .onChange(of: router.revision) {
            guard let route = router.route else { return }
            Task { @MainActor in await apply(route) }
        }
        .onChange(of: intentHandoff.revision) {
            guard let route = intentHandoff.route else { return }
            Task { @MainActor in await apply(route) }
        }
        .task {
            if let route = intentHandoff.route { await apply(route) }
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
            mediaIndex: mediaIndex, catalogStore: catalogStore, settingsStore: settingsStore))
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

    @ViewBuilder
    private func content(for tab: OpenStreamTab) -> some View {
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
                router: router,
                settings: settingsStore,
                openSettings: { selectedTab = .settings }
            )
            .appleAlignedTabTitle(tab.title)
        case .library:
            AppleLibraryView(
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
                openSettings: { selectedTab = .settings }
            )
            .appleAlignedTabTitle(tab.title)
        case .settings:
            AppleSettingsView(
                settings: settingsStore,
                sourceStore: sourceStore,
                webManagement: webManagement
            )
            .appleAlignedTabTitle(tab.title)
        }
    }

    private func apply(_ route: AppleAppRoute) async {
        // Every route lands on Discover; when that tab is hidden, stay on the
        // first tab the bar still shows instead of selecting an absent one.
        let target = OpenStreamTabVisibility.selection(current: .home, visible: visibleTabs)
        switch route {
        case .search:
            // Apple TV has a Search tab; selecting it *is* the navigation.
            selectedTab = visibleTabs.contains(.search) ? .search : target
        case .media:
            selectedTab = target
        case .continueWatching:
            selectedTab = target
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
    private static let debugTopLevelSettingsRoutes: [String: AppleSettingsRoute] = [
        "channels": .channels,
        "playback-settings": .playback,
        "metadata": .metadata,
        "server-downloads": .serverDownloads,
        "trakt": .trakt,
        "watch-providers": .watchProviders,
        "privacy": .privacy,
        "storage": .storage,
        "about": .about,
    ]

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
            Text("Welcome to OpenStream")
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
            Spacer(minLength: 0)
            Button("Open Sources", action: openSettings)
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
            Text("Welcome to OpenStream")
                .font(.system(size: AppleTVChromeMetrics.pageHeaderFontSize, weight: .bold))
                .accessibilityAddTraits(.isHeader)
            // The same gap the billboard uses, which is wide enough that a
            // focused pill's ring and glow clear its neighbour.
            HStack(spacing: AppleTVBillboardMetrics.pillGap) {
                Button("Open Sources", action: openSettings)
                    .buttonStyle(.brandPrimary)
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
            .onChange(of: settingsStore.topShelfEnabled) { _, enabled in
                Task {
                    await publish(records: mediaIndex.records,
                                  sections: catalogStore.sections, enabled: enabled)
                }
            }
        #else
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
            enabled: enabled ?? settingsStore.topShelfEnabled
        )
    }
}
