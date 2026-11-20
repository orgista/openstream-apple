import CloudKit
import Foundation
import Observation
import Synchronization
import Testing
@testable import OpenStreamApple

@MainActor
@Suite("Encrypted media server sign-in sync")
struct AppleMediaServerSessionSyncTests {
    @Test func aMissingPublishedRecordIsRepublishedFromTheCurrentKeychain() async throws {
        let cloud = SessionCloudStub()
        let phone = try SignInSyncDevice(cloud: cloud, publisher: true)
        let tv = try SignInSyncDevice(cloud: cloud, publisher: false)
        defer { phone.cleanUp(); tv.cleanUp() }
        let source = try phone.sources.addMediaServer(kind: .jellyfin, name: "Server", session: session())
        try tv.receive(source)
        await phone.sync.synchronize()
        #expect(cloud.records[source.id] != nil)
        cloud.records.removeAll()

        await phone.sync.synchronize()
        await tv.sync.synchronize()

        #expect(cloud.records[source.id] != nil)
        #expect(tv.sources.sources.first?.isEnabled == true)
        #expect(tv.validations.count == 1)
        #expect(cloud.saves == 2)
        await phone.sync.synchronize()
        #expect(cloud.saves == 2)
    }

    @Test(arguments: [false, true])
    func disabledOrHeldSyncDoesNotFetch(held: Bool) async throws {
        let cloud = SessionCloudStub()
        let device = try SignInSyncDevice(cloud: cloud, publisher: true)
        defer { device.cleanUp() }
        device.defaults.set(held, forKey: AppleDeviceReset.cloudRestoreHeldKey)

        await device.sync.synchronize(enabled: held)

        #expect(cloud.fetches == 0)
        #expect(device.diagnostics.lines.contains("source sign-in sync: skipped reason=\(held ? "restore-held" : "disabled")"))
        #expect(device.diagnostics.summaries.isEmpty)
    }

    @Test func aFreshLocalSignInRepairsAnUnreadableRecordAndCompletesItsMutation() async throws {
        let cloud = SessionCloudStub()
        let phone = try SignInSyncDevice(cloud: cloud, publisher: true)
        defer { phone.cleanUp() }
        let source = try phone.sources.addMediaServer(kind: .jellyfin, name: "Server", session: session())
        await phone.sync.synchronize()
        cloud.unavailableIDs = [source.id]
        _ = try phone.sources.addMediaServer(kind: .jellyfin, name: "Server", session: session(token: "fixture-refreshed-token"))

        await phone.sync.synchronize()

        #expect(cloud.records[source.id]?.session?.accessToken == "fixture-refreshed-token")
        #expect(cloud.saves == 2)
        #expect(phone.sources.mediaServerSessionMutations.isEmpty)
        #expect(phone.sync.hasPendingLocalChanges == false)
    }

    @Test func aLegacyPublicationCacheDoesNotSuppressUploadsAfterRelaunch() async throws {
        let cloud = SessionCloudStub()
        let phone = try SignInSyncDevice(cloud: cloud, publisher: true)
        defer { phone.cleanUp() }
        let source = try phone.sources.addMediaServer(kind: .jellyfin, name: "Server", session: session())
        await phone.sync.synchronize()
        let entry = try #require(cloud.records[source.id])
        let legacy: [String: Any] = ["accountID": "fixture-cloud-account",
            "published": [source.id.uuidString, entry.fingerprint]]
        phone.defaults.set(try JSONSerialization.data(withJSONObject: legacy), forKey: AppleMediaServerSessionSync.stateKey)
        cloud.records.removeAll()
        let reloaded = AppleSourceStore(defaults: phone.defaults, keychain: phone.keys, documentsDirectory: phone.directory)
        let sync = AppleMediaServerSessionSync(sources: reloaded, defaults: phone.defaults,
            cloud: cloud, publishesSessions: true)

        await sync.synchronize()

        #expect(cloud.records[source.id] != nil)
        #expect(cloud.saves == 2)
    }

    @Test func cancellationBeforeSyncDoesNotFetch() async throws {
        let cloud = SessionCloudStub()
        let gate = SessionValidationGate()
        let device = try SignInSyncDevice(cloud: cloud, publisher: true)
        defer { device.cleanUp() }
        let work = Task {
            await gate.pause()
            await device.sync.synchronize()
        }
        await gate.waitUntilEntered()
        work.cancel()
        await gate.release()
        await work.value

        #expect(cloud.fetches == 0)
        #expect(device.diagnostics.lines.contains("source sign-in sync: stopped reason=cancelled"))
        #expect(device.diagnostics.summaries.isEmpty)
    }

    @Test func cancelledSyncRecordsDisabledIntentAndAttemptedMutations() async throws {
        let cloud = SessionCloudStub()
        let gate = SessionValidationGate()
        let device = try SignInSyncDevice(cloud: cloud, publisher: true)
        defer { device.cleanUp() }
        _ = try device.sources.addMediaServer(kind: .jellyfin, name: "Server", session: session())
        #expect(device.sync.hasPendingLocalChanges)
        let work = Task {
            await gate.pause()
            await device.sync.synchronize(enabled: false)
        }
        await gate.waitUntilEntered()
        work.cancel()
        await gate.release()
        await work.value

        #expect(device.sync.hasPendingLocalChanges == false)
        #expect(device.sources.mediaServerSessionMutations.isEmpty == false)
        let restored = await device.sources.refreshCloudSessionAfterUnauthorized?(UUID())
        #expect(restored == false)
        #expect(cloud.fetches == 0)
        #expect(device.diagnostics.lines.contains("source sign-in sync: recovery skipped reason=disabled"))
        #expect(device.diagnostics.summaries.isEmpty)
    }

    @Test func publishCandidatesCountOnlyEligibleSignedInSources() async throws {
        let cloud = SessionCloudStub()
        let phone = try SignInSyncDevice(cloud: cloud, publisher: true)
        defer { phone.cleanUp() }
        let signedIn = try phone.sources.addMediaServer(kind: .jellyfin, name: "Server", session: session())
        try phone.receive(AppleSource(kind: .mediaServer, name: "Waiting", url: #require(URL(string: "https://fixture.example/other")),
            serverKind: .emby, mediaServerIdentity: "fixture-waiting-server"))
        _ = try phone.sources.addLibraryFolder(name: "Local", url: phone.directory, bookmarkData: nil)

        await phone.sync.synchronize()

        #expect(phone.sources.sources.count == 3)
        #expect(Set(cloud.records.keys) == Set([signedIn.id]))
        #expect(phone.diagnostics.lines.contains("source sign-in sync: publish candidates=1 submitted=1 deleted=0"))
        phone.diagnostics.lines.removeAll()
        await phone.sync.synchronize()
        #expect(phone.diagnostics.lines.contains("source sign-in sync: publish candidates=1 submitted=0 deleted=0"))
        #expect(phone.diagnostics.lines.contains("source sign-in sync: publish skipped reason=unchanged"))
    }

    @Test func cancellationDuringFetchDoesNotPublish() async throws {
        let cloud = SessionCloudStub()
        let gate = SessionValidationGate()
        let device = try SignInSyncDevice(cloud: cloud, publisher: true)
        defer { device.cleanUp() }
        _ = try device.sources.addMediaServer(kind: .jellyfin, name: "Server", session: session())
        cloud.beforeFetch = { await gate.pause() }
        let work = Task { await device.sync.synchronize() }
        await gate.waitUntilEntered()
        work.cancel()
        await gate.release()
        await work.value
        cloud.beforeFetch = nil

        #expect(cloud.records.isEmpty)
        #expect(!device.sources.mediaServerSessionMutations.isEmpty)
        #expect(device.diagnostics.lines.contains("source sign-in sync: stopped reason=cancelled"))
        #expect(device.diagnostics.summaries.isEmpty)
    }

    @Test func concurrentRequestsWaitForOneFollowupFetch() async throws {
        let cloud = SessionCloudStub()
        let gate = SessionValidationGate()
        let device = try SignInSyncDevice(cloud: cloud, publisher: false)
        defer { device.cleanUp() }
        cloud.beforeFetch = { await gate.pause() }
        let first = Task { await device.sync.synchronize() }
        await gate.waitUntilEntered()
        let second = Task { await device.sync.synchronize() }
        await device.diagnostics.wait(until: "source sign-in sync: queued reason=already-syncing")
        cloud.beforeFetch = nil
        await gate.release()
        await first.value
        await second.value

        #expect(cloud.fetches == 2)
        #expect(device.diagnostics.lines.contains("source sign-in sync: publish read-only candidates=0 submitted=0"))
    }

    @Test func concurrentImportsPublishOneObservableRefresh() async throws {
        let cloud = SessionCloudStub()
        let gate = SessionValidationGate()
        let phone = try SignInSyncDevice(cloud: cloud, publisher: true)
        let device = try SignInSyncDevice(cloud: cloud, publisher: false)
        defer { phone.cleanUp(); device.cleanUp() }
        let source = try phone.sources.addMediaServer(kind: .jellyfin, name: "Server", session: session())
        try device.receive(source)
        await phone.sync.synchronize()
        await confirmation { refreshed in
            withObservationTracking {
                _ = device.sources.credentialsRestoreRevision
            } onChange: { refreshed() }
            cloud.beforeFetch = { await gate.pause() }
            let first = Task { await device.sync.synchronize() }
            await gate.waitUntilEntered()
            let second = Task { await device.sync.synchronize() }
            await device.diagnostics.wait(until: "source sign-in sync: queued reason=already-syncing")
            cloud.beforeFetch = nil
            await gate.release()
            await first.value
            await second.value
        }

        #expect(device.sources.sources.first?.isEnabled == true)
        #expect(device.sources.credentialsRestoreRevision == 1)
        #expect(device.diagnostics.lines.filter { $0 == "source sign-in sync: refresh restored sources" }.count == 1)
    }

