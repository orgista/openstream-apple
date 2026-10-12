import CryptoKit
import Foundation
import Testing
@testable import OpenStreamApple

@Suite("Set Up from iPhone: QR link")
struct AppleSetupTransferLinkTests {
    private static let key = AppleSetupTransferBase64URL.encode(Data(repeating: 7, count: 32))
    private static let session = AppleSetupTransferBase64URL.encode(Data(repeating: 3, count: 16))

    private func url(h: String = "192.168.1.20:8091", s: String = session, k: String = key,
                     c: String = "ABCD2345", extra: String = "") -> URL {
        URL(string: "openstream://send-setup?h=\(h)&s=\(s)&k=\(k)&c=\(c)\(extra)")!
    }

    @Test func aReceiverLinkRoundTrips() throws {
        let session = AppleSetupReceiveSession(now: .now)
        let link = session.link(host: "10.0.0.5", port: 8091)
        let parsed = try #require(AppleSetupTransferLink(url: link.url))
        #expect(parsed == link)
        #expect(parsed.endpoint.absoluteString == "http://10.0.0.5:8091/setup/\(session.sessionID)")
    }

    @Test(arguments: ["192.168.1.20:8091", "10.1.2.3:8091", "172.20.0.9:65535", "169.254.9.9:8091",
                      "[fd00::1]:8091", "[fe80::1]:8091", "living-room.local:8091"])
    func lanAddressesAreAccepted(_ h: String) {
        #expect(AppleSetupTransferLink(url: url(h: h)) != nil)
    }

    @Test(arguments: ["8.8.8.8:8091", "127.0.0.1:8091", "172.32.0.1:8091", "192.168.1.20:80",
                      "192.168.1.20:70000", "192.168.1.20", "example.com:8091", "[2001:db8::1]:8091",
                      "[fe80::1%25en0]:8091", "192.168.1.20:8091:1", "0x7f.0.0.1:8091", "192.168.001.020:8091x"])
    func otherHostsAreRefused(_ h: String) {
        #expect(AppleSetupTransferLink(url: url(h: h)) == nil)
    }

    @Test func badKeysSessionsAndCodesAreRefused() {
        let shortKey = AppleSetupTransferBase64URL.encode(Data(repeating: 7, count: 31))
        #expect(AppleSetupTransferLink(url: url(k: shortKey)) == nil)
        #expect(AppleSetupTransferLink(url: url(k: String(Self.key.dropLast()) + "*")) == nil)
        #expect(AppleSetupTransferLink(url: url(s: "short")) == nil)
        #expect(AppleSetupTransferLink(url: url(c: "ABCD234")) == nil)
        #expect(AppleSetupTransferLink(url: url(c: "ABCD2340")) == nil) // 0 is not in the alphabet
        #expect(AppleSetupTransferLink(url: url(extra: "&c=ABCD2345")) == nil)
        #expect(AppleSetupTransferLink(url: url(extra: "&x=1")) == nil)
        #expect(AppleSetupTransferLink(url: url(extra: "&v=2")) == nil)
        #expect(AppleSetupTransferLink(url: url(extra: "&v=1")) != nil)
    }

    @Test func missingFieldsAreRefused() {
        let base = "openstream://send-setup?"
        let parts = ["h=192.168.1.20:8091", "s=\(Self.session)", "k=\(Self.key)", "c=ABCD2345"]
        for dropped in parts.indices {
            let query = parts.enumerated().filter { $0.offset != dropped }.map(\.element).joined(separator: "&")
            #expect(AppleSetupTransferLink(url: URL(string: base + query)!) == nil)
        }
        #expect(AppleSetupTransferLink(url: URL(string: "openstream://send-setups?" + parts.joined(separator: "&"))!) == nil)
        #expect(AppleSetupTransferLink(url: URL(string: "https://send-setup?" + parts.joined(separator: "&"))!) == nil)
    }

    @Test @MainActor func theRouterHoldsAValidLinkAndIgnoresABadOne() {
        let router = AppleAppRouter()
        router.open(url(h: "8.8.8.8:8091"))
        #expect(router.setupSendLink == nil)
        #expect(router.route == nil)
        router.open(url())
        #expect(router.setupSendLink?.hostName == "192.168.1.20")
        #expect(router.route == nil)
        router.clearSetupSendLink()
        #expect(router.setupSendLink == nil)
        router.open(URL(string: "openstream://search?query=news")!)
        #expect(router.route == .search("news"))
    }
}

