import Foundation
import Testing
@testable import OpenStreamApple

/// REA round 3 (2026-10-17): trailer start timed from the page appearing, the
/// Home trailer's startup timeout, the remembered sound choice and the page
/// gate's art timeout.
@Suite struct AppleTrailerStartPolicyTests {
    private let shown = Date(timeIntervalSinceReferenceDate: 1_000)

    @Test func theDelayFollowsTheAppleTVAppPerPlatform() {
        #expect(AppleTrailerStartPolicy.delay(on: .phone) == 0.5)
        #expect(AppleTrailerStartPolicy.delay(on: .tv) == 1.0)
        #expect(AppleTrailerStartPolicy.delay(on: .padOrMac) == 2.0)
    }

    @Test func largePhoneWindowsTakeThePadTrailerDelay() {
        #expect(AppleTrailerStartPolicy.iOSPlatform(isPhone: true, isLargeLayout: false) == .phone)
        #expect(AppleTrailerStartPolicy.iOSPlatform(isPhone: true, isLargeLayout: true) == .padOrMac)
        #expect(AppleTrailerStartPolicy.iOSPlatform(isPhone: false, isLargeLayout: false) == .padOrMac)
        #expect(AppleTrailerStartPolicy.iOSPlatform(isPhone: false, isLargeLayout: true) == .padOrMac)
    }

    @Test func loadTimeCountsAgainstTheDelay() {
        #expect(AppleTrailerStartPolicy.remainingDelay(on: .padOrMac, pageShownAt: shown, now: shown) == 2)
        #expect(AppleTrailerStartPolicy.remainingDelay(on: .padOrMac, pageShownAt: shown,
                                                       now: shown.addingTimeInterval(1.5)) == 0.5)
        // Loading took longer than the delay: it starts at once, never a second wait.
        #expect(AppleTrailerStartPolicy.remainingDelay(on: .phone, pageShownAt: shown,
                                                       now: shown.addingTimeInterval(3)) == 0)
    }

    @Test func autoplayIsMutedUntilTheViewerChoosesSound() throws {
        let defaults = try #require(UserDefaults(suiteName: "AppleTrailerSoundMemoryTests"))
        defaults.removePersistentDomain(forName: "AppleTrailerSoundMemoryTests")
        #expect(AppleTrailerSoundMemory.soundOn(in: defaults) == nil)
        #expect(AppleTrailerSoundMemory.autoplayStartsMuted(choice: AppleTrailerSoundMemory.soundOn(in: defaults)))
        AppleTrailerSoundMemory.remember(soundOn: true, in: defaults)
        #expect(!AppleTrailerSoundMemory.autoplayStartsMuted(choice: AppleTrailerSoundMemory.soundOn(in: defaults)))
        AppleTrailerSoundMemory.remember(soundOn: false, in: defaults)
        #expect(AppleTrailerSoundMemory.soundOn(in: defaults) == false)
        #expect(AppleTrailerSoundMemory.autoplayStartsMuted(choice: false))
        defaults.removePersistentDomain(forName: "AppleTrailerSoundMemoryTests")
    }

    @Test func artThatNeverAnswersStillSettlesThePage() {
        #expect(AppleHeroPageSwap.artTimeout == .seconds(8))
        #expect(AppleHeroPageSwap.wordmarkFailedAtTimeout(hasWordmark: true, result: nil))
        #expect(AppleHeroPageSwap.wordmarkFailedAtTimeout(hasWordmark: true, result: false))
        #expect(!AppleHeroPageSwap.wordmarkFailedAtTimeout(hasWordmark: true, result: true))
        #expect(!AppleHeroPageSwap.wordmarkFailedAtTimeout(hasWordmark: false, result: nil))
    }

    @Test func lowPowerAndTheSystemSwitchStopOnlyAutomaticTrailers() {
        #expect(AppleHeroTrailerGate.allowsVideo(lowPower: false, systemVideoAutoplay: true, pressed: false))
        #expect(!AppleHeroTrailerGate.allowsVideo(lowPower: true, systemVideoAutoplay: true, pressed: false))
        #expect(!AppleHeroTrailerGate.allowsVideo(lowPower: false, systemVideoAutoplay: false, pressed: false))
        #expect(AppleHeroTrailerGate.allowsVideo(lowPower: true, systemVideoAutoplay: false, pressed: true))
    }
}