    @Test func accountChangeDuringFetchCannotPublish() async throws {
        let cloud = SessionCloudStub()
        let device = try SignInSyncDevice(cloud: cloud, publisher: true)
        defer { device.cleanUp() }
        _ = try device.sources.addMediaServer(kind: .jellyfin, name: "Server", session: session())
        cloud.beforeFetch = { device.sync.accountChanged() }

        await device.sync.synchronize()
        cloud.beforeFetch = nil

        #expect(cloud.records.isEmpty)
        #expect(device.defaults.bool(forKey: AppleDeviceReset.cloudRestoreHeldKey))
        #expect(device.diagnostics.lines.contains("source sign-in sync: stopped reason=generation-changed-after-fetch"))
        #expect(device.diagnostics.summaries.isEmpty)
    }

    @Test(arguments: [false, true])
    func accountChangeDuringCleanupStopsTheOldGeneration(reset: Bool) async throws {
        let cloud = SessionCloudStub()
        let device = try SignInSyncDevice(cloud: cloud, publisher: true)
        defer { device.cleanUp() }
        let source = try device.sources.addMediaServer(kind: .jellyfin, name: "Server", session: session())
        await device.sync.synchronize()
        if reset { device.defaults.set(true, forKey: AppleMediaServerSessionSync.resetKey) }
        else { try device.sources.signOutMediaServer(id: source.id) }
        cloud.beforeDelete = { device.sync.accountChanged() }

        await device.sync.synchronize(enabled: false)
        cloud.beforeDelete = nil

        #expect(device.defaults.bool(forKey: AppleDeviceReset.cloudRestoreHeldKey))
        #expect(device.diagnostics.lines.contains("source sign-in sync: stopped reason=generation-changed-after-\(reset ? "reset" : "delete")"))
    }

    @Test func accountChangeDuringPublishKeepsTheNewAccountHeld() async throws {
        let cloud = SessionCloudStub()
        let device = try SignInSyncDevice(cloud: cloud, publisher: true)
        defer { device.cleanUp() }
        _ = try device.sources.addMediaServer(kind: .jellyfin, name: "Server", session: session())
        cloud.beforeSave = { device.sync.accountChanged() }

        await device.sync.synchronize()
        cloud.beforeSave = nil

        #expect(device.defaults.bool(forKey: AppleDeviceReset.cloudRestoreHeldKey))
        #expect(device.diagnostics.lines.contains("source sign-in sync: stopped reason=generation-changed-after-publish"))
        let saved = try #require(device.defaults.data(forKey: AppleMediaServerSessionSync.stateKey))
        let state = try #require(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        #expect(state["accountID"] as? String == "")
    }

    @Test func accountChangeDuringValidationDoesNotInstallCredentials() async throws {
        let cloud = SessionCloudStub()
        let gate = SessionValidationGate()
        let tv = try SignInSyncDevice(cloud: cloud, publisher: false, beforeValidation: { await gate.pause() })
        defer { tv.cleanUp() }
        let entry = AppleCloudMediaServerSession(sourceID: UUID(), session: try session())
        cloud.records[entry.sourceID] = entry
        try tv.receive(AppleSource(id: entry.sourceID, kind: .mediaServer, name: "Server", url: entry.sourceURL,
            serverKind: .jellyfin, mediaServerIdentity: entry.identity))
        let work = Task { await tv.sync.synchronize() }
        await gate.waitUntilEntered()
        tv.sync.accountChanged()
        await gate.release()
        await work.value

        #expect(tv.keys.values.isEmpty)
        #expect(tv.sources.sources.first?.needsSignIn == true)
        #expect(tv.diagnostics.lines.contains("source sign-in sync: import skipped reason=generation-changed-after-validation"))
    }

    @Test(arguments: ["disabled", "restore-held", "preference-disabled"])
    func unauthorizedRecoveryExplainsEachGate(reason: String) async throws {
        let cloud = SessionCloudStub()
        let device = try SignInSyncDevice(cloud: cloud, publisher: true)
        defer { device.cleanUp() }
        switch reason {
        case "disabled": await device.sync.synchronize(enabled: false)
        case "restore-held": device.defaults.set(true, forKey: AppleDeviceReset.cloudRestoreHeldKey)
        default: device.defaults.set(false, forKey: AppleKeychainStore.syncPreferenceKey)
        }

        let restored = await device.sources.refreshCloudSessionAfterUnauthorized?(UUID())

        #expect(restored == false)
        #expect(cloud.fetches == 0)
        #expect(device.diagnostics.lines.contains("source sign-in sync: recovery skipped reason=\(reason)"))
    }

    @Test(arguments: [CKError.Code.missingEntitlement, .notAuthenticated, .networkUnavailable])
    func cloudKitFailuresAreTracedWithoutChangingCredentials(code: CKError.Code) async throws {
        let cloud = SessionCloudStub()
        let device = try SignInSyncDevice(cloud: cloud, publisher: true)
        defer { device.cleanUp() }
        let source = try device.sources.addMediaServer(kind: .jellyfin, name: "Server", session: session())
        cloud.fetchError = CKError(code)

        await device.sync.synchronize()

        #expect(cloud.records.isEmpty)
        #expect(try device.sources.mediaServerSession(for: source)?.accessToken == "fixture-phone-token")
        #expect(device.diagnostics.lines.contains("source sign-in sync: unavailable domain=CKErrorDomain code=\(code.rawValue)"))
        #expect(!device.diagnostics.lines.joined().contains("fixture-phone-token"))
        #expect(device.diagnostics.summaries.isEmpty)
    }

    @Test(arguments: [AppleMediaServerKind.jellyfin, .emby, .plex])
    func phoneSignInEnablesTVWithoutAPrompt(kind: AppleMediaServerKind) async throws {
        let cloud = SessionCloudStub()
        let phone = try SignInSyncDevice(cloud: cloud, publisher: true)
        let tv = try SignInSyncDevice(cloud: cloud, publisher: false)
        defer { phone.cleanUp(); tv.cleanUp() }
        let source = try phone.sources.addMediaServer(kind: kind, name: "Rill", session: session(kind: kind))
        try tv.receive(source)

        await phone.sync.synchronize()
        await tv.sync.synchronize()

        let restored = try #require(tv.sources.sources.first)
        #expect(restored.isEnabled)
        #expect(!restored.needsSignIn)
        #expect(try tv.sources.mediaServerSession(for: restored)?.accessToken == "fixture-phone-token")
        #expect(tv.validations.count == 1)
        #expect(phone.diagnostics.lines.contains("source sign-in sync: publish candidates=1 submitted=1 deleted=0"))
        #expect(tv.diagnostics.lines.contains("source sign-in sync: fetch records=1 unreadable=0"))
        #expect(tv.diagnostics.lines.contains("source sign-in sync: import validated=1 imported=1 enabled=1"))
        #expect(tv.diagnostics.summaries.count == 1)
        #expect(!(phone.diagnostics.lines + tv.diagnostics.lines).joined().contains("fixture-phone-token"))
        await tv.sync.synchronize()
        #expect(tv.validations.count == 1)
        let snapshot = try AppleConfigurationSnapshot(sources: tv.sources.sources).cloudData()
        #expect(!String(decoding: snapshot, as: UTF8.self).contains("fixture-phone-token"))
    }

    @Test func localTVSignInWinsEvenWhenSourceIDsDiffer() async throws {
        let cloud = SessionCloudStub()
        let phone = try SignInSyncDevice(cloud: cloud, publisher: true)
        let tv = try SignInSyncDevice(cloud: cloud, publisher: false)
        defer { phone.cleanUp(); tv.cleanUp() }
        let phoneSource = try phone.sources.addMediaServer(kind: .jellyfin, name: "Phone", session: session())
        let local = try tv.sources.addMediaServer(kind: .jellyfin, name: "TV", session: session(token: "fixture-tv-token"))
        try tv.receive(phoneSource)

        await phone.sync.synchronize()
        await tv.sync.synchronize()

        let restored = try #require(tv.sources.sources.first)
        #expect(restored.id == local.id)
        #expect(try tv.sources.mediaServerSession(for: restored)?.accessToken == "fixture-tv-token")
        #expect(tv.validations.count == 0)
        #expect(cloud.saves == 1)
        #expect(cloud.records[phoneSource.id]?.session?.accessToken == "fixture-phone-token")
    }

    @Test func aSignInMadeOnOneTVReachesTheOtherTVsAndThePhone() async throws {
        let cloud = SessionCloudStub()
        let bedroom = try SignInSyncDevice(cloud: cloud, publisher: false)
        let office = try SignInSyncDevice(cloud: cloud, publisher: false)
        let phone = try SignInSyncDevice(cloud: cloud, publisher: true)
        defer { bedroom.cleanUp(); office.cleanUp(); phone.cleanUp() }
        let source = try bedroom.sources.addMediaServer(kind: .jellyfin, name: "Rill", session: session(token: "fixture-bedroom"))
        try office.receive(source)
        try phone.receive(source)

        await bedroom.sync.synchronize()
        await office.sync.synchronize()
        await phone.sync.synchronize()

        #expect(cloud.saves == 1)
        #expect(bedroom.diagnostics.lines.contains("source sign-in sync: publish read-only candidates=1 submitted=1"))
        for device in [office, phone] {
            let restored = try #require(device.sources.sources.first)
            #expect(restored.isEnabled && !restored.needsSignIn)
            #expect(try device.sources.mediaServerSession(for: restored)?.accessToken == "fixture-bedroom")
        }
        await bedroom.sync.synchronize()
        await office.sync.synchronize()
        #expect(cloud.saves == 1)
    }

