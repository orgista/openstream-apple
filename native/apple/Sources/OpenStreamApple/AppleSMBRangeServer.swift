import Foundation
import Network

public enum AppleSMBRangeServerError: Error, LocalizedError, Sendable {
    case listenerUnavailable
    case invalidMedia

    public var errorDescription: String? {
        switch self {
        case .listenerUnavailable: "oStream couldn’t start its private SMB playback bridge."
        case .invalidMedia: "The selected SMB file is no longer available."
        }
    }
}

/// A loopback-only HTTP byte-range bridge for AVPlayer. The random token is a
/// short-lived capability; SMB credentials and paths never appear in logs or
/// in a public network response.
///
/// Connections are kept alive between requests. A bounded range is one SMB
/// open. An open-ended range starts with a few small reads and, if the player
/// keeps reading, goes on as one SMB open streamed as the share answers.
public actor AppleSMBRangeServer {
    public static let shared = AppleSMBRangeServer(structureStore: .standard)

    private struct Session: Sendable {
        let sourceURL: URL
        let credentials: AppleSMBCredentials
        var sizeBytes: UInt64
        let modifiedAt: Date?
        let expiresAt: Date
        /// The share confirmed `sizeBytes`, or couldn't say.
        var sizeChecked = false

        /// The file as the block cache knows it: a file replaced at the same
        /// path and size is another file.
        var cacheFile: String {
            "\(sourceURL.absoluteString)#\(sizeBytes)#\(modifiedAt?.timeIntervalSince1970 ?? 0)"
        }

        var isDiscImage: Bool {
            AppleDiscImagePolicy.imageExtensions.contains(sourceURL.pathExtension.lowercased())
        }
    }

    private let client: any AppleNetworkShareClient
    private let readTimeout: Duration
    private let addedLatency: Duration
    private let usesBlockCache: Bool
    private let structureStore: AppleDiscStructureStore?
    private var blockCache = AppleSMBBlockCache()
    private var readStats: [String: AppleSMBReadStats] = [:]
    private struct ConnectionJob {
        let connection: NWConnection
        let task: Task<Void, Never>
        var token: String?
        var responseStarted = false
    }
    private var connectionJobs: [UUID: ConnectionJob] = [:]
    private var sessions: [String: Session] = [:]
    private var listener: NWListener?
    private var listenerError: (any Error)?
    private var listenerIsReady = false

    public init(
        client: any AppleNetworkShareClient = AppleSMBClient(),
        readTimeout: Duration = .seconds(30),
        addedLatency: Duration = AppleSMBRangeServer.launchArgumentLatency(),
        usesBlockCache: Bool = AppleSMBRangeServer.launchArgumentUsesBlockCache(),
        structureStore: AppleDiscStructureStore? = nil
    ) {
        self.client = client
        self.readTimeout = max(readTimeout, .milliseconds(1))
        self.addedLatency = addedLatency
        self.usesBlockCache = usesBlockCache
        self.structureStore = structureStore
    }

    /// `-OpenStreamSMBTestLatencyMs 40` (Debug builds): a pause before every
    /// SMB read, so a device on a fast LAN can stand in for a slow Wi-Fi path.
    public static func launchArgumentLatency() -> Duration {
        #if DEBUG
        let value = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["OpenStreamSMBTestLatencyMs"]
        let milliseconds = (value as? String).flatMap(Int.init) ?? (value as? Int) ?? 0
        return .milliseconds(min(max(milliseconds, 0), 500))
        #else
        return .zero
        #endif
    }

    /// `-OpenStreamSMBBlockCache NO` (Debug builds): the bridge as it was
    /// before the disc block cache, for before/after measurements.
    public static func launchArgumentUsesBlockCache() -> Bool {
        #if DEBUG
        let value = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["OpenStreamSMBBlockCache"]
        return (value as? String).map { $0.uppercased() != "NO" } ?? true
        #else
        return true
        #endif
    }

    /// Bytes the bridge has sent for `playbackURL` so far; 0 for a URL it did
    /// not issue. A disc image's start shows its progress here while the
    /// engine reads the disc structure and reports nothing else.
    func bytesServed(playbackURL: URL) -> UInt64 {
        Self.token(of: playbackURL).flatMap { readStats[$0]?.bytesServed } ?? 0
    }

    /// Why the share would not open the file behind `playbackURL`, when it would not.
    func openFailure(playbackURL: URL) -> AppleSMBError? {
        Self.token(of: playbackURL).flatMap { readStats[$0]?.openFailure }
    }

    func readStats(playbackURL: URL) -> AppleSMBReadStats? {
        Self.token(of: playbackURL).flatMap { readStats[$0] }
    }

    public func playbackURL(
        sourceURL: URL,
        credentials: AppleSMBCredentials,
        sizeBytes: Int64,
        modifiedAt: Date? = nil,
        lifetime: TimeInterval = 4 * 60 * 60
    ) async throws -> URL {
        guard sourceURL.scheme?.lowercased() == "smb", sizeBytes > 0 else {
            throw AppleSMBRangeServerError.invalidMedia
        }
        let port = try await ensureListener()
        sessions = sessions.filter { $0.value.expiresAt > .now }
        readStats = readStats.filter { sessions[$0.key] != nil }
        guard sessions.count < 32 else { throw AppleSMBRangeServerError.listenerUnavailable }
        let token = Self.token()
        let session = Session(
            sourceURL: sourceURL,
            credentials: credentials,
            sizeBytes: UInt64(sizeBytes),
            modifiedAt: modifiedAt,
            expiresAt: .now.addingTimeInterval(min(max(lifetime, 60), 24 * 60 * 60))
        )
        sessions[token] = session
        if let store = discStore(for: session) {
            let stored = await store.blocks(file: session.cacheFile, fileSize: session.sizeBytes)
            for (index, block) in stored {
                let key = AppleSMBBlockCache.Key(file: session.cacheFile, index: index)
                if blockCache.block(for: key) == nil { blockCache.store(block, for: key) }
            }
            readStats[token, default: AppleSMBReadStats()].diskBlocks = stored.count
        }
        let filename = sourceURL.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            ?? "media"
        return URL(string: "http://127.0.0.1:\(port)/media/\(token)/\(filename)")!
    }

    public func revoke(playbackURL: URL) async {
        guard let token = Self.token(of: playbackURL), sessions[token] != nil else { return }
        if let stats = readStats.removeValue(forKey: token), stats.requests > 0 {
            AppleInteractionTrace.record(.network, "smb bridge \(playbackURL.lastPathComponent.suffix(48)): \(stats.traceLine)")
        }
        sessions.removeValue(forKey: token)
        cancelConnections(token: token)
        if sessions.isEmpty {
            cancelConnections()
            await client.closeAll()
        }
        stopListenerIfIdle()
    }

    public func removeAllSessions() async {
        sessions.removeAll()
        readStats.removeAll()
        blockCache.removeAll()
        cancelConnections()
        await client.closeAll()
        stopListenerIfIdle()
    }

    private func discStore(for session: Session) -> AppleDiscStructureStore? {
        guard usesBlockCache, session.isDiscImage, session.modifiedAt != nil else { return nil }
        return structureStore
    }

    func diagnostics() -> (sessionCount: Int, listenerActive: Bool, connectionCount: Int) {
        (sessions.count, listener != nil, connectionJobs.count)
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
            listener.service = nil
            listener.stateUpdateHandler = { [weak self] state in
                if case .ready = state {
                    Task { await self?.recordListenerReady() }
                } else if case .failed(let error) = state {
                    Task { await self?.recordListenerError(error) }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { await self?.startConnection(connection) }
            }
            listener.start(queue: DispatchQueue(label: "com.orgista.openstream.smb-range"))
            self.listener = listener
        }

        for _ in 0 ..< 100 {
            if listenerError != nil { throw AppleSMBRangeServerError.listenerUnavailable }
            if listenerIsReady, let port = listener?.port?.rawValue { return port }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw AppleSMBRangeServerError.listenerUnavailable
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

    private func startConnection(_ connection: NWConnection) {
        let id = UUID()
        let task = Task { [weak self] in
            guard let self else { connection.cancel(); return }
            await self.accept(connection, id: id)
        }
        connectionJobs[id] = ConnectionJob(connection: connection, task: task)
    }

    private func cancelConnections(token: String? = nil) {
        let ids = connectionJobs.compactMap { id, job in token == nil || job.token == token ? id : nil }
        for id in ids {
            guard let job = connectionJobs.removeValue(forKey: id) else { continue }
            job.task.cancel()
            job.connection.cancel()
        }
    }

    private func accept(_ connection: NWConnection, id: UUID) async {
        defer {
            connectionJobs.removeValue(forKey: id)
            connection.cancel()
        }
        guard Self.isLoopback(connection.endpoint) else {
            connection.cancel()
            return
        }
        connection.start(queue: DispatchQueue(label: "com.orgista.openstream.smb-range.connection"))
        // The engine's disc reader asks for hundreds of small ranges; each one
        // on a new connection was a new loopback handshake.
        var pending = Data()
        var keepAlive = true
        while keepAlive, !Task.isCancelled {
            connectionJobs[id]?.responseStarted = false
            let timeout = Task {
                try? await Task.sleep(for: .seconds(10))
                if !Task.isCancelled { connection.cancel() }
            }
            do {
                let request = try await receiveRequest(connection, pending: &pending)
                timeout.cancel()
                guard let request else { break }
                keepAlive = try await respond(to: request, connection: connection, id: id)
            } catch {
                timeout.cancel()
                if !Task.isCancelled, connectionJobs[id]?.responseStarted != true { try? await send(
                    Data("HTTP/1.1 400 Bad Request\r\nConnection: close\r\nContent-Length: 0\r\n\r\n".utf8),
                    connection: connection,
                    final: true
                ) }
                keepAlive = false
            }
        }
        connection.cancel()
    }

    /// The session with the file's size as the share has it now. A library
    /// scanned before a file was replaced at the same path holds the old size:
    /// a Sonarr upgrade swaps an episode in place (S03E04 on the NAS shrank
    /// by 103,739 bytes under the same name on 2026-10-30).
    private func checkSize(of session: Session, token: String) async throws -> Session {
        var checked = session
        checked.sizeChecked = true
        let source = session.sourceURL, credentials = session.credentials
        let size: UInt64?
        do {
            size = try await withReadTimeout { [client] in try await client.fileSize(url: source, credentials: credentials) }
        } catch let error as AppleSMBError where error == .notFound {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // A slow or failed check leaves the read to find out, with its own retry.
            size = nil
        }
        if let size, size > 0, size != session.sizeBytes {
            AppleInteractionTrace.record(.network,
                "smb bridge \(source.lastPathComponent): size \(size) on the share, \(session.sizeBytes) in the library")
            checked.sizeBytes = size
        }
        if sessions[token] != nil { sessions[token] = checked }
        return checked
    }

    /// Answers one request; true when the connection can take another.
    private func respond(to request: String, connection: NWConnection, id: UUID) async throws -> Bool {
        let lines = request.components(separatedBy: "\r\n")
        let requestParts = lines.first?.split(separator: " ") ?? []
        guard requestParts.count >= 2 else { throw AppleSMBRangeServerError.invalidMedia }
        let method = String(requestParts[0]).uppercased()
        guard method == "GET" || method == "HEAD" else { throw AppleSMBRangeServerError.invalidMedia }
        let path = String(requestParts[1])
        let pieces = path.split(separator: "/")
        guard pieces.count >= 3, pieces[0] == "media" else { throw AppleSMBRangeServerError.invalidMedia }
        let token = String(pieces[1])
        guard var session = sessions[token], session.expiresAt > .now else {
            connectionJobs[id]?.responseStarted = true
            try await send(
                Data("HTTP/1.1 404 Not Found\r\nConnection: close\r\nContent-Length: 0\r\n\r\n".utf8),
                connection: connection,
                final: true
            )
            return false
        }
        connectionJobs[id]?.token = token
        readStats[token, default: AppleSMBReadStats()].requests += 1
        if !session.sizeChecked {
            do {
                session = try await checkSize(of: session, token: token)
            } catch {
                if error is CancellationError || Task.isCancelled { throw error }
                readStats[token]?.openFailure = .notFound
                AppleInteractionTrace.record(.network, "smb bridge \(session.sourceURL.lastPathComponent): not on the share")
                connectionJobs[id]?.responseStarted = true
                try await send(Data("HTTP/1.1 404 Not Found\r\nConnection: close\r\nContent-Length: 0\r\n\r\n".utf8),
                    connection: connection, final: true)
                return false
            }
        }

        let rangeHeader = lines.first { $0.lowercased().hasPrefix("range:") }
        let requestedRange = rangeHeader.flatMap { Self.parseRange($0, size: session.sizeBytes) }
        if rangeHeader != nil, requestedRange == nil {
            connectionJobs[id]?.responseStarted = true
            let response = "HTTP/1.1 416 Range Not Satisfiable\r\n" +
                "Accept-Ranges: bytes\r\n" +
                "Content-Range: bytes */\(session.sizeBytes)\r\n" +
                "Content-Length: 0\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
            try await send(Data(response.utf8), connection: connection, final: true)
            return false
        }
        let keepAlive = Self.keepsAlive(requestLine: lines[0], headers: lines.dropFirst())
        let range = requestedRange ?? 0 ..< session.sizeBytes
        let partial = requestedRange != nil
        let openEnded = rangeHeader.map(Self.isOpenEnded) ?? true
        let contentLength = range.upperBound - range.lowerBound
        let contentType = Self.contentType(for: session.sourceURL.pathExtension)
        var headers = "HTTP/1.1 \(partial ? "206 Partial Content" : "200 OK")\r\n"
        headers += "Accept-Ranges: bytes\r\n"
        headers += "Content-Type: \(contentType)\r\n"
        headers += "Content-Length: \(contentLength)\r\n"
        if partial {
            headers += "Content-Range: bytes \(range.lowerBound)-\(range.upperBound - 1)/\(session.sizeBytes)\r\n"
        }
        headers += "Cache-Control: no-store\r\nConnection: \(keepAlive ? "keep-alive" : "close")\r\n\r\n"
        connectionJobs[id]?.responseStarted = true
        let bodyless = method == "HEAD" || contentLength == 0
        try await send(Data(headers.utf8), connection: connection, final: bodyless && !keepAlive)
        guard !bodyless else { return keepAlive }

        var offset = range.lowerBound
        if usesBlockCache, AppleSMBBlockCache.caches(path: session.sourceURL.path, request: range) {
            let data = try await cachedRead(session: session, token: token, range: range)
            guard !data.isEmpty else { throw AppleSMBRangeServerError.invalidMedia }
            offset = try await sendBody(data, from: offset, of: range, token: token,
                connection: connection, keepAlive: keepAlive)
        } else if !openEnded, range.count <= Self.singleReadLimit {
            let data = try await measuredRead(session: session, token: token, range: range)
            guard !data.isEmpty else { throw AppleSMBRangeServerError.invalidMedia }
            offset = try await sendBody(data, from: offset, of: range, token: token,
                connection: connection, keepAlive: keepAlive)
        } else if openEnded {
            for size in Self.leadingReads where offset < range.upperBound {
                let data = try await measuredRead(session: session, token: token,
                    range: offset ..< min(offset + size, range.upperBound))
                guard !data.isEmpty else { throw AppleSMBRangeServerError.invalidMedia }
                offset = try await sendBody(data, from: offset, of: range, token: token,
                    connection: connection, keepAlive: keepAlive)
            }
        }
        if offset < range.upperBound {
            let started = ContinuousClock.now
            let stream = try await openStream(session: session, token: token, range: offset ..< range.upperBound)
            defer { stream.cancel() }
            // A revoke cancels this task while `next()` may be waiting on the share.
            try await withTaskCancellationHandler {
                var waitingForFirstByte = true
                while offset < range.upperBound {
                    try Task.checkCancellation()
                    guard let data = try await withReadTimeout({ try await stream.next() }), !data.isEmpty else { break }
                    if waitingForFirstByte {
                        waitingForFirstByte = false
                        readStats[token]?.recordStreamFirstByte(milliseconds: Self.milliseconds(since: started))
                    }
                    readStats[token]?.smbBytes += UInt64(data.count)
                    offset = try await sendBody(data, from: offset, of: range, token: token,
                        connection: connection, keepAlive: keepAlive)
                }
            } onCancel: {
                stream.cancel()
            }
        }
        guard offset >= range.upperBound else { throw AppleSMBRangeServerError.invalidMedia }
        return keepAlive
    }

    /// The engine's disc reader asks for bounded ranges of up to 8 MiB; one
    /// `read` is one SMB open and a single SMB read of that size on Samba.
    static let singleReadLimit: UInt64 = 8 * 1_024 * 1_024

    /// The first reads of an open-ended range, before it becomes one streamed open. A stream
    /// reads in the share's largest read size (8 MiB on Samba) and holds the
    /// share connection for each read, so the engine's seek probes, which read
    /// a few kilobytes and hang up, took 7.7 s to place John Wick 4 on a test iPhone
    /// when every request was a stream (2026-10-17). 4 MiB in all, the size
    /// the bridge read per request before.
    static let leadingReads: [UInt64] = [256 * 1_024, 768 * 1_024, 3 * 1_024 * 1_024]

    /// Sends the part of `data` that belongs in `range` from `offset`; returns the offset after it.
    private func sendBody(_ data: Data, from offset: UInt64, of range: Range<UInt64>, token: String,
                          connection: NWConnection, keepAlive: Bool) async throws -> UInt64 {
        let remaining = Int(range.upperBound - offset)
        let bounded = data.count > remaining ? Data(data.prefix(remaining)) : data
        let next = offset + UInt64(bounded.count)
        try await send(bounded, connection: connection, final: !keepAlive && next >= range.upperBound)
        readStats[token]?.bytesServed += UInt64(bounded.count)
        return next
    }

    /// `range` assembled from whole cached blocks (`AppleSMBBlockCache`),
    /// reading the missing ones and keeping them on disk for the next launch.
    private func cachedRead(session: Session, token: String, range: Range<UInt64>) async throws -> Data {
        var data = Data(capacity: Int(range.count))
        for index in AppleSMBBlockCache.blockIndices(for: range) {
            let key = AppleSMBBlockCache.Key(file: session.cacheFile, index: index)
            let block: Data
            if let hit = blockCache.block(for: key) {
                block = hit
                readStats[token]?.cacheHits += 1
            } else {
                block = try await measuredRead(session: session, token: token,
                    range: AppleSMBBlockCache.byteRange(ofBlock: index, fileSize: session.sizeBytes))
                guard !block.isEmpty else { break }
                blockCache.store(block, for: key)
                await discStore(for: session)?.store(block, index: index, file: session.cacheFile)
            }
            let part = AppleSMBBlockCache.slice(block, index: index, of: range)
            guard !part.isEmpty else { break }
            data.append(part)
        }
        return data
    }

    private func measuredRead(session: Session, token: String, range: Range<UInt64>) async throws -> Data {
        let started = ContinuousClock.now
        if addedLatency > .zero { try await Task.sleep(for: addedLatency) }
        let data = try await withReadTimeout { [client] in
            try await client.read(url: session.sourceURL, credentials: session.credentials, range: range)
        }
        readStats[token]?.recordSMBRead(milliseconds: Self.milliseconds(since: started))
        readStats[token]?.smbBytes += UInt64(data.count)
        return data
    }

    private func openStream(session: Session, token: String, range: Range<UInt64>) async throws
        -> any AppleNetworkShareFileStream {
        if addedLatency > .zero { try await Task.sleep(for: addedLatency) }
        // Not raced against `readTimeout`: a stream that opened as the timeout
        // fired would be dropped with its reader still holding the file. The
        // SMB client's own 8 s timeout bounds the open; each read is raced.
        let stream = try await client.openStream(url: session.sourceURL, credentials: session.credentials, range: range)
        readStats[token]?.smbOpens += 1
        return stream
    }

    private func withReadTimeout<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        return try await withThrowingTaskGroup(of: Value.self) { group in
            defer { group.cancelAll() }
            group.addTask(operation: operation)
            group.addTask { [readTimeout] in
                try await Task.sleep(for: readTimeout)
                throw URLError(.timedOut)
            }
            guard let value = try await group.next() else { throw CancellationError() }
            return value
        }
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        Int(start.duration(to: .now) / .milliseconds(1))
    }

    /// The request's header block, or nil when the client closed the
    /// connection between requests. Bytes after the header stay in `pending`.
    private func receiveRequest(_ connection: NWConnection, pending: inout Data) async throws -> String? {
        let terminator = Data("\r\n\r\n".utf8)
        while true {
            if let end = pending.range(of: terminator)?.upperBound {
                let header = pending[pending.startIndex ..< end]
                pending = Data(pending[end...])
                guard let value = String(data: header, encoding: .utf8) else { throw AppleSMBRangeServerError.invalidMedia }
                return value
            }
            guard pending.count < 65_536 else { throw AppleSMBRangeServerError.invalidMedia }
            let chunk = try await receive(connection)
            if chunk.isEmpty {
                guard pending.isEmpty else { throw AppleSMBRangeServerError.invalidMedia }
                return nil
            }
            pending.append(chunk)
        }
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

    /// HTTP/1.1 keeps the connection unless the client says close; HTTP/1.0 never does.
    static func keepsAlive<Headers: Sequence<String>>(requestLine: String, headers: Headers) -> Bool {
        guard requestLine.hasSuffix("HTTP/1.1") else { return false }
        return !headers.contains { line in
            let lower = line.lowercased()
            return lower.hasPrefix("connection:") && lower.contains("close")
        }
    }

    /// `bytes=N-`: the player reads on until it hangs up.
    static func isOpenEnded(_ rangeHeader: String) -> Bool {
        rangeHeader.trimmingCharacters(in: .whitespaces).hasSuffix("-")
    }

    static func parseRange(_ line: String, size: UInt64) -> Range<UInt64>? {
        guard size > 0,
              let value = line.split(separator: ":", maxSplits: 1).last?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              value.lowercased().hasPrefix("bytes=") else { return nil }
        let raw = value.dropFirst(6)
        guard !raw.contains(",") else { return nil }
        let bounds = raw.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard bounds.count == 2 else { return nil }
        if bounds[0].isEmpty, let suffix = UInt64(bounds[1]), suffix > 0 {
            let length = min(suffix, size)
            return (size - length) ..< size
        }
        guard let start = UInt64(bounds[0]), start < size else { return nil }
        let inclusiveEnd = bounds[1].isEmpty ? size - 1 : min(UInt64(bounds[1]) ?? (size - 1), size - 1)
        guard inclusiveEnd >= start else { return nil }
        return start ..< (inclusiveEnd + 1)
    }

    private static func token(of playbackURL: URL) -> String? {
        let pieces = playbackURL.path.split(separator: "/")
        guard pieces.count >= 2, pieces[0] == "media" else { return nil }
        return String(pieces[1])
    }

    private static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        let value = String(describing: host).lowercased()
        return value == "127.0.0.1" || value == "::1" || value == "localhost"
    }

    private static func contentType(for fileExtension: String) -> String {
        switch fileExtension.lowercased() {
        case "mp4", "m4v": "video/mp4"
        case "mov": "video/quicktime"
        case "ts", "m2ts": "video/mp2t"
        case "webm": "video/webm"
        case "mkv": "video/x-matroska"
        default: "application/octet-stream"
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
