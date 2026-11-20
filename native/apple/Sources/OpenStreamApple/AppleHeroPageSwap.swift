import Foundation

/// When the rotating billboard may move to the page the clock asks for.
///
/// The clock (`AppleHeroRotation`) picks a page every interval, and the copy
/// used to follow it on the same frame while the art did not: the backdrop
/// remounted empty and the old wordmark stayed up until the new ones decoded,
/// so the Apple TV showed REACHER over Hamlet's synopsis on a bare surface
/// (sim finding c, 2026-09-22). The billboard now holds the page it is showing
/// until the requested page's art is ready, then changes everything at once.
public enum AppleHeroPageSwap: Sendable {
    struct FadeVisit {
        private(set) var revision = 0
        private var isActive = true
        private var isCovered = false
        private var routeRevision = 0

        mutating func update(isActive: Bool, isCovered: Bool, routeRevision: Int) {
            if isActive && !isCovered && (!self.isActive || self.isCovered || self.routeRevision != routeRevision) {
                revision &+= 1
            }
            self.isActive = isActive
            self.isCovered = isCovered
            self.routeRevision = routeRevision
        }
    }

    /// The page id to draw.
    ///
    /// - Parameters:
    ///   - shown: the page on screen, nil before the first paint (or when it
    ///     has left the candidates) — the first page never waits for its art.
    ///   - requested: the page the clock wants.
    ///   - isReady: whether a page's backdrop and wordmark have settled
    ///     (a failed wordmark can use text; a backdrop must be decoded).
    public static func pageToShow(shown: String?, requested: String, isReady: (String) -> Bool) -> String {
        guard let shown, shown != requested else { return requested }
        return isReady(requested) ? requested : shown
    }

    static func artIsReady(backdrop: Bool?, hasWordmark: Bool, wordmark: Bool?, timedOut: Bool) -> Bool {
        backdrop == true && (!hasWordmark || wordmark != nil || timedOut)
    }

    /// A wordmark may fall back to text after this wait. A missing backdrop
    /// keeps the previous page on screen.
    public static let artTimeout: Duration = .seconds(8)

    /// Whether a page's wordmark failed, once the art timeout has passed: one
    /// that never answered counts as failed, so the page draws the name.
    public static func wordmarkFailedAtTimeout(hasWordmark: Bool, result: Bool?) -> Bool {
        hasWordmark && result != true
    }

    /// The pages whose art to fetch ahead: the one requested and the one after
    /// it, so the next change is usually ready when its tick arrives and the
    /// swap lands on time.
    public static func pagesToWarm(requested: Int, count: Int) -> [Int] {
        guard count > 0, (0 ..< count).contains(requested) else { return [] }
        let next = (requested + 1) % count
        return next == requested ? [requested] : [requested, next]
    }

    /// How a gated page change is drawn on the Apple TV and the rotating
    /// hero: the art crossfades over `art` seconds, the copy fades out over
    /// the first half and the new copy in over the second, and the buttons
    /// stay where they are, so focus never moves. The Apple TV app slides its
    /// TV hero over 1.0 s with the metadata fading on its own (REA round 4
    /// §1); the cut it replaces showed one title's frame, then the next's.
    public struct Crossfade: Equatable, Sendable {
        public let art: TimeInterval
        public var copyOut: TimeInterval { art / 2 }
        public var copyIn: TimeInterval { art / 2 }
        /// The new copy starts once the old one has gone.
        public var copyInDelay: TimeInterval { copyOut }
    }

    /// The page change's crossfade, or nil for Reduce Motion, which cuts.
    public static func crossfade(reduceMotion: Bool) -> Crossfade? {
        reduceMotion ? nil : Crossfade(art: 1.0)
    }
}
