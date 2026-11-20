import Foundation
import Testing
@testable import OpenStreamApple

@Suite(.timeLimit(.minutes(1))) struct AppleLiveZappingTests {
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
        session.beginSelection(programme: nil, shareSelection: true)
        #expect(session.request(for: channel, programme: session.programme).isLive)
        let now = Date()
        session.resumePending = true
        #expect(session.resumeTarget(enabled: true, active: false, watchedIDs: ["a"], availableIDs: ["a"],
                                     lastWatchedAt: now, now: now) == nil)
        #expect(session.resumePending)
        #expect(session.resumeTarget(enabled: true, active: true, watchedIDs: ["a"], availableIDs: ["a"],
                                     lastWatchedAt: now, now: now) == "a")
        #expect(!session.resumePending)
    }

    @MainActor @Test func supersededLiveProbeCannotSelectOrCacheThePreviousChannel() async throws {
        let (loads, pending) = AsyncStream.makeStream(of: CheckedContinuation<(Data, URLResponse), any Error>.self)
        let probe = AppleIPTVStreamProbe { _ in
            try await withCheckedThrowingContinuation { pending.yield($0) }
        }
        let session = AppleLiveSession(coordinator: ApplePlaybackCoordinator(engine: FakePlaybackEngine()), streamProbe: probe)
        let channel = AppleIPTVChannel(id: "a", sourceID: UUID(), name: "Fixture",
            streamURL: URL(string: "https://fixture.example/live")!)
        session.pendingProbe = .init(channel: channel, shareSelection: false, present: false)
        let old = Task { await session.resolvePendingProbe() }
        var started = loads.makeAsyncIterator()
        let continuation = try #require(await started.next())
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
        let now = Date()
        #expect(AppleLiveZappingPolicy.resumeTarget(enabled: true, liveTabActive: false,
            watchedIDs: ["a"], availableIDs: ["a"], lastWatchedAt: now, now: now) == nil)
        #expect(AppleLiveZappingPolicy.resumeTarget(enabled: false, liveTabActive: true,
            watchedIDs: ["a"], availableIDs: ["a"], lastWatchedAt: now, now: now) == nil)
        #expect(AppleLiveZappingPolicy.resumeTarget(enabled: true, liveTabActive: true,
            watchedIDs: ["removed", "a"], availableIDs: ["a"], lastWatchedAt: now, now: now) == "a")
        #expect(AppleLiveZappingPolicy.resumeTarget(enabled: true, liveTabActive: true,
            watchedIDs: [], availableIDs: ["a"], lastWatchedAt: now, now: now) == nil)
    }

    /// G18: resume only inside the window; older, Live opens on the guide.
    @Test func resumeNeedsAWatchInTheLastThirtyMinutes() {
        let now = Date()
        func target(_ lastWatchedAt: Date?) -> String? {
            AppleLiveZappingPolicy.resumeTarget(enabled: true, liveTabActive: true, watchedIDs: ["a"],
                                                availableIDs: ["a"], lastWatchedAt: lastWatchedAt, now: now)
        }
        #expect(target(now.addingTimeInterval(-29 * 60)) == "a")
        #expect(target(now.addingTimeInterval(-31 * 60)) == nil)
        #expect(target(nil) == nil)

        var history = AppleLiveWatchHistory()
        history.record("a", watchedSeconds: 5, at: now.addingTimeInterval(-40 * 60))
        history.touch("b", at: now)
        #expect(history.lastWatchedAt == now.addingTimeInterval(-40 * 60))
        history.touch("a", at: now)
        #expect(history.lastWatchedAt == now)
    }

    /// G18: leaving Live and coming back never re-arms the resume.
    @MainActor @Test func resumeArmsOnTheFirstLiveEntryOfALaunchOnly() {
        let monitor = AppleHangMonitor()
        monitor.screenAppeared("title")
        let first = AppleLiveSession(coordinator: ApplePlaybackCoordinator(engine: FakePlaybackEngine()), hangMonitor: monitor)
        first.enterLive()
        #expect(first.resumePending)
        #expect(monitor.currentScreen == "live")
        first.resumePending = false
        monitor.screenAppeared("search")
        first.refreshScreenLabel()
        #expect(!first.resumePending)
        #expect(monitor.currentScreen == "live")
        monitor.screenAppeared("discover")
        first.enterLive()
        #expect(!first.resumePending)
        #expect(monitor.currentScreen == "live")
        let later = AppleLiveSession(coordinator: ApplePlaybackCoordinator(engine: FakePlaybackEngine()), hangMonitor: monitor)
        later.enterLive()
        #expect(!later.resumePending)

        let now = Date()
        first.resumePending = true
        #expect(first.resumeTarget(enabled: true, active: true, watchedIDs: ["a"], availableIDs: ["a"],
                                   lastWatchedAt: now.addingTimeInterval(-3600), now: now) == nil)
        #expect(!first.resumePending)
    }

    /// G4: 5 presses in 1 s → exactly 1 stream open, on the channel they reached.
    @MainActor @Test func zapPressesCoalesceIntoOneTune() async throws {
        let zapper = AppleLiveZapCoalescer()
        var commits: [(String, Int)] = []
        let ids = ["a", "b", "c", "d", "e", "f", "g"]
        for _ in 0..<5 {
            zapper.press(.next, currentID: "a", orderedIDs: ids) { commits.append(($0, $1)) }
        }
        #expect(commits.isEmpty)
        #expect(zapper.pendingID == "f")
        try await waitUntil { !commits.isEmpty }
        try await Task.sleep(for: .milliseconds(600))
        #expect(commits.count == 1)
        #expect(commits.first?.0 == "f")
        #expect(commits.first?.1 == 5)
        #expect(zapper.pendingID == nil)
    }

    /// G4: Up on the last channel wraps to the first; back to where the
    /// presses started opens nothing.
    @MainActor @Test func zapWrapsAtTheEndsAndReturningHomeOpensNothing() async throws {
        let zapper = AppleLiveZapCoalescer(delay: .milliseconds(50))
        var commits: [String] = []
        zapper.press(.next, currentID: "c", orderedIDs: ["a", "b", "c"]) { id, _ in commits.append(id) }
        #expect(zapper.pendingID == "a")
        zapper.press(.previous, currentID: "c", orderedIDs: ["a", "b", "c"]) { id, _ in commits.append(id) }
        #expect(zapper.pendingID == nil)
        try await Task.sleep(for: .milliseconds(300))
        #expect(commits.isEmpty)
    }

    /// A press just after a tune, before the player reports the new channel,
    /// steps on from the channel that was tuned (Apple TV simulator trace 2026-10-18).
    @MainActor @Test func aPressRightAfterATuneStepsFromTheTunedChannel() async throws {
        let zapper = AppleLiveZapCoalescer(delay: .milliseconds(50))
        let ids = ["a", "b", "c", "d"]
        var commits: [String] = []
        zapper.press(.next, currentID: "a", orderedIDs: ids) { id, _ in commits.append(id) }
        zapper.press(.next, currentID: "a", orderedIDs: ids) { id, _ in commits.append(id) }
        try await waitUntil { !commits.isEmpty }
        #expect(commits == ["c"])
        zapper.press(.next, currentID: "a", orderedIDs: ids) { id, _ in commits.append(id) }
        #expect(zapper.pendingID == "d")
        zapper.cancel()
        zapper.press(.next, currentID: "c", orderedIDs: ids) { id, _ in commits.append(id) }
        #expect(zapper.pendingID == "d")
        zapper.cancel()
    }

    /// F12: one `live first picture` line per tune, from the tune to playing,
    /// keyed by channel id; a tune left before its picture is logged as abandoned.
    @MainActor @Test func firstPictureIsTracedOncePerTune() {
        let session = AppleLiveSession(coordinator: ApplePlaybackCoordinator(engine: FakePlaybackEngine()))
        func channel(_ id: String) -> AppleIPTVChannel {
            AppleIPTVChannel(id: id, sourceID: UUID(), name: "Same Name",
                             streamURL: URL(string: "https://fixture.example/live/\(id).m3u8")!)
        }
        session.markTuneStarted(channel("first-picture-left"))
        session.markTuneStarted(channel("first-picture-kept"))
        session.notePlaybackPhase(.loading)
        session.notePlaybackPhase(.playing)
        session.notePlaybackPhase(.playing)
        let trace = AppleInteractionTrace.snapshot()
        let kept = trace.filter { $0.contains("live first picture first-picture-kept ") }
        #expect(kept.count == 1)
        #expect(kept.first?.hasSuffix(" ms") == true)
        let left = trace.filter { $0.contains("live first picture first-picture-left abandoned ") }
        #expect(left.count == 1)
        #expect(left.first?.hasSuffix(" ms") == true)
    }

    /// Presses still waiting when the channel changes another way (a row,
    /// Last Channel) are dropped: their tune would override the choice.
    @MainActor @Test func aSwitchMadeAnotherWayDropsTheWaitingPresses() async throws {
        let zapper = AppleLiveZapCoalescer(delay: .milliseconds(50))
        let ids = ["a", "b", "c", "d"]
        var commits: [String] = []
        zapper.press(.next, currentID: "a", orderedIDs: ids) { id, _ in commits.append(id) }
        zapper.playerChanged(to: "a")
        #expect(zapper.pendingID == "b")
        zapper.playerChanged(to: "d")
        #expect(zapper.pendingID == nil)
        try await Task.sleep(for: .milliseconds(300))
        #expect(commits.isEmpty)

        zapper.press(.next, currentID: "a", orderedIDs: ids) { id, _ in commits.append(id) }
        try await waitUntil { !commits.isEmpty }
        zapper.press(.next, currentID: "a", orderedIDs: ids) { id, _ in commits.append(id) }
        zapper.playerChanged(to: "b")
        #expect(zapper.pendingID == "c")
        zapper.cancel()
    }

    @Test func recallAndResumeCanCrossTheCurrentGuideFilter() {
        var history = AppleLiveWatchHistory()
        history.record("sports", watchedSeconds: 5)
        history.record("news", watchedSeconds: 5)
        let loadedVisible: Set<String> = ["news", "sports"]
        #expect(AppleLiveZappingPolicy.target(currentID: "news", orderedIDs: ["news"], direction: .next) == nil)
        #expect(history.previous(currentID: "news", availableIDs: loadedVisible) == "sports")
        #expect(AppleLiveZappingPolicy.resumeTarget(enabled: true, liveTabActive: true,
            watchedIDs: history.channelIDs, availableIDs: loadedVisible, lastWatchedAt: history.lastWatchedAt) == "news")
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

    /// The coalescer's timer runs on the main actor, which a full parallel
    /// run keeps busy; wait for the commit rather than a fixed time.
    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    }
}
