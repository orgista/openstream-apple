import Foundation
import Testing
@testable import OpenStreamApple

@Test func dolbyVisionConfigurationParsesProfileAndFlags() {
    let data = Data([1, 0, 16, 0b101, 0])
    let configuration = DolbyVisionConfiguration(record: data)
    #expect(configuration?.profile == 8)
    #expect(configuration?.hasRPU == true)
    #expect(configuration?.hasEnhancementLayer == false)
    #expect(configuration?.hasBaseLayer == true)
    #expect(configuration?.baseLayerSignalCompatibilityID == 0)
    #expect(configuration?.profile(usingBaseTransferFunction: "SMPTE_ST_2084_PQ") == .profile81)
    #expect(configuration?.profile(usingBaseTransferFunction: "ITU_R_2100_HLG") == .profile84)
}

@Test func dolbyVisionConfigurationParsesNonZeroIndexDataSlices() {
    let source = Data([0xff, 0xee, 1, 0, 16, 0b101, 0x20])
    let record = source[2..<7]
    #expect(record.startIndex == 2)

    let configuration = DolbyVisionConfiguration(record: record)
    #expect(configuration?.profile == 8)
    #expect(configuration?.hasRPU == true)
    #expect(configuration?.hasBaseLayer == true)
    #expect(configuration?.baseLayerSignalCompatibilityID == 2)
    #expect(DolbyVisionConfiguration(record: source[3..<7]) == nil)
}

@Test func dolbyVisionProfile8UsesExplicitBaseLayerCompatibilityBeforeTransferFallback() {
    let profile81 = DolbyVisionConfiguration(record: Data([1, 0, 16, 0b101, 0x10]))
    let profile82 = DolbyVisionConfiguration(record: Data([1, 0, 16, 0b101, 0x20]))
    let profile84 = DolbyVisionConfiguration(record: Data([1, 0, 16, 0b101, 0x40]))

    #expect(profile81?.profile(usingBaseTransferFunction: "ITU_R_2100_HLG") == .profile81)
    #expect(profile82?.profile(usingBaseTransferFunction: "SMPTE_ST_2084_PQ") == .profile82)
    #expect(profile84?.profile(usingBaseTransferFunction: "SMPTE_ST_2084_PQ") == .profile84)
}

@Test func negotiatorNeverTreatsDolbyVisionEligibilityAsAProfileGuarantee() {
    let report = OpenStreamCapabilityReport(
        platform: "tvOS",
        hdrEligible: true,
        dynamicRange: [.sdr: .supported, .dolbyVision: .runtimeCheck],
        projections: [.flat: .supported]
    )
    let format = OpenStreamFormat(
        dynamicRange: .dolbyVision,
        dolbyVisionProfile: .profile81,
        codec: "dvh1",
        width: 3840,
        height: 2160,
        frameRate: 23.976
    )
    let decision = OpenStreamCapabilityNegotiator.evaluate(format, against: report)
    #expect(decision.support == .runtimeCheck)
    #expect(decision.reasons.contains { $0.contains("profile") })
}

@Test func unsupportedProjectionBlocksTheRoute() {
    let report = OpenStreamCapabilityReport(
        platform: "tvOS",
        hdrEligible: true,
        dynamicRange: [.hdr10: .runtimeCheck],
        projections: [.stereo180: .unsupported]
    )
    let format = OpenStreamFormat(
        dynamicRange: .hdr10,
        projection: .stereo180,
        codec: "hvc1",
        width: 7680,
        height: 7680,
        frameRate: 90
    )
    #expect(OpenStreamCapabilityNegotiator.evaluate(format, against: report).support == .unsupported)
}

@Test func unknownProjectionMetadataIsNotClassifiedAsFlat() {
    #expect(AppleAssetInspector.projection(kind: nil, stereo: false) == .flat)
    #expect(AppleAssetInspector.projection(kind: "future-projection", stereo: false) == .unknown)
    #expect(AppleAssetInspector.projection(kind: "future-projection", stereo: true) == .unknown)
}

