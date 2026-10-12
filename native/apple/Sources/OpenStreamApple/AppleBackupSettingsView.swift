#if !os(tvOS)
import SwiftUI
import UniformTypeIdentifiers

struct AppleConfigurationDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw AppleConfigurationError.invalidFile }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

@MainActor
struct AppleBackupSettingsView: View {
    let controller: AppleConfigurationController
    @State private var passphrase = ""
    @State private var syncEnabled = false
    @State private var document: AppleConfigurationDocument?
    @State private var exporting = false
    @State private var importing = false
    @State private var syncAvailability = AppleICloudSyncAvailability.available
    @State private var showsSendSetup = false
    @FocusState private var passphraseFocused: Bool

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $syncEnabled) {
                    Text("Sync with iCloud")
                    if let note = syncAvailability.note {
                        Text(note)
                    }
                }
                .tint(.green)
                .disabled(!syncAvailability.allowsChange(from: syncEnabled))
                .accessibilityIdentifier("backup.sync")
                if syncEnabled {
                    AppleConfigurationSyncStatusLines(status: controller.status)
                    Button {
                        Task { await controller.syncNow() }
                    } label: {
                        AppleWorkingButtonLabel(title: "Sync Now", workingTitle: "Syncing…", isWorking: controller.isSyncing, alignment: .leading)
                    }
                    .disabled(controller.isSyncing || controller.isBusy)
                    .accessibilityIdentifier("backup.sync.now")
                }
            }
            Section {
                SecureField("Passphrase for another Apple Account", text: $passphrase)
                    .accessibilityLabel("Passphrase for another Apple Account")
                    .textContentType(.password)
                    .focused($passphraseFocused)
                    .accessibilityIdentifier("backup.passphrase")
                #if !os(macOS)
                exportButton
                importButton
                #endif
            }
            .disabled(controller.isBusy)
            #if os(macOS)
            AppleFormActionSection {
                importButton
                exportButton
            }
            .disabled(controller.isBusy)
            #endif
            if !controller.sources.sources.filter(\.needsSignIn).isEmpty {
                Section("Needs sign-in") {
                    ForEach(controller.sources.sources.filter(\.needsSignIn)) { source in
                        NavigationLink {
                            AppleSourceSignInDestination(source: source, store: controller.sources)
                        } label: {
                            Text(source.name)
                        }
                        .accessibilityIdentifier("backup.signIn.\(source.id.uuidString)")
                    }
                }
            }
            #if os(iOS)
            // Set Up from iPhone: the other device shows a code; the Camera
            // app opens it here (`AppleSetupSendView`).
            Section {
                Button("Send Setup to Another Device") { showsSendSetup = true }
                    .accessibilityIdentifier("backup.sendSetup")
            }
            #endif
            if let result = controller.result {
                Section { Text(result) }
            }
            Section { AppleResetEntry() }
        }
        .alert("Open the Camera", isPresented: $showsSendSetup) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Point it at the code on the other device.")
        }
        .appleSettingsPage(AppleSettingsRootEntry.backup.title)
        .scrollIndicators(.hidden)
        .task {
            syncEnabled = controller.syncEnabled
            syncAvailability = AppleICloudSyncProbe.current()
        }
        .onChange(of: syncEnabled) { _, enabled in
            Task {
                await controller.setSyncEnabled(enabled)
                syncEnabled = controller.syncEnabled
            }
        }
        .fileExporter(isPresented: $exporting, document: document, contentType: .json,
                      defaultFilename: "openstream-config.json") { result in
            switch result {
            case .success: controller.setResult("Configuration exported")
            case .failure: controller.setResult("Export cancelled or unavailable")
            }
            document = nil
        }
        .appleConfigurationImport(isPresented: $importing, controller: controller)
    }

    private var exportButton: some View {
        Button {
            Task {
                do {
                    document = try await AppleConfigurationDocument(data: controller.export(passphrase: passphrase))
                    passphrase = ""
                    exporting = true
                } catch AppleConfigurationError.backupKeyUnavailable {
                    // No iCloud Keychain key here: a passphrase seals the file instead.
                    controller.setResult(AppleConfigurationError.backupKeyUnavailable.errorDescription ?? "")
                    passphraseFocused = true
                } catch { controller.setResult("Could not export configuration") }
            }
        } label: {
            AppleWorkingButtonLabel(title: "Export Configuration…", workingTitle: "Exporting…", isWorking: controller.isBusy && !importing, alignment: .leading)
        }
        .accessibilityIdentifier("backup.export")
    }

    private var importButton: some View {
        Button { importing = true } label: {
            AppleWorkingButtonLabel(title: "Import Configuration…", workingTitle: "Importing…", isWorking: controller.isBusy && importing, alignment: .leading)
        }
        .accessibilityIdentifier("backup.import")
    }
}

