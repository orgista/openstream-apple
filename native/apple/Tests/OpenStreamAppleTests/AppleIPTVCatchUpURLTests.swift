import Foundation
import Testing
@testable import OpenStreamApple

/// Catch-up URL building across the panel's time zones (including DST), the
/// M3U `catchup` styles, and the guide's past window.
@Suite("IPTV catch-up: time zones, styles, window")
struct AppleIPTVCatchUpURLTests {
    private let source = UUID()

    private func xtreamChannel(days: Int? = 3, zone: String? = nil, url: String = "http://fixture.example:8080/live/u%40x/p/101.ts") -> AppleIPTVChannel {
        var channel = AppleIPTVChannel(id: "c", sourceID: source, name: "Atlas News", streamURL: URL(string: url)!)
        channel.catchUpDays = days
        channel.catchUpTimeZoneID = zone
        return channel
    }

    private func m3uChannel(url: String, attributes: [String: String], days: Int? = nil) -> AppleIPTVChannel {
        var channel = AppleIPTVChannel(id: "m", sourceID: source, name: "Atlas News", streamURL: URL(string: url)!)
        channel.catchUp = AppleIPTVCatchUpSpec.from(attributes: attributes)
        channel.catchUpDays = days ?? AppleIPTVCatchUpSpec.days(attributes: attributes) ?? 1
        return channel
    }

    private func programme(start: Date, minutes: Double, title: String = "Morning Report") -> AppleIPTVProgramme {
        AppleIPTVProgramme(id: "p", channelID: "c", title: title, subtitle: nil, description: nil,
                           start: start, end: start.addingTimeInterval(minutes * 60), category: nil, isLive: false)
    }

