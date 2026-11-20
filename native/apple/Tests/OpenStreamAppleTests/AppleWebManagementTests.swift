import Foundation
import Testing
import Darwin
@testable import OpenStreamApple

@Test func webManagementQRIncludesOnlyTheCurrentPairingCode() throws {
    let root = try #require(URL(string: "http://192.168.1.20:8090/"))
    let session = AppleWebManagementSession(
        url: root, friendlyURL: root, expiresAt: .now.addingTimeInterval(600),
        token: "private-token", pairingCode: "ABCD2345"
    )
    #expect(session.pairingURL.absoluteString == "http://192.168.1.20:8090/?pair=ABCD2345")
    #expect(session.friendlyURL == root)
    #expect(!session.pairingURL.absoluteString.contains(session.token))
}

@Test(arguments: ["a b", " ab ", "a\tb", "a\nb", "a\u{00a0}b"])
func xtreamCredentialSanitizerRemovesWhitespace(_ input: String) {
    #expect(AppleIPTVEndpointPolicy.sanitizeCredential(input) == "ab")
    #expect(throws: AppleIPTVError.credentialsContainWhitespace) {
        try AppleIPTVEndpointPolicy.validateCredentials(username: input, password: "valid")
    }
    #expect(throws: AppleIPTVError.credentialsContainWhitespace) {
        try AppleIPTVEndpointPolicy.validateCredentials(username: "valid", password: input)
    }
}

