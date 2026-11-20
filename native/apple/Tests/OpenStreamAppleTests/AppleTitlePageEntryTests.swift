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

    @Test func aLogoPosterFallsBackToAResolvedBackdrop() {
        let resolved = AppleArtworkResolver.Artwork(posterURL: nil,
                                                    backgroundURL: URL(string: "https://fixture.example/resolved.jpg"))
        let noArt = item("fixture:2", poster: "https://fixture.example/logo.png")
        #expect(AppleCatalogArtworkPolicy.plateBackdrop(item: noArt, fallback: resolved, showing: noArt.posterURL)
                == resolved.backgroundURL)
        let imdb = item("tt0098844", poster: "https://fixture.example/logo.png")
        #expect(AppleCatalogArtworkPolicy.plateBackdrop(item: imdb, showing: imdb.posterURL) == nil)
    }

    @Test func theBackdropIsNeverTheImageAlreadyShown() {
        let shown = "https://fixture.example/only.jpg"
        let value = item("fixture:3", poster: shown, background: shown)
        #expect(AppleCatalogArtworkPolicy.plateBackdrop(item: value, showing: URL(string: shown)) == nil)
    }

    /// Trailers use YouTube's IFrame API as documented: the page names our
    /// own origin and leaves YouTube's player untouched.
    @Test func trailersUseTheOfficialPlayerUntouched() throws {
        let embed = try #require(AppleTrailerPreviewPolicy.embedURL(for: "trailer_456"))
        #expect(AppleTrailerPreviewPolicy.embedOrigin.host == AppleTrailerPreviewPolicy.hostBundleIdentifier(Bundle.main.bundleIdentifier))
        let query = try #require(URLComponents(url: embed, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query.first { $0.name == "origin" }?.value == AppleTrailerPreviewPolicy.embedOrigin.absoluteString)
        let html = AppleYouTubePreviewHTML.document(embedURL: embed, startsPlaying: true, startupChromeCanShow: false)
        #expect(html.contains("origin: '\(AppleTrailerPreviewPolicy.embedOrigin.absoluteString)'"))
        #expect(html.contains("origin=\(AppleTrailerPreviewPolicy.embedOrigin.absoluteString)"))
        #expect(html.contains("referrerpolicy=\"strict-origin-when-cross-origin\""))
        #expect(!html.contains("pointer-events:none"))
        #expect(!html.contains("ytp-"))
    }

    @Test func trailerHTMLReplacesAnOutdatedEmbedOrigin() throws {
        let embed = try #require(URL(string: "https://www.youtube-nocookie.com/embed/trailer_456?origin=https://fixture.example"))
        let html = AppleYouTubePreviewHTML.document(embedURL: embed, startsPlaying: true, startupChromeCanShow: false)
        #expect(!html.contains("fixture.example"))
        #expect(html.contains("origin=\(AppleTrailerPreviewPolicy.embedOrigin.absoluteString)"))
    }

    @Test(arguments: ["share", "widgets", "topshelf", "messages"])
    func trailerIdentityUsesTheHostAppForKnownExtensions(suffix: String) {
        #expect(AppleTrailerPreviewPolicy.hostBundleIdentifier("COM.Fixture.OpenStream.\(suffix)") == "com.fixture.openstream")
    }

    @Test func trailerIdentityPreservesAppIDsAndHasAStableFallback() {
        #expect(AppleTrailerPreviewPolicy.hostBundleIdentifier(nil) == "com.orgista.openstream")
        #expect(AppleTrailerPreviewPolicy.hostBundleIdentifier("COM.Fixture.OpenStream") == "com.fixture.openstream")
        #expect(AppleTrailerPreviewPolicy.hostBundleIdentifier("com.fixture.openstream.watchkitapp") == "com.fixture.openstream.watchkitapp")
    }
}
