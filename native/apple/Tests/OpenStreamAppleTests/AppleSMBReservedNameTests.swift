import AetherEngine
import Foundation
import Testing
@testable import OpenStreamApple

/// A share backed by a local folder: the bridge's SMB URL is opened by its
/// decoded path, as AMSMB2 opens it on a NAS.
private struct FolderShareClient: AppleNetworkShareClient {
    let root: URL
    func listShares(host: String, port: Int, credentials: AppleSMBCredentials) async throws -> [AppleSMBShare] { [] }
    func listDirectory(url: URL, credentials: AppleSMBCredentials, recursive: Bool) async throws -> [AppleSMBDirectoryEntry] { [] }
    func read(url: URL, credentials: AppleSMBCredentials, range: Range<UInt64>) async throws -> Data {
        let path = try AppleSMBEndpointPolicy.parts(from: url).path
        guard let handle = FileHandle(forReadingAtPath: root.appendingPathComponent(path).path) else {
            throw AppleSMBError.notFound
        }
        defer { try? handle.close() }
        try handle.seek(toOffset: range.lowerBound)
        return try handle.read(upToCount: Int(range.count)) ?? Data()
    }
    func fileSize(url: URL, credentials: AppleSMBCredentials) async throws -> UInt64? {
        let path = root.appendingPathComponent(try AppleSMBEndpointPolicy.parts(from: url).path).path
        guard let size = try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber else {
            throw AppleSMBError.notFound
        }
        return size.uint64Value
    }
}

private let reservedNames = [
    "Show & Co's Name - S01E01 - A Title.mkv",
    "Georgie & Mandy's First Marriage - S01E03 - An Interval and a British Stripper WEBDL-2160p.mkv",
    "Hash #1 ? query % 50%25 a+b; c=d.mkv",
    "Café Ünïcødé – Co’s ñ.mkv",
]
private let reservedFolder = "TV/Show & Co's #1 ?x %25 a+b; c (2025)/Season 1"

@Test(arguments: reservedNames)
func smbURLsRoundTripReservedCharacters(name: String) throws {
    let path = "\(reservedFolder)/\(name)"
    let url = try AppleSMBEndpointPolicy.makeURL(host: "nas.local", port: 445, share: "Media", path: path)
    let parts = try AppleSMBEndpointPolicy.parts(from: url)
    #expect(parts.share == "Media")
    #expect(parts.path == path)
    #expect(url.lastPathComponent == name)
    #expect(url.query == nil && url.fragment == nil)
}

@Test(arguments: reservedNames)
func bridgeURLKeepsTheFileNameAndToken(name: String) async throws {
    let server = AppleSMBRangeServer(client: FolderShareClient(root: URL(fileURLWithPath: "/nonexistent")))
    let source = try AppleSMBEndpointPolicy.makeURL(host: "nas.local", port: 445, share: "Media", path: "\(reservedFolder)/\(name)")
    let playback = try await server.playbackURL(sourceURL: source, credentials: .init(username: "", password: ""), sizeBytes: 1)
    #expect(playback.host() == "127.0.0.1")
    #expect(playback.query == nil && playback.fragment == nil)
    #expect(playback.lastPathComponent == name)
    #expect(playback.pathComponents.count == 4)
    await server.removeAllSessions()
}

/// The fixture MKV under each reserved name, through the real bridge: the
/// player's bytes are the file's bytes and the engine's probe opens it.
@Test(.timeLimit(.minutes(1)), arguments: reservedNames)
func bridgeServesAndProbesAFileWithReservedCharacters(name: String) async throws {
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/out/mkv-h264-aac.mkv")
    let payload = try Data(contentsOf: fixture)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("smb-reserved-\(UUID().uuidString)")
    let folder = root.appendingPathComponent("Media").appendingPathComponent(reservedFolder)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try payload.write(to: folder.appendingPathComponent(name))

    let server = AppleSMBRangeServer(client: FolderShareClient(root: root.appendingPathComponent("Media")), addedLatency: .zero)
    let source = try AppleSMBEndpointPolicy.makeURL(host: "nas.local", port: 445, share: "Media", path: "\(reservedFolder)/\(name)")
    let playback = try await server.playbackURL(sourceURL: source, credentials: .init(username: "", password: ""),
        sizeBytes: Int64(payload.count))
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let (data, response) = try await session.data(from: playback)
    #expect((response as? HTTPURLResponse)?.statusCode == 200)
    #expect(data == payload)
    let probe = try await Task.detached { try AetherEngine.probe(url: playback) }.value
    #expect(probe.durationSeconds > 0)
    await server.removeAllSessions()
}

/// A file the share cannot open is an HTTP error before any body, never a
/// 200 with no bytes that the demuxer reads as invalid data.
@Test(.timeLimit(.minutes(1)))
func bridgeAnswersAnUnopenableFileWithAnErrorStatus() async throws {
    let server = AppleSMBRangeServer(client: FolderShareClient(root: URL(fileURLWithPath: "/nonexistent")), addedLatency: .zero)
    let source = try AppleSMBEndpointPolicy.makeURL(host: "nas.local", port: 445, share: "Media", path: "Show & Co's Name - S01E01.mkv")
    let playback = try await server.playbackURL(sourceURL: source, credentials: .init(username: "", password: ""), sizeBytes: 4_096)
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let (data, response) = try await session.data(from: playback)
    #expect((response as? HTTPURLResponse)?.statusCode == 404)
    #expect(data.isEmpty)
    #expect(await server.openFailure(playbackURL: playback) == .notFound)
    await server.removeAllSessions()
}

