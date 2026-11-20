import SwiftUI

/// Programmatic access to the Settings tab's navigation path, for flows that
/// move on by themselves (a successful Connect opens the folders) or end
/// several pages deep (Add returns to where the flow started). Every step is
/// a real path entry, so Back and the Apple TV Menu button go back one step.
@MainActor
struct AppleSettingsNavigator {
    let depth: () -> Int
    let push: (any Hashable) -> Void
    let pop: (_ toDepth: Int) -> Void
}

extension EnvironmentValues {
    /// Set once by the root view on the Settings stack; nil elsewhere.
    @Entry var appleSettingsNavigator: AppleSettingsNavigator? = nil
}
