#if DEBUG
import Foundation
import Security

/// `-OpenStreamRestoreBackup <path> -OpenStreamRestorePassphraseFile <path>`:
/// imports a passphrase backup through Backup & Sync's own restore, so a test
/// device (test Apple TV has no file picker) gets the owner's setup and library.
/// Paths are relative to the app's home (container). Debug builds only. Both
/// files are read and deleted in `App.init`.
///
/// The device is then held out of iCloud the way Reset holds it, so another
/// device's configuration does not replace the restored one mid-measurement;
/// Restore from iCloud lets iCloud back in.
@MainActor
public enum AppleDebugBackupRestore {
    static let backupKey = "OpenStreamRestoreBackup"
    static let passphraseKey = "OpenStreamRestorePassphraseFile"
    private static var pending: (data: Data, passphrase: String)?

    #if targetEnvironment(simulator)
    nonisolated static func seedBuild20KeychainIfRequested(service: String) {
        guard service == "com.orgista.openstream.instances",
              UserDefaults.standard.bool(forKey: "OpenStreamSeedBuild20Keychain") else { return }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrSynchronizable as String: false]
        let attributes: [String: Any] = [kSecAttrSynchronizable as String: true,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            appleTraceFailure("keychain fixture: build20 seed failed status=\(status)")
            return
        }
        func count(synchronizable: Bool) -> Int {
            var query = query
            query[kSecAttrSynchronizable as String] = synchronizable
            query[kSecReturnAttributes as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitAll
            var value: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess else { return 0 }
            return (value as? [[String: Any]])?.count ?? 0
        }
        appleTrace("keychain fixture: build20 sync=\(count(synchronizable: true)) local=\(count(synchronizable: false))")
    }
    #endif

    /// A container-relative snapshot exercises the real cloud read/apply path on a signed-out test simulator.
    static func cloudStoreIfRequested(defaults: UserDefaults = .standard) -> AppleCloudKeyValueStore? {
        guard let path = defaults.string(forKey: "OpenStreamCloudSnapshot"), !path.isEmpty else { return nil }
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path, relativeTo: home))
            return AppleDebugSnapshotCloudStore(snapshot: data)
        } catch {
            appleTraceFailure("cloud snapshot hook: could not read snapshot")
            return AppleDebugSnapshotCloudStore(snapshot: nil)
        }
    }

    public static func captureIfRequested(defaults: UserDefaults = .standard, fileManager: FileManager = .default) {
        guard let path = defaults.string(forKey: backupKey), !path.isEmpty else { return }
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let backup = URL(fileURLWithPath: path, relativeTo: home)
        let passFile = defaults.string(forKey: passphraseKey).map { URL(fileURLWithPath: $0, relativeTo: home) }
        defer {
            try? fileManager.removeItem(at: backup)
            if let passFile { try? fileManager.removeItem(at: passFile) }
        }
        guard let data = try? Data(contentsOf: backup) else {
            appleTrace("backup restore hook: cannot read \(backup.lastPathComponent)")
            return
        }
        let passphrase = passFile.flatMap { try? String(contentsOf: $0, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        pending = (data, passphrase)
    }

    /// `-OpenStreamResumeICloudSync YES`: lets a device the hook below held
    /// back into iCloud at launch, as Restore from iCloud does.
    static let resumeKey = "OpenStreamResumeICloudSync"

    static func resumeICloudIfRequested(controller: AppleConfigurationController, defaults: UserDefaults = .standard) async {
        guard defaults.bool(forKey: resumeKey) else { return }
        appleTrace("backup restore hook: resuming iCloud sync")
        await controller.restoreFromCloud()
    }

    static func restorePendingIfNeeded(controller: AppleConfigurationController, defaults: UserDefaults = .standard) async {
        guard let pending else { return }
        self.pending = nil
        defaults.set(true, forKey: AppleDeviceReset.cloudRestoreHeldKey)
        do {
            try await controller.restore(pending.data, passphrase: pending.passphrase)
        } catch {
            appleTraceFailure("backup restore hook: \(appleErrorLabel(error))")
        }
    }
}

private final class AppleDebugSnapshotCloudStore: AppleCloudKeyValueStore {
    private var snapshot: Data?

    init(snapshot: Data?) { self.snapshot = snapshot }
    func data(forKey key: String) -> Data? { key == "openstream.configuration.v1" ? snapshot : nil }
    func set(_ value: Data?, forKey key: String) {
        if key == "openstream.configuration.v1" { snapshot = value }
    }
    func removeObject(forKey key: String) { set(nil, forKey: key) }
    func synchronize() -> Bool { true }
}
#endif
