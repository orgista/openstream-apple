#if DEBUG
import Foundation


/// Where a stubbed request's answer lives on disk: `<root>/<host>/<path>`,
/// with `.json` appended when the path does not already end in it. The query
/// string is ignored, so `/3/search/movie?query=x&api_key=…` reads
/// `api.themoviedb.org/3/search/movie.json`; a search may have its own answer
/// in `api.themoviedb.org/3/search/movie/query=x.json` (lower-cased).
/// Pure: the file system is the caller's.
public enum AppleNetworkStubPolicy {
    public static let launchKey = "OpenStreamStubNetwork"

    static func isLiveFixtureURL(_ url: URL, base: URL) -> Bool {
        base.scheme == "http" && base.host == "127.0.0.1" && base.user == nil && base.password == nil
            && url.scheme == base.scheme && url.host == base.host && url.port == base.port
            && url.user == nil && url.password == nil
    }

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

    /// The search-specific answer for a request with a `query` item, which
    /// `AppleNetworkStub` reads before the path's own fixture.
    public static func searchFixtureURL(for url: URL, root: URL) -> URL? {
        guard let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "query" })?.value?.lowercased(),
              !query.isEmpty, !query.contains("/"), query != "..", query != ".",
              let fixture = fixtureURL(for: url, root: root) else { return nil }
        return fixture.deletingPathExtension().appendingPathComponent("query=\(query).json")
    }
}

/// Serves every control-plane request from fixture files instead of the
/// network (`-OpenStreamStubNetwork <dir>`, Debug builds only): TMDB, IPTV
/// playlists and guides, Xtream. Media never comes through here — AVPlayer and
/// the engine do not use the loader — so playback keeps its 127.0.0.1 fixture
/// servers. A request with no fixture
/// fails loudly and never falls through to the network.
public enum AppleNetworkStub {
    public enum Error: Swift.Error, Equatable, Sendable {
        case unmatched(String)
    }

    /// Overrides belong to one test task and its children, never other suites.
    @TaskLocal static var testRoot: URL?

    /// The root from the launch argument, read once. Tests scope `testRoot`.
    private static let launchRoot: URL? = {
        guard let path = UserDefaults.standard.string(forKey: AppleNetworkStubPolicy.launchKey),
              !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }()

    public static var root: URL? { testRoot ?? launchRoot }

    public static var isActive: Bool { root != nil }

    static func usesLiveFixtureOrigin(_ request: URLRequest) -> Bool {
        guard let raw = UserDefaults.standard.string(forKey: "OpenStreamStubLiveBase"),
              let base = URL(string: raw), let url = request.url else { return false }
        return AppleNetworkStubPolicy.isLiveFixtureURL(url, base: base)
    }

    /// `-OpenStreamStubPlaylistStall <seconds>`: stubbed playlists answer this
    /// late, so a UI test sees Live's loading state every time.
    static func stall(for request: URLRequest) -> Duration? {
        let seconds = UserDefaults.standard.double(forKey: "OpenStreamStubPlaylistStall")
        guard seconds > 0, request.url?.pathExtension.lowercased() == "m3u" else { return nil }
        return .seconds(seconds)
    }

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
        let search = AppleNetworkStubPolicy.searchFixtureURL(for: url, root: root).flatMap { try? Data(contentsOf: $0) }
        guard let fixtureData = search ?? AppleNetworkStubPolicy.fixtureURL(for: url, root: root)
                .flatMap({ try? Data(contentsOf: $0) }) else {
            let line = AppleNetworkStubPolicy.missDescription(for: url)
            AppleInteractionTrace.record(.network, line)
            throw Error.unmatched(line)
        }
        var data = fixtureData
        // Only the E2E route rewrites fictional media hosts to its loopback server.
        // Control-plane requests and artwork still come from the stub files.
        if let base = UserDefaults.standard.string(forKey: "OpenStreamStubMediaBase"),
           let mediaURL = URL(string: base), mediaURL.scheme == "http",
           mediaURL.host == "127.0.0.1", mediaURL.user == nil, mediaURL.password == nil,
           var text = String(data: data, encoding: .utf8) {
            for path in ["/media/", "/live/", "/slow/", "/e2e-download/"] {
                text = text.replacingOccurrences(of: "https://fixture.example" + path, with: base + path)
            }
            data = Data(text.utf8)
        }
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json", "Content-Length": "\(data.count)"]
        ) ?? URLResponse(url: url, mimeType: "application/json", expectedContentLength: data.count, textEncodingName: nil)
        return (data, response)
    }
}
#endif
