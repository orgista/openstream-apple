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
}