@Test func negotiatorRejectsMalformedGeometryAndRequiresUnknownCodecChecks() {
    let report = OpenStreamCapabilityReport(
        platform: "tvOS",
        hdrEligible: true,
        dynamicRange: [.sdr: .supported],
        projections: [.flat: .supported]
    )

    for format in [
        OpenStreamFormat(dynamicRange: .sdr, codec: "hvc1", width: 0, height: 1080, frameRate: 24),
        OpenStreamFormat(dynamicRange: .sdr, codec: "hvc1", width: 1920, height: -1, frameRate: 24),
        OpenStreamFormat(dynamicRange: .sdr, codec: "hvc1", width: 100_000, height: 1080, frameRate: 24),
        OpenStreamFormat(dynamicRange: .sdr, codec: "hvc1", width: 1920, height: 1080, frameRate: .nan),
        OpenStreamFormat(dynamicRange: .sdr, codec: "hvc1", width: 1920, height: 1080, frameRate: .infinity),
        OpenStreamFormat(dynamicRange: .sdr, codec: "hvc1", width: 1920, height: 1080, frameRate: 0),
        OpenStreamFormat(dynamicRange: .sdr, codec: "", width: 1920, height: 1080, frameRate: 24),
    ] {
        #expect(OpenStreamCapabilityNegotiator.evaluate(format, against: report).support == .unsupported)
    }

    let unknownCodec = OpenStreamFormat(
        dynamicRange: .sdr,
        codec: "zzzz",
        width: 1920,
        height: 1080,
        frameRate: 24
    )
    let unknownDecision = OpenStreamCapabilityNegotiator.evaluate(unknownCodec, against: report)
    #expect(unknownDecision.support == .runtimeCheck)
    #expect(unknownDecision.reasons.contains { $0.lowercased().contains("codec") })

    let knownCodec = OpenStreamFormat(
        dynamicRange: .sdr,
        codec: "hvc1",
        width: 1920,
        height: 1080,
        frameRate: 24
    )
    #expect(OpenStreamCapabilityNegotiator.evaluate(knownCodec, against: report).support == .runtimeCheck)
}

@Test func appleOfflinePolicyChoosesTheBestDeviceCompatibleVariant() {
    let variants = [
        AppleOfflineVariant(
            url: URL(string: "https://example.test/4k.m3u8")!,
            width: 3840,
            height: 2160,
            bitrate: 18_000_000,
            codec: .hevc,
            dynamicRange: .dolbyVision,
            estimatedBytes: 9_000_000_000
        ),
        AppleOfflineVariant(
            url: URL(string: "https://example.test/1080.m3u8")!,
            width: 1920,
            height: 1080,
            bitrate: 7_000_000,
            codec: .hevc,
            dynamicRange: .hdr10,
            estimatedBytes: 3_000_000_000
        ),
        AppleOfflineVariant(
            url: URL(string: "https://example.test/720.m3u8")!,
            width: 1280,
            height: 720,
            bitrate: 3_000_000,
            codec: .avc,
            dynamicRange: .sdr,
            estimatedBytes: 1_000_000_000
        ),
    ]
    let device = AppleOfflineDeviceProfile(
        maximumWidth: 1920,
        maximumHeight: 1080,
        codecs: [.avc, .hevc],
        dynamicRanges: [.sdr, .hdr10],
        availableBytes: 5_000_000_000
    )

    #expect(AppleOfflineQualityPolicy.bestVariant(from: variants, for: device)?.height == 1080)
}

@Test func playbackProgressOnlyResumesMeaningfulUnfinishedPlayback() {
    #expect(ApplePlaybackProgress(position: 5, duration: 600).resumePosition == nil)
    #expect(ApplePlaybackProgress(position: 120, duration: 600).resumePosition == 120)
    #expect(ApplePlaybackProgress(position: 569, duration: 600).resumePosition == 569)
    #expect(ApplePlaybackProgress(position: 570, duration: 600).resumePosition == nil)
    #expect(ApplePlaybackProgress(position: 590, duration: 600).resumePosition == nil)
}

