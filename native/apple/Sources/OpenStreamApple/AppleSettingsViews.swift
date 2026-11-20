import SwiftUI

enum AppleSettingsRoute: Hashable {
    case sources
    case channels
    case restrictions
    case general
    case homeRows
    case liveTV
    case metadata
    case metadataAdvanced
    case watchProviders
    case playback
    case subtitleLanguages
    case privacy
    case storage
    case about
    #if os(tvOS)
    case privacyPolicy
    case support
    #endif
    #if !os(tvOS)
    case backup
    case transferTo
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
    @Environment(\.appleExpandsPhoneLayout) private var expandsPhoneLayout
    let settings: AppleSettingsStore
    let sourceStore: AppleSourceStore
    let mediaServerLibrary: AppleMediaServerLibraryStore
    let webManagement: any AppleWebManagementServing
    var backupController: AppleConfigurationController? = nil
    /// Large phone windows and landscape iPads draw Settings as a split view,
    /// sections on the left and the chosen page on the right, with this
    /// as the right column's stack. Nil pushes everything on one stack.
    var splitPath: Binding<NavigationPath>? = nil
    @State private var splitSelection: AppleSettingsRoute = .sources
    @State private var splitVisibility: NavigationSplitViewVisibility = .automatic
    private static let expandedPhoneColumnMinimumWidth: CGFloat = 240
    private static let expandedPhoneColumnIdealWidth: CGFloat = 320

    var body: some View {
        settingsContent.modifier(AppleSettingsPINLock())
    }

    @ViewBuilder private var settingsContent: some View {
        #if os(tvOS)
        AppleTVSettingsSplitView(settings: settings, sourceStore: sourceStore, mediaServerLibrary: mediaServerLibrary,
                                 webManagement: webManagement,
                                 backupController: backupController)
            .navigationDestination(for: AppleSettingsRoute.self) { route in
                destination(for: route)
            }
        #else
        if let splitPath {
            NavigationSplitView(columnVisibility: $splitVisibility) {
                if expandsPhoneLayout {
                    rootForm.navigationSplitViewColumnWidth(min: Self.expandedPhoneColumnMinimumWidth,
                        ideal: Self.expandedPhoneColumnIdealWidth, max: Self.expandedPhoneColumnIdealWidth)
                } else {
                    rootForm
                }
            } detail: {
                if expandsPhoneLayout {
                    splitDetail(path: splitPath)
                        .navigationSplitViewColumnWidth(min: Self.expandedPhoneColumnMinimumWidth,
                                                        ideal: Self.expandedPhoneColumnIdealWidth)
                } else {
                    splitDetail(path: splitPath)
                }
            }
            .navigationSplitViewStyle(.balanced)
            .onChange(of: expandsPhoneLayout, initial: true) {
                if expandsPhoneLayout { splitVisibility = .all }
            }
        } else {
            rootForm
                .navigationDestination(for: AppleSettingsRoute.self) { route in
                    destination(for: route)
                }
        }
        #endif
    }

