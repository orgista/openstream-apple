import Foundation
import Testing
@testable import OpenStreamApple

@Suite struct AppleDiagnosticsReportTests {
    private let header = AppleDiagnosticsReport.Header(
        version: "1.0", build: "15", system: "iOS 18.7", model: "iPhone17,1",
        date: Date(timeIntervalSince1970: 1_800_000_000))

    @Test func theHeaderNamesBuildSystemDeviceAndDate() {
        let text = AppleDiagnosticsReport.text(header: header, trace: "12ms screen discover")
        #expect(text.hasPrefix("OpenStream 1.0 (15)\nSystem: iOS 18.7\nDevice: iPhone17,1\nDate: 2027-01-15"))
        #expect(text.hasSuffix("12ms screen discover"))
    }

    @Test func anEmptyTraceSaysSo() {
        #expect(AppleDiagnosticsReport.text(header: header, trace: nil).contains("(no trace recorded)"))
        #expect(AppleDiagnosticsReport.text(header: header, trace: "").contains("(no trace recorded)"))
    }

    @Test func providerURLsAndCredentialsAreRemoved() {
        let trace = """
        10ms network GET https://fixture.example/player_api.php?username=alice&password=hunter2&action=get_live_streams
        11ms network player_api.php?username=alice&password=hunter2
        12ms network login username=alice password=hunter2
        13ms network tmdb api_key=abc123 access_token: xyz
        """
        let redacted = AppleDiagnosticsReport.redact(trace)
        for secret in ["alice", "hunter2", "abc123", "xyz", "fixture.example"] {
            #expect(!redacted.contains(secret), "\(secret) leaked")
        }
        #expect(redacted.split(separator: "\n").count == 4)
    }

    /// The redactor's body rule runs to the end of its input; line by line
    /// it cannot swallow the rest of the trace.
    @Test func aBodyLineDoesNotEraseTheLinesAfterIt() {
        let redacted = AppleDiagnosticsReport.redact("1ms network body: {secret}\n2ms screen live")
        #expect(redacted.hasSuffix("2ms screen live"))
        #expect(!redacted.contains("{secret}"))
    }

    @Test func ordinaryLinesAreUntouched() {
        let line = "40ms playback channel switch passed in 1.2 s"
        #expect(AppleDiagnosticsReport.redactLine(line) == line)
    }
}
