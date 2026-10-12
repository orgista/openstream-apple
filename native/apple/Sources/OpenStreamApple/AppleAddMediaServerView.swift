import Foundation
import SwiftUI

#if os(iOS) || os(visionOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

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

public struct AppleMediaServerFormPolicy {
    public static func normalizedBaseURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.contains(" ") { return nil }
        let urlString = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard let url = URL(string: urlString), url.host != nil else { return nil }
        return url
    }

    public static func canTest(urlText: String) -> Bool {
        return normalizedBaseURL(urlText) != nil
    }

    public static func canSave(urlText: String, username: String) -> Bool {
        return canTest(urlText: urlText) && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public static func canSignIn(email: String, password: String) -> Bool {
        return email.contains("@") && !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty
    }

    public static func defaultName(kind: AppleMediaServerKind, typedName: String, publicInfo: AppleMediaServerPublicInfo?, host: String?) -> String {
        let trimmed = typedName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if let serverName = publicInfo?.serverName, !serverName.isEmpty { return serverName }
        return host ?? kind.title
    }

    public static func message(for error: AppleMediaServerError) -> String {
        switch error {
        case .invalidCredentials: return "Wrong username or password."
        case .server(let status): return "The server answered with an error (\(status))."
        case .malformedResponse: return "The server's reply made no sense."
        case .unreachable: return "Can't reach the server."
        case .unsupported: return "Not supported by this server."
        case .downloadNotAllowed: return "Downloads are not allowed by this server."
        }
    }

    public static func prefersQuickConnect(isTV: Bool, kind: AppleMediaServerKind, enabled: Bool) -> Bool {
        isTV && kind == .jellyfin && enabled
    }

    public static let quickConnectPollInterval: Duration = .seconds(3)
}

private enum AppleInstanceConnectionAction: Equatable {
    case test(UUID)
    case save(UUID)
    case signIn(UUID)
    case connect(UUID)
    
    var requestID: UUID {
        switch self {
        case .test(let id), .save(let id), .signIn(let id), .connect(let id): return id
        }
    }

    var shouldSave: Bool {
        if case .save = self { return true }
        if case .signIn = self { return true }
        if case .connect = self { return true }
        return false
    }
}

private enum EmbyMode: String, Hashable, CaseIterable {
    case connect = "Emby Connect"
    case server = "Server URL"
}