    #if !os(tvOS)
    private func splitDetail(path: Binding<NavigationPath>) -> some View {
        NavigationStack(path: path) {
            destination(for: splitSelection)
                .navigationDestination(for: AppleSettingsRoute.self) { route in
                    destination(for: route)
                }
        }
    }

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
        case .general:
            AppleGeneralSettingsView(settings: settings)
        case .homeRows:
            AppleHomeRowSettingsView(settings: settings, sourceStore: sourceStore, mediaServerLibrary: mediaServerLibrary)
        case .liveTV:
            AppleLiveSettingsView(settings: settings, sourceStore: sourceStore, webManagement: webManagement)
        case .metadata:
            AppleMetadataSettingsView(settings: settings)
        case .metadataAdvanced:
            Form {
                AppleMetadataCredentialSections(settings: settings)
                AppleSettingsPersistenceError(settings: settings)
            }
            .appleSettingsPage("Advanced")
        case .watchProviders:
            AppleWatchProviderSettingsView(settings: settings)
        case .playback:
            ApplePlaybackSettingsView(settings: settings)
        case .subtitleLanguages:
            AppleSubtitleLanguagesView(settings: settings)
        case .privacy:
            ApplePrivacySettingsView(settings: settings)
        case .storage:
            AppleStorageSettingsView()
        case .about:
            AppleAboutView()
        #if os(tvOS)
        case .privacyPolicy:
            if let url = AppleAttribution.privacyURL { AppleAboutLinkView(title: "Privacy", url: url) }
        case .support:
            if let url = AppleAttribution.supportURL {
                AppleAboutLinkView(title: "Support", url: url)
            }
        #endif
        #if !os(tvOS)
        case .backup:
            if let backupController { AppleBackupSettingsView(controller: backupController) }
        case .transferTo:
            AppleSetupTransferToView(controller: backupController)
        #endif
        }
    }

    #if !os(tvOS)
    private var rootForm: some View {
        Form {
            ForEach(AppleSettingsRootEntry.leadingSections, id: \.self) { entries in
                Section {
                    ForEach(entries, id: \.self) { entry in
                        settingsLink(entry.route) {
                            AppleTVNavigationLabel(entry.title, systemImage: entry.systemImage)
                        }
                        .appleTVReadableFocus()
                        .accessibilityIdentifier("settings.\(entry.rawValue)")
                    }
                }
            }

            Section {
                settingsLink(.general) { Label("General", systemImage: "gearshape") }
                    .accessibilityIdentifier("settings.general")
                settingsLink(.homeRows) { Label("Home Rows", systemImage: "rectangle.stack") }
                    .accessibilityIdentifier("settings.homeRows")
                settingsLink(.playback) { Label("Playback", systemImage: "play.circle") }
                    .accessibilityIdentifier("settings.playback")
                settingsLink(.liveTV) { Label("Live TV", systemImage: "dot.radiowaves.left.and.right") }
                    .accessibilityIdentifier("settings.liveTV")
            }
            Section("Services") {
                settingsLink(.metadata) { Label("Metadata", systemImage: "photo.on.rectangle.angled") }
                    .accessibilityIdentifier("settings.metadata")
                settingsLink(.watchProviders) { Label("Streaming Services", systemImage: "rectangle.stack.badge.play") }
                    .accessibilityIdentifier("settings.watchProviders")
            }
            Section {
                settingsLink(.privacy) { Label("Privacy", systemImage: "hand.raised") }
                    .accessibilityIdentifier("settings.privacy")
                settingsLink(.storage) { Label("Storage", systemImage: "internaldrive") }
                    .accessibilityIdentifier("settings.storage")
                settingsLink(.about) { Label("About", systemImage: "info.circle") }
                    .accessibilityIdentifier("settings.about")
            }
        }
        .appleSettingsContent()
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
    let mediaServerLibrary: AppleMediaServerLibraryStore
    let webManagement: any AppleWebManagementServing
    let backupController: AppleConfigurationController?

    @State private var selection = AppleTVSettingsSection.defaultSelection
    #if DEBUG
    private var debugPane: AppleTVSettingsSection? {
        UserDefaults.standard.string(forKey: "OpenStreamSettingsPane")
            .flatMap(AppleTVSettingsSection.init(rawValue:))
    }
    #endif
    @FocusState private var focusedSection: AppleTVSettingsSection?
    /// Set when a section is selected: focus then moves into its pane
    /// (owner 2026-11-04, "a bunch of sections you can't click").
    @State private var entersPane = false
    @Namespace private var focusScope
    @Environment(\.resetFocus) private var resetFocus
    private let metrics = AppleTVSettingsMetrics.standard

    var body: some View {
        HStack(alignment: .top, spacing: metrics.columnSpacing) {
            sidebar
                .frame(width: metrics.sidebarWidth)
                .frame(maxHeight: .infinity, alignment: .top)
                .focusSection()
                .prefersDefaultFocus(!entersPane, in: focusScope)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .focusSection()
                .prefersDefaultFocus(entersPane, in: focusScope)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // No `defaultFocus` on Sources here: it won the reset below and sent
        // every click back to Sources. Sources is the first row, so the
        // sidebar's own preference lands there on first appearance.
        .focusScope(focusScope)
        .onChange(of: focusedSection) { _, focused in
            guard let focused else { return }
            selection = focused
            entersPane = false
        }
        .onChange(of: entersPane) { _, enters in
            if enters { resetFocus(in: focusScope) }
        }
        #if DEBUG
        .task {
            guard let debugPane else { return }
            focusedSection = debugPane
            selection = debugPane
        }
        #endif
    }

    private var sidebar: some View {
        List {
            ForEach(AppleTVSettingsSection.allCases) { section in
                Button {
                    selection = section
                    if entersPane { resetFocus(in: focusScope) } else { entersPane = true }
                } label: {
                    AppleTVFocusReadableText(section.title)
                }
                .focused($focusedSection, equals: section)
                .accessibilityIdentifier("settings.section.\(section.rawValue)")
                .accessibilityAddTraits(selection == section ? .isSelected : [])
            }
        }
        .listStyle(.plain)
        .scrollIndicators(.hidden)
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
                embeddedInSplit: true,
                backupController: backupController
            )
        case .channels:
            AppleChannelManagerView(settings: settings, sourceStore: sourceStore, embeddedInSplit: true)
        case .restrictions:
            AppleRestrictionsView(sourceStore: sourceStore, embeddedInSplit: true)
        case .liveTV:
            AppleLiveSettingsView(settings: settings, sourceStore: sourceStore, webManagement: webManagement, embeddedInSplit: true)
        case .general:
            AppleGeneralSettingsView(settings: settings, embeddedInSplit: true)
        case .homeRows:
            AppleHomeRowSettingsView(settings: settings, sourceStore: sourceStore,
                mediaServerLibrary: mediaServerLibrary, embeddedInSplit: true)
        case .services:
            AppleMetadataSettingsView(settings: settings, embeddedInSplit: true)
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

#endif

@MainActor
private struct AppleLiveSettingsView: View {
    let settings: AppleSettingsStore
    let sourceStore: AppleSourceStore
    let webManagement: any AppleWebManagementServing
    var embeddedInSplit = false

    var body: some View {
        @Bindable var settings = settings

        return Form {
            AppleLiveResumeSetting()
            Toggle("Show Live tab", isOn: $settings.liveTVEnabled)
                .disabled(!appleCanToggleTab(.live, settings: settings))
                .accessibilityIdentifier("settings.live.enabled")
            Section {
                #if os(tvOS)
                AppleChannelHealthSettingsRows(store: .shared, settings: settings, sourceStore: sourceStore,
                    webManagement: webManagement)
                #else
                AppleChannelHealthSettingsRows(store: .shared, settings: settings, sourceStore: sourceStore)
                #endif
            }
        }
        .appleSettingsPane("Live TV", embedded: embeddedInSplit)
        .task {
            await AppleChannelHealthStore.shared.prepareLineupIfNeeded(
                settings: settings, sourceStore: sourceStore, allowsNetwork: !embeddedInSplit)
        }
    }
}

@MainActor
private struct AppleGeneralSettingsView: View {
    let settings: AppleSettingsStore
    var embeddedInSplit = false

    var body: some View {
        @Bindable var settings = settings

        return Form {
            Section {
                Toggle("Show Discover tab", isOn: $settings.discoverEnabled)
                    .disabled(!appleCanToggleTab(.home, settings: settings))
                    .accessibilityIdentifier("settings.discover.enabled")
                AppleTop10ListsToggle(settings: settings)
            } header: {
                Text("Discover")
            }

            Section("Library") {
                Toggle("Show Library tab", isOn: $settings.libraryEnabled)
                    .disabled(!appleCanToggleTab(.library, settings: settings))
                    .accessibilityIdentifier("settings.library.enabled")
            }

            AppleTitlePageSectionsSettings(settings: settings)
        }
        .appleSettingsPane("General", embedded: embeddedInSplit)
    }
}

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
                AppleSettingsPicker("Package", selection: $settings.liveChannelPackage) {
                    ForEach(AppleLiveChannelPackage.available(entries: completeGuide)) { package in
                        Text(package.title).tag(package)
                    }
                }
                .accessibilityIdentifier("settings.channels.package")
                .accessibilityLabel("Package")
                AppleSettingsPicker("Live view", selection: $settings.liveChannelScope) {
                    ForEach(AppleLiveChannelScope.allCases) { scope in
                        Text(scope.title).tag(scope)
                    }
                }
                .accessibilityIdentifier("settings.channels.view")
                .accessibilityLabel("Live view")

                Toggle("Show Pay-Per-View", isOn: $settings.showPayPerViewChannels)
                Toggle("Show 24/7 channels", isOn: $settings.show24x7Channels)
            }

            #if !os(tvOS)
            AppleLineupImportSection()
            #endif
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
            // The lineup's state rides on this row: a text-only row under
            // My Channels could not take focus (owner 2026-11-04).
            Section {
                Button {
                    guard !isLoading else { return }
                    Task { await reload(clearsArtworkFailures: true) }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        AppleTVNavigationLabel(isLoading ? "Refreshing…" : "Refresh", systemImage: "arrow.clockwise")
                        if let status = channels.isEmpty ? (errorMessage ?? emptyLineupMessage) : errorMessage {
                            Text(status)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("channels.empty")
                        }
                    }
                }
                .accessibilityIdentifier("channels.refresh")
            }
            #endif
            // Owner, 2026-09-17: a 3,000-row wall of toggles is not a way to
            // pick channels. The list holds only what is selected; adding goes
            // through a searchable picker.
            #if os(tvOS)
            if !channels.isEmpty { myChannelsSection }
            #else
            myChannelsSection
            #endif
        }
        .appleSettingsPane("Channel Manager", embedded: embeddedInSplit)
        // tvOS toolbar items always draw a box around the glyph, which is the
        // same defect the owner called on Discover (T4) and Search (R1).
        // On a television these two actions are rows in the form instead.
        #if !os(tvOS)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await reload(clearsArtworkFailures: true) } } label: {
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
        .task(id: sourceIdentity) { await reload(); completeGuide = AppleChannelLineupPresets.current; lineupIndex = AppleChannelLineupIndex(completeGuide) }
        .onReceive(NotificationCenter.default.publisher(for: AppleChannelLineupStore.didChange).receive(on: RunLoop.main)) { _ in
            completeGuide = AppleChannelLineupPresets.current
            lineupIndex = AppleChannelLineupIndex(completeGuide)
            settings.updateAutomaticLiveChannelPackage(channels: channels)
            channelsRevision &+= 1
        }
        .task(id: projectionIdentity) { await rebuildFilteredChannels() }
    }

    private var myChannelsSection: some View {
        Section(settings.liveChannelPackage == .custom ? "Custom Channels" : "My Channels") {
            #if !os(tvOS)
            if isLoading, channels.isEmpty {
                ProgressView()
            } else if channels.isEmpty {
                Text(errorMessage ?? emptyLineupMessage)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("channels.empty")
                if errorMessage != nil {
                    Button("Retry") { Task { await reload() } }
                        .accessibilityIdentifier("channels.retry")
                }
            }
            #endif
            if !channels.isEmpty {
                NavigationLink {
                    channelPicker
                } label: {
                    Label("Add Channels…", systemImage: "plus.circle")
                }
                .accessibilityIdentifier("channels.add")
                #if !os(tvOS)
                if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(.secondary)
                }
                #endif
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
                        .accessibilityLabel("Remove \(channel.displayName)")
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
        if live.isEmpty { return "No Live TV Sources" }
        return live.contains(where: \.isEnabled) ? "No Channels" : "Live TV Source Off"
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
                #if os(tvOS)
                // One row per group until a search narrows it: the whole
                // lineup in one form (9,381 rows) did not open within 10 s
                // on an Apple TV 4K 2nd gen (owner 2026-11-04).
                if query.isEmpty {
                    NavigationLink {
                        Form {
                            ForEach(section.channels) { channel in channelRow(channel) }
                        }
                        .appleSettingsPage(section.name)
                    } label: {
                        LabeledContent(section.name, value: section.channels.count.formatted())
                    }
                } else {
                    Section(section.name) {
                        ForEach(section.channels) { channel in channelRow(channel) }
                    }
                }
                #else
                Section(section.name) {
                    ForEach(section.channels) { channel in channelRow(channel) }
                }
                #endif
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

    private func channelRow(_ channel: AppleIPTVChannel) -> some View {
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
        .accessibilityLabel(channel.displayName)
        .accessibilityValue(isSelected(channel.id) ? "Included" : "Not included")
    }

    private var numberedChannels: [AppleIPTVChannel] {
        AppleGuideChannelProjection.rows(channels: filteredChannels, entries: completeGuide,
            favoriteIDs: [], favoritesOnly: false, sortByNumber: true).map(\.channel)
    }

    private func displayName(for channel: AppleIPTVChannel) -> String {
        guard let entry = lineupIndex.match(channel.name) else {
            return channel.displayName
        }
        return "\(entry.number) · \(channel.displayName)"
    }

    private func reload(clearsArtworkFailures: Bool = false) async {
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
                if clearsArtworkFailures {
                    let saved = await AppleIPTVChannelCache.shared.snapshot(for: source.id)?.channels ?? []
                    await AppleArtworkDiskCache.shared.clearFailures(for: saved.compactMap(\.logoURL))
                }
                let credentials = try sourceStore.iptvCredentials(for: source)
                let client = client
                // A panel that is down can hold the request open well past
                // its idle timeout; My Channels then spun for good (full test
                // 2026-10-01). Each source gets a deadline, then says so.
                let received = try await AppleChannelManagerLoad.withDeadline(AppleChannelManagerLoad.deadline) {
                    try await client.channels(source: source, credentials: credentials)
                }
                try Task.checkCancellation()
                loaded += await AppleIPTVChannelCache.shared.reconcileAndStore(received, for: source.id)
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
    let settings: AppleSettingsStore
    var embeddedInSplit = false

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle("Use Metadata APIs", isOn: $settings.metadataEnabled)
                    .accessibilityIdentifier("settings.metadata.enabled")
            }
            Section {
                NavigationLink(value: AppleSettingsRoute.metadataAdvanced) {
                    AppleTVNavigationLabel("Advanced")
                }
                .appleTVReadableFocus()
                .accessibilityIdentifier("settings.metadata.advanced")
            }
            #if os(tvOS)
            Section {
                NavigationLink(value: AppleSettingsRoute.watchProviders) {
                    Text("Streaming Services")
                }
                .accessibilityIdentifier("settings.watchProviders")
            }
            #endif
            AppleSettingsPersistenceError(settings: settings)
        }
        .appleSettingsPane("Metadata", embedded: embeddedInSplit)
    }
}

