import Testing
import Foundation
@testable import OpenStreamApple

@Suite("AppleMediaServerClient Tests")
struct AppleMediaServerTests {

    let baseURL = URL(string: "https://fixture.example/jellyfin/")!

    @Test("publicInfo parses JSON and infers Jellyfin")
    func testPublicInfoJellyfin() async throws {
        let client = AppleMediaServerClient(loader: { req in
            #expect(req.url?.absoluteString == "https://fixture.example/jellyfin/System/Info/Public")
            let json = """
            {
                "ServerName": "My Server",
                "Version": "10.8.10",
                "Id": "abc1234",
                "ProductName": "Jellyfin Server"
            }
            """
            return (json.data(using: .utf8)!, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })

        let info = try await client.publicInfo(baseURL: baseURL)
        #expect(info.serverName == "My Server")
        #expect(info.detectedKind == .jellyfin)
    }

    @Test("authenticate sends body, headers, and escapes quotes")
    func testAuthenticate() async throws {
        let client = AppleMediaServerClient(loader: { req in
            #expect(req.url?.absoluteString == "https://fixture.example/jellyfin/" + "Users/AuthenticateByName")
            #expect(req.httpMethod == "POST")
            #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")
            
            let auth = req.value(forHTTPHeaderField: "Authorization")
            let embyAuth = req.value(forHTTPHeaderField: "X-Emby-Authorization")
            #expect(auth != nil)
            #expect(auth == embyAuth)
            #expect(auth?.contains("MediaBrowser Client=\"OpenStream\"") == true)
            
            let body = try! JSONDecoder().decode([String: String].self, from: req.httpBody!)
            #expect(body["Username"] == "user")
            #expect(body["Pw"] == "pass")

            let json = """
            {
                "User": { "Id": "u1", "Name": "user" },
                "AccessToken": "token1",
                "ServerId": "s1"
            }
            """
            return (json.data(using: .utf8)!, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, deviceID: "d1", clientName: "OpenStream", deviceName: "Test\"Device", appVersion: "1.0")

        let session = try await client.authenticate(baseURL: baseURL, kind: .jellyfin, username: "user", password: "pass")
        #expect(session.accessToken == "token1")
        #expect(session.userID == "u1")
        #expect(session.serverID == "s1")
    }

    @Test("authenticate returns invalidCredentials on 401")
    func testAuthenticate401() async throws {
        let client = AppleMediaServerClient(loader: { req in
            return (Data(), HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
        })
        
        await #expect(throws: AppleMediaServerError.invalidCredentials) {
            _ = try await client.authenticate(baseURL: baseURL, kind: .jellyfin, username: "user", password: "pass")
        }
    }

    @Test("authenticate returns malformedResponse for bad JSON")
    func testAuthenticateBadJSON() async throws {
        let client = AppleMediaServerClient(loader: { req in
            return (Data("Not JSON".utf8), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        
        await #expect(throws: AppleMediaServerError.malformedResponse) {
            _ = try await client.authenticate(baseURL: baseURL, kind: .jellyfin, username: "user", password: "pass")
        }
    }
}

@Suite("AppleMediaServerClient QuickConnect Tests")
struct AppleMediaServerQuickConnectTests {
    let baseURL = URL(string: "https://fixture.example/jellyfin/")!

    @Test(arguments: [404, 405])
    func quickConnectUnsupportedFallsBackToPassword(_ status: Int) async throws {
        let client = AppleMediaServerClient(loader: { request in
            let url = try #require(request.url)
            return (Data(), try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)))
        })
        #expect(try await client.quickConnectEnabled(baseURL: baseURL) == false)
    }

    @Test func quickConnectMalformedSupportIsNotEnabled() async throws {
        let client = AppleMediaServerClient(loader: { request in
            let url = try #require(request.url)
            return (Data("unknown".utf8), try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        })
        await #expect(throws: AppleMediaServerError.malformedResponse) {
            try await client.quickConnectEnabled(baseURL: baseURL)
        }
    }

    @Test("quickConnect flows")
    func testQuickConnect() async throws {
        let client = AppleMediaServerClient(loader: { req in
            let ok = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            switch req.url?.path ?? "" {
            case "/jellyfin/QuickConnect/Enabled":
                #expect(req.url?.absoluteString == "https://fixture.example/jellyfin/QuickConnect/Enabled")
                return ("true".data(using: .utf8)!, ok)
            case "/jellyfin/QuickConnect/Initiate":
                return ("{\"Secret\":\"sec\",\"Code\":\"123\"}".data(using: .utf8)!, ok)
            case "/jellyfin/QuickConnect/Connect":
                #expect(req.url?.absoluteString == "https://fixture.example/jellyfin/QuickConnect/Connect?secret=sec")
                return ("{\"Authenticated\":true}".data(using: .utf8)!, ok)
            case "/jellyfin/" + "Users/AuthenticateWithQuickConnect":
                let body = try JSONDecoder().decode([String: String].self, from: req.httpBody ?? Data())
                #expect(body["Secret"] == "sec")
                let json = """
                {
                    "User": { "Id": "u1", "Name": "user" },
                    "AccessToken": "token1",
                    "ServerId": "s1"
                }
                """
                return (json.data(using: .utf8)!, ok)
            default:
                Issue.record("unexpected request \(req.url?.path ?? "")")
                return (Data(), HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
            }
        })

        let enabled = try await client.quickConnectEnabled(baseURL: baseURL)
        #expect(enabled)

        let ticket = try await client.quickConnectInitiate(baseURL: baseURL)
        #expect(ticket.secret == "sec")

        let state = try await client.quickConnectState(baseURL: baseURL, secret: ticket.secret)
        #expect(state)

        let session = try await client.authenticateWithQuickConnect(baseURL: baseURL, secret: ticket.secret)
        #expect(session.accessToken == "token1")
    }
}

@Suite("AppleMediaServerClient Emby Connect Tests")
struct AppleMediaServerEmbyConnectTests {
    @Test("Emby connect flow")
    func testEmbyConnect() async throws {
        let client = AppleMediaServerClient(loader: { req in
            let ok = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            switch (req.url?.host ?? "", req.url?.path ?? "") {
            case ("connect.emby.media", "/service/user/authenticate"):
                #expect(req.value(forHTTPHeaderField: "X-Application") == "OpenStream/1.0")
                let bodyStr = String(data: req.httpBody ?? Data(), encoding: .utf8) ?? ""
                #expect(bodyStr.contains("nameOrEmail=user@example.com"))
                #expect(bodyStr.contains("rawpw=pass"))
                return ("{\"AccessToken\":\"token1\",\"User\":{\"Id\":\"u1\"}}".data(using: .utf8)!, ok)
            case ("connect.emby.media", "/service/servers"):
                #expect(req.url?.absoluteString == "https://connect.emby.media/service/servers?userId=u1")
                #expect(req.value(forHTTPHeaderField: "X-Connect-UserToken") == "token1")
                let json = """
                [
                    {
                        "Id": "s1",
                        "Name": "Server 1",
                        "Url": "",
                        "LocalAddress": "http://fixture.example:8096",
                        "AccessKey": "key1"
                    }
                ]
                """
                return (json.data(using: .utf8)!, ok)
            case ("fixture.example", "/Connect/Exchange"):
                #expect(req.url?.absoluteString == "http://fixture.example:8096/Connect/Exchange?format=json&ConnectUserId=u1")
                #expect(req.value(forHTTPHeaderField: "X-Emby-Token") == "key1")
                return ("{\"LocalUserId\":\"lu1\",\"AccessToken\":\"ltoken1\"}".data(using: .utf8)!, ok)
            default:
                Issue.record("unexpected request \(req.url?.absoluteString ?? "")")
                return (Data(), HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
            }
        }, appVersion: "1.0")

        let account = try await client.embyConnectSignIn(email: "user@example.com", password: "pass")
        #expect(account.userID == "u1")

        let servers = try await client.embyConnectServers(account: account)
        #expect(servers.count == 1)
        #expect(servers[0].localAddress == "http://fixture.example:8096")

        let session = try await client.embyConnectExchange(server: servers[0], account: account)
        #expect(session.kind == .emby)
        #expect(session.baseURL.absoluteString == "http://fixture.example:8096")
        #expect(session.userID == "lu1")
        #expect(session.accessToken == "ltoken1")
    }
}

private final class MediaServerCredentialStore: AppleCredentialStoring {
    var values: [String: String] = [:]
    var removals: [String] = []
    func string(for account: String) throws -> String? { values[account] }
    func set(_ value: String, for account: String) throws { values[account] = value }
    func remove(_ account: String) throws { removals.append(account); values.removeValue(forKey: account) }
}

@Suite("AppleSourceStore MediaServer Tests")
struct AppleSourceStoreMediaServerTests {
    @Test("addMediaServer, duplicate handling, and removal")
    @MainActor
    func testStore() throws {
        let suite = "openstream.tests.mediaServer.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let keychain = MediaServerCredentialStore()
        let documents = FileManager.default.temporaryDirectory
            .appendingPathComponent("openstream-media-server-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: documents) }
        let store = AppleSourceStore(defaults: defaults, keychain: keychain, documentsDirectory: documents)
        let session1 = AppleMediaServerSession(kind: .jellyfin, baseURL: URL(string: "https://fixture.example/jf")!, accessToken: "t1", userID: "u1")

        let source1 = try store.addMediaServer(kind: .jellyfin, name: "My JF", session: session1)
        #expect(source1.kind == .mediaServer)
        #expect(source1.serverKind == .jellyfin)
        let reference = try #require(source1.credentialReference)
        #expect(keychain.values[reference] != nil)
        #expect(try store.mediaServerSession(for: source1) == session1)

        // Same kind, host and user: updated in place, not duplicated.
        let session2 = AppleMediaServerSession(kind: .jellyfin, baseURL: URL(string: "https://FIXTURE.example/jf")!, accessToken: "t2", userID: "u1")
        let source2 = try store.addMediaServer(kind: .jellyfin, name: "Updated JF", session: session2)
        #expect(store.sources.filter { $0.kind == .mediaServer }.count == 1)
        #expect(source2.id == source1.id)
        #expect(source2.name == "Updated JF")
        #expect(try store.mediaServerSession(for: source2) == session2)

        // A different user on the same server is a second source.
        let session3 = AppleMediaServerSession(kind: .jellyfin, baseURL: URL(string: "https://fixture.example/jf")!, accessToken: "t3", userID: "u2")
        let source3 = try store.addMediaServer(kind: .jellyfin, name: "Second user", session: session3)
        #expect(source3.id != source1.id)
        #expect(store.sources.filter { $0.kind == .mediaServer }.count == 2)

        // Removal clears the credential now or queues it for the next launch.
        #expect(store.remove(id: source2.id))
        #expect(!store.sources.contains { $0.id == source2.id })
        let pending = defaults.stringArray(forKey: "openstream.sources.v1.pending-keychain-removals") ?? []
        #expect(keychain.values[reference] == nil || pending.contains(reference))
    }

    @Test("decoding v1-style JSON without serverKind succeeds")
    func testDecodeV1Source() throws {
        let json = """
        {
            "id": "123e4567-e89b-12d3-a456-426614174000",
            "kind": "mediaServer",
            "name": "Old Server",
            "url": "https://fixture.example",
            "capabilities": []
        }
        """
        let source = try JSONDecoder().decode(AppleSource.self, from: json.data(using: .utf8)!)
        #expect(source.kind == .mediaServer)
        #expect(source.serverKind == nil)
    }
}

/// The scheme and timeout of each request the loader saw, in order.
private final class AppleMediaServerTimeoutLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [[String: TimeInterval]] = []
    var entries: [[String: TimeInterval]] { lock.withLock { storage } }
    func record(_ request: URLRequest) {
        lock.withLock { storage.append([request.url?.scheme ?? "-": request.timeoutInterval]) }
    }
}

/// Answers `http://fixture.example/…` with a 301 to the same path on https,
/// and the https `System/Info/Public` with Jellyfin's public info, so the
/// real URLSession redirect handling runs.
private final class AppleMediaServerRedirectStub: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "fixture.example" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        if components.scheme == "http" {
            components.scheme = "https"
            let target = components.url!
            let redirect = HTTPURLResponse(url: url, statusCode: 301, httpVersion: "HTTP/1.1",
                                           headerFields: ["Location": target.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: redirect)
            return
        }
        let body = Data(#"{"ServerName":"Rill","Version":"10.10.0","Id":"fixture","ProductName":"Jellyfin Server"}"#.utf8)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite("Media server address: scheme and redirects")
struct AppleMediaServerAddressTests {
    @Test("No scheme tries https first, then http; a typed scheme is kept")
    func candidateOrder() {
        #expect(AppleMediaServerFormPolicy.candidateBaseURLs("fixture.example").map(\.absoluteString)
            == ["https://fixture.example", "http://fixture.example"])
        #expect(AppleMediaServerFormPolicy.candidateBaseURLs("10.0.0.20:8096").map(\.absoluteString)
            == ["https://10.0.0.20:8096", "http://10.0.0.20:8096"])
        #expect(AppleMediaServerFormPolicy.candidateBaseURLs("http://fixture.example:8096").map(\.absoluteString)
            == ["http://fixture.example:8096"])
        #expect(AppleMediaServerFormPolicy.candidateBaseURLs("not a url").isEmpty)
    }

    @Test("https that cannot connect falls back to http")
    func fallsBackToHTTP() async throws {
        let client = AppleMediaServerClient(loader: { request in
            guard request.url?.scheme == "http" else { throw URLError(.cannotConnectToHost) }
            let body = Data(#"{"ServerName":"LAN"}"#.utf8)
            return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, deviceID: "fixture")
        let resolved = try await client.resolveBaseURL("10.0.0.20:8096")
        #expect(resolved.baseURL.absoluteString == "http://10.0.0.20:8096/")
        #expect(resolved.info.serverName == "LAN")
    }

    @Test("The guessed https gets a short timeout; http and a typed scheme keep the default")
    func guessedHTTPSTimesOutQuickly() async throws {
        let timeouts = AppleMediaServerTimeoutLog()
        let client = AppleMediaServerClient(loader: { request in
            timeouts.record(request)
            guard request.url?.scheme == "http" else { throw URLError(.timedOut) }
            let body = Data(#"{"ServerName":"LAN"}"#.utf8)
            return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, deviceID: "fixture")
        let defaultTimeout = URLRequest(url: URL(string: "http://fixture.example")!).timeoutInterval
        let resolved = try await client.resolveBaseURL("10.0.0.20:8096")
        #expect(resolved.baseURL.absoluteString == "http://10.0.0.20:8096/")
        #expect(timeouts.entries == [["https": AppleMediaServerClient.guessTimeout], ["http": defaultTimeout]])

        _ = try? await client.resolveBaseURL("https://10.0.0.20:8096")
        #expect(timeouts.entries.last == ["https": defaultTimeout])
    }

    @Test("https that answers with an error does not fall back to http")
    func keepsHTTPSServerError() async {
        let client = AppleMediaServerClient(loader: { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!)
        }, deviceID: "fixture")
        await #expect(throws: AppleMediaServerError.server(status: 503)) {
            try await client.resolveBaseURL("fixture.example")
        }
    }

    @Test("The base is the address the server redirected to")
    func adoptsRedirect() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AppleMediaServerRedirectStub.self]
        let session = URLSession(configuration: configuration)
        let client = AppleMediaServerClient(loader: { try await session.data(for: $0) }, deviceID: "fixture")
        let resolved = try await client.resolveBaseURL("http://fixture.example/jellyfin")
        #expect(resolved.baseURL.absoluteString == "https://fixture.example/jellyfin/")
        #expect(resolved.info.serverName == "Rill")
    }

    @Test("Base URL from the reached address keeps the path prefix and drops the query")
    func baseFromReachedURL() {
        let requested = URL(string: "http://fixture.example")!
        #expect(AppleMediaServerClient.baseURL(reached: URL(string: "https://fixture.example/jf/System/Info/Public?x=1"),
                                               requested: requested).absoluteString == "https://fixture.example/jf/")
        #expect(AppleMediaServerClient.baseURL(reached: URL(string: "https://fixture.example/login"),
                                               requested: requested) == requested)
        #expect(AppleMediaServerClient.baseURL(reached: nil, requested: requested) == requested)
    }

