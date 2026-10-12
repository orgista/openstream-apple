import Foundation

/// Device-local, most-recent-first unique channels. Selecting or buffering a
/// channel is never a watch; callers supply time actually spent playing.
struct AppleLiveWatchHistory: Codable, Equatable, Sendable {
    static let minimumWatchSeconds: Double = 5
    private(set) var channelIDs: [String] = []

    mutating func record(_ channelID: String, watchedSeconds: Double) {
        guard !channelID.isEmpty, watchedSeconds.isFinite,
              watchedSeconds >= Self.minimumWatchSeconds else { return }
        channelIDs.removeAll { $0 == channelID }
        channelIDs.insert(channelID, at: 0)
        channelIDs = Array(channelIDs.prefix(10))
    }

    func previous(currentID: String, availableIDs: Set<String>) -> String? {
        channelIDs.first { $0 != currentID && availableIDs.contains($0) }
    }
}