@MainActor
private struct AppleMetadataCredentialSections: View {
    private enum Field: Hashable { case tmdb, omdb }
    private static let chain: [Field] = [.tmdb, .omdb]
    @FocusState private var focusedField: Field?
    let settings: AppleSettingsStore

    var body: some View {
        @Bindable var settings = settings
        Section("TMDB") {
            SecureField("API Key or Read Token", text: $settings.tmdbAPIKey)
                .accessibilityLabel("TMDB API Key or Read Token")
                .accessibilityIdentifier("settings.metadata.tmdb")
                .disabled(!settings.metadataEnabled)
                .appleFormSubmit(.tmdb, chain: Self.chain, focus: $focusedField)
        }
        Section("OMDb") {
            SecureField("API Key", text: $settings.omdbAPIKey)
                .accessibilityLabel("OMDb API Key")
                .accessibilityIdentifier("settings.metadata.omdb")
                .disabled(!settings.metadataEnabled)
                .appleFormSubmit(.omdb, chain: Self.chain, focus: $focusedField)
        }
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
                AppleSettingsPicker("Show Captions", selection: $settings.storedCaptionsPreference) {
                    Text("Off").tag(AppleCaptionsPreference.off)
                    Text("English").tag(AppleCaptionsPreference.english)
                    Text("Device Language").tag(AppleCaptionsPreference.deviceLanguage)
                    Text("Always").tag(AppleCaptionsPreference.always)
                }
                .accessibilityIdentifier("settings.captions")
                .accessibilityLabel("Show Captions")
                NavigationLink(value: AppleSettingsRoute.subtitleLanguages) {
                    AppleTVNavigationLabel("Subtitle Languages")
                }
                .appleTVReadableFocus()
            }

