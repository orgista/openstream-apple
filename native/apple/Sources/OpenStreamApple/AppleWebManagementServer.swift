import Darwin
import Foundation
import Network
import Synchronization

public enum AppleWebManagementServerError: Error, Equatable, LocalizedError, Sendable {
    case localNetworkUnavailable
    case invalidConfiguration
    case listenerFailed(String)
    case invalidListenerPort
    case invalidSessionURL
    case sourceValidationTimedOut

    public var errorDescription: String? {
        switch self {
        case .localNetworkUnavailable:
            "Connect this device to a local network first."
        case .invalidConfiguration:
            "The Web Management session configuration is invalid."
        case .listenerFailed(let detail):
            detail.isEmpty ? "Web Management could not start." : "Web Management could not start: \(detail)"
        case .invalidListenerPort:
            "Web Management could not reserve a local port."
        case .invalidSessionURL:
            "Web Management could not create its local URL."
        case .sourceValidationTimedOut:
            "The add-on took too long to respond."
        }
    }
}

public enum AppleWebManagementServerStopReason: Equatable, Sendable {
    case stopped
    case expired
    case completed
    case failed(String)
}

/// Every decision the portal makes about a request, on one line.
///
/// Web Management has three ways to look identical while failing — the
/// listener never binds, the browser never reaches it, or it reaches it and
/// is turned away by the `Host`/origin/pairing checks — and none of them
/// leave a mark on the TV. This names which one happened.
private func traceWeb(_ detail: @autoclosure () -> String) {
    AppleInteractionTrace.record(.network, "web " + detail())
}

@MainActor
public final class AppleWebManagementServer {
    public nonisolated static let defaultPort: UInt16 = 8_090
    public nonisolated static let defaultSessionDuration: TimeInterval = 10 * 60
    public nonisolated static let browserInactivityDuration: TimeInterval = 30 * 60
    public nonisolated static let bonjourServiceType = "_openstream._tcp"

    public struct Configuration: Sendable {
        public let preferredPort: UInt16
        public let sessionDuration: TimeInterval
        public let advertisesBonjour: Bool
        fileprivate let hostProvider: @Sendable () -> String?

    public init(
            preferredPort: UInt16 = AppleWebManagementServer.defaultPort,
            sessionDuration: TimeInterval = AppleWebManagementServer.defaultSessionDuration,
            advertisesBonjour: Bool = true
        ) {
            self.preferredPort = preferredPort
            self.sessionDuration = sessionDuration
            self.advertisesBonjour = advertisesBonjour
            hostProvider = { AppleWebManagementNetwork.localIPv4Address() }
        }


        init(
            preferredPort: UInt16,
            sessionDuration: TimeInterval,
            advertisesBonjour: Bool,
            advertisedHost: String
        ) {
            self.preferredPort = preferredPort
            self.sessionDuration = sessionDuration
            self.advertisesBonjour = advertisesBonjour
            hostProvider = { advertisedHost }
        }
    }

