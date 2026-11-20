import Foundation
import Testing
@testable import OpenStreamApple

/// The Last Airbender (2010).iso on the owner's iPhone (trace iphone-1017b,
/// 2026-10-17): 295 range requests to read the disc structure, 17 s over the
/// SMB bridge, and the 20 s start deadline failed it 2.6 s after the engine
/// recognized the disc.
@Suite struct AppleDiscStartPolicyTests {
    typealias Policy = ApplePlaybackStartPolicy
    typealias Progress = Policy.DiscStartProgress

    @Test func aDiscStillBeingReadGetsAnotherWindow() {
        #expect(Policy.discStartExtension(elapsed: .seconds(20),
            previous: Progress(), current: Progress(bytesRead: 40_000_000)) == .seconds(10))
    }

    @Test func aCheckpointCountsAsProgress() {
        #expect(Policy.discStartExtension(elapsed: .seconds(30),
            previous: Progress(checkpoint: 0, bytesRead: 9), current: Progress(checkpoint: 2, bytesRead: 9)) == .seconds(10))
    }

    @Test func aDiscThatStoppedMovingFails() {
        let stuck = Progress(checkpoint: 1, bytesRead: 40_000_000)
        #expect(Policy.discStartExtension(elapsed: .seconds(30), previous: stuck, current: stuck) == nil)
    }

    @Test func theLastWindowEndsAtTheCap() {
        #expect(Policy.discStartExtension(elapsed: .seconds(55),
            previous: Progress(), current: Progress(bytesRead: 1)) == .seconds(5))
        #expect(Policy.discStartExtension(elapsed: .seconds(60),
            previous: Progress(), current: Progress(bytesRead: 1)) == nil)
    }
}

@Suite struct AppleSMBBlockCacheTests {
    typealias Cache = AppleSMBBlockCache
    let mebibyte: UInt64 = 1 << 20

    @Test func onlyStructureReadsOfDiscImagesAreCached() {
        #expect(Cache.caches(path: "/Media/The Last Airbender (2010).iso", request: 0 ..< 262_144))
        #expect(Cache.caches(path: "/Media/disc.ISO", request: 36 * mebibyte ..< 36 * mebibyte + 262_144))
        #expect(Cache.caches(path: "/Media/disc.iso", request: 64 * mebibyte - 1 ..< 64 * mebibyte + 262_143))
        // The title stream's ramp after a seek: 512 KB, 1 MiB, then larger.
        #expect(!Cache.caches(path: "/Media/disc.iso", request: 0 ..< 524_288))
        #expect(!Cache.caches(path: "/Media/disc.iso", request: 0 ..< mebibyte))
        #expect(!Cache.caches(path: "/Media/disc.iso", request: 0 ..< 8 * mebibyte))
        // The first read after a seek into the streams.
        #expect(!Cache.caches(path: "/Media/disc.iso", request: 64 * mebibyte ..< 64 * mebibyte + 262_144))
        #expect(!Cache.caches(path: "/Media/disc.iso", request: 20_000 * mebibyte ..< 20_000 * mebibyte + 262_144))
        #expect(!Cache.caches(path: "/Media/movie.mkv", request: 0 ..< 262_144))
        #expect(!Cache.caches(path: "/Media/BDMV/STREAM/00125.m2ts", request: 0 ..< 262_144))
    }

    @Test func aReadAcrossABoundaryTouchesBothBlocks() {
        #expect(Cache.blockIndices(for: 0 ..< 262_144) == 0 ... 0)
        #expect(Cache.blockIndices(for: (mebibyte - 1) ..< (mebibyte + 1)) == 0 ... 1)
        #expect(Cache.blockIndices(for: mebibyte ..< 2 * mebibyte) == 1 ... 1)
    }

    @Test func theLastBlockStopsAtTheEndOfTheFile() {
        #expect(Cache.byteRange(ofBlock: 2, fileSize: 2 * mebibyte + 10) == 2 * mebibyte ..< 2 * mebibyte + 10)
    }

