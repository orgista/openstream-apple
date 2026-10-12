import Testing
@testable import OpenStreamApple

@Suite("Apple TV Picture in Picture policy")
struct AppleTVPictureInPicturePolicyTests {
    @Test(arguments: ApplePlaybackPresentationRoute.allCases)
    func onlyTheStockPlayerLayerGoesIntoTheWindow(route: ApplePlaybackPresentationRoute) {
        #expect(AppleTVPictureInPicturePolicy.allowsPictureInPicture(route: route) == (route == .avPlayer))
    }

    @Test func menuEntryNeedsSupportTheAVPlayerRouteAndNoWindowYet() {
        #expect(AppleTVPictureInPicturePolicy.offersMenuEntry(route: .avPlayer, isSupported: true,
                                                              isPictureInPictureActive: false))
        #expect(!AppleTVPictureInPicturePolicy.offersMenuEntry(route: .avPlayer, isSupported: false,
                                                               isPictureInPictureActive: false))
        #expect(!AppleTVPictureInPicturePolicy.offersMenuEntry(route: .avPlayer, isSupported: true,
                                                               isPictureInPictureActive: true))
        for route in [ApplePlaybackPresentationRoute.surface, .none, .audioOnly] {
            #expect(!AppleTVPictureInPicturePolicy.offersMenuEntry(route: route, isSupported: true,
                                                                   isPictureInPictureActive: false))
        }
    }

    @Test func choosingAChannelWhileTheWindowIsUpClosesItAndPlaysFullScreen() {
        #expect(AppleTVPictureInPicturePolicy.channelChoice(isPictureInPictureActive: false) == .playFullScreen)
        #expect(AppleTVPictureInPicturePolicy.channelChoice(isPictureInPictureActive: true)
            == .closeWindowAndPlayFullScreen)
    }

    @Test func multiviewIsHiddenWhileTheWindowIsUp() {
        #expect(AppleTVPictureInPicturePolicy.offersMultiview(isPictureInPictureActive: false))
        #expect(!AppleTVPictureInPicturePolicy.offersMultiview(isPictureInPictureActive: true))
    }

    @Test func onlyTheWindowsFullScreenButtonKeepsPlaybackGoing() {
        #expect(AppleTVPictureInPicturePolicy.keepsPlayingWhenWindowCloses(restoredToFullScreen: true))
        #expect(!AppleTVPictureInPicturePolicy.keepsPlayingWhenWindowCloses(restoredToFullScreen: false))
    }

    @Test func browsingAroundTheWindowNeverStartsAnotherPicture() {
        #expect(!AppleTVPictureInPicturePolicy.resumesLastChannelOnArrival(isPictureInPictureActive: true))
        #expect(AppleTVPictureInPicturePolicy.resumesLastChannelOnArrival(isPictureInPictureActive: false))
        #expect(!AppleTVPictureInPicturePolicy.previewsEnabled(preference: true, isPictureInPictureActive: true))
        #expect(AppleTVPictureInPicturePolicy.previewsEnabled(preference: true, isPictureInPictureActive: false))
        #expect(!AppleTVPictureInPicturePolicy.previewsEnabled(preference: false, isPictureInPictureActive: false))
    }
}