@MainActor
struct AppleAddMediaServerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appleMediaServerConnected) private var mediaServerConnected
    let sourceStore: AppleSourceStore
    
    @State private var plexModel: PlexSignInModel
    
    init(sourceStore: AppleSourceStore) {
        self.sourceStore = sourceStore
        self._plexModel = State(wrappedValue: PlexSignInModel(sourceStore: sourceStore))
    }
    
    @State private var kind: AppleMediaServerKind = .jellyfin
    @State private var embyMode: EmbyMode = .connect
    
    @State private var name: String = ""
    @State private var url: String = ""
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var isPasswordRevealed = false
    
    @State private var embyEmail: String = ""
    @State private var embyPassword: String = ""
    @State private var isEmbyPasswordRevealed = false
    @State private var embyServers: [AppleEmbyConnectServer] = []
    @State private var selectedEmbyServerID: String = ""
    @State private var embyAccount: AppleEmbyConnectAccount?
    
    @State private var isWorking: Bool = false
    @State private var message: String?
    @State private var isError: Bool = false
    @State private var connectionAction: AppleInstanceConnectionAction?
    /// Each press runs once; a task rerun on reappear must not repeat it.
    @State private var actionLedger = AppleOneShotRequestLedger()
    
    @State private var discoveredServers: [AppleDiscoveredMediaServer] = []
    @State private var quickConnectSupported = false
    @State private var usePassword = false
    @State private var connectDiscoveredServer = false

    private var showPassword: Bool {
        #if os(tvOS)
        return !AppleMediaServerFormPolicy.prefersQuickConnect(isTV: true, kind: kind, enabled: quickConnectSupported) || usePassword
        #else
        return true
        #endif
    }

    @State private var ticket: AppleQuickConnectTicket?
    @State private var quickConnectTask: Task<Void, Never>?
    
    private let client = AppleMediaServerClient()
    
    private enum Field: Hashable {
        case name, url, username, embyEmail
    }
    @FocusState private var focusedField: Field?
    
    private var fieldChain: [Field] {
        if kind == .emby && embyMode == .connect {
            return [.embyEmail]
        } else {
            return [.name, .url, .username]
        }
    }
    
    var body: some View {
        Group {
            #if os(tvOS)
            tvOSBody
            #else
            standardBody
            #endif
        }
        .task { discoveredServers = await AppleMediaServerDiscovery.discover() }
        .task(id: "\(kind.rawValue)|\(url)") { await checkQuickConnectSupport() }
    }

    private func selectDiscoveredServer(_ server: AppleDiscoveredMediaServer) {
        cancelQuickConnect()
        kind = .jellyfin
        name = server.name
        url = server.baseURL.absoluteString
        usePassword = false
        connectDiscoveredServer = true
    }

    private func checkQuickConnectSupport() async {
        cancelQuickConnect()
        connectionAction = nil
        quickConnectSupported = false
        usePassword = false
        guard kind == .jellyfin, let baseURL = AppleMediaServerFormPolicy.normalizedBaseURL(url) else { return }
        do {
            try await Task.sleep(for: .milliseconds(600))
            let enabled = try await client.quickConnectEnabled(baseURL: baseURL)
            try Task.checkCancellation()
            quickConnectSupported = enabled
            #if os(tvOS)
            let autoConnect = true
            #else
            let autoConnect = connectDiscoveredServer
            #endif
            connectDiscoveredServer = false
            if enabled && autoConnect { connectionAction = .connect(UUID()) }
        } catch { /* Password sign-in remains available. */ }
    }

    private var nameField: some View {
        TextField("Name", text: $name, prompt: appleSecondaryFieldPrompt("Name"))
            .accessibilityLabel("Name")
            .appleTVFieldOutline()
            .textContentType(.name)
            .appleSourceFieldStyle()
    }
    
    private var urlField: some View {
        TextField("Server URL", text: $url, prompt: appleSecondaryFieldPrompt("Server URL"))
            .accessibilityLabel("Server URL")
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
            .autocorrectionDisabled()
    }
    
    private var passwordField: some View {
        AppleRevealableSecureField("Password", text: $password, isRevealed: $isPasswordRevealed)
    }
    
    private var embyEmailField: some View {
        TextField("Email", text: $embyEmail, prompt: appleSecondaryFieldPrompt("Email"))
            .accessibilityLabel("Email")
            .appleTVFieldOutline()
            .textContentType(.emailAddress)
            .appleSourceFieldStyle()
            #if os(iOS) || os(tvOS) || os(visionOS)
            .textInputAutocapitalization(.never)
            #endif
            #if os(iOS) || os(visionOS)
            .keyboardType(.emailAddress)
            #endif
            .autocorrectionDisabled()
    }
    
    private var embyPasswordField: some View {
        AppleRevealableSecureField("Password", text: $embyPassword, isRevealed: $isEmbyPasswordRevealed)
    }
    
    #if os(tvOS)
    private var tvOSBody: some View {
        let metrics = AppleTVSettingsMetrics.standard
        return ScrollView {
            VStack(alignment: .leading, spacing: metrics.groupSpacing) {
                if !discoveredServers.isEmpty {
                    AppleTVFormGroup("Found on your network") {
                        ForEach(discoveredServers) { server in
                            Button(server.name) { selectDiscoveredServer(server) }
                                .buttonStyle(.brandSecondary)
                                .accessibilityIdentifier("sources.mediaServer.discovered.\(server.id)")
                        }
                    }
                    .focusSection()
                }
                VStack(alignment: .leading, spacing: metrics.groupSpacing) {
                    AppleTVFormField("Server") {
                        HStack(spacing: metrics.iconSpacing) {
                            AppleTVChoicePill(title: AppleMediaServerKind.jellyfin.title, isSelected: kind == .jellyfin) { kind = .jellyfin }
                                .accessibilityIdentifier("sources.mediaServer.kind.jellyfin")
                            AppleTVChoicePill(title: AppleMediaServerKind.emby.title, isSelected: kind == .emby) { kind = .emby }
                                .accessibilityIdentifier("sources.mediaServer.kind.emby")
                            AppleTVChoicePill(title: AppleMediaServerKind.plex.title, isSelected: kind == .plex) { kind = .plex }
                                .accessibilityIdentifier("sources.mediaServer.kind.plex")
                        }
                    }
                    
                    if kind == .emby {
                        AppleTVFormField("Sign in with") {
                            HStack(spacing: metrics.iconSpacing) {
                                AppleTVChoicePill(title: EmbyMode.connect.rawValue, isSelected: embyMode == .connect) { embyMode = .connect }
                                    .accessibilityIdentifier("sources.mediaServer.embyMode.connect")
                                AppleTVChoicePill(title: EmbyMode.server.rawValue, isSelected: embyMode == .server) { embyMode = .server }
                                    .accessibilityIdentifier("sources.mediaServer.embyMode.server")
                            }
                        }
                    }
                    
                    if kind == .emby && embyMode == .connect {
                        AppleTVFormGroup("Emby Connect") {
                            AppleTVFormField("Email") {
                                embyEmailField
                                    .focused($focusedField, equals: .embyEmail)
                                    .accessibilityIdentifier("sources.mediaServer.embyEmail")
                            }
                            AppleTVFormField("Password") {
                                embyPasswordField
                                    .accessibilityIdentifier("sources.mediaServer.embyPassword")
                            }
                        }
                    } else if kind != .plex {
                        AppleTVFormGroup("Connection") {
                            AppleTVFormField("Name") {
                                nameField
                                    .focused($focusedField, equals: .name)
                                    .accessibilityIdentifier("sources.mediaServer.name")
                            }
                            AppleTVFormField("Server URL") {
                                urlField
                                    .focused($focusedField, equals: .url)
                                    .accessibilityIdentifier("sources.mediaServer.url")
                            }
                            if showPassword {
                            AppleTVFormField("Username") {
                                usernameField
                                    .focused($focusedField, equals: .username)
                                    .accessibilityIdentifier("sources.mediaServer.username")
                            }
                            AppleTVFormField("Password") {
                                passwordField
                                    .accessibilityIdentifier("sources.mediaServer.password")
                            }
                            }
                        }
                    }
                }
                .frame(maxWidth: metrics.formColumnWidth, alignment: .leading)
                .focusSection()
                .disabled(isWorking)
                
                if kind == .emby && embyMode == .connect {
                    HStack(spacing: metrics.pillSpacing) {
                        Button { connectionAction = .signIn(UUID()) } label: { connectionLabel(saving: true, text: "Sign In") }
                            .buttonStyle(AppleTVPillStyle(isSelected: true, minimumSize: metrics.pillSize, fontSize: metrics.pillFontSize))
                            .disabled(!AppleMediaServerFormPolicy.canSignIn(email: embyEmail, password: embyPassword) || isWorking)
                            .accessibilityIdentifier("sources.mediaServer.embySignIn")
                    }
                    .focusSection()
                } else if showPassword && kind != .plex {
                    HStack(spacing: metrics.pillSpacing) {
                        Button { connectionAction = .save(UUID()) } label: { connectionLabel(saving: true, text: "Save") }
                            .buttonStyle(AppleTVPillStyle(isSelected: true, minimumSize: metrics.pillSize, fontSize: metrics.pillFontSize))
                            .disabled(!AppleMediaServerFormPolicy.canSave(urlText: url, username: username) || isWorking)
                            .accessibilityIdentifier("sources.mediaServer.save")
                        Button { connectionAction = .test(UUID()) } label: { connectionLabel(saving: false, text: "Test Connection") }
                            .buttonStyle(AppleTVPillStyle(isSelected: false, minimumSize: metrics.pillSize, fontSize: metrics.pillFontSize))
                            .disabled(!AppleMediaServerFormPolicy.canTest(urlText: url) || isWorking)
                            .accessibilityIdentifier("sources.mediaServer.test")
                    }
                    .focusSection()
                }
                
                if kind == .jellyfin && quickConnectSupported {
                    VStack(alignment: .leading, spacing: metrics.groupSpacing) {
                        AppleTVFormGroup("Quick Connect") {
                            HStack(spacing: metrics.pillSpacing) {
                                Button { connectionAction = .connect(UUID()) } label: { connectionLabel(saving: false, text: "Use Quick Connect") }
                                    .buttonStyle(AppleTVPillStyle(isSelected: false, minimumSize: metrics.pillSize, fontSize: metrics.pillFontSize))
                                    .disabled(!AppleMediaServerFormPolicy.canTest(urlText: url) || isWorking)
                                    .accessibilityIdentifier("sources.mediaServer.quickConnect")
                            }
                            if !showPassword {
                                Button("Use Password") {
                                    cancelQuickConnect()
                                    usePassword = true
                                }
                                .buttonStyle(.brandSecondary)
                                .accessibilityIdentifier("sources.mediaServer.usePassword")
                            }
                            if let ticket {
                                AppleTVFormField("Code") {
                                    Text(ticket.code)
                                        .font(.system(size: 64, weight: .semibold, design: .monospaced))
                                        .accessibilityIdentifier("sources.mediaServer.quickConnect.code")
                                }
                                HStack(spacing: metrics.pillSpacing) {
                                    Button("Cancel") { cancelQuickConnect() }
                                        .buttonStyle(AppleTVPillStyle(isSelected: false, minimumSize: metrics.pillSize, fontSize: metrics.pillFontSize))
                                        .accessibilityIdentifier("sources.mediaServer.quickConnect.cancel")
                                }
                            }
                        }
                    }
                    .frame(maxWidth: metrics.formColumnWidth, alignment: .leading)
                    .focusSection()
                }
                
                if !embyServers.isEmpty {
                    VStack(alignment: .leading, spacing: metrics.groupSpacing) {
                        AppleTVFormField("Server") {
                            HStack(spacing: metrics.iconSpacing) {
                                ForEach(embyServers, id: \.id) { server in
                                    AppleTVChoicePill(title: server.name, isSelected: selectedEmbyServerID == server.id) { selectedEmbyServerID = server.id }
                                        .accessibilityIdentifier("sources.mediaServer.embyServer.\(server.id)")
                                }
                            }
                        }
                        HStack(spacing: metrics.pillSpacing) {
                            Button {
                                guard let server = embyServers.first(where: { $0.id == selectedEmbyServerID }) else { return }
                                saveEmbyServer(server: server)
                            } label: { connectionLabel(saving: true, text: "Save") }
                                .buttonStyle(AppleTVPillStyle(isSelected: true, minimumSize: metrics.pillSize, fontSize: metrics.pillFontSize))
                                .disabled(isWorking)
                                .accessibilityIdentifier("sources.mediaServer.saveEmby")
                        }
                        .focusSection()
                    }
                    .frame(maxWidth: metrics.formColumnWidth, alignment: .leading)
                    .focusSection()
                }

                if kind == .plex {
                    if let pin = plexModel.pin {
                        AppleTVFormGroup("Sign In") {
                            AppleTVFormField("Code") {
                                Text(pin.code)
                                    .font(.system(.title2, design: .monospaced))
                                    .accessibilityIdentifier("sources.mediaServer.plex.code")
                            }
                            AppleTVFormField("Enter it at") {
                                Text("plex.tv/link")
                                    .accessibilityIdentifier("sources.mediaServer.plex.link")
                            }
                            HStack(spacing: metrics.pillSpacing) {
                                Button("Cancel") { plexModel.reset() }
                                    .buttonStyle(AppleTVPillStyle(isSelected: false, minimumSize: metrics.pillSize, fontSize: metrics.pillFontSize))
                            }
                        }
                        .frame(maxWidth: metrics.formColumnWidth, alignment: .leading)
                        .focusSection()
                    } else if !plexModel.servers.isEmpty {
                        VStack(alignment: .leading, spacing: metrics.groupSpacing) {
                            AppleTVFormField("Server") {
                                HStack(spacing: metrics.iconSpacing) {
                                    ForEach(plexModel.servers, id: \.clientIdentifier) { server in
                                        AppleTVChoicePill(title: server.name, isSelected: plexModel.selectedServerID == server.clientIdentifier) { plexModel.selectedServerID = server.clientIdentifier }
                                            .accessibilityIdentifier("sources.mediaServer.plex.server.\(server.clientIdentifier)")
                                    }
                                }
                            }
                            HStack(spacing: metrics.pillSpacing) {
                                Button {
                                    Task { await plexModel.saveSelectedServer() }
                                } label: { connectionLabel(saving: true, text: "Save") }
                                    .buttonStyle(AppleTVPillStyle(isSelected: true, minimumSize: metrics.pillSize, fontSize: metrics.pillFontSize))
                                    .disabled(plexModel.isWorking)
                                    .accessibilityIdentifier("sources.mediaServer.plex.save")
                            }
                            .focusSection()
                        }
                        .frame(maxWidth: metrics.formColumnWidth, alignment: .leading)
                        .focusSection()
                    } else {
                        HStack(spacing: metrics.pillSpacing) {
                            Button {
                                Task { await plexModel.signIn() }
                            } label: { 
                                HStack(spacing: 8) {
                                    if plexModel.isWorking { ProgressView().accessibilityHidden(true) }
                                    Text("Sign in with Plex")
                                }
                            }
                            .buttonStyle(AppleTVPillStyle(isSelected: true, minimumSize: metrics.pillSize, fontSize: metrics.pillFontSize))
                            .disabled(plexModel.isWorking)
                            .accessibilityIdentifier("sources.mediaServer.plexSignIn")
                        }
                        .focusSection()
                    }
                }

                if let displayMessage = message ?? plexModel.message {
                    AppleTVFormMessage(text: displayMessage, isError: isError || plexModel.isError)
                        .accessibilityIdentifier("sources.mediaServer.status")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, AppleTVChromeMetrics.verticalSafeInset)
        }
        .scrollIndicators(AppleDesignTokens.scrollIndicatorVisibility)
        .defaultFocus($focusedField, .name)
        .appleSettingsPageTitle("Add Media Server")
        .task(id: connectionAction) {
            guard let connectionAction, actionLedger.consume(connectionAction.requestID) else { return }
            await perform(connectionAction)
        }
        .onChange(of: kind) { _, _ in 
            resetState()
            plexModel.reset()
        }
        .onChange(of: embyMode) { _, _ in resetState() }
        .onChange(of: plexModel.isDone) { _, done in
            if done { dismiss() }
        }
        .onDisappear { 
            cancelQuickConnect() 
            plexModel.reset()
        }
    }
    #else
    private var standardBody: some View {
        Form {
            if !discoveredServers.isEmpty {
                Section("Found on your network") {
                    ForEach(discoveredServers) { server in
                        Button(server.name) { selectDiscoveredServer(server) }
                            .foregroundStyle(.primary)
                            .accessibilityIdentifier("sources.mediaServer.discovered.\(server.id)")
                    }
                }
            }
            Section {
                Picker("Server", selection: $kind) {
                    Text(AppleMediaServerKind.jellyfin.title).tag(AppleMediaServerKind.jellyfin)
                    Text(AppleMediaServerKind.emby.title).tag(AppleMediaServerKind.emby)
                    Text(AppleMediaServerKind.plex.title).tag(AppleMediaServerKind.plex)
                }
                .accessibilityIdentifier("sources.mediaServer.kind")
            }
            .disabled(isWorking)
            
            if kind == .emby {
                Section {
                    Picker("Sign in with", selection: $embyMode) {
                        Text(EmbyMode.connect.rawValue).tag(EmbyMode.connect)
                        Text(EmbyMode.server.rawValue).tag(EmbyMode.server)
                    }
                    .accessibilityIdentifier("sources.mediaServer.embyMode")
                }
                .disabled(isWorking)
            }
            
            if kind == .emby && embyMode == .connect {
                Section {
                    embyEmailField.appleFormSubmit(.embyEmail, chain: fieldChain, focus: $focusedField)
                        .accessibilityIdentifier("sources.mediaServer.embyEmail")
                    embyPasswordField
                        .accessibilityIdentifier("sources.mediaServer.embyPassword")
                }
                .disabled(isWorking)
                
                AppleFormActionSection {
                    Button { connectionAction = .signIn(UUID()) } label: { connectionLabel(saving: true, text: "Sign In") }
                        .disabled(!AppleMediaServerFormPolicy.canSignIn(email: embyEmail, password: embyPassword) || isWorking)
                        .appleMacFormPrimaryAction()
                        .accessibilityIdentifier("sources.mediaServer.embySignIn")
                }
                
                if !embyServers.isEmpty {
                    Section {
                        Picker("Server", selection: $selectedEmbyServerID) {
                            ForEach(embyServers, id: \.id) { server in
                                Text(server.name).tag(server.id)
                            }
                        }
                        .accessibilityIdentifier("sources.mediaServer.embyServer")
                        #if !os(macOS)
                        saveEmbyServerButton
                        #endif
                    }
                    #if os(macOS)
                    AppleFormActionSection { saveEmbyServerButton }
                    #endif
                }
            } else if kind != .plex {
                Section("Connection") {
                    nameField.appleFormSubmit(.name, chain: fieldChain, focus: $focusedField)
                        .accessibilityIdentifier("sources.mediaServer.name")
                    urlField.appleFormSubmit(.url, chain: fieldChain, focus: $focusedField)
                        .accessibilityIdentifier("sources.mediaServer.url")
                    usernameField.appleFormSubmit(.username, chain: fieldChain, focus: $focusedField)
                        .accessibilityIdentifier("sources.mediaServer.username")
                    passwordField
                        .accessibilityIdentifier("sources.mediaServer.password")
                }
                .disabled(isWorking)
                
                #if os(macOS)
                // System Settings order: the default action at the trailing
                // edge. Quick Connect joins them, so its section only appears
                // once there is a code to show.
                AppleFormActionSection {
                    if kind == .jellyfin && quickConnectSupported { quickConnectButton }
                    testConnectionButton
                    saveConnectionButton
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

                if kind == .jellyfin && quickConnectSupported, AppleFormActionLayout.current == .formRow || ticket != nil {
                    Section("Quick Connect") {
                        #if !os(macOS)
                        quickConnectButton
                        #endif
                        if let ticket {
                            LabeledContent("Code") {
                                Text(ticket.code).font(.system(.title2, design: .monospaced))
                            }
                            .accessibilityIdentifier("sources.mediaServer.quickConnect.code")
                            Button("Cancel", role: .cancel) { cancelQuickConnect() }
                                .accessibilityIdentifier("sources.mediaServer.quickConnect.cancel")
                        }
                    }
                }
            }
            
            if kind == .plex {
                if let pin = plexModel.pin {
                    Section {
                        LabeledContent("Code", value: pin.code)
                            .font(.system(.title2, design: .monospaced))
                            .accessibilityIdentifier("sources.mediaServer.plex.code")
                        LabeledContent("Enter it at", value: "plex.tv/link")
                            .accessibilityIdentifier("sources.mediaServer.plex.link")
                        Button("Cancel", role: .cancel) { plexModel.reset() }
                    }
                } else if !plexModel.servers.isEmpty {
                    Section {
                        Picker("Server", selection: $plexModel.selectedServerID) {
                            ForEach(plexModel.servers, id: \.clientIdentifier) { server in
                                Text(server.name).tag(server.clientIdentifier)
                            }
                        }
                        .accessibilityIdentifier("sources.mediaServer.plex.server")
                        #if !os(macOS)
                        plexSaveButton
                        #endif
                    }
                    #if os(macOS)
                    AppleFormActionSection { plexSaveButton }
                    #endif
                } else {
                    AppleFormActionSection {
                        Button {
                            Task { await plexModel.signIn() }
                        } label: { 
                            HStack(spacing: 8) {
                                if plexModel.isWorking { ProgressView().accessibilityHidden(true) }
                                Text("Sign in with Plex")
                            }
                        }
                        .disabled(plexModel.isWorking)
                        .appleMacFormPrimaryAction()
                        .accessibilityIdentifier("sources.mediaServer.plexSignIn")
                    }
                }
            }
            
            if let displayMessage = message ?? plexModel.message {
                Section {
                    let displayError = isError || plexModel.isError
                    Label(displayMessage, systemImage: displayError ? "exclamationmark.circle" : "checkmark.circle")
                        .foregroundStyle(displayError ? .red : .secondary)
                        .accessibilityIdentifier("sources.mediaServer.status")
                }
            }
        }
        .scrollIndicators(AppleDesignTokens.scrollIndicatorVisibility)
        .appleSettingsPage("Add Media Server")
        .task(id: connectionAction) {
            guard let connectionAction, actionLedger.consume(connectionAction.requestID) else { return }
            await perform(connectionAction)
        }
        .onChange(of: kind) { _, _ in 
            resetState()
            plexModel.reset()
        }
        .onChange(of: embyMode) { _, _ in resetState() }
        .onChange(of: plexModel.isDone) { _, done in
            if done { dismiss() }
        }
        .onDisappear { 
            cancelQuickConnect()
            plexModel.reset()
        }
    }
    
    private var connectionButtons: some View {
        Group {
            saveConnectionButton
            testConnectionButton
        }
    }

    private var saveConnectionButton: some View {
        Button { connectionAction = .save(UUID()) } label: { connectionLabel(saving: true, text: "Save") }
            .buttonStyle(.brandPrimary)
            #if os(macOS)
            .keyboardShortcut(.defaultAction)
            #endif
            .disabled(!AppleMediaServerFormPolicy.canSave(urlText: url, username: username) || isWorking)
            .accessibilityIdentifier("sources.mediaServer.save")
    }

    private var quickConnectButton: some View {
        Button { connectionAction = .connect(UUID()) } label: { connectionLabel(saving: false, text: "Use Quick Connect") }
            .disabled(!AppleMediaServerFormPolicy.canTest(urlText: url) || isWorking)
            #if os(macOS)
            // It shares the action bar with Test Connection and Save.
            .buttonStyle(.brandSecondary)
            #endif
            .accessibilityIdentifier("sources.mediaServer.quickConnect")
    }

    private var testConnectionButton: some View {
        Button { connectionAction = .test(UUID()) } label: { connectionLabel(saving: false, text: "Test Connection") }
            .buttonStyle(.brandSecondary)
            .disabled(!AppleMediaServerFormPolicy.canTest(urlText: url) || isWorking)
            .accessibilityIdentifier("sources.mediaServer.test")
    }

    private var saveEmbyServerButton: some View {
        Button {
            guard let server = embyServers.first(where: { $0.id == selectedEmbyServerID }) else { return }
            saveEmbyServer(server: server)
        } label: { connectionLabel(saving: true, text: "Save") }
            .disabled(isWorking)
            .appleMacFormPrimaryAction()
            .accessibilityIdentifier("sources.mediaServer.saveEmby")
    }

    private var plexSaveButton: some View {
        Button {
            Task { await plexModel.saveSelectedServer() }
        } label: {
            HStack(spacing: 8) {
                if plexModel.isWorking { ProgressView().accessibilityHidden(true) }
                Text("Save")
            }
        }
        .disabled(plexModel.isWorking)
        .appleMacFormPrimaryAction()
        .accessibilityIdentifier("sources.mediaServer.plex.save")
    }
    #endif
    
    private func connectionLabel(saving: Bool, text: String) -> some View {
        let active = isWorking && (connectionAction?.shouldSave == saving)
        let workingText = text == "Test Connection" ? "Testing…" : (text == "Sign In" ? "Signing In…" : (text == "Save" ? "Saving…" : (text == "Use Quick Connect" ? "Connecting…" : "\(text)…")))
        return AppleWorkingButtonLabel(
            title: LocalizedStringKey(text),
            workingTitle: LocalizedStringKey(workingText),
            isWorking: active
        )
    }
    
    private func resetState() {
        message = nil
        isError = false
        ticket = nil
        quickConnectTask?.cancel()
        quickConnectTask = nil
    }
    
    private func cancelQuickConnect() {
        ticket = nil
        quickConnectTask?.cancel()
        quickConnectTask = nil
    }
    
    private func perform(_ action: AppleInstanceConnectionAction) async {
        isWorking = true
        message = nil
        isError = false
        defer { isWorking = false }
        
        switch action {
        case .test(_):
            guard let baseURL = AppleMediaServerFormPolicy.normalizedBaseURL(url) else { return }
            do {
                let info = try await client.publicInfo(baseURL: baseURL)
                isError = false
                if let serverName = info.serverName, let version = info.version {
                    message = "Connected to \(serverName) (\(version))"
                } else {
                    message = "Connected"
                }
            } catch let err as AppleMediaServerError {
                isError = true
                message = AppleMediaServerFormPolicy.message(for: err)
            } catch {
                isError = true
                message = error.localizedDescription
            }
            
        case .save(_):
            guard let baseURL = AppleMediaServerFormPolicy.normalizedBaseURL(url) else { return }
            do {
                let session = try await client.authenticate(baseURL: baseURL, kind: kind, username: username, password: password)
                let info = try? await client.publicInfo(baseURL: baseURL)
                let finalName = AppleMediaServerFormPolicy.defaultName(kind: kind, typedName: name, publicInfo: info, host: baseURL.host)
                _ = try sourceStore.addMediaServer(kind: kind, name: finalName, session: session)
                dismiss()
            } catch let err as AppleMediaServerError {
                isError = true
                message = AppleMediaServerFormPolicy.message(for: err)
            } catch {
                isError = true
                message = error.localizedDescription
            }
            
        case .signIn(_):
            do {
                let account = try await client.embyConnectSignIn(email: embyEmail, password: embyPassword)
                self.embyAccount = account
                let servers = try await client.embyConnectServers(account: account)
                if servers.isEmpty {
                    isError = true
                    message = "No servers on this account."
                } else if servers.count == 1 {
                    try await exchangeAndSaveEmbyServer(server: servers[0], account: account)
                } else {
                    self.embyServers = servers
                    self.selectedEmbyServerID = servers[0].id
                }
            } catch let err as AppleMediaServerError {
                isError = true
                message = AppleMediaServerFormPolicy.message(for: err)
            } catch {
                isError = true
                message = error.localizedDescription
            }
            
        case .connect(_):
            cancelQuickConnect()
            guard let baseURL = AppleMediaServerFormPolicy.normalizedBaseURL(url) else { return }
            do {
                let enabled = try await client.quickConnectEnabled(baseURL: baseURL)
                if !enabled {
                    isError = true
                    message = "Quick Connect is off on this server."
                    return
                }
                let newTicket = try await client.quickConnectInitiate(baseURL: baseURL)
                try Task.checkCancellation()
                guard kind == .jellyfin, AppleMediaServerFormPolicy.normalizedBaseURL(url) == baseURL else { return }
                self.ticket = newTicket
                
                quickConnectTask?.cancel()
                quickConnectTask = Task {
                    do {
                        let session = try await client.waitForQuickConnect(baseURL: baseURL, ticket: newTicket)
                        let info = try? await client.publicInfo(baseURL: baseURL)
                        try Task.checkCancellation()
                        guard kind == .jellyfin, AppleMediaServerFormPolicy.normalizedBaseURL(url) == baseURL else { return }
                        let finalName = AppleMediaServerFormPolicy.defaultName(kind: .jellyfin, typedName: name, publicInfo: info, host: baseURL.host)
                        _ = try sourceStore.addMediaServer(kind: .jellyfin, name: finalName, session: session)
                        dismiss()
                        mediaServerConnected?()
                    } catch {
                        if Task.isCancelled { return }
                        ticket = nil
                        isError = true
                        message = "Quick Connect could not finish. Try again or use your password."
                    }
                }
            } catch let err as AppleMediaServerError {
                isError = true
                message = AppleMediaServerFormPolicy.message(for: err)
            } catch {
                isError = true
                message = error.localizedDescription
            }
        }
    }
    
    private func saveEmbyServer(server: AppleEmbyConnectServer) {
        guard let account = embyAccount else { return }
        Task {
            isWorking = true
            message = nil
            isError = false
            defer { isWorking = false }
            do {
                try await exchangeAndSaveEmbyServer(server: server, account: account)
            } catch let err as AppleMediaServerError {
                isError = true
                message = AppleMediaServerFormPolicy.message(for: err)
            } catch {
                isError = true
                message = error.localizedDescription
            }
        }
    }
    
    private func exchangeAndSaveEmbyServer(server: AppleEmbyConnectServer, account: AppleEmbyConnectAccount) async throws {
        let session = try await client.embyConnectExchange(server: server, account: account)
        _ = try sourceStore.addMediaServer(kind: .emby, name: server.name, session: session)
        dismiss()
    }
}
@MainActor
@Observable
final class PlexSignInModel {
    let client: ApplePlexClient
    let sourceStore: AppleSourceStore
    var isWorking = false
    var message: String?
    var isError = false
    
    var pin: ApplePlexPIN?
    var servers: [ApplePlexResource] = []
    var selectedServerID: String = ""
    var pollTask: Task<Void, Never>?
    
    private var account: ApplePlexAccount?
    private var token: String?
    
    var isDone = false
    
    init(client: ApplePlexClient = ApplePlexClient(), sourceStore: AppleSourceStore) {
        self.client = client
        self.sourceStore = sourceStore
    }
    
    func reset() {
        isWorking = false
        message = nil
        isError = false
        pin = nil
        servers = []
        selectedServerID = ""
        pollTask?.cancel()
        pollTask = nil
        account = nil
        token = nil
    }
    
    func signIn() async {
        reset()
        isWorking = true
        defer { isWorking = false }
        
        do {
            let newPIN = try await client.requestPIN()
            self.pin = newPIN
            
            let expirationDate = Date().addingTimeInterval(15 * 60)
            
            pollTask = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(3))
                    if Task.isCancelled { break }
                    
                    if Date() > expirationDate {
                        isError = true
                        message = "The code expired."
                        pin = nil
                        break
                    }
                    
                    do {
                        if let fetchedToken = try await client.pollPIN(id: newPIN.id) {
                            self.pin = nil
                            await self.handleToken(fetchedToken)
                            break
                        }
                    } catch {
                        // ignore poll errors
                    }
                }
            }
        } catch let err as AppleMediaServerError {
            isError = true
            message = AppleMediaServerFormPolicy.message(for: err)
        } catch {
            isError = true
            message = error.localizedDescription
        }
    }
    
    private func handleToken(_ fetchedToken: String) async {
        isWorking = true
        defer { isWorking = false }
        
        do {
            let acc = try await client.account(token: fetchedToken)
            let allResources = try await client.resources(token: fetchedToken)
            let serverResources = allResources.filter { $0.isServer && $0.accessToken != nil }
            
            self.account = acc
            self.token = fetchedToken
            
            if serverResources.isEmpty {
                isError = true
                message = "No Plex servers on this account."
            } else if serverResources.count == 1 {
                try await saveServer(resource: serverResources[0], account: acc, token: fetchedToken)
            } else {
                self.servers = serverResources
                self.selectedServerID = serverResources[0].clientIdentifier
            }
        } catch let err as AppleMediaServerError {
            isError = true
            message = AppleMediaServerFormPolicy.message(for: err)
        } catch {
            isError = true
            message = error.localizedDescription
        }
    }
    
    func saveSelectedServer() async {
        guard let resource = servers.first(where: { $0.clientIdentifier == selectedServerID }),
              let acc = account,
              let tok = token else { return }
        
        isWorking = true
        message = nil
        isError = false
        defer { isWorking = false }
        
        do {
            try await saveServer(resource: resource, account: acc, token: tok)
        } catch let err as AppleMediaServerError {
            isError = true
            message = AppleMediaServerFormPolicy.message(for: err)
        } catch {
            isError = true
            message = error.localizedDescription
        }
    }
    
    private func saveServer(resource: ApplePlexResource, account: ApplePlexAccount, token: String) async throws {
        guard let url = await client.firstReachableConnection(for: resource) else {
            isError = true
            message = "Can't reach \(resource.name) right now."
            return
        }
        
        let session = try client.makeSession(resource: resource, connection: url, account: account, accountToken: token)
        _ = try sourceStore.addMediaServer(kind: .plex, name: resource.name, session: session)
        isDone = true
    }
}