    @Test func aSliceIsThePartOfTheBlockInsideTheRange() {
        let block = Data((0 ..< Int(mebibyte)).map { UInt8($0 % 251) })
        let range = (mebibyte + 100) ..< (mebibyte + 200)
        #expect(Cache.slice(block, index: 1, of: range) == block.subdata(in: 100 ..< 200))
        #expect(Cache.slice(block.prefix(50), index: 1, of: range).isEmpty)
    }

    @Test func theLeastRecentBlockLeavesFirst() {
        var cache = Cache()
        for index in 0 ..< UInt64(Cache.capacity) {
            cache.store(Data([UInt8(index)]), for: .init(file: "a", index: index))
        }
        #expect(cache.block(for: .init(file: "a", index: 0)) != nil)
        cache.store(Data([99]), for: .init(file: "a", index: 99))
        #expect(cache.count == Cache.capacity)
        #expect(cache.block(for: .init(file: "a", index: 0)) != nil)
        #expect(cache.block(for: .init(file: "a", index: 1)) == nil)
    }
}

private actor CountingSMBClient: AppleNetworkShareClient {
    let payload: Data
    private(set) var reads: [Range<UInt64>] = []

    init(payload: Data) { self.payload = payload }

    func listShares(host: String, port: Int, credentials: AppleSMBCredentials) async throws -> [AppleSMBShare] { [] }
    func listDirectory(url: URL, credentials: AppleSMBCredentials, recursive: Bool) async throws -> [AppleSMBDirectoryEntry] { [] }
    func read(url: URL, credentials: AppleSMBCredentials, range: Range<UInt64>) async throws -> Data {
        reads.append(range)
        let lower = min(payload.count, Int(range.lowerBound))
        let upper = min(payload.count, Int(range.upperBound))
        return payload.subdata(in: lower ..< upper)
    }
    func closeAll() async {}
}

@Suite(.serialized) struct AppleSMBBridgeDiscReadTests {
    /// 40 MiB and a bit, every byte a function of its offset.
    static let image: Data = {
        var data = Data(count: 40 * 1_024 * 1_024 + 4_096)
        data.withUnsafeMutableBytes { bytes in
            for index in bytes.indices { bytes[index] = UInt8(truncatingIfNeeded: index &* 31 &+ index >> 20) }
        }
        return data
    }()
    let payload = AppleSMBBridgeDiscReadTests.image
    /// The engine's walk of a Blu-ray: 256 KB reads that alternate between
    /// the file entries near the start and the playlist data further in.
    let walk: [UInt64] = (0 ..< 24).map { step in
        step.isMultiple(of: 2) ? 1_210 * 1_024 + UInt64(step) * 2_048 : 36_654 * 1_024 + UInt64(step) * 2_048
    }
    let credentials = AppleSMBCredentials(username: "fixture", password: "fixture")

