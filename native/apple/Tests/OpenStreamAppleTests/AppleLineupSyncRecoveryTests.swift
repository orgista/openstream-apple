import Foundation
import Testing
@testable import OpenStreamApple

@MainActor
@Suite("Lineup sync recovery")
struct AppleLineupSyncRecoveryTests {
    private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    @Test(arguments: [0.0, 60.0])
    func missingLineupArrivesEvenWhenConfigurationIsNotNewer(localOffset: TimeInterval) async throws {
        let device = try Device()
        defer { device.remove() }
        let data = try JSONEncoder().encode(fixtureLineup())
        let snapshot = AppleConfigurationSnapshot(savedAt: epoch, sources: device.sources.sources, lineup: data)
        device.cloud.set(try snapshot.cloudData(), forKey: Device.cloudKey)
        device.defaults.set(epoch.addingTimeInterval(localOffset), forKey: Device.savedAtKey)
        await device.controller.start()
        #expect(device.lineup.current == (try fixtureLineup()))
        #expect(device.defaults.object(forKey: Device.savedAtKey) as? Date == epoch.addingTimeInterval(localOffset))
    }

    @Test func failedImportRetriesTheSameSnapshotAfterStorageRecovers() async throws {
        let device = try Device()
        defer { device.remove() }
        try Data("blocked".utf8).write(to: device.lineupDirectory)
        device.cloud.set(try AppleConfigurationSnapshot(savedAt: epoch, sources: device.sources.sources,
            lineup: JSONEncoder().encode(fixtureLineup())).cloudData(), forKey: Device.cloudKey)
        await device.controller.start()
        #expect(device.lineup.current == nil)
        #expect(device.controller.status.lastReceivedAt != nil)
        try FileManager.default.removeItem(at: device.lineupDirectory)
        await device.controller.readCloud()
        #expect(device.lineup.current == (try fixtureLineup()))
    }

    @Test func aPurgedCacheIsRecreatedOnAnEqualSnapshotRead() async throws {
        let device = try Device()
        defer { device.remove() }
        device.cloud.set(try AppleConfigurationSnapshot(savedAt: epoch, sources: device.sources.sources,
            lineup: JSONEncoder().encode(fixtureLineup())).cloudData(), forKey: Device.cloudKey)
        await device.controller.start()
        try FileManager.default.removeItem(at: device.lineupDirectory)
        await device.controller.readCloud()
        #expect(AppleChannelLineupStore(directory: device.lineupDirectory).current == (try fixtureLineup()))
    }

    @Test func lineupRevisionIsIndependentOfNewerSettings() async throws {
        let device = try Device()
        defer { device.remove() }
        try device.lineup.importData(replacement(), updatedAt: epoch.addingTimeInterval(-60))
        device.defaults.set(epoch.addingTimeInterval(60), forKey: Device.savedAtKey)
        var remoteSource = try #require(device.sources.sources.first)
        remoteSource.name = "Remote name"
        device.cloud.set(try AppleConfigurationSnapshot(savedAt: epoch, sources: [remoteSource],
            lineup: JSONEncoder().encode(fixtureLineup()), lineupUpdatedAt: epoch).cloudData(), forKey: Device.cloudKey)
        await device.controller.start()
        #expect(device.lineup.current == (try fixtureLineup()))
        #expect(device.sources.sources.first?.name == "Fixture")
        #expect(device.defaults.object(forKey: Device.savedAtKey) as? Date == epoch.addingTimeInterval(60))
    }

