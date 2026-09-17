import Foundation
import Testing
@testable import OpenStreamApple

@Suite(.serialized)
struct AppleCatalogSearchPipelineTests {
    @Test @MainActor
    func newerQueryCancelsNetworkWorkAndCannotBeOverwritten() async throws {
        let fixture = SearchFixture()
        let store = AppleCatalogSearchStore(
            client: AppleStremioCatalogClient(loader: fixture.load),
            debounce: .milliseconds(10),
            // This test verifies cancellation after the loader starts. A tiny
            // deadline could expire before startup on a busy build machine.
            deadline: .seconds(5),
            maximumResults: 10,
            maximumConcurrentRequests: 2
        )
        let slow = searchSource(host: "slow.fixture", name: "Slow")
        let fast = searchSource(host: "fast.fixture", name: "Fast")

        let first = Task { @MainActor in
            await store.search(query: "slow", sources: [slow], baseSections: []) { _ in [] }
        }
        try await waitUntil { fixture.didStart(host: "slow.fixture") }
        first.cancel()
        await store.search(query: "fast", sources: [fast], baseSections: []) { _ in [] }
        _ = await first.value

        #expect(store.results.map(\.title) == ["Fast Result"])
        #expect(fixture.wasCancelled(host: "slow.fixture"))
        #expect(store.metrics?.debounceDuration ?? .zero >= .milliseconds(8))
        #expect(fixture.requestsAreRedacted())
    }

    @Test @MainActor
    func searchIsConcurrentBoundedDeduplicatedAndPartiallySuccessful() async {
        let fixture = SearchFixture()
        let store = AppleCatalogSearchStore(
            client: AppleStremioCatalogClient(loader: fixture.load),
            debounce: .milliseconds(15),
            deadline: .milliseconds(100),
            maximumResults: 3,
            maximumConcurrentRequests: 6
        )
        let sources = [
            searchSource(host: "one.fixture", name: "One"),
            searchSource(host: "two.fixture", name: "Two"),
            searchSource(host: "bad.fixture", name: "Bad"),
            searchSource(host: "failed.fixture", name: "Failed"),
            searchSource(host: "late.fixture", name: "Late"),
        ]

        await store.search(query: "result", sources: sources, baseSections: []) { _ in [] }

        #expect(store.results.count == 3)
        #expect(store.results.map(\.title) == ["A Result", "B Result", "C Result"])
        let shared = store.results.first
        #expect(shared?.canonicalID == "tt1234567")
        #expect(shared?.availability.count == 2)
        #expect(shared?.summary == "Richer metadata")
        #expect(fixture.wasCancelled(host: "late.fixture"))
        #expect(store.metrics?.debounceDuration ?? .zero >= .milliseconds(12))
        // Was `fetchDuration < 180 ms`, which failed whenever the machine was
        // busy — it measured the host, not the pipeline. Concurrency is the
        // actual claim, so assert the overlap directly.
        #expect(fixture.maxConcurrentRequests >= 2)
        #expect(fixture.requestsAreRedacted())

        let requestCount = fixture.requestCount
        await store.search(query: "   \n", sources: sources, baseSections: []) { _ in [] }
        #expect(store.results.isEmpty)
        #expect(fixture.requestCount == requestCount)
    }

    private func searchSource(host: String, name: String) -> AppleSource {
        AppleSource(
            kind: .stremio,
            name: name,
            url: URL(string: "https://\(host)/manifest.json")!,
            resources: ["catalog"],
            catalogs: [
                .init(
                    type: "movie",
                    id: "searchable",
                    requiresInput: true,
                    supportsSearch: true
                ),
            ]
        )
    }

    private func waitUntil(
        _ predicate: @escaping @Sendable () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("Timed out waiting for the local fixture")
    }
}

private final class SearchFixture: @unchecked Sendable {
    private struct Audit {
        let hasAuthorization: Bool
        let hasBody: Bool
        let hasCredentials: Bool
    }

    private let lock = NSLock()
    private var startedHosts = Set<String>()
    private var inFlight = 0
    /// The most requests ever open at once. Proves the fetches overlapped
    /// without depending on how fast the machine happens to be.
    private var peakInFlight = 0
    private var cancelledHosts = Set<String>()
    private var audits: [Audit] = []

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return audits.count
    }

    func didStart(host: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return startedHosts.contains(host)
    }

    func wasCancelled(host: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelledHosts.contains(host)
    }

    func requestsAreRedacted() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return audits.allSatisfy {
            !$0.hasAuthorization && !$0.hasBody && !$0.hasCredentials
        }
    }

    func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let host = request.url?.host ?? ""
        recordStart(host: host, request: request)
        defer { recordFinish() }
        let delay: Duration = switch host {
        case "slow.fixture": .seconds(30)
        case "late.fixture": .milliseconds(400)
        case "one.fixture", "two.fixture": .milliseconds(40)
        default: .milliseconds(5)
        }

        do {
            try await Task.sleep(for: delay)
        } catch {
            recordCancellation(host: host)
            throw error
        }

        let status = host == "failed.fixture" ? 503 : 200
        let data: Data
        switch host {
        case "slow.fixture":
            data = payload([["id": "tt0000001", "type": "movie", "name": "Slow Result"]])
        case "fast.fixture":
            data = payload([["id": "tt0000002", "type": "movie", "name": "Fast Result"]])
        case "one.fixture":
            data = payload([
                ["id": "tt1234567", "type": "movie", "name": "A Result"],
                ["id": "tt2000001", "type": "movie", "name": "B Result"],
            ])
        case "two.fixture":
            data = payload([
                [
                    "id": "tt1234567",
                    "type": "movie",
                    "name": "A Result",
                    "description": "Richer metadata",
                ],
                ["id": "tt2000002", "type": "movie", "name": "C Result"],
                ["id": "tt2000003", "type": "movie", "name": "D Result"],
            ])
        case "bad.fixture":
            data = Data("{".utf8)
        default:
            data = payload([])
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (data, response)
    }

    private func payload(_ metas: [[String: String]]) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["metas": metas])) ?? Data()
    }

    /// How many requests were open simultaneously at the busiest moment.
    var maxConcurrentRequests: Int {
        lock.lock()
        defer { lock.unlock() }
        return peakInFlight
    }

    private func recordFinish() {
        lock.lock()
        inFlight -= 1
        lock.unlock()
    }

    private func recordStart(host: String, request: URLRequest) {
        lock.lock()
        startedHosts.insert(host)
        inFlight += 1
        peakInFlight = max(peakInFlight, inFlight)
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
}
