import Foundation
import Observation
import Security

/// Moves once per in-app Reset. The app's root view is keyed on it, so every
/// store the root owns (sources, settings, catalog, media index) is created
/// again from the storage the reset just emptied.
@MainActor
@Observable
public final class AppleResetGeneration {
    public static let shared = AppleResetGeneration()
    public private(set) var value = 0

    init() {}

    func advance() { value &+= 1 }
}

/// Reset OpenStream: erases everything the app keeps on this device and
/// starts it again at first run (No Sources).
///
/// This device only. It never writes to iCloud (the key-value snapshot other
/// devices read stays as it is), never deletes a synchronizable iCloud
/// Keychain item (other devices share those), and never deletes the Apple
/// Account's backup key (old backups must still open). Afterwards iCloud
/// stays out until the viewer taps Restore from iCloud
/// (`cloudRestoreHeldKey`, read by `AppleConfigurationController`).
public enum AppleDeviceReset {
    static let cloudRestoreHeldKey = "openstream.reset.cloudRestoreHeld.v1"
    /// Keychain services whose items this device may own. The backup key's
    /// service is deliberately not here.
    static let localKeychainServices = ["com.orgista.openstream.settings", "com.orgista.openstream.instances", AppleDownloadResumePersistence.service]
    /// Defaults that describe how this device's keychain is stored rather than
    /// what the viewer set up; losing the sync choice would re-run the
    /// keychain migration on the next launch.
    static let preservedDefaultsKeys = [AppleKeychainStore.syncPreferenceKey]
    /// Left in place inside a wiped Library: cfprefsd owns the plist files and
    /// the defaults domain is cleared through `UserDefaults` instead.
    static let preservedDirectoryNames: Set<String> = ["Preferences"]

    /// What one reset removed; for the trace and the tests.
    struct Report: Equatable {
        var removedItems = 0
        var failedItems = 0
    }

    /// Erases everything, then brings the app back at first run (No Sources)
    /// in place, on every platform. The app never quits itself: App Review
    /// and the HIG both rule that out on iPhone, iPad, Apple TV and Vision Pro.
    @MainActor
    public static func eraseThisDeviceAndRestart() {
        restart(erase: eraseThisDevice, discardInMemoryState: discardInMemoryState, generation: .shared)
    }

    /// The wipe, then the in-memory copies, then a new root. Parameters are
    /// for the tests.
    @MainActor
    static func restart(erase: () -> Report, discardInMemoryState: () -> Void, generation: AppleResetGeneration) {
        let report = erase()
        appleTrace("reset: this device only, downloads=deleted (\(report.removedItems) items, \(report.failedItems) failed)")
        discardInMemoryState()
        generation.advance()
        appleTrace("reset: back to first run in place (generation \(generation.value))")
    }

    /// Shared objects that outlive the root view and hold what the wipe just
    /// removed from disk.
    @MainActor
    static func discardInMemoryState() {
        AppleLocalLibraryStore.shared.discardAfterReset()
        AppleChannelHealthStore.shared.discardAfterReset()
        ApplePlaybackFailureHistory.shared.removeAll()
        ApplePlaybackProgressFeed.shared.storeDidChange()
        AppleRemoteImageCache.shared.removeAllCached()
        Task { await AppleStremioPreviewAssetsCache.shared.removeAll() }
    }

    /// `-OpenStreamResetOnLaunch YES`: the same wipe, before any store loads,
    /// for the test tooling. Debug builds only; Release has no such switch.
    public static func performIfRequestedAtLaunch() {
        #if DEBUG
        guard UserDefaults.standard.bool(forKey: "OpenStreamResetOnLaunch") else { return }
        let report = eraseThisDevice()
        appleTrace("reset: this device only, downloads=deleted (launch argument, \(report.removedItems) items)")
        #endif
    }

