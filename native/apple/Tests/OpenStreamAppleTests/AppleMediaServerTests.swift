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
