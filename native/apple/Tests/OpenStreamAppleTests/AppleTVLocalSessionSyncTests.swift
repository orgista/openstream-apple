import Foundation
import Synchronization
import Testing
@testable import OpenStreamApple

@MainActor
@Suite("TV local sessions during configuration sync")
struct AppleTVLocalSessionSyncTests {
    @Test(arguments: [true, false], [true, false])
    func newerPhoneSnapshotKeepsTheLocalSession(sameID: Bool, phoneEnabled: Bool) async throws {
        let tv = try SessionSyncDevice()
        let phone = try SessionSyncDevice()
        defer { tv.cleanUp(); phone.cleanUp() }
        let session = try fixtureSession()
        let local = try tv.sources.addMediaServer(kind: .jellyfin, name: "Rill", session: session)
        var incoming = sameID ? local : try phone.sources.addMediaServer(
            kind: .jellyfin, name: "Rill", session: fixtureSession(token: "fixture-phone-session"))
        incoming.name = "Rill from phone"
        incoming.isEnabled = phoneEnabled
        await tv.controller.start()
        let savedCredentials = tv.keys.values

        try await tv.receive(incoming)

        #expect(tv.sources.sources.count == 1)
        let restored = try #require(tv.sources.sources.first { $0.id == local.id })
        #expect(restored.name == incoming.name)
        #expect(restored.isEnabled)
        #expect(restored.needsSignIn == false)
        #expect(restored.credentialReference == local.credentialReference)
        #expect(restored.transportReference == local.transportReference)
        #expect(tv.keys.values == savedCredentials)
        #expect(tv.keys.removals.isEmpty)
        #expect(try tv.sources.mediaServerSession(for: restored) == session)

        let reloaded = AppleSourceStore(defaults: tv.defaults, keychain: tv.keys)
        let afterRelaunch = try #require(reloaded.sources.first { $0.id == local.id })
        #expect(reloaded.sources.count == 1)
        #expect(afterRelaunch.isEnabled)
        #expect(afterRelaunch.needsSignIn == false)
        #expect(try reloaded.mediaServerSession(for: afterRelaunch) == session)
        await tv.controller.becameActive()
        #expect(tv.sources.sources.first?.isEnabled == true)
    }

