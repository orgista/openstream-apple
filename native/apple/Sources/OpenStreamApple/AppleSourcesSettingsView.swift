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
    @State private var networkGroups: [AppleNetworkShareGroup] = []
    @State private var ungroupedSources: [AppleSource] = []
    #if DEBUG
    @State private var debugDetailSourceID: AppleSource.ID?
    #endif
    #if os(tvOS)
    /// Apple TV has no Backup & Sync page, so what iCloud sync last did is
    /// shown here instead (`AppleConfigurationSyncStatus`).
    @AppStorage(AppleConfigurationSyncStatus.defaultsKey) private var syncStatusData: Data?
    @AppStorage(AppleDeviceReset.cloudRestoreHeldKey) private var cloudRestoreHeld = false
    #endif

    let sourceStore: AppleSourceStore
    let settings: AppleSettingsStore
    let webManagement: any AppleWebManagementServing
    /// True inside the Apple TV Settings split view's detail pane, where the
    /// header is drawn at the pane's leading edge instead of as a page title.
    var embeddedInSplit = false
    var backupController: AppleConfigurationController? = nil

    private var showsNoSourcesLine: Bool {
        #if os(tvOS)
        false
        #else
        sourceStore.sources.isEmpty
        #endif
    }

    #if os(tvOS)
    private var syncStatus: AppleConfigurationSyncStatus {
        syncStatusData.flatMap { try? JSONDecoder().decode(AppleConfigurationSyncStatus.self, from: $0) }
            ?? AppleConfigurationSyncStatus()
    }
    #endif

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
                NavigationLink(value: AppleSourceRoute.webManagement) {
                    AppleTVNavigationLabel("Web Management", systemImage: "network")
                }
                .appleTVReadableFocus()
                #if os(tvOS)
                // Apple TV only receives, so Transfer opens the receiver.
                Button {
                    AppleSetupTransferCenter.shared.presentReceiver()
                } label: {
                    AppleTVNavigationLabel("Transfer", systemImage: "arrow.left.arrow.right")
                }
                .foregroundStyle(.primary)
                .appleTVReadableFocus()
                .accessibilityIdentifier("settings.transfer")
                #endif
            }

            #if !os(tvOS)
            AppleLineupImportSection()
            #endif

            // Not "Sources" again: the pane is already titled Sources, so the
            // screen read "Sources … Sources" (review 2026-09-14).
            // Uppercased on Apple TV only: this pane is a `List` there while
            // the other settings panes are `Form`s, and a tvOS Form uppercases
            // its section headers while a List does not — so this one header
            // read "Your Sources" beside "CHANNEL PREFERENCES" and
            // "CONNECTION". Everywhere else the header takes the platform's
            // own case like its neighbours; forcing it read "YOUR SOURCES"
            // among the Mac's title-case headers (N54 #13).
            // Apple TV draws no "No sources" line: text alone cannot take focus.
            if showsNoSourcesLine || !ungroupedSources.isEmpty {
                Section {
                    if sourceStore.sources.isEmpty {
                        Text("No sources")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(ungroupedSources) { source in
                            NavigationLink(value: AppleSourceRoute.detail(source.id)) {
                                AppleSourceRow(source: source)
                            }
                            .appleTVReadableFocus()
                        }
                    }
                } header: {
                    // Scoped to the header on purpose: `.textCase` on the Section
                    // uppercases its *rows* too, which turned every source name
                    // into capitals.
                    Text("Your Sources")
                        #if os(tvOS)
                        .textCase(.uppercase)
                        #endif
                }
            }
            ForEach(networkGroups) { group in
                AppleNetworkShareSourcesSection(group: group)
            }
            #if os(tvOS)
            if let backupController {
                Section {
                    // The status rides under an action: a status-only row
                    // took focus and did nothing (owner 2026-11-04).
                    Button {
                        Task { await backupController.syncNow() }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            AppleWorkingButtonLabel(title: "Sync Now", workingTitle: "Syncing…",
                                                    isWorking: backupController.isSyncing, alignment: .leading)
                            AppleConfigurationSyncStatusLines(status: syncStatus)
                        }
                    }
                    .accessibilityIdentifier("sources.icloud.syncNow")
                    if cloudRestoreHeld {
                        Button("Resume iCloud Sync") {
                            Task { await backupController.restoreFromCloud() }
                        }
                        .accessibilityIdentifier("sources.icloud.resume")
                    }
                } header: {
                    Text("iCloud Sync").textCase(.uppercase)
                }
            }
            #endif
        }
        .onChange(of: sourceStore.sources, initial: true) {
            networkGroups = AppleNetworkSharePolicy.groups(in: sourceStore.sources)
            let groupedIDs = Set(networkGroups.flatMap { $0.sources.map(\.id) })
            ungroupedSources = sourceStore.sources.filter { !groupedIDs.contains($0.id) }
        }
        .appleSettingsPane("Sources", embedded: embeddedInSplit)
        .scrollIndicators(AppleDesignTokens.scrollIndicatorVisibility)
        .navigationDestination(for: AppleSourceRoute.self) { route in
            switch route {
            case .addFiles:
                AppleAddFilesView(
                    sourceStore: sourceStore,
                    settings: settings,
                    webManagement: webManagement
                )
            case .addLiveTV:
                AppleAddLiveTVSourceView(sourceStore: sourceStore)
            case .addMediaServer:
                AppleAddMediaServerView(sourceStore: sourceStore)
            case .addNetworkShare:
                AppleNetworkShareConnectView(start: .add(nil), flow: .shared, sourceStore: sourceStore)
            case .networkShareServer(let server):
                AppleNetworkShareConnectView(start: .add(server), flow: .shared, sourceStore: sourceStore)
            case .addNetworkShareFolder(let id):
                AppleNetworkShareConnectView(start: .addFolder(id), flow: .shared, sourceStore: sourceStore)
            case .editNetworkShare(let id, let part):
                AppleNetworkShareConnectView(start: .edit(id, part), flow: .shared, sourceStore: sourceStore)
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
            debugDetailSourceID = sourceStore.sources.first?.id
        }
        #endif
    }
}

