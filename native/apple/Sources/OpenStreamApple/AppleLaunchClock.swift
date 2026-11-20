import Darwin
import Foundation

/// When the kernel started this process.
enum AppleProcessStart {
    static let date: Date? = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&name, u_int(name.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }()
}

#if DEBUG
/// Milestone timing for the simulator, so "how long does this take" is a
/// number rather than an impression (owner 2026-09-14: "make note of loading
/// times"). Prints `[OpenStream] timing <label> <ms>` and nothing else; only
/// compiled into DEBUG builds, and silent unless `OpenStreamTiming` is set.
///
/// Every mark is measured from the moment the kernel started the process, so
/// the numbers include pre-main and the first frame. They used to count from
/// the root view's first `.task`, which starts after the first frame — and a
/// mark reached before that task (the Discover billboard, often) was measured
/// from whenever the clock was first touched, so it read far too small.
public enum AppleLaunchClock {
    nonisolated(unsafe) private static var seen = Set<String>()
    nonisolated(unsafe) private static var counts: [String: Int] = [:]
    private static let lock = NSLock()
    private static let origin: Date = AppleProcessStart.date ?? Date()

    private static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "OpenStreamTiming")
    }

    /// Called from the root view's first `.task`; recorded as `root.task`.
    public static func begin() {
        mark("root.task")
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
        // Flushed per line: a headless run reads stdout from a file, which is
        // block-buffered, and the process is killed rather than quit.
        fflush(stdout)
    }

    /// Counts `label` and records `label.<n>` the first time the count
    /// reaches each of `thresholds` — "the 16th poster has drawn".
    public static func count(_ label: String, marking thresholds: Set<Int>) {
        guard isEnabled else { return }
        lock.lock()
        let count = counts[label, default: 0] + 1
        counts[label] = count
        lock.unlock()
        if thresholds.contains(count) { mark("\(label).\(count)") }
    }
}
#endif
