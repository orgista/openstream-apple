import Foundation
import Testing
@testable import OpenStreamApple

@Suite("Durable remote progress outbox")
@MainActor
struct AppleRemoteProgressOutboxTests {
    private func defaults() -> UserDefaults {
        let name = "remote-outbox-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defaults.set(name, forKey: "test-domain")
        return defaults
    }

    private func clean(_ defaults: UserDefaults) {
        if let name = defaults.string(forKey: "test-domain") { defaults.removePersistentDomain(forName: name) }
    }

    private func entry(_ event: AppleRemoteProgressOutbox.Event, item: String = "episode1", playback: UUID = UUID(), position: Double = 20) -> AppleRemoteProgressOutbox.Entry {
        .init(sourceID: sourceID, itemID: item, playbackID: playback, kind: .plex,
              mediaSourceID: "part", playSessionID: nil, event: event, position: position,
              duration: 100, targetPlayCount: event == .scrobble ? 1 : nil)
    }
    private let sourceID = UUID()

    @Test func fileMigrationPreservesPendingEventsAndCompletionCheckpoints() throws {
        let storage = defaults()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { clean(storage); try? FileManager.default.removeItem(at: root) }
        let legacy = AppleRemoteProgressOutbox(defaults: storage)
        let completion = entry(.scrobble)
        legacy.enqueue(completion)
        legacy.checkpointPlayCount(entryID: completion.id, count: 0)
        let expected = legacy.entries
        let migrated = AppleRemoteProgressOutbox(defaults: storage, blobDirectory: root)
        #expect(migrated.entries == expected)
        #expect(storage.data(forKey: "openstream.remote-progress.outbox.v1") == nil)
        let reopened = AppleRemoteProgressOutbox(defaults: storage, blobDirectory: root)
        #expect(reopened.entries == expected)
        #expect(reopened.highestCompletionTarget(for: .init(sourceID: sourceID, itemID: completion.itemID)) == 1)
    }

    @Test("Failed stop survives relaunch and holds the next episode behind it")
    func failedStopRelaunch() async {
        let storage = defaults()
        defer { clean(storage) }
        let first = AppleRemoteProgressOutbox(defaults: storage)
        first.enqueue(entry(.stopped))
        first.enqueue(entry(.started, item: "episode2"))
        var sent: [String] = []
        await first.drain(now: Date(timeIntervalSince1970: 100)) { value in
            sent.append(value.itemID)
            throw URLError(.notConnectedToInternet)
        }
        #expect(sent == ["episode1"])
        let restored = AppleRemoteProgressOutbox(defaults: storage)
        #expect(restored.entries.count == 2)
        await restored.drain(now: Date(timeIntervalSince1970: 100)) { sent.append($0.itemID) }
        #expect(sent == ["episode1"])
        await restored.drain(now: Date(timeIntervalSince1970: 102)) { sent.append($0.itemID) }
        #expect(sent == ["episode1", "episode1", "episode2"])
        #expect(restored.entries.isEmpty)
    }

    @Test("Coalescing retains start stop and latest intermediate state per playback")
    func coalesces() async {
        let storage = defaults()
        defer { clean(storage) }
        let box = AppleRemoteProgressOutbox(defaults: storage)
        let play = UUID()
        box.enqueue(entry(.started, playback: play))
        box.enqueue(entry(.progress, playback: play, position: 20))
        box.enqueue(entry(.progress, playback: play, position: 30))
        box.enqueue(entry(.paused, playback: play, position: 40))
        box.enqueue(entry(.stopped, playback: play, position: 45))
        var events: [AppleRemoteProgressOutbox.Event] = []
        var positions: [Double] = []
        await box.drain { events.append($0.event); positions.append($0.position) }
        #expect(events == [.started, .paused, .stopped])
        #expect(positions == [20, 40, 45])
    }

    @Test("Acknowledged stop is not resent when scrobble fails")
    func checkpointScrobble() async {
        let storage = defaults()
        defer { clean(storage) }
        let box = AppleRemoteProgressOutbox(defaults: storage)
        box.enqueue([entry(.stopped), entry(.scrobble)])
        #expect(AppleRemoteProgressOutbox(defaults: storage).entries.map(\.event) == [.stopped, .scrobble])
        var events: [AppleRemoteProgressOutbox.Event] = []
        await box.drain(now: Date(timeIntervalSince1970: 10)) { value in
            events.append(value.event)
            if value.event == .scrobble { throw URLError(.timedOut) }
        }
        let restored = AppleRemoteProgressOutbox(defaults: storage)
        await restored.drain(now: Date(timeIntervalSince1970: 12)) { events.append($0.event) }
        #expect(events == [.stopped, .scrobble, .scrobble])
    }

    @Test("Retries stay bounded and retain pending final state")
    func backoffBounded() async {
        let storage = defaults()
        defer { clean(storage) }
        let box = AppleRemoteProgressOutbox(defaults: storage)
        box.enqueue(entry(.stopped))
        var now = Date(timeIntervalSince1970: 10)
        for _ in 0..<20 {
            await box.drain(now: now) { _ in throw URLError(.timedOut) }
            let next = box.entries[0].nextAttemptAt
            #expect(next.timeIntervalSince(now) <= 300)
            #expect(box.entries[0].attempts <= 8)
            now = next
        }
        #expect(box.entries.count == 1)
    }

