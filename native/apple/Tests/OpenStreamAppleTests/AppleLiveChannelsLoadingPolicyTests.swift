import Testing
@testable import OpenStreamApple

/// Live shows one loading state until its rows can show, and never sticks
/// on it or flickers to it from a failure (owner 2026-10-22).
struct AppleLiveChannelsLoadingPolicyTests {
    private func loads(rows: Bool = false, channels: Bool = false, loading: Bool = false, resolved: Bool = true,
                       failure: Bool = false, sorted: Bool = true) -> Bool {
        AppleLiveChannelsLoadingPolicy.showsLoading(hasRows: rows, hasChannels: channels, isLoading: loading,
            hasResolvedFirstLoad: resolved, showsFailure: failure, hasSortedChannels: sorted)
    }

    @Test func theFirstLoadShowsLoadingEvenAfterADeadPlaylistFailed() {
        #expect(loads(resolved: false))
        #expect(loads(loading: true, resolved: false, failure: true))
    }

    @Test func rowsAlwaysWin() {
        #expect(!loads(rows: true, channels: true, loading: true, resolved: false, sorted: false))
    }

    @Test func channelsWaitOnlyForTheFirstSort() {
        #expect(loads(channels: true, sorted: false))
        // Sorted and empty (all hidden or filtered): the empty state, not a spinner.
        #expect(!loads(channels: true, sorted: true))
    }

    /// Review 2026-10-22: an empty Favorites list, then a playlist refresh,
    /// must keep the category bar so the viewer can leave Favorites.
    @Test func anEmptyCategoryStaysAListThroughARefresh() {
        #expect(!loads(channels: true, loading: true, sorted: true))
        #expect(!loads(channels: true, loading: false, sorted: true))
    }

    @Test func aRetryKeepsTheFailureOnScreen() {
        #expect(!loads(loading: true, failure: true))
        #expect(!loads(loading: false, failure: true))
    }

    @Test func aReloadWithNothingOnScreenLoads() {
        #expect(loads(loading: true))
        #expect(!loads(loading: false))
    }
}
