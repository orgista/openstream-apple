import Foundation

/// How Discover's heroes get their wordmarks when the preview-assets cache
/// cannot answer yet.
///
/// The billboard used to peek at the cache twice, at once and two seconds
/// later, and then call every hero resolved. On a fresh install the add-ons
/// had not answered by then, so the heroes drew their names for the whole
/// session (owner 2026-09-29: "JEOPARDY!" as plain text while its title
/// page had the logo). Now each hero the cache cannot answer is asked for
/// once the billboard has drawn, and a hero whose ask failed on the network
/// is asked again a bounded number of times.
enum AppleHeroWordmarkFetch {
    /// What one ask for a hero's preview assets came to.
    enum Outcome: Equatable, Sendable {
        /// The add-ons gave a wordmark.
        case found(URL)
        /// The add-ons answered, with no wordmark.
        case none
        /// No answer: the ask failed on the network (nothing was cached), so
        /// it is worth asking again.
        case transient
    }

    /// The waits before each retry of a hero whose ask failed on the
    /// network. Bounded: after these the name stands for the session unless
    /// the hero set changes.
    static let retryDelays: [Duration] = [.seconds(3), .seconds(10)]

    /// - Parameters:
    ///   - assets: what `AppleStremioMetadataClient.previewAssets` returned.
    ///   - answered: the preview-assets cache now holds an entry for the
    ///     title. `previewAssets` caches every answer, including "none", and
    ///     leaves the cache empty when the add-ons could not be reached.
    static func outcome(assets: AppleStremioPreviewAssets?, answered: Bool) -> Outcome {
        if let logo = assets?.logoURL { return .found(logo) }
        return answered || assets != nil ? .none : .transient
    }

    /// The wait before retry number `retry` (1-based), or nil once the
    /// retries are spent.
    static func retryDelay(_ retry: Int) -> Duration? {
        guard retry >= 1, retry <= retryDelays.count else { return nil }
        return retryDelays[retry - 1]
    }

    /// The interaction-trace line for one ask.
    static func traceLine(title: String, outcome: Outcome, milliseconds: Int) -> String {
        switch outcome {
        case .found: "hero wordmark fetch \(title): found (\(milliseconds)ms)"
        case .none: "hero wordmark fetch \(title): none (\(milliseconds)ms)"
        case .transient: "hero wordmark fetch \(title): none (\(milliseconds)ms, no answer)"
        }
    }
}
