import Foundation
import Testing
@testable import OpenStreamApple

private actor BlockingSMBClient: AppleNetworkShareClient {
    var activeReads = 0
    var closeCount = 0
    private var blocksReads = true
    func allowReads() { blocksReads = false }
    func listShares(host: String, port: Int, credentials: AppleSMBCredentials) async throws -> [AppleSMBShare] { [] }
    func listDirectory(url: URL, credentials: AppleSMBCredentials, recursive: Bool) async throws -> [AppleSMBDirectoryEntry] { [] }
    func read(url: URL, credentials: AppleSMBCredentials, range: Range<UInt64>) async throws -> Data {
        activeReads += 1
        defer { activeReads -= 1 }
        // Stalls until `allowReads()`; only cancellation ends it sooner.
        while blocksReads { try await Task.sleep(for: .milliseconds(10)) }
        return Data(repeating: 1, count: Int(range.count))
    }
    func closeAll() async { closeCount += 1 }
}

private struct FixtureSMBMediaClient: AppleNetworkShareClient {
    let payload: Data
    func listShares(host: String, port: Int, credentials: AppleSMBCredentials) async throws -> [AppleSMBShare] { [] }
    func listDirectory(url: URL, credentials: AppleSMBCredentials, recursive: Bool) async throws -> [AppleSMBDirectoryEntry] { [] }
    func read(url: URL, credentials: AppleSMBCredentials, range: Range<UInt64>) async throws -> Data {
        try Task.checkCancellation()
        let lower = min(payload.count, Int(range.lowerBound))
        let upper = min(payload.count, Int(range.upperBound))
        return payload.subdata(in: lower..<upper)
    }
}

@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["PLAYBACK_ENGINE_TESTS"] == "1"))
func smbPlayerBridgeReachesPlaybackSeeksAndReleasesItsListener() async throws {
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/out/mp4-h264-aac.mp4")
    let payload = try Data(contentsOf: fixture)
    let server = AppleSMBRangeServer(client: FixtureSMBMediaClient(payload: payload))
    let playback = try await server.playbackURL(sourceURL: URL(string: "smb://fixture.invalid/Media/movie.mp4")!,
        credentials: .init(username: "fixture", password: "fixture"), sizeBytes: Int64(payload.count))
    let engine = NativePlaybackEngine()
    do {
        try await engine.load(.init(url: playback, mediaID: "smb-player-fixture", sourceKind: .files))
        let startDeadline = ContinuousClock.now.advanced(by: .seconds(8))
        while engine.position < 0.5, ContinuousClock.now < startDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(engine.position >= 0.5)
        await engine.seek(to: 5)
        let seekDeadline = ContinuousClock.now.advanced(by: .seconds(4))
        while engine.position < 5.5, ContinuousClock.now < seekDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(engine.position >= 5.5)
    } catch {
        engine.stop()
        await server.removeAllSessions()
        throw error
    }
    engine.stop()
    await server.revoke(playbackURL: playback)
    #expect(await server.diagnostics().sessionCount == 0)
    #expect(await server.diagnostics().connectionCount == 0)
    #expect(!(await server.diagnostics().listenerActive))
}

/// The waits have no wall-clock deadline: the server's tasks can be held up
/// for seconds by the parallel gate. The time limit fails a read that never
/// starts or is never cancelled.
@Test(.timeLimit(.minutes(1)))
func revokingOneSMBPlaybackCancelsItsReadWithoutClosingOtherSessions() async throws {
    let client = BlockingSMBClient()
    let server = AppleSMBRangeServer(client: client)
    let credentials = AppleSMBCredentials(username: "fixture", password: "fixture")
    let first = try await server.playbackURL(sourceURL: URL(string: "smb://fixture.invalid/Media/first.mp4")!, credentials: credentials, sizeBytes: 1_024)
    let second = try await server.playbackURL(sourceURL: URL(string: "smb://fixture.invalid/Media/second.mp4")!, credentials: credentials, sizeBytes: 1_024)
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let request = Task { try await session.data(from: first) }
    while await client.activeReads == 0 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(await client.activeReads == 1)
    await server.revoke(playbackURL: first)
    while await client.activeReads != 0 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(await client.closeCount == 0)
    #expect(await server.diagnostics().sessionCount == 1)
    #expect(await server.diagnostics().connectionCount == 0)
    request.cancel()
    _ = try? await request.value
    await server.revoke(playbackURL: second)
    #expect(await client.closeCount == 1)
}

