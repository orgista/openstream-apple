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
    private(set) var loadGeneration = 0
    private var protectedPlaybackURL: URL?
    private(set) var captionObservation: Task<Void, Never>?
    private let captionProbe: AppleLiveCaptionProbe

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

    /// The legible option `applySubtitleSelection` last selected, or nil for
    /// none. The overlay's CC key reads it so it starts in the state the
    /// picture is actually in.
    public private(set) var activeSubtitleTrackID: Int? {
        didSet {
            if activeSubtitleTrackID != oldValue { emit(.tracks) }
        }
    }

    /// Embedded legible tracks are drawn by AVKit; sidecar cues use the app's
    /// shared cue layer. Publish arrivals even while playback is paused.
    public private(set) var subtitleCues: [AppleSubtitleCue] = [] {
        didSet { emit(.tracks) }
    }
    private var embeddedSubtitleTracks: [ApplePlaybackTrack] = []
    private var externalSubtitleTracks: [AppleExternalSubtitleTrack] = []
    /// Internal read access lets tests await the actual load, without sleeps.
    private(set) var externalSubtitleLoad: Task<Void, Never>?
    private var pendingExternalSubtitleID: Int?
    static let externalSubtitleTrackIDBase = 1_000_000
    public var externalSubtitleDataLoader: @Sendable (URL) async throws -> Data
        = AppleExternalSubtitleService.liveDataLoader

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
    /// Captions are off and no selection has overridden that for this item.
    var holdsCaptionsOff: Bool { captionsPreference == .off && !subtitleSelectionOverridden }
    public var preferredSubtitleLanguages: [String] = []
    /// See `AetherPlaybackEngine.subtitleLanguagesAreExplicit`.
    public var subtitleLanguagesAreExplicit = false
    /// An explicit choice (including "Off") stops the auto-select from
    /// overriding it on the next track load.
    @ObservationIgnored private var subtitleSelectionOverridden = false
    @ObservationIgnored private var readyToPlayTracksLoaded = false
    public private(set) var failure: ApplePlaybackFailure? = nil {
        didSet {
            guard failure != oldValue else { return }
            emit(.failure(failure))
        }
    }

    /// Multiview settings survive item replacement and automatic reconnects.
    var multiviewMuted = false {
        didSet { player?.isMuted = multiviewMuted || AppleTestAudioMute.isActive }
    }
    var multiviewQualityLimited = false {
        didSet { applyMultiviewQuality() }
    }
    private func applyMultiviewQuality() {
        item?.preferredMaximumResolution = multiviewQualityLimited ? CGSize(width: 1280, height: 720) : .zero
        item?.preferredPeakBitRate = multiviewQualityLimited ? 3_000_000 : 0
    }

    public var avPlayer: AVPlayer? { player }

    /// The item's own seekable span. On this route `position` is the player's
    /// clock, so the range needs no axis conversion.
    public var seekableRange: AppleSeekableRange? {
        avPlayerSeekableRange(player)?.expanded(toInclude: position)
    }

    public var events: AsyncStream<ApplePlaybackEngineEvent> {
        eventStream.stream()
    }

    public init() { captionProbe = .shared }

    init(captionProbe: AppleLiveCaptionProbe) {
        self.captionProbe = captionProbe
    }

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

        let request = try await captionProbe.preparedRequest(request)
        guard generation == loadGeneration, !Task.isCancelled else { throw CancellationError() }
        let headers = request.effectiveHeaders
        var playbackURL = request.url
        // Undeclared CEA-608 in a live media playlist: AVPlayer only finds it
        // through a master, so the proxy serves one in front of the channel.
        let declaresCaptions = request.isLive && request.hints.declaresEmbeddedCaptions
        if !headers.isEmpty || declaresCaptions {
            playbackURL = try await AppleProtectedHTTPPlaybackServer.shared.playbackURL(
                upstreamURL: request.url, requestHeaders: headers, declaringCaptions: declaresCaptions)
            guard generation == loadGeneration, !Task.isCancelled else {
                await AppleProtectedHTTPPlaybackServer.shared.revoke(playbackURL: playbackURL)
                throw CancellationError()
            }
            protectedPlaybackURL = playbackURL
        }
        let asset = AVURLAsset(url: playbackURL)
        let playerItem = AVPlayerItem(asset: asset)
        playerItem.preferredForwardBufferDuration = AppleLiveBufferPreference.stored()
            .forwardBufferDuration(isLive: request.isLive)
        playerItem.allowedAudioSpatializationFormats = .monoStereoAndMultichannel
        #if !os(macOS)
        if !request.isLive { playerItem.externalMetadata = AppleStockPlayerMetadata.items(title: request.title, subtitle: request.subtitle, year: request.releaseYear) }
        #endif
        isLiveItem = request.isLive
        // The audio language first, then the item: AVPlayer applies its
        // selection criteria as the item becomes ready, so a criteria set
        // after it could start in the file's default dub.
        let avPlayer = AVPlayer()
        let audioLanguages = AppleAudioLanguagePreference.avPlayerLanguages(
            choice: AppleAudioLanguagePreference.storedChoice())
        avPlayer.setMediaSelectionCriteria(
            AVPlayerMediaSelectionCriteria(preferredLanguages: audioLanguages, preferredMediaCharacteristics: nil),
            forMediaCharacteristic: .audible)
        appleTrace("audio language preference \(audioLanguages.joined(separator: ","))")
        avPlayer.replaceCurrentItem(with: playerItem)
        avPlayer.isMuted = multiviewMuted || AppleTestAudioMute.isActive
        self.item = playerItem
        applyMultiviewQuality()
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
        observeLiveCaptions(request, generation: generation)
        describeTracks(of: asset, title: request.title)
        await loadEmbeddedSubtitleTracks(of: asset, item: playerItem)
        await loadChapters(of: asset, item: playerItem)
    }

    private func observeLiveCaptions(_ request: ApplePlaybackRequest, generation: Int) {
        guard request.isLive, request.hints.declaresEmbeddedCaptions else { return }
        let probe = captionProbe
        captionObservation = Task { [weak self] in
            guard !Task.isCancelled, self?.loadGeneration == generation else { return }
            await probe.probe(
                channelID: request.mediaID, playlistURL: request.url, headers: request.effectiveHeaders)
            guard !Task.isCancelled, let self, self.loadGeneration == generation else { return }
            // The probe caches the next-start decision. Leave this item playing,
            // even if its empty captions option remains until the viewer leaves.
            self.captionObservation = nil
        }
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
        activeSubtitleTrackID = nil
        readyToPlayTracksLoaded = false
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
        // AVPlayer never errors on an out-of-range seek: it lands on the
        // nearest seekable time and reports `completed == true`, which reads
        // from here as a seek that worked and from the screen as nothing
        // happening. Clamp against the item's real range so the target we log
        // is the target we get.
        var requested = max(0, seconds)
        if let range = avPlayerSeekableRange(player), !range.contains(requested) {
            let clamped = Swift.min(range.end, Swift.max(range.start, requested))
            appleTrace("native seek \(Int(requested))s is outside seekable \(Int(range.start))–\(Int(range.end))s → \(Int(clamped))s")
            requested = clamped
        }
        let target = CMTime(seconds: requested, preferredTimescale: 600)
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

    /// AVKit already applied this selection. Update the app without issuing a
    /// second select(nil)/select(option) pair or leaving a sidecar on screen.
    func mirrorSubtitleSelection(_ option: AVMediaSelectionOption?) {
        subtitleSelectionOverridden = true
        externalSubtitleLoad?.cancel()
        externalSubtitleLoad = nil
        pendingExternalSubtitleID = nil
        subtitleCues = []
        activeSubtitleTrackID = option.flatMap { selected in
            legibleOptions.first(where: { $0.value == selected })?.key
        }
        emit(.tracks)
    }

    public func addExternalSubtitleTracks(_ tracks: [AppleExternalSubtitleTrack]) {
        var merged = externalSubtitleTracks
        for track in tracks where !merged.contains(where: { $0.id == track.id }) {
            merged.append(track)
        }
        guard merged.count != externalSubtitleTracks.count else { return }
        externalSubtitleTracks = merged
        rebuildSubtitleTracks()
        autoSelectSubtitleIfPreferred()
    }

    private func rebuildSubtitleTracks() {
        subtitleTracks = embeddedSubtitleTracks + externalSubtitleTracks.enumerated().map { index, track in
            track.playbackTrack(id: Self.externalSubtitleTrackIDBase + index)
        }
    }

    private func applySubtitleSelection(id: Int?) {
        // A repeat track-discovery callback must not restart the same download.
        if let id, id >= Self.externalSubtitleTrackIDBase, (id == activeSubtitleTrackID || id == pendingExternalSubtitleID) { return }
        externalSubtitleLoad?.cancel()
        externalSubtitleLoad = nil
        pendingExternalSubtitleID = nil
        activeSubtitleTrackID = nil
        subtitleCues = []
        if let item, let legibleGroup {
            item.select(nil, in: legibleGroup)
        }
        guard let id else { return }
        if id >= Self.externalSubtitleTrackIDBase {
            let index = id - Self.externalSubtitleTrackIDBase
            guard externalSubtitleTracks.indices.contains(index) else { return }
            pendingExternalSubtitleID = id
            let track = externalSubtitleTracks[index]
            let load = externalSubtitleDataLoader
            externalSubtitleLoad = Task { [weak self] in
                let data = try? await load(track.url)
                guard !Task.isCancelled else { return }
                guard let data else {
                    if let self, self.pendingExternalSubtitleID == id { self.pendingExternalSubtitleID = nil }
                    return
                }
                // Match Aether's path: inflate/parse off the main actor.
                let cues = await Task.detached(priority: .userInitiated) {
                    AppleSubtitleTextParser.cues(from: data, language: track.languageCode)
                }.value
                guard let self, !Task.isCancelled, self.pendingExternalSubtitleID == id else { return }
                self.pendingExternalSubtitleID = nil
                self.subtitleCues = cues
                self.activeSubtitleTrackID = cues.isEmpty ? nil : id
            }
        } else if let item, let legibleGroup, let option = legibleOptions[id] {
            item.select(option, in: legibleGroup)
            activeSubtitleTrackID = id
        }
    }

    /// Keep the legible-group index as the track ID, even when forced options
    /// or duplicate languages disappear from the app's captions menu.
    nonisolated static func subtitleTrack(
        optionIndex: Int, title: String, language: String?, codec: String, isForced: Bool,
        isHearingImpaired: Bool = false
    ) -> ApplePlaybackTrack? {
        guard !isForced else { return nil }
        return ApplePlaybackTrack(
            id: optionIndex, title: title, language: language, codec: codec,
            isDefault: optionIndex == 0, isHearingImpaired: isHearingImpaired)
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
            appleTrace("native legible option \(index): title=\(option.displayName), language=\(option.extendedLanguageTag ?? option.locale?.identifier ?? "und"), type=\(option.mediaType.rawValue), subtypes=\(option.mediaSubTypes), playable=\(option.isPlayable), forced=\(option.hasMediaCharacteristic(.containsOnlyForcedSubtitles))")
            // Forced tracks are for untranslated foreign dialogue and are
            // applied by the system, not chosen from a captions menu.
            guard let track = Self.subtitleTrack(
                optionIndex: index,
                title: option.displayName,
                language: option.extendedLanguageTag ?? option.locale?.identifier,
                codec: option.mediaType == .closedCaption ? "cc" : "sub",
                isForced: option.hasMediaCharacteristic(.containsOnlyForcedSubtitles),
                isHearingImpaired: option.hasMediaCharacteristic(.describesMusicAndSoundForAccessibility)
            ) else { continue }
            options[track.id] = option
            tracks.append(track)
        }
        legibleOptions = options
        embeddedSubtitleTracks = tracks
        rebuildSubtitleTracks()
        // A group can arrive after the user has selected a sidecar. Keep
        // AVKit from drawing its automatic legible selection on top of it.
        if let id = activeSubtitleTrackID, id >= Self.externalSubtitleTrackIDBase {
            item.select(nil, in: group)
        }
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
            // `visible` is the language rule: a preferred-language track, or
            // an untagged closed caption when the stream has none.
            guard let match = visible.first else { return }
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
            Task { @MainActor [weak self] in
                self?.traceTransport("timeControlStatus")
                self?.derivePhase()
            }
        })

        let center = NotificationCenter.default
        notificationObservers.append(center.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleEnd() }
        })
        // Seek/stall diagnostics for the stock route, where AVKit seeks the
        // player itself and the engine only sees the consequences.
        notificationObservers.append(center.addObserver(
            forName: AVPlayerItem.timeJumpedNotification, object: playerItem, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.traceTransport("timeJumped") }
        })
        notificationObservers.append(center.addObserver(
            forName: .AVPlayerItemPlaybackStalled, object: playerItem, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.traceTransport("stalled") }
        })
        notificationObservers.append(center.addObserver(
            forName: .AVPlayerItemNewErrorLogEntry, object: playerItem, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let entry = self?.item?.errorLog()?.events.last else { return }
                // Status and domain only: the URI and comment can carry tokens.
                appleTrace("native errorLog: status=\(entry.errorStatusCode) domain=\(entry.errorDomain)")
            }
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

        startClockMonitor(player: player)

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
            if !readyToPlayTracksLoaded {
                readyToPlayTracksLoaded = true
                if let asset = item.asset as? AVURLAsset {
                    Task { @MainActor [weak self, item] in
                        guard let self else { return }
                        await self.loadEmbeddedSubtitleTracks(of: asset, item: item)
                    }
                }
            }
            guard let player else { return }
            if isSeeking {
                phase = .seeking
            } else {
                switch player.timeControlStatus {
                case .playing:
                    phase = .playing
                case .paused:
                    // Paused on the last frame is the end, not a pause. The
                    // pause that AVPlayer makes at the end landed after
                    // `.ended` and replaced it before the view saw it, and
                    // some streams stop there without posting
                    // DidPlayToEndTime, so the stock route never advanced to
                    // the next episode (Apple TV regression 2026-10-01).
                    phase = Self.isAtEnd(position: player.currentTime().seconds,
                                         duration: item.duration.seconds) ? .ended : .paused
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

    private var clockMonitor: Task<Void, Never>?
    private var isLiveItem = false

    /// Watches for the stall AVPlayer does not come out of by itself.
    ///
    /// After a seek on the stock route, AVPlayer can sit in
    /// `waitingToPlayAtSpecifiedRate` (reason: minimize stalls) with media
    /// buffered ahead of the playhead and the network still delivering, yet
    /// never re-decide to play: rate 1, so the stock transport shows playing,
    /// and the clock stands still until the viewer pauses and plays (SNL
    /// S51E1 at 1:07:24 on the Apple TV sim, 11 s, 25 s and 40+ s in three
    /// runs; access log 25–65 MB arriving meanwhile). Pause/play unsticks it
    /// because the stock play button plays what is buffered immediately; this
    /// does the same, through `stallNudgeIsDue`.
    private func startClockMonitor(player: AVPlayer) {
        clockMonitor?.cancel()
        clockMonitor = Task { @MainActor [weak self, weak player] in
            var last = -1.0
            var still = 0
            var sinceNudge = Int.max
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, let player, self.player === player else { return }
                let now = player.currentTime().seconds
                let status = player.timeControlStatus
                still = (status != .paused && now == last) ? still + 1 : 0
                sinceNudge = sinceNudge == .max ? .max : sinceNudge + 1
                last = now
                guard still > 0 else { continue }
                if AppleInteractionTrace.isEnabled, [2, 5, 10, 20, 40].contains(still) || still % 60 == 0 {
                    let access = self.item?.accessLog()?.events.last
                    let bytes = access.map { "\($0.numberOfBytesTransferred / 1024) KB, stalls \($0.numberOfStalls)" } ?? "no access log"
                    self.traceTransport("clock still \(still)s (\(bytes))")
                }
                guard Self.stallNudgeIsDue(
                    isWaitingToMinimizeStalls: status == .waitingToPlayAtSpecifiedRate
                        && player.reasonForWaitingToPlay == .toMinimizeStalls,
                    bufferEmpty: self.item?.isPlaybackBufferEmpty ?? true,
                    isLive: self.isLiveItem,
                    secondsStill: still,
                    secondsSinceLastNudge: sinceNudge) else { continue }
                sinceNudge = 0
                self.traceTransport("stall nudge after \(still)s")
                player.playImmediately(atRate: player.rate > 0 ? player.rate : 1)
            }
        }
    }

    /// Seconds the clock must stand still in a minimize-stalls wait, with
    /// media buffered, before the engine plays what it has.
    nonisolated static let stallNudgeAfter = 4
    /// At most one nudge this often, so a stream that truly has nothing
    /// left stalls normally instead of being kicked every second.
    nonisolated static let stallNudgeCooldown = 8

    /// See `startClockMonitor`. Never for live: a live wait is the live edge
    /// filling, which AVPlayer handles itself.
    nonisolated static func stallNudgeIsDue(
        isWaitingToMinimizeStalls: Bool, bufferEmpty: Bool, isLive: Bool,
        secondsStill: Int, secondsSinceLastNudge: Int
    ) -> Bool {
        isWaitingToMinimizeStalls && !bufferEmpty && !isLive
            && secondsStill >= stallNudgeAfter
            && secondsSinceLastNudge >= stallNudgeCooldown
    }

    /// One trace line per transport change on this route: what AVPlayer
    /// says it is doing, why it is waiting, and where the clock is.
    private func traceTransport(_ cause: String) {
        guard AppleInteractionTrace.isEnabled, let player else { return }
        let status: String
        switch player.timeControlStatus {
        case .paused: status = "paused"
        case .playing: status = "playing"
        case .waitingToPlayAtSpecifiedRate: status = "waiting"
        @unknown default: status = "unknown"
        }
        let reason = player.reasonForWaitingToPlay?.rawValue ?? "-"
        let time = player.currentTime().seconds
        let keepUp = item?.isPlaybackLikelyToKeepUp ?? false
        let empty = item?.isPlaybackBufferEmpty ?? false
        let loaded = item?.loadedTimeRanges.map(\.timeRangeValue).map {
            "\(Int($0.start.seconds))+\(Int($0.duration.seconds))"
        }.joined(separator: ",") ?? ""
        appleTrace("native \(cause): tcs=\(status) reason=\(reason) rate=\(player.rate) t=\(time.isFinite ? Int(time) : -1) keepUp=\(keepUp) bufferEmpty=\(empty) loaded=[\(loaded)] phase=\(phase)")
    }

    private func finishSeek() {
        isSeeking = false
        derivePhase()
    }

    private func handleEnd() {
        isSeeking = false
        phase = .ended
    }

    /// Within `AppleNextEpisodePolicy.endTolerance` of a known, finite
    /// duration. Never true for live (indefinite duration).
    nonisolated static func isAtEnd(position: Double, duration: Double) -> Bool {
        guard position.isFinite, duration.isFinite, duration > 0 else { return false }
        return position >= duration - AppleNextEpisodePolicy.endTolerance
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
        clockMonitor?.cancel()
        clockMonitor = nil
        captionObservation?.cancel()
        captionObservation = nil
        externalSubtitleLoad?.cancel()
        externalSubtitleLoad = nil
        pendingExternalSubtitleID = nil
        externalSubtitleTracks = []
        embeddedSubtitleTracks = []
        legibleGroup = nil
        legibleOptions = [:]
        activeSubtitleTrackID = nil
        subtitleSelectionOverridden = false
        readyToPlayTracksLoaded = false
        subtitleTracks = []
        subtitleCues = []
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
                message: "This stream uses a format oStream cannot play on this device."
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
