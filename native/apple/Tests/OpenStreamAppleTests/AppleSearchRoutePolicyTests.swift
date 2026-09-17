import Testing
@testable import OpenStreamApple

/// A Siri phrase or a deep link used to select Discover and then push
/// Discover's own search page on top — on Apple TV, which already carries
/// Search as a tab. The pushed page also carried a `navigationTitle`, which on
/// tvOS draws over the page.
@Suite("Search route destination")
struct AppleSearchRoutePolicyTests {
    @Test func aPlatformWithASearchTabDoesNotAlsoPushSearch() {
        #expect(AppleSearchRoutePolicy.discoverPushesSearch(hasDedicatedSearchTab: true) == false)
    }

    @Test func aPlatformWithoutOneReachesSearchByPushingIt() {
        #expect(AppleSearchRoutePolicy.discoverPushesSearch(hasDedicatedSearchTab: false))
    }

    /// Apple TV is the platform with the tab; the phone and pad push.
    @Test func theTelevisionIsTheOneWithTheTab() {
        #if os(tvOS)
        #expect(AppleSearchRoutePolicy.platformHasDedicatedSearchTab)
        #else
        #expect(!AppleSearchRoutePolicy.platformHasDedicatedSearchTab)
        #endif
    }

    /// The two halves must agree: wherever the tab exists, nothing pushes.
    @Test func theTwoHalvesNeverBothFire() {
        let pushes = AppleSearchRoutePolicy.discoverPushesSearch(
            hasDedicatedSearchTab: AppleSearchRoutePolicy.platformHasDedicatedSearchTab)
        #expect(pushes != AppleSearchRoutePolicy.platformHasDedicatedSearchTab)
    }
}
