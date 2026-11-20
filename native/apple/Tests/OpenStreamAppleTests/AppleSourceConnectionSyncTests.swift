import Foundation
import Testing
@testable import OpenStreamApple

@MainActor
@Suite("Source connection configuration sync")
struct AppleSourceConnectionSyncTests {
    @Test(arguments: [true, false])
    func encryptedShareSurvivesLaterPlainSnapshots(merge: Bool) throws {
        let phone = try ConnectionSyncDevice()
        let tv = try ConnectionSyncDevice()
        defer { phone.cleanUp(); tv.cleanUp() }
        let original = try phone.sources.addNetworkShare(name: "Fixture", host: "fixture.example", share: "Public",
            path: "Old", username: "fixture-user", password: "fixture-password", domain: "OLD")
        let snapshot = AppleConfigurationSnapshot(sources: [original])
        try tv.sources.restoreConfigurationSources(snapshot.sources, secrets: nil)
        var privateSource = original
        privateSource.url = try AppleSMBEndpointPolicy.makeURL(host: "private.fixture.example", port: 445, share: "Private", path: "New")
        let credentials = AppleSMBCredentials(username: "fixture-cloud-user", password: "fixture-cloud-password", domain: "NEW")
        let entry = AppleCloudMediaServerSession(source: privateSource,
            credential: String(decoding: try JSONEncoder().encode(credentials), as: UTF8.self))
        try tv.sources.installCloudSourceCredentials(entry, for: try #require(tv.sources.sources.first))

        try tv.sources.restoreConfigurationSources(snapshot.sources, secrets: nil, merge: merge)

        let restored = try #require(tv.sources.sources.first)
        #expect(restored.url == privateSource.url)
        #expect(restored.connection?.username == credentials.username)
        #expect(restored.connection?.domain == credentials.domain)
        #expect(restored.connection?.requiresCredentials == true)
        #expect(!restored.usesGuestAccess)
        #expect(restored.isEnabled && !restored.needsSignIn && !restored.needsSourceAddress)
        #expect(try tv.sources.networkCredentials(for: restored) == credentials)
        let reloaded = AppleSourceStore(defaults: tv.defaults, keychain: tv.keys)
        #expect(reloaded.sources.first?.url == privateSource.url)
    }

    @Test(arguments: [true, false])
    func cloudRestoreConsumesThePendingEnablePreference(enabled: Bool) async throws {
        let phone = try ConnectionSyncDevice()
        let tv = try ConnectionSyncDevice()
        defer { phone.cleanUp(); tv.cleanUp() }
        let original = try phone.sources.addNetworkShare(name: "Fixture", host: "fixture.example", share: "Media",
            username: "fixture-user", password: "fixture-password")
        try await phone.sources.setEnabled(enabled, id: original.id)
        let snapshot = AppleConfigurationSnapshot(sources: phone.sources.sources)
        try tv.sources.restoreConfigurationSources(snapshot.sources, secrets: nil)
        let phoneSource = try #require(phone.sources.sources.first)
        let cloudEntry = try phone.sources.cloudSourceCredentials(for: phoneSource)
        let entry = try #require(cloudEntry)

        try tv.sources.installCloudSourceCredentials(entry, for: try #require(tv.sources.sources.first))

        let restored = try #require(tv.sources.sources.first)
        #expect(restored.isEnabled == enabled)
        #expect(!restored.needsSignIn && !restored.needsSourceAddress)
        #expect(restored.isEnabledAfterSignIn == nil)
    }

    @Test(arguments: ["Media Share", "live", "series"])
    func phoneSMBShareAndNestedFoldersReachTVWithoutKeychain(share: String) throws {
        let phone = try ConnectionSyncDevice()
        let tv = try ConnectionSyncDevice()
        defer { phone.cleanUp(); tv.cleanUp() }
        let original = try phone.sources.addNetworkShare(name: "Fixture NAS", host: "fixture.example", port: 1445,
            share: share, path: "Films/Family Movies/Animation", username: "fixture-user",
            password: "fixture-password", domain: "WORKGROUP", displayHost: "fixture.local")

        let data = try AppleConfigurationSnapshot(sources: phone.sources.sources).cloudData()
        let snapshot = try JSONDecoder().decode(AppleConfigurationSnapshot.self, from: data)
        try tv.sources.restoreConfigurationSources(snapshot.sources, secrets: nil)

        let restored = try #require(tv.sources.sources.first)
        let endpoint = try AppleSMBEndpointPolicy.parts(from: restored.url)
        #expect(restored.id == original.id)
        #expect(restored.name == original.name)
        #expect(restored.networkDisplayHost == "fixture.local")
        #expect(endpoint.host == "fixture.example")
        #expect(endpoint.port == 1445)
        #expect(endpoint.share == share)
        #expect(endpoint.path == "Films/Family Movies/Animation")
        #expect(restored.needsSignIn)
        #expect(restored.isEnabled == false)
        #expect(snapshot.sources.allSatisfy { !$0.isEnabled || !$0.needsSignIn })
        #expect(String(decoding: data, as: UTF8.self).contains("fixture-password") == false)
        let connection = try #require(restored.connection)
        #expect(connection.username == "fixture-user")
        #expect(connection.domain == "WORKGROUP")
        let reloaded = AppleSourceStore(defaults: tv.defaults, keychain: tv.keys)
        #expect(reloaded.sources.first?.url == original.url)
    }

    @Test func legacySnapshotWithoutConnectionKeepsLocalShareAndFolders() throws {
        let tv = try ConnectionSyncDevice()
        defer { tv.cleanUp() }
        let original = try tv.sources.addNetworkShare(name: "Fixture NAS", host: "fixture.example",
            share: "Media", path: "Films/Family", username: "fixture-user", password: "fixture-password")
        var object = try #require(JSONSerialization.jsonObject(
            with: AppleConfigurationSnapshot(sources: [original]).cloudData()) as? [String: Any])
        var sources = try #require(object["sources"] as? [[String: Any]])
        sources[0].removeValue(forKey: "connection")
        sources[0]["url"] = AppleConfigurationSnapshot.publicAddress(original.url).absoluteString
        object["sources"] = sources
        let legacy = try JSONDecoder().decode(AppleConfigurationSnapshot.self,
            from: JSONSerialization.data(withJSONObject: object))

        try tv.sources.restoreConfigurationSources(legacy.sources, secrets: nil, merge: false)

        let restored = try #require(tv.sources.sources.first)
        #expect(restored.url == original.url)
        #expect(restored.credentialReference == original.credentialReference)
        #expect(try tv.sources.networkCredentials(for: restored)?.username == "fixture-user")
        let merged = AppleConfigurationSnapshot(sources: [original]).merging(legacy)
        #expect(merged.sources.first?.url == original.url)
    }

