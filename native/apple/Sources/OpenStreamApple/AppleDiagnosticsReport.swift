import Foundation
#if !os(tvOS)
import CoreTransferable
import UniformTypeIdentifiers
#endif

/// The trace, as shared from Settings > About > Share Diagnostics, so a
/// TestFlight device can send its log without a cable (owner, 2026-09-28).
///
/// Every line goes through `AppleDiagnosticRedactor` first, then through the
/// extra rules here for what a trace line can carry that the redactor was not
/// written for: an Xtream `player_api.php` query without its scheme, and API
/// keys. Line by line, because the redactor's body rule runs to the end of
/// its input.
enum AppleDiagnosticsReport {
    static let fileName = "OpenStream Diagnostics.txt"

    struct Header: Equatable, Sendable {
        var version: String
        var build: String
        var system: String
        var model: String
        var date: Date
    }

    static func text(header: Header, trace: String?) -> String {
        let stamp = ISO8601DateFormatter().string(from: header.date)
        let lines = [
            "OpenStream \(header.version) (\(header.build))",
            "System: \(header.system)",
            "Device: \(header.model)",
            "Date: \(stamp)",
            "",
        ]
        let body = trace.map(redact) ?? ""
        return lines.joined(separator: "\n") + "\n" + (body.isEmpty ? "(no trace recorded)\n" : body)
    }

    static func redact(_ trace: String) -> String {
        trace
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { redactLine(String($0)) }
            .joined(separator: "\n")
    }

    static func redactLine(_ line: String) -> String {
        var redacted = AppleDiagnosticRedactor.redact(line)
        for (expression, template) in extraRules {
            redacted = expression.stringByReplacingMatches(
                in: redacted, range: NSRange(redacted.startIndex..., in: redacted), withTemplate: template)
        }
        return redacted
    }

    private static let extraRules: [(NSRegularExpression, String)] = [
        // `player_api.php?username=…&password=…` or `get.php?…` without a scheme.
        (try! NSRegularExpression(pattern: #"(?i)\b((?:player_api|get|xmltv|panel_api)\.php)\?[^\s\"'<>]*"#), "$1?[REDACTED]"),
        (try! NSRegularExpression(
            pattern: #"(?i)\b(api_?key|access_token|refresh_token|auth_?token|secret|pass)\b\s*[\"']?\s*[:=]\s*[\"']?[^,\s;&}\]]+"#),
         "$1=[REDACTED]"),
    ]

    /// The device's model identifier ("iPhone17,1"), which says more than
    /// the marketing name and needs no main actor.
    static var modelIdentifier: String {
        var info = utsname()
        uname(&info)
        let identifier = withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return identifier.isEmpty ? "unknown" : identifier
    }

    static var currentHeader: Header {
        let info = Bundle.main.infoDictionary
        return Header(
            version: info?["CFBundleShortVersionString"] as? String ?? "?",
            build: info?["CFBundleVersion"] as? String ?? "?",
            system: systemName + " " + ProcessInfo.processInfo.operatingSystemVersionString,
            model: modelIdentifier,
            date: Date())
    }

    private static var systemName: String {
        #if os(visionOS)
        "visionOS"
        #elseif os(iOS)
        "iOS"
        #elseif os(macOS)
        "macOS"
        #elseif os(tvOS)
        "tvOS"
        #else
        "unknown"
        #endif
    }

    /// The current trace file, read when the share happens.
    static func currentText() -> String {
        let trace = AppleInteractionTrace.fileURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        return text(header: currentHeader, trace: trace)
    }
}

#if !os(tvOS)
/// Written only when the viewer actually shares, so it is the trace as of the
/// tap, not as of the screen opening.
struct AppleDiagnosticsFile: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .plainText) { _ in
            Data(AppleDiagnosticsReport.currentText().utf8)
        }
        .suggestedFileName(AppleDiagnosticsReport.fileName)
    }
}
#endif
