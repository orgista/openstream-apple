import Foundation
#if os(iOS)
import UIKit
#endif

/// When an autoplaying trailer starts, after the Apple TV app's
/// `playbackDelayInterval` (REA round 3, 2026-10-17, §1.2): the still shows for
/// a set time from the page appearing, and the time spent loading the trailer
/// counts against it, so a slow load never adds a second wait on top.
public enum AppleTrailerStartPolicy {
    public enum Platform: Equatable, Sendable {
        case phone, tv, padOrMac
    }

    /// Still → trailer: iPhone 0.5 s, Apple TV 1.0 s, iPad, Mac and Vision Pro 2.0 s.
    public static func delay(on platform: Platform) -> TimeInterval {
        switch platform {
        case .phone: 0.5
        case .tv: 1.0
        case .padOrMac: 2.0
        }
    }

    /// What is left of the delay once the trailer is ready; 0 when loading
    /// took longer.
    public static func remainingDelay(on platform: Platform, pageShownAt: Date, now: Date) -> TimeInterval {
        max(0, delay(on: platform) - now.timeIntervalSince(pageShownAt))
    }

    /// How long a home hero's requested trailer may take to start playing
    /// before it counts as failed: the still stays and the page gets a fresh
    /// dwell. Without it a stall with no error held the cycle for good.
    public static let homeStartupTimeout: TimeInterval = 8

    static func iOSPlatform(isPhone: Bool, isLargeLayout: Bool) -> Platform {
        isPhone && !isLargeLayout ? .phone : .padOrMac
    }

    @MainActor public static func current(isLargeLayout: Bool = false) -> Platform {
        #if os(tvOS)
        .tv
        #elseif os(iOS)
        iOSPlatform(isPhone: UIDevice.current.userInterfaceIdiom == .phone, isLargeLayout: isLargeLayout)
        #else
        .padOrMac
        #endif
    }
}

/// The viewer's own trailer sound choice, kept across trailers and launches
/// once they tap a trailer's sound control (the Apple TV app's
/// `AutoPlayBgVideoSoundUserHasChanged`). Until they do, autoplay starts muted.
public enum AppleTrailerSoundMemory {
    static let defaultsKey = "openstream.trailer.soundChoice.v1"

    /// True for sound on, false for muted, nil before the first tap.
    public static func soundOn(in defaults: UserDefaults = .standard) -> Bool? {
        defaults.object(forKey: defaultsKey) as? Bool
    }

    public static func remember(soundOn: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(soundOn, forKey: defaultsKey)
    }

    /// Whether a trailer that plays by itself starts muted.
    public static func autoplayStartsMuted(choice: Bool? = soundOn()) -> Bool {
        choice != true
    }
}
