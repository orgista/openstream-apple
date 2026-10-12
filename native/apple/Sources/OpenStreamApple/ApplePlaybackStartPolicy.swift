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
/// (DevPlus trace with the owner's config, 2026-10-07: `live seg-0 finalized`
/// 6 s after the stream opened, `timed out after 10.0 seconds` 0.1 s later).
public enum ApplePlaybackStartPolicy {
    /// The extra wait once, for a live channel whose stream is open.
    public static let liveOpenedExtension: Duration = .seconds(15)

    /// The extension to grant at the live deadline, or nil to fail now.
    public static func liveStartExtension(isLive: Bool, sourceOpened: Bool, alreadyExtended: Bool) -> Duration? {
        guard isLive, sourceOpened, !alreadyExtended else { return nil }
        return liveOpenedExtension
    }
}
