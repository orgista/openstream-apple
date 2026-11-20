import CryptoKit
import Foundation
import Testing
@testable import OpenStreamApple

@Suite("Source enable control")
struct AppleSourceEnableControlTests {
    @Test func aSourceWaitingForItsSignInOffersSignInNotADeadSwitch() throws {
        var source = AppleSource(kind: .liveTV, name: "Provider", url: try #require(URL(string: "https://fixture.example/")))
        #expect(AppleSourceEnableControl.control(for: source) == .toggle)
        source.needsSignIn = true
        #expect(AppleSourceEnableControl.control(for: source) == .signIn)
    }
}

@Suite("Hold to confirm")
struct AppleHoldToConfirmPolicyTests {
    @Test func releasingAt4point9SecondsCancels() {
        #expect(!AppleHoldToConfirmPolicy.fires(heldFor: .milliseconds(4_900)))
    }

    @Test func holdingFiveSecondsFires() {
        #expect(AppleHoldToConfirmPolicy.fires(heldFor: .seconds(5)))
        #expect(AppleHoldToConfirmPolicy.fires(heldFor: .milliseconds(5_300)))
    }
}

@Suite("Full backup")
@MainActor
struct AppleFullBackupTests {
    private let publicPlaylist = URL(string: "https://public.fixture.example/list.m3u")!
    private let configuredPlaylist = URL(string: "https://configured.fixture.example/FIXTUREKEY/list.m3u")!
    /// An address with nothing private in it, which a plain file carries whole.
    private let plainPlaylist = URL(string: "https://public.fixture.example/")!

    /// A phone with two playlists (one with a key in its address) and an
    /// Xtream provider with its password.
    private func seededPhone(keys: MemoryBackupKeys) throws -> (BackupTestDevice, [AppleSource.ID]) {
        let phone = try BackupTestDevice(keys: keys)
        let open = try phone.sources.addIPTV(name: "Public", type: .m3u, endpoint: publicPlaylist.absoluteString)
        let configured = try phone.sources.addIPTV(name: "Configured", type: .m3u,
            endpoint: configuredPlaylist.absoluteString)
        let provider = try phone.sources.addIPTV(name: "Provider", type: .xtream,
            endpoint: "https://fixture.example", username: "fixture-user", password: "fixture-password")
        return (phone, [open.id, configured.id, provider.id])
    }

    @Test func aFullBackupRestoresEverythingSignedInWithTheICloudKey() async throws {
        let keys = MemoryBackupKeys()
        let (phone, ids) = try seededPhone(keys: keys)
        defer { phone.tearDown() }
        let data = try await phone.controller.export(passphrase: "")

        let text = String(decoding: data, as: UTF8.self)
        for secret in ["fixture-password", "FIXTUREKEY", "Provider", "fixture.example", "Public"] {
            #expect(!text.contains(secret), "\(secret) is readable in the file")
        }
        #expect(AppleBackupEnvelope.header(of: data)?.mode == .iCloudKey)

        let pad = try BackupTestDevice(keys: keys)
        defer { pad.tearDown() }
        let preview = try pad.controller.inspectBackup(data)
        #expect(preview.failure == nil)
        #expect(!preview.needsPassphrase)
        #expect(preview.snapshot?.sources.count == 3)
        try await pad.controller.restore(data, passphrase: "")

        let restored = pad.sources.sources
        #expect(restored.count == 3)
        #expect(restored.allSatisfy { !$0.needsSignIn && $0.isEnabled })
        #expect(restored.first { $0.id == ids[0] }?.url == publicPlaylist)
        #expect(restored.first { $0.id == ids[1] }?.url == configuredPlaylist)
        #expect(try pad.sources.configurationSecrets().sourceCredentials[ids[2]] != nil)
    }

