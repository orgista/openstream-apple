import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class AppleConfigurationController {
    private(set) var syncEnabled: Bool
    private(set) var result: String?
    private(set) var isBusy = false
    /// What sync last did here; see `AppleConfigurationSyncStatus`.
    private(set) var status: AppleConfigurationSyncStatus
    private(set) var isSyncing = false
    let sources: AppleSourceStore
    private let settings: AppleSettingsStore
    private let mediaIndex: AppleMediaIndexStore
    private let defaults: UserDefaults
    private let cloud: AppleCloudKeyValueStore
    private let backupKeys: any AppleBackupKeyStoring
    private var pendingWrite: Task<Void, Never>?
    private var keychainRetry: Task<Void, Never>?
    /// Whether this device has had any source since launch. See
    /// `AppleConfigurationSyncPolicy.mayPublish`.
    private var heldSources = false
    private var lastContent: Data?
    private var applying = false
    private var started = false
    private static let cloudKey = "openstream.configuration.v1"
    private static let savedAtKey = "openstream.backup.savedAt.v1"

    init(sources: AppleSourceStore, settings: AppleSettingsStore, mediaIndex: AppleMediaIndexStore,
         defaults: UserDefaults = .standard, cloud: AppleCloudKeyValueStore = NSUbiquitousKeyValueStore.default,
         backupKeys: any AppleBackupKeyStoring = AppleICloudBackupKeychain()) {
        self.sources = sources
        self.settings = settings
        self.mediaIndex = mediaIndex
        self.defaults = defaults
        self.cloud = cloud
        self.backupKeys = backupKeys
        // The Apple TV has no switch to read, so the policy answers for it:
        // always on, and read-only. See `AppleConfigurationSyncPolicy`.
        AppleKeychainStore.adoptDefaultSyncPreference()
        syncEnabled = AppleConfigurationSyncPolicy.isEnabled(
            storedPreference: AppleConfigurationSyncPolicy.storedPreference(in: defaults)
        )
        status = AppleConfigurationSyncStatus.load(from: defaults)
    }

    func start() async {
        guard !started else { return }
        await mediaIndex.load()
        started = true
        heldSources = !sources.sources.isEmpty || !sources.sourceTombstones.isEmpty
        lastContent = try? contentFingerprint()
        // A device that syncs without ever being asked still has to move its
        // existing credentials into the synchronizing keychain. They were
        // written ThisDeviceOnly, and a synchronizable query does not find a
        // ThisDeviceOnly item — the Apple TV would have looked signed out of
        // every source it had already signed in to. Runs once: the migration
        // writes the preference it reads.
        if AppleConfigurationSyncPolicy.isAlwaysOn,
           !defaults.bool(forKey: AppleKeychainStore.syncPreferenceKey) {
            do {
                try AppleKeychainStore.setSynchronizationEnabled(true)
                appleTrace("configuration sync: migrated the keychain to synchronizing")
            } catch {
                appleTrace("configuration sync: keychain migration failed, reading local credentials only")
            }
        }
        appleTrace("configuration sync start: enabled=\(syncEnabled) publishes=\(AppleConfigurationSyncPolicy.publishesChanges())")
        if syncEnabled {
            cloud.synchronize()
            await readCloud(fillingEmptyLocal: true)
            publishIfNeeded()
        }
    }

    /// The app came to the front: read what iCloud holds, send this device's
    /// configuration if iCloud lacks it, and look again for sign-ins iCloud
    /// Keychain may have delivered since the retry schedule ended.
    func becameActive() async {
        await readCloud()
        retryKeychainNow()
        publishIfNeeded()
    }

    /// Backup & Sync's "Sync Now": read, then send if iCloud lacks this
    /// device's configuration. Same guards as launch.
    func syncNow() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        appleTrace("configuration sync now: enabled=\(syncEnabled) publishes=\(AppleConfigurationSyncPolicy.publishesChanges())")
        guard syncEnabled else {
            result = "Turn on Sync with iCloud first"
            return
        }
        appleTrace("configuration sync now: reading")
        cloud.synchronize()
        await readCloud(fillingEmptyLocal: true)
        retryKeychainNow()
        appleTrace("configuration sync now: deciding whether to send")
        if publishIfNeeded(immediately: true) {
            appleTrace("configuration sync now: sent")
        } else {
            appleTrace("configuration sync now: nothing to send")
            if status.lastError == nil { result = "Up to date with iCloud" }
        }
    }

    /// No Sources' "Restore from iCloud". Turns sync on if the viewer had
    /// turned it off, then pulls what iCloud holds into the empty device.
    func restoreFromCloud() async {
        // After Reset OpenStream this tap is what lets iCloud back in.
        defaults.removeObject(forKey: AppleDeviceReset.cloudRestoreHeldKey)
        if !syncEnabled { await setSyncEnabled(true) }
        guard syncEnabled else { return }
        cloud.synchronize()
        await readCloud(fillingEmptyLocal: true)
    }

    /// A full backup, sign-ins included, always sealed: with this Apple
    /// Account's iCloud Keychain backup key, or with `passphrase` when one is
    /// given (for a device on another Apple Account). Throws
    /// `backupKeyUnavailable` when there is no passphrase and no key can be kept.
    func export(passphrase: String) async throws -> Data {
        isBusy = true
        defer { isBusy = false }
        let payload = try fullPayload()
        let snapshot = payload.snapshot
        let data = passphrase.isEmpty
            ? try AppleBackupEnvelope.seal(payload, key: backupKeys.exportKey())
            : try await AppleBackupEnvelope.sealData(payload, passphrase: passphrase)
        appleTrace("backup export: \(snapshot.sources.count) sources, secrets=included")
        return data
    }

    /// Everything a full backup carries, sign-ins included.
    private func fullPayload() throws -> AppleBackupEnvelope.Payload {
        var secrets = try sources.configurationSecrets()
        secrets.settingsCredentials = try settings.configurationCredentials()
        secrets.privateSettings = try settings.configurationValues().filter {
            AppleSettingsStore.configurationURLKeys.contains($0.key)
        }
        return AppleBackupEnvelope.Payload(snapshot: try capture(), secrets: secrets)
    }

    /// Set Up from iPhone, sending side: the same content as a full backup.
    func setupTransferPayload(sender: String) throws -> AppleSetupTransferPayload {
        let payload = try fullPayload()
        appleTrace("setup send: prepared \(payload.snapshot.sources.count) sources")
        return AppleSetupTransferPayload(sender: sender, snapshot: payload.snapshot, secrets: payload.secrets)
    }

    /// Set Up from iPhone, receiving side: applied exactly like a backup
    /// import. Returns how many sources came over.
    @discardableResult
    func importSetupTransfer(_ payload: AppleSetupTransferPayload) async throws -> Int {
        isBusy = true
        defer { isBusy = false }
        try await apply(payload.snapshot, secrets: payload.secrets)
        try finishImport(payload.snapshot, trace: "setup import")
        result = "Setup imported"
        return payload.snapshot.sources.count
    }

    private func finishImport(_ snapshot: AppleConfigurationSnapshot, trace: String) throws {
        let ids = Set(snapshot.sources.map(\.id))
        let waiting = sources.sources.filter { ids.contains($0.id) && $0.needsSignIn }.count
        appleTrace("\(trace): \(ids.count - waiting) restored, \(waiting) need sign-in")
        // A deliberate file restore is a new local edit, regardless of the file's date.
        defaults.set(Date.now, forKey: Self.savedAtKey)
        lastContent = try contentFingerprint()
        if syncEnabled { scheduleWrite() }
    }

    /// What the import sheet can show before Import: the snapshot when the
    /// file is readable now, whether it wants a passphrase, or why it cannot
    /// be opened on this device.
    func inspectBackup(_ data: Data) throws -> AppleBackupPreview {
        guard data.count <= 10_000_000 else { throw AppleConfigurationError.tooLarge }
        if let envelope = AppleBackupEnvelope.header(of: data) {
            switch envelope.mode {
            case .passphrase:
                return AppleBackupPreview(snapshot: nil, needsPassphrase: true, failure: nil)
            case .iCloudKey:
                do {
                    let payload = try envelope.open(key: try? backupKeys.existingKey(), passphrase: "")
                    return AppleBackupPreview(snapshot: payload.snapshot, needsPassphrase: false, failure: nil)
                } catch let error as AppleConfigurationError {
                    return AppleBackupPreview(snapshot: nil, needsPassphrase: false, failure: error)
                }
            }
        }
        let file = try AppleConfigurationFile.inspect(data)
        return AppleBackupPreview(snapshot: file.snapshot, needsPassphrase: file.isEncrypted, failure: nil)
    }

    func restore(_ data: Data, passphrase: String) async throws {
        isBusy = true
        defer { isBusy = false }
        let decoded: (snapshot: AppleConfigurationSnapshot, secrets: AppleConfigurationSecrets?)
        if let envelope = AppleBackupEnvelope.header(of: data) {
            let key = envelope.mode == .iCloudKey ? try? backupKeys.existingKey() : nil
            let payload = try await envelope.openData(key: key, passphrase: passphrase)
            decoded = (payload.snapshot, payload.secrets)
        } else {
            decoded = try await AppleConfigurationFile.importData(data, passphrase: passphrase)
        }
        try await apply(decoded.snapshot, secrets: decoded.secrets)
        try finishImport(decoded.snapshot, trace: "backup import")
        result = "Configuration imported"
    }

    func setSyncEnabled(_ enabled: Bool) async {
        // Nothing on the Apple TV can reach this, but if anything ever did,
        // the television's answer is not the viewer's to change.
        guard AppleConfigurationSyncPolicy.offersToggle(), enabled != syncEnabled else { return }
        do {
            try AppleKeychainStore.setSynchronizationEnabled(enabled)
            syncEnabled = enabled
            pendingWrite?.cancel()
            if enabled {
                cloud.synchronize()
                await readCloud()
                scheduleWrite()
            }
            result = enabled ? "iCloud sync on" : "iCloud sync off"
        } catch { result = "Could not update Keychain sync" }
    }

    func localChanged() {
        guard started, !applying else { return }
        if !sources.sources.isEmpty { heldSources = true }
        do {
            let content = try contentFingerprint()
            guard content != lastContent else { return }
            lastContent = content
            // A reader never stamps a local edit. `savedAt` is how `readCloud`
            // decides whether the cloud snapshot is newer than this device's
            // configuration; on the Apple TV it means "the snapshot I last
            // applied", so a setting nudged with the remote cannot leave the
            // television permanently ahead of the phone and stop it syncing.
            guard AppleConfigurationSyncPolicy.publishesChanges() else { return }
            defaults.set(Date.now, forKey: Self.savedAtKey)
            if syncEnabled { scheduleWrite() }
        } catch { result = "Could not prepare configuration" }
    }

    /// `fillingEmptyLocal`: apply a snapshot with sources to a device that has
    /// none even when it is not newer (launch, iCloud's own change, Restore).
    func readCloud(fillingEmptyLocal: Bool = false) async {
        defer { scheduleKeychainRetry() }
        guard started, syncEnabled, !applying else {
            appleTrace("configuration sync read skipped: started=\(started) enabled=\(syncEnabled) applying=\(applying)")
            return
        }
        guard !cloudRestoreHeld else {
            appleTrace("configuration sync read held: reset, waiting for Restore from iCloud")
            return
        }
        do {
            applying = true
            try sources.refreshConfigurationKeychain()
            try settings.restoreConfigurationCredentials([:])
            applying = false
            let decision = try AppleCloudConfigurationRead.decide(
                data: cloud.data(forKey: Self.cloudKey),
                localSavedAt: defaults.object(forKey: Self.savedAtKey) as? Date,
                localIsEmpty: fillingEmptyLocal && sources.sources.isEmpty
            )
            guard case .apply(let snapshot) = decision else {
                appleTrace("configuration sync read: \(decision.traceDescription)")
                if decision == .notNewer { updateStatus { $0.recordingReceived(at: .now, sourceCount: self.sources.sources.count) } }
                return
            }
            pendingWrite?.cancel()
            try await apply(snapshot, secrets: nil, mergeSources: false)
            defaults.set(snapshot.savedAt, forKey: Self.savedAtKey)
            lastContent = try contentFingerprint()
            if sources.sourceTombstones != snapshot.sourceTombstones { scheduleWrite() }
            if !sources.sources.isEmpty || !sources.sourceTombstones.isEmpty { heldSources = true }
            appleTrace("configuration sync applied: \(snapshot.sources.count) sources from iCloud")
            updateStatus { $0.recordingReceived(at: .now, sourceCount: self.sources.sources.count) }
            result = "Synced with iCloud"
        } catch {
            applying = false
            result = "Could not restore iCloud configuration"
            updateStatus { $0.recordingError("Could not read the iCloud configuration") }
        }
    }

    func setResult(_ value: String) { result = value }

    /// A restored source waits signed out for credentials iCloud Keychain has
    /// not delivered yet. Becoming active and iCloud's own changes look again
    /// (`readCloud`); this also looks a few times on its own, because the
    /// keychain can arrive with neither.
    private func scheduleKeychainRetry() {
        guard syncEnabled, keychainRetry == nil, hasSourcesAwaitingKeychain else { return }
        keychainRetry = Task { [weak self] in
            for delay in AppleConfigurationSyncPolicy.keychainRetryDelays {
                do { try await Task.sleep(for: delay) } catch { return }
                guard let self else { return }
                guard self.syncEnabled, self.hasSourcesAwaitingKeychain else { break }
                guard !self.applying else { continue }
                self.applying = true
                do { try self.sources.refreshConfigurationKeychain() }
                catch { appleTrace("configuration sync: keychain look failed") }
                self.applying = false
                self.recordKeychainWaiting()
                if !self.hasSourcesAwaitingKeychain { appleTrace("configuration sync: restored sources signed in from iCloud Keychain") }
            }
            self?.keychainRetry = nil
        }
    }

    private var hasSourcesAwaitingKeychain: Bool { sourcesAwaitingKeychain > 0 }

    private var sourcesAwaitingKeychain: Int {
        sources.sources.filter { $0.needsSignIn && $0.kind != .library }.count
    }

    /// Looks once, right now, for sign-ins iCloud Keychain delivered after the
    /// retry schedule gave up, then starts the schedule again if any are
    /// still missing.
    private func retryKeychainNow() {
        defer { recordKeychainWaiting() }
        guard started, syncEnabled, !applying, hasSourcesAwaitingKeychain else { return }
        applying = true
        do { try sources.refreshConfigurationKeychain() }
        catch { appleTrace("configuration sync: keychain look failed") }
        applying = false
        appleTrace("configuration sync: keychain look on activation, waiting=\(sourcesAwaitingKeychain)")
        scheduleKeychainRetry()
    }

    private func recordKeychainWaiting() {
        updateStatus { $0.recordingSources(self.sources.sources.count, waitingForKeychain: self.sourcesAwaitingKeychain) }
    }

    private func updateStatus(_ change: (AppleConfigurationSyncStatus) -> AppleConfigurationSyncStatus) {
        let updated = change(status)
        guard updated != status else { return }
        status = updated
        updated.save(to: defaults)
    }

    /// Sends this device's configuration when iCloud lacks it
    /// (`AppleConfigurationSyncPolicy.publishesWithoutEdit`). Returns whether
    /// a send was made (`immediately`) or scheduled.
    @discardableResult
    private func publishIfNeeded(immediately: Bool = false) -> Bool {
        guard started, !applying else { return false }
        let stored = cloud.data(forKey: Self.cloudKey)
        let cloudSnapshot: AppleConfigurationSnapshot?
        if let stored {
            guard let decoded = try? JSONDecoder().decode(AppleConfigurationSnapshot.self, from: stored) else {
                appleTrace("configuration sync: iCloud copy unreadable, not replacing it")
                return false
            }
            cloudSnapshot = decoded
        } else {
            cloudSnapshot = nil
        }
        let localSavedAt = defaults.object(forKey: Self.savedAtKey) as? Date
        guard let local = try? capture(savedAt: localSavedAt ?? .now),
              AppleConfigurationSyncPolicy.publishesWithoutEdit(
                syncEnabled: syncEnabled, restoreHeld: cloudRestoreHeld,
                local: local, localSavedAt: localSavedAt, cloud: cloudSnapshot) else { return false }
        appleTrace("configuration sync: iCloud \(cloudSnapshot == nil ? "has nothing" : "is behind"), sending \(local.sources.count) sources")
        // Stamp a device that was set up before anything stamped it, so its
        // own copy does not later read as newer than itself.
        if localSavedAt == nil { defaults.set(local.savedAt, forKey: Self.savedAtKey) }
        if immediately { return writeNow() }
        scheduleWrite()
        return true
    }

    private func capture(savedAt: Date? = nil) throws -> AppleConfigurationSnapshot {
        var values = try settings.configurationValues()
        for key in AppleSettingsStore.configurationURLKeys {
            guard let data = values[key], let text = try AppleSettingsStore.configurationValue(data) as? String,
                  let url = URL(string: text), !text.isEmpty else { continue }
            let address = AppleConfigurationSnapshot.publicAddress(url).absoluteString
            values[key] = try PropertyListSerialization.data(fromPropertyList: [address], format: .binary, options: 0)
        }
        var snapshot = AppleConfigurationSnapshot(
            savedAt: savedAt ?? (defaults.object(forKey: Self.savedAtKey) as? Date ?? .now),
            sources: sources.sources, sourceTombstones: sources.sourceTombstones, settings: values,
            playbackProgress: ApplePlaybackStore(defaults: defaults).configurationProgress(),
            watchedHistory: ApplePlaybackStore(defaults: defaults).configurationWatchedHistory(),
            watchedTombstones: ApplePlaybackStore(defaults: defaults).configurationWatchedTombstones(),
            watchlist: mediaIndex.records.filter(\.isFavorite),
            ratings: AppleTitleRatingStore(defaults: defaults).allRatings.mapValues(\.rawValue),
            continueWatchingRemovals: ApplePlaybackStore(defaults: defaults).configurationContinueWatchingRemovals())
        snapshot.preservedSourcePayloads = sources.preservedConfigurationSources
        return snapshot
    }

    private func contentFingerprint() throws -> Data {
        try AppleConfigurationSnapshot.encoder.encode(capture(savedAt: .distantPast))
    }

    private func apply(_ snapshot: AppleConfigurationSnapshot, secrets: AppleConfigurationSecrets?, mergeSources: Bool = true) async throws {
        try traced("validate") { try snapshot.validate() }
        var values = snapshot.settings
        if let secrets {
            for (key, value) in secrets.privateSettings where AppleSettingsStore.configurationURLKeys.contains(key) {
                values[key] = value
            }
        } else if syncEnabled {
            values.merge(try settings.synchronizedConfigurationURLs()) { _, incoming in incoming }
        }
        // Validate settings before any store is changed.
        try traced("settings check") {
            for (key, value) in values where AppleSettingsStore.configurationKeys.contains(key) {
                _ = try AppleSettingsStore.configurationValue(value)
            }
        }
        applying = true
        defer { applying = false }
        // Sources and settings are the setup; a failure there stops the import
        // before anything else changes. What follows is kept on a best-effort
        // basis: a part this device cannot keep is skipped and traced, so the
        // rest still arrives (build 17's Apple TV lost the whole setup to its
        // unwritable Application Support).
        sources.mergeSourceTombstones(snapshot.sourceTombstones)
        try traced("sources") {
            let signedOut = try sources.restoreConfigurationSources(snapshot.sources, secrets: secrets, merge: mergeSources)
            if signedOut > 0 { appleTraceFailure("configuration apply: \(signedOut) sources kept signed out") }
        }
        try traced("other sources") {
            try sources.restorePreservedConfigurationSources(snapshot.preservedSourcePayloads, secrets: secrets, merge: mergeSources)
        }
        #if OPENSTREAM_ADDONS
        sources.refreshRestoredManifests(ids: snapshot.sources.map(\.id))
        #endif
        try traced("settings") {
            try settings.restoreConfiguration(snapshot.settings.merging(values) { _, incoming in incoming })
        }
        if let secrets {
            do { try settings.restoreConfigurationCredentials(secrets.settingsCredentials) }
            catch { appleTraceFailure("configuration apply: skipped settings sign-ins: \(appleErrorLabel(error))") }
        }
        ApplePlaybackStore(defaults: defaults).restoreConfigurationProgress(snapshot.playbackProgress)
        ApplePlaybackStore(defaults: defaults).restoreConfigurationWatchedHistory(
            snapshot.watchedHistory, tombstones: snapshot.watchedTombstones)
        ApplePlaybackStore(defaults: defaults).restoreConfigurationContinueWatchingRemovals(
            snapshot.continueWatchingRemovals)
        AppleTitleRatingStore(defaults: defaults).restoreConfigurationRatings(snapshot.ratings)
        do { try await mediaIndex.restoreConfigurationWatchlist(snapshot.watchlist) }
        catch { appleTraceFailure("configuration apply: skipped the watchlist: \(appleErrorLabel(error))") }
    }

    /// Runs one required step of `apply`, tracing which step failed and how.
    private func traced(_ step: String, _ body: () throws -> Void) throws {
        do { try body() }
        catch {
            appleTraceFailure("configuration apply: \(step) failed: \(appleErrorLabel(error))")
            throw error
        }
    }

    /// Reset OpenStream leaves this device out of iCloud, both ways, until
    /// the viewer taps Restore from iCloud: an empty device must not publish
    /// over the other devices' configuration, nor refill itself on its own.
    private var cloudRestoreHeld: Bool { defaults.bool(forKey: AppleDeviceReset.cloudRestoreHeldKey) }

    private func scheduleWrite() {
        guard AppleConfigurationSyncPolicy.publishesChanges(), !cloudRestoreHeld else { return }
        pendingWrite?.cancel()
        pendingWrite = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) }
            catch { return }
            guard let self, self.syncEnabled, !Task.isCancelled else { return }
            self.writeNow()
        }
    }

    /// Writes the snapshot to iCloud now, unless `mayPublish` keeps iCloud's
    /// sources. Returns whether it wrote.
    @discardableResult
    private func writeNow() -> Bool {
        guard syncEnabled, AppleConfigurationSyncPolicy.publishesChanges(), !cloudRestoreHeld else { return false }
        pendingWrite?.cancel()
        do {
            let stored = cloud.data(forKey: Self.cloudKey)
                .flatMap { try? JSONDecoder().decode(AppleConfigurationSnapshot.self, from: $0) }
            guard AppleConfigurationSyncPolicy.mayPublish(
                localSourceCount: sources.sources.count, heldSourcesSinceLaunch: heldSources,
                storedSourceCount: stored?.sources.count ?? 0) else {
                appleTrace("configuration sync: kept iCloud's sources, this device has none yet")
                return false
            }
            let local = try capture()
            let data = try (stored.map { $0.merging(local) } ?? local).cloudData()
            try sources.prepareConfigurationKeychain()
            try settings.prepareConfigurationKeychain()
            cloud.set(data, forKey: Self.cloudKey)
            cloud.synchronize()
            appleTrace("configuration sync: sent \(sources.sources.count) sources to iCloud")
            updateStatus { $0.recordingSent(at: .now, sourceCount: self.sources.sources.count) }
            result = "Configuration saved for iCloud"
            return true
        } catch {
            result = error.localizedDescription
            updateStatus { $0.recordingError(error.localizedDescription) }
            return false
        }
    }
}


@MainActor
struct AppleConfigurationSync: ViewModifier {
    @Binding var controller: AppleConfigurationController?
    let sources: AppleSourceStore
    let settings: AppleSettingsStore
    let mediaIndex: AppleMediaIndexStore
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .task {
                if controller == nil {
                    controller = AppleConfigurationController(sources: sources, settings: settings, mediaIndex: mediaIndex)
                }
                await controller?.start()
            }
            .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
                controller?.localChanged()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSUbiquitousKeyValueStore.didChangeExternallyNotification)) { _ in
                Task { await controller?.readCloud(fillingEmptyLocal: true) }
            }
            .onChange(of: mediaIndex.records.filter(\.isFavorite)) { _, _ in controller?.localChanged() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await controller?.becameActive() } }
            }
    }
}

/// What iCloud sync last did here, in one or two short lines: under the
/// Backup & Sync switch, and in the Apple TV's Sources pane.
struct AppleConfigurationSyncStatusLines: View {
    let status: AppleConfigurationSyncStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(status.activityLine { AppleConfigurationSyncStatus.time($0) })
            Text(status.detailLine)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("backup.sync.status")
    }
}
