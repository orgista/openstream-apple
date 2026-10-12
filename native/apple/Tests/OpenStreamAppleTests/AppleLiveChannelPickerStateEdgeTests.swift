import Foundation
import Testing
@testable import OpenStreamApple

/// Edge-case tests for AppleLiveChannelPickerState beyond the reopen and
/// select-before-switch coverage in AppleLiveChannelPickerStateTests.
@MainActor
@Suite("Live channel picker presentation edges")
struct AppleLiveChannelPickerStateEdgeTests {
    private func makeChannel(_ id: String) throws -> AppleIPTVChannel {
        AppleIPTVChannel(
            id: id,
            sourceID: UUID(),
            name: "Channel A",
            group: "Channel Group A",
            logoURL: try #require(URL(string: "https://fixture.example/\(id)-logo.png")),
            streamURL: try #require(URL(string: "https://fixture.example/\(id).m3u8")),
            userAgent: "OpenStreamFixtureAgent/1.0",
            referer: "https://fixture.example/",
            origin: "https://fixture.example",
            guideID: "guide-\(id)",
            guideURL: try #require(URL(string: "https://fixture.example/\(id)-guide.xml"))
        )
    }

    @Test func dismissWithoutAPriorShowStaysNotPresented() {
        let picker = AppleLiveChannelPickerState()
        picker.dismiss()
        #expect(picker.isPresented == false)
        picker.dismiss()
        #expect(picker.isPresented == false)
    }

    @Test func showIsIdempotentWhenCalledWhileAlreadyPresented() {
        let picker = AppleLiveChannelPickerState()
        picker.show()
        picker.show()
        #expect(picker.isPresented == true)
    }

    @Test func selectStillInvokesTheCallbackWhenThePickerWasNeverShown() throws {
        let picker = AppleLiveChannelPickerState()
        let channel = try makeChannel("never-shown")
        var selections: [AppleIPTVChannel] = []

        #expect(picker.isPresented == false)
        picker.select(channel) { selections.append($0) }

        #expect(selections == [channel])
        #expect(picker.isPresented == false)
    }

    @Test func callbackThatReopensThePickerLeavesItPresentedAfterSelectReturns() throws {
        // select() only dismisses BEFORE invoking onSelect; it never dismisses again
        // afterwards, so a callback that re-opens the picker sticks.
        let picker = AppleLiveChannelPickerState()
        let channel = try makeChannel("reopen")

        picker.show()
        picker.select(channel) { _ in picker.show() }

        #expect(picker.isPresented == true)
    }

    @Test func dismissCalledAgainInsideTheCallbackIsHarmless() throws {
        let picker = AppleLiveChannelPickerState()
        let channel = try makeChannel("double-dismiss")

        picker.show()
        picker.select(channel) { _ in picker.dismiss() }

        #expect(picker.isPresented == false)
    }

    @Test func multipleSequentialSelectionsAreAllRecordedInCallOrder() throws {
        let picker = AppleLiveChannelPickerState()
        let first = try makeChannel("first")
        let second = try makeChannel("second")
        var selections: [AppleIPTVChannel] = []

        picker.show()
        picker.select(first) { selections.append($0) }
        picker.show()
        picker.select(second) { selections.append($0) }

        #expect(selections == [first, second])
        #expect(picker.isPresented == false)
    }

    @Test func selectPassesTheExactChannelValueUnchangedToTheCallback() throws {
        let picker = AppleLiveChannelPickerState()
        let channel = try makeChannel("full-fields")
        var received: AppleIPTVChannel?

        picker.show()
        picker.select(channel) { received = $0 }

        #expect(received == channel)
    }
}
