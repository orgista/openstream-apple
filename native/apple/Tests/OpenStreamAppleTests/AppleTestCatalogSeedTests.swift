import Foundation
import Testing
@testable import OpenStreamApple

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
    return (store, defaults)
}

@Suite @MainActor struct AppleTestCatalogSeedTests {
    private let fixtureManifests = ["https://fixture.example/manifest.json"]

    @Test func anEmptyCatalogConfigurationDoesNotSeedSources() async {
        let (store, _) = seedStore()
        await store.seedTestCatalogsIfNeeded(force: true, manifests: [])
        let added = store.sources.filter { $0.kind == .stremio }
        #expect(added.isEmpty, "Unexpected seeded sources: \(added.count)")
    }

    @Test func seedsAIOMetadataOnceWithItsCatalogs() async throws {
        let (store, _) = seedStore()
        await store.seedTestCatalogsIfNeeded(force: true, manifests: fixtureManifests)
        let added = store.sources.filter { $0.kind == .stremio }
        #expect(added.count == 1)
        #expect(added.first?.name == "AIOMetadata")
        #expect(added.first?.url.host == "fixture.example")
        #expect(added.first?.catalogs.map(\.id) == ["aio.popular"])

        await store.seedTestCatalogsIfNeeded(force: true, manifests: fixtureManifests)
        #expect(store.sources.filter { $0.kind == .stremio }.count == 1)
    }

    @Test func aDeletedSeedStaysDeleted() async throws {
        let (store, _) = seedStore()
        await store.seedTestCatalogsIfNeeded(force: true, manifests: fixtureManifests)
        let id = try #require(store.sources.first { $0.kind == .stremio }?.id)
        #expect(store.remove(id: id))
        await store.seedTestCatalogsIfNeeded(force: true, manifests: fixtureManifests)
        #expect(store.sources.filter { $0.kind == .stremio }.isEmpty)
    }
}
