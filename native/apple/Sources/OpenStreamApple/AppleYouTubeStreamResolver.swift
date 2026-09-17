import Foundation

/// Resolves a YouTube video id to a stream AVPlayer can play natively: the HLS
/// manifest YouTube's public player endpoint returns for the iOS client
/// context. tvOS has no WebKit, so the title page's trailer there can only be
/// a native player; other platforms can use it for a 4K-capable native
/// preview later. No key, no cookies, no sign-in. Manifest URLs expire after
/// about six hours, so cached entries are dropped after four.
actor AppleYouTubeStreamResolver {
    static let shared = AppleYouTubeStreamResolver()

    /// What the endpoint handed back, in the form AVPlayer can be pointed at.
    ///
    /// The player endpoint used to return an HLS manifest for this client and
    /// no longer does for most videos: measured 2026-09-15 on the real
    /// Gentlemen trailer (`wyEOwHrpZH4`), `playabilityStatus` was **OK** and
    /// `streamingData` carried 27 `adaptiveFormats`, a `serverAbrStreamingUrl`
    /// — and no `hlsManifestUrl` at all. Only looking for the manifest meant
    /// every trailer failed as `noHLS`, which is what the owner saw as
    /// "trailers still aren't working". Adaptive formats are audio-only or
    /// video-only, never both, so the pair is recombined at playback.
    enum Source: Sendable, Equatable {
        case hls(URL)
        case adaptive(video: URL, audio: URL)
    }

    struct Stream: Sendable, Equatable {
        let source: Source
        let title: String
        let resolvedAt: Date
    }

    /// One entry of `streamingData.adaptiveFormats`, reduced to what selection
    /// needs. Kept separate from the JSON so the choice can be tested.
    struct AdaptiveFormat: Sendable, Equatable {
        let url: URL
        let mimeType: String
        let height: Int?
        let bitrate: Int
    }

    enum Failure: Error, Equatable {
        case badResponse(Int)
        case unplayable(String)
        case noHLS
    }

    static let endpoint = URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")!
    static let clientName = "IOS"
    static let clientNameID = "5"
    static let clientVersion = "20.10.4"
    static let cacheLifetime: TimeInterval = 4 * 3600

    private var cache: [String: Stream] = [:]
    private let session: URLSession
    private let now: @Sendable () -> Date

    init(session: URLSession = .shared, now: @escaping @Sendable () -> Date = { Date() }) {
        self.session = session
        self.now = now
    }

    func resolve(videoID: String) async throws -> Stream {
        if let cached = cache[videoID], now().timeIntervalSince(cached.resolvedAt) < Self.cacheLifetime {
            return cached
        }
        let (data, response) = try await session.data(for: Self.request(videoID: videoID))
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else { throw Failure.badResponse(status) }
        let stream = try Self.parse(data, resolvedAt: now())
        cache[videoID] = stream
        return stream
    }

    // MARK: - Request

    static func request(videoID: String) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        request.httpBody = try? JSONSerialization.data(withJSONObject: requestBody(videoID: videoID))
        request.timeoutInterval = 15
        return request
    }

    static var headers: [String: String] {
        [
            "Content-Type": "application/json",
            "X-YouTube-Client-Name": clientNameID,
            "X-YouTube-Client-Version": clientVersion,
            "User-Agent": "com.google.ios.youtube/\(clientVersion) (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)",
        ]
    }

    static func requestBody(videoID: String) -> [String: Any] {
        [
            "context": [
                "client": [
                    "clientName": clientName,
                    "clientVersion": clientVersion,
                    "deviceMake": "Apple",
                    "deviceModel": "iPhone16,2",
                    "osName": "iPhone",
                    "osVersion": "18.3.2.22D82",
                    "hl": "en",
                    "gl": "US",
                    "utcOffsetMinutes": 0,
                ],
            ],
            "videoId": videoID,
            "contentCheckOk": true,
            "racyCheckOk": true,
        ]
    }

    // MARK: - Response

    static func parse(_ data: Data, resolvedAt: Date) throws -> Stream {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.badResponse(200)
        }
        let playability = object["playabilityStatus"] as? [String: Any] ?? [:]
        let status = playability["status"] as? String ?? "UNKNOWN"
        guard status == "OK" else {
            throw Failure.unplayable(playability["reason"] as? String ?? status)
        }
        let streaming = object["streamingData"] as? [String: Any] ?? [:]
        let details = object["videoDetails"] as? [String: Any] ?? [:]
        let title = details["title"] as? String ?? ""

        // An HLS manifest is still the best answer when one is offered: one URL,
        // adaptive bitrate, no recombining.
        if let manifest = streaming["hlsManifestUrl"] as? String,
           let url = URL(string: manifest), url.scheme == "https" {
            return Stream(source: .hls(url), title: title, resolvedAt: resolvedAt)
        }

        guard let pair = selectPair(adaptiveFormats(streaming)) else { throw Failure.noHLS }
        return Stream(source: .adaptive(video: pair.video, audio: pair.audio), title: title, resolvedAt: resolvedAt)
    }

    static func adaptiveFormats(_ streaming: [String: Any]) -> [AdaptiveFormat] {
        (streaming["adaptiveFormats"] as? [[String: Any]] ?? []).compactMap { entry in
            // A format carrying `signatureCipher` instead of `url` needs the
            // player's signature routine to unscramble it; those are skipped
            // rather than guessed at.
            guard let raw = entry["url"] as? String,
                  let url = URL(string: raw), url.scheme == "https",
                  let mimeType = entry["mimeType"] as? String else { return nil }
            return AdaptiveFormat(
                url: url,
                mimeType: mimeType,
                height: entry["height"] as? Int,
                bitrate: entry["bitrate"] as? Int ?? 0
            )
        }
    }

    /// The tallest H.264 video up to 1080p, paired with the best AAC audio.
    ///
    /// Codec choice is not a preference — it is what an Apple TV can actually
    /// decode from a plain MP4 URL. The endpoint also offers VP9 (`vp09`) and
    /// AV1 (`av01`) at up to 2160p, neither of which is a safe bet across the
    /// Apple TV generations, and Opus audio in WebM, which AVFoundation does
    /// not read at all. 1080p is also the right ceiling for a preview that
    /// fades in over the hero: it starts sooner and the hero is never the
    /// place to spend a 4K decode.
    static func selectPair(_ formats: [AdaptiveFormat]) -> (video: URL, audio: URL)? {
        let video = formats
            .filter { $0.mimeType.contains("avc1") && ($0.height ?? 0) <= 1080 }
            .max { ($0.height ?? 0, $0.bitrate) < ($1.height ?? 0, $1.bitrate) }
        // `mp4a.40.2` is AAC-LC; `mp4a.40.5` is HE-AAC, which plays but is the
        // lower-bitrate fallback, so highest bitrate picks correctly either way.
        let audio = formats
            .filter { $0.mimeType.contains("mp4a") }
            .max { $0.bitrate < $1.bitrate }
        guard let video, let audio else { return nil }
        return (video.url, audio.url)
    }
}
