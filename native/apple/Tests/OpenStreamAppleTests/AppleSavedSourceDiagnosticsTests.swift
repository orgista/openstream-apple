#if DEBUG
import Foundation
import Testing
@testable import OpenStreamApple

private struct AppleDiagnosticFixture: AppleSavedSourceDiagnosticsOperations {
    let action: @Sendable (AppleSavedSourceDiagnosticProbeKind, AppleSavedSourceDiagnosticStage) async throws -> Void

    func run(
        kind: AppleSavedSourceDiagnosticProbeKind,
        stage: AppleSavedSourceDiagnosticStage
    ) async throws {
        try await action(kind, stage)
    }
}

@Test func diagnosticsAreDisabledWithoutTheLaunchArgument() {
    #expect(!AppleSavedSourceDiagnosticsLaunch.isEnabled(arguments: ["OpenStream"]))
    #expect(AppleSavedSourceDiagnosticsLaunch.isEnabled(arguments: ["OpenStream", "--openstream-diagnostics"]))
}

@Test func diagnosticsReturnOnlyStructuredRedactedFields() async throws {
    let fixture = AppleDiagnosticFixture { _, _ in }
    let results = await AppleSavedSourceDiagnosticsRunner(operations: fixture).run(timeout: .seconds(1))
    #expect(results.count == 16)
    let encoded = try JSONEncoder().encode(results)
    let text = try #require(String(data: encoded, encoding: .utf8))
    #expect(!text.contains("fixture-user"))
    #expect(!text.contains("fixture-password"))
    #expect(!text.contains("https://"))
    #expect(!text.contains("username"))
    #expect(!text.contains("responseBody"))
}

@Test func diagnosticsClassifyTimeoutsWithoutLeakingTheError() async throws {
    let fixture = AppleDiagnosticFixture { _, _ in
        try await Task.sleep(for: .seconds(1))
    }
    let results = await AppleSavedSourceDiagnosticsRunner(operations: fixture).run(timeout: .milliseconds(1))
    #expect(results.allSatisfy { $0.status == .fail && $0.errorCategory == "timeout" })
    #expect(!AppleSavedSourceDiagnosticsConsole.summary(results).contains("Sleep"))
}

@Test func diagnosticsClassifyBlockedAndFailedStagesWithFixedCategories() async {
    let fixture = AppleDiagnosticFixture { _, stage in
        switch stage {
        case .dnsSD: throw AppleSavedSourceDiagnosticsError.noConfiguredSource
        case .browse: throw AppleSavedSourceDiagnosticsError.unsupportedStage
        default: throw AppleSavedSourceDiagnosticsError.fixtureFailure
        }
    }
    let results = await AppleSavedSourceDiagnosticsRunner(operations: fixture).run(timeout: .seconds(1))
    let dns = results.first { $0.stage == .dnsSD }
    let browse = results.first { $0.stage == .browse }
    let other = results.first { $0.stage == .authenticate }
    #expect(dns?.status == .blocked && dns?.errorCategory == "not-configured")
    #expect(browse?.status == .blocked && browse?.errorCategory == "unsupported")
    #expect(other?.status == .fail && other?.errorCategory == "unknown")
}

@Test func diagnosticsFixtureExercisesEveryProductionStage() async {
    let fixture = AppleDiagnosticFixture { _, _ in }
    let results = await AppleSavedSourceDiagnosticsRunner(operations: fixture).run(timeout: .seconds(1))
    #expect(Set(results.map(\.probeKind)) == Set(AppleSavedSourceDiagnosticProbeKind.allCases))
    // `.manifest` is the Live channel check's playlist rung (`AppleChannelHealthProbe`), not a saved-source stage.
    #expect(Set(results.map(\.stage)) == Set(AppleSavedSourceDiagnosticStage.allCases).subtracting([.manifest]))
}
#endif