    public struct ConnectedBrowser: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let name: String
        public fileprivate(set) var lastActivity: Date
    }

    private struct BrowserSession {
        let token: String
        var browser: ConnectedBrowser
    }

    public var connectedBrowsers: [ConnectedBrowser] {
        browsers.values.map(\.browser).filter {
            now().timeIntervalSince($0.lastActivity) < Self.browserInactivityDuration
        }.sorted { $0.lastActivity > $1.lastActivity }
    }
    public var onSessionChange: (@MainActor @Sendable (AppleWebManagementSession?) -> Void)?
    public var onBrowsersChange: (@MainActor @Sendable ([ConnectedBrowser]) -> Void)?
    private var browsers: [UUID: BrowserSession] = [:]
    private var pairingAttempts: [String: (start: Date, count: Int)] = [:]
    private let now: @MainActor () -> Date

    public private(set) var session: AppleWebManagementSession?
    public var onStop: (@MainActor @Sendable (AppleWebManagementServerStopReason) -> Void)?

    private let configuration: Configuration
    #if OPENSTREAM_ADDONS
    private let manifestClient: AppleManifestClient
    #endif
    private let iptvClient: AppleIPTVClient
    private let networkQueue = DispatchQueue(label: "com.orgista.openstream.web-management", qos: .userInitiated)

    private var listener: NWListener?
    private var bonjourService: NetService?
    private var bonjourMonitor: AppleBonjourPublishMonitor?
    private var sourceStore: AppleSourceStore?
    private var expiryTask: Task<Void, Never>?
    private var connectionTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var generation = UUID()
    private var isCompleting = false

    #if OPENSTREAM_ADDONS
    public init(
        configuration: Configuration = Configuration(),
        manifestClient: AppleManifestClient = AppleManifestClient(),
        iptvClient: AppleIPTVClient = AppleIPTVClient(),
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.now = now
        self.configuration = configuration
        self.manifestClient = manifestClient
        self.iptvClient = iptvClient
    }
    #else
    public init(
        configuration: Configuration = Configuration(),
        iptvClient: AppleIPTVClient = AppleIPTVClient(),
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.now = now
        self.configuration = configuration
        self.iptvClient = iptvClient
    }
    #endif

    @discardableResult
    public func start(sourceStore: AppleSourceStore) async throws -> AppleWebManagementSession {
        tearDown(reason: nil)

        guard configuration.sessionDuration > 0,
              configuration.sessionDuration <= 24 * 60 * 60,
              configuration.sessionDuration.isFinite else {
            throw AppleWebManagementServerError.invalidConfiguration
        }
        guard let host = configuration.hostProvider(), AppleWebManagementProtocol.isAllowedClient(host: host) else {
            traceWeb("start rejected: no usable LAN address (\(configuration.hostProvider() ?? "none"))")
            throw AppleWebManagementServerError.localNetworkUnavailable
        }
        traceWeb("start on \(host), preferred port \(configuration.preferredPort)")

        self.sourceStore = sourceStore
        generation = UUID()

        let activeListener: NWListener
        do {
            activeListener = try await startListenerWithFallback(from: configuration.preferredPort)
        } catch {
            self.sourceStore = nil
            traceWeb("listener failed: \(error.localizedDescription)")
            throw AppleWebManagementServerError.listenerFailed(error.localizedDescription)
        }

        guard let port = activeListener.port?.rawValue else {
            activeListener.cancel()
            self.sourceStore = nil
            throw AppleWebManagementServerError.invalidListenerPort
        }

        let token = AppleWebManagementProtocol.makeToken()
        let expiresAt = now().addingTimeInterval(configuration.sessionDuration)
        guard let friendlyURL = Self.makeURL(host: host, port: port, path: "/") else {
            activeListener.cancel()
            self.sourceStore = nil
            throw AppleWebManagementServerError.invalidSessionURL
        }

        let activeSession = AppleWebManagementSession(
            url: friendlyURL,
            friendlyURL: friendlyURL,
            expiresAt: expiresAt,
            token: token,
            pairingCode: AppleWebManagementProtocol.makePairingCode()
        )
        listener = activeListener
        session = activeSession
        traceWeb("listening on \(friendlyURL.absoluteString)")
        publishBonjourIfRequested(port: port)
        installRuntimeStateHandler(for: activeListener)
        scheduleExpiry()
        return activeSession
    }

    public func stop() {
        tearDown(reason: .stopped)
    }

    public func dispose() {
        stop()
    }

    private func startReadyListener(port: UInt16) async throws -> NWListener {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 8
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.includePeerToPeer = false

        let endpointPort = port == 0 ? NWEndpoint.Port.any : NWEndpoint.Port(rawValue: port)!
        let candidate = try NWListener(using: parameters, on: endpointPort)
        // No newConnectionLimit: each request is a short-lived, serially
        // handled connection (the server always replies "Connection: close"),
        // so a session with more than a handful of page loads or pairing
        // attempts would otherwise stop accepting connections once the
        // in-flight/just-finished count crossed a fixed cap — Network
        // framework does not reliably release a slot back the instant a
        // connection is cancelled. Per-connection risk is already bounded by
        // isAllowedClient (LAN only) and the 8 s connection timeout below.
        candidate.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in
                self?.accept(connection)
            }
        }
        listener = candidate
        do {
            try await waitUntilReady(candidate)
            return candidate
        } catch {
            if listener === candidate { listener = nil }
            candidate.stateUpdateHandler = nil
            candidate.cancel()
            throw error
        }
    }

    private func startListenerWithFallback(from preferredPort: UInt16) async throws -> NWListener {
        if preferredPort == 0 {
            return try await startReadyListener(port: 0)
        }
        var lastError: (any Error)?
        for offset in 0 ..< 64 {
            let candidate = UInt32(preferredPort) + UInt32(offset)
            guard candidate <= UInt32(UInt16.max) else { break }
            do {
                return try await startReadyListener(port: UInt16(candidate))
            } catch {
                traceWeb("port \(candidate) unavailable: \(error.localizedDescription)")
                lastError = error
            }
        }
        throw lastError ?? AppleWebManagementServerError.invalidListenerPort
    }

    private func waitUntilReady(_ candidate: NWListener) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let gate = AppleWebManagementListenerStartupGate(continuation: continuation)
                candidate.stateUpdateHandler = { state in
                    gate.receive(state)
                }
                candidate.start(queue: networkQueue)
            }
        } onCancel: {
            candidate.cancel()
        }
    }

    private func installRuntimeStateHandler(for activeListener: NWListener) {
        activeListener.stateUpdateHandler = { [weak self, weak activeListener] state in
            guard case .failed(let error) = state else { return }
            Task { @MainActor [weak self, weak activeListener] in
                guard let self, let activeListener, self.listener === activeListener else { return }
                self.tearDown(reason: .failed(error.debugDescription))
            }
        }
    }

    // The listener remains available until the viewer stops it. Only pairing
    // codes rotate; authenticated browsers have an independent sliding lease.
    private func scheduleExpiry() {
        expiryTask?.cancel()
        expiryTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self else { return }
                self.refreshLifetimes()
            }
        }
    }

    func refreshLifetimes() {
        if let session, session.expiresAt <= now() { rotatePairingCode() }
        let previousCount = browsers.count
        browsers = browsers.filter {
            now().timeIntervalSince($0.value.browser.lastActivity) < Self.browserInactivityDuration
        }
        if browsers.count != previousCount { onBrowsersChange?(connectedBrowsers) }
    }

    private func rotatePairingCode() {
        guard let current = session else { return }
        session = AppleWebManagementSession(
            url: current.url, friendlyURL: current.friendlyURL,
            expiresAt: now().addingTimeInterval(configuration.sessionDuration),
            token: current.token, pairingCode: AppleWebManagementProtocol.makePairingCode()
        )
        onSessionChange?(session)
    }

    public func endBrowser(id: UUID) {
        browsers.removeValue(forKey: id)
        onBrowsersChange?(connectedBrowsers)
    }

    public func endAllBrowsers() {
        browsers.removeAll()
        onBrowsersChange?([])
    }

    private func authenticatedBrowser(headers: [String: String]) -> String? {
        guard let token = AppleWebManagementProtocol.cookieValue("openstream_token", in: headers["cookie"]),
              let id = browsers.first(where: {
                  AppleWebManagementProtocol.secretsMatch($0.value.token, token)
              })?.key else { return nil }
        browsers[id]?.browser.lastActivity = now()
        onBrowsersChange?(connectedBrowsers)
        return token
    }

    private func pair(code: String?, headers: [String: String], remoteHost: String) -> String? {
        let stamp = now()
        pairingAttempts = pairingAttempts.filter {
            let age = stamp.timeIntervalSince($0.value.start)
            return age >= 0 && age < 60
        }
        guard let code, !code.isEmpty,
              pairingAttempts[remoteHost] != nil || pairingAttempts.count < 256 else { return nil }
        var attempts = pairingAttempts[remoteHost] ?? (start: stamp, count: 0)
        guard attempts.count < 10 else { return nil }
        attempts.count += 1
        pairingAttempts[remoteHost] = attempts
        guard let current = session, current.expiresAt > now(),
              AppleWebManagementProtocol.hasValidPairingCode(
                  form: ["pairingCode": code ?? ""], session: current
              ) else { return nil }
        pairingAttempts[remoteHost] = nil
        let agent = headers["user-agent"] ?? ""
        let name = agent.contains("Edg/") ? "Edge" : agent.contains("Firefox/") ? "Firefox"
            : agent.contains("Chrome/") ? "Chrome" : agent.contains("Safari/") ? "Safari" : "Browser"
        let browser = ConnectedBrowser(id: UUID(), name: name, lastActivity: now())
        let token = AppleWebManagementProtocol.makeToken()
        browsers[browser.id] = BrowserSession(token: token, browser: browser)
        rotatePairingCode()
        onBrowsersChange?(connectedBrowsers)
        return token
    }

    /// Bonjour is deliberately independent of listener readiness. Numeric
    /// LAN access and the QR code remain usable when service registration is
    /// denied or unavailable on the current network.
    private func publishBonjourIfRequested(port: UInt16) {
        bonjourService?.stop()
        bonjourService = nil
        bonjourMonitor = nil
        guard configuration.advertisesBonjour else { return }

        let service = NetService(
            domain: "local.",
            type: Self.bonjourServiceType + ".",
            name: "oStream",
            port: Int32(port)
        )
        service.includesPeerToPeer = false
        // Without a delegate a refused registration is completely silent, so
        // "the TV shows an address and the browser finds nothing" looked the
        // same as a working session.
        let monitor = AppleBonjourPublishMonitor()
        bonjourMonitor = monitor
        service.delegate = monitor
        bonjourService = service
        service.publish()
    }

    private func accept(_ connection: NWConnection) {
        guard listener != nil, session != nil else {
            connection.cancel()
            return
        }

        let id = ObjectIdentifier(connection)
        let acceptedGeneration = generation
        connections[id] = connection
        let task = Task { @MainActor [weak self] in
            guard let self else {
                connection.cancel()
                return
            }
            await self.serve(connection, id: id, generation: acceptedGeneration)
        }
        connectionTasks[id] = task
    }

    private func serve(_ connection: NWConnection, id: ObjectIdentifier, generation acceptedGeneration: UUID) async {
        let timeout = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 8_000_000_000)
            } catch {
                return
            }
            if !Task.isCancelled { connection.cancel() }
        }
        defer {
            timeout.cancel()
            connection.cancel()
            connections.removeValue(forKey: id)
            connectionTasks.removeValue(forKey: id)
        }

        connection.start(queue: networkQueue)

        guard let remoteHost = Self.host(from: connection.endpoint),
              AppleWebManagementProtocol.isAllowedClient(host: remoteHost) else {
            timeout.cancel()
            traceWeb("403 client off-LAN: \(Self.host(from: connection.endpoint) ?? "unknown")")
            await send(.plain(403, "Forbidden", "This page is available only on the local network."), to: connection)
            return
        }

        do {
            let request = try await AppleWebManagementHTTPReader.read(from: connection)
            timeout.cancel()
            traceWeb("\(request.method) portal request from \(remoteHost)")
            guard generation == acceptedGeneration, let activeSession = session else {
                traceWeb("dropped: session ended before the reply")
                return
            }
            let result = await response(for: request, session: activeSession, remoteHost: remoteHost)
            traceWeb("-> \(result.response.code) \(result.response.status)")
            await send(result.response, to: connection)
            if result.stopAfterSending, generation == acceptedGeneration {
                // Do not let teardown cancel the task and socket that are still
                // flushing the success response to the browser.
                connections.removeValue(forKey: id)
                connectionTasks.removeValue(forKey: id)
                tearDown(reason: .completed)
            }
        } catch AppleWebManagementHTTPReadError.tooLarge {
            timeout.cancel()
            traceWeb("413 request too large")
            await send(.plain(413, "Payload Too Large", "The request is too large."), to: connection)
        } catch AppleWebManagementHTTPReadError.malformed {
            timeout.cancel()
            traceWeb("400 malformed request")
            await send(.plain(400, "Bad Request", "Malformed request."), to: connection)
        } catch {
            // A closed or timed-out local connection needs no response.
            traceWeb("connection closed without a request: \(error.localizedDescription)")
        }
    }

    private func response(
        for request: AppleWebManagementHTTPRequest,
        session activeSession: AppleWebManagementSession,
        remoteHost: String
    ) async -> (response: AppleWebManagementHTTPResponse, stopAfterSending: Bool) {
        guard request.path == "/" || request.path == "/openstream" || request.path == "/diagnostics"
                || request.path == AppleWorkingM3UExportRoute.path else {
            return (.plain(404, "Not Found", "Not found."), false)
        }
        refreshLifetimes()
        guard AppleWebManagementProtocol.isValidHost(request.headers["host"], session: activeSession) else {
            // The browser typed a different address than the one the app is
            // advertising — a second interface, a hostname, a stale bookmark.
            traceWeb("host check failed: sent \(request.headers["host"] ?? "none"), expected \(activeSession.friendlyURL.host ?? "?"):\(activeSession.friendlyURL.port.map(String.init) ?? "?")")
            return (.plain(403, "Forbidden", "Host rejected."), false)
        }
        guard AppleWebManagementProtocol.isTrustedRequestSource(
            origin: request.headers["origin"],
            referer: request.headers["referer"],
            session: activeSession
        ) else {
            traceWeb("origin check failed")
            return (.plain(403, "Forbidden", "The browser source is not the Web Management page."), false)
        }

        let browserToken = authenticatedBrowser(headers: request.headers)

        // The trace log, readable from a machine on the same network.
        //
        // A shipped build records a timeline, but on a real Apple TV or phone
        // that file is inside the app container and unreachable — which would
        // make the logs the owner asked for unreadable in practice. Serving it
        // here reuses the portal's own LAN listener and its authentication
        // rather than adding a service or a phone-home. It sits behind the
        // session token like any state-changing request, so nothing on the
        // network can read it without the portal already being paired.
        if request.path == "/diagnostics" {
            guard browserToken != nil else {
                traceWeb("diagnostics refused: not paired")
                return (.plain(401, "Session Ended", "Session ended — scan the code again"), false)
            }
            // Same redaction as Share Diagnostics: the page is cleartext HTTP on the LAN.
            let log = AppleDiagnosticsReport.redact(
                (try? String(contentsOf: AppleInteractionTrace.fileURL ?? URL(fileURLWithPath: "/dev/null"), encoding: .utf8)) ?? "")
            traceWeb("diagnostics served (\(log.utf8.count) bytes)")
            return (.plain(200, "OK", log.isEmpty ? "No trace recorded yet." : log, cookies: browserToken.map(pairingCookies) ?? []), false)
        }

        // Apple TV's Export Working M3U: no share sheet there, so the file is
        // downloaded from the portal. It carries the playlist's own stream
        // addresses, so it sits behind pairing like everything else; the
        // address Settings shows includes the pairing code, so one visit on
        // a computer both pairs and downloads.
        if request.path == AppleWorkingM3UExportRoute.path {
            guard request.method == "GET" else {
                return (.plain(405, "Method Not Allowed", "Use GET.", headers: ["Allow": "GET"]), false)
            }
            guard let token = browserToken ?? pair(code: request.query["pair"], headers: request.headers, remoteHost: remoteHost) else {
                traceWeb("working m3u refused: not paired")
                return (.plain(401, "Session Ended", "Session ended — scan the code again"), false)
            }
            guard let choice = request.query["credentials"], ["omit", "include"].contains(choice) else {
                return (.html(200, "OK", """
                    <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
                    <title>Export Playlist</title></head><body><h1>Export Playlist</h1>
                    <p><a href="?credentials=omit">Download Redacted Playlist</a></p>
                    <p><a href="?credentials=include">Download Playlist With Provider Credentials</a></p>
                    </body></html>
                    """, cookies: pairingCookies(token)), false)
            }
            let playlist = AppleChannelHealthStore.shared.workingM3U(includesCredentials: choice == "include")
            traceWeb("working m3u served (\(playlist.utf8.count) bytes)")
            return (.plain(200, "OK", playlist,
                headers: ["Content-Disposition": "attachment; filename=\"\(AppleWorkingM3UExportRoute.fileName)\""],
                cookies: pairingCookies(token)), false)
        }


        switch request.method {
        case "GET":
            if let code = request.query["pair"] {
                guard let token = pair(code: code, headers: request.headers, remoteHost: remoteHost) else {
                    return (.html(403, "Pairing Required", page(session: activeSession, paired: false,
                        error: "The pairing code is missing or incorrect.")), false)
                }
                return (.html(200, "OK", page(session: activeSession, paired: true),
                              cookies: pairingCookies(token)), false)
            }
            let ended = browserToken == nil && request.headers["cookie"] != nil
            return (.html(200, "OK", page(session: activeSession, paired: browserToken != nil,
                error: ended ? "Session ended — scan the code again" : nil),
                cookies: browserToken.map(pairingCookies) ?? []), false)

        case "POST":
            guard !isCompleting else {
                return (.plain(403, "Forbidden", "This session is already adding a source."), false)
            }
            // Browsers post the form urlencoded by default; some in-app
            // browsers and forms that declare it post multipart. Both carry
            // the same field names.
            let form = AppleWebManagementProtocol.parseForm(
                body: request.rawBody,
                contentType: request.headers["content-type"]
            )
            if form["action"] == "pair" {
                guard let token = pair(code: form["pairingCode"] ?? request.query["pair"], headers: request.headers, remoteHost: remoteHost) else {
                    return (.html(403, "Pairing Required", page(session: activeSession, paired: false,
                        error: "The pairing code is missing or incorrect.")), false)
                }
                return (.html(200, "OK", page(session: activeSession, paired: true),
                              cookies: pairingCookies(token)), false)
            }
            guard let browserToken else {
                return (.html(401, "Session Ended", page(session: activeSession, paired: false,
                    manifest: form["manifest"] ?? "", error: "Session ended — scan the code again",
                    sourceType: Self.sourceType(from: form), draft: Self.draft(from: form))), false)
            }
            let cookie = pairingCookies(browserToken)

            switch form["action"] {
            case "remove":
                guard let sourceStore,
                      let id = form["sourceID"].flatMap({ UUID(uuidString: $0) }),
                      let existing = sourceStore.sources.first(where: { $0.id == id }),
                      sourceStore.remove(id: id) else {
                    return (.html(
                        400,
                        "Source Not Removed",
                        page(
                            session: activeSession,
                            paired: true,
                            error: "That source is no longer in the list."
                        ),
                        cookies: cookie
                    ), false)
                }
                return (.html(
                    200,
                    "OK",
                    page(session: activeSession, paired: true, notice: "Removed \(existing.name)"),
                    cookies: cookie
                ), false)
            default:
                break
            }

            let manifest = form["manifest"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let sourceType = Self.sourceType(from: form)
            let draft = Self.draft(from: form)
            isCompleting = true
            defer { isCompleting = false }
            do {
                guard let sourceStore else {
                    return (.plain(400, "Bad Request", "The session is no longer active."), false)
                }
                let source: AppleSource
                switch sourceType {
                case "m3u":
                    source = try await addM3U(form: form, sourceStore: sourceStore)
                case "xtream":
                    source = try await addXtream(form: form, sourceStore: sourceStore)
                default:
                    #if OPENSTREAM_ADDONS
                    source = try await addSource(manifestValue: manifest, sourceStore: sourceStore)
                    #else
                    return (.plain(400, "Bad Request", "Unsupported source type."), false)
                    #endif
                }
                traceWeb("added \(sourceType) source \"\(source.name)\"")
                guard !Task.isCancelled, self.session?.token == activeSession.token else {
                    return (.plain(400, "Bad Request", "The session is no longer active."), false)
                }
                return (
                    .html(
                        200,
                        "OK",
                        page(session: activeSession, paired: true, notice: "Added \(source.name)"),
                        cookies: cookie
                    ),
                    false
                )
            } catch {
                // A failed add names its reason and leaves the pairing intact:
                // the page stays paired, the cookie is refreshed, and the
                // typed values (never the password) come back for a retry.
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                traceWeb("add \(sourceType) failed")
                return (
                    .html(
                        400,
                        "Source Not Added",
                        page(
                            session: activeSession,
                            paired: true,
                            manifest: manifest,
                            error: message,
                            sourceType: sourceType,
                            draft: draft
                        ),
                        cookies: cookie
                    ),
                    false
                )
            }

        default:
            return (
                .plain(405, "Method Not Allowed", "Use GET or POST.", headers: ["Allow": "GET, POST"]),
                false
            )
        }
    }

    /// Renders the portal with the values every response needs: the address the
    /// browser is on, the saved sources, and whether the pairing step is done.
    private func page(
        session activeSession: AppleWebManagementSession,
        paired: Bool,
        manifest: String = "",
        notice: String? = nil,
        error: String? = nil,
        sourceType: String = AppleWebManagementPage.defaultSourceType,
        draft: [String: String] = [:]
    ) -> String {
        AppleWebManagementPage.setup(
            manifest: manifest,
            error: error,
            pairingCode: paired ? nil : activeSession.pairingCode,
            notice: notice,
            sources: sourceStore?.sources ?? [],
            address: Self.displayAddress(for: activeSession),
            sourceType: sourceType,
            draft: draft
        )
    }

    /// The address the page shows is the bare `IP:PORT` the browser typed or
    /// scanned; no scheme, path, or token.
    private static func displayAddress(for session: AppleWebManagementSession) -> String? {
        guard let host = session.friendlyURL.host else { return nil }
        guard let port = session.friendlyURL.port else { return host }
        return "\(host):\(port)"
    }

    /// `addon` is the default so older posts that carry only `manifest` still
    /// add an add-on.
    private static func sourceType(from form: [String: String]) -> String {
        switch form["sourceType"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "m3u": "m3u"
        case "xtream": "xtream"
        #if OPENSTREAM_ADDONS
        default: "addon"
        #else
        default: "unsupported"
        #endif
        }
    }

    private static let draftFields = ["m3uName", "playlistURL", "epgURL", "xtreamName", "serverURL", "username"]

    private static func draft(from form: [String: String]) -> [String: String] {
        draftFields.reduce(into: [:]) { result, field in
            if let value = form[field] { result[field] = value }
        }
    }

#if OPENSTREAM_ADDONS
    private func addSource(
        manifestValue: String,
        sourceStore: AppleSourceStore
    ) async throws -> AppleSource {
        let client = manifestClient
        return try await withThrowingTaskGroup(of: AppleSource.self) { group in
            group.addTask {
                try await sourceStore.addStremio(manifestValue: manifestValue, client: client)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(20))
                throw AppleWebManagementServerError.sourceValidationTimedOut
            }
            guard let result = try await group.next() else {
                throw AppleWebManagementServerError.sourceValidationTimedOut
            }
            group.cancelAll()
            return result
        }
    }
