import Testing

/// Counts loader calls from a Sendable closure without capturing a mutable var.
private final class PlexCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
}
import Foundation
@testable import OpenStreamApple

@Suite("ApplePlexClient Tests")
struct ApplePlexClientTests {
    @Test("PIN request headers/query and decode")
    func testRequestPIN() async throws {
        let client = ApplePlexClient(loader: { req in
            #expect(req.url?.absoluteString == "https://plex.tv/api/v2/pins?strong=false")
            #expect(req.httpMethod == "POST")
            #expect(req.value(forHTTPHeaderField: "X-Plex-Client-Identifier") == "test-client")
            #expect(req.value(forHTTPHeaderField: "Accept") == "application/json")
            
            let json = """
            {
                "id": 1234,
                "code": "ABCD",
                "expiresAt": "2026-09-18T10:00:00Z",
                "authToken": null
            }
            """
            return (json.data(using: .utf8)!, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, clientIdentifier: "test-client")
        
        let pin = try await client.requestPIN()
        #expect(pin.id == 1234)
        #expect(pin.code == "ABCD")
        #expect(pin.authToken == nil)
        #expect(pin.expiresAt != nil)
    }

    @Test("poll nil then token")
    func testPollPIN() async throws {
        let calls = PlexCallCounter()
        let client = ApplePlexClient(loader: { req in
            #expect(req.url?.absoluteString == "https://plex.tv/api/v2/pins/1234")
            let count = calls.next()
            let json: String
            if count == 1 {
                json = "{\"id\":1234,\"code\":\"ABCD\",\"authToken\":null}"
            } else {
                json = "{\"id\":1234,\"code\":\"ABCD\",\"authToken\":\"secret-token\"}"
            }
            return (json.data(using: .utf8)!, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, clientIdentifier: "test-client")
        
        let first = try await client.pollPIN(id: 1234)
        #expect(first == nil)
        
        let second = try await client.pollPIN(id: 1234)
        #expect(second == "secret-token")
    }

    @Test("account decode")
    func testAccount() async throws {
        let client = ApplePlexClient(loader: { req in
            #expect(req.url?.absoluteString == "https://plex.tv/api/v2/user")
            #expect(req.value(forHTTPHeaderField: "X-Plex-Token") == "t")
            let json = """
            {
                "id": 1,
                "username": "testuser",
                "email": "test@example.com",
                "title": "Test User"
            }
            """
            return (json.data(using: .utf8)!, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, clientIdentifier: "test-client")
        
        let acc = try await client.account(token: "t")
        #expect(acc.id == 1)
        #expect(acc.username == "testuser")
    }

    @Test("resources decode + isServer + preferredConnections order")
    func testResources() async throws {
        let client = ApplePlexClient(loader: { req in
            #expect(req.url?.absoluteString == "https://plex.tv/api/v2/resources?includeHttps=1&includeRelay=1&includeIPv6=0")
            let json = """
            [
                {
                    "name": "My Server",
                    "clientIdentifier": "s1",
                    "provides": "server,player",
                    "accessToken": "stoken",
                    "owned": true,
                    "connections": [
                        { "uri": "https://relay.plex.direct:443", "protocol": "https", "address": "1.1.1.1", "port": 443, "local": false, "relay": true },
                        { "uri": "http://10.0.0.1:32400", "protocol": "http", "address": "10.0.0.1", "port": 32400, "local": true, "relay": false },
                        { "uri": "https://10-0-0-1.plex.direct:32400", "protocol": "https", "address": "10.0.0.1", "port": 32400, "local": true, "relay": false },
                        { "uri": "http://10.0.0.1:32400", "protocol": "http", "address": "10.0.0.1", "port": 32400, "local": true, "relay": false },
                        { "uri": "https://remote.plex.direct:32400", "protocol": "https", "address": "2.2.2.2", "port": 32400, "local": false, "relay": false }
                    ]
                }
            ]
            """
            return (json.data(using: .utf8)!, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, clientIdentifier: "test-client")
        
        let res = try await client.resources(token: "t")
        #expect(res.count == 1)
        #expect(res[0].isServer)
        
        let conns = client.preferredConnections(for: res[0])
        #expect(conns.count == 4)
        #expect(conns[0].absoluteString == "https://10-0-0-1.plex.direct:32400")
        #expect(conns[1].absoluteString == "http://10.0.0.1:32400")
        #expect(conns[2].absoluteString == "https://remote.plex.direct:32400")
        #expect(conns[3].absoluteString == "https://relay.plex.direct:443")
    }

    @Test("firstReachableConnection skips a failing uri")
    func testFirstReachable() async throws {
        let client = ApplePlexClient(loader: { req in
            if req.url?.absoluteString.contains("fail") == true {
                throw URLError(.timedOut)
            }
            return (Data(), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, clientIdentifier: "test-client")
        
        let res = ApplePlexResource(name: "S", clientIdentifier: "S1", provides: "server", accessToken: "t", owned: true, connections: [
            ApplePlexConnection(uri: "http://fail.example", protocol: "http", address: "1", port: 1, local: true, relay: false),
            ApplePlexConnection(uri: "http://success.example", protocol: "http", address: "2", port: 2, local: true, relay: false)
        ])
        
        let url = await client.firstReachableConnection(for: res)
        #expect(url?.absoluteString == "http://success.example")
    }

    @Test("makeSession mapping and .unsupported without accessToken")
    func testMakeSession() throws {
        let client = ApplePlexClient(clientIdentifier: "test-client")
        let acc = ApplePlexAccount(id: 1, username: "user", email: nil, title: nil)
        let res1 = ApplePlexResource(name: "Server", clientIdentifier: "S1", provides: "server", accessToken: nil, owned: true, connections: [])
        
        #expect(throws: AppleMediaServerError.unsupported) {
            _ = try client.makeSession(resource: res1, connection: URL(string: "http://local")!, account: acc, accountToken: "at")
        }
        
        let res2 = ApplePlexResource(name: "Server", clientIdentifier: "S1", provides: "server", accessToken: "t", owned: true, connections: [])
        let session = try client.makeSession(resource: res2, connection: URL(string: "http://local")!, account: acc, accountToken: "at")
        
        #expect(session.kind == .plex)
        #expect(session.baseURL.absoluteString == "http://local")
        #expect(session.accessToken == "t")
        #expect(session.userID == "1")
        #expect(session.serverID == "S1")
        #expect(session.serverName == "Server")
        #expect(session.userName == "user")
        #expect(session.accountToken == "at")
    }
}

extension ApplePlexClientTests {
    @Test("Server endpoints")
    func testServerEndpoints() async throws {
        let client = ApplePlexClient(loader: { req in
            let path = req.url?.path ?? ""
            let ok = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            if path.contains("library/sections/1/all") {
                #expect(req.value(forHTTPHeaderField: "X-Plex-Container-Start") == "0")
                #expect(req.value(forHTTPHeaderField: "X-Plex-Container-Size") == "50")
                #expect(req.url?.query?.contains("type=1") == true)
                let json = """
                {
                    "MediaContainer": {
                        "totalSize": 100,
                        "Metadata": [
                            {
                                "ratingKey": "100",
                                "key": "/library/metadata/100",
                                "type": "movie",
                                "title": "The Movie",
                                "duration": 5400000,
                                "viewOffset": 120000,
                                "Guid": [
                                    {"id": "tmdb://603"},
                                    {"id": "imdb://tt0120737"}
                                ],
                                "Media": [
                                    {
                                        "Part": [
                                            { "key": "/library/parts/1/1/file.mkv", "container": "mkv", "file": "/data/file.mkv" }
                                        ]
                                    }
                                ]
                            }
                        ]
                    }
                }
                """
                return (json.data(using: .utf8)!, ok)
            } else if path.contains("library/sections") {
                let json = "{\"MediaContainer\":{\"Directory\":[{\"key\":\"1\",\"title\":\"Movies\",\"type\":\"movie\"}]}}"
                return (json.data(using: .utf8)!, ok)
            } else if path.contains("library/metadata/100/children") {
                return ("{\"MediaContainer\":{\"Metadata\":[]}}".data(using: .utf8)!, ok)
            } else if path.contains("library/onDeck") {
                return ("{\"MediaContainer\":{\"Metadata\":[]}}".data(using: .utf8)!, ok)
            } else if path.contains("library/recentlyAdded") {
                return ("{\"MediaContainer\":{\"Metadata\":[]}}".data(using: .utf8)!, ok)
            } else if path.contains(":/timeline") {
                #expect(req.url?.query?.contains("state=paused") == true)
                #expect(req.url?.query?.contains("time=60000") == true)
                return (Data(), ok)
            } else if path.contains(":/scrobble") {
                return (Data(), ok)
            }
            return (Data(), HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        }, clientIdentifier: "test-client")
        
        let session = AppleMediaServerSession(kind: .plex, baseURL: URL(string: "https://fixture.example:32400/")!, accessToken: "t", userID: "1")
        let sections = try await client.sections(session: session)
        #expect(sections.count == 1)
        #expect(sections[0].key == "1")
        
        let page = try await client.items(session: session, sectionKey: "1", kind: .movie, start: 0, size: 50)
        #expect(page.totalSize == 100)
        #expect(page.items.count == 1)
        
        let item = page.items[0]
        #expect(item.durationSeconds == 5400.0)
        #expect(item.viewOffsetSeconds == 120.0)
        #expect(item.tmdbID == "603")
        #expect(item.imdbID == "tt0120737")
        #expect(item.parts.count == 1)
        #expect(item.parts[0].key == "/library/parts/1/1/file.mkv")
        
        let direct = client.directPlayURL(session: session, part: item.parts[0])
        #expect(direct.absoluteString == "https://fixture.example:32400/library/parts/1/1/file.mkv?X-Plex-Token=t")
        
        let image = client.imageURL(session: session, path: "/library/metadata/100/thumb", width: 100, height: 100)
        #expect(image.absoluteString.contains("photo/:/transcode"))
        #expect(image.absoluteString.contains("url=/library/metadata/100/thumb"))
        
        try await client.reportTimeline(session: session, item: item, state: .paused, positionSeconds: 60)
        
        try await client.markPlayed(session: session, ratingKey: "100")
        
        _ = try await client.children(session: session, ratingKey: "100")
        _ = try await client.onDeck(session: session)
        _ = try await client.recentlyAdded(session: session, sectionKey: "1")
    }

    @Test("session round-trip with accountToken through JSONEncoder/Decoder and a stored session JSON without accountToken decoding")
    func testSessionRoundTrip() throws {
        let session1 = AppleMediaServerSession(kind: .plex, baseURL: URL(string: "http://local")!, accessToken: "t", userID: "1", accountToken: "at")
        let data = try JSONEncoder().encode(session1)
        let session2 = try JSONDecoder().decode(AppleMediaServerSession.self, from: data)
        #expect(session2.accountToken == "at")
        
        let oldJson = """
        {
            "kind": "plex",
            "baseURL": "http://local",
            "accessToken": "t",
            "userID": "1"
        }
        """
        let session3 = try JSONDecoder().decode(AppleMediaServerSession.self, from: oldJson.data(using: .utf8)!)
        #expect(session3.accountToken == nil)
    }
}
