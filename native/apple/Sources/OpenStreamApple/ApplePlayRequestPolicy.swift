import Foundation

/// A press of Play (or Connect, Save, Test) resolves exactly once.
/// `ApplePlayRequestLedger` is the Play-page name for the same type.
///
/// The title page starts playback from `.task(id: request)`. SwiftUI runs a
/// `.task` again every time its view reappears, so a request that was never
/// marked as used fired a second time when the viewer left the page for
/// another tab and came back: ~2 s later the player opened by itself, and for
/// a series it resolved without the episode the press named (iPad, 2026-10-01:
/// Friends S1E2 → Settings → Discover played a season-9 file and saved its
/// position over S1E2's). The same holds for the page's one automatic play.
public struct AppleOneShotRequestLedger: Equatable, Sendable {
    /// The last request that was resolved (or deliberately dropped).
    public private(set) var consumed: UUID?
    /// Whether the page's opening auto-play has already been asked for.
    public private(set) var initialAutoPlayFired = false

    public init() {}

    /// True exactly once per request id; nil and an already-used id are false.
    public mutating func consume(_ request: UUID?) -> Bool {
        guard let request, request != consumed else { return false }
        consumed = request
        return true
    }

    /// True the first time a page that opens straight into playback asks,
    /// never again for the life of that page.
    public mutating func takeInitialAutoPlay(_ wanted: Bool) -> Bool {
        guard wanted, !initialAutoPlayFired else { return false }
        initialAutoPlayFired = true
        return true
    }
}

public typealias ApplePlayRequestLedger = AppleOneShotRequestLedger

extension AppleOneShotRequestLedger {
    /// The page's opening auto-play, taken only once `settle` has returned.
    /// A task cancelled or re-run during the wait leaves it in the ledger for
    /// the next run, so the page still plays.
    @MainActor
    static func takeInitialAutoPlay(_ wanted: Bool, from ledger: () -> Self, update: (Self) -> Void,
                                    after settle: @MainActor () async -> Void) async -> Bool {
        guard wanted, !ledger().initialAutoPlayFired else { return false }
        await settle()
        guard !Task.isCancelled else { return false }
        var value = ledger()
        guard value.takeInitialAutoPlay(wanted) else { return false }
        update(value)
        return true
    }
}

/// A series keeps one progress entry under the show and names the episode in
/// `partID`. A save that names no episode must never replace one that does:
/// it is either a stray play of the whole show or a request that lost its
/// episode, and either way it would wipe that episode's Resume.
public enum AppleSeriesProgressGuard {
    /// Whether `partID` names an episode (`…:season:episode`).
    nonisolated public static func namesEpisode(_ partID: String?) -> Bool {
        partID.flatMap(AppleMediaSeriesInfo.init(mediaID:)) != nil
    }

    /// Whether a save carrying `newPartID` may replace `existing`.
    nonisolated public static func mayOverwrite(existing: ApplePlaybackProgress?, with newPartID: String?) -> Bool {
        guard let existing, namesEpisode(existing.partID) else { return true }
        return namesEpisode(newPartID)
    }
}
