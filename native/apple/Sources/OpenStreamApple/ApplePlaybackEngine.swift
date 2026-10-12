import AVFoundation
import CoreGraphics
import Foundation

public enum ApplePlaybackEnginePhase: Equatable, Sendable {
    case idle
    case loading
    case playing
    case paused
    case seeking
    case rebuffering
    case stalled(reconnecting: Bool)
    case ended
    case error(String)
}

public enum ApplePlaybackPresentationRoute: String, Equatable, Sendable, CaseIterable {
    case none
    case avPlayer
    case surface
    case audioOnly
}

public struct ApplePlaybackTrack: Identifiable, Equatable, Sendable {
    public let id: Int
    public let title: String
    public let language: String?
    public let codec: String?
    public let isDefault: Bool
    /// Container disposition FORCED: every cue on the track is a forced one
    /// (signs, foreign dialogue). Carried as data; drawn like any cue.
    public let isForced: Bool
    /// Container disposition HEARING_IMPAIRED (or the SDH characteristic):
    /// the captions menu names it "English (SDH)" beside a plain English.
    public let isHearingImpaired: Bool
    /// Audio only: 2 = stereo, 6 = 5.1, 8 = 7.1; 0 when unknown.
    public let channels: Int
    /// Container disposition COMMENT (director or cast commentary).
    public let isCommentary: Bool
    /// Dolby Atmos (E-AC-3 JOC or TrueHD Atmos).
    public let isAtmos: Bool

    public init(id: Int, title: String, language: String? = nil, codec: String? = nil,
                isDefault: Bool = false, isForced: Bool = false, isHearingImpaired: Bool = false,
                channels: Int = 0, isCommentary: Bool = false, isAtmos: Bool = false) {
        self.id = id
        self.title = title
        self.language = language
        self.codec = codec
        self.isDefault = isDefault
        self.isForced = isForced
        self.isHearingImpaired = isHearingImpaired
        self.channels = channels
        self.isCommentary = isCommentary
        self.isAtmos = isAtmos
    }
}

/// One contiguous same-styling span of a rich-text subtitle cue, bridged from
/// the engine's `SubtitleTextRun`. Plain values only; the overlay applies the
/// host's font and foreground preference when a run leaves them default.
public struct AppleSubtitleTextRun: Sendable, Equatable {
    public let text: String
    public let isBold: Bool
    public let isItalic: Bool
    public let isUnderlined: Bool
    public let isStruckThrough: Bool

    public init(text: String, isBold: Bool = false, isItalic: Bool = false,
                isUnderlined: Bool = false, isStruckThrough: Bool = false) {
        self.text = text
        self.isBold = isBold
        self.isItalic = isItalic
        self.isUnderlined = isUnderlined
        self.isStruckThrough = isStruckThrough
    }
}

/// One decoded bitmap subtitle object (PGS/DVB), bridged from the engine's
/// `SubtitleImage` with the geometry the disc authored. A PGS composition
/// arrives as one cue per object, so a sign and a line of dialogue on screen
/// together are two of these.
public struct AppleSubtitleBitmap {
    public let image: CGImage
    /// The object's rect, normalized to `canvasSize` ([0, 1], top-left origin).
    public let rect: CGRect
    /// The composition canvas `rect` is normalized against (e.g. 1920×1080).
    /// `.zero` when unknown: the canvas is then taken to be the picture.
    public let canvasSize: CGSize
    /// AV_SUBTITLE_FLAG_FORCED. Carried as data; drawn like any cue.
    public let isForced: Bool

    public init(image: CGImage, rect: CGRect, canvasSize: CGSize = .zero, isForced: Bool = false) {
        self.image = image
        self.rect = rect
        self.canvasSize = canvasSize
        self.isForced = isForced
    }
}

extension AppleSubtitleBitmap: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        // CGImage has no value equality; identity is the practical signal
        // that the decoded bitmap is unchanged.
        lhs.image === rhs.image && lhs.rect == rhs.rect
            && lhs.canvasSize == rhs.canvasSize && lhs.isForced == rhs.isForced
    }
}

/// The payload of a subtitle cue, mirroring the engine's `SubtitleCue.Body`:
/// plain `.text`, styled `.richText`, or a rendered `.image` bitmap (PGS/DVB).
public enum AppleSubtitleCueBody {
    case text(String)
    case richText([AppleSubtitleTextRun])
    case image(AppleSubtitleBitmap)
}

extension AppleSubtitleCueBody: Equatable {
    public static func == (lhs: AppleSubtitleCueBody, rhs: AppleSubtitleCueBody) -> Bool {
        switch (lhs, rhs) {
        case (.text(let a), .text(let b)):
            return a == b
        case (.richText(let a), .richText(let b)):
            return a == b
        case (.image(let a), .image(let b)):
            return a == b
        default:
            return false
        }
    }
}

