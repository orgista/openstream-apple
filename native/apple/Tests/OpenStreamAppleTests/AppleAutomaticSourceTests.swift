import Foundation
import Testing
@testable import OpenStreamApple

@MainActor @Test func failedSourceCooldownExpiresAfterTenMinutes() {
    let history = ApplePlaybackFailureHistory()
    let bad = URL(string: "https://media.example/bad.mkv")!
    let good = URL(string: "https://media.example/good.mkv")!
    let now = Date(timeIntervalSince1970: 1000)
    history.record(bad, now: now)
    #expect([bad, good].filter { !history.contains($0, now: now.addingTimeInterval(599)) } == [good])
    #expect(!history.contains(bad, now: now.addingTimeInterval(600)))
}

@MainActor @Test(.timeLimit(.minutes(1)))
func localSourceStartsBeforeRemoteResolutionAndFallsThroughOnFailure() async throws {
    let engine = FakePlaybackEngine()
    engine.script([.playing])
    var remoteLookups = 0
    let coordinator = ApplePlaybackCoordinator(engine: engine)
    let local = ApplePlaybackRequest(url: URL(fileURLWithPath: "/local-1080p.mkv"), mediaID: "local-first", sourceKind: .files)
    let remote = ApplePlaybackRequest(url: URL(string: "https://media.example/2160p.mkv")!, mediaID: "remote", sourceKind: .mediaServer)
    coordinator.nextAutomaticSource = { remoteLookups += 1; return remote }
    await coordinator.begin(local, fallbackCandidates: [])
    #expect(engine.loadedRequests == [local])
    #expect(remoteLookups == 0)
    engine.emit(.failure(.init(kind: .network, message: "Local source disconnected")))
    // The fallback load runs in the coordinator's own task. Wait for it
    // without a wall-clock deadline (the time limit is the hang guard); a
    // yield loop here also kept the main actor spinning for everyone else.
    while engine.loadedRequests.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(engine.loadedRequests == [local, remote])
    #expect(remoteLookups == 1)
    #expect(coordinator.fallbackNoticeGeneration == 1)
    coordinator.stop()
}
