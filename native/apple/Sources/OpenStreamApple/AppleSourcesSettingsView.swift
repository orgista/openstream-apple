import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import SwiftUI
import UniformTypeIdentifiers

#if os(iOS) || os(visionOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Field prompts. On Apple TV they are tertiary italic so an empty field never
/// reads as a filled-in value from across the room (owner item S9).
private func appleSecondaryFieldPrompt(_ title: String) -> Text {
    #if os(visionOS)
    Text(title).foregroundStyle(.white)
    #elseif os(tvOS)
    // Tertiary italic on black could not be read from the couch (full test
    // 2026-10-01); secondary is the contrast tvOS gives its own placeholders.
    Text(title).foregroundStyle(.secondary)
    #elseif os(iOS)
    // Use the system label color directly; hierarchical secondary styling
    // compounds the text field's placeholder dimming on a dark form.
    Text(title).foregroundStyle(Color(uiColor: .secondaryLabel))
    #else
    Text(title).foregroundStyle(.secondary)
    #endif
}

@MainActor
public protocol AppleWebManagementServing: AnyObject {
    var session: AppleWebManagementSession? { get }
    var connectedBrowsers: [AppleWebManagementServer.ConnectedBrowser] { get }
    func endBrowser(id: UUID)
    func endAllBrowsers()

    func sessionUpdates() -> AsyncStream<AppleWebManagementSession?>
    func start(sourceStore: AppleSourceStore) async throws -> AppleWebManagementSession
    func stop() async
}

public extension AppleWebManagementServing {
    var connectedBrowsers: [AppleWebManagementServer.ConnectedBrowser] { [] }
    func endBrowser(id: UUID) {}
    func endAllBrowsers() {}
}

public struct AppleWebManagementUnavailableError: LocalizedError, Sendable {
    public init() {}

    public var errorDescription: String? {
        "Web Management is unavailable in this build."
    }
}

@MainActor
public final class AppleUnavailableWebManagementService: AppleWebManagementServing {
    public var session: AppleWebManagementSession? { nil }

    public init() {}

    public func sessionUpdates() -> AsyncStream<AppleWebManagementSession?> {
        AsyncStream { continuation in
            continuation.yield(nil)
            continuation.finish()
        }
    }

    public func start(sourceStore: AppleSourceStore) async throws -> AppleWebManagementSession {
        throw AppleWebManagementUnavailableError()
    }

    public func stop() async {}
}

@MainActor
struct AppleSourcesSettingsView: View {
    @State private var showingLibraryImporter = false
    @State private var importError: String?
    #if DEBUG
    @State private var debugDetailSourceID: AppleSource.ID?
    #endif
    #if os(tvOS)
    /// Apple TV has no Backup & Sync page, so what iCloud sync last did is
    /// shown here instead (`AppleConfigurationSyncStatus`).
    @AppStorage(AppleConfigurationSyncStatus.defaultsKey) private var syncStatusData: Data?
    #endif

    let sourceStore: AppleSourceStore
    let settings: AppleSettingsStore
    let webManagement: any AppleWebManagementServing
    /// True inside the Apple TV Settings split view's detail pane, where the
    /// header is drawn at the pane's leading edge instead of as a page title.
    var embeddedInSplit = false

    var body: some View {
        AppleSettingsCollection {
            Section("Add") {
                NavigationLink(value: AppleSourceRoute.addMediaServer) {
                    AppleTVNavigationLabel("Media Server", systemImage: "server.rack")
                }
                .appleTVReadableFocus()
                NavigationLink(value: AppleSourceRoute.addNetworkShare) {
                    AppleTVNavigationLabel("Network Share", systemImage: "externaldrive.badge.plus")
                }
                .appleTVReadableFocus()
                NavigationLink(value: AppleSourceRoute.addLiveTV) {
                    AppleTVNavigationLabel("Live TV", systemImage: "dot.radiowaves.left.and.right")
                }
                .appleTVReadableFocus()
                NavigationLink(value: AppleSourceRoute.addFiles) {
                    AppleTVNavigationLabel("Files", systemImage: "folder.badge.plus")
                }
                .appleTVReadableFocus()
                NavigationLink(value: AppleSourceRoute.addInstance) {
                    AppleTVNavigationLabel("Instance", systemImage: "plus.circle")
                }
                .appleTVReadableFocus()
#if OPENSTREAM_ADDONS
                NavigationLink(value: AppleSourceRoute.addManifest) {
                    AppleTVNavigationLabel("Add Catalog", systemImage: "square.stack.3d.up")
                }
                .appleTVReadableFocus()
#endif
                NavigationLink(value: AppleSourceRoute.webManagement) {
                    AppleTVNavigationLabel("Web Management", systemImage: "network")
                }
                .appleTVReadableFocus()
                Button {
                    AppleSetupTransferCenter.shared.presentReceiver()
                } label: {
                    AppleTVNavigationLabel(AppleSetupTransferDevice.receiveTitle, systemImage: "qrcode")
                }
                .foregroundStyle(.primary)
                .appleTVReadableFocus()
                .accessibilityIdentifier("sources.setupFromPhone")
            }

            // Not "Sources" again: the pane is already titled Sources, so the
            // screen read "Sources … Sources" (review 2026-09-14).
            // Uppercased on Apple TV only: this pane is a `List` there while
            // the other settings panes are `Form`s, and a tvOS Form uppercases
            // its section headers while a List does not — so this one header
            // read "Your Sources" beside "CHANNEL PREFERENCES" and
            // "CONNECTION". Everywhere else the header takes the platform's
            // own case like its neighbours; forcing it read "YOUR SOURCES"
            // among the Mac's title-case headers (N54 #13).
            Section {
                if sourceStore.sources.isEmpty {
                    Text("No sources")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sourceStore.sources) { source in
                        NavigationLink(value: AppleSourceRoute.detail(source.id)) {
                            AppleSourceRow(source: source)
                        }
                        .appleTVReadableFocus()
                    }
                }
            } header: {
                // Scoped to the header on purpose: `.textCase` on the Section
                // uppercases its *rows* too, which turned every source name
                // into "TORRENTIO TB".
                Text("Your Sources")
                    #if os(tvOS)
                    .textCase(.uppercase)
                    #endif
            }
            #if os(tvOS)
            Section {
                AppleConfigurationSyncStatusLines(status: syncStatusData
                    .flatMap { try? JSONDecoder().decode(AppleConfigurationSyncStatus.self, from: $0) }
                    ?? AppleConfigurationSyncStatus())
                    .focusable()
            } header: {
                Text("iCloud Sync").textCase(.uppercase)
            }
            #endif
        }
        .appleSettingsPane("Sources", embedded: embeddedInSplit)
        .scrollIndicators(AppleDesignTokens.scrollIndicatorVisibility)
        .navigationDestination(for: AppleSourceRoute.self) { route in
            switch route {
            case .addFiles:
                AppleAddFilesView(
                    showingLibraryImporter: $showingLibraryImporter,
                    sourceStore: sourceStore,
                    settings: settings,
                    webManagement: webManagement
                )
            case .addInstance:
                AppleAddInstanceView()
            #if OPENSTREAM_ADDONS
            case .addManifest:
                AppleAddManifestSourceView(sourceStore: sourceStore)
            #endif
            case .addLiveTV:
                AppleAddLiveTVSourceView(sourceStore: sourceStore)
            case .addMediaServer:
                AppleAddMediaServerView(sourceStore: sourceStore)
            case .addNetworkShare:
                AppleNetworkShareConnectView(start: .add(nil), flow: .shared, sourceStore: sourceStore)
            case .networkShareServer(let server):
                AppleNetworkShareConnectView(start: .add(server), flow: .shared, sourceStore: sourceStore)
            case .editNetworkShare(let id, let part):
                AppleNetworkShareConnectView(start: .edit(id, part), flow: .shared, sourceStore: sourceStore)
            case .addARR:
                AppleServerDownloadsSettingsView(settings: settings)
            case .webManagement:
                AppleWebManagementView(sourceStore: sourceStore, service: webManagement)
            case .detail(let sourceID):
                AppleSourceDetailView(sourceID: sourceID, sourceStore: sourceStore, settings: settings)
            }
        }
        .navigationDestination(for: AppleNetworkShareRoute.self) { route in
            AppleNetworkShareStepView(route: route, flow: .shared, sourceStore: sourceStore)
        }
        #if DEBUG
        // Simulator-only: opens a real saved source's detail page so it can be
        // screenshotted headlessly. Never runs without the debug default set.
        .navigationDestination(isPresented: Binding(
            get: { debugDetailSourceID != nil },
            set: { if !$0 { debugDetailSourceID = nil } }
        )) {
            if let debugDetailSourceID {
                AppleSourceDetailView(
                    sourceID: debugDetailSourceID,
                    sourceStore: sourceStore,
                    settings: settings
                )
            }
        }
        .task {
            guard UserDefaults.standard.string(forKey: "OpenStreamVisionScreen") == "source-detail" else { return }
            debugDetailSourceID = sourceStore.sources.first {
                AppleSubtitleLanguages.declaresSubtitles(resources: $0.resources)
            }?.id ?? sourceStore.sources.first?.id
        }
        #endif
        #if !os(tvOS)
        .fileImporter(
            isPresented: $showingLibraryImporter,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            importFolder(result)
        }
        #endif
        .alert("Couldn’t Add Folder", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "The folder could not be added.")
        }
    }

    #if !os(tvOS)
    private func importFolder(_ result: Result<[URL], any Error>) {
        do {
            guard let url = try result.get().first else { throw AppleLibrarySourceError.invalidFolder }
            let access = AppleSecurityScopedAccess(url: url)
            defer { withExtendedLifetime(access) {} }
            let bookmark = try AppleLibraryBookmark.make(for: url)
            try sourceStore.addLibraryFolder(name: url.lastPathComponent, url: url, bookmarkData: bookmark)
        } catch {
            importError = error.localizedDescription
        }
    }
    #endif
}