/// The read stalls until allowed and the client's own timeout is far off, so
/// only the server's 100 ms read timeout can end the first response. The
/// time limit fails a server that never gives up.
@Test(.timeLimit(.minutes(1)))
func stalledSMBReadTimesOutReleasesConnectionAndAllowsRetry() async throws {
    let client = BlockingSMBClient()
    let server = AppleSMBRangeServer(client: client, readTimeout: .milliseconds(100))
    let playback = try await server.playbackURL(sourceURL: URL(string: "smb://fixture.invalid/Media/stall.mp4")!,
        credentials: .init(username: "fixture", password: "fixture"), sizeBytes: 1_024)
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    var request = URLRequest(url: playback)
    request.timeoutInterval = 3_600
    do {
        _ = try await session.data(for: request)
        Issue.record("Expected incomplete stalled response to fail")
    } catch {}
    // The client can see the dropped response before the server's cleanup lands.
    while await client.activeReads != 0 { try await Task.sleep(for: .milliseconds(10)) }
    while await server.diagnostics().connectionCount != 0 { try await Task.sleep(for: .milliseconds(10)) }
    await client.allowReads()
    let (data, response) = try await session.data(for: request)
    #expect(data == Data(repeating: 1, count: 1_024))
    #expect((response as? HTTPURLResponse)?.statusCode == 200)
    await server.removeAllSessions()
    #expect(!(await server.diagnostics().listenerActive))
}