    private func get(_ url: URL, _ range: Range<UInt64>) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 206)
        return data
    }

    @Test func aDiscWalkIsServedFromAFewBlocksAndAReplayFromMemory() async throws {
        let client = CountingSMBClient(payload: payload)
        let server = AppleSMBRangeServer(client: client, addedLatency: .zero, usesBlockCache: true)
        let source = URL(string: "smb://fixture.invalid/Media/disc.iso")!
        let first = try await server.playbackURL(sourceURL: source, credentials: credentials, sizeBytes: Int64(payload.count))
        for offset in walk {
            let range = offset ..< offset + 262_144
            #expect(try await get(first, range) == payload.subdata(in: Int(range.lowerBound) ..< Int(range.upperBound)))
        }
        // The entries stay inside block 1; the playlist reads span blocks 35 and 36.
        #expect(await client.reads.count == 3)
        #expect(await server.bytesServed(playbackURL: first) == UInt64(walk.count) * 262_144)
        let stats = try #require(await server.readStats(playbackURL: first))
        #expect(stats.requests == walk.count)
        #expect(stats.smbOpens == 3)
        await server.revoke(playbackURL: first)

        let replay = try await server.playbackURL(sourceURL: source, credentials: credentials, sizeBytes: Int64(payload.count))
        _ = try await get(replay, walk[0] ..< walk[0] + 262_144)
        #expect(await client.reads.count == 3)
        await server.removeAllSessions()
    }

    /// REA round 4, fix 1: a disc opened again after a relaunch reads its
    /// structure from disk; the cold open stays within 10 SMB reads.
    @Test func aDiscOpenedAfterARelaunchReadsItsStructureFromDisk() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("disc-structure-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppleDiscStructureStore(directory: directory)
        let source = URL(string: "smb://fixture.invalid/Media/disc.iso")!
        let modified = Date(timeIntervalSince1970: 1_700_000_000)

        let cold = CountingSMBClient(payload: payload)
        let first = AppleSMBRangeServer(client: cold, addedLatency: .zero, usesBlockCache: true, structureStore: store)
        let firstURL = try await first.playbackURL(sourceURL: source, credentials: credentials,
            sizeBytes: Int64(payload.count), modifiedAt: modified)
        for offset in walk { _ = try await get(firstURL, offset ..< offset + 262_144) }
        #expect(await cold.reads.count <= 10)
        await first.removeAllSessions()

        let warm = CountingSMBClient(payload: payload)
        let relaunched = AppleSMBRangeServer(client: warm, addedLatency: .zero, usesBlockCache: true, structureStore: store)
        let url = try await relaunched.playbackURL(sourceURL: source, credentials: credentials,
            sizeBytes: Int64(payload.count), modifiedAt: modified)
        for offset in walk {
            let range = offset ..< offset + 262_144
            #expect(try await get(url, range) == payload.subdata(in: Int(range.lowerBound) ..< Int(range.upperBound)))
        }
        #expect(await warm.reads.isEmpty)
        #expect(await relaunched.readStats(playbackURL: url)?.diskBlocks == 3)
        await relaunched.removeAllSessions()
    }

    @Test func aDiscWithoutAModificationDateIsNotKept() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("disc-structure-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = AppleSMBRangeServer(client: CountingSMBClient(payload: payload), addedLatency: .zero,
            usesBlockCache: true, structureStore: AppleDiscStructureStore(directory: directory))
        let url = try await server.playbackURL(sourceURL: URL(string: "smb://fixture.invalid/Media/disc.iso")!,
            credentials: credentials, sizeBytes: Int64(payload.count))
        _ = try await get(url, walk[0] ..< walk[0] + 262_144)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        await server.removeAllSessions()
    }

    @Test func theStoreKeepsOnlyTheMostRecentDiscs() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("disc-structure-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppleDiscStructureStore(directory: directory)
        let block = Data(repeating: 7, count: Int(AppleSMBBlockCache.blockSize))
        for disc in 0 ... AppleDiscStructureStore.discLimit {
            await store.store(block, index: 0, file: "disc-\(disc)")
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(disc) * 60)],
                ofItemAtPath: directory.appendingPathComponent(ApplePlaybackIdentity.digest(for: "disc-\(disc)")).path)
        }
        await store.store(block, index: 0, file: "newest")
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == AppleDiscStructureStore.discLimit)
        #expect(await store.blocks(file: "disc-0", fileSize: 40 * 1_048_576).isEmpty)
        #expect(await store.blocks(file: "newest", fileSize: 40 * 1_048_576)[0] == block)
    }

    @Test func theEndOfTheImageIsServedFromAShortBlock() async throws {
        let client = CountingSMBClient(payload: payload)
        let server = AppleSMBRangeServer(client: client, addedLatency: .zero, usesBlockCache: true)
        let url = try await server.playbackURL(sourceURL: URL(string: "smb://fixture.invalid/Media/disc.iso")!,
            credentials: credentials, sizeBytes: Int64(payload.count))
        let tail = UInt64(payload.count - 1_000) ..< UInt64(payload.count)
        #expect(try await get(url, tail) == payload.suffix(1_000))
        await server.removeAllSessions()
    }

    @Test func aFileReplacedAtTheSameSizeIsReadAgain() async throws {
        let client = CountingSMBClient(payload: payload)
        let server = AppleSMBRangeServer(client: client, addedLatency: .zero, usesBlockCache: true)
        let source = URL(string: "smb://fixture.invalid/Media/disc.iso")!
        let range = walk[0] ..< walk[0] + 262_144
        let first = try await server.playbackURL(sourceURL: source, credentials: credentials,
            sizeBytes: Int64(payload.count), modifiedAt: Date(timeIntervalSince1970: 1_700_000_000))
        _ = try await get(first, range)
        await server.revoke(playbackURL: first)
        let replaced = try await server.playbackURL(sourceURL: source, credentials: credentials,
            sizeBytes: Int64(payload.count), modifiedAt: Date(timeIntervalSince1970: 1_760_000_000))
        _ = try await get(replaced, range)
        #expect(await client.reads.count == 2)
        await server.removeAllSessions()
    }

    @Test func aTitleStreamReadGoesStraightToSMB() async throws {
        let client = CountingSMBClient(payload: payload)
        let server = AppleSMBRangeServer(client: client, addedLatency: .zero, usesBlockCache: true)
        let url = try await server.playbackURL(sourceURL: URL(string: "smb://fixture.invalid/Media/disc.iso")!,
            credentials: credentials, sizeBytes: Int64(payload.count))
        // The engine's disc reader doubles its bounded ranges up to 8 MiB past the
        // 256 KiB the structure cache takes; each is one SMB open.
        var start: UInt64 = 20 * 1_048_576 + 4_096
        var ramp: [Range<UInt64>] = []
        for size in [524_288, 1_048_576, 8 * 1_048_576] as [UInt64] {
            let range = start ..< start + size
            #expect(try await get(url, range) == payload.subdata(in: Int(range.lowerBound) ..< Int(range.upperBound)))
            ramp.append(range)
            start = range.upperBound
        }
        #expect(await client.reads == ramp)
        #expect(await server.readStats(playbackURL: url)?.smbOpens == ramp.count)
        await server.removeAllSessions()
    }

    @Test func withoutTheCacheEveryRequestIsAnSMBRead() async throws {
        let client = CountingSMBClient(payload: payload)
        let server = AppleSMBRangeServer(client: client, addedLatency: .zero, usesBlockCache: false)
        let url = try await server.playbackURL(sourceURL: URL(string: "smb://fixture.invalid/Media/disc.iso")!,
            credentials: credentials, sizeBytes: Int64(payload.count))
        for offset in walk.prefix(6) { _ = try await get(url, offset ..< offset + 262_144) }
        #expect(await client.reads.count == 6)
        await server.removeAllSessions()
    }

    @Test func aVideoFileIsReadAsAsked() async throws {
        let client = CountingSMBClient(payload: payload)
        let server = AppleSMBRangeServer(client: client, addedLatency: .zero, usesBlockCache: true)
        let url = try await server.playbackURL(sourceURL: URL(string: "smb://fixture.invalid/Media/movie.mkv")!,
            credentials: credentials, sizeBytes: Int64(payload.count))
        _ = try await get(url, 4_096 ..< 8_192)
        #expect(await client.reads == [4_096 ..< 8_192])
        await server.removeAllSessions()
    }
}

