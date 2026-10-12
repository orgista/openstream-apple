import SwiftUI

enum AppleSettingsRoute: Hashable {
    case sources
    case channels
    case restrictions
    case metadata
    case serverDownloads
    case trakt
    case watchProviders
    case discoverRows
    case playback
    case playbackInfo
    case subtitleLanguages
    case privacy
    case storage
    case about
    #if !os(tvOS)
    case backup
    #endif
}

extension View {
    /// Titles a settings page that can also sit inside the Apple TV split
    /// view's detail pane. Embedded, the header is drawn at the pane's leading
    /// edge and the rows run from it (no 560 pt centred column); everywhere
    /// else this is `appleSettingsPage`.
    @ViewBuilder
    func appleSettingsPane(_ title: String, embedded: Bool) -> some View {
        #if os(tvOS)
        if embedded {
            VStack(alignment: .leading, spacing: 0) {
                TVPageHeader(title: title)
                self
                    // `formColumnWidth`, the same width every standalone
                    // settings page uses — not `formMaximumWidth`. The Sources
                    // list reached through the split view was 1000 pt wide and
                    // the identical list pushed on its own was 900, so the same
                    // rows put their chevrons in two different places depending
                    // on how the viewer got there (2026-09-15 GUI audit).
                    .frame(maxWidth: AppleTVSettingsMetrics.standard.formColumnWidth, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .tint(.white)
                    .toggleStyle(.tvReadable)
            }
        } else {
            appleSettingsPage(title)
        }
        #else
        appleSettingsPage(title)
        #endif
    }
}

@MainActor
struct AppleSettingsView: View {
    let settings: AppleSettingsStore
    let sourceStore: AppleSourceStore
    let webManagement: any AppleWebManagementServing
    var backupController: AppleConfigurationController? = nil
    var catalogStore: AppleCatalogStore? = nil
    /// Set on a regular-width iPad in landscape: Settings draws its own split
    /// view, sections on the left and the chosen page on the right, with this
    /// as the right column's stack. Nil pushes everything on one stack.
    var splitPath: Binding<NavigationPath>? = nil
    @State private var splitSelection: AppleSettingsRoute = .sources
    #if os(iOS)
    @State private var showsSendSetup = false
    #endif

    var body: some View {
        settingsContent.modifier(AppleSettingsPINLock())
    }

    @ViewBuilder private var settingsContent: some View {
        #if os(tvOS)
        AppleTVSettingsSplitView(settings: settings, sourceStore: sourceStore, webManagement: webManagement)
            .navigationDestination(for: AppleSettingsRoute.self) { route in
                destination(for: route)
            }
        #else
        if let splitPath {
            NavigationSplitView {
                rootForm
            } detail: {
                NavigationStack(path: splitPath) {
                    destination(for: splitSelection)
                        .navigationDestination(for: AppleSettingsRoute.self) { route in
                            destination(for: route)
                        }
                }
            }
            .navigationSplitViewStyle(.balanced)
        } else {
            rootForm
                .navigationDestination(for: AppleSettingsRoute.self) { route in
                    destination(for: route)
                }
        }
        #endif
    }

    #if !os(tvOS)
    /// A row that opens a settings page: pushed on the stack, or shown in the
    /// split view's right column with the row marked as the one showing.
    @ViewBuilder
    private func settingsLink<Label: View>(_ route: AppleSettingsRoute, @ViewBuilder label: () -> Label) -> some View {
        if let splitPath {
            let isSelected = splitSelection == route
            Button {
                splitSelection = route
                splitPath.wrappedValue = NavigationPath()
            } label: {
                label()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .foregroundStyle(.primary)
            .listRowBackground(isSelected ? Color.secondary.opacity(0.3) : nil)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        } else {
            NavigationLink(value: route, label: label)
        }
    }
    #endif

    @ViewBuilder
    private func destination(for route: AppleSettingsRoute) -> some View {
        switch route {
        case .sources:
            AppleSourcesSettingsView(
                sourceStore: sourceStore,
                settings: settings,
                webManagement: webManagement
            )
        case .channels:
            AppleChannelManagerView(settings: settings, sourceStore: sourceStore)
        case .restrictions:
            AppleRestrictionsView(sourceStore: sourceStore)
        case .metadata:
            AppleMetadataSettingsView(settings: settings)
        case .serverDownloads:
            AppleServerDownloadsSettingsView(settings: settings)
        case .trakt:
            AppleTraktSettingsView(settings: settings)
        case .watchProviders:
            AppleWatchProviderSettingsView(settings: settings)
        case .discoverRows:
            AppleDiscoverRowsSettingsView(settings: settings, sourceStore: sourceStore, catalogStore: catalogStore)
        case .playback:
            ApplePlaybackSettingsView(settings: settings)
        case .playbackInfo:
            ApplePlaybackInfoView(settings: settings)
        case .subtitleLanguages:
            AppleSubtitleLanguagesView(settings: settings)
        case .privacy:
            ApplePrivacySettingsView(settings: settings)
        case .storage:
            AppleStorageSettingsView()
        case .about:
            AppleAboutView()
        #if !os(tvOS)
        case .backup:
            if let backupController { AppleBackupSettingsView(controller: backupController) }
        #endif
        }
    }

    #if !os(tvOS)
    private var rootForm: some View {
        @Bindable var settings = settings

        return Form {
            ForEach(AppleSettingsRootEntry.leadingSections, id: \.self) { entries in
                Section {
                    ForEach(entries, id: \.self) { entry in
                        settingsLink(entry.route) {
                            AppleTVNavigationLabel(entry.title, systemImage: entry.systemImage)
                        }
                        .appleTVReadableFocus()
                    }
                    if entries.contains(.backup) {
                        setupTransferRows
                    }
                }
            }

            Section("Discover") {
                Toggle("Show Discover tab", isOn: $settings.discoverEnabled)
                    .disabled(!appleCanToggleTab(.home, settings: settings))
                    .accessibilityIdentifier("settings.discover.enabled")
                Toggle("Top 10 lists", isOn: $settings.top10ListsEnabled)
                settingsLink(AppleSettingsRoute.discoverRows) {
                    AppleTVNavigationLabel("Discover Rows")
                }
                .appleTVReadableFocus()
                .accessibilityIdentifier("settings.discover.rows")
            }

            Section("Library") {
                Toggle("Show Library tab", isOn: $settings.libraryEnabled)
                    .disabled(!appleCanToggleTab(.library, settings: settings))
                    .accessibilityIdentifier("settings.library.enabled")
            }

            Section("Live TV") {
                AppleLiveResumeSetting()
                Toggle("Show Live tab", isOn: $settings.liveTVEnabled)
                    .disabled(!appleCanToggleTab(.live, settings: settings))
                    .accessibilityIdentifier("settings.live.enabled")
                AppleChannelHealthSettingsRows(store: .shared, settings: settings, sourceStore: sourceStore)
            }

            Section("Services") {
                settingsLink(AppleSettingsRoute.metadata) {
                    AppleTVNavigationLabel("Metadata", systemImage: "photo.on.rectangle.angled")
                }
                .appleTVReadableFocus()
                settingsLink(AppleSettingsRoute.watchProviders) {
                    AppleTVNavigationLabel("Streaming Services", systemImage: "rectangle.stack.badge.play")
                }
                .appleTVReadableFocus()
                settingsLink(AppleSettingsRoute.serverDownloads) {
                    AppleTVNavigationLabel("Radarr & Sonarr", systemImage: "arrow.down.circle")
                }
                .appleTVReadableFocus()
                settingsLink(AppleSettingsRoute.trakt) {
                    AppleTVNavigationLabel("Trakt", systemImage: "arrow.triangle.2.circlepath")
                }
                .appleTVReadableFocus()
            }

            Section("Playback") {
                settingsLink(AppleSettingsRoute.playback) {
                    AppleTVNavigationLabel("Playback", systemImage: "play.circle")
                }
                .appleTVReadableFocus()
            }

            Section("Privacy") {
                settingsLink(AppleSettingsRoute.privacy) {
                    AppleTVNavigationLabel("Privacy", systemImage: "hand.raised")
                }
                .appleTVReadableFocus()
            }

            Section {
                settingsLink(AppleSettingsRoute.storage) {
                    AppleTVNavigationLabel("Storage", systemImage: "internaldrive")
                }
                .appleTVReadableFocus()
                settingsLink(AppleSettingsRoute.about) {
                    AppleTVNavigationLabel("About", systemImage: "info.circle")
                }
                .appleTVReadableFocus()
            }
        }
        .appleSettingsContent()
        #if os(iOS)
        .alert("Open the Camera", isPresented: $showsSendSetup) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Point it at the code on the other device.")
        }
        #endif
    }

