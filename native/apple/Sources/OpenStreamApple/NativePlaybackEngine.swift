import AVFoundation
import CoreMedia
import Combine
import Foundation

/// The AVPlayer-only fallback engine. It never demuxes: it hands the URL
/// straight to `AVPlayer` (with the request's headers when present) and derives
/// the engine protocol's phases from AVFoundation's own transport and item
/// status signals. Used directly when the caller asks for the native engine, or
/// handed back by `ApplePlaybackEngineFactory` when `AetherPlaybackEngine`
/// cannot be constructed.
@MainActor
public final class NativePlaybackEngine: ApplePlaybackEngine {
    public let kind: ApplePlaybackEngineKind = .native

    private var player: AVPlayer?
    private var item: AVPlayerItem?
    private var observers: [NSKeyValueObservation] = []
    private var notificationObservers: [NSObjectProtocol] = []
    private var timeObserverToken: Any?
    private let eventStream = ApplePlaybackEventStream()
    private var isSeeking = false
    private var lastPositionUpdate = Date.distantPast
    private var loadGeneration = 0
    private var protectedPlaybackURL: URL?

    public private(set) var phase: ApplePlaybackEnginePhase = .idle {
        didSet {
            guard phase != oldValue else { return }
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
        }
    }

    /// Always empty on the native route: AVFoundation draws the selected
    /// legible track itself, so the host overlay has no cues to render.
    // TODO: add-on subtitle files still need a side-load (an `AVMutableComposition`
    // carrying the fetched track, or parsing them into cues) before
    // `addExternalSubtitleTracks` can do anything on this engine. Tracks muxed
    // into the stream are handled below and need neither.
    public var subtitleCues: [AppleSubtitleCue] = []

    /// The asset's legible media selection group, and the option behind each
    /// entry in `subtitleTracks`.
    ///
    /// This route never read it. `subtitleTracks` stayed empty and
    /// `selectSubtitleTrack` was a no-op, so every stream AVFoundation demuxes
    /// itself — MP4, M4V, MOV and HLS, which on Apple TV is most well-formed
    /// content — played with no captions available at all, whether or not an
    /// add-on was installed (owner 2026-09-15: "subtitles are not working but
    /// streams should have subtitles even without an add-on"). Subtitles are
    /// routinely muxed into those containers: `tx3g` and `wvtt` in the MPEG-4
    /// family, `EXT-X-MEDIA:TYPE=SUBTITLES` renditions in HLS.
    /// The stream's own chapter markers, for Skip Intro. Empty when the file
    /// carries none, which is most of them — see `AppleChapterMarkers`.
    public private(set) var chapters: [AppleChapter] = []
    /// Filled by `describeTracks`, which already reads the format description
    /// for the trace — the number was being logged and thrown away.
    public private(set) var videoSize: CGSize?

    @ObservationIgnored private var legibleGroup: AVMediaSelectionGroup?
    @ObservationIgnored private var legibleOptions: [Int: AVMediaSelectionOption] = [:]

    /// Set by the host from `AppleSettingsStore`, exactly as the demuxing
    /// engine is. Both were previously applied only to `AetherPlaybackEngine`,
    /// so on this route the viewer's language choice was ignored outright.
    public var captionsPreference: AppleCaptionsPreference = .off
    public var preferredSubtitleLanguages: [String] = []
    /// See `AetherPlaybackEngine.subtitleLanguagesAreExplicit`.
    public var subtitleLanguagesAreExplicit = false
    /// An explicit choice (including "Off") stops the auto-select from
    /// overriding it on the next track load.
    @ObservationIgnored private var subtitleSelectionOverridden = false
    public private(set) var failure: ApplePlaybackFailure? = nil {
        didSet {
            guard failure != oldValue else { return }
            emit(.failure(failure))
        }
    }

    public var avPlayer: AVPlayer? { player }

    public var events: AsyncStream<ApplePlaybackEngineEvent> {
        eventStream.stream()
    }

    public init() {}

    isolated deinit { teardown() }

    // MARK: - ApplePlaybackEngine

