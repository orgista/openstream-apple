import Foundation

/// Where iCloud configuration sync is the viewer's choice, and where it simply
/// runs.
public enum AppleConfigurationSyncMode: Sendable, Equatable {
    /// iPhone, iPad, Mac, Vision Pro: the Backup screen's "Sync with iCloud"
    /// switch decides, and the device publishes its own changes.
    case viewerChoice
    /// Apple TV: always on, never publishes. A focus-driven remote has nowhere
    /// sensible to put that switch, and the owner asked for the television to
    /// "sync with iCloud to sync the settings and setup from iOS" without being
    /// set up at all — the way Apple's own tvOS apps quietly inherit their
    /// iCloud settings. Read-only, so a stray change on the television can
    /// never overwrite the phone's configuration.
    case automaticReadOnly
}

public enum AppleConfigurationSyncPolicy: Sendable {
    public static let current: AppleConfigurationSyncMode = {
        #if os(tvOS)
        .automaticReadOnly
        #else
        .viewerChoice
        #endif
    }()

    /// True where sync runs whether or not anyone asked for it.
    public static var isAlwaysOn: Bool { current == .automaticReadOnly }

    /// Is sync on? `automaticReadOnly` ignores the stored preference, which on
    /// the Apple TV is never written because nothing there can write it.
    public static func isEnabled(storedPreference: Bool, mode: AppleConfigurationSyncMode = current) -> Bool {
        mode == .automaticReadOnly || storedPreference
    }

    /// The Backup screen's switch as stored. Sync is on unless the viewer
    /// turned it off (owner, 2026-09-28): an install that never touched the
    /// switch reads as on, and an explicit off stays off.
    public static func resolvedPreference(_ stored: Bool?) -> Bool {
        stored ?? true
    }

    /// The stored value as a Bool, whatever form it arrived in: the switch
    /// writes a Bool (an NSNumber once stored), and a launch argument such as
    /// `-openstream.backup.icloud.enabled.v1 NO` arrives as a String. Anything
    /// unreadable counts as unset, so sync stays on.
    static func resolvedPreference(storedValue: Any?) -> Bool {
        switch storedValue {
        case let value as Bool:
            return resolvedPreference(value)
        case let value as NSNumber:
            return resolvedPreference(value.boolValue)
        case let value as String:
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "yes", "true", "1": return resolvedPreference(true)
            case "no", "false", "0": return resolvedPreference(false)
            default: return resolvedPreference(nil)
            }
        default:
            return resolvedPreference(nil)
        }
    }

    /// `resolvedPreference` read from `defaults`.
    static func storedPreference(in defaults: UserDefaults = .standard) -> Bool {
        resolvedPreference(storedValue: defaults.object(forKey: AppleKeychainStore.syncPreferenceKey))
    }

    /// May a snapshot with no sources replace one that has some? Not from a
    /// device that has held no source since launch: a new install can reach
    /// its first write before iCloud has delivered anything, and every other
    /// device would then apply its empty list over theirs.
    public static func mayPublish(localSourceCount: Int, heldSourcesSinceLaunch: Bool, storedSourceCount: Int) -> Bool {
        localSourceCount > 0 || heldSourcesSinceLaunch || storedSourceCount == 0
    }

    /// How long to wait between looks for credentials iCloud Keychain has not
    /// delivered yet. A restored source waits on them signed out; after the
    /// last look it stays that way until the viewer signs in.
    public static let keychainRetryDelays: [Duration] = [.seconds(5), .seconds(15), .seconds(30), .seconds(60), .seconds(120)]

    /// May this device publish its own configuration to iCloud?
    public static func publishesChanges(mode: AppleConfigurationSyncMode = current) -> Bool {
        mode != .automaticReadOnly
    }

    /// Should this device send its configuration to iCloud without a local
    /// edit (launch, becoming active, Sync Now)? A phone set up before sync
    /// was on by default, and not changed since, otherwise never sends
    /// anything and every other device reads "nothing stored".
    ///
    /// Run after the read, so a newer iCloud copy has already been applied.
    /// Never from the Apple TV, with sync off, after Reset OpenStream, or from
    /// a device with no sources: an empty or reset device must not replace
    /// a configuration other devices still use. Otherwise: send when iCloud
    /// holds nothing, or holds something different that is empty or older
    /// than this device's last edit. `cloud` is nil when iCloud holds nothing.
    public static func publishesWithoutEdit(
        mode: AppleConfigurationSyncMode = current, syncEnabled: Bool, restoreHeld: Bool,
        local: AppleConfigurationSnapshot, localSavedAt: Date?, cloud: AppleConfigurationSnapshot?
    ) -> Bool {
        guard publishesChanges(mode: mode), syncEnabled, !restoreHeld, (!local.sources.isEmpty || !local.sourceTombstones.isEmpty) else { return false }
        guard let cloud else { return true }
        guard contentDiffers(local, cloud) else { return false }
        // A newer snapshot from an offline device may still omit our deletions.
        if local.sourceTombstones.contains(where: { id, date in
            cloud.sourceTombstones[id].map { $0 < date } ?? true
        }) { return true }
        if cloud.sources.isEmpty { return true }
        guard let localSavedAt else { return false }
        return localSavedAt > cloud.savedAt
    }

    /// Do two snapshots carry different configurations, ignoring when each
    /// was saved? Compared as iCloud would store them.
    static func contentDiffers(_ lhs: AppleConfigurationSnapshot, _ rhs: AppleConfigurationSnapshot) -> Bool {
        var lhs = lhs, rhs = rhs
        lhs.savedAt = .distantPast
        rhs.savedAt = .distantPast
        return (try? lhs.cloudData()) != (try? rhs.cloudData())
    }

    /// May the viewer be offered the switch at all? Drives nothing on its own —
    /// the Backup screen is already `#if !os(tvOS)` — but keeps the answer in
    /// one place rather than in a platform check next to each caller.
    public static func offersToggle(mode: AppleConfigurationSyncMode = current) -> Bool {
        mode == .viewerChoice
    }
}