@Suite("Set Up from iPhone: crypto and session")
struct AppleSetupTransferSessionTests {
    private func payload(sender: String = "Fixture iPhone") -> AppleSetupTransferPayload {
        let source = AppleSource(kind: .liveTV, name: "Fixture Live", url: URL(string: "https://fixture.example/")!)
        return AppleSetupTransferPayload(
            sender: sender, snapshot: AppleConfigurationSnapshot(sources: [source]),
            secrets: AppleConfigurationSecrets(sourceCredentials: [source.id: "fixture-secret"]))
    }

    @Test func aSealedSetupOpensOnceWithTheQRKeyAndCode() throws {
        let now = Date()
        var session = AppleSetupReceiveSession(now: now)
        let link = session.link(host: "192.168.1.20", port: 8091)
        let sent = payload()
        let body = try AppleSetupTransferCrypto.sealPayload(sent, for: link)
        #expect(!String(decoding: body, as: UTF8.self).contains("fixture-secret"))
        #expect(!String(decoding: body, as: UTF8.self).contains("Fixture"))

        let opened = try session.accept(sessionID: link.sessionID, code: link.code, body: body, now: now).get()
        #expect(opened.sender == sent.sender)
        #expect(opened.snapshot.sources.map(\.id) == sent.snapshot.sources.map(\.id))
        #expect(opened.secrets == sent.secrets)
        #expect(session.accept(sessionID: link.sessionID, code: link.code, body: body, now: now) == .failure(.consumed))
    }

    @Test func aWrongCodeKeyOrSessionDoesNotOpen() throws {
        let now = Date()
        var session = AppleSetupReceiveSession(now: now)
        let link = session.link(host: "192.168.1.20", port: 8091)
        let body = try AppleSetupTransferCrypto.sealPayload(payload(), for: link)

        #expect(session.accept(sessionID: link.sessionID, code: "ZZZZ2222", body: body, now: now) == .failure(.wrongCode))
        #expect(session.accept(sessionID: link.sessionID, code: nil, body: body, now: now) == .failure(.wrongCode))
        let other = AppleSetupReceiveSession(now: now).link(host: "192.168.1.20", port: 8091)
        #expect(session.accept(sessionID: other.sessionID, code: link.code, body: body, now: now) == .failure(.unknownSession))

        // Sealed to another receiver's key, to this key with another code, or to another session id.
        let otherKey = try AppleSetupTransferCrypto.sealPayload(payload(), for: other)
        #expect(session.accept(sessionID: link.sessionID, code: link.code, body: otherKey, now: now) == .failure(.unreadable))
        let wrongCodeLink = AppleSetupTransferLink(hostName: link.hostName, port: link.port, sessionID: link.sessionID,
                                                   receiverKey: link.receiverKey, code: "ZZZZ2222")
        let wrongCode = try AppleSetupTransferCrypto.sealPayload(payload(), for: wrongCodeLink)
        #expect(session.accept(sessionID: link.sessionID, code: link.code, body: wrongCode, now: now) == .failure(.unreadable))
        #expect(session.attempts == 4)
        #expect(!session.consumed)
        #expect(session.accept(sessionID: link.sessionID, code: link.code, body: body, now: now).isSuccess)
    }

    @Test func fiveFailedTriesLockTheSession() throws {
        let now = Date()
        var session = AppleSetupReceiveSession(now: now)
        let link = session.link(host: "192.168.1.20", port: 8091)
        let body = try AppleSetupTransferCrypto.sealPayload(payload(), for: link)
        for _ in 0 ..< AppleSetupReceiveSession.maximumAttempts {
            #expect(session.accept(sessionID: link.sessionID, code: "ZZZZ2222", body: body, now: now) == .failure(.wrongCode))
        }
        #expect(session.isLocked)
        #expect(session.accept(sessionID: link.sessionID, code: link.code, body: body, now: now) == .failure(.tooManyAttempts))
        #expect(session.check(sessionID: link.sessionID, now: now) == .tooManyAttempts)
    }

