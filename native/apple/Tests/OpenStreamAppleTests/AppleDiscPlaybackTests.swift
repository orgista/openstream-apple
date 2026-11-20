import Foundation
import CoreGraphics
import AetherEngine
import SwiftUI
import Testing
@testable import OpenStreamApple

@Suite("Disc playback")
struct AppleDiscPlaybackTests {
    @Test("Play Disc opens navigation; explicit Titles and Skip to Movie bypass it")
    func startMapping() {
        #expect(AppleDiscPlaybackChoice(start: .menu).engineStartMode == .menu)
        #expect(AppleDiscPlaybackChoice(start: .mainTitle).engineStartMode == .mainTitle)
        #expect(AppleDiscPlaybackChoice(start: .menu, titleID: 3).engineStartMode == .mainTitle)
        #expect(AppleDiscPlaybackStart.engineTitleID(start: .menu, titleID: nil) == nil)
        #expect(AppleDiscPlaybackStart.engineTitleID(start: .mainTitle, titleID: nil) == nil)
        #expect(AppleDiscPlaybackChoice(start: .mainTitle, titleID: 3).engineTitleID == 3)
        #expect(AppleDiscPlaybackChoice(start: .menu).traceLine.hasPrefix("disc start menu"))
        #expect(AppleDiscPlaybackChoice(start: .mainTitle).traceLine == "disc start main title")
        #expect(AppleDiscPlaybackChoice(start: .mainTitle, titleID: 2).traceLine == "disc start title 2")
    }

    @Test("The disc start choice reaches Aether load options")
    func engineOptions() {
        var request = ApplePlaybackRequest(url: URL(fileURLWithPath: "/tmp/menu-test.iso"), mediaID: "disc", sourceKind: .files)
        #expect(AetherPlaybackEngine.loadOptions(for: request, headers: [:]).dvdStartMode == .mainTitle)
        request.hints.disc = AppleDiscPlaybackChoice(start: .menu)
        #expect(AetherPlaybackEngine.loadOptions(for: request, headers: [:]).dvdStartMode == .menu)
        request.hints.disc = AppleDiscPlaybackChoice(start: .mainTitle)
        #expect(AetherPlaybackEngine.loadOptions(for: request, headers: [:]).dvdStartMode == .mainTitle)
        request.hints.disc = AppleDiscPlaybackChoice(start: .menu, titleID: 2)
        #expect(AetherPlaybackEngine.loadOptions(for: request, headers: [:]).dvdStartMode == .mainTitle)
    }

    @Test("DVD title handoffs do not end the disc session")
    func discPhaseHandoffs() {
        #expect(AetherPlaybackEngine.forwardedPhase(.ended, hasDiscSession: true) == nil)
        #expect(AetherPlaybackEngine.forwardedPhase(.idle, hasDiscSession: true) == nil)
        #expect(AetherPlaybackEngine.forwardedPhase(.playing, hasDiscSession: true) == .playing)
        #expect(AetherPlaybackEngine.forwardedPhase(.paused, hasDiscSession: true) == .paused)
        #expect(AetherPlaybackEngine.forwardedPhase(.ended, hasDiscSession: false) == .ended)
        #expect(AetherPlaybackEngine.forwardedPhase(.idle, hasDiscSession: false) == .idle)
    }

    @Test("Remote and keyboard arrows preserve DVD directions")
    func menuDirections() {
        #expect(AppleDiscMenuInput.direction(.up) == .up)
        #expect(AppleDiscMenuInput.direction(.down) == .down)
        #expect(AppleDiscMenuInput.direction(.left) == .left)
        #expect(AppleDiscMenuInput.direction(.right) == .right)
    }

