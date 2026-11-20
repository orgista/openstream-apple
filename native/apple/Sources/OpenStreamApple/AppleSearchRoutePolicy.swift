import Foundation

/// Where a `.search` route should land.
///
/// Apple TV carries Search as its own tab; every other platform reaches search
/// by pushing it from Discover. A deep link or App Intent used to do *both* on
/// a television — select Discover, then push Discover's own search page over
/// it — which stacked a second search screen in front of the tab that already
/// existed, carrying a `navigationTitle` that draws over the page on tvOS.
public enum AppleSearchRoutePolicy {
    /// Whether this platform shows Search as a tab of its own.
    public static let platformHasDedicatedSearchTab: Bool = {
        #if os(tvOS)
        true
        #else
        false
        #endif
    }()

    /// Whether Discover should push its own search page for a search route.
    ///
    /// False wherever a Search tab exists: selecting that tab is the whole
    /// navigation, and pushing as well is the duplicate.
    public static func discoverPushesSearch(hasDedicatedSearchTab: Bool) -> Bool {
        !hasDedicatedSearchTab
    }

    /// Whether Discover shows its search page once a route has landed.
    ///
    /// Every route lands on Discover's root: the pages Discover pushed itself
    /// (the billboard title, a See All shelf) close first. Search then opens
    /// for a search route where there is no Search tab, and for a media route,
    /// whose title page is found and pushed by the search page.
    public static func discoverShowsSearch(for route: AppleAppRoute, hasDedicatedSearchTab: Bool) -> Bool {
        switch route {
        case .search: discoverPushesSearch(hasDedicatedSearchTab: hasDedicatedSearchTab)
        case .media, .sharedLink: true
        case .continueWatching, .live: false
        }
    }

    /// Whether Discover still has to act on a router revision.
    ///
    /// Once per revision: Discover sees the same revision again when it comes
    /// back on screen (a tab switch, a page popped off it), and acting again
    /// then would reopen Search over a route that was already handled.
    public static func discoverHandlesRoute(revision: Int, handledRevision: Int) -> Bool {
        revision != handledRevision
    }

    /// Whether a media route closes and reopens a Search that is already up.
    ///
    /// That Search sits under the title page an earlier route pushed and never
    /// sees the new route, so a second link would do nothing. Not while a
    /// player is up: closing Search would pull the page out from under it.
    /// A sheet or an alert does not count; closing Search closes them too.
    public static func discoverReopensSearch(for route: AppleAppRoute, wantsSearch: Bool,
                                             searchShowing: Bool, playerOnScreen: Bool) -> Bool {
        guard case .media = route else { return false }
        return wantsSearch && searchShowing && !playerOnScreen
    }
}