#endif

    private func pairingCookies(_ token: String) -> [String] {
        ["openstream_token=\(token); Max-Age=\(Int(Self.browserInactivityDuration)); SameSite=Strict; HttpOnly; Path=/"]
    }

    private func addM3U(
        form: [String: String],
        sourceStore: AppleSourceStore
    ) async throws -> AppleSource {
        let endpoint = form["playlistURL"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalized = try AppleIPTVEndpointPolicy.normalize(endpoint)
        let draft = AppleSource(
            kind: .liveTV,
            name: form["m3uName"] ?? "",
            url: normalized,
            iptvType: .m3u
        )
        let channels = try await iptvClient.channels(source: draft)
        return try sourceStore.addIPTV(
            name: form["m3uName"] ?? "",
            type: .m3u,
            endpoint: endpoint,
            epgURL: form["epgURL"],
            lastValidatedAt: .now,
            validationSummary: "Connected · \(channels.count) channels",
            discoveredItemCount: channels.count,
            capabilities: ["Live channels", "Playback"]
        )
    }

    private func addXtream(
        form: [String: String],
        sourceStore: AppleSourceStore
    ) async throws -> AppleSource {
        let endpoint = form["serverURL"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let username = form["username"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let password = form["password"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        try AppleIPTVEndpointPolicy.validateCredentials(username: username, password: password)
        let draft = AppleSource(
            kind: .liveTV,
            name: form["xtreamName"] ?? "",
            url: try AppleIPTVEndpointPolicy.normalize(endpoint),
            iptvType: .xtream
        )
        let credentials = AppleIPTVCredentials(username: username, password: password)
        let channels = try await iptvClient.channels(source: draft, credentials: credentials)
        return try sourceStore.addIPTV(
            name: form["xtreamName"] ?? "",
            type: .xtream,
            endpoint: endpoint,
            username: username,
            password: password,
            lastValidatedAt: .now,
            validationSummary: "Connected · \(channels.count) channels",
            discoveredItemCount: channels.count,
            capabilities: ["Live channels", "Playback"]
        )
    }

    private func send(_ response: AppleWebManagementHTTPResponse, to connection: NWConnection) async {
        let data = response.serialized()
        await withCheckedContinuation { continuation in
            connection.send(
                content: data,
                contentContext: .defaultMessage,
                isComplete: true,
                completion: .contentProcessed { _ in continuation.resume() }
            )
        }
    }

    private func tearDown(reason: AppleWebManagementServerStopReason?) {
        let wasActive = listener != nil || session != nil
        generation = UUID()
        isCompleting = false

        expiryTask?.cancel()
        expiryTask = nil

        let activeListener = listener
        listener = nil
        activeListener?.stateUpdateHandler = nil
        activeListener?.cancel()

        bonjourService?.stop()
        bonjourService = nil
        bonjourMonitor = nil

        let tasks = Array(connectionTasks.values)
        connectionTasks.removeAll()
        tasks.forEach { $0.cancel() }

        let activeConnections = Array(connections.values)
        connections.removeAll()
        activeConnections.forEach { $0.cancel() }

        sourceStore = nil
        session = nil
        endAllBrowsers()
        onSessionChange?(nil)
        if wasActive, let reason {
            traceWeb("stopped: \(reason)")
            onStop?(reason)
        }
    }

    private static func makeURL(host: String, port: UInt16, path: String) -> URL? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = Int(port)
        components.path = path
        return components.url
    }

    private static func host(from endpoint: NWEndpoint) -> String? {
        guard case .hostPort(let host, _) = endpoint else { return nil }
        switch host {
        case .name(let name, _):
            return name
        case .ipv4(let address):
            return address.debugDescription
        case .ipv6(let address):
            return address.debugDescription
        @unknown default:
            return nil
        }
    }
}

/// Reports whether the `_openstream._tcp` advertisement was accepted.
///
/// Bonjour is optional — the numeric address and the QR code work without it —
/// but a refusal is the clearest sign that local network access was denied,
/// which is otherwise invisible from the TV.
private final class AppleBonjourPublishMonitor: NSObject, NetServiceDelegate {
    func netServiceDidPublish(_ sender: NetService) {
        traceWeb("bonjour published \(sender.type) on port \(sender.port)")
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        let code = errorDict[NetService.errorCode]?.intValue ?? 0
        let domain = errorDict[NetService.errorDomain]?.intValue ?? 0
        traceWeb("bonjour NOT published (code \(code), domain \(domain)) — discovery is off; the numeric address still works")
    }
}

final class AppleWebManagementListenerStartupGate: Sendable {
    private let continuation: Mutex<CheckedContinuation<Void, any Error>?>

    init(continuation: CheckedContinuation<Void, any Error>) {
        self.continuation = Mutex(continuation)
    }

    func receive(_ state: NWListener.State) {
        let result: Result<Void, any Error>?
        switch state {
        case .ready:
            result = .success(())
        case .failed(let error):
            result = .failure(error)
        case .cancelled:
            result = .failure(CancellationError())
        case .setup, .waiting:
            result = nil
        @unknown default:
            result = .failure(AppleWebManagementServerError.listenerFailed("Unknown listener state."))
        }
        guard let result else { return }

        let continuation = continuation.withLock { stored in
            defer { stored = nil }
            return stored
        }
        continuation?.resume(with: result)
    }
}

enum AppleWebManagementNetwork {
    private struct Candidate {
        let address: String
        let interface: String
    }

    static func localIPv4Address() -> String? {
        var firstAddress: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&firstAddress) == 0, let firstAddress else { return nil }
        defer { freeifaddrs(firstAddress) }

        var candidates: [Candidate] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = firstAddress
        while let interface = cursor?.pointee {
            defer { cursor = interface.ifa_next }
            guard let socketAddress = interface.ifa_addr,
                  socketAddress.pointee.sa_family == UInt8(AF_INET) else { continue }

            let flags = Int32(interface.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let status = getnameinfo(
                socketAddress,
                socklen_t(socketAddress.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard status == 0 else { continue }
            let address = host.withUnsafeBufferPointer { buffer in
                String(
                    decodingCString: UnsafeRawPointer(buffer.baseAddress!).assumingMemoryBound(to: UInt8.self),
                    as: UTF8.self
                )
            }
            guard AppleWebManagementProtocol.isAllowedClient(host: address), !address.hasPrefix("127.") else {
                continue
            }
            let interfaceName = String(
                decodingCString: UnsafeRawPointer(interface.ifa_name).assumingMemoryBound(to: UInt8.self),
                as: UTF8.self
            )
            // `en0` is Wi-Fi on Apple mobile/TV platforms; other `en*`
            // interfaces cover wired Ethernet. Carrier, VPN, bridge, and
            // peer-to-peer addresses are not usable setup destinations.
            guard interfaceName.hasPrefix("en") else { continue }
            candidates.append(Candidate(address: address, interface: interfaceName))
        }

        return candidates.sorted { rank($0) < rank($1) }.first?.address
    }

    private static func rank(_ candidate: Candidate) -> Int {
        let interfaceRank: Int
        if candidate.interface == "en0" { interfaceRank = 0 }
        else { interfaceRank = 1 }
        let addressRank = candidate.address.hasPrefix("169.254.") ? 10 : 0
        return interfaceRank + addressRank
    }
}

enum AppleWebManagementHTTPReadError: Error {
    case malformed
    case tooLarge
}

struct AppleWebManagementHTTPRequest: Sendable {
    let method: String
    let target: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let body: String
    let rawBody: Data
}

enum AppleWebManagementHTTPReader {
    private static let headerTerminator = Data([13, 10, 13, 10])
    private static let maxRequestLineBytes = 2_048
    private static let maxHeaderLineBytes = 4_096
    private static let maxHeaderCount = 40
    private static let maxHeaderBytes = 16_384
    static let maxBodyBytes = 8_192

    /// `maxBodyBytes`/`acceptsBody`: the setup receiver (`AppleSetupReceiveServer`)
    /// reads larger POST bodies on its own paths; the portal keeps 8 KB on `/`.
    static func read(
        from connection: NWConnection,
        maxBodyBytes bodyLimit: Int = maxBodyBytes,
        acceptsBody: @Sendable (String) -> Bool = { $0 == "/" || $0 == "/openstream" }
    ) async throws -> AppleWebManagementHTTPRequest {
        var buffer = Data()
        var streamIsComplete = false

        while true {
            if let terminator = buffer.range(of: headerTerminator) {
                let headerData = buffer[..<terminator.lowerBound]
                guard headerData.count <= maxHeaderBytes else { throw AppleWebManagementHTTPReadError.tooLarge }
                let partial = try parseHead(Data(headerData))
                let bodyOffset = terminator.upperBound

                guard partial.method == "POST", acceptsBody(partial.path) else {
                    return partial.withBody(Data())
                }
                guard partial.headers["transfer-encoding"] == nil else {
                    throw AppleWebManagementHTTPReadError.malformed
                }
                guard let lengthValue = partial.headers["content-length"],
                      let contentLength = Int(lengthValue),
                      (1 ... bodyLimit).contains(contentLength) else {
                    throw AppleWebManagementHTTPReadError.tooLarge
                }

                let availableBodyBytes = buffer.count - bodyOffset
                if availableBodyBytes >= contentLength {
                    let bodyData = buffer[bodyOffset ..< bodyOffset + contentLength]
                    return partial.withBody(Data(bodyData))
                }
                guard buffer.count <= bodyOffset + bodyLimit else {
                    throw AppleWebManagementHTTPReadError.tooLarge
                }
            } else if buffer.count > maxHeaderBytes {
                throw AppleWebManagementHTTPReadError.tooLarge
            }

            if streamIsComplete { throw AppleWebManagementHTTPReadError.malformed }
            let (data, isComplete) = try await receive(from: connection)
            if let data, !data.isEmpty { buffer.append(data) }
            streamIsComplete = isComplete
            if data?.isEmpty != false, !isComplete {
                throw AppleWebManagementHTTPReadError.malformed
            }
        }
    }

    private static func parseHead(_ data: Data) throws -> PartialRequest {
        guard let text = String(data: data, encoding: .utf8) else {
            throw AppleWebManagementHTTPReadError.malformed
        }
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first,
              !requestLine.isEmpty,
              requestLine.utf8.count <= maxRequestLineBytes else {
            throw AppleWebManagementHTTPReadError.tooLarge
        }

        let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard requestParts.count == 3,
              requestParts[2].hasPrefix("HTTP/1."),
              requestParts[1].first == "/" else {
            throw AppleWebManagementHTTPReadError.malformed
        }
        let method = String(requestParts[0])
        let target = String(requestParts[1])
        let targetParts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(targetParts[0])
        let query = targetParts.count == 2 ? AppleWebManagementProtocol.parseForm(String(targetParts[1])) : [:]

        let headerLines = Array(lines.dropFirst())
        guard headerLines.count <= maxHeaderCount else { throw AppleWebManagementHTTPReadError.tooLarge }
        var headers: [String: String] = [:]
        for line in headerLines {
            guard !line.isEmpty, line.utf8.count <= maxHeaderLineBytes else {
                throw line.utf8.count > maxHeaderLineBytes
                    ? AppleWebManagementHTTPReadError.tooLarge
                    : AppleWebManagementHTTPReadError.malformed
            }
            guard let separator = line.firstIndex(of: ":"), separator != line.startIndex else {
                throw AppleWebManagementHTTPReadError.malformed
            }
            let name = String(line[..<separator]).lowercased()
            guard isValidHeaderName(name), headers[name] == nil else {
                throw AppleWebManagementHTTPReadError.malformed
            }
            headers[name] = String(line[line.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
        }

        return PartialRequest(
            method: method,
            target: target,
            path: path,
            query: query,
            headers: headers
        )
    }

    private static func receive(from connection: NWConnection) async throws -> (Data?, Bool) {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (data, isComplete))
                }
            }
        }
    }

    private static func isValidHeaderName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.allSatisfy { byte in
            switch byte {
            case 48 ... 57, 65 ... 90, 97 ... 122:
                true
            case 33, 35 ... 39, 42, 43, 45, 46, 94, 95, 96, 124, 126:
                true
            default:
                false
            }
        }
    }

    private struct PartialRequest {
        let method: String
        let target: String
        let path: String
        let query: [String: String]
        let headers: [String: String]

        func withBody(_ body: Data) -> AppleWebManagementHTTPRequest {
            AppleWebManagementHTTPRequest(
                method: method,
                target: target,
                path: path,
                query: query,
                headers: headers,
                body: String(data: body, encoding: .utf8) ?? "",
                rawBody: body
            )
        }
    }
}

struct AppleWebManagementHTTPResponse: Sendable {
    let code: Int
    let status: String
    let body: String
    let contentType: String
    let headers: [String: String]
    /// Whole `Set-Cookie` values. Kept out of `headers` because that is a
    /// dictionary and a response legitimately sets more than one cookie.
    var cookies: [String] = []

    static func plain(
        _ code: Int,
        _ status: String,
        _ body: String,
        headers: [String: String] = [:],
        cookies: [String] = []
    ) -> Self {
        Self(code: code, status: status, body: body, contentType: "text/plain; charset=utf-8", headers: headers, cookies: cookies)
    }

    static func html(
        _ code: Int,
        _ status: String,
        _ body: String,
        headers: [String: String] = [:],
        cookies: [String] = []
    ) -> Self {
        Self(code: code, status: status, body: body, contentType: "text/html; charset=utf-8", headers: headers, cookies: cookies)
    }

    static func redirect(_ location: String, headers: [String: String] = [:], cookies: [String] = []) -> Self {
        var values = headers
        values["Location"] = location
        return Self(
            code: 303,
            status: "See Other",
            body: "Continue.",
            contentType: "text/plain; charset=utf-8",
            headers: values,
            cookies: cookies
        )
    }

    func serialized() -> Data {
        let bodyData = Data(body.utf8)
        let policy = headers["Content-Security-Policy"] ?? "default-src 'none'; style-src 'unsafe-inline'; script-src 'sha256-\(AppleWebManagementPage.scriptHash)'; connect-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'"
        var lines = [
            "HTTP/1.1 \(code) \(status)",
            "Content-Type: \(contentType)",
            "Content-Length: \(bodyData.count)",
            "Cache-Control: no-store",
            "Connection: close",
            "X-Content-Type-Options: nosniff",
            "X-Frame-Options: DENY",
            "Referrer-Policy: no-referrer",
            "Permissions-Policy: camera=(), microphone=(), geolocation=()",
            "Content-Security-Policy: \(policy)",
        ]
        lines.append(contentsOf: headers.filter { $0.key != "Content-Security-Policy" }.sorted(by: { $0.key < $1.key }).map { "\($0.key): \($0.value)" })
        lines.append(contentsOf: cookies.map { "Set-Cookie: \($0)" })
        var response = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        response.append(bodyData)
        return response
    }
}
