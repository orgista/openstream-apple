import Foundation

/// What one device is playing, as the other devices on the same iCloud account
/// see it.
///
/// App Groups do not span devices and WatchConnectivity only reaches the paired
/// phone, so neither can tell a watch that the Apple TV in the next room is
/// playing something. `NSUbiquitousKeyValueStore` can: it is the same store the
/// configuration sync already uses, it syncs per device against the account
/// rather than through a pairing, and watchOS reads it directly.
///
/// Read-only awareness. The watch shows what the television is playing; it
/// cannot command it, and nothing here pretends otherwise.
public struct AppleDevicePlaybackState: Equatable, Sendable, Codable {
    public let deviceName: String
    public let title: String
    public let isPlaying: Bool
    /// Seconds since 1970. A plain number rather than a `Date` so the JSON is
    /// the same shape on every decoder, including the restated one in the watch
    /// target — `JSONEncoder` writes `Date` as seconds since 2001 by default,
    /// which is the kind of difference that only shows up on a device.
    public let updatedAt: Double

    public init(deviceName: String, title: String, isPlaying: Bool, updatedAt: Double) {
        self.deviceName = deviceName
        self.title = title
        self.isPlaying = isPlaying
        self.updatedAt = updatedAt
    }
}

/// How a reader treats what it finds, and which device wins when two of them
/// claim to be playing.
public enum AppleDevicePlaybackPolicy: Sendable {
    /// The key in the shared key-value store.
    ///
    /// Restated verbatim in `Apps/OpenStreamWatch/AppleWatchLink.swift` — the
    /// watch target does not link this package — and pinned by
    /// `AppleDevicePlaybackBeaconTests`.
    public static let cloudKey = "openstream.nowplaying.device.v1"

    /// An entry older than this is ignored. A television that loses power or
    /// crashes never writes its stop, so the only thing that can retire its
    /// entry is the reader's own clock.
    public static let staleAfter: TimeInterval = 90

    /// How often a playing device rewrites its entry. Comfortably inside
    /// `staleAfter`, so two missed iCloud syncs still leave the entry fresh,
    /// and slow enough that a two-hour film costs a few hundred small writes.
    public static let refreshInterval: TimeInterval = 30

    /// Whether an entry is worth showing: recent, and actually playing. A
    /// paused or stopped device writes `isPlaying: false`, which reads as
    /// nothing playing rather than as a stale claim.
    public static func isShowable(_ state: AppleDevicePlaybackState, now: Date) -> Bool {
        guard state.isPlaying, !state.title.isEmpty else { return false }
        let age = now.timeIntervalSince1970 - state.updatedAt
        return age >= -staleAfter && age <= staleAfter
    }

    /// What the watch puts on screen.
    public enum Resolution: Equatable, Sendable {
        case nothing
        /// The paired phone, over WatchConnectivity. Transport controls apply.
        case local(title: String, isPlaying: Bool)
        /// Another device on the account, over the key-value store. No
        /// transport: the watch has no path to command it.
        case remote(deviceName: String, title: String)
    }

    /// Which source the watch believes.
    ///
    /// The phone wins ties on purpose. It is the device the watch is paired to,
    /// its state arrives live rather than through an iCloud round trip, and it
    /// is the only one whose transport buttons do anything — so when the two
    /// disagree by less than a sync's worth of delay, showing dead controls for
    /// the television would be the worse mistake. The television only wins when
    /// its entry is strictly newer than the phone's, and a phone that reports
    /// no timestamp at all is treated as ambiguous and kept.
    public static func resolve(
        localTitle: String?,
        localIsPlaying: Bool,
        localUpdatedAt: Date?,
        remote: AppleDevicePlaybackState?,
        now: Date
    ) -> Resolution {
        let local = localTitle.flatMap { $0.isEmpty ? nil : $0 }
        let fresh = remote.flatMap { isShowable($0, now: now) ? $0 : nil }
        switch (local, fresh) {
        case (nil, nil):
            return .nothing
        case (nil, .some(let entry)):
            return .remote(deviceName: entry.deviceName, title: entry.title)
        case (.some(let title), nil):
            return .local(title: title, isPlaying: localIsPlaying)
        case (.some(let title), .some(let entry)):
            guard let localUpdatedAt, entry.updatedAt > localUpdatedAt.timeIntervalSince1970 else {
                return .local(title: title, isPlaying: localIsPlaying)
            }
            return .remote(deviceName: entry.deviceName, title: entry.title)
        }
    }

