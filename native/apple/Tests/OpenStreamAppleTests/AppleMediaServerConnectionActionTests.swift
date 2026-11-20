import SwiftUI
import Testing
@testable import OpenStreamApple

@MainActor
struct AppleMediaServerConnectionActionTests {
    @Test func connectedServerOpensItsCatalogSurface() {
        var destination: OpenStreamTab?
        let action = AppleMediaServerConnectionAction { destination = .home }
        action()
        #expect(destination?.title == "Discover")
    }

    @Test func previewsDoNotNavigateAfterConnecting() {
        #expect(EnvironmentValues().appleMediaServerConnected == nil)
    }
}