    @Test func theSessionExpiresAfterTenMinutes() throws {
        let start = Date()
        var session = AppleSetupReceiveSession(now: start)
        let link = session.link(host: "192.168.1.20", port: 8091)
        let body = try AppleSetupTransferCrypto.sealPayload(payload(), for: link)
        #expect(session.check(sessionID: link.sessionID, now: start.addingTimeInterval(599)) == nil)
        let late = start.addingTimeInterval(600)
        #expect(session.check(sessionID: link.sessionID, now: late) == .expired)
        #expect(session.accept(sessionID: link.sessionID, code: link.code, body: body, now: late) == .failure(.expired))
        #expect(session.attempts == 0)
    }

    @Test func garbageBodiesCountAsTries() {
        let now = Date()
        var session = AppleSetupReceiveSession(now: now)
        let link = session.link(host: "192.168.1.20", port: 8091)
        let bad = Data(#"{"v":1,"senderKey":"AAAA","sealed":"AAAA"}"#.utf8)
        #expect(session.accept(sessionID: link.sessionID, code: link.code, body: bad, now: now) == .failure(.unreadable))
        #expect(session.accept(sessionID: link.sessionID, code: link.code, body: Data("x".utf8), now: now) == .failure(.unreadable))
        #expect(session.attempts == 2)
    }
}

@Suite("Set Up from iPhone: import")
@MainActor
struct AppleSetupTransferImportTests {
    @Test func aSentSetupImportsSourcesAndSignInsLikeABackup() async throws {
        let phone = try SetupTransferTestDevice()
        defer { phone.tearDown() }
        let provider = try phone.sources.addIPTV(name: "Provider", type: .xtream,
            endpoint: "https://fixture.example", username: "fixture-user", password: "fixture-password")
        let playlist = try phone.sources.addIPTV(name: "Playlist", type: .m3u,
            endpoint: "https://lists.fixture.example/user/pass/playlist.m3u")

        let now = Date()
        var session = AppleSetupReceiveSession(now: now)
        let link = session.link(host: "192.168.1.20", port: 8091)
        let body = try AppleSetupTransferCrypto.sealPayload(
            phone.controller.setupTransferPayload(sender: "Fixture iPhone"), for: link)
        let received = try session.accept(sessionID: link.sessionID, code: link.code, body: body, now: now).get()
        #expect(received.sender == "Fixture iPhone")

        let tv = try SetupTransferTestDevice()
        defer { tv.tearDown() }
        let count = try await tv.controller.importSetupTransfer(received)
        #expect(count == 2)
        #expect(Set(tv.sources.sources.map(\.id)) == [provider.id, playlist.id])
        #expect(tv.sources.sources.allSatisfy { !$0.needsSignIn })
        #expect(tv.sources.sources.first { $0.id == playlist.id }?.url.absoluteString
            == "https://lists.fixture.example/user/pass/playlist.m3u")
        #expect(try tv.sources.configurationSecrets().sourceCredentials[provider.id] != nil)
        #expect(tv.controller.result == "Setup imported")
    }

    @Test func theReceiverServesItsNameThenTakesOneSetupOverLoopback() async throws {
        let phone = try SetupTransferTestDevice()
        defer { phone.tearDown() }
        _ = try phone.sources.addIPTV(name: "Provider", type: .xtream,
            endpoint: "https://fixture.example", username: "fixture-user", password: "fixture-password")

        let server = AppleSetupReceiveServer(deviceName: "Fixture TV", preferredPort: 0,
                                             hostProvider: { "127.0.0.1" })
        var received: AppleSetupTransferPayload?
        var stops: [AppleSetupReceiveServer.StopReason] = []
        server.onReceive = { received = $0 }
        server.onStop = { stops.append($0) }
        let link = try await server.start()
        defer { server.stop() }

        let sender = AppleSetupTransferSender()
        #expect(try await sender.receiverName(for: link) == "Fixture TV")

        let wrong = AppleSetupTransferLink(hostName: link.hostName, port: link.port, sessionID: link.sessionID,
                                           receiverKey: link.receiverKey, code: "ZZZZ2222")
        await #expect(throws: AppleSetupTransferError.rejected(403)) {
            try await sender.send(phone.controller.setupTransferPayload(sender: "Fixture iPhone"), to: wrong)
        }
        try await sender.send(phone.controller.setupTransferPayload(sender: "Fixture iPhone"), to: link)
        #expect(received?.snapshot.sources.count == 1)
        #expect(stops == [.received])
        #expect(server.link == nil)
        await #expect(throws: AppleSetupTransferError.self) {
            try await sender.send(phone.controller.setupTransferPayload(sender: "Fixture iPhone"), to: link)
        }
    }
}

