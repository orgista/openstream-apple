import Foundation

/// How long a live channel gets to show a picture.
///
/// A channel that has not answered by `ApplePlaybackCoordinator`'s 10 s live
/// deadline is dead or not in the package, and saying so quickly is the point
/// of that deadline (owner 2026-09-14). But a channel whose stream the engine
/// has already opened is answering: on the owner's IPTV provider the stream
/// opens in ~2-5 s and the first two-second segment can take ~6 s more to
/// arrive, so the first picture lands at ~11-12 s. Cut at 10 s, every such
/// channel failed, its retry failed the same way, and Live "no longer worked"
/// (iPhone trace with the owner's config, 2026-10-07: `live seg-0 finalized`
/// 6 s after the stream opened, `timed out after 10.0 seconds` 0.1 s later).
public enum ApplePlaybackStartPolicy {
    static func liveFailureAtDeadline(_ failure: ApplePlaybackFailure, sourceOpened: Bool) -> ApplePlaybackFailure {
        guard !sourceOpened, failure.kind == .player || failure.kind == .timedOut else { return failure }
        return ApplePlaybackFailure(kind: .network, message: "The channel's server did not respond.", networkCode: .timedOut)
    }

    static func initialLiveSeekTarget(in range: AppleSeekableRange?) -> Double? {
        guard let range, range.end > 0,
              range.span > AppleLiveSeekPolicy.minimumEffectiveMove else { return nil }
        // The end names the next sample boundary, which may not have arrived yet.
        return max(0, max(range.start, range.end - 1))
    }

    /// The extra wait once, for a live channel whose stream is open.
    public static let liveOpenedExtension: Duration = .seconds(15)

    /// The extension to grant at the live deadline, or nil to fail now.
    public static func liveStartExtension(isLive: Bool, sourceOpened: Bool, alreadyExtended: Bool) -> Duration? {
        guard isLive, sourceOpened, !alreadyExtended else { return nil }
        return liveOpenedExtension
    }

    /// Rill may need 4.5 seconds to return a redirect or Retry-After response.
    public static let sourceFirstByteDeadline: Duration = .seconds(5)
    /// Reopens per press after a source that sent nothing by the deadline.
    public static let sourceFirstByteReopens = 2

    /// Whether `request` is reopened when its source sends nothing by
    /// `sourceFirstByteDeadline`: remote on-demand streams only. Live streams
    /// have their own deadline, shares and local files are not remote, and a
    /// disc reads its structure before any checkpoint.
    public static func reopensSilentSource(_ request: ApplePlaybackRequest, reopens: Int) -> Bool {
        guard reopens < sourceFirstByteReopens, !request.isLive, request.hints.disc == nil else { return false }
        return request.sourceKind == .mediaServer || request.sourceKind == .catalog
    }

    /// How far a disc image's start has got: the engine's startup checkpoint
    /// and the bytes the SMB bridge has sent it.
    public struct DiscStartProgress: Equatable, Sendable {
        public var checkpoint: Int
        public var bytesRead: UInt64

        public init(checkpoint: Int = 0, bytesRead: UInt64 = 0) {
            self.checkpoint = checkpoint
            self.bytesRead = bytesRead
        }

        func isAhead(of other: Self) -> Bool {
            checkpoint > other.checkpoint || bytesRead > other.bytesRead
        }
    }

    /// A disc image gets no picture until the engine has read its structure,
    /// which over the owner's Wi-Fi took 17 s of the 20 s deadline, and the
    /// rest of the start did not fit (trace iphone-1017b, 2026-10-17: Blu-ray
    /// recognized at 60.0 s, timed out at 62.6 s). Past the deadline a disc
    /// that is still being read gets another window at a time, up to the cap.
    /// Only discs the SMB bridge serves show progress before recognition: the
    /// engine (07afad62) reports no checkpoint until then, so a disc from a
    /// media server or a local file still fails at the first deadline.
    public static let discProgressWindow: Duration = .seconds(10)
    public static let discStartCap: Duration = .seconds(60)

    /// The extension to grant a disc start at its deadline, or nil to fail
    /// now: nothing moved since the last deadline, or the cap is reached.
    public static func discStartExtension(
        elapsed: Duration, previous: DiscStartProgress, current: DiscStartProgress,
        window: Duration = discProgressWindow, cap: Duration = discStartCap
    ) -> Duration? {
        guard current.isAhead(of: previous), elapsed < cap else { return nil }
        return min(window, cap - elapsed)
    }
}
