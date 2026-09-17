import Foundation

/// What an episode row's download control shows for one episode, derived from
/// the single offline coordinator (which downloads one item at a time) plus
/// the set of episodes already stored.
///
/// Downloads are automatic (owner, 2026-09-17: no source sheet), so this is
/// the only feedback the viewer gets that a tap did something — and the
/// tester's "percentage bar during download" (build 10).
enum AppleEpisodeDownloadIndicator: Equatable {
    /// Nothing is happening for this episode.
    case idle
    /// The coordinator is busy with a different episode.
    case otherInProgress
    /// Sources are being resolved for this episode.
    case preparing
    /// Bytes are arriving; `fraction` is nil until the size is known.
    case downloading(fraction: Double?)
    case paused(fraction: Double?)
    /// The episode is stored offline.
    case downloaded

    static func resolve(
        episodeTitle: String,
        coordinatorState: AppleOfflineDownloadCoordinator.State,
        isDownloaded: Bool
    ) -> AppleEpisodeDownloadIndicator {
        if isDownloaded { return .downloaded }
        switch coordinatorState {
        case .resolving(let item, _):
            return item == episodeTitle ? .preparing : .otherInProgress
        case .downloading(let item, _, let received, let expected),
             .resuming(let item, _, let received, let expected):
            return item == episodeTitle ? .downloading(fraction: fraction(received, expected)) : .otherInProgress
        case .paused(let item, _, let received, let expected):
            return item == episodeTitle ? .paused(fraction: fraction(received, expected)) : .otherInProgress
        case .idle, .completed, .failed, .cancelled:
            return .idle
        }
    }

    static func fraction(_ received: Int64, _ expected: Int64?) -> Double? {
        guard let expected, expected > 0 else { return nil }
        return min(max(Double(received) / Double(expected), 0), 1)
    }

    /// VoiceOver text for the control; the percentage rides along when known.
    func accessibilityLabel(episodeTitle: String) -> String {
        switch self {
        case .idle, .otherInProgress: return "Download \(episodeTitle)"
        case .preparing: return "Preparing \(episodeTitle)"
        case .downloading(let fraction): return "Downloading \(episodeTitle)\(Self.percentSuffix(fraction))"
        case .paused(let fraction): return "Paused \(episodeTitle)\(Self.percentSuffix(fraction))"
        case .downloaded: return "Downloaded \(episodeTitle)"
        }
    }

    static func percentSuffix(_ fraction: Double?) -> String {
        guard let fraction else { return "" }
        return ", \(Int((fraction * 100).rounded()))%"
    }
}
