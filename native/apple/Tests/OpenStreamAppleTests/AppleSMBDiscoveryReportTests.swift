import Foundation
import Testing
@testable import OpenStreamApple

private struct NestedSMBClient: AppleNetworkShareClient {
    let directories: [String: [AppleSMBDirectoryEntry]]

    func listShares(host: String, port: Int, credentials: AppleSMBCredentials) async throws -> [AppleSMBShare] { [] }

    func listDirectory(
        url: URL,
        credentials: AppleSMBCredentials,
        recursive: Bool
    ) async throws -> [AppleSMBDirectoryEntry] {
        let path = try AppleSMBEndpointPolicy.parts(from: url).path
        #expect(!recursive)
        return directories[path] ?? []
    }

    func read(url: URL, credentials: AppleSMBCredentials, range: Range<UInt64>) async throws -> Data { Data() }
}

@Test func discoveryExplainsPermissionAndConnectionFailuresSeparately() {
    let denied = AppleSMBDiscoveryReport(servers: [], permissionDenied: true, advertisedCount: 0)
    #expect(denied.message.contains("Local Network"))
    let unreachable = AppleSMBDiscoveryReport(servers: [], permissionDenied: false, advertisedCount: 2)
    #expect(unreachable.message.contains("couldn’t connect"))
    let empty = AppleSMBDiscoveryReport(servers: [], permissionDenied: false, advertisedCount: 0)
    #expect(empty.message.contains("SMB"))
    #expect(!empty.message.contains("password"))
}

@Test func discoveredIPv4InterfaceSuffixDoesNotBecomePartOfTheSMBHostname() throws {
    let server = AppleSMBServer(name: "Test NAS", host: "192.0.2.12%en0", port: 445)
    #expect(server.host == "192.0.2.12")
    let url = try AppleSMBEndpointPolicy.makeURL(host: "192.0.2.12%en0", port: 445, share: "Media")
    #expect(url.host == "192.0.2.12")
}

@Test func scopedIPv6BonjourEndpointsRemainValidAndCarryTheirPort() throws {
    let url = try AppleSMBEndpointPolicy.makeURL(
        host: "fe80::f85c:90ff:fe76:4fd3%en9",
        port: 1445,
        share: "TestMedia"
    )
    #expect(url.host == "fe80::f85c:90ff:fe76:4fd3%en9")
    #expect(url.port == 1445)
    #expect(url.absoluteString.contains("%25en9"))
}

@Test func endpointSelectionPrefersBonjourThenIPv4ThenScopedIPv6() {
    #expect(AppleSMBEndpointPolicy.preferredHost(
        bonjourHost: "Studio.local",
        ipv4Host: "192.0.2.12",
        ipv6Host: "fe80::1%en9"
    ) == "Studio.local")
    #expect(AppleSMBEndpointPolicy.preferredHost(
        bonjourHost: nil,
        ipv4Host: "192.0.2.12",
        ipv6Host: "fe80::1%en9"
    ) == "192.0.2.12")
    #expect(AppleSMBEndpointPolicy.preferredHost(
        bonjourHost: nil,
        ipv4Host: nil,
        ipv6Host: "fe80::1%en9"
    ) == "fe80::1%en9")
    #expect(AppleSMBEndpointPolicy.connectionHost(
        ipv4Host: "192.0.2.12",
        ipv6Host: "fe80::1%en9"
    ) == "192.0.2.12")
    #expect(AppleSMBEndpointPolicy.connectionHost(
        ipv4Host: nil,
        ipv6Host: "fe80::1%en9"
    ) == "fe80::1%en9")
}

@Test func discoveredServiceUsesNumericConnectionURLAndBonjourDisplayLabel() throws {
    let displayHost = try #require(AppleSMBEndpointPolicy.preferredHost(
        bonjourHost: "Studio.local",
        ipv4Host: "192.168.1.95",
        ipv6Host: "fe80::1%en9"
    ))
    let connectionHost = try #require(AppleSMBEndpointPolicy.connectionHost(
        ipv4Host: "192.168.1.95",
        ipv6Host: "fe80::1%en9"
    ))
    let server = AppleSMBServer(
        name: "OpenStreamTestNAS",
        host: connectionHost,
        port: 1445,
        displayHost: displayHost
    )
    let url = try AppleSMBEndpointPolicy.makeURL(
        host: server.host,
        port: server.port,
        share: "TestMedia"
    )

    #expect(server.displayHost == "Studio.local")
    #expect(AppleSMBEndpointPolicy.endpointLabel(host: server.displayHost, port: server.port) == "Studio.local:1445")
    #expect(url.host == "192.168.1.95")
    #expect(url.absoluteString.contains("192.168.1.95"))
    #expect(!url.absoluteString.contains("Studio.local"))
}

