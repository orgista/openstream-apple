import Dispatch
import Synchronization

/// Main-thread hangs as trace lines, in every build that traces. iOS's Hang Detection HUD showed 540-763 ms hangs on
/// the owner's phone (after the full-screen trailer, on Settings › Sources) that no trace recorded, and the only
/// watchdog (`AppleDebugMainThreadWatchdog`) is DEBUG and macOS only.
///
/// A timer on a background queue sends the main queue a ping every 100 ms, one at a time, so a hang past 370 ms is
/// always seen. An answer more than 250 ms late is recorded with the screen that was showing. If the timer itself was
/// held back as long, or had not ticked for that long when the answer came, the whole process was (suspended in the
/// background, stopped in a debugger), and nothing is recorded.
final class AppleHangMonitor: Sendable {
    static let shared = AppleHangMonitor()
    static let threshold: Duration = .milliseconds(250)
    private static let interval: DispatchTimeInterval = .milliseconds(100)

    private struct State {
        var timer: DispatchSourceTimer?
        var pingSentAt: UInt64?
        var lastTick: UInt64 = 0
        var longestTickGap: UInt64 = 0
        var screen = "launch"
    }

    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "openstream.hang-monitor", qos: .userInteractive)

    /// Starts watching if tracing is on; a second call does nothing.
    func startIfTracing() {
        guard AppleInteractionTrace.isEnabled else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let started = state.withLock { current in
            guard current.timer == nil else { return false }
            current.timer = timer
            return true
        }
        guard started else { return }
        timer.schedule(deadline: .now() + Self.interval, repeating: Self.interval, leeway: .milliseconds(20))
        timer.setEventHandler { [self] in tick() }
        timer.resume()
    }

    /// The screen a hang is charged to; set by `appleTraceScreen` as each screen appears.
    func screenAppeared(_ name: String) {
        state.withLock { $0.screen = name }
    }

    var currentScreen: String { state.withLock { $0.screen } }

    /// Whether a late answer was the main thread's own hang rather than the whole process being held.
    static func isHang(answerDelay: Duration, longestTickGap: Duration, sinceLastTick: Duration) -> Bool {
        answerDelay > threshold && longestTickGap <= threshold && sinceLastTick <= threshold
    }

    private func tick() {
        let now = DispatchTime.now().uptimeNanoseconds
        let sendsPing = state.withLock { current in
            if current.pingSentAt != nil, current.lastTick != 0 {
                current.longestTickGap = max(current.longestTickGap, now - current.lastTick)
            }
            current.lastTick = now
            guard current.pingSentAt == nil else { return false }
            current.pingSentAt = now
            current.longestTickGap = 0
            return true
        }
        guard sendsPing else { return }
        DispatchQueue.main.async { [self] in
            let answeredAt = DispatchTime.now().uptimeNanoseconds
            queue.async { [self] in answered(at: answeredAt) }
        }
    }

    private func answered(at answeredAt: UInt64) {
        let (sentAt, longestTickGap, lastTick, screen) = state.withLock { current in
            defer { current.pingSentAt = nil }
            return (current.pingSentAt ?? answeredAt, current.longestTickGap, current.lastTick, current.screen)
        }
        let delay = answeredAt - sentAt
        guard Self.isHang(answerDelay: .nanoseconds(Int64(delay)), longestTickGap: .nanoseconds(Int64(longestTickGap)),
                          sinceLastTick: .nanoseconds(Int64(answeredAt) - Int64(lastTick)))
        else { return }
        AppleInteractionTrace.record(.hang, "\(delay / 1_000_000)ms on \(screen)")
    }
}
