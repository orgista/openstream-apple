import SwiftUI

#if os(iOS) || os(visionOS)
import UIKit
#endif

/// Field prompts, as on the other source forms: tertiary italic on Apple TV so
/// an empty field never reads as a filled-in value.
private func appleSecondaryFieldPrompt(_ title: String) -> Text {
    #if os(visionOS)
    Text(title).foregroundStyle(.white)
    #elseif os(tvOS)
    // Tertiary italic on black could not be read from the couch (full test
    // 2026-10-01); secondary is the contrast tvOS gives its own placeholders.
    Text(title).foregroundStyle(.secondary)
    #elseif os(iOS)
    Text(title).foregroundStyle(Color(uiColor: .secondaryLabel))
    #else
    Text(title).foregroundStyle(.secondary)
    #endif
}

/// Pages pushed inside a network share flow. Registered by the Connect page,
/// so they only exist while that page is on the stack.
enum AppleNetworkShareRoute: Hashable {
    /// Nil is the server itself, listing its shares.
    case browse(AppleNetworkShareLocation?)
    case confirm([AppleNetworkShareLocation])
}

enum AppleNetworkShareEditPart: String, Hashable, Sendable {
    case server
    case folder
    case account
}

/// What a Connect page was opened for.
enum AppleNetworkShareStart: Hashable {
    /// A new share; a discovered server arrives with its address filled in.
    case add(AppleNetworkShareServer?)
    case addFolder(AppleSource.ID)
    case edit(AppleSource.ID, AppleNetworkShareEditPart)
}

extension AppleNetworkShareSetup {
    /// Builds the flow for a start point, reading any saved account from the
    /// store. Nil when the edited source no longer exists.
    static func make(
        for start: AppleNetworkShareStart,
        sourceStore: AppleSourceStore,
        client: any AppleNetworkShareClient = AppleSMBClient(),
        discovery: AppleSMBDiscovery = AppleSMBDiscovery()
    ) -> AppleNetworkShareSetup? {
        let resolve: Resolver = { service in await discovery.resolve(service: service) }
        switch start {
        case .add(let server):
            let saved = server.flatMap { server in
                AppleNetworkSharePolicy.savedCredentials(for: server, in: sourceStore.sources) {
                    try? sourceStore.networkCredentials(for: $0)
                }
            }
            return AppleNetworkShareSetup(server: server, savedCredentials: saved, existingSources: sourceStore.sources, client: client, resolve: resolve)
        case .addFolder(let id):
            guard let source = sourceStore.sources.first(where: { $0.id == id && $0.kind == .nas }),
                  let parts = try? AppleSMBEndpointPolicy.parts(from: source.url) else { return nil }
            let host = source.networkDisplayHost ?? parts.host
            let server = AppleNetworkShareServer(name: host, host: parts.host, port: parts.port, displayHost: host)
            let saved = (try? sourceStore.networkCredentials(for: source))
                ?? AppleNetworkSharePolicy.savedCredentials(for: server, in: sourceStore.sources) {
                    try? sourceStore.networkCredentials(for: $0)
                }
            return AppleNetworkShareSetup(server: server, savedCredentials: saved,
                existingSources: sourceStore.sources, initialBrowseLocation: .init(share: parts.share),
                client: client, resolve: resolve)
        case .edit(let id, let part):
            guard let source = sourceStore.sources.first(where: { $0.id == id && $0.kind == .nas }),
                  let parts = try? AppleSMBEndpointPolicy.parts(from: source.url) else { return nil }
            let displayHost = source.networkDisplayHost ?? parts.host
            let server = AppleNetworkShareServer(
                name: displayHost,
                host: parts.host,
                port: parts.port,
                displayHost: displayHost
            )
            let purpose: AppleNetworkShareSetup.Purpose = switch part {
            case .server: .editServer(id)
            case .folder: .editFolder(id)
            case .account: .editAccount(id)
            }
            return AppleNetworkShareSetup(
                purpose: purpose,
                server: server,
                currentLocation: AppleNetworkShareLocation(share: parts.share, path: parts.path),
                existingName: source.name,
                savedCredentials: (try? sourceStore.networkCredentials(for: source))
                    ?? AppleSMBCredentials(username: "", password: ""),
                existingSources: sourceStore.sources,
                client: client,
                resolve: resolve
            )
        }
    }
}

