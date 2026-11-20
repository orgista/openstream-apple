import Foundation
import Testing
@testable import OpenStreamApple

@Suite("Configuration backup")
struct AppleConfigurationSnapshotTests {
    private func source(id: UUID = UUID(), name: String = "Fixture") -> AppleSource {
        AppleSource(id: id, kind: .liveTV, name: name,
                    url: URL(string: "https://fixture.example/playlist?token=fixture-secret")!,
                    credentialReference: "local-keychain-reference")
    }

    @Test func sourceDeletionsWinInEitherMergeDirectionAndSurviveRoundTrip() throws {
        let removed = source()
        let kept = source(name: "Kept")
        let stale = AppleConfigurationSnapshot(sources: [removed, kept])
        let deletion = AppleConfigurationSnapshot(sourceTombstones: [removed.id: Date(timeIntervalSince1970: 100)])
        for merged in [stale.merging(deletion), deletion.merging(stale)] {
            #expect(merged.sources.map(\.id) == [kept.id])
            #expect(merged.sourceTombstones[removed.id] != nil)
            let restored = try JSONDecoder().decode(AppleConfigurationSnapshot.self, from: merged.cloudData())
            #expect(restored.sourceTombstones == merged.sourceTombstones)
            #expect(restored.merging(stale).sources.map(\.id) == [kept.id])
        }
    }

    @MainActor @Test func deletedSourceCannotReturnFromBackupOrAfterRelaunch() throws {
        let name = "source-tombstones.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = AppleSourceStore(defaults: defaults)
        let original = source()
        try store.restoreConfigurationSources([original], secrets: nil)
        #expect(store.remove(id: original.id))
        #expect(store.sourceTombstones[original.id] != nil)
        let reloaded = AppleSourceStore(defaults: defaults)
        try reloaded.restoreConfigurationSources([original], secrets: nil, merge: false)
        #expect(reloaded.sources.isEmpty)
        let fresh = source(name: "Added again")
        try reloaded.restoreConfigurationSources([fresh], secrets: nil)
        #expect(reloaded.sources.map(\.id) == [fresh.id])
    }

    @MainActor @Test func remoteDeletionRemovesExistingSourceAndPersistsItsTombstone() throws {
        let name = "remote-source-tombstones.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = AppleSourceStore(defaults: defaults)
        let original = source()
        try store.restoreConfigurationSources([original], secrets: nil)
        store.mergeSourceTombstones([original.id: .now])
        #expect(store.sources.isEmpty)
        let reloaded = AppleSourceStore(defaults: defaults)
        #expect(reloaded.sourceTombstones[original.id] != nil)
        try reloaded.restoreConfigurationSources([original], secrets: nil)
        #expect(reloaded.sources.isEmpty)
    }