/// The start deadline runs on a `ManualClock`: the disc's progress is set
/// before each deadline is advanced past, so nothing races a real ticker.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1))) struct AppleDiscStartDeadlineTests {
    private func discRequest() -> ApplePlaybackRequest {
        var hints = ApplePlaybackRequest.Hints()
        hints.disc = AppleDiscPlaybackChoice(start: .mainTitle, format: .bluRay)
        return ApplePlaybackRequest(url: URL(string: "http://127.0.0.1:8765/media/token/disc.iso")!,
            mediaID: "disc", sourceKind: .networkShare, hints: hints)
    }

    private func makeCoordinator(_ engine: FakePlaybackEngine, clock: ManualClock) -> ApplePlaybackCoordinator {
        let coordinator = ApplePlaybackCoordinator(engine: engine, timeout: .milliseconds(200))
        coordinator.discCrashGuard = AppleDiscCrashGuard(defaults: freshDefaults(), build: "test")
        coordinator.clock = clock
        return coordinator
    }

    /// No wall-clock deadline: the failure lands through main-actor tasks the
    /// parallel gate can hold up; the time limit fails one that never comes.
    private func failure(of coordinator: ApplePlaybackCoordinator) async -> ApplePlaybackFailure? {
        while !Task.isCancelled {
            if case .failed(let failure) = coordinator.phase { return failure }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    @Test func aDiscThatKeepsMovingOutlivesTheDeadline() async {
        let engine = FakePlaybackEngine()
        engine.loadHandler = { _ in try await Task.sleep(for: .seconds(30)) }
        let clock = ManualClock()
        let coordinator = makeCoordinator(engine, clock: clock)
        coordinator.discStartWindow = .milliseconds(300)
        coordinator.discStartCap = .seconds(5)
        let begin = Task { await coordinator.begin(discRequest()) }
        // Still reading at the 200 ms deadline: one more window.
        await clock.waitForSleep(until: .milliseconds(200))
        engine.startupCheckpoint = 1
        clock.advance(to: .milliseconds(200))
        await clock.waitForSleep(until: .milliseconds(500))
        #expect(coordinator.phase == .loading)
        // Nothing moves in that window, so its deadline fails the start.
        clock.advance(to: .milliseconds(500))
        let failure = await failure(of: coordinator)
        #expect(failure?.kind == .timedOut)
        coordinator.stop()
        begin.cancel()
    }

    @Test func aDiscThatNeverMovesFailsAtTheFirstDeadline() async {
        let engine = FakePlaybackEngine()
        engine.loadHandler = { _ in try await Task.sleep(for: .seconds(30)) }
        let clock = ManualClock()
        let coordinator = makeCoordinator(engine, clock: clock)
        coordinator.discStartWindow = .seconds(10)
        let begin = Task { await coordinator.begin(discRequest()) }
        await clock.waitForSleep(until: .milliseconds(200))
        clock.advance(to: .milliseconds(200))
        let failure = await failure(of: coordinator)
        #expect(failure?.kind == .timedOut)
        coordinator.stop()
        begin.cancel()
    }

    @Test func theCapEndsADiscThatIsStillMoving() async {
        let engine = FakePlaybackEngine()
        engine.loadHandler = { _ in try await Task.sleep(for: .seconds(30)) }
        let clock = ManualClock()
        let coordinator = makeCoordinator(engine, clock: clock)
        coordinator.discStartWindow = .milliseconds(300)
        coordinator.discStartCap = .milliseconds(800)
        let begin = Task { await coordinator.begin(discRequest()) }
        // Moving at every deadline: 200 ms, then a 300 ms window to 500 ms,
        // then the 300 ms left under the cap; at 800 ms the cap ends it.
        for (step, deadline) in [Duration.milliseconds(200), .milliseconds(500), .milliseconds(800)].enumerated() {
            await clock.waitForSleep(until: deadline)
            engine.startupCheckpoint = step + 1
            clock.advance(to: deadline)
        }
        let failure = await failure(of: coordinator)
        begin.cancel()
        #expect(failure?.kind == .timedOut)
        coordinator.stop()
    }
}

/// A throwaway defaults domain per test, so a guard starts with no history.
private func freshDefaults() -> UserDefaults {
    let name = "OpenStreamDiscTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

@Suite struct AppleDiscMainTitlePolicyTests {
    typealias Policy = AppleDiscMainTitlePolicy
    private func title(_ id: Int, minutes: Double, chapters: Int) -> AppleDiscTitle {
        AppleDiscTitle(id: id, durationSeconds: minutes * 60, chapterCount: chapters)
    }

    @Test func theEnginesLongestTitleStandsWhenChaptersAgree() {
        #expect(Policy.mainTitleID([title(0, minutes: 132, chapters: 20), title(1, minutes: 128, chapters: 18)]) == 0)
        #expect(Policy.mainTitleID([]) == nil)
    }

    /// An obfuscated disc's longest playlist with no chapters, against the
    /// film with 24.
    @Test func aChapteredFeatureBeatsALongerPlaylistWithout() {
        #expect(Policy.mainTitleID([title(0, minutes: 131, chapters: 0), title(1, minutes: 125, chapters: 24),
                                    title(2, minutes: 124, chapters: 24)]) == 1)
    }

    @Test func aGapOfFiveChaptersOrLessKeepsTheLongerTitle() {
        #expect(Policy.mainTitleID([title(0, minutes: 120, chapters: 1), title(1, minutes: 115, chapters: 6)]) == 0)
        #expect(Policy.mainTitleID([title(0, minutes: 120, chapters: 1), title(1, minutes: 115, chapters: 7)]) == 1)
    }

    @Test func bothTitlesMustHaveChaptersForTheGapToBeIgnored() {
        #expect(Policy.mainTitleID([title(0, minutes: 120, chapters: 2), title(1, minutes: 115, chapters: 30)]) == 0)
    }

    @Test func titlesUnderHalfAnHourGoByLength() {
        #expect(Policy.mainTitleID([title(0, minutes: 29, chapters: 0), title(1, minutes: 28, chapters: 12)]) == 0)
        #expect(Policy.mainTitleID([title(0, minutes: 120, chapters: 0), title(1, minutes: 29, chapters: 12)]) == 0)
    }

    @Test func theTitlesRowLeadsWithThePolicysMainFeature() {
        let list = AppleDiscTitleList([title(0, minutes: 131, chapters: 0), title(1, minutes: 125, chapters: 24)])
        #expect(list.visible.map(\.id) == [1, 0])
        #expect(list.visible.map(\.name) == ["Main Feature", "Title 1"])
    }

    @Test func onlyABluRayMainFeatureStartTakesThePick() {
        let titles = [title(0, minutes: 131, chapters: 0), title(1, minutes: 125, chapters: 24)]
        let main = AppleDiscPlaybackChoice(start: .mainTitle, format: .bluRay)
        #expect(main.engineTitleID(knownTitles: titles) == 1)
        #expect(main.engineTitleID(knownTitles: []) == nil)
        #expect(main.replacementMainTitleID(for: titles) == 1)
        #expect(AppleDiscPlaybackChoice(start: .mainTitle, titleID: 0, format: .bluRay).engineTitleID(knownTitles: titles) == 0)
        #expect(AppleDiscPlaybackChoice(start: .mainTitle, format: .dvd).engineTitleID(knownTitles: titles) == nil)
        #expect(AppleDiscPlaybackChoice(start: .menu, format: .dvd).engineTitleID(knownTitles: titles) == nil)
        let agreed = [title(0, minutes: 131, chapters: 24), title(1, minutes: 125, chapters: 24)]
        #expect(main.engineTitleID(knownTitles: agreed) == nil)
    }
}

