import Foundation

/// What to do when a live channel that was playing stalls, drops or errors.
///
/// IPTV feeds hiccup: the provider restarts a transcoder, a CDN edge drops the
/// connection, the panel briefly answers 5xx. A viewer who was watching wants
/// the same channel back, not an apology, so the coordinator quietly reopens
/// it a bounded number of times (iProTV does the same) while the screen says
/// "Reconnecting…". Bounded, because a channel that is really gone must not
/// spin forever: after `maxAttempts` tries, or once `window` has passed, the
/// failure is shown and the player offers the same channel from another list
/// (`AppleLiveOtherListMatch`) or Try Again.
///
/// Pure value: the coordinator owns the clock and the counters, this only
/// decides, so every branch is a unit test.
public struct AppleLiveReconnectPolicy: Equatable, Sendable {
    public enum Decision: Equatable, Sendable {
        /// Reopen the same stream after `delay`. `attempt` is 1-based.
        case reconnect(attempt: Int, delay: Duration)
        case giveUp(GiveUpReason)
    }

    public enum GiveUpReason: Equatable, Sendable {
        /// The channel never showed a frame and its one quick reopen has
        /// been used (or cannot help); move on to alternates.
        case neverPlayed
        /// Retrying cannot fix it (credentials, format, no engine, a switch).
        case notRecoverable
        case attemptsExhausted
        case windowExpired
    }

    /// Reopens per episode.
    public var maxAttempts: Int
    /// Waits before each reopen; the last value repeats if there are more
    /// attempts than delays. Short first, because most drops are momentary.
    public var delays: [Duration]
    /// An episode gives up once this much time has passed since its first
    /// failure, whatever the attempt count.
    public var window: Duration
    /// A playing channel that has been waiting for data this long is treated
    /// as dropped. The engine's own read timeout can be much longer, and a
    /// frozen frame with a spinner is exactly what the viewer complained of.
    public var stallTimeout: Duration
    /// Playing steadily this long after a recovery closes the episode, so a
    /// drop an hour later gets a fresh set of attempts.
    public var episodeResetAfter: Duration

    public init(
        maxAttempts: Int = 3,
        delays: [Duration] = [.seconds(1), .seconds(2), .seconds(4)],
        window: Duration = .seconds(15),
        stallTimeout: Duration = .seconds(8),
        episodeResetAfter: Duration = .seconds(30)
    ) {
        self.maxAttempts = maxAttempts
        self.delays = delays
        self.window = window
        self.stallTimeout = stallTimeout
        self.episodeResetAfter = episodeResetAfter
    }

    public static let standard = AppleLiveReconnectPolicy()

    /// Whether a reopen of the same URL can plausibly fix this failure.
    public static func isRecoverable(_ kind: ApplePlaybackFailure.Kind) -> Bool {
        switch kind {
        case .network, .timedOut, .player, .sourceEnded, .unavailable:
            true
        case .authentication, .unsupportedMedia, .engineUnavailable, .cancelled:
            false
        }
    }

    /// - Parameters:
    ///   - attemptsSoFar: reopens already made in this episode.
    ///   - elapsed: time since this episode's first failure (zero for the first).
    ///   - hasPlayed: whether this channel showed a frame since it was chosen.
    public func decide(
        kind: ApplePlaybackFailure.Kind,
        attemptsSoFar: Int,
        elapsed: Duration,
        hasPlayed: Bool
    ) -> Decision {
        if !hasPlayed {
            guard [.network, .timedOut, .player].contains(kind), attemptsSoFar == 0, maxAttempts > 0 else {
                return .giveUp(.neverPlayed)
            }
            let delay: Duration = .seconds(1)
            guard elapsed + delay <= window else { return .giveUp(.windowExpired) }
            return .reconnect(attempt: 1, delay: delay)
        }
        guard Self.isRecoverable(kind) else { return .giveUp(.notRecoverable) }
        guard attemptsSoFar < maxAttempts else { return .giveUp(.attemptsExhausted) }
        let delay = delay(beforeAttempt: attemptsSoFar + 1)
        // The reopen itself must start inside the window.
        guard elapsed + delay <= window else { return .giveUp(.windowExpired) }
        return .reconnect(attempt: attemptsSoFar + 1, delay: delay)
    }

    /// The wait before 1-based `attempt`.
    public func delay(beforeAttempt attempt: Int) -> Duration {
        guard !delays.isEmpty else { return .zero }
        return delays[min(max(attempt, 1), delays.count) - 1]
    }

    /// Whether an episode that recovered `sincePlaying` ago is over, so the
    /// next failure starts a new one.
    public func startsNewEpisode(playingFor sincePlaying: Duration) -> Bool {
        sincePlaying >= episodeResetAfter
    }
}

/// The same channel on another of the viewer's lists, for when the one being
/// watched is gone: "Watch on <list>". Matching is by the guide id (`tvg-id`,
/// Xtream `epg_channel_id`) first, because two lists that share a guide id
/// mean the same channel whatever they call it; then by the normalized name
/// the lineup already folds feeds with ("US: CBS East" = "CBS HD").
public enum AppleLiveOtherListMatch: Sendable {
    public static func match(
        for channel: AppleIPTVChannel,
        in lineup: [AppleIPTVChannel],
        excludingURLs excluded: Set<URL> = [],
        hasRecentlyFailed: (URL) -> Bool = { _ in false }
    ) -> AppleIPTVChannel? {
        let candidates = lineup.filter { candidate in
            candidate.sourceID != channel.sourceID
                && candidate.streamURL != channel.streamURL
                && !excluded.contains(candidate.streamURL)
                && !AppleChannelVisibilityPolicy.isPlaceholder(candidate)
                && !AppleChannelVisibilityPolicy.isPayPerView(candidate)
        }
        guard !candidates.isEmpty else { return nil }
        // A feed that just failed is not offered at all: offering it back
        // would bounce the viewer between two dead lists.
        func best(_ matches: [AppleIPTVChannel]) -> AppleIPTVChannel? {
            matches.first { !hasRecentlyFailed($0.streamURL) }
        }
        if let wanted = guideKey(channel.guideID) {
            if let byGuide = best(candidates.filter { guideKey($0.guideID) == wanted }) { return byGuide }
        }
        let name = AppleChannelLineupPresets.normalize(name: channel.name)
        guard !name.isEmpty else { return nil }
        return best(candidates.filter { AppleChannelLineupPresets.normalize(name: $0.name) == name })
    }

    /// The button's title. The list's own name, or a generic one when the
    /// list has none.
    public static func offerTitle(sourceName: String?) -> String {
        let name = sourceName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "Watch on Another List" : "Watch on \(name)"
    }

    static func guideKey(_ id: String?) -> String? {
        let key = id?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return key.isEmpty ? nil : key
    }
}