@MainActor
@Test func webManagementQueryPairingSurvivesRotationAndExpiresAfterInactivity() async throws {
    let suite = "openstream-web-sliding-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = AppleSourceStore(defaults: defaults)
    var now = Date()
    let server = AppleWebManagementServer(
        configuration: .init(preferredPort: 0, sessionDuration: 60, advertisesBonjour: false, advertisedHost: "127.0.0.1"),
        iptvClient: fixturePlaylistClient(),
        now: { now }
    )
    let active = try await server.start(sourceStore: store)
    defer { server.stop() }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpShouldSetCookies = false
    let browser = URLSession(configuration: configuration)
    defer { browser.invalidateAndCancel() }
    let (data, paired) = try await dataResponse(for: request(url: active.pairingURL), using: browser)
    #expect(paired.statusCode == 200)
    #expect(String(decoding: data, as: UTF8.self).contains("data-paired=\"true\""))
    let cookie = try pairingCookie(from: paired)
    #expect(paired.value(forHTTPHeaderField: "Set-Cookie")?.contains("HttpOnly") == true)
    #expect(server.connectedBrowsers.count == 1)
    #expect(server.session?.pairingCode != active.pairingCode)
    #expect(try await response(for: request(url: active.pairingURL), using: browser).statusCode == 403)

    var codeOnly = request(url: active.friendlyURL)
    codeOnly.httpMethod = "POST"
    codeOnly.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    var codeOnlyForm = playlistForm(name: "Session TV", url: "https://fixture.example/session.m3u")
    codeOnlyForm["pairingCode"] = try #require(server.session).pairingCode
    codeOnly.httpBody = encodedForm(codeOnlyForm)
    #expect(try await response(for: codeOnly, using: browser).statusCode == 401)
    #expect(store.sources.isEmpty)

    now = now.addingTimeInterval(61)
    var add = request(url: active.friendlyURL)
    add.httpMethod = "POST"
    add.setValue(cookie, forHTTPHeaderField: "Cookie")
    add.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    add.httpBody = encodedForm(playlistForm(name: "Session TV", url: "https://fixture.example/session.m3u"))
    #expect(try await response(for: add, using: browser).statusCode == 200)
    #expect(store.sources.count == 1)
    var page = request(url: active.friendlyURL)
    page.setValue(cookie, forHTTPHeaderField: "Cookie")
    for _ in 0 ..< 2 {
        now = now.addingTimeInterval(29 * 60)
        let (content, response) = try await dataResponse(for: page, using: browser)
        #expect(response.statusCode == 200)
        #expect(String(decoding: content, as: UTF8.self).contains("data-paired=\"true\""))
        #expect(server.connectedBrowsers.count == 1)
    }
    now = now.addingTimeInterval(30 * 60)
    let (ended, expired) = try await dataResponse(for: add, using: browser)
    #expect(expired.statusCode == 401)
    #expect(String(decoding: ended, as: UTF8.self).contains("Session ended — scan the code again"))
    #expect(server.connectedBrowsers.isEmpty)
    #expect(store.sources.count == 1)

    // Query and form pairing share the same single-use check. Two browsers
    // get distinct sessions; ending one cannot revoke the other.
    let next = try #require(server.session)
    var queryPair = request(url: next.pairingURL)
    queryPair.httpMethod = "POST"
    queryPair.httpBody = encodedForm(["action": "pair"])
    queryPair.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    let firstCookie = try pairingCookie(from: await response(for: queryPair, using: browser))
    let firstID = try #require(server.connectedBrowsers.first).id
    let secondCookie = try await pairBrowser(try #require(server.session), using: browser)
    #expect(firstCookie != secondCookie)
    #expect(server.connectedBrowsers.count == 2)
    server.endBrowser(id: firstID)
    add.setValue(firstCookie, forHTTPHeaderField: "Cookie")
    #expect(try await response(for: add, using: browser).statusCode == 401)
    page.setValue(secondCookie, forHTTPHeaderField: "Cookie")
    let (stillPaired, _) = try await dataResponse(for: page, using: browser)
    #expect(String(decoding: stillPaired, as: UTF8.self).contains("data-paired=\"true\""))
    server.endAllBrowsers()
    add.setValue(secondCookie, forHTTPHeaderField: "Cookie")
    #expect(try await response(for: add, using: browser).statusCode == 401)
}

@Test func webManagementTokenAndTrustRulesMatchTheLANContract() throws {
    let tokens = Set((0 ..< 32).map { _ in AppleWebManagementProtocol.makeToken() })
    #expect(tokens.count == 32)
    #expect(tokens.allSatisfy { token in
        token.count == 32 && token.utf8.allSatisfy { byte in
            (48 ... 57).contains(byte) || (97 ... 102).contains(byte)
        }
    })

    let token = try #require(tokens.first)
    let session = AppleWebManagementSession(
        url: URL(string: "http://192.168.1.20:11470/openstream?token=\(token)")!,
        friendlyURL: URL(string: "http://192.168.1.20:11470/")!,
        expiresAt: .now.addingTimeInterval(600),
        token: token
    )

    #expect(AppleWebManagementProtocol.isAllowedClient(host: "127.0.0.1"))
    #expect(!AppleWebManagementProtocol.isAllowedClient(host: "169.254.8.9"))
    #expect(!AppleWebManagementProtocol.isAllowedClient(host: "[fe80::2%en0]"))
    #expect(AppleWebManagementProtocol.isAllowedClient(host: "fd00::2"))
    #expect(!AppleWebManagementProtocol.isAllowedClient(host: "8.8.8.8"))
    #expect(!AppleWebManagementProtocol.isAllowedClient(host: "192.168.bad.1.2"))
    #expect(!AppleWebManagementProtocol.isAllowedClient(host: "fdrive.example"))
    #expect(!AppleWebManagementProtocol.isAllowedClient(host: "fc-malicious.example"))
    #expect(!AppleWebManagementProtocol.isAllowedClient(host: "fe80:not-an-address"))
    #expect(AppleWebManagementProtocol.isValidOrigin("http://192.168.1.20:11470/page", session: session))
    #expect(!AppleWebManagementProtocol.isValidOrigin("http://192.168.1.44:11470/page", session: session))
    #expect(!AppleWebManagementProtocol.isValidOrigin("http://192.168.1.20:8080/page", session: session))
    #expect(!AppleWebManagementProtocol.isValidOrigin("https://evil.example", session: session))
    #expect(!AppleWebManagementProtocol.isValidOrigin("http://attacker.local:11470/", session: session))
    #expect(!AppleWebManagementProtocol.isValidRequestSource(
        origin: "null",
        referer: nil,
        session: session
    ))
    #expect(!AppleWebManagementProtocol.isValidRequestSource(
        origin: nil,
        referer: "about:blank",
        session: session
    ))
    #expect(!AppleWebManagementProtocol.isValidRequestSource(
        origin: "https://evil.example",
        referer: "http://192.168.1.20:11470/openstream",
        session: session
    ))
    #expect(AppleWebManagementProtocol.isValidHost("192.168.1.20:11470", session: session))
    #expect(!AppleWebManagementProtocol.isValidHost("attacker.local:11470", session: session))
    #expect(!AppleWebManagementProtocol.isValidHost("192.168.1.20:8080", session: session))

    #expect(!AppleWebManagementProtocol.hasValidToken(
        form: ["token": "wrong"],
        headers: ["X-Setup-Token": token],
        query: ["token": token],
        session: session
    ))
    #expect(!AppleWebManagementProtocol.hasValidToken(
        form: [:],
        headers: ["X-Setup-Token": "wrong", "Cookie": "openstream_token=wrong"],
        query: ["token": token],
        session: session
    ))
    #expect(AppleWebManagementProtocol.hasValidToken(
        form: [:],
        headers: ["X-Setup-Token": token, "Cookie": "openstream_token=wrong"],
        query: [:],
        session: session
    ))
    #expect(AppleWebManagementProtocol.hasValidToken(
        form: [:],
        headers: ["Cookie": "other=x; openstream_token=\(token)"],
        query: [:],
        session: session
    ))
}

@Test func webManagementPageIsLeanAndEscapesSubmittedValues() {
    let page = AppleWebManagementPage.setup(
        error: "No <unsafe> source",
        address: "192.168.1.95:8090",
        draft: ["playlistURL": "\"><script>alert(1)</script>"]
    )

    #expect(page.contains("oStream"))
    #expect(page.contains("M3U Playlist"))
    #expect(page.contains("Provider Login"))
    #expect(page.contains("192.168.1.95:8090"))
    #expect(page.contains("&lt;script&gt;"))
    #expect(page.contains("No &lt;unsafe&gt; source"))
    #expect(!page.contains("<script>alert(1)</script>"))
    #expect(!page.contains("abc123"))
    #expect(!page.contains("name=\"token\""))
    #expect(!page.contains("Example:"))
    #expect(!page.contains("You can close"))
}

