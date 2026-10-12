import Foundation
import Testing
@testable import OpenStreamApple

/// iPad v2 re-run (2026-10-01): debrid error clips played as the episode,
/// were counted as watched and auto-advanced through the season. They are
/// demoted by their words and, at playback, failed over by their length.
@MainActor
@Suite(.serialized) struct AppleStreamPlaceholderTests {
    private static let device = AppleStreamDeviceCapabilities(supportsHDR: true, supportsDolbyVision: false)

    private func candidate(_ title: String, file: String, description: String? = nil) -> AppleStremioHTTPPlaybackCandidate {
        AppleStremioHTTPPlaybackCandidate(title: title, sourceURL: URL(string: "https://media.fixture.example/\(file)")!,
                                          filename: file, qualityDescription: description)
    }

    private func request(_ id: String, runtime: Double?) -> ApplePlaybackRequest {
        ApplePlaybackRequest(url: URL(string: "http://127.0.0.1:8765/placeholder-\(id)-\(UUID().uuidString).mp4")!,
                             mediaID: id, sourceKind: .stremio, hints: .init(expectedRuntime: runtime))
    }

    // MARK: - Words

    @Test(arguments: [
        "Debrid failed to split torrent into single videos, only rar is available",
        "[RD] download failed",
        "TorBox: Not cached",
        "failed_rar_v2.mp4",
    ])
    func errorClipWordsAreRecognised(text: String) {
        #expect(AppleStreamPlaceholderPolicy.isPlaceholder(text: text))
    }

    @Test(arguments: ["Saturday Night Live S01E01 1080p WEB-DL", "The.Failure.2023.2160p.mkv", "Downloaded 4K HDR"])
    func ordinaryReleasesAreNot(text: String) {
        #expect(AppleStreamPlaceholderPolicy.isPlaceholder(text: text) == false)
    }

    @Test func anErrorClipRanksBelowEveryRealStream() {
        let clip = candidate("Torrentio 4K", file: "clip.mp4",
                             description: "Debrid failed to split torrent into single videos, only rar is available 2160p")
        let real = candidate("Torrentio 720p", file: "Show.S01E01.720p.mkv")
        let wrongShow = candidate("Other 1080p", file: "Another.Show.S01E01.1080p.mkv")
        #expect(AppleStremioCandidateRanking.playbackOrder([clip, real], choice: .automatic, device: Self.device).last == clip)
        #expect(AppleStremioCandidateRanking.rankForAutomaticPlayback([clip, real]).last == clip)
        #expect(AppleStremioCandidateRanking.playbackOrder([clip, wrongShow], choice: .automatic, device: Self.device,
                                                          title: "Show").last == clip)
    }

    // MARK: - Length

    @Test func aClipFarShorterThanTheKnownRuntimeIsAPlaceholder() {
        #expect(AppleStreamPlaceholderPolicy.isPlaceholder(duration: 30, expectedRuntime: 45 * 60))
        #expect(AppleStreamPlaceholderPolicy.isPlaceholder(duration: 59, expectedRuntime: 10 * 60))
        #expect(AppleStreamPlaceholderPolicy.isPlaceholder(duration: 600, expectedRuntime: 120 * 60))
    }

    @Test func unknownOrShortRuntimesAreNeverJudged() {
        #expect(AppleStreamPlaceholderPolicy.isPlaceholder(duration: 30, expectedRuntime: nil) == false)
        #expect(AppleStreamPlaceholderPolicy.isPlaceholder(duration: nil, expectedRuntime: 45 * 60) == false)
        #expect(AppleStreamPlaceholderPolicy.isPlaceholder(duration: 30, expectedRuntime: 5 * 60) == false)
        #expect(AppleStreamPlaceholderPolicy.isPlaceholder(duration: 40 * 60, expectedRuntime: 45 * 60) == false)
    }

    // MARK: - Playback

    @Test func aPlaceholderAtPlaybackFailsOverToTheNextCandidate() async {
        let engine = FakePlaybackEngine()
        engine.loadHandler = { request in
            engine.duration = request.mediaID == "clip" ? 30 : 44 * 60
            engine.phase = .playing
        }
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        coordinator.serviceHealth = AppleStreamServiceHealth()
        await coordinator.begin(request("clip", runtime: 45 * 60), fallbackCandidates: [request("real", runtime: 45 * 60)])
        let played = await placeholderWaitUntil { engine.loadedRequests.count == 2 && coordinator.phase == .playing }
        #expect(played)
        #expect(engine.loadedRequests.map(\.mediaID) == ["clip", "real"])
        #expect(coordinator.isPlaceholderPlayback == false)
        coordinator.stop()
    }

    @Test func aLonePlaceholderFailsAndNeverEnds() async {
        let engine = FakePlaybackEngine()
        engine.loadHandler = { _ in
            engine.duration = 30
            engine.phase = .playing
        }
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        coordinator.serviceHealth = AppleStreamServiceHealth()
        await coordinator.begin(request("clip", runtime: 45 * 60))
        let failed = await placeholderWaitUntil {
            if case .failed = coordinator.phase { return true }
            return false
        }
        #expect(failed)
        #expect(coordinator.phase != .ended)
        coordinator.stop()
    }
}

private func placeholderWaitUntil(timeout: Duration = .seconds(8), _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock().now + timeout
    while ContinuousClock().now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return false
}
