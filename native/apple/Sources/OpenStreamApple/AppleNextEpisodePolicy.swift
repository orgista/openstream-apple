import Foundation

/// What the player needs to offer the next episode: its name, and how to start
/// it.
///
/// Built by whatever presented the player, because only that knows the series,
/// the season and how to build a request for another episode. `nil` for a
/// movie, a live channel, or the last episode of a show.
public struct AppleNextEpisodeContext {
    public let title: String
    public let isPartBoundary: Bool
    /// Starts the next episode, carrying the audio and subtitle choices of the
    /// one that is ending.
    public let start: (AppleTrackCarryOver) -> Void

    public init(title: String, isPartBoundary: Bool = false, start: @escaping (AppleTrackCarryOver) -> Void) {
        self.title = title
        self.isPartBoundary = isPartBoundary
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
    static let countdownSeconds: Double = 15

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
    /// 15, 14, … 1 rather than showing 0 for the last whole second.
    public static func secondsRemaining(position: Double, duration: Double) -> Int {
        guard position.isFinite, duration.isFinite else { return 0 }
        return Int(min(countdownSeconds, max(0, duration - position)).rounded(.up))
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
        guard position.isFinite, position >= 0, remaining <= leadSeconds, remaining >= 0 else { return nil }
        return AppleNextEpisodePrompt(
            title: nextTitle,
            secondsRemaining: secondsRemaining(position: position, duration: duration)
        )
    }

    /// True when the current episode ends and the next one starts by
    /// itself. `isEnabled` is the viewer's "Auto Play Next Episode" setting;
    /// with it off the card still appears and still works, it just never fires
    /// on its own.
    ///
    /// `hasEnded` is the engine reporting the end of the stream. The last
    /// position tick usually lands a few frames short of the duration, so
    /// waiting for `position >= duration` alone missed the end and the player
    /// closed on `.ended` with nothing started (iPhone 27 v2 re-run, 2/2).
    public static func shouldAutoAdvance(
        position: Double,
        duration: Double?,
        nextTitle: String?,
        isLive: Bool = false,
        isDismissed: Bool = false,
        isEnabled: Bool = true,
        hasEnded: Bool = false
    ) -> Bool {
        guard isEnabled, !isDismissed, nextTitle != nil,
              isEligible(duration: duration, hasNext: true, isLive: isLive),
              let duration else { return false }
        return position.isFinite && (hasEnded || position >= duration - endTolerance)
    }

    /// How close to the duration counts as the end without an `.ended` event.
    static let endTolerance: Double = 0.5

    /// True when the end of this episode hands over to the next one, so the
    /// player must stay open at `.ended` instead of closing to the title page.
    /// Mirrors `shouldAutoAdvance` minus the clock.
    public static func handsOffAtEnd(hasNext: Bool, isLive: Bool, isDismissed: Bool, isEnabled: Bool) -> Bool {
        hasNext && !isLive && !isDismissed && isEnabled
    }
}

/// The audio and subtitle choices of the episode that is ending, to be applied
/// to the next one once its tracks are known.
///
/// Matched by language, not track id: ids are per file and the next episode
/// usually comes from a different release.
public struct AppleTrackCarryOver: Equatable, Sendable {
    public enum Subtitle: Equatable, Sendable {
        /// Nothing to carry; the next episode follows the captions settings.
        case unchanged
        case off
        case language(String, hearingImpaired: Bool, forced: Bool)
    }

    public var autoPlayChain: AppleAutoPlayChain? = nil
    public var audioLanguage: String?
    public var subtitle: Subtitle

    public init(audioLanguage: String? = nil, subtitle: Subtitle = .unchanged) {
        self.audioLanguage = audioLanguage
        self.subtitle = subtitle
    }

    public static let none = AppleTrackCarryOver()

    public var isEmpty: Bool { audioLanguage == nil && subtitle == .unchanged && autoPlayChain == nil }

    /// What is playing now. A track with no language carries nothing.
    public static func capture(
        audioTracks: [ApplePlaybackTrack], activeAudioID: Int?,
        subtitleTracks: [ApplePlaybackTrack], activeSubtitleID: Int?
    ) -> AppleTrackCarryOver {
        let audio = activeAudioID.flatMap { id in audioTracks.first { $0.id == id } }
        let subtitle: Subtitle
        if let activeSubtitleID {
            if let track = subtitleTracks.first(where: { $0.id == activeSubtitleID }),
               let language = normalized(track.language) {
                subtitle = .language(language, hearingImpaired: track.isHearingImpaired, forced: track.isForced)
            } else {
                subtitle = .unchanged
            }
        } else {
            subtitle = subtitleTracks.isEmpty ? .unchanged : .off
        }
        return AppleTrackCarryOver(audioLanguage: normalized(audio?.language), subtitle: subtitle)
    }

    /// The audio track in the carried language: not commentary, the stream's
    /// default first. Nil when nothing matches or there is nothing to carry.
    public func audioTrackID(in tracks: [ApplePlaybackTrack]) -> Int? {
        guard let audioLanguage else { return nil }
        let matches = tracks.filter { Self.normalized($0.language) == audioLanguage }
        let preferred = matches.filter { !$0.isCommentary }
        return (preferred.first(where: \.isDefault) ?? preferred.first ?? matches.first)?.id
    }

    /// The subtitle selection to make: `.some(nil)` turns subtitles off,
    /// `.some(id)` selects a track, nil means nothing (yet) to do.
    public func subtitleSelection(in tracks: [ApplePlaybackTrack]) -> Int?? {
        switch subtitle {
        case .unchanged:
            return nil
        case .off:
            return .some(nil)
        case .language(let language, let hearingImpaired, let forced):
            let matches = tracks.filter { Self.normalized($0.language) == language }
            guard !matches.isEmpty else { return nil }
            let best = matches.first { $0.isHearingImpaired == hearingImpaired && $0.isForced == forced }
                ?? matches.first { $0.isForced == forced }
                ?? matches[0]
            return .some(best.id)
        }
    }

    /// "en", "eng" and "English" are one language here.
    static func normalized(_ language: String?) -> String? {
        guard let raw = language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty, raw != "und" else { return nil }
        let base = String(raw.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? Substring(raw))
        if base.count == 2 { return base }
        if base.count == 3, let code = Locale.LanguageCode(base).identifier(.alpha2) { return code }
        let english = Locale(identifier: "en")
        for code in Locale.LanguageCode.isoLanguageCodes {
            if english.localizedString(forLanguageCode: code.identifier)?.lowercased() == base,
               let alpha2 = code.identifier(.alpha2) { return alpha2 }
        }
        return base
    }
}
