import Testing
@testable import OpenStreamApple

struct AppleAutomaticVideoPolicyTests {
    @Test func everySystemRestrictionStopsVideo() {
        #expect(AppleTrailerPreviewPolicy.shouldAutoplay(reduceMotion: false, systemVideoAutoplayEnabled: true))
        #expect(AppleTrailerPreviewPolicy.shouldAutoplay(reduceMotion: true, systemVideoAutoplayEnabled: true) == false)
        #expect(AppleTrailerPreviewPolicy.shouldAutoplay(reduceMotion: false, systemVideoAutoplayEnabled: false) == false)
        #expect(AppleTrailerPreviewPolicy.shouldAutoplay(reduceMotion: false, systemVideoAutoplayEnabled: true, lowPowerMode: true) == false)
        for device in [AppleTrailerPreviewPolicy.TitlePageDevice.phoneOrPad, .vision, .mac, .tv] {
            #expect(AppleTrailerPreviewPolicy.titlePageAutoplays(on: device, setting: true, reduceMotion: false,
                systemVideoAutoplayEnabled: false) == false)
            #expect(AppleTrailerPreviewPolicy.titlePageAutoplays(on: device, setting: true, reduceMotion: false,
                lowPowerMode: true) == false)
        }
    }
}
