import Foundation
import Synchronization
import Testing
@testable import OpenStreamApple

struct AppleIPTVConnectionLimitTests {
    fileprivate static func info(active: Int, maximum: Int = 1) -> AppleIPTVAccountInfo {
        .init(expiration: nil, maxConnections: String(maximum), activeConnections: String(active), status: "Active")
    }

    @MainActor private static func noteStop(sourceID: UUID, now: ContinuousClock.Instant) {
        let owner = NSObject()
        AppleIPTVPreviewActivity.shared.began(owner, sourceID: sourceID)
        AppleIPTVPreviewActivity.shared.ended(owner, now: now)
    }

    @Test func firstPlayDoesNotProbeThePanel() async throws {
        let panel = try await PanelFixture()
        defer { withExtendedLifetime(panel) {} }
        let accounts = panel.accounts
        let sourceID = panel.sourceID
        let calls = Mutex(0)
        await panel.answer(active: 1, {
            calls.withLock { $0 += 1 }
            throw URLError(.timedOut)
        })
        try await accounts.waitForAvailableConnection(sourceID: sourceID, clock: ManualClock())
        #expect(calls.withLock { $0 } == 0)
    }

    @MainActor @Test func previewsRespectPersistedLimitsAndRecentPlayback() async throws {
        let suite = "iptv-limits-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let accounts = AppleIPTVAccountLimits(defaults: UserDefaults(suiteName: suite))
        let sourceID = UUID()
        let activity = AppleIPTVPreviewActivity()
        #expect(activity.allowsAutomaticPreview(sourceID: sourceID, maximumConnections: await accounts.snapshot()[sourceID]))
        await accounts.record(Self.info(active: 0), sourceID: sourceID)
        await accounts.record(.init(expiration: nil, maxConnections: nil, activeConnections: nil, status: "Active"), sourceID: sourceID)
        let relaunched = AppleIPTVAccountLimits(defaults: UserDefaults(suiteName: suite))
        #expect(await relaunched.snapshot()[sourceID] == 1)
        #expect(activity.allowsAutomaticPreview(sourceID: sourceID, maximumConnections: await relaunched.snapshot()[sourceID]))
        let owner = NSObject()
        activity.began(owner, sourceID: sourceID)
        #expect(activity.allowsAutomaticPreview(sourceID: sourceID, maximumConnections: await relaunched.snapshot()[sourceID]) == false)
        await relaunched.record(Self.info(active: 0, maximum: 2), sourceID: sourceID)
        let multiConnection = AppleIPTVAccountLimits(defaults: UserDefaults(suiteName: suite))
        #expect(activity.allowsAutomaticPreview(sourceID: sourceID, maximumConnections: await multiConnection.snapshot()[sourceID]))
    }

