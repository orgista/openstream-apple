import Foundation
import Synchronization
import Testing
@testable import OpenStreamApple

/// The owner's Rill server: ~40 libraries, ~80 row requests per reload, a
/// reload at launch and on every return to Discover (rows-1107).
@MainActor
@Suite(.serialized)
struct AppleServerRowsLoadTests {
    private let source = AppleSource(kind: .mediaServer, name: "Fixture", url: URL(string: "https://fixture.example")!)
    private let session = AppleMediaServerSession(kind: .jellyfin, baseURL: URL(string: "https://fixture.example")!,
        accessToken: "fixture", userID: "fixture")

    private final class Requests: Sendable {
        struct Counts { var started = 0, active = 0, peak = 0 }
        private let counts = Mutex(Counts())
        var started: Int { counts.withLock { $0.started } }
        var peak: Int { counts.withLock { $0.peak } }
        func begin() { counts.withLock { $0.started += 1; $0.active += 1; $0.peak = max($0.peak, $0.active) } }
        func end() { counts.withLock { $0.active -= 1 } }
    }

    /// Movie libraries whose Latest answers after `delay`.
    nonisolated private func client(libraries: Int, delay: Duration = .zero, requests: Requests) -> AppleMediaServerClient {
        AppleMediaServerClient(loader: { request in
            requests.begin()
            defer { requests.end() }
            if delay > .zero { try await Task.sleep(for: delay) }
            let url = try #require(request.url)
            let json: String
            if url.path.hasSuffix("Views") {
                json = #"{"Items":["# + (0..<libraries).map {
                    #"{"Id":"lib\#($0)","Name":"Library \#($0)","CollectionType":"movies"}"#
                }.joined(separator: ",") + "]}"
            } else if url.path.hasSuffix("Latest") {
                let parent = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "ParentId" }?.value ?? "missing"
                json = "[" + (0..<4).map { #"{"Id":"\#(parent)-\#($0)","Name":"\#(parent) \#($0)","Type":"Movie"}"# }.joined(separator: ",") + "]"
            } else { json = #"{"Items":[],"TotalRecordCount":0}"# }
            return (Data(json.utf8), try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        })
    }

    private func cacheURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("rows.json")
    }

    @Test(.timeLimit(.minutes(1))) func aReloadRedrawsTheRowsAtMostOncePerSecond() async throws {
        let requests = Requests()
        let cache = cacheURL()
        defer { try? FileManager.default.removeItem(at: cache.deletingLastPathComponent()) }
        let store = AppleMediaServerLibraryStore(client: client(libraries: 40, delay: .milliseconds(40), requests: requests),
            cacheFileURL: cache)
        let revision = store.contentRevision
        let started = ContinuousClock.now
        await store.reload(sources: [source]) { _ in self.session }
        let elapsed = started.duration(to: .now)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        #expect(store.shelves.count == 40)
        // The first change, one per second after it, and the final state.
        #expect(Double(store.contentRevision - revision) <= seconds.rounded(.down) + 2,
            "\(store.contentRevision - revision) redraws in \(seconds) s")
    }

    @Test(.timeLimit(.minutes(1))) func aRecentCompleteReloadStandsInForTheNextOneEvenAfterRelaunch() async throws {
        let requests = Requests()
        let cache = cacheURL()
        defer { try? FileManager.default.removeItem(at: cache.deletingLastPathComponent()) }
        let loader = client(libraries: 3, requests: requests)
        let store = AppleMediaServerLibraryStore(client: loader, cacheFileURL: cache)
        await store.reload(sources: [source]) { _ in self.session }
        let first = requests.started
        #expect(first > 0)

        await store.reload(sources: [source], unlessReloadedWithin: AppleMediaServerLibraryStore.rowsFreshness) { _ in self.session }
        #expect(requests.started == first)

        let relaunched = AppleMediaServerLibraryStore(client: loader, cacheFileURL: cache)
        relaunched.loadPersisted(sources: [source]) { _ in self.session }
        await relaunched.reload(sources: [source], unlessReloadedWithin: AppleMediaServerLibraryStore.rowsFreshness) { _ in self.session }
        #expect(requests.started == first)
        #expect(relaunched.shelves == store.shelves)

        // A pull to refresh, or rows older than the window, load again.
        await relaunched.reload(sources: [source]) { _ in self.session }
        let forced = requests.started
        #expect(forced > first)
        await relaunched.reload(sources: [source], unlessReloadedWithin: 0) { _ in self.session }
        #expect(requests.started > forced)
    }

    @Test(.timeLimit(.minutes(1))) func rowRequestsWaitWhileATitleOpens() async throws {
        let requests = Requests()
        let cache = cacheURL()
        defer { try? FileManager.default.removeItem(at: cache.deletingLastPathComponent()) }
        let store = AppleMediaServerLibraryStore(client: client(libraries: 3, requests: requests), cacheFileURL: cache)
        AppleForegroundOpening.hold(for: .seconds(30))
        defer { AppleForegroundOpening.release() }
        let reload = Task { await store.reload(sources: [source]) { _ in self.session } }
        try await Task.sleep(for: .milliseconds(300))
        #expect(requests.started == 0)
        #expect(!store.shelves.contains { !$0.items.isEmpty })
        AppleForegroundOpening.release()
        await reload.value
        #expect(store.shelves.count == 3)
    }

    @Test(.timeLimit(.minutes(1))) func threeServersShareFourRequestSlots() async throws {
        let requests = Requests()
        let cache = cacheURL()
        defer { try? FileManager.default.removeItem(at: cache.deletingLastPathComponent()) }
        let sources = (0..<3).map { AppleSource(kind: .mediaServer, name: "Server \($0)", url: URL(string: "https://s\($0).fixture.example")!) }
        let store = AppleMediaServerLibraryStore(client: client(libraries: 6, delay: .milliseconds(30), requests: requests),
            cacheFileURL: cache)
        await store.reload(sources: sources) { _ in self.session }
        #expect(requests.peak == AppleMediaServerLibraryStore.maximumConcurrentLibraryRequests)
        #expect(Set(store.shelves.map(\.sourceID)) == Set(sources.map { $0.id }))
    }
}
