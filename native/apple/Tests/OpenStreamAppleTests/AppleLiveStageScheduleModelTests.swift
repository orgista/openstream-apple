import Foundation
import Testing
@testable import OpenStreamApple

struct AppleLiveStageScheduleModelTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func programme(_ id: String, channel: String = "news", from minutes: Double, to end: Double) -> AppleIPTVProgramme {
        AppleIPTVProgramme(id: id, channelID: channel, title: id, subtitle: nil, description: nil,
                           start: start.addingTimeInterval(minutes * 60), end: start.addingTimeInterval(end * 60),
                           category: nil, isLive: false)
    }

    @Test func splitsTheCurrentProgrammeFromTheNextTwelveHours() {
        let guide = AppleIPTVGuide(programmes: [
            programme("earlier", from: -120, to: -60),
            programme("current", from: -60, to: 30),
            programme("next", from: 30, to: 90),
            programme("tonight", from: 600, to: 700),
            programme("tomorrow", from: 13 * 60, to: 14 * 60),
            programme("other channel", channel: "film", from: 30, to: 90),
        ])
        let schedule = AppleLiveStageScheduleModel(guide: guide, channelID: "news", at: start)
        #expect(schedule.now?.id == "current")
        #expect(schedule.later.map(\.id) == ["next", "tonight"])
    }

    @Test func aChannelWithoutAGuideHasNothingToList() {
        let schedule = AppleLiveStageScheduleModel(guide: AppleIPTVGuide(programmes: []), channelID: "news", at: start)
        #expect(schedule.now == nil)
        #expect(schedule.later.isEmpty)
    }
}
