import Foundation
import Testing
@testable import OpenStreamApple

/// A stream service that is down (5xx, timeouts, no route, its own
/// "maintenance" answer) is skipped for another service's streams, demoted on
/// the next play for a few minutes, and never dropped.
@MainActor
@Suite(.serialized) struct AppleStreamServiceHealthTests {
    private static let serviceA = "addon a|fixture.example"
    private static let serviceB = "addon b|fixture.example"
    private static let device = AppleStreamDeviceCapabilities(supportsHDR: true, supportsDolbyVision: false)

    private func request(_ id: String, service: String?) -> ApplePlaybackRequest {
        ApplePlaybackRequest(
            url: URL(string: "http://127.0.0.1:8765/\(id).mp4")!,
            mediaID: id,
            sourceKind: .stremio,
            hints: .init(serviceKey: service)
        )
    }

    private func candidate(_ file: String, addon: String, host: String = "media.fixture.example") -> AppleStremioHTTPPlaybackCandidate {
        AppleStremioHTTPPlaybackCandidate(title: file, sourceURL: URL(string: "https://\(host)/\(file)")!,
                                          filename: file, sourceName: addon)
    }

    // MARK: - Classification

    @Test(arguments: [500, 502, 503, 504, 429])
    func serverErrorsMeanTheServiceIsDown(status: Int) {
        let failure = ApplePlaybackFailure(kind: .network, message: "HTTP \(status)", httpStatus: status)
        #expect(AppleStreamServiceFailureScope.of(failure) == .service)
    }

    @Test(arguments: [404, 410, 401, 403])
    func oneMissingOrRefusedFileIsNotTheService(status: Int) {
        let kind: ApplePlaybackFailure.Kind = status == 401 || status == 403 ? .authentication : .network
        let failure = ApplePlaybackFailure(kind: kind, message: "HTTP \(status)", httpStatus: status)
        #expect(AppleStreamServiceFailureScope.of(failure) == .stream)
    }

    @Test func unreachableHostsTimeoutsAndAddonErrorsAreServiceLevel() {
        for code in [URLError.Code.cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .timedOut] {
            #expect(AppleStreamServiceFailureScope.of(ApplePlaybackFailure.classify(URLError(code))) == .service)
        }
        let addon = ApplePlaybackFailure.classify(AppleStremioPlaybackError.requestFailed(503))
        #expect(addon.httpStatus == 503)
        #expect(AppleStreamServiceFailureScope.of(addon) == .service)
        let maintenance = ApplePlaybackFailure(kind: .player, message: "Service down for maintenance, try later")
        #expect(AppleStreamServiceFailureScope.of(maintenance) == .service)
    }

    @Test func codecAndDecoderFailuresAreStreamLevel() {
        #expect(AppleStreamServiceFailureScope.of(.init(kind: .unsupportedMedia, message: "Unsupported codec")) == .stream)
        #expect(AppleStreamServiceFailureScope.of(.init(kind: .player, message: "The decoder failed.")) == .stream)
        #expect(AppleStreamServiceFailureScope.of(.classify(URLError(.cannotDecodeContentData))) == .stream)
    }

    // MARK: - Service keys

    @Test func serviceKeyIsTheAddonAndTheDomain() {
        let first = candidate("One.1080p.mkv", addon: "Addon A", host: "a1.cdn.fixture.example")
        let second = candidate("Two.1080p.mkv", addon: "Addon A", host: "b7.fixture.example")
        let other = candidate("Three.1080p.mkv", addon: "Addon B", host: "a1.cdn.fixture.example")
        #expect(first.serviceKey == Self.serviceA)
        #expect(first.serviceKey == second.serviceKey)
        #expect(first.serviceKey != other.serviceKey)
        #expect(AppleStreamServiceKey.domain(of: "127.0.0.1") == "127.0.0.1")
        #expect(AppleStreamServiceKey.domain(of: "media.fixture.co.uk") == "fixture.co.uk")
        #expect(AppleStreamServiceKey.traceName(Self.serviceA) == "addon a")
        #expect(first.playbackRequest(mediaID: "m", title: nil, resume: nil).hints.serviceKey == Self.serviceA)
    }

    // MARK: - Ordering

    @Test func playbackOrderDemotesADownServiceButKeepsIt() {
        let streams = [
            candidate("A.2160p.mkv", addon: "Addon A"),
            candidate("A.1080p.mkv", addon: "Addon A"),
            candidate("B.720p.mkv", addon: "Addon B"),
        ]
        let healthy = AppleStremioCandidateRanking.playbackOrder(streams, choice: .automatic, device: Self.device)
        #expect(healthy.map(\.title) == ["A.2160p.mkv", "A.1080p.mkv", "B.720p.mkv"])
        let demoted = AppleStremioCandidateRanking.playbackOrder(streams, choice: .automatic, device: Self.device,
                                                                 unhealthyServices: [Self.serviceA])
        #expect(demoted.map(\.title) == ["B.720p.mkv", "A.2160p.mkv", "A.1080p.mkv"])
    }