/// The flow in progress. One app-wide instance: only one setup runs at a
/// time, and the Sources pane is rebuilt often enough that state it owned
/// reached its Browse and Add destinations as several different copies.
@MainActor
@Observable
final class AppleNetworkShareFlow {
    static let shared = AppleNetworkShareFlow()

    var setup: AppleNetworkShareSetup?
    /// Path depth to return to when the flow ends.
    var originDepth: Int?
}

/// Browse or Add, for whichever flow is in progress.
@MainActor
struct AppleNetworkShareStepView: View {
    @Environment(\.appleSettingsNavigator) private var navigator
    @Environment(\.dismiss) private var dismiss
    let route: AppleNetworkShareRoute
    let flow: AppleNetworkShareFlow
    let sourceStore: AppleSourceStore

    var body: some View {
        if let setup = flow.setup {
            switch route {
            case .browse(let location):
                AppleNetworkShareBrowseView(setup: setup, location: location, sourceStore: sourceStore)
            case .confirm(let locations):
                AppleNetworkShareConfirmView(setup: setup, locations: locations, sourceStore: sourceStore) {
                    if let navigator, let depth = flow.originDepth { navigator.pop(depth) } else { dismiss() }
                }
            }
        } else {
            ContentUnavailableView("Share Not Found", systemImage: "questionmark.folder")
                .appleSettingsPageTitle("Network Share")
        }
    }
}

// MARK: - Step 2: Connect

@MainActor
struct AppleNetworkShareConnectView: View {
    @Environment(\.appleSettingsNavigator) private var navigator
    @Environment(\.dismiss) private var dismiss
    @State private var setup: AppleNetworkShareSetup?
    @State private var didLoad = false

    let start: AppleNetworkShareStart
    let flow: AppleNetworkShareFlow
    let sourceStore: AppleSourceStore

    var body: some View {
        Group {
            if let setup {
                AppleNetworkShareConnectForm(setup: setup, title: title, onConnected: { advance(setup) })
            } else if didLoad {
                ContentUnavailableView("Source Not Found", systemImage: "questionmark.folder")
                    .appleSettingsPageTitle(title)
            } else {
                Color.clear
                    .appleSettingsPageTitle(title)
            }
        }
        .onAppear {
            // Coming back from Browse re-selects this flow; a fresh page
            // records where the flow started.
            if let setup { flow.setup = setup }
            guard !didLoad else { return }
            didLoad = true
            flow.originDepth = navigator.map { max($0.depth() - 1, 0) }
            #if DEBUG
            if openDebugFixture() { return }
            #endif
            setup = AppleNetworkShareSetup.make(for: start, sourceStore: sourceStore)
            flow.setup = setup
        }
    }

    private var title: String {
        switch start {
        case .add(let server): server?.name ?? "Add Network Share"
        case .addFolder: "Add Folder"
        case .edit(_, .server): "Server"
        case .edit(_, .folder): "Folder"
        case .edit(_, .account): "Account"
        }
    }

    private func advance(_ setup: AppleNetworkShareSetup) {
        switch setup.outcome {
        case .browse:
            navigator?.push(AppleNetworkShareRoute.browse(setup.initialBrowseLocation))
        case .saveAccount:
            if setup.saveAccount(to: sourceStore) { finish() }
        }
    }

    #if DEBUG
    /// Screenshot fixture: `-OpenStreamDebugNetworkShareFixture browse|add`
    /// opens the flow against an in-memory server at fixture.example and walks
    /// to that step. Nothing is saved unless Add is pressed by hand.
    private func openDebugFixture() -> Bool {
        guard case .add(nil) = start,
              let step = UserDefaults.standard.string(forKey: "OpenStreamDebugNetworkShareFixture") else { return false }
        let fixture = AppleNetworkShareSetup(client: AppleNetworkShareDebugFixtureClient())
        fixture.address = "fixture.example"
        setup = fixture
        flow.setup = fixture
        Task { @MainActor in
            guard await fixture.connect(), let navigator else { return }
            let media = AppleNetworkShareLocation(share: "Media")
            if step.hasPrefix("multi") {
                fixture.toggleSelection(media.appending("Movies"))
                fixture.toggleSelection(media.appending("TV Shows"))
            }
            let steps: [AppleNetworkShareRoute] = step == "multi-add"
                ? [.browse(nil), .browse(media), .confirm(fixture.selectedLocations)]
                : step == "add"
                ? [.browse(nil), .browse(media), .confirm([media.appending("Movies")])]
                : [.browse(nil), .browse(media)]
            for route in steps {
                try? await Task.sleep(for: .milliseconds(700))
                navigator.push(route)
            }
        }
        return true
    }
    #endif