    /// Measured 2026-11-07 on the owner's one-connection Xtream panel, with
    /// one stream already open and the panel reporting 1 of 1 in use: a
    /// second channel is not refused. It answers 302 to a 200 `video/mp2t`
    /// stream and both play; no 403/509/458 and no dropped connection. So a
    /// busy-looking account is never itself a reason to fail or retry.
    @Test func theOwnersPanelServesASecondStreamWhileReportingItselfFull() async throws {
        let url = try #require(URL(string: "https://fixture.example/live/2.ts"))
        var packets = Data()
        for _ in 0..<3 { packets.append(0x47); packets.append(Data(repeating: 0xFF, count: 187)) }
        let stream = packets
        let probe = AppleIPTVStreamProbe { _ in
            (stream, try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "video/mp2t", "Server": "nginx"])))
        }
        let result = try await probe.validate(channel: AppleIPTVChannel(id: "2", sourceID: UUID(),
            name: "ANIMAL PLANET", streamURL: url))
        #expect(result.statusCode == 200)
        #expect(result.mediaKind == .rawMPEGTransportStream)
    }

    @Test func limitsOfDeletedSourcesArePruned() async throws {
        let suite = "iptv-limits-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let panel = try await PanelFixture()
        let kept = UUID()
        let deleted = UUID()
        let accounts = AppleIPTVAccountLimits(defaults: UserDefaults(suiteName: suite))
        await accounts.record(Self.info(active: 0), sourceID: kept)
        await accounts.record(Self.info(active: 0, maximum: 2), sourceID: deleted)
        await accounts.registerSourceStore(await panel.store, sourceIDs: [kept])
        #expect(await accounts.snapshot() == [kept: 1])
        let relaunched = AppleIPTVAccountLimits(defaults: UserDefaults(suiteName: suite))
        #expect(await relaunched.snapshot() == [kept: 1])
    }

    @MainActor @Test(arguments: [nil, 0, 2] as [Int?])
    func unknownAndUnlimitedAccountsKeepAutomaticPreviews(maximum: Int?) {
        let activity = AppleIPTVPreviewActivity()
        let sourceID = UUID()
        let owner = NSObject()
        activity.began(owner, sourceID: sourceID)
        #expect(activity.allowsAutomaticPreview(sourceID: sourceID, maximumConnections: maximum))
    }

    @MainActor @Test func previewSuppressionEndsAfterTheOutgoingStreamCloses() {
        let activity = AppleIPTVPreviewActivity()
        let sourceID = UUID()
        let otherSourceID = UUID()
        let owner = NSObject()
        let now = ContinuousClock.now
        #expect(activity.isActiveOrRecent(sourceID: sourceID, now: now) == false)
        activity.began(owner, sourceID: sourceID)
        #expect(activity.isActiveOrRecent(sourceID: sourceID, now: now))
        #expect(activity.isActiveOrRecent(sourceID: otherSourceID, now: now) == false)
        activity.ended(owner, now: now)
        #expect(activity.isActiveOrRecent(sourceID: sourceID, now: now.advanced(by: .milliseconds(1999))))
        #expect(activity.isActiveOrRecent(sourceID: sourceID, now: now.advanced(by: .seconds(2))) == false)
        activity.ended(owner, now: now.advanced(by: .seconds(2)))
        #expect(activity.isActiveOrRecent(sourceID: sourceID, now: now.advanced(by: .seconds(2))) == false)
    }

    @MainActor @Test func slotPollingResolvesCredentialsOncePerWaitAndSkipsAMissingStore() async throws {
        let suite = "iptv-probe-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let keychain = IPTVAccountTestCredentials()
        var store: AppleSourceStore? = AppleSourceStore(defaults: defaults, keychain: keychain)
        weak let observedStore = store
        let source = try #require(store).addIPTV(name: "Fixture", type: .xtream,
            endpoint: "https://fixture.example", username: "fixture", password: "first-fixture")
        let passwords = Mutex<[String]>([])
        let client = AppleIPTVClient { request in
            let url = try #require(request.url)
            let password = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "password" })?.value
            let count = passwords.withLock { $0.append(password ?? ""); return $0.count }
            let active = count.isMultiple(of: 2) ? 0 : 1
            return (Data("{\"user_info\":{\"auth\":1,\"status\":\"Active\",\"max_connections\":\"1\",\"active_cons\":\(active)}}".utf8),
                try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
        let accounts = AppleIPTVAccountLimits(client: client)
        await accounts.registerSourceStore(try #require(store), sourceIDs: [source.id])
        await accounts.record(Self.info(active: 0), sourceID: source.id)
        let clock = ManualClock()
        Self.noteStop(sourceID: source.id, now: clock.now)
        let reads = keychain.reads
        let firstWait = Task { try await accounts.waitForAvailableConnection(sourceID: source.id, clock: clock) }
        await clock.waitForSleep(until: .milliseconds(100))
        let updated = AppleIPTVCredentials(username: "fixture", password: "updated-fixture")
        try keychain.set(String(decoding: JSONEncoder().encode(updated), as: UTF8.self),
            for: try #require(source.credentialReference))
        clock.advance(to: .milliseconds(100))
        try await firstWait.value
        Self.noteStop(sourceID: source.id, now: clock.now)
        let secondWait = Task { try await accounts.waitForAvailableConnection(sourceID: source.id, clock: clock) }
        await clock.waitForSleep(until: .milliseconds(200))
        clock.advance(to: .milliseconds(200))
        try await secondWait.value
        #expect(passwords.withLock { $0 } == ["first-fixture", "first-fixture", "updated-fixture", "updated-fixture"])
        #expect(keychain.reads - reads == 2)
        store = nil
        #expect(observedStore == nil)
        Self.noteStop(sourceID: source.id, now: clock.now)
        try await accounts.waitForAvailableConnection(sourceID: source.id, clock: clock)
        #expect(passwords.withLock { $0.count } == 4)
    }

    @MainActor @Test(arguments: [nil, 0, 1, 2] as [Int?])
    func closingFullScreenReleasesOnlySingleConnectionAccounts(maximum: Int?) async throws {
        let engine = FakePlaybackEngine()
        engine.script([.playing])
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        coordinator.iptvAccounts = AppleIPTVAccountLimits()
        defer { coordinator.stop() }
        let channel = AppleIPTVChannel(id: "fixture", sourceID: UUID(), name: "Fixture",
            streamURL: try #require(URL(string: "https://fixture.example/live.ts")))
        let session = AppleLiveSession(coordinator: coordinator)
        session.channel = channel
        session.resumePending = true
        session.fullScreenRevision = 3
        await coordinator.begin(channel.playbackRequest())
        session.closeFullScreen(maximumConnections: maximum)
        if maximum == 1 {
            #expect(coordinator.phase == .idle)
            #expect(engine.phase == .idle)
            #expect(session.channel == nil)
            #expect(session.resumePending == false)
            #expect(session.fullScreenRevision == 0)
        } else {
            #expect(coordinator.phase == .playing)
            #expect(session.channel?.id == channel.id)
            #expect(session.fullScreenRevision == 3)
        }
        #expect(engine.loadedRequests.count == 1)
    }

    @MainActor @Test func returningToTheGuideDoesNotRestartAnElapsedCloseWait() async throws {
        let panel = try await PanelFixture()
        defer { withExtendedLifetime(panel) {} }
        let accounts = panel.accounts
        let sourceID = panel.sourceID
        let owner = NSObject()
        let clock = ManualClock()
        AppleIPTVPreviewActivity.shared.began(owner, sourceID: sourceID)
        AppleIPTVPreviewActivity.shared.ended(owner, now: clock.now)
        clock.advance(to: .seconds(1))
        let checks = Mutex(0)
        await panel.answer(active: 1, {
            checks.withLock { $0 += 1 }
            throw URLError(.timedOut)
        })
        try await accounts.waitForAvailableConnection(sourceID: sourceID, clock: clock)
        #expect(checks.withLock { $0 } == 0)
    }

    @Test(arguments: [false, true])
    func connectionCheckWaitsForTheProviderToReleaseTheOldStream(rejectsAccountProbe: Bool) async throws {
        let panel = try await PanelFixture()
        defer { withExtendedLifetime(panel) {} }
        let accounts = panel.accounts
        let sourceID = panel.sourceID
        let clock = ManualClock()
        await Self.noteStop(sourceID: sourceID, now: clock.now)
        let calls = Mutex(0)
        await panel.answer(active: 1, {
            let count = calls.withLock { $0 += 1; return $0 }
            if count == 1, rejectsAccountProbe { throw AppleIPTVError.authenticationFailed(status: "MaxConnections") }
            return Self.info(active: count == 1 ? 1 : 0)
        })
        let closed = Mutex(false)
        let waiting = Task {
            try await accounts.waitForAvailableConnection(sourceID: sourceID, clock: clock)
            closed.withLock { $0 = true }
        }
        await clock.waitForSleep(until: .milliseconds(100))
        #expect(closed.withLock { $0 } == false)
        clock.advance(to: .milliseconds(100))
        try await waiting.value
        #expect(closed.withLock { $0 })
        #expect(calls.withLock { $0 } == 2)
    }

    @MainActor @Test func aStaleBusyAccountHasABoundedWaitThenAllowsTheStreamOpen() async throws {
        let panel = try await PanelFixture()
        defer { withExtendedLifetime(panel) {} }
        let accounts = panel.accounts
        let sourceID = panel.sourceID
        let clock = ManualClock()
        Self.noteStop(sourceID: sourceID, now: clock.now)
        let checks = Mutex(0)
        await panel.answer(active: 1, {
            checks.withLock { $0 += 1 }
            return Self.info(active: 1)
        })
        let engine = FakePlaybackEngine()
        engine.script([.playing])
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        coordinator.iptvAccounts = accounts
        coordinator.clock = clock
        defer { coordinator.stop() }
        var request = ApplePlaybackRequest(url: try #require(URL(string: "https://fixture.example/live.ts")),
            isLive: true, mediaID: "channel", sourceKind: .liveTV)
        request.iptvSourceID = sourceID
        let waiting = Task { await coordinator.begin(request) }
        await clock.waitForSleep(until: .milliseconds(100))
        clock.advance(to: .seconds(2))
        await waiting.value
        #expect(checks.withLock { $0 } == 1)
        #expect(engine.loadedRequests.count == 1)
        #expect(coordinator.phase == .playing)
    }

    /// The panel serves the new stream while it still counts the old one, so
    /// a busy count holds a switch for 1 s at most.
    @Test func aBusySlotHoldsTheSwitchForOneSecondAtMost() async throws {
        let panel = try await PanelFixture()
        defer { withExtendedLifetime(panel) {} }
        let clock = ManualClock()
        await Self.noteStop(sourceID: panel.sourceID, now: clock.now)
        let checks = Mutex(0)
        await panel.answer(active: 1, {
            checks.withLock { $0 += 1 }
            return Self.info(active: 1)
        })
        let accounts = panel.accounts
        let sourceID = panel.sourceID
        let waiting = Task { try await accounts.waitForAvailableConnection(sourceID: sourceID, clock: clock) }
        for poll in 1...10 {
            await clock.waitForSleeps(poll)
            clock.advance(by: .milliseconds(100))
        }
        waiting.cancel()
        await #expect(throws: Never.self) { try await waiting.value }
        #expect(checks.withLock { $0 } == 10)
        #expect(clock.requestedDeadlines.last == .seconds(1))
    }

    @Test func anUnavailableAccountProbeDoesNotPreventPlayback() async throws {
        let panel = try await PanelFixture()
        defer { withExtendedLifetime(panel) {} }
        let accounts = panel.accounts
        let sourceID = panel.sourceID
        let clock = ManualClock()
        await Self.noteStop(sourceID: sourceID, now: clock.now)
        let calls = Mutex(0)
        await panel.answer(active: 1, {
            calls.withLock { $0 += 1 }
            throw URLError(.timedOut)
        })
        try await accounts.waitForAvailableConnection(sourceID: sourceID, clock: clock)
        #expect(calls.withLock { $0 } == 1)
    }

    @Test func aCancelledProbeStillCancelsTheStreamOpen() async throws {
        let panel = try await PanelFixture()
        defer { withExtendedLifetime(panel) {} }
        let accounts = panel.accounts
        let sourceID = panel.sourceID
        await Self.noteStop(sourceID: sourceID, now: .now)
        await panel.answer(active: 1, { throw CancellationError() })
        await #expect(throws: CancellationError.self) {
            try await accounts.waitForAvailableConnection(sourceID: sourceID)
        }
    }

    @Test func accountInfoRecordsLimitsEvenWhenTheLineupCannotBeLoaded() async throws {
        let source = AppleSource(kind: .liveTV, name: "Fixture", url: try #require(URL(string: "https://fixture.example")), iptvType: .xtream)
        let client = AppleIPTVClient { request in
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (Data(#"{"user_info":{"auth":1,"status":"Active","max_connections":"1","active_cons":1}}"#.utf8), response)
        }
        await #expect(throws: AppleIPTVError.authenticationFailed(status: "MaxConnections")) {
            _ = try await client.channels(source: source, credentials: .init(username: "fixture", password: "fixture"))
        }
        #expect(await AppleIPTVAccountLimits.shared.snapshot()[source.id] == 1)
        let account = try await client.accountInfo(source: source, credentials: .init(username: "fixture", password: "fixture"))
        #expect(account.maxConnections == 1)
        #expect(await AppleIPTVAccountLimits.shared.snapshot()[source.id] == 1)
    }

    /// The retry waits for the slot again: a refusal means the panel still
    /// counts the old stream, and reopening at once would be refused too.
    @MainActor @Test(arguments: [false, true])
    func aConfirmedLimitRejectionRewaitsForTheSlotAndRetriesOnlyOnce(rejectAgain: Bool) async throws {
        let panel = try await PanelFixture()
        defer { withExtendedLifetime(panel) {} }
        let accounts = panel.accounts
        let sourceID = panel.sourceID
        let clock = ManualClock()
        Self.noteStop(sourceID: sourceID, now: clock.now)
        let checks = Mutex(0)
        await panel.answer(active: 0, {
            let count = checks.withLock { $0 += 1; return $0 }
            return Self.info(active: count.isMultiple(of: 2) ? 0 : 1)
        })
        let engine = FakePlaybackEngine()
        engine.loadHandler = { _ in
            if engine.loadedRequests.count == 1 || rejectAgain {
                throw ApplePlaybackFailure(kind: .authentication, message: "Fixture rejected the stream", httpStatus: 403,
                    isConnectionLimit: true)
            }
            engine.phase = .playing
        }
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        coordinator.iptvAccounts = accounts
        coordinator.clock = clock
        defer { coordinator.stop() }
        var request = ApplePlaybackRequest(url: try #require(URL(string: "https://fixture.example/live.ts")),
            isLive: true, mediaID: "channel", sourceKind: .liveTV)
        request.iptvSourceID = sourceID
        let tuning = Task { await coordinator.begin(request) }
        await clock.waitForSleep(until: .milliseconds(100))
        #expect(engine.loadedRequests.isEmpty)
        clock.advance(to: .milliseconds(100))
        await clock.waitForSleep(until: .milliseconds(200))
        #expect(engine.loadedRequests.count == 1)
        clock.advance(to: .milliseconds(200))
        await tuning.value
        #expect(checks.withLock { $0 } == 4)
        #expect(engine.loadedRequests.count == 2)
        if rejectAgain {
            if case .failed(let failure) = coordinator.phase {
                #expect(failure.isConnectionLimit)
            } else { Issue.record("The repeated limit rejection did not stop playback") }
        } else {
            #expect(coordinator.phase == .playing)
        }
    }

    @MainActor @Test func anAlternateDoesNotRestartTheTunesConnectionWait() async throws {
        let panel = try await PanelFixture()
        defer { withExtendedLifetime(panel) {} }
        let accounts = panel.accounts
        let sourceID = panel.sourceID
        let clock = ManualClock()
        Self.noteStop(sourceID: sourceID, now: clock.now)
        let checks = Mutex(0)
        await panel.answer(active: 0, {
            checks.withLock { $0 += 1 }
            return Self.info(active: 0)
        })
        let engine = FakePlaybackEngine()
        engine.loadHandler = { _ in
            if engine.loadedRequests.count == 1 {
                throw ApplePlaybackFailure(kind: .unsupportedMedia, message: "Fixture format is unsupported")
            }
            engine.phase = .playing
        }
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        coordinator.iptvAccounts = accounts
        coordinator.clock = clock
        defer { coordinator.stop() }
        var request = ApplePlaybackRequest(url: try #require(URL(string: "https://fixture.example/first.m3u8")),
            isLive: true, mediaID: "channel", sourceKind: .liveTV)
        request.iptvSourceID = sourceID
        var alternate = request
        alternate.url = try #require(URL(string: "https://fixture.example/alternate.m3u8"))
        await coordinator.begin(request, fallbackCandidates: [alternate])
        #expect(engine.loadedRequests.count == 2)
        #expect(coordinator.phase == .playing)
        #expect(checks.withLock { $0 } == 1)
    }

    @MainActor @Test(arguments: [ApplePlaybackFailure.Kind.authentication, .timedOut, .unavailable])
    func anOrdinaryPrePlayFailureDoesNotProbeOrRetryALimit(kind: ApplePlaybackFailure.Kind) async throws {
        let panel = try await PanelFixture()
        defer { withExtendedLifetime(panel) {} }
        let accounts = panel.accounts
        let sourceID = panel.sourceID
        let checks = Mutex(0)
        await panel.answer(active: 0, {
            let count = checks.withLock { $0 += 1; return $0 }
            return Self.info(active: count == 1 ? 0 : 1)
        })
        let engine = FakePlaybackEngine()
        engine.loadHandler = { _ in throw ApplePlaybackFailure(kind: kind, message: "Fixture open failed", httpStatus: 403) }
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        coordinator.iptvAccounts = accounts
        defer { coordinator.stop() }
        var request = ApplePlaybackRequest(url: try #require(URL(string: "https://fixture.example/live.ts")),
            isLive: true, mediaID: "channel", sourceKind: .liveTV)
        request.iptvSourceID = sourceID
        await coordinator.begin(request)
        #expect(engine.loadedRequests.count == 1)
        #expect(checks.withLock { $0 } == 0)
        guard case .failed(let failure) = coordinator.phase else { Issue.record("The failure was not reported"); return }
        #expect(failure.isConnectionLimit == false)
    }

    @MainActor @Test func cancelledSlotWaitCannotOpenOrFailTheNextChannel() async throws {
        let panel = try await PanelFixture()
        defer { withExtendedLifetime(panel) {} }
        let accounts = panel.accounts
        let sourceID = panel.sourceID
        await panel.answer(active: 1, { Self.info(active: 1) })
        let engine = FakePlaybackEngine()
        engine.script([.playing])
        let clock = ManualClock()
        Self.noteStop(sourceID: sourceID, now: clock.now)
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        coordinator.iptvAccounts = accounts
        coordinator.clock = clock
        defer { coordinator.stop() }
        var first = ApplePlaybackRequest(url: try #require(URL(string: "https://fixture.example/first.ts")),
            isLive: true, mediaID: "first", sourceKind: .liveTV)
        first.iptvSourceID = sourceID
        let waiting = Task { await coordinator.begin(first) }
        await clock.waitForSleep(until: .milliseconds(100))
        waiting.cancel()
        let second = ApplePlaybackRequest(url: try #require(URL(string: "https://fixture.example/second.ts")),
            isLive: true, mediaID: "second", sourceKind: .liveTV)
        await coordinator.begin(second)
        await waiting.value
        #expect(engine.loadedRequests.map(\.mediaID) == ["second"])
        #expect(coordinator.phase == .playing)
    }

    @MainActor @Test func anExplicitLimitRejectionRetriesEvenIfTheSlotHasAlreadyClosed() async throws {
        let panel = try await PanelFixture()
        defer { withExtendedLifetime(panel) {} }
        let accounts = panel.accounts
        let sourceID = panel.sourceID
        await panel.answer(active: 0, { Self.info(active: 0) })
        let engine = FakePlaybackEngine()
        engine.loadHandler = { _ in
            if engine.loadedRequests.count == 1 { throw AppleIPTVError.authenticationFailed(status: "MaxConnections") }
            engine.phase = .playing
        }
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        coordinator.iptvAccounts = accounts
        defer { coordinator.stop() }
        var request = ApplePlaybackRequest(url: try #require(URL(string: "https://fixture.example/live.ts")),
            isLive: true, mediaID: "channel", sourceKind: .liveTV)
        request.iptvSourceID = sourceID
        await coordinator.begin(request)
        #expect(engine.loadedRequests.count == 2)
        #expect(coordinator.phase == .playing)
    }

    @MainActor @Test(arguments: [false, true])
    func formatProbeWaitsForClosureAndHonorsNewSelection(superseded: Bool) async throws {
        let panel = try await PanelFixture()
        defer { withExtendedLifetime(panel) {} }
        let accounts = panel.accounts
        let sourceID = panel.sourceID
        let checks = Mutex(0)
        await panel.answer(active: 1, {
            let count = checks.withLock { $0 += 1; return $0 }
            return Self.info(active: count == 1 ? 1 : 0)
        })
        let clock = ManualClock()
        Self.noteStop(sourceID: sourceID, now: clock.now)
        let engine = FakePlaybackEngine()
        engine.script([.playing])
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        coordinator.iptvAccounts = accounts
        coordinator.clock = clock
        defer { coordinator.stop() }
        let probes = Mutex(0)
        let url = try #require(URL(string: "https://fixture.example/channel"))
        let probe = AppleIPTVStreamProbe { _ in
            probes.withLock { $0 += 1 }
            return (Data("#EXTM3U".utf8), try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
        let session = AppleLiveSession(coordinator: coordinator, streamProbe: probe)
        let channel = AppleIPTVChannel(id: "channel", sourceID: sourceID, name: "Fixture", streamURL: url)
        session.pendingProbe = .init(channel: channel, shareSelection: true, present: true)
        let pending = Task { await session.resolvePendingProbe() }
        await clock.waitForSleep(until: .milliseconds(100))
        #expect(probes.withLock { $0 } == 0)
        if superseded { session.pendingProbe = .init(channel: channel, shareSelection: true, present: true) }
        clock.advance(to: .milliseconds(100))
        let result = await pending.value
        if superseded {
            guard case .superseded = result else { Issue.record("The old selection still probed the channel"); return }
            #expect(probes.withLock { $0 } == 0)
        } else {
            guard case .ready(let ready) = result else { Issue.record("The available channel was not probed"); return }
            #expect(probes.withLock { $0 } == 1)
            await coordinator.begin(session.request(for: ready.channel, programme: nil))
            #expect(checks.withLock { $0 } == 2)
            #expect(engine.loadedRequests.count == 1)
            session.beginSelection(programme: nil, shareSelection: true)
            await coordinator.begin(session.request(for: ready.channel, programme: nil))
            #expect(checks.withLock { $0 } == 3)
            #expect(engine.loadedRequests.count == 2)
        }
    }

    @MainActor @Test func aPlayedChannelsOwnConnectionDoesNotTurnADropIntoALimitRejection() async throws {
        let panel = try await PanelFixture()
        defer { withExtendedLifetime(panel) {} }
        let accounts = panel.accounts
        let sourceID = panel.sourceID
        let engine = FakePlaybackEngine()
        engine.script([.playing])
        await panel.answer(active: 0, {
            let active = await MainActor.run { engine.phase == .idle ? 0 : 1 }
            return Self.info(active: active)
        })
        let clock = ManualClock()
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        coordinator.iptvAccounts = accounts
        coordinator.clock = clock
        defer { coordinator.stop() }
        var request = ApplePlaybackRequest(url: try #require(URL(string: "https://fixture.example/live.ts")),
            isLive: true, mediaID: "channel", sourceKind: .liveTV)
        request.iptvSourceID = sourceID
        await coordinator.begin(request)
        engine.emit(.failure(.init(kind: .network, message: "Fixture connection dropped")))
        await clock.waitForSleep(until: .seconds(1))
        #expect(coordinator.isReconnectingLive)
        #expect(engine.loadedRequests.count == 1)
        clock.advance(to: .seconds(1))
        await waitFor("normal live reconnect") { engine.loadedRequests.count == 2 && coordinator.phase == .playing }
        #expect(coordinator.phase == .playing)
    }
}

private final class IPTVAccountTestCredentials: AppleCredentialStoring {
    private var values: [String: String] = [:]
    private(set) var reads = 0
    func string(for reference: String) throws -> String? { reads += 1; return values[reference] }
    func set(_ value: String, for reference: String) throws { values[reference] = value }
    func remove(_ reference: String) throws { values[reference] = nil }
}

/// A one-slot Xtream source read the way playback reads it: the source
/// store's credentials and an `AppleIPTVClient` whose panel answers with
/// the test's `answer`.
@MainActor
private final class PanelFixture {
    typealias Answer = @Sendable () async throws -> AppleIPTVAccountInfo
    let accounts: AppleIPTVAccountLimits
    let sourceID: UUID
    let store: AppleSourceStore
    private let suite = "iptv-panel-\(UUID())"
    private final class AnswerBox: Sendable {
        let answer = Mutex<Answer>({ AppleIPTVConnectionLimitTests.info(active: 0) })
    }
    private let currentAnswer = AnswerBox()

    init() async throws {
        store = AppleSourceStore(defaults: try #require(UserDefaults(suiteName: suite)), keychain: IPTVAccountTestCredentials())
        sourceID = try store.addIPTV(name: "Fixture", type: .xtream, endpoint: "https://fixture.example",
            username: "fixture", password: "fixture").id
        let currentAnswer = currentAnswer
        accounts = AppleIPTVAccountLimits(client: AppleIPTVClient { request in
            let info = try await currentAnswer.answer.withLock { $0 }()
            let url = try #require(request.url)
            let body = #"{"user_info":{"auth":1,"status":"\#(info.status ?? "Active")","max_connections":"\#(info.maxConnections ?? 0)","active_cons":"\#(info.activeConnections ?? 0)"}}"#
            return (Data(body.utf8), try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        })
        await accounts.registerSourceStore(store, sourceIDs: [sourceID])
    }

    deinit { UserDefaults.standard.removePersistentDomain(forName: suite) }

    /// Records the account as one-slot with `active` streams; later checks get `answer`.
    func answer(active: Int, _ answer: @escaping Answer) async {
        currentAnswer.answer.withLock { $0 = answer }
        await accounts.record(AppleIPTVConnectionLimitTests.info(active: active), sourceID: sourceID)
    }
}
