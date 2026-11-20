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
        let iptv = root.appendingPathComponent("fixture.example/iptv", isDirectory: true)
        try FileManager.default.createDirectory(at: iptv, withIntermediateDirectories: true)
        try Data(#"{"user_info":{"auth":1}}"#.utf8).write(to: iptv.appendingPathComponent("player_api.php.json"))
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
        #expect(mapped("https://fixture.example/iptv/player_api.php") == "/stubs/fixture.example/iptv/player_api.php.json")
        #expect(mapped("https://fixture.example/iptv/guide.json") == "/stubs/fixture.example/iptv/guide.json")
        // Query strings fold away, so a credential never names a file.
        #expect(mapped("https://api.themoviedb.org/3/search/movie?query=x&api_key=k") == "/stubs/api.themoviedb.org/3/search/movie.json")
        #expect(mapped("http://host.example/player_api.php?username=u&password=p") == "/stubs/host.example/player_api.php.json")
        #expect(mapped("https://host.example/../../etc/passwd") == nil)
        #expect(AppleNetworkStubPolicy.searchFixtureURL(for: URL(string: "https://api.themoviedb.org/3/search/movie?query=Stub%20Movie&api_key=k")!,
                                                        root: root)?.path
            == "/stubs/api.themoviedb.org/3/search/movie/query=stub movie.json")
        #expect(AppleNetworkStubPolicy.searchFixtureURL(for: URL(string: "https://api.themoviedb.org/3/search/movie?query=a/b")!, root: root) == nil)
        #expect(AppleNetworkStubPolicy.searchFixtureURL(for: URL(string: "https://api.themoviedb.org/3/movie/2")!, root: root) == nil)
        #expect(AppleNetworkStubPolicy.missDescription(for: URL(string: "http://h.example/player_api.php?password=p")!)
            == "network stub: no fixture for h.example/player_api.php")
    }

    @Test func loaderServesFixturesAndRejectsMisses() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try await AppleNetworkStub.$testRoot.withValue(root) {

            let request = URLRequest(url: URL(string: "https://fixture.example/iptv/player_api.php?username=x")!)
            let (data, response) = try await AppleBoundedHTTPDataLoader.load(request, maximumBytes: 1_000)
            #expect(String(decoding: data, as: UTF8.self) == #"{"user_info":{"auth":1}}"#)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)

            let tmdb = try await AppleTMDBClient.liveLoader(
                URLRequest(url: URL(string: "https://api.themoviedb.org/3/search/movie?query=x&api_key=k")!))
            #expect(String(decoding: tmdb.0, as: UTF8.self) == #"{"results":[]}"#)

            let named = root.appendingPathComponent("api.themoviedb.org/3/search/movie", isDirectory: true)
            try FileManager.default.createDirectory(at: named, withIntermediateDirectories: true)
            try Data(#"{"results":[{"id":2}]}"#.utf8).write(to: named.appendingPathComponent("query=stub.json"))
            let search = try await AppleTMDBClient.liveLoader(
                URLRequest(url: URL(string: "https://api.themoviedb.org/3/search/movie?query=Stub&api_key=k")!))
            #expect(String(decoding: search.0, as: UTF8.self) == #"{"results":[{"id":2}]}"#)

            let miss = URLRequest(url: URL(string: "https://fixture.example/iptv/missing.json")!)
            await #expect(throws: AppleNetworkStub.Error.unmatched("network stub: no fixture for fixture.example/iptv/missing.json")) {
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