@Test func serverOnlyEndpointInputSupportsShareListingBeforeShareSelection() throws {
    let server = try AppleSMBEndpointPolicy.parseInput(
        host: "192.168.1.95",
        port: 1445,
        share: "IPC$",
        path: ""
    )

    #expect(server.host == "192.168.1.95")
    #expect(server.port == 1445)
    #expect(server.share == "IPC$")
    #expect(server.path.isEmpty)
}

@Test func savedNetworkSourceRoundTripsDisplayHostAndNumericEndpoint() throws {
    let source = AppleSource(
        kind: .nas,
        name: "TestMedia",
        url: try AppleSMBEndpointPolicy.makeURL(host: "192.168.1.95", port: 1445, share: "TestMedia"),
        networkDisplayHost: "Studio.local"
    )
    let restored = try JSONDecoder().decode(AppleSource.self, from: JSONEncoder().encode(source))
    #expect(restored.url.host == "192.168.1.95")
    #expect(restored.networkDisplayHost == "Studio.local")
}

@Test func endpointLabelOmitsDefaultPortAndBracketsIPv6() {
    #expect(AppleSMBEndpointPolicy.endpointLabel(host: "Studio.local", port: 445) == "Studio.local")
    #expect(AppleSMBEndpointPolicy.endpointLabel(host: "Studio.local", port: 1445) == "Studio.local:1445")
    #expect(AppleSMBEndpointPolicy.endpointLabel(host: "fe80::1%en9", port: 1445) == "[fe80::1%en9]:1445")
}

@Test func recursiveShareWalkVisitsNestedDirectories() async throws {
    let root = [
        AppleSMBDirectoryEntry(name: "Movies", path: "Movies", isDirectory: true),
        AppleSMBDirectoryEntry(name: "loose.mkv", path: "loose.mkv", isDirectory: false),
    ]
    let nested: [String: [AppleSMBDirectoryEntry]] = [
        "Movies": [AppleSMBDirectoryEntry(name: "Sample Movie (2024).mp4", path: "Movies/Sample Movie (2024).mp4", isDirectory: false)],
    ]
    let result = try await AppleSMBDirectoryWalker.walk(root: root) { path in
        nested[path] ?? []
    }
    #expect(result.map(\.path) == ["loose.mkv", "Movies", "Movies/Sample Movie (2024).mp4"])
}

@Test func amsmb2DirectoryMetadataPreservesNSNumberDirectoryFlag() {
    #expect(AppleSMBClient.isDirectory([
        .nameKey: "Movies",
        .isDirectoryKey: NSNumber(value: true),
    ]))
    #expect(!AppleSMBClient.isDirectory([
        .nameKey: "movie.mp4",
        .isDirectoryKey: NSNumber(value: false),
    ]))
}

@Test func amsmb2RegularFileFallbackDoesNotHideDirectories() {
    #expect(AppleSMBClient.isDirectory([
        .nameKey: "Movies",
        .fileResourceTypeKey: URLFileResourceType.regular,
        .isRegularFileKey: NSNumber(value: false),
    ]))
    #expect(!AppleSMBClient.isDirectory([
        .nameKey: "movie.mp4",
        .isRegularFileKey: NSNumber(value: true),
    ]))
}

