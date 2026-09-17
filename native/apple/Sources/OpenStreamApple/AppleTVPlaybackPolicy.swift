import CoreGraphics
import Foundation

/// Apple TV player policy (rework plan task 9). Pure decisions only:
///
/// 1. Which presentation route a stream is expected to take
///    (`expectedRoute(for:)`), from its container and codecs. The engine
///    itself chooses the route at load time (`AetherPlaybackEngine` maps
///    loopback/bypass to `.avPlayer` and software decode to `.surface`) and
///    the coordinator mirrors that; this function is the host's forecast.
/// 2. Which engine a presentation should build (`engineKind(for:preferred:)`).
///    The host can only steer the route by handing containers AVFoundation
///    plays on its own to the AVPlayer-only `NativePlaybackEngine`, so on
///    Apple TV the stock player is used whenever the container allows it.
/// 3. Which controls the software-surface overlay draws when that route is
///    unavoidable (`visibleControls(route:isTV:)`), plus the metrics of that
///    chrome (`surfaceChrome(isTV:)`).
public enum AppleTVPlaybackPresentationPolicy {
    public static var isTVPlatform: Bool {
        #if os(tvOS)
        true
        #else
        false
        #endif
    }

    // MARK: - Containers and codecs

    /// Containers AVFoundation demuxes itself: HLS playlists, MPEG-4 family
    /// and plain audio. Matroska, MPEG-TS, AVI and WebM stay with the
    /// demuxing engine.
    public static let nativeContainers: Set<String> = [
        "m3u8", "m3u", "mp4", "m4v", "mov", "qt", "mp3", "m4a", "aac", "wav", "aif", "aiff", "caf",
    ]

    /// Video codecs the Apple TV decodes in hardware, so a remux to loopback
    /// HLS (or the container itself) plays in `AVPlayer`. Anything else
    /// (VP9, AV1 on older hardware, MPEG-2, MPEG-4 part 2, VC-1) is decoded
    /// in software onto the surface.
    public static let nativeVideoCodecs: Set<String> = [
        "h264", "avc", "avc1", "avc3", "x264",
        "hevc", "h265", "hvc1", "hev1", "x265", "dvhe", "dvh1",
    ]

    /// Audio codecs the loopback remux passes through to `AVPlayer` as is.
    /// E-AC-3, TrueHD, DTS, FLAC, Opus, Vorbis and PCM tracks inside a
    /// demuxed container are decoded in software, which forces the surface
    /// route for the whole stream.
    public static let loopbackAudioCodecs: Set<String> = [
        "aac", "mp4a", "aac-lc", "he-aac", "ac3", "ac-3", "a52", "mp3", "mp2", "mpga",
    ]

    /// Audio codecs AVFoundation decodes when the container is its own
    /// (MP4/MOV/HLS): the loopback set plus the codecs it handles natively in
    /// those containers.
    public static let nativeContainerAudioCodecs: Set<String> = loopbackAudioCodecs.union([
        "eac3", "ec-3", "ec3", "e-ac-3", "alac", "flac", "lpcm", "pcm",
    ])

    /// What is known about a stream before it loads. Codecs are `nil` when
    /// the source did not say (a bare URL); the container is the lower-cased
    /// extension, `nil` when neither the filename hint nor the URL carry one.
    public struct StreamSignature: Equatable, Sendable {
        public var container: String?
        public var videoCodec: String?
        public var audioCodec: String?
        public var notWebReady: Bool

        public init(container: String?, videoCodec: String? = nil, audioCodec: String? = nil, notWebReady: Bool = false) {
            self.container = container?.lowercased()
            self.videoCodec = videoCodec?.lowercased()
            self.audioCodec = audioCodec?.lowercased()
            self.notWebReady = notWebReady
        }

