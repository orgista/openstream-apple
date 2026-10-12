import Foundation
import Testing
@testable import OpenStreamApple

struct AppleCatalogArtworkPolicyTests {
    private let backdrop = URL(string: "https://fixture.example/backdrop.jpg")!
    private let poster = URL(string: "https://fixture.example/poster.jpg")!

    @Test func failedBackdropAdvancesToPosterThenCinemeta() {
        let item = AppleCatalogItem(mediaID: "tt1234567", type: "movie", name: "Fixture", posterURL: poster, backgroundURL: backdrop)
        let urls = AppleCatalogArtworkPolicy.candidates(item: item, landscape: true)
        #expect(urls.prefix(2) == [backdrop, poster])
        #expect(urls.count == 4)
        #expect(AppleCatalogArtworkPolicy.next(in: urls, failed: [backdrop]) == poster)
        #expect(AppleCatalogArtworkPolicy.next(in: urls, failed: [backdrop, poster]) == urls[2])
        #expect(AppleCatalogArtworkPolicy.next(in: urls, failed: Set(urls.dropLast())) == urls.last)
        #expect(AppleCatalogArtworkPolicy.next(in: urls, failed: Set(urls)) == nil)
    }

    @Test func posterOnlyLandscapeTileUsesRealArtImmediately() {
        let item = AppleCatalogItem(mediaID: "tt1234567", type: "movie", name: "Fixture", posterURL: poster)
        #expect(AppleCatalogArtworkPolicy.candidates(item: item, landscape: true).first == poster)
    }

    @Test func missingArtStillTriesCinemetaForCanonicalID() {
        let item = AppleCatalogItem(mediaID: "tt1234567", type: "movie", name: "Fixture")
        #expect(AppleCatalogArtworkPolicy.candidates(item: item, landscape: true).count == 2)
    }

    @Test func unknownIdentityDoesNotInventArt() {
        let item = AppleCatalogItem(mediaID: "unresolved-rank-2", type: "movie", name: "Fixture")
        #expect(AppleCatalogArtworkPolicy.candidates(item: item, landscape: true).isEmpty)
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