    @Test func roundTripAndVersion() throws {
        let snapshot = AppleConfigurationSnapshot(sources: [source()])
        let data = try AppleConfigurationFile.encode(snapshot: snapshot)
        let restored = try AppleConfigurationFile.decode(data).snapshot
        #expect(restored == snapshot)
        #expect(restored.formatVersion == 1)
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var body = try #require(json["snapshot"] as? [String: Any])
        body["formatVersion"] = 2
        json["snapshot"] = body
        let unsupported = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: AppleConfigurationError.unsupportedVersion) {
            try AppleConfigurationFile.decode(unsupported)
        }
    }

    @Test func sourceMergeAndSettingsOverwrite() throws {
        let original = source()
        let added = source(name: "New")
        let local = AppleConfigurationSnapshot(sources: [original], settings: ["setting": Data([1])])
        let incoming = AppleConfigurationSnapshot(
            sources: [source(id: original.id, name: "Updated"), added], settings: ["setting": Data([2])])
        let merged = local.merging(incoming)
        #expect(merged.sources.count == 2)
        #expect(merged.sources.first?.name == "Updated")
        #expect(merged.settings == incoming.settings)
    }

    @Test func plainExportOmitsEveryCredential() throws {
        let snapshot = AppleConfigurationSnapshot(sources: [source()])
        let secrets = AppleConfigurationSecrets(sourceCredentials: [snapshot.sources[0].id: "fixture-password"])
        let data = try AppleConfigurationFile.encode(snapshot: snapshot, secrets: secrets)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("fixture-secret"))
        #expect(!text.contains("fixture-password"))
        #expect(!text.contains("local-keychain-reference"))
        #expect(!text.contains("credentialReference"))
        #expect(try AppleConfigurationFile.decode(data).secrets == nil)
        #expect(snapshot.sources[0].needsSignIn)
    }

    @Test func encryptedExportRightAndWrongPassphrase() throws {
        let snapshot = AppleConfigurationSnapshot(sources: [source()])
        let secrets = AppleConfigurationSecrets(sourceCredentials: [snapshot.sources[0].id: "fixture-password"])
        let data = try AppleConfigurationFile.encode(snapshot: snapshot, secrets: secrets, passphrase: "fixture passphrase")
        #expect(!String(decoding: data, as: UTF8.self).contains("fixture-password"))
        #expect(try AppleConfigurationFile.decode(data, passphrase: "fixture passphrase").secrets == secrets)
        #expect(throws: AppleConfigurationError.wrongPassphrase) {
            try AppleConfigurationFile.decode(data, passphrase: "wrong passphrase")
        }
        #expect(throws: AppleConfigurationError.passphraseRequired) {
            try AppleConfigurationFile.decode(data)
        }
    }

    @Test func encryptedPayloadRejectsTampering() throws {
        let snapshot = AppleConfigurationSnapshot()
        let data = try AppleConfigurationFile.encode(snapshot: snapshot, passphrase: "fixture passphrase")
        var file = try JSONDecoder().decode(AppleConfigurationFile.self, from: data)
        file.snapshot.savedAt = .distantPast
        #expect(throws: AppleConfigurationError.wrongPassphrase) {
            try AppleConfigurationFile.decode(JSONEncoder().encode(file), passphrase: "fixture passphrase")
        }
    }

    @Test func cloudKeepsNewest500AndFitsBudget() throws {
        var entries: [String: ApplePlaybackProgress] = [:]
        for index in 0..<700 {
            entries["id-\(index)"] = .init(position: 40, duration: 100,
                updatedAt: Date(timeIntervalSince1970: Double(index)))
        }
        let snapshot = AppleConfigurationSnapshot(playbackProgress: entries)
        let data = try snapshot.cloudData()
        #expect(data.count <= AppleConfigurationSnapshot.maximumCloudBytes)
        let restored = try JSONDecoder().decode(AppleConfigurationSnapshot.self, from: data)
        #expect(restored.playbackProgress.count == 500)
        #expect(restored.playbackProgress["id-699"] != nil)
        #expect(restored.playbackProgress["id-0"] == nil)
    }

    @Test func oversizedNonProgressPayloadIsRejected() {
        let snapshot = AppleConfigurationSnapshot(settings: ["large": Data(repeating: 42, count: 1_000_000)])
        #expect(throws: AppleConfigurationError.tooLarge) { try snapshot.cloudData() }
    }

    @Test func cloudTrimsFurtherForByteLimit() throws {
        let progress = Dictionary(uniqueKeysWithValues: (0..<500).map {
            ("id-\($0)", ApplePlaybackProgress(position: 10, duration: 100, partID: String(repeating: "a", count: 4000)))
        })
        let data = try AppleConfigurationSnapshot(playbackProgress: progress).cloudData()
        #expect(data.count <= AppleConfigurationSnapshot.maximumCloudBytes)
        #expect(try JSONDecoder().decode(AppleConfigurationSnapshot.self, from: data).playbackProgress.count < 500)
    }
    @MainActor @Test func storeMergeKeepsExistingCredentialsAndFlagsNewSources() throws {
        let name = "configuration-tests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let credentials = ConfigurationTestCredentials()
        let store = AppleSourceStore(defaults: defaults, keychain: credentials)
        let original = try store.addIPTV(name: "Original", type: .xtream,
            endpoint: "https://fixture.example", username: "fixture-user", password: "fixture-password")
        var update = original
        update.name = "Updated"
        let newSource = source(name: "New")
        let snapshot = AppleConfigurationSnapshot(sources: [update, newSource])
        try store.restoreConfigurationSources(snapshot.sources, secrets: nil)
        #expect(store.sources.count == 2)
        let existing = try #require(store.sources.first { $0.id == original.id })
        #expect(existing.name == "Updated")
        #expect(!existing.needsSignIn)
        #expect(try store.iptvCredentials(for: existing)?.password == "fixture-password")
        let added = try #require(store.sources.first { $0.id == newSource.id })
        #expect(added.needsSignIn)
        #expect(!added.isEnabled)
        let reloaded = AppleSourceStore(defaults: defaults, keychain: credentials)
        #expect(reloaded.sources.first { $0.id == newSource.id }?.needsSignIn == true)
    }

    @MainActor @Test func restoresSettingsInMemoryAndIgnoresUnknownKeys() throws {
        let name = "configuration-tests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppleSettingsStore(defaults: defaults, keychain: ConfigurationTestCredentials())
        settings.favoriteChannelIDs = ["fixture-channel"]
        settings.autoPlayNextEpisode = false
        var values = try settings.configurationValues()
        values["not-an-openstream-setting"] = try PropertyListSerialization.data(fromPropertyList: [true], format: .binary, options: 0)
        settings.favoriteChannelIDs = []
        settings.autoPlayNextEpisode = true
        try settings.restoreConfiguration(values)
        #expect(settings.favoriteChannelIDs == ["fixture-channel"])
        #expect(!settings.autoPlayNextEpisode)
        #expect(defaults.object(forKey: "not-an-openstream-setting") == nil)
    }

    @MainActor @Test func restoringProgressInvalidatesExistingReaders() throws {
        let name = "configuration-tests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let reader = ApplePlaybackStore(defaults: defaults)
        reader.save(mediaID: "fixture", position: 20, duration: 200)
        #expect(reader.progress(for: "fixture")?.position == 20)
        let key = try #require(ApplePlaybackIdentity.storageKey(for: "fixture"))
        ApplePlaybackStore(defaults: defaults).restoreConfigurationProgress([key: .init(position: 80, duration: 200)])
        #expect(reader.progress(for: "fixture")?.position == 80)
    }

    @Test func duplicateSourceIDsAreRejected() throws {
        let original = source()
        let snapshot = AppleConfigurationSnapshot(sources: [original, original])
        #expect(throws: AppleConfigurationError.invalidFile) { try snapshot.validate() }
    }

}


