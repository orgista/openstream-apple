import Foundation
import Testing
@testable import OpenStreamApple

@Suite(.serialized)
struct AppleManifestFixtureTests {
    @Test func manifestClientFetchAndValidationMatrix() async throws {
        let valid = Data(#"""
        {
          "id":"fixture.addon",
          "name":"Fixture Add-on",
          "version":"1.0.0",
          "resources":["catalog","stream","future-resource"],
          "catalogs":[{"type":"movie","id":"popular","futureFlag":true}],
          "futureField":{"nested":true}
        }
        """#.utf8)
        ManifestFixtureURLProtocol.configure([
            "/valid/manifest.json": .init(statusCode: 200, body: valid),
            "/malformed/manifest.json": .init(statusCode: 200, body: Data("{".utf8)),
            "/empty-id/manifest.json": .init(statusCode: 200, body: Data(#"{"id":"   ","name":"Fixture"}"#.utf8)),
            "/empty-name/manifest.json": .init(statusCode: 200, body: Data(#"{"id":"fixture.addon","name":"  "}"#.utf8)),
            "/not-found/manifest.json": .init(statusCode: 404, body: Data()),
            "/server-error/manifest.json": .init(statusCode: 500, body: Data()),
            "/oversized/manifest.json": .init(
                statusCode: 200,
                body: Data("{}".utf8),
                contentLength: 2_000_001
            ),
            "/secure-redirect/manifest.json": .init(
                statusCode: 200,
                body: valid,
                responseURL: URL(string: "https://redirect.fixture/final")!
            ),
            "/insecure-redirect/manifest.json": .init(
                statusCode: 200,
                body: valid,
                responseURL: URL(string: "http://redirect.fixture/final")!
            ),
            "/delayed/manifest.json": .init(statusCode: 200, body: valid, delay: 0.25),
        ])
        defer { ManifestFixtureURLProtocol.reset() }

        let client = makeClient()
        let (normalizedURL, manifest) = try await client.load("https://manifest.fixture/valid")
        #expect(normalizedURL.absoluteString == "https://manifest.fixture/valid/manifest.json")
        #expect(manifest.id == "fixture.addon")
        #expect(manifest.name == "Fixture Add-on")
        #expect(manifest.resources == ["catalog", "stream", "future-resource"])
        #expect(manifest.catalogs.map(\.id) == ["popular"])

        await #expect(throws: AppleManifestClientError.manifestNotJSON) {
            try await client.load("https://manifest.fixture/malformed")
        }
        await #expect(throws: AppleManifestClientError.manifestMissingField("id")) {
            try await client.load("https://manifest.fixture/empty-id")
        }
        await #expect(throws: AppleManifestClientError.manifestMissingField("name")) {
            try await client.load("https://manifest.fixture/empty-name")
        }
        await #expect(throws: AppleManifestClientError.requestFailed(404)) {
            try await client.load("https://manifest.fixture/not-found")
        }
        await #expect(throws: AppleManifestClientError.requestFailed(500)) {
            try await client.load("https://manifest.fixture/server-error")
        }
        #expect(ManifestFixtureURLProtocol.requestCount(path: "/server-error/manifest.json") == 4)
        await #expect(throws: AppleManifestClientError.responseTooLarge) {
            try await client.load("https://manifest.fixture/oversized")
        }

        let (redirectedURL, redirectedManifest) = try await client.load(
            "https://manifest.fixture/secure-redirect"
        )
        #expect(redirectedURL.host == "manifest.fixture")
        #expect(redirectedManifest.id == "fixture.addon")
        await #expect(throws: AppleManifestClientError.insecureRedirect) {
            try await client.load("https://manifest.fixture/insecure-redirect")
        }

        let cancellation = Task {
            try await client.load("https://manifest.fixture/delayed")
        }
        try await Task.sleep(for: .milliseconds(20))
        cancellation.cancel()
        await #expect(throws: CancellationError.self) {
            try await cancellation.value
        }

        let audit = ManifestFixtureURLProtocol.audit()
        #expect(audit.allSatisfy { !$0.hasAuthorizationHeader })
        #expect(audit.allSatisfy { !$0.hasBody })
        #expect(audit.allSatisfy { !$0.hasURLCredentials })
    }

    @Test func manifestURLPolicyRejectsUnsafeAndUnsupportedForms() throws {
        #expect(throws: AppleManifestURLPolicy.Error.unsupportedScheme("file")) {
            try AppleManifestURLPolicy.normalize("file:///tmp/manifest.json")
        }
        #expect(throws: AppleManifestURLPolicy.Error.unsupportedScheme("ftp")) {
            try AppleManifestURLPolicy.normalize("ftp://manifest.fixture/manifest.json")
        }
        #expect(throws: AppleManifestURLPolicy.Error.missingHost) {
            try AppleManifestURLPolicy.normalize("https:///manifest.json")
        }
        #expect(throws: AppleManifestURLPolicy.Error.credentialsNotAllowed) {
            try AppleManifestURLPolicy.normalize("https://fixture-user:fixture-pass@manifest.fixture")
        }
        #expect(throws: AppleManifestURLPolicy.Error.queryNotAllowed) {
            try AppleManifestURLPolicy.normalize("https://manifest.fixture/manifest.json?fixture=1")
        }
        #expect(throws: AppleManifestURLPolicy.Error.fragmentNotAllowed) {
            try AppleManifestURLPolicy.normalize("https://manifest.fixture/manifest.json#fixture")
        }
        #expect(throws: AppleManifestURLPolicy.Error.wrongJSONDocument("catalog.json")) {
            try AppleManifestURLPolicy.normalize("https://manifest.fixture/catalog.json")
        }
    }

    private func makeClient(timeout: TimeInterval = 2) -> AppleManifestClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ManifestFixtureURLProtocol.self]
        configuration.timeoutIntervalForRequest = timeout
        let boundedClient = AppleBoundedHTTPClient(configuration: configuration)
        return AppleManifestClient(
            loader: { url in
                do {
                    return try await boundedClient.load(
                        URLRequest(url: url),
                        maximumBytes: 2_000_000,
                        redirectPolicy: .follow,
                        behavior: .rejectOverflow
                    )
                } catch AppleBoundedHTTPError.responseTooLarge {
                    throw AppleManifestClientError.responseTooLarge
                }
            },
            sleeper: { _ in }
        )
    }
}

private final class ManifestFixtureURLProtocol: URLProtocol, @unchecked Sendable {
    struct Fixture: @unchecked Sendable {
        let statusCode: Int
        let body: Data
        let contentLength: Int64?
        let responseURL: URL?
        let delay: TimeInterval

        init(
            statusCode: Int,
            body: Data,
            contentLength: Int64? = nil,
            responseURL: URL? = nil,
            delay: TimeInterval = 0
        ) {
            self.statusCode = statusCode
            self.body = body
            self.contentLength = contentLength
            self.responseURL = responseURL
            self.delay = delay
        }
    }

    struct RequestAudit: Sendable {
        let hasAuthorizationHeader: Bool
        let hasBody: Bool
        let hasURLCredentials: Bool
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var fixtures: [String: Fixture] = [:]
    nonisolated(unsafe) private static var requestCounts: [String: Int] = [:]
    nonisolated(unsafe) private static var requestAudits: [RequestAudit] = []
    private let stateLock = NSLock()
    private var stopped = false

    static func configure(_ fixtures: [String: Fixture]) {
        Self.lock.lock()
        self.fixtures = fixtures
        requestCounts = [:]
        requestAudits = []
        Self.lock.unlock()
    }

    static func reset() {
        configure([:])
    }

    static func requestCount(path: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return requestCounts[path, default: 0]
    }

    static func audit() -> [RequestAudit] {
        lock.lock()
        defer { lock.unlock() }
        return requestAudits
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "manifest.fixture"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let fixture: Fixture?
        Self.lock.lock()
        fixture = Self.fixtures[url.path]
        Self.requestCounts[url.path, default: 0] += 1
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        Self.requestAudits.append(RequestAudit(
            hasAuthorizationHeader: request.value(forHTTPHeaderField: "Authorization") != nil,
            hasBody: request.httpBody != nil,
            hasURLCredentials: components?.user != nil || components?.password != nil
        ))
        Self.lock.unlock()

        guard let fixture else {
            finish(statusCode: 404, body: Data(), responseURL: url, contentLength: 0)
            return
        }
        if fixture.delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + fixture.delay) { [weak self] in
                self?.send(fixture: fixture, requestURL: url)
            }
        } else {
            send(fixture: fixture, requestURL: url)
        }
    }

    override func stopLoading() {
        stateLock.lock()
        stopped = true
        stateLock.unlock()
    }

    private func send(fixture: Fixture, requestURL: URL) {
        stateLock.lock()
        let isStopped = stopped
        stateLock.unlock()
        guard !isStopped else { return }
        finish(
            statusCode: fixture.statusCode,
            body: fixture.body,
            responseURL: fixture.responseURL ?? requestURL,
            contentLength: fixture.contentLength ?? Int64(fixture.body.count)
        )
    }

    private func finish(statusCode: Int, body: Data, responseURL: URL, contentLength: Int64) {
        stateLock.lock()
        let isStopped = stopped
        stateLock.unlock()
        guard !isStopped,
              let response = HTTPURLResponse(
                  url: responseURL,
                  statusCode: statusCode,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Length": String(contentLength)]
              ) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if (200 ... 299).contains(statusCode) { client?.urlProtocol(self, didLoad: body) }
        client?.urlProtocolDidFinishLoading(self)
    }
}