/// "Import Configuration…": pick a file, then confirm what it restores. Shared
/// by the Backup page and Discover's No Sources page.
@MainActor
private struct AppleConfigurationImport: ViewModifier {
    @Binding var isPresented: Bool
    let controller: AppleConfigurationController
    @State private var pendingImport: PendingImport?

    private struct PendingImport: Identifiable {
        let id = UUID()
        let data: Data
        let preview: AppleBackupPreview
    }

    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: $isPresented, allowedContentTypes: [.json]) { result in
                do {
                    let url = try result.get()
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= 10_000_000 else { throw AppleConfigurationError.tooLarge }
                    let data = try Data(contentsOf: url)
                    pendingImport = try PendingImport(data: data, preview: controller.inspectBackup(data))
                } catch { controller.setResult("Could not open configuration") }
            }
            .sheet(item: $pendingImport) { pending in
                AppleBackupImportView(controller: controller, data: pending.data, preview: pending.preview)
            }
    }
}

extension View {
    func appleConfigurationImport(isPresented: Binding<Bool>, controller: AppleConfigurationController) -> some View {
        modifier(AppleConfigurationImport(isPresented: isPresented, controller: controller))
    }
}

/// Discover's No Sources on a device with Backup & Sync: "Restore from iCloud"
/// where iCloud can be reached, "Import Backup", then Settings to add one.
@MainActor
struct AppleDiscoverRestoreEmptyState: View {
    let title: String
    var footnote: String?
    let controller: AppleConfigurationController
    let offersICloud: Bool
    let openSettings: () -> Void
    @State private var importing = false

    var body: some View {
        Group {
            if offersICloud {
                AppleSourceEmptyState(
                    title: title, systemImage: OpenStreamTab.home.systemImage,
                    actionTitle: "Restore from iCloud", action: restoreFromICloud,
                    secondaryActionTitle: "Import Backup", secondaryAction: importBackup,
                    tertiaryActionTitle: "Open Settings", tertiaryAction: openSettings,
                    footnote: footnote)
            } else {
                AppleSourceEmptyState(
                    title: title, systemImage: OpenStreamTab.home.systemImage,
                    actionTitle: "Open Settings", action: openSettings,
                    secondaryActionTitle: "Import Backup", secondaryAction: importBackup,
                    tertiaryActionTitle: AppleSetupTransferDevice.receiveTitle,
                    tertiaryAction: { AppleSetupTransferCenter.shared.presentReceiver() },
                    footnote: footnote)
            }
        }
        .appleConfigurationImport(isPresented: $importing, controller: controller)
    }

    private func restoreFromICloud() {
        appleTrace("discover: restore from iCloud")
        Task { await controller.restoreFromCloud() }
    }

    private func importBackup() { importing = true }
}

@MainActor
private struct AppleBackupImportView: View {
    let controller: AppleConfigurationController
    let data: Data
    let preview: AppleBackupPreview
    @Environment(\.dismiss) private var dismiss
    @State private var passphrase = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                if let snapshot = preview.snapshot {
                    Section("Merge") {
                        LabeledContent("Sources", value: snapshot.sources.count.formatted())
                        LabeledContent("Watched", value: snapshot.watchedHistory.count.formatted())
                    }
                    Section("Replace") {
                        Text("Settings and channel selections")
                        LabeledContent("Playback progress", value: snapshot.playbackProgress.count.formatted())
                        LabeledContent("My List", value: snapshot.watchlist.count.formatted())
                        LabeledContent("Ratings", value: snapshot.ratings.count.formatted())
                    }
                }
                if preview.needsPassphrase {
                    Section {
                        SecureField("Passphrase", text: $passphrase)
                            .accessibilityLabel("Passphrase")
                            .textContentType(.password)
                            .accessibilityIdentifier("backup.import.passphrase")
                    }
                }
                if let message = error ?? preview.failure?.errorDescription { Section { Text(message) } }
            }
            .navigationTitle("Import Configuration")
            .scrollIndicators(.hidden)
            .appleMacFormFields()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        Task {
                            do {
                                try await controller.restore(data, passphrase: passphrase)
                                passphrase = ""
                                dismiss()
                            } catch { self.error = (error as? AppleConfigurationError)?.localizedDescription ?? "Could not import configuration" }
                        }
                    }
                    .disabled(controller.isBusy || preview.failure != nil || (preview.needsPassphrase && passphrase.isEmpty))
                }
            }
            .interactiveDismissDisabled(controller.isBusy)
        }
    }
}

#endif
