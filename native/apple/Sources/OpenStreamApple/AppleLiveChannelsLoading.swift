import SwiftUI

/// Live before its first lineup is on screen: one system spinner and its
/// status, in place of rows popping in (owner 2026-10-22). The stage above it
/// stays black until a channel is chosen.
struct AppleLiveChannelsLoading: View {
    var body: some View {
        ProgressView("Loading Channels")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("live.channels.loading")
    }
}

/// When the Live list shows `AppleLiveChannelsLoading` instead of rows.
enum AppleLiveChannelsLoadingPolicy {
    /// Loading only while nothing better can be shown: the first lineup has
    /// not answered, a reload runs with no failure on screen (a retry keeps
    /// the failure in place instead of flickering to the spinner and back),
    /// or the first channels are in but not yet sorted. Once a lineup has
    /// been sorted, an empty list (no favourites, no search match) stays a
    /// list with its category bar, whatever reloads under it.
    static func showsLoading(hasRows: Bool, hasChannels: Bool, isLoading: Bool, hasResolvedFirstLoad: Bool,
                             showsFailure: Bool, hasSortedChannels: Bool) -> Bool {
        guard !hasRows else { return false }
        if hasChannels { return !hasSortedChannels }
        return !hasResolvedFirstLoad || (isLoading && !showsFailure)
    }
}
