import Foundation

public enum AppleLaunchWorkPolicy: Sendable {
    public static let backgroundPriority: TaskPriority = .utility

    /// Work that can wait (the Top 10 charts, the Top Shelf snapshot) starts this long after the process did, so it
    /// does not compete with the first frame, the first rows and the hero's art (F8: rows within 2 s on the phone).
    public static let launchWindow: Duration = .seconds(2)

    /// How much of the launch window is left `processAge` into the process.
    public static func remainingLaunchWindow(processAge: Duration?) -> Duration {
        guard let processAge else { return .zero }
        return max(.zero, launchWindow - processAge)
    }

    public static func scanDelay(hasPersistedIndex: Bool) -> Duration {
        return hasPersistedIndex ? .seconds(1) : .zero
    }

    public static func shouldRescan(published: Bool, sourceDigest: String, now: Date, defaults: UserDefaults = .standard,
                                    credentialsRestoreRevision: Int = 0, scannedCredentialsRestoreRevision: Int = 0) -> Bool {
        let dict = defaults.dictionary(forKey: "openstream.library.lastScan.v1") as? [String: TimeInterval]
        let lastScan = dict?[sourceDigest].map { Date(timeIntervalSince1970: $0) }
        let rescan = shouldRescan(published: published, lastScan: lastScan, now: now,
            credentialsRestoreRevision: credentialsRestoreRevision, scannedCredentialsRestoreRevision: scannedCredentialsRestoreRevision)
        if !rescan, let lastScan {
            appleTrace("library scan skipped: index is \(Int(now.timeIntervalSince(lastScan))) s old")
        }
        return rescan
    }

    static func shouldRescan(published: Bool, lastScan: Date?, now: Date,
                             credentialsRestoreRevision: Int, scannedCredentialsRestoreRevision: Int) -> Bool {
        guard published, credentialsRestoreRevision == scannedCredentialsRestoreRevision, let lastScan else { return true }
        let age = now.timeIntervalSince(lastScan)
        // A future scan is not fresh after the clock moves back; allow a second for stored Double rounding.
        return !(age >= -1 && age <= 600)
    }
    
    public static func recordScan(sourceDigest: String, date: Date, defaults: UserDefaults = .standard) {
        var dict = defaults.dictionary(forKey: "openstream.library.lastScan.v1") as? [String: TimeInterval] ?? [:]
        dict[sourceDigest] = date.timeIntervalSince1970
        defaults.set(dict, forKey: "openstream.library.lastScan.v1")
    }
}