    @Test func aNewerSetupCannotReplaceANewerLineupWithItsStaleCopy() async throws {
        let device = try Device()
        defer { device.remove() }
        let data = try replacement()
        let revision = epoch.addingTimeInterval(10)
        try device.lineup.importData(data, updatedAt: revision)
        device.cloud.set(try AppleConfigurationSnapshot(savedAt: epoch.addingTimeInterval(60), sources: device.sources.sources,
            lineup: JSONEncoder().encode(fixtureLineup()), lineupUpdatedAt: epoch).cloudData(), forKey: Device.cloudKey)
        await device.controller.start()
        await device.controller.syncNow()
        let received = try JSONDecoder().decode(AppleConfigurationSnapshot.self,
            from: #require(device.cloud.data(forKey: Device.cloudKey)))
        #expect(device.lineup.current == (try AppleChannelLineupFile.decode(data)))
        #expect(try received.lineup.map(AppleChannelLineupFile.decode) == device.lineup.current)
        #expect(received.lineupUpdatedAt == revision)
    }

    @Test func anImportPublishesAndArrivesAtBothStoragePaths() async throws {
        let phone = try Device()
        defer { phone.remove() }
        phone.cloud.set(try AppleConfigurationSnapshot(savedAt: epoch, sources: phone.sources.sources).cloudData(),
            forKey: Device.cloudKey)
        await phone.controller.start()
        let lineup = phone.lineup
        try await confirmation("Import notifies configuration sync") { changed in
            let observer = NotificationCenter.default.addObserver(forName: AppleChannelLineupStore.didChange,
                object: nil, queue: nil) { notification in
                if let store = notification.object as? AppleChannelLineupStore, store === lineup { changed() }
            }
            defer { NotificationCenter.default.removeObserver(observer) }
            try lineup.importData(JSONEncoder().encode(fixtureLineup()))
            await phone.controller.localChanged()?.value
        }
        await phone.controller.syncNow()
        let published = try JSONDecoder().decode(AppleConfigurationSnapshot.self,
            from: #require(phone.cloud.data(forKey: Device.cloudKey)))
        #expect(published.lineupUpdatedAt != nil)
        #expect(published.savedAt > epoch)
        for path in ["Library/Caches/Lineups", "Library/Application Support/Lineups"] {
            let receiver = try Device(cloud: phone.cloud, path: path)
            defer { receiver.remove() }
            await receiver.controller.start()
            #expect(receiver.lineup.current == phone.lineup.current)
            #expect(AppleChannelLineupStore(directory: receiver.lineupDirectory).current == phone.lineup.current)
        }
    }

    @Test func mergingUsesTheLineupClockInsteadOfTheSetupClock() throws {
        let old = AppleConfigurationSnapshot(savedAt: epoch.addingTimeInterval(60),
            lineup: try JSONEncoder().encode(fixtureLineup()), lineupUpdatedAt: epoch)
        let newer = AppleConfigurationSnapshot(savedAt: epoch,
            lineup: try replacement(), lineupUpdatedAt: epoch.addingTimeInterval(10))
        #expect(old.merging(newer).lineup == newer.lineup)
        #expect(newer.merging(old).lineup == newer.lineup)
        #expect(newer.merging(old).lineupUpdatedAt == newer.lineupUpdatedAt)
    }

    @Test func lineupRevisionSurvivesRelaunchAndAClockBehindTheLastImport() throws {
        let device = try Device()
        defer { device.remove() }
        try device.lineup.importData(JSONEncoder().encode(fixtureLineup()), updatedAt: epoch)
        let reopened = AppleChannelLineupStore(directory: device.lineupDirectory)
        #expect(reopened.configuration.updatedAt == epoch)
        try reopened.importData(replacement())
        #expect(try #require(reopened.configuration.updatedAt) > epoch)
    }

    @Test func identicalLineupLearnsANewerRevisionBeforeRejectingAStaleReplacement() throws {
        let device = try Device()
        defer { device.remove() }
        let original = try JSONEncoder().encode(fixtureLineup())
        let latest = epoch.addingTimeInterval(60)
        try device.lineup.importData(original, updatedAt: epoch)
        try device.lineup.importData(original, updatedAt: latest)
        try device.lineup.importData(replacement(), updatedAt: epoch.addingTimeInterval(30))
        #expect(device.lineup.current == (try fixtureLineup()))
        #expect(device.lineup.configuration.updatedAt == latest)
        #expect(AppleChannelLineupStore(directory: device.lineupDirectory).configuration.updatedAt == latest)
    }

    @Test func explicitlyReimportingTheSameLineupPublishesANewRevision() async throws {
        let device = try Device()
        defer { device.remove() }
        let data = try JSONEncoder().encode(fixtureLineup())
        device.cloud.set(try AppleConfigurationSnapshot(savedAt: epoch, sources: device.sources.sources,
            lineup: data, lineupUpdatedAt: epoch).cloudData(), forKey: Device.cloudKey)
        await device.controller.start()
        try device.lineup.importData(data)
        await device.controller.localChanged()?.value
        await device.controller.syncNow()
        let published = try JSONDecoder().decode(AppleConfigurationSnapshot.self,
            from: #require(device.cloud.data(forKey: Device.cloudKey)))
        #expect(try #require(published.lineupUpdatedAt) > epoch)
        #expect(device.controller.status.lastSentAt != nil)
        let sentAt = device.controller.status.lastSentAt
        await device.controller.syncNow()
        #expect(device.controller.status.lastSentAt == sentAt)
    }

    @Test func localImportBeatsAnUnappliedFutureCloudRevision() async throws {
        let device = try Device()
        defer { device.remove() }
        let future = Date.now.addingTimeInterval(86_400)
        device.cloud.set(try AppleConfigurationSnapshot(savedAt: future, sources: device.sources.sources,
            lineup: JSONEncoder().encode(fixtureLineup()), lineupUpdatedAt: future).cloudData(), forKey: Device.cloudKey)
        let imported = try replacement()
        try device.lineup.importData(imported)
        #expect(try #require(device.lineup.configuration.updatedAt) > future)
        await device.controller.start()
        await device.controller.syncNow()
        #expect(device.lineup.current == (try AppleChannelLineupFile.decode(imported)))
        let published = try JSONDecoder().decode(AppleConfigurationSnapshot.self,
            from: #require(device.cloud.data(forKey: Device.cloudKey)))
        #expect(try published.lineup.map(AppleChannelLineupFile.decode) == device.lineup.current)
    }

    @Test func modificationDateFailureKeepsDiskAndMemoryOnTheImportedLineup() throws {
        let device = try Device()
        defer { device.remove() }
        let store = AppleChannelLineupStore(directory: device.lineupDirectory,
            setModificationDate: { _, _ in throw CocoaError(.fileWriteNoPermission) })
        let imported = try replacement()
        try store.importData(imported, updatedAt: epoch)
        #expect(store.current == (try AppleChannelLineupFile.decode(imported)))
        #expect(AppleChannelLineupStore(directory: device.lineupDirectory).current == store.current)
        #expect(store.configuration.updatedAt == epoch)
    }

    @Test func legacyJSONFormattingDoesNotRepublishOrPingPong() async throws {
        let device = try Device()
        defer { device.remove() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let legacy = try encoder.encode(fixtureLineup())
        try device.lineup.importData(legacy, updatedAt: epoch.addingTimeInterval(60))
        try #require(device.lineup.data != legacy)
        var local = AppleConfigurationSnapshot(savedAt: epoch.addingTimeInterval(120), sources: device.sources.sources,
            lineup: device.lineup.data, lineupUpdatedAt: device.lineup.configuration.updatedAt)
        let cloud = AppleConfigurationSnapshot(savedAt: epoch, sources: device.sources.sources, lineup: legacy)
        #expect(!AppleConfigurationSyncPolicy.lineupContribution(local, cloud: cloud))
        #expect(!AppleConfigurationSyncPolicy.contentDiffers(local, cloud))
        #expect(!AppleConfigurationSyncPolicy.publishesWithoutEdit(syncEnabled: true, restoreHeld: false,
            local: local, localSavedAt: local.savedAt, cloud: cloud))
        local = cloud.merging(local)
        #expect(local.lineupUpdatedAt == epoch.addingTimeInterval(60))
        let encoded = try cloud.cloudData()
        device.cloud.set(encoded, forKey: Device.cloudKey)
        device.defaults.set(epoch.addingTimeInterval(120), forKey: Device.savedAtKey)
        await device.controller.start()
        for _ in 0..<3 {
            await device.controller.syncNow()
            await device.controller.localChanged()?.value
        }
        #expect(device.cloud.data(forKey: Device.cloudKey) == encoded)
        #expect(device.controller.status.lastSentAt == nil)
    }

    @Test(arguments: [0.0, 60.0])
    func resetHoldBlocksLineupRecoveryUntilExplicitRestore(localOffset: TimeInterval) async throws {
        let device = try Device()
        defer { device.remove() }
        let encoded = try AppleConfigurationSnapshot(savedAt: epoch, sources: device.sources.sources,
            lineup: JSONEncoder().encode(fixtureLineup()), lineupUpdatedAt: epoch).cloudData()
        device.cloud.set(encoded, forKey: Device.cloudKey)
        device.defaults.set(epoch.addingTimeInterval(localOffset), forKey: Device.savedAtKey)
        device.defaults.set(true, forKey: AppleDeviceReset.cloudRestoreHeldKey)
        await device.controller.start()
        await device.controller.readCloud()
        await device.controller.syncNow()
        #expect(device.lineup.current == nil)
        #expect(!FileManager.default.fileExists(atPath: device.lineupDirectory.path))
        #expect(device.cloud.data(forKey: Device.cloudKey) == encoded)
        await device.controller.restoreFromCloud()
        #expect(device.lineup.current == (try fixtureLineup()))
        device.defaults.set(true, forKey: AppleDeviceReset.cloudRestoreHeldKey)
        try FileManager.default.removeItem(at: device.lineupDirectory)
        device.lineup.discardAfterReset()
        await device.controller.readCloud()
        await device.controller.becameActive()
        await device.controller.syncNow()
        #expect(device.lineup.current == nil)
        #expect(!FileManager.default.fileExists(atPath: device.lineupDirectory.path))
    }

    @Test func resetHoldAlsoProtectsTheSharedLineupRestoreHelper() async throws {
        let device = try Device()
        defer { device.remove() }
        device.defaults.set(true, forKey: AppleDeviceReset.cloudRestoreHeldKey)
        let snapshot = AppleConfigurationSnapshot(savedAt: epoch, sources: device.sources.sources,
            lineup: try JSONEncoder().encode(fixtureLineup()))
        try await device.controller.importSetupTransfer(.init(sender: "Fixture phone", snapshot: snapshot, secrets: .init()))
        #expect(device.lineup.current == nil)
        #expect(!FileManager.default.fileExists(atPath: device.lineupDirectory.path))
        #expect(device.defaults.bool(forKey: AppleDeviceReset.cloudRestoreHeldKey))
    }

    @Test func maximumLineupBase64AndRemainingSnapshotFitCloudBudget() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var object = try #require(JSONSerialization.jsonObject(with: encoder.encode(fixtureLineup())) as? [String: Any])
        object["name"] = ""
        let overhead = try JSONSerialization.data(withJSONObject: object, options: .sortedKeys).count
        object["name"] = String(repeating: "L", count: AppleChannelLineupFile.maximumBytes - overhead)
        let maximum = try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
        try #require(maximum.count == AppleChannelLineupFile.maximumBytes)
        let device = try Device()
        defer { device.remove() }
        try device.lineup.importData(maximum, updatedAt: epoch)
        try #require(device.lineup.data == maximum)
        let progress = Dictionary(uniqueKeysWithValues: (0..<30).map {
            ("movie|tt\($0)", ApplePlaybackProgress(position: 60, duration: 120, updatedAt: epoch))
        })
        let snapshot = AppleConfigurationSnapshot(savedAt: epoch,
            sources: [AppleSource(kind: .library, name: "Fixture", url: URL(fileURLWithPath: "/fixture"))],
            settings: ["fixture.bulk": Data(repeating: 65, count: 500_000)], playbackProgress: progress,
            ratings: ["tt1": 1], lineup: maximum, lineupUpdatedAt: epoch)
        let encoded = try snapshot.cloudData()
        let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let base64 = try #require(json["lineup"] as? String)
        #expect(base64.utf8.count == 4 * ((maximum.count + 2) / 3))
        #expect(encoded.count < AppleConfigurationSnapshot.maximumCloudBytes)
        let restored = try JSONDecoder().decode(AppleConfigurationSnapshot.self, from: encoded)
        #expect(restored.lineup == maximum)
        #expect(restored.settings == snapshot.settings)
        #expect(restored.sources == snapshot.sources)
        #expect(restored.playbackProgress == progress)
        #expect(restored.ratings == snapshot.ratings)
        #expect(restored.lineupUpdatedAt == epoch)
        print("Maximum lineup: \(maximum.count) bytes; base64: \(base64.utf8.count); full cloud snapshot: \(encoded.count)/\(AppleConfigurationSnapshot.maximumCloudBytes)")
    }

    private func replacement() throws -> Data {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(fixtureLineup())) as? [String: Any])
        object["name"] = "Replacement"
        return try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
    }