/// One decoded subtitle cue bridged from the engine. `startTime`/`endTime` are
/// source-PTS seconds; the app draws the cue active at the current position
/// (`AppleSubtitleCueLayer`).
public struct AppleSubtitleCue: Identifiable, Equatable {
    public let id: Int
    public let startTime: Double
    public let endTime: Double
    public let body: AppleSubtitleCueBody

    public init(id: Int, startTime: Double, endTime: Double, body: AppleSubtitleCueBody) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.body = body
    }

    /// Plain text for `.text` and `.richText` (runs concatenated); nil for `.image`.
    public var text: String? {
        switch body {
        case .text(let s): return s
        case .richText(let runs): return runs.map(\.text).joined()
        case .image: return nil
        }
    }

    /// True for a bitmap object the disc flagged forced. Text cues carry no
    /// flag of their own; a forced *track* is handled by its disposition.
    public var isForced: Bool {
        if case .image(let bitmap) = body { return bitmap.isForced }
        return false
    }
}

public enum ApplePlaybackEngineEvent: Equatable, Sendable {
    case phase(ApplePlaybackEnginePhase)
    case route(ApplePlaybackPresentationRoute)
    case position(Double)
    case duration(Double?)
    case tracks
    case failure(ApplePlaybackFailure?)
}

public enum ApplePlaybackEngineKind: String, CaseIterable, Sendable {
    case openStream = "engine"
    case native = "native"
}

@MainActor
public protocol ApplePlaybackEngine: AnyObject {
    var kind: ApplePlaybackEngineKind { get }
    var phase: ApplePlaybackEnginePhase { get }
    var route: ApplePlaybackPresentationRoute { get }
    var position: Double { get }
    /// The source time of the frame on screen, the clock subtitle cues are
    /// paced from. `position` is the scrub clock: the OpenStream engine holds
    /// it through live rebases and seek recovery while the picture keeps
    /// moving, so live captions drawn against it lagged the picture. Engines
    /// without a separate presentation clock report `position`.
    var presentationTime: Double { get }
    var duration: Double? { get }
    var audioTracks: [ApplePlaybackTrack] { get }
    var subtitleTracks: [ApplePlaybackTrack] { get }
    /// The subtitle track the engine is rendering right now, or nil for none.
    ///
    /// The overlay keeps its own record of what the viewer picked, but that
    /// record starts empty — and the engine auto-selects a track at load when
    /// the viewer's captions preference asks for one. Without this the CC key
    /// would read "off" over a picture with captions on it.
    var activeSubtitleTrackID: Int? { get }
    /// The audio track playing. A requirement, not only an extension
    /// default: as a default alone, every read through `any
    /// ApplePlaybackEngine` was the default's nil, so the audio menu checked
    /// the file's default track whatever was playing (Apple TV verification
    /// 2026-10-01).
    var activeAudioTrackID: Int? { get }
    /// The picture's pixel dimensions once known, for laying out anything that
    /// has to sit against the video rather than the screen — subtitles, above
    /// all. Nil while unknown, and on routes that cannot report it; callers
    /// fall back to `AppleVideoFitting.assumedAspect`.
    var videoSize: CGSize? { get }
    var outputInfo: ApplePlaybackOutputInfo { get }
    /// Decoded cues for the active subtitle track, for the app to draw: the
    /// transport overlay on `.surface`, `AppleStockPlayerCueLayer` over the
    /// stock player on `.avPlayer`. The native engine leaves it empty; AVKit
    /// renders its tracks.
    var subtitleCues: [AppleSubtitleCue] { get }
    /// The stream's own chapter markers (Matroska chapters, MPEG-4 chapter
    /// tracks), for Skip Intro. Empty when the file carries none.
    var chapters: [AppleChapter] { get }
    var failure: ApplePlaybackFailure? { get }
    /// Non-nil only on `.avPlayer` routes.
    var avPlayer: AVPlayer? { get }
    /// The span the stream can actually be seeked within, on the same axis as
    /// `position`. Nil when the engine has nothing to report — no item loaded,
    /// or a live source with no rewind at all.
    ///
    /// Read from the player, never from `ApplePlaybackRequest.dvrWindowSeconds`:
    /// that number is a load hint every live request carries as 1800, and the
    /// transport used to clamp its seeks to it. See `AppleSeekableRange`.
    var seekableRange: AppleSeekableRange? { get }
    /// A fresh stream per call; every property change is emitted.
    var events: AsyncStream<ApplePlaybackEngineEvent> { get }
    func load(_ request: ApplePlaybackRequest) async throws
    func play()
    func pause()
    var maximumPlaybackRate: Float { get }
    func setPlaybackRate(_ rate: Float)
    func stop()
    func seek(to seconds: Double) async
    func selectAudioTrack(id: Int)
    func selectSubtitleTrack(id: Int?)
    /// Append subtitle files fetched from add-ons to `subtitleTracks`, after the
    /// tracks embedded in the media. Engines that cannot render an external
    /// file ignore them.
    func addExternalSubtitleTracks(_ tracks: [AppleExternalSubtitleTrack])
}

