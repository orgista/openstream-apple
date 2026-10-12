import Foundation
import Testing
@testable import OpenStreamApple

@Suite("Live reconnect policy")
struct AppleLiveReconnectPolicyTests {
    let policy = AppleLiveReconnectPolicy.standard

    @Test func standardIsThreeTriesWithinFifteenSeconds() {
        #expect(policy.maxAttempts == 3)
        #expect(policy.window == .seconds(15))
        let total = (1 ... 3).reduce(Duration.zero) { $0 + policy.delay(beforeAttempt: $1) }
        #expect(total <= policy.window)
    }

    @Test func firstDropReconnectsQuickly() {
        #expect(policy.decide(kind: .network, attemptsSoFar: 0, elapsed: .zero, hasPlayed: true)
            == .reconnect(attempt: 1, delay: .seconds(1)))
    }

    @Test func backoffGrowsPerAttempt() {
        #expect(policy.decide(kind: .timedOut, attemptsSoFar: 1, elapsed: .seconds(3), hasPlayed: true)
            == .reconnect(attempt: 2, delay: .seconds(2)))
        #expect(policy.decide(kind: .sourceEnded, attemptsSoFar: 2, elapsed: .seconds(6), hasPlayed: true)
            == .reconnect(attempt: 3, delay: .seconds(4)))
    }

    @Test func givesUpAfterMaxAttempts() {
        #expect(policy.decide(kind: .network, attemptsSoFar: 3, elapsed: .seconds(8), hasPlayed: true)
            == .giveUp(.attemptsExhausted))
    }

    @Test func givesUpWhenTheNextTryWouldLeaveTheWindow() {
        // 12 s in, the third try's 4 s wait would start it at 16 s.
        #expect(policy.decide(kind: .network, attemptsSoFar: 2, elapsed: .seconds(12), hasPlayed: true)
            == .giveUp(.windowExpired))
    }

    @Test(arguments: [ApplePlaybackFailure.Kind.network, .timedOut, .player])
    func aChannelThatNeverPlayedGetsOnlyOneQuickReopen(kind: ApplePlaybackFailure.Kind) {
        #expect(policy.decide(kind: kind, attemptsSoFar: 0, elapsed: .zero, hasPlayed: false)
            == .reconnect(attempt: 1, delay: .seconds(1)))
        #expect(policy.decide(kind: kind, attemptsSoFar: 1, elapsed: .seconds(1), hasPlayed: false)
            == .giveUp(.neverPlayed))
        #expect(policy.decide(kind: kind, attemptsSoFar: 0, elapsed: .seconds(15), hasPlayed: false)
            == .giveUp(.windowExpired))
    }

    @Test(arguments: [ApplePlaybackFailure.Kind.authentication, .unsupportedMedia, .engineUnavailable, .cancelled, .sourceEnded, .unavailable])
    func otherOpeningFailuresSkipReopen(kind: ApplePlaybackFailure.Kind) {
        #expect(policy.decide(kind: kind, attemptsSoFar: 0, elapsed: .zero, hasPlayed: false)
            == .giveUp(.neverPlayed))
    }

    @Test(arguments: [ApplePlaybackFailure.Kind.authentication, .unsupportedMedia, .engineUnavailable, .cancelled])
    func failuresARetryCannotFixAreNotReconnected(kind: ApplePlaybackFailure.Kind) {
        #expect(policy.decide(kind: kind, attemptsSoFar: 0, elapsed: .zero, hasPlayed: true)
            == .giveUp(.notRecoverable))
    }

    @Test(arguments: [ApplePlaybackFailure.Kind.network, .timedOut, .player, .sourceEnded, .unavailable])
    func dropsAreRecoverable(kind: ApplePlaybackFailure.Kind) {
        #expect(AppleLiveReconnectPolicy.isRecoverable(kind))
    }

    @Test func extraAttemptsRepeatTheLastDelay() {
        let long = AppleLiveReconnectPolicy(maxAttempts: 5, delays: [.seconds(1), .seconds(2)], window: .seconds(60))
        #expect(long.delay(beforeAttempt: 4) == .seconds(2))
        #expect(AppleLiveReconnectPolicy(delays: []).delay(beforeAttempt: 1) == .zero)
    }

    @Test func steadyPlayAfterARecoveryStartsAFreshEpisode() {
        #expect(!policy.startsNewEpisode(playingFor: .seconds(5)))
        #expect(policy.startsNewEpisode(playingFor: .seconds(30)))
    }
}

@Suite("Live other-list match")
struct AppleLiveOtherListMatchTests {
    let xtream = UUID()
    let m3u = UUID()
    let third = UUID()

