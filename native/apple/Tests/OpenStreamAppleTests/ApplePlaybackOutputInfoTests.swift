import Testing
@testable import OpenStreamApple

struct ApplePlaybackOutputInfoTests {
    @Test func labelsActualOutputWithoutUsingTitle() {
        #expect(ApplePlaybackOutputInfo(dynamicRange: .dolbyVision, channels: 6, isAtmos: true).line == "Dolby Vision · Dolby Atmos")
        #expect(ApplePlaybackOutputInfo(dynamicRange: .hdr10Plus, channels: 6).line == "HDR10+ · 5.1")
        #expect(ApplePlaybackOutputInfo(dynamicRange: .hlg, channels: 8).line == "HLG · 7.1")
        #expect(ApplePlaybackOutputInfo(dynamicRange: .hdr10, channels: 2).line == "HDR10 · Stereo")
        #expect(ApplePlaybackOutputInfo(dynamicRange: .sdr, channels: 0).line == "SDR")
        #expect(ApplePlaybackOutputInfo(dynamicRange: nil, channels: 0).line == nil)
    }
}
