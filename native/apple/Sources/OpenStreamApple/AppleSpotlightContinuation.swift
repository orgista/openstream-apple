import SwiftUI

#if canImport(CoreSpotlight) && !os(tvOS)
import CoreSpotlight

public extension View {
    /// Tapping an OpenStream result in Spotlight opens that title, not
    /// whatever screen was last up. Handles cold and warm launches.
    func appleSpotlightContinuation(_ router: AppleAppRouter) -> some View {
        onContinueUserActivity(CSSearchableItemActionType) { activity in
            router.openSpotlightResult(
                identifier: activity.userInfo?[CSSearchableItemActivityIdentifier] as? String)
        }
    }
}
#else
public extension View {
    /// Apple TV has no Spotlight index (`AppleSpotlightIndexer`).
    func appleSpotlightContinuation(_ router: AppleAppRouter) -> some View { self }
}
#endif
