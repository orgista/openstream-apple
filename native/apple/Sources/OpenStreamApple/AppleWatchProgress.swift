import Foundation

/// How far through a title the viewer is, as a `0...1` fraction.
///
/// Every shelf that draws a resume bar goes through here. Doing the division
/// inline produced `NaN` whenever the duration had not been read yet — and a
/// `ProgressView` handed `NaN` draws an empty track, which reads as "not
/// started" for something the viewer is halfway through.
public enum AppleWatchProgress: Sendable {
    public static func fraction(position: Double, duration: Double) -> Double {
        guard duration.isFinite, duration > 0, position.isFinite else { return 0 }
        return min(1, max(0, position / duration))
    }
}
