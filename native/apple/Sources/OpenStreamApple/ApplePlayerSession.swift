import AVFoundation
import Foundation
#if os(iOS) || os(tvOS) || os(visionOS)
import MediaPlayer
#endif

/// Shared AVPlayer setup used by every platform host. Spatial rendering and
/// external playback remain system-controlled; OpenStream only declares the
/// layouts it can supply and leaves AirPods/AirPlay choices to the user.
@MainActor
public final class ApplePlayerSession {
    public let playerItem: AVPlayerItem
    public let player: AVPlayer
    public let progressCoordinator: ApplePlaybackProgressCoordinator
    public let mediaIdentity: String
    public let requestHeaders: [String: String]
    public let title: String?
    public let playbackURL: URL
    public var onPlaybackFailure: (@MainActor @Sendable (ApplePlaybackFailure) -> Void)?

    private var itemStatusObservation: NSKeyValueObservation?
    private var failedToPlayObserver: NSObjectProtocol?
    private var hasReportedPlaybackFailure = false
    private var isStopped = false
    #if os(iOS) || os(tvOS) || os(visionOS)
    private var timeControlObservation: NSKeyValueObservation?
    private var periodicTimeObserver: Any?
    #endif

    public init(
        url: URL,
        resumeAt seconds: Double = 0,
        mediaID: String? = nil,
        progressStore: ApplePlaybackStore? = nil,
        requestHeaders: [String: String] = [:],
        title: String? = nil
    ) {
        let store = progressStore ?? ApplePlaybackStore()
        let identity = mediaID.flatMap(ApplePlaybackIdentity.storageKey(for:))
            ?? ApplePlaybackIdentity.storageKey(for: url)
        mediaIdentity = identity
        playbackURL = url
        self.requestHeaders = requestHeaders
        let cleanTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.title = cleanTitle.isEmpty ? nil : String(cleanTitle.prefix(200))

        // Header-bearing provider URLs are converted to a scoped loopback URL
        // before this point. Keep the native player on documented AVFoundation
        // APIs so behavior remains stable across iOS and tvOS releases.
        let item = AVPlayerItem(url: url)
        item.allowedAudioSpatializationFormats = .monoStereoAndMultichannel
        playerItem = item

        let player = AVPlayer(playerItem: item)
        #if !os(visionOS)
        player.allowsExternalPlayback = requestHeaders.isEmpty && !Self.isLoopback(url)
        #endif
        #if os(iOS) || os(tvOS)
        player.usesExternalPlaybackWhileExternalScreenIsActive = player.allowsExternalPlayback
        #endif
        self.player = player

        let savedPosition = store.progress(for: identity)?.resumePosition ?? 0
        let requestedPosition = seconds.isFinite && seconds > 0 ? seconds : savedPosition
        if requestedPosition > 0 {
            player.seek(to: CMTime(seconds: requestedPosition, preferredTimescale: 600))
        }

        let coordinator = ApplePlaybackProgressCoordinator(
            store: store,
            mediaIdentity: identity
        )
        progressCoordinator = coordinator
        coordinator.startObserving(player)
        startFailureObservation()
        #if os(iOS) || os(tvOS) || os(visionOS)
        startNowPlayingUpdates()
        #endif
    }

    /// Consumes the result of `ApplePlaybackPreparer` directly. Gateway
    /// preparation returns a scoped bearer URL, never global auth headers.
    public convenience init(
        preparedPlayback: ApplePreparedPlayback,
        resumeAt seconds: Double = 0,
        mediaID: String? = nil,
        progressStore: ApplePlaybackStore? = nil,
        title: String? = nil
    ) {
        self.init(
            url: preparedPlayback.url,
            resumeAt: seconds,
            mediaID: mediaID,
            progressStore: progressStore,
            requestHeaders: preparedPlayback.requestHeaders,
            title: title
        )
    }

    public func savePlaybackProgress() {
        progressCoordinator.saveCurrentProgress()
    }

    #if os(iOS) || os(tvOS) || os(visionOS)
    public func handleAudioInterruption(_ event: AppleAudioInterruptionEvent) {
        switch event {
        case .began:
            player.pause()
        case .ended(let shouldResume):
            if shouldResume { player.play() }
        }
        refreshNowPlayingInfo()
    }
    #endif

    public func stop(saveProgress: Bool = true) {
        guard !isStopped else { return }
        isStopped = true
        onPlaybackFailure = nil
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        if let failedToPlayObserver {
            NotificationCenter.default.removeObserver(failedToPlayObserver)
            self.failedToPlayObserver = nil
        }
        progressCoordinator.stopObserving(saveCurrentProgress: saveProgress)
        player.pause()
        #if os(iOS) || os(tvOS) || os(visionOS)
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        if let periodicTimeObserver {
            player.removeTimeObserver(periodicTimeObserver)
            self.periodicTimeObserver = nil
        }
        if MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == title {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            MPNowPlayingInfoCenter.default().playbackState = .stopped
        }
        #endif
        let url = playbackURL
        Task {
            await AppleProtectedHTTPPlaybackServer.shared.revoke(playbackURL: url)
            await AppleSMBRangeServer.shared.revoke(playbackURL: url)
        }
    }

    private func startFailureObservation() {
        itemStatusObservation = playerItem.observe(\.status, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.reportPlaybackFailureIfNeeded() }
        }
        failedToPlayObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: playerItem,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reportPlaybackFailureIfNeeded(force: true) }
        }
    }

    private func reportPlaybackFailureIfNeeded(force: Bool = false) {
        guard !isStopped, !hasReportedPlaybackFailure,
              force || playerItem.status == .failed || player.error != nil else { return }
        hasReportedPlaybackFailure = true
        onPlaybackFailure?(ApplePlaybackFailure.classify(
            playerItem.error ?? player.error ?? URLError(.cannotDecodeContentData)
        ))
    }

    #if os(iOS) || os(tvOS) || os(visionOS)
    private func startNowPlayingUpdates() {
        guard title != nil else { return }
        refreshNowPlayingInfo()
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refreshNowPlayingInfo() }
        }
        periodicTimeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshNowPlayingInfo() }
        }
    }

    func refreshNowPlayingInfo() {
        guard !isStopped, let title else { return }
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyTitle] = title
        let elapsed = player.currentTime().seconds
        if elapsed.isFinite, elapsed >= 0 {
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        }
        let duration = playerItem.duration.seconds
        if duration.isFinite, duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        info[MPNowPlayingInfoPropertyPlaybackRate] = player.rate
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = player.defaultRate
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        center.playbackState = player.rate > 0 ? .playing : .paused
    }
    #endif

    private static func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }
}