    @Test func twoFoldersFromOneShareRestoreWithTheirAddressesAndCredentials() async throws {
        let keys = MemoryBackupKeys()
        let phone = try BackupTestDevice(keys: keys)
        defer { phone.tearDown() }
        let movies = try phone.sources.addNetworkShare(name: "Movies", host: "fixture.example", port: 1445,
            share: "Media", path: "Movies/4K", username: "fixture-user", password: "fixture-password", domain: "FIXTURE")
        let shows = try phone.sources.addNetworkShare(name: "Shows", host: "fixture.example", port: 1445,
            share: "Media", path: "TV Shows", username: "fixture-user", password: "fixture-password", domain: "FIXTURE")
        #expect(movies.credentialReference == shows.credentialReference)
        let data = try await phone.controller.export(passphrase: "")
        let pad = try BackupTestDevice(keys: keys)
        defer { pad.tearDown() }
        #expect(try pad.controller.inspectBackup(data).snapshot?.sources.count == 2)
        try await pad.controller.restore(data, passphrase: "")
        let restored = pad.sources.sources
        #expect(restored.map(\.id) == [movies.id, shows.id])
        #expect(restored.map(\.url) == [movies.url, shows.url])
        #expect(restored.allSatisfy { !$0.needsSignIn && $0.isEnabled })
        for folder in restored {
            #expect(try pad.sources.networkCredentials(for: folder) == AppleSMBCredentials(
                username: "fixture-user", password: "fixture-password", domain: "FIXTURE"))
        }
        #expect(pad.sources.remove(id: movies.id))
        let restoredShows = try #require(restored.first { $0.id == shows.id })
        #expect(try pad.sources.networkCredentials(for: restoredShows)?.password == "fixture-password")

        // The existing portable cloud shape still carries both folder identities;
        // full addresses/accounts reconnect through per-ID iCloud Keychain mirrors.
        try phone.sources.prepareConfigurationKeychain()
        let cloud = AppleConfigurationSnapshot(sources: phone.sources.sources)
        let decoded = try JSONDecoder().decode(AppleConfigurationSnapshot.self, from: cloud.cloudData())
        #expect(decoded.sources.map(\.id) == [movies.id, shows.id])
        #expect(decoded.sources.allSatisfy { $0.credentialReference == nil })
        #expect(try phone.sources.restoreConfigurationSources(decoded.sources, secrets: nil, merge: false) == 0)
        #expect(phone.sources.sources.map(\.url) == [movies.url, shows.url])
        for folder in phone.sources.sources {
            #expect(try phone.sources.networkCredentials(for: folder)?.domain == "FIXTURE")
        }
    }

    @Test func anotherAppleAccountCannotOpenTheICloudKeyBackup() async throws {
        let (phone, _) = try seededPhone(keys: MemoryBackupKeys())
        defer { phone.tearDown() }
        let data = try await phone.controller.export(passphrase: "")
        let stranger = try BackupTestDevice(keys: MemoryBackupKeys())
        defer { stranger.tearDown() }
        let preview = try stranger.controller.inspectBackup(data)
        #expect(preview.failure == .otherAppleAccount)
        #expect(preview.snapshot == nil)
        await #expect(throws: AppleConfigurationError.otherAppleAccount) {
            try await stranger.controller.restore(data, passphrase: "")
        }
        #expect(stranger.sources.sources.isEmpty)
    }

    @Test func aPassphraseBackupOpensOnAnotherAccountWithThePassphrase() async throws {
        let (phone, ids) = try seededPhone(keys: MemoryBackupKeys())
        defer { phone.tearDown() }
        let data = try await phone.controller.export(passphrase: "fixture passphrase")
        #expect(AppleBackupEnvelope.header(of: data)?.mode == .passphrase)

        let stranger = try BackupTestDevice(keys: MemoryBackupKeys())
        defer { stranger.tearDown() }
        let preview = try stranger.controller.inspectBackup(data)
        #expect(preview.needsPassphrase)
        #expect(preview.snapshot == nil)
        await #expect(throws: AppleConfigurationError.wrongPassphrase) {
            try await stranger.controller.restore(data, passphrase: "wrong passphrase")
        }
        try await stranger.controller.restore(data, passphrase: "fixture passphrase")
        #expect(stranger.sources.sources.count == 3)
        #expect(stranger.sources.sources.allSatisfy { !$0.needsSignIn })
        #expect(stranger.sources.sources.first { $0.id == ids[1] }?.url == configuredPlaylist)
    }

    @Test func withoutAnICloudKeyExportAsksForAPassphrase() async throws {
        let (phone, _) = try seededPhone(keys: MemoryBackupKeys(canSave: false))
        defer { phone.tearDown() }
        await #expect(throws: AppleConfigurationError.backupKeyUnavailable) {
            _ = try await phone.controller.export(passphrase: "")
        }
        #expect(try await !phone.controller.export(passphrase: "fixture passphrase").isEmpty)
    }

    @Test func anOldPlainFileStillImports() async throws {
        let old = try AppleConfigurationFile.encode(snapshot: AppleConfigurationSnapshot(sources: [
            AppleSource(kind: .liveTV, name: "Public", url: plainPlaylist, iptvType: .m3u),
        ]))
        let pad = try BackupTestDevice(keys: MemoryBackupKeys())
        defer { pad.tearDown() }
        let preview = try pad.controller.inspectBackup(old)
        #expect(preview.snapshot?.sources.count == 1)
        #expect(!preview.needsPassphrase)
        try await pad.controller.restore(old, passphrase: "")
        #expect(pad.sources.sources.first?.url == plainPlaylist)
        #expect(pad.sources.sources.first?.needsSignIn == false)
    }

    @Test func anOldPassphraseFileStillImports() async throws {
        let snapshot = AppleConfigurationSnapshot(sources: [
            AppleSource(kind: .liveTV, name: "Configured", url: configuredPlaylist, iptvType: .m3u),
        ])
        let id = snapshot.sources[0].id
        let old = try AppleConfigurationFile.encode(snapshot: snapshot,
            secrets: AppleConfigurationSecrets(sourceAddresses: [id: configuredPlaylist]), passphrase: "fixture passphrase")
        let pad = try BackupTestDevice(keys: MemoryBackupKeys())
        defer { pad.tearDown() }
        #expect(try pad.controller.inspectBackup(old).needsPassphrase)
        try await pad.controller.restore(old, passphrase: "fixture passphrase")
        #expect(pad.sources.sources.first?.url == configuredPlaylist)
    }
}

