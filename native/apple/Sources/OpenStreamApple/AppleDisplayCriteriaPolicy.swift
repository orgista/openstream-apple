import Foundation

public enum AppleDisplayCriteriaPolicy {
    /// AetherEngine owns criteria for both decoded and AVPlayer-backed routes. AVKit owns the native fallback.
    public static func automaticAVKitMatching(engine: ApplePlaybackEngineKind) -> Bool {
        engine == .native
    }
}
