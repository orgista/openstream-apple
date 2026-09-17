import Foundation
import Testing
@testable import OpenStreamApple

@Suite("AppleGuideGridModel Tests")
struct AppleGuideGridModelTests {
    @Test func testClamping() async throws {
        let window = DateInterval(start: Date(timeIntervalSince1970: 3600), duration: 7200)
        
        let progs = [
            AppleIPTVProgramme(id: "1", channelID: "ch1", title: "A", subtitle: nil, description: nil, start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 5400), category: nil, isLive: false),
            AppleIPTVProgramme(id: "2", channelID: "ch1", title: "B", subtitle: nil, description: nil, start: Date(timeIntervalSince1970: 5400), end: Date(timeIntervalSince1970: 10800), category: nil, isLive: false)
        ]
        
        let res = AppleGuideGridModel.build(channels: ["ch1"], programmes: ["ch1": progs], window: window, slotWidthMinutes: 30, now: Date(timeIntervalSince1970: 3600))
        
        #expect(res.rows.count == 1)
        let cells = res.rows[0].cells
        #expect(cells.count == 2)
        
        #expect(cells[0].title == "A")
        #expect(cells[0].columnOffset == 0.0)
        #expect(cells[0].columnSpan == 1.0)
        #expect(cells[0].start == Date(timeIntervalSince1970: 3600))
        #expect(cells[0].end == Date(timeIntervalSince1970: 5400))
        
        #expect(cells[1].title == "B")
        #expect(cells[1].columnOffset == 1.0)
        #expect(cells[1].columnSpan == 3.0)
        #expect(cells[1].start == Date(timeIntervalSince1970: 5400))
        #expect(cells[1].end == Date(timeIntervalSince1970: 10800))
    }
    
    @Test func testGaps() async throws {
        let window = DateInterval(start: Date(timeIntervalSince1970: 3600), duration: 7200)
        
        let progs = [
            AppleIPTVProgramme(id: "1", channelID: "ch1", title: "A", subtitle: nil, description: nil, start: Date(timeIntervalSince1970: 5400), end: Date(timeIntervalSince1970: 7200), category: nil, isLive: false)
        ]
        
        let res = AppleGuideGridModel.build(channels: ["ch1"], programmes: ["ch1": progs], window: window, slotWidthMinutes: 30, now: Date(timeIntervalSince1970: 3600))
        
        #expect(res.rows[0].cells.count == 3)
        #expect(res.rows[0].cells[0].title == "No information")
        #expect(res.rows[0].cells[0].columnOffset == 0.0)
        #expect(res.rows[0].cells[0].columnSpan == 1.0)
        
        #expect(res.rows[0].cells[1].title == "A")
        #expect(res.rows[0].cells[1].columnOffset == 1.0)
        #expect(res.rows[0].cells[1].columnSpan == 1.0)
        
        #expect(res.rows[0].cells[2].title == "No information")
        #expect(res.rows[0].cells[2].columnOffset == 2.0)
        #expect(res.rows[0].cells[2].columnSpan == 2.0)
    }
    
    @Test func testNowOffsetAndLabels() async throws {
        let window = DateInterval(start: Date(timeIntervalSince1970: 0), duration: 3600)
        
        let res = AppleGuideGridModel.build(channels: [], programmes: [:], window: window, slotWidthMinutes: 30, now: Date(timeIntervalSince1970: 900))
        
        #expect(res.nowOffset == 0.5)
        #expect(res.headerSlots.count == 2)
        #expect(!res.headerSlots[0].label.isEmpty)
    }
}

/// The Apple TV guide builds one model for the whole screen instead of one per
/// row per render, so these assert the indexed shape the rows read from.
@Suite("Apple guide grid index")
struct AppleGuideGridIndexTests {
    private let window = DateInterval(start: Date(timeIntervalSince1970: 3600), duration: 7200)

    private func programme(_ id: String, channel: String, from: TimeInterval, to: TimeInterval) -> AppleIPTVProgramme {
        AppleIPTVProgramme(id: id, channelID: channel, title: "P\(id)", subtitle: nil, description: nil,
            start: Date(timeIntervalSince1970: from), end: Date(timeIntervalSince1970: to),
            category: nil, isLive: false)
    }

    @Test func indexKeepsEveryChannelsCellsUnderItsOwnID() {
        let guide = AppleIPTVGuide(programmes: [
            programme("1", channel: "ch1", from: 3600, to: 7200),
            programme("2", channel: "ch2", from: 3600, to: 5400)
        ])
        let index = AppleGuideGridModel.index(channels: ["ch1", "ch2"], guide: guide, window: window,
            slotWidthMinutes: 30, now: Date(timeIntervalSince1970: 3600))
        #expect(index.cells(for: "ch1").first?.title == "P1")
        #expect(index.cells(for: "ch2").first?.title == "P2")
        // A channel with no programmes still gets the "No information" filler.
        #expect(index.cells(for: "ch3").isEmpty)
        #expect(index.headerSlots.count == 4)
    }

    @Test func indexMatchesBuildForTheSameInput() {
        let programmes = [programme("1", channel: "ch1", from: 3600, to: 5400)]
        let guide = AppleIPTVGuide(programmes: programmes)
        let now = Date(timeIntervalSince1970: 4000)
        let built = AppleGuideGridModel.build(channels: ["ch1"], programmes: ["ch1": programmes],
            window: window, slotWidthMinutes: 30, now: now)
        let index = AppleGuideGridModel.index(channels: ["ch1"], guide: guide, window: window,
            slotWidthMinutes: 30, now: now)
        #expect(index.cells(for: "ch1") == built.rows.first?.cells)
        #expect(index.headerSlots == built.headerSlots)
        #expect(index.nowOffset == built.nowOffset)
    }

    @Test func indexDropsRepeatedChannelIDs() {
        let guide = AppleIPTVGuide(programmes: [programme("1", channel: "ch1", from: 3600, to: 7200)])
        let index = AppleGuideGridModel.index(channels: ["ch1", "ch1"], guide: guide, window: window,
            slotWidthMinutes: 30, now: Date(timeIntervalSince1970: 3600))
        #expect(index.cellsByChannel.count == 1)
    }

    @Test func emptyIndexDrawsNothing() {
        #expect(AppleGuideGridIndex.empty.cellsByChannel.isEmpty)
        #expect(AppleGuideGridIndex.empty.headerSlots.isEmpty)
        #expect(AppleGuideGridIndex.empty.nowOffset == nil)
    }
}