    @Test func healthExpiresAfterItsTimeToLiveAndRestoresTheOrder() {
        let health = AppleStreamServiceHealth(timeToLive: 600)
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        health.recordFailure(Self.serviceA, now: start)
        #expect(health.isUnhealthy(Self.serviceA, now: start.addingTimeInterval(599)))
        #expect(health.unhealthyKeys(now: start.addingTimeInterval(599)) == [Self.serviceA])
        #expect(health.isUnhealthy(Self.serviceA, now: start.addingTimeInterval(601)) == false)
        #expect(health.unhealthyKeys(now: start.addingTimeInterval(601)).isEmpty)
        let items = [(1, Self.serviceA), (2, Self.serviceB), (3, Self.serviceA)]
        #expect(health.healthyFirst(items, now: start.addingTimeInterval(10), key: \.1).map(\.0) == [2, 1, 3])
        #expect(health.healthyFirst(items, now: start.addingTimeInterval(601), key: \.1).map(\.0) == [1, 2, 3])
    }

    // MARK: - Fallback loop

    @Test func aDownServiceIsSkippedForAnotherServicesStream() async {
        let engine = FakePlaybackEngine()
        engine.loadHandler = { request in
            if request.hints.serviceKey == Self.serviceA {
                throw ApplePlaybackFailure(kind: .network, message: "HTTP 503", httpStatus: 503)
            }
            engine.phase = .playing
        }
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        coordinator.serviceHealth = AppleStreamServiceHealth()
        await coordinator.begin(request("a1", service: Self.serviceA), fallbackCandidates: [
            request("a2", service: Self.serviceA), request("b1", service: Self.serviceB),
        ])
        _ = await coordinatorWaitUntilHealthy { coordinator.phase == .playing }
        #expect(engine.loadedRequests.map(\.mediaID) == ["a1", "b1"])
        #expect(coordinator.serviceHealth.isUnhealthy(Self.serviceA))
        coordinator.stop()
    }

    @Test func aMissingFileDoesNotSkipTheRestOfItsService() async {
        let engine = FakePlaybackEngine()
        engine.loadHandler = { request in
            if request.mediaID == "a1" { throw ApplePlaybackFailure(kind: .network, message: "HTTP 404", httpStatus: 404) }
            engine.phase = .playing
        }
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        coordinator.serviceHealth = AppleStreamServiceHealth()
        await coordinator.begin(request("a1", service: Self.serviceA), fallbackCandidates: [
            request("a2", service: Self.serviceA), request("b1", service: Self.serviceB),
        ])
        _ = await coordinatorWaitUntilHealthy { coordinator.phase == .playing }
        #expect(engine.loadedRequests.map(\.mediaID) == ["a1", "a2"])
        #expect(coordinator.serviceHealth.isUnhealthy(Self.serviceA) == false)
        coordinator.stop()
    }

    @Test func withOnlyOneServiceEveryStreamIsStillTried() async {
        let engine = FakePlaybackEngine()
        engine.loadHandler = { request in
            if request.mediaID == "a3" { engine.phase = .playing; return }
            throw ApplePlaybackFailure(kind: .network, message: "HTTP 503", httpStatus: 503)
        }
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        coordinator.serviceHealth = AppleStreamServiceHealth()
        await coordinator.begin(request("a1", service: Self.serviceA), fallbackCandidates: [
            request("a2", service: Self.serviceA), request("a3", service: Self.serviceA),
        ])
        _ = await coordinatorWaitUntilHealthy { coordinator.phase == .playing }
        #expect(engine.loadedRequests.map(\.mediaID) == ["a1", "a2", "a3"])
        #expect(coordinator.phase == .playing)
        coordinator.stop()
    }

    // MARK: - Add-on requests

    @Test func anAddonThatIsDownDoesNotHideTheOtherAddonsStreams() async throws {
        let client = AppleStremioPlaybackClient { request in
            let down = request.url?.host == "down.fixture.example"
            let body = down ? #"{"error":"unavailable"}"# : #"{"streams":[{"url":"https://media.fixture.example/ready.mp4"}]}"#
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: down ? 503 : 200,
                                                     httpVersion: nil, headerFields: nil)!)
        }
        func source(_ host: String, name: String) -> AppleSource {
            AppleSource(kind: .stremio, name: name, url: URL(string: "https://\(host)/manifest.json")!,
                        isEnabled: true, manifestID: "fixture.\(name)", resources: ["stream"])
        }
        let down = source("down.fixture.example", name: "Down")
        let resolver = AppleStremioPlaybackResolver(client: client)
        let streams = try await resolver.rankedCandidates(sources: [down, source("up.fixture.example", name: "Up")],
            preferredSourceID: down.id, item: .init(mediaID: "tt123", type: "movie", name: "Fixture"))
        #expect(streams.map(\.sourceURL.absoluteString) == ["https://media.fixture.example/ready.mp4"])
        #expect(streams.first?.sourceName == "Up")
    }
}

private func coordinatorWaitUntilHealthy(
    timeout: Duration = .seconds(8),
    _ condition: @MainActor () -> Bool
) async -> Bool {
    let deadline = ContinuousClock().now + timeout
    while ContinuousClock().now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return false
}