    /// Set Up from iPhone, both ends, beside Backup & Sync (owner 2026-10-09:
    /// "can't find where to scan a QR code"); before this they were only
    /// under Sources and at the bottom of Backup & Sync.
    @ViewBuilder
    private var setupTransferRows: some View {
        Button {
            AppleSetupTransferCenter.shared.presentReceiver()
        } label: {
            AppleTVNavigationLabel(AppleSetupTransferDevice.receiveTitle, systemImage: "qrcode")
        }
        .foregroundStyle(.primary)
        .accessibilityIdentifier("settings.setupFromPhone")
        #if os(iOS)
        Button {
            showsSendSetup = true
        } label: {
            AppleTVNavigationLabel("Send Setup to Another Device", systemImage: "iphone.and.arrow.forward")
        }
        .foregroundStyle(.primary)
        .accessibilityIdentifier("settings.sendSetup")
        #endif
    }
    #endif
}

#if !os(tvOS)
private extension AppleSettingsRootEntry {
    var route: AppleSettingsRoute {
        switch self {
        case .sources: .sources
        case .channels: .channels
        case .restrictions: .restrictions
        case .backup: .backup
        }
    }
}
#endif

/// The last content tab still on cannot be switched off, so its toggle goes
/// inert rather than leaving the bar with Settings alone. Every other toggle
/// stays live — including one that is already off, which is the half this used
/// to get wrong.
@MainActor
private func appleCanToggleTab(_ tab: OpenStreamTab, settings: AppleSettingsStore) -> Bool {
    OpenStreamTabVisibility.canToggle(
        tab,
        discover: settings.discoverEnabled,
        library: settings.libraryEnabled,
        live: settings.liveTVEnabled
    )
}

#if os(tvOS)
/// Apple TV Settings as a split layout (rework plan task 7): the sections
/// list on the left at the 80 pt inset, the selected section's form on the
/// right. Focus on a row selects it, so scrolling the list previews each
/// pane the way the stock TV app's sidebar does; deeper pages (Add Live TV,
/// a source's detail) still push over the whole screen and Menu pops back.
@MainActor
private struct AppleTVSettingsSplitView: View {
    let settings: AppleSettingsStore
    let sourceStore: AppleSourceStore
    let webManagement: any AppleWebManagementServing

    @State private var selection = AppleTVSettingsSection.defaultSelection
    #if DEBUG
    /// `defaults write com.orgista.openstream OpenStreamSettingsPane -string privacy`
    /// opens that pane directly. The split view always starts on Sources and
    /// the other eight panes need the remote to reach, so without this they
    /// cannot be reviewed on the simulator at all. Simulator-only, like the
    /// other review hooks.
    private var debugPane: AppleTVSettingsSection? {
        UserDefaults.standard.string(forKey: "OpenStreamSettingsPane")
            .flatMap(AppleTVSettingsSection.init(rawValue:))
    }
    #endif
    @FocusState private var focusedSection: AppleTVSettingsSection?
    private let metrics = AppleTVSettingsMetrics.standard

