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
    Text(title).foregroundColor(.white)
    #elseif os(tvOS)
    Text(title).italic().foregroundStyle(.tertiary)
    #else
    Text(title).foregroundStyle(.secondary)
    #endif
}

@MainActor
public protocol AppleWebManagementServing: AnyObject {
    var session: AppleWebManagementSession? { get }

    func sessionUpdates() -> AsyncStream<AppleWebManagementSession?>
    func start(sourceStore: AppleSourceStore) async throws -> AppleWebManagementSession
    func stop() async
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

    let sourceStore: AppleSourceStore
    let settings: AppleSettingsStore
    let webManagement: any AppleWebManagementServing
    /// True inside the Apple TV Settings split view's detail pane, where the
    /// header is drawn at the pane's leading edge instead of as a page title.
    var embeddedInSplit = false

    var body: some View {
        List {
            Section {
                NavigationLink(value: AppleSourceRoute.addFiles) {
                    AppleTVNavigationLabel("Add Files", systemImage: "folder.badge.plus")
                }
                .appleTVReadableFocus()
                NavigationLink(value: AppleSourceRoute.addInstance) {
                    AppleTVNavigationLabel("Add Instance", systemImage: "plus.circle")
                }
                .appleTVReadableFocus()

                NavigationLink(value: AppleSourceRoute.addManifest) {
                    AppleTVNavigationLabel("Add Catalog", systemImage: "square.stack.3d.up")
                }
                .appleTVReadableFocus()
                NavigationLink(value: AppleSourceRoute.addLiveTV) {
                    AppleTVNavigationLabel("Add Live TV", systemImage: "dot.radiowaves.left.and.right")
                }
                .appleTVReadableFocus()

                NavigationLink(value: AppleSourceRoute.webManagement) {
                    AppleTVNavigationLabel("Web Management", systemImage: "network")
                }
                .appleTVReadableFocus()
            }

            // Not "Sources" again: the pane is already titled Sources, so the
            // screen read "Sources … Sources" (review 2026-09-14).
            // Uppercased explicitly: this pane is a `List` while the other
            // settings panes are `Form`s, and on tvOS a Form uppercases its
            // section headers while a List does not — so this one header read
            // "Your Sources" beside "CHANNEL PREFERENCES" and "CONNECTION"
            // everywhere else.
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
                Text("Your Sources").textCase(.uppercase)
            }
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
            case .addManifest:
                AppleAddManifestSourceView(sourceStore: sourceStore)
            case .addLiveTV:
                AppleAddLiveTVSourceView(sourceStore: sourceStore)
            case .addNetworkShare:
                AppleAddNetworkShareView(sourceStore: sourceStore)
            case .addARR:
                AppleServerDownloadsSettingsView(settings: settings)
            case .webManagement:
                AppleWebManagementView(sourceStore: sourceStore, service: webManagement)
            case .detail(let sourceID):
                AppleSourceDetailView(sourceID: sourceID, sourceStore: sourceStore, settings: settings)
            }
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
    case addManifest
    case addLiveTV
    case addNetworkShare
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
                    NavigationLink {
                        AppleAddNetworkShareView(sourceStore: sourceStore, initialServer: server)
                    } label: {
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
        #if DEBUG && os(visionOS)
        .task {
            if let raw = UserDefaults.standard.string(forKey: "OpenStreamVisionPlaybackURL"),
               let url = AppleDirectPlaybackInput.url(raw) {
                playback = AppleStremioPlayerPresentation(
                    request: ApplePlaybackRequest(url: url,
                        mediaID: ApplePlaybackIdentity.digest(for: url.absoluteString),
                        title: url.lastPathComponent, sourceKind: .files), settings: settings)
            }
        }
        #endif
        .task(id: discoveryTaskIdentity) {
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
    /// Same idea for the Stremio mark: one failure and the row goes back to
    /// its monogram rather than refetching on every redraw.
    @State private var brandIconFailed = false

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
            brandIconFailed = false
        }
    }