    @Test func newerShareSelectionReplacesLocalSelectionAndKeepsPassword() throws {
        let tv = try ConnectionSyncDevice()
        defer { tv.cleanUp() }
        let original = try tv.sources.addNetworkShare(name: "Fixture NAS", host: "fixture.example",
            share: "Old", path: "Old folder", username: "fixture-user", password: "fixture-password")
        var incoming = original
        incoming.url = try AppleSMBEndpointPolicy.makeURL(host: "fixture.example", port: 445,
            share: "New", path: "New folder/Children")
        let snapshot = try JSONDecoder().decode(AppleConfigurationSnapshot.self,
            from: AppleConfigurationSnapshot(sources: [incoming]).cloudData())

        try tv.sources.restoreConfigurationSources(snapshot.sources, secrets: nil)

        let restored = try #require(tv.sources.sources.first)
        #expect(restored.url == incoming.url)
        #expect(restored.needsSignIn == false)
        #expect(try tv.sources.networkCredentials(for: restored)?.password == "fixture-password")
    }

    @Test func migratedHostOnlySMBRecordCannotEraseLocalShare() throws {
        let phone = try ConnectionSyncDevice()
        let tv = try ConnectionSyncDevice()
        defer { phone.cleanUp(); tv.cleanUp() }
        let original = try tv.sources.addNetworkShare(name: "Fixture", host: "fixture.example", share: "Media",
            path: "Films/Family", username: "fixture-user", password: "fixture-password")
        var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        legacy.removeValue(forKey: "connection")
        legacy["url"] = AppleConfigurationSnapshot.publicAddress(original.url).absoluteString
        phone.defaults.set(try JSONSerialization.data(withJSONObject: [legacy]), forKey: AppleSourceStore.defaultStorageKey)
        let migrated = AppleSourceStore(defaults: phone.defaults, keychain: phone.keys)
        let snapshot = try JSONDecoder().decode(AppleConfigurationSnapshot.self,
            from: AppleConfigurationSnapshot(sources: migrated.sources).cloudData())
        #expect(snapshot.sources.first?.url == AppleConfigurationSnapshot.unavailableSourceURL)

        try tv.sources.restoreConfigurationSources(snapshot.sources, secrets: nil)

        #expect(tv.sources.sources.first?.url == original.url)
        #expect(tv.sources.sources.first?.connection?.username == "fixture-user")
    }

