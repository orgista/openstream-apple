import Foundation
import Synchronization

/// The launch's milestones as trace lines, in every build: process start to the first frame, the first row, the
/// hero's art and the cover lifting. The owner's 10-15 recording showed ~4 s of black that no trace could explain,
/// because the only launch timing was `AppleLaunchClock`, which a shipped build does not contain.
///
/// iOS may prewarm the process minutes before the owner opens the app (`ActivePrewarm`). Such a launch is timed from
/// its first frame instead of the kernel's start time, or every mark would read minutes and the launch window
/// would already be over.
public enum AppleLaunchMarks {
    public enum Mark: String, Sendable {
        case firstFrame = "first frame"
        case firstRow = "first row"
        case heroArt = "hero art"
        case coverGone = "cover gone"
        case livePlaylistParsed = "live playlist parsed"
        case liveLogoShown = "live first logo shown"
        case liveGuideShown = "live visible guide shown"
        case serverRowShown = "server first row shown"
    }

    static let isPrewarmed = ProcessInfo.processInfo.environment["ActivePrewarm"] == "1"

    /// Posted on the recording thread the first time a mark is reached; the object is the mark's raw value.
    static let recordedNotification = Notification.Name("AppleLaunchMarks.recorded")

    static func isRecorded(_ mark: Mark) -> Bool {
        state.withLock { $0.recorded.contains(mark) }
    }

    private struct State {
        var recorded: Set<Mark> = []
        var prewarmedOrigin: Date?
    }

    private static let state = Mutex(State())

    /// How far into the launch `now` is.
    static func launchAge(now: Date = Date()) -> Duration? {
        let origin = isPrewarmed ? prewarmedOrigin(now: now) : AppleProcessStart.date
        return origin.map { .milliseconds(Int((now.timeIntervalSince($0) * 1000).rounded())) }
    }

    /// The first frame of a prewarmed launch, or `now` if that frame has not been marked yet.
    private static func prewarmedOrigin(now: Date) -> Date {
        state.withLock { current in
            if let origin = current.prewarmedOrigin { return origin }
            current.prewarmedOrigin = now
            return now
        }
    }

    /// Records `mark` the first time it is reached in this process; later calls do nothing, so this can sit in an
    /// `onAppear` that runs for every row.
    public static func record(_ mark: Mark, _ detail: @autoclosure () -> String = "") {
        guard state.withLock({ $0.recorded.insert(mark).inserted }) else { return }
        NotificationCenter.default.post(name: recordedNotification, object: mark.rawValue)
        guard let age = launchAge() else { return }
        let detail = mark == .firstFrame && isPrewarmed ? "prewarmed" : detail()
        AppleInteractionTrace.record(.launch, line(mark, age: age, detail: detail))
    }

    static func line(_ mark: Mark, age: Duration, detail: String) -> String {
        "\(mark.rawValue) +\(milliseconds(age))ms" + (detail.isEmpty ? "" : " \(detail)")
    }

    static func milliseconds(_ duration: Duration) -> Int64 {
        duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000
    }
}