private final class ConfigurationTestCredentials: AppleCredentialStoring {
    private var values: [String: String] = [:]
    func string(for account: String) throws -> String? { values[account] }
    func set(_ value: String, for account: String) throws { values[account] = value }
    func remove(_ account: String) throws { values.removeValue(forKey: account) }
}

extension AppleConfigurationSnapshotTests {
    @MainActor @Test func aliasBlobDoesNotChangeTheSnapshot() throws {
        try ApplePlaybackAliasFixture.run { fixture in
            fixture.populate()
            @MainActor func capture() -> AppleConfigurationSnapshot {
                AppleConfigurationSnapshot(savedAt: Date(timeIntervalSince1970: 1000),
                    playbackProgress: fixture.store.configurationProgress(),
                    watchedHistory: fixture.store.configurationWatchedHistory(),
                    watchedTombstones: fixture.store.configurationWatchedTombstones(),
                    continueWatchingRemovals: fixture.store.configurationContinueWatchingRemovals(),
                    playbackTerminals: fixture.store.configurationPlaybackTerminals(),
                    playbackActivity: fixture.store.configurationPlaybackActivity())
            }
            let beforeBlobs = fixture.rawBlobs()
            let before = capture()
            let beforeBytes = try AppleConfigurationSnapshot.encoder.encode(before)
            fixture.alias(true)
            let after = capture()
            let afterBytes = try AppleConfigurationSnapshot.encoder.encode(after)
            #expect(beforeBytes == afterBytes)
            #expect(AppleConfigurationSyncPolicy.contentDiffers(before, after) == false)
            #expect(fixture.rawBlobs() == beforeBlobs)
            let decodedBefore = try JSONDecoder().decode(AppleConfigurationSnapshot.self, from: beforeBytes)
            let decodedAfter = try JSONDecoder().decode(AppleConfigurationSnapshot.self, from: afterBytes)
            #expect(decodedBefore == decodedAfter)
            let beforeObject = try #require(JSONSerialization.jsonObject(with: beforeBytes) as? [String: Any])
            let afterObject = try #require(JSONSerialization.jsonObject(with: afterBytes) as? [String: Any])
            #expect(Set(beforeObject.keys) == Set(afterObject.keys))
            #expect(afterObject.keys.contains { $0.localizedCaseInsensitiveContains("alias") } == false)
        }
    }
}
