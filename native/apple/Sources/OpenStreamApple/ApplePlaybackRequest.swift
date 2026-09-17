import Foundation

public struct ApplePlaybackRequest: Equatable, Sendable {
    public enum SourceKind: String, Equatable, Sendable, CaseIterable {
        case stremio
        case iptv
        case liveTV
        case files
        case networkShare
    }

    public struct Hints: Equatable, Sendable {
        public var notWebReady: Bool
        public var proxyHeaders: [String: String]
        public var filename: String?
        /// The add-on media id for this title (`tt0111161`, or `tt0903747:1:2`
        /// for an episode) and its type. Present only when the stream came from
        /// an add-on, and used to ask add-ons for subtitle files.
        public var addonMediaID: String?
        public var addonMediaType: String?

        public init(
            notWebReady: Bool = false,
            proxyHeaders: [String: String] = [:],
            filename: String? = nil,
            addonMediaID: String? = nil,
            addonMediaType: String? = nil
        ) {
            self.notWebReady = notWebReady
            self.proxyHeaders = proxyHeaders
            self.filename = filename
            self.addonMediaID = addonMediaID
            self.addonMediaType = addonMediaType
        }
    }

    public var url: URL
    public var headers: [String: String]
    public var isLive: Bool
    public var dvrWindowSeconds: Double?
    public var resumePosition: Double?
    public var autoplay: Bool
    public var mediaID: String
    public var title: String?
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
