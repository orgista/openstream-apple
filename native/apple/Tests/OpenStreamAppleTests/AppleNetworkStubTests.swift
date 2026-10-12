import Foundation
import Testing
@testable import OpenStreamApple

/// `-OpenStreamStubNetwork <dir>`: every loader request is answered from
/// `<dir>/<host>/<path>.json`; a miss fails loudly and never reaches the
/// network. Task-local roots keep parallel loader tests isolated.
@Suite("Network stub", .serialized)
struct AppleNetworkStubTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("network-stub-\(UUID().uuidString)", isDirectory: true)
        let addon = root.appendingPathComponent("fixture.example/catalog/movie", isDirectory: true)
        try FileManager.default.createDirectory(at: addon, withIntermediateDirectories: true)
        try Data(#"{"id":"org.openstream.fixture"}"#.utf8)
            .write(to: root.appendingPathComponent("fixture.example/manifest.json"))
        try Data(#"{"metas":[]}"#.utf8).write(to: addon.appendingPathComponent("top.json"))
        let tmdb = root.appendingPathComponent("api.themoviedb.org/3/search", isDirectory: true)
        try FileManager.default.createDirectory(at: tmdb, withIntermediateDirectories: true)
        try Data(#"{"results":[]}"#.utf8).write(to: tmdb.appendingPathComponent("movie.json"))
        return root
    }

    @Test func pathsMapToFixtureFiles() throws {
        let root = URL(fileURLWithPath: "/stubs", isDirectory: true)
        func mapped(_ value: String) -> String? {
            AppleNetworkStubPolicy.fixtureURL(for: URL(string: value)!, root: root)?.path
        }
        #expect(mapped("https://fixture.example/manifest.json") == "/stubs/fixture.example/manifest.json")
        #expect(mapped("https://fixture.example/catalog/movie/top.json") == "/stubs/fixture.example/catalog/movie/top.json")
        // Query strings fold away, so a credential never names a file.
        #expect(mapped("https://api.themoviedb.org/3/search/movie?query=x&api_key=k") == "/stubs/api.themoviedb.org/3/search/movie.json")
        #expect(mapped("http://host.example/player_api.php?username=u&password=p") == "/stubs/host.example/player_api.php.json")
        #expect(mapped("https://host.example/../../etc/passwd") == nil)
        #expect(AppleNetworkStubPolicy.missDescription(for: URL(string: "http://h.example/player_api.php?password=p")!)
            == "network stub: no fixture for h.example/player_api.php")
    }

    @Test func loaderServesFixturesAndRejectsMisses() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try await AppleNetworkStub.$testRoot.withValue(root) {

            let request = URLRequest(url: URL(string: "https://fixture.example/catalog/movie/top.json")!)
            let (data, response) = try await AppleBoundedHTTPDataLoader.load(request, maximumBytes: 1_000)
            #expect(String(decoding: data, as: UTF8.self) == #"{"metas":[]}"#)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)

            let tmdb = try await AppleTMDBClient.liveLoader(
                URLRequest(url: URL(string: "https://api.themoviedb.org/3/search/movie?query=x&api_key=k")!))
            #expect(String(decoding: tmdb.0, as: UTF8.self) == #"{"results":[]}"#)

            let miss = URLRequest(url: URL(string: "https://fixture.example/catalog/movie/missing.json")!)
            await #expect(throws: AppleNetworkStub.Error.unmatched("network stub: no fixture for fixture.example/catalog/movie/missing.json")) {
                _ = try await AppleBoundedHTTPDataLoader.load(miss, maximumBytes: 1_000)
            }
            await #expect(throws: AppleBoundedHTTPError.responseTooLarge) {
                _ = try await AppleBoundedHTTPDataLoader.load(request, maximumBytes: 4)
            }
        }
    }

    @Test func devSourcesBesideTheFixturesAreFoundOnlyWhenPresent() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try AppleNetworkStub.$testRoot.withValue(root) {
            #expect(AppleNetworkStub.devSourcesURL == nil)
            try Data(#"{"version":1,"sources":[]}"#.utf8).write(to: root.appendingPathComponent("dev-sources.json"))
            #expect(AppleNetworkStub.devSourcesURL?.lastPathComponent == "dev-sources.json")
        }
    }
}