    @Test(arguments: [true, false])
    func aTVWithoutALocalTokenNeedsSignIn(existingSource: Bool) async throws {
        let tv = try SessionSyncDevice()
        let phone = try SessionSyncDevice()
        defer { tv.cleanUp(); phone.cleanUp() }
        let incoming: AppleSource
        if existingSource {
            incoming = try tv.sources.addMediaServer(kind: .jellyfin, name: "Rill", session: fixtureSession())
            try tv.keys.remove(try #require(incoming.credentialReference))
        } else {
            incoming = try phone.sources.addMediaServer(kind: .jellyfin, name: "Rill", session: fixtureSession())
        }
        await tv.controller.start()

        try await tv.receive(incoming)

        let restored = try #require(tv.sources.sources.first)
        #expect(tv.sources.sources.count == 1)
        #expect(restored.needsSignIn)
        #expect(restored.isEnabled == false)
        #expect(try tv.sources.mediaServerSession(for: restored) == nil)
    }

    @Test func cloudDoesNotReenableALocallyDisabledServer() async throws {
        let tv = try SessionSyncDevice()
        defer { tv.cleanUp() }
        let local = try tv.sources.addMediaServer(kind: .jellyfin, name: "Rill", session: fixtureSession())
        try await tv.sources.setEnabled(false, id: local.id)
        await tv.controller.start()

        try await tv.receive(local)

        let restored = try #require(tv.sources.sources.first)
        #expect(restored.isEnabled == false)
        #expect(restored.needsSignIn == false)
        #expect(try tv.sources.mediaServerSession(for: restored) != nil)
    }

    @Test func freshReadOnlyTVKeepsAuthenticatedSourcesDisabledUntilSecretsArrive() async throws {
        let tv = try SessionSyncDevice()
        let phone = try SessionSyncDevice()
        defer { tv.cleanUp(); phone.cleanUp() }
        _ = try phone.sources.addMediaServer(kind: .plex, name: "Fixture Plex",
            session: .init(kind: .plex, baseURL: try #require(URL(string: "https://fixture.example/plex")),
                accessToken: "fixture-plex-token", userID: "fixture-user", serverID: "fixture-server"))
        _ = try phone.sources.addIPTV(name: "Fixture TV", type: .xtream,
            endpoint: "https://fixture.example/television", username: "fixture-user", password: "fixture-password")
        _ = try phone.sources.addNetworkShare(name: "Fixture NAS", host: "fixture.example", share: "Media", path: "Films",
            username: "fixture-user", password: "fixture-password")
        await tv.controller.start()
        let snapshot = AppleConfigurationSnapshot(savedAt: Date(timeIntervalSinceNow: 60), sources: phone.sources.sources)
        tv.cloud.set(try snapshot.cloudData(), forKey: "openstream.configuration.v1")

        await tv.controller.readCloud()

        #expect(tv.sources.sources.count == 3)
        #expect(tv.sources.sources.filter(\.isEnabled).isEmpty)
        #expect(tv.sources.sources.allSatisfy { $0.needsSignIn })
        let nas = try #require(tv.sources.sources.first { $0.kind == .nas })
        #expect(try AppleSMBEndpointPolicy.parts(from: nas.url).path == "Films")
    }

    @Test(arguments: ["different-user", "different-path"])
    func distinctServerAccountsStaySeparate(difference: String) async throws {
        let tv = try SessionSyncDevice()
        let phone = try SessionSyncDevice()
        defer { tv.cleanUp(); phone.cleanUp() }
        let local = try tv.sources.addMediaServer(kind: .jellyfin, name: "Rill", session: fixtureSession())
        let incoming = try phone.sources.addMediaServer(kind: .jellyfin, name: "Other", session: fixtureSession(
            user: difference == "different-user" ? "fixture-other-user" : "fixture-user",
            path: difference == "different-path" ? "/other" : "/jf"))
        await tv.controller.start()

        try await tv.receive(incoming)

        #expect(tv.sources.sources.count == 2)
        #expect(tv.sources.sources.first { $0.id == local.id }?.isEnabled == true)
        let imported = try #require(tv.sources.sources.first { $0.id == incoming.id })
        #expect(imported.needsSignIn)
        #expect(imported.isEnabled == false)
        #expect(try tv.sources.mediaServerSession(for: imported) == nil)
    }

    @Test func aLegacySnapshotWithoutAUserDoesNotGuessAnAccount() async throws {
        let tv = try SessionSyncDevice()
        let phone = try SessionSyncDevice()
        defer { tv.cleanUp(); phone.cleanUp() }
        let local = try tv.sources.addMediaServer(kind: .jellyfin, name: "Rill", session: fixtureSession())
        var incoming = try phone.sources.addMediaServer(kind: .jellyfin, name: "Phone", session: fixtureSession())
        incoming.mediaServerIdentity = nil
        incoming.isEnabled = false
        await tv.controller.start()
        let saved = tv.keys.values

        try await tv.receive(incoming)

        #expect(tv.sources.sources.count == 2)
        #expect(tv.sources.sources.first { $0.id == local.id }?.isEnabled == true)
        #expect(tv.sources.sources.first { $0.id == incoming.id }?.needsSignIn == true)
        #expect(tv.keys.values == saved)
    }

    @Test func anExistingCredentialReferenceIsNotReplacedByAStableAccount() async throws {
        let tv = try SessionSyncDevice()
        defer { tv.cleanUp() }
        let session = try fixtureSession()
        var local = try tv.sources.addMediaServer(kind: .jellyfin, name: "Rill", session: session)
        let stableReference = try #require(local.credentialReference)
        let localCredential = try #require(tv.keys.values[stableReference])
        local.credentialReference = "fixture-local-reference"
        local.mediaServerIdentity = nil
        try tv.keys.set(localCredential, for: "fixture-local-reference")
        let otherSession = try fixtureSession(token: "fixture-other-session")
        try tv.keys.set(String(decoding: JSONEncoder().encode(otherSession), as: UTF8.self), for: stableReference)
        tv.defaults.set(try JSONEncoder().encode([local]), forKey: AppleSourceStore.defaultStorageKey)
        let store = AppleSourceStore(defaults: tv.defaults, keychain: tv.keys)
        let saved = tv.keys.values
        var incoming = AppleConfigurationSnapshot.portableSource(local)
        incoming.isEnabled = false

        try store.restoreConfigurationSources([incoming], secrets: nil, merge: false)

        let restored = try #require(store.sources.first)
        #expect(restored.credentialReference == "fixture-local-reference")
        #expect(restored.transportReference == local.transportReference)
        #expect(restored.isEnabled)
        #expect(restored.needsSignIn == false)
        #expect(try store.mediaServerSession(for: restored) == session)
        #expect(tv.keys.values == saved)
    }

    @Test func aPreviouslyImportedDuplicateMergesIntoTheActiveLocalSession() throws {
        let tv = try SessionSyncDevice()
        let phone = try SessionSyncDevice()
        defer { tv.cleanUp(); phone.cleanUp() }
        let local = try tv.sources.addMediaServer(kind: .jellyfin, name: "TV", session: fixtureSession())
        var incoming = try phone.sources.addMediaServer(kind: .jellyfin, name: "Phone", session: fixtureSession())
        incoming = AppleConfigurationSnapshot.portableSource(incoming)
        incoming.isEnabled = false
        tv.defaults.set(try JSONEncoder().encode([local, incoming]), forKey: AppleSourceStore.defaultStorageKey)
        let store = AppleSourceStore(defaults: tv.defaults, keychain: tv.keys)
        let saved = tv.keys.values

        try store.restoreConfigurationSources([incoming], secrets: nil)

        #expect(store.sources.map(\.id) == [local.id])
        #expect(store.sources.first?.isEnabled == true)
        #expect(store.sources.first?.needsSignIn == false)
        #expect(store.sourceTombstones[incoming.id] != nil)
        #expect(tv.keys.values == saved)
        #expect(tv.keys.removals.isEmpty)
    }

    @Test(arguments: [true, false])
    func snapshotMergesDeduplicateTheSameServerAccount(legacySnapshot: Bool) throws {
        let tv = try SessionSyncDevice()
        let phone = try SessionSyncDevice()
        defer { tv.cleanUp(); phone.cleanUp() }
        var local = try tv.sources.addMediaServer(kind: .jellyfin, name: "TV", session: fixtureSession())
        let incoming = try phone.sources.addMediaServer(kind: .jellyfin, name: "Phone", session: fixtureSession())
        if legacySnapshot { local.mediaServerIdentity = nil }
        let merged = AppleConfigurationSnapshot(sources: [local]).merging(.init(sources: [incoming]))

        #expect(merged.sources.count == (legacySnapshot ? 2 : 1))
        #expect(merged.sourceTombstones[local.id] != nil || legacySnapshot)
        let cloudText = String(decoding: try merged.cloudData(), as: UTF8.self)
        #expect(cloudText.contains("fixture-user") == false)
        #expect(cloudText.contains("fixture-tv-session") == false)
        let decoded = try JSONDecoder().decode(AppleConfigurationSnapshot.self, from: merged.cloudData())
        #expect(decoded.sources.first { $0.id == incoming.id }?.mediaServerIdentity == incoming.mediaServerIdentity)
        #expect(incoming.mediaServerIdentity?.count == 64)
    }

    @Test func snapshotMergeRemovesPreviouslyPublishedAliases() throws {
        let tv = try SessionSyncDevice()
        let phone = try SessionSyncDevice()
        defer { tv.cleanUp(); phone.cleanUp() }
        let local = try tv.sources.addMediaServer(kind: .jellyfin, name: "TV", session: fixtureSession())
        let alias = try phone.sources.addMediaServer(kind: .jellyfin, name: "Phone", session: fixtureSession())
        let cloud = AppleConfigurationSnapshot(sources: [local, alias])

        let merged = cloud.merging(.init(sources: [local]))

        #expect(merged.sources.map(\.id) == [local.id])
        #expect(merged.sourceTombstones[alias.id] != nil)
    }

    @Test(arguments: ["address", "kind", "identity"])
    func savedTokensSurviveMetadataMismatches(mismatch: String) throws {
        let tv = try SessionSyncDevice()
        defer { tv.cleanUp() }
        let session = try fixtureSession()
        var local = try tv.sources.addMediaServer(kind: .jellyfin, name: "TV", session: session)
        if mismatch == "address" {
            local.url = try #require(URL(string: "http://fixture.example/rewritten"))
            local.mediaServerIdentity = nil
        }
        if mismatch == "kind" { local.serverKind = .emby }
        if mismatch == "identity" { local.mediaServerIdentity = "outdated-identity" }
        tv.defaults.set(try JSONEncoder().encode([local]), forKey: AppleSourceStore.defaultStorageKey)
        let store = AppleSourceStore(defaults: tv.defaults, keychain: tv.keys)
        let saved = tv.keys.values

        #expect(try store.mediaServerSession(for: local) == session)
        try store.restoreConfigurationSources([AppleConfigurationSnapshot.portableSource(local)], secrets: nil)

        let restored = try #require(store.sources.first)
        #expect(restored.isEnabled)
        #expect(restored.needsSignIn == false)
        #expect(try store.mediaServerSession(for: restored) == session)
        #expect(tv.keys.values == saved)
    }

    @Test func corruptSessionsStillThrow() throws {
        let tv = try SessionSyncDevice()
        defer { tv.cleanUp() }
        let local = try tv.sources.addMediaServer(kind: .jellyfin, name: "TV", session: fixtureSession())
        try tv.keys.set("not a session", for: try #require(local.credentialReference))
        #expect(throws: (any Error).self) { try tv.sources.mediaServerSession(for: local) }
    }

    @Test(arguments: [true, false])
    func metadataMismatchesAreRevalidatedAndFailuresKeepWorking(accepted: Bool) async throws {
        let tv = try SessionSyncDevice()
        defer { tv.cleanUp() }
        let session = try fixtureSession()
        var local = try tv.sources.addMediaServer(kind: .jellyfin, name: "TV", session: session)
        local.mediaServerIdentity = "outdated-identity"
        tv.defaults.set(try JSONEncoder().encode([local]), forKey: AppleSourceStore.defaultStorageKey)
        let store = AppleSourceStore(defaults: tv.defaults, keychain: tv.keys)
        let requests = Mutex(0)
        let client = AppleMediaServerClient(loader: { request in
            requests.withLock { $0 += 1 }
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(url: url, statusCode: accepted ? 200 : 401, httpVersion: nil, headerFields: nil))
            return (Data(#"{"Id":"fixture-user"}"#.utf8), response)
        })

        await store.revalidateSavedMediaServerSessions(client: client)

        let restored = try #require(store.sources.first)
        #expect(requests.withLock { $0 } == 1)
        #expect(restored.isEnabled)
        #expect(restored.needsSignIn == false)
        #expect(try store.mediaServerSession(for: restored) == session)
        #expect(restored.mediaServerIdentity == (accepted ? AppleSourceStore.mediaServerIdentity(for: session) : "outdated-identity"))
    }

    @Test(arguments: ["http://fixture.example/jf", "https://fixture.example/other"])
    func signingInAgainMatchesHostPortAndUser(address: String) throws {
        let tv = try SessionSyncDevice()
        defer { tv.cleanUp() }
        let original = try tv.sources.addMediaServer(kind: .jellyfin, name: "TV", session: fixtureSession())
        let session = AppleMediaServerSession(kind: .jellyfin, baseURL: try #require(URL(string: address)),
            accessToken: "replacement-token", userID: "fixture-user")

        let updated = try tv.sources.addMediaServer(kind: .jellyfin, name: "TV", session: session)

        #expect(updated.id == original.id)
        #expect(tv.sources.sources.count == 1)
        #expect(try tv.sources.mediaServerSession(for: updated) == session)
    }

    @Test func snapshotPrefersTheIDMatchAndTombstonesEveryAlias() throws {
        let tv = try SessionSyncDevice()
        let phone = try SessionSyncDevice()
        defer { tv.cleanUp(); phone.cleanUp() }
        let accountMatch = try tv.sources.addMediaServer(kind: .jellyfin, name: "TV", session: fixtureSession())
        var idMatch = try phone.sources.addMediaServer(kind: .jellyfin, name: "Phone", session: fixtureSession(user: "other-user"))
        let old = AppleConfigurationSnapshot(sources: [accountMatch, idMatch])
        idMatch.mediaServerIdentity = accountMatch.mediaServerIdentity

        let merged = old.merging(.init(sources: [idMatch]))

        #expect(merged.sources.map(\.id) == [idMatch.id])
        #expect(merged.sourceTombstones[accountMatch.id] != nil)
        #expect(merged.merging(old).sources.map(\.id) == [idMatch.id])
    }

    @Test(arguments: ["other-user", "same-user"])
    func legacyCredentialsMatchTheUserBeforeMerging(user: String) throws {
        let tv = try SessionSyncDevice()
        defer { tv.cleanUp() }
        let local = try tv.sources.addMediaServer(kind: .jellyfin, name: "TV", session: fixtureSession())
        let incoming = AppleSource(kind: .mediaServer, name: "Phone", url: try #require(URL(string: "https://fixture.example/")), serverKind: .jellyfin)
        let session = try fixtureSession(user: user == "same-user" ? "fixture-user" : "other-user")
        var secrets = AppleConfigurationSecrets()
        secrets.sourceCredentials[incoming.id] = String(decoding: try JSONEncoder().encode(session), as: UTF8.self)
        let saved = tv.keys.values

        try tv.sources.restoreConfigurationSources([incoming], secrets: secrets)

        #expect(tv.sources.sources.count == (user == "same-user" ? 1 : 2))
        #expect(try tv.sources.mediaServerSession(for: local)?.userID == "fixture-user")
        if user == "same-user" { #expect(tv.keys.values == saved) }
    }

    @Test(arguments: [true, false])
    func invalidImportsNeverOverwriteOrOrphanCredentials(sameID: Bool) throws {
        let tv = try SessionSyncDevice()
        defer { tv.cleanUp() }
        let local = try tv.sources.addMediaServer(kind: .jellyfin, name: "TV", session: fixtureSession())
        var incoming = AppleSource(id: sameID ? local.id : UUID(), kind: .mediaServer, name: "Phone",
            url: local.url, serverKind: .jellyfin, mediaServerIdentity: "wrong-account")
        incoming.needsSignIn = true
        var secrets = AppleConfigurationSecrets()
        secrets.sourceCredentials[incoming.id] = String(decoding: try JSONEncoder().encode(fixtureSession(user: "other-user")), as: UTF8.self)
        let saved = tv.keys.values

        try tv.sources.restoreConfigurationSources([incoming], secrets: secrets)

        #expect(tv.keys.values == saved)
        #expect(try tv.sources.mediaServerSession(for: local)?.accessToken == "fixture-tv-session")
    }

    @Test func aFailedCredentialWriteRollsBackAnImportedToken() throws {
        let tv = try SessionSyncDevice()
        defer { tv.cleanUp() }
        let session = try fixtureSession()
        let incoming = AppleSource(kind: .mediaServer, name: "Phone", url: session.baseURL,
            serverKind: .jellyfin, mediaServerIdentity: AppleSourceStore.mediaServerIdentity(for: session))
        var secrets = AppleConfigurationSecrets()
        secrets.sourceCredentials[incoming.id] = String(decoding: try JSONEncoder().encode(session), as: UTF8.self)
        tv.keys.failNextWriteAfterSaving = true

        let failures = try tv.sources.restoreConfigurationSources([incoming], secrets: secrets)

        #expect(failures == 1)
        #expect(tv.keys.values.isEmpty)
        #expect(tv.sources.sources.first?.needsSignIn == true)
    }

    @Test(arguments: [true, false])
    func theTVKeepsCredentialsLocalRegardlessOfTheSyncPreference(preference: Bool) {
        #expect(AppleConfigurationSyncPolicy.synchronizesCredentials(storedPreference: preference, mode: .automaticReadOnly) == false)
        #expect(AppleConfigurationSyncPolicy.synchronizesCredentials(storedPreference: preference, mode: .viewerChoice) == preference)
    }

    @Test func aLegacySnapshotDoesNotGuessBetweenLocalUsers() async throws {
        let tv = try SessionSyncDevice()
        let phone = try SessionSyncDevice()
        defer { tv.cleanUp(); phone.cleanUp() }
        let first = try tv.sources.addMediaServer(kind: .jellyfin, name: "First", session: fixtureSession())
        let second = try tv.sources.addMediaServer(kind: .jellyfin, name: "Second",
            session: fixtureSession(user: "fixture-other-user"))
        var incoming = try phone.sources.addMediaServer(kind: .jellyfin, name: "Phone", session: fixtureSession())
        incoming.mediaServerIdentity = nil
        await tv.controller.start()
        let saved = tv.keys.values

        try await tv.receive(incoming)

        #expect(tv.sources.sources.first { $0.id == first.id }?.isEnabled == true)
        #expect(tv.sources.sources.first { $0.id == second.id }?.isEnabled == true)
        #expect(tv.sources.sources.first { $0.id == incoming.id }?.needsSignIn == true)
        #expect(tv.keys.values == saved)
    }

    @Test func canonicalServerURLsMatchTheSameUser() async throws {
        let tv = try SessionSyncDevice()
        let phone = try SessionSyncDevice()
        defer { tv.cleanUp(); phone.cleanUp() }
        let local = try tv.sources.addMediaServer(kind: .jellyfin, name: "TV", session: fixtureSession())
        let session = AppleMediaServerSession(kind: .jellyfin,
            baseURL: try #require(URL(string: "https://FIXTURE.example:443/jf/")),
            accessToken: "fixture-phone-session", userID: "fixture-user")
        let incoming = try phone.sources.addMediaServer(kind: .jellyfin, name: "Phone", session: session)
        await tv.controller.start()

        try await tv.receive(incoming)

        #expect(tv.sources.sources.map(\.id) == [local.id])
        #expect(tv.sources.sources.first?.isEnabled == true)
        #expect(tv.sources.sources.first?.needsSignIn == false)
    }

    private func fixtureSession(token: String = "fixture-tv-session", user: String = "fixture-user",
                                path: String = "/jf") throws -> AppleMediaServerSession {
        AppleMediaServerSession(kind: .jellyfin,
            baseURL: try #require(URL(string: "https://fixture.example" + path)),
            accessToken: token, userID: user, serverID: "fixture-server")
    }
}

@MainActor
private struct SessionSyncDevice {
    let suite = "tv-session-sync.\(UUID())"
    let defaults: UserDefaults
    let keys = SessionSyncCredentials()
    let cloud = FakeCloudStore()
    let sources: AppleSourceStore
    let controller: AppleConfigurationController
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tv-session-sync-\(UUID())")

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(false, forKey: AppleKeychainStore.syncPreferenceKey)
        sources = AppleSourceStore(defaults: defaults, keychain: keys, documentsDirectory: directory)
        controller = AppleConfigurationController(sources: sources,
            settings: AppleSettingsStore(defaults: defaults, keychain: SessionSyncCredentials()),
            mediaIndex: AppleMediaIndexStore(repository: AppleMediaIndexRepository(
                fileURL: directory.appendingPathComponent("index.json"))),
            defaults: defaults, cloud: cloud,
            lineupStore: AppleChannelLineupStore(directory: directory, latestCloudRevision: { nil }),
            syncMode: .automaticReadOnly)
    }

    func receive(_ source: AppleSource) async throws {
        let snapshot = AppleConfigurationSnapshot(savedAt: Date(timeIntervalSinceNow: 60), sources: [source])
        cloud.set(try snapshot.cloudData(), forKey: "openstream.configuration.v1")
        await controller.readCloud()
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class SessionSyncCredentials: AppleCredentialStoring {
    var values: [String: String] = [:]
    var failNextWriteAfterSaving = false
    private(set) var removals: [String] = []

    func string(for account: String) throws -> String? { values[account] }
    func set(_ value: String, for account: String) throws {
        values[account] = value
        if failNextWriteAfterSaving {
            failNextWriteAfterSaving = false
            throw AppleKeychainStoreError.invalidData
        }
    }
    func remove(_ account: String) throws {
        values.removeValue(forKey: account)
        removals.append(account)
    }
}
