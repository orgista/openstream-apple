import Testing
@testable import OpenStreamApple

/// Live on the owner's IPTV provider (2026-10-08, "Live no longer works"):
/// the stream opened, the first segment arrived ~11 s in, and the 10 s live
/// deadline had already failed the channel.
@Suite struct ApplePlaybackStartPolicyTests {
    typealias Policy = ApplePlaybackStartPolicy

    @Test func anOpenLiveChannelGetsOneLongerWait() {
        #expect(Policy.liveStartExtension(isLive: true, sourceOpened: true, alreadyExtended: false) == .seconds(15))
    }

    @Test func aChannelThatNeverOpenedStillFailsAtTheDeadline() {
        #expect(Policy.liveStartExtension(isLive: true, sourceOpened: false, alreadyExtended: false) == nil)
    }

    @Test func theWaitIsExtendedOnlyOnce() {
        #expect(Policy.liveStartExtension(isLive: true, sourceOpened: true, alreadyExtended: true) == nil)
    }

    @Test func onDemandKeepsItsOwnTimeout() {
        #expect(Policy.liveStartExtension(isLive: false, sourceOpened: true, alreadyExtended: false) == nil)
    }
}
