import Foundation
import Testing
@testable import OpenStreamApple

@MainActor
@Suite("Live channel picker presentation")
struct AppleLiveChannelPickerStateTests {
    @Test func dismissingThePickerAllowsItToBeOpenedAgain() {
        let picker = AppleLiveChannelPickerState()
        #expect(!picker.isPresented)
        picker.show()
        #expect(picker.isPresented)
        picker.dismiss()
        #expect(!picker.isPresented)
        picker.show()
        #expect(picker.isPresented)
    }

    @Test func selectionClosesThePickerBeforeSwitchingTheStream() throws {
        let picker = AppleLiveChannelPickerState()
        let channel = AppleIPTVChannel(
            id: "replacement", sourceID: UUID(), name: "Replacement", group: "News",
            streamURL: try #require(URL(string: "https://fixture.example/replacement.m3u8"))
        )
        var selections: [AppleIPTVChannel] = []

        picker.show()
        picker.select(channel) { selected in
            #expect(!picker.isPresented)
            selections.append(selected)
        }

        #expect(selections == [channel])
        #expect(!picker.isPresented)
        picker.show()
        picker.dismiss()
        #expect(selections == [channel])
    }
}
