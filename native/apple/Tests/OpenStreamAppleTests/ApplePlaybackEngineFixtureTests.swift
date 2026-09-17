import Foundation
import Testing
@testable import OpenStreamApple

// Engine fixture tests run against a real `AetherPlaybackEngine` talking to the
// loopback fixture server from Task 0. They are gated behind
// `PLAYBACK_ENGINE_TESTS=1` and pick the server up at `FIXTURE_BASE_URL`
// (default `http://127.0.0.1:8765`); start the server first:
//
//   python3 Tests/Fixtures/serve.py &
//   PLAYBACK_ENGINE_TESTS=1 swift test --scratch-path … --filter ApplePlaybackEngineFixtureTests

private let fixtureEnabled = ProcessInfo.processInfo.environment["PLAYBACK_ENGINE_TESTS"] == "1"

@MainActor
private func fixtureBaseURL() -> URL {
    let raw = ProcessInfo.processInfo.environment["FIXTURE_BASE_URL"] ?? "http://127.0.0.1:8765"
    let trimmed = raw.hasSuffix("/") ? raw : raw + "/"
    return URL(string: trimmed)!
}

@MainActor
private func fixtureURL(_ path: String) -> URL {
    fixtureBaseURL().appendingPathComponent(path)
}

/// Consume `events` until a phase matching `predicate` is observed, or `timeout`
/// elapses. Every property change the engine emits flows through this stream.
@MainActor
private func waitForPhase(
    _ engine: any ApplePlaybackEngine,
    timeout: TimeInterval,
    matching predicate: (ApplePlaybackEnginePhase) -> Bool
) async {
    if predicate(engine.phase) { return }
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(timeout))
    while clock.now < deadline, !Task.isCancelled {
        if predicate(engine.phase) { return }
        try? await Task.sleep(for: .milliseconds(50))
    }
    Issue.record("Timed out waiting for playback phase; current \(engine.phase), route \(engine.route)")
}

@MainActor
private func waitForPlaying(_ engine: any ApplePlaybackEngine, timeout: TimeInterval = 10) async {
    await waitForPhase(engine, timeout: timeout) { $0 == .playing }
}

@MainActor
private func waitForError(_ engine: any ApplePlaybackEngine, timeout: TimeInterval) async {
    await waitForPhase(engine, timeout: timeout) {
        if case .error = $0 { return true }
        return false
    }
}

@MainActor
private func waitForPosition(_ engine: any ApplePlaybackEngine, atLeast target: Double, timeout: TimeInterval) async {
    if engine.position >= target { return }
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(timeout))
    while clock.now < deadline, !Task.isCancelled {
        if engine.position >= target { return }
        try? await Task.sleep(for: .milliseconds(50))
    }
    Issue.record("Timed out waiting for position >= \(target); current \(engine.position)")
}

@MainActor
private func waitForAudioTracks(_ engine: any ApplePlaybackEngine, timeout: TimeInterval) async {
    if !engine.audioTracks.isEmpty { return }
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(timeout))
    while clock.now < deadline, !Task.isCancelled {
        if !engine.audioTracks.isEmpty { return }
        try? await Task.sleep(for: .milliseconds(50))
    }
}

@MainActor
private func waitForSubtitleTracks(_ engine: any ApplePlaybackEngine, timeout: TimeInterval) async {
    if !engine.subtitleTracks.isEmpty { return }
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(timeout))
    while clock.now < deadline, !Task.isCancelled {
        if !engine.subtitleTracks.isEmpty { return }
        try? await Task.sleep(for: .milliseconds(50))
    }
}

@MainActor
private func makeEngine() throws -> AetherPlaybackEngine {
    try AetherPlaybackEngine()
}

@MainActor
private func load(_ engine: AetherPlaybackEngine, path: String, isLive: Bool = false, headers: [String: String] = [:]) async throws {
    try await engine.load(
        ApplePlaybackRequest(
            url: fixtureURL(path),
            headers: headers,
            isLive: isLive,
            mediaID: path,
            sourceKind: isLive ? .iptv : .files
        )
    )
}

// MARK: - Routes

