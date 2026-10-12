import Foundation
import Testing
@testable import OpenStreamApple

/// Full test 2026-10-01: with the IPTV panel down, My Channels spun forever.
@Suite("Channel Manager load deadline")
struct AppleChannelManagerLoadTests {
    @Test func aPanelThatNeverAnswersTimesOut() async {
        await #expect(throws: URLError.self) {
            try await AppleChannelManagerLoad.withDeadline(.milliseconds(50)) {
                try await Task.sleep(for: .seconds(30))
                return 1
            }
        }
    }

    @Test func anAnswerInTimeComesThrough() async throws {
        let value = try await AppleChannelManagerLoad.withDeadline(.seconds(5)) { 7 }
        #expect(value == 7)
    }

    @Test func aTimeoutReadsPlainly() {
        #expect(AppleChannelManagerLoad.message(sourceName: "Panel", error: URLError(.timedOut))
            == "Panel is not responding.")
    }
}
