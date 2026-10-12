import CryptoKit
import Foundation
import Testing
@testable import OpenStreamApple

@Suite("Add-on URL secret policy")
struct AppleAddonURLSecretPolicyTests {
    private func url(_ text: String) throws -> URL { try #require(URL(string: text)) }

    @Test(arguments: [
        "https://v3-cinemeta.strem.io/manifest.json",
        "https://opensubtitles-v3.strem.io/manifest.json",
        "https://torrentio.strem.fun/manifest.json",
        "https://addon.fixture.example/stremio/manifest.json",
        // Add-on sweep 2026-09-30: repository and catalog names, not options.
        "https://pages.fixture.example/40thproject-stremio-addon/manifest.json",
        "https://pages.fixture.example/animes-season-addon/manifest.json",
        "https://pages.fixture.example/org.stremio.NoReservationDailyMotion/manifest.json",
        "https://catalogs.fixture.example/christmaspopular/manifest.json",
        "https://raw.fixture.example/Andrev2/stremio-xmas-marathon/main/manifest.json",
        "https://pages.fixture.example/stremio-dragonball-es-catalog/manifest.json",
        "https://pages.fixture.example/selecta-vision-stremio/manifest.json",
        "https://dev.fixture.example/stremio/archive.org-addon/manifest.json",
        // Add-on sweep 2026-10-01: options with no key in them (Playlistio,
        // DubbedAnimeFeed, HdHub shapes), as JSON text or base64 JSON.
        "https://fixture.example/%7B%7D/manifest.json",
        "https://fixture.example/%7B%22tmdbKey%22%3A%22%22%7D/manifest.json",
        "https://fixture.example/eyJ0b3Jib3giOiJ1bnNldCIsInNvcnQiOiJkZXNjIn0/manifest.json",
        "https://fixture.baby-beamup.club/eyJjYXRhbG9ncyI6WyJuZngiLCJobnAiXX0/manifest.json",
    ])
    func unconfiguredAddonsArePublic(_ text: String) throws {
        #expect(!AppleAddonURLSecretPolicy.isSecret(try url(text)))
    }

    @Test(arguments: [
        "https://torrentio.strem.fun/realdebrid=FIXTUREKEY%7Csort=qualitysize/manifest.json",
        "https://torrentio.strem.fun/sort=qualitysize|realdebrid=FIXTUREKEY/manifest.json",
        "https://fixture.baby-beamup.club/%7B%22key%22%3A%22fixture%22%7D/manifest.json",
        // A key, a signed-in playlist or an instance id inside JSON options.
        // Any playlist address: sign-ins often sit in the path (user/pass/playlist.m3u).
        "https://fixture.example/eyJwcm92aWRlciI6ImRpcmVjdCIsIm0zdVVybCI6Imh0dHBzOi8vbGlzdHMuZml4dHVyZS5leGFtcGxlL2lwdHYvaW5kZXgubTN1IiwiZW5hYmxlRXBnIjpmYWxzZX0/manifest.json",
        "https://fixture.example/eyJ0b3Jib3giOiJmaXh0dXJlS2V5MDEyMzQ1Njc4OWFiY2RlZiJ9/manifest.json",
        "https://fixture.example/eyJwcm92aWRlciI6ImRpcmVjdCIsIm0zdVVybCI6Imh0dHBzOi8vbGlzdHMuZml4dHVyZS5leGFtcGxlL2dldC5waHA_dXNlcm5hbWU9dSZwYXNzd29yZD1wIn0/manifest.json",
        "https://fixture.example/eyJpbnN0YW5jZUlkIjoiMWI0ZTI4YmEtMmZhMS0xMWQyLTg4M2YtMDAxNmQzY2NhNDI3In0/manifest.json",
        "https://fixture.example/%7B%22realdebrid%22%3A%22FIXTUREKEY%22%7D/manifest.json",
        "https://addon.fixture.example/manifest.json?token=fixture-token",
        "https://user:pass@addon.fixture.example/manifest.json",
        "https://addon.fixture.example/",
        "https://fixture.example/0f1e2d3c4b5a69788796a5b4c3d2e1f0/manifest.json",
        "https://fixture.example/1b4e28ba-2fa1-11d2-883f-0016d3cca427/manifest.json",
        "https://fixture.example/QWERTYUIOPASDFGH/manifest.json",
        "https://fixture.example/xkcdqrtvbnmzpwlk/manifest.json",
        "https://fixture.example/aB3dE5fG7hJ9kL1mN/manifest.json",
    ])
    func configuredOrCredentialedAddonsAreSecret(_ text: String) throws {
        #expect(AppleAddonURLSecretPolicy.isSecret(try url(text)))
    }

    @Test func aLogoUnderAConfigurationPathIsSecret() throws {
        #expect(!AppleAddonURLSecretPolicy.isSecretAsset(try url("https://torrentio.strem.fun/images/logo_v1.png")))
        #expect(AppleAddonURLSecretPolicy.isSecretAsset(try url("https://addon.fixture.example/realdebrid=FIXTUREKEY/logo.png")))
    }

    @Test func aPublicAddonTravelsWholeAndSignedIn() throws {
        let manifest = try url("https://v3-cinemeta.strem.io/manifest.json")
        let portable = AppleConfigurationSnapshot.portableSource(
            AppleSource(kind: .stremio, name: "Cinemeta", url: manifest, transportReference: "transport.fixture"))
        #expect(portable.url == manifest)
        #expect(!portable.needsSignIn)
        #expect(portable.transportReference == nil)
    }

    @Test func aConfiguredAddonTravelsAsItsHostOnly() throws {
        let manifest = try url("https://torrentio.strem.fun/realdebrid=FIXTUREKEY%7Csort=qualitysize/manifest.json")
        let portable = AppleConfigurationSnapshot.portableSource(AppleSource(kind: .stremio, name: "Torrentio", url: manifest))
        #expect(portable.url.absoluteString == "https://torrentio.strem.fun/")
        #expect(portable.needsSignIn)
    }

    @Test func theLogoSurvivesTheFileAndTheICloudSnapshot() throws {
        let logo = try url("https://public.fixture.example/logo.png")
        let source = AppleSource(kind: .stremio, name: "Public",
                                 url: try url("https://public.fixture.example/manifest.json"), logoURL: logo)
        let snapshot = AppleConfigurationSnapshot(sources: [source])
        let fromFile = try AppleConfigurationFile.decode(AppleConfigurationFile.encode(snapshot: snapshot)).snapshot
        #expect(fromFile.sources.first?.logoURL == logo)
        let fromCloud = try JSONDecoder().decode(AppleConfigurationSnapshot.self, from: snapshot.cloudData())
        #expect(fromCloud.sources.first?.logoURL == logo)
    }
}

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
    private let publicManifest = URL(string: "https://public.fixture.example/manifest.json")!
    private let configuredManifest = URL(string: "https://configured.fixture.example/realdebrid=FIXTUREKEY%7Csort=qualitysize/manifest.json")!
    private let logo = URL(string: "https://public.fixture.example/logo.png")!

