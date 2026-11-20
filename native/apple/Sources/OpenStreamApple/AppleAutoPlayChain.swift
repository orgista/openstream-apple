import Foundation

/// Unattended playback travels with the episode handoff, never in saved history.
public struct AppleAutoPlayChain: Equatable, Sendable {
    public private(set) var episodes = 1
    public private(set) var startedAt: Date

    public init(startedAt: Date = .now) { self.startedAt = startedAt }

    public func canAdvance(at now: Date = .now) -> Bool {
        episodes < 3 && now.timeIntervalSince(startedAt) < 7200
    }

    public mutating func didAdvance() { episodes += 1 }
    public mutating func interacted(at now: Date = .now) {
        self = Self(startedAt: now)
    }
}
