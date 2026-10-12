import Foundation

public enum AppleLaunchWorkPolicy: Sendable {
    public static let backgroundPriority: TaskPriority = .utility

    public static func scanDelay(hasPersistedIndex: Bool) -> Duration {
        return hasPersistedIndex ? .seconds(1) : .zero
    }

    public static func shouldRescan(published: Bool, sourceDigest: String, now: Date, defaults: UserDefaults = .standard) -> Bool {
        guard published else { return true }
        let dict = defaults.dictionary(forKey: "openstream.library.lastScan.v1") as? [String: TimeInterval]
        if let timestamp = dict?[sourceDigest] {
            let lastScan = Date(timeIntervalSince1970: timestamp)
            let age = now.timeIntervalSince(lastScan)
            // A scan stamped in the future (the clock moved back) is not
            // fresh: rescan rather than trust it until the clock catches up
            // (a second of slack for the round trip through the stored Double).
            if age >= -1, age <= 600 {
                appleTrace("library scan skipped: index is \(Int(age)) s old")
                return false
            }
        }
        return true
    }
    
    public static func recordScan(sourceDigest: String, date: Date, defaults: UserDefaults = .standard) {
        var dict = defaults.dictionary(forKey: "openstream.library.lastScan.v1") as? [String: TimeInterval] ?? [:]
        dict[sourceDigest] = date.timeIntervalSince1970
        defaults.set(dict, forKey: "openstream.library.lastScan.v1")
    }
}
