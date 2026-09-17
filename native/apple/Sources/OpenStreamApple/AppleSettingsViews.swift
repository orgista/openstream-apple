import SwiftUI

enum AppleSettingsRoute: Hashable {
    case sources
    case channels
    case metadata
    case serverDownloads
    case trakt
    case watchProviders
    case playback
    case playbackInfo
    case subtitleLanguages
    case privacy
    case storage
    case about
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

    var body: some View {
        #if os(tvOS)
        AppleTVSettingsSplitView(settings: settings, sourceStore: sourceStore, webManagement: webManagement)
            .navigationDestination(for: AppleSettingsRoute.self) { route in
                destination(for: route)
            }
        #else
        rootForm
            .navigationDestination(for: AppleSettingsRoute.self) { route in
                destination(for: route)
            }
        #endif
    }

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
        case .metadata:
            AppleMetadataSettingsView(settings: settings)
        case .serverDownloads:
            AppleServerDownloadsSettingsView(settings: settings)
        case .trakt:
            AppleTraktSettingsView(settings: settings)
        case .watchProviders:
            AppleWatchProviderSettingsView(settings: settings)
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
        }
    }

    #if !os(tvOS)
    private var rootForm: some View {
        @Bindable var settings = settings

        return Form {
            Section {
                NavigationLink(value: AppleSettingsRoute.sources) {
                    AppleTVNavigationLabel("Sources", systemImage: "rectangle.stack.badge.plus")
                }
                .appleTVReadableFocus()
                NavigationLink(value: AppleSettingsRoute.channels) {
                    AppleTVNavigationLabel("Channel Manager", systemImage: "list.star")
                }
                .appleTVReadableFocus()
            }

            Section("Discover") {
                Toggle("Show Discover tab", isOn: $settings.discoverEnabled)
                    .disabled(!appleCanToggleTab(.home, settings: settings))
                    .accessibilityIdentifier("settings.discover.enabled")
                Toggle("Top 10 lists", isOn: $settings.top10ListsEnabled)
            }

            Section("Library") {
                Toggle("Show Library tab", isOn: $settings.libraryEnabled)
                    .disabled(!appleCanToggleTab(.library, settings: settings))
                    .accessibilityIdentifier("settings.library.enabled")
            }

            Section("Live TV") {
                Toggle("Show Live tab", isOn: $settings.liveTVEnabled)
                    .disabled(!appleCanToggleTab(.live, settings: settings))
                    .accessibilityIdentifier("settings.live.enabled")
            }

            Section("Services") {
                NavigationLink(value: AppleSettingsRoute.metadata) {
                    AppleTVNavigationLabel("Metadata", systemImage: "photo.on.rectangle.angled")
                }
                .appleTVReadableFocus()
                NavigationLink(value: AppleSettingsRoute.serverDownloads) {
                    AppleTVNavigationLabel("Radarr & Sonarr", systemImage: "arrow.down.circle")
                }
                .appleTVReadableFocus()
                NavigationLink(value: AppleSettingsRoute.trakt) {
                    AppleTVNavigationLabel("Trakt", systemImage: "arrow.triangle.2.circlepath")
                }
                .appleTVReadableFocus()
            }

            Section("Playback") {
                NavigationLink(value: AppleSettingsRoute.playback) {
                    AppleTVNavigationLabel("Playback", systemImage: "play.circle")
                }
                .appleTVReadableFocus()
            }

            Section("Privacy") {
                NavigationLink(value: AppleSettingsRoute.privacy) {
                    AppleTVNavigationLabel("Privacy", systemImage: "hand.raised")
                }
                .appleTVReadableFocus()
            }

            Section {
                NavigationLink(value: AppleSettingsRoute.storage) {
                    AppleTVNavigationLabel("Storage", systemImage: "internaldrive")
                }
                .appleTVReadableFocus()
                NavigationLink(value: AppleSettingsRoute.about) {
                    AppleTVNavigationLabel("About", systemImage: "info.circle")
                }
                .appleTVReadableFocus()
            }
        }
        .appleSettingsContent()
    }
    #endif
}

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
        case .liveTV:
            AppleTVLiveTabPane(settings: settings)
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

    var body: some View {
        @Bindable var settings = settings

        return Form {
            Toggle("Show Live tab", isOn: $settings.liveTVEnabled)
                .disabled(!appleCanToggleTab(.live, settings: settings))
                .accessibilityIdentifier("settings.live.enabled")
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
    @State private var premierGuide: [AppleChannelLineupEntry] = []
    @State private var lineupIndex = AppleChannelLineupIndex([])
    private let client = AppleIPTVClient()

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("Channel Preferences") {
                Picker("Package", selection: $settings.liveChannelPackage) {
                    ForEach(AppleLiveChannelPackage.allCases) { package in
                        Text(package.title).tag(package)
                    }
                }

                Picker("Live view", selection: $settings.liveChannelScope) {
                    ForEach(AppleLiveChannelScope.allCases) { scope in
                        Text(scope == .regional && AppleZIPCodePolicy.isValid(settings.regionalZIPCode)
                            ? "Local Channels · \(settings.regionalZIPCode)" : scope.title).tag(scope)
                    }
                }

                // The ZIP only means anything for the regional lineup. It used
                // to sit here permanently, empty and disabled, which on a
                // television reads as a broken field rather than an
                // inapplicable one. Disclose it the way the Custom Package
                // section below already does.
                if settings.liveChannelScope == .regional {
                    TextField("ZIP code", text: $settings.regionalZIPCode)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                        .onChange(of: settings.regionalZIPCode) { _, value in
                            let digits = String(value.filter(\.isNumber).prefix(5))
                            if digits != value { settings.regionalZIPCode = digits }
                        }
                    if !settings.regionalZIPCode.isEmpty,
                       !AppleZIPCodePolicy.isValid(settings.regionalZIPCode) {
                        Text("Enter a valid 5-digit US ZIP code.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Toggle("Show Pay-Per-View", isOn: $settings.showPayPerViewChannels)
                Toggle("Show 24/7 channels", isOn: $settings.show24x7Channels)
            }

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
                NavigationLink {
                    AppleTVChannelSearchEditor(query: $query)
                } label: {
                    AppleTVNavigationLabel("Search Channels", systemImage: "magnifyingglass")
                }
                Button {
                    Task { await reload() }
                } label: {
                    AppleTVNavigationLabel("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading)
            }
            #endif
            Section(settings.liveChannelPackage == .custom ? "Custom Channels" : "My Channels") {
                if isLoading, channels.isEmpty {
                    ProgressView()
                } else if channels.isEmpty {
                    Text(errorMessage ?? "Add a Live TV source first.")
                        .foregroundStyle(errorMessage == nil ? Color.secondary : Color.red)
                } else {
                    ForEach(numberedChannels) { channel in
                        Toggle(isOn: Binding(
                            get: { isSelected(channel.id) },
                            set: { _ in toggle(channel.id) }
                        )) {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(displayName(for: channel))
                                        .foregroundStyle(.primary)
                                    if !channel.group.isEmpty {
                                        Text(channel.group)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .accessibilityLabel(channel.name)
                        .accessibilityValue(isSelected(channel.id)
                            ? "Included" : "Not included")
                    }
                }
            }
        }
        .appleSettingsPane("Channel Manager", embedded: embeddedInSplit)
        #if !os(tvOS)
        .searchable(text: $query, prompt: "Channels")
        #endif
        // tvOS toolbar items always draw a box around the glyph, which is the
        // same defect the owner called on Discover (T4) and Search (R1).
        // On a television these two actions are rows in the form instead.
        #if !os(tvOS)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await reload() } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading)
            }
        }
        #endif
        .task(id: sourceIdentity) { await reload(); premierGuide = (try? AppleChannelLineupPresets.premierUS()) ?? []; lineupIndex = AppleChannelLineupIndex(premierGuide) }
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
                regionalZIPCode: settings.regionalZIPCode,
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

    private var numberedChannels: [AppleIPTVChannel] {
        AppleGuideChannelProjection.rows(channels: filteredChannels, entries: premierGuide,
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
            channels = []
            filteredChannels = []
            channelsRevision &+= 1
            errorMessage = nil
            return
        }
        isLoading = true
        defer { isLoading = false }
        var loaded: [AppleIPTVChannel] = []
        var errors: [String] = []
        for source in sources {
            do {
                loaded += try await client.channels(
                    source: source,
                    credentials: try sourceStore.iptvCredentials(for: source)
                )
            } catch is CancellationError {
                return
            } catch {
                errors.append("\(source.name): \(error.localizedDescription)")
            }
        }
        channels = loaded
        channelsRevision &+= 1
        errorMessage = errors.first
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

            Section("TMDB") {
                SecureField("API key or read token", text: $settings.tmdbAPIKey)
                    .disabled(!settings.metadataEnabled)
                    .appleFormSubmit(.tmdb, chain: Self.chain, focus: $focusedField)
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
        Section(kind.displayName) {
            TextField("Server URL", text: $baseURL)
                .autocorrectionDisabled()
                .tint(.primary)
                .appleFormSubmit(.baseURL, chain: Self.chain, focus: $focusedField)
            SecureField("API key", text: $apiKey)
                .appleFormSubmit(.apiKey, chain: Self.chain, focus: $focusedField)
            TextField("Root folder path", text: $rootFolderPath)
                .autocorrectionDisabled()
                .appleFormSubmit(.rootFolder, chain: Self.chain, focus: $focusedField)
            TextField("Quality profile ID", text: $qualityProfileID)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
                .appleFormSubmit(.qualityProfile, chain: Self.chain, focus: $focusedField)

            AppleConnectionStatusView(state: state)

            Button {
                Task { await testConnection() }
            } label: {
                AppleConnectionTestLabel(isTesting: state.isTesting)
            }
            .buttonStyle(.brandSecondary)
            .disabled(!canTest || state.isTesting)
            // The list row draws its own capsule and `.brandSecondary` draws a
            // pill inside it — a box in a box, which is the "no boxes and
            // weirdness" the owner called out for the settings panes
            // (2026-09-16). One piece of chrome, not two. Confirmed on the
            // phone as well as the television (2026-09-17), so it is not
            // platform-gated.
            .listRowBackground(Color.clear)
        }
        .onChange(of: baseURL) { _, _ in state = .idle }
        .onChange(of: apiKey) { _, _ in state = .idle }
        .onChange(of: rootFolderPath) { _, _ in state = .idle }
        .onChange(of: qualityProfileID) { _, _ in state = .idle }
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
            Section("Engine") {
                Picker("Player", selection: $settings.playbackEngine) {
                    Text("OpenStream").tag(ApplePlaybackEngineKind.openStream)
                    Text("Native").tag(ApplePlaybackEngineKind.native)
                }
            }

            Section("Captions") {
                // Not "Language": every option here is a *mode* — Off, English,
                // Device Language, Always — so the row read "Language: Always",
                // and the actual language list is the row underneath it. That
                // pair is what left the owner thinking subtitles were chosen
                // when captions were still off (review 2026-09-14).
                Picker("Show Captions", selection: $settings.captionsPreference) {
                    Text("Off").tag(AppleCaptionsPreference.off)
                    Text("English").tag(AppleCaptionsPreference.english)
                    Text("Device Language").tag(AppleCaptionsPreference.deviceLanguage)
                    Text("Always").tag(AppleCaptionsPreference.always)
                }
                NavigationLink(value: AppleSettingsRoute.subtitleLanguages) {
                    AppleTVNavigationLabel("Subtitle Languages")
                }
                .appleTVReadableFocus()
            }

            Section("Playback") {
                Toggle("Auto Play Next Episode", isOn: $settings.autoPlayNextEpisode)
                Toggle("Auto Play Trailer", isOn: $settings.autoPlayTrailer)
                if settings.autoPlayTrailer {
                    Toggle("Auto-Mute", isOn: $settings.autoMuteTrailer)
                }
                Toggle("Delete After Watching", isOn: $settings.deleteAfterWatching)
                NavigationLink(value: AppleSettingsRoute.playbackInfo) {
                    AppleTVNavigationLabel("Playback Info")
                }
                .appleTVReadableFocus()
            }
        }
        .appleSettingsPane("Playback", embedded: embeddedInSplit)
    }
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
                guard let first = AppleSubtitleLanguages.all
                    .first(where: { settings.subtitleLanguages.contains($0.code) }) else { return }
                proxy.scrollTo(first.code, anchor: .center)
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
                            Image(systemName: "checkmark")
                        }
                    }
                }
                .disabled(!isSelected && settings.subtitleLanguages.count >= AppleSubtitleLanguages.maximumSelection)
                .appleTVReadableFocus()
                .accessibilityIdentifier("settings.subtitleLanguages.\(language.code)")
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
                LabeledContent("App", value: "OpenStream")
                LabeledContent("Version", value: version)
                LabeledContent("Build", value: build)
            }

            Section {
                if let url = URL(string: "https://github.com/orgista/openstream") {
                    Link(destination: url) {
                        HStack {
                            Text("GitHub")
                            Spacer()
                            Text("github.com/orgista/openstream")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.primary)
                }
                NavigationLink {
                    AppleThirdPartyNoticesView()
                } label: {
                    AppleTVNavigationLabel("Third-Party Notices", systemImage: "doc.text")
                }
            }
        }
        .appleSettingsPane("About", embedded: embeddedInSplit)
    }
}
