import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Testing
#if os(iOS) || os(tvOS)
import MediaPlayer
#endif
@testable import OpenStreamApple

@MainActor
@Test func reloadGateRejectsOverlapAndAllowsTheNextCompletedReload() {
    let gate = AppleReloadGate()
    #expect(gate.begin())
    #expect(!gate.begin())
    gate.end()
    #expect(gate.begin())
    gate.end()
}

@Test func remoteImageDecoderBoundsDecodedPixelMemory() throws {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = try #require(CGContext(
        data: nil,
        width: 1_024,
        height: 768,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(red: 0.1, green: 0.3, blue: 0.7, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 1_024, height: 768))
    let sourceImage = try #require(context.makeImage())
    let encoded = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(
        encoded,
        "public.png" as CFString,
        1,
        nil
    ))
    CGImageDestinationAddImage(destination, sourceImage, nil)
    #expect(CGImageDestinationFinalize(destination))

    let decoded = try AppleRemoteImageDecoder.downsample(
        data: encoded as Data,
        maximumPixelDimension: 128
    )
    #expect(max(decoded.width, decoded.height) <= 128)
    #expect(decoded.bytesPerRow * decoded.height <= 128 * 128 * 4)
}

@Test func remoteImageCacheDeduplicatesConcurrentLoads() async throws {
    let image = try makeImage(width: 64, height: 64)
    let probe = AppleImageLoadProbe(image: image)
    let cache = AppleRemoteImageCache { _, _ in try await probe.load() }
    let url = URL(string: "https://images.example/poster.png")!

    async let first = cache.image(url: url, maximumPixelDimension: 64)
    async let second = cache.image(url: url, maximumPixelDimension: 64)
    let values = try await (first, second)

    #expect(values.0.width == 64)
    #expect(values.1.width == 64)
    #expect(await probe.loadCount == 1)
}

@MainActor
@Test func postStartPlayerFailureReachesTheUserVisibleCoordinator() async throws {
    let suiteName = "openstream-player-failure-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let session = ApplePlayerSession(
        url: URL(fileURLWithPath: "/tmp/openstream-missing-media.mp4"),
        progressStore: ApplePlaybackStore(defaults: defaults)
    )
    defer { session.stop(saveProgress: false) }
    let coordinator = ApplePlaybackCoordinator()
    coordinator.update(.playing)
    session.onPlaybackFailure = { failure in _ = coordinator.fail(failure) }

    NotificationCenter.default.post(
        name: AVPlayerItem.failedToPlayToEndTimeNotification,
        object: session.playerItem
    )
    try await Task.sleep(for: .milliseconds(50))

    guard case .failed(let failure) = coordinator.phase else {
        Issue.record("Expected a failed playback phase")
        return
    }
    #expect(failure.kind == .unsupportedMedia)
    #expect(!failure.message.isEmpty)
}

@MainActor
@Test func playbackCoordinatorResetDetachesFailureReporting() async throws {
    let suiteName = "openstream-player-monitor-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let session = ApplePlayerSession(
        url: URL(fileURLWithPath: "/tmp/openstream-monitor-fixture.mp4"),
        progressStore: ApplePlaybackStore(defaults: defaults)
    )
    defer { session.stop(saveProgress: false) }
    let coordinator = ApplePlaybackCoordinator()

    coordinator.attachFailureReporting(to: session)
    #expect(session.onPlaybackFailure != nil)
    coordinator.reset()
    #expect(session.onPlaybackFailure == nil)
    NotificationCenter.default.post(
        name: AVPlayerItem.failedToPlayToEndTimeNotification,
        object: session.playerItem
    )
    try await Task.sleep(for: .milliseconds(50))
    #expect(coordinator.phase == .idle)
}

@Test func healthOnlySourceChangesDoNotTriggerCatalogRefreshIdentity() {
    let source = AppleSource(
        kind: .stremio,
        name: "Catalog",
        url: URL(string: "https://catalog.example/manifest.json")!,
        resources: ["catalog"]
    )
    var updated = source
    updated.lastValidatedAt = Date(timeIntervalSince1970: 1_788_000_000)
    updated.validationSummary = "Refreshed 10 titles"
    updated.discoveredItemCount = 10
    updated.capabilities = ["Catalog"]
    updated.lastValidationFailureAt = Date(timeIntervalSince1970: 1_788_000_001)
    updated.validationFailureSummary = "One catalog unavailable"

    #expect(catalogConfigurationIdentity([source]) == catalogConfigurationIdentity([updated]))
}

