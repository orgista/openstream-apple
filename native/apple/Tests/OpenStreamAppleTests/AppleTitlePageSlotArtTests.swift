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

    @Test func aFailedBackdropFallsThrough() {
        #expect(AppleTitlePageSlotArt.choose(backdrops: [textless, backdrop], posters: [poster], failed: [textless])
                == .backdrop(backdrop))
        #expect(AppleTitlePageSlotArt.choose(backdrops: [textless], posters: [poster], failed: [textless])
                == .posterCard(poster))
    }

    @Test func theChoiceWaitsForTheDetailsOrTheDeadline() {
        #expect(!AppleTitlePageSlotArt.isReady(detailsAnswered: false, deadlinePassed: false))
        #expect(AppleTitlePageSlotArt.isReady(detailsAnswered: true, deadlinePassed: false))
        #expect(AppleTitlePageSlotArt.isReady(detailsAnswered: false, deadlinePassed: true))
    }

    @Test func theSlotIsSixteenByNine() {
        #expect(AppleTitlePageSlotArt.slotHeight(width: 430) == 242)
        #expect(AppleTitlePageSlotArt.slotHeight(width: 375) == 211)
    }

    @Test func theTrailerFillsAnExactSlotWithNoZoom() {
        let size = CGSize(width: 430, height: 242)
        #expect(AppleTrailerPreviewLayout.slotFrame(in: size) == CGRect(origin: .zero, size: size))
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
}
