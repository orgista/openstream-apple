import SwiftUI

/// The root owns navigation; the sign-in page only reports completion.
struct AppleMediaServerConnectionAction {
    let open: @MainActor () -> Void
    @MainActor func callAsFunction() { open() }
}

extension EnvironmentValues {
    @Entry var appleMediaServerConnected: AppleMediaServerConnectionAction? = nil
}
