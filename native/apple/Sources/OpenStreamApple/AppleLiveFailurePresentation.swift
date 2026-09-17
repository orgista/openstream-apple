import Foundation

/// What a viewer sees when a live channel will not play.
///
/// A dead channel is ordinary in a lineup this size — the owner's provider
/// carries 9376 — so failing one must not feel like an error in the app. It
/// used to raise a modal alert reading `Demuxer: open failed (Input/output
/// error (-5))` with Retry and Close, which stopped the remote, blamed the
/// viewer's evening on a libavcodec string, and offered no way onward except
/// leaving playback entirely (owner 2026-09-15: "changed to a channel
/// eventually got to this error").
///
/// This turns the engine's diagnosis into one plain sentence and says what the
/// screen should do about it. The technical text is not discarded — it goes to
/// the trace, where it is useful — it just stops being the headline.
public enum AppleLiveFailurePresentation: Sendable {
    /// One sentence, in the viewer's language, naming the channel when known.
    ///
    /// Deliberately short: this is read from a sofa, not a desk.
    public static func message(
        for failure: ApplePlaybackFailure,
        channelName: String? = nil
    ) -> String {
        let subject = channelName.map { "\($0)" } ?? "This channel"
        switch failure.kind {
        case .authentication:
            return "\(subject) needs a valid Live TV username and password."
        case .network:
            return "\(subject) could not be reached."
        case .unsupportedMedia:
            return "\(subject) is in a format this device cannot play."
        case .unavailable:
            return "\(subject) is not available right now."
        case .engineUnavailable:
            return "Playback is unavailable on this device."
        // The common case by far: the provider lists the channel but nothing
        // is coming down it. `player` covers the demuxer's own complaints.
        case .player, .timedOut, .sourceEnded:
            return "\(subject) is not broadcasting right now."
        case .cancelled:
            return ""
        }
    }

    /// The quieter second line, naming who did not answer.
    ///
    /// The owner asked for this explicitly: *"something like endpoint x for
    /// channel x is unreachable or similar so they know it's not the app"*. A
    /// headline about the channel alone reads like the app's fault; naming the
    /// host that went quiet puts it where it belongs, without going back to
    /// quoting the demuxer.
    ///
    /// - Parameter endpoint: the stream's host, e.g. `request.url.host()`.
    ///   Nothing is drawn when it is unknown, or when the failure is not about
    ///   reaching a server at all.
    public static func detail(
        for failure: ApplePlaybackFailure,
        endpoint: String?
    ) -> String? {
        guard let endpoint, !endpoint.isEmpty else { return nil }
        switch failure.kind {
        case .network, .timedOut:
            return "\(endpoint) did not respond."
        case .player, .sourceEnded:
            return "\(endpoint) is not sending this channel."
        case .unsupportedMedia:
            return "The stream from \(endpoint) is in an unsupported format."
        case .authentication:
            return "\(endpoint) rejected the saved credentials."
        case .unavailable:
            return "\(endpoint) has no stream for this channel."
        // Not about reaching anyone.
        case .engineUnavailable, .cancelled:
            return nil
        }
    }

    /// Whether the channel strip should open itself, so the next channel is
    /// one press away instead of a dead end behind a dismissed dialog.
    ///
    /// Everything except a credentials problem is answered by trying another
    /// channel; bad credentials are answered in Settings, and opening the
    /// strip there would just invite the same failure on every row.
    public static func opensChannelStrip(for failure: ApplePlaybackFailure) -> Bool {
        switch failure.kind {
        case .authentication, .cancelled, .engineUnavailable:
            return false
        case .network, .unsupportedMedia, .unavailable, .player, .timedOut, .sourceEnded:
            return true
        }
    }

    /// Whether this failure is worth showing at all. A cancelled load is a
    /// channel switch the viewer asked for.
    public static func isVisible(_ failure: ApplePlaybackFailure) -> Bool {
        failure.kind != .cancelled
    }
}
