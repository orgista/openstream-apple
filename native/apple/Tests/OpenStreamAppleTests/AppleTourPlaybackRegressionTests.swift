import AVFoundation
import Foundation
import MediaPlayer
import Network
import Synchronization
import Testing
@testable import OpenStreamApple

@MainActor
@Suite(.serialized)
struct AppleTourPlaybackRegressionTests {
    @Test(arguments: [ApplePlaybackPresentationRoute.avPlayer, .surface])
    func autoplayRetiresTheInitialEdgeSeekOnJoinAndRejoin(route: ApplePlaybackPresentationRoute) async throws {
        let engine = FakePlaybackEngine()
        engine.scriptedRoute = route
        engine.liveEdgeOffset = 18
        let clock = ManualClock()
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        coordinator.clock = clock
        defer { coordinator.stop() }
        let request = ApplePlaybackRequest(url: try #require(URL(string: "https://fixture.example/live.m3u8")),
            isLive: true, mediaID: "fixture-live", sourceKind: .liveTV)
        for join in 1...2 {
            let (loading, releaseLoad) = AsyncStream<Void>.makeStream()
            engine.loadHandler = { _ in
                engine.phase = .loading
                for await _ in loading {}
            }
            engine.seekableRange = nil
            let begin = Task { await coordinator.begin(request) }
            await waitFor("the pending startup seek") {
                coordinator.initialLiveSeekTask != nil && engine.loadedRequests.count == join && engine.phase == .loading
            }
            let seek = try #require(coordinator.initialLiveSeekTask)
            engine.phase = .playing
            engine.emit(.phase(.playing))
            releaseLoad.finish()
            await begin.value
            await waitFor("autoplay's first frame") { coordinator.phase == .playing }
            #expect(coordinator.initialLiveSeekTask == nil)
            engine.seekableRange = .init(start: 120, end: 180)
            await seek.value
            for (position, elapsed) in [(120.0, 4), (162.0, 6), (163.0, 6)] {
                engine.position = position
                engine.emit(.position(position))
                await waitFor("the post-frame position") { coordinator.lastKnownPosition == position }
                await coordinator.liveEdgeCorrectionTask?.value
                #expect(engine.seeks.isEmpty)
                clock.advance(by: .seconds(elapsed))
            }
            #expect(engine.seeks.isEmpty)
            #expect(engine.loadedRequests.count == join)
            coordinator.stop()
        }
    }

    @Test(arguments: [ApplePlaybackPresentationRoute.avPlayer, .surface])
    func startupStillSeeksToTheEdgeBeforeTheFirstFrame(route: ApplePlaybackPresentationRoute) async throws {
        let engine = FakePlaybackEngine()
        engine.scriptedRoute = route
        engine.script([.loading])
        engine.seekableRange = .init(start: 120, end: 180)
        engine.seekHandler = { engine.position = $0 }
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        defer { coordinator.stop() }
        await coordinator.begin(ApplePlaybackRequest(
            url: try #require(URL(string: "https://fixture.example/live.m3u8")),
            isLive: true, mediaID: "fixture-live", sourceKind: .liveTV))
        await waitFor("the required startup seek") { engine.seeks == [179] }
        await coordinator.initialLiveSeekTask?.value
        #expect(engine.position == 179)
        #expect(engine.phase == .playing)
        #expect(engine.loadedRequests.count == 1)
    }

    @Test func networkPathUpdatesCannotApplyAnOlderPermission() {
        let network = AppleLivePrefetchNetwork(monitor: nil)
        network.applyPath(allowsPrefetch: false, sequence: 2)
        network.applyPath(allowsPrefetch: true, sequence: 1)
        #expect(!network.allowsPrefetch)
        network.applyPath(allowsPrefetch: true, sequence: 3)
        network.applyPath(allowsPrefetch: false, sequence: 2)
        #expect(network.allowsPrefetch)
    }