    /// Back to the page the flow started from (the shares list, or the
    /// source being edited), where the saved share now shows.
    private func finish() {
        if let navigator, let originDepth = flow.originDepth {
            navigator.pop(originDepth)
        } else {
            dismiss()
        }
    }
}

/// Only what connecting needs: the address (unless the server was found on
/// the network) and who to connect as. Connecting is the test.
@MainActor
private struct AppleNetworkShareConnectForm: View {
    @Bindable var setup: AppleNetworkShareSetup
    let title: String
    let onConnected: () -> Void

    @State private var connectRequest: UUID?
    /// A connect runs once per press, not again when the page reappears.
    @State private var connectLedger = AppleOneShotRequestLedger()
    @State private var isPasswordRevealed = false
    @State private var showingAdvanced = false
    @FocusState private var focus: Field?

    private enum Field: Hashable { case address, port, username, domain }

    var body: some View {
        content
            .appleSettingsPageTitle(title)
            .task {
                // A server this device already signed in to goes straight to
                // its folders; the page stays behind it for changing account.
                if await setup.connectWithSavedCredentials() { onConnected() }
            }
            .task(id: connectRequest) {
                guard connectLedger.consume(connectRequest) else { return }
                if await setup.connect() { onConnected() }
            }
    }

    private func connect() {
        guard !setup.isConnecting else { return }
        connectRequest = UUID()
    }

