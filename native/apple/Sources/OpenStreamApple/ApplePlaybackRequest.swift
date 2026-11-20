import Foundation

public struct ApplePlaybackRequest: Equatable, Sendable {
    public enum SourceKind: String, Equatable, Sendable, CaseIterable {
        case catalog
        case iptv
        case liveTV
        case files
        case networkShare
        case mediaServer
    }

    public struct Hints: Equatable, Sendable {
        public var proxyHeaders: [String: String]
        public var filename: String?
        /// Stable episode identity supplied by provider libraries on every player route.
        public var progressPartID: String? = nil
        /// The series keeps its selected episode's resume point alongside the episode's own version timeline.
        public var progressParentID: String? = nil
        public var playbackDecision: ApplePlaybackDecision? = nil
        public var versionID: String? = nil
        public var versionOffset: Double = 0
        public var versionDuration: Double? = nil
        /// Original library file, before local export or the SMB playback proxy.
        public var libraryFileURL: URL?
        /// The title's media id (`tt0111161`, or `tt0903747:1:2` for an
        /// episode) and its type, which name the saved progress part when the
        /// source supplies none.
        public var titleMediaID: String?
        public var titleMediaType: String?
        /// Hand the origin URL to AVPlayer as HLS instead of demuxing it
        /// (`AppleLiveStreamRoutePolicy`). Live channels only.
        public var nativeRemoteHLS: Bool
        /// Play this live HLS media playlist through the local proxy's
        /// synthesized master, which declares the CEA-608 the provider's
        /// manifest left out (`AppleLiveCaptionWrapPolicy`). Live channels only.
        public var declaresEmbeddedCaptions: Bool
        /// A disc image: how it starts (Play Disc, Skip to Movie) or which of
        /// its titles plays. Nil for everything that is not a disc.
        public var disc: AppleDiscPlaybackChoice?
        /// Subtitle files the source offers beside the video (a media
        /// server's external subtitles), added after the embedded tracks.
        public var externalSubtitles: [AppleExternalSubtitleTrack] = []

        public init(
            proxyHeaders: [String: String] = [:],
            filename: String? = nil,
            libraryFileURL: URL? = nil,
            titleMediaID: String? = nil,
            titleMediaType: String? = nil,
            nativeRemoteHLS: Bool = false,
            declaresEmbeddedCaptions: Bool = false
        ) {
            self.proxyHeaders = proxyHeaders
            self.filename = filename
            self.libraryFileURL = libraryFileURL
            self.titleMediaID = titleMediaID
            self.titleMediaType = titleMediaType
            self.nativeRemoteHLS = nativeRemoteHLS
            self.declaresEmbeddedCaptions = declaresEmbeddedCaptions
        }
    }

    public var restrictionChannelID: String?
    public var restrictionGroup: String?
    public var iptvSourceID: UUID?
    var iptvConnectionWaited = false
    public var url: URL
    public var headers: [String: String]
    public var isLive: Bool
    public var dvrWindowSeconds: Double?
    public var resumePosition: Double?
    public var autoplay: Bool
    public var mediaID: String
    public var title: String?
    /// The small line the stock player shows above `title` is "<year> •
    /// <subtitle>": the show for an episode (nil for a film), and the year of
    /// the film or episode. Unset, AVKit used the file's own tags.
    public var subtitle: String?
    /// "S1 E3 · An Interval" and its series for a library episode, whose
    /// `title` is the file's: Now Playing shows the line under the series.
    public var episodeLine: String?
    public var episodeSeries: String?
    public var releaseYear: Int?
    /// The poster (a channel's logo for live), for the Now Playing artwork
    /// on the lock screen and in Control Center. Nil draws the app icon.
    public var artworkURL: URL?
    public var sourceName: String?
    public var sourceKind: SourceKind
    public var hints: Hints

    public init(
        url: URL,
        headers: [String: String] = [:],
        isLive: Bool = false,
        dvrWindowSeconds: Double? = nil,
        resumePosition: Double? = nil,
        autoplay: Bool = true,
        mediaID: String,
        title: String? = nil,
        sourceName: String? = nil,
        sourceKind: SourceKind,
        hints: Hints = Hints()
    ) {
        self.url = url
        self.headers = headers
        self.isLive = isLive
        self.dvrWindowSeconds = dvrWindowSeconds
        self.resumePosition = resumePosition
        self.autoplay = autoplay
        self.mediaID = mediaID
        self.title = title
        self.sourceName = sourceName
        self.sourceKind = sourceKind
        self.hints = hints
    }

    /// headers merged with hints.proxyHeaders; the proxy value wins on a
    /// key collision so provider-injected headers override the caller's.
    public var effectiveHeaders: [String: String] {
        headers.merging(hints.proxyHeaders) { _, proxy in proxy }
    }

    /// dvrWindowSeconds ?? 1800 for live streams; nil for non-live, even
    /// when dvrWindowSeconds has been set.
    public var effectiveDVRWindowSeconds: Double? {
        isLive ? (dvrWindowSeconds ?? 1800) : nil
    }

    func allowsExternalPlayback(playerURL: URL?) -> Bool {
        guard effectiveHeaders.isEmpty, let playerURL,
              !url.isFileURL, !playerURL.isFileURL,
              let scheme = playerURL.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = playerURL.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")),
              host != "localhost", host != "::1", !host.hasPrefix("127.") else { return false }
        return true
    }
}