        public init(request: ApplePlaybackRequest, videoCodec: String? = nil, audioCodec: String? = nil) {
            self.init(
                container: AppleTVPlaybackPresentationPolicy.containerExtension(url: request.url, filename: request.hints.filename),
                videoCodec: videoCodec,
                audioCodec: audioCodec,
                notWebReady: request.hints.notWebReady
            )
        }

        public var isNativeContainer: Bool {
            guard let container else { return false }
            return AppleTVPlaybackPresentationPolicy.nativeContainers.contains(container)
        }
    }

    // MARK: - Route forecast

    /// The presentation route a stream is expected to take. `.avPlayer` when
    /// the container plays in AVFoundation or the engine can remux it to
    /// loopback HLS without decoding; `.surface` when a codec needs the
    /// software decoder; `.audioOnly` for audio containers.
    ///
    /// A `nil` codec is treated as compatible: the container alone decides,
    /// and the engine's runtime `.route` event corrects the forecast.
    public static func expectedRoute(for signature: StreamSignature) -> ApplePlaybackPresentationRoute {
        if let container = signature.container, audioOnlyContainers.contains(container) {
            return .audioOnly
        }
        let videoNative = signature.videoCodec.map { nativeVideoCodecs.contains($0) } ?? true
        if signature.isNativeContainer, !signature.notWebReady {
            let audioNative = signature.audioCodec.map { nativeContainerAudioCodecs.contains($0) } ?? true
            return videoNative && audioNative ? .avPlayer : .surface
        }
        // Demuxed containers (MKV, TS, AVI, WebM, unknown): loopback needs
        // both tracks to pass through untouched.
        let audioPassthrough = signature.audioCodec.map { loopbackAudioCodecs.contains($0) } ?? true
        return videoNative && audioPassthrough ? .avPlayer : .surface
    }

    static let audioOnlyContainers: Set<String> = ["mp3", "m4a", "aac", "wav", "aif", "aiff", "caf"]

    // MARK: - Engine choice

    /// The engine to build for `request`. Off Apple TV, or when the viewer
    /// already asked for the native engine, the preference is returned as is.
    /// On Apple TV a container AVFoundation demuxes itself, whose known codecs
    /// forecast `.avPlayer`, builds the AVPlayer-only engine so the stock
    /// player is used without the loopback hop.
    public static func engineKind(
        for request: ApplePlaybackRequest,
        preferred: ApplePlaybackEngineKind,
        isTV: Bool = isTVPlatform
    ) -> ApplePlaybackEngineKind {
        engineKind(for: StreamSignature(request: request), preferred: preferred, isTV: isTV)
    }

    public static func engineKind(
        for signature: StreamSignature,
        preferred: ApplePlaybackEngineKind,
        isTV: Bool = isTVPlatform
    ) -> ApplePlaybackEngineKind {
        guard isTV, preferred == .openStream else { return preferred }
        // An add-on that flags the stream as not web-ready expects a demuxer.
        guard !signature.notWebReady, signature.isNativeContainer else { return .openStream }
        switch expectedRoute(for: signature) {
        case .avPlayer, .audioOnly: return .native
        case .surface, .none: return .openStream
        }
    }

    public static func isNativelyPlayableContainer(url: URL, filename: String?) -> Bool {
        guard let container = containerExtension(url: url, filename: filename) else { return false }
        return nativeContainers.contains(container)
    }

    /// The filename hint wins over the URL; an HLS playlist hidden behind a
    /// query string or an extension-less path is still recognised.
    static func containerExtension(url: URL, filename: String?) -> String? {
        if let filename, !filename.isEmpty {
            let hinted = URL(fileURLWithPath: filename).pathExtension.lowercased()
            if !hinted.isEmpty { return hinted }
        }
        let fromURL = url.pathExtension.lowercased()
        if !fromURL.isEmpty { return fromURL }
        if url.absoluteString.lowercased().contains(".m3u8") { return "m3u8" }
        return nil
    }

    // MARK: - Surface overlay controls

