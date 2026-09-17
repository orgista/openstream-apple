import Foundation

/// Other feeds of the same network, for when the one being watched is dead.
///
/// The owner's provider lists the same network many times over — different
/// qualities, regions and origins — and a dead channel is ordinary in a lineup
/// of 9376. Until now a dead one simply failed: the coordinator has supported
/// falling back across streams since the on-demand work, but live playback
/// called `begin(_:)` and never handed it any candidates, so every live trace
/// read `attempt 0/0`.
///
/// This finds the alternates. The viewer asked for a network, not a URL
/// (owner 2026-09-15: "a dead channel could it be replaced?"), so a feed that
/// answers is a better answer than an apology.
public enum AppleLiveChannelAlternates: Sendable {
    /// How many alternates are worth lining up. The coordinator only keeps two
    /// beyond the first, and each one costs a connection on a provider that
    /// may allow very few.
    public static let limit = 2

    /// Other channels carrying the same network as `channel`, best first.
    ///
    /// Matching is `AppleChannelLineupPresets.normalize(name:)`, the same
    /// comparison the guide already uses to fold "US: CBS East", "CBS (EAST)"
    /// and "CBS HD" onto one lineup entry — so the replacement is a feed of the
    /// network the viewer chose, never a different channel that happens to sort
    /// nearby.
    ///
    /// - Parameter hasRecentlyFailed: consulted so a feed that just failed is
    ///   tried last rather than immediately again. Passed in rather than
    ///   defaulted to `ApplePlaybackFailureHistory.shared` so this stays a
    ///   pure function off the main actor, and testable without one.
    public static func alternates(
        for channel: AppleIPTVChannel,
        in lineup: [AppleIPTVChannel],
        hasRecentlyFailed: (URL) -> Bool,
        limit: Int = limit
    ) -> [AppleIPTVChannel] {
        guard limit > 0 else { return [] }
        let wanted = AppleChannelLineupPresets.normalize(name: channel.name)
        guard !wanted.isEmpty else { return [] }

        var seenURLs: Set<URL> = [channel.streamURL]
        var healthy: [AppleIPTVChannel] = []
        var previouslyFailed: [AppleIPTVChannel] = []

        for candidate in lineup {
            guard candidate.id != channel.id,
                  // A pay-per-view or placeholder entry is not a replacement
                  // for a network, whatever it is called.
                  !AppleChannelVisibilityPolicy.isPlaceholder(candidate),
                  !AppleChannelVisibilityPolicy.isPayPerView(candidate),
                  AppleChannelLineupPresets.normalize(name: candidate.name) == wanted,
                  // The same URL is the same feed; it will fail the same way.
                  seenURLs.insert(candidate.streamURL).inserted else { continue }

            if hasRecentlyFailed(candidate.streamURL) {
                previouslyFailed.append(candidate)
            } else {
                healthy.append(candidate)
            }
        }

        return Array((healthy + previouslyFailed).prefix(limit))
    }
}