@Test func onlyAMissingFileReadsAsNotFound() {
    #expect(AppleSMBClient.isMissingFile(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))))
    #expect(AppleSMBClient.isMissingFile(NSError(domain: "SMB", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "STATUS_OBJECT_NAME_NOT_FOUND"])))
    #expect(!AppleSMBClient.isMissingFile(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))))
    // Browsing and adding a share keep their own messages for a missing folder.
    #expect(AppleSMBError.mapped(from: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))) != .notFound)
}

@Test func anEpisodeNamesItsLineUnderTheSeries() throws {
    let name = "Show & Co's Name - S01E01 - A Title.mkv"
    let parsed = AppleLibraryTitleParser.parse(name: name, parentPath: "TV/Show & Co's Name/Season 1")
    #expect(AppleLocalLibraryStore.episodeLine(parsed, name: name) == "S1 E1 · A Title")
}

@Test func aFilmHasNoEpisodeLine() {
    let name = "Some Film (2020).mkv"
    let parsed = AppleLibraryTitleParser.parse(name: name, parentPath: "Movies")
    #expect(AppleLocalLibraryStore.episodeLine(parsed, name: name) == nil)
}

/// A real SMB share (`OPENSTREAM_SMB_FIXTURE=smb://127.0.0.1:4447/Media/TV`, with
/// `OPENSTREAM_SMB_FIXTURE_USER` and `OPENSTREAM_SMB_FIXTURE_PASSWORD_FILE`) holding the
/// fixture MKV under the owner's real episode names. Every step is production code: the
/// AMSMB2 client lists the share, the scanner builds the item URLs, the library's snapshot
/// round-trips them, and the bridge serves them to the engine's probe.
@Test(.timeLimit(.minutes(2)), .enabled(if: ProcessInfo.processInfo.environment["OPENSTREAM_SMB_FIXTURE"] != nil))
func realShareEpisodesWithQuotesAndAmpersandsPlayThroughTheBridge() async throws {
    let environment = ProcessInfo.processInfo.environment
    let root = try #require(environment["OPENSTREAM_SMB_FIXTURE"].flatMap(URL.init(string:)))
    let password = try String(contentsOfFile: try #require(environment["OPENSTREAM_SMB_FIXTURE_PASSWORD_FILE"]), encoding: .utf8)
    let credentials = AppleSMBCredentials(username: environment["OPENSTREAM_SMB_FIXTURE_USER"] ?? "", password: password)
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/out/mkv-h264-aac.mkv")
    let payload = try Data(contentsOf: fixture)

    let client = AppleSMBClient()
    let scanned = try await AppleSMBLibraryScanner(client: client)
        .scan(source: AppleSource(kind: .nas, name: "Fixture", url: root), credentials: credentials).items
    // The library snapshot keeps each item's URL through Codable, as this does.
    let items = try scanned.map { item in
        let url = try JSONDecoder().decode(URL.self, from: JSONEncoder().encode(item.url))
        return AppleLibraryItem(sourceID: item.sourceID, name: item.name, url: url, relativePath: item.relativePath,
            sizeBytes: item.sizeBytes, modifiedAt: item.modifiedAt)
    }
    #expect(Set(items.map(\.name)) == [
        "Georgie & Mandy's First Marriage - S01E01 - An Interval and a British Stripper.mkv",
        "Georgie & Mandy's First Marriage - S03E04 - The Devil\u{2019}s Interval and a British Stripper WEBDL-2160p.mkv",
    ])

    let server = AppleSMBRangeServer(client: client, addedLatency: .zero)
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    for item in items {
        #expect(item.url.lastPathComponent == item.name)
        let playback = try await server.playbackURL(sourceURL: item.url, credentials: credentials,
            sizeBytes: item.sizeBytes, modifiedAt: item.modifiedAt)
        #expect(playback.lastPathComponent == item.name)
        let (data, response) = try await session.data(from: playback)
        #expect((response as? HTTPURLResponse)?.statusCode == 200, "\(item.name)")
        #expect(data == payload, "\(item.name)")
        let probe = try await Task.detached { try AetherEngine.probe(url: playback) }.value
        #expect(probe.durationSeconds > 0, "\(item.name)")
    }
    await server.removeAllSessions()
}

/// A file replaced at the same path (a Sonarr upgrade) after the library
/// scanned it: the bridge serves the share's file as it is now, not the
/// library's old size.
@Test(.timeLimit(.minutes(1)), arguments: [Int64(103_739), -103_739])
func bridgeServesAFileReplacedAtTheSamePath(libraryDelta: Int64) async throws {
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/out/mkv-h264-aac.mkv")
    let payload = try Data(contentsOf: fixture)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("smb-replaced-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let name = "Georgie & Mandy's First Marriage - S03E04 - The Devil\u{2019}s Interval and a British Stripper WEBDL-2160p.mkv"
    try payload.write(to: root.appendingPathComponent(name))

    let server = AppleSMBRangeServer(client: FolderShareClient(root: root), addedLatency: .zero)
    let source = try AppleSMBEndpointPolicy.makeURL(host: "nas.local", port: 445, share: "Media", path: name)
    let playback = try await server.playbackURL(sourceURL: source, credentials: .init(username: "", password: ""),
        sizeBytes: Int64(payload.count) + libraryDelta)
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let (data, response) = try await session.data(from: playback)
    #expect((response as? HTTPURLResponse)?.statusCode == 200)
    #expect(data == payload)
    var tail = URLRequest(url: playback)
    tail.setValue("bytes=-4096", forHTTPHeaderField: "Range")
    let (tailData, tailResponse) = try await session.data(for: tail)
    #expect((tailResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range")
        == "bytes \(payload.count - 4_096)-\(payload.count - 1)/\(payload.count)")
    #expect(tailData == payload.suffix(4_096))
    let probe = try await Task.detached { try AetherEngine.probe(url: playback) }.value
    #expect(probe.durationSeconds > 0)
    await server.removeAllSessions()
}
