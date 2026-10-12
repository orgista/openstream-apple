import Foundation
import Testing
@testable import OpenStreamApple

/// Apple TV: no switch, no Backup screen, no viewer action — it reads whatever
/// the phone has published and applies it.
///
/// Every test here is pure. The simulators on this Mac have no iCloud account
/// signed in, and `NSUbiquitousKeyValueStore` silently drops writes without
/// one, so a real two-device round trip cannot be exercised on this machine;
/// this suite is the proof that the decision either end of the store makes is
/// right. Same caveat as `AppleDevicePlaybackBeaconTests`.
@Suite("Configuration sync policy")
struct AppleConfigurationSyncTests {
    private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    private func source(id: UUID = UUID(), name: String = "Fixture") -> AppleSource {
        AppleSource(id: id, kind: .liveTV, name: name,
                    url: URL(string: "https://fixture.example/playlist")!)
    }

    private func cloudData(savedAt: Date, sources: [AppleSource]) throws -> Data {
        try AppleConfigurationSnapshot(savedAt: savedAt, sources: sources).cloudData()
    }

    // MARK: - Which devices sync, and which of them publish

    @Test func theAppleTVSyncsWithoutAStoredPreference() {
        #expect(AppleConfigurationSyncPolicy.isEnabled(storedPreference: false, mode: .automaticReadOnly))
        #expect(AppleConfigurationSyncPolicy.isEnabled(storedPreference: true, mode: .automaticReadOnly))
    }

    @Test func everywhereElseTheViewerDecides() {
        #expect(!AppleConfigurationSyncPolicy.isEnabled(storedPreference: false, mode: .viewerChoice))
        #expect(AppleConfigurationSyncPolicy.isEnabled(storedPreference: true, mode: .viewerChoice))
    }

    /// The television is a reader. A setting nudged with the remote must never
    /// be able to overwrite the configuration the phone published.
    @Test func theAppleTVNeverPublishes() {
        #expect(!AppleConfigurationSyncPolicy.publishesChanges(mode: .automaticReadOnly))
        #expect(AppleConfigurationSyncPolicy.publishesChanges(mode: .viewerChoice))
    }

    /// The switch-free mode is also the one that has to migrate the keychain
    /// on first launch, so the two answers must agree.
    @Test func alwaysOnMatchesTheReadOnlyMode() {
        #expect(AppleConfigurationSyncPolicy.isAlwaysOn == (AppleConfigurationSyncPolicy.current == .automaticReadOnly))
        #expect(AppleConfigurationSyncPolicy.isAlwaysOn != AppleConfigurationSyncPolicy.publishesChanges())
    }

    @Test func onlyTheViewerChoiceModeOffersASwitch() {
        #expect(!AppleConfigurationSyncPolicy.offersToggle(mode: .automaticReadOnly))
        #expect(AppleConfigurationSyncPolicy.offersToggle(mode: .viewerChoice))
    }

    @Test func thisPlatformPicksTheRightMode() {
        #if os(tvOS)
        #expect(AppleConfigurationSyncPolicy.current == .automaticReadOnly)
        #else
        #expect(AppleConfigurationSyncPolicy.current == .viewerChoice)
        #endif
    }

    // MARK: - What a launch, or an external change, does with the store

    /// The apply-on-launch and apply-on-change path, with the store's bytes
    /// seeded by hand. This is what `didChangeExternallyNotification` reaches.
    @Test func aNewerSnapshotIsApplied() throws {
        let data = try cloudData(savedAt: epoch, sources: [source(name: "From the iPhone")])
        let decision = try AppleCloudConfigurationRead.decide(
            data: data, localSavedAt: epoch.addingTimeInterval(-60))
        guard case .apply(let snapshot) = decision else {
            Issue.record("expected the newer snapshot to be applied, got \(decision)")
            return
        }
        #expect(snapshot.sources.map(\.name) == ["From the iPhone"])
        #expect(snapshot.savedAt == epoch)
    }

    /// A first launch on a television that has applied nothing yet.
    @Test func aFirstLaunchAppliesWhateverIsThere() throws {
        let data = try cloudData(savedAt: epoch, sources: [source()])
        #expect(try AppleCloudConfigurationRead.decide(data: data, localSavedAt: nil) != .notNewer)
    }