    var body: some View {
        HStack(alignment: .top, spacing: metrics.columnSpacing) {
            sidebar
                .frame(width: metrics.sidebarWidth)
                .frame(maxHeight: .infinity, alignment: .top)
                .focusSection()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .focusSection()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .defaultFocus($focusedSection, AppleTVSettingsSection.defaultSelection)
        .onChange(of: focusedSection) { _, focused in
            if let focused { selection = focused }
        }
        #if DEBUG
        .task {
            // Runs after `defaultFocus`, so the review pane is not immediately
            // overwritten by focus landing on Sources.
            guard let debugPane else { return }
            try? await Task.sleep(for: .milliseconds(300))
            selection = debugPane
        }
        #endif
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: metrics.rowSpacing) {
            ForEach(AppleTVSettingsSection.allCases) { section in
                Button {
                    selection = section
                } label: {
                    HStack(spacing: metrics.iconSpacing) {
                        Image(systemName: section.systemImage)
                            .font(.body)
                            .frame(width: metrics.iconColumnWidth)
                            .accessibilityHidden(true)
                        Text(section.title)
                            .font(.body)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, metrics.rowHorizontalPadding)
                    .frame(height: metrics.rowHeight)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(AppleTVSettingsRowStyle(isSelected: selection == section, cornerRadius: metrics.rowCornerRadius))
                .focused($focusedSection, equals: section)
                .accessibilityIdentifier("settings.section.\(section.rawValue)")
                .accessibilityAddTraits(selection == section ? .isSelected : [])
            }
        }
        .padding(.top, AppleTVChromeMetrics.pageHeaderTopInset)
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .sources:
            AppleSourcesSettingsView(
                sourceStore: sourceStore,
                settings: settings,
                webManagement: webManagement,
                embeddedInSplit: true
            )
        case .channels:
            AppleChannelManagerView(settings: settings, sourceStore: sourceStore, embeddedInSplit: true)
        case .restrictions:
            AppleRestrictionsView(sourceStore: sourceStore, embeddedInSplit: true)
        case .liveTV:
            AppleTVLiveTabPane(settings: settings, sourceStore: sourceStore, webManagement: webManagement)
        case .discover:
            AppleTVDiscoverPane(settings: settings)
        case .services:
            AppleTVServicesPane(settings: settings)
        case .playback:
            ApplePlaybackSettingsView(settings: settings, embeddedInSplit: true)
        case .privacy:
            ApplePrivacySettingsView(settings: settings, embeddedInSplit: true)
        case .storage:
            AppleStorageSettingsView(embeddedInSplit: true)
        case .about:
            AppleAboutView(embeddedInSplit: true)
        }
    }
}

/// A sections-list row: a stable dark container when unfocused, a lighter one
/// for the selected section, white with black text when focused. No inner
/// chrome and nothing blue.
struct AppleTVSettingsRowStyle: ButtonStyle {
    var isSelected: Bool
    var cornerRadius: CGFloat = AppleTVSettingsMetrics.standard.rowCornerRadius

    func makeBody(configuration: Configuration) -> some View {
        StyledBody(configuration: configuration, isSelected: isSelected, cornerRadius: cornerRadius)
    }

    private struct StyledBody: View {
        @Environment(\.isFocused) private var isFocused
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        let configuration: ButtonStyleConfiguration
        let isSelected: Bool
        let cornerRadius: CGFloat

        var body: some View {
            configuration.label
                .foregroundStyle(isFocused ? Color.black : Color.white)
                .background(fill, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .scaleEffect(reduceMotion ? 1 : (isFocused ? 1.03 : 1))
                .opacity(configuration.isPressed ? 0.8 : 1)
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isFocused)
        }

        private var fill: Color {
            if isFocused { return .white }
            if isSelected { return Color.white.opacity(0.2) }
            return AppleDesignTokens.surface
        }
    }
}

@MainActor
private struct AppleTVLiveTabPane: View {
    let settings: AppleSettingsStore
    let sourceStore: AppleSourceStore
    let webManagement: any AppleWebManagementServing

    var body: some View {
        @Bindable var settings = settings

        return Form {
            AppleLiveResumeSetting()
            Toggle("Show Live tab", isOn: $settings.liveTVEnabled)
                .disabled(!appleCanToggleTab(.live, settings: settings))
                .accessibilityIdentifier("settings.live.enabled")
            Section {
                AppleChannelHealthSettingsRows(store: .shared, settings: settings, sourceStore: sourceStore,
                    webManagement: webManagement)
            }
        }
        .appleSettingsPane("Live TV", embedded: true)
    }
}

@MainActor
private struct AppleTVDiscoverPane: View {
    let settings: AppleSettingsStore

    var body: some View {
        @Bindable var settings = settings

        return Form {
            Section("Discover") {
                Toggle("Show Discover tab", isOn: $settings.discoverEnabled)
                    .disabled(!appleCanToggleTab(.home, settings: settings))
                    .accessibilityIdentifier("settings.discover.enabled")
                Toggle("Top 10 lists", isOn: $settings.top10ListsEnabled)
                NavigationLink(value: AppleSettingsRoute.discoverRows) {
                    AppleTVNavigationLabel("Discover Rows")
                }
                .appleTVReadableFocus()
                .accessibilityIdentifier("settings.discover.rows")
            }

            Section("Library") {
                Toggle("Show Library tab", isOn: $settings.libraryEnabled)
                    .disabled(!appleCanToggleTab(.library, settings: settings))
                    .accessibilityIdentifier("settings.library.enabled")
            }
        }
        .appleSettingsPane("Discover", embedded: true)
    }
}

private struct AppleTVServicesPane: View {
    let settings: AppleSettingsStore

    var body: some View {
        Form {
            NavigationLink(value: AppleSettingsRoute.metadata) {
                AppleTVNavigationLabel("Metadata", systemImage: "photo.on.rectangle.angled")
            }
            NavigationLink(value: AppleSettingsRoute.watchProviders) {
                AppleTVNavigationLabel("Streaming Services", systemImage: "rectangle.stack.badge.play")
            }
            NavigationLink(value: AppleSettingsRoute.serverDownloads) {
                AppleTVNavigationLabel("Radarr & Sonarr", systemImage: "arrow.down.circle")
            }
            NavigationLink(value: AppleSettingsRoute.trakt) {
                AppleTVNavigationLabel("Trakt", systemImage: "arrow.triangle.2.circlepath")
            }
        }
        .appleSettingsPane("Services", embedded: true)
    }
}
#endif

@MainActor
private struct AppleChannelManagerView: View {
    let settings: AppleSettingsStore
    let sourceStore: AppleSourceStore
    var embeddedInSplit = false

