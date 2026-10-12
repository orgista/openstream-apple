import Foundation
import Testing
@testable import OpenStreamApple

private let fixtureManifest = "https://fixture.example/aiometadata/manifest.json"

private final class SeedCredentialStore: AppleCredentialStoring, @unchecked Sendable {
    private var values: [String: String] = [:]
    func string(for reference: String) throws -> String? { values[reference] }
    func set(_ value: String, for reference: String) throws { values[reference] = value }
    func remove(_ reference: String) throws { values[reference] = nil }
}

@MainActor
private func seedStore(manifestName: String = "AIOMetadata") -> (AppleSourceStore, UserDefaults) {
    let defaults = UserDefaults(suiteName: "seed.\(UUID().uuidString)")!
    let manifest = """
    {"id":"community.aiometadata","version":"1.0.0","name":"\(manifestName)","description":"test",
     "resources":["catalog","meta"],"types":["movie","series"],
     "catalogs":[{"type":"movie","id":"aio.popular","name":"Popular"}]}
    """
    let client = AppleManifestClient(loader: { url in
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        return (Data(manifest.utf8), response)
    })
    let store = AppleSourceStore(
        defaults: defaults, storageKey: "seed.sources", keychain: SeedCredentialStore(),
        documentsDirectory: FileManager.default.temporaryDirectory, manifestClient: client)
    // The seed list is the owner's dev-sources file at runtime; tests hand
    // the store a fixture address instead, so no real add-on URL is in the tree.
    store.testCatalogManifestsOverride = [fixtureManifest]
    return (store, defaults)
}

@Suite @MainActor struct AppleTestCatalogSeedTests {
    @Test func seedsTheDevSourcesAddOnOnceWithItsCatalogs() async throws {
        let (store, _) = seedStore()
        await store.seedTestCatalogsIfNeeded(force: true)
        let added = store.sources.filter { $0.kind == .stremio }
        #expect(added.count == 1)
        #expect(added.first?.name == "AIOMetadata")
        #expect(added.first?.url.host == "fixture.example")
        #expect(added.first?.catalogs.map(\.id) == ["aio.popular"])

        await store.seedTestCatalogsIfNeeded(force: true)
        #expect(store.sources.filter { $0.kind == .stremio }.count == 1)
    }

    /// seed-sim.sh: a device set up from the dev-sources file gets only
    /// that file, never the seed beside it (Apple TV check 2026-10-01).
    @Test func devSourcesSetupSkipsTheTestCatalogs() async {
        let (store, _) = seedStore()
        store.markTestCatalogsSeeded()
        await store.seedTestCatalogsIfNeeded(force: true)
        #expect(store.sources.filter { $0.kind == .stremio }.isEmpty)
    }

    @Test func aDeletedSeedStaysDeleted() async throws {
        let (store, _) = seedStore()
        await store.seedTestCatalogsIfNeeded(force: true)
        let id = try #require(store.sources.first { $0.kind == .stremio }?.id)
        #expect(store.remove(id: id))
        await store.seedTestCatalogsIfNeeded(force: true)
        #expect(store.sources.filter { $0.kind == .stremio }.isEmpty)
    }

    /// Nothing to seed without a dev-sources file: a plain debug run starts
    /// empty instead of carrying an address in the binary.
    @Test func noDevSourcesFileSeedsNothing() async {
        let (store, _) = seedStore()
        store.testCatalogManifestsOverride = []
        await store.seedTestCatalogsIfNeeded(force: true)
        #expect(store.sources.filter { $0.kind == .stremio }.isEmpty)
    }
}

/// The seed list comes from the dev-sources file's stremio entries only.
@Suite struct AppleDevSourcesSeedListTests {
    @Test func onlyStremioEntriesAreSeededWithoutDuplicates() {
        let json = """
        {"version": 1, "sources": [
          {"kind": "stremio", "name": "AIOMetadata", "manifestURL": "\(fixtureManifest)"},
          {"kind": "m3u", "name": "List", "playlistURL": "https://iptv.fixture.example/list.m3u"},
          {"kind": "stremio", "name": "Again", "manifestURL": "\(fixtureManifest)"},
          {"kind": "stremio", "name": "Second", "manifestURL": "https://fixture.example/second/manifest.json"},
          {"kind": "stremio", "name": "Empty"}
        ]}
        """
        #expect(AppleTestCatalogSeedPolicy.devSourceManifests(in: Data(json.utf8))
            == [fixtureManifest, "https://fixture.example/second/manifest.json"])
    }

    @Test func aBrokenOrUnsupportedFileSeedsNothing() {
        #expect(AppleTestCatalogSeedPolicy.devSourceManifests(in: Data("not json".utf8)).isEmpty)
        #expect(AppleTestCatalogSeedPolicy.devSourceManifests(in: Data(#"{"version": 2, "sources": []}"#.utf8)).isEmpty)
        #expect(AppleTestCatalogSeedPolicy.devSourceManifests(fileAt: nil).isEmpty)
        #expect(AppleTestCatalogSeedPolicy.devSourceManifests(fileAt: "/nonexistent/dev-sources.json").isEmpty)
    }

    @Test func theFileIsReadInPlaceAndKept() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "seed-\(UUID().uuidString).json")
        let json = #"{"version": 1, "sources": [{"kind": "stremio", "name": "A", "manifestURL": "\#(fixtureManifest)"}]}"#
        try Data(json.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(AppleTestCatalogSeedPolicy.devSourceManifests(fileAt: url.path) == [fixtureManifest])
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func launchArgumentWinsOverTheEnvironment() {
        let env = [AppleTestCatalogSeedPolicy.devSourcesEnvironmentKey: "/env/dev-sources.json"]
        #expect(AppleTestCatalogSeedPolicy.devSourcesPath(launchArgument: "/arg/dev-sources.json", environment: env)
            == "/arg/dev-sources.json")
        #expect(AppleTestCatalogSeedPolicy.devSourcesPath(launchArgument: " ", environment: env) == "/env/dev-sources.json")
        #expect(AppleTestCatalogSeedPolicy.devSourcesPath(launchArgument: nil, environment: [:]) == nil)
    }
}