@MainActor
@Suite(.serialized) struct AppleDiscCrashGuardTests {
    private func discRequest(_ path: String = "smb://fixture.invalid/Media/bad.iso") -> ApplePlaybackRequest {
        var hints = ApplePlaybackRequest.Hints(filename: "bad.iso", libraryFileURL: URL(string: path)!)
        hints.disc = AppleDiscPlaybackChoice(start: .mainTitle, format: .bluRay)
        return ApplePlaybackRequest(url: URL(string: "http://127.0.0.1:8765/media/token/bad.iso")!,
            mediaID: "disc", sourceKind: .networkShare, hints: hints)
    }

    @Test func anOpenThatNeverReturnedIsRefusedNextLaunch() throws {
        let defaults = freshDefaults()
        let before = AppleDiscCrashGuard(defaults: defaults, build: "20")
        let key = try #require(before.key(for: discRequest()))
        before.opening(key)
        // The app dies here; the next launch builds a new guard.
        let after = AppleDiscCrashGuard(defaults: defaults, build: "20")
        #expect(after.refuses(key))
        #expect(defaults.string(forKey: AppleDiscCrashGuard.openingKey) == nil)
        #expect(after.key(for: discRequest("smb://fixture.invalid/Media/good.iso")).map(after.refuses) == false)
    }

