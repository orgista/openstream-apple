import Foundation
import CryptoKit
import Testing
@testable import OpenStreamApple

private final class AuditCredentialStore: AppleCredentialStoring {
    var values: [String: String] = [:]

    func string(for account: String) throws -> String? { values[account] }
    func set(_ value: String, for account: String) throws { values[account] = value }
    func remove(_ account: String) throws { values.removeValue(forKey: account) }
}

@MainActor
@Suite struct AppleSecurityAuditFixesTests {
    @Test func cachedMetadataDropsAuthenticatedURLsButKeepsPublicArtwork() throws {
        let item = AppleCatalogItem(mediaID: "fixture", type: "movie", name: "Fixture",
            posterURL: URL(string: "https://fixture.example/image?X-Plex-Token=fixture-secret"),
            backgroundURL: URL(string: "https://fixture.example/image?width=900"),
            logoURL: URL(string: "https://fixture.example/image?api_key=fixture-secret"))
        let data = try AppleCachedCredentialPolicy.metadata(JSONEncoder().encode(item))
        let cached = try JSONDecoder().decode(AppleCatalogItem.self, from: data)
        #expect(cached.posterURL == nil)
        #expect(cached.logoURL == nil)
        #expect(cached.backgroundURL == item.backgroundURL)
        #expect(!String(decoding: data, as: UTF8.self).contains("fixture-secret"))
        #expect(AppleCachedCredentialPolicy.artwork(URL(string: "https://fixture.example/live/user/pass/image")) == nil)
    }