    func channel(_ id: String, _ source: UUID, _ name: String, guide: String? = nil, url: String? = nil) -> AppleIPTVChannel {
        AppleIPTVChannel(id: id, sourceID: source, name: name,
                         streamURL: URL(string: url ?? "http://fixture.example/\(id).ts")!, guideID: guide)
    }

    @Test func matchesByGuideIDFirst() {
        let dead = channel("x1", xtream, "Atlas News", guide: "atlasnews.fx")
        let lineup = [
            dead,
            channel("m-name", m3u, "Atlas News"),
            channel("m-guide", m3u, "FX | ATLAS NEWS FHD", guide: "AtlasNews.fx"),
        ]
        #expect(AppleLiveOtherListMatch.match(for: dead, in: lineup)?.id == "m-guide")
    }

    @Test func fallsBackToNormalizedName() {
        let dead = channel("x1", xtream, "US: Atlas News HD")
        let lineup = [dead, channel("m1", m3u, "Atlas News"), channel("m2", m3u, "Beacon News")]
        #expect(AppleLiveOtherListMatch.match(for: dead, in: lineup)?.id == "m1")
    }

    @Test func neverOffersTheSameList() {
        let dead = channel("x1", xtream, "Atlas News", guide: "atlasnews.fx")
        let lineup = [dead, channel("x2", xtream, "Atlas News", guide: "atlasnews.fx")]
        #expect(AppleLiveOtherListMatch.match(for: dead, in: lineup) == nil)
    }

    @Test func skipsStreamsAlreadyTriedAndPrefersHealthyOnes() {
        let dead = channel("x1", xtream, "Atlas News", guide: "atlasnews.fx")
        let tried = channel("m1", m3u, "Atlas News", guide: "atlasnews.fx")
        let failed = channel("t1", third, "Atlas News", guide: "atlasnews.fx")
        let healthy = channel("t2", third, "Atlas News", guide: "atlasnews.fx")
        let lineup = [dead, tried, failed, healthy]
        let match = AppleLiveOtherListMatch.match(
            for: dead, in: lineup, excludingURLs: [tried.streamURL],
            hasRecentlyFailed: { $0 == failed.streamURL })
        #expect(match?.id == "t2")
    }

    @Test func aFeedThatJustFailedIsNotOffered() {
        let dead = channel("m1", m3u, "Atlas News", guide: "atlasnews.fx")
        let alsoDead = channel("x1", xtream, "Atlas News", guide: "atlasnews.fx")
        #expect(AppleLiveOtherListMatch.match(for: dead, in: [dead, alsoDead],
                                              hasRecentlyFailed: { $0 == alsoDead.streamURL }) == nil)
    }

    @Test func aDifferentChannelIsNeverOffered() {
        let dead = channel("x1", xtream, "Atlas News", guide: "atlasnews.fx")
        let lineup = [dead, channel("m1", m3u, "Atlas Sports", guide: "atlassports.fx")]
        #expect(AppleLiveOtherListMatch.match(for: dead, in: lineup) == nil)
    }

    @Test func offerNamesTheList() {
        #expect(AppleLiveOtherListMatch.offerTitle(sourceName: "Fixture M3U") == "Watch on Fixture M3U")
        #expect(AppleLiveOtherListMatch.offerTitle(sourceName: "  ") == "Watch on Another List")
        #expect(AppleLiveOtherListMatch.offerTitle(sourceName: nil) == "Watch on Another List")
    }
}

@Suite("IPTV catch-up")
struct AppleIPTVCatchUpTests {
    let source = UUID()

    func xtreamChannel(days: Int?) -> AppleIPTVChannel {
        var channel = AppleIPTVChannel(id: "c", sourceID: source, name: "Atlas News",
                                       streamURL: URL(string: "http://fixture.example:8080/live/u%40x/p/101.ts")!)
        channel.catchUpDays = days
        return channel
    }

    func programme(start: Date, minutes: Double) -> AppleIPTVProgramme {
        AppleIPTVProgramme(id: "p", channelID: "c", title: "Morning Report", subtitle: nil, description: nil,
                           start: start, end: start.addingTimeInterval(minutes * 60), category: nil, isLive: false)
    }

    @Test func archiveDaysNeedTheFlagAndADuration() {
        #expect(AppleIPTVCatchUp.archiveDays(tvArchive: "1", duration: "3") == 3)
        #expect(AppleIPTVCatchUp.archiveDays(tvArchive: "0", duration: "3") == nil)
        #expect(AppleIPTVCatchUp.archiveDays(tvArchive: "1", duration: "0") == nil)
        #expect(AppleIPTVCatchUp.archiveDays(tvArchive: nil, duration: nil) == nil)
    }

