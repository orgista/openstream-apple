import Foundation
import Testing
@testable import OpenStreamApple

private final class LogoRefreshCredentialStore: AppleCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func string(for account: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return values[account]
    }

    func set(_ value: String, for account: String) throws {
        lock.lock(); defer { lock.unlock() }
        values[account] = value
    }

    func remove(_ account: String) throws {
        lock.lock(); defer { lock.unlock() }
        values[account] = nil
    }
}

private final class RequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock(); defer { lock.unlock() }
        count += 1
    }

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }
}

private let openSubtitlesManifestURL = URL(string: "https://opensubtitles-v3.strem.io/manifest.json")!
private let openSubtitlesHTTPLogo = "http://www.strem.io/images/addons/opensubtitles-logo.png"

private func manifestJSON(logo: String?, name: String = "OpenSubtitles v3", version: String = "1.0.0") -> Data {
    var object: [String: Any] = [
        "id": "org.stremio.opensubtitlesv3",
        "name": name,
        "version": version,
        "resources": ["subtitles"],
        "catalogs": [],
        "types": ["movie", "series"]
    ]
    if let logo { object["logo"] = logo }
    return try! JSONSerialization.data(withJSONObject: object)
}

private func stubManifestClient(
    returning body: Data,
    counter: RequestCounter? = nil
) -> AppleManifestClient {
    AppleManifestClient(
        loader: { url in
            counter?.increment()
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (body, response)
        },
        sleeper: { _ in }
    )
}

private func failingManifestClient(counter: RequestCounter? = nil) -> AppleManifestClient {
    AppleManifestClient(
        loader: { _ in
            counter?.increment()
            throw URLError(.cannotConnectToHost)
        },
        sleeper: { _ in }
    )
}

@MainActor
private func makeStore(
    defaults: UserDefaults,
    keychain: LogoRefreshCredentialStore,
    client: AppleManifestClient,
    backfillDelay: Duration = .seconds(60)
) -> AppleSourceStore {
    AppleSourceStore(
        defaults: defaults,
        keychain: keychain,
        documentsDirectory: FileManager.default.temporaryDirectory,
        manifestClient: client,
        logoBackfillDelay: backfillDelay
    )
}

/// The saved shape from before plain `http://` logos were accepted: the
/// manifest decoded, the logo was dropped, so the source carries `nil`.
private func storedManifestWithoutLogo() -> AppleStremioManifest {
    AppleStremioManifest(
        id: "org.stremio.opensubtitlesv3",
        name: "OpenSubtitles v3",
        version: "1.0.0",
        logoURL: nil,
        resources: ["subtitles"]
    )
}

@MainActor
private func waitUntil(
    timeout: Duration = .seconds(5),
    _ condition: @MainActor () -> Bool
) async {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !condition(), clock.now < deadline {
        try? await Task.sleep(for: .milliseconds(20))
    }
}

@Suite("Add-on logo refresh")
struct AppleSourceLogoRefreshTests {
    @MainActor
    @Test("Refreshing the manifest fills a missing logo from a plain http logo and persists it")
    func refreshFillsMissingHTTPLogo() async throws {
        let suite = "openstream-logo-refresh-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let keychain = LogoRefreshCredentialStore()
        let store = makeStore(
            defaults: defaults,
            keychain: keychain,
            client: stubManifestClient(returning: manifestJSON(logo: openSubtitlesHTTPLogo))
        )
        let saved = try store.addStremio(manifestURL: openSubtitlesManifestURL, manifest: storedManifestWithoutLogo())
        #expect(saved.logoURL == nil)
        let revision = saved.configurationRevision

        let changed = await store.refreshManifest(id: saved.id)
        #expect(changed)
        let refreshed = try #require(store.sources.first(where: { $0.id == saved.id }))
        #expect(refreshed.logoURL?.absoluteString == openSubtitlesHTTPLogo)
        #expect(refreshed.name == "OpenSubtitles v3")
        #expect(refreshed.resources == ["subtitles"])
        #expect(refreshed.capabilities == ["Subtitles"])
        #expect(refreshed.configurationRevision == revision)

        // Idempotent: the same manifest again changes nothing.
        let changedAgain = await store.refreshManifest(id: saved.id)
        #expect(!changedAgain)
        #expect(store.sources.first(where: { $0.id == saved.id }) == refreshed)

        // Persisted: a fresh store over the same defaults has the logo.
        let reloaded = makeStore(defaults: defaults, keychain: keychain, client: failingManifestClient())
        #expect(reloaded.sources.first(where: { $0.id == saved.id })?.logoURL?.absoluteString == openSubtitlesHTTPLogo)
    }

