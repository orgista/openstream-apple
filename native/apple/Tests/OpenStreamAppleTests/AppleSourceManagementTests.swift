import Foundation
import Testing
@testable import OpenStreamApple

@MainActor
@Test func importedLibraryRelocatesAfterSandboxChangeWithoutLosingIdentity() async throws {
    let suite = "openstream-import-relocation-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    let documents = root.appendingPathComponent("Documents", isDirectory: true)
    let imports = documents.appendingPathComponent("Imports", isDirectory: true)
    try FileManager.default.createDirectory(at: imports, withIntermediateDirectories: true)
    try Data([0, 1, 2]).write(to: imports.appendingPathComponent("Sample.mp4"))
    let old = AppleSource(kind: .library, name: "Imports",
        url: URL(fileURLWithPath: "/private/var/mobile/Containers/Data/Application/\(UUID())/Documents/Imports", isDirectory: true))
    defaults.set(try JSONEncoder().encode([old]), forKey: "openstream.sources.v1")
    let store = AppleSourceStore(defaults: defaults, documentsDirectory: documents)
    let migrated = try #require(store.sources.first)
    #expect(migrated.id == old.id)
    #expect(migrated.url == imports)
    #expect(migrated.isManagedImports)
    let items = try await AppleLibraryScanner().scan(source: migrated)
    #expect(items.map(\.id) == ["\(old.id.uuidString):Sample.mp4"])
    let granted = try store.addLibraryFolder(name: "Imports", url: imports, bookmarkData: Data([9]))
    #expect(granted.id == old.id)
    #expect(granted.bookmarkData == nil)
    #expect(store.sources.count == 1)
    let nextDocuments = root.appendingPathComponent("NextDocuments", isDirectory: true)
    let reloaded = AppleSourceStore(defaults: defaults, documentsDirectory: nextDocuments)
    #expect(reloaded.sources.first?.id == old.id)
    #expect(reloaded.sources.first?.url == nextDocuments.appendingPathComponent("Imports", isDirectory: true))
}

@MainActor
@Test func importedLibraryRelocationPreservesExternalAndBookmarkedFolders() throws {
    let suite = "openstream-import-external-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let external = AppleSource(kind: .library, name: "Imports", url: URL(fileURLWithPath: "/Volumes/External/Imports"))
    let bookmarked = AppleSource(kind: .library, name: "Imports",
        url: URL(fileURLWithPath: "/private/var/mobile/Containers/Data/Application/\(UUID())/Documents/Imports"),
        bookmarkData: Data([1]))
    defaults.set(try JSONEncoder().encode([external, bookmarked]), forKey: "openstream.sources.v1")
    let store = AppleSourceStore(defaults: defaults, documentsDirectory: URL(fileURLWithPath: "/tmp/new-documents"))
    #expect(store.sources.first(where: { $0.id == external.id }) == external)
    #expect(store.sources.first(where: { $0.id == bookmarked.id }) == bookmarked)
}

@Test func manifestURLPolicyMatchesTheTrustedLANSetupRules() throws {
    #expect(try AppleManifestURLPolicy.normalize(" https://addon.example ").absoluteString ==
        "https://addon.example/manifest.json")
    #expect(try AppleManifestURLPolicy.normalize("https://addon.example/custom/manifest.json").absoluteString ==
        "https://addon.example/custom/manifest.json")
    #expect(try AppleManifestURLPolicy.normalize("http://127.0.0.1:8765/addon/manifest.json").absoluteString ==
        "http://127.0.0.1:8765/addon/manifest.json")

    #expect(throws: AppleManifestURLPolicy.Error.missingScheme) {
        try AppleManifestURLPolicy.normalize("addon.example/manifest.json")
    }
    #expect(throws: AppleManifestURLPolicy.Error.insecureHTTP) {
        try AppleManifestURLPolicy.normalize("http://addon.example/manifest.json")
    }
    #expect(throws: AppleManifestURLPolicy.Error.credentialsNotAllowed) {
        try AppleManifestURLPolicy.normalize("https://user:pass@addon.example/manifest.json")
    }
    #expect(throws: AppleManifestURLPolicy.Error.queryNotAllowed) {
        try AppleManifestURLPolicy.normalize("https://addon.example/manifest.json?token=secret")
    }
    #expect(throws: AppleManifestURLPolicy.Error.fragmentNotAllowed) {
        try AppleManifestURLPolicy.normalize("https://addon.example/manifest.json#setup")
    }
    #expect(throws: AppleManifestURLPolicy.Error.wrongJSONDocument("catalog.json")) {
        try AppleManifestURLPolicy.normalize("https://addon.example/catalog.json")
    }
}