@Test func networkLibraryScanWalksAllNestedFixtureFilesWithFakeClient() async throws {
    let sourceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let source = AppleSource(
        id: sourceID,
        kind: .nas,
        name: "TestMedia",
        url: try AppleSMBEndpointPolicy.makeURL(host: "192.168.1.95", port: 1445, share: "TestMedia")
    )
    let root = [
        AppleSMBDirectoryEntry(name: "Movies", path: "Movies", isDirectory: true),
        AppleSMBDirectoryEntry(name: "Shows", path: "Shows", isDirectory: true),
        AppleSMBDirectoryEntry(name: "mkv-h264-aac.mkv", path: "mkv-h264-aac.mkv", isDirectory: false),
        AppleSMBDirectoryEntry(name: "hdr10-hevc.mp4", path: "hdr10-hevc.mp4", isDirectory: false),
        AppleSMBDirectoryEntry(name: "dv81-hevc-eac3.mp4", path: "dv81-hevc-eac3.mp4", isDirectory: false),
        AppleSMBDirectoryEntry(name: "mkv-hevc-eac3.mkv", path: "mkv-hevc-eac3.mkv", isDirectory: false),
    ]
    let movies = [
        AppleSMBDirectoryEntry(name: "Sample Movie (2024).mp4", path: "Movies/Sample Movie (2024).mp4", isDirectory: false),
        AppleSMBDirectoryEntry(name: "Sample Movie Long (2024).mp4", path: "Movies/Sample Movie Long (2024).mp4", isDirectory: false),
    ]
    let shows = [AppleSMBDirectoryEntry(name: "Sample Show", path: "Shows/Sample Show", isDirectory: true)]
    let show = [AppleSMBDirectoryEntry(name: "Season 1", path: "Shows/Sample Show/Season 1", isDirectory: true)]
    let season = [
        AppleSMBDirectoryEntry(name: "Sample Show S01E01.mkv", path: "Shows/Sample Show/Season 1/Sample Show S01E01.mkv", isDirectory: false),
        AppleSMBDirectoryEntry(name: "Sample Show S01E02.mkv", path: "Shows/Sample Show/Season 1/Sample Show S01E02.mkv", isDirectory: false),
        AppleSMBDirectoryEntry(name: "Sample Show S01E03 (long).mkv", path: "Shows/Sample Show/Season 1/Sample Show S01E03 (long).mkv", isDirectory: false),
    ]
    let scanner = AppleSMBNetworkLibraryScanner(client: NestedSMBClient(directories: [
        "": root,
        "Movies": movies,
        "Shows": shows,
        "Shows/Sample Show": show,
        "Shows/Sample Show/Season 1": season,
    ]))

    let result = try await scanner.scan(source: source, credentials: .init(username: "fixture", password: "fixture"))
    let items = result.items
    #expect(result.status == .complete)
    #expect(items.count == 9)
    #expect(items.map(\.relativePath).contains("Shows/Sample Show/Season 1/Sample Show S01E03 (long).mkv"))
    #expect(items.map(\.relativePath).contains("Movies/Sample Movie Long (2024).mp4"))
    #expect(items.map(\.relativePath) == items.map(\.relativePath).sorted {
        $0.localizedStandardCompare($1) == .orderedAscending
    })
}

@Test func smbFailureMappingNamesAuthenticationAndReachabilityReasons() {
    #expect(AppleSMBError.mapped(from: NSError(
        domain: "SMB", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "NT_STATUS_LOGON_FAILURE"]
    )) == .authenticationFailed)
    #expect(AppleSMBError.mapped(from: NSError(
        domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost
    )) == .serverUnreachable)
    #expect(AppleSMBError.mapped(from: NSError(
        domain: NSPOSIXErrorDomain, code: Int(EPERM)
    )) == .accessDenied)
    // A blocked or pending Local Network permission fails the connect with no route.
    #expect(AppleSMBError.mapped(from: NSError(
        domain: NSPOSIXErrorDomain, code: Int(EHOSTUNREACH)
    )) == .serverUnreachable)
    // libsmb2 reports a wrong password as ECONNREFUSED with the NT status in the text.
    #expect(AppleSMBError.mapped(from: NSError(
        domain: NSPOSIXErrorDomain, code: Int(ECONNREFUSED),
        userInfo: [NSLocalizedDescriptionKey: "Session setup failed: STATUS_LOGON_FAILURE"]
    )) == .authenticationFailed)
    #expect(AppleSMBError.mapped(from: NSError(
        domain: "SMB", code: 2,
        userInfo: [NSLocalizedDescriptionKey: "Tree connect: STATUS_BAD_NETWORK_NAME"]
    )) == .accessDenied)
    #expect(AppleSMBError.authenticationFailed.errorDescription?.contains("username") == true)
    #expect(AppleSMBError.accessDenied.errorDescription?.contains("share") == true)
    #expect(AppleSMBError.serverUnreachable.errorDescription?.contains("unreachable") == true)
}


