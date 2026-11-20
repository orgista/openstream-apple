import Foundation
import Synchronization
import Testing
@testable import OpenStreamApple

@Suite("Top 10 rows: TMDB's weekly chart kept on disk")
struct AppleTop10StoreTests {
    @Test(arguments: [false, true])
    func successfulEmptyChartsStayFreshAcrossCallsAndRelaunches(hasShows: Bool) async throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let calls = Mutex(0)
        let now = Date.now
        let configuration = try AppleTMDBConfiguration(credential: "fixture-key")
        let store = AppleTop10Store(fileURL: file) { [show] type, _ in
            calls.withLock { $0 += 1 }
            return type == "all" && hasShows ? [show] : []
        }
        let chart = try await store.latest(configuration: configuration, now: now)
        #expect(chart.items == (hasShows ? [show] : []))
        #expect(try await store.latest(configuration: configuration, now: now.addingTimeInterval(60)) == chart)
        #expect(calls.withLock { $0 } == 1)
        let relaunched = AppleTop10Store(fileURL: file) { _, _ in throw URLError(.notConnectedToInternet) }
        #expect(try await relaunched.latest(configuration: configuration, now: now.addingTimeInterval(120)) == chart)
    }

    @Test func combinedWeeklyChartKeepsTMDBOrderAndSeparatesMovieAndShowMetadata() async throws {
        let requests = Mutex<[String]>([])
        let client = AppleTMDBClient { request in
            let url = try #require(request.url)
            requests.withLock { $0.append(url.path) }
            guard url.path == "/3/trending/all/week" else { throw URLError(.resourceUnavailable) }
            let data = Data(#"{"results":[{"id":42,"media_type":"movie","title":"Movie"},{"id":7,"media_type":"person","name":"Person"},{"id":43,"media_type":"tv","name":"Show"}]}"#.utf8)
            let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (data, response)
        }
        let items = try await client.weeklyTop10(type: "all", configuration: AppleTMDBConfiguration(credential: "fixture"))
        #expect(items.map(\.name) == ["Movie", "Show"])
        #expect(items.map(\.type) == ["movie", "series"])
        let paths = requests.withLock { $0 }
        #expect(paths.contains("/3/movie/42"))
        #expect(paths.contains("/3/tv/43"))
        #expect(paths.contains("/3/person/7") == false)
    }

    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "top10-\(UUID().uuidString).json")
    }

    private let movie = AppleCatalogItem(mediaID: "tt1234567", type: "movie", name: "Nimona")
    private let show = AppleCatalogItem(mediaID: "tt7654321", type: "series", name: "Unabomber")

    @Test func aFreshChartIsKeptAndReadBackAfterARelaunch() async throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let calls = Mutex(0)
        let store = AppleTop10Store(fileURL: file) { [movie, show] type, _ in
            calls.withLock { $0 += 1 }
            return type == "all" ? [movie, show] : []
        }
        let configuration = try AppleTMDBConfiguration(credential: "fixture-key")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(await store.stored() == nil)
        let chart = try await store.latest(configuration: configuration, now: now)
        #expect(chart.items == [movie, show])
        _ = try await store.latest(configuration: configuration, now: now.addingTimeInterval(60))
        #expect(calls.withLock { $0 } == 1)

        let relaunched = AppleTop10Store(fileURL: file) { _, _ in [] }
        #expect(await relaunched.stored() == chart)
    }

    @Test func aStaleChartIsAskedAgainAndAFailureLeavesTheKeptOne() async throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let kept = AppleTop10Store.Chart(items: [movie, show], fetchedAt: now)
        try JSONEncoder().encode(kept).write(to: file)
        let configuration = try AppleTMDBConfiguration(credential: "fixture-key")

        let failing = AppleTop10Store(fileURL: file) { _, _ in throw URLError(.notConnectedToInternet) }
        #expect(try await failing.latest(configuration: configuration, now: now.addingTimeInterval(60)) == kept)
        await #expect(throws: URLError.self) {
            try await failing.latest(configuration: configuration, now: now.addingTimeInterval(AppleTop10Store.refreshInterval + 1))
        }
        #expect(await failing.stored() == kept)
    }
}
