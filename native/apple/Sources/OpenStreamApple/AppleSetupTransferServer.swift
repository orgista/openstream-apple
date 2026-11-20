import CryptoKit
import Foundation
import Network

private func traceSetup(_ detail: @autoclosure () -> String) {
    AppleInteractionTrace.record(.network, "setup receive " + detail())
}

/// The receiving end of "Set Up from iPhone": a one-session HTTP listener on
/// the LAN. `GET /setup/<s>` names this device; `POST /setup/<s>` with the
/// one-time code in `X-Setup-Code` delivers the sealed setup once. Only
/// private-network clients, the advertised `Host`, no browser `Origin`, a
/// body of at most 4 MB, five tries, ten minutes.
@MainActor
final class AppleSetupReceiveServer {
    enum StopReason: Equatable { case received, expired, locked, failed(String), stopped }

    nonisolated static let preferredPort: UInt16 = 8_091

    var onReceive: (@MainActor (AppleSetupTransferPayload) -> Void)?
    var onStop: (@MainActor (StopReason) -> Void)?

    private(set) var link: AppleSetupTransferLink?
    private var session: AppleSetupReceiveSession?
    private let deviceName: String
    private let preferredPort: UInt16
    private let lifetime: TimeInterval
    private let hostProvider: @Sendable () -> String?
    private let now: @MainActor () -> Date
    private let networkQueue = DispatchQueue(label: "com.orgista.openstream.setup-receive", qos: .userInitiated)
    private var listener: NWListener?
    private var expiryTask: Task<Void, Never>?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    init(deviceName: String, preferredPort: UInt16 = AppleSetupReceiveServer.preferredPort,
         lifetime: TimeInterval = AppleSetupReceiveSession.lifetime,
         hostProvider: @escaping @Sendable () -> String? = { AppleWebManagementNetwork.localIPv4Address() },
         now: @escaping @MainActor () -> Date = { Date() }) {
        self.deviceName = deviceName
        self.preferredPort = preferredPort
        self.lifetime = lifetime
        self.hostProvider = hostProvider
        self.now = now
    }

