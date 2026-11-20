import Foundation
import OSLog

/// Constructs the playback engine for a session. The preferred engine is the
/// OpenStream engine (`AetherPlaybackEngine`, which wraps `AetherEngine`); when
/// it cannot be constructed the factory falls back to `NativePlaybackEngine` so
/// a session never fails to start because the demuxing engine was unavailable.
///
/// `makeAether` exists as a parameter so the throwing construction path is
/// testable without depending on the engine's own availability.
@MainActor
public enum ApplePlaybackEngineFactory {
    public static func make(
        preferred: ApplePlaybackEngineKind,
        makeAether: () throws -> any ApplePlaybackEngine = { try AetherPlaybackEngine() }
    ) -> (engine: any ApplePlaybackEngine, fellBack: Bool) {
        switch preferred {
        case .native:
            return (NativePlaybackEngine(), false)
        case .openStream:
            do {
                let engine = try makeAether()
                return (engine, false)
            } catch {
                // Log once: the demuxing engine could not be constructed, so this
                // session runs on the AVPlayer-only fallback. The user still gets
                // playback; the only cost is the formats AVPlayer cannot demux.
                Logger.playback.error("AetherEngine unavailable; falling back to native playback: \(error.localizedDescription, privacy: .public)")
                return (NativePlaybackEngine(), true)
            }
        }
    }
}

extension Logger {
    /// `os.Logger(subsystem: "com.orgista.openstream", category: "playback")`,
    /// the single logger the playback engine reports a fallback through.
    fileprivate static let playback = Logger(subsystem: "com.orgista.openstream", category: "playback")
}