    @Test func prefetchAllowsUnknownThenReevaluatesTheFirstNetworkPath() {
        #expect(AppleLivePrefetchNetwork.permits(status: nil))
        #expect(AppleLivePrefetchNetwork.permits(status: .satisfied))
        #expect(!AppleLivePrefetchNetwork.permits(status: .satisfied, isExpensive: true))
        #expect(!AppleLivePrefetchNetwork.permits(status: .satisfied, isConstrained: true))
        #expect(!AppleLivePrefetchNetwork.permits(status: .unsatisfied))
        #expect(!AppleLivePrefetchNetwork.permits(status: .requiresConnection))
    }

    @Test(arguments: [AppleMediaServerKind.jellyfin, .emby], [false, true])
    func serverEpisodeRequestsCarrySeriesAndArtwork(kind: AppleMediaServerKind, episodeStill: Bool) async throws {
        let source = AppleSource(kind: .mediaServer, name: "Fixture",
            url: try #require(URL(string: "https://fixture.example")))
        let session = AppleMediaServerSession(kind: kind, baseURL: source.url, accessToken: "fixture", userID: "fixture")
        let client = AppleMediaServerClient(loader: { request in
            let response = HTTPURLResponse(url: try #require(request.url), statusCode: 200,
                httpVersion: nil, headerFields: nil)
            return (Data("""
                {"MediaSources":[{"Id":"version","Container":"mp4","SupportsDirectPlay":true}]}
                """.utf8), try #require(response))
        })
        let library = AppleMediaServerLibraryStore(client: client)
        let series = AppleMediaServerItem(id: "show", name: "Fixture Series", type: .series, primaryImageTag: "poster")
        let episode = AppleMediaServerItem(id: "episode", name: "Pilot", type: .episode,
            seriesID: "show", seriesName: "Fixture Series", indexNumber: 1, parentIndexNumber: 1,
            primaryImageTag: episodeStill ? "still" : nil)
        let detail = AppleMediaServerLibraryStore.AppleMediaServerDetail(item: series, source: source,
            session: session, seasons: [], episodesBySeason: [:])
        let requests = try await library.playbackCandidates(for: episode, in: detail, resume: false)
        let request = try #require(requests.first)
        let metadata = AppleNowPlayingMetadata(request: request)
        #expect(metadata.seriesTitle == "Fixture Series")
        #expect(metadata.artworkURL?.path.contains(episodeStill ? "/episode/" : "/show/") == true)
        let info = metadata.nowPlayingInfo(position: 5, duration: 15, isPlaying: true)
        #expect(info[MPMediaItemPropertyAlbumTitle] as? String == "Fixture Series")
        #expect(info[MPMediaItemPropertyMediaType] as? UInt == MPMediaType.tvShow.rawValue)
        #expect(info[MPNowPlayingInfoPropertyMediaType] as? UInt == MPNowPlayingInfoMediaType.video.rawValue)
    }

    @Test func progressWritesOncePerSampleAndCannotRegressAfterEnd() throws {
        let suite = "tour-progress-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ApplePlaybackStore(defaults: defaults)
        let progress = ApplePlaybackProgressCoordinator(store: store, mediaIdentity: "fixture-episode", partID: "ep1")
        var writes: [Double] = []
        progress.writer = { position, duration in
            writes.append(position)
            store.save(mediaID: "fixture-episode", position: position, duration: duration, partID: "ep1")
        }
        progress.record(position: 5, duration: 15)
        progress.record(position: 5, duration: 15)
        progress.record(position: 15, duration: 15)
        progress.record(position: 14, duration: 15)
        progress.finish(duration: 15)
        progress.record(position: 14, duration: 15)
        progress.stopObserving()
        #expect(writes == [5, 15])
        #expect(store.lastActivity(for: "fixture-episode")?.position == 15)
        progress.beginPlaySession()
        progress.record(position: 2, duration: 15)
        progress.record(position: 2, duration: 15)
        progress.record(position: 15, duration: 15)
        progress.record(position: 14, duration: 15)
        #expect(writes == [5, 15, 2, 15])
        progress.record(position: 3, duration: 15, isPlaying: true)
        #expect(writes == [5, 15, 2, 15, 3])
    }

    @Test(arguments: [AppleUIPlatform.iOS, .tvOS, .visionOS, .macOS])
    func systemSnapshotsArePublishedOnlyWhereATargetReadsThem(platform: AppleUIPlatform) {
        #expect(AppleTopShelfPublisher.supportsPublishing(on: platform) == (platform == .iOS || platform == .tvOS))
    }

    @Test(arguments: [AppleUIPlatform.iOS, .tvOS, .visionOS, .macOS])
    func publisherChecksThePlatformBeforeAccessingTheContainer(platform: AppleUIPlatform) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let containerReads = Mutex(0)
        let writer = AppleTopShelfSnapshotWriter(containerProvider: {
            containerReads.withLock { $0 += 1 }
            return root
        }, snapshotLocation: { AppleTopShelfSnapshotWriter.snapshotURL(in: $0) }, artwork: nil,
           trailerFiles: nil, didChange: {})
        let publisher = AppleTopShelfPublisher(writer: writer, platform: platform)
        await publisher.publish(records: [], sources: [], enabled: true)
        #expect((containerReads.withLock { $0 } > 0) == AppleTopShelfPublisher.supportsPublishing(on: platform))
    }

    @Test(arguments: [false, true])
    func surfaceEndIgnoresLateTicksAndAnInPlaceReplaySavesAgain(positionArrivesAfterPlaying: Bool) async throws {
        let engine = FakePlaybackEngine()
        engine.scriptedRoute = .surface
        engine.script([.playing])
        engine.duration = 15
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        defer { coordinator.stop() }
        var positions: [Double] = []
        var remoteStarts = 0
        var remoteStops = 0
        coordinator.remoteProgressSink = { _, _, _, event in
            switch event {
            case .started: remoteStarts += 1
            case .stopped: remoteStops += 1
            default: break
            }
        }
        coordinator.progressWriter = { position, _ in positions.append(position) }
        let request = ApplePlaybackRequest(url: try #require(URL(string: "https://fixture.example/episode.mp4")),
            mediaID: "fixture-episode", sourceKind: .mediaServer)
        await coordinator.begin(request)
        engine.emit(.position(5))
        await waitFor("the first progress sample") { positions == [5] }
        engine.emit(.position(5))
        engine.emit(.phase(.ended))
        await waitFor("the terminal progress sample") { coordinator.progressEnded }
        engine.emit(.phase(.paused))
        engine.emit(.position(14))
        await waitFor("the late pause event") { coordinator.phase == .paused }
        coordinator.saveProgressNow()
        #expect(positions == [5, 15])
        engine.position = positionArrivesAfterPlaying ? 15 : 2
        engine.phase = .playing
        engine.emit(.phase(.playing))
        await waitFor("the replay's playing transition") { coordinator.phase == .playing }
        engine.position = 2
        engine.emit(.position(2))
        await waitFor("an in-place replay saves again") { positions == [5, 15, 2] }
        #expect(!coordinator.progressEnded)
        #expect(engine.loadedRequests.count == 1)
        engine.position = 3
        coordinator.saveProgressNow()
        #expect(positions == [5, 15, 2, 3])
        engine.emit(.phase(.ended))
        await waitFor("the replay's terminal sample") { positions == [5, 15, 2, 3, 15] }
        #expect(remoteStarts == 2)
        #expect(remoteStops == 2)
    }

    @Test func guideTimeoutRetriesOnForegroundWithBackoffAndStopsAfterSuccess() async throws {
        GuideRetryURLProtocol.state.withLock { $0 = .init(failures: 2) }
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GuideRetryURLProtocol.self]
        let clock = ManualClock()
        let guide = AppleIPTVGuideStore(loader: .init(session: URLSession(configuration: config)),
            diskCache: .init(directory: directory), clock: clock)
        guide.configure(xmltvURL: try #require(URL(string: "https://fixture.example/guide.xml")))
        await guide.refreshVisible(channelIDs: ["ch1"])
        #expect(GuideRetryURLProtocol.state.withLock { $0.requests } == 1)
        let foreground = Task { await guide.retryFailedVisible(channelIDs: ["ch1"]) }
        await clock.waitForSleep(until: .seconds(5))
        #expect(GuideRetryURLProtocol.state.withLock { $0.requests } == 1)
        let revision = guide.retryRevision
        clock.advance(to: .seconds(5))
        await clock.waitForSleep(until: .seconds(15))
        #expect(guide.retryRevision == revision)
        #expect(GuideRetryURLProtocol.state.withLock { $0.requests } == 2)
        clock.advance(to: .seconds(15))
        await foreground.value
        #expect(GuideRetryURLProtocol.state.withLock { $0.requests } == 3)
        #expect(guide.guide(for: ["ch1"]).allProgrammes.map(\.title) == ["Fixture Programme"])
        #expect(clock.pendingSleepers == 0)
        await guide.retryFailedVisible(channelIDs: ["ch1"])
        #expect(GuideRetryURLProtocol.state.withLock { $0.requests } == 3)
    }

    @Test(arguments: [false, true])
    func userRefreshRunsDuringAutomaticRetryBackoff(force: Bool) async throws {
        GuideRetryURLProtocol.state.withLock { $0 = .init(failures: 1) }
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GuideRetryURLProtocol.self]
        let clock = ManualClock()
        let guide = AppleIPTVGuideStore(loader: .init(session: URLSession(configuration: config)),
            diskCache: .init(directory: directory), clock: clock)
        guide.configure(xmltvURL: try #require(URL(string: "https://fixture.example/guide.xml")))
        await guide.refreshVisible(channelIDs: ["ch1"])
        let retry = Task { await guide.retryFailedVisible(channelIDs: ["ch1"]) }
        await clock.waitForSleep(until: .seconds(5))
        await guide.refreshVisible(channelIDs: ["ch1"], force: force)
        #expect(GuideRetryURLProtocol.state.withLock { $0.requests } == 2)
        #expect(!guide.guide(for: ["ch1"]).allProgrammes.isEmpty)
        clock.advance(to: .seconds(5))
        await retry.value
        #expect(GuideRetryURLProtocol.state.withLock { $0.requests } == 2)
    }

    @Test func leavingForegroundCancelsTheGuideRetryDelay() async throws {
        GuideRetryURLProtocol.state.withLock { $0 = .init(failures: 1) }
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GuideRetryURLProtocol.self]
        let clock = ManualClock()
        let guide = AppleIPTVGuideStore(loader: .init(session: URLSession(configuration: config)),
            diskCache: .init(directory: directory), clock: clock)
        guide.configure(xmltvURL: try #require(URL(string: "https://fixture.example/guide.xml")))
        await guide.refreshVisible(channelIDs: ["ch1"])
        let foreground = Task { await guide.retryFailedVisible(channelIDs: ["ch1"]) }
        await clock.waitForSleep(until: .seconds(5))
        foreground.cancel()
        await foreground.value
        clock.advance(to: .seconds(5))
        #expect(GuideRetryURLProtocol.state.withLock { $0.requests } == 1)
        #expect(clock.pendingSleepers == 0)
        await guide.retryFailedVisible(channelIDs: ["ch1"])
        #expect(GuideRetryURLProtocol.state.withLock { $0.requests } == 2)
    }
}

private final class GuideRetryURLProtocol: URLProtocol {
    struct State {
        var failures: Int
        var requests = 0
    }
    static let state = Mutex(State(failures: 0))
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let fail = Self.state.withLock { state in
            state.requests += 1
            return state.requests <= state.failures
        }
        if fail {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            return
        }
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: 200,
            httpVersion: nil, headerFields: nil) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("""
            <tv><channel id="ch1"><display-name>Fixture</display-name></channel>
            <programme start="20261102120000 +0000" stop="20261102130000 +0000" channel="ch1">
            <title>Fixture Programme</title></programme></tv>
            """.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