    @State private var channels: [AppleIPTVChannel] = []
    @State private var filteredChannels: [AppleIPTVChannel] = []
    @State private var customSelectedIDs = Set<String>()
    @State private var channelsRevision = 0
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var query = ""
    @State private var completeGuide: [AppleChannelLineupEntry] = []
    @State private var lineupIndex = AppleChannelLineupIndex([])
    private let client = AppleIPTVClient()

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("Channel Preferences") {
                #if os(tvOS)
                // The stock Picker pushed an empty page here (AppleTVChoicePicker).
                AppleTVChoicePicker("Package", selection: $settings.liveChannelPackage,
                                    options: AppleLiveChannelPackage.available.map { .init(value: $0, title: $0.title) })
                AppleTVChoicePicker("Live view", selection: $settings.liveChannelScope,
                                    options: AppleLiveChannelScope.allCases.map { .init(value: $0, title: $0.title) })
                #else
                Picker("Package", selection: $settings.liveChannelPackage) {
                    ForEach(AppleLiveChannelPackage.available) { package in
                        Text(package.title).tag(package)
                    }
                }

                Picker("Live view", selection: $settings.liveChannelScope) {
                    ForEach(AppleLiveChannelScope.allCases) { scope in
                        Text(scope.title).tag(scope)
                    }
                }
                #endif

                Toggle("Show Pay-Per-View", isOn: $settings.showPayPerViewChannels)
                Toggle("Show 24/7 channels", isOn: $settings.show24x7Channels)
            }

            AppleLiveChannelPreferencesSection(channels: channels, settings: settings)

            if settings.liveChannelPackage == .custom {
                Section("Custom Package") {
                    Toggle("Include West feeds", isOn: $settings.customChannelPackage.includeWestFeeds)
                    ForEach(Array(Set(channels.map(\.group))).filter { !$0.isEmpty }.sorted(), id: \.self) { group in
                        Toggle(group, isOn: Binding(
                            get: { settings.customChannelPackage.groups[group] ?? true },
                            set: { settings.customChannelPackage.groups[group] = $0 }
                        ))
                    }
                }
            }
            #if os(tvOS)
            // These two are rows rather than toolbar items: a tvOS toolbar item
            // always draws a box around its glyph (the T4/R1 defect). They sit
            // in their own section — putting them at the head of the channel
            // list moved focus to the tab bar and left the Settings pill drawn
            // without its icon and overflowing the bar (measured 2026-09-16).
            Section {
                Button {
                    Task { await reload() }
                } label: {
                    AppleTVNavigationLabel("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading)
            }
            #endif
            // Owner, 2026-09-17: a 3,000-row wall of toggles is not a way to
            // pick channels. The list holds only what is selected; adding goes
            // through a searchable picker.
            Section(settings.liveChannelPackage == .custom ? "Custom Channels" : "My Channels") {
                if isLoading, channels.isEmpty {
                    ProgressView()
                } else if channels.isEmpty {
                    Text(errorMessage ?? emptyLineupMessage)
                        #if os(tvOS)
                        // A fixed grey, not the hierarchical `.secondary`: in
                        // this tvOS form the message row drew as an empty
                        // capsule (Apple TV verification 2026-10-01).
                        .foregroundStyle(Color.white.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)
                        #else
                        .foregroundStyle(.secondary)
                        #endif
                        .accessibilityIdentifier("channels.empty")
                    if errorMessage != nil {
                        Button {
                            Task { await reload() }
                        } label: {
                            #if os(tvOS)
                            AppleTVFocusReadableText("Retry")
                            #else
                            Text("Retry")
                            #endif
                        }
                        .accessibilityIdentifier("channels.retry")
                    }
                } else {
                    NavigationLink {
                        channelPicker
                    } label: {
                        Label("Add Channels…", systemImage: "plus.circle")
                    }
                    .accessibilityIdentifier("channels.add")
                    if let errorMessage {
                        Text(errorMessage).font(.caption).foregroundStyle(.red)
                    }
                    ForEach(selectedChannels) { channel in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(displayName(for: channel)).foregroundStyle(.primary)
                                if !channel.group.isEmpty {
                                    Text(channel.group).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 8)
                            #if os(tvOS)
                            Button { toggle(channel.id) } label: { AppleTVFocusReadableText("Remove") }
                            #else
                            Button { toggle(channel.id) } label: {
                                Image(systemName: "minus.circle").foregroundStyle(.secondary)
                                    .frame(minWidth: 44, minHeight: 44)
                                    .contentShape(.rect)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove \(channel.name)")
                            #endif
                        }
                    }
                    #if !os(tvOS)
                    .onDelete { offsets in
                        for channel in offsets.map({ selectedChannels[$0] }) { toggle(channel.id) }
                    }
                    #endif
                }
            }
        }
        .appleSettingsPane("Channel Manager", embedded: embeddedInSplit)
        // tvOS toolbar items always draw a box around the glyph, which is the
        // same defect the owner called on Discover (T4) and Search (R1).
        // On a television these two actions are rows in the form instead.
        #if !os(tvOS)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await reload() } } label: {
                    // The glyph gives way to the spinner while the lineup is
                    // being fetched. Dimming alone was the only answer this
                    // button gave, and against a playlist held on disk the
                    // fetch is over before the dimming is drawn, so the press
                    // read as dead (button crawl, 2026-09-19).
                    if isLoading {
                        ProgressView()
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(isLoading)
            }
        }
        #endif
        .task(id: sourceIdentity) { await reload(); completeGuide = (try? AppleChannelLineupPresets.completeUS()) ?? []; lineupIndex = AppleChannelLineupIndex(completeGuide) }
        .task(id: projectionIdentity) { await rebuildFilteredChannels() }
    }

    private var sourceIdentity: String {
        ApplePlaybackIdentity.digest(for: sourceStore.sources
            .filter { $0.kind == .liveTV }
            .map { "\($0.id.uuidString)|\($0.configurationRevision)|\($0.isEnabled)" }
            .joined(separator: "\u{1f}"))
    }

    private var projectionIdentity: String {
        "\(settings.liveChannelPackage.rawValue)\u{1f}\(settings.customChannelPackage.identity)\u{1f}\(channelsRevision)\u{1f}\(query)\u{1f}\(settings.liveChannelScope.rawValue)\u{1f}\(settings.regionalZIPCode)\u{1f}\(settings.showPayPerViewChannels)\u{1f}\(settings.show24x7Channels)\u{1f}\(settings.favoriteChannelIDs.sorted().joined(separator: "\u{1f}"))"
    }

    private func rebuildFilteredChannels() async {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !clean.isEmpty {
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
        }
        let updated = await AppleChannelProjection.buildMatchesOffMain(
            from: AppleChannelVisibilityPolicy.visibleChannels(
                from: channels,
                scope: settings.liveChannelScope,
                showPayPerView: settings.showPayPerViewChannels,
                favoriteIDs: settings.favoriteChannelIDs,
                show24x7: settings.show24x7Channels
            ),
            query: clean
        )
        guard !Task.isCancelled else { return }
        filteredChannels = updated
        customSelectedIDs = Set(settings.customChannelPackage.selected(from: channels).map(\.id))
    }

