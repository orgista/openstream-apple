import Foundation

#if canImport(MediaPlayer) && !os(macOS)
import MediaPlayer
#endif

/// What a remote command should do, independent of MediaPlayer.
///
/// Kept as plain values so the mapping is testable on every platform — the
/// same reason `AppleAudioRoutePolicy` restates its reasons.
public enum AppleRemoteCommand: Equatable, Sendable {
    case play
    case pause
    case toggle
    case skipForward(Double)
    case skipBackward(Double)

    /// The app's own skip distance, matching the clickpad edges and the
    /// on-screen glyphs, so every way of skipping moves the same amount.
    public static let skipInterval: Double = 10
}

/// Resolves a command against what is playing now.
public enum AppleRemoteCommandPolicy: Sendable {
    /// `toggle` is the one an AirPods stem press sends, so it has to resolve
    /// against the current state rather than being a third action.
    public static func resolve(_ command: AppleRemoteCommand, isPlaying: Bool) -> AppleRemoteCommand {
        guard command == .toggle else { return command }
        return isPlaying ? .pause : .play
    }

    /// Where a skip lands, clamped into the item. Skipping past the end would
    /// otherwise end playback, which is not what a viewer nudging forward
    /// means.
    public static func destination(
        from position: Double,
        offset: Double,
        duration: Double?
    ) -> Double {
        let target = position + offset
        guard let duration, duration.isFinite, duration > 0 else { return max(0, target) }
        return min(duration, max(0, target))
    }
}

#if canImport(MediaPlayer) && !os(macOS)
/// Wires the system's remote commands — the AirPods stem, Control Centre, the
/// lock screen, a car head unit — to whatever engine is playing.
///
/// This talks to `ApplePlaybackEngine`, not to `AVPlayer`, on purpose. Most of
/// the owner's content takes the libavcodec route, which draws into a sample
/// buffer layer and has no `AVPlayer` for the system to control — so anything
/// built on AVPlayer alone would leave a stem press doing nothing on exactly
/// the content that needs it most.
@MainActor
public final class AppleRemoteCommandCenter {
    private weak var engine: (any ApplePlaybackEngine)?
    private var handlers: [Any] = []
    private var isAttached = false

    public init() {}

    public func attach(engine: any ApplePlaybackEngine, title: String?, isLive: Bool) {
        self.engine = engine
        guard !isAttached else { return }
        isAttached = true

        let center = MPRemoteCommandCenter.shared()
        handlers.append(center.playCommand.addTarget { [weak self] _ in
            self?.perform(.play) ?? .commandFailed
        })
        handlers.append(center.pauseCommand.addTarget { [weak self] _ in
            self?.perform(.pause) ?? .commandFailed
        })
        handlers.append(center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.perform(.toggle) ?? .commandFailed
        })

        // A live stream has nowhere to skip to, so the controls are removed
        // rather than left present and inert.
        center.skipForwardCommand.isEnabled = !isLive
        center.skipBackwardCommand.isEnabled = !isLive
        if !isLive {
            center.skipForwardCommand.preferredIntervals = [NSNumber(value: AppleRemoteCommand.skipInterval)]
            center.skipBackwardCommand.preferredIntervals = [NSNumber(value: AppleRemoteCommand.skipInterval)]
            handlers.append(center.skipForwardCommand.addTarget { [weak self] _ in
                self?.perform(.skipForward(AppleRemoteCommand.skipInterval)) ?? .commandFailed
            })
            handlers.append(center.skipBackwardCommand.addTarget { [weak self] _ in
                self?.perform(.skipBackward(AppleRemoteCommand.skipInterval)) ?? .commandFailed
            })
        }
        publishNowPlaying(title: title, isLive: isLive)
    }

    public func detach() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.skipForwardCommand.removeTarget(nil)
        center.skipBackwardCommand.removeTarget(nil)
        handlers.removeAll()
        isAttached = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        engine = nil
    }

    /// Refreshes position and rate so the scrubber on the lock screen and in
    /// Control Centre tracks the player.
    public func refreshNowPlaying(title: String?, isLive: Bool) {
        publishNowPlaying(title: title, isLive: isLive)
    }

    @discardableResult
    private func perform(_ command: AppleRemoteCommand) -> MPRemoteCommandHandlerStatus {
        guard let engine else { return .noSuchContent }
        let isPlaying = engine.phase == .playing
        switch AppleRemoteCommandPolicy.resolve(command, isPlaying: isPlaying) {
        case .play:
            engine.play()
        case .pause:
            engine.pause()
        case .skipForward(let offset), .skipBackward(let offset):
            let signed = if case .skipBackward = command { -offset } else { offset }
            let target = AppleRemoteCommandPolicy.destination(
                from: engine.position, offset: signed, duration: engine.duration
            )
            Task { await engine.seek(to: target) }
        case .toggle:
            return .commandFailed
        }
        appleTrace("remote command \(command)")
        return .success
    }

    private func publishNowPlaying(title: String?, isLive: Bool) {
        guard let engine else { return }
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = title ?? "OpenStream"
        info[MPNowPlayingInfoPropertyIsLiveStream] = isLive
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = engine.position
        info[MPNowPlayingInfoPropertyPlaybackRate] = engine.phase == .playing ? 1.0 : 0.0
        if let duration = engine.duration, duration.isFinite, duration > 0, !isLive {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        center.playbackState = engine.phase == .playing ? .playing : .paused
    }
}
#endif
