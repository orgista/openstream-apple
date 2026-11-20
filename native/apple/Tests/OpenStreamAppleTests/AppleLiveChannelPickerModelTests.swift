import Foundation
import Testing
@testable import OpenStreamApple

/// `AppleLiveChannelPickerEntry.entries` is what the full-screen channel
/// picker actually renders: one row per channel, its current now-playing
/// title pulled from the already-loaded guide, and whether it is the channel
/// on screen. `AppleLiveChannelPickerPresentation` decides the picker's shape.
@Suite("Live channel picker model")
struct AppleLiveChannelPickerModelTests {
    private func channel(_ id: String, name: String) -> AppleIPTVChannel {
        AppleIPTVChannel(
            id: id,
            sourceID: UUID(),
            name: name,
            streamURL: URL(string: "https://fixture.example/live/\(id).m3u8")!
        )
    }

    private func programme(channel: String, title: String, start: Date, end: Date) -> AppleIPTVProgramme {
        AppleIPTVProgramme(
            id: "\(channel)-\(title)",
            channelID: channel,
            title: title,
            subtitle: nil,
            description: nil,
            start: start,
            end: end,
            category: nil,
            isLive: true
        )
    }

    @Test func entriesMapTheNowTitleAndMarkTheCurrentChannel() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let news = channel("news", name: "News One")
        let sports = channel("sports", name: "Sports One")
        let guide = AppleIPTVGuide(programmes: [
            programme(channel: "news", title: "Evening Report",
                start: now.addingTimeInterval(-300), end: now.addingTimeInterval(300)),
        ])

        let entries = AppleLiveChannelPickerEntry.entries(
            channels: [news, sports],
            guide: guide,
            currentChannelID: "news",
            at: now
        )

        #expect(entries.map(\.id) == ["news", "sports"])
        #expect(entries[0].nowTitle == "Evening Report")
        #expect(entries[0].isCurrent)
        // Sports has no programme in the guide at all, not a blank one.
        #expect(entries[1].nowTitle == nil)
        #expect(!entries[1].isCurrent)
    }

    @Test func entriesTrimWhitespaceAndDropABlankNowTitle() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let padded = channel("padded", name: "Padded")
        let blank = channel("blank", name: "Blank")
        let guide = AppleIPTVGuide(programmes: [
            programme(channel: "padded", title: "  Late Show  ",
                start: now.addingTimeInterval(-60), end: now.addingTimeInterval(60)),
            programme(channel: "blank", title: "   ",
                start: now.addingTimeInterval(-60), end: now.addingTimeInterval(60)),
        ])

        let entries = AppleLiveChannelPickerEntry.entries(
            channels: [padded, blank], guide: guide, currentChannelID: nil, at: now
        )

        #expect(entries[0].nowTitle == "Late Show")
        #expect(entries[1].nowTitle == nil)
    }

    @Test func entriesWithNoCurrentChannelIDMarkNothingAsCurrent() {
        let now = Date(timeIntervalSince1970: 3_000_000)
        let channels = [channel("one", name: "One"), channel("two", name: "Two")]
        let entries = AppleLiveChannelPickerEntry.entries(
            channels: channels, guide: AppleIPTVGuide(programmes: []), currentChannelID: nil, at: now
        )
        #expect(entries.allSatisfy { !$0.isCurrent })
    }

    @Test func entriesFromAnEmptyChannelListIsEmpty() {
        let entries = AppleLiveChannelPickerEntry.entries(
            channels: [], guide: AppleIPTVGuide(programmes: []), currentChannelID: "anything"
        )
        #expect(entries.isEmpty)
    }

    @Test func accessibilityLabelJoinsNameCurrentStateAndNowTitleInOrder() {
        let base = channel("one", name: "One")
        let now = Date(timeIntervalSince1970: 4_000_000)
        let guide = AppleIPTVGuide(programmes: [
            programme(channel: "one", title: "The Show",
                start: now.addingTimeInterval(-60), end: now.addingTimeInterval(60)),
        ])
        let empty = AppleIPTVGuide(programmes: [])

        let currentWithShow = AppleLiveChannelPickerEntry.entries(
            channels: [base], guide: guide, currentChannelID: "one", at: now
        )[0]
        #expect(currentWithShow.accessibilityLabel == "One, Now playing, The Show")

        let currentWithoutShow = AppleLiveChannelPickerEntry.entries(
            channels: [base], guide: empty, currentChannelID: "one", at: now
        )[0]
        #expect(currentWithoutShow.accessibilityLabel == "One, Now playing")

        let notCurrentWithShow = AppleLiveChannelPickerEntry.entries(
            channels: [base], guide: guide, currentChannelID: nil, at: now
        )[0]
        #expect(notCurrentWithShow.accessibilityLabel == "One, The Show")

        let notCurrentWithoutShow = AppleLiveChannelPickerEntry.entries(
            channels: [base], guide: empty, currentChannelID: nil, at: now
        )[0]
        #expect(notCurrentWithoutShow.accessibilityLabel == "One")
    }

    @Test func choosePicksTheBottomStripOnlyForLargeLayouts() {
        #expect(AppleLiveChannelPickerPresentation.choose(isLargeLayout: true) == .bottomStrip)
        #expect(AppleLiveChannelPickerPresentation.choose(isLargeLayout: false) == .panel)
    }
}
