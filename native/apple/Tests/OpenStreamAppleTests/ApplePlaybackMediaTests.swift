import Foundation
import Testing
@testable import OpenStreamApple

@Test func playbackIdentityIsStableAndNeverContainsTheSourceValue() throws {
    let mediaID = "file:///fixture/Movies/private-title.mp4"
    let first = try #require(ApplePlaybackIdentity.storageKey(for: mediaID))
    let second = try #require(ApplePlaybackIdentity.storageKey(for: mediaID))

    #expect(first == second)
    #expect(ApplePlaybackIdentity.isStorageKey(first))
    #expect(!first.contains("private-title"))
    #expect(first.count == 71)
}

@MainActor
@Test func playbackStoreUsesOpaqueKeysAndThirtySecondCompletionThreshold() throws {
    let suiteName = "openstream-playback-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = ApplePlaybackStore(defaults: defaults)
    let rawMediaID = "/fixture/Movies/private-title.mp4"

    store.save(mediaID: rawMediaID, position: 589, duration: 600)
    #expect(store.progress(for: rawMediaID)?.resumePosition == 589)

    let data = try #require(defaults.data(forKey: "openstream.playback.progress.v1"))
    let persisted = try JSONDecoder().decode([String: ApplePlaybackProgress].self, from: data)
    let key = try #require(persisted.keys.first)
    #expect(ApplePlaybackIdentity.isStorageKey(key))
    #expect(!key.contains("private-title"))

    store.save(mediaID: rawMediaID, position: 590, duration: 600)
    #expect(store.progress(for: rawMediaID) == nil)
}

@Test func routePolicyRequiresRuntimeSuitabilityAndNeverExportsMatroska() {
    let localMovie = URL(fileURLWithPath: "/tmp/movie.mp4")
    let localMKV = URL(fileURLWithPath: "/tmp/movie.mkv")
    let remoteMKV = URL(string: "https://media.example/movie.mkv")!
    let unsupported = OpenStreamPlaybackDecision(support: .unsupported, reasons: ["runtime rejected asset"])

    #expect(ApplePlaybackRoutePolicy.route(
        sourceURL: localMovie,
        decision: unsupported,
        suitability: .init(
            isPlayable: false,
            isReadable: true,
            isExportable: true,
            isProtected: false
        )
    ) == .nativeOfflineExport(localMovie))

    #expect(ApplePlaybackRoutePolicy.route(
        sourceURL: localMKV,
        decision: unsupported,
        suitability: .init(
            isPlayable: false,
            isReadable: true,
            isExportable: true,
            isProtected: false
        )
    ) == .direct(localMKV))

    #expect(ApplePlaybackRoutePolicy.route(
        sourceURL: remoteMKV,
        decision: unsupported
    ) == .direct(remoteMKV))
}

@Test func protectedNonplayableAndUnreadableAssetsNeverUseNativeExport() {
    let localMovie = URL(fileURLWithPath: "/tmp/movie.mp4")
    let remoteMovie = URL(string: "https://media.example/movie.mp4")!
    let unsupported = OpenStreamPlaybackDecision(support: .unsupported, reasons: ["decoder unavailable"])

    #expect(ApplePlaybackRoutePolicy.route(
        sourceURL: localMovie,
        decision: unsupported,
        suitability: .init(
            isPlayable: false,
            isReadable: true,
            isExportable: true,
            isProtected: true
        )
    ) == .unavailable(["decoder unavailable"]))

    #expect(ApplePlaybackRoutePolicy.route(
        sourceURL: remoteMovie,
        decision: unsupported,
        suitability: .init(
            isPlayable: false,
            isReadable: false,
            isExportable: false,
            isProtected: false
        )
    ) == .requiresExternalDemux(remoteMovie))

    #expect(ApplePlaybackRoutePolicy.route(
        sourceURL: localMovie,
        decision: unsupported,
        suitability: .init(
            isPlayable: false,
            isReadable: true,
            isExportable: false,
            isProtected: false
        )
    ) == .unavailable(["decoder unavailable"]))
}

