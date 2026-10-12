import Foundation
import Synchronization
import Testing
@testable import OpenStreamApple

@Suite struct AppleLiveZappingTests {
    @MainActor @Test func sharedSessionPreservesCoordinatorAndArchiveAcrossSurfaceChanges() throws {
        let coordinator = ApplePlaybackCoordinator(engine: FakePlaybackEngine())
        let session = AppleLiveSession(coordinator: coordinator)
        var channel = AppleIPTVChannel(id: "a", sourceID: UUID(), name: "Fixture",
            streamURL: URL(string: "https://fixture.example/live/u/p/1.m3u8")!)
        channel.catchUpDays = 3
        let start = Date().addingTimeInterval(-1800)
        let programme = AppleIPTVProgramme(id: "p", channelID: "a", title: "Earlier", subtitle: nil,
            description: nil, start: start, end: start.addingTimeInterval(900), category: nil, isLive: false)
        session.beginSelection(programme: programme, shareSelection: false)
        session.channel = channel
        session.fullScreenRevision += 1
        session.multiviewChannels = [channel]
        #expect(session.coordinator === coordinator)
        #expect(!session.request(for: channel, programme: session.programme).isLive)
        #expect(session.zapTarget(currentID: "a", programme: programme, orderedIDs: ["a", "b"], direction: .next) == nil)
        session.beginSelection(programme: nil, shareSelection: true)
        #expect(session.request(for: channel, programme: session.programme).isLive)
        #expect(session.zapTarget(currentID: "a", programme: nil, orderedIDs: ["a", "b"], direction: .next) == "b")
        session.resumePending = true
        #expect(session.resumeTarget(enabled: true, active: false, watchedIDs: ["a"], availableIDs: ["a"]) == nil)
        #expect(session.resumePending)
        #expect(session.resumeTarget(enabled: true, active: true, watchedIDs: ["a"], availableIDs: ["a"]) == "a")
        #expect(!session.resumePending)
    }