    @ViewBuilder
    private var sourceIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.secondary.opacity(0.15))

            if source.kind == .stremio, let logoURL = source.logoURL, !logoIsWordmark, !logoFailed {
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
            } else if let brandURL = AppleStremioBrandIcon.fallbackURL(kind: source.kind, manifestURL: source.url),
                      !brandIconFailed {
                AppleRemoteImage(
                    url: brandURL,
                    contentMode: .fit,
                    placeholderSystemImage: source.kind.systemImage,
                    onLoad: { _ in },
                    onFailure: { brandIconFailed = true }
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
    /// iconless kinds (IPTV, ServerPlus, Library) use the shared glyph.
    private var sourceFallbackIcon: some View {
        Group {
            if source.kind == .stremio, let initial = source.name.trimmingCharacters(in: .whitespaces).first {
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
        case .stremio: "square.stack.3d.up"
        case .youtube: "play.rectangle"
        case .liveTV: "dot.radiowaves.left.and.right"
        case .nas: "externaldrive.connected.to.line.below"
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
                        AppleTruncatingValue(locationLabel(source), value: sourceLocation(source))
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
                        if let lastFailureAt = source.lastValidationFailureAt {
                            LabeledContent(
                                "Last Failure",
                                value: lastFailureAt.formatted(date: .abbreviated, time: .shortened)
                            )
                            if let failure = source.validationFailureSummary {
                                LabeledContent("Failure", value: failure)
                            }
                        }
                        Toggle("Enabled", isOn: enabled)
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

    private func locationLabel(_ source: AppleSource) -> String {
        switch source.kind {
        case .stremio: "Manifest Host"
        case .library: "Folder"
        case .liveTV: "Server"
        default: "Location"
        }
    }

    private func healthLabel(_ source: AppleSource) -> String {
        if let failure = source.lastValidationFailureAt,
           failure > (source.lastValidatedAt ?? .distantPast) {
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

@MainActor
private struct AppleAddManifestSourceView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var manifestURL = ""
    @State private var isAdding = false
    @State private var errorMessage: String?

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
                    AppleTVFormMessage(text: errorMessage, isError: true)
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
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }

            Section {
                Button {
                    addManifest()
                } label: {
                    if isAdding {
                        ProgressView()
                    } else {
                        Text("Add Catalog")
                    }
                }
                .disabled(isAdding || !hasManifestURL)
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

        Task { @MainActor in
            defer { isAdding = false }
            do {
                // Subtitle languages are picked from the add-on's own detail
                // page, so adding a catalog just returns to Sources.
                _ = try await sourceStore.addStremio(manifestValue: manifestURL)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private enum AppleInstanceConnectionAction: Equatable {
    case test(UUID)
    case save(UUID)

    var shouldSave: Bool {
        if case .save = self { return true }
        return false
    }
}

#if os(tvOS)
/// One Apple TV form field: a Caption 1 (25 pt) label above the stock field,
/// whose focused chrome the system draws (rework plan task 8).
private struct AppleTVFormField<Field: View>: View {
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
private struct AppleTVFormGroup<Content: View>: View {
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
private struct AppleTVFormMessage: View {
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
private struct AppleTVChoicePill: View {
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
/// Settings app's do); the plain in-row style inside forms elsewhere.
private extension View {
    @ViewBuilder
    func appleSourceFieldStyle() -> some View {
        #if os(tvOS)
        self
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
private struct AppleRevealableSecureField: View {
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
                .textContentType(.password)
                #if os(iOS) || os(tvOS) || os(visionOS)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
        } else {
                SecureField(title, text: $text, prompt: appleSecondaryFieldPrompt(title))
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

    /// M3U text pasted or read from a chosen file. Saved into the one local
    /// playlist (`AppleLocalPlaylistStore.pastedURL`), so every paste joins
    /// the same source row.
    @State private var pastedPlaylist = ""
    @State private var isChoosingFile = false

    let sourceStore: AppleSourceStore
    private let client = AppleIPTVClient()
    private let streamProbe = AppleIPTVStreamProbe()

    var body: some View {
        #if os(tvOS)
        tvOSBody
        #else
        standardBody
        #endif
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
            .textContentType(.name)
            .appleSourceFieldStyle()
    }

    private var endpointField: some View {
        TextField(endpointTitle, text: $endpoint, prompt: appleSecondaryFieldPrompt(endpointTitle))
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

                HStack(spacing: metrics.pillSpacing) {
                    Button("Save") { connectionAction = .save(UUID()) }
                        .buttonStyle(AppleTVPillStyle(isSelected: true, minimumSize: metrics.pillSize, fontSize: metrics.pillFontSize))
                        .disabled(isWorking)
                        .accessibilityIdentifier("sources.live.save")
                    Button {
                        connectionAction = .test(UUID())
                    } label: {
                        if isWorking { ProgressView() } else { Text("Test Connection") }
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
            guard let connectionAction else { return }
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

            Section("Connection") {
                nameField.appleFormSubmit(.name, chain: fieldChain, focus: $focusedField)
                endpointField.appleFormSubmit(.endpoint, chain: fieldChain, focus: $focusedField)
                if type == .xtream {
                    usernameField.appleFormSubmit(.username, chain: fieldChain, focus: $focusedField)
                    passwordField
                }
            }

            if type == .m3u {
                Section("Playlist Text") {
                    TextEditor(text: $pastedPlaylist)
                        .font(.footnote.monospaced())
                        .frame(minHeight: 120)
                        .autocorrectionDisabled()
                        .accessibilityLabel("Playlist text")
                        .accessibilityIdentifier("sources.live.playlistText")
                    Button("Choose File…") { isChoosingFile = true }
                        .accessibilityIdentifier("sources.live.chooseFile")
                }
            }

            if let message {
                Section {
                    Label(message, systemImage: isError ? "exclamationmark.circle" : "checkmark.circle")
                        .foregroundStyle(isError ? .red : .primary)
                }
            }

            Section {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { connectionButtons }
                    VStack(alignment: .leading, spacing: 12) { connectionButtons }
                }
                .controlSize(.large)
            }
        }
        .appleSettingsPage("Add Live TV")
        .fileImporter(isPresented: $isChoosingFile, allowedContentTypes: [.m3uPlaylist, .plainText, .text, .data]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url),
               let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {
                pastedPlaylist = text
                if name.isEmpty { name = url.deletingPathExtension().lastPathComponent }
            }
        }
        .task(id: connectionAction) {
            guard let connectionAction else { return }
            await perform(connectionAction)
        }
    }

    @ViewBuilder
    private var connectionButtons: some View {
        Button("Save") {
            connectionAction = .save(UUID())
        }
        .buttonStyle(PrimaryPillButtonStyle())
        .disabled(!canSubmit || isWorking)

        Button {
            connectionAction = .test(UUID())
        } label: {
            if isWorking { ProgressView() } else { Text("Test Connection") }
        }
        .buttonStyle(.brandSecondary)
        .disabled(!canSubmit || isWorking)
    }
    #endif

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
        if type == .xtream, username.isEmpty || password.isEmpty {
            return "Enter the Xtream username and password."
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
        var submittedEndpoint = endpoint
        var mergeNote = ""
        if usesPastedPlaylist {
            do {
                let merged = try AppleLocalPlaylistStore.shared.merge(text: pastedPlaylist)
                submittedEndpoint = AppleLocalPlaylistStore.pastedURL.absoluteString
                if submittedName.isEmpty { submittedName = "Playlists" }
                mergeNote = " · \(merged.added) added, \(merged.total) total"
            } catch {
                isError = true
                message = error.localizedDescription
                return
            }
        }
        let submittedUsername = username
        let submittedPassword = password
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
            let channels = try await client.validate(source: source, credentials: credentials)
            let probe = try await streamProbe.validate(channels: channels)
            try Task.checkCancellation()
            if action.shouldSave {
                let summary = "Connected · \(channels.count) channels\(mergeNote) · Playback verified (\(probe.bytesReceived.formatted()) bytes)"
                try sourceStore.addIPTV(
                    name: submittedName,
                    type: submittedType,
                    endpoint: submittedEndpoint,
                    username: submittedUsername,
                    password: submittedPassword,
                    lastValidatedAt: .now,
                    validationSummary: summary,
                    discoveredItemCount: channels.count,
                    capabilities: ["Live channels", "Playback"]
                )
                dismiss()
                return
            }
            isError = false
            message = "Connected · \(channels.count) channels\(mergeNote) · Playback verified (\(probe.bytesReceived.formatted()) bytes)"
        } catch is CancellationError {
            return
        } catch {
            isError = true
            message = error.localizedDescription
        }
    }
}

@MainActor
private struct AppleAddNetworkShareView: View {
    /// Port and Domain sit inside DisclosureGroups, so they are not chain
    /// stops: sending focus to a collapsed field is a dead end. Password is
    /// out for the same reason as the Live TV form — it is a field plus a
    /// reveal button, so focus would land on the wrapper.
    private enum SubmitField: Hashable { case name, address, folder, username }
    private static let chain: [SubmitField] = [.name, .address, .folder, .username]
    @FocusState private var shareFocus: SubmitField?

    @Environment(\.dismiss) private var dismiss
    private let initialServer: AppleSMBServer?
    @State private var name = ""
    @State private var host = ""
    @State private var port = "445"
    @State private var address = ""
    @State private var share = ""
    @State private var path = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isPasswordRevealed = false
    @State private var domain = ""
    @State private var selectedDisplayHost: String?
    @State private var shares: [AppleSMBShare] = []
    @State private var isWorking = false
    @State private var message: String?
    @State private var isError = false
    @State private var connectionAction: AppleInstanceConnectionAction?
    @State private var showingAdvanced = false

    let sourceStore: AppleSourceStore
    private let client = AppleSMBClient()
    private let discovery = AppleSMBDiscovery()

    /// Which pill should show the spinner. Derived from the action already in
    /// flight so there is no second piece of state to keep in step.
    private var isSavingAction: Bool {
        if case .save = connectionAction { return true }
        return false
    }

    init(sourceStore: AppleSourceStore, initialServer: AppleSMBServer? = nil) {
        self.sourceStore = sourceStore
        self.initialServer = initialServer
        _name = State(initialValue: initialServer?.name ?? "")
        _host = State(initialValue: initialServer?.host ?? "")
        _port = State(initialValue: String(initialServer?.port ?? 445))
        _address = State(initialValue: initialServer.map { Self.addressLabel(host: $0.host, port: $0.port) } ?? "")
        _selectedDisplayHost = State(initialValue: initialServer?.displayHost)
    }

    var body: some View {
        #if os(tvOS)
        tvOSBody
        #else
        standardBody
        #endif
    }

    // MARK: Fields shared by every platform

    private var nameField: some View {
        TextField("Name", text: $name, prompt: appleSecondaryFieldPrompt("Name"))
            .textContentType(.name)
    }

    private var addressField: some View {
        TextField("Server URL", text: addressBinding, prompt: appleSecondaryFieldPrompt("Server URL"))
            .textContentType(.URL)
            #if os(iOS) || os(tvOS) || os(visionOS)
            .textInputAutocapitalization(.never)
            #endif
            .autocorrectionDisabled()
    }

    private var portField: some View {
        TextField("Port", text: $port, prompt: appleSecondaryFieldPrompt("Port"))
            #if os(iOS) || os(visionOS)
            .keyboardType(.numberPad)
            #endif
    }

    private var folderField: some View {
        TextField("Folder", text: $path, prompt: appleSecondaryFieldPrompt("Folder"))
            .autocorrectionDisabled()
    }

    private var usernameField: some View {
        TextField("Username", text: $username, prompt: appleSecondaryFieldPrompt("Username"))
            .textContentType(.username)
            #if os(iOS) || os(tvOS) || os(visionOS)
            .textInputAutocapitalization(.never)
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

    private var domainField: some View {
        TextField("Domain", text: $domain, prompt: appleSecondaryFieldPrompt("Domain"))
            #if os(iOS) || os(tvOS) || os(visionOS)
            .textInputAutocapitalization(.never)
            #endif
            .autocorrectionDisabled()
    }

    #if os(tvOS)
    private enum Field: Hashable {
        case name, address, port, folder, username, domain
    }

    @FocusState private var focusedField: Field?

    /// Apple TV: Server, Share and Account groups with Caption 1 labels above
    /// stock fields; the server's shares as pills once loaded; Save and Test
    /// Connection as pills in their own focus section; the exact SMB reason
    /// (authentication, access denied, unreachable) under them (owner W4).
    private var tvOSBody: some View {
        let metrics = AppleTVSettingsMetrics.standard
        return ScrollView {
            VStack(alignment: .leading, spacing: metrics.groupSpacing) {
                VStack(alignment: .leading, spacing: metrics.groupSpacing) {
                    AppleTVFormGroup("Server") {
                        AppleTVFormField("Name") {
                            nameField
                                .focused($focusedField, equals: .name)
                                .accessibilityIdentifier("sources.smb.name")
                        }
                        AppleTVFormField("Server URL") {
                            addressField
                                .focused($focusedField, equals: .address)
                                .accessibilityIdentifier("sources.smb.address")
                        }
                        AppleTVFormField("Port") {
                            portField
                                .focused($focusedField, equals: .port)
                                .accessibilityIdentifier("sources.smb.port")
                        }
                    }

                    AppleTVFormGroup("Share") {
                        if shares.isEmpty {
                            Button("Load Shares") { loadShares() }
                                .buttonStyle(AppleTVPillStyle(isSelected: false, minimumSize: metrics.pillSize, fontSize: metrics.pillFontSize))
                                .disabled(isWorking)
                                .accessibilityIdentifier("sources.smb.loadShares")
                        } else {
                            AppleTVFormField("Share") {
                                LazyVGrid(
                                    columns: [GridItem(.adaptive(minimum: 280), spacing: metrics.iconSpacing, alignment: .leading)],
                                    alignment: .leading,
                                    spacing: metrics.iconSpacing
                                ) {
                                    ForEach(shares) { value in
                                        AppleTVChoicePill(title: shareLabel(value), isSelected: share == value.name) {
                                            share = value.name
                                        }
                                        .accessibilityIdentifier("sources.smb.share.\(value.name)")
                                    }
                                }
                            }
                        }
                        AppleTVFormField("Folder") {
                            folderField
                                .focused($focusedField, equals: .folder)
                                .accessibilityIdentifier("sources.smb.folder")
                        }
                    }

                    AppleTVFormGroup("Account") {
                        AppleTVFormField("Username") {
                            usernameField
                                .focused($focusedField, equals: .username)
                                .accessibilityIdentifier("sources.smb.username")
                        }
                        AppleTVFormField("Password") {
                            passwordField
                                .accessibilityIdentifier("sources.smb.password")
                        }
                        AppleTVFormField("Domain") {
                            domainField
                                .focused($focusedField, equals: .domain)
                                .accessibilityIdentifier("sources.smb.domain")
                        }
                    }
                }
                .frame(maxWidth: metrics.formColumnWidth, alignment: .leading)
                .focusSection()

                // Neither button disables while work is in flight. Disabling
                // the button the viewer just pressed takes focus off it, and
                // tvOS then has nowhere obvious to put focus — which is why
                // testing a share looked like the screen had locked up (owner
                // 2026-09-15). Re-entry is guarded in the action instead, so
                // focus stays put and the pill shows its own progress.
                HStack(spacing: metrics.pillSpacing) {
                    Button {
                        guard !isWorking else { return }
                        connectionAction = .save(UUID())
                    } label: {
                        if isWorking, isSavingAction { ProgressView() } else { Text("Save") }
                    }
                    .buttonStyle(AppleTVPillStyle(isSelected: true, minimumSize: metrics.pillSize, fontSize: metrics.pillFontSize))
                    .accessibilityIdentifier("sources.smb.save")
                    Button {
                        guard !isWorking else { return }
                        connectionAction = .test(UUID())
                    } label: {
                        if isWorking, !isSavingAction { ProgressView() } else { Text("Test Connection") }
                    }
                    .buttonStyle(AppleTVPillStyle(isSelected: false, minimumSize: metrics.pillSize, fontSize: metrics.pillFontSize))
                    .accessibilityIdentifier("sources.smb.test")
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
        .appleSettingsPageTitle("Add Network Share")
        .task(id: connectionAction) {
            guard let connectionAction else { return }
            await perform(connectionAction)
        }
        .onChange(of: host) { _, value in
            address = Self.addressLabel(host: value, port: selectedPort ?? 445)
        }
        .onChange(of: port) { _, value in
            address = Self.addressLabel(host: host, port: Int(value) ?? 445)
        }
    }
    #else
    private var standardBody: some View {
        Form {
            serverSection
            shareSection
            accountSection
            Section {
                Button("Test Connection") {
                    connectionAction = .test(UUID())
                }
                .buttonStyle(SecondaryPillButtonStyle())
                .disabled(isWorking)
            }
            if let message {
                Section {
                    Label(message, systemImage: isError ? "exclamationmark.circle" : "checkmark.circle")
                        .foregroundStyle(isError ? .red : .primary)
                }
            }
        }
        .appleSettingsPage("Add Network Share")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { connectionAction = .save(UUID()) }
                    .disabled(isWorking)
                    #if os(visionOS)
                    .buttonStyle(.brandPrimary)
                    #endif
                    .accessibilityIdentifier("sources.smb.save")
            }
        }
        .task(id: connectionAction) {
            guard let connectionAction else { return }
            await perform(connectionAction)
        }
        .onChange(of: host) { _, value in
            address = Self.addressLabel(host: value, port: selectedPort ?? 445)
        }
        .onChange(of: port) { _, value in
            address = Self.addressLabel(host: host, port: Int(value) ?? 445)
        }
    }

    @ViewBuilder
    private var serverSection: some View {
        Section("Server") {
            nameField.appleFormSubmit(.name, chain: Self.chain, focus: $shareFocus)
            addressField.appleFormSubmit(.address, chain: Self.chain, focus: $shareFocus)
            DisclosureGroup("Advanced", isExpanded: $showingAdvanced) {
                portField
            }
        }
    }

    @ViewBuilder
    private var shareSection: some View {
        Section("Share") {
            if shares.isEmpty {
                Button("Load Shares") { loadShares() }
                    .disabled(!hasServer || isWorking)
                    .appleTVReadableFocus()
            } else {
                Picker("Share", selection: $share) {
                    Text("Share").tag("")
                    ForEach(shares) { value in
                        Text(shareLabel(value)).tag(value.name)
                    }
                }
            }
            folderField.appleFormSubmit(.folder, chain: Self.chain, focus: $shareFocus)
        }
    }

    @ViewBuilder
    private var accountSection: some View {
        Section("Account") {
            usernameField.appleFormSubmit(.username, chain: Self.chain, focus: $shareFocus)
            passwordField
            DisclosureGroup("Advanced") {
                domainField
            }
        }
    }
    #endif

    private func shareLabel(_ value: AppleSMBShare) -> String {
        value.comment.isEmpty ? value.name : "\(value.name) · \(value.comment)"
    }

    private var selectedPort: Int? { Int(port) }
    private var addressBinding: Binding<String> {
        Binding(
            get: { address },
            set: { value in
                address = value
                if let parsed = Self.parseAddress(value) {
                    host = parsed.host
                    port = String(parsed.port)
                } else {
                    host = value
                }
            }
        )
    }

    private var hasServer: Bool {
        serverInput != nil
    }
    private var endpointInput: AppleSMBEndpointInput? {
        let parsed = Self.parseAddress(address)
        return try? AppleSMBEndpointPolicy.parseInput(
            host: parsed?.host ?? host,
            port: parsed?.port ?? selectedPort ?? 0,
            share: share,
            path: path
        )
    }
    private var serverInput: AppleSMBEndpointInput? {
        let parsed = Self.parseAddress(address)
        return try? AppleSMBEndpointPolicy.parseInput(
            host: parsed?.host ?? host,
            port: parsed?.port ?? selectedPort ?? 0,
            share: "",
            path: "",
            requiresShare: false
        )
    }
    private var credentials: AppleSMBCredentials {
        AppleSMBCredentials(username: username, password: password, domain: domain)
    }

    private func loadShares() {
        guard serverInput != nil else {
            isError = true
            message = "Enter a valid server address and port."
            return
        }
        let parsed = Self.parseAddress(address)
        guard let listingInput = try? AppleSMBEndpointPolicy.parseInput(
            host: parsed?.host ?? host,
            port: parsed?.port ?? selectedPort ?? 0,
            share: "IPC$",
            path: ""
        ) else { return }
        let submittedCredentials = credentials
        isWorking = true
        message = nil
        Task { @MainActor in
            defer { isWorking = false }
            do {
                let resolved = try await resolvedEndpoint(listingInput)
                shares = try await client.listShares(
                    host: resolved.host,
                    port: resolved.port,
                    credentials: submittedCredentials
                )
                isError = false
                message = shares.isEmpty ? "The server returned no visible shares." : nil
            } catch {
                isError = true
                message = error.localizedDescription
            }
        }
    }

    private func perform(_ action: AppleInstanceConnectionAction) async {
        guard let endpointInput else {
            isError = true
            message = "Enter a valid server address, port, and share."
            return
        }
        guard !share.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            isError = true
            message = "Choose a share before saving."
            return
        }
        let submittedName = name
        let submittedUsername = username
        let submittedPassword = password
        let submittedDomain = domain
        let submittedDisplayHost = selectedDisplayHost ?? endpointInput.host
        let submittedCredentials = credentials
        isWorking = true
        message = nil
        defer { isWorking = false }
        do {
            let resolved = try await resolvedEndpoint(endpointInput)
            let url = try AppleSMBEndpointPolicy.makeURL(
                host: resolved.host,
                port: resolved.port,
                share: resolved.share,
                path: resolved.path
            )
            let items = try await client.listDirectory(
                url: url,
                credentials: submittedCredentials,
                recursive: true
            )
            try Task.checkCancellation()
            let summary = "Connected · \(items.count) item\(items.count == 1 ? "" : "s")"
            if action.shouldSave {
                try sourceStore.addNetworkShare(
                    name: submittedName,
                    host: resolved.host,
                    port: resolved.port,
                    share: resolved.share,
                    path: resolved.path,
                    username: submittedUsername,
                    password: submittedPassword,
                    domain: submittedDomain,
                    displayHost: submittedDisplayHost,
                    lastValidatedAt: .now,
                    validationSummary: summary,
                    discoveredItemCount: items.count,
                    capabilities: ["Browse", "Playback", "Seeking"]
                )
                dismiss()
                return
            }
            isError = false
            message = summary
        } catch is CancellationError {
            return
        } catch {
            isError = true
            message = error.localizedDescription
        }
    }

    private func resolvedEndpoint(_ input: AppleSMBEndpointInput) async throws -> AppleSMBEndpointInput {
        guard let service = AppleSMBEndpointPolicy.bonjourService(from: input.host) else { return input }
        guard let server = await discovery.resolve(service: service) else {
            throw AppleSMBError.connectionFailed
        }
        return AppleSMBEndpointInput(
            host: server.host,
            port: server.port,
            share: input.share,
            path: input.path
        )
    }

    private static func addressLabel(host: String, port: Int) -> String {
        let value = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return "\(value):\(port)"
    }

    private static func parseAddress(_ value: String) -> (host: String, port: Int)? {
        var clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.lowercased().hasPrefix("smb://"), let url = URL(string: clean) {
            guard let host = url.host, !host.isEmpty else { return nil }
            return (host, url.port ?? 445)
        }
        clean = clean.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if clean.hasPrefix("["), let close = clean.firstIndex(of: "]") {
            let host = String(clean[clean.index(after: clean.startIndex)..<close])
            let suffix = String(clean[clean.index(after: close)...])
            let port = suffix.hasPrefix(":") ? Int(suffix.dropFirst()) : 445
            guard !host.isEmpty, let port, (1 ... 65_535).contains(port) else { return nil }
            return (host, port)
        }
        if let separator = clean.lastIndex(of: ":"),
           clean[clean.index(after: separator)...].allSatisfy(\.isNumber),
           let port = Int(clean[clean.index(after: separator)...]) {
            let host = String(clean[..<separator])
            guard !host.isEmpty, (1 ... 65_535).contains(port) else { return nil }
            return (host, port)
        }
        guard !clean.isEmpty, !clean.contains(":") else { return nil }
        return (clean, 445)
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

    let sourceStore: AppleSourceStore
    let service: any AppleWebManagementServing

    private var activeSession: AppleWebManagementSession? {
        guard let session, !session.isExpired else { return nil }
        return session
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
                        AppleWebManagementQRCode(url: activeSession.friendlyURL)
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

                Section {
                    Button("Copy Address") {
                        copy(activeSession.friendlyURL)
                    }
                    .buttonStyle(.brandSecondary)
                    .listRowBackground(Color.clear)
                }

                Section {
                    stopButton
                    forgetBrowsersButton
                }
            } else {
                Section {
                    // Its own section with no row fill: `startButton` draws a
                    // filled capsule, and inside a grouped card that is two
                    // pieces of chrome for one control.
                    startButton
                        .listRowBackground(Color.clear)
                }
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

                        AppleWebManagementQRCode(url: activeSession.friendlyURL)
                            .frame(width: 260, height: 260)
                    }
                    .padding(30)
                    .background(Color(white: 0.11), in: .rect(cornerRadius: 18))
                }

                // Revocation belongs wherever the feature is used, and the
                // television is where it is used. A browser stays trusted for
                // thirty days; leaving the only way to untrust it on the phone
                // layout would make that a one-way door on the device that
                // actually shows the pairing code.
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
            }
        }
    }
    #endif

    /// Revokes every remembered browser, so the pairing code is required again.
    ///
    /// Trusting a browser for thirty days is only safe if it can be untrusted;
    /// without this the feature would be a one-way door.
    private var forgetBrowsersButton: some View {
        Button("Forget Paired Browsers") { confirmForget = true }
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
        #if !os(tvOS)
        .frame(maxWidth: .infinity)
        #endif
        .buttonStyle(.brandPrimary)
        .disabled(isWorking)
    }

    private var stopButton: some View {
        Button(role: .destructive) {
            guard !isWorking else { return }
            confirmStop = true
        } label: {
            if isWorking {
                HStack {
                    ProgressView()
                    Text("Stopping")
                }
            } else {
                Text("Stop Web Management")
            }
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

private struct AppleWebManagementQRCode: View {
    let url: URL

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
            .accessibilityLabel("Web Management QR code")
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
