#if DEBUG && OPENSTREAM_ADDONS
import CryptoKit
import Foundation
import Testing
@testable import OpenStreamApple

/// Turns a dev-sources file (`scripts/dev-sources.py`, schema v1) into a
/// passphrase backup with the app's own code: the sources go in through
/// `AppleDevSourcesImport` (the add-screen store calls), the file comes out
/// of `AppleConfigurationController.export(passphrase:)`, so Settings › Backup
/// & Sync › Import reads it exactly like an in-app export.
///
/// The maker runs only when `OPENSTREAM_MAKE_BACKUP_IN`, `_PASS_FILE` and
/// `_OUT` are set; it prints source counts by kind, never a name or value.
/// Serialized: the dev-sources import keeps its pending file in static state.
@Suite("Owner backup maker", .serialized)
@MainActor
struct AppleOwnerBackupMakerTests {
    @Test func makesTheOwnerBackupWhenAsked() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let input = environment["OPENSTREAM_MAKE_BACKUP_IN"], !input.isEmpty,
              let passFile = environment["OPENSTREAM_MAKE_BACKUP_PASS_FILE"], !passFile.isEmpty,
              let output = environment["OPENSTREAM_MAKE_BACKUP_OUT"], !output.isEmpty else { return }
        let passphrase = try String(contentsOfFile: passFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try #require(!passphrase.isEmpty, "the passphrase file is empty")

        let phone = try OwnerBackupDevice()
        defer { phone.tearDown() }
        let file = try AppleDevSourcesPolicy.decode(Data(contentsOf: URL(fileURLWithPath: input)))
        try await phone.importDevSources(from: URL(fileURLWithPath: input))
        print("owner backup: file has \(file.sources.count) sources, \(file.problems.count) problems, "
              + "\(file.ignoredKinds.count) unknown kinds; settings \(file.settings.appliedNames)")
        print("owner backup: added \(Self.counts(phone.sources.sources))")

        let data = try await phone.controller.export(passphrase: passphrase)
        let url = URL(fileURLWithPath: output)
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)

        // Re-open it the way the import sheet does, on a fresh device.
        let reread = try Data(contentsOf: url)
        let envelope = try #require(AppleBackupEnvelope.header(of: reread))
        #expect(envelope.mode == .passphrase)
        let payload = try envelope.open(key: nil, passphrase: passphrase)
        #expect(payload.snapshot.sources.count == phone.sources.sources.count)
        let pad = try OwnerBackupDevice()
        defer { pad.tearDown() }
        try await pad.controller.restore(reread, passphrase: passphrase)
        let waiting = pad.sources.sources.filter(\.needsSignIn).count
        print("owner backup: reopened \(Self.counts(pad.sources.sources)); \(waiting) need sign-in; "
              + "tmdb=\(!pad.settings.tmdbAPIKey.isEmpty) metadata=\(pad.settings.metadataEnabled)")
        #expect(pad.sources.sources.count == phone.sources.sources.count)
        #expect(waiting == 0)
    }

    /// A synthetic dev-sources file (no network kinds) survives backup and
    /// restore with every source signed in and the TMDB key applied.
    @Test func aDevSourcesFileRoundTripsThroughABackup() async throws {
        let json = """
        {"version": 1, "sources": [
          {"kind": "xtream", "name": "Box", "serverURL": "http://iptv.fixture.example:8080",
           "username": "fixture-user", "password": "fixture-password"},
          {"kind": "m3u", "name": "List", "playlistURL": "https://iptv.fixture.example/get.php?username=u&password=p",
           "epgURL": "https://iptv.fixture.example/epg.xml"},
          {"kind": "smb", "name": "NAS", "host": "192.0.2.10", "share": "Media",
           "username": "fixture-user", "password": "fixture-password"}
        ], "settings": {"tmdbAPIKey": "fixture-tmdb"}}
        """
        let input = FileManager.default.temporaryDirectory.appending(path: "dev-sources-\(UUID()).json")
        try Data(json.utf8).write(to: input)
        defer { try? FileManager.default.removeItem(at: input) }

        let phone = try OwnerBackupDevice()
        defer { phone.tearDown() }
        try await phone.importDevSources(from: input)
        #expect(Self.counts(phone.sources.sources) == ["liveTV/m3u": 1, "liveTV/xtream": 1, "nas": 1])

        let data = try await phone.controller.export(passphrase: "fixture passphrase")
        let text = String(decoding: data, as: UTF8.self)
        for secret in ["fixture-password", "fixture-tmdb", "iptv.fixture.example", "Box"] {
            #expect(!text.contains(secret), "\(secret) is readable in the file")
        }
        let payload = try #require(AppleBackupEnvelope.header(of: data)).open(key: nil, passphrase: "fixture passphrase")
        #expect(payload.snapshot.sources.map(\.id) == phone.sources.sources.map(\.id))

        let pad = try OwnerBackupDevice()
        defer { pad.tearDown() }
        try await pad.controller.restore(data, passphrase: "fixture passphrase")
        #expect(pad.sources.sources.map(\.id) == phone.sources.sources.map(\.id))
        #expect(pad.sources.sources.allSatisfy { !$0.needsSignIn })
        #expect(try pad.sources.configurationSecrets().sourceCredentials.count
            == phone.sources.configurationSecrets().sourceCredentials.count)
        #expect(pad.settings.tmdbAPIKey == "fixture-tmdb")
    }

    /// "liveTV/xtream": 1, "nas": 1 … — kinds only.
    static func counts(_ sources: [AppleSource]) -> [String: Int] {
        sources.reduce(into: [:]) { counts, source in
            let detail = source.iptvType.map { "/\($0.rawValue)" } ?? source.serverKind.map { "/\($0.rawValue)" } ?? ""
            counts[source.kind.rawValue + detail, default: 0] += 1
        }
    }
}

