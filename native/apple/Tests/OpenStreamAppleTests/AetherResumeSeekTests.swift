import CoreMedia
import Foundation
import Testing
@testable import OpenStreamApple

@MainActor
struct AetherResumeSeekTests {
    #if DEBUG
    @Test(.timeLimit(.minutes(1)), .enabled(if: FileManager.default.fileExists(
        atPath: AetherResumeSeekTests.fixture("mp4-h264-aac.mp4").path)))
    func nativeItemsKeepTheirPresentationRouteDuringLoad() async throws {
        let engine = try AetherPlaybackEngine()
        engine.multiviewMuted = true
        defer { engine.stop() }
        let request = ApplePlaybackRequest(url: Self.fixture("mp4-h264-aac.mp4"),
            autoplay: false, mediaID: "native-first", sourceKind: .files)
        try await engine.load(request)
        let player = try #require(engine.avPlayer)
        let events = engine.events
        var routes: [ApplePlaybackPresentationRoute] = []
        try await engine.load(ApplePlaybackRequest(url: request.url,
            autoplay: false, mediaID: "native-next", sourceKind: .files))
        for await event in events {
            if case .route(let route) = event { routes.append(route) }
            if case .phase(.paused) = event { break }
        }
        #expect(engine.avPlayer === player)
        #if !os(visionOS)
        #expect(!routes.contains(.none), "Native item changes must not unmount the player")
        #endif
        #expect(engine.route == .avPlayer)
    }

    @Test(.enabled(if: FileManager.default.fileExists(
        atPath: AetherResumeSeekTests.fixture("ts-mpeg2-interlaced-mp2.ts").path)))
    func failedLoadNextItemAndStopReleaseThePreviousSurface() async throws {
        let engine = try AetherPlaybackEngine()
        engine.multiviewMuted = true
        defer { engine.stop() }
        let software = ApplePlaybackRequest(url: Self.fixture("ts-mpeg2-interlaced-mp2.ts"),
            autoplay: false, mediaID: "software", sourceKind: .files)
        try await engine.load(software)
        #expect(engine.route == .surface)

        let missing = ApplePlaybackRequest(url: Self.fixture("missing-round4-video.mkv"),
            autoplay: false, mediaID: "missing", sourceKind: .files)
        await #expect(throws: (any Error).self) { try await engine.load(missing) }
        #expect(engine.route == .none)

        let next = ApplePlaybackRequest(url: Self.fixture("mp4-h264-aac.mp4"),
            autoplay: false, mediaID: "next", sourceKind: .files)
        try await engine.load(next)
        #expect(engine.route == .avPlayer)
        engine.stop()
        #expect(engine.route == .none)
    }

    @Test(.enabled(if: FileManager.default.fileExists(
        atPath: AetherResumeSeekTests.fixture("ts-mpeg2-interlaced-mp2.ts").path)),
          arguments: [false, true])
    func loadRestoresSoftwareResumeWithTheLoadedPresentationClock(autoplay: Bool) async throws {
        let engine = try AetherPlaybackEngine()
        engine.multiviewMuted = true
        defer {
            engine.debugResumeSeekProbe = nil
            engine.stop()
        }
        let request = ApplePlaybackRequest(url: Self.fixture("ts-mpeg2-interlaced-mp2.ts"),
            resumePosition: 7.25, autoplay: autoplay, mediaID: "software-resume", sourceKind: .files)
        var seeks: [Double] = []
        engine.debugResumeSeekProbe = { seconds in
            #expect(engine.route == .surface)
            #expect(engine.aetherEngine.softwarePresentationTimebase != nil)
            seeks.append(seconds)
        }

        try await engine.load(request)

        #expect(engine.route == .surface)
        let timebase = try #require(engine.aetherEngine.softwarePresentationTimebase)
        #expect(seeks == [7.25], "load must await one resume seek after the software clock exists")
        #expect(abs(CMTimebaseGetTime(timebase).seconds - 7.25) < 1)
    }

