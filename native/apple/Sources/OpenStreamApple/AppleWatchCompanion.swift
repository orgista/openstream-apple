import Foundation

#if canImport(WatchConnectivity) && os(iOS)
import WatchConnectivity
#endif

/// The payload the phone publishes to the watch, and the commands that come
/// back.
///
/// WatchConnectivity carries `[String: Any]`, which is neither typed nor
/// `Sendable`, so the shape lives here as plain values that both sides encode
/// against. A typo in a key would otherwise fail silently on a device that
/// cannot be debugged easily.
public enum AppleWatchPayload: Sendable {
    public static let titleKey = "title"
    public static let isPlayingKey = "isPlaying"
    public static let commandKey = "command"

    /// Everything the watch actually renders, as one comparable value.
    ///
    /// The link is driven off the player's 0.25 s bind timer, so without this
    /// the phone would push an identical context four times a second.
    public static func signature(title: String?, isPlaying: Bool) -> String {
        "\(isPlaying)|\(title ?? "")"
    }

    public static func context(title: String?, isPlaying: Bool) -> [String: Any] {
        var payload: [String: Any] = [isPlayingKey: isPlaying]
        // A nil title means nothing is playing. Sending the key with an empty
        // string instead would show the watch a blank now-playing card rather
        // than its empty state.
        if let title, !title.isEmpty { payload[titleKey] = title }
        return payload
    }

    /// The command in a message, or nil when it is not one we sent.
    public static func command(in message: [String: Any]) -> AppleRemoteCommand? {
        guard let raw = message[commandKey] as? String else { return nil }
        switch raw {
        case "togglePlayPause": return .toggle
        case "skipForward": return .skipForward(AppleRemoteCommand.skipInterval)
        case "skipBackward": return .skipBackward(AppleRemoteCommand.skipInterval)
        default: return nil
        }
    }
}

#if canImport(WatchConnectivity) && os(iOS)
/// The phone side of the watch link: publishes what is playing, and applies
/// what the wrist asks for.
///
/// Commands run through `AppleRemoteCommandPolicy`, the same rules the AirPods
/// stem and Control Centre use, so the wrist cannot behave differently from
/// every other remote.
@MainActor
public final class AppleWatchCompanion: NSObject {
    public static let shared = AppleWatchCompanion()

    private weak var engine: (any ApplePlaybackEngine)?
    private var title: String?

    override public init() { super.init() }

    public func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    public func attach(engine: any ApplePlaybackEngine, title: String?) {
        self.engine = engine
        self.title = title
        // Forced: the watch may have missed whatever was last sent, and at
        // attach time the engine is usually still loading, so this is the
        // title-only half of the state.
        publish(force: true)
    }

    /// The last context that actually reached the watch.
    private var lastSignature: String?

    public func detach() {
        engine = nil
        title = nil
        publish()
    }

    /// Mirrors the current state to the watch. Safe to call often — the
    /// application context is coalesced by the system, unlike `sendMessage`.
    /// Mirrors the current state to the watch, skipping a context identical to
    /// the last one that went out.
    ///
    /// `attach` used to be the only thing that published a play/pause state,
    /// and it runs while the engine is still loading — so the watch showed a
    /// play button for the whole of a playing title. Nothing republished when
    /// the phase actually changed: `refreshRemoteCommands`, the one method that
    /// would have, had no callers at all.
    public func publish(force: Bool = false) {
        guard WCSession.isSupported() else {
            appleTrace("watch link: WCSession unsupported")
            return
        }
        let session = WCSession.default
        guard session.activationState == .activated else {
            appleTrace("watch link: not activated (state=\(session.activationState.rawValue))")
            return
        }
        let isPlaying = engine?.phase == .playing
        let publishedTitle = engine == nil ? nil : title
        let signature = AppleWatchPayload.signature(title: publishedTitle, isPlaying: isPlaying)
        // Below the dedup guard on purpose. `publish` now runs off the player's
        // 0.25 s bind timer, so tracing above it wrote four identical lines a
        // second into the timeline and buried everything else.
        guard force || signature != lastSignature else { return }
        appleTrace("watch link: paired=\(session.isPaired) installed=\(session.isWatchAppInstalled)")
        let payload = AppleWatchPayload.context(title: publishedTitle, isPlaying: isPlaying)
        do {
            try session.updateApplicationContext(payload)
            lastSignature = signature
            appleTrace("watch link: published \(payload[AppleWatchPayload.titleKey] as? String ?? "nothing")")
        } catch {
            appleTraceFailure("watch link: publish failed — \(error.localizedDescription)")
        }
    }

    private func apply(_ command: AppleRemoteCommand) {
        guard let engine else { return }
        appleTrace("watch command \(command)")
        switch AppleRemoteCommandPolicy.resolve(command, isPlaying: engine.phase == .playing) {
        case .play: engine.play()
        case .pause: engine.pause()
        case .skipForward(let offset), .skipBackward(let offset):
            let signed = if case .skipBackward = command { -offset } else { offset }
            let target = AppleRemoteCommandPolicy.destination(
                from: engine.position, offset: signed, duration: engine.duration
            )
            Task { await engine.seek(to: target) }
        case .toggle: break
        }
        publish()
    }
}

extension AppleWatchCompanion: WCSessionDelegate {
    nonisolated public func session(
        _: WCSession,
        activationDidCompleteWith _: WCSessionActivationState,
        error _: Error?
    ) {
        Task { @MainActor [weak self] in self?.publish() }
    }

    nonisolated public func sessionDidBecomeInactive(_: WCSession) {}

    /// Reactivating is required, or the link dies when the viewer switches
    /// watches and never comes back without relaunching the app.
    nonisolated public func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated public func session(_: WCSession, didReceiveMessage message: [String: Any]) {
        deliver(message)
    }

    nonisolated public func session(_: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        deliver(userInfo)
    }

    /// The command is resolved here, off the main actor, because
    /// `[String: Any]` is not `Sendable` and handing the dictionary across
    /// would be a data race under Swift 6.
    private nonisolated func deliver(_ payload: [String: Any]) {
        guard let command = AppleWatchPayload.command(in: payload) else { return }
        Task { @MainActor [weak self] in self?.apply(command) }
    }
}
#endif
