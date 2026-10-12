import Foundation

/// One row of the SharePlay "Choose the source for this channel" prompt: the
/// shared channel as one of the viewer's sources carries it.
public struct AppleSharedChannelSourceChoice: Identifiable, Equatable, Sendable {
    public let channel: AppleIPTVChannel
    public let title: String

    public var id: String { channel.id }

    /// A row per candidate, named for its source (the channel's own name when
    /// the source is gone). Two sources with the same name, or one source
    /// carrying the channel twice, would read as identical rows, so those
    /// rows add the channel's name, and rows still alike are numbered.
    public static func choices(for channels: [AppleIPTVChannel],
                               sourceNames: [UUID: String]) -> [AppleSharedChannelSourceChoice] {
        let bases = channels.map { channel -> String in
            let name = sourceNames[channel.sourceID]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return name.isEmpty ? channel.name : name
        }
        var counts: [String: Int] = [:]
        for base in bases { counts[base, default: 0] += 1 }
        let titles = zip(channels, bases).map { channel, base in
            let collides = (counts[base] ?? 0) > 1 && base != channel.name
            return collides ? "\(base) · \(channel.name)" : base
        }
        // Rows can still match (the source is named for the channel, or two
        // gone sources fall back to the same channel name): number those.
        var titleCounts: [String: Int] = [:]
        for title in titles { titleCounts[title, default: 0] += 1 }
        var seen: [String: Int] = [:]
        return zip(channels, titles).map { channel, title in
            guard (titleCounts[title] ?? 0) > 1 else {
                return AppleSharedChannelSourceChoice(channel: channel, title: title)
            }
            seen[title, default: 0] += 1
            return AppleSharedChannelSourceChoice(channel: channel, title: "\(title) (\(seen[title]!))")
        }
    }
}

/// A row of the source prompt: start the channel from one source, or leave
/// SharePlay. Leaving is the prompt's only destructive row (red on Apple TV's
/// page, as the dialog it replaced drew it).
public enum AppleSharedSourcePromptAction: Equatable, Sendable {
    case choose(AppleSharedChannelSourceChoice)
    case leave

    public var title: String {
        switch self {
        case .choose(let choice): choice.title
        case .leave: "Leave SharePlay"
        }
    }

    public var isDestructive: Bool {
        switch self {
        case .choose: false
        case .leave: true
        }
    }
}