    private func utc(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)!
    }

    private func startField(_ url: URL?) -> String? {
        url?.pathComponents.dropLast().last
    }

    @Test func startOverRequiresACurrentProgrammeAndAUsableArchive() throws {
        let now = utc("2026-10-01T12:00:00Z")
        let current = programme(start: now.addingTimeInterval(-1800), minutes: 60)
        let channel = xtreamChannel()
        #expect(AppleIPTVCatchUp.canStartOver(current, on: channel, now: now))
        let request = try #require(AppleIPTVCatchUp.startOverRequest(for: channel, programme: current, now: now))
        #expect(request.isLive == false)
        #expect(request.url == AppleIPTVCatchUp.catchUpURL(for: channel, programme: current, now: now))
        #expect(request.resumePosition == nil)
        #expect(AppleIPTVCatchUp.isCatchUp(request))
        #expect(AppleIPTVCatchUp.canStartOver(current, on: xtreamChannel(days: nil), now: now) == false)
        #expect(AppleIPTVCatchUp.canStartOver(programme(start: now, minutes: 60), on: channel, now: now))
        #expect(AppleIPTVCatchUp.canStartOver(programme(start: now.addingTimeInterval(1), minutes: 60), on: channel, now: now) == false)
        #expect(AppleIPTVCatchUp.canStartOver(programme(start: now.addingTimeInterval(-3600), minutes: 60), on: channel, now: now) == false)
        #expect(AppleIPTVCatchUp.canStartOver(current, on: xtreamChannel(url: "https://fixture.example/live.m3u8"), now: now) == false)
        #expect(AppleIPTVCatchUp.startOverRequest(for: xtreamChannel(days: 0), programme: current, now: now) == nil)
    }

    // MARK: Xtream time zones

    @Test(arguments: [("m3u8", "m3u8"), ("ts", "ts"), ("", "ts"), ("mp4", "ts")])
    func timeshiftRetainsSupportedLiveContainer(extensions: (String, String)) {
        let suffix = extensions.0.isEmpty ? "" : "." + extensions.0
        let channel = xtreamChannel(url: "https://fixture.example/live/user/pass/101" + suffix)
        let result = AppleIPTVCatchUp.timeshiftURL(for: channel,
            programme: programme(start: utc("2026-01-15T14:30:00Z"), minutes: 30))
        #expect(result?.pathExtension == extensions.1)
    }

    @Test("The start is written in the panel's zone, UTC when it reports none")
    func panelZoneIsApplied() {
        let start = utc("2026-01-15T14:30:00Z")
        let p = programme(start: start, minutes: 60)
        #expect(startField(AppleIPTVCatchUp.timeshiftURL(for: xtreamChannel(), programme: p)) == "2026-01-15:14-30")
        #expect(startField(AppleIPTVCatchUp.timeshiftURL(for: xtreamChannel(zone: "Europe/Paris"), programme: p)) == "2026-01-15:15-30")
        #expect(startField(AppleIPTVCatchUp.timeshiftURL(for: xtreamChannel(zone: "America/New_York"), programme: p)) == "2026-01-15:09-30")
        #expect(startField(AppleIPTVCatchUp.timeshiftURL(for: xtreamChannel(zone: "Asia/Kolkata"), programme: p)) == "2026-01-15:20-00")
        // A fixed offset the panel reported as "+03:00" is kept as such.
        let offsetZone = AppleIPTVClient.serverTimeZoneID("+03:00")
        #expect(startField(AppleIPTVCatchUp.timeshiftURL(for: xtreamChannel(zone: offsetZone), programme: p)) == "2026-01-15:17-30")
        // An explicit zone still wins over the channel's.
        #expect(startField(AppleIPTVCatchUp.timeshiftURL(for: xtreamChannel(zone: "Europe/Paris"), programme: p,
                                                         timeZone: TimeZone(identifier: "UTC"))) == "2026-01-15:14-30")
    }

    @Test("Summer and winter time, and the day a zone switches")
    func daylightSaving() {
        let berlin = xtreamChannel(zone: "Europe/Berlin")
        // July: CEST = UTC+2.
        #expect(startField(AppleIPTVCatchUp.timeshiftURL(for: berlin, programme: programme(start: utc("2026-07-10T20:15:00Z"), minutes: 30))) == "2026-07-10:22-15")
        // January: CET = UTC+1.
        #expect(startField(AppleIPTVCatchUp.timeshiftURL(for: berlin, programme: programme(start: utc("2026-01-10T20:15:00Z"), minutes: 30))) == "2026-01-10:21-15")
        // 2026-03-29: clocks go 02:00 → 03:00 CET at 01:00 UTC.
        #expect(startField(AppleIPTVCatchUp.timeshiftURL(for: berlin, programme: programme(start: utc("2026-03-29T00:30:00Z"), minutes: 30))) == "2026-03-29:01-30")
        #expect(startField(AppleIPTVCatchUp.timeshiftURL(for: berlin, programme: programme(start: utc("2026-03-29T01:30:00Z"), minutes: 30))) == "2026-03-29:03-30")
        // 2026-10-25: 03:00 CEST → 02:00 CET at 01:00 UTC; 00:30 UTC is still summer time.
        #expect(startField(AppleIPTVCatchUp.timeshiftURL(for: berlin, programme: programme(start: utc("2026-10-25T00:30:00Z"), minutes: 30))) == "2026-10-25:02-30")
        #expect(startField(AppleIPTVCatchUp.timeshiftURL(for: berlin, programme: programme(start: utc("2026-10-25T01:30:00Z"), minutes: 30))) == "2026-10-25:02-30")
        // A zone that crosses midnight moves the date too.
        let auckland = xtreamChannel(zone: "Pacific/Auckland")
        #expect(startField(AppleIPTVCatchUp.timeshiftURL(for: auckland, programme: programme(start: utc("2026-01-15T14:30:00Z"), minutes: 30))) == "2026-01-16:03-30")
        // Minutes are the programme's length, rounded up, never below one.
        #expect(AppleIPTVCatchUp.timeshiftURL(for: berlin, programme: programme(start: utc("2026-01-10T20:15:00Z"), minutes: 0.4))?
            .pathComponents.dropLast(2).last == "1")
    }

    @Test("The panel's reported zone is read in every spelling it uses")
    func serverTimeZoneParsing() {
        #expect(AppleIPTVClient.serverTimeZoneID("Europe/London") == "Europe/London")
        #expect(AppleIPTVClient.serverTimeZoneID(" UTC ") == TimeZone(identifier: "UTC")!.identifier)
        #expect(AppleIPTVClient.serverTimeZoneID("+0300") == TimeZone(secondsFromGMT: 3 * 3600)!.identifier)
        #expect(AppleIPTVClient.serverTimeZoneID("UTC-05:00") == TimeZone(secondsFromGMT: -5 * 3600)!.identifier)
        #expect(AppleIPTVClient.serverTimeZoneID("GMT+2") == TimeZone(secondsFromGMT: 2 * 3600)!.identifier)
        #expect(AppleIPTVClient.serverTimeZoneID("+5:30") == TimeZone(secondsFromGMT: 5 * 3600 + 1800)!.identifier)
        #expect(AppleIPTVClient.serverTimeZoneID("") == nil)
        #expect(AppleIPTVClient.serverTimeZoneID("Mars/Olympus") == nil)
        #expect(AppleIPTVClient.serverTimeZoneID("+99") == nil)
        #expect(AppleIPTVCatchUp.timeZone(for: xtreamChannel(zone: nil)).secondsFromGMT() == 0)
        #expect(AppleIPTVCatchUp.timeZone(for: xtreamChannel(zone: "Nowhere/Here")).secondsFromGMT() == 0)
    }

    // MARK: Playable window

    @Test("Only programmes that have ended, inside the archive, on a channel with one")
    func playableWindow() {
        let now = utc("2026-10-01T12:00:00Z")
        let channel = xtreamChannel(days: 3)
        #expect(AppleIPTVCatchUp.isAvailable(programme(start: now.addingTimeInterval(-3600), minutes: 30), on: channel, now: now))
        // Ends exactly now: over, playable.
        #expect(AppleIPTVCatchUp.isAvailable(programme(start: now.addingTimeInterval(-1800), minutes: 30), on: channel, now: now))
        // Still on: that is the live channel.
        #expect(!AppleIPTVCatchUp.isAvailable(programme(start: now.addingTimeInterval(-1800), minutes: 60), on: channel, now: now))
        // Started exactly three days ago: inside.
        #expect(AppleIPTVCatchUp.isAvailable(programme(start: now.addingTimeInterval(-3 * 86_400), minutes: 60), on: channel, now: now))
        // A minute older: outside.
        #expect(!AppleIPTVCatchUp.isAvailable(programme(start: now.addingTimeInterval(-3 * 86_400 - 60), minutes: 60), on: channel, now: now))
        // No archive; zero days; not an Xtream live URL.
        #expect(!AppleIPTVCatchUp.isAvailable(programme(start: now.addingTimeInterval(-3600), minutes: 30), on: xtreamChannel(days: nil), now: now))
        #expect(!AppleIPTVCatchUp.isAvailable(programme(start: now.addingTimeInterval(-3600), minutes: 30), on: xtreamChannel(days: 0), now: now))
        #expect(!AppleIPTVCatchUp.isAvailable(programme(start: now.addingTimeInterval(-3600), minutes: 30),
                                              on: xtreamChannel(days: 3, url: "http://fixture.example/hls/5/live.m3u8"), now: now))
        // The cell form agrees with the programme form.
        #expect(AppleIPTVCatchUp.isAvailable(start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(-1800), on: channel, now: now))
        #expect(!AppleIPTVCatchUp.isAvailable(start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(-3600), on: channel, now: now))
    }

    @Test("The guide looks back at most three days, whatever the panel keeps")
    func guideLookback() {
        let now = utc("2026-10-01T12:00:00Z")
        #expect(AppleIPTVCatchUp.earliestGuideTime(for: xtreamChannel(days: 1), now: now) == now.addingTimeInterval(-86_400))
        #expect(AppleIPTVCatchUp.earliestGuideTime(for: xtreamChannel(days: 7), now: now) == now.addingTimeInterval(-3 * 86_400))
        #expect(AppleIPTVCatchUp.earliestGuideTime(for: xtreamChannel(days: nil), now: now) == nil)
        #expect(AppleIPTVCatchUp.earliestGuideTime(for: [xtreamChannel(days: nil), xtreamChannel(days: 2)], now: now) == now.addingTimeInterval(-2 * 86_400))
        #expect(AppleIPTVCatchUp.earliestGuideTime(for: [AppleIPTVChannel](), now: now) == nil)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let metrics = AppleTVGuideMetrics.standard
        let live = metrics.window(now: now, calendar: calendar)
        #expect(live.start == now)
        let past = metrics.window(now: utc("2026-10-01T12:20:00Z"), calendar: calendar, earliest: utc("2026-09-28T12:20:00Z"))
        #expect(past.start == utc("2026-09-28T12:00:00Z"))
        #expect(past.end == live.end)
        // The present slot still has its place for the first scroll.
        #expect(metrics.xOffset(of: metrics.slotStart(of: utc("2026-10-01T12:20:00Z"), calendar: calendar), in: past)
            == CGFloat(3 * 48) * metrics.slotWidth)
        let day = AppleGuideChannelProjection.window(day: now, now: now, calendar: calendar, earliest: now.addingTimeInterval(-86_400))
        #expect(day.start == utc("2026-09-30T12:00:00Z"))
        #expect(AppleGuideChannelProjection.window(day: now, now: now, calendar: calendar).start == now)
        // Still under the grid model's 336-slot guard.
        #expect(past.duration / metrics.slotDuration <= 336)
    }

    @Test("A grid cell turns back into the programme it drew")
    func cellProgramme() {
        let start = utc("2026-10-01T10:00:00Z")
        let cell = AppleGuideGridCell(id: "c-programme-1", channelID: "c", start: start.addingTimeInterval(600), end: start.addingTimeInterval(1800),
                                      columnOffset: 0, columnSpan: 1, title: "Morning Report", subtitle: "News", isLive: false,
                                      airStart: start, airEnd: start.addingTimeInterval(3600))
        let programme = cell.programme
        #expect(programme.start == start)
        #expect(programme.end == start.addingTimeInterval(3600))
        #expect(programme.title == "Morning Report")
        #expect(programme.description == "News")
        #expect(programme.channelID == "c")
    }

    // MARK: M3U styles

    @Test("catchup attributes: style, template and days")
    func attributes() {
        #expect(AppleIPTVCatchUpSpec.from(attributes: [:]) == nil)
        #expect(AppleIPTVCatchUpSpec.from(attributes: ["catchup": "unknown"]) == nil)
        #expect(AppleIPTVCatchUpSpec.from(attributes: ["catchup": "default"])?.style == .default)
        #expect(AppleIPTVCatchUpSpec.from(attributes: ["catchup": "append", "catchup-source": "?utc={utc}"]) == AppleIPTVCatchUpSpec(style: .append, source: "?utc={utc}"))
        #expect(AppleIPTVCatchUpSpec.from(attributes: ["catchup": "fs"])?.style == .flussonic)
        #expect(AppleIPTVCatchUpSpec.from(attributes: ["catchup": "flussonic-hls"])?.style == .flussonic)
        #expect(AppleIPTVCatchUpSpec.from(attributes: ["catchup": "shift"])?.style == .shift)
        #expect(AppleIPTVCatchUpSpec.from(attributes: ["catchup": "xc"])?.style == .xtream)
        #expect(AppleIPTVCatchUpSpec.from(attributes: ["catchup-type": "timeshift"])?.style == .shift)
        // A template alone is a default-style archive.
        #expect(AppleIPTVCatchUpSpec.from(attributes: ["catchup-source": "http://a.example/{utc}"])?.style == .default)
        #expect(AppleIPTVCatchUpSpec.days(attributes: ["catchup-days": "5"]) == 5)
        #expect(AppleIPTVCatchUpSpec.days(attributes: ["timeshift": "2"]) == 2)
        #expect(AppleIPTVCatchUpSpec.days(attributes: ["catchup-days": "99"]) == 30)
        #expect(AppleIPTVCatchUpSpec.days(attributes: ["catchup-days": "0"]) == nil)
        #expect(AppleIPTVCatchUpSpec.days(attributes: [:]) == nil)
    }

    @Test("default: the template is the archive URL; both placeholder vocabularies")
    func defaultStyle() {
        let start = utc("2026-01-15T14:30:00Z")
        let now = utc("2026-01-15T18:00:00Z")
        let p = programme(start: start, minutes: 45)
        let channel = m3uChannel(url: "http://a.example/live/5.m3u8", attributes: [
            "catchup": "default", "catchup-days": "3",
            "catchup-source": "http://a.example/archive/5?start={utc}&end=${end}&d={duration}&m={duration:60}&now=${timestamp}&t={Y}{m}{d}T{H}{M}{S}",
        ])
        let url = AppleIPTVCatchUp.catchUpURL(for: channel, programme: p, now: now)
        #expect(url?.absoluteString == "http://a.example/archive/5?start=1768487400&end=1768490100&d=2700&m=45&now=1768500000&t=20260115T143000")
        // The date parts follow the channel's zone, like the Xtream form.
        var zoned = channel
        zoned.catchUpTimeZoneID = "Europe/Paris"
        #expect(AppleIPTVCatchUp.catchUpURL(for: zoned, programme: p, now: now)?.absoluteString.hasSuffix("t=20260115T153000") == true)
        #expect(AppleIPTVCatchUp.supportsCatchUp(channel))
        #expect(AppleIPTVCatchUp.isAvailable(p, on: channel, now: now))
        // No template: nothing to build.
        let bare = m3uChannel(url: "http://a.example/live/5.m3u8", attributes: ["catchup": "default"])
        #expect(!AppleIPTVCatchUp.supportsCatchUp(bare))
        #expect(AppleIPTVCatchUp.catchUpURL(for: bare, programme: p, now: now) == nil)
    }

    @Test("append and shift add to the live URL; existing queries join with &")
    func appendAndShift() {
        let start = utc("2026-01-15T14:30:00Z")
        let now = utc("2026-01-15T18:00:00Z")
        let p = programme(start: start, minutes: 30)
        let append = m3uChannel(url: "http://a.example/live/5.m3u8", attributes: ["catchup": "append", "catchup-source": "?utc={utc}&lutc={lutc}"])
        #expect(AppleIPTVCatchUp.catchUpURL(for: append, programme: p, now: now)?.absoluteString == "http://a.example/live/5.m3u8?utc=1768487400&lutc=1768500000")
        let appendQuery = m3uChannel(url: "http://a.example/live/5.m3u8?token=t", attributes: ["catchup": "append", "catchup-source": "?utc={utc}"])
        #expect(AppleIPTVCatchUp.catchUpURL(for: appendQuery, programme: p, now: now)?.absoluteString == "http://a.example/live/5.m3u8?token=t&utc=1768487400")
        // A `default` template without a scheme behaves like `append`.
        let suffix = m3uChannel(url: "http://a.example/live/5.m3u8", attributes: ["catchup": "default", "catchup-source": "&utc={utc}"])
        #expect(AppleIPTVCatchUp.catchUpURL(for: suffix, programme: p, now: now)?.absoluteString == "http://a.example/live/5.m3u8?utc=1768487400")
        let shift = m3uChannel(url: "http://a.example/live/5.m3u8", attributes: ["catchup": "shift"])
        #expect(AppleIPTVCatchUp.catchUpURL(for: shift, programme: p, now: now)?.absoluteString == "http://a.example/live/5.m3u8?utc=1768487400&lutc=1768500000")
        #expect(AppleIPTVCatchUp.supportsCatchUp(shift))
    }

    @Test("flussonic archives by stream, in seconds; xc is the Xtream endpoint")
    func flussonicAndXC() {
        let start = utc("2026-01-15T14:30:00Z")
        let now = utc("2026-01-15T18:00:00Z")
        let p = programme(start: start, minutes: 30)
        let hls = m3uChannel(url: "http://f.example/news/index.m3u8?token=t", attributes: ["catchup": "flussonic", "catchup-days": "2"])
        #expect(AppleIPTVCatchUp.catchUpURL(for: hls, programme: p, now: now)?.absoluteString == "http://f.example/news/archive-1768487400-1800.m3u8?token=t")
        let video = m3uChannel(url: "http://f.example/news/video.m3u8", attributes: ["catchup": "flussonic-hls"])
        #expect(AppleIPTVCatchUp.catchUpURL(for: video, programme: p, now: now)?.absoluteString == "http://f.example/news/video-1768487400-1800.m3u8")
        let ts = m3uChannel(url: "http://f.example/news/mpegts", attributes: ["catchup": "flussonic-ts"])
        #expect(AppleIPTVCatchUp.catchUpURL(for: ts, programme: p, now: now)?.absoluteString == "http://f.example/news/timeshift_abs-1768487400.ts")
        let xc = m3uChannel(url: "http://x.example/live/user/pass/77.m3u8", attributes: ["catchup": "xc", "catchup-days": "1"])
        #expect(AppleIPTVCatchUp.catchUpURL(for: xc, programme: p, now: now)?.absoluteString == "http://x.example/timeshift/user/pass/30/2026-01-15:14-30/77.m3u8")
        // xc on a URL that is not an Xtream live URL has nothing to build from.
        let xcBad = m3uChannel(url: "http://x.example/hls/77.m3u8", attributes: ["catchup": "xc"])
        #expect(!AppleIPTVCatchUp.supportsCatchUp(xcBad))
    }

    @Test("The playback request is on demand and carries the programme")
    func request() {
        let start = utc("2026-01-15T14:30:00Z")
        let p = programme(start: start, minutes: 30, title: "Evening Edition")
        let channel = m3uChannel(url: "http://a.example/live/5.m3u8", attributes: ["catchup": "shift", "catchup-days": "3"])
        let request = AppleIPTVCatchUp.playbackRequest(for: channel, programme: p, now: start.addingTimeInterval(7200))
        #expect(request?.isLive == false)
        #expect(request?.title == "Evening Edition")
        #expect(request?.sourceKind == .liveTV)
        #expect(request.map(AppleIPTVCatchUp.isCatchUp) == true)
        #expect(!AppleIPTVCatchUp.isCatchUp(channel.playbackRequest()))
        #expect(request?.url.absoluteString.hasPrefix("http://a.example/live/5.m3u8?utc=1768487400") == true)
    }

    @Test("M3U entries keep their catchup attributes; cached channels without them still decode")
    func playlistParsing() throws {
        let playlist = """
        #EXTM3U
        #EXTINF:-1 tvg-id="atlas.fx" catchup="append" catchup-days="2" catchup-source="?utc={utc}&lutc={lutc}",Atlas News
        http://a.example/live/5.m3u8
        #EXTINF:-1 tvg-id="orbit.fx",Orbit Sports
        http://a.example/live/6.m3u8
        """
        let channels = try AppleIPTVClient.parseM3U(Data(playlist.utf8), sourceID: source, baseURL: URL(string: "http://a.example/")!)
        #expect(channels.count == 2)
        #expect(channels[0].catchUp == AppleIPTVCatchUpSpec(style: .append, source: "?utc={utc}&lutc={lutc}"))
        #expect(channels[0].catchUpDays == 2)
        #expect(channels[1].catchUp == nil)
        #expect(channels[1].catchUpDays == nil)

        let legacy = Data("""
        {"id":"c","sourceID":"\(source.uuidString)","name":"Atlas News","group":"","streamURL":"http://a.example/live/5.m3u8"}
        """.utf8)
        let decoded = try JSONDecoder().decode(AppleIPTVChannel.self, from: legacy)
        #expect(decoded.catchUp == nil)
        #expect(decoded.catchUpTimeZoneID == nil)
        var zoned = decoded
        zoned.catchUpTimeZoneID = "Europe/Paris"
        zoned.catchUp = AppleIPTVCatchUpSpec(style: .shift)
        let again = try JSONDecoder().decode(AppleIPTVChannel.self, from: JSONEncoder().encode(zoned))
        #expect(again.catchUpTimeZoneID == "Europe/Paris")
        #expect(again.catchUp?.style == .shift)
        #expect(again.withGuideURL(nil).catchUp?.style == .shift)
    }
}