private actor NetworkLibraryFixtureClient: AppleNetworkShareClient {
    let directories: [String: [AppleSMBDirectoryEntry]]
    let cancelOnPath: String?
    private(set) var requestedPaths: [String] = []

    init(_ directories: [String: [AppleSMBDirectoryEntry]], cancelOnPath: String? = nil) {
        self.directories = directories
        self.cancelOnPath = cancelOnPath
    }

    func listShares(host: String, port: Int, credentials: AppleSMBCredentials) async throws -> [AppleSMBShare] { [] }
    func read(url: URL, credentials: AppleSMBCredentials, range: Range<UInt64>) async throws -> Data { Data() }
    func listDirectory(url: URL, credentials: AppleSMBCredentials, recursive: Bool) async throws -> [AppleSMBDirectoryEntry] {
        #expect(recursive == false)
        let path = try AppleSMBEndpointPolicy.parts(from: url).path
        requestedPaths.append(path)
        if path == cancelOnPath { withUnsafeCurrentTask { $0?.cancel() } }
        guard let entries = directories[path] else { throw AppleSMBError.accessDenied }
        return entries
    }
}

private func networkLibraryEntry(_ path: String, directory: Bool = false) -> AppleSMBDirectoryEntry {
    .init(name: directory ? "Season" : "episode.mkv", path: path, isDirectory: directory, sizeBytes: 1024)
}

private let networkLibrarySource = AppleSource(kind: .nas, name: "Fixture", url: URL(string: "smb://fixture.example/Media")!)
private let networkLibraryCredentials = AppleSMBCredentials(username: "fixture", password: "fixture")

@Test(arguments: ["Shows/Season 1/episode.mkv", "/Shows/Season 1/episode.mkv",
                  "Shows/Season 1/episode.mkv/", "/Shows/Season 1/episode.mkv/"])
func networkLibraryScanPreservesPreChangeIdentityBytes(_ path: String) async throws {
    let entry = networkLibraryEntry(path)
    let client = NetworkLibraryFixtureClient(["": [entry]])
    let result = try await AppleSMBNetworkLibraryScanner(client: client).scan(
        source: networkLibrarySource, credentials: networkLibraryCredentials)
    // The pre-change adapter passed entry.path as-is to both makeURL and relativePath.
    let expectedURL = try AppleSMBEndpointPolicy.makeURL(host: "fixture.example", port: 445, share: "Media", path: entry.path)
    let expected = AppleLibraryItem(sourceID: networkLibrarySource.id, name: entry.name,
        url: expectedURL, relativePath: entry.path, sizeBytes: entry.sizeBytes)
    let item = try #require(result.items.first)
    #expect(result.status == .complete)
    #expect(item == expected)
    #expect(item.id.utf8.elementsEqual(expected.id.utf8))
    #expect(item.relativePath.utf8.elementsEqual(path.utf8))
    #expect(item.url.absoluteString.utf8.elementsEqual(expectedURL.absoluteString.utf8))
}

@Test func networkLibraryCompletesLargeSeasonalSharesWithoutBrowseFilters() async throws {
    var directories: [String: [AppleSMBDirectoryEntry]] = [:]
    let folders = (0..<300).map { "Show/Season \($0)" } + ["downloads", ".archive"]
    directories[""] = folders.map { networkLibraryEntry($0, directory: true) }
    for folder in folders {
        directories[folder] = (0..<40).map { networkLibraryEntry("\(folder)/episode-\($0).mkv") }
    }
    let client = NetworkLibraryFixtureClient(directories)
    let result = try await AppleSMBNetworkLibraryScanner(client: client).scan(
        source: networkLibrarySource, credentials: networkLibraryCredentials)
    #expect(result.status == .complete)
    #expect(result.items.count == 12_080)
    #expect(await client.requestedPaths.count == 303)
    #expect(result.items.contains { $0.relativePath == "downloads/episode-39.mkv" })
    #expect(result.items.contains { $0.relativePath == ".archive/episode-39.mkv" })
}