@Test(.enabled(if: fixtureEnabled))
@MainActor
func aetherPlaysH264AacMP4OverRemoteBypassRoute() async throws {
    let engine = try makeEngine()
    try await load(engine, path: "media/mp4-h264-aac.mp4")
    await waitForPlaying(engine, timeout: 10)
    await waitForPosition(engine, atLeast: 1, timeout: 5)
    #expect(engine.route == .avPlayer)
    if let duration = engine.duration {
        #expect(duration >= 10 && duration <= 20)
    } else {
        Issue.record("Expected a finite VOD duration; got nil")
    }
    engine.stop()
}

@Test(.enabled(if: fixtureEnabled))
@MainActor
func aetherPlaysH264AacMKVOverLoopbackRoute() async throws {
    let engine = try makeEngine()
    try await load(engine, path: "media/mkv-h264-aac.mkv")
    await waitForPlaying(engine, timeout: 10)
    await waitForPosition(engine, atLeast: 1, timeout: 5)
    #expect(engine.route == .avPlayer)
    engine.stop()
}

@Test(.enabled(if: fixtureEnabled))
@MainActor
func aetherListsSubtitleTrackForMKVWithEmbeddedSRT() async throws {
    let engine = try makeEngine()
    try await load(engine, path: "media/mkv-h264-aac.mkv")
    await waitForPlaying(engine, timeout: 15)
    await waitForSubtitleTracks(engine, timeout: 5)
    #expect(engine.subtitleTracks.count >= 1, "Expected at least one subtitle track; got \(engine.subtitleTracks.count)")
    engine.stop()
}

