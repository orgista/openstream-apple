import Foundation
import Observation

@MainActor @Observable
final class AppleLiveWatchHistoryStore {
    static let shared = AppleLiveWatchHistoryStore()
    static let storageKey = "openstream.live.watchedChannelHistory"
    static let resumeKey = "openstream.live.startWithLastChannel"
    private(set) var history: AppleLiveWatchHistory
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        history = defaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode(AppleLiveWatchHistory.self, from: $0) } ?? .init()
    }

    func record(_ channelID: String, watchedSeconds: Double) {
        history.record(channelID, watchedSeconds: watchedSeconds)
        save()
    }

    func touch(_ channelID: String) {
        history.touch(channelID)
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(history) { defaults.set(data, forKey: Self.storageKey) }
    }
}
