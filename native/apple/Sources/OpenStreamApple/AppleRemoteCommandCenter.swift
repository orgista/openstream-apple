import Foundation

#if canImport(MediaPlayer) && !os(macOS)
import MediaPlayer
import UIKit
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
    private var metadata = AppleNowPlayingMetadata(title: nil, isLive: false)
    private var artwork: (url: URL, value: MPMediaItemArtwork)?
    private var artworkLoad: Task<Void, Never>?
    /// Republishes on phase and duration changes: attached before the item
    /// loads, the entry otherwise kept no duration and a paused rate.
    private var engineObservation: Task<Void, Never>?

    public init() {}

    public func attach(engine: any ApplePlaybackEngine, title: String?, isLive: Bool) {
        attach(engine: engine, metadata: AppleNowPlayingMetadata(title: title, isLive: isLive))
    }

    public func attach(engine: any ApplePlaybackEngine, metadata: AppleNowPlayingMetadata) {
        let isLive = metadata.isLive
        self.metadata = metadata
        loadArtwork(metadata.artworkURL)
        if self.engine !== engine {
            self.engine = engine
            engineObservation?.cancel()
            engineObservation = Task { [weak self, weak engine] in
                guard let events = engine?.events else { return }
                for await event in events {
                    guard let self, !Task.isCancelled else { return }
                    switch event {
                    case .phase, .duration: self.publishNowPlaying()
                    case .position, .route, .tracks, .failure: break
                    }
                }
            }
        }
        guard !isAttached else {
            publishNowPlaying()
            return
        }
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
        publishNowPlaying()
    }

    public func detach() {
        engineObservation?.cancel()
        engineObservation = nil
        artworkLoad?.cancel()
        artworkLoad = nil
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
        publishNowPlaying()
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

    private func publishNowPlaying() {
        guard let engine else { return }
        var info = metadata.nowPlayingInfo(position: engine.position, duration: engine.duration,
                                           isPlaying: engine.phase == .playing)
        if let artwork, artwork.url == metadata.artworkURL {
            info[MPMediaItemPropertyArtwork] = artwork.value
        }
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        center.playbackState = engine.phase == .playing ? .playing : .paused
        appleTrace("now playing title=\"\(metadata.title)\" series=\(metadata.seriesTitle != nil) live=\(metadata.isLive) artwork=\(info[MPMediaItemPropertyArtwork] != nil) duration=\(info[MPMediaItemPropertyPlaybackDuration] != nil)")
    }

    /// MediaPlayer calls the request handler on its own queue. Built in a
    /// nonisolated context so the closure doesn't inherit main-actor
    /// isolation (a main-actor closure traps with dispatch_assert_queue_fail
    /// there — every VOD play with artwork crashed, Apple TV 2026-10-02).
    nonisolated private static func artwork(for picture: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: picture.size) { @Sendable _ in picture }
    }

    /// The poster from the app's own image cache, then the entry again.
    private func loadArtwork(_ url: URL?) {
        guard let url else { artwork = nil; return }
        guard artwork?.url != url else { return }
        artworkLoad?.cancel()
        artworkLoad = Task { [weak self] in
            guard let image = try? await AppleRemoteImageCache.shared.image(url: url, maximumPixelDimension: 600),
                  !Task.isCancelled, let self else { return }
            let picture = UIImage(cgImage: image)
            let value = Self.artwork(for: picture)
            self.artwork = (url, value)
            self.publishNowPlaying()
        }
    }
}
#endif
