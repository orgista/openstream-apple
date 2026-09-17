import Foundation
import Testing
@testable import OpenStreamApple

@Suite("Apple TV playback presentation policy")
struct AppleTVPlaybackPolicyTests {
    private func request(_ url: String, filename: String? = nil, notWebReady: Bool = false, isLive: Bool = false) -> ApplePlaybackRequest {
        ApplePlaybackRequest(
            url: URL(string: url)!,
            isLive: isLive,
            mediaID: "tt0111161",
            sourceKind: .stremio,
            hints: ApplePlaybackRequest.Hints(notWebReady: notWebReady, filename: filename)
        )
    }

    @Test func nativeContainersUseTheAVPlayerEngineOnTV() {
        for url in ["https://cdn.example/movie.mp4", "https://cdn.example/movie.M4V", "https://cdn.example/clip.mov",
                    "https://live.example/stream.m3u8", "https://live.example/playlist?type=m3u8&x=1.m3u8"] {
            #expect(AppleTVPlaybackPresentationPolicy.engineKind(for: request(url), preferred: .openStream, isTV: true) == .native, "\(url)")
        }
    }

    @Test func demuxedContainersStayWithTheOpenStreamEngineOnTV() {
        for url in ["https://cdn.example/movie.mkv", "http://iptv.example/live/u/p/123.ts", "https://cdn.example/movie.avi",
                    "https://cdn.example/movie.webm", "https://cdn.example/stream/12345"] {
            #expect(AppleTVPlaybackPresentationPolicy.engineKind(for: request(url), preferred: .openStream, isTV: true) == .openStream, "\(url)")
        }
    }

    @Test func filenameHintWinsOverTheURL() {
        let hinted = request("https://debrid.example/dl/abc123", filename: "Movie.2024.1080p.mkv")
        #expect(AppleTVPlaybackPresentationPolicy.engineKind(for: hinted, preferred: .openStream, isTV: true) == .openStream)
        let mp4Hint = request("https://debrid.example/dl/abc123", filename: "Movie.2024.1080p.mp4")
        #expect(AppleTVPlaybackPresentationPolicy.engineKind(for: mp4Hint, preferred: .openStream, isTV: true) == .native)
        #expect(AppleTVPlaybackPresentationPolicy.containerExtension(url: URL(string: "https://x/y.mp4")!, filename: "z.mkv") == "mkv")
        #expect(AppleTVPlaybackPresentationPolicy.containerExtension(url: URL(string: "https://x/y")!, filename: nil) == nil)
    }

    @Test func notWebReadyStreamsKeepTheDemuxer() {
        let flagged = request("https://cdn.example/movie.mp4", notWebReady: true)
        #expect(AppleTVPlaybackPresentationPolicy.engineKind(for: flagged, preferred: .openStream, isTV: true) == .openStream)
    }

    @Test func viewerChoiceOfNativeEngineIsKept() {
        let mkv = request("https://cdn.example/movie.mkv")
        #expect(AppleTVPlaybackPresentationPolicy.engineKind(for: mkv, preferred: .native, isTV: true) == .native)
    }

    @Test func otherPlatformsAreUnchanged() {
        let mp4 = request("https://cdn.example/movie.mp4")
        #expect(AppleTVPlaybackPresentationPolicy.engineKind(for: mp4, preferred: .openStream, isTV: false) == .openStream)
        #expect(AppleTVPlaybackPresentationPolicy.engineKind(for: mp4, preferred: .native, isTV: false) == .native)
    }

    @Test func liveHLSChannelsUseTheStockPlayer() {
        let hls = request("https://iptv.example/live/abc/index.m3u8", isLive: true)
        #expect(AppleTVPlaybackPresentationPolicy.engineKind(for: hls, preferred: .openStream, isTV: true) == .native)
        let ts = request("https://iptv.example/live/abc/1.ts", isLive: true)
        #expect(AppleTVPlaybackPresentationPolicy.engineKind(for: ts, preferred: .openStream, isTV: true) == .openStream)
    }

    @Test func surfaceChromeOnTVIsScrubberAndCaptionsOnly() {
        let chrome = AppleTVPlaybackPresentationPolicy.surfaceChrome(isTV: true)
        #expect(!chrome.showsCloseButton)
        #expect(!chrome.showsSkipGlyphs)
        #expect(!chrome.showsPlayPauseGlyph)
        #expect(!chrome.showsMenus)
        #expect(chrome.scrubberHeight == 8)
        #expect(chrome.captionsControlCount == 1)
        #expect(chrome.menuClosesPlayer)
        #expect(chrome.selectTogglesPlayback)
        #expect(chrome.moveSkipSeconds == 10)
        #expect(chrome.hidesFocusDuringPlayback)
        #expect(chrome.spinnerOnBlackWhileLoading)
    }