/// Hands out a range as a first part and then 1 MiB parts, holding those until `release()`.
private actor GatedStreamClient: AppleNetworkShareClient {
    let payload: Data
    let firstPart: Int
    private(set) var opens = 0
    private(set) var reads = 0
    private(set) var cancels = 0
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(payload: Data, firstPart: Int) {
        self.payload = payload
        self.firstPart = firstPart
    }

    func listShares(host: String, port: Int, credentials: AppleSMBCredentials) async throws -> [AppleSMBShare] { [] }
    func listDirectory(url: URL, credentials: AppleSMBCredentials, recursive: Bool) async throws -> [AppleSMBDirectoryEntry] { [] }
    func read(url: URL, credentials: AppleSMBCredentials, range: Range<UInt64>) async throws -> Data {
        reads += 1
        return payload.subdata(in: Int(range.lowerBound) ..< Int(range.upperBound))
    }

    func openStream(url: URL, credentials: AppleSMBCredentials, range: Range<UInt64>) async throws
        -> any AppleNetworkShareFileStream {
        opens += 1
        let bytes = payload.subdata(in: Int(range.lowerBound) ..< Int(range.upperBound))
        let rest = stride(from: firstPart, to: bytes.count, by: 1_048_576).map {
            bytes.subdata(in: $0 ..< min($0 + 1_048_576, bytes.count))
        }
        return GatedStream(client: self, parts: [bytes.prefix(firstPart)] + rest)
    }

    func streamCancelled() {
        cancels += 1
        release()
    }

    func waitForRelease() async {
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

private actor GatedStream: AppleNetworkShareFileStream {
    let client: GatedStreamClient
    var parts: [Data]
    var handedOut = 0

    init(client: GatedStreamClient, parts: [Data]) {
        self.client = client
        self.parts = parts
    }

    func next() async throws -> Data? {
        guard !parts.isEmpty else { return nil }
        if handedOut > 0 { await client.waitForRelease() }
        try Task.checkCancellation()
        handedOut += 1
        return parts.removeFirst()
    }

    nonisolated func cancel() {
        Task { await client.streamCancelled() }
    }
}

/// REA round 4, fix 2: a range starts with small reads (a seek probe hangs up
/// within them), then the rest is one SMB open whose bytes reach the player
/// before the share has sent all of it (the bridge used to collect 4 MiB per open).
@Test func aLongRangeStartsSmallThenStreamsOneOpen() async throws {
    let payload = Data((0 ..< 6 * 1_024 * 1_024).map { UInt8($0 % 251) })
    let leading = Int(AppleSMBRangeServer.leadingReads.reduce(0, +))
    let firstPart = 64 * 1_024
    let client = GatedStreamClient(payload: payload, firstPart: firstPart)
    let server = AppleSMBRangeServer(client: client, addedLatency: .zero)
    let url = try await server.playbackURL(sourceURL: URL(string: "smb://fixture.invalid/Media/movie.mkv")!,
        credentials: .init(username: "fixture", password: "fixture"), sizeBytes: Int64(payload.count))
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let (bytes, response) = try await session.bytes(from: url)
    #expect((response as? HTTPURLResponse)?.statusCode == 200)
    var received = Data()
    var iterator = bytes.makeAsyncIterator()
    while received.count < leading + firstPart, let byte = try await iterator.next() { received.append(byte) }
    #expect(received == payload.prefix(leading + firstPart))
    await client.release()
    while let byte = try await iterator.next() { received.append(byte) }
    #expect(received == payload)
    #expect(await client.reads == AppleSMBRangeServer.leadingReads.count)
    #expect(await client.opens == 1)
    #expect(await server.readStats(playbackURL: url)?.smbOpens == AppleSMBRangeServer.leadingReads.count + 1)
    await server.removeAllSessions()
}

@Test func rangeRequestsShareOneKeptAliveConnection() async throws {
    let payload = Data((0 ..< 1_024 * 1_024).map { UInt8($0 % 251) })
    let server = AppleSMBRangeServer(client: FixtureSMBMediaClient(payload: payload), addedLatency: .zero)
    let url = try await server.playbackURL(sourceURL: URL(string: "smb://fixture.invalid/Media/movie.mkv")!,
        credentials: .init(username: "fixture", password: "fixture"), sizeBytes: Int64(payload.count))
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    for start in stride(from: 0, to: 3 * 65_536, by: 65_536) {
        var request = URLRequest(url: url)
        request.setValue("bytes=\(start)-\(start + 65_535)", forHTTPHeaderField: "Range")
        let (data, response) = try await session.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 206)
        #expect(data == payload.subdata(in: start ..< start + 65_536))
    }
    #expect(await server.diagnostics().connectionCount == 1)
    await server.removeAllSessions()
    #expect(await server.diagnostics().connectionCount == 0)
}

@Test func keepAliveFollowsTheRequest() {
    #expect(AppleSMBRangeServer.keepsAlive(requestLine: "GET /media/t/a.mkv HTTP/1.1", headers: ["Range: bytes=0-"]))
    #expect(!AppleSMBRangeServer.keepsAlive(requestLine: "GET /media/t/a.mkv HTTP/1.1", headers: ["Connection: close"]))
    #expect(!AppleSMBRangeServer.keepsAlive(requestLine: "GET /media/t/a.mkv HTTP/1.0", headers: []))
}

/// Starts an open-ended GET and returns once the gated stream has sent its first part.
private func openGatedBody(_ server: AppleSMBRangeServer, payload: Data, firstPart: Int,
                           session: URLSession) async throws -> (url: URL, body: Task<Void, any Error>) {
    let url = try await server.playbackURL(sourceURL: URL(string: "smb://fixture.invalid/Media/movie.mkv")!,
        credentials: .init(username: "fixture", password: "fixture"), sizeBytes: Int64(payload.count))
    let wanted = Int(AppleSMBRangeServer.leadingReads.reduce(0, +)) + firstPart
    let (started, startedContinuation) = AsyncStream<Void>.makeStream()
    let body = Task {
        defer { startedContinuation.finish() }
        let (bytes, _) = try await session.bytes(from: url)
        var received = 0
        for try await _ in bytes {
            received += 1
            if received == wanted { startedContinuation.yield() }
        }
    }
    for await _ in started { break }
    return (url, body)
}

private func waitForCancel(_ client: GatedStreamClient) async throws -> Int {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while await client.cancels == 0, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    return await client.cancels
}

@Test func aPlayerHangingUpMidBodyCancelsTheStream() async throws {
    // Far more than the loopback socket buffers hold, so a send after the hang-up fails.
    let payload = Data((0 ..< 40 * 1_024 * 1_024).map { UInt8($0 % 251) })
    let client = GatedStreamClient(payload: payload, firstPart: 64 * 1_024)
    let server = AppleSMBRangeServer(client: client, addedLatency: .zero)
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let (url, body) = try await openGatedBody(server, payload: payload, firstPart: 64 * 1_024, session: session)
    #expect(await client.cancels == 0)
    body.cancel()
    _ = try? await body.value
    // The share answers after the hang-up; the bridge's send fails and it lets go of the file.
    await client.release()
    #expect(try await waitForCancel(client) >= 1)
    #expect(await server.bytesServed(playbackURL: url) < UInt64(payload.count))
    #expect(await client.opens == 1)
    await server.removeAllSessions()
}

@Test func revokingAPlaybackMidBodyCancelsItsStream() async throws {
    let payload = Data((0 ..< 6 * 1_024 * 1_024).map { UInt8($0 % 251) })
    let client = GatedStreamClient(payload: payload, firstPart: 64 * 1_024)
    let server = AppleSMBRangeServer(client: client, addedLatency: .zero)
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let (url, body) = try await openGatedBody(server, payload: payload, firstPart: 64 * 1_024, session: session)
    await server.revoke(playbackURL: url)
    #expect(try await waitForCancel(client) >= 1)
    #expect(await server.diagnostics().connectionCount == 0)
    _ = try? await body.value
}