@MainActor
@Test func sourceStorePersistsAndDeduplicatesManifests() throws {
    let suiteName = "openstream-source-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = AppleSourceStore(defaults: defaults)
    let first = try store.addStremio(
        manifestURL: AppleManifestURLPolicy.normalize("https://addon.example"),
        name: "Example"
    )
    let duplicate = try store.addStremio(
        manifestURL: AppleManifestURLPolicy.normalize("https://addon.example/manifest.json"),
        name: "Renamed"
    )

    #expect(first.id == duplicate.id)
    #expect(store.sources.count == 1)
    #expect(store.sources[0].name == "Renamed")
    #expect(store.sources[0].configurationRevision == 2)

    let reloaded = AppleSourceStore(defaults: defaults)
    #expect(reloaded.sources == store.sources)

    reloaded.remove(id: first.id)
    #expect(reloaded.sources.isEmpty)
}

@MainActor
@Test func validatedManifestReplacesTheSameProviderIdentityAndKeepsCapabilities() async throws {
    let suiteName = "openstream-manifest-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = AppleSourceStore(defaults: defaults)

    let firstData = Data(#"""
    {
      "id":"org.example.addon",
      "name":"Example Add-on",
      "version":"1.2.3",
      "logo":"https://img.example/addon.png",
      "resources":["catalog",{"name":"stream"}],
      "catalogs":[
        {"type":"movie","id":"popular","name":"Popular"},
        {"type":"series","id":"shows"},
        {"type":"music","id":"ignored"}
      ]
    }
    """#.utf8)
    let firstClient = AppleManifestClient { url in
        (firstData, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    let first = try await store.addStremio(
        manifestValue: "https://one.example/manifest.json",
        client: firstClient
    )

    #expect(first.manifestID == "org.example.addon")
    #expect(first.logoURL == URL(string: "https://img.example/addon.png"))
    #expect(first.resources == ["catalog", "stream"])
    #expect(first.catalogs.map(\.type) == ["movie", "series"])
    #expect(first.lastValidatedAt != nil)
    #expect(first.validationSummary == "Manifest validated")
    #expect(first.capabilities == ["Catalog", "Stream"])
    #expect(first.transportURL == URL(string: "https://one.example/"))

    let replacementData = Data(#"""
    {
      "id":"org.example.addon",
      "name":"Example Renamed",
      "version":"2.0.0",
      "resources":["stream"],
      "catalogs":[]
    }
    """#.utf8)
    let replacementClient = AppleManifestClient { url in
        (replacementData, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    let replacement = try await store.addStremio(
        manifestValue: "https://two.example/manifest.json",
        client: replacementClient
    )

    #expect(replacement.id == first.id)
    #expect(store.sources.count == 1)
    #expect(store.sources[0].name == "Example Renamed")
    #expect(store.sources[0].url == URL(string: "https://two.example/manifest.json"))
}

@Test func manifestParsingIsLossyBoundedAndPreservesCatalogExtras() throws {
    var catalogs: [Any] = [
        42,
        ["type": "movie"],
        [
            "type": "series",
            "id": " search ",
            "name": String(repeating: "S", count: 150),
            "extra": [
                ["name": "search", "isRequired": true],
                99,
            ],
        ],
    ]
    catalogs += (0 ..< 20).map { index in
        ["type": index.isMultiple(of: 2) ? "movie" : "series", "id": "catalog-\(index)"]
    }
    catalogs.append(["type": "book", "id": "ignored"])
    let data = try JSONSerialization.data(withJSONObject: [
        "id": String(repeating: "i", count: 300),
        "name": "  Example  ",
        "version": String(repeating: "v", count: 80),
        "resources": [42, " CATALOG ", ["name": "stream"], ["wrong": "value"], "catalog"],
        "catalogs": catalogs,
    ])

    let manifest = try JSONDecoder().decode(AppleStremioManifest.self, from: data)

    #expect(manifest.id.count == 200)
    #expect(manifest.name == "Example")
    #expect(manifest.version?.count == 40)
    #expect(manifest.resources == ["catalog", "stream"])
    #expect(manifest.catalogs.count == AppleStremioManifest.maximumCatalogs)
    #expect(manifest.catalogs[0].id == "search")
    #expect(manifest.catalogs[0].name?.count == 100)
    #expect(manifest.catalogs[0].requiresInput)
    #expect(manifest.catalogs[0].supportsSearch)
    #expect(!manifest.catalogs.contains(where: { $0.type == "book" }))

    let roundTrip = try JSONDecoder().decode(
        [AppleStremioCatalog].self,
        from: JSONEncoder().encode(manifest.catalogs)
    )
    #expect(roundTrip == manifest.catalogs)
}

@Test func manifestClientRetriesTransientFailuresButNotPermanentClientErrors() async throws {
    actor Attempts {
        var count = 0
        func next() -> Int { count += 1; return count }
    }

    let attempts = Attempts()
    let data = Data(#"{"id":"retry.example","name":"Retry"}"#.utf8)
    let retrying = AppleManifestClient(
        loader: { url in
            let attempt = await attempts.next()
            if attempt < 3 { throw URLError(.timedOut) }
            return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        },
        sleeper: { _ in }
    )
    _ = try await retrying.load("https://retry.example")
    #expect(await attempts.count == 3)

    let permanentAttempts = Attempts()
    let permanent = AppleManifestClient(
        loader: { url in
            _ = await permanentAttempts.next()
            return (Data(), HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        },
        sleeper: { _ in }
    )
    await #expect(throws: AppleManifestClientError.requestFailed(404)) {
        try await permanent.load("https://missing.example")
    }
    #expect(await permanentAttempts.count == 1)
}

@Test func webManagementProtocolRequiresItsSessionTokenAndSameOrigin() throws {
    let session = AppleWebManagementSession(
        url: URL(string: "http://192.168.1.25:11470/openstream?token=abc123")!,
        friendlyURL: URL(string: "http://openstream.local:11470/openstream?token=abc123")!,
        expiresAt: Date(timeIntervalSince1970: 1_800),
        token: "abc123"
    )

    #expect(AppleWebManagementProtocol.isAllowedClient(host: "192.168.1.42"))
    #expect(AppleWebManagementProtocol.isAllowedClient(host: "127.0.0.1"))
    #expect(!AppleWebManagementProtocol.isAllowedClient(host: "8.8.8.8"))
    #expect(AppleWebManagementProtocol.isValidOrigin(
        "http://openstream.local:11470",
        session: session
    ))
    #expect(!AppleWebManagementProtocol.isValidOrigin(
        "https://evil.example",
        session: session
    ))

    let form = AppleWebManagementProtocol.parseForm(
        "manifest=https%3A%2F%2Faddon.example%2Fmanifest.json&token=abc123"
    )
    #expect(form["manifest"] == "https://addon.example/manifest.json")
    #expect(AppleWebManagementProtocol.hasValidToken(
        form: form,
        headers: [:],
        query: [:],
        session: session
    ))
    #expect(!AppleWebManagementProtocol.hasValidToken(
        form: ["manifest": "https://addon.example/manifest.json"],
        headers: [:],
        query: [:],
        session: session
    ))
}

@Test func playbackRouteUsesOnlyProvenNativeExportAndRoutesUnreadableContainersExternally() {
    let localMKV = URL(fileURLWithPath: "/tmp/example.mkv")
    let localMP4 = URL(fileURLWithPath: "/tmp/example.mp4")
    let remoteURL = URL(string: "https://media.example/movie.mkv")!

    #expect(ApplePlaybackRoutePolicy.route(
        sourceURL: localMP4,
        decision: .init(support: .supported, reasons: [])
    ) == .direct(localMP4))
    #expect(ApplePlaybackRoutePolicy.route(
        sourceURL: localMP4,
        decision: .init(support: .unsupported, reasons: ["audio codec"]),
        suitability: .init(isPlayable: false, isReadable: true, isExportable: true, isProtected: false)
    ) == .nativeOfflineExport(localMP4))
    // The engine demuxes Matroska in-app; the gateway is no longer on the
    // playback path for it, so the route is direct even when unreadable.
    #expect(ApplePlaybackRoutePolicy.route(
        sourceURL: localMKV,
        decision: .init(support: .unsupported, reasons: ["container"]),
        suitability: .init(isPlayable: false, isReadable: false, isExportable: false, isProtected: false)
    ) == .direct(localMKV))
    #expect(ApplePlaybackRoutePolicy.route(
        sourceURL: remoteURL,
        decision: .init(support: .unsupported, reasons: ["codec"]),
        gatewayConfigured: true
    ) == .direct(remoteURL))
}
