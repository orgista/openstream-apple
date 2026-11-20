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
    let external = AppleSource(kind: .library, name: "Imports", url: URL(fileURLWithPath: "/fixture/External/Imports"))
    let bookmarked = AppleSource(kind: .library, name: "Imports",
        url: URL(fileURLWithPath: "/private/var/mobile/Containers/Data/Application/\(UUID())/Documents/Imports"),
        bookmarkData: Data([1]))
    defaults.set(try JSONEncoder().encode([external, bookmarked]), forKey: "openstream.sources.v1")
    let store = AppleSourceStore(defaults: defaults, documentsDirectory: URL(fileURLWithPath: "/tmp/new-documents"))
    #expect(store.sources.first(where: { $0.id == external.id }) == external)
    #expect(store.sources.first(where: { $0.id == bookmarked.id }) == bookmarked)
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
        "playlistURL=https%3A%2F%2Ffixture.example%2Flist.m3u&token=abc123"
    )
    #expect(form["playlistURL"] == "https://fixture.example/list.m3u")
    #expect(AppleWebManagementProtocol.hasValidToken(
        form: form,
        headers: [:],
        query: [:],
        session: session
    ))
    #expect(!AppleWebManagementProtocol.hasValidToken(
        form: ["playlistURL": "https://fixture.example/list.m3u"],
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
    // The engine demuxes Matroska in-app; it is never on the
    // playback path for it, so the route is direct even when unreadable.
    #expect(ApplePlaybackRoutePolicy.route(
        sourceURL: localMKV,
        decision: .init(support: .unsupported, reasons: ["container"]),
        suitability: .init(isPlayable: false, isReadable: false, isExportable: false, isProtected: false)
    ) == .direct(localMKV))
    #expect(ApplePlaybackRoutePolicy.route(
        sourceURL: remoteURL,
        decision: .init(support: .unsupported, reasons: ["codec"])
    ) == .direct(remoteURL))
}
