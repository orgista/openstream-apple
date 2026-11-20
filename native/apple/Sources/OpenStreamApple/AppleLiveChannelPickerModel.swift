import Foundation

/// Which shape the full-screen channel picker takes.
///
/// The owner gave two references (2026-09-20). On a large window the picker is a
/// strip of logo tiles along the bottom of the video, so the picture stays
/// whole while you browse; everywhere else it stays the leading-edge panel,
/// which is the only thing that fits a phone in portrait and the only thing
/// the tvOS focus engine can drive.
public enum AppleLiveChannelPickerPresentation: Equatable, Sendable {
    case panel
    case bottomStrip

    public static func choose(isLargeLayout: Bool) -> AppleLiveChannelPickerPresentation {
        isLargeLayout ? .bottomStrip : .panel
    }
}

/// What one channel reads as in the picker: its logo, its name, and what is on
/// it now. The programme line comes from the guide the Live tab has already
/// loaded — no new fetch, no new plumbing.
struct AppleLiveChannelPickerEntry: Identifiable, Equatable {
    let channel: AppleIPTVChannel
    let nowTitle: String?
    let isCurrent: Bool

    var id: String { channel.id }

    static func entries(channels: [AppleIPTVChannel], guide: AppleIPTVGuide,
                        currentChannelID: String?, at time: Date = Date()) -> [AppleLiveChannelPickerEntry] {
        channels.map { channel in
            let now = guide.nowAndNext(channelID: channel.id, at: time).now
            return AppleLiveChannelPickerEntry(
                channel: channel,
                nowTitle: now?.title.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                isCurrent: channel.id == currentChannelID
            )
        }
    }
}

/// What VoiceOver reads for one row. The row is a single accessibility element
/// on purpose, so everything it shows has to be in the label.
extension AppleLiveChannelPickerEntry {
    public var accessibilityLabel: String {
        var parts = [channel.displayName]
        if isCurrent { parts.append("Now playing") }
        if let nowTitle { parts.append(nowTitle) }
        return parts.joined(separator: ", ")
    }
}
