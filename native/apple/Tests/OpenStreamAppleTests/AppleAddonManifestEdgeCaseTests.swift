import Foundation
import Testing
@testable import OpenStreamApple

// Owner add-ons U7-U10: a configured add-on's address carries its settings as
// a path segment (percent-encoded JSON, or a very long base64-like blob). The
// app must fetch, store and derive endpoints from that address byte-for-byte.

private func edgeCaseFixture(_ name: String) throws -> Data {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures", isDirectory: true)
        .appendingPathComponent(name)
    return try Data(contentsOf: url)
}

private let rpdbSegment = "%7B%22rpdb_key%22%3A%22t0-free-rpdb%22%7D"
private let rottenTomatoesHost = "7a82163c306e-rottentomatoes.baby-beamup.club"
private let rottenTomatoesManifest = "https://\(rottenTomatoesHost)/\(rpdbSegment)/manifest.json"
private let streamingCatalogsManifest =
    "https://7a82163c306e-stremio-netflix-catalog-addon.baby-beamup.club/manifest.json"
/// Same length and alphabet as the owner's elfhosted address (1,000+ characters
/// of URL-safe base64 with `+`, `-` and `_`), built so the test stays readable.
private let elfhostedSegment: String = {
    let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_+")
    return (0 ..< 1_200).map { String(alphabet[$0 % alphabet.count]) }.joined()
}()
private let elfhostedManifest = "https://tmdb.elfhosted.com/\(elfhostedSegment)/manifest.json"

private func stremioSource(_ manifest: String) -> AppleSource {
    AppleSource(
        kind: .stremio,
        name: "Fixture",
        url: URL(string: manifest)!,
        manifestID: "fixture",
        resources: ["catalog", "meta"],
        catalogs: [AppleStremioCatalog(type: "movie", id: "rtfresh_movie")]
    )
}

private func statusClient(_ status: Int) -> AppleManifestClient {
    AppleManifestClient(
        loader: { url in
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (Data(), response)
        },
        sleeper: { _ in }
    )
}

private func bodyClient(_ body: String) -> AppleManifestClient {
    AppleManifestClient(
        loader: { url in
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (Data(body.utf8), response)
        },
        sleeper: { _ in }
    )
}

@Suite("Add-on manifest edge cases")
struct AppleAddonManifestEdgeCaseTests {
    // MARK: URL byte-exactness

    @Test func percentEncodedJSONSegmentSurvivesNormalisationUntouched() throws {
        let url = try AppleManifestURLPolicy.normalize(rottenTomatoesManifest)
        #expect(url.absoluteString == rottenTomatoesManifest)
        #expect(url.host() == rottenTomatoesHost)
        // The segment reaches the server exactly as pasted: no double
        // encoding (`%257B`) and no decoding into raw braces.
        #expect(!url.absoluteString.contains("%25"))
        #expect(!url.absoluteString.contains("{"))
    }

    @Test func surroundingWhitespaceIsTheOnlyThingTrimmed() throws {
        let pasted = "\n  \(rottenTomatoesManifest)\t \n"
        #expect(try AppleManifestURLPolicy.normalize(pasted).absoluteString == rottenTomatoesManifest)
    }

    @Test func longConfigurationSegmentIsKeptByteExact() throws {
        #expect(elfhostedManifest.count > 1_200)
        let url = try AppleManifestURLPolicy.normalize(elfhostedManifest)
        #expect(url.absoluteString == elfhostedManifest)
        // Without the filename the policy appends it; the segment is unchanged.
        let bare = "https://tmdb.elfhosted.com/\(elfhostedSegment)"
        #expect(try AppleManifestURLPolicy.normalize(bare).absoluteString == elfhostedManifest)
        #expect(try AppleManifestURLPolicy.normalize(bare + "/").absoluteString == elfhostedManifest)
    }

