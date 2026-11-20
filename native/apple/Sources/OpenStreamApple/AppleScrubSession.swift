import Foundation

/// A ring or swipe scrub on the Apple TV clickpad, from touch to lift, or a
/// quick run of left/right presses.
///
/// Each step moves a local destination, which the scrubber shows at once.
/// Media seeks follow at most once per `commitInterval`, each to the newest
/// destination, and once more on lift if the finger moved since. Spinning the
/// ring issued a real seek per ten-second step before (REA-1104 §3), and a
/// fast spin queued a seek behind every landing.
struct AppleScrubSession: Equatable {
    static let commitInterval: Duration = .milliseconds(500)
    /// Clickpad presses closer together than this are one scrub (test Apple TV:
    /// a fast run of presses arrives about 270 ms apart).
    static let pressBurstIdle: Duration = .milliseconds(400)

    /// Where the scrub is headed; nil outside a scrub.
    private(set) var destination: Double?
    private var committed: Double?
    private var lastCommit: ContinuousClock.Instant?

    var isActive: Bool { destination != nil }

    /// One step of `seconds`. The first step starts from `base`, the newest
    /// target the transport has.
    mutating func move(by seconds: Double, from base: Double, in bounds: ClosedRange<Double>) {
        let start = destination ?? base
        destination = AppleSeekTargetPolicy.step(from: start, by: seconds, in: bounds)
    }

    /// When the next commit may run: now for the first, then one interval
    /// after the last.
    func nextCommit(now: ContinuousClock.Instant) -> ContinuousClock.Instant {
        lastCommit.map { max(now, $0.advanced(by: Self.commitInterval)) } ?? now
    }

    /// The destination to seek to now, or nil when it was already committed.
    mutating func commit(now: ContinuousClock.Instant) -> Double? {
        guard let destination, destination != committed else { return nil }
        committed = destination
        lastCommit = now
        return destination
    }

    /// The finger lifted: the destination still owed a seek, if any.
    mutating func end() -> Double? {
        defer { self = Self() }
        guard let destination, destination != committed else { return nil }
        return destination
    }
}
