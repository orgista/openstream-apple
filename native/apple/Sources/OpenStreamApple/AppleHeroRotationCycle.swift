import Foundation

extension AppleHeroRotation {
    /// The iPhone hero's rotation, held as state rather than read off the clock.
    ///
    /// The clock-derived `index(at:)` cannot be swiped, jumped or held still,
    /// and the owner asked for the Apple TV app's hero on the iPhone: swipe to
    /// change page, tap a dot to jump, and a timer that stops while you touch it
    /// (2026-09-22, "match apple tv hero buttons trailers and 'cycle'"). Same
    /// interval and candidates as the clock; only the iPhone portrait hero uses
    /// this, every other hero still follows `index(at:)`.
    public struct Cycle: Equatable, Sendable {
        public let count: Int
        public let interval: TimeInterval
        public private(set) var index: Int
        /// Time already spent on this page before the current run began.
        private var elapsedBeforeRun: TimeInterval = 0
        /// When the current run began; nil while paused.
        private var runningSince: Date?
        private var awaitsPresentation = false

        public init(count: Int, index: Int = 0, interval: TimeInterval = AppleHeroRotation.interval, now: Date = .now) {
            self.count = max(count, 0)
            self.interval = interval
            self.index = self.count > 0 ? min(max(index, 0), self.count - 1) : 0
            self.runningSince = now
        }

        public var isPaused: Bool { runningSince == nil }

        /// How far the active page's timer has run, 0...1 — the fill of the
        /// active dot.
        public func progress(at now: Date) -> Double {
            guard interval > 0, !awaitsPresentation else { return 0 }
            let running = runningSince.map { max(0, now.timeIntervalSince($0)) } ?? 0
            return min(max((elapsedBeforeRun + running) / interval, 0), 1)
        }

        /// When the page changes on its own, or nil when it will not (paused, or
        /// nothing to move to). The last page wraps to the first, as build 15
        /// did (owner, 2026-10-17: "the hero cycle is gone").
        public var dueDate: Date? {
            guard !awaitsPresentation, count > 1, interval > 0, let runningSince else { return nil }
            return runningSince.addingTimeInterval(max(interval - elapsedBeforeRun, 0))
        }

        /// Loading is independent of focus/visibility pause. No dwell is
        /// consumed until the gate presents the requested art and copy.
        public mutating func waitForPresentation() {
            awaitsPresentation = true
            elapsedBeforeRun = 0
        }

        public mutating func didPresent(at now: Date) {
            guard awaitsPresentation else { return }
            awaitsPresentation = false
            elapsedBeforeRun = 0
            if runningSince != nil { runningSince = now }
        }

        /// The indicator belongs to the art actually on screen, even while a
        /// different requested page is still loading.
        public func indicator(showing index: Int) -> Self {
            var shown = self
            shown.index = index
            return shown
        }

        public mutating func pause(at now: Date) {
            guard runningSince != nil else { return }
            elapsedBeforeRun = progress(at: now) * interval
            runningSince = nil
        }

        public mutating func resume(at now: Date) {
            guard runningSince == nil else { return }
            runningSince = now
        }

        /// The page's trailer has played to its end: the page moves on
        /// `delay` after now (the Apple TV app's `autoAdvanceForIdleVideo`,
        /// 1 s), or that long after the cycle resumes if it is held.
        public mutating func videoEnded(at now: Date, delay: TimeInterval = AppleHeroRotation.afterVideoDelay) {
            guard !awaitsPresentation, interval > 0 else { return }
            elapsedBeforeRun = max(interval - max(delay, 0), 0)
            if runningSince != nil { runningSince = now }
        }

        /// The page's trailer failed or never started: its still gets a full
        /// dwell from now, as if the page had just appeared.
        public mutating func videoFailed(at now: Date) {
            guard !awaitsPresentation else { return }
            elapsedBeforeRun = 0
            if runningSince != nil { runningSince = now }
        }