@Test func smbRangeBridgeMeasuresSeekStartupAndReleasesItsListener() async throws {
    let payload = Data((0 ..< 8 * 1_024 * 1_024).map { UInt8($0 % 251) })
    let client = ApplePerformanceSMBClient(payload: payload)
    let server = AppleSMBRangeServer(client: client)
    let source = URL(string: "smb://fixture.invalid/Media/movie.mp4")!
    let playback = try await server.playbackURL(
        sourceURL: source,
        credentials: .init(username: "fixture", password: "fixture"),
        sizeBytes: Int64(payload.count)
    )
    var request = URLRequest(url: playback)
    request.setValue("bytes=4194304-4198399", forHTTPHeaderField: "Range")

    let clock = ContinuousClock()
    let started = clock.now
    let (data, response) = try await URLSession.shared.data(for: request)
    let elapsed = started.duration(to: clock.now)
    print("OpenStream SMB range 4 KiB seek fixture: \(elapsed)")
    #expect((response as? HTTPURLResponse)?.statusCode == 206)
    #expect(data == payload.subdata(in: 4_194_304 ..< 4_198_400))
    #expect(elapsed < .seconds(2))

    await server.revoke(playbackURL: playback)
    let stopped = await server.diagnostics()
    #expect(stopped.sessionCount == 0)
    #expect(!stopped.listenerActive)
    #expect(await client.closeCount == 1)

    let replay = try await server.playbackURL(
        sourceURL: source,
        credentials: .init(username: "fixture", password: "fixture"),
        sizeBytes: Int64(payload.count)
    )
    await server.revoke(playbackURL: replay)
}

#if os(iOS) || os(tvOS)
@MainActor
@Test func audioNotificationsPostedOffMainHopSafelyToTheCoordinator() async throws {
    let coordinator = AppleAudioSessionCoordinator()
    var interruptions: [AppleAudioInterruptionEvent] = []
    coordinator.onInterruption = { event in
        MainActor.assertIsolated()
        interruptions.append(event)
    }

    await Task.detached {
        NotificationCenter.default.post(
            name: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [AVAudioSessionRouteChangeReasonKey: NSNumber(value: 3)]
        )
        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [AVAudioSessionInterruptionTypeKey: NSNumber(value: AVAudioSession.InterruptionType.began.rawValue)]
        )
    }.value
    try await Task.sleep(for: .milliseconds(100))

    #expect(coordinator.state.lastRouteChangeReasonRawValue == 3)
    #expect(coordinator.state.isInterrupted)
    #expect(interruptions == [.began])
}

@MainActor
@Test func interruptionPauseResumeUpdatesPlayerAndNowPlayingState() throws {
    let suiteName = "openstream-audio-interruption-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let session = ApplePlayerSession(
        url: URL(fileURLWithPath: "/tmp/openstream-audio-fixture.mp4"),
        progressStore: ApplePlaybackStore(defaults: defaults),
        title: "Fixture title"
    )
    defer { session.stop(saveProgress: false) }

    session.player.play()
    session.refreshNowPlayingInfo()
    session.handleAudioInterruption(.began)
    #expect(session.player.rate == 0)
    #expect(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Float == 0)

    session.handleAudioInterruption(.ended(shouldResume: true))
    #expect(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == "Fixture title")
}
#endif

private actor ApplePerformanceSMBClient: AppleNetworkShareClient {
    let payload: Data
    private(set) var closeCount = 0

    init(payload: Data) { self.payload = payload }

    func listShares(host _: String, port _: Int, credentials _: AppleSMBCredentials) async throws -> [AppleSMBShare] { [] }

    func listDirectory(
        url _: URL,
        credentials _: AppleSMBCredentials,
        recursive _: Bool
    ) async throws -> [AppleSMBDirectoryEntry] { [] }

    func read(
        url _: URL,
        credentials _: AppleSMBCredentials,
        range: Range<UInt64>
    ) async throws -> Data {
        payload.subdata(in: Int(range.lowerBound) ..< Int(range.upperBound))
    }

    func closeAll() async { closeCount += 1 }
}

private actor AppleImageLoadProbe {
    let image: CGImage
    private(set) var loadCount = 0

    init(image: CGImage) { self.image = image }

    func load() async throws -> CGImage {
        loadCount += 1
        try await Task.sleep(for: .milliseconds(50))
        return image
    }
}

private func makeImage(width: Int, height: Int) throws -> CGImage {
    let context = try #require(CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(gray: 0.5, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return try #require(context.makeImage())
}