@Test func appleOfflineStoreCopiesListsAndRemovesLocalMedia() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "openstream-offline-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appending(path: "source.mp4")
    try Data([0, 1, 2, 3]).write(to: source)
    let store = AppleOfflineMediaStore(rootDirectory: root.appending(path: "library"))

    let artworkURL = URL(string: "https://images.example/movie.jpg")!
    let record = try await store.makeAvailable(
        mediaID: "movie:1",
        sourceURL: source,
        title: "Example Movie",
        subtitle: "2026",
        artworkURL: artworkURL
    )
    #expect(FileManager.default.fileExists(atPath: record.localURL.path))
    #expect(await store.record(for: "movie:1")?.sourceExtension == "mp4")
    #expect(await store.record(for: "movie:1")?.title == "Example Movie")
    #expect(await store.record(for: "movie:1")?.subtitle == "2026")
    #expect(await store.record(for: "movie:1")?.artworkURL == artworkURL)
    #expect(await store.allRecords().map(\.mediaID) == ["movie:1"])

    try await store.remove(mediaID: "movie:1")
    #expect(await store.record(for: "movie:1") == nil)
}

@Test func appleOfflineStoreDownloadsWithOnlyApprovedPlaybackHeaders() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "openstream-offline-request-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let temporaryDownload = root.appending(path: "response.mp4")
    try Data([4, 3, 2, 1]).write(to: temporaryDownload)

    let store = AppleOfflineMediaStore(
        rootDirectory: root.appending(path: "library"),
        downloader: { request in
            #expect(request.value(forHTTPHeaderField: "User-Agent") == "Provider Player")
            #expect(request.value(forHTTPHeaderField: "Referer") == "https://provider.example/")
            #expect(request.value(forHTTPHeaderField: "X-Unsafe") == nil)
            return (
                temporaryDownload,
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
            )
        }
    )

    let record = try await store.makeAvailable(
        mediaID: "movie:headers",
        sourceURL: URL(string: "https://media.example/movie.mp4")!,
        requestHeaders: [
            "User-Agent": "Provider Player",
            "Referer": "https://provider.example/",
            "X-Unsafe": "must not leave the app",
        ]
    )

    #expect(FileManager.default.fileExists(atPath: record.localURL.path))
    #expect(try Data(contentsOf: record.localURL) == Data([4, 3, 2, 1]))
}

@Test func offlineDownloadPolicyUsesTheProtectedCapabilityWithoutForwardingHeaders() {
    let upstream = URL(string: "https://media.example/master.m3u8?token=secret")!
    let capability = URL(string: "http://127.0.0.1:32100/live/opaque/stream.m3u8")!
    let candidate = AppleStremioHTTPPlaybackCandidate(
        title: "Protected HLS",
        sourceURL: upstream,
        requestHeaders: ["Authorization": "Bearer secret"]
    )
    let resolved = AppleResolvedStremioPlayback(
        stream: candidate,
        preparedPlayback: ApplePreparedPlayback(
            route: .direct(capability),
            url: capability
        )
    )

    let plan = AppleOfflineDownloadPolicy.plan(for: resolved)
    #expect(plan.sourceURL == capability)
    #expect(plan.requestHeaders.isEmpty)
    #expect(plan.protectedCapabilityToRevoke == capability)

    let direct = AppleResolvedStremioPlayback(
        stream: AppleStremioHTTPPlaybackCandidate(title: "Direct", sourceURL: upstream),
        preparedPlayback: ApplePreparedPlayback(route: .direct(upstream), url: upstream)
    )
    let directPlan = AppleOfflineDownloadPolicy.plan(for: direct)
    #expect(directPlan.sourceURL == upstream)
    #expect(directPlan.protectedCapabilityToRevoke == nil)
}

