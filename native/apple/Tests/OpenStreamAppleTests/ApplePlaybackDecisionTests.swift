import Testing
@testable import OpenStreamApple

struct ApplePlaybackDecisionTests {
    @Test func originalFirstEvenOnRemoteHighBitrate() {
        let descriptor = AppleStreamDescriptors(container: "mkv", videoCodec: "hevc", videoLevel: 5.2,
            dolbyVisionProfile: 7, audioCodec: "truehd", subtitleCodec: "pgs", bitrate: 60_000_000)
        let result = ApplePlaybackDecision.decide(descriptor, remote: true)
        #expect(result.video == .originalBytes)
        #expect(result.audio == .localDecode("truehd"))
        #expect(result.subtitle == .embedded)
        #expect(result.reasons.contains(.containerNotNative))
        #expect(result.reasons.contains(.videoLevelAboveHardware(5.2)))
        #expect(result.reasons.contains(.dolbyVisionProfileUnsupported(7)))
        #expect(result.reasons.contains(.bitrateAboveRouteLimit) == false)
    }
    @Test func matroskaOriginalKeepsNativeAudioAndEmbeddedSubtitles() {
        let decision = ApplePlaybackDecision.decide(.init(container: "mkv", videoCodec: "h264", audioCodec: "aac", subtitleCodec: "pgs"))
        #expect(decision.video == .originalBytes)
        #expect(decision.audio == .passthrough)
        #expect(decision.subtitle == .embedded)
        #expect(decision.reasons == [.containerNotNative])
        let dv = ApplePlaybackDecision.decide(.init(container: "mp4", videoCodec: "hevc", dolbyVisionProfile: 7))
        #expect(dv.video == .originalBytes)
        #expect(dv.reasons == [.dolbyVisionProfileUnsupported(7)])
    }

    @Test func localHighLevelIsSoftwareAndNativeAudioPassesThrough() {
        let decision = ApplePlaybackDecision.decide(.init(container: "mp4", videoCodec: "hevc", videoLevel: 5.2, audioCodec: "aac"))
        #expect(decision.video == .localSoftwareDecode)
        #expect(decision.audio == .passthrough)
    }
    @Test func serverOnlyConversionAndFallbackAreBounded() {
        let direct = AppleMediaServerPlaybackInfo.MediaSource(id: "original", supportsDirectPlay: true)
        let converted = AppleMediaServerPlaybackInfo.MediaSource(id: "converted", transcodingURLPath: "/stream.m3u8")
        #expect(AppleJellyfinPlaybackPolicy.select([converted, direct], failed: [])?.id == "original")
        #expect(AppleJellyfinPlaybackPolicy.route(for: converted, afterFailure: false) == .conversion)
        #expect(AppleJellyfinPlaybackPolicy.route(for: converted, afterFailure: true) == .conversion)
        #expect(AppleJellyfinPlaybackPolicy.conversionDecision(for: converted).video == .serverTranscode)
        #expect(ApplePlaybackFallbackPolicy.next(triedConversion: false, nextVersionAvailable: true) == .conversion)
        #expect(ApplePlaybackFallbackPolicy.next(triedConversion: true, nextVersionAvailable: true) == .nextVersion)
        #expect(ApplePlaybackFallbackPolicy.next(triedConversion: true, nextVersionAvailable: false) == .unavailable)
    }
    @Test func observedMismatchIsDiagnosticOnly() {
        let decision = ApplePlaybackDecision.decide(.init(container: "mp4", videoCodec: "h264", audioCodec: "aac"))
        #expect(decision.mismatch(observedSoftwareDecode: true))
        #expect(decision.video == .originalBytes)
    }
}

import Foundation

