import Foundation
import SwiftUI

struct AppleStorageSnapshot: Equatable, Sendable {
    var cacheBytes: Int64
    var metadataBytes: Int64
    var downloadBytes: Int64
    var downloadCount: Int

    static let empty = AppleStorageSnapshot(
        cacheBytes: 0,
        metadataBytes: 0,
        downloadBytes: 0,
        downloadCount: 0
    )
}

actor AppleStorageMaintenance {
    private let fileManager: FileManager
    private let offlineStore: AppleOfflineMediaStore
    private let cacheDirectory: URL
    private let metadataDirectory: URL

    init(
        fileManager: FileManager = .default,
        offlineStore: AppleOfflineMediaStore = AppleOfflineMediaStore(),
        cacheDirectory: URL? = nil,
        metadataDirectory: URL? = nil
    ) {
        self.fileManager = fileManager
        self.offlineStore = offlineStore

        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        self.cacheDirectory = cacheDirectory
            ?? caches.appending(path: "OpenStream", directoryHint: .isDirectory)

        let applicationSupport = AppleStorageLocation.directory(.applicationSupport, fileManager: fileManager)
        self.metadataDirectory = metadataDirectory
            ?? applicationSupport.appending(path: "OpenStream/Metadata", directoryHint: .isDirectory)
    }

    func snapshot() async -> AppleStorageSnapshot {
        let records = await offlineStore.allRecords()
        return AppleStorageSnapshot(
            cacheBytes: directoryByteCount(cacheDirectory),
            metadataBytes: directoryByteCount(metadataDirectory),
            downloadBytes: records.reduce(0) { $0 + fileByteCount($1.localURL) },
            downloadCount: records.count
        )
    }

    func clearCache() throws {
        try clearContents(of: cacheDirectory)
    }

    func clearMetadata() throws {
        try clearContents(of: metadataDirectory)
    }

    func clearDownloads() async throws {
        let records = await offlineStore.allRecords()
        for record in records {
            try await offlineStore.remove(mediaID: record.mediaID)
        }
    }

    private func clearContents(of directory: URL) throws {
        guard fileManager.fileExists(atPath: directory.path) else { return }
        for child in try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            try fileManager.removeItem(at: child)
        }
    }

    private func directoryByteCount(_ directory: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += fileByteCount(url)
        }
        return total
    }

    private func fileByteCount(_ url: URL) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: [
            .isRegularFileKey,
            .totalFileAllocatedSizeKey,
            .fileSizeKey,
        ]), values.isRegularFile == true else {
            return 0
        }
        return Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
    }
}

@MainActor
struct AppleStorageSettingsView: View {
    @State private var snapshot = AppleStorageSnapshot.empty
    @State private var workingAction: AppleStorageAction?
    @State private var confirmation: AppleStorageAction?
    @State private var statusMessage: String?

    private let maintenance: AppleStorageMaintenance
    private let embeddedInSplit: Bool

    init(maintenance: AppleStorageMaintenance = AppleStorageMaintenance(), embeddedInSplit: Bool = false) {
        self.maintenance = maintenance
        self.embeddedInSplit = embeddedInSplit
    }

    var body: some View {
        Form {
            Section("Usage") {
                LabeledContent("Download Quality", value: "Automatic")
                LabeledContent("Cache", value: format(snapshot.cacheBytes))
                LabeledContent("Metadata", value: format(snapshot.metadataBytes))
                LabeledContent("Downloads", value: format(snapshot.downloadBytes))
                LabeledContent("Downloaded Items", value: String(snapshot.downloadCount))
            }

            #if os(macOS)
            AppleFormActionSection { actions }
            #else
            Section("Actions") { actions }
            #endif

            if let statusMessage {
                Section {
                    Label(statusMessage, systemImage: statusMessage == "Done" ? "checkmark.circle" : "exclamationmark.circle")
                        .foregroundStyle(statusMessage == "Done" ? Color.primary : Color.red)
                }
            }

            #if os(tvOS)
            // Apple TV has no Backup & Sync page, so Reset lives here.
            Section { AppleResetEntry() }
            #endif
        }
        .appleSettingsPane("Storage", embedded: embeddedInSplit)
        .task {
            snapshot = await maintenance.snapshot()
        }
        .alert(item: $confirmation) { action in
            Alert(
                title: Text(action.confirmationTitle),
                primaryButton: .destructive(Text(action.confirmationButton)) {
                    run(action)
                },
                secondaryButton: .cancel()
            )
        }
    }

    @ViewBuilder
    private var actions: some View {
        actionButton("Clear Cache", action: .cache) { run(.cache) }
            .disabled(snapshot.cacheBytes == 0 || workingAction != nil)

        actionButton("Clear Metadata", role: .destructive, action: .metadata) { confirmation = .metadata }
            .disabled(snapshot.metadataBytes == 0 || workingAction != nil)

        actionButton("Delete All Downloads", role: .destructive, action: .downloads) { confirmation = .downloads }
            .disabled(snapshot.downloadCount == 0 || workingAction != nil)
    }

    @ViewBuilder
    private func actionButton(_ title: String, role: ButtonRole? = nil, action: AppleStorageAction, perform: @escaping () -> Void) -> some View {
        Button(role: role) {
            perform()
        } label: {
            AppleWorkingButtonLabel(
                title: LocalizedStringKey(title),
                workingTitle: LocalizedStringKey(action.workingLabel),
                isWorking: workingAction == action,
                alignment: .leading
            )
            .accessibilityLabel(workingAction == action ? action.inProgressLabel : title)
        }
    }

    private func run(_ action: AppleStorageAction) {
        workingAction = action
        statusMessage = nil

        Task { @MainActor in
            do {
                switch action {
                case .cache:
                    try await maintenance.clearCache()
                case .metadata:
                    try await maintenance.clearMetadata()
                case .downloads:
                    try await maintenance.clearDownloads()
                }
                snapshot = await maintenance.snapshot()
                statusMessage = "Done"
            } catch {
                statusMessage = error.localizedDescription
            }
            workingAction = nil
        }
    }

    private func format(_ bytes: Int64) -> String {
        AppleByteFormatting.string(bytes)
    }
}

private enum AppleStorageAction: String, Identifiable {
    case cache
    case metadata
    case downloads

    var id: String { rawValue }

    var confirmationTitle: String {
        switch self {
        case .cache: "Clear Cache?"
        case .metadata: "Clear Metadata?"
        case .downloads: "Delete All Downloads?"
        }
    }

    var confirmationButton: String {
        switch self {
        case .cache, .metadata: "Clear"
        case .downloads: "Delete"
        }
    }

    var inProgressLabel: String {
        switch self {
        case .cache: "Clearing cache"
        case .metadata: "Clearing metadata"
        case .downloads: "Deleting downloads"
        }
    }

    var workingLabel: String {
        switch self {
        case .cache, .metadata: "Clearing…"
        case .downloads: "Deleting…"
        }
    }
}