        /// Shows `target` (wrapping) with a fresh timer, keeping the paused or
        /// running state as it was.
        public mutating func show(_ target: Int, at now: Date) {
            guard count > 0 else { return }
            index = ((target % count) + count) % count
            elapsedBeforeRun = 0
            if runningSince != nil { runningSince = now }
        }

        public mutating func step(by offset: Int, at now: Date) {
            show(index + offset, at: now)
        }

        /// The page to draw and the page to preload when `pageCount` ids are
        /// on hand, or nil when the page on screen is gone.
        ///
        /// The carousels draw once with the new ids before their `onChange`
        /// restarts the cycle, so a list that just shrank (5 heroes → 1 when
        /// a row with little backdrop art becomes the first shelf) met a cycle
        /// still counting 5: `(index + 1) % count` then subscripted past the
        /// end of the ids and trapped. Both indices are bounded by the ids
        /// actually there, never by `count` alone.
        public func pages(available pageCount: Int) -> (shown: Int, next: Int?)? {
            guard count > 0, index < pageCount else { return nil }
            let span = min(count, pageCount)
            guard span > 1 else { return (index, nil) }
            let next = (index + 1) % span
            return (index, next == index ? nil : next)
        }

        /// Applies what the page's trailer just did.
        public mutating func handle(_ event: VideoEvent, at now: Date) {
            switch event {
            case .ended: videoEnded(at: now)
            case .failed: videoFailed(at: now)
            }
        }

        /// Moves to the next page when its timer has run out. True when it moved.
        @discardableResult
        public mutating func advanceIfDue(at now: Date) -> Bool {
            guard let dueDate, now >= dueDate else { return false }
            step(by: 1, at: now)
            return true
        }

        /// How often the active dot's fill needs redrawing: each time it has
        /// grown by half a device pixel, and never faster than 30 Hz. The Mac,
        /// iPhone and iPad dots all tick by this.
        ///
        /// The Mac's 22 pt fill crosses 44 pixels over a 12 s interval, so a 30 Hz timeline
        /// redrew it 360 times to move it 44 pixels — and on the Mac every
        /// tick lays out and renders the whole window (~6 ms of main thread,
        /// a fifth of a core while Discover sits idle, N34 trace). Half-pixel
        /// steps draw the same bar at ~7 Hz.
        public func fillTickInterval(width: CGFloat, displayScale: CGFloat) -> TimeInterval {
            let steps = Double(width * max(displayScale, 1)) * 2
            guard interval > 0, steps > 0 else { return Self.slowestFillTick }
            return min(max(interval / steps, Self.fastestFillTick), Self.slowestFillTick)
        }

        static let fastestFillTick: TimeInterval = 1.0 / 30.0
        static let slowestFillTick: TimeInterval = 0.5
    }

    /// A hero trailer's end or failure, as the cycle sees it.
    public enum VideoEvent: Equatable, Sendable {
        case ended, failed
    }

    /// How long after a hero's trailer ends the page moves on, on every
    /// platform (the Apple TV app's `advanceToNextPageDelayDuration`).
    public static let afterVideoDelay: TimeInterval = 1

    /// Whether a hero's timer holds still: while a finger (or the pointer) is
    /// on the hero, and while its trailer plays — muted or not. The page moves
    /// on `afterVideoDelay` after the trailer ends (owner, 2026-09-24: "the
    /// trailer loads and it cycles too fast … give it more time, depending how
    /// long the trailer is"). Mute and Play Trailer no longer change this; the
    /// parameters stay for the callers. It also holds while nobody can see the
    /// hero (`heroIsVisible`), so the page is where it was when the viewer
    /// comes back.
    public static func cycleIsPaused(isTouching: Bool, trailerIsPlaying: Bool, trailerIsMuted _: Bool,
                                     trailerWasRequested _: Bool = false, isHidden: Bool = false) -> Bool {
        isHidden || isTouching || trailerIsPlaying
    }
}