enum AppleSourceRoute: Hashable {
    case addFiles
    case addInstance
    #if OPENSTREAM_ADDONS
    case addManifest
    #endif
    case addLiveTV
    case addMediaServer
    case addNetworkShare
    /// A server found on the network: Connect with its address filled in.
    case networkShareServer(AppleNetworkShareServer)
    case editNetworkShare(AppleSource.ID, AppleNetworkShareEditPart)
    case addARR
    case webManagement
    case detail(AppleSource.ID)
}

private struct AppleAddInstanceView: View {
    var body: some View {
        List {
            NavigationLink(value: AppleSourceRoute.addARR) {
                AppleTVNavigationLabel("Radarr or Sonarr", systemImage: "arrow.down.circle")
            }
            .appleTVReadableFocus()
        }
        .appleSettingsPage("Add Instance")
        .scrollIndicators(AppleDesignTokens.scrollIndicatorVisibility)
    }
}

private struct AppleAddFilesView: View {
    @Binding var showingLibraryImporter: Bool
    let sourceStore: AppleSourceStore
    let settings: AppleSettingsStore
    let webManagement: any AppleWebManagementServing
    @State private var directURL = ""
    @State private var showingDirectURL = false
    @State private var playback: AppleStremioPlayerPresentation?
    @State private var playbackError: String?
    @State private var discovered: [AppleSMBServer] = []
    @State private var isDiscovering = false
    #if os(visionOS)
    @State private var discoveryFailure: String?
    @State private var discoveryRevision = 0
    #endif
    private let discovery = AppleSMBDiscovery()

    var body: some View {
        List {
            Section("Network Shares") {
                if isDiscovering && discovered.isEmpty {
                    // Centred: a bare spinner pinned to the leading edge read
                    // as a glitch under the section heading rather than as the
                    // row searching for servers.
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .accessibilityLabel("Looking for servers")
                        .listRowBackground(Color.clear)
                }
                #if os(visionOS)
                if let discoveryFailure {
                    Text(discoveryFailure).foregroundStyle(.secondary)
                    Button("Find Servers") { discoveryRevision += 1 }
                        .buttonStyle(.brandSecondary)
                }
                #endif
                ForEach(discovered) { server in
                    NavigationLink(value: AppleSourceRoute.networkShareServer(AppleNetworkShareServer(server))) {
                        LabeledContent(server.name, value: endpointLabel(for: server))
                    }
                    .appleTVReadableFocus()
                }
                NavigationLink(value: AppleSourceRoute.addNetworkShare) {
                    AppleTVNavigationLabel("Add Network Share", systemImage: "externaldrive.badge.plus")
                }
                .appleTVReadableFocus()
                ForEach(sourceStore.sources.filter { $0.kind == .nas }) { source in
                    NavigationLink(value: AppleSourceRoute.detail(source.id)) {
                        HStack {
                        AppleTVNavigationLabel(source.name, systemImage: AppleSourceKind.nas.systemImage)
                            Spacer()
                            Image(systemName: "pencil")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .appleTVReadableFocus()
                    .accessibilityLabel("Edit \(source.name)")
                }
            }
            // tvOS has no document picker, so `Section("Folder")` rendered as a
            // heading with nothing underneath it; and `Section("Direct URL")`
            // held a single row that repeated its own heading. Both showed up
            // in the owner's capture as a broken-looking stack of labels
            // (2026-09-15: "add files gui needs work"). One section, and no row
            // restates its heading.
            Section {
                #if !os(tvOS)
                Button { showingLibraryImporter = true } label: { locationRow("Choose Folder", "folder") }
                #endif
                Button { showingDirectURL = true } label: {
                    locationRow("Direct URL", "globe")
                }
                .appleTVReadableFocus()
                .alert("Direct URL", isPresented: $showingDirectURL) {
                    TextField("URL", text: $directURL, prompt: appleSecondaryFieldPrompt("URL"))
                        .accessibilityLabel("URL")
                        #if os(iOS) || os(tvOS) || os(visionOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                    Button("Play") {
                        guard let url = AppleDirectPlaybackInput.url(directURL) else {
                            playbackError = "Enter a valid HTTP or HTTPS video URL."
                            return
                        }
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(250))
                            playback = AppleStremioPlayerPresentation(
                                request: ApplePlaybackRequest(url: url,
                                    mediaID: ApplePlaybackIdentity.digest(for: url.absoluteString),
                                    title: url.lastPathComponent, sourceKind: .files), settings: settings)
                        }
                    }
                    Button("Cancel", role: .cancel) { }
                }
            }
        }
        .appleSettingsPage("Add Files")
        .scrollIndicators(AppleDesignTokens.scrollIndicatorVisibility)
        #if DEBUG
        .task {
            if let raw = UserDefaults.standard.string(forKey: "OpenStreamVisionPlaybackURL"),
               let url = AppleDirectPlaybackInput.url(raw) ?? URL(string: raw).flatMap({ $0.isFileURL ? $0 : nil }) {
                let mediaID = ApplePlaybackIdentity.digest(for: url.absoluteString)
                let request: ApplePlaybackRequest
                if UserDefaults.standard.bool(forKey: "OpenStreamVisionPlaybackIsLive") {
                    request = AppleIPTVChannel(id: mediaID, sourceID: UUID(), name: "Caption fixture",
                                               streamURL: url).playbackRequest()
                } else {
                    request = ApplePlaybackRequest(url: url, mediaID: mediaID,
                                                   title: url.lastPathComponent, sourceKind: .files)
                }
                playback = AppleStremioPlayerPresentation(request: request, settings: settings)
            }
        }
        #endif
        .task(id: discoveryTaskIdentity) {
            #if DEBUG
            // The local playback proof needs no LAN discovery or saved source.
            if let raw = UserDefaults.standard.string(forKey: "OpenStreamVisionPlaybackURL"),
               let url = URL(string: raw), url.host == "127.0.0.1" || url.isFileURL { return }
            #endif
            isDiscovering = true
            // `defer`, not a trailing assignment: the cancellation guard below
            // returns early, and without this the flag stayed true for the
            // life of the screen — so navigating away and back left a spinner
            // under "Network Shares" that never stopped (2026-09-15).
            defer { isDiscovering = false }
            #if os(visionOS)
            discoveryFailure = nil
            #endif
            let report = await discovery.discoverReport()
            guard !Task.isCancelled else { return }
            discovered = report.servers
            #if os(visionOS)
            discoveryFailure = report.servers.isEmpty ? report.message : nil
            #if DEBUG
            print("[Vision review] SMB advertised=\(report.advertisedCount) resolved=\(report.servers.count) denied=\(report.permissionDenied)")
            #endif
            #endif
        }
        // Same presentation as the title page on every platform: a sheet on
        // tvOS 18 is an inset rounded card on a light ground, which is what the
        // owner saw when playing a file from a share (FEEDBACK Y1).
        .modifier(AppleStremioPlayerPresentationModifier(presentation: $playback))
        .alert("Invalid Video URL", isPresented: Binding(get: { playbackError != nil }, set: { if !$0 { playbackError = nil } })) {
            Button("OK", role: .cancel) { playbackError = nil }
        } message: { Text(playbackError ?? "") }
    }

    private var discoveryTaskIdentity: Int {
        #if os(visionOS)
        discoveryRevision
        #else
        0
        #endif
    }

    /// A stock `Label` sizes its icon column to the font on tvOS, so `globe`
    /// and `folder` ran straight into their titles while the rows either side
    /// — which already used `AppleTVNavigationLabel` — sat on a clean column
    /// (owner: "add files gui needs work", 2026-09-15).
    private func locationRow(_ title: String, _ icon: String) -> some View {
        AppleTVNavigationLabel(title, systemImage: icon)
            .foregroundStyle(AppleDesignTokens.textPrimary)
    }

    private func endpointLabel(for server: AppleSMBServer) -> String {
        AppleSMBEndpointPolicy.endpointLabel(host: server.displayHost, port: server.port)
    }
}