/// The owner's real setup, shaped with fake values: six add-ons, an IPTV
/// provider and an SMB NAS; Radarr, Sonarr, TMDB and gateway settings; Live
/// favourites; progress, history, ratings and a watchlist. Build 17's Apple TV
/// refused it with "Couldn't import this setup." because the Apple TV cannot
/// write to Application Support, where the media index (and the watchlist the
/// import restores into it) lived.
@Suite("Set Up from iPhone: an owner-sized setup", .serialized)
@MainActor
struct AppleSetupTransferOwnerSetupTests {
    @Test func importsOnADeviceThatCannotWriteApplicationSupport() async throws {
        let phone = try SetupTransferTestDevice()
        defer { phone.tearDown() }
        try await Self.fillLikeTheOwner(phone)
        let received = try Self.send(phone)

        // An Application Support the device may not write to, as on Apple TV.
        let locked = FileManager.default.temporaryDirectory.appending(path: "setup-locked-\(UUID())")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: locked)
        }
        let tv = try SetupTransferTestDevice(indexURL: locked.appending(path: "OpenStream/media-index-v1.json"))
        defer { tv.tearDown() }

        let count = try await tv.controller.importSetupTransfer(received)
        #expect(count == phone.sources.sources.count)
        #expect(Set(tv.sources.sources.map(\.id)) == Set(phone.sources.sources.map(\.id)))
        #expect(tv.sources.sources.allSatisfy { !$0.needsSignIn })
        #expect(tv.settings.tmdbAPIKey == "fixture-tmdb")
        #expect(tv.settings.radarrAPIKey == "fixture-radarr")
        #expect(tv.settings.radarrURL == "https://fixture.example/radarr")
        #expect(tv.settings.gatewayURL == "https://fixture.example/gateway")
        #expect(tv.settings.favoriteChannelIDs == ["fixture-channel-1", "fixture-channel-2"])
        #expect(ApplePlaybackStore(defaults: tv.defaults).progress(for: "tt0000001")?.position == 600)
        #expect(AppleTitleRatingStore(defaults: tv.defaults).rating(for: "tt0000002") == .up)
        #expect(tv.controller.result == "Setup imported")
    }

    @Test func aSourceWhoseSignInCannotBeSavedArrivesSignedOut() async throws {
        let phone = try SetupTransferTestDevice()
        defer { phone.tearDown() }
        try await Self.fillLikeTheOwner(phone)
        let received = try Self.send(phone)
        let nas = try #require(phone.sources.sources.first { $0.kind == .nas })

        let keychain = SetupTransferRefusingCredentials()
        keychain.refused = [nas.id.uuidString.lowercased()]
        let tv = try SetupTransferTestDevice(sourceKeychain: keychain)
        defer { tv.tearDown() }

        let count = try await tv.controller.importSetupTransfer(received)
        #expect(count == phone.sources.sources.count)
        #expect(Set(tv.sources.sources.map(\.id)) == Set(phone.sources.sources.map(\.id)))
        let arrived = try #require(tv.sources.sources.first { $0.id == nas.id })
        #expect(arrived.needsSignIn)
        #expect(tv.sources.sources.filter { $0.id != nas.id }.allSatisfy { !$0.needsSignIn })
    }

    @Test func theSameSetupImportsOnAnotherIPhone() async throws {
        let phone = try SetupTransferTestDevice()
        defer { phone.tearDown() }
        try await Self.fillLikeTheOwner(phone)
        let received = try Self.send(phone)
        let other = try SetupTransferTestDevice()
        defer { other.tearDown() }
        #expect(try await other.controller.importSetupTransfer(received) == phone.sources.sources.count)
        #expect(other.index.records.filter(\.isFavorite).count == 1)
        #expect(other.sources.sources.allSatisfy { !$0.needsSignIn })
    }

    private static func send(_ phone: SetupTransferTestDevice) throws -> AppleSetupTransferPayload {
        let now = Date()
        var session = AppleSetupReceiveSession(now: now)
        let link = session.link(host: "192.168.1.20", port: 8091)
        let body = try AppleSetupTransferCrypto.sealPayload(
            phone.controller.setupTransferPayload(sender: "Fixture iPhone"), for: link)
        return try session.accept(sessionID: link.sessionID, code: link.code, body: body, now: now).get()
    }

    private static func fillLikeTheOwner(_ phone: SetupTransferTestDevice) async throws {
        #if OPENSTREAM_ADDONS
        for number in 1 ... 6 {
            _ = try phone.sources.addStremio(
                manifestURL: try #require(URL(string: "https://fixture.example/addon-\(number)/manifest.json")),
                name: "Add-on \(number)")
        }
        #endif
        _ = try phone.sources.addIPTV(name: "Provider", type: .xtream, endpoint: "https://fixture.example",
                                      username: "fixture-user", password: "fixture-password")
        _ = try phone.sources.addNetworkShare(name: "NAS", host: "192.0.2.10", share: "Media",
                                              username: "fixture-user", password: "fixture-password")
        phone.settings.radarrURL = "https://fixture.example/radarr"
        phone.settings.radarrAPIKey = "fixture-radarr"
        phone.settings.sonarrURL = "https://fixture.example/sonarr"
        phone.settings.sonarrAPIKey = "fixture-sonarr"
        phone.settings.tmdbAPIKey = "fixture-tmdb"
        phone.settings.gatewayURL = "https://fixture.example/gateway"
        phone.settings.gatewayEnabled = true
        phone.settings.favoriteChannelIDs = ["fixture-channel-1", "fixture-channel-2"]
        let playback = ApplePlaybackStore(defaults: phone.defaults)
        playback.save(mediaID: "tt0000001", position: 600, duration: 6_000)
        playback.markWatched(mediaID: "tt0000002")
        AppleTitleRatingStore(defaults: phone.defaults).set(.up, for: "tt0000002")
        let record = AppleMediaRecord(canonicalID: "tt0000003", kind: .movie, title: "Fixture Movie",
            availability: [.init(instanceID: UUID(), capability: .resolvable, itemReference: "movie|tt0000003")])
        try await phone.index.upsert(record)
        try await phone.index.setFavorite(true, recordID: record.id)
    }
}