    @Test(.enabled(if: FileManager.default.fileExists(
        atPath: AetherResumeSeekTests.fixture("mp4-h264-aac.mp4").path)),
          arguments: [false, true])
    func loadRestoresPausedNativeResumeWithoutRepeatingAutoplaySeek(autoplay: Bool) async throws {
        let engine = try AetherPlaybackEngine()
        engine.multiviewMuted = true
        defer {
            engine.debugResumeSeekProbe = nil
            engine.stop()
        }
        let request = ApplePlaybackRequest(url: Self.fixture("mp4-h264-aac.mp4"),
            resumePosition: 7.25, autoplay: autoplay, mediaID: "native-resume", sourceKind: .files)
        var seeks: [Double] = []
        engine.debugResumeSeekProbe = { seconds in
            #expect(engine.route == .avPlayer)
            seeks.append(seconds)
        }

        try await engine.load(request)

        #expect(engine.route == .avPlayer)
        #expect(seeks == (autoplay ? [] : [7.25]))
        let player = try #require(engine.avPlayer)
        #expect(abs(player.currentTime().seconds - 7.25) < 1)
    }

    nonisolated private static func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/out").appendingPathComponent(name)
    }
    #endif

    @Test(arguments: [false, true], [false, true])
    func loadedResumeSeeksOnceWhenPausedOrSoftwareClockIsArmed(autoplay: Bool, hasTimebase: Bool) async throws {
        let engine = FakePlaybackEngine()
        engine.scriptedRoute = .surface
        let request = ApplePlaybackRequest(
            url: try #require(URL(string: "https://fixture.example/movie.mkv")),
            resumePosition: 451, autoplay: autoplay, mediaID: "resume", sourceKind: .files)
        var timebase: CMTimebase?
        engine.loadHandler = { _ in
            if hasTimebase {
                #expect(CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault,
                    sourceClock: CMClockGetHostTimeClock(), timebaseOut: &timebase) == noErr)
            }
        }
        try await engine.load(request)
        await AetherPlaybackEngine.restoreResumePosition(request, route: engine.route, softwareTimebase: timebase) { seconds in
            #expect(engine.loadedRequests.count == 1)
            #expect((timebase != nil) == hasTimebase)
            await engine.seek(to: seconds)
        }
        #expect(engine.seeks == (!autoplay || hasTimebase ? [451] : []))
    }

    @Test func nativeAutoplayDoesNotRepeatTheLoadResumeSeek() async throws {
        let engine = FakePlaybackEngine()
        let request = ApplePlaybackRequest(
            url: try #require(URL(string: "https://fixture.example/movie.mp4")),
            resumePosition: 451, autoplay: true, mediaID: "resume", sourceKind: .files)
        var timebase: CMTimebase?
        #expect(CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(), timebaseOut: &timebase) == noErr)
        try await engine.load(request)
        await AetherPlaybackEngine.restoreResumePosition(request, route: engine.route,
            softwareTimebase: timebase, seek: engine.seek)
        #expect(engine.seeks.isEmpty)
    }

    @Test(arguments: [false, true], [false, true])
    func liveResumeNeverSeeksAfterLoad(autoplay: Bool, hasSoftwareClock: Bool) async throws {
        let engine = FakePlaybackEngine()
        engine.scriptedRoute = .surface
        let request = ApplePlaybackRequest(
            url: try #require(URL(string: "https://fixture.example/live.ts")),
            isLive: true, resumePosition: 451, autoplay: autoplay, mediaID: "live", sourceKind: .iptv)
        var timebase: CMTimebase?
        if hasSoftwareClock {
            #expect(CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault,
                sourceClock: CMClockGetHostTimeClock(), timebaseOut: &timebase) == noErr)
        }
        try await engine.load(request)
        await AetherPlaybackEngine.restoreResumePosition(request, route: engine.route,
            softwareTimebase: timebase, seek: engine.seek)
        #expect(engine.seeks.isEmpty)
    }

    @Test(arguments: [nil, 0, -1, Double.nan, Double.infinity] as [Double?])
    func absentOrInvalidResumeNeverSeeks(resume: Double?) async throws {
        let engine = FakePlaybackEngine()
        let request = ApplePlaybackRequest(
            url: try #require(URL(string: "https://fixture.example/movie.mkv")),
            resumePosition: resume, autoplay: false, mediaID: "resume", sourceKind: .files)
        try await engine.load(request)
        await AetherPlaybackEngine.restoreResumePosition(request, route: engine.route,
            softwareTimebase: nil, seek: engine.seek)
        #expect(engine.seeks.isEmpty)
    }
}
