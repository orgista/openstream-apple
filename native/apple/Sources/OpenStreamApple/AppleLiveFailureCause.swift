import Foundation

/// Why Live TV cannot show something, said the same way in the tab, inside
/// the player frame and in full screen: one symbol, a title of at most five
/// words that names the source (or the channel), one button. The technical
/// text stays in the trace.
///
/// A status code or a string match never yields "stream limit": only the
/// panel's own `MaxConnections` status does (`AppleIPTVFailureCause`, owner
/// item 20). Source names are the saved Live TV source's display name, never
/// a host.
public enum AppleLiveFailureCause: Equatable, Sendable {
    case unreachable(source: String)
    case loginFailed(source: String)
    case accountExpired(source: String)
    case streamLimit(source: String)
    case loadFailed(source: String)
    case notBroadcasting(channel: String)
    case cannotPlay(channel: String)
    case noSources

    public enum Action: Equatable, Sendable {
        case tryAgain, openSettings, nextChannel, addSource

        public var title: String {
            switch self {
            case .tryAgain: "Try Again"
            case .openSettings: "Open Settings"
            case .nextChannel: "Next Channel"
            case .addSource: "Add Source"
            }
        }
    }

    public var systemImage: String {
        switch self {
        case .unreachable: "wifi.exclamationmark"
        case .loginFailed, .accountExpired: "person.crop.circle.badge.exclamationmark"
        case .streamLimit: "person.2.slash"
        case .loadFailed, .cannotPlay: "exclamationmark.triangle"
        case .notBroadcasting: "tv.slash"
        case .noSources: "tv"
        }
    }

    public var title: String {
        switch self {
        case .unreachable(let source): "Can’t reach \(source)"
        case .loginFailed(let source): "\(source) login failed"
        case .accountExpired(let source): "\(source) account expired"
        case .streamLimit(let source): "\(source) stream limit"
        case .loadFailed(let source): "Couldn’t load \(source)"
        case .notBroadcasting(let channel): "\(channel) isn’t broadcasting"
        case .cannotPlay(let channel): "\(channel) can’t play here"
        case .noSources: "No Live TV source"
        }
    }

    public var action: Action {
        switch self {
        case .unreachable, .streamLimit, .loadFailed: .tryAgain
        case .loginFailed, .accountExpired: .openSettings
        case .notBroadcasting, .cannotPlay: .nextChannel
        case .noSources: .addSource
        }
    }

    /// A playlist (Xtream panel or M3U) that did not load.
    public static func source(_ error: any Error, sourceName: String) -> Self {
        let name = displayName(sourceName, fallback: "Live TV")
        if case AppleIPTVError.authenticationFailed(let status)? = error as? AppleIPTVError {
            switch status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "maxconnections": return .streamLimit(source: name)
            case "expired": return .accountExpired(source: name)
            default: return .loginFailed(source: name)
            }
        }
        switch AppleIPTVFailureCause.classify(error) {
        case .streamLimit: return .streamLimit(source: name)
        case .unreachable: return .unreachable(source: name)
        case .other: return .loadFailed(source: name)
        }
    }

    /// A channel that will not play. Nil for a cancelled load (a switch the
    /// viewer asked for).
    public static func playback(_ failure: ApplePlaybackFailure, channelName: String?,
                                sourceName: String?) -> Self? {
        let channel = displayName(channelName, fallback: "This channel")
        let source = displayName(sourceName, fallback: "Live TV")
        switch failure.kind {
        case .cancelled: return nil
        case .network, .timedOut: return .unreachable(source: source)
        case .authentication: return .loginFailed(source: source)
        case .player, .sourceEnded, .unavailable: return .notBroadcasting(channel: channel)
        case .unsupportedMedia, .engineUnavailable: return .cannotPlay(channel: channel)
        }
    }

    private static func displayName(_ value: String?, fallback: String) -> String {
        let clean = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return clean.isEmpty ? fallback : clean
    }
}