@Test func networkLibraryDeniedChildIsPartialAndRetainsOldItemsAndStamp() async throws {
    let old = AppleLibraryItem(sourceID: networkLibrarySource.id, name: "old.mkv",
        url: URL(string: "smb://fixture.example/Media/denied/old.mkv")!, relativePath: "/denied/old.mkv", sizeBytes: 1024)
    let client = NetworkLibraryFixtureClient([
        "": [networkLibraryEntry("denied", directory: true), networkLibraryEntry("readable", directory: true)],
        "readable": [networkLibraryEntry("readable/new.mkv")],
    ])
    let result = try await AppleSMBNetworkLibraryScanner(client: client).scan(
        source: networkLibrarySource, credentials: networkLibraryCredentials)
    #expect(result.status == .partial)
    #expect(result.items.map(\.relativePath) == ["readable/new.mkv"])
    #expect(Set(result.retaining([old]).map(\.id)) == Set([old.id] + result.items.map(\.id)))
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = AppleMediaIndexRepository(fileURL: directory.appendingPathComponent("index.json"))
    let previous = AppleMediaIngestion.libraryRecords(source: networkLibrarySource, items: [old])
    try await repository.replace(instanceID: networkLibrarySource.id, with: previous)
    let stamp = await repository.lastSuccessfulScan(for: networkLibrarySource.id)
    try await repository.replace(instanceID: networkLibrarySource.id,
        with: AppleMediaIngestion.libraryRecords(source: networkLibrarySource, items: result.items), scanStatus: result.status)
    let records = await repository.records()
    #expect(records.count == 2)
    #expect(records.first { $0.id == previous[0].id }?.availability.first?.isStale == true)
    #expect(await repository.lastSuccessfulScan(for: networkLibrarySource.id) == stamp)
}

@Test func networkLibraryUnavailableRootFailsWithoutFreshness() async throws {
    let result = try await AppleSMBNetworkLibraryScanner(client: NetworkLibraryFixtureClient([:])).scan(
        source: networkLibrarySource, credentials: networkLibraryCredentials)
    #expect(result.status == .failed)
    #expect(result.items.isEmpty)
}

@Test(arguments: [(2, 20), (100, 1)])
func networkLibrarySafetyBoundsYieldPartial(_ limits: (Int, Int)) async throws {
    let client = NetworkLibraryFixtureClient([
        "": [networkLibraryEntry("a", directory: true), networkLibraryEntry("b", directory: true)],
        "a": [networkLibraryEntry("a/one.mkv")],
        "b": [networkLibraryEntry("b/two.mkv")],
    ])
    let result = try await AppleSMBNetworkLibraryScanner(client: client,
        maximumEntries: limits.0, maximumFolders: limits.1).scan(
        source: networkLibrarySource, credentials: networkLibraryCredentials)
    #expect(result.status == .partial)
}

@Test func networkLibraryCancellationStopsBeforeRootAndAfterChildListing() async {
    let beforeRoot = NetworkLibraryFixtureClient(["": []])
    let cancelled = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await AppleSMBNetworkLibraryScanner(client: beforeRoot).scan(
            source: networkLibrarySource, credentials: networkLibraryCredentials)
    }
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    #expect(await beforeRoot.requestedPaths.isEmpty)

    let duringWalk = NetworkLibraryFixtureClient([
        "": [networkLibraryEntry("a", directory: true), networkLibraryEntry("b", directory: true)],
        "a": [networkLibraryEntry("a/one.mkv")], "b": [],
    ], cancelOnPath: "a")
    let interrupted = Task {
        try await AppleSMBNetworkLibraryScanner(client: duringWalk).scan(
            source: networkLibrarySource, credentials: networkLibraryCredentials)
    }
    await #expect(throws: CancellationError.self) { try await interrupted.value }
    let requested = await duringWalk.requestedPaths
    #expect(requested.first == "")
    #expect(requested.contains("a"))
    #expect(Set(requested).isSubset(of: ["", "a", "b"]))
}
