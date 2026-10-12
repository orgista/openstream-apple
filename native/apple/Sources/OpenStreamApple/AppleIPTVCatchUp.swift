import Foundation

/// How a playlist says its archive is reached: the M3U `catchup` attribute
/// (TiviMate / Kodi IPTV Simple vocabulary) plus its `catchup-source`
/// template. Xtream panels need none of this — their timeshift endpoint is
/// derived from the live URL — but a channel may still carry `.xtream` when
/// the playlist said `catchup="xc"`.
public struct AppleIPTVCatchUpSpec: Sendable, Equatable, Codable {
    public enum Style: String, Sendable, Codable {
        /// `catchup="default"`: `catchup-source` is the archive URL itself
        /// (a template with placeholders), or a suffix when it has no scheme.
        case `default`
        /// `catchup="append"`: `catchup-source` is appended to the live URL.
        case append
        /// `catchup="flussonic"` / `fs` / `flussonic-hls` / `flussonic-ts`:
        /// `…/<stream>/index.m3u8` → `…/<stream>/archive-<utc>-<seconds>.m3u8`.
        case flussonic
        /// `catchup="shift"` / `timeshift`: `?utc=<start>&lutc=<now>` on the live URL.
        case shift
        /// `catchup="xc"`: the Xtream timeshift endpoint.
        case xtream
    }

    public var style: Style
    public var source: String?

    public init(style: Style, source: String? = nil) {
        self.style = style
        let trimmed = source?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.source = trimmed.isEmpty ? nil : trimmed
    }

    /// Reads the `catchup` / `catchup-source` / `catchup-type` attributes of
    /// an `#EXTINF` line (keys lowercased). nil when the entry declares none.
    public static func from(attributes: [String: String]) -> AppleIPTVCatchUpSpec? {
        let raw = (attributes["catchup"] ?? attributes["catchup-type"])?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let source = attributes["catchup-source"]
        let style: Style
        switch raw {
        case "default", "1", "yes", "true":
            style = .default
        case "append":
            style = .append
        case "flussonic", "fs", "flussonic-hls", "flussonic-ts":
            style = .flussonic
        case "shift", "timeshift":
            style = .shift
        case "xc", "xtream":
            style = .xtream
        case "":
            // A template without a style behaves like `default`.
            guard let source, !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            style = .default
        default:
            return nil
        }
        return AppleIPTVCatchUpSpec(style: style, source: source)
    }

    /// `catchup-days="3"` or `timeshift="3"` (both are days), capped like
    /// the Xtream archive duration.
    public static func days(attributes: [String: String]) -> Int? {
        for key in ["catchup-days", "timeshift", "tvg-rec"] {
            if let value = attributes[key].flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }), value > 0 {
                return min(value, 30)
            }
        }
        return nil
    }
}

/// Catch-up (archive) playback: a programme that already aired on a channel
/// whose provider keeps an archive, played from the provider's archive URL.
///
/// Xtream: `GET /timeshift/<user>/<pass>/<minutes>/<YYYY-MM-DD:HH-MM>/<stream_id>.ts`,
/// derived from the channel's own live URL (`/live/<user>/<pass>/<stream_id>.<ext>`),
/// so no credentials are stored or passed anywhere new. The start is written
/// in the panel's own clock (`server_info.timezone`), which is where every
/// time-zone bug in this feature lives.
///
/// M3U: the `catchup` styles in `AppleIPTVCatchUpSpec`, with unix timestamps
/// (zone-free) wherever the style allows it.
///
/// Pure functions; the guide asks, the player plays.
public enum AppleIPTVCatchUp: Sendable {
    /// The guide scrolls back at most this far, whatever the panel keeps.
    public static let maximumGuideDays = 3

