import AVFoundation
import Combine
import Foundation
import AetherEngine

/// OpenStream's primary playback engine: a thin `ApplePlaybackEngine` adapter
/// around `AetherEngine` that mirrors its Combine publishers into the engine
/// protocol's properties and `AsyncStream` events. One instance owns one
/// `AetherEngine`; the subscriptions live for the lifetime of this adapter and
/// are cancelled automatically when it deinits (every sink captures `self`
/// weakly, so there is no retain cycle).
@MainActor
public final class AetherPlaybackEngine: ApplePlaybackEngine {
    public let kind: ApplePlaybackEngineKind = .openStream

    private let aether: AetherEngine
    private var cancellables = Set<AnyCancellable>()
    private let eventStream = ApplePlaybackEventStream()

    /// True once playback has actually rolled for this session; an error after
    /// this point is a mid-playback failure rather than a load failure.
    private var hasReachedPlaying = false
    private var subtitleSelectionOverridden = false
    private var lastPositionUpdate = Date.distantPast
    /// Latest values published by `aether.$duration` / `aether.$isLive`. Used by
    /// `refreshDuration` because `@Published` sinks fire on `willSet`, when the
    /// engine's own stored properties still hold the previous value.
    private var lastPublishedDuration: Double = 0
    private var lastPublishedIsLive: Bool = false

    /// Subtitle tracks demuxed from the media, kept apart from the add-on
    /// tracks so `subtitleTracks` can be rebuilt with the embedded ones first
    /// and the appended add-on ids stay stable.
    private var embeddedSubtitleTracks: [ApplePlaybackTrack] = []
    private var externalSubtitleTracks: [AppleExternalSubtitleTrack] = []
    private var activeExternalSubtitleID: Int?
    private var externalSubtitleLoad: Task<Void, Never>?

    /// Track ids at or above this value address `externalSubtitleTracks`; the
    /// engine's own track indices are small integers.
    static let externalSubtitleTrackIDBase = 1_000_000

    /// Downloads a chosen add-on subtitle file. Injectable for tests.
    public var externalSubtitleDataLoader: @Sendable (URL) async throws -> Data
        = AppleExternalSubtitleService.liveDataLoader

    public private(set) var phase: ApplePlaybackEnginePhase = .idle {
        didSet {
            guard phase != oldValue else { return }
            if case .playing = phase { hasReachedPlaying = true }
            emit(.phase(phase))
        }
    }
    public private(set) var route: ApplePlaybackPresentationRoute = .none {
        didSet {
            guard route != oldValue else { return }
            emit(.route(route))
        }
    }
    public private(set) var position: Double = 0
    public private(set) var duration: Double? = nil {
        didSet {
            guard duration != oldValue else { return }
            emit(.duration(duration))
        }
    }
    public private(set) var audioTracks: [ApplePlaybackTrack] = [] {
        didSet {
            guard audioTracks != oldValue else { return }
            emit(.tracks)
        }
    }
    public private(set) var subtitleTracks: [ApplePlaybackTrack] = [] {
        didSet {
            guard subtitleTracks != oldValue else { return }
            emit(.tracks)
            autoSelectSubtitleIfPreferred()
        }
    }

    /// Decoded cues for the active subtitle track, mirrored from the engine for
    /// the `.surface` overlay to render. Not emitted through `events`; the model
    /// re-reads it on position ticks. Empty on `.avPlayer` routes where the
    /// system player's own captions menu renders the track.
    public private(set) var subtitleCues: [AppleSubtitleCue] = []

    /// Preferred caption behaviour applied at load and when tracks arrive. The
    /// host sets this from `AppleSettingsStore.captionsPreference` before load;
    /// `.always` auto-selects the first track, `.english` / `.deviceLanguage`
    /// hand the engine matching languages, `.off` selects nothing.
    public var captionsPreference: AppleCaptionsPreference = .off

    /// The viewer's chosen subtitle languages. Auto-selection picks the first
    /// track in these rather than the first track in the file: a remux lists
    /// its tracks in whatever order the muxer used, so "first" was routinely a
    /// language the viewer does not read (owner 2026-09-14). Empty means no
    /// preference, and then the first track stands.
    public var preferredSubtitleLanguages: [String] =
        UserDefaults.standard.stringArray(forKey: AppleSubtitleLanguages.defaultsKey) ?? []
    /// True when `preferredSubtitleLanguages` is a language the viewer picked
    /// rather than one inferred from the device. A picked language is the whole
    /// menu; see `AppleSubtitleTrackFilter.visible`.
    public var subtitleLanguagesAreExplicit = false
    public private(set) var failure: ApplePlaybackFailure? = nil {
        didSet {
            guard failure != oldValue else { return }
            emit(.failure(failure))
        }
    }

