import AetherEngine
import Foundation
import Testing
@testable import OpenStreamApple

/// Run separately from other engine fixtures because the upstream test switch
/// is process-wide. Exercises the surface path used on iPhone Simulator.
@Test(.enabled(if: ProcessInfo.processInfo.environment["OPENSTREAM_PAUSE_FIXTURE"] == "1"))
@MainActor
func surfacePlaybackStaysPausedAfterReloadingAtItsSavedPosition() async throws {
    AetherEngine.setForceSoftwarePathForTesting(true)
    defer { AetherEngine.setForceSoftwarePathForTesting(false) }
    let engine = try AetherPlaybackEngine()
    let coordinator = ApplePlaybackCoordinator(engine: engine)
    defer { coordinator.stop() }
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/out/mp4-h264-aac.mp4")
    var request = ApplePlaybackRequest(url: fixture, mediaID: "pause-review", sourceKind: .files)
    await coordinator.begin(request)
    let deadline = ContinuousClock.now.advanced(by: .seconds(8))
    while engine.position < 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
    #expect(engine.route == .surface)
    #expect(engine.position >= 2)
    coordinator.userPause()
    try await Task.sleep(for: .milliseconds(300))
    let pausedAt = engine.position
    try await Task.sleep(for: .seconds(2))
    #expect(abs(engine.position - pausedAt) < 0.5)
    #expect(engine.phase == .paused)
    coordinator.stop()
    request.resumePosition = pausedAt
    request.autoplay = false
    await coordinator.begin(request)
    try await Task.sleep(for: .milliseconds(500))
    let restoredAt = engine.position
    try await Task.sleep(for: .seconds(2))
    #expect(abs(restoredAt - pausedAt) < 1)
    #expect(abs(engine.position - restoredAt) < 0.5)
    #expect(engine.phase == .paused)
    coordinator.userPlay()
    let resumeDeadline = ContinuousClock.now.advanced(by: .seconds(6))
    while engine.position < restoredAt + 0.75, ContinuousClock.now < resumeDeadline {
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(engine.position >= restoredAt + 0.75)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["OPENSTREAM_PAUSE_FIXTURE"] == "1"))
@MainActor
func nativePlaybackLoadsPausedAtItsSavedPosition() async throws {
    let engine = NativePlaybackEngine()
    defer { engine.stop() }
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/out/mp4-h264-aac.mp4")
    try await engine.load(.init(url: fixture, resumePosition: 5, autoplay: false,
                                mediaID: "native-pause-review", sourceKind: .files))
    try await Task.sleep(for: .seconds(2))
    #expect(engine.phase == .paused)
    #expect(abs(engine.position - 5) < 0.5)
    engine.play()
    let deadline = ContinuousClock.now.advanced(by: .seconds(6))
    while engine.position < 6, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
    #expect(engine.position >= 6)
}
