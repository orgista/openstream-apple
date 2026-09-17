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
        if blocksReads { try await Task.sleep(for: .seconds(10)) }
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

@Test func revokingOneSMBPlaybackCancelsItsReadWithoutClosingOtherSessions() async throws {
    let client = BlockingSMBClient()
    let server = AppleSMBRangeServer(client: client)
    let credentials = AppleSMBCredentials(username: "fixture", password: "fixture")
    let first = try await server.playbackURL(sourceURL: URL(string: "smb://fixture.invalid/Media/first.mp4")!, credentials: credentials, sizeBytes: 1_024)
    let second = try await server.playbackURL(sourceURL: URL(string: "smb://fixture.invalid/Media/second.mp4")!, credentials: credentials, sizeBytes: 1_024)
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let request = Task { try await session.data(from: first) }
    let startDeadline = ContinuousClock.now.advanced(by: .seconds(2))
    while await client.activeReads == 0, ContinuousClock.now < startDeadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await client.activeReads == 1)
    await server.revoke(playbackURL: first)
    let cancelDeadline = ContinuousClock.now.advanced(by: .seconds(1))
    while await client.activeReads != 0, ContinuousClock.now < cancelDeadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await client.activeReads == 0)
    #expect(await client.closeCount == 0)
    #expect(await server.diagnostics().sessionCount == 1)
    #expect(await server.diagnostics().connectionCount == 0)
    request.cancel()
    _ = try? await request.value
    await server.revoke(playbackURL: second)
    #expect(await client.closeCount == 1)
}

@Test func stalledSMBReadTimesOutReleasesConnectionAndAllowsRetry() async throws {
    let client = BlockingSMBClient()
    let server = AppleSMBRangeServer(client: client, readTimeout: .milliseconds(100))
    let playback = try await server.playbackURL(sourceURL: URL(string: "smb://fixture.invalid/Media/stall.mp4")!,
        credentials: .init(username: "fixture", password: "fixture"), sizeBytes: 1_024)
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    var request = URLRequest(url: playback)
    request.timeoutInterval = 2
    let start = ContinuousClock.now
    do {
        _ = try await session.data(for: request)
        Issue.record("Expected incomplete stalled response to fail")
    } catch {}
    #expect(start.duration(to: .now) < .seconds(2))
    #expect(await client.activeReads == 0)
    #expect(await server.diagnostics().connectionCount == 0)
    await client.allowReads()
    let (data, response) = try await session.data(for: request)
    #expect(data == Data(repeating: 1, count: 1_024))
    #expect((response as? HTTPURLResponse)?.statusCode == 200)
    await server.removeAllSessions()
    #expect(!(await server.diagnostics().listenerActive))
}