    @Test func anOpenThatReturnedIsNotACrash() throws {
        let defaults = freshDefaults()
        let first = AppleDiscCrashGuard(defaults: defaults, build: "20")
        let key = try #require(first.key(for: discRequest()))
        first.opening(key)
        first.opened(key)
        #expect(!AppleDiscCrashGuard(defaults: defaults, build: "20").refuses(key))
    }

    @Test func anOlderOpenDoesNotClearANewerMark() throws {
        let defaults = freshDefaults()
        let crashGuard = AppleDiscCrashGuard(defaults: defaults, build: "20")
        let older = try #require(crashGuard.key(for: discRequest("smb://fixture.invalid/Media/a.iso")))
        let newer = try #require(crashGuard.key(for: discRequest("smb://fixture.invalid/Media/b.iso")))
        crashGuard.opening(older)
        crashGuard.opening(newer)
        crashGuard.opened(older)
        #expect(defaults.string(forKey: AppleDiscCrashGuard.openingKey) == newer)
    }

    @Test func aNewBuildTriesTheDiscAgain() throws {
        let defaults = freshDefaults()
        let crashed = AppleDiscCrashGuard(defaults: defaults, build: "20")
        crashed.opening(try #require(crashed.key(for: discRequest())))
        let updated = AppleDiscCrashGuard(defaults: defaults, build: "21")
        #expect(!updated.refuses(try #require(updated.key(for: discRequest()))))
    }

    @Test func onlyDiscRequestsAreGuarded() {
        let crashGuard = AppleDiscCrashGuard(defaults: freshDefaults(), build: "20")
        #expect(crashGuard.key(for: ApplePlaybackRequest(url: URL(string: "https://fixture.example/movie.mkv")!,
            mediaID: "movie", sourceKind: .networkShare)) == nil)
    }

    @Test func theCoordinatorRefusesACrashedDiscWithoutOpeningIt() async throws {
        let defaults = freshDefaults()
        let crashed = AppleDiscCrashGuard(defaults: defaults, build: "20")
        crashed.opening(try #require(crashed.key(for: discRequest())))
        let engine = FakePlaybackEngine()
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        coordinator.discCrashGuard = AppleDiscCrashGuard(defaults: defaults, build: "20")
        await coordinator.begin(discRequest())
        guard case .failed(let failure) = coordinator.phase else {
            Issue.record("expected a failure, got \(coordinator.phase)")
            return
        }
        #expect(failure.userMessage == AppleDiscCrashGuard.refusalMessage)
        #expect(engine.loadedRequests.isEmpty)
        coordinator.stop()
    }

    @Test func theCoordinatorMarksADiscOnlyWhileItOpens() async throws {
        let defaults = freshDefaults()
        let engine = FakePlaybackEngine()
        var markDuringLoad: String?
        engine.loadHandler = { _ in markDuringLoad = defaults.string(forKey: AppleDiscCrashGuard.openingKey) }
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        coordinator.discCrashGuard = AppleDiscCrashGuard(defaults: defaults, build: "20")
        await coordinator.begin(discRequest())
        #expect(markDuringLoad == coordinator.discCrashGuard.key(for: discRequest()))
        #expect(defaults.string(forKey: AppleDiscCrashGuard.openingKey) == nil)
        coordinator.stop()
    }
}
