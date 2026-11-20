import Foundation
import Testing
@testable import OpenStreamApple

/// What each row of the SharePlay source prompt says.
@Suite("SharePlay source choice titles")
struct AppleSharedChannelSourceChoiceTests {
    private func channel(_ id: String, _ name: String, source: UUID) -> AppleIPTVChannel {
        AppleIPTVChannel(id: id, sourceID: source, name: name, group: "All",
                         logoURL: nil, streamURL: URL(string: "https://fixture.example/\(id).m3u8")!)
    }

    @Test("Each row is named for its source, in the given order")
    func namedForSource() {
        let first = UUID(), second = UUID()
        let choices = AppleSharedChannelSourceChoice.choices(
            for: [channel("a", "News One", source: first), channel("b", "News One HD", source: second)],
            sourceNames: [first: "Home Lineup", second: "Backup Lineup"])
        #expect(choices.map(\.title) == ["Home Lineup", "Backup Lineup"])
        #expect(choices.map(\.id) == ["a", "b"])
    }

    @Test("A source that is gone, or has a blank name, falls back to the channel name")
    func missingSourceFallsBack() {
        let known = UUID(), blank = UUID()
        let choices = AppleSharedChannelSourceChoice.choices(
            for: [channel("a", "News One", source: UUID()), channel("b", "News Two", source: blank),
                  channel("c", "News Three", source: known)],
            sourceNames: [known: "Home Lineup", blank: "  "])
        #expect(choices.map(\.title) == ["News One", "News Two", "Home Lineup"])
    }

    @Test("Rows that would read the same add the channel name")
    func collidingSourcesAddChannelName() {
        let first = UUID(), second = UUID(), other = UUID()
        let choices = AppleSharedChannelSourceChoice.choices(
            for: [channel("a", "News One", source: first), channel("b", "News One East", source: second),
                  channel("c", "News One", source: other)],
            sourceNames: [first: "IPTV", second: "IPTV", other: "Backup"])
        #expect(choices.map(\.title) == ["IPTV · News One", "IPTV · News One East", "Backup"])
    }

    @Test("One source carrying the channel twice still gives two readable rows")
    func sameSourceTwice() {
        let source = UUID()
        let choices = AppleSharedChannelSourceChoice.choices(
            for: [channel("a", "News One", source: source), channel("b", "News One HD", source: source)],
            sourceNames: [source: "IPTV"])
        #expect(choices.map(\.title) == ["IPTV · News One", "IPTV · News One HD"])
    }

    @Test("Rows still alike after adding the channel name are numbered")
    func stillAlikeAreNumbered() {
        let first = UUID(), second = UUID()
        let gone = AppleSharedChannelSourceChoice.choices(
            for: [channel("a", "News One", source: UUID()), channel("b", "News One", source: UUID())],
            sourceNames: [:])
        #expect(gone.map(\.title) == ["News One (1)", "News One (2)"])
        let namedForChannel = AppleSharedChannelSourceChoice.choices(
            for: [channel("a", "News One", source: first), channel("b", "News One", source: second),
                  channel("c", "News Two", source: UUID())],
            sourceNames: [first: "News One", second: "News One"])
        #expect(namedForChannel.map(\.title) == ["News One (1)", "News One (2)", "News Two"])
    }

    @Test("No candidates, no rows")
    func empty() {
        #expect(AppleSharedChannelSourceChoice.choices(for: [], sourceNames: [:]).isEmpty)
    }

    @Test("Only Leave SharePlay is destructive; a source row is not")
    func onlyLeaveIsDestructive() {
        let choices = AppleSharedChannelSourceChoice.choices(
            for: [channel("a", "News One", source: UUID())], sourceNames: [:])
        let actions = choices.map(AppleSharedSourcePromptAction.choose) + [.leave]
        #expect(actions.filter(\.isDestructive) == [.leave])
        #expect(actions.map(\.title) == ["News One", "Leave SharePlay"])
    }
}