/// A settings value that may be long and have nowhere to wrap.
///
/// `LabeledContent(_:value:)` wraps its value, and a value with no spaces —
/// `opensubtitles-v3.strem.io`, a share path, a validation summary — breaks
/// **mid-word** when it runs out of room, which is what the owner reported on
/// 2026-09-14. Widening the form column hid it; it did not remove it, because
/// any value long enough still wraps.
///
/// Middle truncation rather than tail: for a host or a path the beginning and
/// the end both identify it, and the middle is the part nobody needs.
private struct AppleTruncatingValue: View {
    let label: String
    let value: String

    init(_ label: String, value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        LabeledContent(label) {
            Text(value)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

private struct AppleSourceRow: View {
    let source: AppleSource

    /// Add-on logos that are wide wordmarks (OpenSubtitles ships one) shrink
    /// to an unreadable sliver inside the 44-point square, so those rows keep
    /// the kind glyph instead. Anything wider than this ratio counts.
    static let wordmarkAspectRatio: CGFloat = 2.2

    @State private var logoIsWordmark = false
    /// Set once a fetched logo genuinely fails (bad URL, 404, timeout), so
    /// that row stops retrying it every redraw and shows the same deliberate
    /// fallback as a manifest with no logo at all.
    @State private var logoFailed = false

    var body: some View {
        HStack(spacing: 12) {
            sourceIcon

            VStack(alignment: .leading, spacing: 2) {
                Text(source.name)
                Text(AppleSourceOriginLabel.subtitle(kind: source.kind.title, url: source.url))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(source.isEnabled ? "On" : "Off")
                .foregroundStyle(.secondary)
        }
        .onChange(of: source.logoURL) { _, _ in
            logoIsWordmark = false
            logoFailed = false
        }
    }

    @ViewBuilder
    private var sourceIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.secondary.opacity(0.15))

            if source.isAddon, let logoURL = source.logoURL.flatMap(AppleAddonLogoURLPolicy.displayURL(for:)),
               !logoIsWordmark, !logoFailed {
                AppleRemoteImage(
                    url: logoURL,
                    contentMode: .fit,
                    placeholderSystemImage: source.kind.systemImage,
                    onLoad: { image in
                        logoIsWordmark = CGFloat(image.width) > CGFloat(image.height) * Self.wordmarkAspectRatio
                    },
                    onFailure: { logoFailed = true }
                )
                .padding(6)
            } else {
                sourceFallbackIcon
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityHidden(true)
    }

    /// Every add-on without a usable logo — Cinemeta's manifest publishes
    /// none, OpenSubtitles v3's is a wordmark too wide to read at this size —
    /// otherwise fell back to the exact same glyph as a source with no
    /// manifest at all, which read as broken rather than "no icon." An
    /// add-on keeps its own mark, its initial, instead; only the truly
    /// iconless kinds (IPTV, a home server, Library) use the shared glyph.
    private var sourceFallbackIcon: some View {
        Group {
            if source.isAddon, let initial = source.name.trimmingCharacters(in: .whitespaces).first {
                Text(String(initial).uppercased())
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: source.kind.systemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(6)
    }
}

private extension AppleSourceKind {
    var systemImage: String {
        switch self {
        case .library: "books.vertical"
        #if OPENSTREAM_ADDONS
        case .stremio: "square.stack.3d.up"
        #endif
        case .youtube: "play.rectangle"
        case .liveTV: "dot.radiowaves.left.and.right"
        case .nas: "externaldrive.connected.to.line.below"
        case .mediaServer: "server.rack"
        }
    }
}

@MainActor
private struct AppleSourceDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false

    let sourceID: AppleSource.ID
    let sourceStore: AppleSourceStore
    let settings: AppleSettingsStore

    private var source: AppleSource? {
        sourceStore.sources.first { $0.id == sourceID }
    }

    private var enabled: Binding<Bool> {
        Binding(
            get: { source?.isEnabled ?? false },
            set: { sourceStore.setEnabled($0, id: sourceID) }
        )
    }

    var body: some View {
        Group {
            if let source {
                Form {
                    Section {
                        LabeledContent("Type", value: source.kind.title)
                        if source.kind != .nas {
                            // A share's server and folder are rows of their own below.
                            AppleTruncatingValue(locationLabel(source), value: sourceLocation(source))
                        }
                        LabeledContent("Health", value: healthLabel(source))
                        if let lastValidatedAt = source.lastValidatedAt {
                            LabeledContent(
                                "Last Success",
                                value: lastValidatedAt.formatted(date: .abbreviated, time: .shortened)
                            )
                            if let validationSummary = source.validationSummary {
                                AppleTruncatingValue("Status", value: validationSummary)
                            }
                        } else {
                            LabeledContent("Status", value: "Not yet validated")
                        }
                        if let discoveredItemCount = source.discoveredItemCount {
                            LabeledContent("Items", value: discoveredItemCount.formatted())
                        }
                        if !source.capabilities.isEmpty {
                            AppleTruncatingValue("Capabilities", value: source.capabilities.joined(separator: ", "))
                        }
                        if source.hasCurrentValidationFailure, let lastFailureAt = source.lastValidationFailureAt {
                            LabeledContent(
                                "Last Failure",
                                value: lastFailureAt.formatted(date: .abbreviated, time: .shortened)
                            )
                            if let failure = source.validationFailureSummary {
                                LabeledContent("Failure", value: failure)
                            }
                        }
                        switch AppleSourceEnableControl.control(for: source) {
                        case .toggle:
                            Toggle("Enabled", isOn: enabled)
                        case .signIn:
                            // It cannot be switched on until it is signed in.
                            NavigationLink {
                                AppleSourceSignInDestination(source: source, store: sourceStore)
                            } label: {
                                AppleTVNavigationLabel("Sign In")
                            }
                            .appleTVReadableFocus()
                            .accessibilityIdentifier("source.detail.signIn")
                        }
                    }

                    if source.kind == .liveTV {
                        AppleGuideTimeOffsetSection(sourceID: source.id, settings: settings)
                        if source.iptvType == .xtream {
                            AppleIPTVAccountSection(source: source, sourceStore: sourceStore)
                        }
                    }

                    if source.kind == .nas {
                        AppleNetworkShareEditRows(source: source, sourceStore: sourceStore)
                    }

                    if AppleSubtitleLanguages.declaresSubtitles(resources: source.resources) {
                        Section {
                            NavigationLink {
                                AppleSubtitleLanguagesView(settings: settings)
                            } label: {
                                AppleTVNavigationLabel("Subtitles", systemImage: "captions.bubble")
                            }
                            .appleTVReadableFocus()
                        }
                    }

                    let catalogs = AppleCatalogDiscoveryPolicy.browsableCatalogs(for: source)
#if OPENSTREAM_ADDONS
                    if source.isAddon, catalogs.count > 1 {
                        Section("Catalogs") {
                            let shown = Set(AppleCatalogDiscoveryPolicy.catalogs(for: source)
                                .map(AppleCatalogDiscoveryPolicy.choiceKey))
                            let titles = catalogTitles(catalogs)
                            ForEach(Array(zip(catalogs, titles)), id: \.1.key) { catalog, title in
                                Toggle(title.text, isOn: Binding(
                                    get: { shown.contains(AppleCatalogDiscoveryPolicy.choiceKey(catalog)) },
                                    set: { sourceStore.setCatalog(catalog, shown: $0, id: sourceID) }
                                ))
                                .accessibilityIdentifier(
                                    "source.detail.catalog.\(AppleCatalogDiscoveryPolicy.choiceKey(catalog))")
                            }
                        }
                    }
#endif

                    Section {
                        Button("Delete Source", role: .destructive) {
                            confirmDelete = true
                        }
                    }
                }
                .appleSettingsPage(source.name)
            } else {
                // Titled like every other settings page. `appleSettingsPageTitle`
                // is what gives a page its navigation title *and* its trace
                // entry, and this branch was the one page in the app that
                // skipped both — the exact thing that modifier's own comment
                // says must not happen. Without it the viewer lands on a bare
                // centred message with an empty navigation bar behind it.
                ContentUnavailableView("Source Not Found", systemImage: "questionmark.folder")
                    .appleSettingsPageTitle("Source")
            }
        }
        .alert("Delete Source?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                if sourceStore.remove(id: sourceID) { dismiss() }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// Each catalog's row title; a name used by more than one catalog reads
    /// "Popular Movies" / "Popular Shows", as on Discover.
    private func catalogTitles(_ catalogs: [AppleStremioCatalog]) -> [(key: String, text: String)] {
        let titles = catalogs.map(AppleCatalogShelfPolicy.title(for:))
        let counts = Dictionary(titles.map { ($0.lowercased(), 1) }, uniquingKeysWith: +)
        return zip(catalogs, titles).map { catalog, title in
            (AppleCatalogDiscoveryPolicy.choiceKey(catalog),
             (counts[title.lowercased()] ?? 0) > 1 ? AppleCatalogShelfPolicy.typedTitle(title, type: catalog.type) : title)
        }
    }

    private func locationLabel(_ source: AppleSource) -> String {
        switch source.kind {
        #if OPENSTREAM_ADDONS
        case .stremio: "Manifest Host"
        #endif
        case .library: "Folder"
        case .liveTV: "Server"
        default: "Location"
        }
    }

    private func healthLabel(_ source: AppleSource) -> String {
        if source.hasCurrentValidationFailure {
            return "Needs attention"
        }
        if source.lastValidatedAt != nil { return "Connected" }
        return "Not checked"
    }

    private func sourceLocation(_ source: AppleSource) -> String {
        if source.url.isFileURL { return source.url.lastPathComponent }
        let url = source.url
        guard let host = url.host else { return "Private source" }
        let displayHost = source.kind == .nas ? (source.networkDisplayHost ?? host) : host
        return url.port.map { "\(displayHost):\($0)" } ?? displayHost
    }
}

 #if OPENSTREAM_ADDONS
@MainActor
private struct AppleAddManifestSourceView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var manifestURL = ""
    @State private var isAdding = false
    @State private var errorMessage: String?
    /// Set when the add-on must be configured on its own site first.
    @State private var configureURL: URL?
    /// The add-on answered "configure me first": a state, not a failure.
    @State private var needsConfiguration = false

    let sourceStore: AppleSourceStore

    var body: some View {
        #if os(tvOS)
        tvOSBody
        #else
        standardBody
        #endif
    }

    private var manifestField: some View {
        TextField(
            "Manifest URL",
            text: $manifestURL,
            prompt: appleSecondaryFieldPrompt("Manifest URL")
        )
            .appleTVFieldOutline()
            #if os(iOS) || os(tvOS) || os(visionOS)
            .textInputAutocapitalization(.never)
            #endif
            .autocorrectionDisabled()
            .tint(.primary)
    }

    private var hasManifestURL: Bool {
        !manifestURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    #if os(tvOS)
    @FocusState private var manifestFieldFocused: Bool

    private var tvOSBody: some View {
        let metrics = AppleTVSettingsMetrics.standard
        return ScrollView {
            VStack(alignment: .leading, spacing: metrics.groupSpacing) {
                AppleTVFormField("Manifest URL") {
                    manifestField
                        .focused($manifestFieldFocused)
                        .accessibilityIdentifier("sources.catalog.manifest")
                }
                .frame(maxWidth: metrics.formColumnWidth, alignment: .leading)
                .focusSection()

                HStack(spacing: metrics.pillSpacing) {
                    Button {
                        addManifest()
                    } label: {
                        if isAdding { ProgressView() } else { Text("Add Catalog") }
                    }
                    .buttonStyle(AppleTVPillStyle(isSelected: true, minimumSize: metrics.pillSize, fontSize: metrics.pillFontSize))
                    .disabled(isAdding)
                    .accessibilityIdentifier("sources.catalog.add")
                }
                .focusSection()

                if let errorMessage {
                    if needsConfiguration {
                        // Plain secondary text: no browser on the Apple TV,
                        // so no link either.
                        Text(errorMessage)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: metrics.formColumnWidth, alignment: .leading)
                            .accessibilityIdentifier("sources.form.message")
                    } else {
                        AppleTVFormMessage(text: errorMessage, isError: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, AppleTVChromeMetrics.verticalSafeInset)
        }
        .scrollIndicators(AppleDesignTokens.scrollIndicatorVisibility)
        .defaultFocus($manifestFieldFocused, true)
        .appleSettingsPageTitle("Add Catalog")
    }
    #else
    private var standardBody: some View {
        Form {
            Section("Manifest URL") {
                manifestField
                    #if os(macOS)
                    // A macOS form draws a text field's own title as a leading
                    // label, so this row said "Manifest URL" twice — once as
                    // the section header, once beside the field (macOS sweep,
                    // 2026-09-21). iOS and visionOS never show that title (the
                    // field carries a `prompt`), which is why it went unseen.
                    // The header keeps the name and the field takes the row.
                    .labelsHidden()
                    #endif
            }

            if let errorMessage {
                Section {
                    // "Configure first" is a state, not a failure: plain text.
                    Text(errorMessage)
                        .foregroundStyle(needsConfiguration ? AnyShapeStyle(.primary) : AnyShapeStyle(.red))
                    if let configureURL {
                        Link("Open Configuration", destination: configureURL)
                            .accessibilityIdentifier("sources.catalog.configure")
                    }
                }
            }

            AppleFormActionSection {
                Button {
                    addManifest()
                } label: {
                    if isAdding {
                        ProgressView()
                            #if os(macOS)
                            .controlSize(.small)
                            #endif
                    } else {
                        Text("Add Catalog")
                    }
                }
                .disabled(isAdding || !hasManifestURL)
                .appleMacFormPrimaryAction()
                #if os(macOS)
                .keyboardShortcut(.defaultAction)
                #endif
                .appleTVReadableFocus()
            }
        }
        .appleSettingsPage("Add Catalog")
    }
    #endif

    private func addManifest() {
        guard hasManifestURL else {
            errorMessage = "Enter the add-on's manifest URL."
            return
        }
        isAdding = true
        errorMessage = nil
        configureURL = nil
        needsConfiguration = false

        Task { @MainActor in
            defer { isAdding = false }
            do {
                // Subtitle languages are picked from the add-on's own detail
                // page, so adding a catalog just returns to Sources.
                _ = try await sourceStore.addStremio(manifestValue: manifestURL)
                dismiss()
            } catch AppleManifestClientError.manifestNeedsSetup(let url) {
                errorMessage = AppleManifestClientError.manifestNeedsSetup(configureURL: url).errorDescription
                configureURL = url
                needsConfiguration = true
            } catch AppleManifestClientError.manifestNeedsConfiguration {
                needsConfiguration = true
                errorMessage = AppleManifestClientError.manifestNeedsConfiguration.errorDescription
                configureURL = (try? AppleManifestURLPolicy.normalize(manifestURL))
                    .flatMap(AppleManifestURLPolicy.configureURL(forManifest:))
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
#endif

private enum AppleInstanceConnectionAction: Equatable {
    case test(UUID)
    case save(UUID)

    var requestID: UUID {
        switch self {
        case .test(let id), .save(let id): return id
        }
    }

    var shouldSave: Bool {
        if case .save = self { return true }
        return false
    }
}

#if os(tvOS)
/// One Apple TV form field: a Caption 1 (25 pt) label above the stock field,
/// whose focused chrome the system draws (rework plan task 8).
struct AppleTVFormField<Field: View>: View {
    let label: String
    @ViewBuilder let field: () -> Field

    init(_ label: String, @ViewBuilder field: @escaping () -> Field) {
        self.label = label
        self.field = field
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppleTVSettingsMetrics.standard.labelSpacing) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            field()
        }
    }
}

/// A titled group of fields (Server, Share, Account), title in Caption 1.
struct AppleTVFormGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppleTVSettingsMetrics.standard.fieldSpacing) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }
}

/// The result line under a form's pills: the exact failure reason in red or
/// the success summary in primary, both Body 29.
struct AppleTVFormMessage: View {
    let text: String
    let isError: Bool

    var body: some View {
        Label(text, systemImage: isError ? "exclamationmark.circle" : "checkmark.circle")
            .font(.body)
            .foregroundStyle(isError ? Color.red : Color.primary)
            .frame(maxWidth: AppleTVSettingsMetrics.standard.formColumnWidth, alignment: .leading)
            .accessibilityIdentifier("sources.form.message")
    }
}

/// Two or more choices shown as pills (Xtream Account / M3U Playlist, the
/// server's shares); the chosen one is white.
struct AppleTVChoicePill: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        // The pill style only makes the selected choice "a touch brighter",
        // which for a two-way choice was not enough to tell M3U from Xtream at
        // a glance (review 2026-09-14, U8). A checkmark says it outright, and
        // it is the stock answer — no ring, no glow.
        Button(action: action) {
            HStack(spacing: 10) {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: AppleTVSettingsMetrics.standard.bodyFontSize - 4, weight: .bold))
                }
                Text(title)
            }
        }
        .buttonStyle(AppleTVPillStyle(
            isSelected: isSelected,
            minimumSize: CGSize(width: 0, height: AppleTVSettingsMetrics.standard.choicePillHeight),
            fontSize: AppleTVSettingsMetrics.standard.bodyFontSize
        ))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
#endif

/// Stock field chrome on Apple TV (the focused field lifts the way the system
/// Settings app's do) and on the Mac (the outlined field System Settings
/// draws, N56); the plain in-row style inside iPhone, iPad and visionOS forms.
extension View {
    @ViewBuilder
    func appleSourceFieldStyle() -> some View {
        #if os(tvOS)
        self
        #elseif os(macOS)
        self.appleMacFormFields()
        #else
        self.textFieldStyle(.plain)
        #endif
    }
}

/// A `SecureField` with an owner-controlled reveal button, since pasted
/// Xtream/SMB credentials are hard to verify when fully masked. On Apple TV
/// the eye is an inline focusable glyph beside the field, not a separate
/// "Show password" toggle row (owner item S10).
@MainActor
struct AppleRevealableSecureField: View {
    private let title: String
    @Binding private var text: String
    @Binding private var isRevealed: Bool

    init(_ title: String, text: Binding<String>, isRevealed: Binding<Bool>) {
        self.title = title
        self._text = text
        self._isRevealed = isRevealed
    }

    var body: some View {
        #if os(tvOS)
        HStack(spacing: AppleTVSettingsMetrics.standard.iconSpacing) {
            field
            Button {
                isRevealed.toggle()
            } label: {
                Image(systemName: isRevealed ? "eye.slash" : "eye")
                    .font(.system(size: AppleTVSettingsMetrics.standard.bodyFontSize, weight: .medium))
            }
            .buttonStyle(AppleTVGlyphStyle())
            .accessibilityLabel(isRevealed ? "Hide password" : "Show password")
            .accessibilityIdentifier("sources.password.reveal")
        }
        #else
        HStack {
            field
            Button {
                isRevealed.toggle()
            } label: {
                Image(systemName: isRevealed ? "eye.slash" : "eye")
                    .foregroundStyle(.secondary)
                    .frame(minWidth: AppleDesignTokens.minimumActionSize, minHeight: AppleDesignTokens.minimumActionSize)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .appleVisionActionTarget()
            .accessibilityLabel(isRevealed ? "Hide password" : "Show password")
        }
        #endif
    }

    @ViewBuilder
    private var field: some View {
        if isRevealed {
            TextField(title, text: $text, prompt: appleSecondaryFieldPrompt(title))
                .accessibilityLabel(Text(title))
                .appleTVFieldOutline()
                .textContentType(.password)
                #if os(iOS) || os(tvOS) || os(visionOS)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
        } else {
                SecureField(title, text: $text, prompt: appleSecondaryFieldPrompt(title))
                    .appleTVFieldOutline()
                .textContentType(.password)
                #if os(iOS) || os(tvOS) || os(visionOS)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
                .accessibilityLabel(title)
        }
    }
}

@MainActor
private struct AppleAddLiveTVSourceView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var type = AppleIPTVSourceType.xtream
    @State private var name = ""
    @State private var endpoint = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isPasswordRevealed = false
    @State private var isWorking = false
    @State private var message: String?
    @State private var isError = false
    @State private var connectionAction: AppleInstanceConnectionAction?
    /// Each press runs once; a task rerun on reappear must not repeat it.
    @State private var actionLedger = AppleOneShotRequestLedger()

    /// File imports join the existing local playlist only when Save is pressed.
    @State private var pastedPlaylist = ""
    @State private var isChoosingFile = false
    @State private var playlistFileName: String?

    let sourceStore: AppleSourceStore
    private let client = AppleIPTVClient()
    private let streamProbe = AppleIPTVStreamProbe()

    var body: some View {
        Group {
            #if os(tvOS)
            tvOSBody
            #else
            standardBody
            #endif
        }
        .onChange(of: username) { _, value in
            username = AppleIPTVEndpointPolicy.sanitizeCredential(value)
        }
        .onChange(of: password) { _, value in
            password = AppleIPTVEndpointPolicy.sanitizeCredential(value)
        }
        .onChange(of: endpoint) { _, value in
            endpoint = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        .onChange(of: [type.rawValue, name, endpoint, username, password, pastedPlaylist]) { _, _ in
            message = nil
            isError = false
        }
    }

    private var endpointTitle: String {
        type == .xtream ? "Server URL" : "Playlist URL"
    }

    private var usesPastedPlaylist: Bool {
        type == .m3u && !pastedPlaylist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Fields shared by every platform

    private var nameField: some View {
        TextField("Name", text: $name, prompt: appleSecondaryFieldPrompt("Name"))
            .accessibilityLabel("Name")
            .appleTVFieldOutline()
            .textContentType(.name)
            .appleSourceFieldStyle()
    }

    private var endpointField: some View {
        TextField(endpointTitle, text: $endpoint, prompt: appleSecondaryFieldPrompt(endpointTitle))
            .accessibilityLabel(Text(endpointTitle))
            .appleTVFieldOutline()
            .textContentType(.URL)
            .appleSourceFieldStyle()
            .tint(.primary)
            #if os(iOS) || os(tvOS) || os(visionOS)
            .textInputAutocapitalization(.never)
            #endif
            #if os(iOS) || os(visionOS)
            .keyboardType(.URL)
            #endif
            .autocorrectionDisabled()
    }

    private var usernameField: some View {
        TextField("Username", text: $username, prompt: appleSecondaryFieldPrompt("Username"))
            .accessibilityLabel("Username")
            .appleTVFieldOutline()
            .textContentType(.username)
            .appleSourceFieldStyle()
            #if os(iOS) || os(tvOS) || os(visionOS)
            .textInputAutocapitalization(.never)
            #endif
            #if os(iOS) || os(visionOS)
            .keyboardType(.emailAddress)
            #endif
            .autocorrectionDisabled()
    }

    private var passwordField: some View {
        AppleRevealableSecureField(
            "Password",
            text: $password,
            isRevealed: $isPasswordRevealed
        )
    }

    private enum Field: Hashable {
        case name, endpoint, username
    }

    @FocusState private var focusedField: Field?

    /// The fields actually on screen, in the order the return key walks them.
    /// Password is deliberately not in the chain: it is a composed control
    /// (field plus a reveal button), so focus applied to it would land on the
    /// wrapper rather than the field inside.
    private var fieldChain: [Field] {
        type == .xtream ? [.name, .endpoint, .username] : [.name, .endpoint]
    }

    #if os(tvOS)

    /// Apple TV: labels above stock fields, Save and Test Connection as pills
    /// in their own focus section below, the result line under them. The
    /// pills stay focusable while the form is incomplete; pressing one names
    /// what is missing instead of going inert (owner items S9, S10, S11).
    private var tvOSBody: some View {
        let metrics = AppleTVSettingsMetrics.standard
        return ScrollView {
            VStack(alignment: .leading, spacing: metrics.groupSpacing) {
                VStack(alignment: .leading, spacing: metrics.groupSpacing) {
                    AppleTVFormField("Type") {
                        HStack(spacing: metrics.iconSpacing) {
                            ForEach(AppleIPTVSourceType.allCases, id: \.self) { value in
                                AppleTVChoicePill(title: value.title, isSelected: type == value) { type = value }
                                    .accessibilityIdentifier("sources.live.type.\(value.rawValue)")
                            }
                        }
                    }

                    AppleTVFormGroup("Connection") {
                        AppleTVFormField("Name") {
                            nameField
                                .focused($focusedField, equals: .name)
                                .accessibilityIdentifier("sources.live.name")
                        }
                        AppleTVFormField(endpointTitle) {
                            endpointField
                                .focused($focusedField, equals: .endpoint)
                                .accessibilityIdentifier("sources.live.endpoint")
                        }
                        if type == .xtream {
                            AppleTVFormField("Username") {
                                usernameField
                                    .focused($focusedField, equals: .username)
                                    .accessibilityIdentifier("sources.live.username")
                            }
                            AppleTVFormField("Password") {
                                passwordField
                                    .accessibilityIdentifier("sources.live.password")
                            }
                        }
                    }
                }
                .frame(maxWidth: metrics.formColumnWidth, alignment: .leading)
                .focusSection()
                .disabled(isWorking)

                HStack(spacing: metrics.pillSpacing) {
                    Button { connectionAction = .save(UUID()) } label: { connectionLabel(saving: true) }
                        .buttonStyle(AppleTVPillStyle(isSelected: true, minimumSize: metrics.pillSize, fontSize: metrics.pillFontSize))
                        .disabled(isWorking)
                        .accessibilityIdentifier("sources.live.save")
                    Button {
                        connectionAction = .test(UUID())
                    } label: {
                        connectionLabel(saving: false)
                    }
                    .buttonStyle(AppleTVPillStyle(isSelected: false, minimumSize: metrics.pillSize, fontSize: metrics.pillFontSize))
                    .disabled(isWorking)
                    .accessibilityIdentifier("sources.live.test")
                }
                .focusSection()

                if let message {
                    AppleTVFormMessage(text: message, isError: isError)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, AppleTVChromeMetrics.verticalSafeInset)
        }
        .scrollIndicators(AppleDesignTokens.scrollIndicatorVisibility)
        .defaultFocus($focusedField, .name)
        .appleSettingsPageTitle("Add Live TV")
        .task(id: connectionAction) {
            guard let connectionAction, actionLedger.consume(connectionAction.requestID) else { return }
            await perform(connectionAction)
        }
    }
    #else
    private var standardBody: some View {
        Form {
            Section {
                Picker("Type", selection: $type) {
                    ForEach(AppleIPTVSourceType.allCases, id: \.self) { value in
                        Text(value.title).tag(value)
                    }
                }
            }
            .disabled(isWorking)

            Section("Connection") {
                nameField.appleFormSubmit(.name, chain: fieldChain, focus: $focusedField)
                endpointField.appleFormSubmit(.endpoint, chain: fieldChain, focus: $focusedField)
                if type == .xtream {
                    usernameField.appleFormSubmit(.username, chain: fieldChain, focus: $focusedField)
                    passwordField
                }
            }
            .disabled(isWorking)

            if type == .m3u {
                Section {
                    Button("Choose File…") { isChoosingFile = true }
                        .accessibilityIdentifier("sources.live.chooseFile")
                    // The system Paste control reads the clipboard without
                    // the "Allow Paste" prompt: a playlist copied as text,
                    // or a playlist address for the URL field.
                    PasteButton(payloadType: String.self) { strings in
                        acceptPastedPlaylist(strings.joined(separator: "\n"))
                    }
                    .accessibilityIdentifier("sources.live.paste")
                    if let playlistFileName {
                        LabeledContent("File", value: playlistFileName)
                        Button("Remove File", role: .destructive) {
                            pastedPlaylist = ""
                            self.playlistFileName = nil
                        }
                    }
                }
                .disabled(isWorking)
            }

            if let message {
                Section {
                    Label(message, systemImage: isError ? "exclamationmark.circle" : "checkmark.circle")
                        .foregroundStyle(.primary)
                        .accessibilityIdentifier("sources.live.result")
                }
            }

            #if os(macOS)
            // System Settings order: the default action at the trailing edge.
            AppleFormActionSection {
                testButton
                saveButton
            }
            #else
            Section {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { connectionButtons }
                    VStack(alignment: .leading, spacing: 12) { connectionButtons }
                }
                .controlSize(.large)
            }
            .listRowBackground(Color.clear)
            #endif
        }
        .scrollIndicators(AppleDesignTokens.scrollIndicatorVisibility)
        .appleSettingsPage("Add Live TV")
        .fileImporter(isPresented: $isChoosingFile, allowedContentTypes: [.m3uPlaylist, .plainText, .text, .data]) { result in
            do {
                let url = try result.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                    throw AppleIPTVError.invalidPlaylist
                }
                pastedPlaylist = text
                playlistFileName = url.lastPathComponent
                if name.isEmpty { name = url.deletingPathExtension().lastPathComponent }
            } catch {
                let failure = error as NSError
                guard failure.domain != NSCocoaErrorDomain || failure.code != NSUserCancelledError else { return }
                isError = true
                message = "The playlist file could not be opened. Choose it again or enter a playlist URL."
            }
        }
        .task(id: connectionAction) {
            guard let connectionAction, actionLedger.consume(connectionAction.requestID) else { return }
            await perform(connectionAction)
        }
    }

    /// A pasted single address goes into the URL field; pasted playlist text
    /// is imported on Save, like a chosen file.
    private func acceptPastedPlaylist(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.contains(where: \.isNewline), (try? AppleIPTVEndpointPolicy.normalize(trimmed)) != nil {
            endpoint = trimmed
            return
        }
        guard trimmed.contains("://") else {
            isError = true
            message = "The clipboard has no playlist."
            return
        }
        pastedPlaylist = trimmed
        playlistFileName = "Pasted Playlist"
    }

    private var connectionButtons: some View {
        Group {
            saveButton
            testButton
        }
    }

    private var saveButton: some View {
        Button { connectionAction = .save(UUID()) } label: {
            connectionLabel(saving: true)
        }
        .buttonStyle(.brandPrimary)
        #if os(macOS)
        .keyboardShortcut(.defaultAction)
        #endif
        .disabled(!canSubmit || isWorking)
        .accessibilityIdentifier("sources.live.save")
    }

    private var testButton: some View {
        Button { connectionAction = .test(UUID()) } label: {
            connectionLabel(saving: false)
        }
        .buttonStyle(.brandSecondary)
        .disabled(!canSubmit || isWorking)
        .accessibilityIdentifier("sources.live.test")
    }
    #endif

    private func connectionLabel(saving: Bool) -> some View {
        let active = isWorking && (connectionAction?.shouldSave == saving)
        return AppleWorkingButtonLabel(
            title: saving ? "Save" : "Test Connection",
            workingTitle: saving ? "Saving…" : "Testing…",
            isWorking: active
        )
    }

    private var canSubmit: Bool {
        submissionProblem == nil
    }

    /// Why the form cannot be submitted yet, named for the viewer; nil when
    /// it can.
    private var submissionProblem: String? {
        if usesPastedPlaylist { return nil }
        guard (try? AppleIPTVEndpointPolicy.normalize(endpoint)) != nil else {
            return type == .xtream
                ? "Enter the Xtream server URL, including the port."
                : "Enter the playlist's HTTP or HTTPS URL."
        }
        if type == .xtream {
            do {
                try AppleIPTVEndpointPolicy.validateCredentials(username: username, password: password)
            } catch {
                return error.localizedDescription
            }
        }
        return nil
    }

    private func perform(_ action: AppleInstanceConnectionAction) async {
        if let submissionProblem {
            isError = true
            message = submissionProblem
            return
        }
        let submittedType = type
        var submittedName = name
        let importingFile = usesPastedPlaylist
        let submittedEndpoint = importingFile ? AppleLocalPlaylistStore.pastedURL.absoluteString : endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if importingFile && submittedName.isEmpty { submittedName = "Playlists" }
        let submittedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let submittedPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)
        isWorking = true
        message = nil
        defer { isWorking = false }
        do {
            let source = AppleSource(
                kind: .liveTV,
                name: submittedName.isEmpty ? "My TV" : submittedName,
                url: try AppleIPTVEndpointPolicy.normalize(submittedEndpoint),
                iptvType: submittedType
            )
            let credentials = submittedType == .xtream
                ? AppleIPTVCredentials(username: submittedUsername, password: submittedPassword)
                : nil
            let channels: [AppleIPTVChannel]
            if importingFile {
                let data = Data(pastedPlaylist.utf8)
                channels = try await AppleImportStore.shared.run(title: source.name, unit: "channels") { progress in
                    try await AppleIPTVClient.parseM3UOffMain(data, sourceID: source.id, baseURL: source.url, progress: progress)
                }
                guard !channels.isEmpty else { throw AppleIPTVError.noChannels }
            } else {
                channels = try await client.validate(source: source, credentials: credentials)
            }
            try Task.checkCancellation()
            if action.shouldSave {
                let channelCount = importingFile
                    ? try AppleLocalPlaylistStore.shared.merge(text: pastedPlaylist).total
                    : channels.count
                try sourceStore.addIPTV(
                    name: submittedName,
                    type: submittedType,
                    endpoint: submittedEndpoint,
                    username: submittedUsername,
                    password: submittedPassword,
                    lastValidatedAt: .now,
                    validationSummary: "Connected · \(channelCount) channels",
                    discoveredItemCount: channelCount,
                    capabilities: ["Live channels"]
                )
                dismiss()
                return
            }
            do {
                _ = try await streamProbe.validate(channels: channels)
                try Task.checkCancellation()
                isError = false
                message = "Connected · \(channels.count) channels · Sample stream responded"
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                isError = true
                message = "Loaded \(channels.count) channels. Sample streams unavailable. \(error.localizedDescription)"
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            isError = true
            message = error.localizedDescription
        }
    }
}

@MainActor
private struct AppleWebManagementView: View {
    @State private var session: AppleWebManagementSession?
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var confirmStop = false
    @State private var confirmForget = false
    @State private var forgetNotice = false
    @State private var connectedBrowsers: [AppleWebManagementServer.ConnectedBrowser] = []
    @State private var addressWasCopied = false
    @State private var copyReceipt: Task<Void, Never>?

    let sourceStore: AppleSourceStore
    let service: any AppleWebManagementServing

    private var activeSession: AppleWebManagementSession? {
        session
    }

    var body: some View {
        platformBody
        #if DEBUG
        // Web Management is the one screen a screenshot cannot check — the
        // portal lives in a browser on another machine. This starts the
        // session at launch so the whole path (listener, address, pairing,
        // add, teardown) can be exercised from outside the app.
        .task {
            let defaults = UserDefaults.standard
            guard defaults.bool(forKey: "OpenStreamStartWebManagement")
                || defaults.bool(forKey: "OpenStreamVisionStartWebManagement") else { return }
            start()
        }
        #endif
    }

    @ViewBuilder
    private var platformBody: some View {
        #if os(tvOS)
        tvOSBody
        #else
        standardBody
        #endif
    }

    private var standardBody: some View {
        Form {
            if let activeSession {
                Section {
                    VStack(alignment: .leading, spacing: 16) {
                        addressBlock(activeSession)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        AppleWebManagementQRCode(url: activeSession.pairingURL)
                            .frame(width: 180, height: 180)
                            .frame(maxWidth: .infinity)
                    }
                } header: {
                    Text("Portal address")
                }

                Section("Pairing code") {
                    Text(activeSession.pairingCode)
                        .font(.system(size: 24, design: .monospaced))
                        .tracking(2)
                        .appleSelectableText()
                    LabeledContent("Expires", value: activeSession.expiresAt.formatted(date: .omitted, time: .shortened))
                }

                #if os(macOS)
                AppleFormActionSection { copyAddressButton(activeSession) }
                #else
                Section {
                    copyAddressButton(activeSession)
                        .listRowBackground(Color.clear)
                }
                #endif

                if !connectedBrowsers.isEmpty {
                    Section("Connected browsers") {
                        AppleWebManagementBrowserRows(browsers: connectedBrowsers, service: service)
                    }
                }

                Section {
                    stopButton
                    forgetBrowsersButton
                }
            } else {
                #if os(macOS)
                AppleFormActionSection { startButton }
                #else
                Section {
                    // Its own section with no row fill: `startButton` draws a
                    // filled capsule, and inside a grouped card that is two
                    // pieces of chrome for one control.
                    startButton
                        .listRowBackground(Color.clear)
                }
                #endif
                Section {
                    forgetBrowsersButton
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
        }
        .appleSettingsPage("Web Management")
        .alert("Stop Web Management?", isPresented: $confirmStop) {
            Button("Stop", role: .destructive) { stop() }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Forget Paired Browsers?", isPresented: $confirmForget) {
            Button("Forget", role: .destructive) {
                service.endAllBrowsers()
                AppleWebManagementTrust().forgetAllBrowsers()
                appleTrace("web management: all trusted browsers forgotten")
                forgetNotice = true
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Paired browsers forgotten", isPresented: $forgetNotice) {
            Button("OK", role: .cancel) {}
        }
        .task {
            for await updatedSession in service.sessionUpdates() {
                guard !Task.isCancelled else { return }
                session = updatedSession
                connectedBrowsers = service.connectedBrowsers
            }
        }
    }

    #if os(tvOS)
    private var tvOSBody: some View {
        let metrics = AppleTVSettingsMetrics.standard
        return ScrollView {
            VStack(alignment: .leading, spacing: metrics.groupSpacing) {
                if let activeSession {
                    // The card sizes to its own content (address, code, QR)
                    // instead of stretching to the form column width, which
                    // left a wide empty strip beside the QR code when the
                    // card was forced that wide (owner review 2026-09-15).
                    HStack(alignment: .top, spacing: 44) {
                        VStack(alignment: .leading, spacing: metrics.fieldSpacing) {
                            AppleTVFormField("Portal Address") {
                                addressBlock(activeSession, fontSize: 32, bare: true)
                            }
                            AppleTVFormField("Pairing Code") {
                                Text(activeSession.pairingCode)
                                    .font(.system(size: 30, design: .monospaced))
                                    .tracking(3)
                                    .appleSelectableText()
                            }
                            AppleTVFormField("Expires") {
                                Text(activeSession.expiresAt.formatted(date: .omitted, time: .shortened))
                                    .font(.body)
                            }
                        }

                        AppleWebManagementQRCode(url: activeSession.pairingURL)
                            .frame(width: 260, height: 260)
                    }
                    .padding(30)
                    .background(Color(white: 0.11), in: .rect(cornerRadius: 18))
                }

                if !connectedBrowsers.isEmpty {
                    Text("Connected browsers").font(.headline)
                    AppleWebManagementBrowserRows(browsers: connectedBrowsers, service: service)
                }

                HStack(spacing: 24) {
                    if activeSession == nil {
                        startButton
                    } else {
                        // `.bordered` paints both the destructive-role fill and
                        // the label red on tvOS, which read as an error state
                        // rather than a deliberate button (owner review
                        // 2026-09-15). `.brandSecondary` is the app's stock dark
                        // capsule for a weighty secondary action elsewhere in
                        // this file; it ignores role tinting, so the copy alone
                        // signals "stop."
                        stopButton
                            .buttonStyle(.brandSecondary)
                    }
                    forgetBrowsersButton
                        .buttonStyle(.brandSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
            // Laid out like Add Catalog / Add Live TV / Add Network Share, whose
            // content measures flush at x≈80 under its heading. This pane
            // measured x=223 (see `startButton` for why).
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 20)
        }
        .scrollIndicators(AppleDesignTokens.scrollIndicatorVisibility)
        .focusSection()
        .appleSettingsPageTitle("Web Management")
        .alert("Stop Web Management?", isPresented: $confirmStop) {
            Button("Stop", role: .destructive) { stop() }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Forget Paired Browsers?", isPresented: $confirmForget) {
            Button("Forget", role: .destructive) {
                service.endAllBrowsers()
                AppleWebManagementTrust().forgetAllBrowsers()
                appleTrace("web management: all trusted browsers forgotten")
                forgetNotice = true
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Paired browsers forgotten", isPresented: $forgetNotice) {
            Button("OK", role: .cancel) {}
        }
        .task {
            for await updatedSession in service.sessionUpdates() {
                guard !Task.isCancelled else { return }
                session = updatedSession
                connectedBrowsers = service.connectedBrowsers
            }
        }
    }
    #endif

    /// Ends every active browser session.
    private var forgetBrowsersButton: some View {
        Button { confirmForget = true } label: {
            Text("Forget Paired Browsers")
                .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                .contentShape(.rect)
        }
        #if !os(tvOS)
            .buttonStyle(.plain)
        #endif
            .accessibilityIdentifier("webmanagement.forget-browsers")
    }

    private var startButton: some View {
        Button {
            guard !isWorking else { return }
            start()
        } label: {
            if isWorking {
                HStack {
                    ProgressView()
                    Text("Starting")
                }
            } else {
                Text("Start Web Management")
            }
        }
        // A full-width button is right on the phone, where every control in
        // the form spans the sheet. On tvOS it stretches the capsule across the
        // page and centres its own label, which is what put Start Web
        // Management in the middle of the screen while the heading above it was
        // flush left, and pushed Forget Paired Browsers off to the right.
        // On the Mac it is a content-sized button under the form instead
        // (`AppleFormActionLayout`).
        #if !os(tvOS) && !os(macOS)
        .frame(maxWidth: .infinity)
        #endif
        .buttonStyle(.brandPrimary)
        .disabled(isWorking)
    }

    private func copyAddressButton(_ session: AppleWebManagementSession) -> some View {
        // The button says what it did. Copying is invisible — nothing on the
        // screen changes and there is no way to tell it from a dead control
        // (button crawl, 2026-09-19) — so the label carries the receipt and
        // goes back on its own.
        Button(addressWasCopied ? "Address Copied" : "Copy Address") {
            copy(session.friendlyURL)
            addressWasCopied = true
            copyReceipt?.cancel()
            copyReceipt = Task {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                addressWasCopied = false
            }
        }
        .buttonStyle(.brandSecondary)
        .animation(nil, value: addressWasCopied)
    }

    private var stopButton: some View {
        Button(role: .destructive) {
            guard !isWorking else { return }
            confirmStop = true
        } label: {
            Group {
                if isWorking {
                    HStack {
                        ProgressView()
                        Text("Stopping")
                    }
                } else {
                    Text("Stop Web Management")
                }
            }
            .frame(minWidth: 44, minHeight: 44, alignment: .leading)
            .contentShape(.rect)
        }
        #if !os(tvOS)
        .buttonStyle(.plain)
        .foregroundStyle(.red)
        // No full-width frame. It is left over from when this was a filled
        // capsule; on a plain action row it only centres the text, which left
        // "Stop Web Management" centred and "Forget Paired Browsers"
        // leading-aligned in the same card (measured 2026-09-17). Both are
        // action rows and both read from the leading edge.
        #endif
        .disabled(isWorking)
    }

    private func start() {
        isWorking = true
        errorMessage = nil

        Task { @MainActor in
            defer { isWorking = false }
            do {
                session = try await service.start(sourceStore: sourceStore)
            } catch {
                errorMessage = error.localizedDescription
                #if DEBUG
                AppleInteractionTrace.record(.failure, "web start failed: \(error.localizedDescription)")
                #endif
            }
        }
    }

    private func stop() {
        isWorking = true
        errorMessage = nil

        Task { @MainActor in
            await service.stop()
            session = nil
            isWorking = false
        }
    }

    private func copy(_ url: URL) {
        #if os(iOS) || os(visionOS)
        UIPasteboard.general.url = url
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([url as NSURL])
        #endif
    }

    /// `bare` drops the scheme and trailing slash, matching what the portal
    /// page itself shows for the address a browser typed or scanned
    /// (`AppleWebManagementServer.displayAddress`); `Copy Address` still
    /// copies the full URL, so only the on-screen text changes.
    private func addressBlock(_ session: AppleWebManagementSession, fontSize: CGFloat = 22, bare: Bool = false) -> some View {
        Text(bare ? Self.bareAddress(session.friendlyURL) : session.friendlyURL.absoluteString)
            .font(.system(size: fontSize, design: .monospaced))
            .lineLimit(1)
            .minimumScaleFactor(15 / fontSize)
            .appleSelectableText()
    }

    private static func bareAddress(_ url: URL) -> String {
        guard let host = url.host else { return url.absoluteString }
        guard let port = url.port else { return host }
        return "\(host):\(port)"
    }
}

private struct AppleWebManagementBrowserRows: View {
    let browsers: [AppleWebManagementServer.ConnectedBrowser]
    let service: any AppleWebManagementServing

    var body: some View {
        ForEach(browsers) { browser in
            HStack {
                VStack(alignment: .leading) {
                    Text(browser.name)
                    Text(browser.lastActivity, style: .time)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("End") { service.endBrowser(id: browser.id) }
                    .buttonStyle(.brandSecondary)
                    .accessibilityLabel("End \(browser.name) session")
            }
        }
    }
}

struct AppleWebManagementQRCode: View {
    let url: URL
    var accessibilityText = "Web Management QR code"

    var body: some View {
        if let image = Self.image(for: url) {
            ZStack {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .padding()
                    .background(.white, in: .rect(cornerRadius: 16))
            }
            .frame(maxWidth: 280, maxHeight: 280)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
        }
    }

    private static func image(for url: URL) -> CGImage? {
        let key = url.absoluteString as NSString
        if let cached = cache.object(forKey: key) { return cached.image }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: .init(scaleX: 12, y: 12)) else { return nil }
        guard let image = context.createCGImage(output, from: output.extent) else { return nil }
        cache.setObject(CachedImage(image), forKey: key)
        return image
    }

    private final class CachedImage {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private static let cache = NSCache<NSString, CachedImage>()
    private static let context = CIContext(options: [.useSoftwareRenderer: false])
}


private extension View {
    @ViewBuilder
    func appleSelectableText() -> some View {
        #if os(tvOS)
        self
        #else
        self.textSelection(.enabled)
        #endif
    }
}