    @Test("An unreadable reply traces method, path, status and type, never the query")
    func malformedTraceLine() {
        let path = "/" + ["Users", "AuthenticateByName"].joined(separator: "/")
        var request = URLRequest(url: URL(string: "http://fixture.example\(path)?api_key=secret")!)
        request.httpMethod = "POST"
        let response = HTTPURLResponse(url: URL(string: "https://fixture.example\(path)")!,
                                       statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/html"])
        let line = AppleMediaServerClient.malformedTraceLine(request: request, response: response)
        #expect(line == "media server reply made no sense: POST \(path) status=200 type=text/html landed=https://…\(path)")
        #expect(!line.contains("secret"))
        #expect(AppleMediaServerClient.malformedTraceLine(request: request, response: nil)
            == "media server reply made no sense: POST \(path) no HTTP response")
    }

    @Test("A sign-in reply without a session is malformed")
    func authenticateMalformed() async {
        let client = AppleMediaServerClient(loader: { request in
            (Data("<html></html>".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                                         headerFields: ["Content-Type": "text/html"])!)
        }, deviceID: "fixture")
        await #expect(throws: AppleMediaServerError.malformedResponse) {
            try await client.authenticate(baseURL: URL(string: "https://fixture.example/")!, kind: .jellyfin,
                                          username: "fixture", password: "fixture")
        }
    }
}