    @Test(arguments: AppleMediaServerKind.allCases)
    func mediaServerURLAndAccountMetadataReachTV(kind: AppleMediaServerKind) throws {
        let phone = try ConnectionSyncDevice()
        let tv = try ConnectionSyncDevice()
        defer { phone.cleanUp(); tv.cleanUp() }
        let url = try #require(URL(string: "https://fixture.example/servers/\(kind.rawValue)/"))
        let session = AppleMediaServerSession(kind: kind, baseURL: url, accessToken: "fixture-access-token",
            userID: "fixture-user-id", serverID: "fixture-server-id", serverName: "Fixture Server",
            userName: "fixture-user-name", accountToken: "fixture-account-token")
        _ = try phone.sources.addMediaServer(kind: kind, name: "Fixture \(kind.rawValue)", session: session)
        let data = try AppleConfigurationSnapshot(sources: phone.sources.sources).cloudData()
        let snapshot = try JSONDecoder().decode(AppleConfigurationSnapshot.self, from: data)

        try tv.sources.restoreConfigurationSources(snapshot.sources, secrets: nil)

        let restored = try #require(tv.sources.sources.first)
        #expect(restored.url == url)
        #expect(restored.serverKind == kind)
        #expect(restored.needsSignIn)
        #expect(restored.isEnabled == false)
        let connection = try #require(restored.connection)
        #expect(connection.username == "fixture-user-name")
        for secret in ["fixture-access-token", "fixture-account-token", "fixture-user-id", "fixture-server-id"] {
            #expect(String(decoding: data, as: UTF8.self).contains(secret) == false)
        }
    }

