import Foundation
import AetherEngine

/// Routes AetherEngine's diagnostic lines (`EngineLog.handler`) into the app
/// trace while tracing is on, so a failed open reads as the engine's own
/// story (probe, route, reroute) beside the app's lines.
///
/// Every line is scrubbed with the same rules as Share Diagnostics
/// (`AppleDiagnosticsReport.redactLine`: URLs, credentials, `player_api.php`
/// queries, API keys), cut to a bounded length, and rate-limited: the engine
/// can emit dozens of lines a second during a reroute, and the trace keeps
/// only 400 entries.
enum AppleEngineLogBridge {
    /// The trace line's kind already says `engine`; the text carries the
    /// engine's own bracketed subsystem (`[AetherEngine]`, `[SWHost]`).
    static let prefix = ""
    static let maximumLineLength = 240
    /// At most this many lines per window; the rest are counted and the
    /// count is traced when the next window opens.
    static let linesPerWindow = 30
    static let window: TimeInterval = 1

    /// Installs the handler once. Cheap when tracing is off: the trace's own
    /// switch is checked per line before anything is formatted.
    static func install() {
        EngineLog.handler = { line in
            guard AppleInteractionTrace.isEnabled else { return }
            switch limiter.admit(now: Date()) {
            case .drop: return
            case .admit(let dropped):
                if dropped > 0 {
                    AppleInteractionTrace.record(.engine, "\(prefix)… \(dropped) lines dropped (rate limit)")
                }
                AppleInteractionTrace.record(.engine, traceLine(line))
            }
        }
    }

    /// The trace text for one engine line: scrubbed, single-line, bounded.
    static func traceLine(_ line: String) -> String {
        let flattened = line.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let scrubbed = AppleDiagnosticsReport.redactLine(flattened)
        let bounded = scrubbed.count > maximumLineLength
            ? String(scrubbed.prefix(maximumLineLength)) + "…"
            : scrubbed
        return prefix + bounded
    }

    static let limiter = RateLimiter(limit: linesPerWindow, window: window)

    /// A fixed-window counter; thread-safe, since the engine logs from any
    /// thread.
    final class RateLimiter: @unchecked Sendable {
        enum Verdict: Equatable { case admit(droppedBefore: Int), drop }

        private let limit: Int
        private let window: TimeInterval
        private let lock = NSLock()
        private var windowStart = Date.distantPast
        private var admitted = 0
        private var dropped = 0

        init(limit: Int, window: TimeInterval) {
            self.limit = limit
            self.window = window
        }

        func admit(now: Date) -> Verdict {
            lock.lock()
            defer { lock.unlock() }
            if now.timeIntervalSince(windowStart) >= window {
                windowStart = now
                admitted = 0
                let carried = dropped
                dropped = 0
                admitted = 1
                return .admit(droppedBefore: carried)
            }
            guard admitted < limit else {
                dropped += 1
                return .drop
            }
            admitted += 1
            return .admit(droppedBefore: 0)
        }
    }
}