    @Test func timeshiftURLKeepsTheLiveURLsCredentialsAndHost() throws {
        let start = try #require(ISO8601DateFormatter().date(from: "2026-10-01T14:30:00Z"))
        let url = AppleIPTVCatchUp.timeshiftURL(for: xtreamChannel(days: 3), programme: programme(start: start, minutes: 60))
        #expect(url?.absoluteString == "http://fixture.example:8080/timeshift/u%40x/p/60/2026-10-01:14-30/101.ts")
    }

    @Test func timeshiftURLUsesThePanelsTimeZone() throws {
        let start = try #require(ISO8601DateFormatter().date(from: "2026-10-01T14:30:00Z"))
        let zone = try #require(TimeZone(identifier: "Europe/Paris"))
        let url = AppleIPTVCatchUp.timeshiftURL(for: xtreamChannel(days: 3), programme: programme(start: start, minutes: 45),
                                                timeZone: zone)
        #expect(url?.absoluteString.contains("/45/2026-10-01:16-30/101.ts") == true)
    }

    @Test func onlyEndedProgrammesInsideTheWindowAreAvailable() {
        let now = Date(timeIntervalSince1970: 1_790_900_000)
        let channel = xtreamChannel(days: 1)
        #expect(AppleIPTVCatchUp.isAvailable(programme(start: now.addingTimeInterval(-7200), minutes: 60), on: channel, now: now))
        // Still airing: that is the live channel.
        #expect(!AppleIPTVCatchUp.isAvailable(programme(start: now.addingTimeInterval(-600), minutes: 60), on: channel, now: now))
        // Older than the archive.
        #expect(!AppleIPTVCatchUp.isAvailable(programme(start: now.addingTimeInterval(-2 * 86_400), minutes: 60), on: channel, now: now))
        // No archive on the channel.
        #expect(!AppleIPTVCatchUp.isAvailable(programme(start: now.addingTimeInterval(-7200), minutes: 60),
                                              on: xtreamChannel(days: nil), now: now))
    }

    @Test func anM3UChannelHasNoTimeshiftURL() {
        var channel = AppleIPTVChannel(id: "m", sourceID: source, name: "Atlas News",
                                       streamURL: URL(string: "http://fixture.example/hls/1/live.m3u8")!)
        channel.catchUpDays = 3
        #expect(AppleIPTVCatchUp.timeshiftURL(for: channel, programme: programme(start: .now.addingTimeInterval(-7200), minutes: 30)) == nil)
    }

    @Test func catchUpRequestIsOnDemand() {
        let request = AppleIPTVCatchUp.playbackRequest(
            for: xtreamChannel(days: 3), programme: programme(start: .now.addingTimeInterval(-7200), minutes: 30))
        #expect(request?.isLive == false)
        #expect(request?.title == "Morning Report")
    }
}

@MainActor
@Suite("Live reconnect in the coordinator", .serialized)
struct AppleLiveReconnectCoordinatorTests {
    private let fast = AppleLiveReconnectPolicy(
        maxAttempts: 3,
        delays: [.milliseconds(20), .milliseconds(40), .milliseconds(60)],
        window: .seconds(5),
        stallTimeout: .milliseconds(150),
        episodeResetAfter: .seconds(30)
    )

