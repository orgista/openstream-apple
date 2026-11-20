import Foundation
import Testing
@testable import OpenStreamApple

@Suite struct AppleGuideRegressionTests {
    private func programme(_ id: String, start: Double, end: Double, channel: String = "one") -> AppleIPTVProgramme {
        AppleIPTVProgramme(id: id, channelID: channel, title: id, subtitle: nil, description: nil,
            start: Date(timeIntervalSince1970: start), end: Date(timeIntervalSince1970: end), category: nil, isLive: false)
    }

    @Test func overlappingAndDuplicateProgrammesDoNotShiftTheTimeline() {
        let result = AppleGuideGridModel.build(channels: ["one", "one"], programmes: ["one": [
            programme("a", start: 0, end: 2400),
            programme("a", start: 0, end: 2400),
            programme("b", start: 1800, end: 3600),
            programme("invalid", start: 4000, end: 2000),
            programme("wrong-channel", start: 0, end: 3600, channel: "two"),
        ]], window: DateInterval(start: Date(timeIntervalSince1970: 0), duration: 3600),
            slotWidthMinutes: 30, now: Date(timeIntervalSince1970: 600))
        #expect(result.rows.count == 1)
        let cells = result.rows[0].cells
        #expect(cells.count == 2)
        #expect(Set(cells.map(\.id)).count == cells.count)
        #expect(cells.reduce(0) { $0 + $1.columnSpan } == 2)
        #expect(cells.last?.start == Date(timeIntervalSince1970: 2400))
    }

    @Test func completeLineupDoesNotRepeatNumbersForHDAndEastVariants() {
        let source = UUID()
        let channels = ["CBS", "CBS HD", "CBS (EAST)", "CBS (WEST)"].enumerated().map { index, name in
            AppleIPTVChannel(id: String(index), sourceID: source, name: name,
                streamURL: URL(string: "http://127.0.0.1/fixture.mp4")!)
        }
        let entries = [AppleChannelLineupEntry(number: 2, name: "CBS", aliases: ["CBS HD", "CBS (EAST)"], category: "Local")]
        let result = AppleChannelProjection.completeGuideGroups(from: channels, entries: entries).flatMap(\.channels)
        #expect(result.count == 1)
        #expect(result.first?.name == "CBS")
    }

    @Test func guideFavoritesAreRealAndChannelsBeyondThreeHundredRemainReachable() {
        let source = UUID()
        let channels = (0..<5200).map { index in
            AppleIPTVChannel(id: String(index), sourceID: source, name: "Channel \(index)",
                streamURL: URL(string: "http://127.0.0.1/fixture.mp4")!)
        }
        let all = AppleGuideChannelProjection.rows(channels: channels, entries: [], favoriteIDs: [], favoritesOnly: false, sortByNumber: true)
        #expect(all.count == 5200)
        let favorites = AppleGuideChannelProjection.rows(channels: channels, entries: [], favoriteIDs: ["5199"], favoritesOnly: true, sortByNumber: true)
        #expect(favorites.map(\.id) == ["5199"])
    }

    @Test func todaysGuideStartsNearNowAndIncludesTheEvening() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 15 * 3600 + 17 * 60)
        let window = AppleGuideChannelProjection.window(day: now, now: now, calendar: calendar)
        #expect(window.start == Date(timeIntervalSince1970: 15 * 3600))
        #expect(window.contains(now))
        #expect(window.end == Date(timeIntervalSince1970: 24 * 3600))
    }
}

/// d018726 meant logo + number + name, but the number only ever came from the
/// curated US lineup; a provider's own `tvg-chno` was never read.
@Test func guideRowsShowThePlaylistChannelNumber() throws {
    let playlist = """
    #EXTM3U
    #EXTINF:-1 tvg-id="a" tvg-chno="12" group-title="News",Atlas News
    http://a.example/a.m3u8
    #EXTINF:-1 tvg-id="b" tvg-chno="x" group-title="News",Beacon News
    http://a.example/b.m3u8
    #EXTINF:-1 tvg-id="c" tvg-chno="3" group-title="Sports",Cedar Sports
    http://a.example/c.m3u8
    """
    let channels = try AppleIPTVClient.parseM3U(Data(playlist.utf8), sourceID: UUID(), baseURL: URL(string: "http://a.example/")!)
    #expect(channels.map(\.channelNumber) == [12, nil, 3])
    let rows = AppleGuideChannelProjection.rows(channels: channels, entries: [], favoriteIDs: [], favoritesOnly: false, sortByNumber: true)
    #expect(rows.map(\.channel.name) == ["Cedar Sports", "Atlas News", "Beacon News"])
    #expect(rows.map(\.number) == [3, 12, nil])
    #expect(AppleIPTVChannel.playlistChannelNumber(" 7 ") == 7)
    #expect(AppleIPTVChannel.playlistChannelNumber("0") == nil)
    #expect(AppleIPTVChannel.playlistChannelNumber("5.1") == nil)
}
