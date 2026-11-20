import Foundation
import Testing
@testable import OpenStreamApple

struct AetherLoadOptionsTests {
    /// Licence audit 2026-10-22: the device never encodes E-AC-3; audio
    /// that needs re-encoding is bridged as FLAC.
    @Test(arguments: [false, true])
    func bridgedAudioIsNeverEncodedAsEAC3(isLive: Bool) throws {
        let request = ApplePlaybackRequest(url: try #require(URL(string: "https://fixture.example/movie.mkv")),
                                           isLive: isLive, mediaID: "bridge", sourceKind: .mediaServer)
        #expect(AetherPlaybackEngine.loadOptions(for: request, headers: [:]).audioBridgeMode == .lossless)
    }

    @Test func liveRawTSRequestsUseFastZapJoin() throws {
        let request = ApplePlaybackRequest(
            url: try #require(URL(string: "https://fixture.example/live.ts")),
            isLive: true, mediaID: "live-ts", sourceKind: .iptv
        )
        let options = AetherPlaybackEngine.loadOptions(for: request, headers: [:])
        #expect(options.liveJoinProfile == .fastZap)
        #expect(options.isLive)
        #expect(options.nativeRemoteHLS == false)
    }

    @Test func liveHLSRequestsKeepStandardJoin() throws {
        // The routing hint also covers HLS served from extension-less URLs.
        let request = ApplePlaybackRequest(
            url: try #require(URL(string: "https://fixture.example/channel")),
            isLive: true, mediaID: "live-hls", sourceKind: .iptv,
            hints: .init(nativeRemoteHLS: true)
        )
        let options = AetherPlaybackEngine.loadOptions(for: request, headers: [:])
        #expect(options.liveJoinProfile == .standard)
        #expect(options.nativeRemoteHLS)
    }

    @Test(arguments: [false, true])
    func vodRequestsKeepStandardJoin(nativeRemoteHLS: Bool) throws {
        let request = ApplePlaybackRequest(
            url: try #require(URL(string: "https://fixture.example/movie.ts")),
            isLive: false, mediaID: "vod", sourceKind: .files,
            hints: .init(nativeRemoteHLS: nativeRemoteHLS)
        )
        let options = AetherPlaybackEngine.loadOptions(for: request, headers: [:])
        #expect(options.liveJoinProfile == .standard)
        #expect(options.isLive == false)
    }

    @Test(arguments: [[], ["fr"]])
    func loadOptionsPreservePlaybackAndCaptionPolicy(languages: [String]) throws {
        let request = ApplePlaybackRequest(
            url: try #require(URL(string: "https://fixture.example/live.ts")),
            headers: ["User-Agent": "original"], isLive: true,
            dvrWindowSeconds: 600, autoplay: false,
            mediaID: "live-ts", sourceKind: .iptv
        )
        // The caption proxy can replace the request headers before options are built.
        let options = AetherPlaybackEngine.loadOptions(
            for: request, headers: ["User-Agent": "resolved"],
            preferredSubtitleLanguages: languages, captionsPreference: .english
        )
        #expect(options.httpHeaders == ["User-Agent": "resolved"])
        #expect(options.dvrWindowSeconds == 600)
        #expect(options.autoplay == false)
        #expect(options.preferredDecodePath == .automatic)
        // Mac/iPhone: no renditions for AVKit's CC menu; the app's menu and
        // cue layer own captions (N38). Apple TV keeps them for AirPlay.
        #expect(options.prepareNativeSubtitles == AetherPlaybackEngine.declaresNativeSubtitleRenditions)
        #expect(AetherPlaybackEngine.declaresNativeSubtitleRenditions == false)
        #expect(options.preferredSubtitleLanguages == (languages.isEmpty ? ["eng", "en"] : languages))
    }

    /// Captions off: a chosen subtitle language must not make the demuxer
    /// auto-select at load (Apple TV verification 2026-10-01).
    @Test(arguments: [[], ["en"], ["es", "en"]])
    func captionsOffHandsTheDemuxerNoLanguages(languages: [String]) throws {
        let request = ApplePlaybackRequest(url: try #require(URL(string: "https://fixture.example/movie.mkv")),
                                           mediaID: "movie", sourceKind: .files)
        let options = AetherPlaybackEngine.loadOptions(
            for: request, headers: [:], preferredSubtitleLanguages: languages, captionsPreference: .off)
        #expect(options.preferredSubtitleLanguages.isEmpty)
    }
}