    @Test func rawBracesPastedFromABrowserBarAreEncodedOnce() throws {
        let raw = "https://\(rottenTomatoesHost)/{\"rpdb_key\":\"t0-free-rpdb\"}/manifest.json"
        let url = try AppleManifestURLPolicy.normalize(raw)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "https")
        #expect(components.host == rottenTomatoesHost)
        #expect(components.path == "/{\"rpdb_key\":\"t0-free-rpdb\"}/manifest.json")
        #expect(!components.percentEncodedPath.contains("{"))
        #expect(!components.percentEncodedPath.contains("\""))
        #expect(!components.percentEncodedPath.contains("%25"))
    }

    // MARK: Install-scheme acceptance

    @Test func installSchemeMapsToHTTPSAndKeepsTheConfiguredSegment() throws {
        let installLink = "stremio://\(rottenTomatoesHost)/\(rpdbSegment)/manifest.json"
        #expect(try AppleManifestURLPolicy.normalize(installLink).absoluteString == rottenTomatoesManifest)
        #expect(try AppleManifestURLPolicy.normalize("stremio://tmdb.elfhosted.com/\(elfhostedSegment)/manifest.json")
            .absoluteString == elfhostedManifest)
        #expect(try AppleManifestURLPolicy.normalize("STREMIO://\(rottenTomatoesHost)/\(rpdbSegment)")
            .absoluteString == rottenTomatoesManifest)
    }

    @Test func plainHTTPToAPublicHostStillNamesItsReason() {
        #expect(throws: AppleManifestURLPolicy.Error.insecureHTTP) {
            try AppleManifestURLPolicy.normalize("http://\(rottenTomatoesHost)/\(rpdbSegment)/manifest.json")
        }
        #expect(AppleManifestURLPolicy.Error.insecureHTTP.errorDescription == "Use the add-on's HTTPS manifest URL.")
    }

    // MARK: Base URL derivation

    @Test func baseURLRemovesOnlyTheTrailingManifestFilename() {
        let rotten = AppleManifestURLPolicy.addonBaseURL(forManifest: URL(string: rottenTomatoesManifest)!)
        #expect(rotten.absoluteString == "https://\(rottenTomatoesHost)/\(rpdbSegment)/")

        let elfhosted = AppleManifestURLPolicy.addonBaseURL(forManifest: URL(string: elfhostedManifest)!)
        #expect(elfhosted.absoluteString == "https://tmdb.elfhosted.com/\(elfhostedSegment)/")

        let plain = AppleManifestURLPolicy.addonBaseURL(forManifest: URL(string: streamingCatalogsManifest)!)
        #expect(plain.absoluteString == "https://7a82163c306e-stremio-netflix-catalog-addon.baby-beamup.club/")

        // Not a manifest address: returned unchanged.
        let other = URL(string: "https://addon.example/catalog/movie/top.json")!
        #expect(AppleManifestURLPolicy.addonBaseURL(forManifest: other) == other)
    }

    @Test func sourceTransportURLUsesTheByteExactBase() {
        #expect(stremioSource(rottenTomatoesManifest).transportURL.absoluteString
            == "https://\(rottenTomatoesHost)/\(rpdbSegment)/")
        #expect(stremioSource(elfhostedManifest).transportURL.absoluteString
            == "https://tmdb.elfhosted.com/\(elfhostedSegment)/")
    }

    // MARK: Catalog URL construction

    @Test func catalogEndpointsAppendToTheConfiguredSegment() throws {
        let source = stremioSource(rottenTomatoesManifest)
        let catalog = try #require(source.catalogs.first)
        #expect(try AppleStremioCatalogClient.endpoint(source: source, catalog: catalog).absoluteString
            == "https://\(rottenTomatoesHost)/\(rpdbSegment)/catalog/movie/rtfresh_movie.json")

        let elfhosted = stremioSource(elfhostedManifest)
        let top = AppleStremioCatalog(type: "movie", id: "tmdb.top", supportsSearch: true)
        let configured = AppleSource(
            kind: .stremio,
            name: elfhosted.name,
            url: elfhosted.url,
            manifestID: "tmdb-addon",
            resources: ["catalog", "meta"],
            catalogs: [top]
        )
        #expect(try AppleStremioCatalogClient.endpoint(source: configured, catalog: top).absoluteString
            == "https://tmdb.elfhosted.com/\(elfhostedSegment)/catalog/movie/tmdb.top.json")
        #expect(try AppleStremioCatalogClient.searchEndpoint(source: configured, catalog: top, query: "dune part").absoluteString
            == "https://tmdb.elfhosted.com/\(elfhostedSegment)/catalog/movie/tmdb.top/search=dune%20part.json")
    }

    // MARK: Fixture decoding (recorded from the live add-ons on 2026-09-14)

    @Test func streamingCatalogsFixtureDecodesWithoutExtraOrConfigurationFields() throws {
        let manifest = try JSONDecoder().decode(
            AppleStremioManifest.self,
            from: edgeCaseFixture("addon-streaming-catalogs-manifest.json")
        )
        #expect(manifest.id == "pw.ers.netflix-catalog")
        #expect(manifest.name == "Streaming Catalogs")
        #expect(manifest.version == "1.1.1")
        #expect(manifest.resources == ["catalog"])
        #expect(manifest.catalogs.count == 10)
        #expect(manifest.catalogs.map(\.id) == ["nfx", "nfx", "hbm", "hbm", "dnp", "dnp", "amp", "amp", "atp", "atp"])
        // `catalogs[].extra` is absent and `behaviorHints.configurable` alone
        // does not mean the add-on demands configuration.
        #expect(manifest.catalogs.allSatisfy { !$0.requiresInput && !$0.supportsSearch })
        #expect(!manifest.requiresConfiguration)
        #expect(manifest.logoURL?.host() == "play-lh.googleusercontent.com")
    }

    @Test func rottenTomatoesFixtureDecodesOptionalGenreExtraAndEmptyHints() throws {
        let manifest = try JSONDecoder().decode(
            AppleStremioManifest.self,
            from: edgeCaseFixture("addon-rottentomatoes-manifest.json")
        )
        #expect(manifest.id == "pw.ers.rottentomatoes")
        #expect(manifest.version == "1.0.9")
        #expect(manifest.resources == ["catalog"])
        #expect(manifest.catalogs.map(\.id) == ["rtfresh_movie", "rtfresh_series"])
        #expect(manifest.catalogs.map(\.type) == ["movie", "series"])
        #expect(manifest.catalogs.map(\.name) == ["RT: Certified Fresh", "RT: Fresh TV Shows"])
        #expect(manifest.catalogs.allSatisfy { !$0.requiresInput })
        #expect(!manifest.requiresConfiguration)
    }

    @Test func tmdbFixtureDecodesThirtyTwoCatalogsDownToTheShelfLimit() throws {
        let data = try edgeCaseFixture("addon-tmdb-configured-manifest.json")
        let document = try JSONSerialization.jsonObject(with: data)
        let raw = try #require(document as? [String: Any])
        #expect((raw["catalogs"] as? [Any])?.count == 32)

        let manifest = try JSONDecoder().decode(AppleStremioManifest.self, from: data)
        #expect(manifest.id == "tmdb-addon")
        #expect(manifest.version == "3.1.7")
        #expect(manifest.resources == ["catalog", "meta"])
        #expect(manifest.catalogs.count == AppleStremioManifest.maximumCatalogs)
        #expect(manifest.catalogs.first?.id == "tmdb.latest")
        #expect(manifest.catalogs.contains { $0.id == "tmdb.top" && $0.type == "movie" })
        // `extra: [{name: "genre", isRequired: false}, {name: "skip"}]`
        #expect(manifest.catalogs.allSatisfy { !$0.requiresInput })
        #expect(!manifest.requiresConfiguration)
        #expect(manifest.logoURL?.absoluteString == "https://tmdb.elfhosted.com/logo.png")
    }

    // MARK: Lenient, spec-shaped decoding

    @Test func resourcesMayBeObjectsAndIncludeAddonCatalogAndSubtitles() throws {
        let payload = Data(#"""
        {
          "id": "fixture.objects",
          "name": "Object Resources",
          "resources": [
            "catalog",
            {"name": "meta", "types": ["movie", "series"], "idPrefixes": ["tt"]},
            {"name": "subtitles", "types": ["movie"]},
            "addon_catalog",
            {"types": ["movie"]}
          ],
          "catalogs": [{"type": "movie", "id": "top"}],
          "behaviorHints": {"adult": false, "p2p": false, "configurable": false}
        }
        """#.utf8)
        let manifest = try JSONDecoder().decode(AppleStremioManifest.self, from: payload)
        #expect(manifest.resources == ["catalog", "meta", "subtitles", "addon_catalog"])
        #expect(manifest.catalogs.map(\.id) == ["top"])
        #expect(manifest.version == nil)
        #expect(manifest.logoURL == nil)
        #expect(!manifest.requiresConfiguration)
    }

    @Test func manifestWithOnlyRequiredFieldsDecodes() throws {
        let manifest = try JSONDecoder().decode(
            AppleStremioManifest.self,
            from: Data(#"{"id":"fixture.minimal","name":"Minimal"}"#.utf8)
        )
        #expect(manifest.id == "fixture.minimal")
        #expect(manifest.resources.isEmpty)
        #expect(manifest.catalogs.isEmpty)
    }

    // MARK: Every failing add names a reason

    @Test func httpFailuresNameTheStatus() async {
        await #expect(throws: AppleManifestClientError.requestFailed(403)) {
            try await statusClient(403).load(rottenTomatoesManifest)
        }
        #expect(AppleManifestClientError.requestFailed(403).errorDescription
            == "The manifest request failed with HTTP 403.")
    }

    @Test func nonManifestBodiesNameTheirShapeProblem() async {
        await #expect(throws: AppleManifestClientError.manifestNotJSON) {
            try await bodyClient("<!doctype html><html><body>Configure me</body></html>").load(streamingCatalogsManifest)
        }
        await #expect(throws: AppleManifestClientError.manifestNotObject) {
            try await bodyClient(#"[{"id":"fixture","name":"List"}]"#).load(streamingCatalogsManifest)
        }
        await #expect(throws: AppleManifestClientError.manifestFieldWrongType("id", "text")) {
            try await bodyClient(#"{"id":42,"name":"Number ID"}"#).load(streamingCatalogsManifest)
        }
        await #expect(throws: AppleManifestClientError.manifestFieldWrongType("catalogs", "a list")) {
            try await bodyClient(#"{"id":"fixture","name":"Object Catalogs","catalogs":{"type":"movie"}}"#)
                .load(streamingCatalogsManifest)
        }
        await #expect(throws: AppleManifestClientError.manifestMissingField("name")) {
            try await bodyClient(#"{"id":"fixture","resources":["catalog"]}"#).load(streamingCatalogsManifest)
        }
        #expect(AppleManifestClientError.manifestNotObject.errorDescription == "The manifest is not a JSON object.")
        #expect(AppleManifestClientError.manifestFieldWrongType("catalogs", "a list").errorDescription
            == "The manifest's \"catalogs\" is not a list.")
    }

    @Test func liveFixturesPassTheClientEndToEnd() async throws {
        for (address, fixture, id) in [
            (streamingCatalogsManifest, "addon-streaming-catalogs-manifest.json", "pw.ers.netflix-catalog"),
            (rottenTomatoesManifest, "addon-rottentomatoes-manifest.json", "pw.ers.rottentomatoes"),
            (elfhostedManifest, "addon-tmdb-configured-manifest.json", "tmdb-addon"),
        ] {
            let body = try edgeCaseFixture(fixture)
            let client = AppleManifestClient(
                loader: { url in
                    #expect(url.absoluteString == address)
                    let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
                    return (body, response)
                },
                sleeper: { _ in }
            )
            let (url, manifest) = try await client.load(address)
            #expect(url.absoluteString == address)
            #expect(manifest.id == id)
        }
    }
}