            Section("Playback") {
                AppleSettingsPicker("Live Buffer", selection: $settings.liveBuffer) {
                    ForEach(AppleLiveBufferPreference.allCases, id: \.self) { preference in
                        Text(preference.title).tag(preference)
                    }
                }
                .accessibilityIdentifier("settings.liveBuffer")
                .accessibilityLabel("Live Buffer")
                AppleSettingsPicker("Audio Language", selection: $settings.audioLanguage) {
                    Text(AppleAudioLanguagePreference.automaticTitle).tag("")
                    ForEach(AppleSubtitleLanguages.all) { language in
                        Text(language.name).tag(language.code)
                    }
                }
                .accessibilityIdentifier("settings.audioLanguage")
                .accessibilityLabel("Audio Language")
                Toggle("Auto Play Next Episode", isOn: $settings.autoPlayNextEpisode)
                    .accessibilityIdentifier("settings.autoPlayNextEpisode")
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
            }
            Section {
                NavigationLink {
                    ApplePlaybackInfoView(settings: settings)
                } label: {
                    AppleTVNavigationLabel("Playback Info")
                }
                .appleTVReadableFocus()
                .accessibilityIdentifier("settings.playback.info")
            }
        }
        .appleSettingsPane("Playback", embedded: embeddedInSplit)
    }
}

