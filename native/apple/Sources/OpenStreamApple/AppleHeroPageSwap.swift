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
    /// The page id to draw.
    ///
    /// - Parameters:
    ///   - shown: the page on screen, nil before the first paint (or when it
    ///     has left the candidates) — the first page never waits for its art.
    ///   - requested: the page the clock wants.
    ///   - isReady: whether a page's backdrop and wordmark have settled
    ///     (decoded or failed; a failure must not stall the rotation).
    public static func pageToShow(shown: String?, requested: String, isReady: (String) -> Bool) -> String {
        guard let shown, shown != requested else { return requested }
        return isReady(requested) ? requested : shown
    }

    /// The pages whose art to fetch ahead: the one requested and the one after
    /// it, so the next change is usually ready when its tick arrives and the
    /// swap lands on time.
    public static func pagesToWarm(requested: Int, count: Int) -> [Int] {
        guard count > 0, (0 ..< count).contains(requested) else { return [] }
        let next = (requested + 1) % count
        return next == requested ? [requested] : [requested, next]
    }
}
