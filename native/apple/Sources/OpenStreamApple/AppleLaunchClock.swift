#if DEBUG
import Foundation

/// Milestone timing for the simulator, so "how long does this take" is a
/// number rather than an impression (owner 2026-09-14: "make note of loading
/// times"). Prints `[OpenStream] timing <label> <ms>` and nothing else; only
/// compiled into DEBUG builds, and silent unless `OpenStreamTiming` is set.
public enum AppleLaunchClock {
    nonisolated(unsafe) private static var origin = Date()
    nonisolated(unsafe) private static var seen = Set<String>()
    nonisolated(unsafe) private static let lock = NSLock()

    private static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "OpenStreamTiming")
    }

    /// Called as early in launch as the app has a chance to.
    public static func begin() {
        guard isEnabled else { return }
        lock.lock()
        origin = Date()
        seen.removeAll()
        lock.unlock()
    }

    /// Records the first time a milestone is reached. Later calls with the
    /// same label are ignored, so this can sit in a view body or a task that
    /// runs more than once.
    public static func mark(_ label: String) {
        guard isEnabled else { return }
        lock.lock()
        let isFirst = seen.insert(label).inserted
        let elapsed = Date().timeIntervalSince(origin)
        lock.unlock()
        guard isFirst else { return }
        print("[OpenStream] timing \(label) \(Int((elapsed * 1000).rounded()))ms")
    }
}
#endif
