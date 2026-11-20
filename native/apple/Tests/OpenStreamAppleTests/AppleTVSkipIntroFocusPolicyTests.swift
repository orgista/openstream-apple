import Foundation
import Testing
@testable import OpenStreamApple

/// Full test 2026-10-01: Skip Intro showed, but Down from the video went to
/// the scrubber row and never reached it, and the auto-hide took the focus
/// back to the picture.
@Suite("Apple TV Skip Intro focus")
struct AppleTVSkipIntroFocusPolicyTests {
    @Test func theScrubberStandsDownWhileSkipIntroIsOffered() {
        #expect(!AppleTVSkipIntroFocusPolicy.scrubberIsFocusable(showsSkipIntro: true))
        #expect(AppleTVSkipIntroFocusPolicy.scrubberIsFocusable(showsSkipIntro: false))
    }

    @Test func theEnginesFirstPickGoesBackToThePicture() {
        #expect(AppleTVSkipIntroFocusPolicy.returnsInitialFocusToSurface(cameFromNowhere: true, landedOnSkipIntro: true))
        #expect(!AppleTVSkipIntroFocusPolicy.returnsInitialFocusToSurface(cameFromNowhere: false, landedOnSkipIntro: true))
        #expect(!AppleTVSkipIntroFocusPolicy.returnsInitialFocusToSurface(cameFromNowhere: true, landedOnSkipIntro: false))
    }

    @Test func hiddenSkipIntroStaysAFocusTargetButIsNotSeen() {
        #expect(AppleTVSkipIntroFocusPolicy.hiddenOpacity > 0.01)
        #expect(AppleTVSkipIntroFocusPolicy.hiddenOpacity <= 0.02)
    }

    @Test func hidingTheControlsLeavesAFocusedSkipIntroAlone() {
        #expect(!AppleTVSkipIntroFocusPolicy.returnsFocusToSurfaceOnHide(
            isVisible: false, hidesFocusDuringPlayback: true, skipIntroIsFocused: true))
        #expect(AppleTVSkipIntroFocusPolicy.returnsFocusToSurfaceOnHide(
            isVisible: false, hidesFocusDuringPlayback: true, skipIntroIsFocused: false))
        #expect(!AppleTVSkipIntroFocusPolicy.returnsFocusToSurfaceOnHide(
            isVisible: true, hidesFocusDuringPlayback: true, skipIntroIsFocused: false))
        #expect(!AppleTVSkipIntroFocusPolicy.returnsFocusToSurfaceOnHide(
            isVisible: false, hidesFocusDuringPlayback: false, skipIntroIsFocused: false))
    }
}
