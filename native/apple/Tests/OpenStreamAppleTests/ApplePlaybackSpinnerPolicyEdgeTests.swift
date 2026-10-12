import Foundation
import Testing
@testable import OpenStreamApple

/// Edge cases for `ApplePlaybackSpinnerPolicy` the main suite in
/// `AppleTransportOverlayModelTests.swift` does not exercise: the fourth
/// route case, a route already known before `hasRouted` has latched, and
/// the idle (`isBusy == false`) side of the "once routed, always hidden"
/// rule.
@Suite("Playback spinner policy: routes and idle states the main suite skips")
struct ApplePlaybackSpinnerPolicyEdgeTests {
    @Test func audioOnlyRouteNeverShowsTheScreenSpinner() {
        #expect(!ApplePlaybackSpinnerPolicy.showsScreenSpinner(route: .audioOnly, isBusy: true, hasRouted: false))
        #expect(!ApplePlaybackSpinnerPolicy.showsScreenSpinner(route: .audioOnly, isBusy: true, hasRouted: true))
        #expect(!ApplePlaybackSpinnerPolicy.showsScreenSpinner(route: .audioOnly, isBusy: false, hasRouted: false))
    }

    /// A route the coordinator has already picked, but `hasRouted` has not
    /// yet flipped to `true` for it: still no screen spinner, because the
    /// rule keys off the route value itself, not the latch.
    @Test func aRouteAlreadyKnownNeverShowsTheSpinnerBeforeTheLatchFlips() {
        for route: ApplePlaybackPresentationRoute in [.surface, .avPlayer, .audioOnly] {
            #expect(!ApplePlaybackSpinnerPolicy.showsScreenSpinner(route: route, isBusy: true, hasRouted: false))
        }
    }

    /// The main suite only proves the latch suppresses the spinner while
    /// busy; it must suppress it while idle too.
    @Test func hasRoutedSuppressesTheSpinnerRegardlessOfBusyState() {
        #expect(!ApplePlaybackSpinnerPolicy.showsScreenSpinner(route: .none, isBusy: false, hasRouted: true))
        #expect(!ApplePlaybackSpinnerPolicy.showsScreenSpinner(route: .surface, isBusy: false, hasRouted: true))
    }

    /// An idle `.none` route (no request in flight yet) never draws the
    /// spinner, whether or not the latch has fired.
    @Test func idleNoneRouteNeverShowsTheSpinnerEitherWayOfTheLatch() {
        #expect(!ApplePlaybackSpinnerPolicy.showsScreenSpinner(route: .none, isBusy: false, hasRouted: false))
        #expect(!ApplePlaybackSpinnerPolicy.showsScreenSpinner(route: .none, isBusy: false, hasRouted: true))
    }

    /// Exhaustive over every route (`CaseIterable`), so a fifth route added
    /// later is exercised automatically: the spinner shows in exactly one
    /// combination — `.none`, busy, not yet routed.
    @Test func onlyTheIdleUnroutedBusyNoneCombinationShowsTheSpinner() {
        for route in ApplePlaybackPresentationRoute.allCases {
            for isBusy in [true, false] {
                for hasRouted in [true, false] {
                    let expected = (route == .none) && isBusy && !hasRouted
                    #expect(
                        ApplePlaybackSpinnerPolicy.showsScreenSpinner(route: route, isBusy: isBusy, hasRouted: hasRouted) == expected,
                        "route: \(route), isBusy: \(isBusy), hasRouted: \(hasRouted)"
                    )
                }
            }
        }
    }
}
