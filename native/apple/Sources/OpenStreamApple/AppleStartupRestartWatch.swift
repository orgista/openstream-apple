import Foundation

/// Closes the producer restart a resume causes before playback starts.
///
/// AVPlayer opens a resumed item at the saved time, and its first segment
/// request can send AetherEngine's producer back to that segment's start. The
/// engine reports the restart as a native scrub and, when it drains, arms a
/// landing watch with the rendered time as "the pre-scrub picture". On a
/// resume that time is already the resume point, above the segment start, so
/// `AetherEngine.nativeScrubLanded` reads a backward scrub and waits for the
/// picture to drop below it. Playback only moves forward, the watch expires
/// after 8 s, and the engine reports `.seeking` until then: the first frame
/// waited 8 s on a test Apple TV (2026-11-04, `seek#1 nativeScrub stalled`).
///
/// This closes such a restart as landed once the picture is in the restarted
/// region and has moved (or the transport is paused on it). Any other seek
/// that begins takes over, and the engine's own outcome ends the watch.
struct AppleStartupRestartWatch: Equatable {
    /// How far below the restarted segment's start a picture may sit and
    /// still count, the engine's own landing tolerance.
    static let tolerance: Double = 0.75
    /// How far the clock must move to show the transport is rolling.
    static let rollEvidence: Double = 0.2

    /// The engine's id for the newest restart, kept after it closes so its
    /// late events stay recognisable.
    private(set) var restartID: UInt64?
    private var target: Double?
    private var firstSample: Double?
    private(set) var hasLanded = false

    /// The engine still reports the restart as a seek, but its picture has
    /// landed.
    var overridesSeeking: Bool { target != nil && hasLanded }

    /// One seek event. `hasPresented`: this load has shown a frame or
    /// played. Events under `restartID` are the startup restart's, not the
    /// viewer's scrub.
    mutating func observe(id: UInt64, isNativeScrub: Bool, began: Bool, target: Double,
                          hasPresented: Bool) {
        if id == restartID {
            if !began { self.target = nil }
            return
        }
        guard began else { return }
        // A restart that moves on before the first frame is the same startup.
        if isNativeScrub, !hasPresented, target.isFinite {
            self = Self(restartID: id, target: target)
        } else {
            self.target = nil
        }
    }

    /// A position tick on the event's axis. Returns true on the tick the
    /// restart lands.
    mutating func observe(position: Double, firstFrameReady: Bool, isPaused: Bool) -> Bool {
        guard let target, !hasLanded, firstFrameReady, position.isFinite,
              position >= target - Self.tolerance else { return false }
        if isPaused {
            hasLanded = true
        } else if let firstSample {
            hasLanded = position >= firstSample + Self.rollEvidence
        } else {
            firstSample = position
        }
        return hasLanded
    }

    /// A seek the app asked for replaces the restart.
    mutating func viewerSeek() { target = nil }
}