    /// Whether a playing device should write again.
    ///
    /// Rewrites only when the title changed or `refreshInterval` has passed:
    /// the beacon runs off the player's 0.25 s bind timer, and iCloud's
    /// key-value store is not a thing to write at four hertz.
    public static func shouldWrite(
        last: AppleDevicePlaybackState?,
        title: String,
        now: Date
    ) -> Bool {
        guard let last, last.isPlaying, last.title == title else { return true }
        return now.timeIntervalSince1970 - last.updatedAt >= refreshInterval
    }

    public static func encode(_ state: AppleDevicePlaybackState) -> Data? {
        try? JSONEncoder().encode(state)
    }

    public static func decode(_ data: Data?) -> AppleDevicePlaybackState? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(AppleDevicePlaybackState.self, from: data)
    }
}

/// Publishes this device's playback into the shared key-value store.
///
/// Attached at the same points in `ApplePlayerHost` as the watch link, but on
/// Apple TV: the television is the device nobody is holding, and the wrist is
/// where "what is on in the living room" is worth a glance.
@MainActor
public final class AppleDevicePlaybackBeacon {
    public static let shared = AppleDevicePlaybackBeacon()

    private let cloud: NSUbiquitousKeyValueStore
    private let deviceName: String
    private let now: @Sendable () -> Date
    private weak var engine: (any ApplePlaybackEngine)?
    private var title: String?
    private var lastWritten: AppleDevicePlaybackState?

    public init(
        cloud: NSUbiquitousKeyValueStore = .default,
        deviceName: String = AppleDevicePlaybackBeacon.defaultDeviceName,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.cloud = cloud
        self.deviceName = deviceName
        self.now = now
    }

    /// "Apple TV" rather than the owner's name for the box. The watch shows
    /// this string verbatim and a house with three of them still reads fine;
    /// a device name can also carry a person's name, which has no business
    /// syncing around for a now-playing line.
    public nonisolated static var defaultDeviceName: String {
        #if os(tvOS)
        return "Apple TV"
        #elseif os(iOS)
        return "iPhone"
        #elseif os(macOS)
        return "Mac"
        #else
        return "oStream"
        #endif
    }

    public func attach(engine: any ApplePlaybackEngine, title: String?) {
        self.engine = engine
        self.title = title
        publish(force: true)
    }

    public func detach() {
        engine = nil
        title = nil
        clear()
    }

    /// Writes the current state, skipping an entry identical to the last one
    /// unless `refreshInterval` has passed. Safe to call on the player's bind
    /// timer: most ticks cost a comparison.
    public func publish(force: Bool = false) {
        let isPlaying = engine?.phase == .playing
        guard let title, !title.isEmpty, isPlaying else {
            clear()
            return
        }
        let moment = now()
        guard force || AppleDevicePlaybackPolicy.shouldWrite(
            last: lastWritten, title: title, now: moment
        ) else { return }
        let state = AppleDevicePlaybackState(
            deviceName: deviceName, title: title, isPlaying: true,
            updatedAt: moment.timeIntervalSince1970
        )
        guard let data = AppleDevicePlaybackPolicy.encode(state) else { return }
        cloud.set(data, forKey: AppleDevicePlaybackPolicy.cloudKey)
        cloud.synchronize()
        lastWritten = state
    }

    /// Removes the entry outright. An `isPlaying: false` record would say the
    /// same thing, but a key that is gone cannot go stale.
    public func clear() {
        guard lastWritten != nil else { return }
        cloud.removeObject(forKey: AppleDevicePlaybackPolicy.cloudKey)
        cloud.synchronize()
        lastWritten = nil
    }

    /// The entry another device left, if any.
    public func read() -> AppleDevicePlaybackState? {
        AppleDevicePlaybackPolicy.decode(cloud.data(forKey: AppleDevicePlaybackPolicy.cloudKey))
    }
}