    public var avPlayer: AVPlayer? { aether.currentAVPlayer }

    /// Exposed for `ApplePlaybackSurfaceView`, which mounts the engine's own
    /// SwiftUI surface on `.surface` routes.
    internal var aetherEngine: AetherEngine { aether }

    public var events: AsyncStream<ApplePlaybackEngineEvent> {
        eventStream.stream()
    }

    public init() throws {
        aether = try AetherEngine()
        // The app owns the system Now Playing card; the engine must not take it
        // from AVKit. The default is already `false`, set it explicitly so the
        // intent survives an engine-side default change.
        #if os(iOS) || os(tvOS)
        aether.ownsVideoNowPlayingSession = false
        #endif
        bind()
    }

    // MARK: - ApplePlaybackEngine

    public func load(_ request: ApplePlaybackRequest) async throws {
        hasReachedPlaying = false
        subtitleSelectionOverridden = false
        clearExternalSubtitles()
        failure = nil
        var options = LoadOptions(
            httpHeaders: request.effectiveHeaders,
            isLive: request.isLive,
            dvrWindowSeconds: request.effectiveDVRWindowSeconds
        )
        // Declare WebVTT renditions in the loopback HLS so embedded SRT/ASS
        // (and DVB/teletext the engine can render to text) reach the system
        // player's own captions menu on `.avPlayer`/loopback routes. On `.surface`
        // the host overlay reads `subtitleCues` instead; declaring native
        // renditions also keeps cues flowing there.
        options.preferredDecodePath = .automatic
        options.prepareNativeSubtitles = true
        options.autoplay = request.autoplay
        // A language the viewer picked wins over one derived from the captions
        // preference: under `.always` the preference contributes no languages
        // at all, so the demuxer used to pick in muxer order at load and get
        // corrected afterwards — a visible flash of the wrong language.
        options.preferredSubtitleLanguages = preferredSubtitleLanguages.isEmpty
            ? captionsPreference.preferredSubtitleLanguages
            : preferredSubtitleLanguages
        _ = try await aether.load(
            url: request.url,
            startPosition: request.resumePosition,
            options: options
        )
        print("[OpenStream] route title=\(request.title ?? "Untitled") container=\(request.hints.filename.map { URL(fileURLWithPath: $0).pathExtension } ?? request.url.pathExtension) route=\(aether.videoRoute) decoder=\(aether.activeVideoDecoder ?? "unknown") audio=\(audioTracks.map(\.codec))")
        try Task.checkCancellation()
        if !request.autoplay, let resume = request.resumePosition, resume.isFinite, resume > 0 {
            // A paused mount prepares the demuxer at the resume offset but
            // does not arm its clock. Seek while paused to publish that offset.
            await aether.seek(to: resume)
        }
    }

    public func play() { aether.play() }
    public func pause() { aether.pause() }
    public var maximumPlaybackRate: Float { aether.maxSupportedRate }
    public func setPlaybackRate(_ rate: Float) {
        guard rate.isFinite, rate >= 0, rate <= maximumPlaybackRate else { return }
        aether.setRate(rate)
    }

    public func stop() {
        aether.stop()
        clearExternalSubtitles()
        hasReachedPlaying = false
        position = 0
        lastPositionUpdate = .distantPast
    }

    public func seek(to seconds: Double) async {
        await aether.seek(to: seconds)
    }

    public func selectAudioTrack(id: Int) {
        aether.selectAudioTrack(index: id)
    }

    public func selectSubtitleTrack(id: Int?) {
        subtitleSelectionOverridden = true
        applySubtitleSelection(id: id)
    }

    /// Appends add-on subtitle files after the embedded tracks. Ids already
    /// present are ignored, so a second batch from a slower add-on never
    /// renumbers a track the viewer can already see.
    public func addExternalSubtitleTracks(_ tracks: [AppleExternalSubtitleTrack]) {
        var merged = externalSubtitleTracks
        for track in tracks where !merged.contains(where: { $0.id == track.id }) {
            merged.append(track)
        }
        guard merged.count != externalSubtitleTracks.count else { return }
        externalSubtitleTracks = merged
        rebuildSubtitleTracks()
    }

    // MARK: - External subtitles