@Test func webManagementPageCarriesTheAppMarkAndPairedLineupImport() {
    let unpaired = AppleWebManagementPage.setup(pairingCode: "ABCD2345", address: "192.168.1.95:8090")
    let paired = AppleWebManagementPage.setup(
        sources: [AppleSource(kind: .liveTV, name: "Fixture TV", url: URL(string: "https://fixture.example/playlist.m3u")!,
                              iptvType: .m3u)],
        address: "192.168.1.95:8090"
    )

    for page in [unpaired, paired] {
        #expect(!page.lowercased().contains("upload"))
        #expect(!page.contains("/upload"))
        // The mark is the app's own three-bar drawing, inline, with no
        // external image and no other product's name on the page.
        #expect(page.contains("<svg class=\"mark\""))
        #expect(!page.contains("<img"))
        #expect(!page.contains("http://") || page.contains("192.168.1.95:8090"))
    }

    #expect(unpaired.contains("Pairing code"))
    #expect(!unpaired.contains("id=\"playlistURL\""))
    #expect(paired.contains("data-paired=\"true\""))
    #expect(paired.contains("id=\"playlistURL\""))
    #expect(paired.contains("Fixture TV"))
    #expect(paired.contains("value=\"remove\""))
    #expect(paired.contains("action=\"/lineup\""))
    #expect(paired.contains("accept=\".oslineup,.json,application/json\""))
    #expect(unpaired.contains("action=\"/lineup\"") == false)
}

@Test func webManagementUsesAReadablePort() {
    #expect(AppleWebManagementServer.defaultPort == 8090)
}

@MainActor
@Test func webManagementLoopbackServesAndPersistsOnePlaylist() async throws {
    let suiteName = "openstream-web-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let sourceStore = AppleSourceStore(defaults: defaults)
    let configuration = AppleWebManagementServer.Configuration(
        preferredPort: 0,
        sessionDuration: 30,
        advertisesBonjour: false,
        advertisedHost: "127.0.0.1"
    )
    let server = AppleWebManagementServer(configuration: configuration, iptvClient: fixturePlaylistClient())
    let activeSession = try await server.start(sourceStore: sourceStore)
    defer { server.stop() }
    let requestConfiguration = URLSessionConfiguration.ephemeral
    requestConfiguration.httpShouldSetCookies = false
    let requestSession = URLSession(configuration: requestConfiguration)
    defer { requestSession.invalidateAndCancel() }

    #expect(activeSession.friendlyURL.host == "127.0.0.1")
    #expect(activeSession.url == activeSession.friendlyURL)
    #expect(activeSession.url.path == "/")
    #expect(activeSession.url.query == nil)
    #expect(activeSession.pairingCode.count == 8)
    #expect(activeSession.privateURL.query != nil)

    let (unauthorizedData, unauthorizedResponse) = try await dataResponse(
        for: request(url: activeSession.friendlyURL),
        using: requestSession
    )
    #expect(unauthorizedResponse.statusCode == 200)
    #expect(String(decoding: unauthorizedData, as: UTF8.self).contains("Pairing code"))
    #expect(!String(decoding: unauthorizedData, as: UTF8.self).contains(activeSession.token))

    let bootstrapDelegate = AppleNoRedirectSessionDelegate()
    let bootstrap = URLSession(
        configuration: .ephemeral,
        delegate: bootstrapDelegate,
        delegateQueue: nil
    )
    defer { bootstrap.invalidateAndCancel() }
    let (_, rawBootstrapResponse) = try await bootstrap.data(for: request(url: activeSession.privateURL))
    let bootstrapResponse = try #require(rawBootstrapResponse as? HTTPURLResponse)
    #expect(bootstrapResponse.statusCode == 200)
    #expect(bootstrapResponse.value(forHTTPHeaderField: "Set-Cookie") == nil)
    let cookie = try await pairBrowser(activeSession, using: requestSession)

    var pageRequest = request(url: activeSession.friendlyURL)
    pageRequest.setValue(cookie, forHTTPHeaderField: "Cookie")
    let (pageData, pageResponse) = try await dataResponse(for: pageRequest, using: requestSession)
    #expect(pageResponse.statusCode == 200)
    #expect(pageResponse.url?.query == nil)
    #expect(pageResponse.value(forHTTPHeaderField: "Content-Security-Policy")?.contains("default-src 'none'") == true)
    #expect(String(decoding: pageData, as: UTF8.self).contains("Playlist URL"))
    #expect(!String(decoding: pageData, as: UTF8.self).contains(activeSession.token))

    let playlist = "https://fixture.example/loopback.m3u"
    var invalidPost = request(url: activeSession.friendlyURL)
    invalidPost.httpMethod = "POST"
    invalidPost.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    invalidPost.httpBody = formBody(playlist: playlist, token: "wrong")
    #expect(try await response(for: invalidPost, using: requestSession).statusCode == 401)

    var validPost = request(url: activeSession.friendlyURL)
    validPost.httpMethod = "POST"
    validPost.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    validPost.setValue(activeSession.friendlyURL.absoluteString, forHTTPHeaderField: "Origin")
    validPost.setValue(cookie, forHTTPHeaderField: "Cookie")
    validPost.httpBody = formBody(playlist: playlist)
    let (successData, successResponse) = try await dataResponse(for: validPost, using: requestSession)
    #expect(successResponse.statusCode == 200)
    #expect(String(decoding: successData, as: UTF8.self).contains("Loopback TV"))
    #expect(sourceStore.sources.count == 1)
    #expect(sourceStore.sources.first?.kind == .liveTV)
    #expect(sourceStore.sources.first?.iptvType == .m3u)
    #expect(sourceStore.sources.first?.discoveredItemCount == 1)
    #expect(server.session != nil)
}