@Suite("Reset OpenStream")
struct AppleDeviceResetTests {
    @Test func theWipeEmptiesTheContainerAndKeepsOnlyTheKeychainChoice() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appending(path: "reset-\(UUID())", directoryHint: .isDirectory)
        defer { try? fileManager.removeItem(at: root) }
        let library = root.appending(path: "Library", directoryHint: .isDirectory)
        let documents = root.appending(path: "Documents", directoryHint: .isDirectory)
        for folder in ["Documents/Downloads", "Library/Caches/artwork", "Library/Application Support/index",
                       "Library/Preferences", "Library/Other"] {
            try fileManager.createDirectory(at: root.appending(path: folder), withIntermediateDirectories: true)
        }
        for file in ["Documents/Downloads/film.mp4", "Library/Caches/artwork/a.jpg",
                     "Library/Application Support/index/db.json", "Library/Preferences/app.plist", "Library/Other/x"] {
            try Data([1]).write(to: root.appending(path: file))
        }
        let suite = "reset-defaults.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data([1]), forKey: "openstream.sources.v1")
        defaults.set(["tt1": 5], forKey: "openstream.ratings.v1")
        defaults.set(false, forKey: AppleKeychainStore.syncPreferenceKey)

        let report = AppleDeviceReset.wipe(defaults: defaults, domain: suite,
                                           directories: [documents] + AppleDeviceReset.libraryTree(library: library))