    private func applySubtitleSelection(id: Int?) {
        externalSubtitleLoad?.cancel()
        externalSubtitleLoad = nil
        let previousExternal = activeExternalSubtitleID
        activeExternalSubtitleID = nil
        guard let id else {
            aether.clearSubtitle()
            if previousExternal != nil { subtitleCues = [] }
            return
        }
        let index = id - Self.externalSubtitleTrackIDBase
        guard index >= 0, index < externalSubtitleTracks.count else {
            if previousExternal != nil { subtitleCues = [] }
            aether.selectSubtitleTrack(index: id)
            return
        }
        // The engine renders one cue stream; an add-on file replaces it.
        aether.clearSubtitle()
        subtitleCues = []
        activeExternalSubtitleID = id
        let track = externalSubtitleTracks[index]
        let load = externalSubtitleDataLoader
        externalSubtitleLoad = Task { [weak self] in
            let data = try? await load(track.url)
            guard self != nil, !Task.isCancelled, let data else { return }
            // Inflating and parsing a whole subtitle file on the main actor
            // froze the player; do it off the main actor and hop back only
            // to publish the cues.
            let cues = await Task.detached(priority: .userInitiated) {
                AppleSubtitleTextParser.cues(from: data)
            }.value
            guard let self, !Task.isCancelled, self.activeExternalSubtitleID == id else { return }
            self.subtitleCues = cues
        }
    }

    /// Internal so an engine test can stand in for the demuxer's track list.
    func applyEmbeddedSubtitleTracks(_ tracks: [ApplePlaybackTrack]) {
        embeddedSubtitleTracks = tracks
        rebuildSubtitleTracks()
    }

    private func rebuildSubtitleTracks() {
        subtitleTracks = embeddedSubtitleTracks + externalSubtitleTracks.enumerated().map { index, track in
            ApplePlaybackTrack(
                id: Self.externalSubtitleTrackIDBase + index,
                title: track.displayName
            )
        }
    }

    private func clearExternalSubtitles() {
        externalSubtitleLoad?.cancel()
        externalSubtitleLoad = nil
        activeExternalSubtitleID = nil
        externalSubtitleTracks = []
        rebuildSubtitleTracks()
    }

    // MARK: - Combine bridging

    private func bind() {
        aether.$playbackPhase
            .sink { [weak self] phase in self?.applyPhase(phase) }
            .store(in: &cancellables)
        aether.$videoRoute
            .sink { [weak self] videoRoute in self?.route = Self.mapRoute(videoRoute) }
            .store(in: &cancellables)
        aether.$errorInfo
            .sink { [weak self] info in self?.applyFailure(info) }
            .store(in: &cancellables)
        aether.$audioTracks
            .sink { [weak self] tracks in self?.audioTracks = tracks.map(Self.mapTrack) }
            .store(in: &cancellables)
        aether.$subtitleTracks
            .sink { [weak self] tracks in self?.applyEmbeddedSubtitleTracks(tracks.map(Self.mapTrack)) }
            .store(in: &cancellables)
        aether.$subtitleCues
            .sink { [weak self] cues in
                guard let self, self.activeExternalSubtitleID == nil else { return }
                self.subtitleCues = cues.map(Self.mapCue)
            }
            .store(in: &cancellables)
        aether.$duration
            .sink { [weak self] seconds in
                guard let self else { return }
                // `@Published` emits on `willSet`, so the sink's parameter is
                // the new value while `aether.duration` still holds the old one.
                // Capture the published value and compute from it, not the store.
                self.lastPublishedDuration = seconds
                self.refreshDuration()
            }
            .store(in: &cancellables)
        aether.$isLive
            .sink { [weak self] live in
                guard let self else { return }
                self.lastPublishedIsLive = live
                self.refreshDuration()
            }
            .store(in: &cancellables)
        aether.clock.$currentTime
            .sink { [weak self] seconds in self?.applyPosition(seconds) }
            .store(in: &cancellables)
    }

    private func applyPhase(_ phase: PlaybackPhase) {
        self.phase = Self.mapPhase(phase)
    }

    private func applyFailure(_ info: PlaybackErrorInfo?) {
        guard let info else {
            failure = nil
            return
        }
        failure = Self.classify(info, hasReachedPlaying: hasReachedPlaying)
    }

    private func applyPosition(_ seconds: Double) {
        guard seconds.isFinite else { return }
        let now = Date()
        guard now.timeIntervalSince(lastPositionUpdate) >= 0.25 else { return }
        lastPositionUpdate = now
        position = max(0, seconds)
        emit(.position(position))
    }

    private func refreshDuration() {
        if lastPublishedIsLive {
            duration = nil
        } else if lastPublishedDuration > 0 {
            duration = lastPublishedDuration
        } else {
            duration = nil
        }
    }