/// The slice of `NSUbiquitousKeyValueStore` the configuration sync uses.
///
/// A protocol only so the apply path can be tested: the simulators on this Mac
/// have no iCloud account, and `NSUbiquitousKeyValueStore.default` silently
/// drops writes without one, so a real round trip cannot be exercised here.
public protocol AppleCloudKeyValueStore: AnyObject {
    func data(forKey key: String) -> Data?
    func set(_ value: Data?, forKey key: String)
    @discardableResult func synchronize() -> Bool
}

extension NSUbiquitousKeyValueStore: AppleCloudKeyValueStore {}

/// What the sync should do with whatever the key-value store currently holds.
///
/// Pulled out of `AppleConfigurationController.readCloud` so the rule the
/// Apple TV depends on — apply a snapshot that is newer than the one this
/// device last applied, ignore anything else — can be tested without an iCloud
/// account. See `AppleConfigurationSyncTests`.
public enum AppleCloudConfigurationRead: Equatable, Sendable {
    /// A valid snapshot, newer than this device's, ready to apply.
    case apply(AppleConfigurationSnapshot)
    /// Nothing has ever been published — iCloud is off, or signed out, or the
    /// account simply has no OpenStream configuration yet.
    case nothingStored
    /// The account's snapshot is the one already applied here, or older.
    case notNewer

    public var traceDescription: String {
        switch self {
        case .apply(let snapshot): return "apply \(snapshot.sources.count) sources"
        case .nothingStored: return "nothing stored"
        case .notNewer: return "not newer"
        }
    }