        #expect(report.failedItems == 0)
        #expect(try fileManager.contentsOfDirectory(atPath: documents.path).isEmpty)
        #expect(try fileManager.contentsOfDirectory(atPath: library.appending(path: "Caches").path).isEmpty)
        #expect(try fileManager.contentsOfDirectory(atPath: library.appending(path: "Application Support").path).isEmpty)
        #expect(!fileManager.fileExists(atPath: library.appending(path: "Other").path))
        #expect(fileManager.fileExists(atPath: library.appending(path: "Preferences/app.plist").path))
        #expect(defaults.object(forKey: "openstream.sources.v1") == nil)
        #expect(defaults.object(forKey: "openstream.ratings.v1") == nil)
        #expect(defaults.object(forKey: AppleKeychainStore.syncPreferenceKey) as? Bool == false)
        #expect(defaults.bool(forKey: AppleDeviceReset.cloudRestoreHeldKey))
    }

    /// e2e 2026-10-12: the group root's container metadata was deleted and the
    /// app group stopped existing for widgets and Top Shelf.
    @Test func theWipeKeepsTheSystemsContainerBookkeeping() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appending(path: "reset-group-\(UUID())", directoryHint: .isDirectory)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root.appending(path: "Library/Caches"), withIntermediateDirectories: true)
        let metadata = root.appending(path: ".com.apple.mobile_container_manager.metadata.plist")
        try Data([1]).write(to: metadata)
        try Data([1]).write(to: root.appending(path: "topshelf.json"))

        let report = AppleDeviceReset.wipe(directories: AppleDeviceReset.libraryTree(root: root))

        #expect(report.failedItems == 0)
        #expect(fileManager.fileExists(atPath: metadata.path))
        #expect(!fileManager.fileExists(atPath: root.appending(path: "topshelf.json").path))
    }

    @Test func theBackupKeySurvivesTheKeychainWipe() throws {
        try #require(AppleKeychainStore.testMemory != nil, "needs the in-process test keychain")
        #expect(!AppleDeviceReset.localKeychainServices.contains(AppleICloudBackupKeychain.defaultService))
        let localService = "reset-local.\(UUID())"
        let keys = AppleICloudBackupKeychain(service: "reset-backup-key.\(UUID())")
        let local = AppleKeychainStore(service: localService)
        try local.set("fixture-password", for: "provider")
        let key = try keys.exportKey()

        AppleDeviceReset.removeLocalKeychainItems(services: [localService])

        #expect(try local.string(for: "provider") == nil)
        let kept = try #require(try keys.existingKey())
        #expect(AppleBackupEnvelope.keyID(for: kept) == AppleBackupEnvelope.keyID(for: key))
    }

    @MainActor @Test func defaultsBurstDefersFingerprintUntilTheBurstSettles() async throws {
        let device = try BackupTestDevice(keys: MemoryBackupKeys())
        defer { device.tearDown() }
        device.defaults.set(false, forKey: AppleKeychainStore.syncPreferenceKey)
        await device.controller.start()
        let savedAtKey = "openstream.backup.savedAt.v1"
        device.defaults.removeObject(forKey: savedAtKey)
        device.defaults.set(false, forKey: AppleSettingsStore.autoPlayNextEpisodeKey)
        _ = device.controller.localChanged()
        device.defaults.set(true, forKey: AppleSettingsStore.autoPlayNextEpisodeKey)
        device.defaults.set(false, forKey: AppleSettingsStore.autoPlayNextEpisodeKey)
        let lastChange = try #require(device.controller.localChanged())
        #expect(device.defaults.object(forKey: savedAtKey) == nil)
        await lastChange.value
        #expect(device.defaults.object(forKey: savedAtKey) as? Date != nil)
        let saved = device.defaults.object(forKey: savedAtKey) as? Date
        await device.controller.localChanged()?.value
        #expect(device.defaults.object(forKey: savedAtKey) as? Date == saved)
    }

    @MainActor @Test func cloudReadFlushesAPendingLocalEditBeforeComparingClocks() async throws {
        let device = try BackupTestDevice(keys: MemoryBackupKeys())
        defer { device.tearDown() }
        await device.controller.start()
        device.defaults.removeObject(forKey: "openstream.backup.savedAt.v1")
        device.defaults.set(false, forKey: AppleSettingsStore.autoPlayNextEpisodeKey)
        device.controller.localChanged()
        await device.controller.readCloud()
        #expect(device.defaults.object(forKey: "openstream.backup.savedAt.v1") as? Date != nil)
    }

    /// After a reset the empty device neither refills itself from iCloud nor
    /// writes to it, until the viewer taps Restore from iCloud.
    @MainActor @Test func afterAResetICloudWaitsForRestoreAndIsNeverWritten() async throws {
        let device = try BackupTestDevice(keys: MemoryBackupKeys())
        defer { device.tearDown() }
        let seeded = try AppleConfigurationSnapshot(savedAt: .now, sources: [
            AppleSource(kind: .liveTV, name: "Public", url: #require(URL(string: "https://public.fixture.example/list.m3u")),
                        iptvType: .m3u),
        ]).cloudData()
        device.cloud.set(seeded, forKey: "openstream.configuration.v1")
        device.defaults.set(true, forKey: AppleDeviceReset.cloudRestoreHeldKey)

        await device.controller.start()
        device.controller.localChanged()
        #expect(device.sources.sources.isEmpty)
        #expect(device.cloud.data(forKey: "openstream.configuration.v1") == seeded)

        await device.controller.restoreFromCloud()
        #expect(device.sources.sources.map(\.name) == ["Public"])
        #expect(!device.defaults.bool(forKey: AppleDeviceReset.cloudRestoreHeldKey))
    }

    /// The app never quits itself (App Review, HIG): the reset wipes, drops
    /// the in-memory copies, then moves the generation the root view is keyed
    /// on. This test process still running afterwards is part of the proof.
    @MainActor @Test func resetStartsOverInPlaceWithoutQuitting() {
        let generation = AppleResetGeneration()
        var steps: [String] = []

        AppleDeviceReset.restart(
            erase: { steps.append("erase"); return AppleDeviceReset.Report(removedItems: 3) },
            discardInMemoryState: { steps.append("discard") },
            generation: generation
        )

        #expect(steps == ["erase", "discard"])
        #expect(generation.value == 1)
    }

    /// What the new root sees: stores created again from the wiped defaults
    /// start at No Sources.
    @MainActor @Test func storesCreatedAfterTheWipeStartAtNoSources() throws {
        let device = try BackupTestDevice(keys: MemoryBackupKeys())
        defer { device.tearDown() }
        let url = try #require(URL(string: "https://public.fixture.example/list.m3u"))
        _ = try device.sources.addIPTV(name: "Public", type: .m3u, endpoint: url.absoluteString)
        let failures = ApplePlaybackFailureHistory()
        failures.record(url)

        _ = AppleDeviceReset.wipe(defaults: device.defaults, domain: device.suite, directories: [])
        failures.removeAll()

        let recreated = AppleSourceStore(defaults: device.defaults, keychain: BackupTestCredentials())
        #expect(recreated.sources.isEmpty)
        #expect(!failures.contains(url))
    }
}

