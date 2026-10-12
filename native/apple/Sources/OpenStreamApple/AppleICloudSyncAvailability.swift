import Foundation
#if os(macOS)
import Security
#endif

/// Whether the Backup page's "Sync with iCloud" switch can do anything.
///
/// A build without the iCloud key-value entitlement (a worker or unsigned
/// build) showed a live switch that silently did nothing. It now says so, and
/// a device with no iCloud account says what to do about it.
public enum AppleICloudSyncAvailability: Sendable, Equatable {
    case available
    /// This build carries no iCloud entitlement, so nothing can ever sync.
    case notEntitled
    /// Entitled, but no iCloud account answers on this device.
    case signedOut

    public static func resolve(isEntitled: Bool, hasICloudAccount: Bool) -> AppleICloudSyncAvailability {
        guard isEntitled else { return .notEntitled }
        return hasICloudAccount ? .available : .signedOut
    }

    /// The one secondary line under the switch; nil when it just works.
    public var note: String? {
        switch self {
        case .available: nil
        case .notEntitled: "iCloud isn't available in this build"
        // No line: the token also reads nil with only iCloud Drive off, so it would mislead.
        case .signedOut: nil
        }
    }

    /// May the switch be flipped from `isOn`? Only a build without the
    /// entitlement locks it. "Signed out" is only a hint: the account token
    /// also reads nil when just iCloud Drive is off, and sync (key-value store
    /// + iCloud Keychain) works without iCloud Drive.
    public func allowsChange(from isOn: Bool) -> Bool {
        self != .notEntitled
    }
}

/// Reads the two facts `AppleICloudSyncAvailability` needs from the running
/// process. Cheap and prompt-free: no keychain access and no network.
public enum AppleICloudSyncProbe {
    static let entitlement = "com.apple.developer.ubiquity-kvstore-identifier"

    public static func current() -> AppleICloudSyncAvailability {
        .resolve(isEntitled: isEntitled, hasICloudAccount: FileManager.default.ubiquityIdentityToken != nil)
    }

    /// The Mac reads its own code signature; only local Mac builds ever ship
    /// without the entitlement. Elsewhere every installed build is signed with
    /// a profile that carries it, and `synchronize()` returning false can be a
    /// passing failure, so it must not lock the switch (review of 696fdd4).
    static var isEntitled: Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(task, entitlement as CFString, nil) != nil
        #else
        return true
        #endif
    }
}