    /// Auto-selects the first subtitle track when `captionsPreference` is
    /// `.always` and nothing is active yet. `.english` / `.deviceLanguage` are
    /// served at load by `LoadOptions.preferredSubtitleLanguages`; `.off` selects
    /// nothing. Idempotent: a selected track (`activeSubtitleTrackIndex != nil`)
    /// stops the auto-select, so the user's explicit "Off" survives.
    private func autoSelectSubtitleIfPreferred() {
        guard !subtitleSelectionOverridden, captionsPreference.autoSelectsAnyTrack,
              !subtitleTracks.isEmpty,
              aether.activeSubtitleTrackIndex == nil,
              activeExternalSubtitleID == nil,
              let first = AppleSubtitleTrackFilter.visible(
                  subtitleTracks,
                  preferredLanguages: preferredSubtitleLanguages,
                  isExplicitChoice: subtitleLanguagesAreExplicit
              ).first else { return }
        applySubtitleSelection(id: first.id)
    }

    private func emit(_ event: ApplePlaybackEngineEvent) {
        eventStream.emit(event)
    }

    // MARK: - Mapping

    private static func mapPhase(_ phase: PlaybackPhase) -> ApplePlaybackEnginePhase {
        switch phase {
        case .idle: return .idle
        case .loading: return .loading
        case .playing: return .playing
        case .paused: return .paused
        case .seeking: return .seeking
        case .rebuffering: return .rebuffering
        case .stalled(let reconnecting): return .stalled(reconnecting: reconnecting)
        case .ended: return .ended
        case .error(let message): return .error(message)
        }
    }

    private static func mapRoute(_ route: VideoRoute) -> ApplePlaybackPresentationRoute {
        switch route {
        case .none: return .none
        case .remoteBypass, .loopback: return .avPlayer
        case .software: return .surface
        case .audio: return .audioOnly
        }
    }

    private static func mapTrack(_ track: TrackInfo) -> ApplePlaybackTrack {
        ApplePlaybackTrack(
            id: track.id,
            title: track.name,
            language: track.language,
            codec: track.codec,
            isDefault: track.isDefault
        )
    }

    private static func mapCue(_ cue: SubtitleCue) -> AppleSubtitleCue {
        AppleSubtitleCue(
            id: cue.id,
            startTime: cue.startTime,
            endTime: cue.endTime,
            body: mapCueBody(cue.body)
        )
    }

    private static func mapCueBody(_ body: SubtitleCue.Body) -> AppleSubtitleCueBody {
        switch body {
        case .text(let s):
            return .text(s)
        case .richText(let runs):
            return .richText(runs.map { run in
                AppleSubtitleTextRun(
                    text: run.text,
                    isBold: run.isBold,
                    isItalic: run.isItalic,
                    isUnderlined: run.isUnderlined,
                    isStruckThrough: run.isStruckThrough
                )
            })
        case .image(let image):
            return .image(image.cgImage)
        }
    }

    private static func classify(_ info: PlaybackErrorInfo, hasReachedPlaying: Bool) -> ApplePlaybackFailure {
        let code = info.underlyingCode
        // An HTTP 401/403 from the origin is authentication regardless of the
        // engine's own kind token (`sourceRefused` carries the status in `underlyingCode`).
        if code == 401 || code == 403 {
            return ApplePlaybackFailure(
                kind: .authentication,
                message: "The provider rejected the account or request headers (HTTP \(code!)."
            )
        }
        // After playback has rolled, surface the engine's own message as a
        // mid-playback player failure rather than reclassifying the load.
        if hasReachedPlaying {
            return ApplePlaybackFailure(kind: .player, message: info.message)
        }
        let unsupportedKinds: Set<PlaybackErrorKind> = [
            .noPlayableTrackWithinBudget,
            .masterPlaylistRejected,
            .softwarePipelineFailed,
            .dolbyVisionRequiresHardware,
            .demuxedAudioLiveUnsupported,
            .hlsPlaylistOnRawLivePath,
        ]
        if unsupportedKinds.contains(info.kind) {
            return ApplePlaybackFailure(
                kind: .unsupportedMedia,
                message: "This stream uses a format OpenStream cannot play on this device."
            )
        }
        // AVFoundation codec/container rejections land as unsupported too.
        if let domain = info.underlyingDomain, domain == AVFoundationErrorDomain,
           let resolvedCode = code, resolvedCode == -11828 || resolvedCode == -11829 {
            return ApplePlaybackFailure(
                kind: .unsupportedMedia,
                message: "This stream uses a format OpenStream cannot play on this device."
            )
        }
        let networkKinds: Set<PlaybackErrorKind> = [
            .sourceRefused,
            .sourceRateLimited,
            .vodSourceFailed,
            .liveSourceUnavailable,
            .audioSessionFailed,
        ]
        if networkKinds.contains(info.kind) {
            return ApplePlaybackFailure(kind: .network, message: info.message)
        }
        return ApplePlaybackFailure(kind: .player, message: info.message)
    }
}
