import Foundation

/// A server trailer's handover between its still and its video
/// (`AppleServerTrailerPlayback` applies it). A trailer taken down while it
/// is on screen — ended, failed, concealed or started over — is held on its
/// last frame with its sound fading while the still crossfades back over
/// it, and is let go only once the still is up: the Apple TV app's hero
/// (REA 2026-10-29: pause on the last frame, still back, then stop). One
/// that was never seen just stops.
struct AppleServerTrailerHandover: Equatable {
    enum Phase: Equatable { case idle, loading, playing, ended, failed }

    /// What becomes of the player that was running.
    enum Takedown: Equatable {
        case none
        /// Never seen: stopped at once.
        case discard
        /// Seen: paused on its last frame, its sound faded out over `soundFade`.
        case hold(soundFade: TimeInterval)
    }

    /// The player the layer draws.
    enum Shown: Equatable { case current, held }

    /// The still ↔ video crossfade (0 with Reduce Motion).
    var crossfade: TimeInterval
    private(set) var phase: Phase = .idle
    private(set) var holdsLastFrame = false

    init(crossfade: TimeInterval = AppleTrailerArtFirstPolicy.crossfadeDuration) {
        self.crossfade = crossfade
    }

    /// The held frame stays drawn until the new video is revealed over it.
    var shown: Shown { phase != .playing && holdsLastFrame ? .held : .current }

    mutating func start() -> Takedown {
        let takedown = takeDown()
        phase = .loading
        return takedown
    }

    /// The video shows a real picture: it crossfades in, any held frame goes,
    /// and its sound comes up this long later, once the crossfade is done.
    mutating func reveal() -> TimeInterval? {
        guard phase == .loading else { return nil }
        phase = .playing
        holdsLastFrame = false
        return crossfade
    }

    mutating func finish(_ end: Phase) -> Takedown {
        guard phase == .loading || phase == .playing else { return .none }
        let takedown = takeDown()
        phase = end
        return takedown
    }

    mutating func conceal() -> Takedown {
        let takedown = takeDown()
        phase = .idle
        return takedown
    }

    /// The still is back over the video: whether a held player can go.
    mutating func stillIsUp() -> Bool {
        guard phase != .playing, holdsLastFrame else { return false }
        holdsLastFrame = false
        return true
    }

    mutating func stop() {
        phase = .idle
        holdsLastFrame = false
    }

    private mutating func takeDown() -> Takedown {
        switch phase {
        case .playing:
            holdsLastFrame = true
            return .hold(soundFade: crossfade)
        case .loading:
            return .discard
        case .idle, .ended, .failed:
            return .none
        }
    }
}
