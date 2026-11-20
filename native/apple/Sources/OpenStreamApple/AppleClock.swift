import Foundation

/// The time source behind a deadline or a retry delay. The app always uses
/// `AppleSystemClock`; tests pass a clock they advance by hand, so a timer
/// fires when the test says, not when a loaded machine gets round to it.
public protocol AppleClock: Sendable {
    var now: ContinuousClock.Instant { get }
    func sleep(until deadline: ContinuousClock.Instant) async throws
}

extension AppleClock {
    public func sleep(for duration: Duration) async throws {
        try await sleep(until: now.advanced(by: duration))
    }
}

public struct AppleSystemClock: AppleClock {
    public init() {}
    public var now: ContinuousClock.Instant { .now }
    public func sleep(until deadline: ContinuousClock.Instant) async throws {
        try await Task.sleep(until: deadline, clock: .continuous)
    }
}