    /// Days of archive from the panel's `tv_archive` / `tv_archive_duration`;
    /// nil when the channel has none.
    public static func archiveDays(tvArchive: String?, duration: String?) -> Int? {
        guard let flag = tvArchive?.trimmingCharacters(in: .whitespaces), flag == "1" || flag.lowercased() == "true",
              let days = duration.flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }), days > 0 else {
            return nil
        }
        return min(days, 30)
    }

    /// The panel's clock: its reported zone, else UTC.
    public static func timeZone(for channel: AppleIPTVChannel) -> TimeZone {
        channel.catchUpTimeZoneID.flatMap(TimeZone.init(identifier:)) ?? TimeZone(identifier: "UTC")!
    }

    /// Whether the channel can play anything from an archive: it reports
    /// archive days and its URL has a known archive shape.
    public static func supportsCatchUp(_ channel: AppleIPTVChannel) -> Bool {
        guard let days = channel.catchUpDays, days > 0 else { return false }
        if let spec = channel.catchUp {
            switch spec.style {
            case .xtream: return timeshiftBase(for: channel.streamURL) != nil
            case .default: return spec.source != nil
            case .append: return spec.source != nil
            case .flussonic, .shift: return true
            }
        }
        return timeshiftBase(for: channel.streamURL) != nil
    }

    /// How far back the guide may scroll for `channel` at `now`: the panel's
    /// archive, capped at `maximumGuideDays`. nil when there is no archive.
    public static func earliestGuideTime(for channel: AppleIPTVChannel, now: Date = Date()) -> Date? {
        guard supportsCatchUp(channel), let days = channel.catchUpDays else { return nil }
        return now.addingTimeInterval(-Double(min(days, maximumGuideDays)) * 86_400)
    }

    /// The earliest guide time across `channels` (the guide's one window
    /// serves every row), or nil when none has an archive.
    public static func earliestGuideTime(for channels: some Sequence<AppleIPTVChannel>, now: Date = Date()) -> Date? {
        channels.compactMap { earliestGuideTime(for: $0, now: now) }.min()
    }

    /// Whether `programme` on `channel` can be played from the archive at `now`:
    /// it has ended (a programme still airing is the live channel), and it
    /// started inside the panel's archive window.
    public static func isAvailable(
        _ programme: AppleIPTVProgramme,
        on channel: AppleIPTVChannel,
        now: Date = Date()
    ) -> Bool {
        isAvailable(start: programme.start, end: programme.end, on: channel, now: now)
    }

    /// `isAvailable` for a guide cell, which carries the programme's air times.
    public static func isAvailable(
        start: Date, end: Date,
        on channel: AppleIPTVChannel,
        now: Date = Date()
    ) -> Bool {
        guard let days = channel.catchUpDays, days > 0, supportsCatchUp(channel) else { return false }
        guard end <= now, end > start else { return false }
        return start >= now.addingTimeInterval(-Double(days) * 86_400)
    }

    /// Current programmes use the provider's archive URL from the original air start.
    /// Keep this separate from past catch-up eligibility, which requires an ended programme.
    public static func canStartOver(_ programme: AppleIPTVProgramme, on channel: AppleIPTVChannel,
                                    now: Date = Date()) -> Bool {
        guard programme.channelID == channel.id, programme.start <= now, programme.end > now,
              supportsCatchUp(channel), let days = channel.catchUpDays,
              programme.start >= now.addingTimeInterval(-Double(days) * 86_400) else { return false }
        return catchUpURL(for: channel, programme: programme, now: now) != nil
    }

    public static func startOverRequest(for channel: AppleIPTVChannel, programme: AppleIPTVProgramme,
                                        now: Date = Date()) -> ApplePlaybackRequest? {
        guard canStartOver(programme, on: channel, now: now) else { return nil }
        return playbackRequest(for: channel, programme: programme, now: now)
    }

    /// The archive URL for `programme`, whatever the channel's style; nil when
    /// the channel has no usable archive shape.
    public static func catchUpURL(
        for channel: AppleIPTVChannel,
        programme: AppleIPTVProgramme,
        now: Date = Date()
    ) -> URL? {
        guard let spec = channel.catchUp else {
            return timeshiftURL(for: channel, programme: programme)
        }
        let start = Int(programme.start.timeIntervalSince1970)
        let end = Int(programme.end.timeIntervalSince1970)
        let seconds = max(60, end - start)
        switch spec.style {
        case .xtream:
            return timeshiftURL(for: channel, programme: programme)
        case .default, .append:
            guard let source = spec.source else { return nil }
            let filled = fill(template: source, channel: channel, programme: programme, now: now)
            if spec.style == .default, let url = URL(string: filled), url.scheme != nil, url.host != nil {
                return url
            }
            return appending(filled, to: channel.streamURL)
        case .shift:
            return appending("?utc=\(start)&lutc=\(Int(now.timeIntervalSince1970))", to: channel.streamURL)
        case .flussonic:
            guard var components = URLComponents(url: channel.streamURL, resolvingAgainstBaseURL: false) else { return nil }
            var segments = components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard let last = segments.popLast(), !segments.isEmpty else { return nil }
            let file: String
            if last == "mpegts" || last.hasSuffix(".ts") {
                file = "timeshift_abs-\(start).ts"
            } else if last == "video.m3u8" {
                file = "video-\(start)-\(seconds).m3u8"
            } else {
                file = "archive-\(start)-\(seconds).m3u8"
            }
            components.percentEncodedPath = (segments + [file]).joined(separator: "/")
            return components.url
        }
    }

    /// The panel's timeshift URL for `programme`, or nil when the channel's
    /// URL is not an Xtream live URL.
    ///
    /// - Parameter timeZone: the panel's clock. Panels read the start time in
    ///   their own zone; the channel's reported zone (else UTC) when nil.
    public static func timeshiftURL(
        for channel: AppleIPTVChannel,
        programme: AppleIPTVProgramme,
        timeZone: TimeZone? = nil
    ) -> URL? {
        guard let base = timeshiftBase(for: channel.streamURL) else { return nil }
        let minutes = max(1, Int((programme.end.timeIntervalSince(programme.start) / 60).rounded(.up)))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone ?? self.timeZone(for: channel)
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: programme.start)
        guard let year = parts.year, let month = parts.month, let day = parts.day,
              let hour = parts.hour, let minute = parts.minute else { return nil }
        let start = String(format: "%04d-%02d-%02d:%02d-%02d", year, month, day, hour, minute)
        let liveExtension = channel.streamURL.pathExtension.lowercased()
        let container = liveExtension == "m3u8" ? "m3u8" : "ts"
        var components = base.components
        components.percentEncodedPath = "\(base.prefix)/timeshift/\(base.user)/\(base.password)/\(minutes)/\(start)/\(base.streamID).\(container)"
        return components.url
    }

    /// A playback request for the archived programme: on demand (it has a
    /// length and can be scrubbed), titled after the programme.
    public static func playbackRequest(
        for channel: AppleIPTVChannel,
        programme: AppleIPTVProgramme,
        timeZone: TimeZone? = nil,
        now: Date = Date()
    ) -> ApplePlaybackRequest? {
        let url: URL?
        if let timeZone {
            url = timeshiftURL(for: channel, programme: programme, timeZone: timeZone)
        } else {
            url = catchUpURL(for: channel, programme: programme, now: now)
        }
        guard let url else { return nil }
        var request = ApplePlaybackRequest(
            url: url,
            headers: channel.playbackHeaders,
            isLive: false,
            mediaID: "\(channel.id)#catchup-\(Int(programme.start.timeIntervalSince1970))",
            title: programme.title,
            sourceKind: .liveTV
        )
        request.artworkURL = channel.logoURL
        request.restrictionChannelID = channel.id
        request.restrictionGroup = channel.group
        return request
    }

    /// Whether `request` came from `playbackRequest(for:programme:)`.
    public static func isCatchUp(_ request: ApplePlaybackRequest) -> Bool {
        request.sourceKind == .liveTV && !request.isLive && request.mediaID.contains("#catchup-")
    }

    /// An unavailable archive is final: retrying or opening the live fallback would play the wrong programme.
    public static func unavailableFailure(for failure: ApplePlaybackFailure, request: ApplePlaybackRequest) -> ApplePlaybackFailure? {
        guard isCatchUp(request), failure.httpStatus == 403 || failure.httpStatus == 404 else { return nil }
        return ApplePlaybackFailure(kind: .unavailable, message: "Catch-up isn't available for this programme",
            httpStatus: failure.httpStatus)
    }

    // MARK: - Templates

    /// Fills a `catchup-source` template. Both vocabularies are accepted:
    /// `{utc}` `{lutc}` `{duration}` `{duration:60}` `{Y}{m}{d}{H}{M}{S}`
    /// (Kodi / TiviMate) and `${start}` `${end}` `${timestamp}` `${now}`
    /// `${duration}` `${duration:60}`. Date parts are in the channel's clock.
    static func fill(template: String, channel: AppleIPTVChannel, programme: AppleIPTVProgramme, now: Date) -> String {
        let start = Int(programme.start.timeIntervalSince1970)
        let end = Int(programme.end.timeIntervalSince1970)
        let seconds = max(0, end - start)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone(for: channel)
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: programme.start)
        var result = template
        let replacements: [(String, String)] = [
            ("{utc}", "\(start)"), ("${start}", "\(start)"), ("${utc}", "\(start)"),
            ("{lutc}", "\(Int(now.timeIntervalSince1970))"), ("${timestamp}", "\(Int(now.timeIntervalSince1970))"),
            ("${now}", "\(Int(now.timeIntervalSince1970))"), ("${lutc}", "\(Int(now.timeIntervalSince1970))"),
            ("{utcend}", "\(end)"), ("${end}", "\(end)"),
            ("{duration:60}", "\(max(1, Int((Double(seconds) / 60).rounded(.up))))"),
            ("${duration:60}", "\(max(1, Int((Double(seconds) / 60).rounded(.up))))"),
            ("{duration}", "\(seconds)"), ("${duration}", "\(seconds)"),
            ("{Y}", String(format: "%04d", parts.year ?? 0)), ("{m}", String(format: "%02d", parts.month ?? 0)),
            ("{d}", String(format: "%02d", parts.day ?? 0)), ("{H}", String(format: "%02d", parts.hour ?? 0)),
            ("{M}", String(format: "%02d", parts.minute ?? 0)), ("{S}", String(format: "%02d", parts.second ?? 0)),
        ]
        for (token, value) in replacements {
            result = result.replacingOccurrences(of: token, with: value)
        }
        return result
    }

    /// Appends a `catchup-source` suffix to the live URL: a `?…` suffix joins
    /// an existing query with `&`; anything else is appended as written.
    private static func appending(_ suffix: String, to url: URL) -> URL? {
        var text = url.absoluteString
        var suffix = suffix
        if suffix.hasPrefix("?"), text.contains("?") {
            suffix = "&" + suffix.dropFirst()
        } else if suffix.hasPrefix("&"), !text.contains("?") {
            suffix = "?" + suffix.dropFirst()
        }
        text += suffix
        return URL(string: text)
    }

    private struct Base {
        var components: URLComponents
        var prefix: String
        var user: String
        var password: String
        var streamID: String
    }

    /// Splits `<prefix>/live/<user>/<pass>/<id>.<ext>` (percent-encoded parts
    /// kept as they are).
    private static func timeshiftBase(for streamURL: URL) -> Base? {
        guard var components = URLComponents(url: streamURL, resolvingAgainstBaseURL: false) else { return nil }
        let segments = components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard segments.count >= 5, segments[segments.count - 4] == "live" else { return nil }
        let file = segments[segments.count - 1]
        let streamID = file.split(separator: ".").first.map(String.init) ?? ""
        guard !streamID.isEmpty, streamID.allSatisfy(\.isNumber) else { return nil }
        let prefix = segments[0 ..< segments.count - 4].joined(separator: "/")
        components.query = nil
        components.fragment = nil
        return Base(components: components, prefix: prefix,
                    user: segments[segments.count - 3], password: segments[segments.count - 2], streamID: streamID)
    }
}