    @Test func surfaceChromeElsewhereKeepsTheTouchControls() {
        let chrome = AppleTVPlaybackPresentationPolicy.surfaceChrome(isTV: false)
        #expect(chrome.showsCloseButton)
        #expect(chrome.showsSkipGlyphs)
        #expect(chrome.showsPlayPauseGlyph)
        #expect(chrome.showsMenus)
        #expect(chrome.scrubberHeight == 6)
        #expect(chrome.captionsControlCount == 1)
        #expect(!chrome.menuClosesPlayer)
        #expect(!chrome.selectTogglesPlayback)
        #expect(!chrome.hidesFocusDuringPlayback)
    }

    // MARK: - Route forecast (task 9, pure function cases)

    private typealias Policy = AppleTVPlaybackPresentationPolicy

    @Test func hevcAndH264InMP4ForecastTheAVPlayerRoute() {
        let hevc = Policy.StreamSignature(container: "mp4", videoCodec: "hevc", audioCodec: "aac")
        #expect(Policy.expectedRoute(for: hevc) == .avPlayer)
        let h264 = Policy.StreamSignature(container: "mp4", videoCodec: "h264", audioCodec: "aac")
        #expect(Policy.expectedRoute(for: h264) == .avPlayer)
        // Codec labels arrive in several spellings; the case is irrelevant.
        let fourCC = Policy.StreamSignature(container: "MP4", videoCodec: "HVC1", audioCodec: "mp4a")
        #expect(Policy.expectedRoute(for: fourCC) == .avPlayer)
        // E-AC-3 inside MP4 is AVFoundation's own container: still the stock player.
        let eac3InMP4 = Policy.StreamSignature(container: "mp4", videoCodec: "h264", audioCodec: "eac3")
        #expect(Policy.expectedRoute(for: eac3InMP4) == .avPlayer)
    }

    @Test func mkvWithEAC3NeedsTheSoftwareSurface() {
        let eac3 = Policy.StreamSignature(container: "mkv", videoCodec: "h264", audioCodec: "eac3")
        #expect(Policy.expectedRoute(for: eac3) == .surface)
        let hevcEAC3 = Policy.StreamSignature(container: "mkv", videoCodec: "hevc", audioCodec: "ec-3")
        #expect(Policy.expectedRoute(for: hevcEAC3) == .surface)
        let trueHD = Policy.StreamSignature(container: "mkv", videoCodec: "hevc", audioCodec: "truehd")
        #expect(Policy.expectedRoute(for: trueHD) == .surface)
        let vp9 = Policy.StreamSignature(container: "webm", videoCodec: "vp9", audioCodec: "opus")
        #expect(Policy.expectedRoute(for: vp9) == .surface)
        // A software video codec forces the surface even in MP4.
        let mpeg4InMP4 = Policy.StreamSignature(container: "mp4", videoCodec: "mp4v", audioCodec: "aac")
        #expect(Policy.expectedRoute(for: mpeg4InMP4) == .surface)
    }

    @Test func mkvWithPassthroughCodecsRemuxesToTheAVPlayerRoute() {
        let aac = Policy.StreamSignature(container: "mkv", videoCodec: "h264", audioCodec: "aac")
        #expect(Policy.expectedRoute(for: aac) == .avPlayer)
        let ac3 = Policy.StreamSignature(container: "mkv", videoCodec: "hevc", audioCodec: "ac3")
        #expect(Policy.expectedRoute(for: ac3) == .avPlayer)
        // Unknown codecs are forecast compatible; the engine's route event decides.
        let bare = Policy.StreamSignature(container: "mkv")
        #expect(Policy.expectedRoute(for: bare) == .avPlayer)
        let noContainer = Policy.StreamSignature(container: nil)
        #expect(Policy.expectedRoute(for: noContainer) == .avPlayer)
    }

    @Test func audioContainersForecastAudioOnly() {
        #expect(Policy.expectedRoute(for: Policy.StreamSignature(container: "mp3")) == .audioOnly)
        #expect(Policy.expectedRoute(for: Policy.StreamSignature(container: "m4a", audioCodec: "alac")) == .audioOnly)
    }