@Test func offlineActionPolicyExcludesEveryLiveTVRoute() {
    #expect(!AppleOfflineActionPolicy.isAvailable(
        sourceKind: .liveTV,
        itemType: "movie",
        indexedKind: .movie,
        hasLiveAvailability: false
    ))
    #expect(!AppleOfflineActionPolicy.isAvailable(
        sourceKind: .stremio,
        itemType: "channel",
        indexedKind: .movie,
        hasLiveAvailability: false
    ))
    #expect(!AppleOfflineActionPolicy.isAvailable(
        sourceKind: .stremio,
        itemType: "movie",
        indexedKind: .channel,
        hasLiveAvailability: false
    ))
    #expect(!AppleOfflineActionPolicy.isAvailable(
        sourceKind: .stremio,
        itemType: "movie",
        indexedKind: .movie,
        hasLiveAvailability: true
    ))
    #expect(!AppleOfflineActionPolicy.isAvailable(
        sourceKind: .stremio,
        itemType: "linear",
        indexedKind: .movie,
        hasLiveAvailability: false
    ))
    #expect(!AppleOfflineActionPolicy.isAvailable(
        sourceKind: .stremio,
        itemType: "sports-event",
        indexedKind: nil,
        hasLiveAvailability: false
    ))
    #expect(AppleOfflineActionPolicy.isAvailable(
        sourceKind: .stremio,
        itemType: "series",
        indexedKind: .series,
        hasLiveAvailability: false
    ))
    #expect(AppleOfflineActionPolicy.isAvailable(
        sourceKind: .stremio,
        itemType: "movie",
        indexedKind: .movie,
        hasLiveAvailability: false
    ))
}

#if !os(tvOS)
@Test func appleOfflineStorePersistsSystemDownloadedHLSAssets() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "openstream-offline-hls-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let package = root.appending(path: "download.movpkg", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
    try Data([7, 8, 9]).write(to: package.appending(path: "segment.data"))

    let playlist = URL(string: "https://media.example/master.m3u8")!
    let store = AppleOfflineMediaStore(
        rootDirectory: root.appending(path: "library"),
        hlsDownloader: { url, title in
            #expect(url == playlist)
            #expect(title == "movie:hls")
            return package
        }
    )

    let record = try await store.makeAvailable(mediaID: "movie:hls", sourceURL: playlist)
    #expect(record.localURL == package)
    #expect(record.sourceExtension == "movpkg")
    #expect(await store.record(for: "movie:hls") == record)

    await #expect(throws: AppleOfflineStoreError.adaptiveStreamHeadersUnsupported) {
        try await store.makeAvailable(
            mediaID: "movie:protected-hls",
            sourceURL: playlist,
            requestHeaders: ["Authorization": "Bearer secret"]
        )
    }
}

@Test func appleOfflineStoreDetectsAnExtensionlessHLSManifestBeforePersistingIt() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "openstream-offline-extensionless-hls-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let downloadedManifest = root.appending(path: "response.data")
    try Data("\u{FEFF}\n#EXTM3U\n#EXT-X-VERSION:7\n".utf8).write(to: downloadedManifest)
    let package = root.appending(path: "download.movpkg", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
    try Data([1, 2, 3]).write(to: package.appending(path: "segment.data"))
    let extensionlessURL = URL(string: "https://media.example/play?id=123")!

    let store = AppleOfflineMediaStore(
        rootDirectory: root.appending(path: "library"),
        downloader: { request in
            #expect(request.url == extensionlessURL)
            return (
                downloadedManifest,
                HTTPURLResponse(
                    url: extensionlessURL,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
            )
        },
        hlsDownloader: { url, title in
            #expect(url == extensionlessURL)
            #expect(title == "movie:extensionless-hls")
            return package
        }
    )

    let record = try await store.makeAvailable(
        mediaID: "movie:extensionless-hls",
        sourceURL: extensionlessURL
    )
    #expect(record.localURL == package)
    #expect(record.sourceExtension == "movpkg")
    #expect(!FileManager.default.fileExists(atPath: downloadedManifest.path))
}
#endif

@Test func appleOfflineStoreRejectsHTTPErrorBodiesWithoutReplacingAnExistingDownload() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "openstream-offline-error-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let source = root.appending(path: "original.mp4")
    let originalBytes = Data([0, 1, 2, 3])
    try originalBytes.write(to: source)
    let library = root.appending(path: "library")
    let originalStore = AppleOfflineMediaStore(rootDirectory: library)
    let original = try await originalStore.makeAvailable(mediaID: "movie:replace", sourceURL: source)

    let rejectedBody = root.appending(path: "rejected-response.mp4")
    try Data("provider error".utf8).write(to: rejectedBody)
    let rejectingStore = AppleOfflineMediaStore(
        rootDirectory: library,
        downloader: { request in
            (
                rejectedBody,
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 403,
                    httpVersion: nil,
                    headerFields: nil
                )!
            )
        }
    )

    await #expect(throws: AppleOfflineStoreError.downloadRequestFailed(403)) {
        try await rejectingStore.makeAvailable(
            mediaID: "movie:replace",
            sourceURL: URL(string: "https://media.example/original.mp4")!
        )
    }

    #expect(try Data(contentsOf: original.localURL) == originalBytes)
    #expect(await rejectingStore.record(for: "movie:replace")?.localURL == original.localURL)
}