    @Test("Reentrant coalescing cannot erase an update arriving during delivery")
    func inFlightUpdate() async {
        let storage = defaults()
        defer { clean(storage) }
        let box = AppleRemoteProgressOutbox(defaults: storage)
        let play = UUID()
        box.enqueue(entry(.progress, playback: play, position: 20))
        var sent: [Double] = []
        await box.drain { value in
            sent.append(value.position)
            if value.position == 20 { box.enqueue(entry(.progress, playback: play, position: 40)) }
        }
        #expect(sent == [20, 40])
    }
    @Test("Interleaved items coalesce independently without crossing stop boundaries")
    func interleaved() {
        let storage = defaults()
        defer { clean(storage) }
        let box = AppleRemoteProgressOutbox(defaults: storage)
        let first = UUID(), second = UUID()
        box.enqueue(entry(.progress, playback: first, position: 20))
        box.enqueue(entry(.progress, item: "episode2", playback: second, position: 20))
        box.enqueue(entry(.progress, playback: first, position: 40))
        #expect(box.entries.count == 2)
        #expect(box.entries[0].position == 40)
        box.enqueue(entry(.stopped, playback: first))
        box.enqueue(entry(.progress, playback: first, position: 50))
        #expect(box.entries.count == 4)
    }

    @Test("Disabled sources and missing credentials retain queued stops until reenabled")
    func sourceLifecycle() async throws {
        let storage = defaults()
        defer { clean(storage) }
        let fake = RemoteFakeServer(kind: .emby)
        let client = AppleMediaServerClient(loader: { try await fake.load($0) })
        var source = AppleSource(id: sourceID, kind: .mediaServer, name: "Fixture", url: URL(string: "https://fixture.example/")!, isEnabled: true)
        let session = AppleMediaServerSession(kind: .emby, baseURL: source.url, accessToken: "fixture", userID: "fixture")
        let store = AppleMediaServerLibraryStore(client: client, progressDefaults: storage)
        store.automaticallyDeliversRemoteProgress = false
        await store.reload(sources: [source]) { _ in session }
        let reference = AppleMediaServerItemReference(sourceID: source.id, itemID: "movie")
        let detail = try await store.detail(for: reference)
        let request = try await store.playbackRequest(for: detail.item, in: detail, resume: false)
        // Invalidate credentials before the active ticket posts its final stop.
        await store.reload(sources: [source]) { _ in nil }
        store.handleRemoteProgress(mediaID: request.mediaID, position: 20, duration: 100, event: .stopped)
        await store.flushRemoteProgress()
        #expect(await fake.completions == 0)
        #expect(AppleRemoteProgressOutbox(defaults: storage).entries.count == 1)
        source.isEnabled = false
        store.clear(sourceID: source.id)
        await store.reload(sources: [source]) { _ in session }
        await store.flushRemoteProgress()
        #expect(await fake.completions == 0)
        #expect(AppleRemoteProgressOutbox(defaults: storage).entries.count == 1)
        source.isEnabled = true
        await store.reload(sources: [source]) { _ in session }
        await store.flushRemoteProgress()
        await store.flushRemoteProgress(now: Date().addingTimeInterval(300))
        #expect(await fake.completions == 1)
        #expect(AppleRemoteProgressOutbox(defaults: storage).entries.isEmpty)
    }

    @Test("Only truly deleted source IDs purge pending entries and completion reservations")
    func removedSourcePurges() async {
        let storage = defaults()
        defer { clean(storage) }
        let box = AppleRemoteProgressOutbox(defaults: storage)
        box.enqueue([entry(.stopped), entry(.scrobble)])
        let store = AppleMediaServerLibraryStore(progressDefaults: storage)
        store.automaticallyDeliversRemoteProgress = false
        store.clear(sourceID: sourceID)
        #expect(AppleRemoteProgressOutbox(defaults: storage).entries.count == 2)
        await store.reload(sources: []) { _ in nil }
        let restored = AppleRemoteProgressOutbox(defaults: storage)
        #expect(restored.entries.isEmpty)
        #expect(restored.highestCompletionTarget(for: .init(sourceID: sourceID, itemID: "episode1")) == 0)
    }