    /// A phone with a public add-on (with its logo), a configured add-on and
    /// an Xtream provider with its password.
    private func seededPhone(keys: MemoryBackupKeys) throws -> (BackupTestDevice, [AppleSource.ID]) {
        let phone = try BackupTestDevice(keys: keys)
        let open = try phone.sources.addStremio(manifestURL: publicManifest, name: "Public")
        phone.sources.applyManifest(AppleStremioManifest(id: "fixture.public", name: "Public", logoURL: logo), to: open.id)
        let configured = try phone.sources.addStremio(manifestURL: configuredManifest, name: "Configured")
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
        #expect(restored.first { $0.id == ids[0] }?.url == publicManifest)
        #expect(restored.first { $0.id == ids[0] }?.logoURL == logo)
        #expect(restored.first { $0.id == ids[1] }?.url == configuredManifest)
        #expect(try pad.sources.configurationSecrets().sourceCredentials[ids[2]] != nil)
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
        #expect(stranger.sources.sources.first { $0.id == ids[1] }?.url == configuredManifest)
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
            AppleSource(kind: .stremio, name: "Public", url: publicManifest),
        ]))
        let pad = try BackupTestDevice(keys: MemoryBackupKeys())
        defer { pad.tearDown() }
        let preview = try pad.controller.inspectBackup(old)
        #expect(preview.snapshot?.sources.count == 1)
        #expect(!preview.needsPassphrase)
        try await pad.controller.restore(old, passphrase: "")
        #expect(pad.sources.sources.first?.url == publicManifest)
        #expect(pad.sources.sources.first?.needsSignIn == false)
    }

    @Test func anOldPassphraseFileStillImports() async throws {
        let snapshot = AppleConfigurationSnapshot(sources: [AppleSource(kind: .stremio, name: "Configured", url: configuredManifest)])
        let id = snapshot.sources[0].id
        let old = try AppleConfigurationFile.encode(snapshot: snapshot,
            secrets: AppleConfigurationSecrets(sourceAddresses: [id: configuredManifest]), passphrase: "fixture passphrase")
        let pad = try BackupTestDevice(keys: MemoryBackupKeys())
        defer { pad.tearDown() }
        #expect(try pad.controller.inspectBackup(old).needsPassphrase)
        try await pad.controller.restore(old, passphrase: "fixture passphrase")
        #expect(pad.sources.sources.first?.url == configuredManifest)
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

    /// After a reset the empty device neither refills itself from iCloud nor
    /// writes to it, until the viewer taps Restore from iCloud.
    @MainActor @Test func afterAResetICloudWaitsForRestoreAndIsNeverWritten() async throws {
        let device = try BackupTestDevice(keys: MemoryBackupKeys())
        defer { device.tearDown() }
        let seeded = try AppleConfigurationSnapshot(savedAt: .now, sources: [
            AppleSource(kind: .stremio, name: "Public", url: #require(URL(string: "https://public.fixture.example/manifest.json"))),
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
        let url = try #require(URL(string: "https://public.fixture.example/manifest.json"))
        try device.sources.addStremio(manifestURL: url, name: "Public")
        let failures = ApplePlaybackFailureHistory()
        failures.record(url)

        _ = AppleDeviceReset.wipe(defaults: device.defaults, domain: device.suite, directories: [])
        failures.removeAll()

        let recreated = AppleSourceStore(defaults: device.defaults, keychain: BackupTestCredentials(),
                                         logoBackfillDelay: .seconds(3_600))
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
        // A long delay keeps the post-restore manifest refresh off the network.
        sources = AppleSourceStore(defaults: defaults, keychain: BackupTestCredentials(),
                                   logoBackfillDelay: .seconds(3_600))
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

@Suite("Add-on logo display URL")
struct AppleAddonLogoURLPolicyTests {
    private func display(_ text: String) throws -> String? {
        try AppleAddonLogoURLPolicy.displayURL(for: #require(URL(string: text)))?.absoluteString
    }

    @Test func plainHTTPLogosAreAskedForOverHTTPS() throws {
        #expect(try display("http://www.strem.io/images/addons/opensubtitles-logo.png")
            == "https://www.strem.io/images/addons/opensubtitles-logo.png")
    }

    @Test func rasterHTTPSLogosAreUnchanged() throws {
        #expect(try display("https://torrentio.strem.fun/images/logo_v1.png") == "https://torrentio.strem.fun/images/logo_v1.png")
        #expect(try display("https://myth-115.github.io/Dummy1/logo.png") == "https://myth-115.github.io/Dummy1/logo.png")
    }

    @Test func aWikimediaSVGUsesItsPNGRendition() throws {
        #expect(try display("https://upload.wikimedia.org/wikipedia/commons/5/5b/Rotten_Tomatoes.svg")
            == "https://upload.wikimedia.org/wikipedia/commons/thumb/5/5b/Rotten_Tomatoes.svg/256px-Rotten_Tomatoes.svg.png")
    }

    @Test func anyOtherSVGIsNoLogo() throws {
        #expect(try display("https://logo.fixture.example/mark.svg") == nil)
        #expect(try display("ftp://logo.fixture.example/mark.png") == nil)
    }
}
