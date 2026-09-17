import Foundation

/// What the player needs to offer the next episode: its name, and how to start
/// it.
///
/// Built by whatever presented the player, because only that knows the series,
/// the season and how to build a request for another episode. `nil` for a
/// movie, a live channel, or the last episode of a show.
public struct AppleNextEpisodeContext {
    public let title: String
    public let start: () -> Void

    public init(title: String, start: @escaping () -> Void) {
        self.title = title
        self.start = start
    }
}

/// What the end-of-episode "Next Episode" affordance shows, and when.
///
/// Every value is plain data so the behaviour can be asserted without a view —
/// the same shape as `AppleTVLiveFooterState` and `AppleTVGuideMetrics`.
public struct AppleNextEpisodePrompt: Equatable, Sendable {
    /// "S1 E2 · The Thing", from the episode's own `displayTitle`.
    public let title: String
    /// Whole seconds until the next episode starts, never negative.
    public let secondsRemaining: Int

    public init(title: String, secondsRemaining: Int) {
        self.title = title
        self.secondsRemaining = secondsRemaining
    }

    /// "Next Episode in 12s", or "Next Episode" on the final tick.
    public var countdownLabel: String {
        secondsRemaining > 0 ? "Next Episode in \(secondsRemaining)s" : "Next Episode"
    }
}

/// When to offer the next episode, and when to start it.
///
/// A show should carry on to the next episode the way every other TV app does
/// (owner 2026-09-15). The card appears in the closing seconds rather than
/// living in the transport: the Apple TV overlay is deliberately a scrubber and
/// one captions control, and a permanent button there would undo that.
public enum AppleNextEpisodePolicy: Sendable {
    /// How long before the end the card appears, and so how long the viewer
    /// has to stop it. Long enough to read and act on with a remote, short
    /// enough not to sit over the last scene.
    ///
    /// `defaults write com.orgista.openstream OpenStreamNextEpisodeLeadSeconds
    /// -float 99999` brings the card up from the first frame, so it can be
    /// reviewed on the simulator without playing an episode to its last twenty
    /// seconds. Simulator only, like the other review hooks.
    public static var leadSeconds: Double {
        #if DEBUG
        let override = UserDefaults.standard.double(forKey: "OpenStreamNextEpisodeLeadSeconds")
        if override > 0 { return override }
        #endif
        return defaultLeadSeconds
    }

    static let defaultLeadSeconds: Double = 20

    /// Nothing is offered for a live stream, a movie, an episode with no
    /// successor, or one whose duration is not known yet — a card that cannot
    /// say how long is left is worse than no card.
    /// The floor is `defaultLeadSeconds`, not `leadSeconds`: it exists to keep
    /// the card off something shorter than the window it needs, and must not
    /// move with the simulator override — an override longer than the episode
    /// would otherwise rule the episode out and show nothing at all.
    public static func isEligible(duration: Double?, hasNext: Bool, isLive: Bool) -> Bool {
        guard hasNext, !isLive, let duration, duration.isFinite,
              duration > defaultLeadSeconds else { return false }
        return true
    }

    /// Seconds left, clamped at zero and rounded up so the label counts
    /// 20, 19, … 1 rather than showing 0 for the last whole second.
    public static func secondsRemaining(position: Double, duration: Double) -> Int {
        max(0, Int((duration - position).rounded(.up)))
    }

    /// The card to show, or nil for "nothing yet".
    ///
    /// `isDismissed` is the viewer having said no. It suppresses the card *and*
    /// the auto-advance for the rest of the episode, so dismissing it is a real
    /// answer rather than a delay.
    public static func prompt(
        position: Double,
        duration: Double?,
        nextTitle: String?,
        isLive: Bool = false,
        isDismissed: Bool = false
    ) -> AppleNextEpisodePrompt? {
        guard !isDismissed, let nextTitle,
              isEligible(duration: duration, hasNext: true, isLive: isLive),
              let duration else { return nil }
        let remaining = duration - position
        guard remaining <= leadSeconds, remaining >= 0 else { return nil }
        return AppleNextEpisodePrompt(
            title: nextTitle,
            secondsRemaining: secondsRemaining(position: position, duration: duration)
        )
    }

    /// True once the episode has run out and the next one should start by
    /// itself. `isEnabled` is the viewer's "Auto Play Next Episode" setting;
    /// with it off the card still appears and still works, it just never fires
    /// on its own.
    public static func shouldAutoAdvance(
        position: Double,
        duration: Double?,
        nextTitle: String?,
        isLive: Bool = false,
        isDismissed: Bool = false,
        isEnabled: Bool = true
    ) -> Bool {
        guard isEnabled, !isDismissed, nextTitle != nil,
              isEligible(duration: duration, hasNext: true, isLive: isLive),
              let duration else { return false }
        return position >= duration
    }
}
