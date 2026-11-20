import CoreGraphics
import Foundation
import Testing
@testable import OpenStreamApple

/// The iPhone title page's 16:9 header art (Mythos §5).
@Suite struct AppleTitlePageSlotArtTests {
    private let textless = URL(string: "https://fixture.example/backdrop-null.jpg")!
    private let backdrop = URL(string: "https://fixture.example/backdrop.jpg")!
    private let poster = URL(string: "https://fixture.example/poster.jpg")!

    @Test func backdropsComeBeforePosters() {
        #expect(AppleTitlePageSlotArt.choose(backdrops: [nil, textless, backdrop], posters: [poster]) == .backdrop(textless))
        #expect(AppleTitlePageSlotArt.choose(backdrops: [nil], posters: [nil, poster]) == .posterCard(poster))
        #expect(AppleTitlePageSlotArt.choose(backdrops: [], posters: []) == nil)
    }

    @Test func landingAndTitlePagesUseTheSameArtCandidates() {
        let item = AppleCatalogItem(mediaID: "tt2250912", type: "movie", name: "Fixture",
                                    posterURL: poster, backgroundURL: backdrop)
        #expect(AppleTitlePageSlotArt.choose(item: item) == .backdrop(backdrop))
        let details = AppleTMDBDetails(posterURL: poster, backdropURL: backdrop, textlessBackdropURL: textless)
        #expect(AppleTitlePageSlotArt.choose(item: item, details: details) == .backdrop(textless))
        #expect(AppleTitlePageSlotArt.choose(item: item, details: details, failed: [textless, backdrop]) == .posterCard(poster))
    }

    @Test func titlePageArtworkOnlyUpgradesToTextlessBackdrops() {
        let details = AppleTMDBDetails(posterURL: poster, backdropURL: backdrop)
        let artwork = AppleHeroArtworkUpgrade.Artwork(details: details)
        #expect(artwork.backdropURL == nil)
        #expect(artwork.titlePage?.backdropURL == nil)
        let item = AppleCatalogItem(mediaID: "tt1234567", type: "movie", name: "Fixture", backgroundURL: backdrop)
        #expect(AppleTitlePageSlotArt.choose(item: item) == .backdrop(backdrop))
        #expect(artwork.titlePage?.posterURL == poster)
        let textlessDetails = AppleTMDBDetails(backdropURL: backdrop, textlessBackdropURL: textless)
        #expect(AppleHeroArtworkUpgrade.Artwork(details: textlessDetails).titlePage?.backdropURL == textless)
    }

    @Test func oldArtworkAnswersCanBeDistinguishedFromAnAnsweredEmptyTitlePage() throws {
        let legacy = try JSONDecoder().decode(AppleHeroArtworkUpgrade.Artwork.self,
            from: Data("{\"backdropURL\":null,\"logoURL\":null}".utf8))
        #expect(legacy.titlePage == nil)
        let empty = AppleHeroArtworkUpgrade.Artwork(details: nil)
        let restored = try JSONDecoder().decode(AppleHeroArtworkUpgrade.Artwork.self,
            from: JSONEncoder().encode(empty))
        #expect(restored.titlePage != nil)
        #expect(restored.titlePage?.backdropURL == nil)
    }

    @Test func aRememberedLandingBackdropKeepsTheCatalogFallback() {
        let item = AppleCatalogItem(mediaID: "fixture", type: "movie", name: "Fixture",
                                    posterURL: poster, backgroundURL: backdrop)
        let candidates = AppleTitlePageSlotArt.landingBackdrops(item: item,
            details: AppleTMDBDetails(), remembered: .backdrop(textless))
        #expect(AppleTitlePageSlotArt.choose(backdrops: candidates, posters: [poster]) == .backdrop(textless))
        #expect(AppleTitlePageSlotArt.choose(backdrops: candidates, posters: [poster], failed: [textless]) == .backdrop(backdrop))
    }

