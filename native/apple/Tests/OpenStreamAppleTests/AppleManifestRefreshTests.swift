import Foundation
import Testing
@testable import OpenStreamApple

private final class ManifestRefreshCredentialStore: AppleCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func string(for account: String) throws -> String? { lock.lock(); defer { lock.unlock() }; return values[account] }
    func set(_ value: String, for account: String) throws { lock.lock(); defer { lock.unlock() }; values[account] = value }
    func remove(_ account: String) throws { lock.lock(); defer { lock.unlock() }; values[account] = nil }
}

private let manifestBody: Data = {
    let object: [String: Any] = [
        "id": "org.fixture.catalogs",
        "name": "Fixture Catalogs",
        "version": "1.0.0",
        "resources": ["catalog"],
        "types": ["movie"],
        "catalogs": [
            ["type": "movie", "id": "top", "name": "Top", "extra": [["name": "skip"], ["name": "search"]]],
            ["type": "movie", "id": "new", "name": "New"],
        ],
    ]
    return try! JSONSerialization.data(withJSONObject: object)
}()

@Suite("Add-on manifest refresh (catalog paging)")
struct AppleManifestRefreshTests {
    private func stremio(_ id: UUID = UUID(), enabled: Bool = true, catalogs: [AppleStremioCatalog] = [
        AppleStremioCatalog(type: "movie", id: "top"),
    ]) -> AppleSource {
        AppleSource(id: id, kind: .stremio, name: "Fixture", url: URL(string: "https://fixture.example/manifest.json")!,
                    isEnabled: enabled, resources: ["catalog"], catalogs: catalogs)
    }

    @Test("Due: never tried, or tried a day ago; not disabled, not catalog-less, not other kinds")
    func due() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let fresh = stremio(), stale = stremio(), never = stremio()
        let disabled = stremio(enabled: false), empty = stremio(catalogs: [])
        let other = AppleSource(kind: .liveTV, name: "TV", url: URL(string: "https://fixture.example/tv.m3u")!)
        let attempts = [
            fresh.id.uuidString: now.timeIntervalSince1970 - 3_600,
            stale.id.uuidString: now.timeIntervalSince1970 - 90_000,
        ]
        let due = AppleManifestRefreshPolicy.due(sources: [fresh, stale, never, disabled, empty, other],
                                                 lastAttempt: attempts, now: now)
        #expect(due == [stale.id, never.id])
        #expect(AppleManifestRefreshPolicy.pruned(attempts, liveIDs: [fresh.id.uuidString]).keys.sorted() == [fresh.id.uuidString])
    }

    @Test("Stored catalogs keep their set and order and take the manifest's skip flag")
    func refreshedCatalogs() {
        let stored = [AppleStremioCatalog(type: "movie", id: "top", name: "Top"),
                      AppleStremioCatalog(type: "movie", id: "gone", name: "Gone")]
        let manifest = [AppleStremioCatalog(type: "movie", id: "top", supportsSearch: true, supportsSkip: true),
                        AppleStremioCatalog(type: "movie", id: "new")]
        let result = AppleManifestRefreshPolicy.refreshedCatalogs(stored: stored, manifest: manifest)
        #expect(result.map(\.id) == ["top", "gone"])
        #expect(result[0].supportsSkip && result[0].supportsSearch)
        #expect(result[0].name == "Top")
        #expect(!result[1].supportsSkip)
    }

    @Test("A shelf cached with the old catalog pages with the source's refreshed one")
    func liveCatalog() {
        let old = AppleStremioCatalog(type: "movie", id: "top")
        let source = stremio(catalogs: [AppleStremioCatalog(type: "movie", id: "top", supportsSkip: true)])
        #expect(AppleCatalogPaging.liveCatalog(old, in: source).supportsSkip)
        #expect(AppleCatalogPaging.nextSkip(catalog: AppleCatalogPaging.liveCatalog(old, in: source),
                                            loadedCount: 20, state: nil) == 20)
        #expect(AppleCatalogPaging.nextSkip(catalog: old, loadedCount: 20, state: nil) == nil)
    }

    @MainActor
    @Test("Refreshing an add-on saved without skip stores the flag; the launch pass records the attempt")
    func storeRefresh() async throws {
        let suite = "openstream-manifest-refresh-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = AppleManifestClient(loader: { url in
            (manifestBody, HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!)
        }, sleeper: { _ in })
        let store = AppleSourceStore(defaults: defaults, keychain: ManifestRefreshCredentialStore(),
                                     documentsDirectory: FileManager.default.temporaryDirectory,
                                     manifestClient: client, logoBackfillDelay: .milliseconds(1))
        // Saved the way builds before 40e9350 saved it: no skip on the catalog.
        let saved = try store.addStremio(
            manifestURL: URL(string: "https://fixture.example/manifest.json")!,
            manifest: AppleStremioManifest(id: "org.fixture.catalogs", name: "Fixture Catalogs", version: "1.0.0",
                                           logoURL: URL(string: "https://fixture.example/logo.png"),
                                           resources: ["catalog"],
                                           catalogs: [AppleStremioCatalog(type: "movie", id: "top", name: "Top")]))
        #expect(store.sources.first { $0.id == saved.id }?.catalogs.first?.supportsSkip == false)

        store.scheduleDailyManifestRefresh()
        let deadline = ContinuousClock.now + .seconds(5)
        while store.sources.first(where: { $0.id == saved.id })?.catalogs.first?.supportsSkip != true,
              ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let refreshed = try #require(store.sources.first { $0.id == saved.id })
        #expect(refreshed.catalogs.map(\.id) == ["top"])
        #expect(refreshed.catalogs.first?.supportsSkip == true)
        while (defaults.dictionary(forKey: "openstream.sources.v1.manifest-refresh.v1") as? [String: Double])?[saved.id.uuidString] == nil,
              ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let attempts = defaults.dictionary(forKey: "openstream.sources.v1.manifest-refresh.v1") as? [String: Double]
        #expect(attempts?[saved.id.uuidString] != nil)
        // The persisted copy carries the flag too.
        let reloaded = AppleSourceStore(defaults: defaults, keychain: ManifestRefreshCredentialStore(),
                                        documentsDirectory: FileManager.default.temporaryDirectory,
                                        manifestClient: client, logoBackfillDelay: .seconds(3_600))
        #expect(reloaded.sources.first { $0.id == saved.id }?.catalogs.first?.supportsSkip == true)
        // Tried today: the next launch does not ask again.
        #expect(AppleManifestRefreshPolicy.due(sources: reloaded.sources, lastAttempt: attempts ?? [:], now: Date()).isEmpty)
    }
}