struct AppleJellyfinNegotiationTests {
    @Test func sourceDescriptorsDecodeAndAudioConversionCopiesVideo() throws {
        let data = Data(#"{"Id":"v1","Container":"mkv","Size":"59989628115","RunTimeTicks":60000000000,"Bitrate":60000000,"SupportsTranscoding":true,"TranscodingUrl":"/Videos/item/master.m3u8?VideoCodec=h264","MediaStreams":[{"Type":"Video","Codec":"hevc","Level":153,"Height":2160,"VideoRangeType":"HDR10"},{"Type":"Audio","Codec":"truehd","Index":2,"Channels":8,"Profile":"Dolby Atmos"}]}"#.utf8)
        let source = try JSONDecoder().decode(AppleMediaServerPlaybackInfo.MediaSource.self, from: data)
        #expect(source.size == 59_989_628_115)
        #expect(try JSONDecoder().decode(AppleMediaServerPlaybackInfo.MediaSource.self, from: JSONEncoder().encode(source)).size == source.size)
        #expect(source.descriptors.videoLevel == 5.1)
        #expect(source.descriptors.duration == 6000)
        #expect(source.formatBadges.contains(.uhd))
        #expect(source.formatBadges.contains(.hdr10))
        #expect(source.formatBadges.contains(.surround71))
        #expect(AppleJellyfinPlaybackPolicy.isAudioOnlyMismatch(source))
        let decision = AppleJellyfinPlaybackPolicy.conversionDecision(for: source)
        #expect(decision.video == .originalBytes)
        #expect(decision.audio == .serverTranscode)
        let session = AppleMediaServerSession(kind: .jellyfin, baseURL: URL(string: "https://fixture.example/")!, accessToken: "fixture", userID: "viewer")
        let url = try AppleJellyfinPlaybackPolicy.conversionURL(source.transcodingURLPath!, session: session, audioStreamIndex: 2, audioOnly: true, videoCodec: source.descriptors.videoCodec)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.contains(URLQueryItem(name: "AllowVideoStreamCopy", value: "true")))
        #expect(query.contains(URLQueryItem(name: "VideoCodec", value: "hevc")))
        #expect(query.contains(URLQueryItem(name: "VideoCodec", value: "h264")) == false)
        #expect(query.contains(URLQueryItem(name: "AllowAudioStreamCopy", value: "false")))
        #expect(query.contains(URLQueryItem(name: "AudioStreamIndex", value: "2")))
        #expect(throws: AppleMediaServerError.unsupported) {
            try AppleJellyfinPlaybackPolicy.conversionURL("https://other.example/stream", session: session)
        }
    }

    @Test func serverOrderWinsAndExplicitVersionStillWins() {
        let low = AppleMediaServerPlaybackInfo.MediaSource(id: "low", supportsDirectPlay: true, name: "1080p")
        let high = AppleMediaServerPlaybackInfo.MediaSource(id: "high", supportsDirectPlay: true, name: "2160p")
        #expect(AppleJellyfinPlaybackPolicy.select([low, high], failed: [])?.id == "low")
        #expect(AppleJellyfinPlaybackPolicy.select([low, high], failed: [], preferred: "high")?.id == "high")
        #expect(AppleJellyfinPlaybackPolicy.select([low, high], failed: ["high"])?.id == "low")
        #expect(AppleJellyfinPlaybackPolicy.select([low, high], failed: ["low", "high"]) == nil)
    }

    @Test func automaticSelectionSkipsVideoBeyondNativeCapabilities() {
        var oversized = AppleMediaServerPlaybackInfo.MediaSource(id: "8k", supportsDirectPlay: true)
        oversized.mediaStreams = [.init(type: "Video", codec: "hevc", level: 186, width: 7680, height: 4320)]
        var highLevel = AppleMediaServerPlaybackInfo.MediaSource(id: "high-level", supportsDirectPlay: true)
        highLevel.mediaStreams = [.init(type: "Video", codec: "hevc", level: 186, width: 3840, height: 2160)]
        var software = AppleMediaServerPlaybackInfo.MediaSource(id: "software", supportsDirectPlay: true)
        software.mediaStreams = [.init(type: "Video", codec: "vp9", width: 3840, height: 2160)]
        var prepared = AppleMediaServerPlaybackInfo.MediaSource(id: "prepared", supportsDirectPlay: true)
        prepared.mediaStreams = [.init(type: "Video", codec: "h264", width: 1920, height: 1080)]
        let sources = [oversized, highLevel, software, prepared]
        #expect(AppleJellyfinPlaybackPolicy.select(sources, failed: [])?.id == "prepared")
        #expect(AppleJellyfinPlaybackPolicy.ranked(sources, failed: []).map(\.id) == ["prepared"])
        #expect(AppleJellyfinPlaybackPolicy.select(sources, failed: ["prepared"]) == nil)
        #expect(AppleJellyfinPlaybackPolicy.select(sources, failed: [], preferred: "8k")?.id == "8k")
    }

    @Test func unknownDimensionsStillRespectAn8KReleaseLabel() {
        let oversized = AppleMediaServerPlaybackInfo.MediaSource(id: "8k", supportsDirectPlay: true, name: "Movie 8K HEVC")
        let prepared = AppleMediaServerPlaybackInfo.MediaSource(id: "prepared", supportsDirectPlay: true, name: "Movie 1080p H264")
        #expect(AppleJellyfinPlaybackPolicy.select([oversized, prepared], failed: [])?.id == "prepared")
    }

    @Test func an8KLabelCannotBeHiddenByContradictory1080pDescriptors() {
        var oversized = AppleMediaServerPlaybackInfo.MediaSource(id: "8k", supportsDirectPlay: true, name: "Movie 8K")
        oversized.mediaStreams = [.init(type: "Video", codec: "h264", width: 1920, height: 1080)]
        let prepared = AppleMediaServerPlaybackInfo.MediaSource(id: "prepared", supportsDirectPlay: true, name: "Movie 1080p")
        #expect(AppleJellyfinPlaybackPolicy.select([oversized, prepared], failed: [], defaultMediaSourceID: "8k")?.id == "prepared")
    }

    @Test func serverDefaultIsUsedOnlyWhenNativelyPlayableAndUnfailed() throws {
        let data = Data(#"{"DefaultMediaSourceId":"default","MediaSources":[{"Id":"first","SupportsDirectPlay":true},{"Id":"default","SupportsDirectPlay":true}]}"#.utf8)
        let info = try JSONDecoder().decode(AppleMediaServerPlaybackInfo.self, from: data)
        #expect(info.defaultMediaSourceID == "default")
        #expect(AppleJellyfinPlaybackPolicy.select(info.mediaSources, failed: [], defaultMediaSourceID: info.defaultMediaSourceID)?.id == "default")
        #expect(AppleJellyfinPlaybackPolicy.select(info.mediaSources, failed: ["default"], defaultMediaSourceID: info.defaultMediaSourceID)?.id == "first")
        #expect(AppleJellyfinPlaybackPolicy.select(info.mediaSources, failed: [], defaultMediaSourceID: "absent")?.id == "first")
        #expect(try JSONDecoder().decode(AppleMediaServerPlaybackInfo.self, from: JSONEncoder().encode(info)) == info)
    }

    @Test func hardwareCapabilityAndCodecAliasesControlAutomaticSelection() {
        var hevc = AppleMediaServerPlaybackInfo.MediaSource(id: "hevc", supportsDirectPlay: true)
        hevc.mediaStreams = [.init(type: "Video", codec: "h265", level: 153, width: 3840, height: 2160)]
        var h264 = AppleMediaServerPlaybackInfo.MediaSource(id: "h264", supportsDirectPlay: true)
        h264.mediaStreams = [.init(type: "Video", codec: "avc1", level: 41, width: 1920, height: 1080)]
        #expect(hevc.descriptors.videoLevel == 5.1)
        var capabilities = AppleDeviceCapabilities()
        #expect(AppleJellyfinPlaybackPolicy.select([hevc, h264], failed: [], capabilities: capabilities)?.id == "hevc")
        capabilities.nativeVideoCodecs.remove("hevc")
        #expect(AppleJellyfinPlaybackPolicy.select([hevc, h264], failed: [], defaultMediaSourceID: "hevc", capabilities: capabilities)?.id == "h264")
    }

    @Test func oversizedVideoRequiresVideoConversionEvenWithAnAudioMismatch() {
        var source = AppleMediaServerPlaybackInfo.MediaSource(id: "8k", supportsDirectPlay: true, transcodingURLPath: "/Videos/movie/master.m3u8")
        source.mediaStreams = [.init(type: "Video", codec: "hevc", width: 7680, height: 4320), .init(type: "Audio", codec: "truehd")]
        #expect(AppleJellyfinPlaybackPolicy.route(for: source, afterFailure: false) == .conversion)
        #expect(!AppleJellyfinPlaybackPolicy.isAudioOnlyMismatch(source))
        #expect(AppleJellyfinPlaybackPolicy.conversionDecision(for: source).video == .serverTranscode)
    }

    @Test func explicitVersionIsIncludedInPlaybackInfoNegotiation() async throws {
        let session = AppleMediaServerSession(kind: .jellyfin, baseURL: URL(string: "https://fixture.example/")!, accessToken: "fixture", userID: "viewer")
        let client = AppleMediaServerClient(loader: { request in
            let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
            #expect(body["MediaSourceId"] as? String == "manual")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            #expect(query.contains(URLQueryItem(name: "MediaSourceId", value: "manual")))
            return (Data(#"{"MediaSources":[]}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, deviceID: "fixture")
        _ = try await client.playbackInfo(session: session, itemID: "movie", mediaSourceID: "manual")
    }
}