    /// Every control the software-surface overlay can draw. Order is the
    /// reading order of the overlay: top bar, centre row, bottom bar.
    public enum SurfaceControl: String, CaseIterable, Equatable, Sendable {
        case close
        case otherSourcesMenu
        case sharePlayMenu
        case skipBack
        /// On Apple TV this is the surface itself: Select and the remote's
        /// Play/Pause button toggle playback and no glyph is drawn. Elsewhere
        /// it is the centred play/pause glyph.
        case playPause
        case skipForward
        case scrubber
        case captions
    }

    /// The controls the overlay draws for `route`. The overlay exists only on
    /// the software surface, so every other route returns nothing. On Apple
    /// TV the surface route keeps Play/Pause (remote button and Select), the
    /// scrubber and the one captions control; the remote's Menu button closes
    /// the player and the clickpad edges skip, so no close button, skip
    /// glyphs or menus are drawn.
    public static func visibleControls(
        route: ApplePlaybackPresentationRoute,
        isTV: Bool = isTVPlatform,
        isScrubbable: Bool = true,
        hasOtherSources: Bool = false,
        hasSharePlay: Bool = false
    ) -> [SurfaceControl] {
        guard route == .surface else { return [] }
        var controls: [SurfaceControl] = []
        if isTV {
            controls.append(.playPause)
            if isScrubbable { controls.append(.scrubber) }
            controls.append(.captions)
            return controls
        }
        controls.append(.close)
        if hasOtherSources { controls.append(.otherSourcesMenu) }
        if hasSharePlay { controls.append(.sharePlayMenu) }
        controls.append(contentsOf: [.skipBack, .playPause, .skipForward])
        if isScrubbable { controls.append(.scrubber) }
        controls.append(.captions)
        return controls
    }

    /// What the software-surface overlay shows.
    public struct SurfaceChrome: Equatable, Sendable {
        public var showsCloseButton: Bool
        public var showsSkipGlyphs: Bool
        public var showsPlayPauseGlyph: Bool
        public var showsMenus: Bool
        public var scrubberHeight: CGFloat
        public var captionsControlCount: Int
        public var menuClosesPlayer: Bool
        public var selectTogglesPlayback: Bool
        public var moveSkipSeconds: Double
        public var hidesFocusDuringPlayback: Bool
        public var spinnerOnBlackWhileLoading: Bool
    }

    /// On Apple TV the overlay keeps only an 8 pt scrubber and one captions
    /// control: Play/Pause and the clickpad drive playback, Menu closes, and
    /// left/right skip ten seconds. Elsewhere the touch chrome is unchanged.
    public static func surfaceChrome(isTV: Bool = isTVPlatform) -> SurfaceChrome {
        let controls = visibleControls(route: .surface, isTV: isTV, hasOtherSources: true, hasSharePlay: true)
        if isTV {
            return SurfaceChrome(
                showsCloseButton: controls.contains(.close),
                showsSkipGlyphs: controls.contains(.skipBack),
                showsPlayPauseGlyph: false,
                showsMenus: controls.contains(.otherSourcesMenu),
                scrubberHeight: 8,
                captionsControlCount: controls.filter { $0 == .captions }.count,
                menuClosesPlayer: true,
                selectTogglesPlayback: true,
                moveSkipSeconds: 10,
                hidesFocusDuringPlayback: true,
                spinnerOnBlackWhileLoading: true
            )
        }
        return SurfaceChrome(
            showsCloseButton: controls.contains(.close),
            showsSkipGlyphs: controls.contains(.skipBack),
            showsPlayPauseGlyph: controls.contains(.playPause),
            showsMenus: controls.contains(.otherSourcesMenu),
            scrubberHeight: 6,
            captionsControlCount: controls.filter { $0 == .captions }.count,
            menuClosesPlayer: false,
            selectTogglesPlayback: false,
            moveSkipSeconds: 10,
            hidesFocusDuringPlayback: false,
            spinnerOnBlackWhileLoading: true
        )
    }
}