    @Test func aFailedBackdropFallsThrough() {
        #expect(AppleTitlePageSlotArt.choose(backdrops: [textless, backdrop], posters: [poster], failed: [textless])
                == .backdrop(backdrop))
        #expect(AppleTitlePageSlotArt.choose(backdrops: [textless], posters: [poster], failed: [textless])
                == .posterCard(poster))
    }

    @Test func knownCatalogArtIsReadyBeforeAnyMetadataAnswer() {
        let art = AppleTitlePageSlotArt.backdrop(backdrop)
        #expect(AppleTitlePageSlotArt.isReady(knownArt: art, detailsAnswered: false))
        #expect(!AppleTitlePageSlotArt.isReady(knownArt: nil, detailsAnswered: false))
    }

    @Test func answeredEmptyIsAnExplicitStablePlaceholder() {
        #expect(AppleTitlePageSlotArt.isReady(knownArt: nil, detailsAnswered: true))
        #expect(AppleTitlePageSlotArt.updating(nil, with: nil) == nil)
    }

    @Test func lateBackdropUpgradesPosterAndEmptyAnswersNeverEraseKnownArt() {
        let posterArt = AppleTitlePageSlotArt.posterCard(poster)
        let backdropArt = AppleTitlePageSlotArt.backdrop(backdrop)
        #expect(AppleTitlePageSlotArt.updating(posterArt, with: backdropArt) == backdropArt)
        #expect(AppleTitlePageSlotArt.updating(backdropArt, with: posterArt) == backdropArt)
        #expect(AppleTitlePageSlotArt.updating(backdropArt, with: nil) == backdropArt)
    }

    @Test func aPendingUpgradeKeepsTheFirstImageAndRejectsObsoleteCompletions() {
        let first = AppleTitlePageSlotArt.posterCard(poster)
        let better = AppleTitlePageSlotArt.backdrop(backdrop)
        #expect(AppleTitlePageSlotArt.acceptsLoadedArt(first, requested: better, displayed: nil))
        #expect(!AppleTitlePageSlotArt.acceptsLoadedArt(first, requested: better, displayed: better))
        #expect(AppleTitlePageSlotArt.acceptsLoadedArt(better, requested: better, displayed: first))
    }

    @Test func aLandingPosterCanRequestALateBackdropWithoutChangingTheDisplayedImage() {
        let displayed = AppleTitlePageSlotArt.posterCard(poster)
        let requested = AppleTitlePageSlotArt.landingArt(displayed: displayed, requested: displayed,
            candidate: .backdrop(backdrop), failed: [])
        #expect(requested == .backdrop(backdrop))
        #expect(AppleTitlePageSlotArt.acceptsLoadedArt(.backdrop(backdrop), requested: requested, displayed: displayed))
        #expect(!AppleTitlePageSlotArt.acceptsLoadedArt(displayed, requested: requested, displayed: .backdrop(backdrop)))
    }

    @Test func aPendingLandingPosterDoesNotBlockABetterBackdrop() {
        #expect(AppleTitlePageSlotArt.landingArt(displayed: nil, requested: .posterCard(poster),
            candidate: .backdrop(backdrop), failed: []) == .backdrop(backdrop))
    }

    @Test func aLandingBackdropStaysStableWhenOtherCandidatesArrive() {
        for candidate in [AppleTitlePageSlotArt.backdrop(textless), .posterCard(poster)] {
            #expect(AppleTitlePageSlotArt.landingArt(displayed: .backdrop(backdrop), requested: .backdrop(backdrop),
                candidate: candidate, failed: []) == .backdrop(backdrop))
        }
        #expect(AppleTitlePageSlotArt.landingArt(displayed: .backdrop(backdrop), requested: nil,
            candidate: nil, failed: []) == .backdrop(backdrop))
    }

    @Test func aLandingPosterStaysVisibleIfNoBackdropIsAvailable() {
        #expect(AppleTitlePageSlotArt.landingArt(displayed: .posterCard(poster), requested: nil,
            candidate: .posterCard(textless), failed: []) == .posterCard(poster))
        #expect(AppleTitlePageSlotArt.landingArt(displayed: nil, requested: .backdrop(backdrop),
            candidate: .posterCard(poster), failed: [backdrop]) == .posterCard(poster))
        #expect(AppleTitlePageSlotArt.landingArt(displayed: .backdrop(backdrop), requested: .backdrop(backdrop),
            candidate: .posterCard(poster), failed: [backdrop]) == .backdrop(backdrop))
    }

    @Test func theSlotIsSixteenByNine() {
        #expect(AppleTitlePageSlotArt.slotHeight(width: 430) == 242)
        #expect(AppleTitlePageSlotArt.slotHeight(width: 375) == 211)
    }

    @Test func thePausedControlIsCentredAndTheSoundControlSitsBottomRight() {
        let visible = CGRect(x: 0, y: 0, width: 430, height: 242)
        let paused = AppleTrailerPreviewLayout.controlFrame(in: visible, paused: true, topInset: nil)
        #expect(paused.midX == visible.midX && paused.midY == visible.midY)
        #expect(paused.width >= 44 && paused.height >= 44)
        let sound = AppleTrailerPreviewLayout.controlFrame(in: visible, paused: false, topInset: nil)
        #expect(sound.width == 44 && sound.height == 44)
        #expect(sound.maxX <= visible.maxX && sound.maxY <= visible.maxY && sound.minX > visible.midX)
    }

    @Test func aTopSoundControlLinesUpWithTheRoundControlColumn() {
        let visible = CGRect(x: 0, y: 0, width: 430, height: 652)
        let sound = AppleTrailerPreviewLayout.controlFrame(in: visible, paused: false, topInset: 111)
        let side = AppleTrailerPreviewLayout.minimumControlSide
        #expect(sound == CGRect(x: visible.maxX - AppleDesignTokens.phoneHeroControlInset - side,
                                y: 111, width: side, height: side))
    }
}