    private func isSelected(_ id: String) -> Bool {
        settings.liveChannelPackage == .custom ? customSelectedIDs.contains(id) : settings.favoriteChannelIDs.contains(id)
    }

    private func toggle(_ id: String) {
        if settings.liveChannelPackage == .custom {
            let adding = !customSelectedIDs.contains(id)
            // Owner, 2026-09-17: past 300 the guide will not draw it, so do not
            // let the list be built past what can be shown — say so instead.
            if adding, !AppleLiveChannelSnapshot.canAddChannel(toSelectionOf: customSelectedIDs.count) {
                errorMessage = AppleLiveChannelSnapshot.limitReachedMessage
                return
            }
            errorMessage = nil
            settings.customChannelPackage.channels[id] = adding
            return
        }
        var values = settings.favoriteChannelIDs
        if values.contains(id) {
            values.remove(id)
        } else {
            guard AppleLiveChannelSnapshot.canAddChannel(toSelectionOf: values.count) else {
                errorMessage = AppleLiveChannelSnapshot.limitReachedMessage
                return
            }
            values.insert(id)
        }
        errorMessage = nil
        settings.favoriteChannelIDs = values
    }

    /// "Add a source" is wrong when one exists but is switched off.
    private var emptyLineupMessage: String {
        let live = sourceStore.sources.filter { $0.kind == .liveTV }
        if live.isEmpty { return "Add a Live TV source first." }
        return live.contains(where: \.isEnabled) ? "No channels yet." : "Your Live TV source is turned off."
    }

    private var selectedChannels: [AppleIPTVChannel] {
        numberedChannels.filter { isSelected($0.id) }
    }

    /// The whole (filtered) lineup, grouped by the provider's groups, or a
    /// flat result list while searching. Rows add with ⊕ and show ✓ once in.
    private var channelPicker: some View {
        Form {
            #if os(tvOS)
            Section {
                NavigationLink {
                    AppleTVChannelSearchEditor(query: $query)
                } label: {
                    AppleTVNavigationLabel(query.isEmpty ? "Search Channels" : "Search · \(query)", systemImage: "magnifyingglass")
                }
            }
            #endif
            if let errorMessage {
                Section { Text(errorMessage).font(.caption).foregroundStyle(.red) }
            }
            ForEach(AppleChannelPickerSections.build(channels: numberedChannels, query: query)) { section in
                Section(section.name) {
                    ForEach(section.channels) { channel in
                        Button {
                            toggle(channel.id)
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(displayName(for: channel)).foregroundStyle(.primary)
                                    if !query.isEmpty, !channel.group.isEmpty {
                                        Text(channel.group).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 8)
                                Image(systemName: isSelected(channel.id) ? "checkmark.circle.fill" : "plus.circle")
                                    .foregroundStyle(isSelected(channel.id) ? Color.primary : Color.secondary)
                            }
                        }
                        .accessibilityLabel(channel.name)
                        .accessibilityValue(isSelected(channel.id) ? "Included" : "Not included")
                    }
                }
            }
        }
        .appleSettingsPage("Add Channels")
        // The manager's own `task(id:)` sleeps while it is covered by this
        // page, so the query has to drive the projection from here too.
        .task(id: projectionIdentity) { await rebuildFilteredChannels() }
        // Always-visible field: an inline-title page otherwise hides the
        // search bar until the list is pulled down, which nobody discovers.
        #if os(iOS)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Channels")
        #elseif !os(tvOS)
        .searchable(text: $query, prompt: "Channels")
        #endif
    }

    private var numberedChannels: [AppleIPTVChannel] {
        AppleGuideChannelProjection.rows(channels: filteredChannels, entries: completeGuide,
            favoriteIDs: [], favoritesOnly: false, sortByNumber: true).map(\.channel)
    }

    private func displayName(for channel: AppleIPTVChannel) -> String {
        guard let entry = lineupIndex.match(channel.name) else {
            return channel.name
        }
        return "\(entry.number) · \(channel.name)"
    }

    private func reload() async {
        let sources = sourceStore.sources.filter { $0.kind == .liveTV && $0.isEnabled }
        guard !sources.isEmpty else {
            settings.updateAutomaticLiveChannelPackage(channels: [])
            channels = []
            filteredChannels = []
            channelsRevision &+= 1
            errorMessage = nil
            return
        }
        // The saved lineup goes up at once, as on the Live tab: with the
        // panel down, My Channels spun until the deadline (Apple TV
        // regression 2026-10-01). A dead Xtream panel now fails its login
        // probe in `AppleIPTVClient.accountProbeTimeout` and says so.
        if channels.isEmpty {
            var cached: [AppleIPTVChannel] = []
            for source in sources {
                cached += await AppleIPTVChannelCache.shared.snapshot(for: source.id)?.channels ?? []
            }
            if !cached.isEmpty {
                settings.updateAutomaticLiveChannelPackage(channels: cached)
                channels = cached
                channelsRevision &+= 1
            }
        }
        isLoading = true
        let started = ContinuousClock.now
        defer { isLoading = false }
        var loaded: [AppleIPTVChannel] = []
        var errors: [String] = []
        for source in sources {
            do {
                let credentials = try sourceStore.iptvCredentials(for: source)
                let client = client
                // A panel that is down can hold the request open well past
                // its idle timeout; My Channels then spun for good (full test
                // 2026-10-01). Each source gets a deadline, then says so.
                loaded += try await AppleChannelManagerLoad.withDeadline(AppleChannelManagerLoad.deadline) {
                    try await client.channels(source: source, credentials: credentials)
                }
            } catch is CancellationError {
                return
            } catch {
                errors.append(AppleChannelManagerLoad.message(sourceName: source.name, error: error))
                // Its saved copy stays, with the error under it.
                loaded += await AppleIPTVChannelCache.shared.snapshot(for: source.id)?.channels ?? []
            }
        }
        settings.updateAutomaticLiveChannelPackage(channels: loaded)
        channels = loaded
        channelsRevision &+= 1
        errorMessage = errors.first
        try? await Task.sleep(for: AppleProgressVisibility.remaining(since: started))
    }
}

