import Foundation
import Synchronization
import Testing
@testable import OpenStreamApple

/// Counts requests a fake server loader saw.
final class RequestCounter: Sendable {
    private let count = Mutex(0)
    var value: Int { count.withLock { $0 } }
    @discardableResult func increment() -> Int { count.withLock { $0 += 1; return $0 } }
}

/// Walk b20r24: a hero's Play opened the title page, but the page's item
/// lookup never answered, so its `prepare()` never returned and autoplay never
/// ran. A title lookup now waits `answerLimit`, then asks once more on a new
/// connection.
@Suite("Media server lookups that get no answer", .timeLimit(.minutes(1)))
@MainActor
struct AppleMediaServerStallTests {
    let source = AppleSource(id: UUID(), kind: .mediaServer, name: "Fixture",
                             url: URL(string: "https://fixture.example/")!, isEnabled: true)
    var session: AppleMediaServerSession {
        AppleMediaServerSession(kind: .jellyfin, baseURL: source.url, accessToken: "tk", userID: "u")
    }
    nonisolated static let movie = Data(#"{"Id":"m1","Name":"Stalled Movie","Type":"Movie"}"#.utf8)

    /// Answers item lookups after `stalls` of them went unanswered; counts them.
    private func store(stalls: Int, itemCalls: RequestCounter) -> AppleMediaServerLibraryStore {
        let client = AppleMediaServerClient(loader: { request in
            let path = request.url!.path
            if path.hasSuffix("/Items/m1") {
                let call = itemCalls.increment()
                if call <= stalls { try await Task.sleep(for: .seconds(60)) }
                return (Self.movie, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            return (Data(#"{"Items":[]}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, deviceID: "fixture-device", answerLimit: .milliseconds(300))
        let defaults = UserDefaults(suiteName: "media-server-stall-\(UUID())")!
        return AppleMediaServerLibraryStore(client: client, progressDefaults: defaults)
    }

    @Test("An unanswered title lookup is asked again and the page gets its detail")
    func stalledLookupRetries() async throws {
        let calls = RequestCounter()
        let library = store(stalls: 1, itemCalls: calls)
        let session = session
        await library.reload(sources: [source]) { _ in session }
        let started = ContinuousClock.now
        let detail = try await library.detail(for: .init(sourceID: source.id, itemID: "m1"))
        #expect(detail.item.name == "Stalled Movie")
        #expect(calls.value == 2)
        #expect(started.duration(to: .now) < .seconds(5))
    }

    @Test("A lookup unanswered twice fails instead of holding the page")
    func twiceStalledLookupFails() async {
        let calls = RequestCounter()
        let library = store(stalls: 2, itemCalls: calls)
        let session = session
        await library.reload(sources: [source]) { _ in session }
        let started = ContinuousClock.now
        await #expect(throws: AppleMediaServerError.self) {
            try await library.detail(for: .init(sourceID: source.id, itemID: "m1"))
        }
        #expect(calls.value == 2)
        #expect(started.duration(to: .now) < .seconds(5))
    }

    @Test("Requests stuck on one connection replace the pool once")
    func poolReplacedOncePerStall() {
        let made = RequestCounter()
        let connection = AppleMediaServerConnection(makeSession: {
            made.increment()
            return URLSession(configuration: .ephemeral)
        })
        let stuck = connection.generation
        connection.replace(after: stuck)
        connection.replace(after: stuck)
        #expect(connection.generation == stuck + 1)
        #expect(made.value == 2)
    }
}