    @MainActor @Test func supersededLiveProbeCannotSelectOrCacheThePreviousChannel() async throws {
        let pending = Mutex<CheckedContinuation<(Data, URLResponse), any Error>?>(nil)
        let probe = AppleIPTVStreamProbe { _ in
            try await withCheckedThrowingContinuation { continuation in pending.withLock { $0 = continuation } }
        }
        let session = AppleLiveSession(coordinator: ApplePlaybackCoordinator(engine: FakePlaybackEngine()), streamProbe: probe)
        let channel = AppleIPTVChannel(id: "a", sourceID: UUID(), name: "Fixture",
            streamURL: URL(string: "https://fixture.example/live")!)
        session.pendingProbe = .init(channel: channel, shareSelection: false, present: false)
        let old = Task { await session.resolvePendingProbe() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while pending.withLock({ $0 == nil }), ContinuousClock.now < deadline { await Task.yield() }
        let continuation = try #require(pending.withLock { $0 })
        let replacement = AppleLiveSession.ProbeRequest(channel: channel, shareSelection: true, present: true)
        session.pendingProbe = replacement
        continuation.resume(returning: (Data("#EXTM3U".utf8), HTTPURLResponse(url: channel.streamURL,
            statusCode: 200, httpVersion: nil, headerFields: nil)!))
        guard case .superseded = await old.value else { Issue.record("Superseded probe became current"); return }
        #expect(session.pendingProbe?.id == replacement.id)
        #expect(session.probedKinds.isEmpty && session.channel == nil)
    }

    @Test func onlyPlayedTimeQualifiesAndHistoryIsBounded() throws {
        var history = AppleLiveWatchHistory()
        history.record("preview", watchedSeconds: 4.99)
        history.record("failed", watchedSeconds: .nan)
        #expect(history.channelIDs.isEmpty)
        for index in 0..<12 { history.record("ch\(index)", watchedSeconds: 5) }
        #expect(history.channelIDs == (2..<12).reversed().map { "ch\($0)" })
        history.record("ch5", watchedSeconds: 5)
        #expect(history.channelIDs.first == "ch5")
        #expect(history.channelIDs.count == 10)
        let restored = try JSONDecoder().decode(AppleLiveWatchHistory.self, from: JSONEncoder().encode(history))
        #expect(restored == history)
    }

    @Test func recallFlipsEvenBeforeTheNewChannelQualifies() {
        var history = AppleLiveWatchHistory()
        history.record("a", watchedSeconds: 5)
        history.record("b", watchedSeconds: 5)
        #expect(history.previous(currentID: "b", availableIDs: ["a", "b"]) == "a")
        #expect(history.previous(currentID: "a", availableIDs: ["a", "b"]) == "b")
        #expect(history.previous(currentID: "b", availableIDs: ["b"]) == nil)
        #expect(history.previous(currentID: "preview", availableIDs: ["a", "b"]) == "b")
    }

    @Test func watchSessionExcludesBufferingPauseAndBackground() {
        var session = AppleLiveWatchSession()
        let result0 = session.advance(seconds: 20, playing: false)
        #expect(result0 == false)
        let result1 = session.advance(seconds: 3, playing: true)
        #expect(result1 == false)
        let result2 = session.advance(seconds: 20, playing: false)
        #expect(result2 == false)
        let result3 = session.advance(seconds: 2, playing: true)
        #expect(result3 == true)
        let result4 = session.advance(seconds: 10, playing: true)
        #expect(result4 == false)
        #expect(session.watchedSeconds == 5)
    }

    @Test func directionWrapsAndHandlesMissingOrSingleChannel() {
        #expect(AppleLiveZappingPolicy.target(currentID: "b", orderedIDs: ["a", "b", "c"], direction: .next) == "c")
        #expect(AppleLiveZappingPolicy.target(currentID: "a", orderedIDs: ["a", "b", "c"], direction: .previous) == "c")
        #expect(AppleLiveZappingPolicy.target(currentID: "c", orderedIDs: ["a", "b", "c"], direction: .next) == "a")
        #expect(AppleLiveZappingPolicy.target(currentID: "missing", orderedIDs: ["a", "b"], direction: .previous) == "b")
        #expect(AppleLiveZappingPolicy.target(currentID: "a", orderedIDs: ["a"], direction: .next) == nil)
        #expect(AppleLiveZappingPolicy.target(currentID: "a", orderedIDs: [], direction: .next) == nil)
    }

    @Test func remoteMappingPreservesMenusAndMultiviewFocus() {
        #expect(AppleLiveZappingPolicy.action(.up) == .zap(.next))
        #expect(AppleLiveZappingPolicy.action(.down) == .zap(.previous))
        #expect(AppleLiveZappingPolicy.action(.select) == .showInfo)
        #expect(AppleLiveZappingPolicy.action(.longSelect) == .showOptions)
        #expect(AppleLiveZappingPolicy.action(.up, infoVisible: true) == .navigate)
        #expect(AppleLiveZappingPolicy.action(.down, multiview: true) == .navigate)
        #expect(AppleLiveZappingPolicy.action(.up, multiview: true) == .navigate)
    }

    @Test @MainActor func historyPersistsLocallyAndIgnoresLegacySelection() throws {
        let name = "LiveZappingTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("preview", forKey: "openstream.live.lastChannelID")
        let store = AppleLiveWatchHistoryStore(defaults: defaults)
        #expect(store.history.channelIDs.isEmpty)
        store.record("a", watchedSeconds: 5)
        #expect(AppleLiveWatchHistoryStore(defaults: defaults).history.channelIDs == ["a"])
    }
    @Test func zappingUsesTheGuidePackageHiddenAndFavoriteOrder() {
        let source = UUID()
        let channels = ["a", "b", "c", "hidden", "outside"].enumerated().map { index, id in
            var channel = AppleIPTVChannel(id: id, sourceID: source, name: "Fixture \(id)", group: "News",
                streamURL: URL(string: "https://fixture.example/\(id).m3u8")!)
            channel.channelNumber = index + 1
            return channel
        }
        let visible = AppleLiveChannelPreferences.visible(channels, hiddenIDs: ["hidden"], hiddenGroups: [])
        var package = AppleCustomChannelPackage()
        package.channels = ["a": true, "b": true, "c": true, "hidden": true, "outside": false]
        let snapshot = AppleLiveChannelSnapshot.build(groups: [.init(name: "News", channels: visible)],
            package: .custom, custom: package, entries: [], favoriteIDs: ["a", "c"], category: "Favorites")
        let rows = AppleGuideChannelProjection.rows(channels: snapshot.channels, entries: [],
            favoriteIDs: ["a", "c"], favoritesOnly: false, sortByNumber: true, favoriteOrder: ["c", "a"])
        #expect(rows.map(\.id) == ["c", "a"])
        #expect(AppleLiveZappingPolicy.target(currentID: "c", orderedIDs: rows.map(\.id), direction: .next) == "a")
        #expect(!rows.contains { ["b", "hidden", "outside"].contains($0.id) })
    }

    @Test func swipesIgnoreScrubbingAndSmallDrags() {
        #expect(AppleLiveZappingPolicy.swipe(horizontal: 10, vertical: -80) == .next)
        #expect(AppleLiveZappingPolicy.swipe(horizontal: 0, vertical: 80) == .previous)
        #expect(AppleLiveZappingPolicy.swipe(horizontal: 100, vertical: 80) == nil)
        #expect(AppleLiveZappingPolicy.swipe(horizontal: 0, vertical: 59) == nil)
    }

    @Test func resumeOnlyRunsWhenLiveOpensAndSkipsUnavailableChannels() {
        #expect(AppleLiveZappingPolicy.resumeTarget(enabled: true, liveTabActive: false,
            watchedIDs: ["a"], availableIDs: ["a"]) == nil)
        #expect(AppleLiveZappingPolicy.resumeTarget(enabled: false, liveTabActive: true,
            watchedIDs: ["a"], availableIDs: ["a"]) == nil)
        #expect(AppleLiveZappingPolicy.resumeTarget(enabled: true, liveTabActive: true,
            watchedIDs: ["removed", "a"], availableIDs: ["a"]) == "a")
        #expect(AppleLiveZappingPolicy.resumeTarget(enabled: true, liveTabActive: true,
            watchedIDs: [], availableIDs: ["a"]) == nil)
    }

    @Test func recallAndResumeCanCrossTheCurrentGuideFilter() {
        var history = AppleLiveWatchHistory()
        history.record("sports", watchedSeconds: 5)
        history.record("news", watchedSeconds: 5)
        let loadedVisible: Set<String> = ["news", "sports"]
        #expect(AppleLiveZappingPolicy.target(currentID: "news", orderedIDs: ["news"], direction: .next) == nil)
        #expect(history.previous(currentID: "news", availableIDs: loadedVisible) == "sports")
        #expect(AppleLiveZappingPolicy.resumeTarget(enabled: true, liveTabActive: true,
            watchedIDs: history.channelIDs, availableIDs: loadedVisible) == "news")
        #expect(history.previous(currentID: "news", availableIDs: ["news"]) == nil)
    }

    @Test func programmeFetchIncludesARecalledChannelOutsideTheGuide() {
        #expect(AppleLiveZappingPolicy.guideNeighborhood(currentID: "sports", orderedIDs: ["a", "b", "c"], radius: 1) == ["sports", "a"])
        #expect(AppleLiveZappingPolicy.guideNeighborhood(currentID: "b", orderedIDs: ["a", "b", "c"], radius: 1) == ["a", "b"])
        #expect(AppleLiveZappingPolicy.guideNeighborhood(currentID: "sports", orderedIDs: [], radius: 1) == ["sports"])
    }

    @Test func playerMenuMultiviewChoosesADistinctCompanionWithoutAHeldChannel() {
        #expect(AppleMultiviewPolicy.companionID(currentID: "a", heldID: nil, orderedIDs: ["a", "b"]) == "b")
        #expect(AppleMultiviewPolicy.companionID(currentID: "a", heldID: "a", orderedIDs: ["a", "b"]) == "b")
        #expect(AppleMultiviewPolicy.companionID(currentID: "a", heldID: "c", orderedIDs: ["a", "b"]) == "c")
        #expect(AppleMultiviewPolicy.companionID(currentID: "a", heldID: nil, orderedIDs: ["a"]) == nil)
    }

    @Test func aRequestedChannelIsHandledOnceTheSavedLineupKnowsIt() {
        #expect(AppleLiveZappingPolicy.handlesRequest(isLoading: true, channelIsKnown: true))
        #expect(!AppleLiveZappingPolicy.handlesRequest(isLoading: true, channelIsKnown: false))
        #expect(AppleLiveZappingPolicy.handlesRequest(isLoading: false, channelIsKnown: false))
    }

    @Test func askingForTheChannelAlreadyStartingKeepsItsAttempt() {
        for phase: ApplePlaybackPhase in [.resolving, .loading, .waiting(nil), .playing, .paused] {
            #expect(AppleLiveZappingPolicy.keepsCurrentAttempt(requestedID: "cbs", selectedID: "cbs",
                isCatchUp: false, phase: phase))
        }
        for phase: ApplePlaybackPhase in [.idle, .ended, .failed(ApplePlaybackFailure(kind: .timedOut, message: "t"))] {
            #expect(!AppleLiveZappingPolicy.keepsCurrentAttempt(requestedID: "cbs", selectedID: "cbs",
                isCatchUp: false, phase: phase))
        }
        #expect(!AppleLiveZappingPolicy.keepsCurrentAttempt(requestedID: "fox", selectedID: "cbs",
            isCatchUp: false, phase: .loading))
        #expect(!AppleLiveZappingPolicy.keepsCurrentAttempt(requestedID: "cbs", selectedID: "cbs",
            isCatchUp: true, phase: .playing))
    }
}