@Test
@MainActor
func offlineDownloadBuildsAFilesRequestAndPlaysThroughTheEngine() async throws {
    // The offline record is a local file played directly through the engine;
    // no AVAssetExportSession is attempted for Matroska. Copy the fixture into
    // a temp offline library dir and build the request the source view would.
    let testFile = URL(fileURLWithPath: #filePath)
    let fixture = testFile.deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/out/mkv-h264-aac.mkv")
    guard FileManager.default.fileExists(atPath: fixture.path) else { return }
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("openstream-offline-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    let fileURL = tempDir.appendingPathComponent("mkv-h264-aac.mkv")
    try FileManager.default.copyItem(at: fixture, to: fileURL)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let request = ApplePlaybackRequest(
        url: fileURL,
        isLive: false,
        mediaID: "offline:mkv-h264-aac",
        title: "Downloaded Video",
        sourceKind: .files
    )
    #expect(request.sourceKind == .files)
    #expect(request.url.isFileURL)
    #expect(request.url == fileURL)
    #expect(request.isLive == false)

    guard fixtureEnabled else { return }
    let engine = try makeEngine()
    try await engine.load(request)
    await waitForPlaying(engine, timeout: 15)
    #expect(engine.route == .avPlayer)
    engine.stop()
}

@Test
@MainActor
func libraryPreparationLetsOpenStreamPlayMatroska() async throws {
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/out/mkv-h264-aac.mkv")
    let prepared = try await ApplePlaybackPreparer().prepareLibraryMedia(
        sourceURL: fixture, preferredEngine: .openStream
    )
    #expect(prepared.url == fixture)
    #expect(prepared.route == .direct(fixture))
    let engine = try AetherPlaybackEngine()
    defer { engine.stop() }
    try await engine.load(.init(url: prepared.url, mediaID: "library-preparation-fixture", sourceKind: .files))
    await waitForPosition(engine, atLeast: 1, timeout: 8)
    #expect(engine.position >= 1)
}

@Test(.enabled(if: fixtureEnabled))
@MainActor
func aetherPlaysLiveTSWithNilDuration() async throws {
    let engine = try makeEngine()
    try await load(engine, path: "live/ts-h264-aac.ts", isLive: true)
    await waitForPlaying(engine, timeout: 15)
    await waitForPosition(engine, atLeast: 1, timeout: 5)
    #expect(engine.duration == nil)
    engine.stop()
}

@Test(.enabled(if: fixtureEnabled))
@MainActor
func aetherExposesEAC3AudioTrackForHEVCMKV() async throws {
    let engine = try makeEngine()
    try await load(engine, path: "media/mkv-hevc-eac3.mkv")
    await waitForPlaying(engine, timeout: 15)
    await waitForAudioTracks(engine, timeout: 5)
    let codec = engine.audioTracks.first?.codec?.lowercased()
    #expect(codec?.contains("eac3") == true, "Expected an E-AC-3 audio track; first codec was \(String(describing: codec))")
    engine.stop()
}

@Test(.enabled(if: fixtureEnabled))
@MainActor
func aetherRoutesInterlacedMPEG2MP2TSToSoftwareSurface() async throws {
    let engine = try makeEngine()
    try await load(engine, path: "media/ts-mpeg2-interlaced-mp2.ts")
    await waitForPlaying(engine, timeout: 15)
    await waitForPosition(engine, atLeast: 1, timeout: 5)
    #expect(engine.route == .surface)
    engine.stop()
}

@Test(.enabled(if: fixtureEnabled))
@MainActor
func aetherPlaysDolbyVisionProfile81MP4OverRemoteBypass() async throws {
    let engine = try makeEngine()
    try await load(engine, path: "media/dv81-hevc-eac3.mp4")
    await waitForPlaying(engine, timeout: 15)
    #expect(engine.route == .avPlayer)
    engine.stop()
}

// MARK: - Authentication

@Test(.enabled(if: fixtureEnabled))
@MainActor
func aetherPlaysProtectedMP4WhenRefererHeaderIsPresent() async throws {
    let engine = try makeEngine()
    try await load(engine, path: "protected/mp4-h264-aac.mp4", headers: ["Referer": "https://fixtures.local/x"])
    await waitForPlaying(engine, timeout: 10)
    engine.stop()
}

@Test(.enabled(if: fixtureEnabled))
@MainActor
func aetherReportsAuthenticationWhenProtectedMP4LacksReferer() async throws {
    let engine = try makeEngine()
    // The engine throws on a 403 and publishes `.error`; either path is fine,
    // the failure kind is what the assertion checks.
    do {
        try await load(engine, path: "protected/mp4-h264-aac.mp4")
    } catch {
        // Expected: the engine refuses the headerless request.
    }
    await waitForError(engine, timeout: 10)
    #expect(engine.failure?.kind == .authentication, "Expected .authentication; got \(String(describing: engine.failure?.kind))")
    engine.stop()
}

// MARK: - Seek

@Test(.enabled(if: fixtureEnabled))
@MainActor
func aetherSeeksToRequestedPosition() async throws {
    let engine = try makeEngine()
    try await load(engine, path: "media/mp4-h264-aac.mp4")
    await waitForPlaying(engine, timeout: 30)
    await engine.seek(to: 5)
    await waitForPosition(engine, atLeast: 4.5, timeout: 3)
    #expect(engine.position >= 4.5)
    engine.stop()
}

@Test(.enabled(if: fixtureEnabled))
@MainActor
func aetherPlaysHLSAndTimeAdvances() async throws {
    let engine = try makeEngine()
    defer { engine.stop() }
    try await load(engine, path: "hls/index.m3u8")
    await waitForPlaying(engine, timeout: 10)
    await waitForPosition(engine, atLeast: 1, timeout: 5)
    #expect(engine.route == .avPlayer)
}

@Test(.enabled(if: fixtureEnabled))
@MainActor
func nativeEngineHonorsResumeAndAwaitedSeek() async throws {
    let engine = NativePlaybackEngine()
    defer { engine.stop() }
    try await engine.load(ApplePlaybackRequest(url: fixtureURL("media/mp4-h264-aac.mp4"),
        resumePosition: 5, mediaID: "native-resume-fixture", sourceKind: .files))
    await waitForPlaying(engine, timeout: 10)
    await waitForPosition(engine, atLeast: 4.5, timeout: 2)
    #expect(engine.position >= 4.5)
    await engine.seek(to: 10)
    #expect(engine.position >= 9.5)
}

@Test(.enabled(if: fixtureEnabled))
@MainActor
func nativeEnginePreservesProtectedHeadersAndTimeAdvances() async throws {
    let engine = NativePlaybackEngine()
    defer { engine.stop() }
    try await engine.load(ApplePlaybackRequest(url: fixtureURL("protected/mp4-h264-aac.mp4"),
        headers: ["Referer": "https://fixtures.local/x"], mediaID: "native-protected", sourceKind: .files))
    await waitForPlaying(engine, timeout: 10)
    await waitForPosition(engine, atLeast: 1, timeout: 5)
}
