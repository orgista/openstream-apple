import Foundation

/// Which billboard is on screen right now.
///
/// Discover and Library both used to pin the first candidate, so the home
/// screen opened on the same title every time (owner 2026-09-14: "can we have
/// hero cards cycle or reco content"). The index is derived from the clock
/// rather than held in state, so both screens agree, nothing has to be
/// invalidated to advance it, and the behaviour is testable without a view.
public enum AppleHeroRotation: Sendable {
    /// How long a page shows its still. The Apple TV app's image-only dwell is
    /// 5 s (`advanceToNextPageDelayDurationImageOnly`); 12 s with five pages
    /// felt stalled (REA round 3, 2026-10-17). A page whose trailer plays holds
    /// the timer and moves on `afterVideoDelay` after it ends.
    public static let interval: TimeInterval = 6

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
        preferring: ((Value, Value) -> Bool)? = nil,
        limit: Int = maximumCandidates
    ) -> [Value] {
        guard limit > 0 else { return [] }
        var positions: [String: Int] = [:]
        var result: [Value] = []
        for value in values {
            let key = id(value)
            if let position = positions[key] {
                if preferring?(value, result[position]) == true { result[position] = value }
            } else if result.count < limit {
                positions[key] = result.count
                result.append(value)
            }
        }
        return result
    }

    /// The same, keeping only the values `hasBackdrop` accepts — the Apple TV
    /// app's hero never shows a title without art, and a page drawn from the
    /// poster or the placeholder was a hero with no picture and no title
    /// (Binnelanders, iPhone sim 2026-09-23). When nothing has a backdrop the
    /// rotation is left as it was rather than emptied.
    public static func candidates<Value>(
        _ values: [Value],
        id: (Value) -> String,
        hasBackdrop: (Value) -> Bool,
        limit: Int = maximumCandidates
    ) -> [Value] {
        let unique = candidates(values, id: id, limit: .max)
        let withArt = unique.filter(hasBackdrop)
        return Array((withArt.isEmpty ? unique : withArt).prefix(limit))
    }

    /// Whether `item` has art a hero can stand on: a real backdrop, not a
    /// missing one and not the poster handed back as its own background.
    public static func hasBackdrop(_ item: AppleCatalogItem) -> Bool {
        guard let background = item.backgroundURL else { return false }
        return background != item.posterURL
    }
}
