import Foundation


/// Where a stubbed request's answer lives on disk: `<root>/<host>/<path>`,
/// with `.json` appended when the path does not already end in it. The query
/// string is ignored, so `/3/search/movie?query=x&api_key=…` reads
/// `api.themoviedb.org/3/search/movie.json`. Pure: the file system is the
/// caller's.
public enum AppleNetworkStubPolicy {
    public static let launchKey = "OpenStreamStubNetwork"

    /// Trace wording for a miss, with no query string, so a credential in a
    /// `player_api.php?username=…` request never reaches the log.
    public static func missDescription(for url: URL) -> String {
        "network stub: no fixture for \(url.host ?? "?")\(url.path)"
    }

    public static func fixtureURL(for url: URL, root: URL) -> URL? {
        guard let host = url.host, !host.isEmpty else { return nil }
        var path = url.path
        if path.isEmpty || path == "/" { path = "/index" }
        if !path.hasSuffix(".json") { path += ".json" }
        // Stay inside the root: a `..` segment in a request is not a fixture.
        guard !path.split(separator: "/").contains("..") else { return nil }
        return root.appendingPathComponent(host).appendingPathComponent(String(path.dropFirst()))
    }
}

/// Serves every control-plane request from fixture files instead of the
/// network (`-OpenStreamStubNetwork <dir>`, Debug builds only): add-on
/// manifests, catalogs, meta and streams, TMDB, Xtream, debrid. Media never
/// comes through here — AVPlayer and the engine do not use the loader — so
/// playback keeps its 127.0.0.1 fixture servers. A request with no fixture
/// fails loudly and never falls through to the network.
public enum AppleNetworkStub {
    public enum Error: Swift.Error, Equatable, Sendable {
        case unmatched(String)
    }

    /// Overrides belong to one test task and its children, never other suites.
    @TaskLocal static var testRoot: URL?

    /// The root from the launch argument, read once. Tests scope `testRoot`.
    private static let launchRoot: URL? = {
        #if DEBUG
        guard let path = UserDefaults.standard.string(forKey: AppleNetworkStubPolicy.launchKey),
              !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
        #else
        return nil
        #endif
    }()

    public static var root: URL? { testRoot ?? launchRoot }

    public static var isActive: Bool { root != nil }

    /// `<root>/dev-sources.json` beside the fixtures: the sources a stubbed
    /// run should have, read in place and never deleted (it is a repo file).
    public static var devSourcesURL: URL? {
        guard let root else { return nil }
        let url = root.appendingPathComponent("dev-sources.json")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The fixture answer for `request`, or `Error.unmatched` with a trace
    /// line naming the missing file's request.
    static func response(for request: URLRequest, root: URL) throws -> (Data, URLResponse) {
        guard let url = request.url else { throw Error.unmatched("no url") }
        guard let fixture = AppleNetworkStubPolicy.fixtureURL(for: url, root: root),
              let data = try? Data(contentsOf: fixture) else {
            let line = AppleNetworkStubPolicy.missDescription(for: url)
            AppleInteractionTrace.record(.network, line)
            throw Error.unmatched(line)
        }
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json", "Content-Length": "\(data.count)"]
        ) ?? URLResponse(url: url, mimeType: "application/json", expectedContentLength: data.count, textEncodingName: nil)
        return (data, response)
    }
}
