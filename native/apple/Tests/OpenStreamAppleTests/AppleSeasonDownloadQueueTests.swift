import Foundation
import Testing
@testable import OpenStreamApple

@MainActor @Suite struct AppleSeasonDownloadQueueTests {
    @Test func downloadsInOrderAndIgnoresDuplicateEpisodes() async throws {
        let queue = AppleSeasonDownloadQueue()
        var visited: [String] = []
        queue.start(episodeIDs: ["one", "two", "one", "three"]) { id in visited.append(id) }
        await queue.waitUntilFinished()
        #expect(visited == ["one", "two", "three"])
        #expect(queue.completed == 3)
        #expect(queue.total == 3)
        #expect(queue.failure == nil)
    }
    @Test func failureStopsBeforeTheNextEpisodeAndCanBeRetried() async {
        let queue = AppleSeasonDownloadQueue()
        var visited: [String] = []
        queue.start(episodeIDs: ["one", "two", "three"]) { id in
            visited.append(id)
            if id == "two" { throw URLError(.notConnectedToInternet) }
        }
        await queue.waitUntilFinished()
        #expect(visited == ["one", "two"])
        #expect(queue.completed == 1)
        #expect(queue.failure != nil)
        queue.start(episodeIDs: ["two", "three"]) { _ in }
        await queue.waitUntilFinished()
        #expect(queue.completed == 2)
        #expect(queue.failure == nil)
    }
    @Test func cancellationDoesNotStartRemainingEpisodes() async {
        let queue = AppleSeasonDownloadQueue()
        var visited: [String] = []
        queue.start(episodeIDs: ["one", "two"]) { id in
            visited.append(id)
            try await Task.sleep(for: .seconds(20))
        }
        while visited.isEmpty { await Task.yield() }
        queue.cancel()
        await queue.waitUntilFinished()
        #expect(visited == ["one"])
        #expect(queue.completed == 0)
        #expect(!queue.isRunning)
    }

    @Test func cancellationClearsAStaleFailure() async {
        let queue = AppleSeasonDownloadQueue()
        queue.start(episodeIDs: ["one"]) { _ in
            throw URLError(.notConnectedToInternet)
        }
        await queue.waitUntilFinished()
        #expect(queue.failure != nil)
        queue.cancel()
        #expect(queue.failure == nil)
    }
}