@Test func negotiatorNeedsConcreteAssetAndTrackEvidence() {
    let report = OpenStreamCapabilityReport(
        platform: "tvOS",
        hdrEligible: true,
        dynamicRange: [.sdr: .supported],
        projections: [.flat: .supported]
    )
    let format = OpenStreamFormat(
        dynamicRange: .sdr,
        codec: "hvc1",
        width: 1920,
        height: 1080,
        frameRate: 24
    )

    #expect(OpenStreamCapabilityNegotiator.evaluate(format, against: report).support == .runtimeCheck)

    let evidence = OpenStreamRuntimePlaybackEvidence(
        assetIsPlayable: true,
        assetIsReadable: true,
        assetIsExportable: true,
        hasProtectedContent: false,
        enabledVideoTracksArePlayableAndDecodable: true,
        enabledAudioTracksArePlayableAndDecodable: true
    )
    #expect(OpenStreamCapabilityNegotiator.evaluate(
        format,
        against: report,
        runtime: evidence
    ).support == .supported)
}

@Test func routePolicyRoutesMatroskaAndMPEGTransportStreamDirectly() {
    let localMKV = URL(fileURLWithPath: "/tmp/movie.mkv")
    let localTS = URL(fileURLWithPath: "/tmp/movie.ts")
    let remoteTS = URL(string: "https://media.example/live.ts")!
    let unsupported = OpenStreamPlaybackDecision(support: .unsupported, reasons: ["container"])

    #expect(ApplePlaybackRoutePolicy.route(
        sourceURL: localMKV,
        decision: unsupported
    ) == .direct(localMKV))

    #expect(ApplePlaybackRoutePolicy.route(
        sourceURL: localTS,
        decision: unsupported
    ) == .direct(localTS))

    #expect(ApplePlaybackRoutePolicy.route(
        sourceURL: remoteTS,
        decision: unsupported
    ) == .direct(remoteTS))
}

@MainActor
@Test func preparedPlaybackIsDirectlyConsumableByThePlayerSession() throws {
    let suiteName = "openstream-prepared-player-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let url = URL(fileURLWithPath: "/tmp/prepared-movie.mp4")
    let prepared = ApplePreparedPlayback(
        route: .direct(url),
        url: url,
        requestHeaders: ["User-Agent": "OpenStream-IPTV", "Referer": "https://provider.example/"]
    )
    let session = ApplePlayerSession(
        preparedPlayback: prepared,
        progressStore: ApplePlaybackStore(defaults: defaults)
    )
    defer { session.stop(saveProgress: false) }

    #expect(session.requestHeaders == prepared.requestHeaders)
    #expect(session.player.currentItem === session.playerItem)
    #expect(ApplePlaybackIdentity.isStorageKey(session.mediaIdentity))
}

@MainActor
@Test func playbackCoordinatorReportsStagesAndClassifiesActionableFailures() {
    let coordinator = ApplePlaybackCoordinator()

    coordinator.beginResolving()
    #expect(coordinator.phase == .resolving)
    coordinator.update(.loading)
    #expect(coordinator.phase == .loading)
    coordinator.update(.loading)
    #expect(coordinator.phase == .loading)

    let authentication = coordinator.fail(AppleIPTVError.requestFailed(403))
    #expect(authentication.kind == .authentication)
    #expect(authentication.message.contains("HTTP 403"))
    #expect(coordinator.phase == .failed(authentication))

    let unsupported = ApplePlaybackFailure.classify(URLError(.cannotDecodeContentData))
    #expect(unsupported.kind == .unsupportedMedia)
    #expect(unsupported.message.contains("cannot be played directly"))

    let network = ApplePlaybackFailure.classify(URLError(.cannotConnectToHost))
    #expect(network.kind == .network)
    #expect(network.message.contains("network"))
}
