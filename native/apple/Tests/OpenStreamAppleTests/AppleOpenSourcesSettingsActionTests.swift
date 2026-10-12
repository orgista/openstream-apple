import SwiftUI
import Testing
@testable import OpenStreamApple

@Suite("Open Sources settings action")
@MainActor
struct AppleOpenSourcesSettingsActionTests {
    @Test func callingTheActionRunsTheRootHandlerOnce() {
        var calls = 0
        let action = AppleOpenSourcesSettingsAction { calls += 1 }
        action()
        #expect(calls == 1)
    }

    @Test func outsideTheRootThereIsNoAction() {
        #expect(EnvironmentValues().appleOpenSourcesSettings == nil)
    }
}