@MainActor
@Test func webManagementAddsM3UAndShowsTheXtreamFailureReason() async throws {
    let suiteName = "openstream-web-iptv-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = AppleSourceStore(defaults: defaults)
    let playlist = Data("#EXTM3U\n#EXTINF:-1,Fixture News\nhttp://127.0.0.1:8765/live/news.ts\n".utf8)
    let iptvClient = AppleIPTVClient(loader: { request in
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        if request.url?.path.hasSuffix("player_api.php") == true {
            return (Data(#"{"user_info":{"auth":0,"status":"Disabled"}}"#.utf8), response)
        }
        return (playlist, response)
    })
    let server = AppleWebManagementServer(
        configuration: .init(preferredPort: 0, sessionDuration: 30, advertisesBonjour: false, advertisedHost: "127.0.0.1"),
        iptvClient: iptvClient
    )
    let active = try await server.start(sourceStore: store)
    defer { server.stop() }
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }

    let cookie = try await pairBrowser(active, using: session)
    var m3u = request(url: active.friendlyURL)
    m3u.setValue(cookie, forHTTPHeaderField: "Cookie")
    m3u.httpMethod = "POST"
    m3u.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    m3u.setValue(active.friendlyURL.absoluteString, forHTTPHeaderField: "Origin")
    m3u.httpBody = encodedForm([
        "sourceType": "m3u",
        "m3uName": "Fixture TV",
        "playlistURL": "http://127.0.0.1:8765/media/stress-5000.m3u"
    ])
    let (m3uData, m3uResponse) = try await dataResponse(for: m3u, using: session)
    #expect(m3uResponse.statusCode == 200)
    #expect(String(decoding: m3uData, as: UTF8.self).contains("Fixture TV"))
    #expect(store.sources.first?.kind == .liveTV)
    #expect(store.sources.first?.discoveredItemCount == 1)

    var xtream = request(url: active.friendlyURL)
    xtream.httpMethod = "POST"
    xtream.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    xtream.setValue(active.friendlyURL.absoluteString, forHTTPHeaderField: "Origin")
    xtream.setValue(cookie, forHTTPHeaderField: "Cookie")
    xtream.httpBody = encodedForm([
        "sourceType": "login",
        "loginName": "Wrong Account",
        "serverURL": "http://provider.example:8080",
        "username": "wrong",
        "password": "wrong"
    ])
    let (xtreamData, xtreamResponse) = try await dataResponse(for: xtream, using: session)
    #expect(xtreamResponse.statusCode == 400)
    #expect(String(decoding: xtreamData, as: UTF8.self).contains("account is disabled"))
    #expect(store.sources.count == 1)
}

@MainActor
@Test func webManagementRejectsInvalidHTTPRequests() async throws {
    let suiteName = "openstream-web-rejection-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let sourceStore = AppleSourceStore(defaults: defaults)
    let configuration = AppleWebManagementServer.Configuration(
        preferredPort: 0,
        sessionDuration: 30,
        advertisesBonjour: false,
        advertisedHost: "127.0.0.1"
    )
    let server = AppleWebManagementServer(configuration: configuration)
    let activeSession = try await server.start(sourceStore: sourceStore)
    defer { server.stop() }
    let clientConfiguration = URLSessionConfiguration.ephemeral
    clientConfiguration.httpShouldSetCookies = false
    let client = URLSession(configuration: clientConfiguration)
    defer { client.invalidateAndCancel() }

    let notFound = try await response(
        for: request(url: activeSession.friendlyURL.appendingPathComponent("missing")),
        using: client
    )
    #expect(notFound.statusCode == 404)

    var methodRequest = request(url: activeSession.friendlyURL)
    methodRequest.httpMethod = "PUT"
    #expect(try await response(for: methodRequest, using: client).statusCode == 405)

    var originRequest = request(url: activeSession.friendlyURL)
    originRequest.setValue("https://evil.example", forHTTPHeaderField: "Origin")
    #expect(try await response(for: originRequest, using: client).statusCode == 403)

    var emptyPost = request(url: activeSession.friendlyURL)
    emptyPost.httpMethod = "POST"
    emptyPost.httpBody = Data()
    #expect(try await response(for: emptyPost, using: client).statusCode == 413)
}

@MainActor
@Test func webManagementRotatesCodeWithoutReleasingItsListener() async throws {
    let suiteName = "openstream-web-expiry-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let sourceStore = AppleSourceStore(defaults: defaults)
    var now = Date()
    let server = AppleWebManagementServer(configuration: .init(
        preferredPort: 0, sessionDuration: 60, advertisesBonjour: false, advertisedHost: "127.0.0.1"
    ), now: { now })
    let first = try await server.start(sourceStore: sourceStore)
    defer { server.stop() }
    now = now.addingTimeInterval(61)
    server.refreshLifetimes()
    #expect(server.session?.pairingURL != first.pairingURL)
    #expect(server.session?.friendlyURL == first.friendlyURL)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpShouldSetCookies = false
    let browser = URLSession(configuration: configuration)
    defer { browser.invalidateAndCancel() }
    #expect(try await response(for: request(url: first.pairingURL), using: browser).statusCode == 403)
    let current = try #require(server.session)
    let cookie = try await pairBrowser(current, using: browser)
    let connected = try #require(server.connectedBrowsers.first)
    server.endBrowser(id: connected.id)
    var add = request(url: first.friendlyURL)
    add.httpMethod = "POST"
    add.setValue(cookie, forHTTPHeaderField: "Cookie")
    add.httpBody = encodedForm(playlistForm(name: "Fixture TV", url: "https://fixture.example/playlist.m3u"))
    #expect(try await response(for: add, using: browser).statusCode == 401)
    #expect(server.connectedBrowsers.isEmpty)
}

@MainActor
@Test func webManagementBoundsFailedPairingAttemptsAndAllowsRetryAfterTheWindow() async throws {
    let name = "openstream-web-pair-limit-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    var now = Date()
    let server = AppleWebManagementServer(configuration: .init(preferredPort: 0, sessionDuration: 600,
        advertisesBonjour: false, advertisedHost: "127.0.0.1"), now: { now })
    let active = try await server.start(sourceStore: AppleSourceStore(defaults: defaults))
    defer { server.stop() }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpShouldSetCookies = false
    let browser = URLSession(configuration: configuration)
    defer { browser.invalidateAndCancel() }
    let wrong = active.friendlyURL.appending(queryItems: [.init(name: "pair", value: "INVALID")])
    for _ in 0..<10 { #expect(try await response(for: request(url: wrong), using: browser).statusCode == 403) }
    #expect(try await response(for: request(url: active.pairingURL), using: browser).statusCode == 403)
    #expect(server.connectedBrowsers.isEmpty)
    now = now.addingTimeInterval(61)
    #expect(try await response(for: request(url: active.pairingURL), using: browser).statusCode == 200)
    #expect(server.connectedBrowsers.count == 1)
}

@MainActor
@Test func webManagementFallsBackWhenThePreferredPortIsOccupied() async throws {
    let (socketDescriptor, occupiedPort) = try occupiedLoopbackPort()
    defer { Darwin.close(socketDescriptor) }

    let suiteName = "openstream-web-fallback-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let sourceStore = AppleSourceStore(defaults: defaults)
    let configuration = AppleWebManagementServer.Configuration(
        preferredPort: occupiedPort,
        sessionDuration: 30,
        advertisesBonjour: false,
        advertisedHost: "127.0.0.1"
    )
    let server = AppleWebManagementServer(configuration: configuration)
    defer { server.stop() }

    let activeSession = try await server.start(sourceStore: sourceStore)
    #expect(activeSession.url.port != Int(occupiedPort))
    #expect((activeSession.url.port ?? 0) > 0)
}

/// No short client deadline: the server answers from the main actor, which
/// the parallel gate can hold for seconds. The default timeout is a hang guard.
private func request(url: URL) -> URLRequest {
    URLRequest(url: url)
}

private func formBody(playlist: String, token: String? = nil) -> Data {
    var components = URLComponents()
    components.queryItems = [
        URLQueryItem(name: "sourceType", value: "m3u"),
        URLQueryItem(name: "m3uName", value: "Loopback TV"),
        URLQueryItem(name: "playlistURL", value: playlist),
    ]
    if let token { components.queryItems?.append(URLQueryItem(name: "token", value: token)) }
    return Data((components.percentEncodedQuery ?? "").utf8)
}

private func playlistForm(name: String, url: String) -> [String: String] {
    ["sourceType": "m3u", "m3uName": name, "playlistURL": url]
}

/// Answers every playlist request with one channel; `broken.example` answers 404.
private func fixturePlaylistClient() -> AppleIPTVClient {
    AppleIPTVClient(loader: { request in
        let url = try #require(request.url)
        let status = url.host == "broken.example" ? 404 : 200
        let playlist = Data("#EXTM3U\n#EXTINF:-1,Fixture News\nhttps://fixture.example/live/news.m3u8\n".utf8)
        return (playlist, try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)))
    })
}

