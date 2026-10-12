import Foundation
import Synchronization

public struct AppleChannelHealthConfiguration: Sendable {
    public let concurrency: Int
    public let requestTimeout: TimeInterval
    public let requestsPerSecondPerHost: Double
    public init(concurrency: Int = 4, requestTimeout: TimeInterval = 8,
                requestsPerSecondPerHost: Double = 4) {
        self.concurrency = max(1, concurrency)
        self.requestTimeout = requestTimeout.isFinite ? max(0.05, requestTimeout) : 8
        self.requestsPerSecondPerHost = requestsPerSecondPerHost.isFinite
            ? max(0.1, requestsPerSecondPerHost) : 4
    }
}

/// Shared by every rung and redirect in a sweep. No burst after a delayed wakeup.
private actor AppleHealthHostLimiter {
    private var next: [String: ContinuousClock.Instant] = [:]
    let interval: Duration
    init(rate: Double) { interval = .seconds(1 / rate) }
    func completed(_ url: URL) {
        next[url.host?.lowercased() ?? ""] = ContinuousClock.now.advanced(by: interval)
    }
    func acquire(_ url: URL) async throws {
        let host = url.host?.lowercased() ?? ""
        while true {
            try Task.checkCancellation()
            let now = ContinuousClock.now
            if let deadline = next[host], deadline > now {
                try await Task.sleep(until: deadline, clock: .continuous)
            } else {
                next[host] = now.advanced(by: interval)
                return
            }
        }
    }
}

/// A response-header callback measures first response arrival independently of body delivery.
/// Each request owns this delegate; the mutex protects callbacks, completion and cancellation.
private final class AppleHealthHTTPDelegate: NSObject, URLSessionDataDelegate, Sendable {
    struct Response: Sendable {
        let status: Int
        let ttfb: Int
        let data: Data
        let bodyFailed: Bool
        let location: String?
    }
    private struct State {
        var continuation: CheckedContinuation<Response, any Error>?
        var response: HTTPURLResponse?
        var started = ContinuousClock.now
        var ttfb = 0
        var data = Data()
        var limit = 512 * 1024
    }
    private let state = Mutex(State())