    @MainActor private struct Device {
        static let cloudKey = "openstream.configuration.v1"
        static let savedAtKey = "openstream.backup.savedAt.v1"
        let suite = "lineup-recovery.\(UUID())"
        let root: URL
        let lineupDirectory: URL
        let defaults: UserDefaults
        let lineup: AppleChannelLineupStore
        let cloud: FakeCloudStore
        let sources: AppleSourceStore
        let controller: AppleConfigurationController

        init(cloud: FakeCloudStore = FakeCloudStore(), path: String = "Lineups") throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            lineupDirectory = root.appendingPathComponent(path)
            defaults = try #require(UserDefaults(suiteName: suite))
            self.cloud = cloud
            lineup = AppleChannelLineupStore(directory: lineupDirectory, latestCloudRevision: {
                guard let data = cloud.data(forKey: "openstream.configuration.v1"),
                      let snapshot = try? JSONDecoder().decode(AppleConfigurationSnapshot.self, from: data),
                      snapshot.lineup != nil else { return nil }
                return snapshot.lineupUpdatedAt ?? snapshot.savedAt
            })
            let credentials = LineupRecoveryCredentials()
            sources = AppleSourceStore(defaults: defaults, keychain: credentials, documentsDirectory: root)
            try sources.restoreConfigurationSources([
                AppleSource(kind: .library, name: "Fixture", url: URL(fileURLWithPath: "/fixture")),
            ], secrets: nil)
            controller = AppleConfigurationController(sources: sources,
                settings: AppleSettingsStore(defaults: defaults, keychain: credentials, lineupStore: lineup),
                mediaIndex: AppleMediaIndexStore(repository: AppleMediaIndexRepository(fileURL: root.appendingPathComponent("index.json"))),
                defaults: defaults, cloud: cloud, lineupStore: lineup)
        }

        func remove() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }
}

private final class LineupRecoveryCredentials: AppleCredentialStoring {
    private var values: [String: String] = [:]
    func string(for account: String) throws -> String? { values[account] }
    func set(_ value: String, for account: String) throws { values[account] = value }
    func remove(_ account: String) throws { values.removeValue(forKey: account) }
}