private func encodedForm(_ values: [String: String]) -> Data {
    var components = URLComponents()
    components.queryItems = values.map { URLQueryItem(name: $0.key, value: $0.value) }
    return Data((components.percentEncodedQuery ?? "").utf8)
}

private func response(for request: URLRequest) async throws -> HTTPURLResponse {
    try await dataResponse(for: request).1
}

private func response(for request: URLRequest, using session: URLSession) async throws -> HTTPURLResponse {
    try await dataResponse(for: request, using: session).1
}

private func dataResponse(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpShouldSetCookies = false
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let (data, response) = try await session.data(for: request)
    return (data, try #require(response as? HTTPURLResponse))
}

private func dataResponse(
    for request: URLRequest,
    using session: URLSession
) async throws -> (Data, HTTPURLResponse) {
    let (data, response) = try await session.data(for: request)
    return (data, try #require(response as? HTTPURLResponse))
}

private final class AppleNoRedirectSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// Holds a loopback port BELOW the ephemeral range (49152…65535 on macOS).
/// An OS-assigned port sits inside that range, where the kernel hands the
/// next ports out to every other test's sockets while this one runs — so the
/// server's P+1…P+63 fallback could find all of them taken ("Address already
/// in use"). Nothing allocates below the range implicitly, so the ports after
/// this one stay free unless a named listener already owns them.
private func occupiedLoopbackPort() throws -> (Int32, UInt16) {
    let firstCandidate = UInt16.random(in: 20_000 ..< 40_000)
    for offset in 0 ..< 256 {
        let port = firstCandidate + UInt16(offset)
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.ENFILE) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bindResult == 0, Darwin.listen(descriptor, 1) == 0 {
            return (descriptor, port)
        }
        let failure = errno
        Darwin.close(descriptor)
        guard failure == EADDRINUSE else {
            throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
        }
    }
    throw POSIXError(.EADDRINUSE)
}

@MainActor
@Test func webManagementNoLongerServesTheUploadRoute() async throws {
    let suite = "openstream-web-upload-removed-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = AppleSourceStore(defaults: defaults)
    let server = AppleWebManagementServer(
        configuration: .init(preferredPort: 0, sessionDuration: 30, advertisesBonjour: false, advertisedHost: "127.0.0.1")
    )
    let active = try await server.start(sourceStore: store)
    defer { server.stop() }
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }

    var page = request(url: active.friendlyURL.appending(path: "upload"))
    page.setValue(active.token, forHTTPHeaderField: "X-Setup-Token")
    #expect(try await response(for: page, using: session).statusCode == 404)

    var post = request(url: active.friendlyURL.appending(path: "upload"))
    post.httpMethod = "POST"
    post.httpBody = Data([1, 2, 3])
    post.setValue(active.token, forHTTPHeaderField: "X-Setup-Token")
    post.setValue(active.friendlyURL.absoluteString, forHTTPHeaderField: "Origin")
    #expect(try await response(for: post, using: session).statusCode == 404)
}