    func start() async throws -> AppleSetupTransferLink {
        stop(reason: nil)
        guard let host = hostProvider(), AppleWebManagementProtocol.isAllowedClient(host: host) else {
            traceSetup("no LAN address")
            throw AppleWebManagementServerError.localNetworkUnavailable
        }
        let active = try await startListener()
        guard let port = active.port?.rawValue else {
            active.cancel()
            throw AppleWebManagementServerError.invalidListenerPort
        }
        listener = active
        let fresh = AppleSetupReceiveSession(now: now(), lifetime: lifetime)
        session = fresh
        let made = fresh.link(host: host, port: Int(port))
        link = made
        traceSetup("listening on port \(port)")
        #if DEBUG
        // The end-to-end run reads the QR's content from the trace; never in a shipped build.
        appleTrace("setup receive qr \(made.url.absoluteString)")
        #endif
        active.stateUpdateHandler = { [weak self, weak active] state in
            guard case .failed(let error) = state else { return }
            Task { @MainActor [weak self, weak active] in
                guard let self, let active, self.listener === active else { return }
                self.stop(reason: .failed(error.debugDescription))
            }
        }
        let expiresAt = fresh.expiresAt
        expiryTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self else { return }
                if self.now() >= expiresAt {
                    traceSetup("expired")
                    self.stop(reason: .expired)
                    return
                }
            }
        }
        return made
    }

    func stop() { stop(reason: .stopped) }

    private func stop(reason: StopReason?) {
        let wasActive = listener != nil
        expiryTask?.cancel()
        expiryTask = nil
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        listener = nil
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
        session = nil
        link = nil
        if wasActive, let reason {
            traceSetup("stopped: \(reason)")
            onStop?(reason)
        }
    }

    private func startListener() async throws -> NWListener {
        var lastError: (any Error)?
        let candidates: [UInt16] = preferredPort == 0
            ? [0]
            : (0 ..< 16).compactMap { offset in
                let value = UInt32(preferredPort) + UInt32(offset)
                return value <= UInt32(UInt16.max) ? UInt16(value) : nil
            }
        for port in candidates {
            do { return try await startReadyListener(port: port) } catch {
                lastError = error
            }
        }
        throw AppleWebManagementServerError.listenerFailed(lastError?.localizedDescription ?? "")
    }

    private func startReadyListener(port: UInt16) async throws -> NWListener {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 8
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.includePeerToPeer = false
        let endpointPort = port == 0 ? NWEndpoint.Port.any : NWEndpoint.Port(rawValue: port)!
        let candidate = try NWListener(using: parameters, on: endpointPort)
        candidate.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in
                guard let self else { connection.cancel(); return }
                self.accept(connection)
            }
        }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let gate = AppleWebManagementListenerStartupGate(continuation: continuation)
                candidate.stateUpdateHandler = { state in gate.receive(state) }
                candidate.start(queue: networkQueue)
            }
            return candidate
        } catch {
            candidate.stateUpdateHandler = nil
            candidate.cancel()
            throw error
        }
    }

    private func accept(_ connection: NWConnection) {
        guard listener != nil else { connection.cancel(); return }
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        Task { @MainActor [weak self] in
            await self?.serve(connection, id: id)
            connection.cancel()
            self?.connections.removeValue(forKey: id)
        }
    }

    private func serve(_ connection: NWConnection, id: ObjectIdentifier) async {
        let timeout = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            connection.cancel()
        }
        defer { timeout.cancel() }
        connection.start(queue: networkQueue)
        guard let remote = Self.host(from: connection.endpoint),
              AppleWebManagementProtocol.isAllowedClient(host: remote) else {
            traceSetup("403 client off-LAN")
            await send(.plain(403, "Forbidden", "Local network only."), to: connection)
            return
        }
        let request: AppleWebManagementHTTPRequest
        do {
            request = try await AppleWebManagementHTTPReader.read(
                from: connection, maxBodyBytes: AppleSetupReceiveSession.maximumBodyBytes,
                acceptsBody: { $0.hasPrefix("/setup/") })
        } catch AppleWebManagementHTTPReadError.tooLarge {
            traceSetup("413 too large")
            await send(.plain(413, "Payload Too Large", "Too large."), to: connection)
            return
        } catch {
            traceSetup("400 unreadable request")
            await send(.plain(400, "Bad Request", "Malformed request."), to: connection)
            return
        }
        let (response, payload) = respond(to: request)
        traceSetup("\(request.method) -> \(response.code)")
        if let payload {
            // Single use: close the listener first (this connection stays
            // open for the reply), so nothing else is accepted meanwhile.
            connections.removeValue(forKey: id)
            stop(reason: nil)
            traceSetup("received \(payload.snapshot.sources.count) sources")
            onReceive?(payload)
            onStop?(.received)
        }
        await send(response, to: connection)
        if payload == nil, session?.isLocked == true {
            traceSetup("locked after \(AppleSetupReceiveSession.maximumAttempts) tries")
            stop(reason: .locked)
        }
    }

    private func respond(to request: AppleWebManagementHTTPRequest)
        -> (AppleWebManagementHTTPResponse, AppleSetupTransferPayload?) {
        guard let link, var current = session else { return (.plain(410, "Gone", "Gone."), nil) }
        guard request.path.hasPrefix("/setup/") else { return (.plain(404, "Not Found", "Not found."), nil) }
        let candidate = String(request.path.dropFirst("/setup/".count))
        guard AppleSetupTransferLink.isSessionID(candidate) else { return (.plain(404, "Not Found", "Not found."), nil) }
        // The address the QR code names, and no browser page: a DNS-rebinding
        // page sends its own Host and Origin.
        guard request.headers["host"]?.lowercased() == link.address.lowercased() else {
            traceSetup("host check failed")
            return (.plain(403, "Forbidden", "Host rejected."), nil)
        }
        guard request.headers["origin"] == nil else {
            traceSetup("origin refused")
            return (.plain(403, "Forbidden", "Browsers cannot send a setup."), nil)
        }
        switch request.method {
        case "GET":
            if let rejection = current.check(sessionID: candidate, now: now()) {
                return (.plain(rejection.status.code, rejection.status.text, "Unavailable."), nil)
            }
            let body = (try? JSONEncoder().encode(AppleSetupTransferInfo(v: 1, name: deviceName))) ?? Data("{}".utf8)
            return (.json(200, "OK", String(decoding: body, as: UTF8.self)), nil)
        case "POST":
            let result = current.accept(sessionID: candidate, code: request.headers["x-setup-code"],
                                        body: request.rawBody, now: now())
            session = current
            switch result {
            case .success(let payload):
                return (.json(200, "OK", #"{"v":1,"ok":true}"#), payload)
            case .failure(let rejection):
                traceSetup("refused: \(rejection)")
                return (.plain(rejection.status.code, rejection.status.text, "Refused."), nil)
            }
        default:
            return (.plain(405, "Method Not Allowed", "Use GET or POST.", headers: ["Allow": "GET, POST"]), nil)
        }
    }

    private func send(_ response: AppleWebManagementHTTPResponse, to connection: NWConnection) async {
        let data = response.serialized()
        await withCheckedContinuation { continuation in
            connection.send(content: data, contentContext: .defaultMessage, isComplete: true,
                            completion: .contentProcessed { _ in continuation.resume() })
        }
    }

    private static func host(from endpoint: NWEndpoint) -> String? {
        guard case .hostPort(let host, _) = endpoint else { return nil }
        switch host {
        case .name(let name, _): return name
        case .ipv4(let address): return address.debugDescription
        case .ipv6(let address): return address.debugDescription
        @unknown default: return nil
        }
    }
}

/// The sending end: asks the receiver its name, then POSTs the sealed setup.
struct AppleSetupTransferSender: Sendable {
    /// A new session per request: the receiver answers `Connection: close`,
    /// and a POST sent on the GET's pooled connection was lost (e2e 2026-10-08).
    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.httpShouldUsePipelining = false
        return URLSession(configuration: configuration)
    }

    func receiverName(for link: AppleSetupTransferLink) async throws -> String {
        let (data, response) = try await load(URLRequest(url: link.endpoint))
        try Self.check(response)
        guard let info = try? JSONDecoder().decode(AppleSetupTransferInfo.self, from: data),
              info.v == 1 else { throw AppleSetupTransferError.unreadable }
        let name = info.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((name.isEmpty ? "the other device" : name).prefix(60))
    }

    func send(_ payload: AppleSetupTransferPayload, to link: AppleSetupTransferLink) async throws {
        let body = try AppleSetupTransferCrypto.sealPayload(payload, for: link)
        var request = URLRequest(url: link.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(link.code, forHTTPHeaderField: "X-Setup-Code")
        request.httpBody = body
        let (_, response) = try await load(request)
        try Self.check(response)
    }

    private func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let session = Self.makeSession()
        defer { session.finishTasksAndInvalidate() }
        var request = request
        request.setValue("close", forHTTPHeaderField: "Connection")
        do { return try await session.data(for: request) } catch {
            let code = (error as NSError).code
            appleTraceFailure("setup send: \(request.httpMethod ?? "GET") failed (\((error as NSError).domain) \(code))")
            throw AppleSetupTransferError.unreachable
        }
    }

    private static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw AppleSetupTransferError.unreachable }
        guard http.statusCode == 200 else { throw AppleSetupTransferError.rejected(http.statusCode) }
    }
}

private extension AppleWebManagementHTTPResponse {
    static func json(_ code: Int, _ status: String, _ body: String) -> Self {
        Self(code: code, status: status, body: body, contentType: "application/json; charset=utf-8", headers: [:])
    }
}
