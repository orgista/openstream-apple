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
    #expect(results.count == 25)
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
        case .catalog: throw AppleSavedSourceDiagnosticsError.unsupportedStage
        default: throw AppleSavedSourceDiagnosticsError.fixtureFailure
        }
    }
    let results = await AppleSavedSourceDiagnosticsRunner(operations: fixture).run(timeout: .seconds(1))
    let dns = results.first { $0.stage == .dnsSD }
    let catalog = results.first { $0.stage == .catalog }
    let other = results.first { $0.stage == .authenticate }
    #expect(dns?.status == .blocked && dns?.errorCategory == "not-configured")
    #expect(catalog?.status == .blocked && catalog?.errorCategory == "unsupported")
    #expect(other?.status == .fail && other?.errorCategory == "unknown")
}

@Test func diagnosticsFixtureExercisesEveryProductionStage() async {
    let fixture = AppleDiagnosticFixture { _, _ in }
    let results = await AppleSavedSourceDiagnosticsRunner(operations: fixture).run(timeout: .seconds(1))
    #expect(Set(results.map(\.probeKind)) == Set(AppleSavedSourceDiagnosticProbeKind.allCases))
    #expect(Set(results.map(\.stage)) == Set(AppleSavedSourceDiagnosticStage.allCases))
}

@Test func diagnosticsSelectTheFirstEnabledStreamCapableAddon() throws {
    let catalogOnly = AppleSource(
        kind: .stremio,
        name: "Catalog only",
        url: try #require(URL(string: "https://catalog.example/manifest.json")),
        isEnabled: true,
        manifestID: "example.catalog",
        resources: ["catalog", "meta"]
    )
    let streamProvider = AppleSource(
        kind: .stremio,
        name: "Streams",
        url: try #require(URL(string: "https://streams.example/manifest.json")),
        isEnabled: true,
        manifestID: "example.streams",
        resources: ["catalog", "STREAM"]
    )

    #expect(AppleSavedSourceDiagnosticsProductionOperations.firstStreamSource(
        in: [catalogOnly, streamProvider]
    )?.id == streamProvider.id)
}

@Test func diagnosticsClassifyAllSupportedAndUnsupportedStreamShapes() throws {
    let fixtures: [(String, AppleSavedSourceDiagnosticsError?)] = [
        (#"{"streams":[{"url":"https://media.example/movie.mp4"}]}"#, nil),
        (#"{"streams":[{"url":"https://media.example/master.m3u8","behaviorHints":{"proxyHeaders":{"request":{"Referer":"https://provider.example"}}}}]}"#, nil),
        (#"{"streams":[{"externalUrl":"stremio:///detail/movie/tt123"}]}"#, .externalStream),
        (#"{"streams":[{"infoHash":"0123456789abcdef0123456789abcdef01234567","sources":["tracker:udp://tracker.example:80"]}]}"#, .torrentStream),
        (#"{"streams":[{"url":"file:///private/movie.mp4"}]}"#, .malformedStream),
        (#"{"streams":[]}"#, .emptyStreamResponse),
    ]

    for (json, expectedError) in fixtures {
        let selection = try AppleStremioPlaybackClient.parseStreams(Data(json.utf8))
        do {
            try AppleSavedSourceDiagnosticsProductionOperations.validateStreamClassification(selection)
            #expect(expectedError == nil)
        } catch let error as AppleSavedSourceDiagnosticsError {
            #expect(error == expectedError)
        }
    }
}

@Test func diagnosticsExposeActionableRedactedStreamCategories() async {
    let expected: [(AppleSavedSourceDiagnosticsError, AppleSavedSourceDiagnosticStatus, String)] = [
        (.noStreamProvider, .blocked, "no-stream-provider"),
        (.externalStream, .blocked, "external-link"),
        (.torrentStream, .blocked, "torrent-service-required"),
        (.youtubeStream, .blocked, "youtube-link"),
        (.malformedStream, .fail, "malformed-stream"),
        (.emptyStreamResponse, .fail, "empty-streams"),
    ]

    for (error, status, category) in expected {
        let fixture = AppleDiagnosticFixture { kind, stage in
            if kind == .streamingAddon && stage == .streamClassification { throw error }
        }
        let result = await AppleSavedSourceDiagnosticsRunner(operations: fixture)
            .run(timeout: .seconds(1))
            .first { $0.probeKind == .streamingAddon && $0.stage == .streamClassification }
        #expect(result?.status == status)
        #expect(result?.errorCategory == category)
    }
}
#endif
