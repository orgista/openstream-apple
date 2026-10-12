import SwiftUI
import UniformTypeIdentifiers

/// What a source's page offers where its Enabled switch sits. A source that
/// waits for its sign-in cannot be switched on (`AppleSourceStore.setEnabled`
/// refuses), so the switch snapped back; it gets a Sign In row instead.
enum AppleSourceEnableControl: Equatable, Sendable {
    case toggle
    case signIn

    static func control(for source: AppleSource) -> Self {
        source.needsSignIn ? .signIn : .toggle
    }
}

/// Where a source waiting for its sign-in is fixed: the media-server sign-in
/// for Plex, Jellyfin and Emby, otherwise the address and account form.
struct AppleSourceSignInDestination: View {
    let source: AppleSource
    let store: AppleSourceStore

    var body: some View {
        if source.kind == .mediaServer {
            AppleAddMediaServerView(sourceStore: store)
        } else {
            AppleSourceSignInView(source: source, store: store)
        }
    }
}

/// Signs a restored source back in: its full address (an add-on's manifest
/// URL with its configuration), the account for Xtream and network shares,
/// or the folder for a library.
struct AppleSourceSignInView: View {
    let source: AppleSource
    let store: AppleSourceStore
    @Environment(\.dismiss) private var dismiss
    @State private var choosingFolder = false
    @State private var address: String
    @State private var username = ""
    @State private var password = ""
    @State private var error: String?

    init(source: AppleSource, store: AppleSourceStore) {
        self.source = source
        self.store = store
        _address = State(initialValue: Self.startingAddress(for: source))
    }

    var body: some View {
        Form {
            if source.kind != .library {
                TextField(source.isAddon ? "Manifest URL" : "Source address", text: $address)
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
                    .accessibilityIdentifier("source.signIn.address")
            }
            if source.iptvType == .xtream || source.kind == .nas {
                TextField("Username", text: $username)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password)
                    .textContentType(.password)
            }
            #if os(macOS)
            if let error { Text(error) }
            AppleFormActionSection { signInButton }
            #else
            signInButton
            if let error { Text(error) }
            #endif
        }
        #if !os(tvOS)
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                #if os(macOS)
                let bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                #else
                let bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
                #endif
                store.reconnectConfigurationFolder(id: source.id, url: url, bookmark: bookmark)
                dismiss()
            } catch { self.error = "Could not open folder" }
        }
        #endif
        .appleSettingsPage(source.name)
        .scrollIndicators(.hidden)
        .appleMacFormFields()
    }

    @ViewBuilder
    private var signInButton: some View {
        if source.kind == .library {
            #if !os(tvOS)
            Button("Choose Folder…") { choosingFolder = true }
            #endif
        } else {
            Button("Sign In", action: signIn)
                .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .appleMacFormPrimaryAction()
                .accessibilityIdentifier("source.signIn.submit")
        }
    }

    private func signIn() {
        do {
            let url: URL
            #if OPENSTREAM_ADDONS
            if source.isAddon {
                url = try AppleManifestURLPolicy.normalize(address)
            } else {
                let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let parsed = URL(string: trimmed),
                      ["http", "https", "smb"].contains(parsed.scheme?.lowercased() ?? ""),
                      parsed.host != nil else { throw AppleConfigurationError.invalidFile }
                url = parsed
            }
            #else
                let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let parsed = URL(string: trimmed),
                      ["http", "https", "smb"].contains(parsed.scheme?.lowercased() ?? ""),
                      parsed.host != nil else { throw AppleConfigurationError.invalidFile }
                url = parsed
            #endif
            try store.restoreSourceSignIn(id: source.id, address: url, username: username, password: password)
            appleTrace("source sign-in: restored \(source.kind.rawValue)")
            dismiss()
        } catch {
            #if OPENSTREAM_ADDONS
            if let policy = error as? AppleManifestURLPolicy.Error { self.error = policy.errorDescription; return }
            #endif
            self.error = "Could not restore source"
        }
    }

    /// The host a restored source kept, ready to be completed; empty when it
    /// kept nothing usable.
    static func startingAddress(for source: AppleSource) -> String {
        guard !source.url.isFileURL, let host = source.url.host, host != "source.invalid" else { return "" }
        return source.url.absoluteString
    }
}