    @Test("A tap maps through the fitted picture after rotation, excluding letterbox")
    func menuTap() {
        for container in [CGSize(width: 402, height: 874), CGSize(width: 874, height: 402)] {
            let picture = AppleVideoFitting.fittedRect(container: container, videoSize: CGSize(width: 4, height: 3))
            #expect(AppleDiscMenuInput.normalizedPoint(CGPoint(x: picture.midX, y: picture.midY),
                container: container, videoSize: CGSize(width: 4, height: 3)) == CGPoint(x: 0.5, y: 0.5))
            #expect(AppleDiscMenuInput.normalizedPoint(CGPoint(x: -1, y: -1),
                container: container, videoSize: CGSize(width: 4, height: 3)) == nil)
        }
    }

    @Test("ISO images and files inside VIDEO_TS or BDMV are disc items; ordinary files are not")
    func discDetection() {
        #expect(AppleDiscImagePolicy.isDiscImage(path: "Movies/Heat (1995).iso"))
        #expect(AppleDiscImagePolicy.isDiscImage(path: "Movies/Heat (1995).ISO"))
        #expect(AppleDiscImagePolicy.isDiscImage(path: "Movies/Heat/VIDEO_TS/VTS_01_1.VOB"))
        #expect(AppleDiscImagePolicy.isDiscImage(path: "Movies/Heat/BDMV/STREAM/00001.m2ts"))
        #expect(!AppleDiscImagePolicy.isDiscImage(path: "Movies/Heat (1995).mkv"))
        #expect(!AppleDiscImagePolicy.isDiscImage(path: "Movies/BDMV.mkv"))
        #expect(AppleDiscImagePolicy.isDiscImage(path: "/media/Share/Movies/Heat.udf"))
        #expect(!AppleDiscImagePolicy.isDiscImage(path: "/media/Share/Movies/iso"))
        #expect(AppleLibraryScanner.supportedExtensions.contains("iso"))
    }

    @Test("The Titles row lists real titles, the main feature first, and only when there is a choice")
    func titleRows() {
        let titles = [
            AppleDiscTitle(id: 1, durationSeconds: 300, chapterCount: 1),
            AppleDiscTitle(id: 0, durationSeconds: 6_120, chapterCount: 24),
            AppleDiscTitle(id: 2, durationSeconds: 2, chapterCount: 0),
        ]
        let rows = AppleDiscTitleList(titles)
        #expect(rows.visible.map(\.id) == [0, 1])
        #expect(rows.more.isEmpty)
        #expect(rows.visible[0].name == "Main Feature")
        #expect(rows.visible[1].name == "Title 2")
        #expect(rows.visible[0].detailLabel == "1 hr 42 min · 24 chapters")
        #expect(rows.visible[1].detailLabel == "5 min")
        #expect(AppleDiscTitle(id: 4, durationSeconds: 45, chapterCount: 0).durationLabel == "45 sec")
        #expect(AppleDiscTitleList([titles[1]]).isEmpty)
        #expect(AppleDiscTitleList([titles[1], titles[2]]).isEmpty)
    }

    /// Shaped like the owner's Matilda UHD ISO (Apple TV 4K 2026-10-15: "Blu-ray
    /// recognized: 28 title(s), selected 0"): the feature, its alternate-language
    /// and commentary-free copies, a handful of extras, and a pile of logos,
    /// trailers and menu stubs.
    static let matildaUHD: [AppleDiscTitle] = {
        var titles = [
            AppleDiscTitle(id: 0, durationSeconds: 5_886.4, chapterCount: 16),
            AppleDiscTitle(id: 1, durationSeconds: 5_885.1, chapterCount: 16),   // same feature, other playlist
            AppleDiscTitle(id: 2, durationSeconds: 5_887.9, chapterCount: 16),   // same feature, ±1.5 s
            AppleDiscTitle(id: 3, durationSeconds: 5_886.4, chapterCount: 1),    // one-chapter copy: kept, different
            AppleDiscTitle(id: 4, durationSeconds: 1_510, chapterCount: 5),
            AppleDiscTitle(id: 5, durationSeconds: 1_222, chapterCount: 1),
            AppleDiscTitle(id: 6, durationSeconds: 902, chapterCount: 1),
            AppleDiscTitle(id: 7, durationSeconds: 640, chapterCount: 1),
            AppleDiscTitle(id: 8, durationSeconds: 410, chapterCount: 1),
            AppleDiscTitle(id: 9, durationSeconds: 305, chapterCount: 1),
            AppleDiscTitle(id: 10, durationSeconds: 248, chapterCount: 1),
            AppleDiscTitle(id: 11, durationSeconds: 150, chapterCount: 1),
        ]
        // 16 trailers, logos and menu loops under two minutes.
        for id in 12..<28 { titles.append(AppleDiscTitle(id: id, durationSeconds: Double(130 - (id - 12) * 8), chapterCount: 1)) }
        return titles
    }()

    @Test("A 28-title UHD disc lists the feature once, then its extras, with More for the rest")
    func matildaTitles() {
        #expect(Self.matildaUHD.count == 28)
        let list = AppleDiscTitleList(Self.matildaUHD)
        #expect(list.visible.first?.id == 0)
        #expect(list.visible.first?.name == "Main Feature")
        #expect(!list.all.contains { $0.id == 1 || $0.id == 2 })
        #expect(list.visible.map(\.id) == [0, 3, 4, 5, 6, 7])
        // 130 s and 122 s pass the two-minute line; 114 s and shorter do not.
        #expect(list.more.map(\.id) == [8, 9, 10, 11, 12, 13])
        #expect(list.all.allSatisfy { $0.durationSeconds >= AppleDiscTitleList.minimumSeconds })
        #expect(Set(list.all.map(\.id)).count == list.all.count)
    }

    @Test("An obfuscated disc with 300 copies of the feature lists it once")
    func obfuscatedTitles() {
        var titles = (0..<300).map { id in
            // Same film, clip order shuffled per playlist: lengths within a second.
            AppleDiscTitle(id: id, durationSeconds: 7_980 + Double(id % 7) * 0.25, chapterCount: 32)
        }
        titles.append(AppleDiscTitle(id: 300, durationSeconds: 1_800, chapterCount: 4))
        titles.append(AppleDiscTitle(id: 301, durationSeconds: 15, chapterCount: 1))
        let list = AppleDiscTitleList(titles)
        #expect(list.visible.map(\.id) == [0, 300])
        #expect(list.more.isEmpty)

        // A disc whose decoys differ in length still yields a finite row.
        let decoys = (0..<300).map { AppleDiscTitle(id: $0, durationSeconds: 8_000 - Double($0) * 5, chapterCount: 32) }
        let capped = AppleDiscTitleList(decoys)
        #expect(capped.visible.count == AppleDiscTitleList.visibleLimit)
        #expect(capped.more.count == AppleDiscTitleList.moreLimit)
        #expect(capped.visible.first?.id == 0)
    }

    @Test("The engine's main title leads even when a longer playlist exists")
    func mainFeatureFirst() {
        let list = AppleDiscTitleList([
            AppleDiscTitle(id: 1, durationSeconds: 9_000, chapterCount: 1),
            AppleDiscTitle(id: 0, durationSeconds: 6_000, chapterCount: 20),
        ])
        #expect(list.visible.map(\.id) == [0, 1])
    }

    @Test("Blu-ray and UHD images are told apart from DVDs by folder, name and size")
    func discFormat() {
        #expect(AppleDiscImagePolicy.format(path: "Movies/Matilda.1996.COMPLETE.UHD.BLURAY-B0MBARDiERS.iso") == .bluRay)
        #expect(AppleDiscImagePolicy.format(path: "Movies/Heat (1995) Blu-ray.iso") == .bluRay)
        #expect(AppleDiscImagePolicy.format(path: "Movies/Heat/BDMV/STREAM/00001.m2ts") == .bluRay)
        #expect(AppleDiscImagePolicy.format(path: "Movies/Heat/VIDEO_TS/VTS_01_1.VOB") == .dvd)
        #expect(AppleDiscImagePolicy.format(path: "Movies/Heat (1995).iso", sizeBytes: 7_900_000_000) == .dvd)
        #expect(AppleDiscImagePolicy.format(path: "Movies/Heat (1995).iso", sizeBytes: 48_000_000_000) == .bluRay)
        #expect(AppleDiscImagePolicy.format(path: "Movies/Huddersfield (2001).iso") == .dvd)
        #expect(AppleDiscImagePolicy.format(path: "Movies/menu-test.iso") == .dvd)
    }

    @Test("A Blu-ray offers no menu: Play goes to the main feature and the trace says why")
    func bluRayNoMenu() {
        #expect(AppleDiscFormat.dvd.supportsMenu)
        #expect(!AppleDiscFormat.bluRay.supportsMenu)
        let bluRay = AppleDiscPlaybackChoice(start: .menu, format: .bluRay)
        #expect(bluRay.start == .mainTitle)
        #expect(bluRay.engineStartMode == .mainTitle)
        #expect(bluRay.engineTitleID == nil)
        #expect(bluRay.traceLine == "disc start main title (Blu-ray: disc menus are not supported, playing the main feature)")
        let title = AppleDiscPlaybackChoice(start: .mainTitle, titleID: 4, format: .bluRay)
        #expect(title.traceLine == "disc start title 4")
        #expect(title.engineTitleID == 4)
        // DVDs keep their menu.
        let dvd = AppleDiscPlaybackChoice(start: .menu, format: .dvd)
        #expect(dvd.engineStartMode == .menu)

        var request = ApplePlaybackRequest(url: URL(fileURLWithPath: "/tmp/Matilda.UHD.BLURAY.iso"), mediaID: "disc", sourceKind: .files)
        request.hints.disc = bluRay
        #expect(AetherPlaybackEngine.loadOptions(for: request, headers: [:]).dvdStartMode == .mainTitle)
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
        // The engine's read of the image wins over the name.
        let item = AppleLibraryItem(sourceID: UUID(), name: "Matilda", url: URL(fileURLWithPath: "/tmp/Matilda.UHD.BLURAY.iso"),
                                    relativePath: "Matilda.UHD.BLURAY.iso", sizeBytes: 60_000_000_000)
        #expect(catalog.format(for: item) == .bluRay)
        catalog.record(.dvd, for: item.url)
        #expect(catalog.format(for: item) == .dvd)
    }

    @Test("A disc start rides on the request hints")
    func requestHints() {
        var hints = ApplePlaybackRequest.Hints()
        #expect(hints.disc == nil)
        hints.disc = AppleDiscPlaybackChoice(start: .menu)
        #expect(hints.disc?.engineTitleID == nil)
        #expect(hints != ApplePlaybackRequest.Hints())
    }

    @Test func aBluRaySizedImageOnAShareIsABluRay() {
        let size: Int64 = 27_800_000_000
        #expect(AppleDiscImagePolicy.format(path: "Media/movies/The Last Airbender (2010).iso", sizeBytes: size) == .bluRay)
        #expect(AppleDiscImagePolicy.format(path: "Media/movies/The Last Airbender (2010).iso", sizeBytes: 7_900_000_000) == .dvd)
    }
}