    public func load(_ request: ApplePlaybackRequest) async throws {
        teardown()
        loadGeneration &+= 1
        let generation = loadGeneration
        failure = nil
        isSeeking = false
        position = 0
        lastPositionUpdate = .distantPast

        let headers = request.effectiveHeaders
        var playbackURL = request.url
        if !headers.isEmpty {
            playbackURL = try await AppleProtectedHTTPPlaybackServer.shared.playbackURL(
                upstreamURL: request.url, requestHeaders: headers)
            guard generation == loadGeneration, !Task.isCancelled else {
                await AppleProtectedHTTPPlaybackServer.shared.revoke(playbackURL: playbackURL)
                throw CancellationError()
            }
            protectedPlaybackURL = playbackURL
        }
        let asset = AVURLAsset(url: playbackURL)
        let playerItem = AVPlayerItem(asset: asset)
        playerItem.allowedAudioSpatializationFormats = .monoStereoAndMultichannel
        let avPlayer = AVPlayer(playerItem: playerItem)
        self.item = playerItem
        self.player = avPlayer
        route = .avPlayer
        phase = .loading
        observe(playerItem: playerItem, player: avPlayer)
        if let resume = request.resumePosition, resume.isFinite, resume > 0, !request.isLive {
            await seek(to: resume)
            guard generation == loadGeneration, !Task.isCancelled else { throw CancellationError() }
        }
        if request.autoplay { avPlayer.play() }
        else { avPlayer.pause(); derivePhase() }
        describeTracks(of: asset, title: request.title)
        await loadEmbeddedSubtitleTracks(of: asset, item: playerItem)
        await loadChapters(of: asset, item: playerItem)
    }

    /// Reads the chapter markers AVFoundation exposes as timed metadata groups
    /// — the MPEG-4 family's chapter tracks and Matroska chapters.
    private func loadChapters(of asset: AVURLAsset, item: AVPlayerItem) async {
        guard let locales = try? await asset.load(.availableChapterLocales) else { return }
        let preferred = locales.isEmpty ? [] : locales.map(\.identifier)
        guard let groups = try? await asset.loadChapterMetadataGroups(
            bestMatchingPreferredLanguages: preferred.isEmpty ? ["en"] : preferred
        ) else { return }
        guard self.item === item else { return }

        var parsed: [AppleChapter] = []
        for group in groups {
            let title = await Self.title(of: group)
            guard !title.isEmpty else { continue }
            let start = group.timeRange.start.seconds
            let end = group.timeRange.end.seconds
            guard start.isFinite, end.isFinite, end > start else { continue }
            parsed.append(AppleChapter(title: title, start: start, end: end))
        }
        chapters = parsed
        guard !parsed.isEmpty else { return }
        appleTrace("native engine chapters: \(parsed.count) — \(parsed.map(\.title).prefix(6).joined(separator: ", "))")
    }

    private static func title(of group: AVTimedMetadataGroup) async -> String {
        for item in group.items where item.commonKey == .commonKeyTitle {
            let value = (try? await item.load(.stringValue)) ?? nil
            if let value, !value.isEmpty { return value }
        }
        return ""
    }

    /// Names the codec AVPlayer was handed, once its tracks load.
    ///
    /// A black picture with working audio and an advancing timeline means the
    /// pipeline is alive and only the video is not being rendered — which is a
    /// decoder question, not a playback one, and impossible to answer from the
    /// outside (owner 2026-09-15: "video play back is black on this title").
    /// Formats are reported as their four-character codes: `avc1` H.264,
    /// `hvc1`/`hev1` HEVC, `dvh1`/`dvhe` Dolby Vision.
    private func describeTracks(of asset: AVURLAsset, title: String?) {
        Task { [weak self] in
            guard let tracks = try? await asset.loadTracks(withMediaType: .video),
                  let track = tracks.first else {
                appleTraceFailure("native engine: \(title ?? "untitled") has no video track at all")
                return
            }
            guard let descriptions = try? await track.load(.formatDescriptions),
                  let format = descriptions.first else { return }
            let code = CMFormatDescriptionGetMediaSubType(format)
            let fourCC = String(bytes: [
                UInt8((code >> 24) & 0xff), UInt8((code >> 16) & 0xff),
                UInt8((code >> 8) & 0xff), UInt8(code & 0xff),
            ], encoding: .ascii) ?? "?"
            let size = CMVideoFormatDescriptionGetDimensions(format)
            await MainActor.run { self?.videoSize = CGSize(width: Int(size.width), height: Int(size.height)) }
            _ = self
            appleTrace("native engine video: \(fourCC) \(size.width)x\(size.height) — \(title ?? "untitled")")
        }
    }

