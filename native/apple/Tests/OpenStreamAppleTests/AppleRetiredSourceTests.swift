import CryptoKit
import Foundation
import Testing
@testable import OpenStreamApple

/// Sources of a kind this app no longer has (saved by builds before
/// 2026-10-22) are deleted wherever they turn up — this device's list, a backup, an iCloud copy, a setup transfer —
/// with their Keychain entries and a tombstone, and the other sources stay as they were.
@MainActor
@Suite struct AppleRetiredSourceTests {
    private static let retiredID = UUID()
    private static let retired: [String: Any] = [
        "id": retiredID.uuidString, "kind": "retired-kind", "manifestID": "org.fixture.old", "name": "Old Source",
        "url": "https://fixture.example/old/source.json", "isEnabled": true,
        "credentialReference": "old-account", "transportReference": "old-transport",
        "resources": ["catalog", "stream"], "catalogs": [["type": "movie", "id": "top"]],
    ]

    @Test func loadingTheSavedListDeletesARetiredSourceAndItsKeychainEntries() throws {
        let device = try RetiredSourceDevice()
        defer { device.tearDown() }
        let reference = Self.retiredID.uuidString.lowercased()
        for account in ["old-account", "old-transport", "transport.\(reference)", "guide.\(reference)"] {
            try device.keychain.set("fixture-secret", for: account)
        }
        let kept = try device.keepSource()
        device.defaults.set(try device.storedList(adding: Self.retired), forKey: device.storageKey)

        let store = device.makeStore()

        #expect(store.sources.map(\.id) == [kept.id])
        #expect(store.credentialError == nil)
        let stored = try #require(device.defaults.data(forKey: device.storageKey))
        #expect(!String(decoding: stored, as: UTF8.self).contains(Self.retiredID.uuidString))
        for account in ["old-account", "old-transport", "transport.\(reference)", "guide.\(reference)"] {
            #expect(try device.keychain.string(for: account) == nil)
        }
        #expect(device.defaults.stringArray(forKey: device.storageKey + ".pending-keychain-removals") == nil)
        #expect(device.makeStore().sourceTombstones[Self.retiredID] != nil)
    }

    /// Only the kinds older builds had are retired; a kind a later build adds
    /// is left alone rather than deleted from every device.
    @Test func onlyTheOldKindsAreRetired() {
        let id = UUID().uuidString
        #expect(AppleRetiredSource(fields: ["id": id, "kind": "youtube"]) != nil)
        #expect(AppleRetiredSource(fields: ["id": id, "kind": "retired-kind", "manifestID": "org.fixture.old"]) != nil)
        #expect(AppleRetiredSource(fields: ["id": id, "kind": "laterKind"]) == nil)
        #expect(AppleRetiredSource(fields: ["id": id, "kind": AppleSourceKind.nas.rawValue, "manifestID": "x"]) == nil)
    }

