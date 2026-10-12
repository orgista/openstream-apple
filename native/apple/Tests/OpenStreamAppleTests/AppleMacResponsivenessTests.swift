import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import OpenStreamApple

/// The N34 Mac responsiveness fixes: each one keeps what is drawn and only
/// stops work nobody sees.
@Suite("Mac responsiveness")
struct AppleMacResponsivenessTests {
    @Test("The Mac page dot's fill redraws once per half device pixel",
          arguments: [(2, 12.0 / 88.0), (1, 12.0 / 44.0), (3, 12.0 / 132.0)] as [(CGFloat, TimeInterval)])
    func fillTicksPerHalfPixel(displayScale: CGFloat, expected: TimeInterval) {
        let cycle = AppleHeroRotation.Cycle(count: 5, interval: 12)
        let tick = cycle.fillTickInterval(width: AppleMacHeroPageDots.activeWidth, displayScale: displayScale)
        #expect(abs(tick - expected) < 0.000_1)
        // Each tick moves the fill no more than half a device pixel.
        let pixelsPerTick = AppleMacHeroPageDots.activeWidth * displayScale * tick / 12
        #expect(pixelsPerTick <= 0.5 + 0.000_1)
    }

    @Test func fillTickStaysBetween30HzAndTwiceASecond() {
        let quick = AppleHeroRotation.Cycle(count: 5, interval: 0.5)
        #expect(quick.fillTickInterval(width: 22, displayScale: 2) == 1.0 / 30.0)
        let slow = AppleHeroRotation.Cycle(count: 5, interval: 600)
        #expect(slow.fillTickInterval(width: 22, displayScale: 2) == 0.5)
        let empty = AppleHeroRotation.Cycle(count: 5, interval: 12)
        #expect(empty.fillTickInterval(width: 0, displayScale: 2) == 0.5)
        // A zero scale (no screen yet) is treated as 1x rather than dividing by zero.
        #expect(empty.fillTickInterval(width: 22, displayScale: 0) == 12.0 / 44.0)
    }

    @Test("A title-indexed lookup matches exactly as the per-call one does",
          arguments: [
              ("The Perfect Family", "movie", nil), ("perfect family", "movie", nil), ("Perfect Family", "series", nil),
              ("Amélie", "movie", nil), ("AMELIE!", "movie", nil), ("The Office", "series", "The Office (US)"),
              ("Office", "series", nil), ("A Quiet Place", "movie", nil), ("Quiet Place", "movie", nil), ("Missing", "movie", nil),
          ] as [(String, String, String?)])
    func indexedTitleMatchingIsUnchanged(title: String, type: String, seasonTitle: String?) {
        let titles = [("tt1", "movie", "The Perfect Family"), ("tt2", "movie", "Perfect Family"), ("tt3", "movie", "Amélie"),
                      ("tt4", "series", "The Office"), ("tt5", "series", "Office"), ("tt6", "movie", "A Quiet Place"),
                      ("tt7", "movie", "The Quiet Place")]
        let source = Self.source
        let plain = Self.lookup(titles, source: source, indexesTitles: false)
        let indexed = Self.lookup(titles, source: source, indexesTitles: true)
        for ignoringArticle in [false, true] {
            let expected = plain.match(title: title, type: type, seasonTitle: seasonTitle, ignoringLeadingArticle: ignoringArticle)
            let actual = indexed.match(title: title, type: type, seasonTitle: seasonTitle, ignoringLeadingArticle: ignoringArticle)
            #expect(actual == expected)
        }
        // The fixture exercises both outcomes, not only misses.
        if title == "The Perfect Family" { #expect(plain.match(title: title, type: type)?.item.mediaID == "tt1") }
    }

    @Test func discoverBuildsItsLookupWithTheTitleIndex() async {
        let catalog = AppleStremioCatalog(type: "movie", id: "top")
        let source = AppleSource(kind: .stremio, name: "Fixture", url: URL(string: "https://fixture.example/manifest.json")!,
                                 resources: ["catalog"], catalogs: [catalog])
        let section = AppleCatalogSection(source: source, catalog: catalog,
                                          items: [AppleCatalogItem(mediaID: "tt1", type: "movie", name: "The Perfect Family")])
        let lookup = await AppleCatalogSearchLookup.buildOffMain(sections: [section], sources: [source])
        #expect(lookup.match(title: "Perfect Family", type: "movie", ignoringLeadingArticle: true)?.item.mediaID == "tt1")
    }

    private static var source: AppleSource {
        AppleSource(kind: .stremio, name: "Fixture", url: URL(string: "https://fixture.example/manifest.json")!,
                    resources: ["catalog"], catalogs: [AppleStremioCatalog(type: "movie", id: "top"),
                                                       AppleStremioCatalog(type: "series", id: "top")])
    }

    private static func lookup(_ titles: [(String, String, String)], source: AppleSource,
                               indexesTitles: Bool) -> AppleCatalogSearchLookup {
        let sections = ["movie", "series"].map { type in
            AppleCatalogSection(source: source, catalog: AppleStremioCatalog(type: type, id: "top"),
                                items: titles.filter { $0.1 == type }.map { AppleCatalogItem(mediaID: $0.0, type: $0.1, name: $0.2) })
        }
        return AppleCatalogSearchLookup(sections: sections, sources: [source], indexesTitles: indexesTitles)
    }

    @Test func rememberedStorageKeysMatchFreshlyHashedOnes() throws {
        let fresh = "sha256:" + ApplePlaybackIdentity.digest(for: "tt0903747:1:2")
        #expect(ApplePlaybackIdentity.storageKey(for: "tt0903747:1:2") == fresh)
        #expect(ApplePlaybackIdentity.storageKey(for: "tt0903747:1:2") == fresh)
        #expect(ApplePlaybackIdentity.storageKey(for: "  tt0903747:1:2\n") == fresh)
        #expect(ApplePlaybackIdentity.storageKey(for: fresh) == fresh)
        #expect(ApplePlaybackIdentity.storageKey(for: "   ") == nil)
        // Past the bound it starts over and still answers correctly.
        for index in 0 ... ApplePlaybackIdentity.mediaIDKeyLimit {
            _ = ApplePlaybackIdentity.storageKey(for: "n34-bound-\(index)")
        }
        #expect(ApplePlaybackIdentity.storageKey(for: "n34-bound-7") == "sha256:" + ApplePlaybackIdentity.digest(for: "n34-bound-7"))
        #expect(ApplePlaybackIdentity.storageKey(for: "tt0903747:1:2") == fresh)
    }

    @MainActor @Test func aLazyDestinationBuildsNothingUntilItIsShown() {
        let builds = BuildCounter()
        let destination = AppleLazyDestination {
            builds.count += 1
            return Text("Title page")
        }
        #expect(builds.count == 0)
        _ = destination.body
        #expect(builds.count == 1)
    }
}

@MainActor
private final class BuildCounter {
    var count = 0
}