@MainActor
@Test func webManagementAddsAPlaylistFromABrowserFormAndKeepsPairingAfterAFailure() async throws {
    let suite = "openstream-web-browser-form-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = AppleSourceStore(defaults: defaults)
    let server = AppleWebManagementServer(
        configuration: .init(preferredPort: 0, sessionDuration: 60, advertisesBonjour: false, advertisedHost: "127.0.0.1"),
        iptvClient: fixturePlaylistClient()
    )
    let active = try await server.start(sourceStore: store)
    defer { server.stop() }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpShouldSetCookies = false
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }

    func browserPost(_ values: [String: String], cookie: String? = nil) -> URLRequest {
        var post = request(url: active.friendlyURL)
        post.httpMethod = "POST"
        post.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        post.setValue(active.friendlyURL.absoluteString, forHTTPHeaderField: "Origin")
        post.setValue(active.friendlyURL.absoluteString, forHTTPHeaderField: "Referer")
        post.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        if let cookie { post.setValue(cookie, forHTTPHeaderField: "Cookie") }
        post.httpBody = encodedForm(values)
        return post
    }

    let initialCookie = try await pairBrowser(active, using: session)
    // A failed add keeps the browser session and refreshes its cookie.
    let (failureData, failureResponse) = try await dataResponse(
        for: browserPost(playlistForm(name: "Browser TV", url: "https://broken.example/playlist.m3u"),
                         cookie: initialCookie),
        using: session
    )
    #expect(failureResponse.statusCode == 400)
    let failureBody = String(decoding: failureData, as: UTF8.self)
    #expect(failureBody.contains("HTTP 404"))
    #expect(failureBody.contains("data-paired=\"true\""))
    #expect(failureBody.contains("id=\"playlistURL\""))
    #expect(failureBody.contains("value=\"https://broken.example/playlist.m3u\""))
    let cookie = try pairingCookie(from: failureResponse)
    #expect(cookie == initialCookie)
    #expect(store.sources.isEmpty)

    // The cookie from the failed answer is enough for the retry; no code.
    let (successData, successResponse) = try await dataResponse(
        for: browserPost(playlistForm(name: "Browser TV", url: "https://fixture.example/playlist.m3u"),
                         cookie: cookie),
        using: session
    )
    #expect(successResponse.statusCode == 200)
    let successBody = String(decoding: successData, as: UTF8.self)
    #expect(successBody.contains("Added Browser TV"))
    #expect(successBody.contains("data-paired=\"true\""))
    #expect(store.sources.count == 1)
    #expect(store.sources.first?.kind == .liveTV)

    // The page is still reachable without the cookie after the code was used.
    #expect(try await response(for: request(url: active.friendlyURL), using: session).statusCode == 200)

    // A headerless same-origin post is still authorized by its session cookie.
    var headerless = request(url: active.friendlyURL)
    headerless.httpMethod = "POST"
    headerless.setValue(cookie, forHTTPHeaderField: "Cookie")
    headerless.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    headerless.httpBody = encodedForm([
        "action": "remove",
        "sourceID": try #require(store.sources.first).id.uuidString
    ])
    let (removedData, removedResponse) = try await dataResponse(for: headerless, using: session)
    #expect(removedResponse.statusCode == 200)
    #expect(String(decoding: removedData, as: UTF8.self).contains("Removed Browser TV"))
    #expect(store.sources.isEmpty)
}

