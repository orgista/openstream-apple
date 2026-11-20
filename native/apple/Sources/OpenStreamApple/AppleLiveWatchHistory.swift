import Foundation

/// Device-local, most-recent-first unique channels. Selecting or buffering a
/// channel is never a watch; callers supply time actually spent playing.
struct AppleLiveWatchHistory: Codable, Equatable, Sendable {
    static let minimumWatchSeconds: Double = 5
    private(set) var channelIDs: [String] = []
    /// The last time the first channel was seen playing; gates the resume.
    private(set) var lastWatchedAt: Date?

    mutating func record(_ channelID: String, watchedSeconds: Double, at date: Date = Date()) {
        guard !channelID.isEmpty, watchedSeconds.isFinite,
              watchedSeconds >= Self.minimumWatchSeconds else { return }
        channelIDs.removeAll { $0 == channelID }
        channelIDs.insert(channelID, at: 0)
        channelIDs = Array(channelIDs.prefix(10))
        lastWatchedAt = date
    }

    /// Still playing the first channel.
    mutating func touch(_ channelID: String, at date: Date = Date()) {
        guard channelIDs.first == channelID else { return }
        lastWatchedAt = date
    }

    func previous(currentID: String, availableIDs: Set<String>) -> String? {
        channelIDs.first { $0 != currentID && availableIDs.contains($0) }
    }
}
