import Darwin
import Foundation
import Network

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

    public private(set) var session: AppleWebManagementSession?
    public var onStop: (@MainActor @Sendable (AppleWebManagementServerStopReason) -> Void)?

    private let configuration: Configuration
    private let manifestClient: AppleManifestClient
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
    /// Browsers that have already entered a code once and need not again.
    private let trust = AppleWebManagementTrust()

    public init(
        configuration: Configuration = Configuration(),
        manifestClient: AppleManifestClient = AppleManifestClient(),
        iptvClient: AppleIPTVClient = AppleIPTVClient()
    ) {
        self.configuration = configuration
        self.manifestClient = manifestClient
        self.iptvClient = iptvClient
    }

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
        let expiresAt = Date().addingTimeInterval(configuration.sessionDuration)
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
        traceWeb("listening on \(friendlyURL.absoluteString) pairing=\(activeSession.pairingCode) for \(Int(configuration.sessionDuration))s")
        publishBonjourIfRequested(port: port)
        installRuntimeStateHandler(for: activeListener)
        scheduleExpiry(after: configuration.sessionDuration)
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
        candidate.newConnectionLimit = 8
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

    private func scheduleExpiry(after duration: TimeInterval) {
        expiryTask?.cancel()
        expiryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(duration))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.tearDown(reason: .expired)
        }
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
            name: "OpenStream",
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
        var timeout = Task { @MainActor in
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
            traceWeb("\(request.method) \(request.target) from \(remoteHost) host=\(request.headers["host"] ?? "none") origin=\(request.headers["origin"] ?? "none")")
            guard generation == acceptedGeneration, let activeSession = session else {
                traceWeb("dropped: session ended before the reply")
                return
            }
            let result = await response(for: request, session: activeSession)
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
        session activeSession: AppleWebManagementSession
    ) async -> (response: AppleWebManagementHTTPResponse, stopAfterSending: Bool) {
        guard request.path == "/" || request.path == "/openstream" || request.path == "/diagnostics" else {
            return (.plain(404, "Not Found", "Not found."), false)
        }
        guard !activeSession.isExpired else {
            return (.plain(410, "Gone", "This setup session has expired."), true)
        }
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
            traceWeb("origin check failed: origin=\(request.headers["origin"] ?? "none") referer=\(request.headers["referer"] ?? "none")")
            return (.plain(403, "Forbidden", "The browser source is not the Web Management page."), false)
        }

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
            guard AppleWebManagementProtocol.hasValidToken(
                form: [:], headers: request.headers, query: request.query, session: activeSession
            ) else {
                traceWeb("diagnostics refused: not paired")
                return (.plain(403, "Forbidden", "Pair with the portal first."), false)
            }
            let log = (try? String(contentsOf: AppleInteractionTrace.fileURL ?? URL(fileURLWithPath: "/dev/null"), encoding: .utf8)) ?? ""
            traceWeb("diagnostics served (\(log.utf8.count) bytes)")
            return (.plain(200, "OK", log.isEmpty ? "No trace recorded yet." : log), false)
        }


        switch request.method {
        case "GET":
            let hasBootstrapToken = request.query["token"].map {
                AppleWebManagementProtocol.hasValidToken(
                    form: ["token": $0], headers: [:], query: [:], session: activeSession
                )
            } ?? false
            let hasSessionToken = AppleWebManagementProtocol.hasValidToken(
                form: [:], headers: request.headers, query: [:], session: activeSession
            )
            let isTrusted = trust.trusts(cookieHeader: request.headers["cookie"])
            if hasBootstrapToken {
                return (
                    .redirect(
                        activeSession.friendlyURL.absoluteString,
                        cookies: pairingCookies(for: activeSession)
                    ),
                    false
                )
            }
            // A browser that paired before is handed the session token straight
            // away, so the code is asked for once per browser rather than once
            // per session (owner 2026-09-15).
            if isTrusted, !hasSessionToken {
                traceWeb("trusted browser recognised; skipping the pairing code")
                return (
                    .html(200, "OK", page(session: activeSession, paired: true),
                          cookies: pairingCookies(for: activeSession)),
                    false
                )
            }
            return (.html(200, "OK", page(session: activeSession, paired: hasSessionToken || isTrusted)), false)

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
            let hasToken = AppleWebManagementProtocol.hasValidToken(
                form: form,
                headers: request.headers,
                query: request.query,
                session: activeSession
            )
            // The pairing code stays usable for the whole session. Consuming it
            // on first use locked the browser out after a failed add, because a
            // dropped cookie left no second way in.
            let paired = AppleWebManagementProtocol.hasValidPairingCode(form: form, session: activeSession)
                || trust.trusts(cookieHeader: request.headers["cookie"])
            guard hasToken || paired else {
                traceWeb("pairing failed: action=\(form["action"] ?? "add") code=\(form["pairingCode"] == nil ? "absent" : "wrong") cookie=\(request.headers["cookie"] == nil ? "absent" : "present")")
                return (.html(
                    403,
                    "Pairing Required",
                    page(
                        session: activeSession,
                        paired: false,
                        manifest: form["manifest"] ?? "",
                        error: "The pairing code is missing or incorrect."
                    )
                ), false)
            }
            // Every authenticated answer refreshes the cookie, so the browser
            // never has to be asked for the pairing code twice.
            let cookie = pairingCookies(for: activeSession)

            switch form["action"] {
            case "pair":
                return (.html(200, "OK", page(session: activeSession, paired: true), cookies: cookie), false)
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
                    source = try await addSource(manifestValue: manifest, sourceStore: sourceStore)
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
                traceWeb("add \(sourceType) failed: \(message)")
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
        sourceType: String = "addon",
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
        default: "addon"
        }
    }

    private static let draftFields = ["m3uName", "playlistURL", "epgURL", "xtreamName", "serverURL", "username"]

    private static func draft(from form: [String: String]) -> [String: String] {
        draftFields.reduce(into: [:]) { result, field in
            if let value = form[field] { result[field] = value }
        }
    }

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

    private func pairingCookies(for session: AppleWebManagementSession) -> [String] {
        let maxAge = max(1, Int(session.expiresAt.timeIntervalSinceNow.rounded(.down)))
        return [
            "openstream_token=\(session.token); Max-Age=\(maxAge); SameSite=Strict; HttpOnly; Path=/",
            trust.cookieHeaderValue,
        ]
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
        let password = form["password"] ?? ""
        // Name the missing field before any network call; the panel would
        // otherwise answer with a generic login failure.
        // Describes the credentials without ever recording them. The owner
        // reports the portal rejecting an account that is known good
        // (2026-09-15, `auth=0`), and the question that answers it is whether
        // what *arrived* matches what was typed — a password mangled by form
        // decoding, truncated, or quietly autofilled by the browser looks
        // identical to a wrong one from the outside. Lengths and character
        // classes distinguish those; the values themselves are never written.
        traceWeb(
            "xtream submit: server=\(endpoint) user=\(username.count) chars"
            + " password=\(password.count) chars"
            + " userASCII=\(username.allSatisfy(\.isASCII)) passwordASCII=\(password.allSatisfy(\.isASCII))"
            + " passwordHasSpace=\(password.contains(" "))"
            + " passwordTrimmedDiffers=\(password != password.trimmingCharacters(in: .whitespacesAndNewlines))"
        )
        guard !username.isEmpty, !password.isEmpty else { throw AppleIPTVError.missingCredentials }
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

private final class AppleWebManagementListenerStartupGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?

    init(continuation: CheckedContinuation<Void, any Error>) {
        self.continuation = continuation
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

        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

private enum AppleWebManagementNetwork {
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

private enum AppleWebManagementHTTPReader {
    private static let headerTerminator = Data([13, 10, 13, 10])
    private static let maxRequestLineBytes = 2_048
    private static let maxHeaderLineBytes = 4_096
    private static let maxHeaderCount = 40
    private static let maxHeaderBytes = 16_384
    private static let maxBodyBytes = 8_192

    static func read(from connection: NWConnection) async throws -> AppleWebManagementHTTPRequest {
        var buffer = Data()
        var streamIsComplete = false

        while true {
            if let terminator = buffer.range(of: headerTerminator) {
                let headerData = buffer[..<terminator.lowerBound]
                guard headerData.count <= maxHeaderBytes else { throw AppleWebManagementHTTPReadError.tooLarge }
                let partial = try parseHead(Data(headerData))
                let bodyOffset = terminator.upperBound

                guard partial.method == "POST", partial.path == "/" || partial.path == "/openstream" else {
                    return partial.withBody(Data())
                }
                guard partial.headers["transfer-encoding"] == nil else {
                    throw AppleWebManagementHTTPReadError.malformed
                }
                guard let lengthValue = partial.headers["content-length"],
                      let contentLength = Int(lengthValue),
                      (1 ... maxBodyBytes).contains(contentLength) else {
                    throw AppleWebManagementHTTPReadError.tooLarge
                }

                let availableBodyBytes = buffer.count - bodyOffset
                if availableBodyBytes >= contentLength {
                    let bodyData = buffer[bodyOffset ..< bodyOffset + contentLength]
                    return partial.withBody(Data(bodyData))
                }
                guard buffer.count <= bodyOffset + maxBodyBytes else {
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

private struct AppleWebManagementHTTPResponse: Sendable {
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
        let policy = headers["Content-Security-Policy"] ?? "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'"
        var lines = [
            "HTTP/1.1 \(code) \(status)",
            "Content-Type: \(contentType)",
            "Content-Length: \(bodyData.count)",
            "Cache-Control: no-store",
            "Connection: close",
            "X-Content-Type-Options: nosniff",
            "X-Frame-Options: DENY",
            "Referrer-Policy: same-origin",
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