enum AppleSourceRoute: Hashable {
    case addFiles
    case addLiveTV
    case addMediaServer
    case addNetworkShare
    /// A server found on the network: Connect with its address filled in.
    case networkShareServer(AppleNetworkShareServer)
    case addNetworkShareFolder(AppleSource.ID)
    case editNetworkShare(AppleSource.ID, AppleNetworkShareEditPart)
    case webManagement
    case detail(AppleSource.ID)
}

private struct AppleAddFilesView: View {
    let sourceStore: AppleSourceStore
    let settings: AppleSettingsStore
    let webManagement: any AppleWebManagementServing
    @State private var directURL = ""
    @State private var showingDirectURL = false
    @State private var playback: AppleMediaPlayerPresentation?
    @State private var playbackError: String?
    @State private var discovered: [AppleSMBServer] = []
    @State private var isDiscovering = false
    #if !os(tvOS)
    @State private var showingLibraryImporter = false
    @State private var importError: String?
    #endif
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
                            playback = AppleMediaPlayerPresentation(
                                request: AppleDirectPlaybackInput.request(for: url), settings: settings)
                        }
                    }
                    Button("Cancel", role: .cancel) { }
                }
            }
        }
        .appleSettingsPage("Add Files")
        .scrollIndicators(AppleDesignTokens.scrollIndicatorVisibility)
        #if !os(tvOS)
        .fileImporter(isPresented: $showingLibraryImporter, allowedContentTypes: [.folder], allowsMultipleSelection: false) {
            importFolder($0)
        }
        .alert("Couldn’t Add Folder", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "The folder could not be added.")
        }
        #endif
        #if DEBUG
        .task {
            if let raw = UserDefaults.standard.string(forKey: "OpenStreamVisionPlaybackURL"),
               let url = AppleDirectPlaybackInput.url(raw) ?? URL(string: raw).flatMap({ $0.isFileURL ? $0 : nil }) {
                let mediaID = ApplePlaybackIdentity.digest(for: url.absoluteString)
                if UserDefaults.standard.bool(forKey: "OpenStreamClearFixturePlayback") {
                    guard url.lastPathComponent == "e2e-long.mp4", url.user == nil, url.password == nil else { return }
                    ApplePlaybackStore().clear(mediaID: mediaID)
                    AppleInteractionTrace.record(.playback, "fixture playback progress cleared")
                    return
                }
                var request: ApplePlaybackRequest
                if UserDefaults.standard.bool(forKey: "OpenStreamVisionPlaybackIsLive") {
                    request = AppleIPTVChannel(id: mediaID, sourceID: UUID(), name: "Caption fixture",
                                               streamURL: url).playbackRequest()
                } else {
                    request = AppleDirectPlaybackInput.request(for: url)
                }
                #if os(visionOS)
                if UserDefaults.standard.bool(forKey: "OpenStreamImmersiveProxy") {
                    do { request = try await AppleDebugImmersiveProbe.proxyRequest(request) }
                    catch { appleTrace("immersive probe: proxy failed"); return }
                }
                #endif
                if let rawStart = UserDefaults.standard.string(forKey: "OpenStreamDiscStart"),
                   let start = AppleDiscPlaybackStart(rawValue: rawStart) {
                    request.hints.disc = AppleDiscPlaybackChoice(start: start)
                }
                playback = AppleMediaPlayerPresentation(request: request, settings: settings)
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
        .modifier(AppleMediaPlayerPresentationModifier(presentation: $playback))
        .alert("Invalid Video URL", isPresented: Binding(get: { playbackError != nil }, set: { if !$0 { playbackError = nil } })) {
            Button("OK", role: .cancel) { playbackError = nil }
        } message: { Text(playbackError ?? "") }
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
            if (error as? CocoaError)?.code == .userCancelled { return }
            importError = (error as? AppleLibrarySourceError)?.errorDescription ?? error.localizedDescription
        }
    }
    #endif

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
/// a long host name, a share path, a validation summary — breaks
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
    }

    @ViewBuilder
    private var sourceIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.secondary.opacity(0.15))

            Image(systemName: source.kind.systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(6)
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityHidden(true)
    }
}

