import Foundation
import Synchronization

/// Asks one question about a live channel: does it carry CEA-608 captions the
/// manifest never declared?
///
/// Bare media playlists are declared before the first play. Alongside playback,
/// bounded segment samples confirm 608 or suppress the next declaration after a
/// 60-second observation window. The current item is never reloaded. Failed or cancelled observations stay unknown;
/// completed answers are cached per channel for this app run.
public actor AppleLiveCaptionProbe {
    public static let shared = AppleLiveCaptionProbe()

    /// One segment's head is dozens of frames — far more than the detector's
    /// threshold — and small enough that a probe costs a fraction of a second.
    public static let maximumProbeBytes = 512 * 1024
    public static let requestTimeout: TimeInterval = 8
    public static let preflightTimeout: Duration = .milliseconds(1_500)

    public struct Result: Equatable, Sendable {
        public let carriesUndeclaredCaptions: Bool
        public let manifestAlreadyDeclares: Bool
        /// The URL answered with an HLS media playlist (segments, no
        /// variants) — the only shape a synthesized master can wrap. False for
        /// a raw transport stream and for a master.
        public var isMediaPlaylist: Bool = false

        /// Play this channel through a caption-declaring master next time.
        public var wrapsInCaptionMaster: Bool {
            AppleLiveCaptionWrapPolicy.shouldWrap(
                carriesEmbeddedCaptions: carriesUndeclaredCaptions,
                manifestDeclaresCaptions: manifestAlreadyDeclares,
                isMediaPlaylist: isMediaPlaylist)
        }
    }

    private var answers: [String: Result] = [:]
    /// nil is unknown, false is a completed negative observation. The channel
    /// picker reads this synchronously while constructing a playback request.
    private nonisolated let wrapDecisions = Mutex<[String: Bool]>([:])
    private let session: URLSession
    private let observationDuration: Duration
    private let pollingInterval: Duration
    private let clock: any AppleClock
    public static let observationWindow: Duration = .seconds(60)

    public init(
        session: URLSession? = nil,
        observationDuration: Duration = observationWindow,
        pollingInterval: Duration = .seconds(5),
        clock: any AppleClock = AppleSystemClock()
    ) {
        self.observationDuration = observationDuration
        self.pollingInterval = pollingInterval
        self.clock = clock
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = Self.requestTimeout
            configuration.timeoutIntervalForResource = Self.requestTimeout
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: configuration)
        }
    }

    public func cachedResult(channelID: String) -> Result? { answers[channelID] }

    /// Unknown channels are eligible immediately; a completed negative probe
    /// suppresses the wrapper on subsequent starts.
    public nonisolated func wrapsInCaptionMaster(channelID: String) -> Bool? {
        wrapDecisions.withLock { $0[channelID] }
    }

    /// Validate the fetched playlist before either engine asks the proxy for a
    /// master. The segment probe never delays this first-play declaration.
    public func preparedRequest(_ request: ApplePlaybackRequest) async throws -> ApplePlaybackRequest {
        guard request.isLive, request.hints.nativeRemoteHLS,
              request.hints.declaresEmbeddedCaptions else { return request }
        var prepared = request
        prepared.hints.declaresEmbeddedCaptions = false
        guard wrapsInCaptionMaster(channelID: request.mediaID) != false else { return prepared }
        let clock = self.clock
        let started = clock.now
        defer {
            let elapsed = started.duration(to: clock.now)
            let milliseconds = Double(elapsed.components.seconds) * 1_000
                + Double(elapsed.components.attoseconds) / 1e15
            appleTrace("caption preflight \(Int(milliseconds.rounded())) ms")
        }
        do {
            // An inactivity timeout alone allows a trickling response to hold up
            // a channel switch indefinitely. Race the entire read against one
            // deadline, cancelling the URLSession task when the budget expires.
            let (data, _) = try await withThrowingTaskGroup(of: (Data, URL).self) { group in
                group.addTask {
                    try await self.bytes(at: request.url, headers: request.effectiveHeaders,
                                         limit: Self.maximumProbeBytes, timeout: 1.5)
                }
                group.addTask {
                    try await clock.sleep(until: started.advanced(by: Self.preflightTimeout))
                    throw URLError(.timedOut)
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else { throw CancellationError() }
                return result
            }
            if let playlist = Self.playlistText(data) {
                prepared.hints.declaresEmbeddedCaptions = AppleLiveCaptionWrapPolicy.shouldWrap(playlist: playlist)
            }
        } catch {
            // A caption preflight failure must not prevent ordinary playback.
            try Task.checkCancellation()
        }
        try Task.checkCancellation()
        return prepared
    }

    /// The headers a provider insists on. Same three a live request carries, so
    /// the probe is not refused where playback is allowed.
    public nonisolated static func headers(for channel: AppleIPTVChannel) -> [String: String] {
        var headers: [String: String] = [:]
        if let agent = channel.userAgent { headers["User-Agent"] = agent }
        if let referer = channel.referer { headers["Referer"] = referer }
        if let origin = channel.origin { headers["Origin"] = origin }
        return headers
    }

    /// Observes media playlists for a full minute before caching a negative.
    /// Callers own cancellation. Completed answers affect the next start only;
    /// playback is never interrupted. Errors never mean "no captions".
    @discardableResult
    public func probe(channelID: String, playlistURL: URL, headers: [String: String] = [:]) async -> Result? {
        if let answer = answers[channelID] { return answer }
        let clock = ContinuousClock()
        let started = clock.now
        var sampledSegments = Set<URL>()
        do {
            while true {
                try Task.checkCancellation()
                let (head, resolvedURL) = try await bytes(at: playlistURL, headers: headers,
                                                         limit: Self.maximumProbeBytes)
                guard let manifest = Self.playlistText(head) else {
                    return remember(Result(carriesUndeclaredCaptions: AppleCEA608Detector.carriesCEA608(in: head),
                                           manifestAlreadyDeclares: false), channelID: channelID)
                }
                let declares = AppleHLSCaptionDeclaration.declaresClosedCaptions(manifest)
                let media = manifest.contains("#EXTINF:") && !AppleHLSCaptionDeclaration.isMasterPlaylist(manifest)
                guard media, !declares else {
                    return remember(Result(carriesUndeclaredCaptions: false, manifestAlreadyDeclares: declares,
                                           isMediaPlaylist: media), channelID: channelID)
                }
                // Sample recent segments, not always the oldest entry in the
                // DVR window. Resolve relative URIs against the final URL.
                let segments = manifest.components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty && !$0.hasPrefix("#") }
                    .suffix(3)
                    .compactMap { URL(string: $0, relativeTo: resolvedURL)?.absoluteURL }
                guard !segments.isEmpty else { return nil }
                for segment in segments where !sampledSegments.contains(segment) {
                    let (sample, _) = try await bytes(at: segment, headers: headers, limit: Self.maximumProbeBytes)
                    guard !sample.isEmpty else { return nil }
                    if AppleCEA608Detector.carriesCEA608(in: sample) {
                        return remember(Result(carriesUndeclaredCaptions: true, manifestAlreadyDeclares: false,
                                               isMediaPlaylist: true), channelID: channelID)
                    }
                    sampledSegments.insert(segment)
                }
                if started.duration(to: clock.now) >= observationDuration {
                    return remember(Result(carriesUndeclaredCaptions: false, manifestAlreadyDeclares: false,
                                           isMediaPlaylist: true), channelID: channelID)
                }
                // Bound history even for providers with tiny live segments.
                if sampledSegments.count > 64 { sampledSegments = Set(segments) }
                try await Task.sleep(for: min(pollingInterval, observationDuration - started.duration(to: clock.now)))
            }
        } catch {
            return nil
        }
    }

    private func remember(_ result: Result, channelID: String) -> Result? {
        guard !Task.isCancelled else { return nil }
        if let answer = answers[channelID], answer.wrapsInCaptionMaster { return answer }
        answers[channelID] = result
        wrapDecisions.withLock { $0[channelID] = result.wrapsInCaptionMaster }
        return result
    }

    /// The bytes read as an HLS playlist, or `nil` when the provider handed
    /// back media instead of a manifest.
    static func playlistText(_ data: Data) -> String? {
        let head = String(decoding: data.prefix(8_192), as: UTF8.self)
        guard head.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") else { return nil }
        return String(decoding: data.prefix(2 * 1024 * 1024), as: UTF8.self)
    }

    /// Reads at most `limit` bytes and then stops.
    ///
    /// `URLSession.data(for:)` cannot be used here: a live channel's URL often
    /// answers with the transport stream itself, which never ends, and the
    /// request timeout only fires when data *stops* arriving. The first probe
    /// written that way sat on the connection until the app was killed
    /// (measured on the iPad, 2026-09-20). `Range` is still sent for the
    /// servers that honour it; the byte count is what guarantees the stop.
    private func bytes(
        at url: URL, headers: [String: String], limit: Int, timeout: TimeInterval = requestTimeout
    ) async throws -> (Data, URL) {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue("bytes=0-\(limit - 1)", forHTTPHeaderField: "Range")
        let (stream, response) = try await session.bytes(for: request)
        defer { stream.task.cancel() }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try await withTaskCancellationHandler {
            var data = Data()
            data.reserveCapacity(min(limit, 512 * 1024))
            for try await byte in stream {
                data.append(byte)
                if data.count >= limit { break }
            }
            try Task.checkCancellation()
            return (data, response.url ?? url)
        } onCancel: {
            stream.task.cancel()
        }
    }
}

/// Whether a live channel plays through a synthesized master that declares its
/// CEA-608 (`AppleHLSCaptionDeclaration.master(wrapping:)`).
///
/// AVFoundation only discovers in-band 608 through a master's
/// `CLOSED-CAPTIONS` attribute; a bare media playlist carrying it plays with no
/// captions track at all. Wrapping is limited to exactly that case: a manifest
/// that already speaks about captions (including `CLOSED-CAPTIONS=NONE`) is the
/// provider's word and stays as served, and a raw transport stream or a master
/// has nothing a one-variant wrapper could correctly stand in front of.
public enum AppleLiveCaptionWrapPolicy {
    public static func shouldWrap(playlist: String) -> Bool {
        playlist.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U")
            && playlist.contains("#EXTINF:")
            && !AppleHLSCaptionDeclaration.isMasterPlaylist(playlist)
            && !AppleHLSCaptionDeclaration.declaresClosedCaptions(playlist)
    }

    public static func shouldWrap(
        carriesEmbeddedCaptions: Bool, manifestDeclaresCaptions: Bool, isMediaPlaylist: Bool
    ) -> Bool {
        carriesEmbeddedCaptions && !manifestDeclaresCaptions && isMediaPlaylist
    }
}