@MainActor
private struct AppleMetadataSettingsView: View {
    private enum Field: Hashable { case tmdb, omdb }
    private static let chain: [Field] = [.tmdb, .omdb]
    @FocusState private var focusedField: Field?

    let settings: AppleSettingsStore

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section {
                Toggle("Use Metadata APIs", isOn: $settings.metadataEnabled)
            }

            Section {
                SecureField("API key or read token", text: $settings.tmdbAPIKey)
                    .disabled(!settings.metadataEnabled)
                    .appleFormSubmit(.tmdb, chain: Self.chain, focus: $focusedField)
            } header: {
                // TMDB's credit lives once, in About (owner 2026-10-08: no notices around the app).
                Text("TMDB")
            }

            Section("OMDb") {
                SecureField("API key", text: $settings.omdbAPIKey)
                    .disabled(!settings.metadataEnabled)
                    .appleFormSubmit(.omdb, chain: Self.chain, focus: $focusedField)
            }

            AppleSettingsPersistenceError(settings: settings)
        }
        .appleSettingsPage("Metadata")
    }
}

@MainActor
struct AppleServerDownloadsSettingsView: View {
    let settings: AppleSettingsStore

    var body: some View {
        @Bindable var settings = settings

        Form {
            AppleArrConnectionSection(
                kind: .radarr,
                baseURL: $settings.radarrURL,
                apiKey: $settings.radarrAPIKey,
                rootFolderPath: $settings.radarrRootFolderPath,
                qualityProfileID: $settings.radarrQualityProfileID
            )

            AppleArrConnectionSection(
                kind: .sonarr,
                baseURL: $settings.sonarrURL,
                apiKey: $settings.sonarrAPIKey,
                rootFolderPath: $settings.sonarrRootFolderPath,
                qualityProfileID: $settings.sonarrQualityProfileID
            )

            AppleSettingsPersistenceError(settings: settings)
        }
        .appleSettingsPage("Radarr & Sonarr")
    }
}

@MainActor
private struct AppleArrConnectionSection: View {
    /// Quality profile is last on purpose: it uses the number pad, which has
    /// no return key at all, so it can be arrived at but never submitted from.
    private enum Field: Hashable { case baseURL, apiKey, rootFolder, qualityProfile }
    private static let chain: [Field] = [.baseURL, .apiKey, .rootFolder, .qualityProfile]
    @FocusState private var focusedField: Field?

    let kind: AppleArrKind
    @Binding var baseURL: String
    @Binding var apiKey: String
    @Binding var rootFolderPath: String
    @Binding var qualityProfileID: String

    private let client: AppleArrClient
    @State private var state = AppleConnectionTestState.idle

    init(
        kind: AppleArrKind,
        baseURL: Binding<String>,
        apiKey: Binding<String>,
        rootFolderPath: Binding<String>,
        qualityProfileID: Binding<String>,
        client: AppleArrClient = AppleArrClient()
    ) {
        self.kind = kind
        _baseURL = baseURL
        _apiKey = apiKey
        _rootFolderPath = rootFolderPath
        _qualityProfileID = qualityProfileID
        self.client = client
    }

    var body: some View {
        Group {
            #if os(macOS)
            Section {
                fields
            } header: {
                Text(kind.displayName)
            } footer: {
                AppleFormActionBar { testButton }
            }
            #else
            Section(kind.displayName) {
                fields
                testButton
                    // The list row draws its own capsule and `.brandSecondary` draws a
                    // pill inside it — a box in a box, which is the "no boxes and
                    // weirdness" the owner called out for the settings panes
                    // (2026-09-16). One piece of chrome, not two. Confirmed on the
                    // phone as well as the television (2026-09-17), so it is not
                    // platform-gated.
                    .listRowBackground(Color.clear)
            }
            #endif
        }
        .onChange(of: baseURL) { _, _ in state = .idle }
        .onChange(of: apiKey) { _, _ in state = .idle }
        .onChange(of: rootFolderPath) { _, _ in state = .idle }
        .onChange(of: qualityProfileID) { _, _ in state = .idle }
    }

    /// The prompt colour the other add-source forms use: the default
    /// placeholder was fainter here, and the empty API key row read as blank
    /// (UX tour 2026-10-08).
    private static func prompt(_ title: String) -> Text {
        #if os(iOS)
        Text(title).foregroundStyle(Color(uiColor: .secondaryLabel))
        #else
        Text(title).foregroundStyle(.secondary)
        #endif
    }

    @ViewBuilder
    private var fields: some View {
        TextField("Server URL", text: $baseURL, prompt: Self.prompt("Server URL"))
            .autocorrectionDisabled()
            #if os(iOS) || os(visionOS)
            .keyboardType(.URL)
            .textContentType(.URL)
            #endif
            .tint(.primary)
            .appleFormSubmit(.baseURL, chain: Self.chain, focus: $focusedField)
        SecureField("API key", text: $apiKey, prompt: Self.prompt("API key"))
            .textContentType(.password)
            .appleFormSubmit(.apiKey, chain: Self.chain, focus: $focusedField)
        TextField("Root folder path", text: $rootFolderPath, prompt: Self.prompt("Root folder path"))
            .autocorrectionDisabled()
            .appleFormSubmit(.rootFolder, chain: Self.chain, focus: $focusedField)
        TextField("Quality profile ID", text: $qualityProfileID, prompt: Self.prompt("Quality profile ID"))
            #if os(iOS)
            .keyboardType(.numberPad)
            #endif
            .appleFormSubmit(.qualityProfile, chain: Self.chain, focus: $focusedField)

        AppleConnectionStatusView(state: state)
    }

    private var testButton: some View {
        Button {
            Task { await testConnection() }
        } label: {
            AppleConnectionTestLabel(isTesting: state.isTesting)
        }
        .buttonStyle(.brandSecondary)
        .disabled(!canTest || state.isTesting)
    }

    private var canTest: Bool {
        AppleArrEndpointPolicy.isAllowed(baseURL) && AppleArrClient.isValidAPIKey(apiKey)
    }

    private func testConnection() async {
        let submittedURL = baseURL
        let submittedAPIKey = apiKey
        state = .testing

        do {
            let status = try await client.test(kind: kind, baseURL: submittedURL, apiKey: submittedAPIKey)
            guard baseURL == submittedURL, apiKey == submittedAPIKey else { return }
            state = .success(connectionLabel(for: status))
        } catch is CancellationError {
            guard baseURL == submittedURL, apiKey == submittedAPIKey else { return }
            state = .idle
        } catch {
            guard baseURL == submittedURL, apiKey == submittedAPIKey else { return }
            state = .failure(error.localizedDescription)
        }
    }

