import Foundation
import Testing
@testable import OpenStreamApple

@Suite("Disc playback")
struct AppleDiscPlaybackTests {
    @Test("Play Disc and Skip to Movie both open the main title until the engine has a menu")
    func startMapping() {
        #expect(AppleDiscPlaybackStart.engineTitleID(start: .menu, titleID: nil) == nil)
        #expect(AppleDiscPlaybackStart.engineTitleID(start: .mainTitle, titleID: nil) == nil)
        #expect(AppleDiscPlaybackChoice(start: .mainTitle, titleID: 3).engineTitleID == 3)
        #expect(AppleDiscPlaybackChoice(start: .menu).traceLine.hasPrefix("disc start menu"))
        #expect(AppleDiscPlaybackChoice(start: .mainTitle).traceLine == "disc start main title")
        #expect(AppleDiscPlaybackChoice(start: .mainTitle, titleID: 2).traceLine == "disc start title 2")
    }

    @Test("ISO images and files inside VIDEO_TS or BDMV are disc items; ordinary files are not")
    func discDetection() {
        #expect(AppleDiscImagePolicy.isDiscImage(path: "Movies/Heat (1995).iso"))
        #expect(AppleDiscImagePolicy.isDiscImage(path: "Movies/Heat (1995).ISO"))
        #expect(AppleDiscImagePolicy.isDiscImage(path: "Movies/Heat/VIDEO_TS/VTS_01_1.VOB"))
        #expect(AppleDiscImagePolicy.isDiscImage(path: "Movies/Heat/BDMV/STREAM/00001.m2ts"))
        #expect(!AppleDiscImagePolicy.isDiscImage(path: "Movies/Heat (1995).mkv"))
        #expect(!AppleDiscImagePolicy.isDiscImage(path: "Movies/BDMV.mkv"))
        #expect(AppleLibraryScanner.supportedExtensions.contains("iso"))
    }

    @Test("The Titles row lists real titles longest first and only when there is a choice")
    func titleRows() {
        let titles = [
            AppleDiscTitle(id: 1, durationSeconds: 300, chapterCount: 1),
            AppleDiscTitle(id: 0, durationSeconds: 6_120, chapterCount: 24),
            AppleDiscTitle(id: 2, durationSeconds: 2, chapterCount: 0),
        ]
        let rows = AppleDiscTitle.rowTitles(titles)
        #expect(rows.map(\.id) == [0, 1])
        #expect(rows[0].name == "Title 1")
        #expect(rows[0].durationLabel == "1 hr 42 min")
        #expect(rows[1].durationLabel == "5 min")
        #expect(AppleDiscTitle(id: 4, durationSeconds: 45, chapterCount: 0).durationLabel == "45 sec")
        #expect(AppleDiscTitle.rowTitles([titles[1]]).isEmpty)
    }

    @MainActor
    @Test("The poster badge matches the library title by IMDb id, or by name and year")
    func catalogKeys() {
        let catalog = AppleDiscCatalog()
        let local = AppleCatalogItem(mediaID: "tt0113277", type: "movie", name: "Heat", releaseInfo: "1995")
        catalog.replaceKeys([local.id, AppleDiscCatalog.matchKey(local)])
        #expect(catalog.contains(AppleCatalogItem(mediaID: "tt0113277", type: "movie", name: "Heat (1995)")))
        let unresolved = AppleCatalogItem(mediaID: "local-abc", type: "movie", name: "Menu Test", releaseInfo: "2026")
        catalog.replaceKeys([AppleDiscCatalog.matchKey(unresolved)])
        #expect(catalog.contains(AppleCatalogItem(mediaID: "tmdb:1", type: "movie", name: "Menu  Test!", releaseInfo: "2026-01-01")))
        #expect(!catalog.contains(AppleCatalogItem(mediaID: "tmdb:1", type: "movie", name: "Menu Test", releaseInfo: "2025")))
    }

    @MainActor
    @Test("Titles recorded for a disc file are kept per file and a single empty answer is ignored")
    func titleCache() {
        let catalog = AppleDiscCatalog()
        let url = URL(fileURLWithPath: "/tmp/menu-test.iso")
        catalog.record([], for: url)
        #expect(catalog.titles[url] == nil)
        catalog.record([AppleDiscTitle(id: 0, durationSeconds: 60, chapterCount: 2)], for: url)
        #expect(catalog.titles[url]?.count == 1)
    }

    @Test("A disc start rides on the request hints")
    func requestHints() {
        var hints = ApplePlaybackRequest.Hints()
        #expect(hints.disc == nil)
        hints.disc = AppleDiscPlaybackChoice(start: .menu)
        #expect(hints.disc?.engineTitleID == nil)
        #expect(hints != ApplePlaybackRequest.Hints())
    }
}
