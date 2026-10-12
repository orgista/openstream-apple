import Foundation
import Testing
@testable import OpenStreamApple

struct AppleLiveGuideLookupTests {
    private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    private func programme(_ id: String, _ start: Double, _ end: Double, channel: String = "fixture.example") -> AppleIPTVProgramme {
        AppleIPTVProgramme(id: id, channelID: channel, title: id, subtitle: nil, description: nil,
                           start: epoch.addingTimeInterval(start), end: epoch.addingTimeInterval(end), category: nil, isLive: false)
    }

    @Test func programmeBoundariesAndGaps() {
        let guide = AppleIPTVGuide(programmes: [programme("second", 20, 30), programme("first", 0, 10)])
        let cases: [(Double, String?, String?)] = [
            (-1, nil, "first"), (0, "first", "second"), (9, "first", "second"),
            (10, nil, "second"), (19, nil, "second"), (20, "second", nil), (30, nil, nil)
        ]
        for (offset, now, next) in cases {
            let result = guide.nowAndNext(channelID: "fixture.example", at: epoch.addingTimeInterval(offset))
            #expect(result.now?.id == now)
            #expect(result.next?.id == next)
        }
        #expect(guide.nowAndNext(channelID: "missing", at: epoch).now == nil)
        #expect(guide.nowAndNext(channelID: "missing", at: epoch).next == nil)
    }

    @Test func overlappingProgrammeSurvivesLaterExpiredEntries() {
        let guide = AppleIPTVGuide(programmes: [programme("long", 0, 100), programme("short", 10, 20), programme("later", 30, 40)])
        #expect(guide.nowAndNext(channelID: "fixture.example", at: epoch.addingTimeInterval(15)).now?.id == "short")
        let result = guide.nowAndNext(channelID: "fixture.example", at: epoch.addingTimeInterval(25))
        #expect(result.now?.id == "long")
        #expect(result.next?.id == "later")
        #expect(guide.nowAndNext(channelID: "fixture.example", at: epoch.addingTimeInterval(90)).now?.id == "long")
    }

    @Test func equalStartsKeepLastActiveAndFirstFutureSemantics() {
        let guide = AppleIPTVGuide(programmes: [programme("first", 10, 50), programme("second", 10, 20), programme("future", 60, 70)])
        #expect(guide.nowAndNext(channelID: "fixture.example", at: epoch).next?.id == "first")
        #expect(guide.nowAndNext(channelID: "fixture.example", at: epoch.addingTimeInterval(10)).now?.id == "second")
        #expect(guide.nowAndNext(channelID: "fixture.example", at: epoch.addingTimeInterval(20)).now?.id == "first")
    }

    @Test func indexedGuideMatchesReferenceAcrossIrregularSchedules() {
        var programmes: [AppleIPTVProgramme] = []
        for i in 0..<96 {
            let start = Double(i * 30)
            let duration: Double = i % 7 == 0 ? 180 : 15
            programmes.append(programme("show-\(i)", start, start + duration))
        }
        let guide = AppleIPTVGuide(programmes: Array(programmes.reversed()))
        for offset in stride(from: -1, through: 3100, by: 7) {
            let time = epoch.addingTimeInterval(Double(offset))
            let result = guide.nowAndNext(channelID: "fixture.example", at: time)
            #expect(result.now == programmes.last { $0.start <= time && $0.end > time })
            #expect(result.next == programmes.first { $0.start > time })
        }
    }

    @Test func newGuideReplacesProgrammeDataWithoutTimeCache() {
        let before = AppleIPTVGuide(programmes: [programme("old", 0, 30)])
        let after = AppleIPTVGuide(programmes: [programme("replacement", 0, 30)])
        #expect(before.nowAndNext(channelID: "fixture.example", at: epoch).now?.id == "old")
        #expect(after.nowAndNext(channelID: "fixture.example", at: epoch).now?.id == "replacement")
        #expect(AppleIPTVGuide(programmes: []).nowAndNext(channelID: "fixture.example", at: epoch).now == nil)
    }

    @Test func channelIndexKeepsFirstDuplicateAndFullLineup() throws {
        let source = UUID()
        let url = try #require(URL(string: "https://fixture.example/live.ts"))
        let first = AppleIPTVChannel(id: "same", sourceID: source, name: "First", streamURL: url)
        let duplicate = AppleIPTVChannel(id: "same", sourceID: source, name: "Duplicate", streamURL: url)
        let hidden = AppleIPTVChannel(id: "outside-filter", sourceID: source, name: "Other", streamURL: url)
        let index = AppleIPTVChannelIndex([first, duplicate, hidden])
        #expect(index.channels == [first, duplicate, hidden])
        #expect(index["same"] == first)
        #expect(index["outside-filter"] == hidden)
        #expect(index["missing"] == nil)
    }

    @Test func channelIndexReplacementAndClearCannotKeepStaleValues() throws {
        let source = UUID()
        let url = try #require(URL(string: "https://fixture.example/live.ts"))
        let old = AppleIPTVChannel(id: "same", sourceID: source, name: "Old", streamURL: url)
        let updated = AppleIPTVChannel(id: "same", sourceID: source, name: "Updated", streamURL: url)
        var index = AppleIPTVChannelIndex([old])
        index = AppleIPTVChannelIndex([updated])
        #expect(index["same"] == updated)
        index = AppleIPTVChannelIndex([])
        #expect(index.channels.isEmpty)
        #expect(index["same"] == nil)
    }
}