    @Test("Partial stop response loss cannot duplicate a provider play count", arguments: [AppleMediaServerKind.jellyfin, .emby])
    func ambiguousPartialStop(kind: AppleMediaServerKind) async throws {
        let fake = RemoteFakeServer(kind: kind)
        let storage = defaults()
        defer { clean(storage) }
        let client = AppleMediaServerClient(loader: { try await fake.load($0) })
        let source = AppleSource(id: UUID(), kind: .mediaServer, name: "Fixture", url: URL(string: "https://fixture.example/")!, isEnabled: true)
        let session = AppleMediaServerSession(kind: kind, baseURL: source.url, accessToken: "fixture", userID: "fixture")
        let store = AppleMediaServerLibraryStore(client: client, progressDefaults: storage)
        store.automaticallyDeliversRemoteProgress = false
        await store.reload(sources: [source]) { _ in session }
        let reference = AppleMediaServerItemReference(sourceID: source.id, itemID: "movie")
        let detail = try await store.detail(for: reference)
        let request = try await store.playbackRequest(for: detail.item, in: detail, resume: false)
        store.handleRemoteProgress(mediaID: request.mediaID, position: 20, duration: 100, event: .stopped)
        await store.flushRemoteProgress()
        await store.flushRemoteProgress(now: Date().addingTimeInterval(300))
        let count = await fake.completions
        #expect(count == 1)
        #expect(AppleRemoteProgressOutbox(defaults: storage).entries.isEmpty)
    }

    @Test("Applied response loss is reconciled before repeating completion", arguments: [AppleMediaServerKind.plex, .jellyfin, .emby])
    func ambiguousCompletion(kind: AppleMediaServerKind) async throws {
        let fake = RemoteFakeServer(kind: kind)
        let client = AppleMediaServerClient(loader: { try await fake.load($0) })
        let plex = ApplePlexClient(loader: { try await fake.load($0) })
        let storage = defaults()
        defer { clean(storage) }
        let source = AppleSource(id: UUID(), kind: .mediaServer, name: "Fixture", url: URL(string: "https://fixture.example/")!, isEnabled: true)
        let session = AppleMediaServerSession(kind: kind, baseURL: source.url, accessToken: "fixture", userID: "fixture")
        let store = AppleMediaServerLibraryStore(client: client, plexClient: plex, progressDefaults: storage)
        store.automaticallyDeliversRemoteProgress = false
        await store.reload(sources: [source]) { _ in session }
        let reference = AppleMediaServerItemReference(sourceID: source.id, itemID: "movie")
        let detail = try await store.detail(for: reference)
        let request = try await store.playbackRequest(for: detail.item, in: detail, resume: false)
        store.handleRemoteProgress(mediaID: request.mediaID, position: 99, duration: 100, event: .stopped)
        await store.flushRemoteProgress()
        let applied = await fake.completions
        #expect(applied == 1)
        // Relaunch resolves credentials afresh and retries the pending phase.
        let restored = AppleMediaServerLibraryStore(client: client, plexClient: plex, progressDefaults: storage)
        restored.automaticallyDeliversRemoteProgress = false
        await restored.reload(sources: [source]) { _ in session }
        await restored.flushRemoteProgress(now: Date().addingTimeInterval(300))
        let final = await fake.completions
        #expect(final == 1)
        #expect(AppleRemoteProgressOutbox(defaults: storage).entries.isEmpty)
        // Late ticks on the stopped ticket cannot replace its terminal state.
        store.handleRemoteProgress(mediaID: request.mediaID, position: 20, duration: 100, event: .progress)
        #expect(AppleRemoteProgressOutbox(defaults: storage).entries.isEmpty)
        // A new completed rewatch reserves another count after relaunch,
        // including when the acknowledged old queue is empty.
        let rewatchDetail = try await restored.detail(for: reference)
        let rewatch = try await restored.playbackRequest(for: rewatchDetail.item, in: rewatchDetail, resume: false)
        restored.handleRemoteProgress(mediaID: rewatch.mediaID, position: 99, duration: 100, event: .stopped)
        await restored.flushRemoteProgress(now: Date().addingTimeInterval(301))
        let rewatchedCount = await fake.completions
        #expect(rewatchedCount == 2)
    }

}


private actor RemoteFakeServer {
    let kind: AppleMediaServerKind
    private(set) var completions = 0
    init(kind: AppleMediaServerKind) { self.kind = kind }

    func load(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        let path = url.path
        if path.hasSuffix("scrobble") || path.hasSuffix("Stopped") {
            completions += 1
            if completions == 1 { throw URLError(.timedOut) }
        }
        let json: String
        if kind == .plex {
            if path.hasSuffix("movie") {
                json = """
                {"MediaContainer":{"Metadata":[{"ratingKey":"movie","key":"/library/metadata/movie","type":"movie","title":"Fixture","duration":100000,"viewCount":\(completions),"Media":[{"Part":[{"key":"/library/parts/fixture","container":"mp4"}]}]}]}}
                """
            } else {
                json = "{\"MediaContainer\":{\"Metadata\":[],\"Directory\":[]}}"
            }
        } else if path.hasSuffix("PlaybackInfo") {
            json = "{\"MediaSources\":[{\"Id\":\"part\",\"SupportsDirectStream\":true}],\"PlaySessionId\":\"session\"}"
        } else if path.hasSuffix("movie") {
            json = """
            {"Id":"movie","Name":"Fixture","Type":"Movie","RunTimeTicks":1000000000,"UserData":{"PlayCount":\(completions),"Played":\(completions > 0)}}
            """
        } else { json = "{\"Items\":[],\"TotalRecordCount\":0}" }
        return (Data(json.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
