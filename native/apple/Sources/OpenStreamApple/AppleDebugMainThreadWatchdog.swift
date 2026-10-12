#if DEBUG && os(macOS)
import Darwin
import Foundation
import Synchronization

/// `-OpenStreamMainThreadWatchdog YES`: logs the main thread's stack when it
/// stops answering, DEBUG and macOS only (N56).
///
/// N54 saw 3 of ~45 background launches stall mid-launch with no crash report,
/// and nothing on record said whether the main thread was hung or the whole
/// process was being held back by App Nap. A debugger could have said, and is
/// not allowed on this Mac. This answers it from inside the process:
///
/// - A timer on a background queue posts a heartbeat to the main queue every
///   200 ms and watches for the answer.
/// - When the main queue has not answered for 1 s (again at 5, 20 and 60 s of
///   the same stall), the main thread is sent `SIGUSR2`. Its handler records
///   `backtrace()` into a buffer allocated up front (nothing is allocated in
///   the handler), and the watchdog thread symbolicates and logs it.
///   `Thread.callStackSymbols` would have been simpler, but it only ever
///   describes the thread that calls it: the watchdog's own.
/// - The timer also logs how late it itself fires. If it is late too, the
///   whole process was held back (App Nap throttles every thread's timers)
///   rather than the main thread being stuck.
///
/// Every line goes to stderr with the `OPENSTREAM-WATCHDOG` prefix.
public enum AppleDebugMainThreadWatchdog {
    public static let preferenceKey = "OpenStreamMainThreadWatchdog"

    /// Call as early in launch as possible, on the main thread.
    @MainActor
    public static func startIfRequested() {
        guard UserDefaults.standard.bool(forKey: preferenceKey) else { return }
        AppleMainThreadWatchdog.shared.start()
    }
}

// The signal handler's buffer. Allocated once, before the handler can run;
// the handler writes it and publishes `watchdogCaptured`, and only the
// watchdog queue reads it, after that store.
private let watchdogFrameCapacity: Int32 = 128
nonisolated(unsafe) private let watchdogFrames =
    UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: Int(watchdogFrameCapacity))
nonisolated(unsafe) private var watchdogFrameCount: Int32 = 0
private let watchdogCaptured = Atomic<Bool>(false)

private func watchdogSignalHandler(_: Int32) {
    watchdogFrameCount = backtrace(watchdogFrames, watchdogFrameCapacity)
    watchdogCaptured.store(true, ordering: .releasing)
}

private final class AppleMainThreadWatchdog: Sendable {
    static let shared = AppleMainThreadWatchdog()