    /// The same notification fires repeatedly; re-applying the snapshot already
    /// in place would restore sources over whatever is on screen each time.
    @Test func theSnapshotAlreadyAppliedIsIgnored() throws {
        let data = try cloudData(savedAt: epoch, sources: [source()])
        #expect(try AppleCloudConfigurationRead.decide(data: data, localSavedAt: epoch) == .notNewer)
        #expect(try AppleCloudConfigurationRead.decide(
            data: data, localSavedAt: epoch.addingTimeInterval(1)) == .notNewer)
    }

    /// Signed out of iCloud, or an account that has never published: nothing
    /// stored, no crash, no sync — the same as before this existed.
    @Test func anEmptyStoreIsNotAnError() throws {
        #expect(try AppleCloudConfigurationRead.decide(data: nil, localSavedAt: nil) == .nothingStored)
        #expect(try AppleCloudConfigurationRead.decide(data: nil, localSavedAt: epoch) == .nothingStored)
    }

    @Test func anOversizedPayloadIsRejectedRatherThanDecoded() {
        let data = Data(repeating: 0x7B, count: AppleConfigurationSnapshot.maximumCloudBytes + 1)
        #expect(throws: AppleConfigurationError.tooLarge) {
            try AppleCloudConfigurationRead.decide(data: data, localSavedAt: nil)
        }
    }

    @Test func rubbishInTheStoreThrowsRatherThanApplying() {
        #expect(throws: (any Error).self) {
            try AppleCloudConfigurationRead.decide(data: Data("not a snapshot".utf8), localSavedAt: nil)
        }
    }

    // MARK: - Sync is on unless the viewer turned it off

    @Test func anUnsetPreferenceMeansSyncIsOn() {
        #expect(AppleConfigurationSyncPolicy.resolvedPreference(nil))
        #expect(AppleConfigurationSyncPolicy.isEnabled(
            storedPreference: AppleConfigurationSyncPolicy.resolvedPreference(nil), mode: .viewerChoice))
    }

    @Test func anExplicitOffStaysOff() {
        #expect(!AppleConfigurationSyncPolicy.resolvedPreference(false))
        #expect(AppleConfigurationSyncPolicy.resolvedPreference(true))
        #expect(!AppleConfigurationSyncPolicy.isEnabled(
            storedPreference: AppleConfigurationSyncPolicy.resolvedPreference(false), mode: .viewerChoice))
    }

    /// A launch argument (`-openstream.backup.icloud.enabled.v1 NO`) lands in
    /// the argument domain as a String; the UI tests turn sync off that way.
    @Test(arguments: ["NO", "no", "false", "FALSE", "0", " No "])
    func aLaunchArgumentTurnsSyncOff(value: String) {
        #expect(!AppleConfigurationSyncPolicy.resolvedPreference(storedValue: value))
    }

    @Test(arguments: ["YES", "yes", "true", "True", "1"])
    func aLaunchArgumentTurnsSyncOn(value: String) {
        #expect(AppleConfigurationSyncPolicy.resolvedPreference(storedValue: value))
    }

    @Test func boolsNumbersAndUnreadableValuesResolve() {
        #expect(!AppleConfigurationSyncPolicy.resolvedPreference(storedValue: false))
        #expect(AppleConfigurationSyncPolicy.resolvedPreference(storedValue: true))
        #expect(!AppleConfigurationSyncPolicy.resolvedPreference(storedValue: NSNumber(value: 0)))
        #expect(AppleConfigurationSyncPolicy.resolvedPreference(storedValue: NSNumber(value: 1)))
        #expect(AppleConfigurationSyncPolicy.resolvedPreference(storedValue: nil))
        #expect(AppleConfigurationSyncPolicy.resolvedPreference(storedValue: "maybe"))
        #expect(AppleConfigurationSyncPolicy.resolvedPreference(storedValue: Data()))
    }

    @Test func aStringInDefaultsIsReadAsTheSwitch() throws {
        let name = "configuration-sync-tests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("NO", forKey: AppleKeychainStore.syncPreferenceKey)
        #expect(!AppleConfigurationSyncPolicy.storedPreference(in: defaults))
        defaults.set("YES", forKey: AppleKeychainStore.syncPreferenceKey)
        #expect(AppleConfigurationSyncPolicy.storedPreference(in: defaults))
    }

    @Test func theStoredPreferenceIsReadWithTheDefault() throws {
        let name = "configuration-sync-tests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(AppleConfigurationSyncPolicy.storedPreference(in: defaults))
        defaults.set(false, forKey: AppleKeychainStore.syncPreferenceKey)
        #expect(!AppleConfigurationSyncPolicy.storedPreference(in: defaults))
    }

    // MARK: - A device with no sources

    /// A new device stamps a local edit before iCloud delivers anything, so
    /// the phone's snapshot is "older" and was never applied.
    @Test func anEmptyDeviceTakesTheSnapshotEvenWhenItIsNotNewer() throws {
        let data = try cloudData(savedAt: epoch, sources: [source(name: "From the iPhone")])
        let later = epoch.addingTimeInterval(60)
        let decision = try AppleCloudConfigurationRead.decide(data: data, localSavedAt: later, localIsEmpty: true)
        guard case .apply(let snapshot) = decision else {
            Issue.record("expected the empty device to take the snapshot, got \(decision)")
            return
        }
        #expect(snapshot.sources.map(\.name) == ["From the iPhone"])
        #expect(try AppleCloudConfigurationRead.decide(data: data, localSavedAt: later) == .notNewer)
    }

    @Test func anEmptyDeviceIgnoresAnOlderSnapshotWithNoSources() throws {
        let data = try cloudData(savedAt: epoch, sources: [])
        #expect(try AppleCloudConfigurationRead.decide(
            data: data, localSavedAt: epoch.addingTimeInterval(60), localIsEmpty: true) == .notNewer)
    }

    /// A new install must not publish its empty list over the phone's.
    @Test func aDeviceThatNeverHadSourcesDoesNotReplaceSomeWithNone() {
        #expect(!AppleConfigurationSyncPolicy.mayPublish(localSourceCount: 0, heldSourcesSinceLaunch: false, storedSourceCount: 3))
        #expect(AppleConfigurationSyncPolicy.mayPublish(localSourceCount: 0, heldSourcesSinceLaunch: true, storedSourceCount: 3))
        #expect(AppleConfigurationSyncPolicy.mayPublish(localSourceCount: 0, heldSourcesSinceLaunch: false, storedSourceCount: 0))
        #expect(AppleConfigurationSyncPolicy.mayPublish(localSourceCount: 1, heldSourcesSinceLaunch: false, storedSourceCount: 3))
    }

    @Test func keychainRetriesAreFewAndGrow() {
        let delays = AppleConfigurationSyncPolicy.keychainRetryDelays
        #expect(!delays.isEmpty && delays.count <= 6)
        #expect(delays == delays.sorted())
    }

    /// iCloud Keychain delivers a restored source's credentials after the
    /// snapshot. When they land, the source signs itself back in.
    @MainActor @Test func aRestoredSourceSignsInWhenItsKeychainItemsArrive() throws {
        #expect(AppleConfigurationSyncPolicy.storedPreference(), "this test needs sync on in the test process")
        let phoneName = "configuration-sync-phone.\(UUID())"
        let padName = "configuration-sync-pad.\(UUID())"
        let phoneDefaults = try #require(UserDefaults(suiteName: phoneName))
        let padDefaults = try #require(UserDefaults(suiteName: padName))
        defer {
            phoneDefaults.removePersistentDomain(forName: phoneName)
            padDefaults.removePersistentDomain(forName: padName)
        }
        let phoneKeychain = SyncTestCredentials()
        let padKeychain = SyncTestCredentials()
        let phone = AppleSourceStore(defaults: phoneDefaults, keychain: phoneKeychain)
        let added = try phone.addIPTV(name: "Provider", type: .xtream,
            endpoint: "https://fixture.example", username: "fixture-user", password: "fixture-password")
        try phone.prepareConfigurationKeychain()

        let pad = AppleSourceStore(defaults: padDefaults, keychain: padKeychain)
        try pad.restoreConfigurationSources(phone.sources, secrets: nil, merge: false)
        let waiting = try #require(pad.sources.first { $0.id == added.id })
        #expect(waiting.needsSignIn)
        #expect(!waiting.isEnabled)

        padKeychain.values = phoneKeychain.values
        try pad.refreshConfigurationKeychain()
        let signedIn = try #require(pad.sources.first { $0.id == added.id })
        #expect(!signedIn.needsSignIn)
        #expect(signedIn.isEnabled)
    }

    // MARK: - Sending without a local edit (launch, becoming active, Sync Now)

    private func snapshot(savedAt: Date, sources: [AppleSource]) -> AppleConfigurationSnapshot {
        AppleConfigurationSnapshot(savedAt: savedAt, sources: sources)
    }

    private func publishes(
        mode: AppleConfigurationSyncMode = .viewerChoice, syncEnabled: Bool = true, restoreHeld: Bool = false,
        local: AppleConfigurationSnapshot, localSavedAt: Date?, cloud: AppleConfigurationSnapshot?
    ) -> Bool {
        AppleConfigurationSyncPolicy.publishesWithoutEdit(
            mode: mode, syncEnabled: syncEnabled, restoreHeld: restoreHeld,
            local: local, localSavedAt: localSavedAt, cloud: cloud)
    }

    /// The phone set up before sync was on by default: iCloud holds nothing,
    /// so it sends at launch without waiting for an edit.
    @Test func aConfiguredPhoneSendsWhenICloudHoldsNothing() {
        let local = snapshot(savedAt: epoch, sources: [source()])
        #expect(publishes(local: local, localSavedAt: epoch, cloud: nil))
        #expect(publishes(local: local, localSavedAt: nil, cloud: nil))
    }

    @Test func theAppleTVNeverSendsAtLaunch() {
        let local = snapshot(savedAt: epoch, sources: [source()])
        #expect(!publishes(mode: .automaticReadOnly, local: local, localSavedAt: epoch, cloud: nil))
    }

    @Test func anEmptyDeviceNeverSendsAtLaunch() {
        let empty = snapshot(savedAt: epoch.addingTimeInterval(60), sources: [])
        let cloud = snapshot(savedAt: epoch, sources: [source(name: "From the iPhone")])
        #expect(!publishes(local: empty, localSavedAt: epoch.addingTimeInterval(60), cloud: cloud))
        #expect(!publishes(local: empty, localSavedAt: nil, cloud: nil))
    }

    @Test func aResetDeviceNeverSendsAtLaunch() {
        let local = snapshot(savedAt: epoch.addingTimeInterval(60), sources: [source()])
        let cloud = snapshot(savedAt: epoch, sources: [source(name: "From the iPhone")])
        #expect(!publishes(restoreHeld: true, local: local, localSavedAt: epoch.addingTimeInterval(60), cloud: cloud))
        #expect(!publishes(restoreHeld: true, local: local, localSavedAt: epoch, cloud: nil))
    }

    @Test func syncOffNeverSends() {
        let local = snapshot(savedAt: epoch, sources: [source()])
        #expect(!publishes(syncEnabled: false, local: local, localSavedAt: epoch, cloud: nil))
    }

    /// Only the save time differs: iCloud already has this configuration.
    @Test func theSameConfigurationIsNotSentAgain() {
        let shared = source()
        let local = snapshot(savedAt: epoch.addingTimeInterval(60), sources: [shared])
        let cloud = snapshot(savedAt: epoch, sources: [shared])
        #expect(!publishes(local: local, localSavedAt: epoch.addingTimeInterval(60), cloud: cloud))
    }

    @Test func aNewerLocalConfigurationReplacesAnOlderOne() {
        let local = snapshot(savedAt: epoch.addingTimeInterval(60), sources: [source(name: "Phone")])
        let cloud = snapshot(savedAt: epoch, sources: [source(name: "Older")])
        #expect(publishes(local: local, localSavedAt: epoch.addingTimeInterval(60), cloud: cloud))
    }

    /// iCloud's copy is newer (the read applies it) or this device never
    /// stamped an edit: leave iCloud alone.
    @Test func anOlderOrUnstampedLocalConfigurationIsNotSent() {
        let local = snapshot(savedAt: epoch, sources: [source(name: "Phone")])
        let cloud = snapshot(savedAt: epoch.addingTimeInterval(60), sources: [source(name: "Newer")])
        #expect(!publishes(local: local, localSavedAt: epoch, cloud: cloud))
        #expect(!publishes(local: local, localSavedAt: nil, cloud: cloud))
    }

    @Test func anICloudCopyWithNoSourcesIsFilled() {
        let local = snapshot(savedAt: epoch, sources: [source()])
        let cloud = snapshot(savedAt: epoch.addingTimeInterval(60), sources: [])
        #expect(publishes(local: local, localSavedAt: nil, cloud: cloud))
    }

    // MARK: - Sync status

    @Test func statusRecordsSendsAndReceivesAndClearsTheError() {
        let failed = AppleConfigurationSyncStatus().recordingError("Could not read the iCloud configuration")
        #expect(failed.detailLine == "Could not read the iCloud configuration")
        let sent = failed.recordingSent(at: epoch, sourceCount: 8)
        #expect(sent.lastSentAt == epoch)
        #expect(sent.lastError == nil)
        let received = sent.recordingError("Quota").recordingReceived(at: epoch.addingTimeInterval(60), sourceCount: 7)
        #expect(received.lastReceivedAt == epoch.addingTimeInterval(60))
        #expect(received.lastSentAt == epoch)
        #expect(received.sourceCount == 7)
        #expect(received.lastError == nil)
    }

    @Test func statusLinesReadPlainly() {
        let time: (Date) -> String = { $0 == self.epoch ? "2:14 PM" : "2:15 PM" }
        #expect(AppleConfigurationSyncStatus().activityLine(time: time) == "Not synced yet")
        let status = AppleConfigurationSyncStatus()
            .recordingSent(at: epoch, sourceCount: 8)
            .recordingReceived(at: epoch.addingTimeInterval(60), sourceCount: 8)
        #expect(status.activityLine(time: time) == "Last sent 2:14 PM · Last received 2:15 PM")
        #expect(status.detailLine == "8 sources")
        #expect(status.recordingSources(8, waitingForKeychain: 2).detailLine
                == "8 sources · 2 waiting for passwords from iCloud Keychain")
        #expect(status.recordingSources(1, waitingForKeychain: 0).detailLine == "1 source")
    }

    /// Kept on this device only: never a configuration key, so never in a
    /// backup or the iCloud snapshot.
    @MainActor @Test func statusIsStoredLocallyAndNeverSynced() throws {
        let name = "configuration-sync-status.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(AppleConfigurationSyncStatus.load(from: defaults) == AppleConfigurationSyncStatus())
        let status = AppleConfigurationSyncStatus(lastSentAt: epoch, sourceCount: 3, waitingForKeychain: 1)
        status.save(to: defaults)
        #expect(AppleConfigurationSyncStatus.load(from: defaults) == status)
        #expect(!AppleSettingsStore.configurationKeys.contains(AppleConfigurationSyncStatus.defaultsKey))
    }

    // MARK: - The injectable store

    /// The controller talks to a protocol, so a fake can stand in for iCloud.
    @Test func aFakeStoreStandsInForICloud() throws {
        let store = FakeCloudStore()
        let data = try cloudData(savedAt: epoch, sources: [source(name: "Seeded")])
        store.set(data, forKey: "openstream.configuration.v1")
        #expect(store.synchronize())
        let decision = try AppleCloudConfigurationRead.decide(
            data: store.data(forKey: "openstream.configuration.v1"), localSavedAt: nil)
        guard case .apply(let snapshot) = decision else {
            Issue.record("expected the seeded snapshot to be applied, got \(decision)")
            return
        }
        #expect(snapshot.sources.map(\.name) == ["Seeded"])
    }
}

/// An in-memory `AppleCloudKeyValueStore`, so the read path can be exercised
/// without an iCloud account.
final class FakeCloudStore: AppleCloudKeyValueStore, @unchecked Sendable {
    private var storage: [String: Data] = [:]
    private(set) var synchronizeCount = 0

    func data(forKey key: String) -> Data? { storage[key] }

    func set(_ value: Data?, forKey key: String) { storage[key] = value }

    @discardableResult func synchronize() -> Bool {
        synchronizeCount += 1
        return true
    }
}

/// A keychain the test can hand from one device to the other.
private final class SyncTestCredentials: AppleCredentialStoring {
    var values: [String: String] = [:]
    func string(for account: String) throws -> String? { values[account] }
    func set(_ value: String, for account: String) throws { values[account] = value }
    func remove(_ account: String) throws { values.removeValue(forKey: account) }
}
