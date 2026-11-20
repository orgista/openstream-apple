import Foundation

/// Where the transport is headed while the viewer's seeks land.
///
/// A relative move (a scrubber press, a ±10 s skip) starts from the newest
/// target the viewer asked for, not from the playback position: until a seek
/// lands the position still reports where playback was, and a second press
/// added its step to that and threw the first one away. Moves that arrive
/// while a seek is in flight fold into one follow-up seek to the newest target.
///
/// Every seek carries a generation, so a seek that returns after it was
/// abandoned by the coordinator or an item change cannot end the one
/// that replaced it.
struct AppleSeekTargetPolicy: Equatable {
    struct Seek: Equatable {
        let target: Double
        let generation: Int
    }

    /// The newest target the position has not reached yet.
    private(set) var pending: Double?
    /// The seek in flight; nil when none is.
    private(set) var inFlight: Seek?
    /// After the last seek returned, the position wins at this time even if
    /// it never reached `pending`.
    private var releaseAt: ContinuousClock.Instant?
    private var generation = 0

    /// A position this close to the target counts as arrived.
    static let arrivalTolerance: Double = 2
    /// How long the position may lag `pending` once the seek returned: a seek
    /// that settled on a keyframe away from the target, or a SharePlay seek,
    /// which returns as soon as it is issued.
    static let releaseAfter: Duration = .seconds(3)

    /// Where the next relative move starts, and what the scrubber shows.
    func base(position: Double) -> Double { pending ?? position }

    /// `base + delta` clamped to `bounds`.
    static func step(from base: Double, by delta: Double, in bounds: ClosedRange<Double>) -> Double {
        min(bounds.upperBound, max(bounds.lowerBound, base + delta))
    }

    /// Records `target` as the newest destination. Returns the seek to start
    /// now, or nil when one is in flight and `returned` will follow it up.
    /// `superseding` replaces an in-flight seek to another target instead:
    /// its late return is then ignored like an abandoned one.
    mutating func request(_ target: Double, deferred: Bool = false, superseding: Bool = false) -> Seek? {
        pending = target
        releaseAt = nil
        if deferred { return nil }
        if let inFlight, !superseding || inFlight.target == target { return nil }
        return start(target)
    }

    /// `seek` returned. Returns the follow-up seek to the newest target, or
    /// nil when nothing newer was asked for or `seek` was abandoned.
    mutating func returned(_ seek: Seek, now: ContinuousClock.Instant) -> Seek? {
        guard seek == inFlight else { return nil }
        guard let pending, pending != seek.target else {
            inFlight = nil
            releaseAt = now.advanced(by: Self.releaseAfter)
            return nil
        }
        return start(pending)
    }

    /// A position tick from the engine.
    mutating func observe(position: Double, now: ContinuousClock.Instant) {
        guard let target = pending else { return }
        // A reversal can cross the old position, and engines can publish an
        // optimistic target before the picture lands. Neither completes a seek.
        if inFlight == nil, abs(position - target) <= Self.arrivalTolerance {
            pending = nil
            releaseAt = nil
        } else if let releaseAt, now >= releaseAt {
            pending = nil
            self.releaseAt = nil
        }
    }

    private mutating func start(_ target: Double) -> Seek {
        generation &+= 1
        let seek = Seek(target: target, generation: generation)
        inFlight = seek
        return seek
    }

    /// The item changed, or the coordinator retries: forget the target
    /// and the seek, whose late return is then ignored.
    mutating func reset() {
        pending = nil
        inFlight = nil
        releaseAt = nil
    }
}
