import Foundation
import Testing
@testable import OpenStreamApple

private final class RemediationCredentialStore: AppleCredentialStoring {
    var values: [String: String] = [:]

    func string(for account: String) throws -> String? {
        values[account]
    }

    func set(_ value: String, for account: String) throws {
        values[account] = value
    }

    func remove(_ account: String) throws {
        values.removeValue(forKey: account)
    }
}

private func networkShareSetupSources() throws -> String {
    let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Sources")
        .appending(path: "OpenStreamApple")
    return try ["AppleNetworkShareSetup.swift", "AppleNetworkShareSetupViews.swift"]
        .map { try String(contentsOf: directory.appending(path: $0), encoding: .utf8) }
        .joined(separator: "\n")
}

private struct UnusedShareClient: AppleNetworkShareClient {
    func listShares(host: String, port: Int, credentials: AppleSMBCredentials) async throws -> [AppleSMBShare] { [] }
    func listDirectory(url: URL, credentials: AppleSMBCredentials, recursive: Bool) async throws -> [AppleSMBDirectoryEntry] { [] }
    func read(url: URL, credentials: AppleSMBCredentials, range: Range<UInt64>) async throws -> Data { Data() }
}

@MainActor
@Test func networkShareDefaultsAreEmptyAndNoProductionPresetExists() throws {
    let setup = AppleNetworkShareSetup(client: UnusedShareClient())
    #expect(setup.address.isEmpty)
    #expect(setup.username.isEmpty)
    #expect(setup.password.isEmpty)
    #expect(setup.domain.isEmpty)
    #expect(setup.account == .guest)
    #expect(setup.fixedServer == nil)

    let source = try networkShareSetupSources()
    #expect(!source.contains("fillTestSMBConfiguration"))
    #expect(!source.contains("Something to Test"))
}

@MainActor
@Test func networkShareSourceSerializationContainsCredentialReferenceOnly() throws {
    let suiteName = "AppleSecurityRemediationTests.serialization.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let keychain = RemediationCredentialStore()
    let store = AppleSourceStore(defaults: defaults, keychain: keychain)
    let fixtureUsername = "fixture-user"
    let fixturePassword = "fixture-password"
    let source = try store.addNetworkShare(
        name: "Media",
        host: "media.example.invalid",
        share: "Movies",
        path: "Library",
        username: fixtureUsername,
        password: fixturePassword,
        domain: "WORKGROUP"
    )

    let persisted = try #require(defaults.data(forKey: "openstream.sources.v1"))
    let text = try #require(String(data: persisted, encoding: .utf8))
    let credentialReference = try #require(source.credentialReference)

    #expect(credentialReference == source.id.uuidString.lowercased())
    #expect(text.contains("\"credentialReference\""))
    #expect(!text.contains(fixtureUsername))
    #expect(!text.contains(fixturePassword))
    #expect(keychain.values[credentialReference]?.contains(fixtureUsername) == true)
    #expect(keychain.values[credentialReference]?.contains(fixturePassword) == true)
}

@MainActor
@Test func sourceDiagnosticsRedactURLsCredentialsAndBodyFields() throws {
    let suiteName = "AppleSecurityRemediationTests.diagnostics.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let keychain = RemediationCredentialStore()
    let store = AppleSourceStore(defaults: defaults, keychain: keychain)
    let source = try store.addNetworkShare(
        name: "Media",
        host: "media.example.invalid",
        share: "Movies"
    )
    let fixtureUsername = "fixture-user"
    let fixturePassword = "fixture-password"
    let fixtureToken = "fixture-token"
    let diagnostic = "Request failed at smb://\(fixtureUsername):\(fixturePassword)@media.example.invalid/private/movies?token=\(fixtureToken) body={\"username\":\"\(fixtureUsername)\",\"password\":\"\(fixturePassword)\"}"

    store.recordValidationFailure(id: source.id, summary: diagnostic)

    let summary = try #require(store.sources.first?.validationFailureSummary)
    let persisted = try #require(defaults.data(forKey: "openstream.sources.v1"))
    let persistedText = try #require(String(data: persisted, encoding: .utf8))
    for sensitiveValue in [fixtureUsername, fixturePassword, fixtureToken, "/private/movies"] {
        #expect(!summary.contains(sensitiveValue))
        #expect(!persistedText.contains(sensitiveValue))
    }
    #expect(summary.contains("[REDACTED URL]"))
    #expect(summary.contains("body=[REDACTED]"))
}