    @MainActor
    @Test("An existing https logo is kept, including when the fresh manifest has none")
    func refreshKeepsExistingHTTPSLogo() async throws {
        let suite = "openstream-logo-keep-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let keychain = LogoRefreshCredentialStore()
        let httpsLogo = "https://opensubtitles-v3.strem.io/logo.png"
        let store = makeStore(
            defaults: defaults,
            keychain: keychain,
            client: stubManifestClient(returning: manifestJSON(logo: httpsLogo))
        )
        let saved = try store.addStremio(
            manifestURL: openSubtitlesManifestURL,
            manifest: AppleStremioManifest(
                id: "org.stremio.opensubtitlesv3",
                name: "OpenSubtitles v3",
                version: "1.0.0",
                logoURL: URL(string: httpsLogo),
                resources: ["subtitles"]
            )
        )
        #expect(saved.logoURL?.absoluteString == httpsLogo)

        let changed = await store.refreshManifest(id: saved.id)
        #expect(!changed)
        #expect(store.sources.first(where: { $0.id == saved.id })?.logoURL?.absoluteString == httpsLogo)

        let manifestWithoutLogo = try JSONDecoder().decode(AppleStremioManifest.self, from: manifestJSON(logo: nil))
        #expect(manifestWithoutLogo.logoURL == nil)
        let cleared = store.applyManifest(manifestWithoutLogo, to: saved.id)
        #expect(!cleared)
        #expect(store.sources.first(where: { $0.id == saved.id })?.logoURL?.absoluteString == httpsLogo)
    }

    @MainActor
    @Test("A manifest without a logo leaves a missing logo nil")
    func refreshWithoutLogoLeavesNil() async throws {
        let suite = "openstream-logo-none-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let keychain = LogoRefreshCredentialStore()
        let store = makeStore(
            defaults: defaults,
            keychain: keychain,
            client: stubManifestClient(returning: manifestJSON(logo: nil))
        )
        let saved = try store.addStremio(manifestURL: openSubtitlesManifestURL, manifest: storedManifestWithoutLogo())

        let changed = await store.refreshManifest(id: saved.id)
        #expect(!changed)
        #expect(store.sources.first(where: { $0.id == saved.id })?.logoURL == nil)
    }

    @MainActor
    @Test("A refresh that fails in transport leaves the source untouched")
    func refreshFailsOpen() async throws {
        let suite = "openstream-logo-fail-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let keychain = LogoRefreshCredentialStore()
        let store = makeStore(defaults: defaults, keychain: keychain, client: failingManifestClient())
        let saved = try store.addStremio(manifestURL: openSubtitlesManifestURL, manifest: storedManifestWithoutLogo())

        let changed = await store.refreshManifest(id: saved.id)
        #expect(!changed)
        #expect(store.sources.first(where: { $0.id == saved.id }) == saved)
    }

    @MainActor
    @Test("An owner-named add-on gains the logo but keeps its name")
    func refreshKeepsOwnerName() async throws {
        let suite = "openstream-logo-name-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let keychain = LogoRefreshCredentialStore()
        let store = makeStore(
            defaults: defaults,
            keychain: keychain,
            client: stubManifestClient(returning: manifestJSON(logo: openSubtitlesHTTPLogo))
        )
        let saved = try store.addStremio(manifestURL: openSubtitlesManifestURL, name: "Subs")
        #expect(saved.manifestID == nil)

        let changed = await store.refreshManifest(id: saved.id)
        #expect(changed)
        let refreshed = try #require(store.sources.first(where: { $0.id == saved.id }))
        #expect(refreshed.name == "Subs")
        #expect(refreshed.manifestID == nil)
        #expect(refreshed.logoURL?.absoluteString == openSubtitlesHTTPLogo)
    }

    @MainActor
    @Test("A manifest with a different id does not take over the saved entry")
    func applyRejectsDifferentAddon() throws {
        let suite = "openstream-logo-identity-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let keychain = LogoRefreshCredentialStore()
        let store = makeStore(defaults: defaults, keychain: keychain, client: failingManifestClient())
        let saved = try store.addStremio(manifestURL: openSubtitlesManifestURL, manifest: storedManifestWithoutLogo())

        let other = AppleStremioManifest(
            id: "org.other.addon",
            name: "Other",
            logoURL: URL(string: "https://other.example/logo.png"),
            resources: ["stream"]
        )
        #expect(!store.applyManifest(other, to: saved.id))
        #expect(store.sources.first(where: { $0.id == saved.id }) == saved)
    }

