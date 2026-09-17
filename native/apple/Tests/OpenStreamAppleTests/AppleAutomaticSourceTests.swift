import Foundation
import Testing
@testable import OpenStreamApple

@Test func automaticSourcesRankResolutionThenSizeThenProviderOrder() {
    func candidate(_ title: String) -> AppleStremioHTTPPlaybackCandidate {
        .init(title: title, sourceURL: URL(string: "https://media.example/\(UUID()).mkv")!)
    }
    let low = candidate("1080p 50 GB")
    let high = candidate("2160p 10 GB")
    let larger = candidate("4K 30 GB")
    let same = candidate("2160p 30 GB")
    #expect(AppleStremioCandidateRanking.rank([low, high, larger, same]) == [larger, same, high, low])
}

@MainActor @Test func failedSourceCooldownExpiresAfterTenMinutes() {
    let history = ApplePlaybackFailureHistory()
    let bad = URL(string: "https://media.example/bad.mkv")!
    let good = URL(string: "https://media.example/good.mkv")!
    let now = Date(timeIntervalSince1970: 1000)
    history.record(bad, now: now)
    #expect([bad, good].filter { !history.contains($0, now: now.addingTimeInterval(599)) } == [good])
    #expect(!history.contains(bad, now: now.addingTimeInterval(600)))
}

@MainActor @Test func localSourceStartsBeforeAddonResolutionAndFallsThroughOnFailure() async {
    let engine = FakePlaybackEngine()
    engine.script([.playing])
    var addonLookups = 0
    let coordinator = ApplePlaybackCoordinator(engine: engine)
    let local = ApplePlaybackRequest(url: URL(fileURLWithPath: "/local-1080p.mkv"), mediaID: "local-first", sourceKind: .files)
    let addon = ApplePlaybackRequest(url: URL(string: "https://media.example/2160p.mkv")!, mediaID: "addon", sourceKind: .stremio)
    coordinator.nextAutomaticSource = { addonLookups += 1; return addon }
    await coordinator.begin(local, fallbackCandidates: [])
    #expect(engine.loadedRequests == [local])
    #expect(addonLookups == 0)
    engine.emit(.failure(.init(kind: .network, message: "Local source disconnected")))
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while engine.loadedRequests.count < 2, ContinuousClock.now < deadline { await Task.yield() }
    #expect(engine.loadedRequests == [local, addon])
    #expect(addonLookups == 1)
    #expect(coordinator.fallbackNoticeGeneration == 1)
    coordinator.stop()
}

@Test func equalUnknownQualityPreservesProviderOrderForAutomaticPlayback() {
    let first = AppleStremioHTTPPlaybackCandidate(title: "First provider", sourceURL: URL(string: "https://first.example/file.mkv")!)
    let second = AppleStremioHTTPPlaybackCandidate(title: "Second provider", sourceURL: URL(string: "https://second.example/file.mp4")!)
    #expect(AppleStremioCandidateRanking.rankForAutomaticPlayback([first, second]) == [first, second])
}