    func load(_ request: URLRequest, session: URLSession) async throws -> Response {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                state.withLock { $0.continuation = continuation; $0.started = .now }
                session.dataTask(with: request).resume()
            }
        } onCancel: { session.invalidateAndCancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(error: URLError(.badServerResponse))
            return
        }
        state.withLock {
            $0.response = http
            let elapsed = $0.started.duration(to: .now).components
            $0.ttfb = Int(elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000)
        }
        if (200..<300).contains(http.statusCode) { completionHandler(.allow) }
        else { completionHandler(.cancel); finish(error: nil) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let complete = state.withLock { value -> Bool in
            guard value.continuation != nil else { return false }
            value.data.append(data.prefix(max(0, value.limit - value.data.count)))
            if value.data.starts(with: Data("#EXTM3U".utf8)) { value.limit = 256 * 1024 }
            return value.data.count >= value.limit
        }
        if complete { finish(error: nil); dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        // responseStartDate is the first received response byte, including connection setup in TTFB.
        if let metric = metrics.transactionMetrics.first,
           let firstByte = metric.responseStartDate, let start = metric.fetchStartDate {
            state.withLock {
                $0.ttfb = max(0, Int(firstByte.timeIntervalSince(start) * 1_000))
                // Foundation can defer the response delegate while sniffing an absent MIME type.
                if $0.response == nil { $0.response = metric.response as? HTTPURLResponse }
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        finish(error: error)
    }

    private func finish(error: (any Error)?) {
        let completion = state.withLock { value -> (CheckedContinuation<Response, any Error>, Result<Response, any Error>)? in
            guard let continuation = value.continuation else { return nil }
            value.continuation = nil
            if let response = value.response {
                return (continuation, .success(Response(status: response.statusCode, ttfb: value.ttfb,
                    data: value.data, bodyFailed: error != nil, location: response.value(forHTTPHeaderField: "Location"))))
            }
            return (continuation, .failure(error ?? URLError(.badServerResponse)))
        }
        if let (continuation, result) = completion { continuation.resume(with: result) }
    }
}

public struct AppleChannelHealthProbe: Sendable {
    private let configuration: AppleChannelHealthConfiguration
    private let limiter: AppleHealthHostLimiter
    public init(configuration: AppleChannelHealthConfiguration = .init()) {
        self.configuration = configuration
        limiter = AppleHealthHostLimiter(rate: configuration.requestsPerSecondPerHost)
    }

    private struct Response: Sendable {
        let url: URL
        let status: Int
        let ttfb: Int
        let data: Data
        let bodyFailed: Bool
    }

    @concurrent
    public func probe(_ channel: AppleIPTVChannel) async throws -> AppleChannelHealthResult {
        var stage: AppleSavedSourceDiagnosticStage = .headers
        var status: Int?
        var ttfb: Int?
        var info: AppleChannelHealthVideoInfo?
        func result(_ bucket: AppleChannelHealthBucket) -> AppleChannelHealthResult {
            .init(channelID: channel.id, bucket: bucket, failedStage: bucket == .online ? nil : stage,
                  httpStatus: status, ttfbMs: ttfb, videoInfo: info)
        }
        do {
            var response = try await fetch(channel.streamURL, headers: channel.playbackHeaders)
            status = response.status
            ttfb = response.ttfb
            guard (200..<300).contains(response.status) else { return result(.offline) }
            stage = .manifest
            guard !response.bodyFailed else { return result(.reachable) }
            var media = response.data
            var encrypted = false
            if Self.isManifest(media) {
                var visited = Set<URL>()
                // Follow only the first variant, with a hard cycle/depth bound.
                while true {
                    try Task.checkCancellation()
                    guard visited.insert(response.url).inserted, visited.count <= 4,
                          let playlist = Playlist(response.data, base: response.url) else { return result(.reachable) }
                    encrypted = encrypted || playlist.encrypted
                    if let variant = playlist.variant {
                        response = try await fetch(variant, headers: channel.playbackHeaders)
                        status = response.status
                        guard (200..<300).contains(response.status), !response.bodyFailed else { return result(.reachable) }
                        continue
                    }
                    guard let segment = playlist.segment else { return result(.reachable) }
                    stage = .firstRead
                    var prefix = Data()
                    if let initialization = playlist.initialization {
                        let head = try await fetch(initialization, headers: channel.playbackHeaders)
                        status = head.status
                        guard (200..<300).contains(head.status), !head.bodyFailed, !head.data.isEmpty else { return result(.reachable) }
                        prefix = head.data
                    }
                    let sample = try await fetch(segment, headers: channel.playbackHeaders, range: playlist.range)
                    status = sample.status
                    guard (200..<300).contains(sample.status), !sample.bodyFailed, !sample.data.isEmpty else { return result(.reachable) }
                    media = prefix + sample.data
                    break
                }
            } else if AppleChannelHealthMediaProbe.formatHint(media) == nil {
                return result(.reachable) // HTML/JSON/text masquerading as HTTP success.
            }
            stage = .firstRead
            guard !media.isEmpty else { return result(.reachable) }
            // Declared encryption is classified at playback, not as a dead endpoint.
            if !encrypted, AppleChannelHealthMediaProbe.formatHint(media) == nil { return result(.reachable) }
            stage = .playbackRequest
            guard !encrypted else { return result(.reachable) }
            info = try await AppleChannelHealthMediaProbe.inspect(media, timeout: configuration.requestTimeout)
            try Task.checkCancellation()
            guard info?.hasVideo == true, info?.width != nil, info?.height != nil,
                  info?.codec != nil else { return result(.reachable) }
            return result(.online)
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            if stage == .headers {
                return result((error as? URLError)?.code == .timedOut ? .timeout : .offline)
            }
            return result(.reachable)
        }
    }

    private func fetch(_ url: URL, headers: [String: String], range: String? = nil) async throws -> Response {
        var current = url
        for _ in 0..<6 {
            try Task.checkCancellation()
            guard ["http", "https"].contains(current.scheme?.lowercased() ?? "") else {
                throw URLError(.unsupportedURL)
            }
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = configuration.requestTimeout
            config.timeoutIntervalForResource = configuration.requestTimeout
            config.urlCache = nil
            config.httpCookieStorage = nil
            config.urlCredentialStorage = nil
            let delegate = AppleHealthHTTPDelegate()
            let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            var request = URLRequest(url: current, timeoutInterval: configuration.requestTimeout)
            request.allHTTPHeaderFields = headers
            request.setValue(range ?? "bytes=0-4194303", forHTTPHeaderField: "Range")
            try await limiter.acquire(current)
            let response = try await delegate.load(request, session: session)
            try Task.checkCancellation()
            await limiter.completed(current)
            if [301, 302, 303, 307, 308].contains(response.status),
               let location = response.location,
               let target = URL(string: location, relativeTo: current)?.absoluteURL {
                current = target
                continue
            }
            return Response(url: current, status: response.status, ttfb: response.ttfb, data: response.data, bodyFailed: response.bodyFailed)
        }
        throw URLError(.httpTooManyRedirects)
    }

    private static func isManifest(_ data: Data) -> Bool {
        String(data: data.prefix(64), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") == true
    }

    private struct Playlist {
        var variant: URL?
        var segment: URL?
        var initialization: URL?
        var encrypted = false
        var range: String?
        init?(_ data: Data, base: URL) {
            guard let text = String(data: data, encoding: .utf8),
                  text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") else { return nil }
            let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            var wantsVariant = false
            var wantsSegment = false
            for line in lines {
                if line.hasPrefix("#EXT-X-STREAM-INF:") { wantsVariant = true }
                else if line.hasPrefix("#EXTINF:") { wantsSegment = true }
                else if line.hasPrefix("#EXT-X-KEY:") || line.hasPrefix("#EXT-X-SESSION-KEY:") {
                    encrypted = encrypted || !line.contains("METHOD=NONE")
                } else if line.hasPrefix("#EXT-X-MAP:") {
                    // A ranged initialization section needs a separate range, not the full object.
                    guard !line.contains("BYTERANGE="), let uri = Self.uri(line) else { return nil }
                    initialization = URL(string: uri, relativeTo: base)?.absoluteURL
                } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                    let parts = line.dropFirst("#EXT-X-BYTERANGE:".count).split(separator: "@")
                    guard let length = parts.first.flatMap({ Int64($0) }), length > 0,
                          length <= 4 * 1024 * 1024 else { return nil }
                    let offset = parts.count == 2 ? Int64(parts[1]) : 0
                    guard let offset, offset >= 0, offset <= Int64.max - length else { return nil }
                    range = "bytes=\(offset)-\(offset + length - 1)"
                } else if !line.isEmpty && !line.hasPrefix("#") {
                    guard let url = URL(string: line, relativeTo: base)?.absoluteURL else { return nil }
                    if wantsVariant { variant = url; return }
                    if wantsSegment { segment = url; return }
                    return nil
                }
            }
        }
        private static func uri(_ line: String) -> String? {
            guard let start = line.range(of: "URI=\"")?.upperBound,
                  let end = line[start...].firstIndex(of: "\"") else { return nil }
            return String(line[start..<end])
        }
    }
}

public struct AppleChannelHealthSweep: Sendable {
    public struct Progress: Sendable {
        public let completed: Int
        public let total: Int
        public let result: AppleChannelHealthResult
    }
    private let configuration: AppleChannelHealthConfiguration
    public init(configuration: AppleChannelHealthConfiguration = .init()) { self.configuration = configuration }

    /// Structured children are bounded; cancellation throws, never records a false outage.
    /// Completed results remain in history when the caller cancels a partial sweep.
    @concurrent
    public func run(_ lineup: [AppleIPTVChannel], history: AppleChannelHealthHistory? = .shared,
                    progress: @escaping @Sendable (Progress) async -> Void = { _ in }) async throws -> [AppleChannelHealthResult] {
        let probe = AppleChannelHealthProbe(configuration: configuration)
        return try await withThrowingTaskGroup(of: AppleChannelHealthResult.self) { group in
            var next = 0
            var results: [AppleChannelHealthResult] = []
            for _ in 0..<min(configuration.concurrency, lineup.count) {
                let channel = lineup[next]
                next += 1
                group.addTask { try await probe.probe(channel) }
            }
            while let result = try await group.next() {
                try Task.checkCancellation()
                results.append(result)
                try await history?.record(result)
                await progress(.init(completed: results.count, total: lineup.count, result: result))
                if next < lineup.count {
                    let channel = lineup[next]
                    next += 1
                    group.addTask { try await probe.probe(channel) }
                }
            }
            try Task.checkCancellation()
            return results
        }
    }
}