    @Test func signatureIsDerivedFromTheRequest() {
        let hinted = Policy.StreamSignature(request: request("https://debrid.example/dl/abc123", filename: "Movie.2024.2160p.mkv", notWebReady: true))
        #expect(hinted.container == "mkv")
        #expect(hinted.notWebReady)
        #expect(!hinted.isNativeContainer)
        let mp4 = Policy.StreamSignature(request: request("https://cdn.example/movie.mp4"), videoCodec: "HEVC")
        #expect(mp4.container == "mp4")
        #expect(mp4.videoCodec == "hevc")
        #expect(mp4.isNativeContainer)
    }

    @Test func engineChoiceFollowsTheRouteForecastOnTV() {
        // Stock player for a native container whose codecs AVFoundation decodes.
        let hevcMP4 = Policy.StreamSignature(container: "mp4", videoCodec: "hevc", audioCodec: "eac3")
        #expect(Policy.engineKind(for: hevcMP4, preferred: .openStream, isTV: true) == .native)
        // A native container with a software video codec keeps the demuxing engine.
        let mpeg4MP4 = Policy.StreamSignature(container: "mp4", videoCodec: "mp4v", audioCodec: "aac")
        #expect(Policy.engineKind(for: mpeg4MP4, preferred: .openStream, isTV: true) == .openStream)
        // Demuxed containers always need the OpenStream engine, whatever the forecast.
        let aacMKV = Policy.StreamSignature(container: "mkv", videoCodec: "h264", audioCodec: "aac")
        #expect(Policy.expectedRoute(for: aacMKV) == .avPlayer)
        #expect(Policy.engineKind(for: aacMKV, preferred: .openStream, isTV: true) == .openStream)
        // Off Apple TV the viewer's preference stands.
        #expect(Policy.engineKind(for: hevcMP4, preferred: .openStream, isTV: false) == .openStream)
    }

    // MARK: - Visible controls (task 9, pure helper)

    @Test func surfaceRouteOnTVShowsPlayPauseScrubberAndCaptionsOnly() {
        let controls = Policy.visibleControls(route: .surface, isTV: true, hasOtherSources: true, hasSharePlay: true)
        #expect(controls == [.playPause, .scrubber, .captions])
        #expect(!controls.contains(.close))
        #expect(!controls.contains(.skipBack))
        #expect(!controls.contains(.skipForward))
        #expect(!controls.contains(.otherSourcesMenu))
        #expect(!controls.contains(.sharePlayMenu))
        #expect(controls.filter { $0 == .captions }.count == 1)
    }

    @Test func surfaceRouteOnTVWithoutADurationDropsTheScrubber() {
        let live = Policy.visibleControls(route: .surface, isTV: true, isScrubbable: false)
        #expect(live == [.playPause, .captions])
    }

    @Test func otherRoutesDrawNoOverlayControls() {
        for route in ApplePlaybackPresentationRoute.allCases where route != .surface {
            #expect(Policy.visibleControls(route: route, isTV: true).isEmpty, "\(route)")
            #expect(Policy.visibleControls(route: route, isTV: false, hasOtherSources: true).isEmpty, "\(route)")
        }
    }

    @Test func surfaceRouteElsewhereKeepsTheTouchControlsInReadingOrder() {
        let full = Policy.visibleControls(route: .surface, isTV: false, hasOtherSources: true, hasSharePlay: true)
        #expect(full == [.close, .otherSourcesMenu, .sharePlayMenu, .skipBack, .playPause, .skipForward, .scrubber, .captions])
        let plain = Policy.visibleControls(route: .surface, isTV: false)
        #expect(plain == [.close, .skipBack, .playPause, .skipForward, .scrubber, .captions])
        #expect(plain.filter { $0 == .captions }.count == 1)
    }

    @Test func surfaceChromeAgreesWithTheVisibleControls() {
        for isTV in [true, false] {
            let chrome = Policy.surfaceChrome(isTV: isTV)
            let controls = Policy.visibleControls(route: .surface, isTV: isTV, hasOtherSources: true, hasSharePlay: true)
            #expect(chrome.showsCloseButton == controls.contains(.close), "isTV=\(isTV)")
            #expect(chrome.showsSkipGlyphs == controls.contains(.skipBack), "isTV=\(isTV)")
            #expect(chrome.showsMenus == controls.contains(.otherSourcesMenu), "isTV=\(isTV)")
            #expect(chrome.captionsControlCount == controls.filter { $0 == .captions }.count, "isTV=\(isTV)")
            #expect(controls.contains(.playPause), "isTV=\(isTV)")
        }
        // The glyph is drawn only where Select does not already toggle playback.
        #expect(Policy.surfaceChrome(isTV: true).showsPlayPauseGlyph == false)
        #expect(Policy.surfaceChrome(isTV: false).showsPlayPauseGlyph == true)
    }
}
