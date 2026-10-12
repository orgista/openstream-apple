import Foundation
import Testing
@testable import OpenStreamApple

@Suite(.serialized)
struct AppleMetadataResolverTests {
    @Test
    func fallbackOrderingMergesRicherFieldsAndPreservesIdentity() async throws {
        let fixture = MetadataFixture()
        let preferred = metadataSource(host: "preferred.fixture", name: "Preferred")
        let secondary = metadataSource(host: "secondary.fixture", name: "Secondary")
        let unauthorized = metadataSource(host: "unauthorized.fixture", name: "Unauthorized")
        let empty = metadataSource(host: "empty.fixture", name: "Empty")
        let oversized = metadataSource(host: "oversized.fixture", name: "Oversized")
        let insecure = metadataSource(host: "insecure.fixture", name: "Insecure")
        let defaultSource = metadataSource(host: "default.fixture", name: "Default")
        // This test is about *ordering and merging*, not the deadline: it has
        // to walk all seven fixtures to assert the host order. Seven 5 ms
        // sleeps fit a 250 ms budget on an idle machine and do not when the
        // whole suite is running in parallel, which made it fail roughly one
        // run in four — every assertion at once, because a cut-short walk
        // merges nothing. The deadline itself is covered by the next test,
        // which keeps its 250 ms and asserts the elapsed time.
        let resolver = AppleMetadataResolver(
            sourceClient: AppleStremioMetadataClient(loader: fixture.load),
            overallDeadline: .seconds(5),
            defaultSource: defaultSource
        )

        let details = try await resolver.resolve(
            sources: [preferred, secondary, unauthorized, empty, oversized, insecure],
            preferredSourceID: preferred.id,
            type: "movie",
            mediaID: "tt1234567"
        )

        #expect(details?.mediaID == "tt1234567")
        #expect(details?.mediaType == "movie")
        #expect(details?.title == "Preferred Title")
        #expect(details?.releaseInfo == "2024")
        #expect(details?.overview == "Preferred description")
        #expect(details?.runtimeMinutes == 121)
        #expect(details?.genres == ["Drama", "Mystery"])
        #expect(details?.posterURL == URL(string: "https://image.fixture/poster.jpg"))
        #expect(details?.backdropURL == URL(string: "https://image.fixture/backdrop.jpg"))
        // Requests go out together, so only which hosts were asked is fixed;
        // the merge order is asserted by the fields above.
        #expect(Set(fixture.hosts) == [
            "preferred.fixture", "secondary.fixture", "unauthorized.fixture", "empty.fixture",
            "oversized.fixture", "insecure.fixture", "default.fixture",
        ])
        #expect(fixture.requestsAreRedacted())
    }

    @Test
    func missingInstalledMetadataUsesDefaultAndCancelsSlowPreferredSource() async throws {
        let fixture = MetadataFixture()
        let slow = metadataSource(host: "slow.fixture", name: "Slow")
        let noMetadata = AppleSource(
            kind: .stremio,
            name: "Catalog only",
            url: URL(string: "https://catalog-only.fixture/manifest.json")!,
            resources: ["catalog"]
        )
        let resolver = AppleMetadataResolver(
            sourceClient: AppleStremioMetadataClient(loader: fixture.load),
            requestDeadline: .milliseconds(100),
            overallDeadline: .milliseconds(250),
            defaultSource: metadataSource(host: "default.fixture", name: "Default")
        )

        let start = ContinuousClock().now
        let details = try await resolver.resolve(
            sources: [slow, noMetadata],
            preferredSourceID: slow.id,
            type: "series",
            mediaID: "tt7654321:1:2"
        )
        let elapsed = start.duration(to: ContinuousClock().now)

        #expect(details?.mediaID == "tt7654321:1:2")
        #expect(details?.title == "Default Episode")
        #expect(details?.runtimeMinutes == 42)
        #expect(details?.genres == ["Drama"])
        #expect(fixture.wasCancelled(host: "slow.fixture"))
        #expect(elapsed < .milliseconds(220))
        #expect(fixture.requestsAreRedacted())
    }

    private func metadataSource(host: String, name: String, manifestID: String? = nil) -> AppleSource {
        AppleSource(
            kind: .stremio,
            name: name,
            url: URL(string: "https://\(host)/manifest.json")!,
            manifestID: manifestID,
            resources: ["meta"]
        )
    }

    @Test
    func fallbackOrderingPrefersAddonsOverBuiltInCinemeta() async throws {
        let fixture = MetadataFixture()
        let cinemeta = metadataSource(host: "default.fixture", name: "Cinemeta", manifestID: "com.stremio.cinemeta")
        let addon = metadataSource(host: "secondary.fixture", name: "AIO", manifestID: "com.aio.meta")
        let defaultSource = metadataSource(host: "default.fixture", name: "Default", manifestID: "com.stremio.cinemeta")
        
        let resolver = AppleMetadataResolver(
            sourceClient: AppleStremioMetadataClient(loader: fixture.load),
            overallDeadline: .seconds(2),
            defaultSource: defaultSource
        )
        
        let details = try await resolver.resolve(
            sources: [cinemeta, addon],
            preferredSourceID: cinemeta.id,
            type: "movie",
            mediaID: "tt1234567"
        )
        
        #expect(details?.overview == "Preferred description")
        #expect(details?.title == "Preferred Title")
        #expect(Set(fixture.hosts) == ["secondary.fixture", "default.fixture"])
    }

    @Test
    func fallbackOrderingTwoAddOnsPreferredFirst() async throws {
        let fixture = MetadataFixture()
        let addon1 = metadataSource(host: "empty.fixture", name: "Addon1", manifestID: "com.addon1")
        let addon2 = metadataSource(host: "secondary.fixture", name: "Addon2", manifestID: "com.addon2")
        let defaultSource = metadataSource(host: "default.fixture", name: "Default", manifestID: "com.stremio.cinemeta")
        
        let resolver = AppleMetadataResolver(
            sourceClient: AppleStremioMetadataClient(loader: fixture.load),
            overallDeadline: .seconds(2),
            defaultSource: defaultSource
        )
        
        let details = try await resolver.resolve(
            sources: [addon2, addon1],
            preferredSourceID: addon1.id,
            type: "movie",
            mediaID: "tt1234567"
        )
        
        #expect(Set(fixture.hosts).isSuperset(of: ["empty.fixture", "secondary.fixture"]))
        #expect(details?.title == "Preferred Title")
    }

    @Test
    func fallbackOrderingNoAddOnsCinemetaResolves() async throws {
        let fixture = MetadataFixture()
        let cinemeta = metadataSource(host: "default.fixture", name: "Cinemeta", manifestID: "com.stremio.cinemeta")
        let defaultSource = metadataSource(host: "default.fixture", name: "Default", manifestID: "com.stremio.cinemeta")
        
        let resolver = AppleMetadataResolver(
            sourceClient: AppleStremioMetadataClient(loader: fixture.load),
            overallDeadline: .seconds(2),
            defaultSource: defaultSource
        )
        
        let details = try await resolver.resolve(
            sources: [cinemeta],
            preferredSourceID: cinemeta.id,
            type: "movie",
            mediaID: "tt1234567"
        )
        
        #expect(details?.title == "Default Title")
        #expect(details?.runtimeMinutes == 121)
    }

    @Test
    func fallbackOrderingAddOnFailsCinemetaFillsIn() async throws {
        let fixture = MetadataFixture()
        let failingAddon = metadataSource(host: "unauthorized.fixture", name: "FailingAddon", manifestID: "com.failing")
        let cinemeta = metadataSource(host: "default.fixture", name: "Cinemeta", manifestID: "com.stremio.cinemeta")
        let defaultSource = metadataSource(host: "default.fixture", name: "Default", manifestID: "com.stremio.cinemeta")
        
        let resolver = AppleMetadataResolver(
            sourceClient: AppleStremioMetadataClient(loader: fixture.load),
            overallDeadline: .seconds(2),
            defaultSource: defaultSource
        )
        
        let details = try await resolver.resolve(
            sources: [failingAddon, cinemeta],
            preferredSourceID: failingAddon.id,
            type: "movie",
            mediaID: "tt1234567"
        )
        
        #expect(details?.title == "Default Title")
        #expect(details?.runtimeMinutes == 121)
    }

}

