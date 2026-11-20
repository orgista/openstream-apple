import Foundation

/// A timeline of what the viewer did and what the app did about it.
///
/// There is no headless Siri Remote, so every focus-driven fix shipped
/// unverified and every report came back as an end state — a screenshot of
/// something already wrong, with the sequence that produced it missing. This
/// records that sequence, so "it freezes" becomes a readable trail: focus
/// moved here, Select at t+0, the channel switch began, the engine stalled
/// 1.2 s later, focus went nowhere.
///
/// This ships in release builds too. It was DEBUG-only, which would have made
/// a TestFlight build record nothing at all — the opposite of what the owner
/// asked for ("add traces so we have logs … I want you to be able to review
/// every time I use until the next build"). It stays cheap: one boolean check
/// per call, and `OpenStreamTrace = false` silences it entirely.
///
/// Entries are kept in a bounded ring buffer for the current session and
/// appended to a rolling file that survives launches, so several sessions can
/// be read back from one device.
public enum AppleInteractionTrace {
    public enum Kind: String, Sendable {
        /// Focus landed somewhere new.
        case focus
        /// The viewer pressed something — Select, Menu, a direction.
        case press
        /// A screen appeared or went away.
        case screen
        /// Playback state: a request started, a route was chosen, it stalled.
        case playback
        /// A local server or client: listeners, requests, responses.
        case network
        /// Something failed in a way the viewer can see.
        case failure
        /// A line from the playback engine's own log (`AppleEngineLogBridge`).
        case engine
        /// A launch milestone, timed from process start (`AppleLaunchMarks`).
        case launch
        /// The main thread stopped answering for longer than a frame budget (`AppleHangMonitor`).
        case hang
    }

    /// Enough to cover a reproduction without holding a session's worth.
    public static let limit = 400

    /// A timed step (`appleTraceStep`) shorter than this is not written.
    /// `-OpenStreamTraceStepMilliseconds 1` lowers it to see every step.
    static let stepThreshold: Duration = .milliseconds(
        UserDefaults.standard.object(forKey: "OpenStreamTraceStepMilliseconds") == nil
            ? 8 : UserDefaults.standard.integer(forKey: "OpenStreamTraceStepMilliseconds"))

    nonisolated(unsafe) private static var entries: [String] = []
    nonisolated(unsafe) private static var origin = Date()
    private static let lock = NSLock()

    /// The key a viewer's own choice is stored under. An explicitly stored
    /// value always wins, on either side of the default.
    public static let preferenceKey = "OpenStreamTrace"

    /// On by default while developing, off by default in a shipped build.
    ///
    /// A trace nobody switched on records nothing, so debug builds default to
    /// on — that is what makes a simulator session readable afterwards. A
    /// release build is a different situation: it goes to people who did not
    /// ask to be recorded, and this build's log names the channels they watch
    /// and the titles in their library. So release defaults to **off**, and
    /// anyone who wants to help with a bug report turns it on in Settings
    /// (owner 2026-09-15: "tracing only on internal external off").
    ///
    /// Internal testers are simply the ones who turn it on; there is no
    /// reliable runtime signal that separates an internal TestFlight tester
    /// from an external one, and inventing one would be guesswork.
    public static var isEnabled: Bool {
        // A launch argument (`-OpenStreamTrace YES`, as the UI tests pass it)
        // lands here as the String "YES"; `bool(forKey:)` reads both that and
        // the Bool the Settings toggle stores.
        if UserDefaults.standard.object(forKey: preferenceKey) != nil {
            return UserDefaults.standard.bool(forKey: preferenceKey)
        }
        #if DEBUG
        return true
        #else
        // TestFlight, App Review and the App Store behave alike (2026-10-22).
        return false
        #endif
    }

    /// Restarts the timeline. Called from the root view's `task`, which runs
    /// *after* the first screens have already appeared — so this must not
    /// throw away what they recorded. It resets the clock only when nothing
    /// has been written yet; the file itself is cleared by the first entry of
    /// the process, wherever that comes from.
    public static func begin() {
        guard isEnabled else { return }
        lock.lock()
        let isFirst = entries.isEmpty
        if isFirst { origin = Date() }
        lock.unlock()
        guard isFirst else { return }
        record(.screen, "trace started")
    }

    /// Debug builds echo the trace to stdout; a shipped build never does.
    #if DEBUG
    static let printsToConsole = true
    #else
    static let printsToConsole = false
    #endif

    public static func record(_ kind: Kind, _ detail: @autoclosure () -> String) {
        guard isEnabled else { return }
        let text = detail()
        lock.lock()
        let elapsed = Int((Date().timeIntervalSince(origin) * 1000).rounded())
        let line = "\(elapsed)ms \(kind.rawValue) \(text)"
        entries.append(line)
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
        lock.unlock()
        if printsToConsole {
            print("[OpenStream] trace \(line)")
            fflush(stdout)
        }
        append(line)
    }

    /// Where the timeline is written, so a reproduction driven from the
    /// Simulator UI — rather than from a console-attached launch — can still
    /// be read back afterwards. This is the whole point: the viewer presses
    /// the buttons, the file records what happened.
    public static var fileURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("openstream-trace.log")
    }

    nonisolated(unsafe) private static var hasOpenedSession = false

    /// The file is trimmed to roughly this, oldest first, so a build that is
    /// used daily for a fortnight cannot fill the device.
    public static let maximumFileBytes = 512 * 1024

    private static func append(_ line: String) {
        guard let fileURL, let data = (line + "\n").data(using: .utf8) else { return }
        lock.lock()
        let opensSession = !hasOpenedSession
        hasOpenedSession = true
        lock.unlock()
        // A launch no longer wipes the file. It used to, which meant only the
        // most recent session could ever be read — no good for "review every
        // time I use until the next build". Each run marks itself instead.
        if opensSession { beginSessionInFile() }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// Writes a session banner and trims the file if it has grown past the cap.
    private static func beginSessionInFile() {
        guard let fileURL else { return }
        trimIfNeeded(fileURL)
        let stamp = ISO8601DateFormatter().string(from: Date())
        // The process's age when the timeline's clock started, so the first
        // lines of a session read as launch times.
        let launch = AppleProcessStart.date.map { " launch+\(Int((origin.timeIntervalSince($0) * 1000).rounded()))ms" } ?? ""
        var banner = "\n=== session \(stamp) \(buildDescription)\(launch) ===\n"
        #if DEBUG
        // The launch arguments' names, so a trace shows whether a test's
        // launch, even one by URL, carried its switches.
        let switches = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain).keys.sorted()
        if !switches.isEmpty { banner += "launch arguments: \(switches.joined(separator: " "))\n" }
        #endif
        guard let data = banner.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// Which build produced the lines that follow, so a log covering several
    /// days says which of them is being read.
    private static var buildDescription: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "v\(version) (\(build))"
    }

    /// Keeps the newest half when the file passes the cap, cutting on a line
    /// boundary so the first surviving entry is not a fragment.
    private static func trimIfNeeded(_ fileURL: URL) {
        guard let size = try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int,
              size > maximumFileBytes,
              let existing = try? Data(contentsOf: fileURL) else { return }
        let keep = existing.suffix(maximumFileBytes / 2)
        let trimmed: Data
        if let newline = keep.firstIndex(of: UInt8(ascii: "\n")) {
            trimmed = Data(keep[keep.index(after: newline)...])
        } else {
            trimmed = Data(keep)
        }
        try? trimmed.write(to: fileURL, options: .atomic)
    }

    /// The timeline so far, oldest first.
    public static func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
}