    @MainActor
    @Test("Store load backfills a missing logo in the background")
    func loadBackfillsMissingLogo() async throws {
        let suite = "openstream-logo-backfill-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let keychain = LogoRefreshCredentialStore()
        let seed = makeStore(defaults: defaults, keychain: keychain, client: failingManifestClient())
        let saved = try seed.addStremio(manifestURL: openSubtitlesManifestURL, manifest: storedManifestWithoutLogo())
        #expect(saved.logoURL == nil)

        let counter = RequestCounter()
        let store = makeStore(
            defaults: defaults,
            keychain: keychain,
            client: stubManifestClient(returning: manifestJSON(logo: openSubtitlesHTTPLogo), counter: counter),
            backfillDelay: .zero
        )
        #expect(store.sources.first(where: { $0.id == saved.id })?.logoURL == nil)
        await waitUntil { store.sources.first(where: { $0.id == saved.id })?.logoURL != nil }
        #expect(store.sources.first(where: { $0.id == saved.id })?.logoURL?.absoluteString == openSubtitlesHTTPLogo)
        #expect(counter.value == 1)
        #expect(defaults.stringArray(forKey: "openstream.sources.v1.logo-backfill") == [saved.id.uuidString])

        // Persisted, and a further load has nothing left to fetch.
        let reloaded = makeStore(
            defaults: defaults,
            keychain: keychain,
            client: failingManifestClient(counter: counter),
            backfillDelay: .zero
        )
        #expect(reloaded.sources.first(where: { $0.id == saved.id })?.logoURL?.absoluteString == openSubtitlesHTTPLogo)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(counter.value == 1)
    }

    @MainActor
    @Test("A manifest that answered without a logo is not asked again on the next load")
    func backfillIsOneTimePerAnsweredManifest() async throws {
        let suite = "openstream-logo-once-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let keychain = LogoRefreshCredentialStore()
        let seed = makeStore(defaults: defaults, keychain: keychain, client: failingManifestClient())
        let saved = try seed.addStremio(manifestURL: openSubtitlesManifestURL, manifest: storedManifestWithoutLogo())

        let counter = RequestCounter()
        let first = makeStore(
            defaults: defaults,
            keychain: keychain,
            client: stubManifestClient(returning: manifestJSON(logo: nil), counter: counter),
            backfillDelay: .zero
        )
        await waitUntil { defaults.stringArray(forKey: "openstream.sources.v1.logo-backfill") != nil }
        #expect(first.sources.first(where: { $0.id == saved.id })?.logoURL == nil)
        #expect(counter.value == 1)

        let second = makeStore(
            defaults: defaults,
            keychain: keychain,
            client: stubManifestClient(returning: manifestJSON(logo: openSubtitlesHTTPLogo), counter: counter),
            backfillDelay: .zero
        )
        try? await Task.sleep(for: .milliseconds(100))
        #expect(second.sources.first(where: { $0.id == saved.id })?.logoURL == nil)
        #expect(counter.value == 1)
    }

    @MainActor
    @Test("A transport failure during backfill retries on the next load")
    func backfillRetriesAfterTransportFailure() async throws {
        let suite = "openstream-logo-retry-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let keychain = LogoRefreshCredentialStore()
        let seed = makeStore(defaults: defaults, keychain: keychain, client: failingManifestClient())
        let saved = try seed.addStremio(manifestURL: openSubtitlesManifestURL, manifest: storedManifestWithoutLogo())

        let failures = RequestCounter()
        let failing = makeStore(
            defaults: defaults,
            keychain: keychain,
            client: failingManifestClient(counter: failures),
            backfillDelay: .zero
        )
        await waitUntil { failures.value >= 1 }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(failing.sources.first(where: { $0.id == saved.id })?.logoURL == nil)
        #expect(defaults.stringArray(forKey: "openstream.sources.v1.logo-backfill") == nil)

        let store = makeStore(
            defaults: defaults,
            keychain: keychain,
            client: stubManifestClient(returning: manifestJSON(logo: openSubtitlesHTTPLogo)),
            backfillDelay: .zero
        )
        await waitUntil { store.sources.first(where: { $0.id == saved.id })?.logoURL != nil }
        #expect(store.sources.first(where: { $0.id == saved.id })?.logoURL?.absoluteString == openSubtitlesHTTPLogo)
    }

    @Test("The manifest logo sanitizer accepts http and https and rejects credentials or an empty host")
    func logoSanitizer() throws {
        func sanitized(_ value: String) -> String? {
            AppleStremioManifest(id: "id", name: "Name", logoURL: URL(string: value)).logoURL?.absoluteString
        }
        #expect(sanitized(openSubtitlesHTTPLogo) == openSubtitlesHTTPLogo)
        #expect(sanitized("https://cdn.example/logo.png") == "https://cdn.example/logo.png")
        #expect(sanitized("HTTPS://cdn.example/logo.png") != nil)
        #expect(sanitized("http://user:secret@cdn.example/logo.png") == nil)
        #expect(sanitized("https://user@cdn.example/logo.png") == nil)
        #expect(sanitized("https:///logo.png") == nil)
        #expect(sanitized("file:///tmp/logo.png") == nil)
        #expect(sanitized("data:image/png;base64,AAAA") == nil)
        #expect(AppleStremioManifest(id: "id", name: "Name", logoURL: nil).logoURL == nil)

        let decoded = try JSONDecoder().decode(AppleStremioManifest.self, from: manifestJSON(logo: openSubtitlesHTTPLogo))
        #expect(decoded.logoURL?.absoluteString == openSubtitlesHTTPLogo)
    }
}
