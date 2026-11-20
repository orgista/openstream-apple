import Foundation
import Testing
import Synchronization
@testable import OpenStreamApple

@Suite("Durable guide mapping evidence", .serialized)
struct AppleIPTVGuideMappingEvidenceTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func resolve(_ names: [String: String], declared: String? = nil, manual: String? = nil,
                         previous: AppleIPTVGuideMappingEvidence? = nil, uniqueName: Bool = true,
                         shift: Double = 0, correction: Double = 0, fetchedAt: Date? = nil) -> AppleIPTVGuideMappingEvidence? {
        AppleIPTVGuideMappingEvidence.resolve(id: "local", declaredID: declared, manualID: manual,
            name: "News HD", uniqueName: uniqueName, index: .init(names: names), available: Set(names.keys),
            previous: previous, channelShiftHours: shift, correctionHours: correction, fetchedAt: fetchedAt ?? now)
    }

    @Test func providerGuideIDChangeRetainsLocalIdentity() throws {
        let source = UUID()
        func playlist(_ guideID: String) throws -> [AppleIPTVChannel] {
            try AppleIPTVClient.parseM3U(Data("""
            #EXTM3U
            #EXTINF:-1 tvg-id="\(guideID)",News
            https://fixture.example/live/news.m3u8
            """.utf8), sourceID: source, baseURL: URL(string: "https://fixture.example/playlist.m3u")!)
        }
        let original = try #require(playlist("old").first)
        let received = try playlist("new")
        let channel = try #require(AppleIPTVChannelCache.reconciled(received, previous: [original], sourceID: source).first)
        #expect(channel.id == original.id && channel.guideID == "new")
        let decoded = try JSONDecoder().decode(AppleIPTVChannel.self, from: JSONEncoder().encode(channel))
        #expect(decoded.id == original.id && decoded.guideID == "new")
        let duplicate = received[0].withLocalIdentity("different")
        #expect(AppleIPTVChannelCache.reconciled(received + [duplicate], previous: [original], sourceID: source).map(\.id) == (received + [duplicate]).map(\.id))
        #expect(AppleIPTVChannelCache.reconciled(received, previous: [original], sourceID: UUID()) == received)
    }

    @Test func duplicateNamesNeedIdentityAndManualAlwaysWins() throws {
        let names = ["1.news": "News", "10.news": "News FHD"]
        #expect(resolve(names) == nil)
        #expect(resolve(["1.news": "News"], uniqueName: false) == nil)
        let exact = try #require(resolve(names, declared: "10.news"))
        #expect(exact.providerID == "10.news" && exact.origin == .providerID && exact.confidence == 1)
        let manual = try #require(resolve(names, declared: "10.news", manual: "1.news"))
        #expect(manual.providerID == "1.news" && manual.origin == .manual)
        #expect(resolve(names, declared: "10.news", previous: manual)?.providerID == "10.news")
    }

    @Test func providerIDChangeKeepsManualAndPreviouslyResolvedIdentity() throws {
        let previous = try #require(resolve(["old": "News"], declared: "old"))
        let retained = try #require(resolve(["old": "News", "other": "News"], declared: "changed", previous: previous))
        #expect(retained.providerID == "old" && retained.declaredProviderID == "changed")
        #expect(resolve(["new": "News"], declared: "new", previous: previous)?.providerID == "new")
        let manual = try #require(resolve(["old": "News"], declared: "changed", manual: "old"))
        let vanished = try #require(resolve(["new": "News"], declared: "new", manual: "old", previous: manual))
        #expect(vanished.providerID == "old" && vanished.isStale)
        let byName = try #require(resolve(["new": "News"]))
        #expect(byName.origin == .name && byName.confidence == 0.95)
    }

    @Test func explicitDSTOffsetsAndFractionalCorrectionApplyOnceToRawData() throws {
        let raw = AppleIPTVGuideXMLTVParser().parse(data: Data("""
        <tv>
        <programme channel="one" start="20261101013000 -0400" stop="20261101013000 -0500"><title>Fallback</title></programme>
        </tv>
        """.utf8), defaultOffsetHours: 9)
        let programme = try #require(raw.first)
        #expect(programme.end.timeIntervalSince(programme.start) == 3600)
        let first = try #require(resolve(["one": "News"], declared: "one", shift: -4.5, correction: 1))
        let corrected = try #require(resolve(["one": "News"], declared: "one", previous: first, shift: -4.5, correction: 2))
        #expect(first.project(raw, channelID: "local").first?.start == programme.start.addingTimeInterval(-3.5 * 3600))
        #expect(corrected.project(raw, channelID: "local").first?.start == programme.start.addingTimeInterval(-2.5 * 3600))
        #expect(corrected.project(raw, channelID: "local").first?.end == programme.end.addingTimeInterval(-2.5 * 3600))
    }

    @Test func coveragePreservesGapsAndEvidenceReadsLegacySnapshot() throws {
        var evidence = try #require(resolve(["one": "News"], manual: "one"))
        func programme(_ start: Double, _ end: Double) -> AppleIPTVProgramme {
            AppleIPTVProgramme(id: String(start), channelID: "local", title: "Fixture", subtitle: nil,
                description: nil, start: now.addingTimeInterval(start), end: now.addingTimeInterval(end), category: nil, isLive: false)
        }
        evidence.coverage = AppleIPTVGuideMappingEvidence.coverage(of: [programme(0, 60), programme(30, 90), programme(120, 180)])
        #expect(evidence.coverage == [DateInterval(start: now, duration: 90), DateInterval(start: now.addingTimeInterval(120), duration: 60)])
        let snapshot = AppleIPTVGuideDiskCache.Snapshot(programmes: [], channelNames: [:], mappingEvidence: ["local": evidence])
        let restored = try JSONDecoder().decode(AppleIPTVGuideDiskCache.Snapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(restored.mappingEvidence?["local"] == evidence)
        let legacy = try JSONDecoder().decode(AppleIPTVGuideDiskCache.Snapshot.self, from: Data("{\"programmes\":[],\"channelNames\":{}}".utf8))
        #expect(legacy.mappingEvidence == nil)
    }
    @MainActor @Test func emptyXtreamRefreshThrottlesRequestsButRetriesAfterRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = AppleIPTVGuideDiskCache(directory: directory)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EmptyXtreamEvidenceProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let loader = AppleIPTVGuideLoader(session: session)
        let fetchedAt = now.addingTimeInterval(-901)
        let programme = AppleIPTVProgramme(id: "saved", channelID: "101", title: "Saved guide", subtitle: nil,
            description: nil, start: now, end: now.addingTimeInterval(3600), category: nil, isLive: false)
        let evidence = AppleIPTVGuideMappingEvidence(providerID: "202", declaredProviderID: "101", origin: .manual,
            confidence: 1, defaultOffsetHours: 0, channelShiftHours: 0, correctionHours: 0,
            fetchedAt: fetchedAt, coverage: AppleIPTVGuideMappingEvidence.coverage(of: [programme]), isStale: false)
        await disk.store([programme], key: "|evidence-v2|xtream|https://fixture.example|fixture|fixture",
            mappingEvidence: ["101": evidence], now: now)
        func makeStore() -> AppleIPTVGuideStore {
            let store = AppleIPTVGuideStore(loader: loader, diskCache: disk)
            store.channelProviderIDs = ["101": "101"]
            store.manualChannelMapping = ["101": "202"]
            store.configure(xtreamBase: URL(string: "https://fixture.example")!, username: "fixture", password: "fixture")
            return store
        }
        EmptyXtreamEvidenceProtocol.requests.withLock { $0 = [] }
        let store = makeStore()
        await store.refreshVisible(channelIDs: ["101"], now: now)
        await store.refreshVisible(channelIDs: ["101"], now: now.addingTimeInterval(1))
        #expect(EmptyXtreamEvidenceProtocol.requests.withLock { $0.count } == 1)
        #expect(store.guide(for: ["101"]).allProgrammes == [programme])
        #expect(store.mappingEvidence["101"]?.fetchedAt == fetchedAt)
        #expect(store.mappingEvidence["101"]?.isStale == true)
        #expect(store.manualChannelMapping == ["101": "202"])
        await store.refreshVisible(channelIDs: ["101"], now: now.addingTimeInterval(900))
        #expect(EmptyXtreamEvidenceProtocol.requests.withLock { $0.count } == 2)
        let restarted = makeStore()
        await restarted.refreshVisible(channelIDs: ["101"], now: now.addingTimeInterval(901))
        await restarted.refreshVisible(channelIDs: ["101"], now: now.addingTimeInterval(902))
        #expect(EmptyXtreamEvidenceProtocol.requests.withLock { $0.count } == 3)
        #expect(restarted.guide(for: ["101"]).allProgrammes == [programme])
        #expect(restarted.mappingEvidence["101"]?.fetchedAt == fetchedAt)
        let requests = EmptyXtreamEvidenceProtocol.requests.withLock { $0 }
        #expect(requests.allSatisfy { request in
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            return items.contains(URLQueryItem(name: "action", value: "get_short_epg"))
                && items.contains(URLQueryItem(name: "stream_id", value: "202"))
        })
    }

    @MainActor @Test(arguments: [false, true])
    func legacyEvidenceIsRemovedOnlyAfterSuccessfulV2Write(blockV2Write: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = URL(string: "https://fixture.example/evidence.xml")!
        func manifest(_ version: Int) -> URL {
            let key = "|evidence-v\(version)|xmltv|" + url.absoluteString
            return directory.appendingPathComponent(ApplePlaybackIdentity.digest(for: key) + ".json")
        }
        let evidence = try #require(resolve(["one": "News"], manual: "one", fetchedAt: now.addingTimeInterval(-901)))
        let programme = AppleIPTVProgramme(id: "legacy", channelID: "local", title: "Saved guide", subtitle: nil,
            description: nil, start: now, end: now.addingTimeInterval(3600), category: nil, isLive: false)
        let legacy = AppleIPTVGuideDiskCache.Snapshot(programmes: [programme], channelNames: [:], mappingEvidence: ["local": evidence])
        try JSONEncoder().encode(legacy).write(to: manifest(1), options: .atomic)
        if blockV2Write {
            try FileManager.default.createDirectory(at: manifest(2), withIntermediateDirectories: false)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MappingEvidenceProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        MappingEvidenceProtocol.state.withLock { $0 = 2 } // The saved manual station has vanished.
        let disk = AppleIPTVGuideDiskCache(directory: directory)
        let store = AppleIPTVGuideStore(loader: AppleIPTVGuideLoader(session: session), diskCache: disk)
        store.manualChannelMapping = ["local": "one"]
        store.configure(xmltvURL: url, channelMapping: ["local": "one"])
        await store.refreshVisible(channelIDs: ["local"], now: now)
        #expect(store.guide(for: ["local"]).allProgrammes == [programme])
        #expect(store.manualChannelMapping == ["local": "one"])
        #expect(FileManager.default.fileExists(atPath: manifest(1).path) == blockV2Write)
        if blockV2Write == false {
            let restored = await disk.snapshot(key: "|evidence-v2|xmltv|" + url.absoluteString, now: now)
            #expect(restored.programmes == [programme])
            #expect(restored.mappingEvidence?["local"]?.providerID == "one")
        }
    }

    @Test func emptyRefreshRetainsFetchTimeAndCannotEraseManualGuide() throws {
        var previous = try #require(resolve(["one": "News"], manual: "one"))
        let raw = AppleIPTVProgramme(id: "fixture", channelID: "one", title: "Fixture", subtitle: nil,
            description: nil, start: now, end: now.addingTimeInterval(3600), category: nil, isLive: false)
        let saved = previous.project([raw], channelID: "local")
        previous.coverage = AppleIPTVGuideMappingEvidence.coverage(of: saved)
        let incoming = try #require(resolve(["other": "News"], manual: "one", previous: previous, fetchedAt: now.addingTimeInterval(60)))
        let empty = AppleIPTVGuideMappingEvidence.replacement(providerProgrammes: [], channelID: "local",
            evidence: incoming, previousProgrammes: saved, previousEvidence: previous)
        #expect(empty.programmes == saved && empty.evidence.isStale)
        #expect(empty.evidence.coverage == previous.coverage && empty.evidence.fetchedAt == previous.fetchedAt)
        let changed = try #require(resolve(["other": "News"], manual: "other"))
        let reassigned = AppleIPTVGuideMappingEvidence.replacement(providerProgrammes: [], channelID: "local",
            evidence: changed, previousProgrammes: saved, previousEvidence: previous)
        #expect(reassigned.programmes.isEmpty && reassigned.evidence.providerID == "other")
    }

    @MainActor @Test func failureAndMissingManualTargetRetainGuideAndEvidenceAcrossRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = AppleIPTVGuideDiskCache(directory: directory)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MappingEvidenceProtocol.self]
        let loader = AppleIPTVGuideLoader(session: URLSession(configuration: configuration))
        let store = AppleIPTVGuideStore(loader: loader, diskCache: disk)
        let url = URL(string: "https://fixture.example/evidence.xml")!
        let start = try #require(AppleIPTVGuideXMLTVParser.parseDate("20261101013000 -0400", defaultOffsetHours: 0))
        MappingEvidenceProtocol.state.withLock { $0 = 0 }
        store.manualChannelMapping = ["local": "one"]
        store.configure(xmltvURL: url, channelMapping: ["local": "one"], channelShifts: ["local": -0.5], timeShiftHours: 1)
        await store.refreshVisible(channelIDs: ["local"], now: start)
        let original = try #require(store.guide(for: ["local"]).allProgrammes.first)
        let evidence = try #require(store.mappingEvidence["local"])
        #expect(original.start == start.addingTimeInterval(1800))
        MappingEvidenceProtocol.state.withLock { $0 = 1 }
        store.configure(xmltvURL: url, channelMapping: ["local": "changed"], defaultOffsetHours: 2, channelShifts: ["local": -0.5], timeShiftHours: 1)
        await store.refreshVisible(channelIDs: ["local"], force: true, now: start.addingTimeInterval(60))
        #expect(store.guide(for: ["local"]).allProgrammes == [original])
        #expect(store.mappingEvidence["local"] == evidence)
        let restarted = AppleIPTVGuideStore(loader: loader, diskCache: disk)
        restarted.manualChannelMapping = ["local": "one"]
        restarted.configure(xmltvURL: url, channelMapping: ["local": "changed"], defaultOffsetHours: 2)
        await restarted.refreshVisible(channelIDs: ["local"], force: true, now: start.addingTimeInterval(120))
        #expect(restarted.guide(for: ["local"]).allProgrammes == [original])
        #expect(restarted.mappingEvidence["local"]?.fetchedAt == evidence.fetchedAt)
        MappingEvidenceProtocol.state.withLock { $0 = 2 }
        await restarted.refreshVisible(channelIDs: ["local"], force: true, now: start.addingTimeInterval(180))
        #expect(restarted.guide(for: ["local"]).allProgrammes.first?.start == start)
        #expect(restarted.mappingEvidence["local"]?.isStale == true)
        #expect(restarted.mappingEvidence["local"]?.providerID == "one")
        #expect(restarted.mappingEvidence["local"]?.fetchedAt == evidence.fetchedAt)
        let revision = restarted.revision
        await restarted.refreshVisible(channelIDs: ["local"], now: start.addingTimeInterval(240))
        #expect(restarted.revision == revision)
    }

    @MainActor @Test func legacyManualGuideCacheMigratesOfflineWithProviderIdentitySeparate() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = AppleIPTVGuideDiskCache(directory: directory)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MappingEvidenceProtocol.self]
        MappingEvidenceProtocol.state.withLock { $0 = 1 }
        let start = try #require(AppleIPTVGuideXMLTVParser.parseDate("20261101013000 -0400", defaultOffsetHours: 0))
        let raw = AppleIPTVProgramme(id: "legacy", channelID: "one", title: "Saved guide", subtitle: nil,
            description: nil, start: start, end: start.addingTimeInterval(3600), category: nil, isLive: false)
        // The old Live view folded the manual assignment into channelMapping as well as the manual dictionary.
        let legacyKey = "|https://fixture.example/evidence.xml|0.0|0.0|local=one|local=one|"
        await disk.store([raw], key: legacyKey, channelNames: ["one": "News"], fetchedAt: start, isRawXMLTV: true)
        let store = AppleIPTVGuideStore(loader: AppleIPTVGuideLoader(session: URLSession(configuration: configuration)), diskCache: disk)
        store.channelDisplayNames = ["local": "News"]
        store.manualChannelMapping = ["local": "one"]
        store.configure(xmltvURL: URL(string: "https://fixture.example/evidence.xml")!, channelMapping: ["local": "declared"])
        await store.refreshVisible(channelIDs: ["local"], now: start)
        #expect(store.guide(for: ["local"]).allProgrammes.first?.title == "Saved guide")
        #expect(store.mappingEvidence["local"]?.origin == .manual)
        #expect(store.mappingEvidence["local"]?.declaredProviderID == "declared")
        #expect(store.mappingEvidence["local"]?.fetchedAt == start)
    }

    @MainActor @Test func correctionChangeProjectsFreshRawCacheOnceWithoutAnotherRequest() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MappingEvidenceProtocol.self]
        MappingEvidenceProtocol.state.withLock { $0 = 0 }
        let store = AppleIPTVGuideStore(loader: AppleIPTVGuideLoader(session: URLSession(configuration: configuration)),
            diskCache: AppleIPTVGuideDiskCache(directory: directory))
        let url = URL(string: "https://fixture.example/evidence.xml")!
        let start = try #require(AppleIPTVGuideXMLTVParser.parseDate("20261101013000 -0400", defaultOffsetHours: 0))
        store.configure(xmltvURL: url, channelMapping: ["local": "one"], timeShiftHours: 1)
        await store.refreshVisible(channelIDs: ["local"], now: start)
        MappingEvidenceProtocol.state.withLock { $0 = 1 } // Any further request would fail.
        store.configure(xmltvURL: url, channelMapping: ["local": "one"], timeShiftHours: 2)
        await store.refreshVisible(channelIDs: ["local"], now: start.addingTimeInterval(60))
        #expect(store.guide(for: ["local"]).allProgrammes.first?.start == start.addingTimeInterval(7200))
        #expect(store.mappingEvidence["local"]?.correctionHours == 2)
        await store.refreshVisible(channelIDs: ["local"], now: start.addingTimeInterval(120))
        #expect(store.guide(for: ["local"]).allProgrammes.first?.start == start.addingTimeInterval(7200))
    }


    @MainActor @Test func reconciledLineupWritesKeepPersistedSettingsKeys() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "plex12-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        let cache = AppleIPTVChannelCache(directory: directory)
        let source = UUID()
        func playlist(_ guideID: String) throws -> [AppleIPTVChannel] {
            try AppleIPTVClient.parseM3U(Data("#EXTM3U\n#EXTINF:-1 tvg-id=\"\(guideID)\",News\nhttps://fixture.example/live/news.m3u8".utf8),
                sourceID: source, baseURL: URL(string: "https://fixture.example/list.m3u")!)
        }
        let first = try #require(playlist("old").first)
        await cache.store([first], for: source)
        let settings = AppleSettingsStore(defaults: defaults)
        settings.guideChannelAssignments = [first.id: "station"]
        settings.hiddenLiveChannelIDs = [first.id]
        settings.favoriteLiveChannelOrder = [first.id]
        settings.favoriteChannelIDs = [first.id]
        let manager = await cache.reconcileAndStore(try playlist("new"), for: source)
        let managed = try #require(manager.first)
        settings.favoriteChannelIDs.remove(managed.id)
        let live = await cache.reconcileAndStore(try playlist("newer"), for: source)
        let liveID = try #require(live.first?.id)
        #expect(liveID == first.id)
        let restored = AppleSettingsStore(defaults: defaults)
        #expect(!restored.favoriteChannelIDs.contains(liveID))
        #expect(restored.hiddenLiveChannelIDs.contains(liveID))
        #expect(restored.guideChannelAssignments[liveID] == "station")
        #expect(restored.favoriteLiveChannelOrder == [liveID])
        #expect(await cache.snapshot(for: source)?.channels == live)
    }

    @Test func guideChannelIDsIncludeStationsWithoutDisplayNames() {
        let programme = AppleIPTVProgramme(id: "one", channelID: "unlabelled", title: "Fixture", subtitle: nil,
            description: nil, start: now, end: now.addingTimeInterval(60), category: nil, isLive: false)
        let guide = AppleIPTVGuide(programmes: Array(repeating: programme, count: 10_000), channelNames: ["named": "News"])
        #expect(guide.channelIDs == ["unlabelled"])
        #expect(Set(guide.channelNames.keys).union(guide.channelIDs) == ["named", "unlabelled"])
    }

    @MainActor @Test func defaultOffsetChangeReparsesZonelessDatesAndPreservesExplicitDST() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MappingEvidenceProtocol.self]
        let store = AppleIPTVGuideStore(loader: AppleIPTVGuideLoader(session: URLSession(configuration: configuration)),
            diskCache: AppleIPTVGuideDiskCache(directory: directory))
        let url = URL(string: "https://fixture.example/evidence.xml")!
        MappingEvidenceProtocol.state.withLock { $0 = 4 }
        let start = try #require(AppleIPTVGuideXMLTVParser.parseDate("20261101013000", defaultOffsetHours: 0))
        store.configure(xmltvURL: url, channelMapping: ["local": "one"])
        await store.refreshVisible(channelIDs: ["local"], now: start)
        let old = store.guide(for: ["local"]).allProgrammes
        #expect(old.count == 2)
        store.configure(xmltvURL: url, channelMapping: ["local": "one"], defaultOffsetHours: 2)
        MappingEvidenceProtocol.state.withLock { $0 = 1 }
        await store.refreshVisible(channelIDs: ["local"], now: start.addingTimeInterval(30))
        #expect(store.guide(for: ["local"]).allProgrammes == old)
        MappingEvidenceProtocol.state.withLock { $0 = 4 }
        await store.refreshVisible(channelIDs: ["local"], now: start.addingTimeInterval(60))
        let programmes = store.guide(for: ["local"]).allProgrammes
        #expect(programmes.first { $0.title == "Zoneless" }?.start == start.addingTimeInterval(-7200))
        #expect(programmes.first { $0.title == "Explicit" }?.start == old.first { $0.title == "Explicit" }?.start)
        let revision = store.revision
        await store.refreshVisible(channelIDs: ["local"], now: start.addingTimeInterval(90))
        #expect(store.revision == revision)
    }

    @Test func reusedTransportDoesNotTransferIdentityBetweenNamedStations() throws {
        let source = UUID()
        func channel(_ name: String, _ guideID: String) throws -> AppleIPTVChannel {
            try #require(AppleIPTVClient.parseM3U(Data("#EXTM3U\n#EXTINF:-1 tvg-id=\"\(guideID)\",\(name)\nhttps://fixture.example/live/slot.m3u8".utf8),
                sourceID: source, baseURL: URL(string: "https://fixture.example/list.m3u")!).first)
        }
        let old = try channel("CNN", "cnn.us")
        let new = try channel("ESPN", "espn.us")
        #expect(AppleIPTVChannelCache.reconciled([new], previous: [old], sourceID: source) == [new])
        let renamed = try channel("US CNN HD", "new.cnn")
        #expect(AppleIPTVChannelCache.reconciled([renamed], previous: [old], sourceID: source).first?.id == old.id)
    }

    @Test func evidenceProgrammesUseBoundedDayShardsAndRoundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = AppleIPTVGuideDiskCache(directory: directory)
        var evidence = try #require(resolve(["one": "News"], declared: "one"))
        func programme(_ day: Double) -> AppleIPTVProgramme {
            AppleIPTVProgramme(id: String(day), channelID: "local", title: "Fixture", subtitle: nil, description: nil,
                start: now.addingTimeInterval(day * 86400), end: now.addingTimeInterval(day * 86400 + 3600), category: nil, isLive: false)
        }
        evidence.coverage = AppleIPTVGuideMappingEvidence.coverage(of: [programme(0), programme(1)])
        await disk.store([programme(-4), programme(0), programme(1), programme(8)], key: "evidence",
            mappingEvidence: ["local": evidence], now: now)
        let manifest = try Data(contentsOf: directory.appendingPathComponent(ApplePlaybackIdentity.digest(for: "evidence") + ".json"))
        let decoded = try JSONDecoder().decode(AppleIPTVGuideDiskCache.Snapshot.self, from: manifest)
        #expect(decoded.programmes.isEmpty)
        #expect(decoded.shardDays?.count == 2)
        let restored = await disk.snapshot(key: "evidence", now: now)
        #expect(restored.programmes.count == 2)
        #expect(restored.mappingEvidence?["local"]?.coverage == evidence.coverage)
    }

    @MainActor @Test func removingGuideClearsOnlyItsListingsAndEvidence() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MappingEvidenceProtocol.self]
        MappingEvidenceProtocol.state.withLock { $0 = 0 }
        let store = AppleIPTVGuideStore(loader: AppleIPTVGuideLoader(session: URLSession(configuration: configuration)),
            diskCache: AppleIPTVGuideDiskCache(directory: directory))
        let source = UUID(), other = UUID()
        let id = source.uuidString + ":local", otherID = other.uuidString + ":local"
        let url = URL(string: "https://fixture.example/evidence.xml")!
        store.configure(xmltvURL: url, sourceID: source, channelMapping: [id: "one"])
        store.configure(xmltvURL: url, sourceID: other, channelMapping: [otherID: "one"])
        await store.refreshVisible(channelIDs: [id, otherID], now: now)
        #expect(!store.guide(for: [id]).allProgrammes.isEmpty)
        store.configure(xmltvURL: nil, sourceID: source)
        #expect(store.guide(for: [id]).allProgrammes.isEmpty)
        #expect(store.mappingEvidence[id] == nil)
        #expect(!store.guide(for: [otherID]).allProgrammes.isEmpty)
        #expect(store.mappingEvidence[otherID] != nil)
    }

    @MainActor @Test func lineupVariantsShareOneGuideButRefuseConflictingTargets() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MappingEvidenceProtocol.self]
        MappingEvidenceProtocol.state.withLock { $0 = 0 }
        let store = AppleIPTVGuideStore(loader: AppleIPTVGuideLoader(session: URLSession(configuration: configuration)),
            diskCache: AppleIPTVGuideDiskCache(directory: directory))
        let url = URL(string: "https://fixture.example/evidence.xml")!
        store.channelDisplayNames = ["sd": "News", "hd": "News HD", "fhd": "News FHD"]
        store.configure(xmltvURL: url)
        await store.refreshVisible(channelIDs: ["sd", "hd", "fhd"], now: now)
        #expect(store.mappingEvidence.values.map(\.providerID) == ["one", "one", "one"])
        MappingEvidenceProtocol.state.withLock { $0 = 3 }
        store.configure(xmltvURL: url, channelMapping: ["sd": "one", "hd": "two"])
        await store.refreshVisible(channelIDs: ["sd", "hd", "fhd"], force: true, now: now)
        #expect(store.mappingEvidence["sd"]?.providerID == "one")
        #expect(store.mappingEvidence["hd"]?.providerID == "two")
        #expect(store.mappingEvidence["fhd"]?.isStale == true)
    }

}


private final class MappingEvidenceProtocol: URLProtocol {
    static let state = Mutex(0)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let state = Self.state.withLock { $0 }
        if state == 1 {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let body = state == 4 ? "<tv><channel id=\"one\"><display-name>News</display-name></channel><programme channel=\"one\" start=\"20261101013000\" stop=\"20261101023000\"><title>Zoneless</title></programme><programme channel=\"one\" start=\"20261101013000 -0400\" stop=\"20261101013000 -0500\"><title>Explicit</title></programme></tv>" : state == 3 ? "<tv><channel id=\"one\"><display-name>News</display-name></channel><channel id=\"two\"><display-name>Sports</display-name></channel></tv>" : state == 2 ? "<tv><channel id=\"new\"><display-name>News</display-name></channel></tv>" : """
        <tv><channel id="one"><display-name>News</display-name></channel>
        <programme channel="one" start="20261101013000 -0400" stop="20261101013000 -0500"><title>Fixture</title></programme></tv>
        """
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class EmptyXtreamEvidenceProtocol: URLProtocol {
    static let requests = Mutex<[URLRequest]>([])
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.withLock { $0.append(request) }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
            httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"epg_listings\":[]}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
