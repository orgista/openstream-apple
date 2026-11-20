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

/// What another device on the same iCloud account says it is playing.
///
/// The watch target does not link `OpenStreamApple`, so the shape and the key
/// are restated here rather than imported. They are pinned against the
/// package's own `AppleDevicePlaybackPolicy` by
/// `AppleDevicePlaybackBeaconTests`, the same way `AppleWatchPayload.commandKey`
/// is pinned above.
///
/// Read-only. The watch has no path to command an Apple TV, so nothing here
/// offers transport for one.
struct AppleRemotePlayback: Decodable, Equatable {
    let deviceName: String
    let title: String
    let isPlaying: Bool
    /// Seconds since 1970.
    let updatedAt: Double

    /// Mirrors `AppleDevicePlaybackPolicy.cloudKey`.
    static let cloudKey = "openstream.nowplaying.device.v1"
    /// Mirrors `AppleDevicePlaybackPolicy.staleAfter`. A television that loses
    /// power never writes its stop, so this clock is what retires its entry.
    static let staleAfter: TimeInterval = 90

    func isShowable(now: Date) -> Bool {
        guard isPlaying, !title.isEmpty else { return false }
        let age = now.timeIntervalSince1970 - updatedAt
        return age >= -Self.staleAfter && age <= Self.staleAfter
    }
}

/// What the watch puts on screen. Mirrors
/// `AppleDevicePlaybackPolicy.Resolution`.
enum AppleWatchNowPlaying: Equatable {
    case nothing
    case local(title: String, isPlaying: Bool)
    case remote(deviceName: String, title: String)
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
    /// The last entry another device left in the shared key-value store, and
    /// when the phone last said anything. Both feed `nowPlaying`.
    private(set) var remotePlayback: AppleRemotePlayback?
    private var localUpdatedAt: Date?

    private let cloud = NSUbiquitousKeyValueStore.default
    private var cloudObserver: (any NSObjectProtocol)?

    override init() { super.init() }

    /// What to show, phone and television resolved against each other.
    ///
    /// The phone wins ties: it is the device the watch is paired to, its state
    /// arrives live rather than through an iCloud round trip, and it is the
    /// only one the transport buttons can reach. The television only wins when
    /// its entry is strictly newer. Mirrors `AppleDevicePlaybackPolicy.resolve`.
    var nowPlaying: AppleWatchNowPlaying { resolved(now: Date()) }

    func resolved(now: Date) -> AppleWatchNowPlaying {
        let local = nowPlayingTitle.flatMap { $0.isEmpty ? nil : $0 }
        let fresh = remotePlayback.flatMap { $0.isShowable(now: now) ? $0 : nil }
        switch (local, fresh) {
        case (nil, nil):
            return .nothing
        case (nil, .some(let entry)):
            return .remote(deviceName: entry.deviceName, title: entry.title)
        case (.some(let title), nil):
            return .local(title: title, isPlaying: isPlaying)
        case (.some(let title), .some(let entry)):
            guard let localUpdatedAt, entry.updatedAt > localUpdatedAt.timeIntervalSince1970 else {
                return .local(title: title, isPlaying: isPlaying)
            }
            return .remote(deviceName: entry.deviceName, title: entry.title)
        }
    }

    func activate() {
        #if canImport(WatchConnectivity)
        if WCSession.isSupported() {
            let session = WCSession.default
            session.delegate = self
            session.activate()
        }
        #endif
        guard cloudObserver == nil else {
            refreshRemote()
            return
        }
        // iCloud pushes the change when another device writes; the periodic
        // refresh in the view is only there to retire an entry that stopped
        // arriving, which no notification can announce.
        cloudObserver = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloud,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshRemote() }
        }
        cloud.synchronize()
        refreshRemote()
    }

    /// Re-reads the shared entry. Cheap — a local plist read, not a network
    /// call — so the view can call it on a timer to let a stale entry expire.
    func refreshRemote() {
        guard let data = cloud.data(forKey: AppleRemotePlayback.cloudKey) else {
            remotePlayback = nil
            return
        }
        remotePlayback = try? JSONDecoder().decode(AppleRemotePlayback.self, from: data)
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
        localUpdatedAt = Date()
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
