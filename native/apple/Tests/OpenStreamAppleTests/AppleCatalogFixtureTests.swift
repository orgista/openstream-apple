import Foundation
import Testing
@testable import OpenStreamApple

@Suite(.serialized)
struct AppleCatalogFixtureTests {
    @Test func catalogClientFetchesParsesAndAuditsLoopbackFixtures() async throws {
        let moviePayload = Data(#"""
        {
          "metas":[
            {"id":"m-2","type":"movie","name":"Second","imdbRating":"8.5","futureField":true},
            {"id":"s-1","type":"series","name":"Series","extra":{"new":true}},
            {"id":"m-2","type":"movie","name":"Duplicate"},
            {"id":"missing-name","type":"movie"},
            42,
            {"id":"wrong-type","type":"book","name":"Ignored"},
            {"id":"m-1","type":"movie","name":"First"}
          ],
          "futureCatalogField":{"nested":true}
        }
        """#.utf8)
        let seriesPayload = Data(#"{"metas":[{"id":"s-2","type":"series","name":"Later"}]}"#.utf8)
        CatalogFixtureURLProtocol.configure([
            "/catalog/movie/popular.json": .init(statusCode: 200, body: moviePayload),
            "/catalog/series/featured.json": .init(statusCode: 200, body: seriesPayload),
            "/catalog/movie/malformed.json": .init(statusCode: 200, body: Data("{".utf8)),
            "/catalog/movie/missing-metas.json": .init(statusCode: 200, body: Data(#"{"future":true}"#.utf8)),
            "/catalog/movie/not-found.json": .init(statusCode: 404, body: Data()),
            "/catalog/movie/server-error.json": .init(statusCode: 500, body: Data()),
            "/catalog/movie/oversized.json": .init(
                statusCode: 200,
                body: Data("{}".utf8),
                contentLength: 2_000_001
            ),
            "/catalog/movie/insecure.json": .init(
                statusCode: 200,
                body: moviePayload,
                responseURL: URL(string: "http://redirect.fixture/catalog/movie/insecure.json")!
            ),
            "/catalog/movie/delayed.json": .init(
                statusCode: 200,
                body: moviePayload,
                delay: 0.25
            ),
        ])
        defer { CatalogFixtureURLProtocol.reset() }

        let source = makeSource(catalogs: [
            .init(type: "movie", id: "popular"),
            .init(type: "series", id: "featured"),
            .init(type: "movie", id: "malformed"),
            .init(type: "movie", id: "missing-metas"),
            .init(type: "movie", id: "not-found"),
            .init(type: "movie", id: "server-error"),
            .init(type: "movie", id: "oversized"),
            .init(type: "movie", id: "insecure"),
            .init(type: "movie", id: "delayed"),
        ])
        let client = makeClient()

        let movieItems = try await client.load(source: source, catalog: source.catalogs[0])
        #expect(movieItems.map(\.id) == ["movie:m-2", "series:s-1", "movie:m-1"])
        #expect(movieItems.map(\.name) == ["Second", "Series", "First"])
        #expect(movieItems[0].rating == 8.5)

        let seriesItems = try await client.load(source: source, catalog: source.catalogs[1])
        #expect(seriesItems.map(\.id) == ["series:s-2"])
        #expect(CatalogFixtureURLProtocol.requestedPaths() == [
            "/catalog/movie/popular.json",
            "/catalog/series/featured.json",
        ])

        await #expect(throws: AppleStremioCatalogError.invalidCatalog) {
            try await client.load(source: source, catalog: source.catalogs[2])
        }
        await #expect(throws: AppleStremioCatalogError.invalidCatalog) {
            try await client.load(source: source, catalog: source.catalogs[3])
        }
        await #expect(throws: AppleStremioCatalogError.requestFailed(404)) {
            try await client.load(source: source, catalog: source.catalogs[4])
        }
        await #expect(throws: AppleStremioCatalogError.requestFailed(500)) {
            try await client.load(source: source, catalog: source.catalogs[5])
        }
        #expect(CatalogFixtureURLProtocol.requestCount(path: "/catalog/movie/server-error.json") == 1)
        await #expect(throws: AppleStremioCatalogError.responseTooLarge) {
            try await client.load(source: source, catalog: source.catalogs[6])
        }
        await #expect(throws: AppleStremioCatalogError.insecureRedirect) {
            try await client.load(source: source, catalog: source.catalogs[7])
        }

        let cancellation = Task {
            try await client.load(source: source, catalog: source.catalogs[8])
        }
        try await Task.sleep(for: .milliseconds(20))
        cancellation.cancel()
        do {
            _ = try await cancellation.value
            Issue.record("The catalog request should have been cancelled.")
        } catch is CancellationError {
        } catch {
            Issue.record("The catalog cancellation returned an unexpected error.")
        }

        let audit = CatalogFixtureURLProtocol.audit()
        #expect(audit.allSatisfy { !$0.hasAuthorizationHeader })
        #expect(audit.allSatisfy { !$0.hasBody })
        #expect(audit.allSatisfy { !$0.hasURLCredentials })
    }

    @Test func catalogClientRejectsInvalidSourceAndUnsafeEndpointInputs() async {
        let validCatalog = AppleStremioCatalog(type: "movie", id: "popular")
        let source = makeSource(catalogs: [validCatalog])
        let client = AppleStremioCatalogClient { _ in
            Issue.record("The loader must not run for invalid catalog sources.")
            throw URLError(.badURL)
        }

        await #expect(throws: AppleStremioCatalogError.invalidSource) {
            try await client.load(
                source: AppleSource(
                    kind: .stremio,
                    name: "Disabled",
                    url: source.url,
                    isEnabled: false,
                    resources: ["catalog"],
                    catalogs: [validCatalog]
                ),
                catalog: validCatalog
            )
        }
        await #expect(throws: AppleStremioCatalogError.invalidSource) {
            try await client.load(source: source, catalog: .init(type: "movie", id: "not-advertised"))
        }
        #expect(throws: AppleStremioCatalogError.invalidSource) {
            try AppleStremioCatalogClient.endpoint(
                source: AppleSource(
                    kind: .stremio,
                    name: "Query",
                    url: URL(string: "https://catalog.fixture/?fixture=1")!,
                    resources: ["catalog"],
                    catalogs: [validCatalog]
                ),
                catalog: validCatalog
            )
        }
    }

    private func makeSource(catalogs: [AppleStremioCatalog]) -> AppleSource {
        AppleSource(
            kind: .stremio,
            name: "Fixture Catalog",
            url: URL(string: "https://catalog.fixture/manifest.json")!,
            manifestID: "fixture.catalog",
            resources: ["catalog", "future-resource"],
            catalogs: catalogs
        )
    }

    private func makeClient(timeout: TimeInterval = 2) -> AppleStremioCatalogClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CatalogFixtureURLProtocol.self]
        configuration.timeoutIntervalForRequest = timeout
        let boundedClient = AppleBoundedHTTPClient(configuration: configuration)
        return AppleStremioCatalogClient { request in
            do {
                return try await boundedClient.load(
                    request,
                    maximumBytes: 2_000_000,
                    redirectPolicy: .follow,
                    behavior: .rejectOverflow
                )
            } catch AppleBoundedHTTPError.responseTooLarge {
                throw AppleStremioCatalogError.responseTooLarge
            }
        }
    }
}

private final class CatalogFixtureURLProtocol: URLProtocol, @unchecked Sendable {
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
    nonisolated(unsafe) private static var paths: [String] = []
    nonisolated(unsafe) private static var counts: [String: Int] = [:]
    nonisolated(unsafe) private static var audits: [RequestAudit] = []
    private let stateLock = NSLock()
    private var stopped = false

    static func configure(_ fixtures: [String: Fixture]) {
        lock.lock()
        self.fixtures = fixtures
        paths = []
        counts = [:]
        audits = []
        lock.unlock()
    }

    static func reset() { configure([:]) }

    static func requestedPaths() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return paths
    }

    static func requestCount(path: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[path, default: 0]
    }

    static func audit() -> [RequestAudit] {
        lock.lock()
        defer { lock.unlock() }
        return audits
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "catalog.fixture"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let fixture: Fixture?
        Self.lock.lock()
        fixture = Self.fixtures[url.path]
        Self.paths.append(url.path)
        Self.counts[url.path, default: 0] += 1
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        Self.audits.append(RequestAudit(
            hasAuthorizationHeader: request.value(forHTTPHeaderField: "Authorization") != nil,
            hasBody: request.httpBody != nil,
            hasURLCredentials: components?.user != nil || components?.password != nil
        ))
        Self.lock.unlock()

        guard let fixture else {
            send(statusCode: 404, body: Data(), responseURL: url, contentLength: 0)
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
        send(
            statusCode: fixture.statusCode,
            body: fixture.body,
            responseURL: fixture.responseURL ?? requestURL,
            contentLength: fixture.contentLength ?? Int64(fixture.body.count)
        )
    }

    private func send(statusCode: Int, body: Data, responseURL: URL, contentLength: Int64) {
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