    /// A list whose other source still needs its inline sign-in moved to the
    /// Keychain is saved without the retired source on the same launch.
    @Test func aRetiredSourceIsDroppedOnTheLaunchThatMovesInlineCredentials() throws {
        let device = try RetiredSourceDevice()
        defer { device.tearDown() }
        let kept = try device.keepSource()
        let data = try #require(device.defaults.data(forKey: device.storageKey))
        let stored = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        var legacy = try #require(stored.first)
        legacy["iptvType"] = AppleIPTVSourceType.xtream.rawValue
        legacy["username"] = "fixture-user"
        legacy["password"] = "fixture-password"
        legacy["credentialReference"] = nil
        device.defaults.set(try JSONSerialization.data(withJSONObject: [legacy, Self.retired]), forKey: device.storageKey)

        let store = device.makeStore()

        #expect(store.sources.map(\.id) == [kept.id])
        let saved = String(decoding: try #require(device.defaults.data(forKey: device.storageKey)), as: UTF8.self)
        #expect(!saved.contains(Self.retiredID.uuidString))
        #expect(!saved.contains("fixture-password"))
    }

    /// An older build still lists the source as its own; the copy this
    /// device sends carries the tombstone, which that build applies by
    /// deleting it, so the two never send it back and forth.
    @Test func theNextCopySentCarriesTheRetiredSourcesTombstone() throws {
        let device = try RetiredSourceDevice()
        defer { device.tearDown() }
        device.defaults.set(try JSONSerialization.data(withJSONObject: [Self.retired]), forKey: device.storageKey)
        let store = device.makeStore()

        let sent = AppleConfigurationSnapshot(sources: store.sources, sourceTombstones: store.sourceTombstones)
        let received = try JSONDecoder().decode(AppleConfigurationSnapshot.self, from: JSONEncoder().encode(sent))

        #expect(received.sourceTombstones.keys.contains(Self.retiredID))
    }

    @Test func theOldShelfAndChartCachesAreDeletedAndTheCurrentChartIsKept() throws {
        let caches = try #require(FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first)
        let folder = caches.appending(path: "OpenStream", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let old = ["catalogs-v2.json", "top10-artwork-v1.json", "netflix-top10-v1.json"].map { folder.appending(path: $0) }
        let current = folder.appending(path: AppleTop10Store.fileName)
        let hadCurrent = FileManager.default.fileExists(atPath: current.path)
        for file in old + (hadCurrent ? [] : [current]) { try Data("{}".utf8).write(to: file) }
        defer { if !hadCurrent { try? FileManager.default.removeItem(at: current) } }

        AppleRetiredSource.removeLeftoverFiles()

        #expect(old.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(FileManager.default.fileExists(atPath: current.path))
    }

    @Test func aSnapshotDropsRetiredSourcesAndKeepsTheRest() throws {
        let kept = AppleSource(kind: .liveTV, name: "Live", url: try #require(URL(string: "https://fixture.example/live.m3u")))
        let data = try Self.snapshotJSON(AppleConfigurationSnapshot(sources: [kept]), adding: Self.retired)

        let snapshot = try JSONDecoder().decode(AppleConfigurationSnapshot.self, from: data)

        #expect(snapshot.sources.map(\.id) == [kept.id])
        #expect(snapshot.retiredSourceCount == 1)
        #expect(snapshot.sourceTombstones[Self.retiredID] == snapshot.savedAt)
        #expect(throws: Never.self) { try snapshot.validate() }
        let reencoded = try JSONDecoder().decode(AppleConfigurationSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(reencoded.sources.map(\.id) == [kept.id])
        #expect(reencoded.retiredSourceCount == 0)
    }

    @Test func aBrokenSourceOfAKnownKindStillFailsTheFile() throws {
        var broken = Self.retired
        broken["kind"] = AppleSourceKind.liveTV.rawValue
        broken["url"] = 7
        let data = try Self.snapshotJSON(AppleConfigurationSnapshot(), adding: broken)

        #expect(throws: AppleConfigurationError.invalidFile) {
            try JSONDecoder().decode(AppleConfigurationSnapshot.self, from: data)
        }
    }

    @Test func aBackupFileWithRetiredSourcesRestoresTheRest() async throws {
        let kept = AppleSource(kind: .liveTV, name: "Live", url: try #require(URL(string: "https://fixture.example/live.m3u")))
        let file = try AppleConfigurationFile.encode(snapshot: AppleConfigurationSnapshot(sources: [kept]))
        var object = try #require(JSONSerialization.jsonObject(with: file) as? [String: Any])
        var snapshot = try #require(object["snapshot"] as? [String: Any])
        snapshot["sources"] = (snapshot["sources"] as? [Any] ?? []) + [Self.retired]
        object["snapshot"] = snapshot
        let backup = try JSONSerialization.data(withJSONObject: object)
        let device = try RetiredSourceDevice()
        defer { device.tearDown() }

        #expect(try device.controller.inspectBackup(backup).snapshot?.sources.map(\.id) == [kept.id])
        try await device.controller.restore(backup, passphrase: "")

        #expect(device.sources.sources.map(\.id) == [kept.id])
        #expect(device.controller.status.lastError == nil)
    }

    @Test func anICloudCopyWithRetiredSourcesFillsThisDeviceWithoutThem() async throws {
        let kept = AppleSource(kind: .liveTV, name: "Live", url: try #require(URL(string: "https://fixture.example/live.m3u")))
        let device = try RetiredSourceDevice()
        defer { device.tearDown() }
        device.cloud.set(try Self.snapshotJSON(AppleConfigurationSnapshot(savedAt: .now, sources: [kept]), adding: Self.retired),
                         forKey: "openstream.configuration.v1")

        await device.controller.start()
        await device.controller.restoreFromCloud()

        #expect(device.sources.sources.map(\.id) == [kept.id])
        #expect(device.sources.sourceTombstones[Self.retiredID] != nil)
        #expect(device.controller.status.lastError == nil)
    }

    @Test func aSetupTransferWithRetiredSourcesImportsTheRest() async throws {
        let kept = AppleSource(kind: .liveTV, name: "Live", url: try #require(URL(string: "https://fixture.example/live.m3u")))
        let payload = AppleSetupTransferPayload(sender: "Fixture iPhone", snapshot: AppleConfigurationSnapshot(sources: [kept]),
                                                secrets: AppleConfigurationSecrets())
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
        var snapshot = try #require(object["snapshot"] as? [String: Any])
        snapshot["sources"] = (snapshot["sources"] as? [Any] ?? []) + [Self.retired]
        object["snapshot"] = snapshot
        let received = try JSONDecoder().decode(AppleSetupTransferPayload.self,
                                                from: JSONSerialization.data(withJSONObject: object))
        let device = try RetiredSourceDevice()
        defer { device.tearDown() }

        #expect(try await device.controller.importSetupTransfer(received) == 1)
        #expect(device.sources.sources.map(\.id) == [kept.id])
    }

    private static func snapshotJSON(_ snapshot: AppleConfigurationSnapshot, adding member: [String: Any]) throws -> Data {
        var object = try #require(JSONSerialization.jsonObject(with: AppleConfigurationSnapshot.encoder.encode(snapshot))
            as? [String: Any])
        object["sources"] = (object["sources"] as? [Any] ?? []) + [member]
        return try JSONSerialization.data(withJSONObject: object)
    }
}

/// One device's stores on throwaway defaults, keychain, cloud and index file.
@MainActor
private struct RetiredSourceDevice {
    let suite = "retired-source.\(UUID())"
    let storageKey = "openstream.sources.v1"
    let defaults: UserDefaults
    let keychain = RetiredSourceCredentials()
    let cloud = FakeCloudStore()
    let indexURL = FileManager.default.temporaryDirectory.appending(path: "retired-index-\(UUID()).json")
    let sources: AppleSourceStore
    let controller: AppleConfigurationController

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
        sources = AppleSourceStore(defaults: defaults, storageKey: storageKey, keychain: keychain)
        controller = AppleConfigurationController(
            sources: sources, settings: AppleSettingsStore(defaults: defaults, keychain: RetiredSourceCredentials()),
            mediaIndex: AppleMediaIndexStore(repository: AppleMediaIndexRepository(fileURL: indexURL)),
            defaults: defaults, cloud: cloud, backupKeys: RetiredSourceBackupKeys())
    }

    func makeStore() -> AppleSourceStore {
        AppleSourceStore(defaults: defaults, storageKey: storageKey, keychain: keychain)
    }

    /// A playlist source saved through the store, so its stored shape is real.
    func keepSource() throws -> AppleSource {
        try sources.addIPTV(name: "Live", type: .m3u, endpoint: "https://fixture.example/live.m3u")
    }

    func storedList(adding member: [String: Any]) throws -> Data {
        let stored = try #require(defaults.data(forKey: storageKey))
        let members = try #require(JSONSerialization.jsonObject(with: stored) as? [Any])
        return try JSONSerialization.data(withJSONObject: members + [member])
    }

    func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: indexURL)
    }
}

private final class RetiredSourceCredentials: AppleCredentialStoring {
    private var values: [String: String] = [:]
    func string(for account: String) throws -> String? { values[account] }
    func set(_ value: String, for account: String) throws { values[account] = value }
    func remove(_ account: String) throws { values.removeValue(forKey: account) }
}

private final class RetiredSourceBackupKeys: AppleBackupKeyStoring, @unchecked Sendable {
    func existingKey() throws -> SymmetricKey? { nil }
    func exportKey() throws -> SymmetricKey { throw AppleConfigurationError.backupKeyUnavailable }
}
