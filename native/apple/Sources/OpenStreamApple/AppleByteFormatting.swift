import Foundation

/// Byte counts as the app shows them.
///
/// `ByteCountFormatter` spells zero as **"Zero KB"** by default, which reads as
/// a placeholder someone forgot to fill in — it appeared three times on the
/// Storage pane against real values like "4.5 MB" (2026-09-16 settings audit).
/// Apple's own Settings writes "0 bytes". `allowsNonnumericFormatting = false`
/// is the switch for that, and it has to be set on an instance: the
/// `ByteCountFormatter.string(fromByteCount:countStyle:)` class method gives no
/// way to reach it, which is why every call site produced the same wording.
public enum AppleByteFormatting: Sendable {
    public static func string(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: max(0, bytes))
    }
}
