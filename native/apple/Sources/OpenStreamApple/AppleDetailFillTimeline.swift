import Foundation

/// How long a title page takes to fill, one trace line per milestone.
///
/// The push itself was fixed (`9b405f0`), but the page still filled over
/// 10–18 s on the iPhone simulator and nothing said which part was late. Each
/// opening writes `detail fill "<title>" <milestone> +<ms>ms` to the
/// interaction trace, measured from the moment the page appeared, so a
/// before/after comparison is a grep rather than a stopwatch.
///
/// A reference type on purpose: the page holds it in `@State`, and recording a
/// milestone must not invalidate the view that is being measured.
@MainActor
public final class AppleDetailFillTimeline {
    public enum Milestone: String, CaseIterable, Sendable {
        /// The page appeared.
        case paint
        /// A synopsis is on screen — the catalog's own, or the enriched one.
        case overview
        /// The enriched details (overview, cast, genres) arrived.
        case metadata
        /// A series' episode list arrived.
        case episodes
        /// The wordmark finished loading.
        case wordmark
        /// The hero still finished loading.
        case artwork
        /// Every request the page makes on opening has finished.
        case done
    }

    private let now: () -> ContinuousClock.Instant
    private var start: ContinuousClock.Instant?
    private var title = ""
    private var seen: Set<Milestone> = []

    public init(now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.now = now
    }

    /// Starts a new opening. Milestones before this are ignored.
    public func begin(title: String) {
        start = now()
        self.title = title
        seen = []
    }

    /// Records the first time a milestone is reached in this opening and
    /// returns the trace line; later calls, and calls before `begin`, return nil.
    @discardableResult
    public func mark(_ milestone: Milestone, detail: String = "") -> String? {
        guard let start, seen.insert(milestone).inserted else { return nil }
        let line = Self.line(
            title: title,
            milestone: milestone,
            elapsed: start.duration(to: now()),
            detail: detail
        )
        appleTrace(line)
        return line
    }

    public static func line(title: String, milestone: Milestone, elapsed: Duration, detail: String = "") -> String {
        let milliseconds = max(0, Int((Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1e15).rounded()))
        let suffix = detail.isEmpty ? "" : " \(detail)"
        return "detail fill \"\(title)\" \(milestone.rawValue) +\(milliseconds)ms\(suffix)"
    }
}