    public func play() { player?.play() }
    public func pause() { player?.pause() }

    public func stop() {
        loadGeneration &+= 1
        legibleGroup = nil
        legibleOptions = [:]
        subtitleTracks = []
        chapters = []
        videoSize = nil
        subtitleSelectionOverridden = false
        teardown()
        isSeeking = false
        position = 0
        lastPositionUpdate = .distantPast
        failure = nil
        route = .none
        phase = .idle
    }

    public func seek(to seconds: Double) async {
        guard let player, seconds.isFinite else { return }
        isSeeking = true
        phase = .seeking
        let target = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        let completed = await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        guard self.player === player else { return }
        if completed {
            let seconds = player.currentTime().seconds
            if seconds.isFinite {
                position = max(0, seconds)
                emit(.position(position))
            }
        }
        finishSeek()
    }

    public func selectAudioTrack(id: Int) {
        // AVPlayer media selection is driven by AVMediaSelectionGroup; the
        // native fallback does not expose a track index the host can address,
        // so this is a no-op on this engine.
    }

    public func selectSubtitleTrack(id: Int?) {
        subtitleSelectionOverridden = true
        applySubtitleSelection(id: id)
    }

    private func applySubtitleSelection(id: Int?) {
        guard let item, let legibleGroup else { return }
        guard let id, let option = legibleOptions[id] else {
            item.select(nil, in: legibleGroup)
            return
        }
        item.select(option, in: legibleGroup)
    }

    /// Publishes the stream's own subtitle tracks and honours the captions
    /// preference, mirroring the demuxing engine: `.always` takes the first
    /// visible track, a language preference takes the first that matches, and
    /// `.off` selects nothing.
    private func loadEmbeddedSubtitleTracks(of asset: AVURLAsset, item: AVPlayerItem) async {
        guard let group = try? await asset.loadMediaSelectionGroup(for: .legible) else { return }
        guard self.item === item else { return }
        legibleGroup = group
        var options: [Int: AVMediaSelectionOption] = [:]
        var tracks: [ApplePlaybackTrack] = []
        for (index, option) in group.options.enumerated() {
            // Forced tracks are for untranslated foreign dialogue and are
            // applied by the system, not chosen from a captions menu.
            guard !option.hasMediaCharacteristic(.containsOnlyForcedSubtitles) else { continue }
            options[index] = option
            tracks.append(ApplePlaybackTrack(
                id: index,
                title: option.displayName,
                language: option.extendedLanguageTag ?? option.locale?.identifier,
                codec: option.mediaType == .closedCaption ? "cc" : "sub",
                isDefault: index == 0
            ))
        }
        legibleOptions = options
        subtitleTracks = tracks
        appleTrace("native engine subtitles: \(tracks.count) embedded track(s) — \(tracks.map(\.title).joined(separator: ", "))")
        autoSelectSubtitleIfPreferred()
    }

    private func autoSelectSubtitleIfPreferred() {
        guard !subtitleSelectionOverridden, !subtitleTracks.isEmpty else { return }
        let visible = AppleSubtitleTrackFilter.visible(
            subtitleTracks,
            preferredLanguages: preferredSubtitleLanguages,
            isExplicitChoice: subtitleLanguagesAreExplicit)
        switch captionsPreference {
        case .off:
            applySubtitleSelection(id: nil)
        case .always:
            guard let first = visible.first else { return }
            applySubtitleSelection(id: first.id)
        default:
            // A language preference only selects a track that actually matches
            // it; `visible` falls back to every track when nothing does, so
            // check the match rather than trusting the fallback.
            let wanted = preferredSubtitleLanguages.map(AppleSubtitleTrackFilter.normalized)
            guard let match = visible.first(where: {
                wanted.contains(AppleSubtitleTrackFilter.normalized($0.language ?? ""))
            }) else { return }
            applySubtitleSelection(id: match.id)
        }
    }

    // MARK: - Observation