@Test func webManagementDecodesMultipartFormsAndIgnoresFileParts() {
    let boundary = "----WebKitFormBoundaryQ7x2"
    var body = multipartForm(["sourceType": "login", "username": "a b&c=d", "password": "p\"q"], boundary: boundary)
    // Drop the closing delimiter, add a file part, then close again.
    body.removeLast("--\(boundary)--\r\n".utf8.count)
    body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.mp4\"\r\nContent-Type: video/mp4\r\n\r\n\u{00}\u{01}\r\n--\(boundary)--\r\n".utf8))

    let fields = AppleWebManagementProtocol.parseForm(
        body: body,
        contentType: "multipart/form-data; boundary=\"\(boundary)\""
    )
    #expect(fields["sourceType"] == "login")
    #expect(fields["username"] == "a b&c=d")
    #expect(fields["password"] == "p\"q")
    #expect(fields["file"] == nil)
    #expect(fields.count == 3)

    let encoded = AppleWebManagementProtocol.parseForm(
        body: Data("sourceType=m3u&playlistURL=http%3A%2F%2Fexample.test%2Fa.m3u&m3uName=My+TV".utf8),
        contentType: "application/x-www-form-urlencoded"
    )
    #expect(encoded["sourceType"] == "m3u")
    #expect(encoded["playlistURL"] == "http://example.test/a.m3u")
    #expect(encoded["m3uName"] == "My TV")
    #expect(AppleWebManagementProtocol.parseForm(body: Data("a=1".utf8), contentType: nil)["a"] == "1")
}

@MainActor
@Test func webManagementAddsAPlaylistFromAMultipartBrowserForm() async throws {
    let suite = "openstream-web-multipart-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = AppleSourceStore(defaults: defaults)
    let server = AppleWebManagementServer(
        configuration: .init(preferredPort: 0, sessionDuration: 60, advertisesBonjour: false, advertisedHost: "127.0.0.1"),
        iptvClient: fixturePlaylistClient()
    )
    let active = try await server.start(sourceStore: store)
    defer { server.stop() }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpShouldSetCookies = false
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }

    let cookie = try await pairBrowser(active, using: session)
    let boundary = "----WebKitFormBoundary\(UUID().uuidString.prefix(16))"
    var post = request(url: active.friendlyURL)
    post.httpMethod = "POST"
    post.setValue(cookie, forHTTPHeaderField: "Cookie")
    post.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    post.setValue(active.friendlyURL.absoluteString, forHTTPHeaderField: "Origin")
    post.setValue(active.friendlyURL.absoluteString, forHTTPHeaderField: "Referer")
    post.httpBody = multipartForm(
        playlistForm(name: "Multipart TV", url: "https://fixture.example/multipart.m3u"),
        boundary: boundary
    )

    let (data, response) = try await dataResponse(for: post, using: session)
    #expect(response.statusCode == 200)
    let body = String(decoding: data, as: UTF8.self)
    #expect(body.contains("Added Multipart TV"))
    #expect(try pairingCookie(from: response) == cookie)
    #expect(store.sources.count == 1)
    #expect(store.sources.first?.kind == .liveTV)
}

@MainActor
@Test func webManagementKeepsPairingAfterAnUnreachablePlaylistAndShowsIPAndPort() async throws {
    let suite = "openstream-web-unreachable-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = AppleSourceStore(defaults: defaults)
    let client = AppleIPTVClient(loader: { _ in throw URLError(.cannotConnectToHost) })
    let server = AppleWebManagementServer(
        configuration: .init(preferredPort: 0, sessionDuration: 60, advertisesBonjour: false, advertisedHost: "127.0.0.1"),
        iptvClient: client
    )
    let active = try await server.start(sourceStore: store)
    defer { server.stop() }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpShouldSetCookies = false
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let port = try #require(active.friendlyURL.port)

    let initialCookie = try await pairBrowser(active, using: session)
    var post = request(url: active.friendlyURL)
    post.httpMethod = "POST"
    post.setValue(initialCookie, forHTTPHeaderField: "Cookie")
    post.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    post.setValue(active.friendlyURL.absoluteString, forHTTPHeaderField: "Origin")
    post.httpBody = encodedForm(playlistForm(name: "Unreachable TV", url: "https://unreachable.example/playlist.m3u"))
    let (failureData, failureResponse) = try await dataResponse(for: post, using: session)
    #expect(failureResponse.statusCode == 400)
    let failureBody = String(decoding: failureData, as: UTF8.self)
    #expect(failureBody.contains("class=\"feedback error\" role=\"alert\">"))
    #expect(!failureBody.contains("role=\"alert\"></p>"))
    #expect(failureBody.contains("data-paired=\"true\""))
    #expect(store.sources.isEmpty)
    let cookie = try pairingCookie(from: failureResponse)

    // The next plain GET with that cookie is still paired and shows the
    // address as IP:PORT, the app's own mark, and no upload or other name.
    var page = request(url: active.friendlyURL)
    page.setValue(cookie, forHTTPHeaderField: "Cookie")
    let (pageData, pageResponse) = try await dataResponse(for: page, using: session)
    #expect(pageResponse.statusCode == 200)
    let pageBody = String(decoding: pageData, as: UTF8.self)
    #expect(pageBody.contains("id=\"playlistURL\""))
    #expect(pageBody.contains("data-paired=\"true\""))
    #expect(pageBody.contains("<p class=\"address\">127.0.0.1:\(port)</p>"))
    #expect(!pageBody.contains("http://127.0.0.1"))
    #expect(pageBody.contains("<svg class=\"mark\""))
    #expect(!pageBody.contains("<img"))
    #expect(!pageBody.lowercased().contains("upload"))
    for foreign in ["Orgista", "Plex", "Kodi", "Jellyfin"] {
        #expect(!pageBody.contains(foreign))
    }

    // Missing Xtream credentials are named before any network call.
    var xtream = request(url: active.friendlyURL)
    xtream.httpMethod = "POST"
    xtream.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    xtream.setValue(cookie, forHTTPHeaderField: "Cookie")
    xtream.httpBody = encodedForm(["sourceType": "login", "serverURL": "http://provider.example:8080"])
    let (xtreamData, xtreamResponse) = try await dataResponse(for: xtream, using: session)
    #expect(xtreamResponse.statusCode == 400)
    let xtreamBody = String(decoding: xtreamData, as: UTF8.self)
    #expect(xtreamBody.contains("Username and password are required."))
    #expect(xtreamBody.contains("id=\"type-login\" name=\"sourceType\" value=\"login\" checked"))
    #expect(xtreamBody.contains("value=\"http://provider.example:8080\""))
    #expect(store.sources.isEmpty)
}