    #if os(tvOS)
    private var content: some View {
        let metrics = AppleTVSettingsMetrics.standard
        return ScrollView {
            VStack(alignment: .leading, spacing: metrics.groupSpacing) {
                AppleTVFormGroup("Server") {
                    if let server = setup.fixedServer {
                        serverSummary(server)
                    } else {
                        AppleTVFormField("Server or IP") {
                            addressField
                                .focused($focus, equals: .address)
                        }
                        AppleTVFormField("Port") {
                            portField
                                .focused($focus, equals: .port)
                        }
                    }
                }
                .frame(maxWidth: metrics.formColumnWidth, alignment: .leading)
                .focusSection()

                AppleTVFormGroup("Connect As") {
                    HStack(spacing: metrics.iconSpacing) {
                        ForEach(AppleNetworkShareAccount.allCases) { account in
                            AppleTVChoicePill(title: account.title, isSelected: setup.account == account) {
                                setup.account = account
                            }
                            .accessibilityIdentifier("sources.smb.account.\(account.rawValue)")
                        }
                    }
                    if setup.account == .registered {
                        AppleTVFormField("Username") {
                            usernameField
                                .focused($focus, equals: .username)
                        }
                        AppleTVFormField("Password") {
                            passwordField
                        }
                        AppleTVFormField("Domain") {
                            domainField
                                .focused($focus, equals: .domain)
                        }
                    }
                }
                .frame(maxWidth: metrics.formColumnWidth, alignment: .leading)
                .focusSection()

                // Never disabled while connecting: disabling the focused pill
                // throws focus somewhere arbitrary. Re-entry is guarded instead.
                Button(action: connect) {
                    if setup.isConnecting { ProgressView() } else { Text("Connect") }
                }
                .buttonStyle(AppleTVPillStyle(isSelected: true, minimumSize: metrics.pillSize, fontSize: metrics.pillFontSize))
                .accessibilityIdentifier("sources.smb.connect")
                .focusSection()

                if let error = setup.connectError {
                    AppleTVFormMessage(text: error, isError: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, AppleTVChromeMetrics.verticalSafeInset)
        }
        .scrollIndicators(AppleDesignTokens.scrollIndicatorVisibility)
        .defaultFocus($focus, setup.fixedServer == nil ? .address : nil)
    }

    private func serverSummary(_ server: AppleNetworkShareServer) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(server.name)
                .font(.body)
            Text(server.endpointLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
    #else
    private var content: some View {
        Form {
            Section {
                if let server = setup.fixedServer {
                    LabeledContent(server.name, value: server.endpointLabel)
                    if setup.account == .registered {
                        DisclosureGroup("Advanced", isExpanded: $showingAdvanced) {
                            domainField
                                .focused($focus, equals: .domain)
                        }
                    }
                } else {
                    addressField
                        .focused($focus, equals: .address)
                        .onSubmit(connect)
                        #if os(macOS)
                        .labelsHidden()
                        #endif
                    // One Advanced group: a second one under Connect As (for
                    // the domain) read as a duplicate control (UX tour 2026-10-08).
                    DisclosureGroup("Advanced", isExpanded: $showingAdvanced) {
                        LabeledContent("Port") {
                            portField
                                .focused($focus, equals: .port)
                                .multilineTextAlignment(.trailing)
                                .labelsHidden()
                        }
                        if setup.account == .registered {
                            domainField
                                .focused($focus, equals: .domain)
                        }
                    }
                }
            } header: {
                Text("Server")
            }

            Section {
                Picker("Connect As", selection: $setup.account) {
                    ForEach(AppleNetworkShareAccount.allCases) { account in
                        Text(account.title).tag(account)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityIdentifier("sources.smb.account")

                if setup.account == .registered {
                    usernameField
                        .focused($focus, equals: .username)
                        .onSubmit(connect)
                    passwordField
                        .onSubmit(connect)
                }
            } header: {
                Text("Connect As")
            }

            if let error = setup.connectError {
                Section {
                    Label(error, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("sources.form.message")
                }
            }
            #if os(macOS)
            AppleFormActionSection { connectButton }
            #endif
        }
        .appleSettingsContent()
        #if !os(macOS)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                connectButton
            }
        }
        #endif
    }

    private var connectButton: some View {
        Button(action: connect) {
            if setup.isConnecting {
                ProgressView()
                    .controlSize(.small)
            } else {
                Text("Connect")
            }
        }
        .disabled(!setup.canConnect)
        #if os(macOS) || os(visionOS)
        .buttonStyle(.brandPrimary)
        #endif
        .keyboardShortcut(.defaultAction)
        .accessibilityIdentifier("sources.smb.connect")
    }
    #endif

    // MARK: Fields

    private var addressField: some View {
        TextField("Server or IP", text: $setup.address, prompt: appleSecondaryFieldPrompt("Server or IP"))
            .accessibilityLabel("Server or IP")
            .appleTVFieldOutline()
            .textContentType(.URL)
            #if os(iOS) || os(tvOS) || os(visionOS)
            .textInputAutocapitalization(.never)
            #endif
            #if os(iOS) || os(visionOS)
            .keyboardType(.URL)
            #endif
            .autocorrectionDisabled()
            .accessibilityIdentifier("sources.smb.address")
    }

    private var portField: some View {
        TextField("Port", text: $setup.port, prompt: appleSecondaryFieldPrompt("445"))
            .accessibilityLabel("Port")
            .appleTVFieldOutline()
            #if os(iOS) || os(visionOS)
            .keyboardType(.numberPad)
            #endif
            .accessibilityIdentifier("sources.smb.port")
    }

    private var usernameField: some View {
        TextField("Username", text: $setup.username, prompt: appleSecondaryFieldPrompt("Username"))
            .accessibilityLabel("Username")
            .appleTVFieldOutline()
            .textContentType(.username)
            #if os(iOS) || os(tvOS) || os(visionOS)
            .textInputAutocapitalization(.never)
            #endif
            .autocorrectionDisabled()
            .accessibilityIdentifier("sources.smb.username")
    }

    private var passwordField: some View {
        AppleRevealableSecureField("Password", text: $setup.password, isRevealed: $isPasswordRevealed)
            .accessibilityIdentifier("sources.smb.password")
    }

    private var domainField: some View {
        TextField("Domain", text: $setup.domain, prompt: appleSecondaryFieldPrompt("Domain"))
            .accessibilityLabel("Domain")
            .appleTVFieldOutline()
            #if os(iOS) || os(tvOS) || os(visionOS)
            .textInputAutocapitalization(.never)
            #endif
            .autocorrectionDisabled()
            .accessibilityIdentifier("sources.smb.domain")
    }
}

// MARK: - Step 3: Browse

/// One level of the server: its shares at the top, folders below that.
@MainActor
struct AppleNetworkShareBrowseView: View {
    let setup: AppleNetworkShareSetup
    let location: AppleNetworkShareLocation?
    let sourceStore: AppleSourceStore

    @State private var listing: AppleNetworkShareListing?
    @State private var failure: String?
    @State private var attempt = 0

    var body: some View {
        AppleSettingsCollection {
            #if !os(macOS)
            Section { addButton }
            #endif
            if let location, setup.allowsMultipleFolders {
                Section {
                    HStack {
                        Text(location.folderName)
                        Spacer()
                        selectionButton(location)
                    }
                }
            }
            Section {
                rows
            } header: {
                if let location {
                    Text(breadcrumb(location))
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
        }
        .appleSettingsPageTitle(title)
        .scrollIndicators(AppleDesignTokens.scrollIndicatorVisibility)
        #if os(macOS)
        .safeAreaInset(edge: .bottom) {
            AppleFormActionBar { addButton.buttonStyle(.brandPrimary).keyboardShortcut(.defaultAction) }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
        #endif
        .onAppear { setup.updateExistingSources(sourceStore.sources) }
        .onChange(of: sourceStore.sources, initial: true) {
            setup.updateExistingSources(sourceStore.sources)
        }
        .task(id: attempt) {
            guard let location else { return }
            failure = nil
            do {
                listing = try await setup.listing(at: location)
            } catch is CancellationError {
                return
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    @Environment(\.appleSettingsNavigator) private var navigator

    private var title: String {
        location?.folderName ?? setup.server?.name ?? "Shares"
    }

    @ViewBuilder
    private var rows: some View {
        if location == nil {
            if setup.shares.isEmpty {
                Text("No Shares")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(setup.shares) { share in
                    folderLink(
                        name: share.name,
                        destination: AppleNetworkShareLocation(share: share.name),
                        systemImage: "externaldrive.connected.to.line.below"
                    )
                    .accessibilityIdentifier("sources.smb.share.\(share.name)")
                }
            }
        } else if let failure {
            Text(failure)
                .foregroundStyle(.secondary)
            Button("Try Again") { attempt += 1 }
                .appleTVReadableFocus()
        } else if let listing {
            if listing.folders.isEmpty {
                Text("No Folders")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(listing.folders) { folder in
                    folderLink(name: folder.name, destination: folder.location, systemImage: "folder")
                        .accessibilityIdentifier("sources.smb.folder.\(folder.name)")
                }
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, alignment: .center)
                .accessibilityLabel("Loading folders")
        }
    }

    private func folderLink(
        name: String,
        destination: AppleNetworkShareLocation,
        systemImage: String
    ) -> some View {
        HStack {
            NavigationLink(value: AppleNetworkShareRoute.browse(destination)) {
                AppleNetworkShareFolderRow(name: name, systemImage: systemImage, videoCount: setup.videoCounts[destination])
            }
            .appleTVReadableFocus()
            if setup.allowsMultipleFolders { selectionButton(destination) }
        }
        #if os(tvOS)
        .focusSection()
        #endif
        .task { await setup.loadVideoCount(at: destination) }
    }

    private var foldersToConfirm: [AppleNetworkShareLocation] {
        if setup.allowsMultipleFolders, !setup.selectedLocations.isEmpty { return setup.selectedLocations }
        guard let location, setup.selectionState(for: location).canToggle else { return [] }
        return [location]
    }

    private var addTitle: String {
        if !setup.allowsMultipleFolders { return "Save This Folder" }
        let count = setup.selectedLocations.count
        return count > 1 ? "Add \(count) Folders" : "Add Folders"
    }

    private var addButton: some View {
        Button {
            let folders = foldersToConfirm
            guard !folders.isEmpty else { return }
            navigator?.push(AppleNetworkShareRoute.confirm(folders))
        } label: {
            AppleTVNavigationLabel(addTitle, systemImage: "plus.circle")
                .foregroundStyle(.primary)
        }
        .appleTVReadableFocus()
        .disabled(foldersToConfirm.isEmpty)
        .accessibilityIdentifier("sources.smb.addFolder")
    }

    private func selectionButton(_ destination: AppleNetworkShareLocation) -> some View {
        let state = setup.selectionState(for: destination)
        return Button {
            guard state.canToggle else { return }
            setup.toggleSelection(destination)
        } label: {
            Image(systemName: state.isChecked ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(.primary)
                .frame(minWidth: 44, minHeight: 44)
        }
        #if os(tvOS)
        .buttonStyle(.borderless)
        .opacity(state.canToggle ? 1 : 0.5)
        #else
        .buttonStyle(.plain)
        #endif
        .disabled(!state.canToggle)
        .accessibilityLabel("Select \(destination.folderName)")
        .accessibilityValue(state == .added ? "Already added" : state == .overlap ? "Overlapping folder" : state.isChecked ? "Selected" : "Not selected")
        .accessibilityIdentifier("sources.smb.select.\(destination.share)/\(destination.path)")
    }

    private func breadcrumb(_ location: AppleNetworkShareLocation) -> String {
        ([setup.server?.name, location.share].compactMap { $0 }
            + location.path.split(separator: "/").map(String.init))
            .joined(separator: " › ")
    }
}

private struct AppleNetworkShareFolderRow: View {
    let name: String
    let systemImage: String
    let videoCount: Int?

    var body: some View {
        HStack {
            AppleTVNavigationLabel(name, systemImage: systemImage)
            Spacer(minLength: 12)
            if let videoCount, videoCount > 0 {
                Label(videoCount.formatted(), systemImage: "film")
                    .labelStyle(.titleAndIcon)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .accessibilityLabel("\(videoCount) video\(videoCount == 1 ? "" : "s")")
            }
        }
    }
}

// MARK: - Step 4: Add

@MainActor
struct AppleNetworkShareConfirmView: View {
    let setup: AppleNetworkShareSetup
    let locations: [AppleNetworkShareLocation]
    let sourceStore: AppleSourceStore
    let onFinish: () -> Void

    @State private var folders: [AppleNetworkShareNamedFolder] = []
    @State private var failure: String?
    @State private var didPrefill = false
    @State private var isSaving = false

    private var actionTitle: String { setup.purpose == .add ? "Add" : "Save" }
    private var title: String { locations.count == 1 ? locations[0].folderName : "Add Folders" }

    var body: some View {
        content
            .appleSettingsPageTitle(title)
            .onAppear {
                guard !didPrefill else { return }
                didPrefill = true
                folders = locations.map { .init(location: $0, name: setup.proposedName(for: $0)) }
            }
    }

    private func save() {
        guard !isSaving, !folders.isEmpty else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try setup.saveFolders(folders, to: sourceStore)
            onFinish()
        } catch {
            failure = error.localizedDescription
        }
    }

    private func folderLabel(_ location: AppleNetworkShareLocation) -> String {
        ([location.share] + location.path.split(separator: "/").map(String.init)).joined(separator: " › ")
    }

    private func nameField(_ folder: Binding<AppleNetworkShareNamedFolder>) -> some View {
        TextField("Name", text: folder.name, prompt: appleSecondaryFieldPrompt("Name"))
            .appleTVFieldOutline()
            .accessibilityLabel("Name for \(folder.wrappedValue.location.folderName)")
            .accessibilityIdentifier(folder.wrappedValue.location == locations.first
                ? "sources.smb.name" : "sources.smb.name.\(folder.wrappedValue.location.path)")
    }

    #if os(tvOS)
    private var content: some View {
        let metrics = AppleTVSettingsMetrics.standard
        return ScrollView {
            VStack(alignment: .leading, spacing: metrics.groupSpacing) {
                AppleTVFormGroup("Server") {
                    Text(setup.server?.name ?? "")
                        .accessibilityIdentifier("sources.smb.confirm.server")
                }
                .frame(maxWidth: metrics.formColumnWidth, alignment: .leading)
                ForEach($folders) { $folder in
                    AppleTVFormGroup(folderLabel(folder.location)) {
                        nameField($folder)
                    }
                    .frame(maxWidth: metrics.formColumnWidth, alignment: .leading)
                    .focusSection()
                }
                Button(actionTitle, action: save)
                    .buttonStyle(AppleTVPillStyle(isSelected: true, minimumSize: metrics.pillSize, fontSize: metrics.pillFontSize))
                    .accessibilityIdentifier("sources.smb.add")
                    .focusSection()
                if let failure { AppleTVFormMessage(text: failure, isError: true) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, AppleTVChromeMetrics.verticalSafeInset)
        }
        .scrollIndicators(AppleDesignTokens.scrollIndicatorVisibility)
    }
    #else
    private var content: some View {
        Form {
            Section {
                LabeledContent("Server", value: setup.server?.name ?? "")
            }
            ForEach($folders) { $folder in
                Section(folderLabel(folder.location)) {
                    nameField($folder)
                        .onSubmit(save)
                        #if os(macOS)
                        .labelsHidden()
                        #endif
                }
            }
            if let failure {
                Section {
                    Label(failure, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.secondary)
                }
            }
            #if os(macOS)
            AppleFormActionSection { addButton }
            #endif
        }
        .appleSettingsContent()
        #if !os(macOS)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { addButton }
        }
        #endif
    }

    private var addButton: some View {
        Button(actionTitle, action: save)
            #if os(macOS) || os(visionOS)
            .buttonStyle(.brandPrimary)
            #endif
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("sources.smb.add")
    }
    #endif
}

// MARK: - Editing a saved share

/// Server, Folder and Account on a saved share's page, each opening the step
/// that changes it.
@MainActor
struct AppleNetworkShareEditRows: View {
    let source: AppleSource
    let sourceStore: AppleSourceStore

    /// Loaded once per configuration, not per redraw: the keychain holds the
    /// only copy of the account.
    @State private var accountLabel = ""

    var body: some View {
        Section {
            row(.server, title: "Server", value: serverLabel)
            row(.folder, title: "Folder", value: folderLabel)
            row(.account, title: "Account", value: accountLabel)
            NavigationLink(value: AppleSourceRoute.addNetworkShareFolder(source.id)) {
                AppleTVNavigationLabel("Add Folder")
            }
            .appleTVReadableFocus()
            .accessibilityIdentifier("sources.smb.addFolderFromSettings")
        }
        .task(id: source.configurationRevision) {
            let credentials = try? sourceStore.networkCredentials(for: source)
            if let username = credentials?.username, !username.isEmpty {
                accountLabel = username
            } else {
                accountLabel = "Guest"
            }
        }
    }

    private func row(_ part: AppleNetworkShareEditPart, title: String, value: String) -> some View {
        NavigationLink(value: AppleSourceRoute.editNetworkShare(source.id, part)) {
            LabeledContent(title) {
                Text(value)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .appleTVReadableFocus()
        .accessibilityIdentifier("sources.smb.edit.\(part.rawValue)")
    }

    private var parts: (host: String, port: Int, share: String, path: String)? {
        try? AppleSMBEndpointPolicy.parts(from: source.url)
    }

    private var serverLabel: String {
        guard let parts else { return "" }
        return AppleSMBEndpointPolicy.endpointLabel(host: source.networkDisplayHost ?? parts.host, port: parts.port)
    }

    private var folderLabel: String {
        guard let parts else { return "" }
        return ([parts.share] + parts.path.split(separator: "/").map(String.init)).joined(separator: " › ")
    }
}

#if DEBUG
/// An in-memory SMB server for screenshots. Never touches the network.
actor AppleNetworkShareDebugFixtureClient: AppleNetworkShareClient {
    private let directories: [String: [AppleSMBDirectoryEntry]] = {
        func folder(_ name: String) -> AppleSMBDirectoryEntry {
            AppleSMBDirectoryEntry(name: name, path: name, isDirectory: true)
        }
        func file(_ name: String) -> AppleSMBDirectoryEntry {
            AppleSMBDirectoryEntry(name: name, path: name, isDirectory: false, sizeBytes: 1_024)
        }
        return [
            "Media": [folder("Movies"), folder("TV Shows"), folder("Home Videos"), folder("@eaDir"), file("readme.txt")],
            "Media/Movies": [folder("Classics"), folder("4K"), file("Fixture One.mkv"), file("Fixture Two.mp4")],
            "Media/TV Shows": [folder("Fixture Show"), folder("Another Show")],
            "Media/Home Videos": [file("clip-01.mov"), file("clip-02.mov"), file("clip-03.mov")],
            "Backups": [folder("Archive")],
        ]
    }()

    func listShares(host: String, port: Int, credentials: AppleSMBCredentials) async throws -> [AppleSMBShare] {
        [AppleSMBShare(name: "IPC$"), AppleSMBShare(name: "Media"), AppleSMBShare(name: "Backups")]
    }

    func listDirectory(url: URL, credentials: AppleSMBCredentials, recursive: Bool) async throws -> [AppleSMBDirectoryEntry] {
        let parts = try AppleSMBEndpointPolicy.parts(from: url)
        let key = parts.path.isEmpty ? parts.share : "\(parts.share)/\(parts.path)"
        return directories[key] ?? []
    }

    func read(url: URL, credentials: AppleSMBCredentials, range: Range<UInt64>) async throws -> Data { Data() }
}
#endif