public extension ApplePlaybackEngine {
    func addExternalSubtitleTracks(_ tracks: [AppleExternalSubtitleTrack]) {}
    /// One clock for everything on engines that have only one.
    var presentationTime: Double { position }
    /// Engines that cannot report their selection say nothing, and the overlay
    /// falls back to the last track it selected itself.
    var activeSubtitleTrackID: Int? { nil }
    /// The audio track playing, when the engine can say; the audio menu's
    /// check mark. Nil falls back to the overlay's last pick, then the default.
    var activeAudioTrackID: Int? { nil }
    /// Most routes cannot report this; the fitting falls back to 16:9.
    var videoSize: CGSize? { nil }
    var outputInfo: ApplePlaybackOutputInfo { ApplePlaybackOutputInfo(dynamicRange: nil) }

    /// Engines that know nothing about their seekable span report none, and
    /// the transport treats the stream as live-edge-only.
    var seekableRange: AppleSeekableRange? { nil }

    /// `AVPlayerItem.seekableTimeRanges`, folded to the one contiguous range
    /// that matters. Live HLS reports a single sliding range; a VOD item
    /// reports its whole timeline. Shared by both engines, because both end up
    /// behind an `AVPlayer` on the routes where this is knowable.
    @MainActor
    func avPlayerSeekableRange(_ player: AVPlayer?) -> AppleSeekableRange? {
        guard let item = player?.currentItem else { return nil }
        let ranges = item.seekableTimeRanges.map(\.timeRangeValue).filter { $0.duration.isNumeric }
        guard let first = ranges.first else { return nil }
        // Take the outer bounds: a stream with a gap is still seekable across
        // the parts it holds, and the player clamps inside them for us.
        let start = ranges.reduce(first.start.seconds) { Swift.min($0, $1.start.seconds) }
        let end = ranges.reduce(first.end.seconds) { Swift.max($0, $1.end.seconds) }
        return AppleSeekableRange(start: start, end: end)
    }

    var maximumPlaybackRate: Float { 2 }
    func setPlaybackRate(_ rate: Float) {
        guard rate.isFinite, rate >= 0, rate <= maximumPlaybackRate else { return }
        if let avPlayer { avPlayer.rate = rate }
        else if rate == 0 { pause() }
        else { play() }
    }
}

// Cues are immutable values (text runs, or a decoded CGImage that is never
// mutated after creation); they may be parsed off the main actor and handed
// back to it.
extension AppleSubtitleCueBody: @unchecked Sendable {}
extension AppleSubtitleCue: @unchecked Sendable {}

// MARK: - Caption preferences

public extension ApplePlaybackEngine {
    /// Hands the viewer's caption settings to whichever engine is playing.
    ///
    /// Every call site used to do this with `as? AetherPlaybackEngine`, so on
    /// the AVPlayer route — which on Apple TV takes MP4, M4V, MOV and HLS, i.e.
    /// most well-formed content — the chosen language and the captions
    /// preference were dropped on the floor (owner 2026-09-15: "subtitles are
    /// not working"). One call, both engines.
    @MainActor
    func applyCaptionPreferences(
        preference: AppleCaptionsPreference,
        languages: [String],
        languagesAreExplicit: Bool
    ) {
        if let aether = self as? AetherPlaybackEngine {
            aether.captionsPreference = preference
            aether.preferredSubtitleLanguages = languages
            aether.subtitleLanguagesAreExplicit = languagesAreExplicit
        } else if let native = self as? NativePlaybackEngine {
            native.captionsPreference = preference
            native.preferredSubtitleLanguages = languages
            native.subtitleLanguagesAreExplicit = languagesAreExplicit
        }
    }

    /// The captions preference alone, for the live toggle in the transport.
    @MainActor
    func applyCaptionPreference(_ preference: AppleCaptionsPreference) {
        if let aether = self as? AetherPlaybackEngine {
            aether.captionsPreference = preference
        } else if let native = self as? NativePlaybackEngine {
            native.captionsPreference = preference
        }
    }
}

public extension ApplePlaybackEngine {
    var chapters: [AppleChapter] { [] }
}
