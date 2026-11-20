import Foundation
import Testing
@testable import OpenStreamApple

struct AppleCatalogArtworkPolicyTests {
    private let backdrop = URL(string: "https://fixture.example/backdrop.jpg")!
    private let poster = URL(string: "https://fixture.example/poster.jpg")!

    @Test func tmdbDisplayRequestWaitsForUnknownSizeAndUsesKnownCardPixels() {
        let url = URL(string: "https://image.tmdb.org/t/p/w500/poster.jpg")!
        let pending = AppleCatalogArtworkPolicy.displayRequest(url: url, pixels: .zero, purpose: .poster)
        #expect(pending.url == nil)
        #expect(pending.waitsForGeometry)
        let measured = AppleCatalogArtworkPolicy.displayRequest(url: url, pixels: CGSize(width: 430, height: 645), purpose: .poster)
        #expect(measured.url == URL(string: "https://image.tmdb.org/t/p/w342/poster.jpg"))
        #expect(measured.waitsForGeometry == false)
        #expect(measured.fixedPixelDimension == 513)
    }

    @Test func tmdbResizingWithinBucketKeepsURLAndDecodeIdentityAndCrossingChangesOnce() {
        let url = URL(string: "https://image.tmdb.org/t/p/w500/poster.jpg")!
        let first = AppleCatalogArtworkPolicy.displayRequest(url: url, pixels: CGSize(width: 430, height: 645), purpose: .poster)
        let within = AppleCatalogArtworkPolicy.displayRequest(url: url, pixels: CGSize(width: 440, height: 660), purpose: .poster)
        let crossed = AppleCatalogArtworkPolicy.displayRequest(url: url, pixels: CGSize(width: 641, height: 962), purpose: .poster)
        #expect(first == within)
        #expect(crossed.url == URL(string: "https://image.tmdb.org/t/p/w500/poster.jpg"))
        #expect(crossed.fixedPixelDimension == 750)
        #expect(crossed != first)
    }

    @Test func heroesStartWithoutGeometryAndSharePrefetchKeysAtScreenResolution() {
        let item = AppleCatalogItem(mediaID: "fixture", type: "movie", name: "Fixture",
            backgroundURL: URL(string: "https://image.tmdb.org/t/p/w1280/hero.jpg"))
        for pixels in [CGFloat(1920), 3840, 5120] {
            let request = AppleCatalogArtworkPolicy.heroRequest(item: item, pixelWidth: pixels)
            #expect(request.url?.path.contains("/w1280/") == true)
            #expect(request.waitsForGeometry == false)
            #expect(request.fixedPixelDimension.map(AppleArtworkSizePolicy.bucket) ?? 0 >= Int(pixels))
        }
        #expect(AppleCatalogArtworkPolicy.heroRequest(item: item, pixelWidth: 0).url != nil)
        let posterHero = AppleCatalogItem(mediaID: "poster", type: "movie", name: "Fixture",
            posterURL: URL(string: "https://image.tmdb.org/t/p/w500/poster.jpg"))
        let posterRequest = AppleCatalogArtworkPolicy.heroRequest(item: posterHero, pixelWidth: 3840)
        #expect(posterRequest.url?.path.contains("/w780/") == true)
        #expect(posterRequest.fixedPixelDimension == 5760)
        let provider = AppleCatalogItem(mediaID: "provider", type: "movie", name: "Fixture", backgroundURL: backdrop)
        let request = AppleCatalogArtworkPolicy.heroRequest(item: provider, pixelWidth: 3840)
        #expect(request.url == backdrop)
        #expect(request.fixedPixelDimension == 3840)
    }

