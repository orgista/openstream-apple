import Foundation
import Testing
@testable import OpenStreamApple

@Suite("AppleGuideRowModel")
struct AppleGuideRowModelTests {
    @Test("Spans are laid out correctly for a 30-minute window")
    func layoutAndEquality() {
        let channel = AppleIPTVChannel(
            id: "chan-1",
            sourceID: UUID(),
            name: "Channel 1",
            streamURL: URL(string: "http://example.com/1.m3u8")!
        )
        let span1 = AppleGuideProgrammeSpan(
            id: "prog-1",
            startOffset: 0.0,
            width: 1.5, // 45 minutes / 30
            title: "News",
            subtitle: nil,
            isNow: false
        )
        let span2 = AppleGuideProgrammeSpan(
            id: "prog-2",
            startOffset: 1.5,
            width: 0.5, // 15 minutes / 30
            title: "Weather",
            subtitle: nil,
            isNow: true
        )
        let model = AppleGuideRowModel(
            id: "chan-1",
            channel: channel,
            number: 1,
            spans: [span1, span2]
        )
        
        #expect(model.id == "chan-1")
        #expect(model.spans.count == 2)
        #expect(model.spans[0].startOffset == 0.0)
        #expect(model.spans[0].width == 1.5)
        #expect(model.spans[0].isNow == false)
        #expect(model.spans[1].startOffset == 1.5)
        #expect(model.spans[1].width == 0.5)
        #expect(model.spans[1].isNow == true)
        
        let model2 = AppleGuideRowModel(
            id: "chan-1",
            channel: channel,
            number: 1,
            spans: [span1, span2]
        )
        #expect(model == model2)
        
        let span2NotNow = AppleGuideProgrammeSpan(
            id: "prog-2",
            startOffset: 1.5,
            width: 0.5,
            title: "Weather",
            subtitle: nil,
            isNow: false
        )
        let model3 = AppleGuideRowModel(
            id: "chan-1",
            channel: channel,
            number: 1,
            spans: [span1, span2NotNow]
        )
        #expect(model != model3)
    }
    @Test("Equality is stable across rebuilds with the same inputs")
    func equalityRebuilds() {
        let channel = AppleIPTVChannel(
            id: "chan-1",
            sourceID: UUID(),
            name: "Channel 1",
            streamURL: URL(string: "http://example.com/1.m3u8")!
        )
        let prog1 = AppleIPTVProgramme(
            id: "p1",
            channelID: "chan-1",
            title: "News",
            subtitle: nil,
            description: nil,
            start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: 3600),
            category: nil,
            isLive: false
        )
        let prog2 = AppleIPTVProgramme(
            id: "p1",
            channelID: "chan-1",
            title: "News 2",
            subtitle: nil,
            description: nil,
            start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: 3600),
            category: nil,
            isLive: false
        )
        let window = DateInterval(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 3600))
        let now = Date(timeIntervalSince1970: 1800)
        
        let buildRow = { (c: AppleIPTVChannel, programmes: [AppleIPTVProgramme], time: Date) -> AppleGuideRowModel in
            // Replicates the builder logic in AppleIPTVGuideGridView.swift
            let guide = AppleIPTVGuide(programmes: programmes)
            let gridIndex = AppleGuideGridModel.index(
                channels: [c.id],
                guide: guide,
                window: window,
                slotWidthMinutes: 30,
                now: time
            )
            let cells = gridIndex.cells(for: c.id)
            let spans = cells.map { cell in
                AppleGuideProgrammeSpan(
                    id: cell.id,
                    startOffset: cell.columnOffset,
                    width: cell.columnSpan,
                    title: cell.title,
                    subtitle: cell.subtitle,
                    isNow: cell.isLive || (cell.start <= time && cell.end > time)
                )
            }
            return AppleGuideRowModel(id: c.id, channel: c, number: 1, spans: spans)
        }
        
        let a = buildRow(channel, [prog1], now)
        let b = buildRow(channel, [prog1], now)
        #expect(a == b)
        
        let c = buildRow(channel, [prog2], now)
        #expect(a != c)
    }

    @Test("isNow flips only for the programme containing now")
    func isNowFlips() {
        let channel = AppleIPTVChannel(
            id: "chan-1",
            sourceID: UUID(),
            name: "Channel 1",
            streamURL: URL(string: "http://example.com/1.m3u8")!
        )
        
        let p1 = AppleIPTVProgramme(id: "p1", channelID: "chan-1", title: "Show 1", subtitle: nil, description: nil, start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 1800), category: nil, isLive: false)
        let p2 = AppleIPTVProgramme(id: "p2", channelID: "chan-1", title: "Show 2", subtitle: nil, description: nil, start: Date(timeIntervalSince1970: 1800), end: Date(timeIntervalSince1970: 3600), category: nil, isLive: false)
        let p3 = AppleIPTVProgramme(id: "p3", channelID: "chan-1", title: "Show 3", subtitle: nil, description: nil, start: Date(timeIntervalSince1970: 3600), end: Date(timeIntervalSince1970: 5400), category: nil, isLive: false)
        
        let guide = AppleIPTVGuide(programmes: [p1, p2, p3])
        let window = DateInterval(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 5400))
        
        let buildRow = { (time: Date) -> AppleGuideRowModel in
            let gridIndex = AppleGuideGridModel.index(
                channels: [channel.id],
                guide: guide,
                window: window,
                slotWidthMinutes: 30,
                now: time
            )
            let cells = gridIndex.cells(for: channel.id)
            let spans = cells.map { cell in
                AppleGuideProgrammeSpan(
                    id: cell.id,
                    startOffset: cell.columnOffset,
                    width: cell.columnSpan,
                    title: cell.title,
                    subtitle: cell.subtitle,
                    isNow: cell.isLive || (cell.start <= time && cell.end > time)
                )
            }
            return AppleGuideRowModel(id: channel.id, channel: channel, number: 1, spans: spans)
        }
        
        // now inside the second (Show 2 is from 1800 to 3600)
        let rowNowSecond = buildRow(Date(timeIntervalSince1970: 2000))
        #expect(rowNowSecond.spans.count == 3)
        #expect(rowNowSecond.spans[0].isNow == false)
        #expect(rowNowSecond.spans[1].isNow == true)
        #expect(rowNowSecond.spans[2].isNow == false)
        
        // now inside the third (Show 3 is from 3600 to 5400)
        let rowNowThird = buildRow(Date(timeIntervalSince1970: 4000))
        #expect(rowNowThird.spans.count == 3)
        #expect(rowNowThird.spans[0].isNow == false)
        #expect(rowNowThird.spans[1].isNow == false)
        #expect(rowNowThird.spans[2].isNow == true)
    }
}
