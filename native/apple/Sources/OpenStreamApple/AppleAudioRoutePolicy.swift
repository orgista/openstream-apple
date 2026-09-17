import Foundation

#if canImport(AVFoundation)
import AVFoundation
#endif

/// Whether a route change should pause what is playing.
///
/// Taking AirPods out, or walking away from a Bluetooth speaker, must pause —
/// otherwise the audio jumps to the device speaker and plays out loud, which is
/// the behaviour every other player avoids and the one the owner asked for
/// ("AirPod aware ... pause/play features", 2026-09-16). The route handler
/// recorded the reason and did nothing with it.
///
/// Plain values so the rule can be asserted without an audio session.
public enum AppleAudioRoutePolicy: Sendable {
    /// The reasons as `AVAudioSession.RouteChangeReason` raw values, restated
    /// here so the policy is testable on platforms without AVFoundation.
    public enum Reason: UInt, Sendable, CaseIterable {
        case unknown = 0
        case newDeviceAvailable = 1
        case oldDeviceUnavailable = 2
        case categoryChange = 3
        case override = 4
        case wakeFromSleep = 6
        case noSuitableRouteForCategory = 7
        case routeConfigurationChange = 8
    }

    /// Only an output that went away pauses.
    ///
    /// Deliberately not `newDeviceAvailable`: plugging AirPods **in** should
    /// move the audio, not stop it. Not `categoryChange`, `override` or
    /// `routeConfigurationChange` either — those fire during ordinary setup,
    /// and pausing on them would stop playback as it starts.
    public static func shouldPause(for reason: Reason?) -> Bool {
        switch reason {
        case .oldDeviceUnavailable, .noSuitableRouteForCategory: true
        default: false
        }
    }

    public static func shouldPause(forRawValue raw: UInt?) -> Bool {
        shouldPause(for: raw.flatMap(Reason.init(rawValue:)))
    }

    /// Whether playback may resume by itself when the device comes back.
    ///
    /// It may not. Apple's own players do not auto-resume when AirPods go back
    /// in, because the viewer may have moved on, and audio restarting
    /// unattended is worse than a paused player.
    public static func shouldResume(for _: Reason?) -> Bool { false }
}
