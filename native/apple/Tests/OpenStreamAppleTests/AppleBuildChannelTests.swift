import Testing
@testable import OpenStreamApple

@Suite struct AppleBuildChannelTests {
    @Test func sandboxReceiptMeansTestFlight() {
        #expect(AppleBuildChannel.isTestFlightReceipt("sandboxReceipt"))
    }

    @Test func appStoreReceiptAndNoReceiptAreNotTestFlight() {
        #expect(!AppleBuildChannel.isTestFlightReceipt("receipt"))
        #expect(!AppleBuildChannel.isTestFlightReceipt(nil))
    }
}

@Suite struct AppleTraceDefaultTests {
    @Test func testFlightTracesUnlessTheBuildSaysOtherwise() {
        #expect(AppleInteractionTrace.defaultEnabled(infoPlistFlag: nil, isTestFlight: true))
        #expect(!AppleInteractionTrace.defaultEnabled(infoPlistFlag: false, isTestFlight: true))
    }

    @Test func appStoreStaysOffUnlessTheBuildTurnsItOn() {
        #expect(!AppleInteractionTrace.defaultEnabled(infoPlistFlag: nil, isTestFlight: false))
        #expect(AppleInteractionTrace.defaultEnabled(infoPlistFlag: true, isTestFlight: false))
    }
}