    private func liveRequest() -> ApplePlaybackRequest {
        ApplePlaybackRequest(url: URL(string: "http://127.0.0.1:8790/live/fixture/fixture/105.ts")!,
                             isLive: true, mediaID: "ch5", sourceKind: .liveTV)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock().now + .seconds(8)
        while ContinuousClock().now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test func aDropMidPlayReconnectsAndRecovers() async {
        let engine = FakePlaybackEngine()
        engine.script([.loading, .playing])
        let coordinator = ApplePlaybackCoordinator(engine: engine, timeout: .seconds(60))
        coordinator.liveReconnectPolicy = fast
        await coordinator.begin(liveRequest())
        #expect(coordinator.phase == .playing)

        engine.emit(.failure(.init(kind: .network, message: "connection reset")))
        #expect(await waitUntil { coordinator.liveReconnectAttempt == 1 })
        #expect(coordinator.phase.isBusy)
        #expect(await waitUntil { engine.loadedRequests.count == 2 && coordinator.phase == .playing })
        #expect(coordinator.liveReconnectAttempt == 0)
        #expect(engine.loadedRequests.map(\.url) == [liveRequest().url, liveRequest().url])
        coordinator.stop()
    }

    @Test func aChannelThatStaysDeadGivesUpAfterThreeTries() async {
        let engine = FakePlaybackEngine()
        engine.script([.loading, .playing])
        let coordinator = ApplePlaybackCoordinator(engine: engine, timeout: .seconds(60))
        coordinator.liveReconnectPolicy = fast
        await coordinator.begin(liveRequest())
        #expect(coordinator.phase == .playing)

        engine.loadHandler = { _ in throw ApplePlaybackFailure(kind: .unavailable, message: "HTTP 404") }
        engine.emit(.failure(.init(kind: .network, message: "connection reset")))
        let failed = await waitUntil {
            if case .failed = coordinator.phase { return true }
            return false
        }
        #expect(failed)
        // The first open plus three reopens, then the failure is shown.
        #expect(engine.loadedRequests.count == 4)
        #expect(coordinator.liveReconnectAttempt == 0)
        coordinator.stop()
    }

    @Test func aChannelThatNeverPlayedReopensOnlyOnce() async {
        let engine = FakePlaybackEngine()
        engine.failOnLoad = .init(kind: .network, message: "refused")
        let coordinator = ApplePlaybackCoordinator(engine: engine, timeout: .seconds(60))
        coordinator.liveReconnectPolicy = fast
        await coordinator.begin(liveRequest())
        _ = await waitUntil {
            if case .failed = coordinator.phase { return true }
            return false
        }
        #expect(engine.loadedRequests.count == 2)
        coordinator.stop()
    }

    @Test func aStallLongerThanTheTimeoutIsTreatedAsADrop() async {
        let engine = FakePlaybackEngine()
        engine.script([.loading, .playing])
        let coordinator = ApplePlaybackCoordinator(engine: engine, timeout: .seconds(60))
        coordinator.liveReconnectPolicy = fast
        await coordinator.begin(liveRequest())
        #expect(coordinator.phase == .playing)

        engine.emit(.phase(.stalled(reconnecting: false)))
        #expect(await waitUntil { coordinator.phase == .waiting("Reconnecting…") })
        #expect(await waitUntil { engine.loadedRequests.count == 2 && coordinator.phase == .playing })
        coordinator.stop()
    }

    @Test func dataMovingAgainAfterAStallGivesTheEngineMoreTime() async {
        let engine = FakePlaybackEngine()
        engine.script([.loading, .playing])
        let coordinator = ApplePlaybackCoordinator(engine: engine, timeout: .seconds(60))
        coordinator.liveReconnectPolicy = AppleLiveReconnectPolicy(
            delays: [.milliseconds(20)], window: .seconds(5), stallTimeout: .milliseconds(300))
        await coordinator.begin(liveRequest())
        engine.emit(.phase(.stalled(reconnecting: true)))
        #expect(await waitUntil { coordinator.isReconnectingLive })
        try? await Task.sleep(for: .milliseconds(200))
        // The engine's own reconnect got data: buffering, not stalled.
        engine.emit(.phase(.rebuffering))
        try? await Task.sleep(for: .milliseconds(200))
        // 400 ms after the stall, past one timeout, but the timer restarted.
        #expect(engine.loadedRequests.count == 1)
        engine.emit(.phase(.playing))
        #expect(await waitUntil { coordinator.phase == .playing })
        try? await Task.sleep(for: .milliseconds(300))
        #expect(engine.loadedRequests.count == 1)
        coordinator.stop()
    }

    @Test func aShortRebufferIsLeftAlone() async {
        let engine = FakePlaybackEngine()
        engine.script([.loading, .playing])
        let coordinator = ApplePlaybackCoordinator(engine: engine, timeout: .seconds(60))
        coordinator.liveReconnectPolicy = fast
        await coordinator.begin(liveRequest())
        engine.emit(.phase(.rebuffering))
        #expect(await waitUntil { coordinator.phase == .waiting("Buffering…") })
        engine.emit(.phase(.playing))
        #expect(await waitUntil { coordinator.phase == .playing })
        try? await Task.sleep(for: .milliseconds(300))
        #expect(engine.loadedRequests.count == 1)
        coordinator.stop()
    }

    @Test func endOfALiveStreamReconnects() async {
        let engine = FakePlaybackEngine()
        engine.script([.loading, .playing])
        let coordinator = ApplePlaybackCoordinator(engine: engine, timeout: .seconds(60))
        coordinator.liveReconnectPolicy = fast
        await coordinator.begin(liveRequest())
        engine.emit(.phase(.ended))
        #expect(await waitUntil { engine.loadedRequests.count == 2 && coordinator.phase == .playing })
        coordinator.stop()
    }
}
