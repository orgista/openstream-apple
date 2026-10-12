import Foundation

/// Proves — at runtime, inside the sandbox — that the shared app group
/// container resolves *and* can be read and written.
///
/// This exists because the obvious check is the one that lies.
/// `containerURL(forSecurityApplicationGroupIdentifier:)` returned a non-nil
/// URL on macOS **without** the entitlement and with the wrong (unprefixed)
/// identifier; every read and write through it then failed with EPERM —
/// `NSCocoaErrorDomain 513` on write, `257` on a directory listing (measured
/// 2026-09-21). So `guard let root = containerProvider() else { return }` at
/// the snapshot call sites passed and the writes failed silently. Nothing
/// short of a round trip settles it.
///
/// It deliberately does **not** go through `AppleTopShelfSnapshotWriter`: that
/// would overwrite the app's own `topshelf-v1.json`, and a diagnostic has no
/// business touching a file the app publishes. It uses the same `appGroup`
/// constant and the same FileManager call, which is where every mistake this
/// is looking for actually lives.
public enum AppleAppGroupDiagnostics {
    /// Deleted again at the end of a successful run, so a repeated check
    /// leaves the container exactly as it found it.
    static let probeFilename = "appgroup-probe.json"

    public struct Result: Sendable {
        public let appGroup: String
        public let containerURL: URL?
        public let wrote: Bool
        public let readBack: Bool
        public let listedEntries: [String]?
        public let failure: String?

        public var isPass: Bool { failure == nil }
    }

    /// Whether the launch asked for this. Same shape as the saved-source
    /// diagnostics hook, and like that one the call site is DEBUG-only, so a
    /// shipped build cannot reach it.
    public static func isEnabled(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Bool {
        arguments.contains("-OpenStreamAppGroupCheck")
    }

    public static func run(appGroup: String = AppleTopShelfSnapshotWriter.appGroup) -> Result {
        let manager = FileManager.default
        guard let root = manager.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else {
            return Result(appGroup: appGroup, containerURL: nil, wrote: false, readBack: false,
                          listedEntries: nil,
                          failure: "containerURL returned nil — the entitlement is absent or the identifier is wrong")
        }
        let probe = root.appending(path: probeFilename)
        let payload = Data(#"{"probe":1}"#.utf8)
        do {
            try payload.write(to: probe, options: .atomic)
        } catch {
            return Result(appGroup: appGroup, containerURL: root, wrote: false, readBack: false,
                          listedEntries: nil, failure: "write failed: \(error)")
        }
        guard let readBack = try? Data(contentsOf: probe), readBack == payload else {
            try? manager.removeItem(at: probe)
            return Result(appGroup: appGroup, containerURL: root, wrote: true, readBack: false,
                          listedEntries: nil, failure: "wrote the probe but could not read it back")
        }
        // The directory listing is the call that returned 257 before, so it is
        // part of the proof rather than a nicety.
        let listed = try? manager.contentsOfDirectory(atPath: root.path)
        try? manager.removeItem(at: probe)
        guard let listed else {
            return Result(appGroup: appGroup, containerURL: root, wrote: true, readBack: true,
                          listedEntries: nil, failure: "could not list the container directory")
        }
        return Result(appGroup: appGroup, containerURL: root, wrote: true, readBack: true,
                      listedEntries: listed.sorted(), failure: nil)
    }

    /// Writes the summary where a headless run can actually read it.
    ///
    /// Standard error, not `print`. A GUI app launched from a script has a
    /// pipe rather than a terminal on stdout, so `print` is block-buffered and
    /// six short lines sit in the buffer until the process exits — which for
    /// an app that never exits means they are never seen at all. stderr is
    /// unbuffered.
    public static func emit(_ result: Result) {
        FileHandle.standardError.write(Data((summary(result) + "\n").utf8))
    }

    /// One block of text, so a headless run can be read out of the console log
    /// with no debugger attached.
    public static func summary(_ result: Result) -> String {
        [
            "OPENSTREAM-APPGROUP group: \(result.appGroup)",
            "OPENSTREAM-APPGROUP containerURL: \(result.containerURL?.path ?? "nil")",
            "OPENSTREAM-APPGROUP wrote: \(result.wrote)",
            "OPENSTREAM-APPGROUP readBack: \(result.readBack)",
            "OPENSTREAM-APPGROUP listed: \(result.listedEntries?.joined(separator: ", ") ?? "nil")",
            "OPENSTREAM-APPGROUP verdict: \(result.failure ?? "PASS")",
        ].joined(separator: "\n")
    }
}
