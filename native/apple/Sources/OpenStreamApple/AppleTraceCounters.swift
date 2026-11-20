import Foundation

/// Running playback tallies for the trace, so "does it work for testers"
/// reads as one line — "live: 41 tried, 30 played, 9 failed (authentication 7,
/// network 2)" — instead of 400 raw events (owner 2026-09-21: "how do we add
/// traces to see if it works for users").
///
/// Counts only: no channel names, URLs or titles, so the summary is safe to
/// show anywhere the trace itself is.
public struct AppleTraceCounters: Equatable, Sendable {
    public struct Tally: Equatable, Sendable {
        public var attempts = 0
        public var started = 0
        public var failures: [ApplePlaybackFailure.Kind: Int] = [:]

        public var failed: Int { failures.values.reduce(0, +) }
    }

    public private(set) var live = Tally()
    public private(set) var onDemand = Tally()

    public init() {}

    public mutating func recordAttempt(isLive: Bool) {
        update(isLive) { $0.attempts += 1 }
    }

    public mutating func recordStarted(isLive: Bool) {
        update(isLive) { $0.started += 1 }
    }

    /// A cancelled load is a channel switch, not a failure the viewer saw.
    public mutating func recordFailure(_ kind: ApplePlaybackFailure.Kind, isLive: Bool) {
        guard kind != .cancelled else { return }
        update(isLive) { $0.failures[kind, default: 0] += 1 }
    }

    public var summary: String {
        [("live", live), ("on demand", onDemand)]
            .filter { $0.1.attempts > 0 || $0.1.failed > 0 }
            .map { name, tally in
                var text = "\(name): \(tally.attempts) tried, \(tally.started) played, \(tally.failed) failed"
                if !tally.failures.isEmpty {
                    let reasons = tally.failures
                        .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key.rawValue < $1.key.rawValue }
                        .map { "\($0.key.rawValue) \($0.value)" }
                        .joined(separator: ", ")
                    text += " (\(reasons))"
                }
                return text
            }
            .joined(separator: "; ")
    }

    private mutating func update(_ isLive: Bool, _ change: (inout Tally) -> Void) {
        if isLive { change(&live) } else { change(&onDemand) }
    }
}

extension AppleInteractionTrace {
    nonisolated(unsafe) private static var counters = AppleTraceCounters()
    private static let countersLock = NSLock()

    /// The tallies since launch.
    public static var playbackCounters: AppleTraceCounters {
        countersLock.lock(); defer { countersLock.unlock() }
        return counters
    }

    /// Applies one change and, when the trace is on, writes the new summary
    /// as a line of its own so it survives in the exported log.
    static func count(_ change: (inout AppleTraceCounters) -> Void) {
        countersLock.lock()
        let before = counters
        change(&counters)
        let after = counters
        countersLock.unlock()
        guard after != before else { return }
        record(.playback, "counters \(after.summary)")
    }
}