private final class MetadataFixture: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requestHosts: [String] = []
    private var cancelledHosts = Set<String>()
    private var audits: [Audit] = []

    func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let host = request.url?.host ?? ""
        recordRequest(host: host, request: request)

        do {
            try await Task.sleep(for: host == "slow.fixture" ? .milliseconds(300) : .milliseconds(5))
        } catch {
            recordCancellation(host: host)
            throw error
        }

        let status = host == "preferred.fixture" ? 403 : 200
        let body: Data
        if host == "secondary.fixture" {
            body = Data(#"{"meta":{"id":"tt1234567","type":"movie","name":"Preferred Title","description":"Preferred description","releaseInfo":"2024","poster":"https://image.fixture/poster.jpg"}}"#.utf8)
        } else if host == "default.fixture" && request.url?.path.contains("tt7654321") == true {
            body = Data(#"{"meta":{"id":"tt7654321:1:2","type":"episode","name":"Default Episode","runtime":"42","genre":["Drama"]}}"#.utf8)
        } else if host == "default.fixture" {
            body = Data(#"{"meta":{"id":"tt1234567","type":"movie","name":"Default Title","runtime":121,"genres":["Drama","Mystery"],"background":"https://image.fixture/backdrop.jpg"}}"#.utf8)
        } else if host == "empty.fixture" {
            body = Data(#"{"meta":{}}"#.utf8)
        } else if host == "oversized.fixture" {
            body = Data(repeating: 97, count: 2_000_001)
        } else {
            body = Data("{".utf8)
        }
        let responseURL = host == "insecure.fixture"
            ? URL(string: "http://insecure.fixture/meta/movie/tt1234567.json")!
            : request.url!
        let responseStatus = host == "unauthorized.fixture" ? 401 : status
        let response = HTTPURLResponse(
            url: responseURL,
            statusCode: responseStatus,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (body, response)
    }

    private func recordRequest(host: String, request: URLRequest) {
        lock.lock()
        requestHosts.append(host)
        audits.append(Audit(
            hasAuthorization: request.value(forHTTPHeaderField: "Authorization") != nil,
            hasBody: request.httpBody != nil || request.httpBodyStream != nil,
            hasCredentials: request.url?.user != nil || request.url?.password != nil
        ))
        lock.unlock()
    }

    private func recordCancellation(host: String) {
        lock.lock()
        cancelledHosts.insert(host)
        lock.unlock()
    }

    func wasCancelled(host: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelledHosts.contains(host)
    }

    func requestsAreRedacted() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return audits.allSatisfy { !$0.hasAuthorization && !$0.hasBody && !$0.hasCredentials }
    }

    var hosts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return requestHosts
    }

    private struct Audit {
        let hasAuthorization: Bool
        let hasBody: Bool
        let hasCredentials: Bool
    }
}

