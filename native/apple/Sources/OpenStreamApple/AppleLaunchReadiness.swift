import Observation

/// Whether the first screen has content ready.
@MainActor
@Observable
public final class AppleLaunchReadiness {
    public static let shared = AppleLaunchReadiness()

    public private(set) var firstScreenIsReady = false

    public init() {}

    public func markFirstScreenReady() {
        guard !firstScreenIsReady else { return }
        firstScreenIsReady = true
        #if DEBUG
        AppleLaunchClock.mark("first.screen.ready")
        #endif
    }
}