    /// Doctor X on a test Apple TV (walk b20r19): Rill listed a series backdrop its
    /// proxy answered with a 502, and the hero went blank.
    @Test func aHeroStillThatFailsGivesWayToTheCatalogBackdropThenThePoster() throws {
        let catalog = try #require(URL(string: "https://fixture.example/catalog-backdrop.jpg"))
        let item = AppleCatalogItem(mediaID: "fixture", type: "series", name: "Fixture",
                                    posterURL: poster, backgroundURL: backdrop)
        func next(_ failed: Set<URL>) -> AppleCatalogArtworkPolicy.DisplayRequest? {
            AppleCatalogArtworkPolicy.heroRequest(item: item, catalogBackdropURL: catalog, pixelWidth: 3840, skipping: failed)
        }
        #expect(next([]) == AppleCatalogArtworkPolicy.heroRequest(item: item, pixelWidth: 3840))
        #expect(next([backdrop])?.url == catalog)
        #expect(next([backdrop])?.fixedPixelDimension == 3840)
        #expect(next([backdrop, catalog])?.url == poster)
        #expect(next([backdrop, catalog])?.fixedPixelDimension == 5760)
        #expect(next([backdrop, catalog, poster]) == nil)
        let posterOnly = AppleCatalogItem(mediaID: "poster", type: "movie", name: "Fixture", posterURL: poster)
        #expect(AppleCatalogArtworkPolicy.heroRequest(item: posterOnly, catalogBackdropURL: nil, pixelWidth: 3840,
                                                      skipping: []) == AppleCatalogArtworkPolicy.heroRequest(item: posterOnly, pixelWidth: 3840))
    }

    @Test func aFailedArtworkUpgradeKeepsTheStillAlreadyOnScreen() throws {
        let upgrade = try #require(URL(string: "https://fixture.example/upgrade.jpg"))
        let shown = AppleHeroStillPage(id: "series", url: poster)
        let upgraded = AppleCatalogItem(mediaID: "series", type: "series", name: "Fixture",
                                        posterURL: poster, backgroundURL: upgrade)
        let failedUpgrade = AppleCatalogArtworkPolicy.heroRequest(item: upgraded, catalogBackdropURL: nil,
                                                                  pixelWidth: 3840, skipping: [upgrade])
        let current = AppleHeroStillPage(id: "series", url: failedUpgrade?.url)
        #expect(current == shown)
        #expect(AppleHeroStillPage.displayed(current: current, retained: shown) == shown)
    }

    @Test func displayRequestNeverHoldsOrRewritesSignedOrProviderURLs() {
        let urls = [poster, URL(string: "https://image.tmdb.org/t/p/w500/poster.jpg?signature=fixture")!,
                    URL(string: "https://image.tmdb.org/not-an-image.jpg")!]
        for url in urls {
            let pending = AppleCatalogArtworkPolicy.displayRequest(url: url, pixels: .zero, purpose: .poster)
            let measured = AppleCatalogArtworkPolicy.displayRequest(url: url, pixels: CGSize(width: 430, height: 645), purpose: .poster)
            #expect(pending.url == url)
            #expect(pending == measured)
            #expect(pending.waitsForGeometry == false)
            #expect(pending.fixedPixelDimension == nil)
        }
    }

    @Test(arguments: ["jellyfin", "emby"])
    func mediaServerImagesResizeForTheDisplayedCard(_ server: String) throws {
        let url = try #require(URL(string: "https://fixture.example/" + server + "/Items/123/Images/Primary?tag=fixture&maxWidth=600&api_key=fixture"))
        let first = AppleCatalogArtworkPolicy.displayRequest(url: url, pixels: CGSize(width: 230, height: 345), purpose: .poster)
        let within = AppleCatalogArtworkPolicy.displayRequest(url: url, pixels: CGSize(width: 240, height: 360), purpose: .poster)
        #expect(first == within)
        let resized = try #require(first.url)
        let query = try #require(URLComponents(url: resized, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query.first { $0.name == "maxWidth" }?.value == "224")
        #expect(query.first { $0.name == "fillWidth" }?.value == "224")
        #expect(query.first { $0.name == "quality" }?.value == "85")
        #expect(query.first { $0.name == "tag" }?.value == "fixture")
        #expect(query.first { $0.name == "api_key" }?.value == "fixture")
        #expect(resized.path == url.path)
        #expect(first.fixedPixelDimension == 336)
    }

    @Test func plexTranscodeResizesBothDimensionsAndPreservesItsSourceAndToken() throws {
        let url = try #require(URL(string: "https://fixture.example/photo/:/transcode?width=600&height=900&url=%2Flibrary%2Fmetadata%2F123%2Fthumb&X-Plex-Token=fixture&minSize=1"))
        let request = AppleCatalogArtworkPolicy.displayRequest(url: url, pixels: CGSize(width: 480, height: 270), purpose: .resume)
        let resized = try #require(request.url)
        let query = try #require(URLComponents(url: resized, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query.first { $0.name == "width" }?.value == "480")
        #expect(query.first { $0.name == "height" }?.value == "270")
        #expect(query.first { $0.name == "url" }?.value == "/library/metadata/123/thumb")
        #expect(query.first { $0.name == "X-Plex-Token" }?.value == "fixture")
        #expect(query.first { $0.name == "minSize" }?.value == "1")
        #expect(request.fixedPixelDimension == 480)
    }

    @Test func plexPosterFallbackKeepsItsAspectInALandscapeCard() throws {
        let url = try #require(URL(string: "https://fixture.example/photo/:/transcode?width=600&height=900&url=%2Flibrary%2Fmetadata%2F123%2Fthumb&X-Plex-Token=fixture"))
        let request = AppleCatalogArtworkPolicy.displayRequest(url: url, pixels: CGSize(width: 480, height: 270), purpose: .poster)
        let resized = try #require(request.url)
        let query = try #require(URLComponents(url: resized, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query.first { $0.name == "width" }?.value == "160")
        #expect(query.first { $0.name == "height" }?.value == "240")
    }

    @Test func tvCardAndShelfPrefetchUseTheSameFirstRequest() {
        let url = URL(string: "https://image.tmdb.org/t/p/w500/poster.jpg")!
        let item = AppleCatalogItem(mediaID: "fixture", type: "movie", name: "Fixture", posterURL: url)
        // Apple TV uses a known 230-point poster width at 2x display scale.
        let pixels = CGSize(width: 460, height: 690)
        let request = AppleCatalogArtworkPolicy.displayRequest(url: url, pixels: pixels, purpose: .poster)
        let prefetch = AppleArtworkPrefetchPolicy.requests(items: [item], pixels: pixels, landscape: false)
        #expect(prefetch.first?.url == request.url)
        #expect(prefetch.first?.maximumPixelDimension == request.fixedPixelDimension.map(AppleArtworkSizePolicy.bucket))
        #expect(request.url?.path.contains("/w342/") == true)
    }

    @Test(arguments: [230.0, 280, 420, 460, 640, 780])
    func tileRequestsStayWithinTheirPixelWidth(_ width: Double) throws {
        let pixels = CGSize(width: width, height: width * 1.5)
        let tmdb = try #require(URL(string: "https://image.tmdb.org/t/p/w500/poster.jpg"))
        let server = try #require(URL(string: "https://fixture.example/Items/123/Images/Primary?maxWidth=600&tag=fixture"))
        let tmdbRequest = AppleCatalogArtworkPolicy.displayRequest(url: tmdb, pixels: pixels, purpose: .poster)
        let size = try #require(tmdbRequest.url?.path.split(separator: "/").dropFirst(2).first)
        #expect(try #require(Int(size.dropFirst())) <= Int(width))
        let serverRequest = AppleCatalogArtworkPolicy.displayRequest(url: server, pixels: pixels, purpose: .poster)
        let query = try #require(serverRequest.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems })
        let requestedWidth = try #require(query.first { $0.name == "maxWidth" }?.value.flatMap(Int.init))
        #expect(requestedWidth <= Int(width))
    }

    @Test func landscapePosterFallbackFitsBothTileDimensions() throws {
        let url = try #require(URL(string: "https://image.tmdb.org/t/p/w500/poster.jpg"))
        let request = AppleCatalogArtworkPolicy.displayRequest(url: url, pixels: CGSize(width: 480, height: 270), purpose: .poster)
        #expect(request.url?.path.contains("/w154/") == true)
        #expect(request.fixedPixelDimension == 231)
    }

    @Test func metadataTaskMarkerContainsNoCredentialAndChangesWithConfiguration() throws {
        let first = try AppleTMDBConfiguration(credential: "fixture-key-one")
        let second = try AppleTMDBConfiguration(credential: "fixture-key-two")
        let marker = AppleCatalogArtworkPolicy.configurationMarker(first)
        #expect(marker.contains(first.credential) == false)
        #expect(marker == AppleCatalogArtworkPolicy.configurationMarker(first))
        #expect(marker != AppleCatalogArtworkPolicy.configurationMarker(second))
        #expect(AppleCatalogArtworkPolicy.configurationMarker(nil) == "metadata-off")
    }

    @Test func failedBackdropAdvancesToPoster() {
        let item = AppleCatalogItem(mediaID: "tt1234567", type: "movie", name: "Fixture", posterURL: poster, backgroundURL: backdrop)
        let urls = AppleCatalogArtworkPolicy.candidates(item: item, landscape: true)
        #expect(urls == [backdrop, poster])
        #expect(AppleCatalogArtworkPolicy.next(in: urls, failed: [backdrop]) == poster)
        #expect(AppleCatalogArtworkPolicy.next(in: urls, failed: Set(urls)) == nil)
    }

    @Test func posterOnlyLandscapeTileUsesRealArtImmediately() {
        let item = AppleCatalogItem(mediaID: "tt1234567", type: "movie", name: "Fixture", posterURL: poster)
        #expect(AppleCatalogArtworkPolicy.candidates(item: item, landscape: true).first == poster)
    }

    @Test func unknownIdentityDoesNotInventArt() {
        let item = AppleCatalogItem(mediaID: "unresolved-rank-2", type: "movie", name: "Fixture")
        #expect(AppleCatalogArtworkPolicy.candidates(item: item, landscape: true).isEmpty)
    }

    @Test func resolvedLandscapeArtPrecedesPosterFramingButSourceBackdropWins() {
        let item = AppleCatalogItem(mediaID: "tt1234567", type: "movie", name: "Fixture", posterURL: poster)
        let fallback = AppleArtworkResolver.Artwork(posterURL: nil, backgroundURL: backdrop)
        #expect(AppleCatalogArtworkPolicy.candidates(item: item, landscape: true, fallback: fallback).first == backdrop)
        let supplied = AppleCatalogItem(mediaID: "tt1234567", type: "movie", name: "Fixture", posterURL: poster, backgroundURL: poster)
        #expect(AppleCatalogArtworkPolicy.candidates(item: supplied, landscape: true, fallback: fallback).first == poster)
    }

    @Test func logoPurposeKeepsSourceLogoFirstAndNeverUsesPosterAsLogo() {
        let item = AppleCatalogItem(mediaID: "tt1234567", type: "movie", name: "Fixture", posterURL: poster, logoURL: backdrop)
        let fallback = AppleArtworkResolver.Artwork(posterURL: poster, backgroundURL: backdrop, logoURL: poster)
        #expect(AppleCatalogArtworkPolicy.candidates(item: item, purpose: .logo, fallback: fallback) == [backdrop, poster])
        let missing = AppleCatalogItem(mediaID: "tt1234567", type: "movie", name: "Fixture", posterURL: poster)
        #expect(AppleCatalogArtworkPolicy.candidates(item: missing, purpose: .logo).isEmpty)
    }

    @Test func landscapePosterFallbackUsesPosterSizesAndPortraitBackdropFallbackUsesBackdropSizes() {
        let item = AppleCatalogItem(mediaID: "tt1234567", type: "movie", name: "Fixture", posterURL: poster, backgroundURL: backdrop)
        #expect(AppleCatalogArtworkPolicy.purpose(of: poster, item: item, fallback: nil, preferred: .resume) == .poster)
        #expect(AppleCatalogArtworkPolicy.purpose(of: backdrop, item: item, fallback: nil, preferred: .poster) == .resume)
        #expect(AppleCatalogArtworkPolicy.purpose(of: backdrop, item: item, fallback: nil, preferred: .hero) == .hero)
    }

    /// Wonka's The Golden Ticket, Apple TV Top 10 (2026-10-01): a poster and
    /// no backdrop showed the poster's dark top third as a box.
    @Test func aPortraitPosterInASixteenByNineCardIsDrawnWhole() {
        #expect(AppleCatalogArtworkPolicy.framing(landscapeCard: true, imageWidth: 500, imageHeight: 750)
            == .posterInFrame(aspect: 500.0 / 750.0))
    }

    @Test func wideArtAndPosterCardsStillFill() {
        #expect(AppleCatalogArtworkPolicy.framing(landscapeCard: true, imageWidth: 1280, imageHeight: 720) == .fill)
        #expect(AppleCatalogArtworkPolicy.framing(landscapeCard: true, imageWidth: 720, imageHeight: 720) == .fill)
        #expect(AppleCatalogArtworkPolicy.framing(landscapeCard: false, imageWidth: 500, imageHeight: 750) == .fill)
        #expect(AppleCatalogArtworkPolicy.framing(landscapeCard: true, imageWidth: 0, imageHeight: 0) == .fill)
    }
}