    private func connectionLabel(for status: AppleArrStatus) -> String {
        var parts = ["Connected", status.appName]
        if !status.version.isEmpty { parts.append(status.version) }
        if !status.instanceName.isEmpty { parts.append(status.instanceName) }
        return parts.joined(separator: " · ")
    }
}

@MainActor
private struct AppleTraktSettingsView: View {
    private enum Field: Hashable { case clientID, clientSecret }
    private static let chain: [Field] = [.clientID, .clientSecret]
    @FocusState private var focusedField: Field?

    let settings: AppleSettingsStore

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("Client Credentials") {
                SecureField("Client ID", text: $settings.traktClientID)
                    .appleFormSubmit(.clientID, chain: Self.chain, focus: $focusedField)
                SecureField("Client secret", text: $settings.traktClientSecret)
                    .appleFormSubmit(.clientSecret, chain: Self.chain, focus: $focusedField)
            }

            AppleSettingsPersistenceError(settings: settings)
        }
        .appleSettingsPage("Trakt")
    }
}

@MainActor
private struct ApplePlaybackSettingsView: View {
    let settings: AppleSettingsStore
    var embeddedInSplit = false

    var body: some View {
        @Bindable var settings = settings

        Form {
            // No Player choice: every play uses the OpenStream engine inside
            // Apple's own player (owner decision 2026-10-01).
            Section("Captions") {
                // Not "Language": every option here is a *mode* — Off, English,
                // Device Language, Always — so the row read "Language: Always",
                // and the actual language list is the row underneath it. That
                // pair is what left the owner thinking subtitles were chosen
                // when captions were still off (review 2026-09-14).
                #if os(tvOS)
                AppleTVChoicePicker("Show Captions", selection: $settings.storedCaptionsPreference, options: [
                    .init(value: .off, title: "Off"), .init(value: .english, title: "English"),
                    .init(value: .deviceLanguage, title: "Device Language"), .init(value: .always, title: "Always"),
                ])
                #else
                Picker("Show Captions", selection: $settings.storedCaptionsPreference) {
                    Text("Off").tag(AppleCaptionsPreference.off)
                    Text("English").tag(AppleCaptionsPreference.english)
                    Text("Device Language").tag(AppleCaptionsPreference.deviceLanguage)
                    Text("Always").tag(AppleCaptionsPreference.always)
                }
                #endif
                NavigationLink(value: AppleSettingsRoute.subtitleLanguages) {
                    AppleTVNavigationLabel("Subtitle Languages")
                }
                .appleTVReadableFocus()
            }

            Section("Playback") {
                #if os(tvOS)
                AppleTVChoicePicker("Live buffer", selection: $settings.liveBuffer,
                    options: AppleLiveBufferPreference.allCases.map { .init(value: $0, title: $0.title) })
                #else
                Picker("Live buffer", selection: $settings.liveBuffer) {
                    ForEach(AppleLiveBufferPreference.allCases, id: \.self) { preference in
                        Text(preference.title).tag(preference)
                    }
                }
                .accessibilityIdentifier("settings.liveBuffer")
                #endif
                #if os(tvOS)
                AppleTVChoicePicker("Audio Language", selection: $settings.audioLanguage,
                                    options: Self.audioLanguageOptions)
                #else
                Picker("Audio Language", selection: $settings.audioLanguage) {
                    Text(AppleAudioLanguagePreference.automaticTitle).tag("")
                    ForEach(AppleSubtitleLanguages.all) { language in
                        Text(language.name).tag(language.code)
                    }
                }
                .accessibilityIdentifier("settings.audioLanguage")
                #endif
                Toggle("Auto Play Next Episode", isOn: $settings.autoPlayNextEpisode)
                #if os(tvOS)
                // Apple TV has no trailers (47aebf1); the same stored switch now
                // only starts the Live guide's channel previews, which are always
                // silent, so there is nothing for Auto-Mute to do here.
                Toggle("Auto Play Live Previews", isOn: $settings.autoPlayTrailer)
                #else
                Toggle("Auto Play Trailer", isOn: $settings.autoPlayTrailer)
                if settings.autoPlayTrailer {
                    Toggle("Auto-Mute", isOn: $settings.autoMuteTrailer)
                }
                #endif
                Toggle("Delete After Watching", isOn: $settings.deleteAfterWatching)
                NavigationLink(value: AppleSettingsRoute.playbackInfo) {
                    AppleTVNavigationLabel("Playback Info")
                }
                .appleTVReadableFocus()
            }
        }
        .appleSettingsPane("Playback", embedded: embeddedInSplit)
    }

    #if os(tvOS)
    private static var audioLanguageOptions: [AppleTVChoicePicker<String>.Option] {
        [AppleTVChoicePicker<String>.Option(value: "", title: AppleAudioLanguagePreference.automaticTitle)]
            + AppleSubtitleLanguages.all.map { AppleTVChoicePicker<String>.Option(value: $0.code, title: $0.name) }
    }
    #endif
}

/// Picks up to three languages the captions menu lists add-on subtitles for.
/// Plain focusable rows with a checkmark; further rows go inert once three
/// are chosen. Nothing is forced: the page stays until Done or Menu (U14).
@MainActor
struct AppleSubtitleLanguagesView: View {
    @Environment(\.dismiss) private var dismiss
    let settings: AppleSettingsStore

    var body: some View {
        // Opens at the chosen language. The list is alphabetical and runs to
        // forty-odd entries, so a viewer with English selected arrived at
        // "Arabic" and had to scroll to find their own setting (review
        // 2026-09-14, U5).
        ScrollViewReader { proxy in
            list.onAppear {
                guard let target = AppleSubtitleLanguages.initialScrollTarget(
                    selected: settings.subtitleLanguages) else { return }
                proxy.scrollTo(target, anchor: .center)
            }
        }
    }

