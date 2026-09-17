import Foundation
import Testing
import Darwin
@testable import OpenStreamApple

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
        manifest: "\"><script>alert(1)</script>",
        error: "No <unsafe> source",
        address: "192.168.1.95:8090"
    )

    #expect(page.contains("OpenStream"))
    #expect(page.contains("Add-on"))
    #expect(page.contains("IPTV playlist"))
    #expect(page.contains("Xtream"))
    #expect(page.contains("192.168.1.95:8090"))
    #expect(page.contains("&lt;script&gt;"))
    #expect(page.contains("No &lt;unsafe&gt; source"))
    #expect(!page.contains("<script>"))
    #expect(!page.contains("abc123"))
    #expect(!page.contains("name=\"token\""))
    #expect(!page.contains("Example:"))
    #expect(!page.contains("You can close"))
}

@Test func webManagementPageCarriesTheAppMarkAndNoUploadSection() {
    let unpaired = AppleWebManagementPage.setup(pairingCode: "ABCD2345", address: "192.168.1.95:8090")
    let paired = AppleWebManagementPage.setup(
        sources: [AppleSource(kind: .stremio, name: "Cinemeta", url: URL(string: "https://v3-cinemeta.strem.io/manifest.json")!)],
        address: "192.168.1.95:8090"
    )

    for page in [unpaired, paired] {
        #expect(!page.lowercased().contains("upload"))
        #expect(!page.contains("/upload"))
        // The mark is the app's own three-bar drawing, inline, with no
        // external image and no other product's name on the page.
        #expect(page.contains("<svg class=\"mark\""))
        #expect(!page.contains("<img"))
        #expect(!page.contains("Stremio"))
        #expect(!page.contains("http://") || page.contains("192.168.1.95:8090"))
    }

    #expect(unpaired.contains("Pairing code"))
    #expect(!unpaired.contains("id=\"manifest\""))
    #expect(!paired.contains("Pairing code"))
    #expect(paired.contains("id=\"manifest\""))
    #expect(paired.contains("Cinemeta"))
    #expect(paired.contains("value=\"remove\""))
}