    /// Throws `AppleConfigurationError.tooLarge` for an oversized payload and
    /// whatever decoding or validation reports for a corrupt one, so the caller
    /// surfaces the same message it always has.
    ///
    /// `localIsEmpty`: this device has no sources. A snapshot that has some is
    /// applied even when it is not newer, because an empty device can stamp a
    /// local edit (a setting, a watched mark) before iCloud delivers anything.
    public static func decide(data: Data?, localSavedAt: Date?, localIsEmpty: Bool = false) throws -> AppleCloudConfigurationRead {
        guard let data else { return .nothingStored }
        guard data.count <= AppleConfigurationSnapshot.maximumCloudBytes else {
            throw AppleConfigurationError.tooLarge
        }
        let snapshot = try JSONDecoder().decode(AppleConfigurationSnapshot.self, from: data)
        try snapshot.validate()
        let isNewer = snapshot.savedAt > (localSavedAt ?? .distantPast)
        guard isNewer || (localIsEmpty && !snapshot.sources.isEmpty) else { return .notNewer }
        return .apply(snapshot)
    }
}

/// What iCloud sync last did on this device, for the lines under the Backup &
/// Sync switch (and the Apple TV's Sources pane). Kept in this device's
/// defaults under `defaultsKey`, which is not a configuration key, so it is
/// never part of a backup or the iCloud snapshot; Reset OpenStream clears it
/// with the rest of the domain.
public struct AppleConfigurationSyncStatus: Codable, Equatable, Sendable {
    public static let defaultsKey = "openstream.backup.syncStatus.v1"

    /// When this device last sent its configuration to iCloud.
    public var lastSentAt: Date?
    /// When this device last found iCloud's configuration and applied it, or
    /// found it already applied here.
    public var lastReceivedAt: Date?
    /// Sources on this device when the status was last brought up to date.
    public var sourceCount = 0
    /// Sources still waiting for their sign-in from iCloud Keychain.
    public var waitingForKeychain = 0
    /// The last thing that went wrong, until the next send or receive works.
    public var lastError: String?

    public init(lastSentAt: Date? = nil, lastReceivedAt: Date? = nil, sourceCount: Int = 0,
                waitingForKeychain: Int = 0, lastError: String? = nil) {
        self.lastSentAt = lastSentAt
        self.lastReceivedAt = lastReceivedAt
        self.sourceCount = sourceCount
        self.waitingForKeychain = waitingForKeychain
        self.lastError = lastError
    }

    public func recordingSent(at date: Date, sourceCount: Int) -> Self {
        var copy = self
        copy.lastSentAt = date
        copy.sourceCount = sourceCount
        copy.lastError = nil
        return copy
    }

    public func recordingReceived(at date: Date, sourceCount: Int) -> Self {
        var copy = self
        copy.lastReceivedAt = date
        copy.sourceCount = sourceCount
        copy.lastError = nil
        return copy
    }

    public func recordingSources(_ count: Int, waitingForKeychain waiting: Int) -> Self {
        var copy = self
        copy.sourceCount = count
        copy.waitingForKeychain = waiting
        return copy
    }

    public func recordingError(_ message: String) -> Self {
        var copy = self
        copy.lastError = message
        return copy
    }

    /// "Last sent 2:14 PM · Last received 2:15 PM", or "Not synced yet".
    public func activityLine(time: (Date) -> String) -> String {
        let parts = [lastSentAt.map { "Last sent \(time($0))" }, lastReceivedAt.map { "Last received \(time($0))" }]
            .compactMap { $0 }
        return parts.isEmpty ? "Not synced yet" : parts.joined(separator: " · ")
    }

    /// The error if there is one, otherwise "8 sources · 2 waiting for
    /// passwords from iCloud Keychain".
    public var detailLine: String {
        if let lastError { return lastError }
        let sources = sourceCount == 1 ? "1 source" : "\(sourceCount) sources"
        guard waitingForKeychain > 0 else { return sources }
        return "\(sources) · \(waitingForKeychain) waiting for passwords from iCloud Keychain"
    }

    /// Today's times as a time, anything older with its date.
    public static func time(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        calendar.isDate(date, inSameDayAs: now)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(date: .abbreviated, time: .shortened)
    }

    public static func load(from defaults: UserDefaults = .standard) -> Self {
        defaults.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? Self()
    }

    public func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
