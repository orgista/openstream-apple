import Foundation

struct AppleLiveEdgeFollowPolicy {
    static let driftGrace: Duration = .seconds(5)
    static let correctionInterval: Duration = .seconds(10)

    private var followsLive = true
    private var driftStarted: ContinuousClock.Instant?
    private var lastCorrection: ContinuousClock.Instant?
    private var awaitingRecovery = false

    mutating func suspend() {
        followsLive = false
        driftStarted = nil
    }

    mutating func seek(to target: Double, range: AppleSeekableRange?, holdBack: Double?) {
        followsLive = AppleLiveSeekPolicy.isAtLiveEdge(position: target, in: range,
            tolerance: AppleLiveSeekPolicy.edgeTolerance(holdBack: holdBack))
        driftStarted = nil
    }

    mutating func target(position: Double, range: AppleSeekableRange?, isPlaying: Bool,
                         holdBack: Double?, now: ContinuousClock.Instant) -> Double? {
        if !isPlaying, let lastCorrection, now - lastCorrection < Self.correctionInterval {
            // A correction that causes buffering must not trigger another seek.
            suspend()
        }
        guard followsLive, isPlaying, let range, position.isFinite,
              let holdBack, holdBack.isFinite, holdBack > 0 else {
            driftStarted = nil
            return nil
        }
        guard range.end - position > AppleLiveSeekPolicy.edgeTolerance(holdBack: holdBack) else {
            awaitingRecovery = false
            driftStarted = nil
            return nil
        }
        guard !awaitingRecovery else { return nil }
        // A sliding HLS window advances in whole segments; wait out that jitter.
        let start = driftStarted ?? now
        driftStarted = start
        guard now - start >= Self.driftGrace,
              lastCorrection.map({ now - $0 >= Self.correctionInterval }) ?? true,
              let target = AppleLiveSeekPolicy.liveTarget(in: range, holdBack: holdBack) else { return nil }
        driftStarted = nil
        lastCorrection = now
        awaitingRecovery = true
        return target
    }
}
