import Foundation
import Testing
@testable import OpenStreamApple

private struct AddonFixtureCredentialStore: AppleCredentialStoring {
    func string(for account: String) throws -> String? { nil }
    func set(_ value: String, for account: String) throws {}
    func remove(_ account: String) throws {}
}

private func addonFixture(_ name: String) throws -> Data {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures", isDirectory: true)
        .appendingPathComponent(name)
    return try Data(contentsOf: url)
}

/// Replays a recorded manifest and asserts the requested URL is byte-for-byte
/// the address the owner pasted.
private func manifestClient(
    expecting expected: String,
    fixture: String
) throws -> AppleManifestClient {
    let body = try addonFixture(fixture)
    return AppleManifestClient(
        loader: { url in
            #expect(url.absoluteString == expected)
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (body, response)
        },
        sleeper: { _ in }
    )
}

private func catalogClient(
    expecting expected: String,
    fixture: String
) throws -> AppleStremioCatalogClient {
    let body = try addonFixture(fixture)
    return AppleStremioCatalogClient(loader: { request in
        #expect(request.url?.absoluteString == expected)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (body, response)
    })
}

@MainActor
private func addonStore() -> AppleSourceStore {
    AppleSourceStore(
        defaults: UserDefaults(suiteName: "addon.fixtures.\(UUID().uuidString)")!,
        storageKey: "addon.fixtures",
        keychain: AddonFixtureCredentialStore(),
        documentsDirectory: FileManager.default.temporaryDirectory
    )
}

private let streamingCatalogsManifestURL =
    "https://7a82163c306e-stremio-netflix-catalog-addon.baby-beamup.club/manifest.json"
private let rottenTomatoesManifestURL =
    "https://7a82163c306e-rottentomatoes.baby-beamup.club/%7B%22rpdb_key%22%3A%22t0-free-rpdb%22%7D/manifest.json"
private let tmdbManifestURL =
    "https://tmdb.elfhosted.com/" + String(repeating: "FixtureConfig+value-", count: 90) + "/manifest.json"

@MainActor
@Test func streamingCatalogsAddOnAddsAndListsACatalogPage() async throws {
    let client = try manifestClient(
        expecting: streamingCatalogsManifestURL,
        fixture: "addon-streaming-catalogs-manifest.json"
    )
    let store = addonStore()
    let source = try await store.addStremio(manifestValue: streamingCatalogsManifestURL, client: client)
    #expect(source.url.absoluteString == streamingCatalogsManifestURL)
    #expect(source.manifestID == "pw.ers.netflix-catalog")
    #expect(source.version == "1.1.1")
    #expect(source.resources == ["catalog"])
    #expect(source.catalogs.count == 10)

    let catalog = try #require(source.catalogs.first)
    #expect(catalog.type == "movie")
    #expect(catalog.id == "nfx")
    let endpoint = try AppleStremioCatalogClient.endpoint(source: source, catalog: catalog)
    #expect(endpoint.absoluteString ==
        "https://7a82163c306e-stremio-netflix-catalog-addon.baby-beamup.club/catalog/movie/nfx.json")
    let items = try await catalogClient(
        expecting: endpoint.absoluteString,
        fixture: "addon-streaming-catalogs-movie-nfx.json"
    ).load(source: source, catalog: catalog)
    #expect(items.count == 3)
    #expect(items.first?.mediaID == "tt0120791")
}

@MainActor
@Test func rottenTomatoesAddOnKeepsItsConfiguredJSONPathSegmentByteExact() async throws {
    // The config segment is a percent-encoded JSON object. Re-encoding it, or
    // decoding it into raw braces, gives the add-on an address it rejects.
    #expect(try AppleManifestURLPolicy.normalize(rottenTomatoesManifestURL).absoluteString
        == rottenTomatoesManifestURL)
    #expect(try AppleManifestURLPolicy.normalize(
        " https://7a82163c306e-rottentomatoes.baby-beamup.club/%7B%22rpdb_key%22%3A%22t0-free-rpdb%22%7D "
    ).absoluteString == rottenTomatoesManifestURL)

    let client = try manifestClient(
        expecting: rottenTomatoesManifestURL,
        fixture: "addon-rottentomatoes-manifest.json"
    )
    let store = addonStore()
    let source = try await store.addStremio(manifestValue: rottenTomatoesManifestURL, client: client)
    #expect(source.url.absoluteString == rottenTomatoesManifestURL)
    #expect(source.manifestID == "pw.ers.rottentomatoes")
    #expect(source.catalogs.map(\.id) == ["rtfresh_movie", "rtfresh_series"])
    // `extra: [{ name: "genre", isRequired: false }]` must not lock the shelf.
    #expect(source.catalogs.allSatisfy { !$0.requiresInput })

    let catalog = try #require(source.catalogs.first)
    let endpoint = try AppleStremioCatalogClient.endpoint(source: source, catalog: catalog)
    #expect(endpoint.absoluteString ==
        "https://7a82163c306e-rottentomatoes.baby-beamup.club/%7B%22rpdb_key%22%3A%22t0-free-rpdb%22%7D/catalog/movie/rtfresh_movie.json")
    let items = try await catalogClient(
        expecting: endpoint.absoluteString,
        fixture: "addon-rottentomatoes-movie-rtfresh.json"
    ).load(source: source, catalog: catalog)
    #expect(items.count == 3)
    #expect(items.first?.mediaID == "tt33095251")
}