@Test func appleOfflineStoreAtomicallyReplacesAnExistingDownloadAfterValidation() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "openstream-offline-replace-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let originalSource = root.appending(path: "original.mp4")
    try Data([1, 1, 1]).write(to: originalSource)
    let library = root.appending(path: "library")
    let originalStore = AppleOfflineMediaStore(rootDirectory: library)
    let original = try await originalStore.makeAvailable(mediaID: "movie:replace-success", sourceURL: originalSource)

    let replacementSource = root.appending(path: "replacement.mp4")
    let replacementBytes = Data([2, 2, 2, 2])
    try replacementBytes.write(to: replacementSource)
    let replacementStore = AppleOfflineMediaStore(
        rootDirectory: library,
        downloader: { request in
            (
                replacementSource,
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
            )
        }
    )

    let replacement = try await replacementStore.makeAvailable(
        mediaID: "movie:replace-success",
        sourceURL: URL(string: "https://media.example/replacement.mp4")!
    )

    #expect(replacement.localURL == original.localURL)
    #expect(try Data(contentsOf: replacement.localURL) == replacementBytes)
    #expect(await replacementStore.record(for: "movie:replace-success")?.storedAt == replacement.storedAt)
}

@Test func appleOfflineStoreRejectsEmptyAndUnsupportedRemoteDownloads() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "openstream-offline-validation-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let emptyResponse = root.appending(path: "empty.mp4")
    try Data().write(to: emptyResponse)

    let store = AppleOfflineMediaStore(
        rootDirectory: root.appending(path: "library"),
        downloader: { request in
            (
                emptyResponse,
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
            )
        }
    )

    await #expect(throws: AppleOfflineStoreError.emptyDownloadedFile) {
        try await store.makeAvailable(
            mediaID: "movie:empty",
            sourceURL: URL(string: "https://media.example/empty.mp4")!
        )
    }
    await #expect(throws: AppleOfflineStoreError.unsupportedRemoteScheme) {
        try await store.makeAvailable(
            mediaID: "movie:rtsp",
            sourceURL: URL(string: "rtsp://media.example/live")!
        )
    }
}

@Test func completedOfflineMediaReplaysWithoutConsultingTheNetwork() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "openstream-offline-replay-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let source = root.appending(path: "source.mp4")
    let expected = Data([0, 0, 0, 20, 0x66, 0x74, 0x79, 0x70, 1, 2, 3, 4])
    try expected.write(to: source)
    let library = root.appending(path: "library", directoryHint: .isDirectory)
    let writer = AppleOfflineMediaStore(rootDirectory: library, allowedDirectories: [root])
    _ = try await writer.makeAvailable(mediaID: "movie:offline-replay", sourceURL: source)

    let offlineReader = AppleOfflineMediaStore(
        rootDirectory: library,
        allowedDirectories: [root],
        downloader: { _ in
            Issue.record("Completed offline replay must not consult the network")
            throw URLError(.notConnectedToInternet)
        }
    )
    let restored = try #require(await offlineReader.record(for: "movie:offline-replay"))
    #expect(restored.container == "mp4")
    #expect(try Data(contentsOf: restored.localURL) == expected)
}
