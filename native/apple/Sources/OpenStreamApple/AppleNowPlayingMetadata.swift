import Foundation
#if canImport(MediaPlayer)
import MediaPlayer
#endif

/// What the lock screen, Control Center and the Apple TV's Now Playing show
/// for the stream playing: the episode line and its series, the poster (a
/// channel's logo for live), whether it is live, and that it is video.
/// Plain values, so the mapping is testable on every platform.
public struct AppleNowPlayingMetadata: Equatable, Sendable {
    public let title: String
    /// The series for an episode; nil for a film or a channel.
    public let seriesTitle: String?
    public let isLive: Bool
    public let artworkURL: URL?

    public init(title: String?, seriesTitle: String? = nil, isLive: Bool, artworkURL: URL? = nil) {
        let clean = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.title = clean.isEmpty ? "oStream" : Self.episodeLine(clean)
        hasTitle = !clean.isEmpty
        let series = seriesTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.seriesTitle = series.isEmpty || series == clean ? nil : series
        self.isLive = isLive
        self.artworkURL = Self.loadableArtwork(artworkURL)
    }

    /// The title, or nil where there was none to show (the watch and the
    /// TV beacon draw their own placeholder).
    var knownTitle: String? { hasTitle ? title : nil }
    private let hasTitle: Bool

    public init(request: ApplePlaybackRequest) {
        self.init(title: request.title, seriesTitle: request.subtitle, isLive: request.isLive,
                  artworkURL: request.artworkURL)
    }

    /// The title page's "S1 E2 · Pilot" as Now Playing writes it, "S1, E2 · Pilot".
    static func episodeLine(_ title: String) -> String {
        guard let match = title.wholeMatch(of: /S(\d+) E(\d+) · (.+)/) else { return title }
        return "S\(match.1), E\(match.2) · \(match.3)"
    }

    /// Only a plain web image: no credentials, nothing on a custom scheme.
    private static func loadableArtwork(_ url: URL?) -> URL? {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.user == nil, url.password == nil, url.host?.isEmpty == false else { return nil }
        return url
    }

    #if canImport(MediaPlayer)
    /// The `MPNowPlayingInfoCenter` dictionary for this item at `position`.
    /// `artwork` is added by the caller once the image has loaded.
    func nowPlayingInfo(position: Double, duration: Double?, isPlaying: Bool) -> [String: Any] {
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = title
        if let seriesTitle {
            info[MPMediaItemPropertyAlbumTitle] = seriesTitle
            info[MPMediaItemPropertyArtist] = seriesTitle
        }
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.video.rawValue
        info[MPNowPlayingInfoPropertyIsLiveStream] = isLive
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position.isFinite ? max(0, position) : 0
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        // A live stream has no length; a duration there drew a scrubber that
        // ran out mid-programme.
        if !isLive, let duration, duration.isFinite, duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        return info
    }
    #endif
}
