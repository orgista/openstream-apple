import Foundation

/// Which billboard is on screen right now.
///
/// Discover and Library both used to pin the first candidate, so the home
/// screen opened on the same title every time (owner 2026-09-14: "can we have
/// hero cards cycle or reco content"). The index is derived from the clock
/// rather than held in state, so both screens agree, nothing has to be
/// invalidated to advance it, and the behaviour is testable without a view.
public enum AppleHeroRotation: Sendable {
    /// Long enough to read the copy and press Play, short enough that a second
    /// title is reachable without leaving the screen.
    public static let interval: TimeInterval = 12

    /// A billboard loads full-bleed artwork, so the rotation stays short: five
    /// titles cover the recommendations without cycling the network.
    public static let maximumCandidates = 5

    /// The candidate to show at `date`, or nil when there is nothing to show.
    public static func index(at date: Date, count: Int, interval: TimeInterval = interval) -> Int? {
        guard count > 0 else { return nil }
        guard count > 1, interval > 0 else { return 0 }
        let elapsed = date.timeIntervalSinceReferenceDate
        let step = Int((elapsed / interval).rounded(.down))
        // `%` keeps the sign of the dividend; dates before 2001 are negative.
        return ((step % count) + count) % count
    }

    /// How far through the current interval `date` sits, 0...1.
    ///
    /// Derived from the same clock as `index`, so the indicator that shows a
    /// change is coming needs no state of its own and can never disagree with
    /// the billboard it belongs to. The owner asked for "a little bar … it's
    /// about to cycle through" (2026-09-15); this is the number it draws.
    public static func progress(at date: Date, interval: TimeInterval = interval) -> Double {
        guard interval > 0 else { return 0 }
        let position = date.timeIntervalSinceReferenceDate / interval
        let fraction = position - position.rounded(.down)
        return min(max(fraction, 0), 1)
    }

    /// The candidates a billboard rotates through: the order given, without
    /// repeats, capped so the screen does not churn artwork.
    public static func candidates<Value>(
        _ values: [Value],
        id: (Value) -> String,
        limit: Int = maximumCandidates
    ) -> [Value] {
        var seen = Set<String>()
        var result: [Value] = []
        for value in values where seen.insert(id(value)).inserted {
            result.append(value)
            if result.count == limit { break }
        }
        return result
    }
}