    @Test(arguments: AppleIPTVSourceType.allCases)
    func publicIPTVAndGuideAddressesReachTV(type: AppleIPTVSourceType) throws {
        let phone = try ConnectionSyncDevice()
        let tv = try ConnectionSyncDevice()
        defer { phone.cleanUp(); tv.cleanUp() }
        let original = try phone.sources.addIPTV(name: "Fixture TV", type: type,
            endpoint: "https://fixture.example/television/lineup.m3u",
            username: "fixture-user", password: "fixture-password",
            epgURL: "https://fixture.example/television/guide.xml")
        let data = try AppleConfigurationSnapshot(sources: phone.sources.sources).cloudData()
        let snapshot = try JSONDecoder().decode(AppleConfigurationSnapshot.self, from: data)

        try tv.sources.restoreConfigurationSources(snapshot.sources, secrets: nil)

        let restored = try #require(tv.sources.sources.first)
        #expect(restored.url == original.url)
        #expect(restored.epgURL == original.epgURL)
        #expect(restored.needsSignIn == (type == .xtream))
        #expect(restored.isEnabled == (type == .m3u))
        if type == .xtream { #expect(restored.connection?.username == "fixture-user") }
        #expect(String(decoding: data, as: UTF8.self).contains("fixture-password") == false)
    }

    @Test(arguments: ["https://fixture.example/list.m3u?token=fixture-secret",
                      "https://fixture.example/list.m3u?u=fixture-user&p=fixture-secret",
                      "https://fixture.example/list.m3u?pass=fixture-secret",
                      "https://fixture.example/list.m3u?key=fixture-secret",
                      "https://fixture.example/list.m3u?pin=fixture-secret",
                      "https://fixture.example/list.m3u?user=fixture-user&pass=fixture-secret",
                      "https://fixture.example/list.m3u?format=fixture-secret",
                      "https://fixture.example/list.m3u#fixture-secret",
                      "https://fixture.example/fixture-secret/list.m3u",
                      "https://fixture.example/FIXTUREKEY/list.m3u",
                      "https://fixture.example/get.php?username=fixture-user&password=fixture-secret",
                      "https://fixture.example/live/fixture-user/fixture-secret/1.m3u8",
                      "https://fixture-user:fixture-secret@fixture.example/list.m3u"])
    func credentialBearingAddressesStayOut(address: String) throws {
        let source = AppleSource(kind: .liveTV, name: "Fixture", url: try #require(URL(string: address)), iptvType: .m3u)
        let data = try AppleConfigurationSnapshot(sources: [source]).cloudData()
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("fixture-secret") == false)
        #expect(text.contains("FIXTUREKEY") == false)
        let snapshot = try JSONDecoder().decode(AppleConfigurationSnapshot.self, from: data)
        #expect(snapshot.sources.first?.needsSignIn == true)
    }

    @Test(arguments: ["u=fixture-user&p=fixture-secret", "pass=fixture-secret", "key=fixture-secret", // gitleaks:allow (fixture query strings, not credentials)
                      "pin=fixture-secret", "user=fixture-user&pass=fixture-secret", "language=fixture-secret"])
    func privateGuideQueriesStayOut(query: String) throws {
        let source = AppleSource(kind: .liveTV, name: "Fixture",
            url: try #require(URL(string: "https://fixture.example/public/list.m3u")), iptvType: .m3u,
            epgURL: try #require(URL(string: "https://fixture.example/guide.xml?\(query)")))
        let data = try AppleConfigurationSnapshot(sources: [source]).cloudData()
        #expect(String(decoding: data, as: UTF8.self).contains("fixture-secret") == false)
    }

    @Test(arguments: AppleIPTVSourceType.allCases)
    func sourceAndGuideEditsHaveOneAddress(type: AppleIPTVSourceType) throws {
        let phone = try ConnectionSyncDevice()
        let tv = try ConnectionSyncDevice()
        defer { phone.cleanUp(); tv.cleanUp() }
        var incoming = try phone.sources.addIPTV(name: "Fixture", type: type,
            endpoint: "https://fixture.example/old/list.m3u", username: "fixture-user", password: "fixture-password",
            epgURL: "https://fixture.example/old/guide.xml")
        incoming.url = try #require(URL(string: "https://fixture.example/"))
        incoming.epgURL = nil
        let snapshot = try JSONDecoder().decode(AppleConfigurationSnapshot.self,
            from: AppleConfigurationSnapshot(sources: [incoming]).cloudData())

        try tv.sources.restoreConfigurationSources(snapshot.sources, secrets: nil)

        #expect(tv.sources.sources.first?.url == incoming.url)
        #expect(tv.sources.sources.first?.epgURL == nil)
    }

    @Test func encryptedAddressesTakePrecedenceOverPublicSnapshot() throws {
        let tv = try ConnectionSyncDevice()
        defer { tv.cleanUp() }
        let incoming = AppleSource(kind: .liveTV, name: "Fixture",
            url: try #require(URL(string: "https://fixture.example/public/list.m3u")), iptvType: .m3u,
            epgURL: try #require(URL(string: "https://fixture.example/public/guide.xml")))
        let address = try #require(URL(string: "https://fixture.example/list.m3u?key=fixture-secret"))
        let guide = try #require(URL(string: "https://fixture.example/guide.xml?pin=fixture-secret"))
        let secrets = AppleConfigurationSecrets(sourceAddresses: [incoming.id: address], guideAddresses: [incoming.id: guide])

        try tv.sources.restoreConfigurationSources(AppleConfigurationSnapshot(sources: [incoming]).sources, secrets: secrets)

        #expect(tv.sources.sources.first?.url == address)
        #expect(tv.sources.sources.first?.epgURL == guide)
    }

    @Test func privateAddressesRemainAvailableForEncryptedTransport() throws {
        let phone = try ConnectionSyncDevice()
        defer { phone.cleanUp() }
        let original = try phone.sources.addIPTV(name: "Fixture", type: .m3u,
            endpoint: "https://fixture.example/list.m3u?u=fixture-user&p=fixture-secret",
            epgURL: "https://fixture.example/guide.xml?pin=fixture-guide-secret")

        let secrets = try phone.sources.configurationSecrets()
        let data = try AppleConfigurationSnapshot(sources: phone.sources.sources).cloudData()

        #expect(secrets.sourceAddresses[original.id] == original.url)
        #expect(secrets.guideAddresses[original.id] == original.epgURL)
        #expect(String(decoding: data, as: UTF8.self).contains("fixture-secret") == false)
        #expect(String(decoding: data, as: UTF8.self).contains("fixture-guide-secret") == false)
    }

    @Test(arguments: ["nas", "xtream", "m3u"])
    func applyingSnapshotPreservesLocalSignInFailure(kind: String) throws {
        let tv = try ConnectionSyncDevice()
        defer { tv.cleanUp() }
        var local: AppleSource
        if kind == "nas" {
            local = try tv.sources.addNetworkShare(name: "Fixture", host: "fixture.example", share: "Media",
                username: "fixture-user", password: "fixture-password")
        } else {
            local = try tv.sources.addIPTV(name: "Fixture", type: kind == "xtream" ? .xtream : .m3u,
                endpoint: "https://fixture.example/list.m3u", username: "fixture-user", password: "fixture-password")
        }
        let incoming = AppleConfigurationSnapshot(sources: [local])
        local.needsSignIn = true
        local.isEnabled = false
        tv.defaults.set(try JSONEncoder().encode([local]), forKey: AppleSourceStore.defaultStorageKey)
        let store = AppleSourceStore(defaults: tv.defaults, keychain: tv.keys)

        try store.restoreConfigurationSources(incoming.sources, secrets: nil)

        #expect(store.sources.first?.needsSignIn == true)
        #expect(store.sources.first?.isEnabled == false)
    }

    @Test func connectionMigrationRetriesAfterKeychainUnlock() throws {
        let device = try ConnectionSyncDevice()
        defer { device.cleanUp() }
        let original = try device.sources.addNetworkShare(name: "Fixture", host: "fixture.example", share: "Media",
            username: "fixture-user", password: "fixture-password")
        var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        legacy.removeValue(forKey: "connection")
        device.defaults.set(try JSONSerialization.data(withJSONObject: [legacy]), forKey: AppleSourceStore.defaultStorageKey)
        device.keys.isLocked = true

        let locked = AppleSourceStore(defaults: device.defaults, keychain: device.keys)

        #expect(locked.sources.first?.connection == nil)
        device.keys.isLocked = false
        let unlocked = AppleSourceStore(defaults: device.defaults, keychain: device.keys)
        #expect(unlocked.sources.first?.connection?.username == "fixture-user")
    }

    @Test(arguments: AppleMediaServerKind.allCases)
    func localMediaServerSessionKeepsItsAddress(kind: AppleMediaServerKind) throws {
        let tv = try ConnectionSyncDevice()
        defer { tv.cleanUp() }
        let localURL = try #require(URL(string: "http://fixture.local:8096/server/"))
        let session = AppleMediaServerSession(kind: kind, baseURL: localURL,
            accessToken: "fixture-token", userID: "fixture-user-id", serverID: "fixture-server-id", userName: "fixture-user")
        let local = try tv.sources.addMediaServer(kind: kind, name: "TV", session: session)
        var incoming = local
        incoming.url = try #require(URL(string: "https://fixture.example/server/"))
        let data = try AppleConfigurationSnapshot(sources: [incoming]).cloudData()
        let snapshot = try JSONDecoder().decode(AppleConfigurationSnapshot.self, from: data)

        try tv.sources.restoreConfigurationSources(snapshot.sources, secrets: nil)

        let restored = try #require(tv.sources.sources.first)
        #expect(restored.url == session.baseURL)
        #expect(restored.isEnabled)
        #expect(restored.needsSignIn == false)
        #expect(try tv.sources.mediaServerSession(for: restored) == session)
        let localSnapshot = AppleConfigurationSnapshot(sources: [local])
        #expect(String(decoding: try localSnapshot.cloudData(), as: UTF8.self).contains(localURL.absoluteString))
    }

    @Test(arguments: ["file:///fixture-private-folder/lineup.m3u", "openstream-playlist://local/fixture-private-folder"])
    func localPathsStayOnTheirDevice(address: String) throws {
        let tv = try ConnectionSyncDevice()
        defer { tv.cleanUp() }
        let source = AppleSource(kind: address.hasPrefix("file:") ? .library : .liveTV, name: "Fixture",
            url: try #require(URL(string: address)))
        let data = try AppleConfigurationSnapshot(sources: [source]).cloudData()
        #expect(String(decoding: data, as: UTF8.self).contains("fixture-private-folder") == false)
        let snapshot = try JSONDecoder().decode(AppleConfigurationSnapshot.self, from: data)
        #expect(snapshot.sources.first?.connection == nil)

        try tv.sources.restoreConfigurationSources(snapshot.sources, secrets: nil)

        let restored = try #require(tv.sources.sources.first)
        #expect(restored.isEnabled == false)
        #expect(restored.needsSignIn)
        #expect(restored.url.isFileURL == false)
        #expect(AppleLocalPlaylistStore.isLocal(restored.url) == false)
    }

    @Test func guestShareArrivesEnabledWithACompletePath() throws {
        let phone = try ConnectionSyncDevice()
        let tv = try ConnectionSyncDevice()
        defer { phone.cleanUp(); tv.cleanUp() }
        let original = try phone.sources.addNetworkShare(name: "Fixture", host: "fixture.example", share: "Media", path: "Films")
        let snapshot = try JSONDecoder().decode(AppleConfigurationSnapshot.self,
            from: AppleConfigurationSnapshot(sources: [original]).cloudData())

        try tv.sources.restoreConfigurationSources(snapshot.sources, secrets: nil)

        let restored = try #require(tv.sources.sources.first)
        #expect(restored.url == original.url)
        #expect(restored.isEnabled)
        #expect(restored.needsSignIn == false)
        #expect(try AppleSMBEndpointPolicy.parts(from: restored.url).share == "Media")
    }

    @Test(arguments: AppleSourceKind.allCases)
    func existingInstallsMigrateNonsecretKeychainFields(kind: AppleSourceKind) throws {
        let device = try ConnectionSyncDevice()
        defer { device.cleanUp() }
        let original: AppleSource
        switch kind {
        case .nas:
            original = try device.sources.addNetworkShare(name: "Fixture", host: "fixture.example", share: "Media",
                path: "Films", username: "fixture-user", password: "fixture-password")
        case .liveTV:
            original = try device.sources.addIPTV(name: "Fixture", type: .xtream,
                endpoint: "https://fixture.example/television", username: "fixture-user", password: "fixture-password")
        case .mediaServer:
            original = try device.sources.addMediaServer(kind: .jellyfin, name: "Fixture",
                session: .init(kind: .jellyfin, baseURL: try #require(URL(string: "https://fixture.example/jf")),
                    accessToken: "fixture-token", userID: "fixture-id", userName: "fixture-user"))
        case .library:
            original = try device.sources.addLibraryFolder(name: "Fixture",
                url: FileManager.default.temporaryDirectory.appendingPathComponent("Fixture-\(UUID())"), bookmarkData: nil)
        }
        let persisted = try #require(device.defaults.data(forKey: AppleSourceStore.defaultStorageKey))
        var fields = try #require(JSONSerialization.jsonObject(with: persisted) as? [[String: Any]])
        fields[0].removeValue(forKey: "connection")
        device.defaults.set(try JSONSerialization.data(withJSONObject: fields), forKey: AppleSourceStore.defaultStorageKey)

        let reloaded = AppleSourceStore(defaults: device.defaults, keychain: device.keys)
        let snapshot = try JSONDecoder().decode(AppleConfigurationSnapshot.self,
            from: AppleConfigurationSnapshot(sources: reloaded.sources).cloudData())

        #expect(snapshot.sources.first?.url == (kind == .library ? AppleConfigurationSnapshot.unavailableSourceURL : original.url))
        #expect(snapshot.sources.first?.connection?.username == (kind == .library ? nil : "fixture-user"))
    }

    @Test func missingConnectionFieldsKeepLocalValues() throws {
        let device = try ConnectionSyncDevice()
        defer { device.cleanUp() }
        let original = try device.sources.addIPTV(name: "Fixture", type: .m3u,
            endpoint: "https://fixture.example/public/list.m3u", epgURL: "https://fixture.example/public/guide.xml")
        var object = try #require(JSONSerialization.jsonObject(
            with: AppleConfigurationSnapshot(sources: [original]).cloudData()) as? [String: Any])
        var sources = try #require(object["sources"] as? [[String: Any]])
        sources[0]["connection"] = [:] as [String: Any]
        object["sources"] = sources
        let legacy = try JSONDecoder().decode(AppleConfigurationSnapshot.self,
            from: JSONSerialization.data(withJSONObject: object))

        try device.sources.restoreConfigurationSources(legacy.sources, secrets: nil)

        let restored = try #require(device.sources.sources.first)
        #expect(restored.url == original.url)
        #expect(restored.epgURL == original.epgURL)
        #expect(restored.connection == original.connection)
    }

    @Test(arguments: AppleSourceKind.allCases)
    func cloudBlobNeverContainsPasswordsOrTokens(kind: AppleSourceKind) throws {
        let phone = try ConnectionSyncDevice()
        defer { phone.cleanUp() }
        switch kind {
        case .nas:
            _ = try phone.sources.addNetworkShare(name: "Fixture", host: "fixture.example", share: "Media",
                username: "fixture-user", password: "fixture-password")
        case .liveTV:
            _ = try phone.sources.addIPTV(name: "Fixture", type: .xtream,
                endpoint: "https://fixture.example/list?key=fixture-url-secret", username: "fixture-user", password: "fixture-password",
                epgURL: "https://fixture.example/guide?pin=fixture-guide-secret")
        case .mediaServer:
            _ = try phone.sources.addMediaServer(kind: .jellyfin, name: "Fixture",
                session: .init(kind: .jellyfin, baseURL: try #require(URL(string: "https://fixture.example/jf")),
                    accessToken: "fixture-access-token", userID: "fixture-user-id", accountToken: "fixture-account-token"))
        case .library:
            _ = try phone.sources.addLibraryFolder(name: "Fixture",
                url: URL(fileURLWithPath: "/fixture-private-folder"), bookmarkData: Data("fixture-bookmark-secret".utf8))
        }
        let text = String(decoding: try AppleConfigurationSnapshot(sources: phone.sources.sources).cloudData(), as: UTF8.self)
        for secret in ["fixture-password", "fixture-url-secret", "fixture-guide-secret", "fixture-access-token",
                       "fixture-account-token", "fixture-bookmark-secret", "fixture-private-folder"] {
            #expect(text.contains(secret) == false)
        }
    }

    @Test func hostOnlySMBSourceNeverArrivesEnabled() throws {
        let tv = try ConnectionSyncDevice()
        defer { tv.cleanUp() }
        let source = AppleSource(kind: .nas, name: "Fixture", url: try #require(URL(string: "smb://fixture.example/")))

        try tv.sources.restoreConfigurationSources([source], secrets: nil)

        #expect(tv.sources.sources.first?.isEnabled == false)
        #expect(tv.sources.sources.first?.needsSignIn == true)
    }

    @Test func cloudEncodingScrubsSourcesAssignedAfterCapture() throws {
        var snapshot = AppleConfigurationSnapshot()
        snapshot.sources = [AppleSource(kind: .liveTV, name: "Fixture",
            url: try #require(URL(string: "https://fixture.example/list?u=fixture-user&p=fixture-secret")),
            epgURL: try #require(URL(string: "https://fixture.example/guide?key=fixture-secret")))]

        let text = String(decoding: try snapshot.cloudData(), as: UTF8.self)

        #expect(text.contains("fixture-secret") == false)
    }

    @Test func networkSignInUsesTheSyncedDomain() throws {
        let phone = try ConnectionSyncDevice()
        let tv = try ConnectionSyncDevice()
        defer { phone.cleanUp(); tv.cleanUp() }
        let original = try phone.sources.addNetworkShare(name: "Fixture", host: "fixture.example", share: "Media",
            username: "fixture-user", password: "fixture-password", domain: "FIXTURE")
        try tv.sources.restoreConfigurationSources(AppleConfigurationSnapshot(sources: [original]).sources, secrets: nil)

        try tv.sources.restoreSourceSignIn(id: original.id, address: original.url, username: "fixture-user", password: "fixture-password")

        let restored = try #require(tv.sources.sources.first)
        #expect(try tv.sources.networkCredentials(for: restored)?.domain == "FIXTURE")
    }

    @Test(arguments: [true, false])
    func encryptedRestoreKeepsTheEnablePreference(enabled: Bool) async throws {
        let phone = try ConnectionSyncDevice()
        let tv = try ConnectionSyncDevice()
        defer { phone.cleanUp(); tv.cleanUp() }
        let original = try phone.sources.addNetworkShare(name: "Fixture", host: "fixture.example", share: "Media",
            username: "fixture-user", password: "fixture-password")
        try await phone.sources.setEnabled(enabled, id: original.id)
        let data = try AppleConfigurationSnapshot(sources: phone.sources.sources).cloudData()
        let snapshot = try JSONDecoder().decode(AppleConfigurationSnapshot.self, from: data)

        try tv.sources.restoreConfigurationSources(snapshot.sources, secrets: phone.sources.configurationSecrets())

        let restored = try #require(tv.sources.sources.first)
        #expect(restored.needsSignIn == false)
        #expect(restored.isEnabled == enabled)
        #expect(restored.isEnabledAfterSignIn == nil)
    }
}

@MainActor
private struct ConnectionSyncDevice {
    let suite = "source-connection-sync.\(UUID())"
    let defaults: UserDefaults
    let keys = ConnectionSyncCredentials()
    let sources: AppleSourceStore

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
        sources = AppleSourceStore(defaults: defaults, keychain: keys)
    }

    func cleanUp() { defaults.removePersistentDomain(forName: suite) }
}

private final class ConnectionSyncCredentials: AppleCredentialStoring {
    private var values: [String: String] = [:]
    var isLocked = false
    func string(for account: String) throws -> String? {
        if isLocked { throw AppleKeychainStoreError.invalidData }
        return values[account]
    }
    func set(_ value: String, for account: String) throws { values[account] = value }
    func remove(_ account: String) throws { values.removeValue(forKey: account) }
}
