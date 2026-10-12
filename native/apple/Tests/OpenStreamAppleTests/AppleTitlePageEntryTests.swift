import Foundation
import Testing
@testable import OpenStreamApple

/// N49 #17, #20, #21: the title page keeps Discover's bar from every entry
/// point, draws no YouTube chrome over a playing trailer, and never shows a
/// logo-only poster as a grey box.
@Suite("Title page entry points, trailer chrome and logo posters")
struct AppleTitlePageEntryTests {
    private func item(_ mediaID: String, poster: String? = nil, background: String? = nil) -> AppleCatalogItem {
        AppleCatalogItem(
            mediaID: mediaID,
            type: "series",
            name: "Fixture",
            posterURL: poster.flatMap(URL.init(string:)),
            backgroundURL: background.flatMap(URL.init(string:))
        )
    }

    /// Every tab a title page can be opened from hands it Search then
    /// Refresh (the page draws them beside Back); the page itself adds none.
    @Test(arguments: [OpenStreamTab.home, .library])
    func titlePageOpenedFromATabCarriesItsSearchAndRefresh(tab: OpenStreamTab) {
        #expect(AppleTabToolbarPolicy.items(for: tab, isTV: false) == [.search, .refresh])
    }

    @Test func aLogoPosterIsDrawnOverTheTitlesOwnBackdrop() throws {
        let poster = "https://fixture.example/logo.png"
        let backdrop = "https://fixture.example/backdrop.jpg"
        let value = item("fixture:1", poster: poster, background: backdrop)
        #expect(AppleCatalogArtworkPolicy.plateBackdrop(item: value, showing: URL(string: poster))
                == URL(string: backdrop))
    }

    @Test func aLogoPosterFallsBackToAResolvedThenCinemetaBackdrop() throws {
        let resolved = AppleArtworkResolver.Artwork(posterURL: nil,
                                                    backgroundURL: URL(string: "https://fixture.example/resolved.jpg"))
        let noArt = item("fixture:2", poster: "https://fixture.example/logo.png")
        #expect(AppleCatalogArtworkPolicy.plateBackdrop(item: noArt, fallback: resolved, showing: noArt.posterURL)
                == resolved.backgroundURL)
        let imdb = item("tt0098844", poster: "https://fixture.example/logo.png")
        let cinemeta = try #require(AppleCatalogArtworkPolicy.plateBackdrop(item: imdb, showing: imdb.posterURL))
        #expect(cinemeta.absoluteString.contains("/background/"))
        #expect(cinemeta.absoluteString.contains("tt0098844"))
    }

    @Test func theBackdropIsNeverTheImageAlreadyShown() {
        let shown = "https://fixture.example/only.jpg"
        let value = item("fixture:3", poster: shown, background: shown)
        #expect(AppleCatalogArtworkPolicy.plateBackdrop(item: value, showing: URL(string: shown)) == nil)
    }

    /// The iPhone/iPad title page's web view hides the same YouTube chrome
    /// (the centre play/pause glyph, captions) as the Mac hero's.
    @Test func trailerChromeIsHiddenOnEveryHost() {
        for script in [AppleYouTubePreviewHTML.playerChromeScript, AppleYouTubePreviewHTML.macPlayerFrameScript] {
            #expect(script.contains(#"[class^="player-controls"]"#) == false)
            #expect(script.contains(".ytp-bezel"))
            #expect(script.contains("display:none!important"))
            #expect(script.contains("youtube(-nocookie)?"))
        }
    }
}