@MainActor
@Test func newerCloudCannotResurrectDeletedSourceAndSyncNowPublishesDeletion() async throws {
    let device = try BackupTestDevice(keys: MemoryBackupKeys())
    defer { device.tearDown() }
    let source = try device.sources.addIPTV(name: "Fixture", type: .m3u,
        endpoint: "https://fixture.example/playlist.m3u")
    let stale = AppleConfigurationSnapshot(savedAt: .now, sources: device.sources.sources)
    #expect(device.sources.remove(id: source.id))
    device.cloud.set(try stale.cloudData(), forKey: "openstream.configuration.v1")
    await device.controller.start()
    #expect(device.sources.sources.isEmpty)
    await device.controller.syncNow()
    let data = try #require(device.cloud.data(forKey: "openstream.configuration.v1"))
    let synced = try JSONDecoder().decode(AppleConfigurationSnapshot.self, from: data)
    #expect(synced.sources.isEmpty)
    #expect(synced.sourceTombstones[source.id] != nil)
    #expect(synced.merging(stale).sources.isEmpty)
}

@MainActor @Test func cloudControllerMergesPlaybackEvenWhenGlobalSnapshotIsOlder() async throws {
    let device = try BackupTestDevice(keys: MemoryBackupKeys())
    defer { device.tearDown() }
    _ = try device.sources.addIPTV(name: "Local fixture", type: .m3u, endpoint: "https://fixture.example/playlist.m3u")
    let old = Date(timeIntervalSince1970: 100), newer = Date(timeIntervalSince1970: 200)
    device.defaults.set(Date(timeIntervalSince1970: 500), forKey: "openstream.backup.savedAt.v1")
    let key = try #require(ApplePlaybackIdentity.storageKey(for: "fixture-film"))
    let store = ApplePlaybackStore(defaults: device.defaults)
    store.restoreConfigurationProgress([key: .init(position: 900, duration: 3600, updatedAt: old)])
    let cloud = AppleConfigurationSnapshot(savedAt: old, playbackProgress: [key: .init(position: 30, duration: 3600, updatedAt: newer)])
    device.cloud.set(try cloud.cloudData(), forKey: "openstream.configuration.v1")
    await device.controller.start()
    #expect(store.progress(for: "fixture-film")?.position == 30)
    #expect(device.sources.sources.map(\.name) == ["Local fixture"])
    store.clear(mediaID: "fixture-film")
    await device.controller.syncNow()
    let published = try JSONDecoder().decode(AppleConfigurationSnapshot.self,
        from: #require(device.cloud.data(forKey: "openstream.configuration.v1")))
    #expect(published.playbackTerminals[key]?.resetAt != nil)
    #expect(published.playbackProgress[key] == nil)
}

@MainActor @Test func newerCloudSnapshotReceivesOfflineLocalCompletionBarrier() async throws {
    let device = try BackupTestDevice(keys: MemoryBackupKeys())
    defer { device.tearDown() }
    _ = try device.sources.addIPTV(name: "Fixture", type: .m3u, endpoint: "https://fixture.example/playlist.m3u")
    let key = try #require(ApplePlaybackIdentity.storageKey(for: "fixture-film"))
    let store = ApplePlaybackStore(defaults: device.defaults)
    store.save(mediaID: "fixture-film", position: 3590, duration: 3600)
    let cloud = AppleConfigurationSnapshot(savedAt: Date(timeIntervalSinceNow: 60), sources: device.sources.sources,
        playbackProgress: [key: .init(position: 900, duration: 3600, updatedAt: Date(timeIntervalSince1970: 100))])
    device.cloud.set(try cloud.cloudData(), forKey: "openstream.configuration.v1")
    await device.controller.start()
    await device.controller.syncNow()
    let published = try JSONDecoder().decode(AppleConfigurationSnapshot.self,
        from: #require(device.cloud.data(forKey: "openstream.configuration.v1")))
    #expect(published.playbackTerminals[key]?.completedAt != nil)
    #expect(published.playbackProgress[key] == nil)
}

private let configurationKey = "openstream.configuration.v1"
private let savedAtKey = "openstream.backup.savedAt.v1"

private func publishedSnapshot(_ device: BackupTestDevice) throws -> AppleConfigurationSnapshot {
    try JSONDecoder().decode(AppleConfigurationSnapshot.self, from: #require(device.cloud.data(forKey: configurationKey)))
}

/// The phone's clock is behind the device that published last: its edit
/// still goes out stamped later, so a television that applied the earlier
/// copy reads it as newer instead of "not newer".
@MainActor @Test func anEditOnADeviceWhoseClockIsBehindStillReachesTheOthers() async throws {
    let device = try BackupTestDevice(keys: MemoryBackupKeys())
    defer { device.tearDown() }
    let fixture = try device.sources.addIPTV(name: "Fixture", type: .m3u, endpoint: "https://fixture.example/playlist.m3u")
    let ahead = Date(timeIntervalSinceNow: 3_600)
    let published = AppleConfigurationSnapshot(savedAt: ahead, sources: device.sources.sources)
    device.cloud.set(try published.cloudData(), forKey: configurationKey)
    await device.controller.start()
    #expect(device.defaults.object(forKey: savedAtKey) as? Date == ahead)

    #expect(device.sources.remove(id: fixture.id))
    await device.controller.localChanged()?.value
    await device.controller.syncNow()

    let sent = try publishedSnapshot(device)
    #expect(sent.savedAt > ahead)
    #expect(sent.sourceTombstones[fixture.id] != nil)
    let television = try AppleCloudConfigurationRead.decide(data: device.cloud.data(forKey: configurationKey), localSavedAt: ahead)
    guard case .apply(let received) = television else {
        Issue.record("the television must apply the deletion, got \(television)")
        return
    }
    #expect(received.sources.isEmpty)
}

/// A deletion this device made offline, folded into another device's newer
/// copy, is a new edit: without a later stamp every device that applied that
/// copy keeps the deleted source.
@MainActor @Test func anOfflineDeletionIsStampedAfterTheCopyItIsMergedInto() async throws {
    let device = try BackupTestDevice(keys: MemoryBackupKeys())
    defer { device.tearDown() }
    let kept = try device.sources.addIPTV(name: "Kept", type: .m3u, endpoint: "https://fixture.example/kept.m3u")
    let removed = try device.sources.addIPTV(name: "Removed", type: .m3u, endpoint: "https://fixture.example/removed.m3u")
    let other = AppleConfigurationSnapshot(savedAt: Date(timeIntervalSinceNow: 60), sources: device.sources.sources)
    #expect(device.sources.remove(id: removed.id))
    device.cloud.set(try other.cloudData(), forKey: configurationKey)

    await device.controller.start()
    await device.controller.syncNow()

    #expect(device.sources.sources.map(\.id) == [kept.id])
    let sent = try publishedSnapshot(device)
    #expect(sent.savedAt > other.savedAt)
    #expect(sent.sources.map(\.id) == [kept.id])
}

/// A newer copy from iCloud adds and updates sources; it does not drop one
/// this device has and the copy never had (an Apple TV's own source).
@MainActor @Test func aNewerCopyKeepsSourcesOnlyThisDeviceHas() async throws {
    let device = try BackupTestDevice(keys: MemoryBackupKeys())
    defer { device.tearDown() }
    let local = try device.sources.addIPTV(name: "Local", type: .m3u, endpoint: "https://fixture.example/local.m3u")
    let phone = AppleSource(kind: .liveTV, name: "Phone", url: try #require(URL(string: "https://fixture.example/phone.m3u")))
    device.defaults.set(Date(timeIntervalSince1970: 100), forKey: savedAtKey)
    device.cloud.set(try AppleConfigurationSnapshot(savedAt: .now, sources: [phone]).cloudData(), forKey: configurationKey)

    await device.controller.start()

    #expect(Set(device.sources.sources.map(\.id)) == [local.id, phone.id])
}

/// A newer copy this device cannot read is never applied, so it must not
/// hold this device's sends: the local edit replaces it.
@MainActor @Test func aNewerCopyThatCannotBeReadDoesNotHoldTheSend() async throws {
    let device = try BackupTestDevice(keys: MemoryBackupKeys())
    defer { device.tearDown() }
    let kept = try device.sources.addIPTV(name: "Kept", type: .m3u, endpoint: "https://fixture.example/kept.m3u")
    let removed = try device.sources.addIPTV(name: "Removed", type: .m3u, endpoint: "https://fixture.example/removed.m3u")
    await device.controller.start()
    let newer = AppleConfigurationSnapshot(savedAt: Date(timeIntervalSinceNow: 3_600), sources: device.sources.sources)
    var payload = try #require(JSONSerialization.jsonObject(with: newer.cloudData()) as? [String: Any])
    payload["formatVersion"] = 2
    device.cloud.set(try JSONSerialization.data(withJSONObject: payload), forKey: configurationKey)

    #expect(device.sources.remove(id: removed.id))
    await device.controller.localChanged()?.value
    await device.controller.syncNow()

    let sent = try publishedSnapshot(device)
    #expect(sent.formatVersion == 1)
    #expect(sent.sources.map(\.id) == [kept.id])
    #expect(sent.sourceTombstones[removed.id] != nil)
}

/// Restore from iCloud (and the Debug resume flag) applies what iCloud holds
/// even when this device stamped its own restore later, as the test Apple TV's did.
@MainActor @Test func restoreFromICloudAppliesWhatICloudHoldsAfterAHeldRestore() async throws {
    let device = try BackupTestDevice(keys: MemoryBackupKeys())
    defer { device.tearDown() }
    _ = try device.sources.addIPTV(name: "Restored", type: .m3u, endpoint: "https://fixture.example/restored.m3u")
    let phone = AppleSource(kind: .liveTV, name: "Phone", url: try #require(URL(string: "https://fixture.example/phone.m3u")))
    device.defaults.set(Date(timeIntervalSinceNow: 3_600), forKey: savedAtKey)
    device.defaults.set(true, forKey: AppleDeviceReset.cloudRestoreHeldKey)
    device.cloud.set(try AppleConfigurationSnapshot(savedAt: .now, sources: [phone]).cloudData(), forKey: configurationKey)
    await device.controller.start()
    #expect(device.sources.sources.map(\.name) == ["Restored"])

    await device.controller.restoreFromCloud()

    #expect(Set(device.sources.sources.map(\.name)) == ["Restored", "Phone"])
    #expect(!device.defaults.bool(forKey: AppleDeviceReset.cloudRestoreHeldKey))
}

/// A library scan or source check is not an edit: the phone no longer sends
/// every device a new setup each time one finishes.
@MainActor @Test func aSourceCheckAloneIsNotALocalEdit() async throws {
    let device = try BackupTestDevice(keys: MemoryBackupKeys())
    defer { device.tearDown() }
    let fixture = try device.sources.addIPTV(name: "Fixture", type: .m3u, endpoint: "https://fixture.example/playlist.m3u")
    await device.controller.start()
    let stamped = Date(timeIntervalSince1970: 100)
    device.defaults.set(stamped, forKey: savedAtKey)

    device.sources.recordValidationSuccess(id: fixture.id, summary: "402 files", discoveredItemCount: 402)
    await device.controller.localChanged()?.value

    #expect(device.defaults.object(forKey: savedAtKey) as? Date == stamped)
}

/// One device's stores on throwaway defaults, keychain and index file.
@MainActor
private struct BackupTestDevice {
    let suite: String
    let defaults: UserDefaults
    let sources: AppleSourceStore
    let controller: AppleConfigurationController
    let cloud = FakeCloudStore()
    let indexURL: URL

    init(keys: MemoryBackupKeys) throws {
        suite = "backup-device.\(UUID())"
        defaults = try #require(UserDefaults(suiteName: suite))
        indexURL = FileManager.default.temporaryDirectory.appending(path: "backup-index-\(UUID()).json")
        sources = AppleSourceStore(defaults: defaults, keychain: BackupTestCredentials())
        let settings = AppleSettingsStore(defaults: defaults, keychain: BackupTestCredentials())
        let index = AppleMediaIndexStore(repository: AppleMediaIndexRepository(fileURL: indexURL))
        controller = AppleConfigurationController(sources: sources, settings: settings, mediaIndex: index,
                                                  defaults: defaults, cloud: cloud, backupKeys: keys)
    }

    func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: indexURL)
    }
}

/// The Apple Account's backup key, in memory; `canSave: false` is a device
/// without iCloud Keychain.
private final class MemoryBackupKeys: AppleBackupKeyStoring, @unchecked Sendable {
    private var key: SymmetricKey?
    private let canSave: Bool

    init(canSave: Bool = true) { self.canSave = canSave }

    func existingKey() throws -> SymmetricKey? { key }

    func exportKey() throws -> SymmetricKey {
        if let key { return key }
        guard canSave else { throw AppleConfigurationError.backupKeyUnavailable }
        let made = SymmetricKey(size: .bits256)
        key = made
        return made
    }
}

private final class BackupTestCredentials: AppleCredentialStoring {
    private var values: [String: String] = [:]
    func string(for account: String) throws -> String? { values[account] }
    func set(_ value: String, for account: String) throws { values[account] = value }
    func remove(_ account: String) throws { values.removeValue(forKey: account) }
}