/// One device's stores on throwaway defaults, keychain and index file, with
/// a passphrase-only backup key (as on a device without iCloud Keychain).
@MainActor
private struct OwnerBackupDevice {
    let suite: String
    let defaults: UserDefaults
    let sources: AppleSourceStore
    let settings: AppleSettingsStore
    let controller: AppleConfigurationController
    let indexURL: URL

    init() throws {
        suite = "owner-backup-device.\(UUID())"
        defaults = try #require(UserDefaults(suiteName: suite))
        indexURL = FileManager.default.temporaryDirectory.appending(path: "owner-backup-index-\(UUID()).json")
        sources = AppleSourceStore(defaults: defaults, keychain: OwnerBackupCredentials(),
                                   logoBackfillDelay: .seconds(3_600))
        settings = AppleSettingsStore(defaults: defaults, keychain: OwnerBackupCredentials())
        let index = AppleMediaIndexStore(repository: AppleMediaIndexRepository(fileURL: indexURL))
        controller = AppleConfigurationController(sources: sources, settings: settings, mediaIndex: index,
                                                  defaults: defaults, cloud: FakeCloudStore(),
                                                  backupKeys: OwnerBackupNoKey())
    }

    /// The `-OpenStreamDevSources` path: capture (which deletes the file it
    /// is given, so it gets a copy), then import into these stores.
    func importDevSources(from url: URL) async throws {
        let copy = FileManager.default.temporaryDirectory.appending(path: "dev-sources-copy-\(UUID()).json")
        try FileManager.default.copyItem(at: url, to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }
        defaults.set(copy.path, forKey: AppleDevSourcesPolicy.launchKey)
        AppleDevSourcesImport.captureIfRequested(defaults: defaults)
        defaults.removeObject(forKey: AppleDevSourcesPolicy.launchKey)
        try #require(AppleDevSourcesImport.isPending)
        await AppleDevSourcesImport.importPendingIfNeeded(sourceStore: sources, settings: settings)
    }

    func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: indexURL)
    }
}

private struct OwnerBackupNoKey: AppleBackupKeyStoring {
    func existingKey() throws -> SymmetricKey? { nil }
    func exportKey() throws -> SymmetricKey { throw AppleConfigurationError.backupKeyUnavailable }
}

private final class OwnerBackupCredentials: AppleCredentialStoring {
    private var values: [String: String] = [:]
    func string(for account: String) throws -> String? { values[account] }
    func set(_ value: String, for account: String) throws { values[account] = value }
    func remove(_ account: String) throws { values.removeValue(forKey: account) }
}
#endif