    private var list: some View {
        List {
            ForEach(AppleSubtitleLanguages.all) { language in
                let isSelected = settings.subtitleLanguages.contains(language.code)
                Button {
                    settings.subtitleLanguages = AppleSubtitleLanguages.toggling(
                        language.code,
                        in: settings.subtitleLanguages
                    )
                } label: {
                    HStack {
                        Text(language.name)
                        Spacer()
                        if isSelected {
                            // The row's Selected trait says it.
                            Image(systemName: "checkmark")
                                .accessibilityHidden(true)
                        }
                    }
                }
                .disabled(!isSelected && settings.subtitleLanguages.count >= AppleSubtitleLanguages.maximumSelection)
                .appleTVReadableFocus()
                .accessibilityIdentifier("settings.subtitleLanguages.\(language.code)")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityRemoveTraits(isSelected ? [] : .isSelected)
                .id(language.code)
            }

            Section {
                Button("Done") { dismiss() }
                    .appleTVReadableFocus()
            }
        }
        .appleSettingsPage("Subtitle Languages")
        .scrollIndicators(AppleDesignTokens.scrollIndicatorVisibility)
    }
}

@MainActor
private struct ApplePrivacySettingsView: View {
    let settings: AppleSettingsStore
    var embeddedInSplit = false

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("Apple Services") {
                Toggle("Show in Apple services", isOn: $settings.showInAppleServices)
            }
            Section("Diagnostics") {
                Toggle("Diagnostic Logging", isOn: $settings.diagnosticLoggingEnabled)
            }
        }
        .appleSettingsPane("Privacy", embedded: embeddedInSplit)
    }
}

private enum AppleConnectionTestState: Equatable {
    case idle
    case testing
    case success(String)
    case failure(String)

    var isTesting: Bool {
        if case .testing = self { return true }
        return false
    }
}

private struct AppleConnectionStatusView: View {
    let state: AppleConnectionTestState

    @ViewBuilder
    var body: some View {
        switch state {
        case .idle, .testing:
            EmptyView()
        case .success(let message):
            Label(message, systemImage: "checkmark.circle")
                .foregroundStyle(.primary)
        case .failure(let message):
            Text(message)
                .foregroundStyle(.red)
        }
    }
}

private struct AppleConnectionTestLabel: View {
    let isTesting: Bool

    var body: some View {
        if isTesting {
            HStack {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Testing connection")
                Text("Testing")
            }
        } else {
            Text("Test Connection")
        }
    }
}

@MainActor
private struct AppleSettingsPersistenceError: View {
    let settings: AppleSettingsStore

    var body: some View {
        if let error = settings.persistenceError {
            Section {
                Text(error)
                    .foregroundStyle(.red)
            }
        }
    }
}

private struct AppleAboutView: View {
    var embeddedInSplit = false

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("App", value: "oStream")
                LabeledContent("Version", value: version)
                LabeledContent("Build", value: build)
            }

            // TMDB's logo and notice and the JustWatch credit sit behind one
            // (i) row (owner: "just make them (i)"). The app is open source:
            // the repository link may 404 until the owner flips it public
            // after a secret scan, which is expected.
            Section {
                AppleAttributionInfoRow()
                #if os(tvOS)
                LabeledContent("Source Code", value: AppleAttribution.sourceCodeDisplay)
                    .accessibilityIdentifier("settings.about.sourceCode")
                #else
                Link(destination: AppleAttribution.sourceCodeURL) {
                    HStack {
                        Text("Source Code")
                        Spacer()
                        Text(AppleAttribution.sourceCodeDisplay)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.primary)
                .accessibilityIdentifier("settings.about.sourceCode")
                #endif
            }

            Section {
                NavigationLink {
                    AppleThirdPartyNoticesView()
                } label: {
                    AppleTVNavigationLabel("Third-Party Notices", systemImage: "doc.text")
                }
            }

            #if !os(tvOS)
            Section {
                ShareLink(item: AppleDiagnosticsFile(), preview: SharePreview("oStream Diagnostics")) {
                    Text("Share Diagnostics")
                }
                .accessibilityIdentifier("settings.about.shareDiagnostics")
            }
            #endif
        }
        .appleSettingsPane("oStream", embedded: embeddedInSplit)
    }
}

struct AppleWorkingButtonLabel: View {
    let title: LocalizedStringKey
    let workingTitle: LocalizedStringKey
    let isWorking: Bool
    /// `.leading` for a Form row. Centred in the width of "◌ Syncing…", a
    /// row's "Sync Now" sat ~8 pt right of the rows above it (UX tour
    /// 2026-10-08); pill buttons keep the centre.
    var alignment: Alignment = .center

    var body: some View {
        ZStack(alignment: alignment) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.mini).accessibilityHidden(true)
                Text(workingTitle)
            }
            .hidden()
            .accessibilityHidden(true)
            
            HStack(spacing: 8) {
                Text(title)
            }
            .hidden()
            .accessibilityHidden(true)
            
            HStack(spacing: 8) {
                if isWorking {
                    ProgressView().controlSize(.mini).accessibilityHidden(true)
                }
                Text(isWorking ? workingTitle : title)
                    .contentTransition(.identity)
            }
            .animation(nil, value: isWorking)
        }
        #if os(tvOS)
        // A focused Settings row turns white and the form's white tint drew
        // "Clear Cache" white on it (Apple TV regression 2026-10-01).
        .modifier(AppleTVFocusedLabelInk())
        #endif
    }
}

#if os(tvOS)
/// Black ink on the white focus fill; untouched otherwise, so a destructive
/// role keeps its own colour.
struct AppleTVFocusedLabelInk: ViewModifier {
    @Environment(\.isFocused) private var isFocused

    func body(content: Content) -> some View {
        if isFocused {
            content.foregroundStyle(Color.black)
        } else {
            content
        }
    }
}
#endif

/// Loading the lineup for the Channel Manager.
enum AppleChannelManagerLoad {
    /// Longer than one request's idle timeout (20 s), shorter than patience.
    static let deadline: Duration = .seconds(30)

    static func message(sourceName: String, error: Error) -> String {
        if (error as? URLError)?.code == .timedOut {
            return "\(sourceName) is not responding."
        }
        return "\(sourceName): \(error.localizedDescription)"
    }

    static func withDeadline<Value: Sendable>(
        _ duration: Duration,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        return try await withThrowingTaskGroup(of: Value.self) { group in
            defer { group.cancelAll() }
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: duration)
                throw URLError(.timedOut)
            }
            guard let value = try await group.next() else { throw CancellationError() }
            return value
        }
    }
}
