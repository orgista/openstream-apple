import Foundation

/// When the OpenStream engine's open fails before the first frame, the same
/// candidate gets one more try about a second later before the press falls
/// back to the next one. A loopback server still binding, a debrid link
/// still warming, a share that answered slowly: these fail once and open on
/// the second go, and moving to a worse candidate for them threw the good
/// one away.
///
/// Never for live (the live route has its own retry), never once a frame
/// has played, never twice for one candidate in one press, and never for an
/// answer that will not change: a 4xx, a rejected account, an error clip, a
/// file cut short, or a timeout (which has already waited its full time).
enum AppleEngineOpenRetryPolicy {
    static let delay: Duration = .seconds(1)

    static func shouldRetry(
        failure: ApplePlaybackFailure,
        isLive: Bool,
        reachedFirstFrame: Bool,
        alreadyRetried: Bool,
        engineIsOpenStream: Bool
    ) -> Bool {
        guard engineIsOpenStream, !isLive, !reachedFirstFrame, !alreadyRetried else { return false }
        if let status = failure.httpStatus, (400..<500).contains(status) { return false }
        if failure.message == AppleStreamPlaceholderPolicy.failureMessage
            || failure.message == AppleTruncatedMediaProbe.message { return false }
        switch failure.kind {
        case .network, .player, .unsupportedMedia:
            return true
        case .authentication, .unavailable, .timedOut, .sourceEnded, .engineUnavailable, .cancelled:
            return false
        }
    }
}