@MainActor
@Test func tmdbAddOnKeepsItsLongConfigurationSegmentAndServesMeta() async throws {
    #expect(tmdbManifestURL.count > 1_000)
    #expect(try AppleManifestURLPolicy.normalize(tmdbManifestURL).absoluteString == tmdbManifestURL)

    let client = try manifestClient(
        expecting: tmdbManifestURL,
        fixture: "addon-tmdb-configured-manifest.json"
    )
    let store = addonStore()
    let source = try await store.addStremio(manifestValue: tmdbManifestURL, client: client)
    #expect(source.url.absoluteString == tmdbManifestURL)
    #expect(source.manifestID == "tmdb-addon")
    #expect(source.resources == ["catalog", "meta"])
    #expect(source.catalogs.count == AppleStremioManifest.maximumCatalogs)

    let catalog = try #require(source.catalogs.first { $0.id == "tmdb.top" && $0.type == "movie" })
    let endpoint = try AppleStremioCatalogClient.endpoint(source: source, catalog: catalog)
    #expect(endpoint.absoluteString == tmdbManifestURL.replacingOccurrences(
        of: "/manifest.json",
        with: "/catalog/movie/tmdb.top.json"
    ))
    let items = try await catalogClient(
        expecting: endpoint.absoluteString,
        fixture: "addon-tmdb-movie-top.json"
    ).load(source: source, catalog: catalog)
    #expect(items.count == 3)
    let first = try #require(items.first)
    #expect(first.mediaID == "tmdb:969681")

    let metaBody = try addonFixture("addon-tmdb-meta-movie.json")
    let metaClient = AppleStremioMetadataClient(loader: { request in
        #expect(request.url?.absoluteString == tmdbManifestURL.replacingOccurrences(
            of: "/manifest.json",
            with: "/meta/movie/tmdb%3A969681.json"
        ))
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (metaBody, response)
    })
    let details = try await metaClient.details(source: source, type: "movie", mediaID: first.mediaID)
    #expect(details.mediaID == "tmdb:969681")
    #expect(details.title == "Spider-Man: Brand New Day")
}

@Test func addOnFailuresNameTheirReason() {
    #expect(AppleManifestClientError.manifestNotJSON.errorDescription
        == "The address returned a page instead of a manifest.")
    #expect(AppleManifestClientError.manifestMissingField("id").errorDescription
        == "The manifest has no \"id\".")
    #expect(AppleManifestClientError.manifestNeedsConfiguration.errorDescription
        == "Configure this add-on on its own site first, then paste the address it gives you.")
}

@Test func installLinksFromAddOnDirectoriesAreAccepted() throws {
    #expect(try AppleManifestURLPolicy.normalize("stremio://addon.example/manifest.json").absoluteString
        == "https://addon.example/manifest.json")
    #expect(try AppleManifestURLPolicy.normalize("stremio://addon.example").absoluteString
        == "https://addon.example/manifest.json")
}

@Test func catalogsDeclaringExtraSupportedAreReadForSearch() throws {
    let payload = Data(#"""
    {
      "id": "fixture.extra",
      "name": "Extra Shorthand",
      "resources": ["catalog"],
      "catalogs": [
        {"type": "movie", "id": "browse", "extraSupported": ["search", "skip"]},
        {"type": "series", "id": "byGenre", "extraRequired": ["genre"]}
      ]
    }
    """#.utf8)
    let manifest = try JSONDecoder().decode(AppleStremioManifest.self, from: payload)
    #expect(manifest.catalogs.count == 2)
    #expect(manifest.catalogs[0].supportsSearch)
    #expect(!manifest.catalogs[0].requiresInput)
    #expect(manifest.catalogs[1].requiresInput)
}

@Test func manifestsThatDemandConfigurationSaySo() async {
    let body = Data(#"""
    {
      "id": "fixture.needs-config",
      "name": "Needs Config",
      "resources": ["catalog"],
      "behaviorHints": {"configurable": true, "configurationRequired": true}
    }
    """#.utf8)
    let client = AppleManifestClient(
        loader: { url in
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (body, response)
        },
        sleeper: { _ in }
    )
    await #expect(throws: AppleManifestClientError.manifestNeedsConfiguration) {
        try await client.load("https://addon.example/manifest.json")
    }
}
