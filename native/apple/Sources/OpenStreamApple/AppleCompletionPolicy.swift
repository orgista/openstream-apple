import Foundation

/// Provider watched state is authoritative. Local files use one completion rule.
public enum AppleCompletionPolicy {
    public static let fraction = 0.95
    public static let remainingSeconds = 30.0

    /// Runtime bands apply to existing saved clocks without rewriting storage.
    public static func playedThreshold(duration: Double) -> Double? {
        guard duration.isFinite, duration > 0 else { return nil }
        switch duration {
        case ..<10: return duration
        // Clips: the last 10 s, but never less than 90 % (a 10 s clip was
        // "watched" at its first frame).
        case ..<900: return max(duration * 0.9, duration - 10)
        case ..<1800: return duration - 180
        case ..<3900: return duration - 240
        case ..<6000: return duration - 480
        default: return duration - 660
        }
    }

    public static func isComplete(position: Double, duration: Double, providerWatched: Bool? = nil) -> Bool {
        if let providerWatched { return providerWatched }
        guard duration.isFinite, position.isFinite, duration > 0, position >= 0 else { return false }
        let position = min(position, duration)
        return playedThreshold(duration: duration).map { position >= $0 } ?? false
    }

    public static func successor(after partID: String?, episodes: [AppleMediaEpisode],
                                 completedIDs: Set<String>, now: Date = .now) -> AppleMediaEpisode? {
        let ordered = AppleMediaEpisodePolicy.episodes(in: nil, from: episodes)
        let regular = ordered.filter { $0.season != 0 }
        let candidates = regular.isEmpty ? ordered : regular
        guard let partID, let index = candidates.firstIndex(where: { $0.id == partID }) else { return nil }
        return candidates.dropFirst(index + 1).first {
            guard !completedIDs.contains($0.id) else { return false }
            if let release = $0.releaseInfo, let date = ISO8601DateFormatter().date(from: release) { return date <= now }
            if let release = $0.releaseInfo, release.count >= 10 {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = "yyyy-MM-dd"
                if let date = formatter.date(from: String(release.prefix(10))) { return date <= now }
            }
            return true
        }
    }

    /// No automatic expiry: activity remains until completion, explicit removal,
    /// or loss of successor availability. Rewatch requires a new resumable save.
    static func includes(saved: ApplePlaybackProgress?, activity: ApplePlaybackProgress?,
                         successorAvailable: Bool, removedAt: Date?) -> Bool {
        let latest = activity ?? saved
        guard !AppleContinueWatchingRemovalPolicy.isRemoved(removedAt: removedAt, lastPlayedAt: latest?.updatedAt) else { return false }
        if saved?.resumePosition != nil { return true }
        return latest?.isComplete == true && successorAvailable
    }
}
