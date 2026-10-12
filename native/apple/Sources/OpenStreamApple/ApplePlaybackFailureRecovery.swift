import Foundation

/// What the title page's "Playback Unavailable" alert offers besides Close.
///
/// It used to offer Retry for every failure. When the failure was the same on
/// every press — no stream source, a format the device cannot play, a rejected
/// account — Retry failed again at once and put back the identical alert, so
/// the press looked like it did nothing (ui-smoke 20260923: 180 of them). Retry
/// is offered only where a second attempt can turn out differently; where it
/// cannot, the way forward is a change of source, so the alert offers that.
public enum ApplePlaybackFailureRecovery: Equatable, Sendable {
    /// The network, a slow server or the player: worth another go.
    case retry
    /// The same press gets the same answer until a source is added, fixed or
    /// signed in again — Settings › Sources.
    case sources
    /// Nothing the viewer can do from here.
    case closeOnly

    public init(_ failure: ApplePlaybackFailure) {
        switch failure.kind {
        case .network, .timedOut, .player, .sourceEnded:
            self = .retry
        case .unavailable, .unsupportedMedia, .authentication:
            self = .sources
        case .engineUnavailable, .cancelled:
            self = .closeOnly
        }
    }

    /// How long a retried attempt shows its loading state before a new
    /// failure may replace it. A failure that comes back in a few milliseconds
    /// otherwise lands before the alert has even gone, and the viewer sees the
    /// same alert and no sign that anything was tried.
    public static let retryFeedbackMinimum: Duration = .milliseconds(1_500)

    /// What is left of `retryFeedbackMinimum` after `elapsed`; zero once it has passed.
    public static func remainingRetryFeedback(elapsed: Duration) -> Duration {
        max(.zero, retryFeedbackMinimum - elapsed)
    }
}
