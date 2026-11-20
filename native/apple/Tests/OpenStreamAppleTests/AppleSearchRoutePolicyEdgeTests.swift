import Testing
@testable import OpenStreamApple

/// `AppleSearchRoutePolicy` only has a `Bool -> Bool` decision and a static
/// platform flag, so its "boundary" is exhausting both possible inputs and
/// confirming the function reads only its parameter, not the platform, plus
/// that the memoized static flag is safe to read from concurrent tests.
/// `AppleSearchRoutePolicyTests` already covers the two calls with literal
/// arguments and the platform-derived combination; these don't repeat those.
@Suite struct AppleSearchRoutePolicyEdgeTests {
    @Test func discoverPushesSearchIsTheExactNegationForBothPossibleInputs() {
        for hasTab in [true, false] {
            #expect(AppleSearchRoutePolicy.discoverPushesSearch(hasDedicatedSearchTab: hasTab) == !hasTab)
        }
    }

    /// A caller that (wrongly) claims the current platform has a tab must
    /// still get `false` back, even on a platform where that isn't true --
    /// the function must not silently fall back to `platformHasDedicatedSearchTab`.
    @Test func discoverPushesSearchTreatsAnExplicitTrueAsHavingATabRegardlessOfPlatform() {
        #expect(AppleSearchRoutePolicy.discoverPushesSearch(hasDedicatedSearchTab: true) == false)
    }

    /// Same check in the other direction: an explicit `false` always pushes,
    /// even on tvOS where the real platform flag would say otherwise.
    @Test func discoverPushesSearchTreatsAnExplicitFalseAsHavingNoTabRegardlessOfPlatform() {
        #expect(AppleSearchRoutePolicy.discoverPushesSearch(hasDedicatedSearchTab: false) == true)
    }

    @Test func discoverPushesSearchIsDeterministicAcrossRepeatedCalls() {
        let results = (0..<10).map { _ in AppleSearchRoutePolicy.discoverPushesSearch(hasDedicatedSearchTab: true) }
        #expect(results.allSatisfy { $0 == false })
    }

    /// The flag is a lazily-initialised `static let`; reading it from many
    /// tasks concurrently (Swift Testing runs tests in parallel) must never
    /// produce a value that disagrees with a plain sequential read.
    @Test func platformHasDedicatedSearchTabIsStableAcrossConcurrentReads() async {
        let expected = AppleSearchRoutePolicy.platformHasDedicatedSearchTab
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<20 {
                group.addTask { AppleSearchRoutePolicy.platformHasDedicatedSearchTab }
            }
            for await value in group {
                #expect(value == expected)
            }
        }
    }
}
