#if DEBUG
import SwiftUI

/// Headless verification enters the production Folder scanner and Library views.
public struct AppleLibraryTitlesDebugView: View {
    private static var preparedColdMeasurement = false
    @State private var sources: AppleSourceStore
    @State private var settings: AppleSettingsStore
    /// Its own index file: fixture records never reach the real media index.
    @State private var index = AppleMediaIndexStore(repository: AppleMediaIndexRepository(
        fileURL: FileManager.default.temporaryDirectory.appending(path: "library-titles-fixture-index.json")))
    @State private var autoPlayGroup: AppleLibrarySeries?

    public init() {
        Self.prepareColdMeasurementIfRequested()
        AppleLocalLibraryStore.persistsScanResults = false
        let defaults = UserDefaults(suiteName: "openstream.library-titles-fixture")!
        let path = ProcessInfo.processInfo.environment["OPENSTREAM_LIBRARY_FIXTURE_PATH"]
        if defaults.string(forKey: "fixture.path") != path {
            defaults.removeObject(forKey: "openstream.sources.v1")
            defaults.set(path, forKey: "fixture.path")
        }
        let smbRaw = ProcessInfo.processInfo.environment["OPENSTREAM_LIBRARY_FIXTURE_SMB"]
        if smbRaw != nil { defaults.removeObject(forKey: "openstream.sources.v1") }
        let store = AppleSourceStore(defaults: defaults, keychain: AppleLibraryFixtureCredentials())
        if let smbRaw, let data = smbRaw.data(using: .utf8),
           let smb = try? JSONDecoder().decode(AppleLibraryFixtureSMB.self, from: data) {
            _ = try? store.addNetworkShare(name: "Media", host: smb.host, port: smb.port ?? 445,
                share: smb.share, path: smb.path ?? "", username: smb.username ?? "",
                password: smb.password ?? "", domain: smb.domain ?? "")
        } else if let path {
            _ = try? store.addLibraryFolder(name: "Media", url: URL(fileURLWithPath: path), bookmarkData: nil)
        }
        _sources = State(initialValue: store)
        if AppleNetworkStub.isActive {
            let fixtureSettings = AppleSettingsStore(defaults: defaults, keychain: AppleLibraryFixtureCredentials())
            fixtureSettings.metadataEnabled = true
            fixtureSettings.tmdbAPIKey = "fixture"
            _settings = State(initialValue: fixtureSettings)
        } else {
            _settings = State(initialValue: AppleSettingsStore())
        }
    }

    /// The E2E runner snapshots and restores this container. Do this once
    /// per process: SwiftUI may construct the fixture view more than once.
    private static func prepareColdMeasurementIfRequested() {
        guard !preparedColdMeasurement, AppleNetworkStub.isActive,
              ProcessInfo.processInfo.environment["OPENSTREAM_DETAIL_SPEED_COLD"] == "1",
              let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        preparedColdMeasurement = true
        let artworkCaches = caches.appendingPathComponent("OpenStream")
        let directories = [caches.appendingPathComponent("LibraryTitles-v1"),
            artworkCaches.appendingPathComponent(AppleMetadataDiskCachePolicy.version),
            artworkCaches.appendingPathComponent(AppleArtworkDiskCachePolicy.version)]
        for directory in directories {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    public var body: some View {
        NavigationStack {
            if let autoPlayGroup {
                AppleLocalTitleDestination(group: autoPlayGroup, sourceStore: sources, mediaIndex: index,
                    settings: settings, openSettings: {}, tabToolbar: nil, autoPlay: true)
            } else {
                AppleLibraryView(sourceStore: sources, mediaIndex: index, settings: settings, openSettings: {})
                    .navigationTitle("Library")
            }
        }.preferredColorScheme(.dark).tint(.white)
        // The app's root starts the scan; this fixture replaces the root.
        .task {
            await AppleLocalLibraryStore.shared.reload(sourceStore: sources, mediaIndex: index, settings: settings)
            if ProcessInfo.processInfo.environment["OPENSTREAM_LIBRARY_FIXTURE_AUTOPLAY"] == "1" {
                autoPlayGroup = AppleLocalLibraryStore.shared.groups.first
            }
        }
        #if os(macOS)
        // The window shot hangs off the app's normal root, which this
        // fixture replaces; without it the fixture cannot be reviewed headless.
        .task {
            guard let request = AppleMacWindowShot.request() else { return }
            await AppleMacWindowShot.run(request)
        }
        #endif
    }
}
private struct AppleLibraryFixtureSMB: Decodable {
    let host: String
    let share: String
    var port: Int?
    var path: String?
    var username: String?
    var password: String?
    var domain: String?
}

/// Fixture credentials live only for this process and never enter Keychain.
private final class AppleLibraryFixtureCredentials: AppleCredentialStoring {
    private var values: [String: String] = [:]
    func string(for account: String) -> String? { values[account] }
    func set(_ value: String, for account: String) { values[account] = value }
    func remove(_ account: String) { values.removeValue(forKey: account) }
}
#endif
