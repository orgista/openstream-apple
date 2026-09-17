import AVFoundation
import AVKit
import Foundation

/// Vends the platform AVKit controller bound to the coordinator's engine.
/// On `.avPlayer` routes the controller's `player` is kept in sync with
/// `engine.avPlayer` so the system player UI — transport, captions, audio,
/// AirPlay, Picture-in-Picture, and Apple's HDR/Atmos pipeline — stays intact.
/// No custom overlay is drawn; nothing is inserted into
/// `contentOverlayView`. On `.surface` routes the controller is idle — the
/// surface view draws the frames and `AppleTransportOverlay` vends the
/// minimal transport UI.
@MainActor
public final class ApplePlayerHost {
    private let coordinator: ApplePlaybackCoordinator
    private let audioSession: AppleAudioSessionCoordinator
    #if canImport(MediaPlayer) && !os(macOS)
    /// The AirPods stem, Control Centre, the lock screen and a car head unit.
    /// Bound to the engine rather than to `AVPlayer`, so it works on the
    /// libavcodec route too — see `AppleRemoteCommandCenter`.
    private let remoteCommands = AppleRemoteCommandCenter()
    #endif

    #if os(macOS)
    private let _playerView: AVPlayerView
    #else
    private let _viewController: AVPlayerViewController
    #endif

    private var boundPlayer: AVPlayer?
    private var bindTimer: Timer?
    private var resumeAfterInterruption = false

    public var route: ApplePlaybackPresentationRoute { coordinator.route }

    #if os(macOS)
    public var playerView: AVPlayerView { _playerView }
    #else
    public var viewController: AVPlayerViewController { _viewController }
    #endif

    public init(coordinator: ApplePlaybackCoordinator, audioSession: AppleAudioSessionCoordinator) {
        self.coordinator = coordinator
        self.audioSession = audioSession
        // Taking AirPods out pauses rather than moving the audio to the device
        // speaker. `AppleAudioRoutePolicy` decides which route changes count;
        // plugging headphones *in* is not one of them.
        audioSession.outputDidDisappear = { [weak coordinator] in
            coordinator?.engine.pause()
        }

        #if os(macOS)
        let view = AVPlayerView()
        // The system player UI: floating controls (no custom overlay).
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        view.allowsPictureInPicturePlayback = true
        // Disable Live Text / "Show Text" frame analysis.
        view.allowsVideoFrameAnalysis = false
        _playerView = view
        #else
        let controller = AVPlayerViewController()
        // Owner decision (plan Task 7e): the stock Apple transport UI on every
        // AVKit route. Subtitles reach the system captions menu through the
        // loopback HLS renditions; the only thing removed is Live Text
        // (`allowsVideoFrameAnalysis = false` below).
        controller.showsPlaybackControls = true
        controller.allowsPictureInPicturePlayback = true
        #if os(iOS)
        // Disable Live Text / "Show Text" frame analysis (`allowsVideoFrameAnalysis`
        // is unavailable on tvOS, which has no Live Text feature to disable).
        controller.allowsVideoFrameAnalysis = false
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        #endif
        #if os(tvOS)
        controller.appliesPreferredDisplayCriteriaAutomatically = false
        #endif
        _viewController = controller
        #endif

        activate()
    }

    public func activate() {
        audioSession.onInterruption = { [weak self] event in
            guard let self else { return }
            switch event {
            case .began:
                self.coordinator.sharedPlayback?.setAudioInterrupted(true)
                self.resumeAfterInterruption = self.coordinator.phase == .playing
                coordinator.engine.pause()
            case .ended(let shouldResume):
                if shouldResume && self.resumeAfterInterruption { coordinator.engine.play() }
                self.coordinator.sharedPlayback?.setAudioInterrupted(false, canResume: shouldResume && self.resumeAfterInterruption)
                self.resumeAfterInterruption = false
            }
        }

        refreshBinding()
        startBindTimer()
    }

    /// Live TV is not rate-adjustable. Clearing AVKit's speed list removes the
    /// stock speed button from both inline and full-screen presentations while
    /// leaving the rest of Apple's player controls intact.
    public func configureLivePlaybackControls() {
        #if os(iOS) || os(tvOS) || os(visionOS)
        _viewController.speeds = []
        #if os(tvOS)
        _viewController.transportBarCustomMenuItems = []
        #endif
        #endif
    }

    /// Stops the engine, tears down the AVKit binding, and deactivates the
    /// shared audio session. Called from the player view's `onDisappear`.
    public func teardown() {
        bindTimer?.invalidate()
        bindTimer = nil
        audioSession.onInterruption = nil
        audioSession.outputDidDisappear = nil
        #if canImport(MediaPlayer) && !os(macOS)
        // Clears the Now Playing entry too, so the lock screen does not keep
        // offering to control a player that has gone.
        remoteCommands.detach()
        #endif
        #if canImport(WatchConnectivity) && os(iOS)
        // Clears the wrist too, so it shows "Nothing Playing" rather than
        // offering transport for a player that has gone.
        AppleWatchCompanion.shared.detach()
        #endif
        #if os(macOS)
        _playerView.player = nil
        #else
        _viewController.player = nil
        #endif
        boundPlayer = nil
        audioSession.deactivate()
    }

    /// Hands the system's transport controls to the engine.
    ///
    /// Called once the request is known, because the Now Playing entry needs
    /// its title and whether it is live (a live stream gets no skip controls
    /// rather than inert ones).
    public func attachRemoteCommands(title: String?, isLive: Bool) {
        #if canImport(MediaPlayer) && !os(macOS)
        remoteCommands.attach(engine: coordinator.engine, title: title, isLive: isLive)
        #endif
        #if canImport(WatchConnectivity) && os(iOS)
        // Same engine, same command rules — the wrist is another remote, not a
        // second implementation.
        AppleWatchCompanion.shared.activate()
        AppleWatchCompanion.shared.attach(engine: coordinator.engine, title: title)
        #endif
    }

    /// Keeps the lock-screen scrubber tracking the player.
    public func refreshRemoteCommands(title: String?, isLive: Bool) {
        #if canImport(MediaPlayer) && !os(macOS)
        remoteCommands.refreshNowPlaying(title: title, isLive: isLive)
        #endif
        #if canImport(WatchConnectivity) && os(iOS)
        AppleWatchCompanion.shared.publish()
        #endif
    }

    /// Binds the controller to whatever the engine holds right now. The 0.25 s
    /// timer below is the safety net; a caller that knows a new stream just
    /// started (a live channel switch) calls this so the picture changes on the
    /// same run loop instead of up to a quarter second later.
    public func rebind() { refreshBinding() }

    /// Rebinds the AVKit controller to `engine.avPlayer` when it changes.
    private func refreshBinding() {
        #if canImport(WatchConnectivity) && os(iOS)
        // The wrist tracks the phase from here: this is the only thing that
        // runs while playback is in flight, and `publish` drops a context that
        // has not changed, so it costs nothing on the quiet ticks.
        AppleWatchCompanion.shared.publish()
        #endif
        let player = coordinator.engine.avPlayer
        if let channel = coordinator.sharePlayChannel {
            AppleSharePlaySessionStore.shared.refreshPlayback(coordinator, channel: channel)
        }
        if let player { coordinator.configureExternalPlayback(on: player) }
        guard player !== boundPlayer else { return }
        boundPlayer = player
        #if os(macOS)
        _playerView.player = player
        #else
        _viewController.player = player
        #endif
    }

    private func startBindTimer() {
        bindTimer?.invalidate()
        bindTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshBinding() }
        }
    }

    isolated deinit { bindTimer?.invalidate() }
}
