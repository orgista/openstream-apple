import Foundation
import Testing
@testable import OpenStreamApple

@Test func siblingSubtitleStemMatchUsesOneNonRecursiveSMBListing() async throws {
    let client = SiblingListingClient()
    let video = URL(string: "smb://fixture.example/Media/Movie.mkv")!
    let tracks = try await AppleSMBLibraryScanner(client: client).siblingSubtitles(
        for: video, credentials: .init(username: "", password: ""))
    #expect(tracks.map(\.url.lastPathComponent) == ["Movie.en.srt", "Movie.srt"])
    #expect(await client.listings == 1)
}

@Test func siblingSubtitleLanguageAndAccessibilityTokensComeFromTheSuffix() {
    let folder = URL(fileURLWithPath: "/fixture")
    let video = folder.appendingPathComponent("Movie.en.mkv")
    let tracks = AppleLibrarySubtitleService.matching(video: video, files: [
        "Movie.en.srt", "Movie.en.en.sdh.srt", "Movie.en.es.forced.vtt", "Movie.en.forced.ass", "Movie.en.sdh.ssa"
    ].map { folder.appendingPathComponent($0) })
    #expect(tracks.map(\.languageCode) == ["en", "es", "", "", ""])
    #expect(tracks.map(\.displayName) == ["English SDH", "Spanish Forced", "Forced", "SDH", "Subtitles"])
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func siblingSubtitlesLoadForPlaybackAndCacheTheFolderForThisPlay() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let video = folder.appendingPathComponent("Movie.mkv")
    // English, the only language the menu lists when none was picked.
    let subtitle = folder.appendingPathComponent("Movie.en.srt")
    try Data("1\n00:00:00,000 --> 00:02:00,000\nHOLA DESDE ESPANA\n".utf8).write(to: subtitle)
    let cache = AppleLibrarySubtitleService()
    let first = await cache.tracks(for: video)
    #expect(first.map(\.displayName) == ["English"])
    try Data().write(to: folder.appendingPathComponent("Movie.fr.srt"))
    #expect(await cache.tracks(for: video) == first)
    let data = try await AppleExternalSubtitleService.liveDataLoader(subtitle)
    #expect(AppleSubtitleTextParser.cues(from: data).first?.text == "HOLA DESDE ESPANA")

    let native = NativePlaybackEngine()
    let aether = try AetherPlaybackEngine()
    for player: any ApplePlaybackEngine in [native, aether] {
        player.applyCaptionPreferences(preference: .off, languages: ["en"], languagesAreExplicit: true)
        player.addExternalSubtitleTracks(first)
        let track = try #require(player.subtitleTracks.first)
        #expect(track.id >= 1_000_000)
        let menu = AppleStockPlayerSubtitles()
        menu.select(track.id, on: player)
        while player.subtitleCues.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(player.subtitleCues.first?.text == "HOLA DESDE ESPANA")
        menu.refresh(from: player)
        #expect(menu.menuEntries.first(where: { $0.title == "English" })?.isSelected == true)
        menu.select(nil, on: player)
        #expect(menu.menuEntries.first?.isSelected == true)
        #expect(player.subtitleCues.isEmpty)
        player.stop()
    }

    let engine = FakePlaybackEngine()
    engine.loadHandler = { _ in
        engine.externalSubtitleTracks = []
        engine.phase = .playing
    }
    let coordinator = ApplePlaybackCoordinator(engine: engine)
    var request = ApplePlaybackRequest(url: video, mediaID: "fixture", sourceKind: .files)
    await coordinator.begin(request)
    while engine.externalSubtitleTracks.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(engine.externalSubtitleTracks.map(\.displayName) == ["English", "French"])
    coordinator.stop()
    request.isLive = true
    await coordinator.begin(request)
    for _ in 0..<20 { await Task.yield() }
    #expect(engine.externalSubtitleTracks.isEmpty)
    coordinator.stop()
}

private actor SiblingListingClient: AppleNetworkShareClient {
    var listings = 0
    func listShares(host: String, port: Int, credentials: AppleSMBCredentials) async throws -> [AppleSMBShare] { [] }
    func listDirectory(url: URL, credentials: AppleSMBCredentials, recursive: Bool) async throws -> [AppleSMBDirectoryEntry] {
        listings += 1
        #expect(url.path == "/Media")
        #expect(recursive == false)
        return ["Movie.en.srt", "Movie.srt", "Other.srt", "Movie.txt", "child/Movie.es.srt", "../Movie.fr.srt"].map {
            AppleSMBDirectoryEntry(name: $0, path: $0, isDirectory: false, sizeBytes: 100)
        } + [AppleSMBDirectoryEntry(name: "Movie.de.srt", path: "Movie.de.srt", isDirectory: true, sizeBytes: 100)]
    }
    func read(url: URL, credentials: AppleSMBCredentials, range: Range<UInt64>) async throws -> Data {
        Issue.record("Discovery must not download subtitle files")
        return Data()
    }
}