/// Picks up to three languages the captions menu prefers.
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
                    .accessibilityIdentifier("settings.privacy.logging")
                #if !os(tvOS)
                ShareLink(item: AppleDiagnosticsFile(), preview: SharePreview("oStream Diagnostics")) {
                    Text("Share Diagnostics")
                }
                .accessibilityIdentifier("settings.privacy.shareDiagnostics")
                #endif
            }
        }
        .appleSettingsPane("Privacy", embedded: embeddedInSplit)
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
    #if os(tvOS)
    @State private var showsDataSources = false
    #endif

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    var body: some View {
        Form {
            Section {
                #if !os(tvOS)
                LabeledContent("App", value: "oStream")
                #endif
                LabeledContent("Version", value: version)
                    .accessibilityIdentifier("settings.about.version")
                LabeledContent("Build", value: build)
                    .accessibilityIdentifier("settings.about.build")
            }
            #if os(tvOS)
            .labeledContentStyle(.appleTVReadOnlyRow)
            #endif

            Section {
                NavigationLink {
                    AppleThirdPartyNoticesView()
                } label: {
                    Text("Acknowledgements")
                }
                .accessibilityIdentifier("settings.about.acknowledgements")
                #if os(tvOS)
                NavigationLink(value: AppleSettingsRoute.privacyPolicy) { Text("Privacy") }
                    .accessibilityIdentifier("settings.about.privacy")
                NavigationLink(value: AppleSettingsRoute.support) { Text("Support") }
                    .accessibilityIdentifier("settings.about.support")
                #else
                if let privacyURL = AppleAttribution.privacyURL {
                    Link("Privacy", destination: privacyURL)
                        .accessibilityIdentifier("settings.about.privacy")
                }
                if let supportURL = AppleAttribution.supportURL {
                    Link("Support", destination: supportURL)
                        .accessibilityIdentifier("settings.about.support")
                }
                #endif
            }
            Section {
                #if os(tvOS)
                // The credits open from one row: as lines of text they could
                // not take focus (owner 2026-11-04).
                Button(AppleAttribution.infoTitle) { showsDataSources = true }
                    .accessibilityIdentifier("settings.about.dataSources")
                #else
                AppleTMDBAttributionRow()
                Text(AppleAttribution.justWatchCredit)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings.about.justwatch")
                Text(AppleAttribution.noContentDisclaimer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings.about.noContent")
                #endif
            }
        }
        .appleSettingsPane("About", embedded: embeddedInSplit)
        #if os(tvOS)
        .sheet(isPresented: $showsDataSources) { AppleAttributionSheet() }
        #endif
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
/// A read-only row that still takes focus, as on the system's own About page.
/// A page of rows the remote could not reach gave Menu nothing to pop, and
/// tvOS then left the app (Playback Info, owner 2026-11-04).
struct AppleTVReadOnlyRowStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        LabeledContent(configuration).focusable()
    }
}

