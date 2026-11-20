import Foundation
import Testing
@testable import OpenStreamApple

/// Walk b20r21, owner iPhone sim: "ABC SPARK" answers HTTP 403, text/html,
/// empty body. The engine reported `Demuxer: open failed (Input/output error
/// (-5))`, so the app said "ABC SPARK isn't broadcasting".
@MainActor
@Suite("Live refusal probe", .serialized, .timeLimit(.minutes(1)))
struct AppleLiveRefusalProbeTests {
    private static let demuxerOpenFailed = ApplePlaybackFailure(
        kind: .player, message: "Demuxer: open failed (Input/output error (-5))")

    private func liveRequest(_ url: URL) -> ApplePlaybackRequest {
        ApplePlaybackRequest(url: url, isLive: true, mediaID: "spark", sourceKind: .liveTV,
                             hints: .init(proxyHeaders: ["User-Agent": "Fixture"]))
    }

    private func failure(_ coordinator: ApplePlaybackCoordinator) -> ApplePlaybackFailure? {
        if case .failed(let failure) = coordinator.phase { return failure }
        return nil
    }

    private func cause(_ failure: ApplePlaybackFailure?) -> AppleLiveFailureCause? {
        failure.flatMap { AppleLiveFailureCause.playback($0, channelName: "ABC SPARK", sourceName: "Home IPTV") }
    }

    @Test func aRefusedChannelSaysItCannotPlayHereOnEveryPlatform() async throws {
        let server = HealthHTTPFixture()
        let base = try await server.start()
        await server.route("/live/u/p/spark.ts", status: 403, headers: ["Server": "nginx"])
        let engine = FakePlaybackEngine()
        engine.failOnLoad = Self.demuxerOpenFailed
        let coordinator = ApplePlaybackCoordinator(engine: engine, timeout: .seconds(60))
        coordinator.clock = ManualClock()

        await coordinator.begin(liveRequest(base.appending(path: "live/u/p/spark.ts")))
        await server.stop()

        let shown = try #require(failure(coordinator))
        #expect(shown.kind == .authentication)
        #expect(shown.httpStatus == 403)
        // iPhone and iPad.
        #expect(cause(shown) == .cannotPlay(channel: "ABC SPARK"))
        #expect(cause(shown)?.action == .nextChannel)
        // Apple TV, Mac and Vision.
        #expect(AppleLiveFailurePresentation.message(for: shown, channelName: "ABC SPARK") == "ABC SPARK can’t play here")
        #expect(AppleLiveFailurePresentation.retryTitle(for: shown) == "Next Channel")
        #expect(AppleLiveFailurePresentation.opensChannelStrip(for: shown))
        // A refusal is not reopened, and the stream was asked once, with its headers.
        #expect(engine.loadedRequests.count == 1)
        #expect(await server.hits("/live/u/p/spark.ts") == 1)
        #expect(await server.header("/live/u/p/spark.ts", "user-agent") == "Fixture")
    }

    @Test func anOffAirChannelStillSaysItIsNotBroadcasting() async throws {
        let server = HealthHTTPFixture()
        let base = try await server.start()
        // 200 and a body that never comes: the probe returns on the head.
        await server.route("/live/u/p/quiet.ts", status: 200, body: Data(count: 188), bodyDelay: .seconds(30))
        let engine = FakePlaybackEngine()
        engine.failOnLoad = Self.demuxerOpenFailed
        let clock = ManualClock()
        let coordinator = ApplePlaybackCoordinator(engine: engine, timeout: .seconds(60))
        coordinator.clock = clock

        let opening = Task { await coordinator.begin(liveRequest(base.appending(path: "live/u/p/quiet.ts"))) }
        // The one quick reopen a never-played channel gets.
        await clock.waitForSleep(until: .seconds(1))
        clock.advance(to: .seconds(1))
        await opening.value
        while failure(coordinator) == nil { try await Task.sleep(for: .milliseconds(10)) }
        await server.stop()

        #expect(cause(failure(coordinator)) == .notBroadcasting(channel: "ABC SPARK"))
        // Asked once per press, not on the reopen too.
        #expect(await server.hits("/live/u/p/quiet.ts") == 1)
    }

    @Test func onlyA401Or403IsARefusal() {
        #expect(AppleLiveRefusalProbe.refusal(status: 403)?.httpStatus == 403)
        #expect(AppleLiveRefusalProbe.refusal(status: 401)?.httpStatus == 401)
        for status in [nil, 200, 302, 404, 458, 509] {
            #expect(AppleLiveRefusalProbe.refusal(status: status) == nil)
        }
    }

    @Test func aRealLoginFailureStillOpensSettings() {
        let login = ApplePlaybackFailure(kind: .authentication, message: "x")
        #expect(cause(login) == .loginFailed(source: "Home IPTV"))
        #expect(AppleLiveFailurePresentation.isChannelRefusal(login) == false)
        #expect(AppleLiveFailurePresentation.opensChannelStrip(for: login) == false)
        #expect(AppleLiveFailurePresentation.retryTitle(for: login) == "Try Again")
    }
}