    @discardableResult
    static func eraseThisDevice() -> Report {
        let fileManager = FileManager.default
        var report = wipe(defaults: .standard, domain: Bundle.main.bundleIdentifier,
                          directories: containerDirectories(fileManager), fileManager: fileManager)
        let group = AppleTopShelfSnapshotWriter.appGroup
        if let groupDefaults = UserDefaults(suiteName: group) {
            groupDefaults.removePersistentDomain(forName: group)
        }
        if let groupRoot = fileManager.containerURL(forSecurityApplicationGroupIdentifier: group) {
            let groupReport = wipe(directories: libraryTree(root: groupRoot), fileManager: fileManager)
            report.removedItems += groupReport.removedItems
            report.failedItems += groupReport.failedItems
        }
        removeLocalKeychainItems(services: localKeychainServices)
        return report
    }

    /// Clears the defaults domain (keeping `preservedDefaultsKeys`), marks
    /// iCloud as held, and empties every directory.
    static func wipe(defaults: UserDefaults, domain: String?, directories: [URL],
                     fileManager: FileManager = .default) -> Report {
        let kept = preservedDefaultsKeys.compactMap { key in defaults.object(forKey: key).map { (key, $0) } }
        if let domain { defaults.removePersistentDomain(forName: domain) }
        for (key, value) in kept { defaults.set(value, forKey: key) }
        defaults.set(true, forKey: cloudRestoreHeldKey)
        defaults.synchronize()
        return wipe(directories: directories, fileManager: fileManager)
    }

    /// Removes each directory's contents, leaving the directory itself, any
    /// child named in `preservedDirectoryNames`, and any child that is itself
    /// in `directories` (Library/Caches is emptied, not deleted, so code that
    /// writes into it still finds it).
    static func wipe(directories: [URL], fileManager: FileManager = .default) -> Report {
        var report = Report()
        let emptied = Set(directories.map { $0.resolvingSymlinksInPath().path })
        for directory in directories {
            guard let children = try? fileManager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: []) else { continue }
            for child in children where !preservedDirectoryNames.contains(child.lastPathComponent) {
                if emptied.contains(child.resolvingSymlinksInPath().path) { continue }
                do {
                    try fileManager.removeItem(at: child)
                    report.removedItems += 1
                } catch {
                    report.failedItems += 1
                }
            }
        }
        return report
    }

    /// Deletes this device's own (non-synchronizing) items in `services`.
    /// Synchronizable items are shared with the viewer's other devices through
    /// iCloud Keychain and are left alone.
    static func removeLocalKeychainItems(services: [String]) {
        if AppleKeychainStore.isBypassedForReview { return }
        if let memory = AppleKeychainStore.testMemory {
            for service in services { memory.removeAll(service: service) }
            return
        }
        for service in services {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            ]
            SecItemDelete(query as CFDictionary)
        }
    }

    /// The app's own storage. A Mac build outside the sandbox would resolve
    /// these to the viewer's home folders, so there only the app's own
    /// subfolders are wiped.
    static func containerDirectories(_ fileManager: FileManager) -> [URL] {
        let temporary = fileManager.temporaryDirectory
        #if os(macOS)
        if ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] == nil {
            let bundle = Bundle.main.bundleIdentifier ?? "com.orgista.openstream"
            return [.applicationSupportDirectory, .cachesDirectory].compactMap {
                fileManager.urls(for: $0, in: .userDomainMask).first?.appendingPathComponent(bundle)
            }
        }
        #endif
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)
        let library = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first
        return documents + (library.map { libraryTree(library: $0) } ?? []) + [temporary]
    }

    /// A container root, its Library, and the Library folders that are
    /// emptied rather than deleted.
    static func libraryTree(root: URL) -> [URL] {
        [root] + libraryTree(library: root.appendingPathComponent("Library", isDirectory: true))
    }

    static func libraryTree(library: URL) -> [URL] {
        [library,
         library.appendingPathComponent("Caches", isDirectory: true),
         library.appendingPathComponent("Application Support", isDirectory: true)]
    }
}
