#if os(macOS)
import AVFoundation
import SwiftUI

extension ApplePlaybackCoordinator {
    /// This session's answers to the Mac Controls menu.
    ///
    /// Closures rather than a reference to the coordinator, because the menu is
    /// built once for the whole app and there is one coordinator per playback
    /// session. Weakly captured: the menu outlives the player, and a strong
    /// capture here would keep a finished session's engine alive.
    func macPlaybackControls(id: UUID) -> AppleMacPlaybackControls {
        let mute = AppleMacMuteMemory()
        return AppleMacPlaybackControls(
            id: id,
            togglePlayPause: { [weak self] in
                guard let self else { return }
                // Resolved against what is happening now, the same way an
                // AirPods stem press is (`AppleRemoteCommandPolicy`), so one
                // key does both jobs instead of being a third action.
                if phase == .playing { userPause() } else { userPlay() }
            },
            skipForward: { [weak self] in self?.macSkip(by: AppleRemoteCommand.skipInterval) },
            skipBackward: { [weak self] in self?.macSkip(by: -AppleRemoteCommand.skipInterval) },
            volumeUp: { [weak self] in self?.macStepVolume(AppleMacVolumeStep.raised, mute: mute) },
            volumeDown: { [weak self] in self?.macStepVolume(AppleMacVolumeStep.lowered, mute: mute) },
            toggleMute: { [weak self] in self?.macToggleMute(mute) }
        )
    }

    /// The session's volume. The Aether engine routes it to whichever host is
    /// playing (its AVPlayer or its own renderer); the native engine is an
    /// AVPlayer.
    private var macVolume: Float? {
        get {
            if let aether = engine as? AetherPlaybackEngine { return aether.aetherEngine.volume }
            return engine.avPlayer?.volume
        }
        set {
            guard let newValue else { return }
            if let aether = engine as? AetherPlaybackEngine {
                aether.aetherEngine.volume = newValue
            } else {
                engine.avPlayer?.volume = newValue
            }
        }
    }

    /// A volume key unmutes first, as it does in the Apple TV app.
    private func macStepVolume(_ step: (Float) -> Float, mute: AppleMacMuteMemory) {
        if isMacMuted(mute) { macToggleMute(mute) }
        guard let volume = macVolume else { return }
        macVolume = step(volume)
    }

    /// AVPlayer's own mute where there is an AVPlayer, so AVPlayerView's
    /// controls and the overlay's speaker glyph show it. Aether's software
    /// renderer has no mute, so there it is volume 0 and back.
    private func macToggleMute(_ mute: AppleMacMuteMemory) {
        if let player = engine.avPlayer {
            player.isMuted.toggle()
        } else if let restore = mute.volumeBeforeMute {
            mute.volumeBeforeMute = nil
            macVolume = restore
        } else if let volume = macVolume {
            mute.volumeBeforeMute = volume
            macVolume = 0
        }
    }

    private func isMacMuted(_ mute: AppleMacMuteMemory) -> Bool {
        if let player = engine.avPlayer { return player.isMuted }
        return mute.volumeBeforeMute != nil
    }

    private func macSkip(by offset: Double) {
        let destination = AppleRemoteCommandPolicy.destination(
            from: engine.position,
            offset: offset,
            duration: engine.duration
        )
        Task { await userSeek(to: destination) }
    }
}

/// The volume a software-rendered session had before Controls ▸ Mute, for
/// the next Mute (or volume key) to put back. One per installation.
@MainActor
private final class AppleMacMuteMemory {
    var volumeBeforeMute: Float?
}

extension View {
    /// Lends the Mac Controls menu to this player for as long as it is on
    /// screen.
    ///
    /// The menu items are disabled while nothing is installed, and a disabled
    /// menu item does not claim its key equivalent — which is the only reason
    /// the bare space bar can be the play/pause key without making it
    /// impossible to type a space into a text field anywhere else in the app.
    func appleMacPlaybackCommands(_ coordinator: ApplePlaybackCoordinator) -> some View {
        modifier(AppleMacPlaybackCommandsModifier(coordinator: coordinator))
    }
}

private struct AppleMacPlaybackCommandsModifier: ViewModifier {
    let coordinator: ApplePlaybackCoordinator
    /// Identifies this installation so a player being dismissed over another
    /// one cannot clear the menu the visible player just claimed.
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .onAppear {
                AppleMacCommandCenter.shared.install(coordinator.macPlaybackControls(id: id))
            }
            .onDisappear {
                AppleMacCommandCenter.shared.remove(id: id)
            }
    }
}
#endif
