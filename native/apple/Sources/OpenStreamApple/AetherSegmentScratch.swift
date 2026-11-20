import Darwin
import Foundation

/// AetherEngine writes each playback's segments to `tmp/aether-segments/<UUID>` (live DVR rings to
/// `dvr-<UUID>`) and deletes the folder when the session closes. A playback the system ends first
/// (the app killed in the background, a crash) leaves its folder behind, 30-50 MB each, and the
/// engine only reclaims such folders once they are an hour old and a new playback starts. On a
/// 32 GB Apple TV that is enough to make installs fail. This sweep reclaims them app-side.
///
/// A folder is in use while its session holds an flock(2) on `session.lock` inside it (AE#451);
/// the kernel drops that lock when the owning process dies, so an unheld marker means the session
/// is gone. Folders without a marker (DVR rings) can only be judged by when they were made.
public enum AetherSegmentScratch {
    static let liveMarkerName = "session.lock"

    static var defaultDirectory: URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("aether-segments", isDirectory: true)
    }

    /// At launch no playback of this process has started yet, so everything already there belongs
    /// to an earlier process, marker or not.
    public static func sweepAtLaunch() {
        let launched = Date()
        Task.detached(priority: .background) {
            sweep(createdBefore: launched, removesUnmarked: true)
        }
    }

    /// After a playback stops. The engine closes its session on a detached task that can wait 3 s
    /// for its producer, so this runs a little later; a session still closing keeps its lock and
    /// is left to the engine. Unmarked folders stay: another live playback may own one.
    static func sweepAfterPlayback() {
        let stopped = Date()
        Task.detached(priority: .background) {
            try? await Task.sleep(for: .seconds(5))
            sweep(createdBefore: stopped, removesUnmarked: false)
        }
    }

    /// Removes session folders created before `cutoff` that no session holds. Returns the names removed.
    @discardableResult
    static func sweep(directory: URL = defaultDirectory, createdBefore cutoff: Date,
                      removesUnmarked: Bool) -> [String] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: directory,
                                                        includingPropertiesForKeys: [.creationDateKey],
                                                        options: [.skipsHiddenFiles]) else {
            return []
        }
        var removed: [String] = []
        for entry in entries {
            // Unknown age counts as new: never delete what might have just been made.
            guard let created = (try? entry.resourceValues(forKeys: [.creationDateKey]))?.creationDate,
                  created < cutoff else { continue }
            switch markerState(entry) {
            case .held: continue
            case .missing where !removesUnmarked: continue
            case .missing, .unheld: break
            }
            if (try? fm.removeItem(at: entry)) != nil { removed.append(entry.lastPathComponent) }
        }
        if !removed.isEmpty {
            AppleInteractionTrace.record(.playback, "segment scratch sweep removed \(removed.count) folder(s)")
        }
        return removed
    }

    enum MarkerState { case held, unheld, missing }

    static func markerState(_ sessionDirectory: URL) -> MarkerState {
        let fd = open(sessionDirectory.appendingPathComponent(liveMarkerName).path, O_RDONLY)
        guard fd >= 0 else { return .missing }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return .held }
        flock(fd, LOCK_UN)
        return .unheld
    }
}