private extension Result {
    var isSuccess: Bool { if case .success = self { true } else { false } }
}

@MainActor
private struct SetupTransferTestDevice {
    let suite: String
    let defaults: UserDefaults
    let sources: AppleSourceStore
    let settings: AppleSettingsStore
    let index: AppleMediaIndexStore
    let controller: AppleConfigurationController
    let indexURL: URL

    /// `indexURL`: where the media index lives, e.g. under a folder this
    /// device may not write to (an Apple TV's Application Support).
    init(indexURL: URL? = nil, sourceKeychain: any AppleCredentialStoring = SetupTransferTestCredentials()) throws {
        suite = "setup-transfer-device.\(UUID())"
        defaults = try #require(UserDefaults(suiteName: suite))
        self.indexURL = indexURL
            ?? FileManager.default.temporaryDirectory.appending(path: "setup-transfer-index-\(UUID()).json")
        sources = AppleSourceStore(defaults: defaults, keychain: sourceKeychain,
                                   logoBackfillDelay: .seconds(3_600))
        settings = AppleSettingsStore(defaults: defaults, keychain: SetupTransferTestCredentials())
        index = AppleMediaIndexStore(repository: AppleMediaIndexRepository(fileURL: self.indexURL))
        controller = AppleConfigurationController(sources: sources, settings: settings, mediaIndex: index,
                                                  defaults: defaults, cloud: FakeCloudStore(),
                                                  backupKeys: SetupTransferNoKeys())
    }

    func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: indexURL)
    }
}

private final class SetupTransferTestCredentials: AppleCredentialStoring {
    private var values: [String: String] = [:]
    func string(for account: String) throws -> String? { values[account] }
    func set(_ value: String, for account: String) throws { values[account] = value }
    func remove(_ account: String) throws { values.removeValue(forKey: account) }
}

/// A keychain that refuses to save one account, the way a real device's
/// keychain can refuse an item.
private final class SetupTransferRefusingCredentials: AppleCredentialStoring {
    private var values: [String: String] = [:]
    var refused: Set<String> = []
    func string(for account: String) throws -> String? { values[account] }
    func set(_ value: String, for account: String) throws {
        if refused.contains(account) { throw AppleKeychainStoreError.unexpectedStatus(-25_308) }
        values[account] = value
    }
    func remove(_ account: String) throws { values.removeValue(forKey: account) }
}

private struct SetupTransferNoKeys: AppleBackupKeyStoring {
    func existingKey() throws -> SymmetricKey? { nil }
    func exportKey() throws -> SymmetricKey { throw AppleConfigurationError.backupKeyUnavailable }
}
