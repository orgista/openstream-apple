import Foundation
import Observation
#if canImport(WatchConnectivity)
import WatchConnectivity
#endif

/// What the watch can ask the phone to do.
///
/// App Groups do not span devices, so the watch cannot read the snapshot the
/// widgets use — this is a live link, not shared storage.
public enum AppleWatchCommand: String, Sendable {
    case togglePlayPause
    case skipForward
    case skipBackward
}

/// The watch side of the link.
///
/// State is whatever the phone last reported. It is deliberately not persisted:
/// a stale "now playing" on the wrist is worse than an honest empty state,
/// because the viewer would tap transport controls at something that stopped
/// playing an hour ago.
@MainActor
@Observable
final class AppleWatchLink: NSObject {
    static let shared = AppleWatchLink()

    private(set) var nowPlayingTitle: String?
    private(set) var isPlaying = false

    override init() { super.init() }

    func activate() {
        #if canImport(WatchConnectivity)
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        #endif
    }

    func send(_ command: AppleWatchCommand) {
        #if canImport(WatchConnectivity)
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        // `sendMessage` only works while the phone is reachable; the queued
        // transfer is the fallback so a tap is not silently dropped when the
        // phone is asleep in a pocket.
        // Key must match `AppleWatchPayload.commandKey` on the phone. The
        // watch target does not link the package, so it is restated here and
        // pinned by a test on the phone side.
        let payload = ["command": command.rawValue]
        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil) { _ in
                session.transferUserInfo(payload)
            }
        } else {
            session.transferUserInfo(payload)
        }
        #endif
    }

    fileprivate func apply(title: String?, isPlaying: Bool) {
        nowPlayingTitle = title
        self.isPlaying = isPlaying
    }
}

#if canImport(WatchConnectivity)
extension AppleWatchLink: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith state: WCSessionActivationState,
        error: Error?
    ) {
        deliver(session.receivedApplicationContext)
    }

    nonisolated func session(_: WCSession, didReceiveApplicationContext context: [String: Any]) {
        deliver(context)
    }

    /// `[String: Any]` is not `Sendable`, so the two values are read here, on
    /// the delegate's own thread, and only those cross to the main actor.
    /// Handing the dictionary over would be a data race under Swift 6.
    private nonisolated func deliver(_ context: [String: Any]) {
        // Keys must match `AppleWatchPayload` on the phone.
        let title = context["title"] as? String
        let isPlaying = context["isPlaying"] as? Bool ?? false
        Task { @MainActor [weak self] in self?.apply(title: title, isPlaying: isPlaying) }
    }
}
#endif
