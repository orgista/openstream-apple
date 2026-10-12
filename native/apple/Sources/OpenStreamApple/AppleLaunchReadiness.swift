import Observation

/// Whether the first screen has something worth looking at yet.
///
/// The iPhone and iPad brand cover used to lift on a fixed 1.3 s timer that
/// started after the first frame, so a Discover billboard ready at ~0.97 s
/// sat hidden behind it until ~2.1 s (iPhone 16 Pro sim, 2026-09-23). The
/// billboard reports here once its still has drawn (or failed), and the
/// cover lifts then; the old timer stays as the cap, so a launch that never
/// reports — another tab, no sources — behaves exactly as before.
@MainActor
@Observable
public final class AppleLaunchReadiness {
    public static let shared = AppleLaunchReadiness()

    public private(set) var firstScreenIsReady = false

    public init() {}

    public func markFirstScreenReady() {
        guard !firstScreenIsReady else { return }
        firstScreenIsReady = true
        #if DEBUG
        AppleLaunchClock.mark("first.screen.ready")
        #endif
    }
}

/// How long the launch cover holds.
public enum AppleLaunchCoverPolicy {
    /// The cover never holds longer than this after it first draws — the
    /// timer it had before it listened for the first screen.
    public static func maximumHold(reduceMotion: Bool) -> Duration {
        reduceMotion ? .milliseconds(220) : .milliseconds(1_300)
    }

    /// Long enough for the mark's fade-in to read as intended rather than
    /// a flash, when the first screen is ready almost at once.
    public static func minimumHold(reduceMotion: Bool) -> Duration {
        reduceMotion ? .zero : .milliseconds(350)
    }

    /// How much longer the cover should stay up, `elapsed` after it drew.
    public static func remainingHold(elapsed: Duration, firstScreenIsReady: Bool, reduceMotion: Bool) -> Duration {
        let maximum = maximumHold(reduceMotion: reduceMotion)
        let target = firstScreenIsReady ? min(minimumHold(reduceMotion: reduceMotion), maximum) : maximum
        return max(.zero, target - elapsed)
    }
}
