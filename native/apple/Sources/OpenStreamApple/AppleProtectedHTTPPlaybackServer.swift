import Foundation
import Network

public enum AppleProtectedHTTPPlaybackError: Error, LocalizedError, Sendable {
    case listenerUnavailable
    case invalidUpstream
    case invalidRequest

    public var errorDescription: String? {
        switch self {
        case .listenerUnavailable: "OpenStream couldn’t start its private Live TV playback bridge."
        case .invalidUpstream: "The Live TV provider returned an invalid stream address."
        case .invalidRequest: "The private Live TV playback request was invalid."
        }
    }
}

/// Hides credential-bearing provider routes behind a loopback-only, expiring
/// capability URL before they reach AVPlayer or any user-visible player UI.
/// The upstream URL exists only in this actor's volatile session table.
public actor AppleProtectedHTTPPlaybackServer {
    public static let shared = AppleProtectedHTTPPlaybackServer()

    private struct Session: Sendable {
        let upstreamURL: URL
        let requestHeaders: [String: String]
        let expiresAt: Date
        var childURLs: [String: URL]
        /// Current manifests pin every referenced resource. Older segments
        /// retain a bounded grace window for in-flight reads and live seeks.
        var childOrder: [String] = []
        var playlistResources: [String: Set<String>] = [:]
        var playlistOrder: [String] = []
        /// Sticky final URL (post-redirect) from the most recent successful
        /// playlist fetch of `upstreamURL` itself. A load-balanced panel that
        /// 302s to a different edge host on every request would otherwise
        /// make "the same" live media sequence resolve to a different
        /// absolute segment URL on every playlist refresh; going straight to
        /// this URL on subsequent refreshes keeps it pinned to one edge.
        var resolvedPlaylistURL: URL? = nil
        /// Same stickiness as `resolvedPlaylistURL`, keyed per child resource
        /// ID, for registered children that are themselves playlists (e.g. a
        /// media playlist referenced from a master playlist).
        var childResolvedURLs: [String: URL] = [:]
    }

    private var sessions: [String: Session] = [:]
    private var listener: NWListener?
    private var listenerError: (any Error)?
    private var listenerIsReady = false

    public init() {}

    public func playbackURL(
        upstreamURL: URL,
        requestHeaders: [String: String] = [:],
        lifetime: TimeInterval = 4 * 60 * 60
    ) async throws -> URL {
        guard let scheme = upstreamURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              upstreamURL.host?.isEmpty == false else {
            throw AppleProtectedHTTPPlaybackError.invalidUpstream
        }
        let port = try await ensureListener()
        sessions = sessions.filter { $0.value.expiresAt > .now }
        guard sessions.count < 512 else { throw AppleProtectedHTTPPlaybackError.listenerUnavailable }
        let token = Self.token()
        sessions[token] = Session(
            upstreamURL: upstreamURL,
            requestHeaders: Self.safeHeaders(requestHeaders),
            expiresAt: .now.addingTimeInterval(min(max(lifetime, 60), 24 * 60 * 60)),
            childURLs: [:]
        )
        let ext = Self.safeExtension(upstreamURL.pathExtension)
        return URL(string: "http://127.0.0.1:\(port)/live/\(token)/stream.\(ext)")!
    }

    public func revoke(playbackURL: URL) {
        let pieces = playbackURL.path.split(separator: "/")
        guard pieces.count >= 2, pieces[0] == "live" else { return }
        sessions.removeValue(forKey: String(pieces[1]))
        stopListenerIfIdle()
    }

    func diagnostics() -> (sessionCount: Int, listenerActive: Bool, childResourceCount: Int) {
        (sessions.count, listener != nil, sessions.values.reduce(0) { $0 + $1.childURLs.count })
    }

    private func ensureListener() async throws -> UInt16 {
        if listenerIsReady, let port = listener?.port?.rawValue { return port }
        if listener == nil {
            listenerError = nil
            listenerIsReady = false
            let parameters = NWParameters.tcp
            parameters.requiredInterfaceType = .loopback
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters, on: .any)
            listener.stateUpdateHandler = { [weak self] state in
                if case .ready = state {
                    Task { await self?.recordListenerReady() }
                } else if case .failed(let error) = state {
                    Task { await self?.recordListenerError(error) }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { await self?.accept(connection) }
            }
            listener.start(queue: DispatchQueue(label: "com.orgista.openstream.live-shield"))
            self.listener = listener
        }
        for _ in 0 ..< 100 {
            if listenerError != nil { throw AppleProtectedHTTPPlaybackError.listenerUnavailable }
            if listenerIsReady, let port = listener?.port?.rawValue { return port }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw AppleProtectedHTTPPlaybackError.listenerUnavailable
    }

    private func recordListenerReady() { listenerIsReady = true }
    private func recordListenerError(_ error: any Error) {
        listenerError = error
        listenerIsReady = false
        listener?.cancel()
        listener = nil
    }

    private func stopListenerIfIdle() {
        guard sessions.isEmpty else { return }
        listener?.cancel()
        listener = nil
        listenerError = nil
        listenerIsReady = false
    }

    private func accept(_ connection: NWConnection) async {
        guard Self.isLoopback(connection.endpoint) else {
            connection.cancel()
            return
        }
        connection.start(queue: DispatchQueue(label: "com.orgista.openstream.live-shield.connection"))
        let timeout = Task {
            try? await Task.sleep(for: .seconds(10))
            if !Task.isCancelled { connection.cancel() }
        }
        do {
            let request = try await receiveRequest(connection)
            timeout.cancel()
            try await respond(to: request, connection: connection)
        } catch {
            timeout.cancel()
            try? await send(
                Data("HTTP/1.1 400 Bad Request\r\nConnection: close\r\nContent-Length: 0\r\n\r\n".utf8),
                connection: connection,
                final: true
            )
        }
        timeout.cancel()
        connection.cancel()
    }

    private func respond(to rawRequest: String, connection: NWConnection) async throws {
        let lines = rawRequest.components(separatedBy: "\r\n")
        let requestParts = lines.first?.split(separator: " ") ?? []
        guard requestParts.count >= 2 else { throw AppleProtectedHTTPPlaybackError.invalidRequest }
        let method = String(requestParts[0]).uppercased()
        guard method == "GET" || method == "HEAD" else {
            throw AppleProtectedHTTPPlaybackError.invalidRequest
        }
        let pieces = String(requestParts[1]).split(separator: "/")
        guard pieces.count >= 3, pieces[0] == "live" else {
            throw AppleProtectedHTTPPlaybackError.invalidRequest
        }
        let token = String(pieces[1])
        guard let session = sessions[token], session.expiresAt > .now else {
            try await send(
                Data("HTTP/1.1 404 Not Found\r\nConnection: close\r\nContent-Length: 0\r\n\r\n".utf8),
                connection: connection,
                final: true
            )
            return
        }
        let childID: String?
        let originURL: URL
        if pieces.count >= 4, pieces[2] == "resource" {
            let id = String(pieces[3])
            guard let child = session.childURLs[id] else {
                try await send(
                    Data("HTTP/1.1 404 Not Found\r\nConnection: close\r\nContent-Length: 0\r\n\r\n".utf8),
                    connection: connection,
                    final: true
                )
                return
            }
            childID = id
            originURL = child
        } else {
            childID = nil
            originURL = session.upstreamURL
        }

        // Prefer the sticky final URL from a prior successful playlist fetch
        // of this same resource (root or child) over re-resolving `originURL`,
        // so a load-balanced panel that 302s to a different edge on every
        // request can't make the same media sequence resolve to a different
        // absolute segment URL between two live playlist refreshes.
        let stickyTarget = Self.stickyURL(childID: childID, in: session)
        var attempt = await attemptFetch(
            method: method,
            lines: lines,
            requestHeaders: session.requestHeaders,
            targetURL: stickyTarget ?? originURL,
            originURL: originURL,
            connection: connection
        )
        if stickyTarget != nil, Self.isFailedAttempt(attempt) {
            // The sticky edge is gone (network error or non-2xx); fall back
            // to the original panel URL once and let it re-resolve to a
            // (possibly different) edge.
            setStickyURL(nil, childID: childID, sessionToken: token)
            attempt = await attemptFetch(
                method: method,
                lines: lines,
                requestHeaders: session.requestHeaders,
                targetURL: originURL,
                originURL: originURL,
                connection: connection
            )
        }

        switch attempt {
        case .handled:
            return
        case .failed(let error):
            throw error
        case .playlist(let response, let body):
            guard Self.isSuccessfulPlaylist(response, body: body) else {
                try await send(Self.emptyPlaylistResponse(), connection: connection, final: true)
                return
            }
            let finalURL = response.url ?? originURL
            setStickyURL(finalURL, childID: childID, sessionToken: token)
            let rewritten = try rewriteHLSPlaylist(body, baseURL: finalURL, sessionToken: token,
                                                 playlistID: childID ?? "root")
            try await send(
                Self.responseHeaders(
                    response,
                    contentType: "application/vnd.apple.mpegurl",
                    contentLength: rewritten.count
                ),
                connection: connection,
                final: false
            )
            try await send(rewritten, connection: connection, final: true)
        }
    }

    private enum PlaylistAttempt {
        case handled
        case playlist(response: HTTPURLResponse, body: Data)
        case failed(any Error)
    }

    private func attemptFetch(
        method: String,
        lines: [String],
        requestHeaders: [String: String],
        targetURL: URL,
        originURL: URL,
        connection: NWConnection
    ) async -> PlaylistAttempt {
        do {
            return try await fetchUpstream(
                method: method,
                lines: lines,
                requestHeaders: requestHeaders,
                targetURL: targetURL,
                originURL: originURL,
                connection: connection
            )
        } catch {
            return .failed(error)
        }
    }

    private static func isFailedAttempt(_ attempt: PlaylistAttempt) -> Bool {
        switch attempt {
        case .handled: false
        case .failed: true
        case .playlist(let response, let body): !isSuccessfulPlaylist(response, body: body)
        }
    }

    private static func isSuccessfulPlaylist(_ response: HTTPURLResponse, body: Data) -> Bool {
        (200 ... 299).contains(response.statusCode) && !body.isEmpty
    }

    private static func stickyURL(childID: String?, in session: Session) -> URL? {
        guard let childID else { return session.resolvedPlaylistURL }
        return session.childResolvedURLs[childID]
    }

    private func setStickyURL(_ url: URL?, childID: String?, sessionToken: String) {
        guard var session = sessions[sessionToken] else { return }
        if let childID {
            session.childResolvedURLs[childID] = url
        } else {
            session.resolvedPlaylistURL = url
        }
        sessions[sessionToken] = session
    }

    /// Fetches `targetURL` and either streams the response straight to
    /// `connection` (a HEAD request, or any non-playlist body) and returns
    /// `.handled`, or — for anything recognized as an HLS playlist — buffers
    /// the full body and returns it unsent, so the caller can validate it and
    /// decide whether to retry against a different URL before committing any
    /// bytes to the client connection. `originURL` is the session's (or
    /// child's) pre-redirect upstream URL, used only to decide whether
    /// `targetURL` is same-origin for header-forwarding purposes.
    private func fetchUpstream(
        method: String,
        lines: [String],
        requestHeaders: [String: String],
        targetURL: URL,
        originURL: URL,
        connection: NWConnection
    ) async throws -> PlaylistAttempt {
        var upstreamRequest = URLRequest(url: targetURL)
        upstreamRequest.httpMethod = method
        upstreamRequest.timeoutInterval = 30
        upstreamRequest.cachePolicy = .reloadIgnoringLocalCacheData
        for (name, value) in requestHeaders {
            upstreamRequest.setValue(value, forHTTPHeaderField: name)
        }
        if let range = Self.header(named: "range", in: lines) {
            upstreamRequest.setValue(range, forHTTPHeaderField: "Range")
        }
        // `targetURL` can be a previously-redirected sticky URL fetched
        // directly, with no redirect hop left for the delegate to sanitize,
        // so the same cross-origin header policy the redirect handler
        // applies must also be applied here, up front.
        if !Self.isSameOrigin(targetURL, originURL) {
            upstreamRequest = AppleHTTPStreamDelegate.sanitizedCrossOriginRequest(upstreamRequest)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        let delegate = AppleHTTPStreamDelegate(allowedOrigin: targetURL)
        let urlSession = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let dataTask = urlSession.dataTask(with: upstreamRequest)
        defer {
            dataTask.cancel()
            urlSession.invalidateAndCancel()
        }
        dataTask.resume()

        var response: HTTPURLResponse?
        var isPlaylist = false
        var playlist = Data()
        for try await event in delegate.events {
            switch event {
            case .response(let value):
                guard let http = value as? HTTPURLResponse,
                      let finalScheme = http.url?.scheme?.lowercased(),
                      finalScheme == "http" || finalScheme == "https" else {
                    throw AppleProtectedHTTPPlaybackError.invalidUpstream
                }
                response = http
                isPlaylist = Self.isHLSPlaylist(
                    url: http.url ?? targetURL,
                    contentType: http.value(forHTTPHeaderField: "Content-Type") ?? ""
                )
                if method == "HEAD" {
                    try await send(Self.responseHeaders(http), connection: connection, final: true)
                    return .handled
                }
                if !isPlaylist {
                    try await send(Self.responseHeaders(http), connection: connection, final: false)
                }
            case .data(let data):
                guard response != nil else { throw AppleProtectedHTTPPlaybackError.invalidUpstream }
                if isPlaylist {
                    guard playlist.count + data.count <= 5 * 1_024 * 1_024 else {
                        throw AppleProtectedHTTPPlaybackError.invalidUpstream
                    }
                    playlist.append(data)
                } else {
                    try await send(data, connection: connection, final: false)
                }
            }
        }
        guard let response else { throw AppleProtectedHTTPPlaybackError.invalidUpstream }
        if isPlaylist {
            return .playlist(response: response, body: playlist)
        }
        try await send(Data(), connection: connection, final: true)
        return .handled
    }

    private func rewriteHLSPlaylist(
        _ data: Data,
        baseURL: URL,
        sessionToken: String,
        playlistID: String
    ) throws -> Data {
        guard let text = String(data: data, encoding: .utf8),
              let port = listener?.port?.rawValue,
              var session = sessions[sessionToken] else {
            throw AppleProtectedHTTPPlaybackError.invalidUpstream
        }
        var resources: [String: URL] = [:]
        var order: [String] = []
        let lines = try text.components(separatedBy: .newlines).map { line -> String in
            let clean = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { return line }
            if !clean.hasPrefix("#") {
                guard let upstream = Self.safeResolvedURL(clean, relativeTo: baseURL) else {
                    throw AppleProtectedHTTPPlaybackError.invalidUpstream
                }
                return try registerHLSResource(upstream, sessionToken: sessionToken, port: port,
                                               resources: &resources, order: &order)
            }
            return try rewriteQuotedHLSURIs(line, baseURL: baseURL, sessionToken: sessionToken,
                                            port: port, resources: &resources, order: &order)
        }

        // Publish one complete manifest atomically. Evicting while rewriting
        // made the first segment, key, and init map of long VODs return 404.
        session.playlistResources[playlistID] = Set(resources.keys)
        if playlistID != "root" {
            session.playlistOrder.removeAll { $0 == playlistID }
            session.playlistOrder.append(playlistID)
            if session.playlistOrder.count > Self.maxChildPlaylistsPerSession {
                let evicted = session.playlistOrder.removeFirst()
                session.playlistResources.removeValue(forKey: evicted)
            }
        }
        let active = session.playlistResources.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        guard active.count <= Self.maxActiveResourcesPerSession else {
            throw AppleProtectedHTTPPlaybackError.invalidUpstream
        }
        let refreshed = Set(resources.keys)
        session.childOrder.removeAll { refreshed.contains($0) }
        session.childOrder.append(contentsOf: order)
        let recent = session.childOrder.filter { !active.contains($0) }.suffix(Self.maxRecentResourcesPerSession)
        let retained = active.union(recent)
        session.childURLs.merge(resources) { _, new in new }
        session.childURLs = session.childURLs.filter { retained.contains($0.key) }
        session.childResolvedURLs = session.childResolvedURLs.filter { retained.contains($0.key) }
        session.childOrder.removeAll { !retained.contains($0) }
        sessions[sessionToken] = session
        return Data(lines.joined(separator: "\n").utf8)
    }

    private func rewriteQuotedHLSURIs(
        _ line: String,
        baseURL: URL,
        sessionToken: String,
        port: UInt16,
        resources: inout [String: URL],
        order: inout [String]
    ) throws -> String {
        guard let expression = Self.hlsURIExpression else { return line }
        let range = NSRange(line.startIndex..., in: line)
        var result = line
        for match in expression.matches(in: line, range: range).reversed() {
            guard let valueRange = Range(match.range(at: 1), in: line),
                  let replacementRange = Range(match.range(at: 1), in: result),
                  let upstream = Self.safeResolvedURL(String(line[valueRange]), relativeTo: baseURL) else {
                throw AppleProtectedHTTPPlaybackError.invalidUpstream
            }
            result.replaceSubrange(
                replacementRange,
                with: try registerHLSResource(upstream, sessionToken: sessionToken, port: port,
                                               resources: &resources, order: &order)
            )
        }
        return result
    }

    /// Stable session-scoped IDs survive playlist refreshes and keep provider
    /// credentials out of the URLs passed to the player.
    private func registerHLSResource(
        _ url: URL, sessionToken: String, port: UInt16,
        resources: inout [String: URL], order: inout [String]
    ) throws -> String {
        let resourceID = Self.childResourceID(upstreamURL: url, sessionToken: sessionToken)
        if resources[resourceID] == nil {
            guard resources.count < Self.maxActiveResourcesPerSession else {
                throw AppleProtectedHTTPPlaybackError.invalidUpstream
            }
            order.append(resourceID)
        }
        resources[resourceID] = url
        return "http://127.0.0.1:\(port)/live/\(sessionToken)/resource/\(resourceID)"
    }

    // Bound current manifests separately from the rolling live grace window.
    // A capacity failure leaves the last valid manifest's resources intact.
    private static let maxActiveResourcesPerSession = 16_384
    private static let maxRecentResourcesPerSession = 512
    private static let maxChildPlaylistsPerSession = 32

    private static func childResourceID(upstreamURL: URL, sessionToken: String) -> String {
        ApplePlaybackIdentity.digest(for: sessionToken + upstreamURL.absoluteString)
    }

    private func receiveRequest(_ connection: NWConnection) async throws -> String {
        var data = Data()
        while data.count < 65_536 {
            let chunk = try await receive(connection)
            data.append(chunk)
            if data.range(of: Data("\r\n\r\n".utf8)) != nil { break }
            if chunk.isEmpty { break }
        }
        guard data.range(of: Data("\r\n\r\n".utf8)) != nil,
              let value = String(data: data, encoding: .utf8) else {
            throw AppleProtectedHTTPPlaybackError.invalidRequest
        }
        return value
    }

    private func receive(_ connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: data ?? Data()) }
            }
        }
    }

    private func send(_ data: Data, connection: NWConnection, final: Bool) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, contentContext: .defaultMessage, isComplete: final, completion: .contentProcessed {
                if let error = $0 { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    private static func header(named name: String, in lines: [String]) -> String? {
        lines.first { $0.lowercased().hasPrefix("\(name):") }
            .flatMap { $0.split(separator: ":", maxSplits: 1).last }
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { safeHeaderValue($0) ? $0 : nil }
    }

    private static func safeHeaders(_ values: [String: String]) -> [String: String] {
        let allowed = Set(["user-agent", "referer", "origin", "cookie", "authorization"])
        return Dictionary(uniqueKeysWithValues: values.compactMap { name, value in
            guard allowed.contains(name.lowercased()), safeHeaderValue(value) else { return nil }
            return (name, value)
        })
    }

    private static func safeHeaderValue(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 2_048
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static func responseHeaders(
        _ response: HTTPURLResponse,
        contentType: String? = nil,
        contentLength: Int? = nil
    ) -> Data {
        var headers = "HTTP/1.1 \(response.statusCode) \(reason(response.statusCode))\r\n"
        if let contentType {
            headers += "Content-Type: \(contentType)\r\n"
        } else if let value = response.value(forHTTPHeaderField: "Content-Type"), safeHeaderValue(value) {
            headers += "Content-Type: \(value)\r\n"
        }
        if let contentLength {
            headers += "Content-Length: \(contentLength)\r\n"
        } else {
            for name in ["Content-Length", "Content-Range", "Accept-Ranges"] {
                if let value = response.value(forHTTPHeaderField: name), safeHeaderValue(value) {
                    headers += "\(name): \(value)\r\n"
                }
            }
        }
        headers += "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        return Data(headers.utf8)
    }

    /// Sent instead of a 0-byte playlist so AVPlayer reports a clear failure
    /// (CoreMediaErrorDomain -12887) rather than "0 Length playlist".
    private static func emptyPlaylistResponse() -> Data {
        let body = Data("upstream returned an empty playlist".utf8)
        let headers = "HTTP/1.1 502 \(reason(502))\r\n"
            + "Content-Type: text/plain\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        return Data(headers.utf8) + body
    }

    private static func safeExtension(_ value: String) -> String {
        let clean = value.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        return clean.isEmpty ? "ts" : String(clean.prefix(8))
    }

    private static func isHLSPlaylist(url: URL, contentType: String) -> Bool {
        let type = contentType.lowercased()
        return url.pathExtension.lowercased() == "m3u8"
            || url.pathExtension.lowercased() == "m3u"
            || type.contains("mpegurl")
    }

    private static func safeResolvedURL(_ value: String, relativeTo baseURL: URL) -> URL? {
        guard let url = URL(string: value, relativeTo: baseURL)?.absoluteURL,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false,
              url.user == nil,
              url.password == nil else { return nil }
        // Playlist child URIs (segments, keys, variant playlists) are allowed
        // to live on a different origin than the playlist itself: providers
        // routinely serve manifests from a panel host and media from a CDN.
        return url
    }

    private static func isSameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && effectivePort(lhs) == effectivePort(rhs)
    }

    private static func effectivePort(_ url: URL) -> Int? {
        url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
    }

    private static let hlsURIExpression = try? NSRegularExpression(pattern: #"URI=\"([^\"]+)\""#)

    private static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        let value = String(describing: host).lowercased()
        return value == "127.0.0.1" || value == "::1" || value == "localhost"
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 206: "Partial Content"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 416: "Range Not Satisfiable"
        case 500 ... 599: "Upstream Error"
        default: "Response"
        }
    }

    private static func token() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private enum AppleHTTPStreamEvent: @unchecked Sendable {
    case response(URLResponse)
    case data(Data)
}

private final class AppleHTTPStreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let events: AsyncThrowingStream<AppleHTTPStreamEvent, any Error>

    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<AppleHTTPStreamEvent, any Error>.Continuation?
    private let allowedOrigin: URL
    private var redirectCount = 0

    private static let maxRedirectHops = 5
    private static let crossOriginForwardableHeaders: Set<String> = [
        "user-agent", "accept", "range", "icy-metadata",
    ]

    init(allowedOrigin: URL) {
        self.allowedOrigin = allowedOrigin
        var captured: AsyncThrowingStream<AppleHTTPStreamEvent, any Error>.Continuation?
        events = AsyncThrowingStream(bufferingPolicy: .bufferingOldest(16)) { captured = $0 }
        continuation = captured
        super.init()
    }

    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let hopCount = lock.withLock {
            redirectCount += 1
            return redirectCount
        }
        guard hopCount <= Self.maxRedirectHops, let target = request.url else {
            completionHandler(nil)
            return
        }
        // Same-origin redirects keep every header as-is (today's behaviour).
        // Cross-origin redirects (panel host -> CDN/edge host is the common
        // Xtream/IPTV case) are still followed, but only carry a header
        // subset that can't leak the panel's credentials to a third party.
        guard Self.isSameOrigin(target, allowedOrigin) else {
            completionHandler(Self.sanitizedCrossOriginRequest(request))
            return
        }
        completionHandler(request)
    }

    fileprivate static func sanitizedCrossOriginRequest(_ request: URLRequest) -> URLRequest {
        guard let url = request.url else { return request }
        var sanitized = URLRequest(url: url)
        sanitized.httpMethod = request.httpMethod
        sanitized.cachePolicy = request.cachePolicy
        sanitized.timeoutInterval = request.timeoutInterval
        for (name, value) in request.allHTTPHeaderFields ?? [:]
            where crossOriginForwardableHeaders.contains(name.lowercased()) {
            sanitized.setValue(value, forHTTPHeaderField: name)
        }
        return sanitized
    }

    func urlSession(
        _: URLSession,
        dataTask _: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        lock.withLock { _ = continuation?.yield(.response(response)) }
        completionHandler(.allow)
    }

    func urlSession(_: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let result = lock.withLock { continuation?.yield(.data(data)) }
        if case .dropped? = result {
            dataTask.cancel()
            finish(throwing: URLError(.dataLengthExceedsMaximum))
        }
    }

    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        finish(throwing: error)
    }

    private func finish(throwing error: (any Error)?) {
        lock.withLock {
            guard let continuation else { return }
            self.continuation = nil
            if let error { continuation.finish(throwing: error) }
            else { continuation.finish() }
        }
    }

    private static func isSameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && effectivePort(lhs) == effectivePort(rhs)
    }

    private static func effectivePort(_ url: URL) -> Int? {
        url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
    }
}
