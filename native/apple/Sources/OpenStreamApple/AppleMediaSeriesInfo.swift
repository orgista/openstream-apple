import Foundation

/// Season and episode read from an episode media id (`tt123:2:5`).
public struct AppleMediaSeriesInfo: Equatable, Sendable {
    public let season: Int
    public let episode: Int

    public init?(mediaID: String) {
        let parts = mediaID.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 3,
              let season = Int(parts[parts.count - 2]),
              let episode = Int(parts[parts.count - 1]),
              (0 ... 10_000).contains(season),
              (0 ... 100_000).contains(episode) else {
            return nil
        }
        self.season = season
        self.episode = episode
    }
}

