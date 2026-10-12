import Foundation

public struct ApplePlaybackRequest: Equatable, Sendable {
    public enum SourceKind: String, Equatable, Sendable, CaseIterable {
        case catalog
        #if OPENSTREAM_ADDONS
        public static var stremio: Self { .catalog }
        #endif
        case iptv
        case liveTV
        case files
        case networkShare
        case mediaServer
    }

    public struct Hints: Equatable, Sendable {
        public var notWebReady: Bool
        public var proxyHeaders: [String: String]
        public var filename: String?
        /// Stable episode identity supplied by provider libraries on every player route.
        public var progressPartID: String? = nil
        /// Original library file, before local export or the SMB playback proxy.
        public var libraryFileURL: URL?
        /// The add-on media id for this title (`tt0111161`, or `tt0903747:1:2`
        /// for an episode) and its type. Present only when the stream came from
        /// an add-on, and used to ask add-ons for subtitle files.
        public var addonMediaID: String?
        public var addonMediaType: String?
        /// Hand the origin URL to AVPlayer as HLS instead of demuxing it
        /// (`AppleLiveStreamRoutePolicy`). Live channels only.
        public var nativeRemoteHLS: Bool
        /// Play this live HLS media playlist through the local proxy's
        /// synthesized master, which declares the CEA-608 the provider's
        /// manifest left out (`AppleLiveCaptionWrapPolicy`). Live channels only.
        public var declaresEmbeddedCaptions: Bool
        /// The service an add-on stream belongs to (`AppleStreamServiceKey`),
        /// so a service that is down can be skipped. Nil for everything else.
        public var serviceKey: String?
        /// How long the title runs, in seconds, when its metadata says. A
        /// stream far shorter than this is a provider's error clip
        /// (`AppleStreamPlaceholderPolicy`). Nil when unknown.
        public var expectedRuntime: Double?
        /// A disc image: how it starts (Play Disc, Skip to Movie) or which of
        /// its titles plays. Nil for everything that is not a disc.
        public var disc: AppleDiscPlaybackChoice?

        public init(
            notWebReady: Bool = false,
            proxyHeaders: [String: String] = [:],
            filename: String? = nil,
            libraryFileURL: URL? = nil,
            addonMediaID: String? = nil,
            addonMediaType: String? = nil,
            nativeRemoteHLS: Bool = false,
            declaresEmbeddedCaptions: Bool = false,
            serviceKey: String? = nil,
            expectedRuntime: Double? = nil
        ) {
            self.notWebReady = notWebReady
            self.proxyHeaders = proxyHeaders
            self.filename = filename
            self.libraryFileURL = libraryFileURL
            self.addonMediaID = addonMediaID
            self.addonMediaType = addonMediaType
            self.nativeRemoteHLS = nativeRemoteHLS
            self.declaresEmbeddedCaptions = declaresEmbeddedCaptions
            self.serviceKey = serviceKey
            self.expectedRuntime = expectedRuntime
        }
    }

    public var restrictionChannelID: String?
    public var restrictionGroup: String?
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
              let host = playerURL.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")),
              host != "localhost", host != "::1", !host.hasPrefix("127.") else { return false }
        return true
    }
}