    @Test func mediaIndexCacheDoesNotRetainServerTokensAndMigratesOldCopies() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("index.json")
        let tokenURL = URL(string: "https://fixture.example/image?api_key=fixture-secret")!
        let record = AppleMediaRecord(kind: .movie, title: "Fixture", artworkURL: tokenURL,
            availability: [.init(instanceID: UUID(), capability: .resolvable, itemReference: "fixture")])
        let repository = AppleMediaIndexRepository(fileURL: url)
        try await repository.upsert(record)
        #expect(!(try String(contentsOf: url, encoding: .utf8)).contains("fixture-secret"))
        #expect(await repository.records().first?.artworkURL == tokenURL, "live artwork remains authenticated")
        var legacy = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var records = try #require(legacy["records"] as? [[String: Any]])
        records[0]["artworkURL"] = tokenURL.absoluteString
        legacy["records"] = records
        try JSONSerialization.data(withJSONObject: legacy).write(to: url)
        let reloaded = AppleMediaIndexRepository(fileURL: url)
        #expect(await reloaded.records().first?.artworkURL == nil)
        #expect(!(try String(contentsOf: url, encoding: .utf8)).contains("fixture-secret"))
    }

    @Test func resumeDataIsSealedAndLegacyCopyIsReplaced() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture.resume")
        let payload = try PropertyListSerialization.data(fromPropertyList: [
            "NSURLSessionResumeOriginalRequest": Data("https://fixture.example/video?api_key=fixture-secret".utf8),
            "Authorization": "Bearer fixture-secret"], format: .binary, options: 0)
        // A legacy URLSession plist must migrate without altering its opaque request bytes.
        try payload.write(to: url)
        let key = Data(repeating: 42, count: 32)
        #expect(try AppleDownloadResumePersistence.read(url, key: key) == payload)
        let stored = try Data(contentsOf: url)
        #expect(stored != payload)
        #expect(stored.range(of: Data("fixture-secret".utf8)) == nil)
        #expect(try AppleDownloadResumePersistence.read(url, key: key) == payload)
        #expect(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        var damaged = stored
        damaged[damaged.count - 1] ^= 1
        try damaged.write(to: url)
        #expect(throws: CryptoKitError.authenticationFailure) { try AppleDownloadResumePersistence.read(url, key: key) }
    }

    private static let guide = "https://iptv.fixture.example/xmltv.php?username=fixture-user&password=fixture-password"

    private func makeDefaults() throws -> (UserDefaults, String) {
        let name = "AppleSecurityAuditFixesTests.\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: name)), name)
    }

    private func blobText(_ defaults: UserDefaults) throws -> String {
        let data = try #require(defaults.data(forKey: "openstream.sources.v1"))
        return try #require(String(data: data, encoding: .utf8))
    }

    @Test func guideAddressLivesInKeychainNotInDefaults() throws {
        let (defaults, name) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let keychain = AuditCredentialStore()
        let store = AppleSourceStore(defaults: defaults, keychain: keychain)
        let source = try store.addIPTV(
            name: "TV", type: .xtream, endpoint: "https://iptv.fixture.example",
            username: "fixture-user", password: "fixture-password", epgURL: Self.guide)

        let text = try blobText(defaults)
        #expect(!text.contains("fixture-password"))
        #expect(!text.contains("xmltv"))
        #expect(!text.contains("epgURL"))
        #expect(keychain.values[AppleSourceStore.guideReference(source.id)] == Self.guide)

        let reloaded = AppleSourceStore(defaults: defaults, keychain: keychain)
        #expect(reloaded.sources.first?.epgURL?.absoluteString == Self.guide)
        #expect(try reloaded.configurationSecrets().guideAddresses[source.id]?.absoluteString == Self.guide)
    }

    @Test func savedBlobWithGuideAddressIsMigratedOnLoad() throws {
        let (defaults, name) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let keychain = AuditCredentialStore()
        let source = try AppleSourceStore(defaults: defaults, keychain: keychain).addIPTV(
            name: "TV", type: .xtream, endpoint: "https://iptv.fixture.example",
            username: "fixture-user", password: "fixture-password")
        // Rebuild the pre-fix blob: the guide address stored inline, nothing in the Keychain.
        let data = try #require(defaults.data(forKey: "openstream.sources.v1"))
        var members = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        members[0]["epgURL"] = Self.guide
        defaults.set(try JSONSerialization.data(withJSONObject: members), forKey: "openstream.sources.v1")
        #expect(try blobText(defaults).contains("fixture-password"))

        let migrated = AppleSourceStore(defaults: defaults, keychain: keychain)
        #expect(migrated.sources.first?.epgURL?.absoluteString == Self.guide)
        #expect(keychain.values[AppleSourceStore.guideReference(source.id)] == Self.guide)
        #expect(!(try blobText(defaults)).contains("fixture-password"))
        #expect(!(try blobText(defaults)).contains("epgURL"))
    }

    @Test func clearingGuideAddressRemovesKeychainEntry() throws {
        let (defaults, name) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let keychain = AuditCredentialStore()
        let store = AppleSourceStore(defaults: defaults, keychain: keychain)
        let source = try store.addIPTV(
            name: "TV", type: .xtream, endpoint: "https://iptv.fixture.example",
            username: "fixture-user", password: "fixture-password", epgURL: Self.guide)
        _ = try store.addIPTV(
            name: "TV", type: .xtream, endpoint: "https://iptv.fixture.example",
            username: "fixture-user", password: "fixture-password", epgURL: nil)

        #expect(keychain.values[AppleSourceStore.guideReference(source.id)] == nil)
        #expect(AppleSourceStore(defaults: defaults, keychain: keychain).sources.first?.epgURL == nil)
    }

    @Test func redactorCoversSchemelessXtreamPathsAndBearerTokens() {
        let line = "load iptv.fixture.example:8080/live/fixture-user/fixture-password/42.ts; Authorization: Bearer abc.def-123 done"
        let redacted = AppleDiagnosticsReport.redactLine(line)
        #expect(!redacted.contains("fixture-user"))
        #expect(!redacted.contains("fixture-password"))
        #expect(!redacted.contains("abc.def-123"))
        #expect(redacted.contains("/live/[REDACTED]/[REDACTED]/42.ts"))
        #expect(!AppleDiagnosticRedactor.redact("GET host/series/user-a/pass-b/1.mkv").contains("pass-b"))
    }

    @Test func errorDescriptionsInTracesCarryNoStreamURL() {
        let failing = "https://iptv.fixture.example/live/fixture-user/fixture-password/42.ts"
        let error = URLError(.timedOut, userInfo: [NSURLErrorFailingURLStringErrorKey: failing])
        #expect("\(error)".contains("fixture-password"))
        #expect(!AppleDiagnosticRedactor.describe(error).contains("fixture-password"))
    }

    @Test func gzipSubtitleInflationStopsAtTheCap() throws {
        func gzip(_ payload: Data) throws -> Data {
            let deflated = try (payload as NSData).compressed(using: .zlib) as Data
            return Data([0x1f, 0x8b, 0x08, 0, 0, 0, 0, 0, 0, 0xff]) + deflated + Data(repeating: 0, count: 8)
        }
        let small = Data("1\n00:00:01,000 --> 00:00:02,000\nHello\n".utf8)
        #expect(AppleSubtitleTextParser.decompressedIfNeeded(try gzip(small)) == small)

        let bomb = try gzip(Data(count: AppleSubtitleTextParser.maximumInflatedBytes + 1_000_000))
        #expect(bomb.count < 1_000_000)
        #expect(AppleSubtitleTextParser.decompressedIfNeeded(bomb) == bomb)
        #expect(AppleSubtitleTextParser.inflate(Data([0x01, 0x02, 0x03]), limit: 1_000) == nil)
    }

    @Test func encodedPlaylistNamesCannotEscapeTheOwnedDirectory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = AppleLocalPlaylistStore(directory: directory)
        for text in ["openstream-playlist://local/..%2Foutside.m3u", "openstream-playlist://local/%2Ftmp%2Foutside.m3u",
                     "openstream-playlist://local/..", "openstream-playlist://local/%E2%98%83.m3u"] {
            let file = store.fileURL(for: try #require(URL(string: text)))
            #expect(file.standardizedFileURL.deletingLastPathComponent().path == directory.standardizedFileURL.path)
            #expect(!file.lastPathComponent.contains("/"))
        }
        #expect(store.fileURL(for: AppleLocalPlaylistStore.pastedURL).lastPathComponent == "pasted.m3u")
    }

    @Test func remoteMediaExtensionsCannotBecomePathComponents() {
        #expect(AppleOfflineMediaStore.safeMediaExtension("M4V") == "m4v")
        #expect(AppleOfflineMediaStore.safeMediaExtension("mkv") == "mkv")
        for value in ["", "../mp4", "mp4/../../outside", "mp4%2Foutside", "☃", String(repeating: "a", count: 100)] {
            #expect(AppleOfflineMediaStore.safeMediaExtension(value) == "media")
        }
    }
}