    private func observe(playerItem: AVPlayerItem, player: AVPlayer) {
        observers.append(playerItem.observe(\.status, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.derivePhase() }
        })
        observers.append(playerItem.observe(\.isPlaybackBufferEmpty, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.derivePhase() }
        })
        observers.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.derivePhase() }
        })

        let center = NotificationCenter.default
        notificationObservers.append(center.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleEnd() }
        })
        notificationObservers.append(center.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            // The notification's `note` is not Sendable; the item's own status
            // and `error` are the authoritative failure surface, so re-derive
            // phase here instead of forwarding the notification payload.
            Task { @MainActor [weak self] in self?.derivePhase() }
        })

        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in self?.updatePosition(time.seconds) }
        }
    }

    private func derivePhase() {
        guard let item else { return }
        switch item.status {
        case .unknown:
            phase = .loading
        case .readyToPlay:
            guard let player else { return }
            if isSeeking {
                phase = .seeking
            } else {
                switch player.timeControlStatus {
                case .playing:
                    phase = .playing
                case .paused:
                    phase = .paused
                case .waitingToPlayAtSpecifiedRate:
                    phase = .rebuffering
                @unknown default:
                    phase = .loading
                }
            }
            refreshDuration()
        case .failed:
            applyItemFailure()
        @unknown default:
            break
        }
    }

    private func finishSeek() {
        isSeeking = false
        derivePhase()
    }

    private func handleEnd() {
        isSeeking = false
        phase = .ended
    }

    private func applyItemFailure() {
        guard let item else { return }
        if let error = item.error {
            failure = Self.classify(error)
            phase = .error(failure?.message ?? "Playback failed.")
        } else {
            phase = .error("Playback failed.")
        }
    }

    private func updatePosition(_ seconds: Double) {
        guard seconds.isFinite else { return }
        let now = Date()
        guard now.timeIntervalSince(lastPositionUpdate) >= 0.25 else { return }
        lastPositionUpdate = now
        position = max(0, seconds)
        emit(.position(position))
    }

    private func refreshDuration() {
        guard let item, item.status == .readyToPlay else { return }
        let seconds = item.duration.seconds
        if seconds.isFinite && seconds > 0 {
            duration = seconds
        } else {
            duration = nil
        }
    }

    private func teardown() {
        if let url = protectedPlaybackURL {
            protectedPlaybackURL = nil
            Task { await AppleProtectedHTTPPlaybackServer.shared.revoke(playbackURL: url) }
        }
        if let token = timeObserverToken {
            player?.removeTimeObserver(token)
            timeObserverToken = nil
        }
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        notificationObservers.removeAll()
        observers.removeAll()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        item = nil
        player = nil
    }

    private func emit(_ event: ApplePlaybackEngineEvent) {
        eventStream.emit(event)
    }

    // MARK: - Failure classification

    private static func classify(_ error: Error) -> ApplePlaybackFailure {
        let nsError = error as NSError
        // AVFoundation codec/container rejections.
        if nsError.domain == AVFoundationErrorDomain,
           nsError.code == -11828 || nsError.code == -11829 {
            return ApplePlaybackFailure(
                kind: .unsupportedMedia,
                message: "This stream uses a format OpenStream cannot play on this device."
            )
        }
        // HTTP 401/403 surfaced as the underlying status, either as the error's
        // own code or in the userInfo AVFoundation attaches to a URL response.
        let statusCode = nsError.userInfo["NSURLErrorFailingURLResponseStatusCodeCode"] as? Int
            ?? nsError.userInfo["StatusCode"] as? Int
        if let code = statusCode, code == 401 || code == 403 {
            return ApplePlaybackFailure(
                kind: .authentication,
                message: "The provider rejected the account or request headers (HTTP \(code))."
            )
        }
        if nsError.code == 401 || nsError.code == 403 {
            return ApplePlaybackFailure(
                kind: .authentication,
                message: "The provider rejected the account or request headers (HTTP \(nsError.code))."
            )
        }
        if let urlError = error as? URLError, urlError.code == .userAuthenticationRequired {
            return ApplePlaybackFailure(
                kind: .authentication,
                message: "The provider rejected the account or request headers (HTTP 401)."
            )
        }
        return ApplePlaybackFailure(kind: .player, message: error.localizedDescription)
    }
}
