import Foundation
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

/// `openSearch()` is the Mac ⌘F path, added because Search on macOS is a page
/// pushed from Discover with no tab and no shortcut to reach it.
@Suite("Opening search with no query")
@MainActor
struct AppleAppRouterOpenSearchTests {
    @Test("⌘F routes to Search with an empty field")
    func openSearchRoutesWithNoQuery() {
        let router = AppleAppRouter()
        router.openSearch()
        #expect(router.route == .search(""))
        #expect(router.searchQuery.isEmpty)
        #expect(router.revision == 1)
    }

    /// `showSearch(_:)` serves `openstream://search?query=…`, where a link with
    /// no term in it is a malformed link. That refusal is why ⌘F needed its own
    /// entry point rather than passing an empty string through this one.
    @Test("A deep link with no term is still refused")
    func showSearchStillRefusesAnEmptyQuery() {
        let router = AppleAppRouter()
        router.showSearch("   ")
        #expect(router.route == nil)
        #expect(router.revision == 0)
    }

    @Test("⌘F clears a query left over from an earlier deep link")
    func openSearchClearsAPreviousQuery() {
        let router = AppleAppRouter()
        router.showSearch("dune")
        #expect(router.searchQuery == "dune")
        router.openSearch()
        #expect(router.searchQuery.isEmpty)
        #expect(router.revision == 2)
    }
}

/// Discover used to be rebuilt for every route (its stack's `.id` carried the
/// router revision), which crashed iOS 18. It now moves its own navigation
/// state instead; these pin what that state becomes.
@Suite("Discover navigation for a route")
struct AppleDiscoverRouteNavigationTests {
    private static let mediaID = String(repeating: "a", count: 64)

    @Test("A search route opens Discover's search page only where there is no Search tab")
    func searchRoute() {
        #expect(AppleSearchRoutePolicy.discoverShowsSearch(for: .search("dune"), hasDedicatedSearchTab: false))
        #expect(!AppleSearchRoutePolicy.discoverShowsSearch(for: .search("dune"), hasDedicatedSearchTab: true))
    }

    @Test("A media route opens search, which finds and pushes the title", arguments: [false, true])
    func mediaRoute(hasDedicatedSearchTab: Bool) {
        for action in [AppleMediaRouteAction.display, .play] {
            #expect(AppleSearchRoutePolicy.discoverShowsSearch(
                for: .media(id: Self.mediaID, action: action), hasDedicatedSearchTab: hasDedicatedSearchTab))
        }
    }

    @Test("Continue Watching lands on Discover's root with search closed", arguments: [false, true])
    func continueWatchingRoute(hasDedicatedSearchTab: Bool) {
        #expect(!AppleSearchRoutePolicy.discoverShowsSearch(
            for: .continueWatching, hasDedicatedSearchTab: hasDedicatedSearchTab))
    }

    @Test("Discover acts on each revision once, not again when it reappears")
    func eachRevisionIsHandledOnce() {
        #expect(AppleSearchRoutePolicy.discoverHandlesRoute(revision: 1, handledRevision: 0))
        #expect(!AppleSearchRoutePolicy.discoverHandlesRoute(revision: 1, handledRevision: 1))
        #expect(AppleSearchRoutePolicy.discoverHandlesRoute(revision: 2, handledRevision: 1))
    }
}

/// App Intents (Siri, Shortcuts, Spotlight) go through the same router as a
/// deep link, so Discover handles both one way.
@Suite("Opening a route without a URL")
@MainActor
struct AppleAppRouterOpenRouteTests {
    @Test("An intent search sets the query and bumps the revision")
    func intentSearch() {
        let router = AppleAppRouter()
        router.open(.search("dune"))
        #expect(router.route == .search("dune"))
        #expect(router.searchQuery == "dune")
        #expect(router.revision == 1)
    }

    @Test("An intent media route keeps the last query and bumps the revision")
    func intentMedia() {
        let router = AppleAppRouter()
        router.showSearch("dune")
        let id = String(repeating: "b", count: 64)
        router.open(.media(id: id, action: .play))
        #expect(router.route == .media(id: id, action: .play))
        #expect(router.searchQuery == "dune")
        #expect(router.revision == 2)
    }

    @Test("A URL and the same route opened directly land identically")
    func urlAndRouteAgree() throws {
        let viaURL = AppleAppRouter()
        viaURL.open(try #require(URL(string: "openstream://search?query=dune")))
        let direct = AppleAppRouter()
        direct.open(.search("dune"))
        #expect(viaURL.route == direct.route)
        #expect(viaURL.searchQuery == direct.searchQuery)
        #expect(viaURL.revision == direct.revision)
    }
}