    @Test func aTVNeverRepublishesASignInThePhoneSignedOut() async throws {
        let cloud = SessionCloudStub()
        let bedroom = try SignInSyncDevice(cloud: cloud, publisher: false)
        let phone = try SignInSyncDevice(cloud: cloud, publisher: true)
        defer { bedroom.cleanUp(); phone.cleanUp() }
        let source = try bedroom.sources.addMediaServer(kind: .jellyfin, name: "Rill", session: session(token: "fixture-bedroom"))
        try phone.receive(source)
        await bedroom.sync.synchronize()
        await phone.sync.synchronize()

        try phone.sources.signOutMediaServer(id: source.id)
        await phone.sync.synchronize()
        #expect(cloud.records.isEmpty)
        await bedroom.sync.synchronize()

        #expect(cloud.records.isEmpty)
        #expect(cloud.saves == 1)
    }

    @Test(arguments: [true, false])
    func phoneSignOutOrRemovalReachesTV(removeSource: Bool) async throws {
        let cloud = SessionCloudStub()
        let phone = try SignInSyncDevice(cloud: cloud, publisher: true)
        let tv = try SignInSyncDevice(cloud: cloud, publisher: false)
        defer { phone.cleanUp(); tv.cleanUp() }
        let source = try phone.sources.addMediaServer(kind: .jellyfin, name: "Rill", session: session())
        try tv.receive(source)
        await phone.sync.synchronize()
        await tv.sync.synchronize()
        if removeSource { #expect(phone.sources.remove(id: source.id)) }
        else { try phone.sources.signOutMediaServer(id: source.id) }

        await phone.sync.synchronize()
        await tv.sync.synchronize()

        let restored = try #require(tv.sources.sources.first)
        #expect(restored.needsSignIn)
        #expect(!restored.isEnabled)
        #expect(try tv.sources.mediaServerSession(for: restored) == nil)
        #expect(cloud.records.isEmpty)
    }

    @Test func unavailableAccountLeavesTheSourceWaiting() async throws {
        let cloud = SessionCloudStub()
        let tv = try SignInSyncDevice(cloud: cloud, publisher: false)
        defer { tv.cleanUp() }
        let record = AppleCloudMediaServerSession(sourceID: UUID(), session: try session())
        cloud.records[record.sourceID] = record
        try tv.receive(AppleSource(id: record.sourceID, kind: .mediaServer, name: "Rill",
            url: record.sourceURL, serverKind: .jellyfin, mediaServerIdentity: record.identity))
        cloud.accountID = nil

        await tv.sync.synchronize()

        #expect(tv.sources.sources.first?.needsSignIn == true)
        #expect(tv.sources.sources.first?.isEnabled == false)
        #expect(tv.sources.credentialsRestoreRevision == 0)
        #expect(tv.keys.values.isEmpty)
        #expect(cloud.deletions.isEmpty)
        #expect(tv.diagnostics.lines.contains("source sign-in sync: skipped reason=cloud-unavailable"))
        #expect(tv.diagnostics.summaries.isEmpty)
    }

    @Test func rejectedTokenStaysInCloudAndDoesNotEnableTheSource() async throws {
        let cloud = SessionCloudStub()
        let tv = try SignInSyncDevice(cloud: cloud, publisher: false, status: 401)
        defer { tv.cleanUp() }
        let record = AppleCloudMediaServerSession(sourceID: UUID(), session: try session())
        cloud.records[record.sourceID] = record
        try tv.receive(AppleSource(id: record.sourceID, kind: .mediaServer, name: "Rill",
            url: record.sourceURL, serverKind: .jellyfin, mediaServerIdentity: record.identity))

        await tv.sync.synchronize()

        #expect(tv.sources.sources.first?.needsSignIn == true)
        #expect(tv.sources.sources.first?.isEnabled == false)
        #expect(cloud.records[record.sourceID] == record)
        #expect(cloud.deletions.isEmpty)
        #expect(tv.keys.values.isEmpty)
    }

    @Test func refreshedPhoneTokenUpdatesAnImportedSession() async throws {
        let cloud = SessionCloudStub()
        let phone = try SignInSyncDevice(cloud: cloud, publisher: true)
        let tv = try SignInSyncDevice(cloud: cloud, publisher: false)
        defer { phone.cleanUp(); tv.cleanUp() }
        let source = try phone.sources.addMediaServer(kind: .jellyfin, name: "Rill", session: session())
        try tv.receive(source)
        await phone.sync.synchronize()
        await tv.sync.synchronize()
        try await tv.sources.setEnabled(false, id: source.id)
        _ = try phone.sources.addMediaServer(kind: .jellyfin, name: "Rill", session: session(token: "fixture-refreshed-token"))

        await phone.sync.synchronize()
        await tv.sync.synchronize()

        let restored = try #require(tv.sources.sources.first)
        #expect(restored.isEnabled)
        #expect(try tv.sources.mediaServerSession(for: restored)?.accessToken == "fixture-refreshed-token")
        #expect(tv.validations.count == 2)
        #expect(tv.sources.credentialsRestoreRevision == 2)
    }

    @Test func networkFailureCannotLookLikeSignOut() async throws {
        let cloud = SessionCloudStub()
        let phone = try SignInSyncDevice(cloud: cloud, publisher: true)
        let tv = try SignInSyncDevice(cloud: cloud, publisher: false)
        defer { phone.cleanUp(); tv.cleanUp() }
        let source = try phone.sources.addMediaServer(kind: .jellyfin, name: "Rill", session: session())
        try tv.receive(source)
        await phone.sync.synchronize()
        await tv.sync.synchronize()
        cloud.fetchFails = true

        await tv.sync.synchronize()

        #expect(tv.sources.sources.first?.isEnabled == true)
        #expect(tv.sources.sources.first?.needsSignIn == false)
    }

    @Test func cloudRecordEncryptsEverySessionFieldAndOmitsAccountToken() throws {
        var value = try session(kind: .plex)
        value.accountToken = "fixture-account-token"
        let entry = AppleCloudMediaServerSession(sourceID: UUID(), session: value)
        let record = try AppleCloudKitMediaServerSessionStore.record(for: entry)

        #expect(Set(record.encryptedValues.allKeys()) == Set(record.allKeys()))
        let payload = try #require(record.encryptedValues["payload"] as? String)
        #expect(payload.contains(value.accessToken))
        #expect(payload.contains(value.userID))
        #expect(payload.contains(entry.identity))
        #expect(!payload.contains("fixture-account-token"))
        #expect(record.encryptedValues["accountToken"] == nil)
        let decoded = try AppleCloudKitMediaServerSessionStore.session(from: record)
        #expect(decoded == entry)
        #expect(decoded.session?.accountToken == nil)
    }

    @Test func fullServerAddressOnlyReachesEncryptedFields() throws {
        let url = try #require(URL(string: "https://fixture-user:fixture-password@fixture.example/jf?password=fixture-secret#fragment"))
        let value = AppleMediaServerSession(kind: .jellyfin, baseURL: url,
            accessToken: "fixture-token", userID: "fixture-user")
        let entry = AppleCloudMediaServerSession(sourceID: UUID(), session: value)

        let record = try AppleCloudKitMediaServerSessionStore.record(for: entry)

        #expect(try AppleCloudKitMediaServerSessionStore.session(from: record).sourceURL == url)
        #expect(record.allKeys().allSatisfy { record[$0] == nil })
        #expect(try AppleCloudKitMediaServerSessionStore.session(from: record).identity == entry.identity)
    }

    @Test func localSignInDuringCloudValidationWins() async throws {
        let cloud = SessionCloudStub()
        let gate = SessionValidationGate()
        let tv = try SignInSyncDevice(cloud: cloud, publisher: false, beforeValidation: { await gate.pause() })
        defer { tv.cleanUp() }
        let localSession = try session(token: "fixture-tv-token")
        let record = AppleCloudMediaServerSession(sourceID: UUID(), session: try session())
        cloud.records[record.sourceID] = record
        try tv.receive(AppleSource(id: record.sourceID, kind: .mediaServer, name: "Rill",
            url: record.sourceURL, serverKind: .jellyfin, mediaServerIdentity: record.identity))
        let reading = Task { await tv.sync.synchronize() }
        await gate.waitUntilEntered()
        _ = try tv.sources.addMediaServer(kind: .jellyfin, name: "Rill", session: localSession)
        await gate.release()
        await reading.value

        let restored = try #require(tv.sources.sources.first)
        #expect(try tv.sources.mediaServerSession(for: restored)?.accessToken == "fixture-tv-token")
        #expect(restored.isEnabled)
        #expect(tv.diagnostics.lines.contains("source sign-in sync: import skipped reason=source-changed-during-validation"))
        #expect(tv.diagnostics.lines.contains("source sign-in sync: import validated=1 imported=0 enabled=0"))
    }

    @Test func failedSignOutIsRetriedAfterRelaunch() async throws {
        let cloud = SessionCloudStub()
        let phone = try SignInSyncDevice(cloud: cloud, publisher: true)
        defer { phone.cleanUp() }
        let source = try phone.sources.addMediaServer(kind: .jellyfin, name: "Rill", session: session())
        await phone.sync.synchronize()
        try phone.sources.signOutMediaServer(id: source.id)
        cloud.fetchFails = true
        await phone.sync.synchronize()
        let reloaded = AppleSourceStore(defaults: phone.defaults, keychain: phone.keys, documentsDirectory: phone.directory)
        let sync = AppleMediaServerSessionSync(sources: reloaded, defaults: phone.defaults,
            cloud: cloud, publishesSessions: true)
        cloud.fetchFails = false

        await sync.synchronize(enabled: false)

        #expect(cloud.records.isEmpty)
        #expect(reloaded.mediaServerSessionMutations.isEmpty)
    }

    @Test func accountSwitchDropsImportedCredentials() async throws {
        let cloud = SessionCloudStub()
        let phone = try SignInSyncDevice(cloud: cloud, publisher: true)
        let tv = try SignInSyncDevice(cloud: cloud, publisher: false)
        defer { phone.cleanUp(); tv.cleanUp() }
        let source = try phone.sources.addMediaServer(kind: .jellyfin, name: "Rill", session: session())
        try tv.receive(source)
        await phone.sync.synchronize()
        await tv.sync.synchronize()
        cloud.accountID = "fixture-other-cloud-account"
        cloud.records = [:]

        await tv.sync.synchronize()

        #expect(tv.sources.sources.first?.isEnabled == false)
        #expect(tv.sources.sources.first?.needsSignIn == true)
        #expect(tv.diagnostics.lines.contains("source sign-in sync: stopped reason=account-changed"))
    }

    @Test func wrongServerIdentityIsNeverImported() async throws {
        let cloud = SessionCloudStub()
        let tv = try SignInSyncDevice(cloud: cloud, publisher: false)
        defer { tv.cleanUp() }
        let record = AppleCloudMediaServerSession(sourceID: UUID(), session: try session())
        cloud.records[record.sourceID] = record
        try tv.receive(AppleSource(id: record.sourceID, kind: .mediaServer, name: "Rill",
            url: record.sourceURL, serverKind: .jellyfin, mediaServerIdentity: "fixture-different-identity"))

        await tv.sync.synchronize()

        #expect(tv.sources.sources.first?.needsSignIn == true)
        #expect(tv.validations.count == 0)
        #expect(tv.keys.values.isEmpty)
    }

    @Test func entitlementGateRequiresTheServiceAndExactContainer() throws {
        let entitled: [String: Any] = ["com.apple.developer.icloud-services": ["CloudKit"],
            "com.apple.developer.icloud-container-identifiers": [AppleCloudKitSignInCapabilities.containerID]]
        #expect(AppleCloudKitSignInCapabilities.permitsCloudKit(entitled))
        #expect(!AppleCloudKitSignInCapabilities.permitsCloudKit([:]))
        #expect(!AppleCloudKitSignInCapabilities.permitsCloudKit([
            "com.apple.developer.icloud-services": ["CloudKit"],
            "com.apple.developer.icloud-container-identifiers": ["iCloud.fixture.other"]]))
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/cloudkit-development-entitlements.xml")
        let xml = try Data(contentsOf: fixture)
        let signed = try #require(PropertyListSerialization.propertyList(from: xml, format: nil) as? [String: Any])
        #expect(AppleCloudKitSignInCapabilities.permitsCloudKit(signed))
        #expect(AppleCloudKitSignInCapabilities.missingCloudKitEntitlement(in: signed) == nil)
        // Signed b20r10 iOS load commands and XML blob; signature relocated, other signing slots omitted.
        let executableURL = fixture.deletingPathExtension().appendingPathExtension("macho")
        let executable = try Data(contentsOf: executableURL)
        #expect(AppleCloudKitSignInCapabilities.permitsCloudKit(AppleCloudKitSignInCapabilities.entitlements(executableURL: executableURL)))
        #expect(AppleCloudKitSignInCapabilities.permitsCloudKit(AppleCloudKitSignInCapabilities.entitlements(in: executable)))
        #expect(AppleCloudKitSignInCapabilities.entitlements(in: Data(executable.prefix(54))).isEmpty)
        #expect(AppleCloudKitSignInCapabilities.entitlements(in: Data(executable.dropLast())).isEmpty)
        #expect(AppleCloudKitSignInCapabilities.entitlements(in: Data()).isEmpty)
    }

    @Test func absentUnreadableAndUnsignedExecutablesFailClosed() {
        #expect(AppleCloudKitSignInCapabilities.entitlements(executableURL: nil).isEmpty)
        let absent = FileManager.default.temporaryDirectory.appendingPathComponent("missing-executable-\(UUID())")
        #expect(AppleCloudKitSignInCapabilities.entitlements(executableURL: absent).isEmpty)
        let unsigned = URL(fileURLWithPath: #filePath)
        #expect(AppleCloudKitSignInCapabilities.entitlements(executableURL: unsigned).isEmpty)
    }

    @Test func entitlementFailuresIdentifyTheMissingKey() {
        let service = "com.apple.developer.icloud-services"
        let container = "com.apple.developer.icloud-container-identifiers"
        #expect(AppleCloudKitSignInCapabilities.missingCloudKitEntitlement(in: [:]) == service)
        #expect(AppleCloudKitSignInCapabilities.missingCloudKitEntitlement(in: [service: ["CloudDocuments"]]) == service)
        #expect(AppleCloudKitSignInCapabilities.missingCloudKitEntitlement(in: [service: "CloudKit"]) == service)
        #expect(AppleCloudKitSignInCapabilities.missingCloudKitEntitlement(in: [service: ["CloudKit"]]) == container)
        #expect(AppleCloudKitSignInCapabilities.missingCloudKitEntitlement(in:
            [service: ["CloudKit"], container: ["iCloud.fixture.other"]]) == container)
    }

    @Test func accountFingerprintUsesOnlyEightHexCharactersOfSHA256() {
        #expect(AppleCloudKitMediaServerSessionStore.accountFingerprint("abc") == "ba7816bf")
        #expect(AppleCloudKitMediaServerSessionStore.accountFingerprint("") == "e3b0c442")
    }

    @Test func accountStatusGateNamesEveryUnavailableStatus() {
        #expect(AppleCloudKitMediaServerSessionStore.accountUnavailableReason(.available) == nil)
        #expect(AppleCloudKitMediaServerSessionStore.accountUnavailableReason(.couldNotDetermine) == "could-not-determine")
        #expect(AppleCloudKitMediaServerSessionStore.accountUnavailableReason(.restricted) == "restricted")
        #expect(AppleCloudKitMediaServerSessionStore.accountUnavailableReason(.noAccount) == "no-account")
        #expect(AppleCloudKitMediaServerSessionStore.accountUnavailableReason(.temporarilyUnavailable) == "temporarily-unavailable")
    }

    @Test func launchLocalChangesAndForegroundRunTheSyncAutomatically() async throws {
        let cloud = SessionCloudStub()
        let configuration = FakeCloudStore()
        let phone = try SignInSyncDevice(cloud: cloud, publisher: true)
        let tv = try SignInSyncDevice(cloud: cloud, publisher: false)
        defer { phone.cleanUp(); tv.cleanUp() }
        let source = try phone.sources.addMediaServer(kind: .jellyfin, name: "Rill", session: session())
        configuration.set(try AppleConfigurationSnapshot(sources: [source]).cloudData(), forKey: "openstream.configuration.v1")
        let phoneController = phone.controller(configuration: configuration, mode: .viewerChoice)
        let tvController = tv.controller(configuration: configuration, mode: .automaticReadOnly)

        await phoneController.start()
        await tvController.start()

        #expect(tv.sources.sources.first?.isEnabled == true)
        #expect(tv.sources.sources.first?.needsSignIn == false)
        #expect(tv.validations.count == 1)
        let fetches = cloud.fetches
        await phoneController.localChanged()?.value
        #expect(cloud.fetches == fetches)

        try phone.sources.signOutMediaServer(id: source.id)
        await phoneController.localChanged()?.value
        await tvController.becameActive()

        #expect(tv.sources.sources.first?.needsSignIn == true)
        #expect(tv.sources.sources.first?.isEnabled == false)
        #expect(cloud.records.isEmpty)
    }

    @Test func launchRetriesSignOutEvenWithSyncSwitchedOff() async throws {
        let cloud = SessionCloudStub()
        let phone = try SignInSyncDevice(cloud: cloud, publisher: true)
        defer { phone.cleanUp() }
        let source = try phone.sources.addMediaServer(kind: .jellyfin, name: "Rill", session: session())
        await phone.sync.synchronize()
        try phone.sources.signOutMediaServer(id: source.id)
        phone.defaults.set(false, forKey: AppleKeychainStore.syncPreferenceKey)
        let controller = phone.controller(configuration: FakeCloudStore(), mode: .viewerChoice)

        await controller.start()

        #expect(cloud.records.isEmpty)
        #expect(phone.sources.mediaServerSessionMutations.isEmpty)
    }

    @Test func locallySignedInTVSurvivesPhoneSignOut() async throws {
        let cloud = SessionCloudStub()
        let phone = try SignInSyncDevice(cloud: cloud, publisher: true)
        let tv = try SignInSyncDevice(cloud: cloud, publisher: false)
        defer { phone.cleanUp(); tv.cleanUp() }
        let source = try phone.sources.addMediaServer(kind: .jellyfin, name: "Phone", session: session())
        let local = try tv.sources.addMediaServer(kind: .jellyfin, name: "TV", session: session(token: "fixture-local"))
        try tv.receive(source)
        await phone.sync.synchronize()
        await tv.sync.synchronize()
        try phone.sources.signOutMediaServer(id: source.id)
        await phone.sync.synchronize()
        await tv.sync.synchronize()
        let restored = try #require(tv.sources.sources.first { $0.id == local.id })
        #expect(restored.isEnabled && !restored.needsSignIn)
        #expect(try tv.sources.mediaServerSession(for: restored)?.accessToken == "fixture-local")
        #expect(cloud.records.isEmpty)
    }

    @Test func rejectedRotationKeepsThePreviouslyWorkingImportedToken() async throws {
        let cloud = SessionCloudStub()
        let phone = try SignInSyncDevice(cloud: cloud, publisher: true)
        let tv = try SignInSyncDevice(cloud: cloud, publisher: false)
        defer { phone.cleanUp(); tv.cleanUp() }
        let source = try phone.sources.addMediaServer(kind: .jellyfin, name: "Phone", session: session())
        try tv.receive(source)
        await phone.sync.synchronize()
        await tv.sync.synchronize()
        tv.validations.status = 401
        cloud.records[source.id] = AppleCloudMediaServerSession(sourceID: source.id,
            session: try session(token: "fixture-rejected-rotation"))
        await tv.sync.synchronize()
        let restored = try #require(tv.sources.sources.first)
        #expect(restored.isEnabled && !restored.needsSignIn)
        #expect(try tv.sources.mediaServerSession(for: restored)?.accessToken == "fixture-phone-token")
    }

    @Test(arguments: [true, false])
    func tvSignOutCompletesDeletionAndCanReceiveALaterLogin(rotatesToken: Bool) async throws {
        let cloud = SessionCloudStub()
        let phone = try SignInSyncDevice(cloud: cloud, publisher: true)
        let tv = try SignInSyncDevice(cloud: cloud, publisher: false)
        defer { phone.cleanUp(); tv.cleanUp() }
        let source = try phone.sources.addMediaServer(kind: .jellyfin, name: "Phone", session: session())
        try tv.receive(source)
        await phone.sync.synchronize()
        await tv.sync.synchronize()
        try tv.sources.signOutMediaServer(id: source.id)
        await tv.sync.synchronize()
        #expect(tv.sources.mediaServerSessionMutations.isEmpty)
        #expect(tv.sources.sources.first?.needsSignIn == true)
        #expect(cloud.deletions.isEmpty)
        _ = try phone.sources.addMediaServer(kind: .jellyfin, name: "Phone",
            session: session(token: rotatesToken ? "fixture-later-login" : "fixture-phone-token"))
        await phone.sync.synchronize()
        await tv.sync.synchronize()
        #expect(tv.sources.sources.first?.isEnabled == true)
    }

    @Test func syncOffWithPendingDeletionCannotRevokeAnotherImportedSource() async throws {
        let cloud = SessionCloudStub()
        let device = try SignInSyncDevice(cloud: cloud, publisher: true)
        defer { device.cleanUp() }
        let first = AppleCloudMediaServerSession(sourceID: UUID(), session: try session())
        cloud.records[first.sourceID] = first
        try device.receive(AppleSource(id: first.sourceID, kind: .mediaServer, name: "Imported",
            url: first.sourceURL, serverKind: .jellyfin, mediaServerIdentity: first.identity))
        await device.sync.synchronize()
        let local = try device.sources.addMediaServer(kind: .plex, name: "Local", session: session(kind: .plex))
        try device.sources.signOutMediaServer(id: local.id)
        cloud.records.removeAll()
        await device.sync.synchronize(enabled: false)
        #expect(device.sources.sources.first { $0.id == first.sourceID }?.isEnabled == true)
    }

    @Test func poisonRecordDoesNotHideHealthyRecordsOrMasqueradeAsDeletion() throws {
        let good = AppleCloudMediaServerSession(sourceID: UUID(), session: try session())
        let goodRecord = try AppleCloudKitMediaServerSessionStore.record(for: good)
        let badID = CKRecord.ID(recordName: UUID().uuidString)
        let bad = CKRecord(recordType: "MediaServerSignInV1", recordID: badID)
        bad.encryptedValues["kind"] = "future-kind" as NSString
        let failureID = CKRecord.ID(recordName: UUID().uuidString)
        let decoded = AppleCloudKitMediaServerSessionStore.decodeRecords([
            goodRecord.recordID: .success(goodRecord), badID: .success(bad),
            failureID: .failure(URLError(.cannotDecodeContentData))])
        #expect(decoded.records == [good.sourceID: good])
        #expect(decoded.unavailableIDs == Set([try #require(UUID(uuidString: badID.recordName)),
            try #require(UUID(uuidString: failureID.recordName))]))
    }

    @Test func zoneSetupRunsOncePerLaunchAndAccount() async throws {
        AppleCloudKitMediaServerSessionStore.resetZoneSetup()
        var attempts = 0
        for account in ["fixture-a", "fixture-a", "fixture-b"] {
            try await AppleCloudKitMediaServerSessionStore.prepareZone(accountID: account) { attempts += 1 }
        }
        #expect(attempts == 2)
        AppleCloudKitMediaServerSessionStore.resetZoneSetup()
        try await AppleCloudKitMediaServerSessionStore.prepareZone(accountID: "fixture-a") { attempts += 1 }
        #expect(attempts == 3)
        AppleCloudKitMediaServerSessionStore.resetZoneSetup()
    }

    @Test func unrelatedPushReturnsNoData() async {
        #expect(await AppleMediaServerSignInNotifications.receive(["aps": ["content-available": 1]]) == false)
    }

    @Test(arguments: [AppleMediaServerKind.jellyfin, .emby, .plex], [true, false])
    func realisticPhoneSetupRestoresRecordEnableStateOnAFreshReadOnlyTV(kind: AppleMediaServerKind, enabled: Bool) async throws {
        let cloud = SessionCloudStub()
        let phone = try SignInSyncDevice(cloud: cloud, publisher: true)
        let tv = try SignInSyncDevice(cloud: cloud, publisher: false)
        defer { phone.cleanUp(); tv.cleanUp() }
        try addPhoneSources(to: phone, kind: kind)
        let nas = try #require(phone.sources.sources.first { $0.kind == .nas })
        if !enabled {
            for source in phone.sources.sources { try await phone.sources.setEnabled(false, id: source.id) }
        }
        var snapshot = AppleConfigurationSnapshot(sources: phone.sources.sources)
        // Configuration and sign-ins arrive independently; the pending toggle can predate the record.
        for index in snapshot.sources.indices { snapshot.sources[index].isEnabledAfterSignIn = !enabled }
        let snapshotData = try snapshot.cloudData()
        let text = String(decoding: snapshotData, as: UTF8.self)
        #expect(!text.contains("fixture-xtream-password") && !text.contains("fixture-smb-password") && !text.contains("fixture-guide"))
        await phone.sync.synchronize()
        #expect(cloud.records.count == 3)
        let configuration = FakeCloudStore()
        configuration.set(snapshotData, forKey: "openstream.configuration.v1")
        let controller = tv.controller(configuration: configuration, mode: .automaticReadOnly)
        await controller.start()
        #expect(tv.sources.sources.count == 3)
        #expect(tv.sources.sources.allSatisfy { $0.isEnabled == enabled && !$0.needsSignIn && !$0.needsSourceAddress })
        #expect(tv.sources.sources.allSatisfy { $0.isEnabledAfterSignIn == nil })
        #expect(tv.sources.credentialsRestoreRevision == 3)
        #expect(tv.diagnostics.lines.filter { $0 == "source sign-in sync: refresh restored sources" }.count == 3)
        let restoredLines = tv.diagnostics.lines.filter { $0.hasPrefix("source sign-in sync: credentials restored ") }
        #expect(restoredLines.count == 3)
        for source in tv.sources.sources {
            #expect(restoredLines.contains("source sign-in sync: credentials restored kind=\(source.kind.rawValue) isEnabled=\(enabled) needsSignIn=false isEnabledAfterSignIn=nil"))
        }
        let share = try #require(tv.sources.sources.first { $0.id == nas.id })
        #expect(share.url == nas.url)
        #expect(try AppleSMBEndpointPolicy.parts(from: share.url).share == "Media")
        #expect(try tv.sources.networkCredentials(for: share)?.password == "fixture-smb-password")
        let xtream = try #require(tv.sources.sources.first { $0.iptvType == .xtream })
        #expect(try tv.sources.iptvCredentials(for: xtream)?.password == "fixture-xtream-password")
        #expect(xtream.epgURL?.absoluteString == "https://fixture.example/guide?token=fixture-guide")
        #expect(tv.diagnostics.lines.allSatisfy { !$0.contains("fixture") })

        await controller.readCloud()
        #expect(tv.sources.credentialsRestoreRevision == 3)
        #expect(tv.diagnostics.lines.filter { $0 == "source sign-in sync: refresh restored sources" }.count == 3)
        let reloaded = AppleSourceStore(defaults: tv.defaults, keychain: tv.keys, documentsDirectory: tv.directory)
        #expect(reloaded.sources.allSatisfy { $0.isEnabled == enabled && !$0.needsSignIn && !$0.needsSourceAddress })

        if enabled {
            for source in tv.sources.sources { try await tv.sources.setEnabled(false, id: source.id) }
            try #require(tv.sources.sources.allSatisfy { !$0.isEnabled && !$0.needsSignIn && !$0.needsSourceAddress })
            let disabledSources = tv.sources.sources
            let validations = tv.validations.count
            for _ in 0..<3 { await controller.readCloud() }
            await controller.becameActive()
            #expect(tv.sources.sources == disabledSources)
            #expect(tv.validations.count == validations)
            #expect(tv.sources.credentialsRestoreRevision == 3)
            #expect(tv.diagnostics.lines.filter { $0.hasPrefix("source sign-in sync: credentials restored ") }.count == 3)
            #expect(tv.diagnostics.lines.filter { $0 == "source sign-in sync: refresh restored sources" }.count == 3)
        }
    }

    @Test func phoneEnableChangesReachTheTVOnceWithoutCredentialChanges() async throws {
        let cloud = SessionCloudStub()
        let phone = try SignInSyncDevice(cloud: cloud, publisher: true)
        let tv = try SignInSyncDevice(cloud: cloud, publisher: false)
        defer { phone.cleanUp(); tv.cleanUp() }
        try addPhoneSources(to: phone)
        for source in phone.sources.sources { try tv.receive(source) }
        await phone.sync.synchronize()
        await tv.sync.synchronize()
        let fingerprints = cloud.records.mapValues(\.fingerprint)

        for enabled in [false, true] {
            for source in phone.sources.sources {
                try await phone.sources.setEnabled(enabled, id: source.id, client: phone.client, plexClient: phone.plexClient)
            }
            await phone.sync.synchronize()
            #expect(cloud.records.values.allSatisfy { $0.isEnabled == enabled })
            #expect(cloud.records.mapValues(\.fingerprint) == fingerprints)
            let revision = tv.sources.credentialsRestoreRevision
            let validations = tv.validations.count
            await tv.sync.synchronize()
            #expect(tv.sources.sources.allSatisfy { $0.isEnabled == enabled && !$0.needsSignIn })
            #expect(tv.sources.credentialsRestoreRevision == revision + 3)
            #expect(tv.validations.count == validations + 1)
            let restoredSources = tv.sources.sources
            let relaunchedSync = AppleMediaServerSessionSync(sources: tv.sources, defaults: tv.defaults, cloud: cloud,
                publishesSessions: false, client: tv.client, plexClient: tv.plexClient, trace: { tv.diagnostics.record($0) })
            for _ in 0..<3 { await relaunchedSync.synchronize() }
            #expect(tv.sources.sources == restoredSources)
            #expect(tv.sources.credentialsRestoreRevision == revision + 3)
            #expect(tv.validations.count == validations + 1)
        }
        #expect(cloud.saves == 9)
        #expect(tv.diagnostics.lines.filter { $0.hasPrefix("source sign-in sync: credentials restored ") }.count == 9)
        #expect(tv.diagnostics.lines.filter { $0 == "source sign-in sync: refresh restored sources" }.count == 9)
    }

    @Test func legacyImportsRepairEnablementOnceAndPreserveLaterLocalDisables() async throws {
        let cloud = SessionCloudStub()
        let phone = try SignInSyncDevice(cloud: cloud, publisher: true)
        let tv = try SignInSyncDevice(cloud: cloud, publisher: false)
        defer { phone.cleanUp(); tv.cleanUp() }
        try addPhoneSources(to: phone)
        for source in phone.sources.sources { try tv.receive(source) }
        await phone.sync.synchronize()
        await tv.sync.synchronize()
        for source in tv.sources.sources { try await tv.sources.setEnabled(false, id: source.id) }
        let saved = try #require(tv.defaults.data(forKey: AppleMediaServerSessionSync.stateKey))
        var legacy = try #require(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        legacy.removeValue(forKey: "lastAppliedEnabled")
        tv.defaults.set(try JSONSerialization.data(withJSONObject: legacy), forKey: AppleMediaServerSessionSync.stateKey)
        let repairedSync = AppleMediaServerSessionSync(sources: tv.sources, defaults: tv.defaults, cloud: cloud,
            publishesSessions: false, client: tv.client, plexClient: tv.plexClient, trace: { tv.diagnostics.record($0) })

        await repairedSync.synchronize()

        #expect(tv.sources.sources.allSatisfy { $0.isEnabled && !$0.needsSignIn && !$0.needsSourceAddress })
        #expect(tv.sources.credentialsRestoreRevision == 6)
        #expect(tv.validations.count == 2)
        for source in tv.sources.sources { try await tv.sources.setEnabled(false, id: source.id) }
        let disabledSources = tv.sources.sources
        let relaunchedSync = AppleMediaServerSessionSync(sources: tv.sources, defaults: tv.defaults, cloud: cloud,
            publishesSessions: false, client: tv.client, plexClient: tv.plexClient, trace: { tv.diagnostics.record($0) })
        let controller = tv.controller(configuration: FakeCloudStore(), mode: .automaticReadOnly, sessionSync: relaunchedSync)
        await controller.start()
        for _ in 0..<3 { await controller.readCloud() }
        await controller.becameActive()

        #expect(tv.sources.sources == disabledSources)
        #expect(tv.validations.count == 2)
        #expect(tv.sources.credentialsRestoreRevision == 6)
        #expect(tv.diagnostics.lines.filter { $0.hasPrefix("source sign-in sync: credentials restored ") }.count == 6)
        #expect(tv.diagnostics.lines.filter { $0 == "source sign-in sync: refresh restored sources" }.count == 6)
    }

    @Test(arguments: [true, false])
    func guestShareAndCredentialFreeM3UStayUsable(merge: Bool) async throws {
        let cloud = SessionCloudStub()
        let phone = try SignInSyncDevice(cloud: cloud, publisher: true)
        let tv = try SignInSyncDevice(cloud: cloud, publisher: false)
        defer { phone.cleanUp(); tv.cleanUp() }
        let nas = try phone.sources.addNetworkShare(name: "Guest", host: "fixture.example", share: "Media", path: "Movies")
        let m3u = try phone.sources.addIPTV(name: "Free", type: .m3u, endpoint: "https://fixture.example/channels/list.m3u")
        let encoded = try AppleConfigurationSnapshot(sources: phone.sources.sources).cloudData()
        let portable = try JSONDecoder().decode(AppleConfigurationSnapshot.self, from: encoded).sources
        #expect(portable.allSatisfy { !$0.needsSignIn })
        try tv.sources.restoreConfigurationSources(portable, secrets: nil, merge: merge)
        #expect(tv.sources.sources.allSatisfy { !($0.isEnabled && $0.needsSignIn) })
        await phone.sync.synchronize()
        await tv.sync.synchronize()
        #expect(tv.sources.sources.allSatisfy { $0.isEnabled && !$0.needsSignIn })
        #expect(tv.sources.sources.first { $0.id == m3u.id }?.url == m3u.url)
        #expect(tv.sources.sources.first { $0.id == nas.id }?.url == nas.url)
    }

    @Test(arguments: [true, false], [true, false])
    func everyRestorePathEnforcesSourceInvariants(merge: Bool, withSecrets: Bool) throws {
        let cloud = SessionCloudStub()
        let phone = try SignInSyncDevice(cloud: cloud, publisher: true)
        let tv = try SignInSyncDevice(cloud: cloud, publisher: false)
        defer { phone.cleanUp(); tv.cleanUp() }
        _ = try phone.sources.addNetworkShare(name: "Guest", host: "fixture.example", share: "Media", path: "Movies")
        _ = try phone.sources.addIPTV(name: "Free", type: .m3u, endpoint: "https://fixture.example/list.m3u")
        _ = try phone.sources.addIPTV(name: "Login", type: .xtream, endpoint: "https://fixture.example",
            username: "fixture-user", password: "fixture-password")
        _ = try phone.sources.addMediaServer(kind: .plex, name: "Plex", session: session(kind: .plex))
        var incoming = AppleConfigurationSnapshot(sources: phone.sources.sources).sources
        incoming.append(AppleSource(kind: .nas, name: "Incomplete", url: try #require(URL(string: "smb://fixture.example/"))))
        try tv.sources.restoreConfigurationSources(incoming, secrets: withSecrets ? phone.sources.configurationSecrets() : nil, merge: merge)
        for source in tv.sources.sources {
            #expect(!(source.isEnabled && source.needsSignIn))
            if source.kind == .nas && source.isEnabled { #expect(throws: Never.self) { try AppleSMBEndpointPolicy.parts(from: source.url) } }
        }
        try tv.sources.refreshConfigurationKeychain()
        #expect(tv.sources.sources.allSatisfy { !($0.isEnabled && $0.needsSignIn) })
    }

    @Test func resetQueuesDeletionOfEveryCloudSourceKind() async throws {
        let cloud = SessionCloudStub()
        let phone = try SignInSyncDevice(cloud: cloud, publisher: true)
        defer { phone.cleanUp() }
        _ = try phone.sources.addMediaServer(kind: .jellyfin, name: "Server", session: session())
        _ = try phone.sources.addIPTV(name: "TV", type: .xtream, endpoint: "https://fixture.example",
            username: "fixture-user", password: "fixture-password")
        await phone.sync.synchronize()
        #expect(cloud.records.count == 2)
        _ = AppleDeviceReset.wipe(defaults: phone.defaults, domain: phone.suite, directories: [])
        let reloaded = AppleSourceStore(defaults: phone.defaults, keychain: phone.keys, documentsDirectory: phone.directory)
        let sync = AppleMediaServerSessionSync(sources: reloaded, defaults: phone.defaults, cloud: cloud, publishesSessions: true)
        await sync.synchronize(enabled: false)
        #expect(cloud.records.isEmpty)
        #expect(reloaded.mediaServerSessionMutations.isEmpty)
    }

    @Test(arguments: [true, false])
    func realEnableEntryPointRepullsOnceBeforeSigningOut(rotatedTokenAvailable: Bool) async throws {
        let cloud = SessionCloudStub()
        let phone = try SignInSyncDevice(cloud: cloud, publisher: true)
        let tv = try SignInSyncDevice(cloud: cloud, publisher: false)
        defer { phone.cleanUp(); tv.cleanUp() }
        let source = try phone.sources.addMediaServer(kind: .jellyfin, name: "Phone", session: session())
        try tv.receive(source)
        await phone.sync.synchronize()
        await tv.sync.synchronize()
        try await tv.sources.setEnabled(false, id: source.id)
        if rotatedTokenAvailable {
            cloud.records[source.id] = AppleCloudMediaServerSession(sourceID: source.id,
                session: try session(token: "fixture-rotated"))
        } else { tv.validations.status = 401 }
        let unauthorized = AppleMediaServerClient(loader: { request in
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(url: url, statusCode: 401,
                httpVersion: nil, headerFields: nil))
            return (Data(), response)
        })
        let before = cloud.fetches
        do {
            try await tv.sources.setEnabled(true, id: source.id, client: unauthorized)
            #expect(rotatedTokenAvailable)
        } catch AppleMediaServerError.invalidCredentials {
            #expect(!rotatedTokenAvailable)
        }
        #expect(cloud.fetches == before + 1)
        let restored = try #require(tv.sources.sources.first)
        #expect(restored.isEnabled == rotatedTokenAvailable)
        #expect(restored.needsSignIn == !rotatedTokenAvailable)
        if !rotatedTokenAvailable { #expect(tv.sources.mediaServerSessionMutations[source.id]?.deleted == true) }
    }

    @Test func pendingConfigurationFlushFinishesBeforeCloudKitSuspends() async throws {
        let cloud = SessionCloudStub()
        let configuration = FakeCloudStore()
        let phone = try SignInSyncDevice(cloud: cloud, publisher: true)
        defer { phone.cleanUp() }
        let source = try phone.sources.addMediaServer(kind: .jellyfin, name: "Before", session: session())
        let controller = phone.controller(configuration: configuration, mode: .viewerChoice)
        await controller.start()
        _ = try phone.sources.addMediaServer(kind: .jellyfin, name: "Pending edit", session: session(token: "fixture-new"))
        var incoming = source
        incoming.name = "Incoming setup"
        configuration.set(try AppleConfigurationSnapshot(savedAt: .now.addingTimeInterval(3_600),
            sources: [incoming]).cloudData(), forKey: "openstream.configuration.v1")
        let gate = SessionValidationGate()
        cloud.beforeFetch = { await gate.pause() }
        let reading = Task { await controller.readCloud() }
        await gate.waitUntilEntered()
        #expect(phone.sources.sources.first?.name == "Incoming setup")
        await gate.release()
        await reading.value
        cloud.beforeFetch = nil
    }

    @Test func ubiquityAccountSwitchHoldsThePhonesOldConfiguration() async throws {
        let cloud = SessionCloudStub()
        let configuration = FakeCloudStore()
        let phone = try SignInSyncDevice(cloud: cloud, publisher: true)
        defer { phone.cleanUp() }
        _ = try phone.sources.addMediaServer(kind: .jellyfin, name: "Old account", session: session())
        var identity = "fixture-account-a"
        let controller = phone.controller(configuration: configuration, mode: .viewerChoice,
            accountIdentity: { identity as NSString })
        await controller.start()
        configuration.removeObject(forKey: "openstream.configuration.v1")
        cloud.accountID = "fixture-account-b"
        cloud.records.removeAll()
        identity = "fixture-account-b"
        await controller.cloudAccountChanged()
        await controller.syncNow()
        #expect(phone.defaults.bool(forKey: AppleDeviceReset.cloudRestoreHeldKey))
        #expect(configuration.data(forKey: "openstream.configuration.v1") == nil)
        #expect(cloud.records.isEmpty)
    }

    @Test func aFailedZoneSetupCanBeRetried() async throws {
        AppleCloudKitMediaServerSessionStore.resetZoneSetup()
        await #expect(throws: URLError.self) {
            try await AppleCloudKitMediaServerSessionStore.prepareZone(accountID: "fixture-failed") {
                throw URLError(.notConnectedToInternet)
            }
        }
        var completed = false
        try await AppleCloudKitMediaServerSessionStore.prepareZone(accountID: "fixture-failed") { completed = true }
        #expect(completed)
        AppleCloudKitMediaServerSessionStore.resetZoneSetup()
    }

    @Test func duplicateServerRecordsUseTheNewestValidatedLogin() async throws {
        let cloud = SessionCloudStub()
        let tv = try SignInSyncDevice(cloud: cloud, publisher: false)
        defer { tv.cleanUp() }
        let older = AppleCloudMediaServerSession(sourceID: UUID(), session: try session(token: "fixture-old"),
            validatedAt: Date(timeIntervalSince1970: 100))
        let newer = AppleCloudMediaServerSession(sourceID: UUID(), session: try session(token: "fixture-newest"),
            validatedAt: Date(timeIntervalSince1970: 200))
        cloud.records = [older.sourceID: older, newer.sourceID: newer]
        try tv.receive(AppleSource(id: newer.sourceID, kind: .mediaServer, name: "Server", url: newer.sourceURL,
            serverKind: .jellyfin, mediaServerIdentity: newer.identity))
        await tv.sync.synchronize()
        let restored = try #require(tv.sources.sources.first)
        #expect(try tv.sources.mediaServerSession(for: restored)?.accessToken == "fixture-newest")
        #expect(tv.validations.count == 1)
    }

    @Test func revokingAnImportDoesNotDeleteThePhonesSynchronizingKeychainItem() async throws {
        let cloud = SessionCloudStub()
        let phone = try SignInSyncDevice(cloud: cloud, publisher: true)
        let tv = try SignInSyncDevice(cloud: cloud, publisher: false)
        defer { phone.cleanUp(); tv.cleanUp() }
        let source = try phone.sources.addMediaServer(kind: .jellyfin, name: "Phone", session: session())
        try tv.receive(source)
        await phone.sync.synchronize()
        await tv.sync.synchronize()
        let stable = source.id.uuidString.lowercased()
        tv.keys.set("fixture-phone-keychain-item", for: stable)
        cloud.records.removeAll()
        await tv.sync.synchronize()
        #expect(tv.keys.string(for: stable) == "fixture-phone-keychain-item")
        let restored = try #require(tv.sources.sources.first)
        #expect(!restored.isEnabled && restored.needsSignIn)
        #expect(try tv.sources.mediaServerSession(for: restored) == nil)
    }

    @Test(arguments: [true, false])
    func encryptedNASLoginReplacesACompleteGuestConfiguration(enabled: Bool) async throws {
        let cloud = SessionCloudStub()
        let phone = try SignInSyncDevice(cloud: cloud, publisher: true)
        let tv = try SignInSyncDevice(cloud: cloud, publisher: false)
        defer { phone.cleanUp(); tv.cleanUp() }
        let guest = try tv.sources.addNetworkShare(name: "Guest", host: "fixture.example", share: "Media", path: "Movies")
        try phone.sources.restoreConfigurationSources([guest], secrets: tv.sources.configurationSecrets())
        try await tv.sources.setEnabled(enabled, id: guest.id)
        _ = try phone.sources.updateNetworkShare(id: guest.id, name: "Registered", host: "fixture.example", port: 445,
            share: "Media", path: "Shows", credentials: .init(username: "fixture-user", password: "fixture-nas-password"),
            displayHost: nil, validationSummary: "Connected")
        await phone.sync.synchronize()
        await tv.sync.synchronize()
        await tv.sync.synchronize()
        let restored = try #require(tv.sources.sources.first)
        #expect(restored.url.path == "/Media/Shows")
        #expect(restored.isEnabled && !restored.needsSignIn)
        #expect(try tv.sources.networkCredentials(for: restored)?.password == "fixture-nas-password")
        #expect(tv.sources.credentialsRestoreRevision == 1)
    }

    @Test func restoreHoldDuringValidationPreventsCredentialInstallation() async throws {
        let cloud = SessionCloudStub()
        let gate = SessionValidationGate()
        let tv = try SignInSyncDevice(cloud: cloud, publisher: false, beforeValidation: { await gate.pause() })
        defer { tv.cleanUp() }
        let record = AppleCloudMediaServerSession(sourceID: UUID(), session: try session())
        cloud.records[record.sourceID] = record
        try tv.receive(AppleSource(id: record.sourceID, kind: .mediaServer, name: "Server", url: record.sourceURL,
            serverKind: .jellyfin, mediaServerIdentity: record.identity))
        let reading = Task { await tv.sync.synchronize() }
        await gate.waitUntilEntered()
        tv.defaults.set(true, forKey: AppleDeviceReset.cloudRestoreHeldKey)
        await gate.release()
        await reading.value
        #expect(tv.sources.sources.first?.isEnabled == false)
        #expect(tv.keys.values.isEmpty)
        #expect(tv.diagnostics.lines.contains("source sign-in sync: import skipped reason=restore-held"))
    }

    @Test func sessionValidationUsesABoundedRequestTimeout() async throws {
        let client = AppleMediaServerClient(loader: { request in
            #expect(request.timeoutInterval == 5)
            let url = try #require(request.url)
            return (Data(#"{"Id":"fixture-user"}"#.utf8),
                try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        })
        try await client.validateSession(session())
    }

    @Test(.timeLimit(.minutes(1))) func slowServerValidationDoesNotHoldNASOrIPTVRestoration() async throws {
        let cloud = SessionCloudStub()
        let gate = SessionValidationGate()
        let phone = try SignInSyncDevice(cloud: cloud, publisher: true)
        let tv = try SignInSyncDevice(cloud: cloud, publisher: false, beforeValidation: { await gate.pause() })
        defer { phone.cleanUp(); tv.cleanUp() }
        try addPhoneSources(to: phone)
        await phone.sync.synchronize()
        try tv.sources.restoreConfigurationSources(phone.sources.sources.map(AppleConfigurationSnapshot.portableSource), secrets: nil)
        let work = Task { await tv.sync.synchronize() }
        await gate.waitUntilEntered()
        let restored = tv.sources.sources.filter { $0.kind != .mediaServer }
        #expect(restored.count == 2)
        #expect(restored.allSatisfy { $0.isEnabled && !$0.needsSignIn })
        #expect(tv.sources.credentialsRestoreRevision > 0)
        await gate.release()
        await work.value
    }

    @Test(.timeLimit(.minutes(1))) func unavailableValidationRetriesInTheSameSession() async throws {
        let cloud = SessionCloudStub()
        let retry = SessionValidationGate()
        let phone = try SignInSyncDevice(cloud: cloud, publisher: true)
        let tv = try SignInSyncDevice(cloud: cloud, publisher: false, status: 503,
            retryWait: { _ in await retry.pause() })
        defer { phone.cleanUp(); tv.cleanUp() }
        let source = try phone.sources.addMediaServer(kind: .jellyfin, name: "Server", session: session())
        try tv.receive(source)
        await phone.sync.synchronize()
        await tv.sync.synchronize()
        #expect(tv.sources.sources.first?.needsSignIn == true)
        await retry.waitUntilEntered()
        tv.validations.status = 200
        await retry.release()
        await tv.diagnostics.wait(until: "source sign-in sync: import validated=1 imported=1 enabled=1")
        #expect(tv.sources.sources.first?.isEnabled == true)
        #expect(tv.validations.count == 2)
    }

    private func addPhoneSources(to phone: SignInSyncDevice, kind: AppleMediaServerKind = .jellyfin) throws {
        _ = try phone.sources.addMediaServer(kind: kind, name: "Server", session: session(kind: kind))
        _ = try phone.sources.addIPTV(name: "TV", type: .xtream, endpoint: "https://fixture.example/provider",
            username: "fixture-user", password: "fixture-xtream-password", epgURL: "https://fixture.example/guide?token=fixture-guide")
        _ = try phone.sources.addNetworkShare(name: "NAS", host: "fixture.example", share: "Media",
            path: "Movies", username: "fixture-user", password: "fixture-smb-password")
    }

    private func session(kind: AppleMediaServerKind = .jellyfin,
                         token: String = "fixture-phone-token") throws -> AppleMediaServerSession {
        AppleMediaServerSession(kind: kind, baseURL: try #require(URL(string: "https://fixture.example/jf")),
            accessToken: token, userID: "fixture-user", serverID: "fixture-server")
    }
}

@MainActor
private struct SignInSyncDevice {
    let suite = "encrypted-signin-sync.\(UUID())"
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("signin-sync-\(UUID())")
    let defaults: UserDefaults
    let keys = SignInSyncCredentials()
    let sources: AppleSourceStore
    let sync: AppleMediaServerSessionSync
    let validations: SessionValidationCount
    let diagnostics: SessionSyncDiagnostics
    let client: AppleMediaServerClient
    let plexClient: ApplePlexClient

    init(cloud: SessionCloudStub, publisher: Bool, status: Int = 200,
         beforeValidation: (@Sendable () async -> Void)? = nil,
         retryWait: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) throws {
        defaults = try #require(UserDefaults(suiteName: suite))
        sources = AppleSourceStore(defaults: defaults, keychain: keys, documentsDirectory: directory)
        let validations = SessionValidationCount()
        validations.status = status
        self.validations = validations
        let diagnostics = SessionSyncDiagnostics()
        self.diagnostics = diagnostics
        let loader: AppleMediaServerClient.Loader = { request in
            validations.increment()
            await beforeValidation?()
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(url: url, statusCode: validations.status,
                httpVersion: nil, headerFields: nil))
            let body = request.url?.path.contains("library/sections") == true
                ? #"{"MediaContainer":{"Directory":[]}}"# : #"{"Id":"fixture-user"}"#
            return (Data(body.utf8), response)
        }
        client = AppleMediaServerClient(loader: loader)
        plexClient = ApplePlexClient(loader: loader)
        sync = AppleMediaServerSessionSync(sources: sources, defaults: defaults, cloud: cloud,
            publishesSessions: publisher, client: client,
            plexClient: plexClient, trace: { diagnostics.record($0) }, retryWait: retryWait)
    }

    func receive(_ source: AppleSource) throws {
        try sources.restoreConfigurationSources([AppleConfigurationSnapshot.portableSource(source)], secrets: nil)
    }

    func controller(configuration: FakeCloudStore, mode: AppleConfigurationSyncMode,
                    accountIdentity: @escaping () -> NSObject? = { nil },
                    sessionSync: AppleMediaServerSessionSync? = nil) -> AppleConfigurationController {
        AppleConfigurationController(sources: sources,
            settings: AppleSettingsStore(defaults: defaults, keychain: SignInSyncCredentials()),
            mediaIndex: AppleMediaIndexStore(repository: AppleMediaIndexRepository(
                fileURL: directory.appendingPathComponent("index.json"))),
            defaults: defaults, cloud: configuration,
            lineupStore: AppleChannelLineupStore(directory: directory, latestCloudRevision: { nil }),
            syncMode: mode, sessionSync: sessionSync ?? sync, accountIdentity: accountIdentity)
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
private final class SessionSyncDiagnostics {
    var lines: [String] = []
    var summaries: [String] {
        lines.filter { $0.hasPrefix("source sign-in sync: import validated=") || $0.hasPrefix("source sign-in sync: publish candidates=") }
    }
    private var waiter: (line: String, continuation: CheckedContinuation<Void, Never>)?

    func record(_ line: String) {
        lines.append(line)
        if waiter?.line == line {
            waiter?.continuation.resume()
            waiter = nil
        }
    }

    func wait(until line: String) async {
        if lines.contains(line) { return }
        await withCheckedContinuation { waiter = (line, $0) }
    }
}

private final class SessionValidationCount: Sendable {
    private let value = Mutex(0)
    private let responseStatus = Mutex(200)
    var status: Int {
        get { responseStatus.withLock { $0 } }
        set { responseStatus.withLock { $0 = newValue } }
    }
    var count: Int { value.withLock { $0 } }
    func increment() { value.withLock { $0 += 1 } }
}

private actor SessionValidationGate {
    private var entered = false
    private var entry: CheckedContinuation<Void, Never>?
    private var resume: CheckedContinuation<Void, Never>?

    func pause() async {
        entered = true
        entry?.resume()
        entry = nil
        await withCheckedContinuation { resume = $0 }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entry = $0 }
    }
    func release() { resume?.resume(); resume = nil }
}

private final class SignInSyncCredentials: AppleCredentialStoring {
    var values: [String: String] = [:]
    func string(for account: String) -> String? { values[account] }
    func set(_ value: String, for account: String) { values[account] = value }
    func remove(_ account: String) { values[account] = nil }
}

@MainActor
private final class SessionCloudStub: AppleMediaServerSessionCloudStoring {
    var accountID: String? = "fixture-cloud-account"
    var records: [UUID: AppleCloudMediaServerSession] = [:]
    var deletions: [UUID] = []
    var fetchFails = false
    var beforeFetch: (@MainActor () async -> Void)?
    var beforeSave: (@MainActor () async -> Void)?
    var beforeDelete: (@MainActor () async -> Void)?
    var fetchError: (any Error)?
    var unavailableIDs: Set<UUID> = []
    private(set) var fetches = 0
    private(set) var saves = 0

    func fetch() async throws -> AppleMediaServerSessionCloudSnapshot? {
        fetches += 1
        await beforeFetch?()
        if let fetchError { throw fetchError }
        if fetchFails { throw URLError(.notConnectedToInternet) }
        return accountID.map { AppleMediaServerSessionCloudSnapshot(accountID: $0,
            records: records.filter { !unavailableIDs.contains($0.key) }, unavailableIDs: unavailableIDs) }
    }
    func save(_ record: AppleCloudMediaServerSession, accountID: String) async throws {
        await beforeSave?()
        saves += 1
        records[record.sourceID] = try AppleCloudKitMediaServerSessionStore.session(
            from: AppleCloudKitMediaServerSessionStore.record(for: record))
    }
    func delete(_ sourceID: UUID, accountID: String) async throws {
        await beforeDelete?()
        records[sourceID] = nil
        deletions.append(sourceID)
    }
}
