#if DEBUG && os(tvOS)
import Foundation

/// Keeps the empty-pane device check and the fixed simulator walk out of the viewer's stores.
@MainActor
final class AppleTVSettingsWalkFixture {
    static let current: AppleTVSettingsWalkFixture? = {
        guard let mode = UserDefaults.standard.string(forKey: "OpenStreamSettingsWalkFixture"),
              ["empty", "lineup"].contains(mode) else { return nil }
        do { return try AppleTVSettingsWalkFixture(hasLineup: mode == "lineup") }
        catch { preconditionFailure("Could not prepare the Settings walk fixture: \(error)") }
    }()

    let settings: AppleSettingsStore
    let sources: AppleSourceStore
    let storage: AppleStorageMaintenance

    private init(hasLineup: Bool) throws {
        let domain = "openstream.settings-walk-fixture"
        guard let defaults = UserDefaults(suiteName: domain) else {
            preconditionFailure("Could not create the Settings walk defaults")
        }
        defaults.removePersistentDomain(forName: domain)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("settings-walk-\(UUID())")
        let credentials = AppleSettingsWalkCredentials()
        let lineup = AppleChannelLineupStore(directory: directory.appendingPathComponent("lineup"))
        settings = AppleSettingsStore(defaults: defaults, keychain: credentials, lineupStore: lineup)
        settings.metadataEnabled = true
        settings.tmdbAPIKey = "fixture"
        if hasLineup {
            let sourceID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1))
            guard let playlistURL = URL(string: "https://fixture.example/settings/channels.m3u") else {
                preconditionFailure("Invalid fixture playlist URL")
            }
            let source = AppleSource(id: sourceID, kind: .liveTV, name: "Fixture IPTV", url: playlistURL, iptvType: .m3u)
            defaults.set(try JSONEncoder().encode([source]), forKey: AppleSourceStore.defaultStorageKey)
            func channelID(_ name: String) -> String {
                sourceID.uuidString + ":" + ApplePlaybackIdentity.digest(for: "\(name)|https://fixture.example/live/\(name).ts")
            }
            settings.favoriteChannelIDs = [channelID("one"), channelID("two")]
            settings.favoriteLiveChannelOrder = [channelID("two"), channelID("one")]
            settings.hiddenLiveChannelIDs = [channelID("three")]
        }
        sources = AppleSourceStore(defaults: defaults, keychain: credentials,
                                   documentsDirectory: directory.appendingPathComponent("documents"))
        storage = AppleStorageMaintenance(
            offlineStore: AppleOfflineMediaStore(rootDirectory: directory.appendingPathComponent("downloads")),
            cacheDirectory: directory.appendingPathComponent("cache"),
            metadataDirectory: directory.appendingPathComponent("metadata")
        )
    }
}

private final class AppleSettingsWalkCredentials: AppleCredentialStoring {
    private var values: [String: String] = [:]
    func string(for account: String) -> String? { values[account] }
    func set(_ value: String, for account: String) { values[account] = value }
    func remove(_ account: String) { values.removeValue(forKey: account) }
}
#endif