@MainActor
@Test func webManagementUsesAReadableAddressAndAcceptsSubtitlesOnlyManifests() async throws {
    #expect(AppleWebManagementServer.defaultPort == 8090)

    let suiteName = "openstream-subtitles-only-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = AppleSourceStore(defaults: defaults)
    let manifestData = Data(#"{"id":"org.example.subtitles","name":"OpenSubtitles v3","resources":["subtitles"],"catalogs":[]}"#.utf8)
    let client = AppleManifestClient { url in
        (manifestData, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    let source = try await store.addStremio(
        manifestValue: "https://opensubtitles-v3.strem.io/manifest.json",
        client: client
    )

    #expect(source.resources == ["subtitles"])
    #expect(source.catalogs.isEmpty)
    #expect(source.capabilities == ["Subtitles"])
    #expect(AppleCatalogDiscoveryPolicy.catalogs(for: source, maximumCatalogs: 12).isEmpty)
}

@MainActor
@Test func webManagementLoopbackServesAndPersistsOneManifest() async throws {
    let suiteName = "openstream-web-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let sourceStore = AppleSourceStore(defaults: defaults)

    let manifestData = Data(#"""
    {
      "id":"org.example.loopback",
      "name":"Loopback Catalog",
      "version":"1.0.0",
      "resources":["catalog","stream"],
      "catalogs":[{"type":"movie","id":"popular"}]
    }
    """#.utf8)
    let manifestClient = AppleManifestClient { url in
        (manifestData, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    let configuration = AppleWebManagementServer.Configuration(
        preferredPort: 0,
        sessionDuration: 30,
        advertisesBonjour: false,
        advertisedHost: "127.0.0.1"
    )
    let server = AppleWebManagementServer(configuration: configuration, manifestClient: manifestClient)
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
    #expect(bootstrapResponse.statusCode == 303)
    #expect(bootstrapResponse.value(forHTTPHeaderField: "Location") == activeSession.friendlyURL.absoluteString)
    #expect(bootstrapResponse.value(forHTTPHeaderField: "Set-Cookie")?.contains("openstream_token=") == true)

    var pageRequest = request(url: activeSession.friendlyURL)
    pageRequest.setValue("openstream_token=\(activeSession.token)", forHTTPHeaderField: "Cookie")
    let (pageData, pageResponse) = try await dataResponse(for: pageRequest, using: requestSession)
    #expect(pageResponse.statusCode == 200)
    #expect(pageResponse.url?.query == nil)
    #expect(pageResponse.value(forHTTPHeaderField: "Content-Security-Policy")?.contains("default-src 'none'") == true)
    #expect(String(decoding: pageData, as: UTF8.self).contains("Manifest URL"))
    #expect(!String(decoding: pageData, as: UTF8.self).contains(activeSession.token))

    let manifest = "https://addon.example/manifest.json"
    var invalidPost = request(url: activeSession.friendlyURL)
    invalidPost.httpMethod = "POST"
    invalidPost.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    invalidPost.httpBody = formBody(manifest: manifest, token: "wrong")
    #expect(try await response(for: invalidPost, using: requestSession).statusCode == 403)

    var validPost = request(url: activeSession.friendlyURL)
    validPost.httpMethod = "POST"
    validPost.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    validPost.setValue(activeSession.friendlyURL.absoluteString, forHTTPHeaderField: "Origin")
    validPost.setValue("openstream_token=\(activeSession.token)", forHTTPHeaderField: "Cookie")
    validPost.httpBody = formBody(manifest: manifest)
    let (successData, successResponse) = try await dataResponse(for: validPost, using: requestSession)
    #expect(successResponse.statusCode == 200)
    #expect(String(decoding: successData, as: UTF8.self).contains("Loopback Catalog"))
    #expect(sourceStore.sources.count == 1)
    #expect(sourceStore.sources.first?.manifestID == "org.example.loopback")
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

    var m3u = request(url: active.friendlyURL)
    m3u.httpMethod = "POST"
    m3u.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    m3u.setValue(active.friendlyURL.absoluteString, forHTTPHeaderField: "Origin")
    m3u.httpBody = encodedForm([
        "pairingCode": active.pairingCode,
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
    xtream.setValue("openstream_token=\(active.token)", forHTTPHeaderField: "Cookie")
    xtream.httpBody = encodedForm([
        "sourceType": "xtream",
        "xtreamName": "Wrong Account",
        "serverURL": "http://provider.example:8080",
        "username": "wrong",
        "password": "wrong"
    ])
    let (xtreamData, xtreamResponse) = try await dataResponse(for: xtream, using: session)
    #expect(xtreamResponse.statusCode == 400)
    #expect(String(decoding: xtreamData, as: UTF8.self).contains("auth=0"))
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
@Test func webManagementExpiresAndReleasesItsListener() async throws {
    let suiteName = "openstream-web-expiry-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let sourceStore = AppleSourceStore(defaults: defaults)
    let configuration = AppleWebManagementServer.Configuration(
        preferredPort: 0,
        sessionDuration: 0.05,
        advertisesBonjour: false,
        advertisedHost: "127.0.0.1"
    )
    let server = AppleWebManagementServer(configuration: configuration)

    _ = try await server.start(sourceStore: sourceStore)
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while server.session != nil, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(server.session == nil)
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

private func request(url: URL) -> URLRequest {
    var request = URLRequest(url: url)
    request.timeoutInterval = 5
    return request
}

private func formBody(manifest: String, token: String? = nil) -> Data {
    var components = URLComponents()
    components.queryItems = [URLQueryItem(name: "manifest", value: manifest)]
    if let token { components.queryItems?.append(URLQueryItem(name: "token", value: token)) }
    return Data((components.percentEncodedQuery ?? "").utf8)
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

private func occupiedLoopbackPort() throws -> (Int32, UInt16) {
    let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw POSIXError(.ENFILE) }

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

    let bindResult = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bindResult == 0, Darwin.listen(descriptor, 1) == 0 else {
        Darwin.close(descriptor)
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let nameResult = withUnsafeMutablePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.getsockname(descriptor, $0, &length)
        }
    }
    guard nameResult == 0 else {
        Darwin.close(descriptor)
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return (descriptor, UInt16(bigEndian: address.sin_port))
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
@Test func webManagementAddsAnAddonFromABrowserFormAndKeepsPairingAfterAFailure() async throws {
    let suite = "openstream-web-browser-form-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = AppleSourceStore(defaults: defaults)
    let manifest = Data(#"{"id":"org.example.browser","name":"Browser Catalog","version":"1.0.0","resources":["catalog"],"catalogs":[{"type":"movie","id":"top"}]}"#.utf8)
    let client = AppleManifestClient { url in
        guard url.host == "addon.example" else {
            return (Data(), HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        }
        return (manifest, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    let server = AppleWebManagementServer(
        configuration: .init(preferredPort: 0, sessionDuration: 60, advertisesBonjour: false, advertisedHost: "127.0.0.1"),
        manifestClient: client
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

    // A failed add must name the reason, keep the page paired, and hand the
    // browser a pairing cookie instead of spending the code.
    let (failureData, failureResponse) = try await dataResponse(
        for: browserPost([
            "pairingCode": active.pairingCode,
            "sourceType": "addon",
            "manifest": "https://broken.example/manifest.json"
        ]),
        using: session
    )
    #expect(failureResponse.statusCode == 400)
    let failureBody = String(decoding: failureData, as: UTF8.self)
    #expect(failureBody.contains("HTTP 404"))
    #expect(!failureBody.contains("Pairing code"))
    #expect(failureBody.contains("id=\"manifest\""))
    #expect(failureBody.contains("value=\"https://broken.example/manifest.json\""))
    let cookie = try pairingCookie(from: failureResponse)
    #expect(cookie == "openstream_token=\(active.token)")
    #expect(store.sources.isEmpty)

    // The cookie from the failed answer is enough for the retry; no code.
    let (successData, successResponse) = try await dataResponse(
        for: browserPost([
            "sourceType": "addon",
            "manifest": "https://addon.example/manifest.json"
        ], cookie: cookie),
        using: session
    )
    #expect(successResponse.statusCode == 200)
    let successBody = String(decoding: successData, as: UTF8.self)
    #expect(successBody.contains("Added Browser Catalog"))
    #expect(successBody.contains("Browser Catalog"))
    #expect(!successBody.contains("Pairing code"))
    #expect(store.sources.count == 1)
    #expect(store.sources.first?.manifestID == "org.example.browser")

    // The page is still reachable without the cookie after the code was used.
    #expect(try await response(for: request(url: active.friendlyURL), using: session).statusCode == 200)

    // Safari omits Referer under a no-referrer policy and can omit Origin on a
    // same-origin form post; the request must still work, and the pairing
    // code is still accepted after the earlier failure and success.
    var headerless = request(url: active.friendlyURL)
    headerless.httpMethod = "POST"
    headerless.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    headerless.httpBody = encodedForm([
        "action": "remove",
        "pairingCode": active.pairingCode,
        "sourceID": try #require(store.sources.first).id.uuidString
    ])
    let (removedData, removedResponse) = try await dataResponse(for: headerless, using: session)
    #expect(removedResponse.statusCode == 200)
    #expect(String(decoding: removedData, as: UTF8.self).contains("Removed Browser Catalog"))
    #expect(store.sources.isEmpty)
}

@Test func webManagementDecodesMultipartFormsAndIgnoresFileParts() {
    let boundary = "----WebKitFormBoundaryQ7x2"
    var body = multipartForm(["sourceType": "xtream", "username": "a b&c=d", "password": "p\"q"], boundary: boundary)
    // Drop the closing delimiter, add a file part, then close again.
    body.removeLast("--\(boundary)--\r\n".utf8.count)
    body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.mp4\"\r\nContent-Type: video/mp4\r\n\r\n\u{00}\u{01}\r\n--\(boundary)--\r\n".utf8))

    let fields = AppleWebManagementProtocol.parseForm(
        body: body,
        contentType: "multipart/form-data; boundary=\"\(boundary)\""
    )
    #expect(fields["sourceType"] == "xtream")
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
@Test func webManagementAddsAnAddonFromAMultipartBrowserForm() async throws {
    let suite = "openstream-web-multipart-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = AppleSourceStore(defaults: defaults)
    let manifest = Data(#"{"id":"org.example.multipart","name":"Multipart Catalog","version":"1.0.0","resources":["catalog"],"catalogs":[{"type":"movie","id":"top"}]}"#.utf8)
    let client = AppleManifestClient { url in
        (manifest, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    let server = AppleWebManagementServer(
        configuration: .init(preferredPort: 0, sessionDuration: 60, advertisesBonjour: false, advertisedHost: "127.0.0.1"),
        manifestClient: client
    )
    let active = try await server.start(sourceStore: store)
    defer { server.stop() }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpShouldSetCookies = false
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }

    let boundary = "----WebKitFormBoundary\(UUID().uuidString.prefix(16))"
    var post = request(url: active.friendlyURL)
    post.httpMethod = "POST"
    post.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    post.setValue(active.friendlyURL.absoluteString, forHTTPHeaderField: "Origin")
    post.setValue(active.friendlyURL.absoluteString, forHTTPHeaderField: "Referer")
    post.httpBody = multipartForm([
        "pairingCode": active.pairingCode,
        "sourceType": "addon",
        "manifest": "https://addon.example/manifest.json"
    ], boundary: boundary)

    let (data, response) = try await dataResponse(for: post, using: session)
    #expect(response.statusCode == 200)
    let body = String(decoding: data, as: UTF8.self)
    #expect(body.contains("Added Multipart Catalog"))
    #expect(try pairingCookie(from: response) == "openstream_token=\(active.token)")
    #expect(store.sources.count == 1)
    #expect(store.sources.first?.manifestID == "org.example.multipart")
}

@MainActor
@Test func webManagementKeepsPairingAfterAnUnreachableAddonAndShowsIPAndPort() async throws {
    let suite = "openstream-web-unreachable-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = AppleSourceStore(defaults: defaults)
    let client = AppleManifestClient(
        loader: { _ in throw URLError(.cannotConnectToHost) },
        sleeper: { _ in }
    )
    let server = AppleWebManagementServer(
        configuration: .init(preferredPort: 0, sessionDuration: 60, advertisesBonjour: false, advertisedHost: "127.0.0.1"),
        manifestClient: client
    )
    let active = try await server.start(sourceStore: store)
    defer { server.stop() }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpShouldSetCookies = false
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let port = try #require(active.friendlyURL.port)

    var post = request(url: active.friendlyURL)
    post.httpMethod = "POST"
    post.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    post.setValue(active.friendlyURL.absoluteString, forHTTPHeaderField: "Origin")
    post.httpBody = encodedForm([
        "pairingCode": active.pairingCode,
        "sourceType": "addon",
        "manifest": "https://unreachable.example/manifest.json"
    ])
    let (failureData, failureResponse) = try await dataResponse(for: post, using: session)
    #expect(failureResponse.statusCode == 400)
    let failureBody = String(decoding: failureData, as: UTF8.self)
    #expect(failureBody.contains("class=\"feedback error\" role=\"alert\">"))
    #expect(!failureBody.contains("role=\"alert\"></p>"))
    #expect(!failureBody.contains("Pairing code"))
    #expect(store.sources.isEmpty)
    let cookie = try pairingCookie(from: failureResponse)

    // The next plain GET with that cookie is still paired and shows the
    // address as IP:PORT, the app's own mark, and no upload or other name.
    var page = request(url: active.friendlyURL)
    page.setValue(cookie, forHTTPHeaderField: "Cookie")
    let (pageData, pageResponse) = try await dataResponse(for: page, using: session)
    #expect(pageResponse.statusCode == 200)
    let pageBody = String(decoding: pageData, as: UTF8.self)
    #expect(pageBody.contains("id=\"manifest\""))
    #expect(!pageBody.contains("Pairing code"))
    #expect(pageBody.contains("<p class=\"address\">127.0.0.1:\(port)</p>"))
    #expect(!pageBody.contains("http://127.0.0.1"))
    #expect(pageBody.contains("<svg class=\"mark\""))
    #expect(!pageBody.contains("<img"))
    #expect(!pageBody.lowercased().contains("upload"))
    for foreign in ["Stremio", "Orgista", "Plex", "Kodi", "Jellyfin"] {
        #expect(!pageBody.contains(foreign))
    }

    // Missing Xtream credentials are named before any network call.
    var xtream = request(url: active.friendlyURL)
    xtream.httpMethod = "POST"
    xtream.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    xtream.setValue(cookie, forHTTPHeaderField: "Cookie")
    xtream.httpBody = encodedForm(["sourceType": "xtream", "serverURL": "http://provider.example:8080"])
    let (xtreamData, xtreamResponse) = try await dataResponse(for: xtream, using: session)
    #expect(xtreamResponse.statusCode == 400)
    let xtreamBody = String(decoding: xtreamData, as: UTF8.self)
    #expect(xtreamBody.contains("Username and password are required."))
    #expect(xtreamBody.contains("id=\"type-xtream\" name=\"sourceType\" value=\"xtream\" checked"))
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
