import Foundation

/// Per-device live buffering; Automatic leaves the engine's existing window alone.
public enum AppleLiveBufferPreference: String, CaseIterable, Sendable {
    case automatic, lowLatency, stable

    public static let defaultsKey = "openstream.settings.playback.liveBuffer.v1"

    public var title: String {
        switch self {
        case .automatic: "Automatic"
        case .lowLatency: "Low latency"
        case .stable: "Stable"
        }
    }

    public static func stored(in defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .automatic
    }

    public func forwardBufferDuration(isLive: Bool) -> Double {
        guard isLive else { return 0 }
        switch self {
        case .automatic: return 0
        case .lowLatency: return 2
        case .stable: return 20
        }
    }

    public func forwardBufferSegments(isLive: Bool) -> Int? {
        guard isLive else { return nil }
        switch self {
        case .automatic: return nil
        case .lowLatency: return 4 // Engine's minimum safe loopback window.
        case .stable: return 20
        }
    }
}
