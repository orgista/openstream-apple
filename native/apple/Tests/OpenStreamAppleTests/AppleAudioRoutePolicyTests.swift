import Foundation
import Testing
@testable import OpenStreamApple

#if canImport(AVFoundation)
import AVFoundation
#endif

/// Owner 2026-09-16: "support AirPods ... make sure we're AirPod aware ...
/// pause/play features." Pulling AirPods out must not dump the audio onto the
/// device speaker.
@Suite("Audio route policy")
struct AppleAudioRoutePolicyTests {
    @Test func removingTheOutputPauses() {
        #expect(AppleAudioRoutePolicy.shouldPause(for: .oldDeviceUnavailable))
    }

    /// Plugging headphones **in** moves the audio; it must not stop it.
    @Test func addingAnOutputDoesNotPause() {
        #expect(!AppleAudioRoutePolicy.shouldPause(for: .newDeviceAvailable))
    }

    /// These fire during ordinary session setup. Pausing on them would stop
    /// playback at the moment it starts.
    @Test func setupReasonsDoNotPause() {
        for reason in [AppleAudioRoutePolicy.Reason.categoryChange, .override,
                       .routeConfigurationChange, .wakeFromSleep, .unknown] {
            #expect(!AppleAudioRoutePolicy.shouldPause(for: reason), "paused on \(reason)")
        }
    }

    /// Losing every usable output is the same situation as losing the one in
    /// use, so it pauses too.
    @Test func losingEveryRoutePauses() {
        #expect(AppleAudioRoutePolicy.shouldPause(for: .noSuitableRouteForCategory))
    }

    @Test func anUnknownReasonNeverPauses() {
        #expect(!AppleAudioRoutePolicy.shouldPause(for: nil))
        #expect(!AppleAudioRoutePolicy.shouldPause(forRawValue: 99))
    }

    /// Putting AirPods back in must not restart audio unattended.
    @Test func nothingEverAutoResumes() {
        for reason in AppleAudioRoutePolicy.Reason.allCases {
            #expect(!AppleAudioRoutePolicy.shouldResume(for: reason))
        }
    }

    #if canImport(AVFoundation) && os(iOS)
    /// The raw values must match AVFoundation's, since that is what the
    /// notification actually carries.
    @Test func rawValuesMatchAVFoundation() {
        #expect(AppleAudioRoutePolicy.Reason.oldDeviceUnavailable.rawValue
                == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue)
        #expect(AppleAudioRoutePolicy.Reason.newDeviceAvailable.rawValue
                == AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue)
        #expect(AppleAudioRoutePolicy.Reason.noSuitableRouteForCategory.rawValue
                == AVAudioSession.RouteChangeReason.noSuitableRouteForCategory.rawValue)
    }
    #endif
}
