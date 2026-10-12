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

    #if os(iOS) || os(macOS)
    private lazy var subtitleSelection = ApplePlayerSubtitleSelection(engine: coordinator.engine)
    private var mirrorsSubtitleSelection = false
    #endif
    #if !os(tvOS)
    /// Picture in Picture and external screens, for the caption handoff.
    private let pictureInPicture = ApplePictureInPictureWatcher()
    private var externalPictureActive = false
    #endif
    #if os(tvOS)
    /// Picture in Picture: the stock controller's own window on demand, and
    /// the live player's from `pictureInPictureLayerView` (`AppleTVPictureInPicture`).
    private let pictureInPictureDelegate = AppleTVPictureInPictureDelegate()
    let pictureInPictureLayerView = AppleTVPictureInPictureLayerView()
    private var pictureInPictureController: AVPictureInPictureController?
    #endif
    private var boundPlayer: AVPlayer?
    private var bindTimer: Timer?
    private var resumeAfterInterruption = false

    public var route: ApplePlaybackPresentationRoute { coordinator.route }

    var keepsPlaybackForPictureInPicture: Bool {
        #if !os(tvOS)
        pictureInPicture.isStartingOrActive
        #else
        pictureInPictureController?.isPictureInPictureActive == true
        #endif
    }

    #if os(macOS)
    public var playerView: AVPlayerView { _playerView }
    #else
    public var viewController: AVPlayerViewController { _viewController }
    #endif

    public init(coordinator: ApplePlaybackCoordinator, audioSession: AppleAudioSessionCoordinator,
                activateImmediately: Bool = true) {
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
        // No AVKit full-screen button: the app's player takes over the window
        // instead (`AppleMacPlayerViewRepresentable`).
        view.showsFullScreenToggleButton = false
        view.allowsPictureInPicturePlayback = true
        // Disable Live Text / "Show Text" frame analysis.
        view.allowsVideoFrameAnalysis = false
        view.pictureInPictureDelegate = pictureInPicture
        _playerView = view
        #else
        let controller = AVPlayerViewController()
        // Owner decision (plan Task 7e): the stock Apple transport UI on every
        // AVKit route. The app draws overlay subtitles; the iOS full-screen
        // bridge can hand a chosen legible rendition to AVKit, as PiP and
        // AirPlay do. The only thing removed is Live Text
        // (`allowsVideoFrameAnalysis = false` below).
        controller.showsPlaybackControls = true
        controller.allowsPictureInPicturePlayback = true
        #if os(visionOS)
        if #available(visionOS 26.0, *) {
            // In the app's window, and AVKit's own expanded view; no
            // immersive button until the owner decides on one (2026-10-07).
            controller.experienceController.allowedExperiences = .only([.embedded, .expanded])
        }
        #endif
        #if os(iOS)
        // Disable Live Text / "Show Text" frame analysis (`allowsVideoFrameAnalysis`
        // is unavailable on tvOS, which has no Live Text feature to disable).
        controller.allowsVideoFrameAnalysis = false
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        #endif
        #if !os(tvOS)
        controller.delegate = pictureInPicture
        #else
        controller.delegate = pictureInPictureDelegate
        #endif
        #if os(tvOS)
        controller.appliesPreferredDisplayCriteriaAutomatically = AppleDisplayCriteriaPolicy.automaticAVKitMatching(engine: coordinator.engine.kind)
        // AVKit treats an empty language array as unrestricted on tvOS 26.
        // zxx (no linguistic content) excludes spoken-language renditions;
        // the app owns Off/Auto too, so remove those rows before binding.
        controller.allowedSubtitleOptionLanguages = ["zxx"]
        controller.requiresFullSubtitles = true
        #endif
        _viewController = controller
        #endif

        #if !os(tvOS)
        pictureInPicture.onChange = { [weak self] _ in self?.refreshPictureWhereabouts() }
        #else
        pictureInPictureDelegate.host = self
        #endif
        if activateImmediately { activate() }
    }

    /// A Picture in Picture window started or stopped by something other
    /// than the stock player's own button (the DEBUG captions probe).
    func pictureInPictureDidChange(_ active: Bool) {
        #if !os(tvOS)
        pictureInPicture.set(active, source: .other, event: active ? "started elsewhere" : "stopping elsewhere")
        #endif
    }

    /// Tells the default engine whether the picture is somewhere the app's
    /// cue layer cannot follow, so it can hand the film's captions to AVKit
    /// there (`AppleCaptionHandoff`). Apple TV declares its renditions
    /// always and has nothing to hand over.
    private func refreshPictureWhereabouts() {
        #if !os(tvOS)
        guard let aether = coordinator.engine as? AetherPlaybackEngine else { return }
        #if os(visionOS)
        // No external playback on Vision: the picture is always the wearer's.
        let playerReportsExternal = false
        #else
        let playerReportsExternal = coordinator.engine.avPlayer?.isExternalPlaybackActive ?? false
        #endif
        externalPictureActive = AppleCaptionHandoff.externalPictureActive(
            playerReportsExternal: playerReportsExternal,
            externalRouteHoldsAudio: Self.externalRouteHoldsAudio,
            wasActive: externalPictureActive)
        aether.setPictureWhereabouts(pictureInPicture: pictureInPicture.isActive, external: externalPictureActive)
        #endif
    }

    /// An AirPlay receiver or an HDMI screen holds the audio route. Survives
    /// the item rebuild that briefly clears `isExternalPlaybackActive`
    /// (AetherEngine #227).
    private static var externalRouteHoldsAudio: Bool {
        #if os(iOS)
        AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .airPlay || $0.portType == .HDMI }
        #else
        false
        #endif
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
    public func teardown(deactivateAudioSession: Bool = true) {
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
        #if os(tvOS)
        AppleDevicePlaybackBeacon.shared.detach()
        #endif
        #if os(macOS)
        _playerView.player = nil
        #else
        _viewController.player = nil
        #endif
        #if os(tvOS)
        pictureInPictureDidStop()
        #endif
        #if os(iOS) || os(macOS)
        if mirrorsSubtitleSelection { subtitleSelection.bind(to: nil) }
        mirrorsSubtitleSelection = false
        #endif
        boundPlayer = nil
        if deactivateAudioSession { audioSession.deactivate() }
    }

    /// Hands the system's transport controls to the engine.
    ///
    /// Called once the request is known, because the Now Playing entry needs
    /// its title and whether it is live (a live stream gets no skip controls
    /// rather than inert ones).
    public func attachRemoteCommands(title: String?, isLive: Bool) {
        attachRemoteCommands(metadata: AppleNowPlayingMetadata(title: title, isLive: isLive))
    }

    /// The same, with the series line and the poster from the request.
    public func attachRemoteCommands(request: ApplePlaybackRequest) {
        attachRemoteCommands(metadata: AppleNowPlayingMetadata(request: request))
    }

    private func attachRemoteCommands(metadata: AppleNowPlayingMetadata) {
        #if canImport(MediaPlayer) && !os(macOS)
        remoteCommands.attach(engine: coordinator.engine, metadata: metadata)
        #endif
        #if canImport(WatchConnectivity) && os(iOS)
        // Same engine, same command rules — the wrist is another remote, not a
        // second implementation.
        AppleWatchCompanion.shared.activate()
        AppleWatchCompanion.shared.attach(engine: coordinator.engine, title: metadata.knownTitle)
        #endif
        #if os(tvOS)
        // The television has no watch of its own to talk to; it leaves a note
        // in the shared key-value store instead, and any watch on the account
        // can read it. See `AppleDevicePlaybackBeacon`.
        AppleDevicePlaybackBeacon.shared.attach(engine: coordinator.engine, title: metadata.knownTitle)
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
        #if os(tvOS)
        AppleDevicePlaybackBeacon.shared.publish()
        #endif
    }

    /// Binds the controller to whatever the engine holds right now. The 0.25 s
    /// timer below is the safety net; a caller that knows a new stream just
    /// started (a live channel switch) calls this so the picture changes on the
    /// same run loop instead of up to a quarter second later.
    public func rebind() { refreshBinding() }

    /// Whether this platform's stock player shows its own captions menu, so
    /// a choice made there has to reach the engine (`ApplePlayerSubtitleSelection`).
    ///
    /// The Mac was left out, and its CC menu did nothing (owner, 2026-09-24).
    /// On the default engine the legible group is pinned deselected while the
    /// app owns captions, so AVKit's select was undone the moment it landed;
    /// on the AVPlayer engine the choice held only until the next add-on batch
    /// re-applied the captions setting over it. The mirror is what tells the
    /// engine the viewer chose, on iPhone and on the Mac alike. Apple TV hides
    /// the stock rows and drives selection from its own menu instead.
    static var mirrorsStockSubtitleSelection: Bool {
        #if os(iOS) || os(macOS)
        true
        #else
        false
        #endif
    }

    #if os(iOS) || os(macOS)
    func enableSubtitleSelectionMirroring() {
        mirrorsSubtitleSelection = true
        appleTrace("subtitle mirror: engine=\(coordinator.engine.kind.rawValue)")
        subtitleSelection.bind(to: coordinator.engine.avPlayer?.currentItem)
    }

    func selectSubtitleTrack(id: Int?) {
        appleTrace("subtitle mirror: app=\(id.map(String.init) ?? "off")")
        subtitleSelection.selectFromApp(id: id)
    }
    #endif

    #if os(tvOS)
    /// Opens the window from the live player's layer
    /// (`AppleTVPictureInPictureLayerView`, mounted under the stock
    /// controller). `false` when this stream or device cannot.
    func startPictureInPicture() async -> Bool {
        guard AppleTVPictureInPicturePolicy.allowsPictureInPicture(route: coordinator.route),
              AVPictureInPictureController.isPictureInPictureSupported(),
              let player = coordinator.engine.avPlayer else { return false }
        let layer = pictureInPictureLayerView.playerLayer
        layer.player = player
        let controller = pictureInPictureController
            ?? AVPictureInPictureController(contentSource: .init(playerLayer: layer))
        controller.delegate = pictureInPictureDelegate
        pictureInPictureController = controller
        // Possible once the layer has a frame ready to hand over.
        for _ in 0..<30 where !controller.isPictureInPicturePossible {
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { break }
        }
        guard controller.isPictureInPicturePossible, !Task.isCancelled else {
            appleTrace("picture in picture: not possible on this stream")
            pictureInPictureDidStop()
            return false
        }
        controller.startPictureInPicture()
        return true
    }

    /// Closes a window opened from the live player's layer. A window from
    /// the stock controller closes when `teardown` takes its player away.
    func stopPictureInPicture() {
        pictureInPictureController?.stopPictureInPicture()
    }

    /// The window is gone: the layer under the controller lets go of the
    /// player so the picture is not composited twice.
    func pictureInPictureDidStop() {
        guard pictureInPictureController?.isPictureInPictureActive != true else { return }
        pictureInPictureController = nil
        pictureInPictureLayerView.playerLayer.player = nil
    }
    #endif

    /// Rebinds the AVKit controller to `engine.avPlayer` when it changes.
    private func refreshBinding() {
        #if canImport(WatchConnectivity) && os(iOS)
        // The wrist tracks the phase from here: this is the only thing that
        // runs while playback is in flight, and `publish` drops a context that
        // has not changed, so it costs nothing on the quiet ticks.
        AppleWatchCompanion.shared.publish()
        #endif
        #if os(tvOS)
        // Same reasoning as the wrist above: this is the one thing that runs
        // while playback is in flight, and a write that would change nothing
        // is dropped before it reaches iCloud.
        AppleDevicePlaybackBeacon.shared.publish()
        #endif
        let player = coordinator.engine.avPlayer
        #if os(tvOS)
        _viewController.appliesPreferredDisplayCriteriaAutomatically = AppleDisplayCriteriaPolicy.automaticAVKitMatching(engine: coordinator.engine.kind)
        // AVKit's window button only where the window can show the picture.
        let allowsPictureInPicture = AppleTVPictureInPicturePolicy.allowsPictureInPicture(route: coordinator.route)
        if _viewController.allowsPictureInPicturePlayback != allowsPictureInPicture {
            _viewController.allowsPictureInPicturePlayback = allowsPictureInPicture
        }
        // A live reconnect can replace the AVPlayer while the window is up.
        let pictureInPictureLayer = pictureInPictureLayerView.playerLayer
        if pictureInPictureLayer.player != nil, let player, pictureInPictureLayer.player !== player {
            pictureInPictureLayer.player = player
        }
        #endif
        if let channel = coordinator.sharePlayChannel {
            AppleSharePlaySessionStore.shared.refreshPlayback(coordinator, channel: channel)
        }
        if let player { coordinator.configureExternalPlayback(on: player) }
        refreshPictureWhereabouts()
        refreshOutputInfo(on: player?.currentItem)
        #if os(iOS) || os(macOS)
        // The item can change without replacing the AVPlayer (recovery/seek).
        if mirrorsSubtitleSelection { subtitleSelection.bind(to: player?.currentItem) }
        #endif
        guard player !== boundPlayer else { return }
        boundPlayer = player
        #if os(macOS)
        _playerView.player = player
        #else
        _viewController.player = player
        #endif
    }

    /// AVKit presents description metadata in its existing Info panel. Keep
    /// it current across seeks, item replacement and display-mode changes.
    private func refreshOutputInfo(on item: AVPlayerItem?) {
        #if os(iOS) || os(tvOS) || os(visionOS)
        guard let item else { return }
        let identifier = AVMetadataIdentifier.commonIdentifierDescription
        let line = coordinator.engine.outputInfo.line
        let current = item.externalMetadata.first { $0.identifier == identifier }?.stringValue
        guard current != line else { return }
        var metadata = item.externalMetadata.filter { $0.identifier != identifier }
        if let line {
            let description = AVMutableMetadataItem()
            description.identifier = identifier
            description.value = line as NSString
            description.extendedLanguageTag = "und"
            metadata.append(description)
        }
        item.externalMetadata = metadata
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
