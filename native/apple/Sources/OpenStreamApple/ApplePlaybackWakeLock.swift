import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Applies (or lifts) the platform's "do not let the display sleep" assertion.
///
/// Split out from `ApplePlaybackWakeLock` so the reference counting can be
/// tested: there is no `UIApplication` in the SPM test process, and a test
/// must never take a real assertion on the machine running it.
@MainActor
public protocol ApplePlaybackWakeAssertion: AnyObject {
    func setDisplaySleepDisabled(_ disabled: Bool)
}

/// The real assertion: the idle timer on iOS/tvOS/visionOS, a
/// `ProcessInfo` activity on macOS.
@MainActor
public final class AppleSystemWakeAssertion: ApplePlaybackWakeAssertion {
    #if os(macOS)
    /// The activity token `beginActivity` handed back. Held for exactly as long
    /// as the assertion is up; `endActivity` is the only thing that releases it,
    /// and dropping it without ending it would keep the Mac awake for the life
    /// of the process.
    private var activity: (any NSObjectProtocol)?
    #endif

    public init() {}

    public func setDisplaySleepDisabled(_ disabled: Bool) {
        #if os(macOS)
        if disabled {
            guard activity == nil else { return }
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.idleDisplaySleepDisabled, .userInitiated],
                reason: "oStream video playback"
            )
        } else if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
        #elseif canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = disabled
        #endif
    }

    /// Last line of defence. A holder that is torn down without a matching
    /// release is a bug, but a bug that keeps a television awake forever is
    /// worse than the one this file exists to fix.
    isolated deinit { setDisplaySleepDisabled(false) }
}

/// The one owner of "the viewer is watching something; do not sleep".
///
/// Apple TV ran its screen saver over a live channel that was playing fine
/// (owner 2026-09-21: "it went to apple screen savers"). Live MPEG-TS is
/// demuxed by the engine and drawn into an `AVSampleBufferDisplayLayer` on the
/// `.surface` route — there is no `AVPlayer` anywhere in that path, so
/// `AVPlayer.preventsDisplaySleepDuringVideoPlayback` (which defaults to true)
/// never applied to it. On-demand titles AVPlayer can open take the
/// `.avPlayer` route and were held awake by the player itself, which is why
/// only live slept.
///
/// Holders are named, and the set of names *is* the reference count: two
/// players on screen at once each hold their own name, and one ending does not
/// let the other's picture go dark. Acquiring or releasing the same name twice
/// is a no-op, so a release on pause followed by a release on teardown cannot
/// underflow the count.
///
/// On iOS/tvOS/visionOS the assertion is additionally gated on the app being in
/// the foreground, so Picture-in-Picture and background audio — which keep
/// playing with the app backgrounded — hold nothing. macOS is deliberately not
/// gated: a video window playing behind Safari is still someone watching, and
/// that is what every other Mac player does.
@MainActor
public final class ApplePlaybackWakeLock {
    public static let shared = ApplePlaybackWakeLock(observesApplicationState: true)

    private let assertion: any ApplePlaybackWakeAssertion
    private var holders: Set<String> = []
    private var isApplicationActive = true
    private var observers: [any NSObjectProtocol] = []

    /// What was last handed to the system, so the assertion is only touched on
    /// a real change.
    public private(set) var isDisplaySleepDisabled = false

    /// How many distinct holders are asking to stay awake right now.
    public var holderCount: Int { holders.count }

    public init(
        assertion: any ApplePlaybackWakeAssertion = AppleSystemWakeAssertion(),
        observesApplicationState: Bool = false
    ) {
        self.assertion = assertion
        if observesApplicationState { startObservingApplicationState() }
    }

    /// Ask to stay awake under `owner`. Idempotent.
    public func acquire(_ owner: String) {
        guard holders.insert(owner).inserted else { return }
        apply()
    }

    /// Give up `owner`'s claim. Idempotent, and a no-op for an owner that never
    /// acquired — pause, stop, error and teardown all release, and only the
    /// first of them has anything to do.
    public func release(_ owner: String) {
        guard holders.remove(owner) != nil else { return }
        apply()
    }

    /// Drop every claim. For teardown paths that own the whole lock.
    public func releaseAll() {
        guard holders.isEmpty == false else { return }
        holders.removeAll()
        apply()
    }

    /// The foreground gate. Claims are remembered while the app is away, so
    /// coming back to a still-playing picture takes the assertion again without
    /// the player having to notice.
    public func setApplicationActive(_ isActive: Bool) {
        guard isApplicationActive != isActive else { return }
        isApplicationActive = isActive
        apply()
    }

    private func apply() {
        let shouldHold = holders.isEmpty == false && isApplicationActive
        guard shouldHold != isDisplaySleepDisabled else { return }
        isDisplaySleepDisabled = shouldHold
        assertion.setDisplaySleepDisabled(shouldHold)
    }

    private func startObservingApplicationState() {
        #if canImport(UIKit) && !os(watchOS)
        let center = NotificationCenter.default
        let background = center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.setApplicationActive(false) }
        }
        let foreground = center.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.setApplicationActive(true) }
        }
        observers = [background, foreground]
        #endif
    }

    isolated deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        if isDisplaySleepDisabled {
            isDisplaySleepDisabled = false
            assertion.setDisplaySleepDisabled(false)
        }
    }
}

/// Whether a coordinator in this state is showing someone a picture.
///
/// Only a playing *video* route holds the display: `.audioOnly` is music or a
/// stream with no picture, and `.none` is a route that has not been decided
/// yet — the route event that follows within a frame or two takes the
/// assertion. Everything that is not `.playing` (loading, buffering, paused,
/// ended, failed, idle) lets the display sleep.
public enum ApplePlaybackWakePolicy {
    public static func shouldHoldDisplayAwake(
        phase: ApplePlaybackPhase,
        route: ApplePlaybackPresentationRoute
    ) -> Bool {
        guard phase == .playing else { return false }
        switch route {
        case .avPlayer, .surface: return true
        case .none, .audioOnly: return false
        }
    }
}