    private struct State {
        var started: UInt64 = 0
        var lastTick: UInt64 = 0
        var lastBeat: UInt64 = 0
        var beatPending = false
        var stallReports = 0
        var maxGap: Double = 0
        var maxLate: Double = 0
        var lastSummary: UInt64 = 0
        var timer: DispatchSourceTimer?
    }

    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "openstream.debug.main-thread-watchdog", qos: .userInteractive)
    nonisolated(unsafe) private var mainThread: pthread_t?

    private static let interval: Double = 0.2
    private static let reportAt: [Double] = [1, 5, 20, 60]

    @MainActor
    func start() {
        let alreadyRunning = state.withLock { $0.timer != nil }
        guard !alreadyRunning else { return }
        mainThread = pthread_self()
        signal(SIGUSR2, watchdogSignalHandler)
        let now = DispatchTime.now().uptimeNanoseconds
        let timer = makeTimer()
        state.withLock {
            $0.started = now
            $0.lastTick = now
            $0.lastBeat = now
            $0.lastSummary = now
            $0.timer = timer
        }
        Self.log("start pid=\(getpid()) interval=\(Self.interval)s")
        timer.resume()
    }

    /// Built outside `start()` on purpose: a closure formed in a `@MainActor`
    /// method is main-actor isolated, and the first tick on the watchdog
    /// queue then trapped in the runtime's isolation check (N56 crash
    /// reports 12:46–12:53, `_dispatch_assert_queue_fail`).
    private func makeTimer() -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.interval, repeating: Self.interval, leeway: .milliseconds(10))
        timer.setEventHandler { [self] in tick() }
        return timer
    }

    private func tick() {
        let now = DispatchTime.now().uptimeNanoseconds
        enum Action { case none, beat, report(gap: Double, late: Double, index: Int) }
        let (action, late, elapsed, summary): (Action, Double, Double, String?) = state.withLock { s in
            let late = max(0, Self.seconds(now - s.lastTick) - Self.interval)
            s.lastTick = now
            s.maxLate = max(s.maxLate, late)
            let elapsed = Self.seconds(now - s.started)
            var summary: String?
            if Self.seconds(now - s.lastSummary) >= 10 {
                summary = "alive t=\(Self.fmt(elapsed)) maxMainGap=\(Self.fmt(s.maxGap)) maxTimerLate=\(Self.fmt(s.maxLate))"
                s.maxGap = 0
                s.maxLate = 0
                s.lastSummary = now
            }
            guard s.beatPending else {
                s.beatPending = true
                s.lastBeat = now
                return (.beat, late, elapsed, summary)
            }
            let gap = Self.seconds(now - s.lastBeat)
            s.maxGap = max(s.maxGap, gap)
            if s.stallReports < Self.reportAt.count, gap >= Self.reportAt[s.stallReports] {
                s.stallReports += 1
                return (.report(gap: gap, late: late, index: s.stallReports), late, elapsed, summary)
            }
            return (.none, late, elapsed, summary)
        }
        if late >= 1 {
            Self.log("timer late \(Self.fmt(late))s at t=\(Self.fmt(elapsed)) (the whole process was held back)")
        }
        if let summary { Self.log(summary) }
        switch action {
        case .none:
            break
        case .beat:
            DispatchQueue.main.async { [self] in beatArrived() }
        case let .report(gap, late, index):
            Self.log("main thread silent \(Self.fmt(gap))s at t=\(Self.fmt(elapsed)) (report \(index); watchdog timer late \(Self.fmt(late))s)")
            for line in captureMainStack() { Self.log("  \(line)") }
        }
    }

    private func beatArrived() {
        let now = DispatchTime.now().uptimeNanoseconds
        let (reports, gap, elapsed) = state.withLock { s in
            let result = (s.stallReports, Self.seconds(now - s.lastBeat), Self.seconds(now - s.started))
            s.beatPending = false
            s.stallReports = 0
            return result
        }
        if reports > 0 {
            Self.log("main thread back after \(Self.fmt(gap))s at t=\(Self.fmt(elapsed))")
        }
    }

    private func captureMainStack() -> [String] {
        guard let mainThread else { return ["no main thread recorded"] }
        watchdogCaptured.store(false, ordering: .relaxed)
        guard pthread_kill(mainThread, SIGUSR2) == 0 else { return ["pthread_kill failed"] }
        for _ in 0 ..< 100 where !watchdogCaptured.load(ordering: .acquiring) {
            usleep(2_000)
        }
        guard watchdogCaptured.load(ordering: .acquiring) else {
            return ["main thread did not take the signal within 200 ms"]
        }
        let count = watchdogFrameCount
        guard count > 0, let symbols = backtrace_symbols(watchdogFrames, count) else { return ["empty stack"] }
        defer { free(symbols) }
        return (0 ..< Int(count)).compactMap { symbols[$0].map { String(cString: $0) } }
    }

    private static func seconds(_ nanoseconds: UInt64) -> Double { Double(nanoseconds) / 1_000_000_000 }
    private static func fmt(_ value: Double) -> String { String(format: "%.2f", value) }

    private static func log(_ line: String) {
        FileHandle.standardError.write(Data("OPENSTREAM-WATCHDOG \(line)\n".utf8))
    }
}
#endif
