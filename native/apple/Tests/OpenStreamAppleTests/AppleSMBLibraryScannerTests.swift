import Foundation
import Testing
@testable import OpenStreamApple

private actor LibraryScanClient: AppleNetworkShareClient {
    let directories: [String: [AppleSMBDirectoryEntry]]
    var requestedPaths: [String] = []
    init(_ directories: [String: [AppleSMBDirectoryEntry]]) { self.directories = directories }
    func listShares(host: String, port: Int, credentials: AppleSMBCredentials) async throws -> [AppleSMBShare] { [] }
    func listDirectory(url: URL, credentials: AppleSMBCredentials, recursive: Bool) async throws -> [AppleSMBDirectoryEntry] {
        #expect(!recursive)
        let path = try AppleSMBEndpointPolicy.parts(from: url).path
        requestedPaths.append(path)
        guard let entries = directories[path] else { throw AppleSMBError.connectionFailed }
        return entries
    }
    func read(url: URL, credentials: AppleSMBCredentials, range: Range<UInt64>) async throws -> Data { Data() }
}

private func scanEntry(_ path: String, directory: Bool = false) -> AppleSMBDirectoryEntry {
    .init(name: URL(fileURLWithPath: path).lastPathComponent, path: path, isDirectory: directory, sizeBytes: directory ? 0 : 1024)
}

private let scanSource = AppleSource(kind: .nas, name: "Test NAS", url: URL(string: "smb://nas.example/Media")!)
private let scanCredentials = AppleSMBCredentials(username: "fixture", password: "fixture")

@Test func smbLibraryKeepsReadableVideosWhenAnotherFolderIsDenied() async throws {
    let client = LibraryScanClient([
        "": [scanEntry("denied", directory: true), scanEntry("movies", directory: true), scanEntry("readme.txt")],
        "movies": [scanEntry("movies/film.mkv")],
    ])
    let result = try await AppleSMBLibraryScanner(client: client).scan(source: scanSource, credentials: scanCredentials)
    #expect(result.items.map(\.relativePath) == ["movies/film.mkv"])
    #expect(result.skippedFolderCount == 1)
    #expect(!result.reachedLimit)
    #expect(await client.requestedPaths == ["", "denied", "movies"])
}

@Test func smbLibraryStillReportsAnInaccessibleRoot() async {
    let client = LibraryScanClient([:])
    await #expect(throws: AppleSMBError.connectionFailed) {
        try await AppleSMBLibraryScanner(client: client).scan(source: scanSource, credentials: scanCredentials)
    }
}

@Test func smbLibraryBoundsTraversalAndRejectsEscapingPaths() async throws {
    let client = LibraryScanClient([
        "": [scanEntry("../outside", directory: true), scanEntry("a", directory: true), scanEntry("b", directory: true)],
        "a": [scanEntry("a/one.mp4"), scanEntry("a/two.mp4")],
        "b": [scanEntry("b/three.mp4")],
    ])
    let result = try await AppleSMBLibraryScanner(client: client, maximumItems: 1, maximumFolders: 2)
        .scan(source: scanSource, credentials: scanCredentials)
    #expect(result.items.map(\.relativePath) == ["a/one.mp4"])
    #expect(result.reachedLimit)
    #expect(await client.requestedPaths == ["", "a"])
}

@Test func smbLibraryDoesNotVisitTheSameFolderTwiceOrLeaveTheSelectedFolder() async throws {
    let source = AppleSource(kind: .nas, name: "Folder", url: URL(string: "smb://nas.example/Media/selected")!)
    let client = LibraryScanClient([
        "selected": [scanEntry("selected", directory: true), scanEntry("other", directory: true),
                     scanEntry("selected/child", directory: true), scanEntry("selected/child", directory: true)],
        "selected/child": [scanEntry("selected/child/film.mp4")],
    ])
    let result = try await AppleSMBLibraryScanner(client: client).scan(source: source, credentials: scanCredentials)
    #expect(result.items.count == 1)
    #expect(await client.requestedPaths == ["selected", "selected/child"])
}

@Test func smbLibraryCancellationStopsBeforeConnecting() async {
    let client = LibraryScanClient(["": []])
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await AppleSMBLibraryScanner(client: client).scan(source: scanSource, credentials: scanCredentials)
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await client.requestedPaths.isEmpty)
}
