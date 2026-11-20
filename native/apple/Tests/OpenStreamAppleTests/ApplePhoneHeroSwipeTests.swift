import Foundation
import Testing
@testable import OpenStreamApple

@Suite("Phone hero swipe")
struct ApplePhoneHeroSwipeTests {
    @Test func aShortSlowDragTracksTheFingerBeforeCommitting() {
        let drag = CGSize(width: -100, height: 3)
        #expect(ApplePhoneHeroSwipe.displacement(drag, pageWidth: 430) == -100)
        #expect(ApplePhoneHeroSwipe.turn(translation: drag, predicted: drag, pageWidth: 430) == 1)
    }

    @Test func aDragOrFlickTurnsInEitherDirection() {
        #expect(ApplePhoneHeroSwipe.turn(translation: CGSize(width: -120, height: 2),
            predicted: CGSize(width: -120, height: 2), pageWidth: 430) == 1)
        #expect(ApplePhoneHeroSwipe.turn(translation: CGSize(width: 30, height: 2),
            predicted: CGSize(width: 170, height: 2), pageWidth: 430) == -1)
    }

    @Test func smallSlowDragsKeepTheirPage() {
        let drag = CGSize(width: 50, height: 2)
        #expect(ApplePhoneHeroSwipe.turn(translation: drag,
            predicted: CGSize(width: 160, height: 2), pageWidth: 430) == nil)
    }

    @Test func verticalScrollingDoesNotShiftOrTurnTheHero() {
        let drag = CGSize(width: 100, height: 200)
        #expect(ApplePhoneHeroSwipe.displacement(drag, pageWidth: 430) == 0)
        #expect(ApplePhoneHeroSwipe.turn(translation: drag, predicted: drag, pageWidth: 430) == nil)
    }

    @Test func overdragStopsAtOnePage() {
        #expect(ApplePhoneHeroSwipe.displacement(CGSize(width: -800, height: 1), pageWidth: 430) == -430)
        #expect(ApplePhoneHeroSwipe.displacement(CGSize(width: 800, height: 1), pageWidth: 430) == 430)
    }
}