private func multipartForm(_ values: [String: String], boundary: String) -> Data {
    var body = ""
    for (name, value) in values {
        body += "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n"
    }
    body += "--\(boundary)--\r\n"
    return Data(body.utf8)
}

/// The `openstream_token=<token>` pair from a response, without attributes.
private func pairingCookie(from response: HTTPURLResponse) throws -> String {
    let header = try #require(response.value(forHTTPHeaderField: "Set-Cookie"))
    let pair = try #require(header.split(separator: ";").first).trimmingCharacters(in: .whitespaces)
    #expect(pair.hasPrefix("openstream_token="))
    return pair
}

private func pairBrowser(_ active: AppleWebManagementSession, using browser: URLSession) async throws -> String {
    var post = request(url: active.friendlyURL)
    post.httpMethod = "POST"
    post.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    post.httpBody = encodedForm(["action": "pair", "pairingCode": active.pairingCode])
    let response = try await response(for: post, using: browser)
    #expect(response.statusCode == 200)
    return try pairingCookie(from: response)
}


@MainActor
@Test func webLineupUploadRequiresPairingAndTrustedOriginAndPersists() async throws {
    let suite = "openstream-lineup-web-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
    let lineup = AppleChannelLineupStore(directory: directory)
    let server = AppleWebManagementServer(configuration: .init(preferredPort: 0, sessionDuration: 600,
        advertisesBonjour: false, advertisedHost: "127.0.0.1"), lineupStore: lineup)
    let active = try await server.start(sourceStore: AppleSourceStore(defaults: defaults))
    defer { server.stop() }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpShouldSetCookies = false
    let browser = URLSession(configuration: configuration)
    defer { browser.invalidateAndCancel() }
    var upload = URLRequest(url: active.friendlyURL.appendingPathComponent("lineup"))
    upload.httpMethod = "POST"
    upload.setValue("application/json", forHTTPHeaderField: "Content-Type")
    upload.httpBody = try JSONEncoder().encode(fixtureLineup())
    #expect(try await response(for: upload, using: browser).statusCode == 401)
    #expect(lineup.current == nil)
    let cookie = try await pairBrowser(active, using: browser)
    upload.setValue(cookie, forHTTPHeaderField: "Cookie")
    upload.setValue("https://fixture.example", forHTTPHeaderField: "Origin")
    #expect(try await response(for: upload, using: browser).statusCode == 403)
    upload.setValue(nil, forHTTPHeaderField: "Origin")
    upload.setValue("fixture.example", forHTTPHeaderField: "Host")
    #expect(try await response(for: upload, using: browser).statusCode == 403)
    upload.setValue(nil, forHTTPHeaderField: "Host")
    let boundary = "lineup-test-boundary"
    let encoded = try JSONEncoder().encode(fixtureLineup())
    upload.httpBody = Data(("--\(boundary)\r\nContent-Disposition: form-data; name=\"lineup\"; filename=\"fixture.oslineup\"\r\nContent-Type: application/json\r\n\r\n"
        + String(decoding: encoded, as: UTF8.self) + "\r\n--\(boundary)--\r\n").utf8)
    upload.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    #expect(try AppleWebManagementServer.uploadedLineup(body: #require(upload.httpBody), contentType: upload.value(forHTTPHeaderField: "Content-Type")) == encoded)
    let uploaded = try await response(for: upload, using: browser)
    #expect(uploaded.statusCode == 200)
    #expect(lineup.current == (try fixtureLineup()))
    #expect(AppleChannelLineupStore(directory: directory).current == lineup.current)
    upload.setValue("application/json", forHTTPHeaderField: "Content-Type")
    upload.httpBody = Data("{}".utf8)
    #expect(try await response(for: upload, using: browser).statusCode == 400)
    #expect(lineup.current == (try fixtureLineup()))
    upload.httpBody = Data(repeating: 32, count: AppleChannelLineupFile.maximumBytes + 1)
    #expect(try await response(for: upload, using: browser).statusCode == 400)
    upload.httpBody = Data(repeating: 32, count: 4 * 1024 * 1024 + 1)
    upload.setValue("100-continue", forHTTPHeaderField: "Expect")
    #expect(try await response(for: upload, using: browser).statusCode == 413)
}