private extension AppleSourceKind {
    var systemImage: String {
        switch self {
        case .library: "books.vertical"
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
    @State private var hasSavedMediaServerSession: Bool?
    @State private var enableRequest: UUID?
    @State private var requestedEnabled = false
    @State private var isEnabling = false
    @State private var connectionError: String?
    @AppStorage(AppleOStreamFeedPreference.offKey) private var serverFeedOff = ""

    let sourceID: AppleSource.ID
    let sourceStore: AppleSourceStore
    let settings: AppleSettingsStore

    private var usesServerFeed: Binding<Bool> {
        Binding(get: { _ = serverFeedOff; return AppleOStreamFeedPreference.isOn(sourceID) },
                set: { AppleOStreamFeedPreference.setOn($0, sourceID: sourceID) })
    }

    private var source: AppleSource? {
        sourceStore.sources.first { $0.id == sourceID }
    }

    private var enabled: Binding<Bool> {
        Binding(
            get: { source?.isEnabled ?? false },
            set: { enabled in
                requestedEnabled = enabled
                enableRequest = UUID()
            }
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
                        }
                        if let status = source.validationStatus {
                            LabeledContent("Status") {
                                Text(status)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .multilineTextAlignment(.trailing)
                            }
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
                        switch AppleSourceEnableControl.control(for: source, hasSavedMediaServerSession: hasSavedMediaServerSession) {
                        case .checking:
                            LabeledContent("Enabled") { ProgressView() }
                                .accessibilityIdentifier("source.detail.checkingSession")
                        case .toggle:
                            Toggle("Enabled", isOn: enabled)
                                .disabled(isEnabling)
                                .accessibilityIdentifier("source.detail.enabled")
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
                        if source.kind == .mediaServer,
                           AppleOStreamFeedPreference.hasAnswered(sourceID) || !AppleOStreamFeedPreference.isOn(sourceID) {
                            Toggle("Use Rill's rows", isOn: usesServerFeed)
                                .accessibilityIdentifier("source.detail.serverRows")
                        }
                        if let connectionError { Text(connectionError) }
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

                    Section {
                        if source.kind == .mediaServer, !source.needsSignIn {
                            Button("Sign Out", role: .destructive) {
                                do {
                                    try sourceStore.signOutMediaServer(id: sourceID)
                                    hasSavedMediaServerSession = false
                                } catch { connectionError = "Could not sign out." }
                            }
                            .disabled(isEnabling)
                            .accessibilityIdentifier("source.detail.signOut")
                        }
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
        .task(id: sourceID) {
            guard let source, source.kind == .mediaServer else { return }
            hasSavedMediaServerSession = nil
            do {
                let hasSession = try await sourceStore.hasSavedMediaServerSession(for: source)
                try Task.checkCancellation()
                hasSavedMediaServerSession = hasSession
            } catch {
                if Task.isCancelled { return }
                hasSavedMediaServerSession = false
                connectionError = "Could not read the saved sign-in."
            }
        }
        .task(id: enableRequest) {
            guard let request = enableRequest, !Task.isCancelled else { return }
            let enabled = requestedEnabled
            isEnabling = true
            connectionError = nil
            defer {
                if enableRequest == request {
                    isEnabling = false
                    enableRequest = nil
                }
            }
            do {
                try await sourceStore.setEnabled(enabled, id: sourceID)
                guard enableRequest == request, !Task.isCancelled else { return }
                if enabled, source?.kind == .mediaServer { hasSavedMediaServerSession = true }
            } catch let error as AppleMediaServerError {
                guard enableRequest == request, !Task.isCancelled else { return }
                if error == .invalidCredentials { hasSavedMediaServerSession = false }
                connectionError = AppleMediaServerFormPolicy.message(for: error, serverName: source?.name)
            } catch {
                guard enableRequest == request, !Task.isCancelled else { return }
                connectionError = "Could not read the saved sign-in."
            }
        }
        .alert("Delete Source?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                if sourceStore.remove(id: sourceID) { dismiss() }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func locationLabel(_ source: AppleSource) -> String {
        switch source.kind {
        case .library: "Folder"
        case .liveTV: "Server"
        default: "Location"
        }
    }

    private func healthLabel(_ source: AppleSource) -> String {
        if source.hasCurrentValidationFailure {
            return "Needs attention"
        }
        if source.savedPlaylistHealth != nil { return "Showing saved channels" }
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

/// Two or more choices shown as pills (Provider Login / M3U Playlist, the
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

    /// Apple TV: labels above stock fields, Save and Test as pills
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
            title: saving ? "Save" : "Test",
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
                ? "Enter the provider's server URL, including the port."
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
            let announcesImport = action.shouldSave && !sourceStore.sources.contains { $0.kind == .liveTV }
            let channels: [AppleIPTVChannel]
            if importingFile && announcesImport {
                let data = Data(pastedPlaylist.utf8)
                channels = try await AppleImportStore.shared.run(title: source.name, unit: "channels") { progress in
                    try await AppleIPTVClient.parseM3UOffMain(data, sourceID: source.id, baseURL: source.url, progress: progress)
                }
                guard !channels.isEmpty else { throw AppleIPTVError.noChannels }
            } else if importingFile {
                channels = try await AppleIPTVClient.parseM3UOffMain(Data(pastedPlaylist.utf8), sourceID: source.id, baseURL: source.url, progress: { _ in })
                guard !channels.isEmpty else { throw AppleIPTVError.noChannels }
            } else {
                channels = try await client.validate(source: source, credentials: credentials, announcesImport: announcesImport)
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
                        .accessibilityIdentifier("webmanagement.pairingCode")
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
                                    .accessibilityIdentifier("webmanagement.pairingCode")
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
        // Content-sized actions share one row on TV and Mac.
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
            .accessibilityIdentifier("webmanagement.address")
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

@MainActor
private struct AppleNetworkShareSourcesSection: View {
    let group: AppleNetworkShareGroup

    var body: some View {
        Section {
            ForEach(group.sources) { source in
                NavigationLink(value: AppleSourceRoute.detail(source.id)) { AppleSourceRow(source: source) }
                    .appleTVReadableFocus()
                    .accessibilityIdentifier("sources.smb.saved.\(source.id)")
            }
            if let sourceID = group.sources.first?.id {
                NavigationLink(value: AppleSourceRoute.addNetworkShareFolder(sourceID)) {
                    AppleTVNavigationLabel("Add Folder", systemImage: "folder.badge.plus")
                }
                .appleTVReadableFocus()
                .accessibilityIdentifier("sources.smb.addToShare.\(group.id)")
            }
        } header: {
            // Same tvOS uppercase as "Your Sources" (header only, never the rows).
            Text(group.title)
                #if os(tvOS)
                .textCase(.uppercase)
                #endif
        }
    }
}

#if !os(tvOS)
struct AppleLineupImportSection: View {
    @State private var lineup = AppleChannelLineupStore.shared.current
    @State private var choosingFile = false
    @State private var lineupURL = ""
    @State private var isFetching = false
    @State private var importTask: Task<Void, Never>?
    @State private var resultMessage: String?

    var body: some View {
        Section("Channel Lineup") {
            if let lineup {
                Text(lineup.name).accessibilityIdentifier("lineup.name")
            }
            Button("Import Lineup…", systemImage: "square.and.arrow.down") { choosingFile = true }
                .accessibilityIdentifier("lineup.import.file")
            TextField("Lineup URL", text: $lineupURL)
                .autocorrectionDisabled()
                #if os(iOS) || os(visionOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
                .accessibilityIdentifier("lineup.url")
            Button("Import URL", action: fetchLineup)
                .disabled(isFetching || lineupURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("lineup.import.url")
            if isFetching { ProgressView().accessibilityLabel("Importing lineup") }
        }
        .onReceive(NotificationCenter.default.publisher(for: AppleChannelLineupStore.didChange).receive(on: RunLoop.main)) { _ in
            lineup = AppleChannelLineupStore.shared.current
        }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.openStreamLineup, .json]) { result in
            do {
                try AppleChannelLineupStore.shared.importFile(result.get())
                resultMessage = "Lineup imported."
            } catch {
                if (error as? CocoaError)?.code == .userCancelled { return }
                resultMessage = (error as? AppleChannelLineupError)?.errorDescription ?? "Could not open the lineup file."
            }
        }
        .alert("Channel Lineup", isPresented: Binding(
            get: { resultMessage != nil }, set: { if !$0 { resultMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: { Text(resultMessage ?? "") }
        .onDisappear { importTask?.cancel() }
    }

    private func fetchLineup() {
        guard let url = URL(string: lineupURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            resultMessage = AppleChannelLineupError.couldNotDownload.errorDescription
            return
        }
        isFetching = true
        importTask = Task {
            defer { isFetching = false }
            do {
                try await AppleChannelLineupStore.shared.importURL(url)
                resultMessage = "Lineup imported."
            } catch is CancellationError { return }
            catch { resultMessage = (error as? AppleChannelLineupError)?.errorDescription ?? "Could not download the lineup." }
        }
    }
}
#endif
