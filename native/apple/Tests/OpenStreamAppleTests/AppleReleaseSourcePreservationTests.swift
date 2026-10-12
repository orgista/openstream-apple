import Foundation
import Testing
@testable import OpenStreamApple

@Suite struct AppleReleaseSourcePreservationTests {
    @Test @MainActor func unknownSourcesSurviveStoreEditsAndBackupRoundTrip() throws {
        let suite = "addons-preservation-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID()
        let payload: [String: Any] = ["id": id.uuidString, "kind": "future-source", "name": "Saved Source",
            "url": "https://fixture.example/source", "catalogs": [["type": "movie", "id": "saved"]],
            "catalogChoices": ["movie:saved": false], "isEnabled": true]
        defaults.set(try JSONSerialization.data(withJSONObject: [payload]), forKey: "sources")
        let store = AppleSourceStore(defaults: defaults, storageKey: "sources", keychain: ReleasePreservationCredentials())
        #expect(store.sources.isEmpty)
        _ = try store.addIPTV(name: "Live", type: .m3u, endpoint: "https://fixture.example/live.m3u")
        let reopened = AppleSourceStore(defaults: defaults, storageKey: "sources", keychain: ReleasePreservationCredentials())
        #expect(reopened.sources.count == 1)
        #expect(reopened.preservedConfigurationSources.count == 1)
        var snapshot = AppleConfigurationSnapshot(sources: reopened.sources)
        snapshot.preservedSourcePayloads = reopened.preservedConfigurationSources
        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(AppleConfigurationSnapshot.self, from: encoded)
        #expect(decoded.preservedSourcePayloads == snapshot.preservedSourcePayloads)
        #expect(decoded.sources.count == 1)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let members = try #require(object["sources"] as? [[String: Any]])
        let preserved = try #require(members.first { $0["id"] as? String == id.uuidString })
        #expect(NSDictionary(dictionary: preserved).isEqual(to: payload))
    }
    @Test @MainActor func preservedSourceSecretsSurviveExportAndRestore() throws {
        let suite = "preserved-secrets-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID()
        let keychain = ReleasePreservationCredentials()
        let address = try #require(URL(string: "https://fixture.example/configured-source"))
        try keychain.set("fixture-private-value", for: "fixture-account")
        try keychain.set(address.absoluteString, for: "fixture-transport")
        let payload: [String: Any] = ["id": id.uuidString, "kind": "future-source",
            "name": "Saved Source", "url": "https://fixture.example/source",
            "credentialReference": "fixture-account", "transportReference": "fixture-transport"]
        defaults.set(try JSONSerialization.data(withJSONObject: [payload]), forKey: "sources")
        let store = AppleSourceStore(defaults: defaults, storageKey: "sources", keychain: keychain)
        let secrets = try store.configurationSecrets()
        #expect(secrets.sourceAddresses[id] == address)
        #expect(secrets.sourceCredentials[id] == "fixture-private-value")
        let restoredKeys = ReleasePreservationCredentials()
        let restored = AppleSourceStore(defaults: defaults, storageKey: "restored", keychain: restoredKeys)
        try restored.restorePreservedConfigurationSources(store.preservedConfigurationSources, secrets: secrets, merge: false)
        #expect(restored.sources.isEmpty)
        #expect(try restored.configurationSecrets() == secrets)
    }
    #if !OPENSTREAM_ADDONS
    @Test @MainActor func savedAddonsAreIgnoredWithoutDeletingThem() throws {
        let suite = "release-addons-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let payload: [String: Any] = ["id": UUID().uuidString, "kind": "stremio", "name": "Saved Add-on",
            "url": "https://fixture.example/manifest.json", "resources": ["catalog", "stream", "meta", "subtitles"],
            "catalogs": [["type": "movie", "id": "saved"]]]
        let original = try JSONSerialization.data(withJSONObject: [payload])
        defaults.set(original, forKey: "sources")
        let store = AppleSourceStore(defaults: defaults, storageKey: "sources", keychain: ReleasePreservationCredentials())
        #expect(store.sources.isEmpty)
        #expect(store.credentialError == nil)
        #expect(AppleDiscoverEmptyState(sources: store.sources, catalogFailureCount: 0, hasSourceError: true) == .noSources)
        #expect(defaults.data(forKey: "sources") == original)
        #expect(store.preservedConfigurationSources.count == 1)
        #expect(AppleWebManagementPage.defaultSourceType == "m3u")
        #expect(!AppleWebManagementPage.setup().contains("Manifest URL"))
    }
    #endif
}

private final class ReleasePreservationCredentials: AppleCredentialStoring {
    private var values: [String: String] = [:]
    func string(for account: String) throws -> String? { values[account] }
    func set(_ value: String, for account: String) throws { values[account] = value }
    func remove(_ account: String) throws { values.removeValue(forKey: account) }
}
