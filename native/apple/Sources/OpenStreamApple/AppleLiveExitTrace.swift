import Foundation

@MainActor
enum AppleLiveExitTrace {
    private static var started: ContinuousClock.Instant?

    static func begin() {
        guard AppleInteractionTrace.isEnabled else { return }
        started = .now
        AppleInteractionTrace.record(.press, "live exit requested")
    }

    static func guideFocused() {
        guard let started else { return }
        self.started = nil
        AppleInteractionTrace.record(.playback,
            "live exit guide interactive \(AppleLaunchMarks.milliseconds(started.duration(to: .now)))ms")
    }
}
