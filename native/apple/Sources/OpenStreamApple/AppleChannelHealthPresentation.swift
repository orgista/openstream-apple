import Foundation

/// The mark a channel row carries. Silence means healthy: a working channel,
/// or one never checked, has no indicator at all (owner, QUEUE item 4).
public enum AppleChannelHealthIndicator: Equatable, Sendable {
    /// Amber: the server answered but nothing playable came back.
    case notPlayable
    /// Red: the first request failed or timed out.
    case offline

    public init?(bucket: AppleChannelHealthBucket) {
        switch bucket {
        case .online: return nil
        case .reachable: self = .notPlayable
        case .offline, .timeout: self = .offline
        }
    }

    public init?(result: AppleChannelHealthResult?) {
        guard let result else { return nil }
        self.init(bucket: result.bucket)
    }

    public var accessibilityLabel: String {
        switch self {
        case .notPlayable: "Not playable"
        case .offline: "Offline"
        }
    }
}

/// Short relative times for the health surfaces: "just now", "5m ago",
/// "2h ago", "3d ago". Fixed English like the rest of the UI, and
/// deterministic so the summary line can be tested.
public enum AppleChannelHealthTime {
    public static func ago(_ date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86_400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86_400)d ago"
    }
}

/// Settings' one line: "412 of 780 responding, last swept 2h ago".
/// Responding counts channels that passed every rung — the ones the working
/// export would include — out of the whole lineup, checked or not.
public enum AppleChannelHealthSummary {
    public static func line(lineupIDs: [String], results: [String: AppleChannelHealthResult], now: Date) -> String {
        let checked = lineupIDs.compactMap { results[AppleChannelHealthResult.storageID($0)] }
        guard let last = checked.map(\.checkedAt).max() else { return "Not checked yet" }
        let online = checked.filter { $0.bucket == .online }.count
        return "\(online) of \(lineupIDs.count) responding, last swept \(AppleChannelHealthTime.ago(last, now: now))"
    }

    public static func progress(completed: Int, total: Int) -> String {
        "Checking \(completed) of \(total)"
    }
}

/// What the (i) detail shows for one channel, in plain words.
public struct AppleChannelHealthDetail: Equatable, Sendable {
    public struct Row: Equatable, Sendable, Identifiable {
        public let label: String
        public let value: String
        public var id: String { label }
    }

    public let rows: [Row]

    public init(result: AppleChannelHealthResult, now: Date) {
        var rows = [
            Row(label: "Status", value: Self.status(result.bucket)),
            Row(label: "Checked", value: AppleChannelHealthTime.ago(result.checkedAt, now: now)),
            Row(label: "Status Code", value: result.httpStatus.map(String.init) ?? "No response"),
        ]
        if let ttfb = result.ttfbMs { rows.append(Row(label: "First Byte", value: "\(ttfb) ms")) }
        if let stage = result.failedStage { rows.append(Row(label: "Failed At", value: Self.stage(stage))) }
        if let video = result.videoInfo, let text = Self.video(video) { rows.append(Row(label: "Video", value: text)) }
        self.rows = rows
    }

    public static func status(_ bucket: AppleChannelHealthBucket) -> String {
        switch bucket {
        case .online: "Working"
        case .reachable: "Not playable"
        case .timeout: "Timed out"
        case .offline: "Offline"
        }
    }

    /// The rung that failed, named for what it checks rather than how.
    public static func stage(_ stage: AppleSavedSourceDiagnosticStage) -> String {
        switch stage {
        case .headers: "Connection"
        case .manifest: "Playlist"
        case .firstRead: "Video data"
        case .playbackRequest: "Decoding"
        default: "Check"
        }
    }

    static func video(_ info: AppleChannelHealthVideoInfo) -> String? {
        guard info.hasVideo else { return "Audio only" }
        var parts: [String] = []
        if let width = info.width, let height = info.height { parts.append("\(width)×\(height)") }
        if let codec = info.codec { parts.append(codec.uppercased()) }
        if let fps = info.fps { parts.append("\(Int(fps.rounded())) fps") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

/// The per-channel results a lineup's rows draw from, keyed by the app's own
/// channel id. Built once per lineup or history change, never per row render.
public enum AppleChannelHealthMap {
    public static func build(channels: [AppleIPTVChannel],
                             results: [String: AppleChannelHealthResult]) -> [String: AppleChannelHealthResult] {
        guard !results.isEmpty else { return [:] }
        var map: [String: AppleChannelHealthResult] = [:]
        for channel in channels {
            if let result = results[AppleChannelHealthResult.storageID(channel.id)] { map[channel.id] = result }
        }
        return map
    }
}

#if DEBUG
/// Review builds only: an in-memory snapshot for the first channels of a
/// lineup, so the dots and the detail can be photographed without probing a
/// provider. Never written to history.
enum AppleChannelHealthFixture {
    static let launchKey = "OpenStreamDebugChannelHealth"

    static func results(for channels: [AppleIPTVChannel], now: Date) -> [String: AppleChannelHealthResult] {
        let video = AppleChannelHealthVideoInfo(codec: "h264", width: 1920, height: 1080, fps: 29.97, hasVideo: true)
        let pattern: [(AppleChannelHealthBucket, AppleSavedSourceDiagnosticStage?, Int?, Int?, AppleChannelHealthVideoInfo?)] = [
            (.offline, .headers, 403, 212, nil),
            (.online, nil, 200, 184, video),
            (.reachable, .firstRead, 404, 240, nil),
            (.timeout, .headers, nil, nil, nil),
            (.online, nil, 200, 96, video),
            (.reachable, .manifest, 200, 131, nil),
            (.online, nil, 200, 150, video),
            (.offline, .headers, 404, 88, nil),
            (.reachable, .playbackRequest, 200, 305, nil),
            (.online, nil, 200, 120, video),
        ]
        var results: [String: AppleChannelHealthResult] = [:]
        for (index, channel) in channels.prefix(pattern.count).enumerated() {
            let (bucket, stage, status, ttfb, info) = pattern[index]
            let result = AppleChannelHealthResult(channelID: channel.id, bucket: bucket, failedStage: stage,
                httpStatus: status, ttfbMs: ttfb, checkedAt: now.addingTimeInterval(-8100 - Double(index) * 40),
                videoInfo: info)
            results[result.channelID] = result
        }
        return results
    }
}
#endif
