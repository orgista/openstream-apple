import Foundation
import Testing
@testable import OpenStreamApple

func fixtureLineup() throws -> AppleChannelLineupFile {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/test-lineup.oslineup")
    return try AppleChannelLineupFile.decode(Data(contentsOf: url))
}

struct AppleChannelLineupStoreTests {
    @Test func importPersistsAndInvalidReplacementKeepsPreviousFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppleChannelLineupStore(directory: directory)
        #expect(store.current == nil)
        let data = try JSONEncoder().encode(fixtureLineup())
        try store.importData(data)
        #expect(AppleChannelLineupStore(directory: directory).current == store.current)
        #expect(throws: AppleChannelLineupError.invalidFile) { try store.importData(Data("{}".utf8)) }
        #expect(AppleChannelLineupStore(directory: directory).current == store.current)
    }

    @Test func resetDiscardsTheLineupAlreadyRemovedFromDisk() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try fixtureLineupStore(directory: directory)
        let report = AppleDeviceReset.wipe(directories: [directory])
        #expect(report.failedItems == 0)
        store.discardAfterReset()
        #expect(store.current == nil)
        #expect(store.data == nil)
        #expect(AppleChannelLineupStore(directory: directory).current == nil)
        try store.importData(JSONEncoder().encode(fixtureLineup()))
        #expect(store.current == (try fixtureLineup()))
        #expect(AppleChannelLineupStore(directory: directory).current == store.current)
    }

    @Test func productionResetListIncludesBothLineupStorageLocations() {
        let directories = AppleDeviceReset.containerDirectories(.default)
        let fallback = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenStream/Library/Application Support/Lineups", isDirectory: true)
        #expect(directories.contains(AppleChannelLineupStore.defaultDirectory))
        #expect(directories.contains(fallback))
    }

    @Test func identicalImportRecreatesAMissingDiskCopy() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try fixtureLineupStore(directory: directory)
        let data = try #require(store.data)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("current.oslineup"))
        try store.importData(data)
        #expect(AppleChannelLineupStore(directory: directory).current == store.current)
    }

    @Test func legacyHeaderIsAcceptedAndNewVersionsGiveActionableError() throws {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(fixtureLineup())) as? [String: Any])
        object.removeValue(forKey: "format")
        object.removeValue(forKey: "version")
        #expect(try AppleChannelLineupFile.decode(JSONSerialization.data(withJSONObject: object)).version == 1)
        object["version"] = 2
        object["futureOption"] = true
        #expect(throws: AppleChannelLineupError.unsupportedVersion) {
            try AppleChannelLineupFile.decode(JSONSerialization.data(withJSONObject: object))
        }
    }

    @Test func sizeLimitAndStreamOrConfigurationFieldsAreRejected() throws {
        #expect(throws: AppleChannelLineupError.tooLarge) {
            try AppleChannelLineupFile.decode(Data(repeating: 32, count: AppleChannelLineupFile.maximumBytes + 1))
        }
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(fixtureLineup())) as? [String: Any])
        object["settings"] = ["feature": true]
        #expect(throws: AppleChannelLineupError.invalidFile) {
            try AppleChannelLineupFile.decode(JSONSerialization.data(withJSONObject: object))
        }
        object.removeValue(forKey: "settings")
        var channels = try #require(object["channels"] as? [[String: Any]])
        channels[0]["url"] = "https://fixture.example/live"
        object["channels"] = channels
        #expect(throws: AppleChannelLineupError.invalidFile) {
            try AppleChannelLineupFile.decode(JSONSerialization.data(withJSONObject: object))
        }
    }

    @Test func noLineupKeepsPlaylistNumbersAndGroups() throws {
        var channel = AppleIPTVChannel(id: "fixture", sourceID: UUID(), name: "ESPN", group: "Fixture Group",
            streamURL: try #require(URL(string: "https://fixture.example/live")))
        channel.channelNumber = 77
        #expect(AppleLiveChannelPackage.available(entries: []) == [.everything, .custom])
        #expect(AppleLiveChannelPackage.defaultPackage(for: [channel], entries: []) == .everything)
        #expect(AppleGuideChannelProjection.rows(channels: [channel], entries: [], favoriteIDs: [],
            favoritesOnly: false, sortByNumber: true).first?.number == 77)
        #expect(AppleLiveChannelSnapshot.build(groups: [.init(name: "Fixture Group", channels: [channel])],
            package: .everything, custom: .init(), entries: [], favoriteIDs: [], category: "All").categories.contains("Fixture Group"))
    }

    @Test func importedCategoriesAreNotLimitedToTheOldPreset() throws {
        let channel = AppleIPTVChannel(id: "fixture", sourceID: UUID(), name: "Fixture Channel", group: "Provider Group",
            streamURL: try #require(URL(string: "https://fixture.example/live")))
        let entries = [AppleChannelLineupEntry(number: 77, name: channel.name, aliases: [], category: "Documentaries")]
        let snapshot = AppleLiveChannelSnapshot.build(groups: [.init(name: channel.group, channels: [channel])],
            package: .everything, custom: .init(), entries: entries, favoriteIDs: [], category: "Documentaries")
        #expect(snapshot.categories.contains("Documentaries"))
        #expect(snapshot.channels == [channel])
    }

    @MainActor @Test func aSavedCompleteGuideChoiceWaitsForAnImportedLineup() throws {
        let suite = "lineup-package.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        defaults.set("completeGuide", forKey: "openstream.settings.live.package.v1")
        let lineup = AppleChannelLineupStore(directory: directory)
        let settings = AppleSettingsStore(defaults: defaults, keychain: LineupTestCredentials(), lineupStore: lineup)
        #expect(settings.liveChannelPackage == .everything)
        try lineup.importData(JSONEncoder().encode(fixtureLineup()))
        #expect(settings.liveChannelPackage == .completeGuide)
        #expect(defaults.string(forKey: "openstream.settings.live.package.v1") == "completeGuide")
    }

    @Test func backupAndSealedSetupCarryLineupWithoutChangingOldSnapshots() throws {
        let data = try JSONEncoder().encode(fixtureLineup())
        let snapshot = AppleConfigurationSnapshot(lineup: data)
        let backup = try AppleConfigurationFile.encode(snapshot: snapshot)
        #expect(try AppleConfigurationFile.decode(backup).snapshot.lineup == data)
        let old = AppleConfigurationSnapshot()
        #expect(old.merging(snapshot).lineup == data)
        #expect(snapshot.merging(old).lineup == data)
        let payload = AppleSetupTransferPayload(sender: "Test", snapshot: snapshot, secrets: .init())
        var receiver = AppleSetupReceiveSession(now: .now)
        let link = receiver.link(host: "192.168.1.20", port: 8091)
        let sealed = try AppleSetupTransferCrypto.sealPayload(payload, for: link)
        let received = try receiver.accept(sessionID: link.sessionID, code: link.code, body: sealed, now: .now).get()
        #expect(received.snapshot.lineup == data)
        #expect(try JSONDecoder().decode(AppleConfigurationSnapshot.self, from: snapshot.cloudData()).lineup == data)
    }

    @Test func maximumSizeLineupFitsCloudAndSealedSetupWithOtherConfiguration() throws {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(fixtureLineup())) as? [String: Any])
        object["name"] = ""
        let overhead = try JSONSerialization.data(withJSONObject: object).count
        object["name"] = String(repeating: "L", count: AppleChannelLineupFile.maximumBytes - overhead)
        let data = try JSONSerialization.data(withJSONObject: object)
        try #require(data.count == AppleChannelLineupFile.maximumBytes)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppleChannelLineupStore(directory: directory)
        try store.importData(data)
        let stored = try #require(store.data)
        let snapshot = AppleConfigurationSnapshot(settings: ["fixture.bulk": Data(repeating: 65, count: 500_000)], lineup: stored)
        let cloud = try snapshot.cloudData()
        #expect(cloud.count <= AppleConfigurationSnapshot.maximumCloudBytes)
        #expect(try JSONDecoder().decode(AppleConfigurationSnapshot.self, from: cloud).lineup == stored)
        let payload = AppleSetupTransferPayload(sender: "Fixture phone", snapshot: snapshot, secrets: .init())
        var receiver = AppleSetupReceiveSession(now: .now)
        let link = receiver.link(host: "192.168.1.20", port: 8091)
        let sealed = try AppleSetupTransferCrypto.sealPayload(payload, for: link)
        #expect(sealed.count <= AppleSetupReceiveSession.maximumBodyBytes)
        #expect(try receiver.accept(sessionID: link.sessionID, code: link.code, body: sealed, now: .now).get().snapshot.lineup == stored)
        #expect(throws: AppleConfigurationError.tooLarge) {
            try AppleConfigurationSnapshot(settings: ["fixture.bulk": Data(repeating: 65, count: 800_000)], lineup: stored).cloudData()
        }
    }

    @Test(arguments: ["true", "1.5", "null", "\"1\""])
    func malformedVersionIsRejected(version: String) {
        let data = Data("{\"version\":\(version),\"channels\":[]}".utf8)
        #expect(throws: AppleChannelLineupError.invalidFile) { try AppleChannelLineupFile.decode(data) }
    }

    @Test func fileImportHonorsTheLimitAndKeepsTheCurrentLineup() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try fixtureLineupStore(directory: directory)
        let url = directory.appendingPathComponent("replacement.oslineup")
        try Data(repeating: 32, count: AppleChannelLineupFile.maximumBytes + 1).write(to: url)
        #expect(throws: AppleChannelLineupError.tooLarge) { try store.importFile(url) }
        #expect(store.current == (try fixtureLineup()))
        try JSONEncoder().encode(fixtureLineup()).write(to: url)
        try store.importFile(url)
        #expect(AppleChannelLineupStore(directory: directory).current == (try fixtureLineup()))
    }

    @Test func urlImportFetchesOnceAndRejectsFailuresWithoutReplacingTheLineup() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppleChannelLineupStore(directory: directory)
        let fixture = HealthHTTPFixture()
        let base = try await fixture.start()
        do {
            await fixture.route("/lineup", body: try JSONEncoder().encode(fixtureLineup()))
            try await store.importURL(base.appendingPathComponent("lineup"))
            #expect(store.current == (try fixtureLineup()))
            #expect(AppleChannelLineupStore(directory: directory).current == store.current)
            #expect(await fixture.hits("/lineup") == 1)
            await fixture.route("/failed", status: 503)
            await #expect(throws: AppleChannelLineupError.couldNotDownload) {
                try await store.importURL(base.appendingPathComponent("/failed"))
            }
            await fixture.route("/large", body: Data(repeating: 32, count: AppleChannelLineupFile.maximumBytes + 1))
            await #expect(throws: AppleChannelLineupError.tooLarge) {
                try await store.importURL(base.appendingPathComponent("/large"))
            }
            #expect(store.current == (try fixtureLineup()))
        } catch {
            await fixture.stop()
            throw error
        }
        await fixture.stop()
    }

    @Test func cancellingAURLImportDoesNotSaveIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppleChannelLineupStore(directory: directory)
        let fixture = HealthHTTPFixture()
        let base = try await fixture.start()
        await fixture.route("/lineup", body: try JSONEncoder().encode(fixtureLineup()))
        await fixture.holdResponses()
        let task = Task { try await store.importURL(base.appendingPathComponent("lineup")) }
        await fixture.waitForHit("/lineup")
        task.cancel()
        await fixture.releaseResponses()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(store.current == nil)
        await fixture.stop()
    }

    @MainActor @Test func cloudBackupAndSetupApplyToAnEmptyLineupStore() async throws {
        let suite = "lineup-sync.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let lineup = AppleChannelLineupStore(directory: directory.appendingPathComponent("Lineups"))
        let cloud = FakeCloudStore()
        let expectedLineup = try fixtureLineup()
        let source = AppleSource(kind: .liveTV, name: "Fixture", url: try #require(URL(string: "https://fixture.example/list.m3u")))
        let snapshot = AppleConfigurationSnapshot(sources: [source], lineup: try JSONEncoder().encode(expectedLineup))
        cloud.set(try snapshot.cloudData(), forKey: "openstream.configuration.v1")
        let credentials = LineupTestCredentials()
        let controller = AppleConfigurationController(
            sources: AppleSourceStore(defaults: defaults, keychain: credentials),
            settings: AppleSettingsStore(defaults: defaults, keychain: credentials, lineupStore: lineup),
            mediaIndex: AppleMediaIndexStore(repository: AppleMediaIndexRepository(fileURL: directory.appendingPathComponent("index.json"))),
            defaults: defaults, cloud: cloud, lineupStore: lineup)
        await controller.start()
        #expect(lineup.current == expectedLineup)
        let payload = try controller.setupTransferPayload(sender: "Fixture phone")
        #expect(try payload.snapshot.lineup.map(AppleChannelLineupFile.decode) == expectedLineup)
        let backup = try await controller.export(passphrase: "lineup-fixture-passphrase")
        let restored = try await AppleBackupEnvelope.header(of: backup)?.openData(key: nil, passphrase: "lineup-fixture-passphrase")
        #expect(try restored?.snapshot.lineup.map(AppleChannelLineupFile.decode) == expectedLineup)
        try await controller.importSetupTransfer(payload)
        #expect(AppleChannelLineupStore(directory: directory.appendingPathComponent("Lineups")).current == expectedLineup)
    }
}

func fixtureLineupStore(directory: URL) throws -> AppleChannelLineupStore {
    let store = AppleChannelLineupStore(directory: directory)
    try store.importData(JSONEncoder().encode(fixtureLineup()))
    return store
}

private final class LineupTestCredentials: AppleCredentialStoring {
    private var values: [String: String] = [:]
    func string(for account: String) throws -> String? { values[account] }
    func set(_ value: String, for account: String) throws { values[account] = value }
    func remove(_ account: String) throws { values.removeValue(forKey: account) }
}