extension LabeledContentStyle where Self == AppleTVReadOnlyRowStyle {
    static var appleTVReadOnlyRow: AppleTVReadOnlyRowStyle { AppleTVReadOnlyRowStyle() }
}

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
        // The Live tab's plain words for a panel that did not answer, not the setup advice.
        return AppleIPTVFailureCause.message(for: error, providerName: sourceName)
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

/// Off limits until TMDB is set up: the rows are TMDB's charts. Off and
/// dimmed then, rather than a line saying why (no explainer text).
@MainActor
private struct AppleTop10ListsToggle: View {
    let settings: AppleSettingsStore

    var body: some View {
        Toggle("Top 10 lists", isOn: Binding(
            get: { settings.top10ListsEnabled && settings.top10ListsAvailable },
            set: { settings.top10ListsEnabled = $0 }
        ))
        .disabled(!settings.top10ListsAvailable)
        .accessibilityIdentifier("settings.discover.top10")
    }
}

/// Settings › Title Page (owner 2026-10-28): the sections a title page shows.
@MainActor
private struct AppleTitlePageSectionsSettings: View {
    let settings: AppleSettingsStore

    var body: some View {
        @Bindable var settings = settings

        Section("Title Page") {
            Toggle("Trailers", isOn: $settings.titlePageTrailersEnabled)
                .accessibilityIdentifier("settings.titlePage.trailers")
            Toggle("Cast & Crew", isOn: $settings.titlePageCastEnabled)
                .accessibilityIdentifier("settings.titlePage.cast")
            Toggle("Information", isOn: $settings.titlePageInformationEnabled)
                .accessibilityIdentifier("settings.titlePage.information")
            Toggle("About", isOn: $settings.titlePageAboutEnabled)
                .accessibilityIdentifier("settings.titlePage.about")
        }
    }
}
