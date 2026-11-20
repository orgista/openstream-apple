import SwiftUI

/// Switches to Settings and opens Sources, the page where a stream source
/// is added, fixed or signed in again. A struct rather than a bare closure,
/// like `AppleSettingsNavigator`, so the environment entry holds a value.
struct AppleOpenSourcesSettingsAction {
    let open: @MainActor () -> Void

    @MainActor func callAsFunction() { open() }
}

extension EnvironmentValues {
    /// Set once by the root view; a title page's "Sources…" answer to a
    /// playback failure calls it. Nil outside the app's root (previews, debug
    /// fixtures), where the page falls back to its own `openSettings`.
    @Entry var appleOpenSourcesSettings: AppleOpenSourcesSettingsAction? = nil
}
