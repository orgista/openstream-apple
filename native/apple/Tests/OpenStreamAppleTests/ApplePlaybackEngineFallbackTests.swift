import Foundation
import Testing
@testable import OpenStreamApple

/// Owner decision 2026-10-01: on the Native player a title none of whose
/// streams the stock player opens (SNL S51E7, all MKV) plays on the OpenStream
/// engine at once, and one whose stock-playable streams all fail falls back to
/// it; "Playback Unavailable" only when the OpenStream engine fails as well.
@Suite struct ApplePlaybackEngineFallbackTests {
    private func stream(_ name: String, live: Bool = false) -> ApplePlaybackRequest {
        ApplePlaybackRequest(url: URL(string: "https://fixture.example/\(name)")!, isLive: live,
            mediaID: "tt0000001", sourceKind: .catalog,
            hints: .init(filename: name))
    }

    private let failed = ApplePlaybackFailure(kind: .unsupportedMedia,
        message: "None of the 3 streams for this title plays on this device.")

    @Test func nativeWithOnlyMatroskaAndTSStartsOnTheOpenStreamEngine() {
        let streams = [stream("a.mkv"), stream("b.ts"), stream("c.avi"), stream("d.webm")]
        #expect(ApplePlaybackEngineFallback.engine(preferred: .native, for: streams) == .openStream)
    }

    @Test(arguments: ["e.mp4", "f.m3u8", "opaque-id"])
    func nativeKeepsTheStockPlayerWhenOneStreamIsStockPlayable(_ playable: String) {
        let streams = [stream("a.mkv"), stream(playable), stream("b.ts")]
        #expect(ApplePlaybackEngineFallback.engine(preferred: .native, for: streams) == .native)
    }

    @Test func theOpenStreamSettingLiveStreamsAndNoStreamsAreLeftAlone() {
        #expect(ApplePlaybackEngineFallback.engine(preferred: .openStream, for: [stream("a.mkv")]) == .openStream)
        #expect(ApplePlaybackEngineFallback.engine(preferred: .native, for: [stream("ch.ts", live: true)]) == .native)
        #expect(ApplePlaybackEngineFallback.engine(preferred: .native, for: []) == .native)
    }

    @Test func nativeFailingFallsBackToTheOpenStreamEngine() {
        #expect(ApplePlaybackEngineFallback.afterEveryStreamFailed(failed, engine: .native,
            alreadyFellBack: false) == .openStream)
    }

    @Test func theOpenStreamEngineFailingShowsTheFailureText() {
        #expect(ApplePlaybackEngineFallback.afterEveryStreamFailed(failed, engine: .openStream,
            alreadyFellBack: false) == .alert(failed.message))
        // The fallback press never falls back again, whatever engine it ran.
        #expect(ApplePlaybackEngineFallback.afterEveryStreamFailed(failed, engine: .native,
            alreadyFellBack: true) == .alert(failed.message))
    }

    @Test func aCancelledLoadDecidesNothing() {
        let cancelled = ApplePlaybackFailure(kind: .cancelled, message: "Playback was cancelled.")
        #expect(ApplePlaybackEngineFallback.afterEveryStreamFailed(cancelled, engine: .native,
            alreadyFellBack: false) == nil)
    }

    @Test func theFallbackTriesTheStreamsTheStockPlayerSkippedFirst() {
        let streams = [stream("a.mp4"), stream("b.mkv"), stream("c.mp4"), stream("d.ts")]
        let tried: Set<URL> = [streams[0].url, streams[2].url]
        let order = ApplePlaybackEngineFallback.fallbackOrder(streams, url: \.url, tried: tried)
        #expect(order.map(\.hints.filename) == ["b.mkv", "d.ts", "a.mp4", "c.mp4"])
        #expect(ApplePlaybackEngineFallback.fallbackOrder(streams, url: \.url, tried: []) == streams)
    }
}
